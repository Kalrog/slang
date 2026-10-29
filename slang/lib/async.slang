// slang/async: Futures, Streams and await on coroutines, driven by the uv
// event loop (the native `uv` module). Callback style and await style mix:
//
//   local async = require("slang/async")
//   async.main(func(){
//     local conn = async.await(async.connect("127.0.0.1", 8080))
//     async.await(async.write(conn, "hello\n"))
//     local reader = async.reader(conn)
//     for(true){
//       local r = async.await(reader:next())
//       if(r.done){ break }
//       print(r.value)
//     }
//   })
//
// The extension `extensions/async` adds `async func`, `await` and `await for`
// on top of this module.
//
// A Future completes once, with a value or an error (any value; errors raised
// inside async functions are the error tables pcall produces). A Stream is a
// sequence of values ending with done or an error; `next()` gives the next
// event as a Future, `listen` consumes it with a callback.
//
// await(f) must be called from a coroutine started by async.run (an "async
// function"). It registers a waiter that reschedules the coroutine and
// yields; a completed Future returns immediately without yielding. Waiters
// run from the loop (a zero timer), never inside the code that completed
// the Future, so completing a Future never re-enters the completer.
local thread = require("slang/thread")
local str = require("slang/string")

local async = {}

// ------------------------------------------------------------ scheduler

local uv = null
local ready = {}
local wake = null

local func loop_module(){
  if(uv == null){
    uv = require("uv")
  }
  return uv
}

// runs f from the loop, after the current callback or coroutine returns
local func schedule(f){
  append(ready, f)
  if(wake == null){
    wake = loop_module().timer()
  }
  if(not wake:is_active()){
    wake:start(0, 0, func(){
      local batch = ready
      ready = {}
      for(let local g in values(batch)){
        g()
      }
    })
  }
}

// coroutines started by async.run, by thread object
local running = {}
// failed futures nobody awaited or caught (reported by async.main)
local unhandled = {}

// ------------------------------------------------------------ futures

local future_methods = {}
local future_meta = {__index: future_methods, __type: "Future"}

local func new_future(){
  local f = {state: "pending", value: null, error: null, waiters: {}, handled: false}
  f.meta = future_meta
  return f
}

local func settle(f, state, v){
  if(f.state != "pending"){
    error("the future is already ", f.state)
  }
  f.state = state
  if(state == "done"){
    f.value = v
  } else {
    f.error = v
    if(not f.handled){
      append(unhandled, f)
    }
  }
  local waiters = f.waiters
  f.waiters = {}
  for(let local w in values(waiters)){
    w(f)
  }
}

local func on_settled(f, w){
  f.handled = true
  if(f.state == "pending"){
    append(f.waiters, w)
  } else {
    w(f)
  }
}

func future_methods.is_done(f){
  return f.state != "pending"
}

// then(on_value, on_error) -> Future of what the handler returns; a handler
// may return a Future, which the result then follows. Without on_error the
// error propagates to the returned future.
func future_methods.then(f, on_value, on_error){
  local out = new_future()
  on_settled(f, func(f){
    local handler = on_value
    local arg = f.value
    if(f.state == "error"){
      handler = on_error
      arg = f.error
    }
    if(handler == null){
      settle(out, f.state, arg)
      return
    }
    local r = pcall(handler, arg)
    if(r[0] == "err"){
      settle(out, "error", r[1])
    } else if(type(r[1]) == "Future"){
      on_settled(r[1], func(g){
        if(g.state == "done"){
          settle(out, "done", g.value)
        } else {
          settle(out, "error", g.error)
        }
      })
    } else {
      settle(out, "done", r[1])
    }
  })
  return out
}

func future_methods.catch(f, on_error){
  return f:then(null, on_error)
}

// completer() -> {future, complete(value), fail(error)}
func async.completer(){
  local f = new_future()
  return {
    future: f,
    complete: func(v){ settle(f, "done", v) },
    fail: func(e){ settle(f, "error", e) },
  }
}

func async.value(v){
  local f = new_future()
  settle(f, "done", v)
  return f
}

func async.failed(e){
  local f = new_future()
  settle(f, "error", e)
  return f
}

// wrap(start) -> Future: start(cb) begins an operation whose callback has the
// uv shape cb(err, value); the future fails with err or completes with value
func async.wrap(start){
  local c = async.completer()
  local r = pcall(start, func(err, value){
    if(err != null){
      c.fail(err)
    } else {
      c.complete(value)
    }
  })
  if(r[0] == "err"){
    c.fail(r[1])
  }
  return c.future
}

// all(futures) -> Future of the list of values (fails with the first error)
func async.all(futures){
  local c = async.completer()
  local values_out = {}
  local left = len(futures)
  if(left == 0){
    c.complete(values_out)
    return c.future
  }
  local failed = false
  for(let local e in entries(futures)){
    local i = e[0]
    on_settled(e[1], func(f){
      if(failed){ return }
      if(f.state == "error"){
        failed = true
        c.fail(f.error)
        return
      }
      values_out[i] = f.value
      left = left - 1
      if(left == 0){
        c.complete(values_out)
      }
    })
  }
  return c.future
}

// race(futures) -> Future that settles like the first of the futures to
// settle; the others are marked handled and their results dropped
func async.race(futures){
  local c = async.completer()
  local settled = false
  for(let local f in values(futures)){
    on_settled(f, func(f){
      if(settled){ return }
      settled = true
      if(f.state == "done"){
        c.complete(f.value)
      } else {
        c.fail(f.error)
      }
    })
  }
  return c.future
}

// timeout(f, ms, message) -> Future of f's value, or failing with message
// ("timed out after <ms> ms" by default) when f takes longer than ms
// milliseconds (an error keeps only its message through raise, so tell a
// timeout by the message you chose)
func async.timeout(f, ms, message){
  local c = async.completer()
  local settled = false
  local timer = loop_module().timer()
  timer:start(ms, 0, func(){
    timer:close()
    if(not settled){
      settled = true
      c.fail(message or concat("timed out after ", string(ms), " ms"))
    }
  })
  on_settled(f, func(f){
    if(settled){ return }
    settled = true
    timer:stop()
    timer:close()
    if(f.state == "done"){
      c.complete(f.value)
    } else {
      c.fail(f.error)
    }
  })
  return c.future
}

// ------------------------------------------------------------ await and run

// await(f) -> the value of f, or raises its error
func async.await(f){
  if(type(f) != "Future"){
    error("await expects a Future, got ", type(f))
  }
  f.handled = true
  if(f.state == "pending"){
    local co = thread.current()
    if(running[co] == null){
      error("await outside an async function (use async.run or async.main)")
    }
    on_settled(f, func(f){
      schedule(func(){ thread.resume(co) })
    })
    thread.yield()
  }
  if(f.state == "error"){
    raise(f.error)
  }
  return f.value
}

// run(f) -> Future: runs f in a coroutine that may await; the future
// completes with f's return value or fails with its error
func async.run(f){
  local fut = new_future()
  local co = null
  co = thread.create(func(){
    local r = pcall(f)
    running[co] = null
    if(r[0] == "ok"){
      settle(fut, "done", r[1])
    } else {
      settle(fut, "error", r[1])
    }
  })
  running[co] = true
  thread.resume(co)
  return fut
}

// sleep(ms) -> Future that completes after ms milliseconds
func async.sleep(ms){
  return async.wrap(func(cb){
    local timer = loop_module().timer()
    timer:start(ms, 0, func(){
      timer:close()
      cb(null, null)
    })
  })
}

// main(f) -> the value of f: runs f as an async function and drives the
// event loop until it finishes. Failed futures nobody handled are reported.
func async.main(f){
  local uv = loop_module()
  local fut = async.run(f)
  for(fut.state == "pending"){
    local more = uv.run("once")
    if(not more and fut.state == "pending"){
      error("async.main: the loop has nothing left to do but the main function has not finished")
    }
  }
  if(len(unhandled) > 0){
    local bad = unhandled
    unhandled = {}
    for(let local g in values(bad)){
      if(not g.handled){
        local msg = g.error
        if(type(msg) == "table" and msg.message != null){
          msg = msg.message
        }
        print("async: unhandled error in a future: ", msg, "\n")
      }
    }
  }
  if(fut.state == "error"){
    raise(fut.error)
  }
  return fut.value
}

// ------------------------------------------------------------ streams

local stream_methods = {}
local stream_meta = {__index: stream_methods, __type: "Stream"}

// controller() -> {stream, add(value), close(), fail(error)}; on_pause and
// on_resume on the controller are called when the buffer passes high_water
// and when a reader drains it (backpressure)
func async.controller(options){
  local s = {buffer: {}, done: false, error: null, pending: null, listener: null, paused: false,
             high_water: (options or {}).high_water or 16}
  s.meta = stream_meta
  local c = {stream: s, on_pause: null, on_resume: null}
  local func deliver(){
    // a listener takes everything; a pending next() takes one event
    if(s.listener != null){
      local buffered = s.buffer
      s.buffer = {}
      for(let local v in values(buffered)){
        s.listener(null, v)
      }
      if(s.error != null){
        local e = s.error
        s.error = null
        s.listener(e, null)
      } else if(s.done and not s.finished){
        s.finished = true
        s.listener(null, null)
      }
    } else if(s.pending != null){
      if(len(s.buffer) > 0){
        local v = remove(s.buffer, 0)
        local p = s.pending
        s.pending = null
        p.complete({value: v})
      } else if(s.error != null){
        local e = s.error
        s.error = null
        local p = s.pending
        s.pending = null
        p.fail(e)
      } else if(s.done){
        local p = s.pending
        s.pending = null
        p.complete({done: true})
      }
    }
    if(s.paused and len(s.buffer) < s.high_water and c.on_resume != null){
      s.paused = false
      c.on_resume()
    }
  }
  s.deliver = deliver
  c.add = func(v){
    if(s.done){ error("the stream is closed") }
    append(s.buffer, v)
    deliver()
    if(not s.paused and len(s.buffer) >= s.high_water and c.on_pause != null){
      s.paused = true
      c.on_pause()
    }
  }
  c.close = func(){
    if(s.done){ return }
    s.done = true
    deliver()
  }
  c.fail = func(e){
    if(s.done){ return }
    s.done = true
    s.error = e
    deliver()
  }
  return c
}

// next() -> Future of {value} or {done: true}; fails with the stream's error
func stream_methods.next(s){
  if(s.pending != null){
    error("the stream is already being read")
  }
  if(s.listener != null){
    error("the stream has a listener")
  }
  local c = async.completer()
  s.pending = c
  s.deliver()
  return c.future
}

// listen(cb(err, value)): callback style; value is null at the end
func stream_methods.listen(s, cb){
  if(s.listener != null or s.pending != null){
    error("the stream is already being read")
  }
  s.listener = cb
  s.deliver()
  return s
}

// collect() -> Future of the list of all values
func stream_methods.collect(s){
  local c = async.completer()
  local out = {}
  s:listen(func(err, v){
    if(err != null){
      c.fail(err)
    } else if(v == null){
      c.complete(out)
    } else {
      append(out, v)
    }
  })
  return c.future
}

// pull(next_value) -> a Stream that reads only when asked: next() calls
// next_value(), which returns the next value, null at the end, or a Future
// of either. Nothing is read ahead, so a slow reader slows the source (a
// file sent to a slow client is not read into memory first).
local pull_methods = {}
local pull_meta = {__index: pull_methods, __type: "Stream"}

func async.pull(next_value){
  return {meta: pull_meta, source: next_value, done: false, busy: false}
}

func pull_methods.next(s){
  if(s.busy){
    error("the stream is already being read")
  }
  if(s.done){
    return async.value({done: true})
  }
  s.busy = true
  local r = pcall(s.source)
  local f = null
  if(r[0] == "err"){
    f = async.failed(r[1])
  } else if(type(r[1]) == "Future"){
    f = r[1]
  } else {
    f = async.value(r[1])
  }
  return f:then(func(v){
    s.busy = false
    if(v == null){
      s.done = true
      return {done: true}
    }
    return {value: v}
  }, func(e){
    s.busy = false
    s.done = true
    raise(e)
  })
}

func pull_methods.collect(s){
  return async.run(func(){
    local out = {}
    for(true){
      local e = async.await(s:next())
      if(e.done){
        return out
      }
      append(out, e.value)
    }
  })
}

func pull_methods.listen(s, cb){
  async.run(func(){
    local r = pcall(func(){
      for(true){
        local e = async.await(s:next())
        if(e.done){
          return null
        }
        cb(null, e.value)
      }
    })
    if(r[0] == "err"){
      cb(r[1], null)
    } else {
      cb(null, null)
    }
  })
  return s
}

// iterator(stream) -> a function returning the next value, or null at the
// end (what `await for` loops over: a for-in loop calls it until the pattern
// stops matching, so a null value ends the loop early)
func async.iterator(s){
  return func(){
    local e = async.await(s:next())
    if(e.done){
      return null
    }
    return e.value
  }
}

// ------------------------------------------------------------ tcp adapters

// is_ip(host): an IPv4 or IPv6 address rather than a name
local func is_ip(host){
  if(str.index_of(host, ":") >= 0){
    return true
  }
  for(local i = 0; i < len(host); i = i + 1){
    local b = str.byte_at(host, i)
    if(b != 46 and (b < 48 or b > 57)){
      return false
    }
  }
  return true
}

// resolve(host, port, family) -> Future of the list of {ip, port, family}
// the name resolves to; family "ipv4" or "ipv6" limits it
func async.resolve(host, port, family){
  return async.wrap(func(cb){
    if(family != null){
      loop_module().getaddrinfo(host, port, family, cb)
    } else {
      loop_module().getaddrinfo(host, port, cb)
    }
  })
}

// connect(host, port) -> Future of a connected uv.tcp handle; a host name
// is resolved first and its addresses tried in order
func async.connect(host, port){
  local uv = loop_module()
  return async.wrap(func(cb){
    local func attempt(addrs, i, last_err){
      if(i >= len(addrs)){
        cb(last_err or concat("cannot connect to ", host, ": no addresses"), null)
        return
      }
      local conn = uv.tcp()
      conn:connect(addrs[i].ip, port, func(err){
        if(err == null){
          cb(null, conn)
        } else {
          conn:close()
          attempt(addrs, i + 1, err)
        }
      })
    }
    if(is_ip(host)){
      attempt({{ip: host}}, 0, null)
    } else {
      uv.getaddrinfo(host, port, func(err, addrs){
        if(err != null){
          cb(err, null)
        } else {
          attempt(addrs, 0, null)
        }
      })
    }
  })
}

// write(handle, data) -> Future
func async.write(handle, data){
  return async.wrap(func(cb){
    handle:write(data, cb)
  })
}

// shutdown(handle) -> Future; close(handle) -> Future
func async.shutdown(handle){
  return async.wrap(func(cb){
    handle:shutdown(cb)
  })
}

func async.close(handle){
  return async.wrap(func(cb){
    handle:close(func(){ cb(null, null) })
  })
}

// reader(handle) -> Stream of chunks (reading pauses when the consumer falls
// behind and resumes when it catches up)
func async.reader(handle, options){
  local c = async.controller(options)
  c.on_pause = func(){ handle:read_stop() }
  c.on_resume = func(){ handle:read_start(c.on_chunk) }
  c.on_chunk = func(err, chunk){
    if(err != null){
      c.fail(err)
    } else if(chunk == null){
      c.close()
    } else {
      c.add(chunk)
    }
  }
  handle:read_start(c.on_chunk)
  return c.stream
}

// serve(host, port, options) -> {server, connections, close()}: a listening
// socket and a Stream of accepted uv.tcp handles; close() stops listening
// and ends the stream
func async.serve(host, port, options){
  local uv = loop_module()
  local server = uv.tcp()
  server:bind(host, port)
  local c = async.controller(options)
  server:listen((options or {}).backlog or 128, func(err){
    if(err != null){
      c.fail(err)
      return
    }
    local conn = uv.tcp()
    server:accept(conn)
    c.add(conn)
  })
  return {server: server, connections: c.stream, close: func(){
    server:close()
    c.close()
  }}
}

// ------------------------------------------------------------ files

// The file system on libuv's thread pool; every function returns a Future.
// Errors read like "ENOENT: no such file or directory, read_file 'x'".
//
//   fs.read_file(path) -> the contents    fs.write_file(path, data)
//   fs.append_file(path, data)            fs.exists(path) -> bool
//   fs.stat(path) -> {size, mode, mtime, atime, ctime, is_file, is_dir}
//   fs.list_dir(path) -> list of {name, type}   (type "file", "dir", ...)
//   fs.remove(path)   fs.mkdir(path)   fs.rmdir(path)   fs.rename(from, to)
//   fs.open(path, flags) -> fd   (flags as fopen: "r", "w", "a", "r+", ...)
//   fs.read(fd, length, offset) -> data ("" at the end; offset null reads on)
//   fs.write(fd, data, offset) -> bytes written   fs.close(fd)
//   fs.read_stream(path, chunk_size) -> a Stream of the file, read on demand
local fs = {}
async.fs = fs

local func fs_call(name, ...arguments){
  return async.wrap(func(cb){
    local uv = loop_module()
    uv[name](...arguments, cb)
  })
}

func fs.read_file(path){ return fs_call("fs_read_file", path) }
func fs.write_file(path, data){ return fs_call("fs_write_file", path, data, false) }
func fs.append_file(path, data){ return fs_call("fs_write_file", path, data, true) }
func fs.stat(path){ return fs_call("fs_stat", path) }
func fs.list_dir(path){ return fs_call("fs_scandir", path) }
func fs.remove(path){ return fs_call("fs_unlink", path) }
func fs.mkdir(path){ return fs_call("fs_mkdir", path) }
func fs.rmdir(path){ return fs_call("fs_rmdir", path) }
func fs.rename(from, to){ return fs_call("fs_rename", from, to) }
func fs.open(path, flags){ return fs_call("fs_open", path, flags or "r") }
func fs.close(fd){ return fs_call("fs_close", fd) }

func fs.read(fd, length, offset){
  return async.wrap(func(cb){ loop_module().fs_read(fd, length, offset or -1, cb) })
}

func fs.write(fd, data, offset){
  return async.wrap(func(cb){ loop_module().fs_write(fd, data, offset or -1, cb) })
}

// read_stream(path, chunk_size) -> a Stream of the file's contents in
// chunks (64 KiB by default), read as they are asked for; the file is
// closed at the end or on an error
func fs.read_stream(path, chunk_size){
  local size = chunk_size or 65536
  local fd = null
  local finished = false
  return async.pull(func(){
    if(finished){
      return null
    }
    return async.run(func(){
      local r = pcall(func(){
        if(fd == null){
          fd = async.await(fs.open(path, "r"))
        }
        return async.await(fs.read(fd, size, null))
      })
      if(r[0] == "err" or r[1] == ""){
        finished = true
        if(fd != null){
          pcall(async.await, fs.close(fd))
        }
        if(r[0] == "err"){
          raise(r[1])
        }
        return null
      }
      return r[1]
    })
  })
}

func fs.exists(path){
  return async.wrap(func(cb){
    loop_module().fs_stat(path, func(err, st){ cb(null, err == null) })
  })
}

// ------------------------------------------------------------ signals

// on_signal(name, f) -> the uv.signal handle: f(name) runs each time the
// process gets the signal ("SIGINT", "SIGTERM", ...). The handle does not
// keep the loop running; stop() or close() it when done.
func async.on_signal(name, f){
  local h = loop_module().signal()
  h:start(name, func(err, got){ f(got) })
  h:unref()
  return h
}

// ------------------------------------------------------------ processes

// spawn(file, args, options) -> {process, pid, stdin, stdout, stderr,
// pipes, exit, kill(sig)}: starts a program. options as for uv.spawn (cwd,
// env, detached), except that a stdio entry "pipe" makes a pipe: the ones
// for fds 0, 1 and 2 are stdin, stdout and stderr, all of them are in
// pipes by fd. Without stdio the child inherits 0, 1 and 2. exit is a
// Future of {status, signal}. Raises when the program cannot be started.
func async.spawn(file, args, options){
  local uv = loop_module()
  local opts = {}
  for(let local e in entries(options or {})){
    opts[e[0]] = e[1]
  }
  local pipes = {}
  if(opts.stdio != null){
    local stdio = {}
    for(local i = 0; i < len(opts.stdio); i = i + 1){
      local entry = opts.stdio[i]
      if(entry == "pipe"){
        entry = uv.pipe()
        pipes[i] = entry
      }
      append(stdio, entry)
    }
    opts.stdio = stdio
  }
  local exit = async.completer()
  local process = uv.spawn(file, args or {}, opts, func(err, r){
    if(err != null){
      exit.fail(err)
    } else {
      exit.complete(r)
    }
  })
  return {process: process, pid: process:pid(), pipes: pipes,
          stdin: pipes[0], stdout: pipes[1], stderr: pipes[2], exit: exit.future,
          kill: func(sig){ process:kill(sig) }}
}

// collect(pipe) -> Future of everything read from the pipe until it ends
local func collect(pipe){
  return async.wrap(func(cb){
    local parts = {}
    pipe:read_start(func(err, chunk){
      if(err != null){
        pipe:close()
        cb(err, null)
      } else if(chunk == null){
        pipe:close()
        cb(null, str.join(parts, ""))
      } else {
        append(parts, chunk)
      }
    })
  })
}

// exec(file, args, options) -> Future of {status, signal, stdout, stderr}:
// runs a program to the end and collects its output. options.input is
// written to its stdin (otherwise stdin is empty); cwd and env as for spawn.
func async.exec(file, args, options){
  local opts = {}
  for(let local e in entries(options or {})){
    opts[e[0]] = e[1]
  }
  local input = opts.input
  opts.input = null
  opts.stdio = {"pipe", "pipe", "pipe"}
  local p = null
  local r = pcall(func(){ p = async.spawn(file, args, opts) })
  if(r[0] == "err"){
    return async.failed(r[1])
  }
  if(input != null and input != ""){
    p.stdin:write(input)
  }
  p.stdin:shutdown(func(){ p.stdin:close() })
  local out = collect(p.stdout)
  local err = collect(p.stderr)
  return async.all({p.exit, out, err}):then(func(all){
    return {status: all[0].status, signal: all[0].signal, stdout: all[1], stderr: all[2]}
  })
}

return async
