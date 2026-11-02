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
// A [Future] completes once, with a value or an error (any value; errors
// raised inside async functions are the error tables pcall produces). A
// [Stream] is a sequence of values ending with done or an error; its next()
// gives the next [Event] as a Future, listen() consumes it with a callback.
// A [Completer] makes a Future, a [Controller] a Stream.
//
// [await] must be called from a coroutine started by [run] or [main] (an
// "async function"). It registers a waiter that reschedules the coroutine
// and yields; a completed Future returns immediately without yielding.
// Waiters run from the loop (a zero timer), never inside the code that
// completed the Future, so completing a Future never re-enters the
// completer.
//
// Handles (TCP connections, pipes, timers) are the native `uv` module's;
// [connect], [serve] and [reader] turn them into Futures and Streams.
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

// The result of an operation that finishes later: it completes once, with
// a value or an error. [await] it in an async function, or chain
// [Future.then] and [Future.catch]. A failed Future nobody awaits or
// catches is reported by [main].
// type Future
local future_methods = {}
local future_meta = {__index: future_methods, __type: "async.Future"}

local func new_future(){
  local f = {
    state: "pending", value: null, error: null, waiters: {}, handled: false
  }
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

// is_done() -> bool
// Whether the future has completed or failed.
func future_methods.is_done(f){
  return f.state != "pending"
}

// then(on_value?: func(value: any): any,
//      on_error?: func(error: any): any) -> Future
// A Future of what the handler returns; a handler may return a Future,
// which the result then follows. Without on_error the error propagates to
// the returned future; an error the handler raises fails it.
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
    } else if(type(r[1]) == "async.Future"){
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

// catch(on_error: func(error: any): any) -> Future
// then(null, on_error): a Future of f's value, or of what on_error returns
// for its error.
func future_methods.catch(f, on_error){
  return f:then(null, on_error)
}

// The making side of a Future: call complete or fail once (a second call
// raises "the future is already ...").
// type Completer = {future: Future, complete: func(value: any),
//   fail: func(error: any)}

// completer() -> Completer
// A pending [Future] and the functions that settle it.
//   local c = async.completer()
//   timer:start(100, 0, func(){ c.complete("late") })
//   return c.future
func async.completer(){
  local f = new_future()
  return {
    future: f,
    complete: func(v){ settle(f, "done", v) },
    fail: func(e){ settle(f, "error", e) },
  }
}

// value(v) -> Future
// A Future already completed with v.
func async.value(v){
  local f = new_future()
  settle(f, "done", v)
  return f
}

// failed(e) -> Future
// A Future already failed with e. Unless something awaits or catches it,
// [main] reports it as unhandled.
func async.failed(e){
  local f = new_future()
  settle(f, "error", e)
  return f
}

// wrap(start: func(cb: func(err: any, value: any))) -> Future
// Turns a callback-style operation into a Future: start(cb) begins it, and
// cb has the uv shape cb(err, value). The future fails with err (when not
// null) or completes with value; an error start raises fails it too.
//   local f = async.wrap(func(cb){ handle:write(data, cb) })
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

// all(futures: {Future}) -> Future
// A Future of the list of the futures' values, in their order; it fails
// with the first error. An empty list gives an empty list at once.
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

// race(futures: {Future}) -> Future
// Settles like the first of the futures to settle; the others are marked
// handled and their results dropped. An empty list never settles.
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

// timeout(f: Future, ms: int, message?: string) -> Future
// A Future of f's value (or error), failing with [message] instead when f
// takes longer than ms milliseconds. f itself goes on; its late result is
// dropped. An error keeps only its message through raise, so tell a
// timeout by the message you chose.
// [message]: "timed out after <ms> ms" by default
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

// await(f: Future) -> the value of f
// Waits for f, suspending the async function, and returns its value or
// raises its error. Raises when f is not a Future or when called outside
// an async function ([run], [main]). A completed f returns at once.
func async.await(f){
  if(type(f) != "async.Future"){
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

// run(f: function) -> Future
// Runs f as an async function: in a coroutine that may [await]. It starts
// at once and runs until its first await. The future completes with f's
// return value or fails with its error.
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

// sleep(ms: int) -> Future
// Completes (with null) after ms milliseconds.
func async.sleep(ms){
  return async.wrap(func(cb){
    local timer = loop_module().timer()
    timer:start(ms, 0, func(){
      timer:close()
      cb(null, null)
    })
  })
}

// receive(ch: isolate.Channel) -> Future
// The next value of a channel (slang/isolate) as a Future, without
// blocking the loop: it completes when a value arrives, with null once the
// channel is closed and empty. An isolate's channel wakes the loop through
// a uv async handle, which keeps the loop running while the receive waits.
func async.receive(ch){
  local v = ch:try_receive()
  if(v != null or ch.closed){
    return async.value(v)
  }
  local c = async.completer()
  local h = null
  h = loop_module().async(func(){
    local got = ch:try_receive()
    if(got != null or ch.closed){
      ch:unwatch(h)
      h:close()
      c.complete(got)
    }
  })
  ch:watch(h)
  return c.future
}

// The driver: what async.main calls to wait for and handle one batch of
// events, returning whether there is more to do. By default libuv's
// run("once"); a GUI extension (slang/webview) sets its own, which waits on
// the window system and on libuv together.
local driver = null

// set_driver(step?: func(): bool)
// Replaces how [main] waits for events: step() handles one batch and says
// whether there is more to do. null restores libuv's run("once"). For GUI
// extensions (slang/webview) that wait on a window system and libuv
// together.
func async.set_driver(step){
  driver = step
}

// main(f: function) -> the value of f
// Runs f as an async function and drives the event loop until it
// finishes; the program's entry point. Raises f's error, or when the loop
// runs dry while f still waits. Failed futures nobody awaited or caught
// are printed as "async: unhandled error in a future".
func async.main(f){
  local uv = loop_module()
  local fut = async.run(f)
  for(fut.state == "pending"){
    local more = false
    if(driver != null){
      more = driver()
    } else {
      more = uv.run("once")
    }
    if(not more and fut.state == "pending"){
      error(
        "async.main: the loop has nothing left to do but the main function has not finished",
      )
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

// A sequence of values that ends with done or an error. Read it one way:
// [Stream.next] (or `await for`), [Stream.listen] or [Stream.collect]; a
// second reader raises "the stream is already being read".
// type Stream
local stream_methods = {}
local stream_meta = {__index: stream_methods, __type: "async.Stream"}

// What [Stream.next] gives: {value: v}, or {done: true} at the end.
// type Event = {value?: any, done?: bool}

// The writing side of a Stream. add raises once the stream is closed;
// close and fail after the end do nothing.
// type Controller = {stream: Stream, add: func(value: any), close: func(),
//   fail: func(error: any), on_pause?: func(), on_resume?: func()}
// [on_pause]: called when the buffer reaches the high-water mark: pause
// [on_resume]: called when a reader has drained the buffer below it again

// controller(options?: {high_water?: int}) -> Controller
// A [Stream] fed by add(), with a buffer for values no one has read yet.
//   local c = async.controller()
//   c.add("a")
//   c.close()
//   async.await(c.stream:collect())   // {"a"}
// [options]: high_water, the buffered values that call on_pause (16)
func async.controller(options){
  local s = {
    buffer: {}, done: false, error: null, pending: null, listener: null,
    paused: false, high_water: (options or {}).high_water or 16
  }
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

// next() -> Future
// A Future of the next [Event]; it fails with the stream's error. One
// next() at a time; raises while another is pending or with a listener.
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

// listen(cb: func(err: any, value: any)) -> Stream
// Reads the stream with a callback: cb(null, value) for each value, then
// cb(null, null) at the end or cb(err, null) on an error. Returns the
// stream.
func stream_methods.listen(s, cb){
  if(s.listener != null or s.pending != null){
    error("the stream is already being read")
  }
  s.listener = cb
  s.deliver()
  return s
}

// collect() -> Future
// A Future of the list of all the values; it fails with the stream's
// error.
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

// the methods of a pulled Stream (async.pull): next, collect and listen as
// a controller's Stream has them
local pull_methods = {}
local pull_meta = {__index: pull_methods, __type: "async.Stream"}

// pull(next_value: func(): any) -> Stream
// A Stream that reads only when asked: each next() calls next_value(),
// which returns the next value, null at the end, or a Future of either; an
// error it raises (or its Future's) ends the stream with that error.
// Nothing is read ahead, so a slow reader slows the source (a file sent to
// a slow client is not read into memory first).
//   local n = 0
//   local s = async.pull(func(){ n = n + 1  return n <= 3 and n or null })
func async.pull(next_value){
  return {meta: pull_meta, source: next_value, done: false, busy: false}
}

// next() -> Future
// Calls the source once and gives a Future of the next [Event].
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
  } else if(type(r[1]) == "async.Future"){
    f = r[1]
  } else {
    f = async.value(r[1])
  }
  return f:then(
    func(v){
      s.busy = false
      if(v == null){
        s.done = true
        return {done: true}
      }
      return {value: v}
    },
    func(e){
      s.busy = false
      s.done = true
      raise(e)
    },
  )
}

// collect() -> Future
// A Future of the list of all the values.
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

// listen(cb: func(err: any, value: any)) -> Stream
// Reads the stream with a callback, as [Stream.listen] does.
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

// iterator(s: Stream) -> func(): any
// A function that awaits and returns the stream's next value, or null at
// the end; what `await for` loops over. Call it in an async function. A
// for-in loop stops at the first null, so a null value in the stream ends
// the loop early.
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

// An address a name resolves to.
// type Address = {ip: string, port: int, family: string}

// resolve(host: string, port: int, family?: string) -> Future
// A Future of the list of [Address]es host resolves to.
// [family]: "ipv4" or "ipv6" to resolve to that family only
func async.resolve(host, port, family){
  return async.wrap(func(cb){
    if(family != null){
      loop_module().getaddrinfo(host, port, family, cb)
    } else {
      loop_module().getaddrinfo(host, port, cb)
    }
  })
}

// connect(host: string, port: int) -> Future
// A Future of a connected uv.tcp handle. A host name is resolved first and
// its addresses tried in order; the future fails with the last error.
func async.connect(host, port){
  local uv = loop_module()
  return async.wrap(func(cb){
    local func attempt(addrs, i, last_err){
      if(i >= len(addrs)){
        cb(
          last_err or concat("cannot connect to ", host, ": no addresses"),
          null,
        )
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

// write(handle, data: string) -> Future
// Writes data to a uv stream handle (TCP, pipe, TLS); completes when it is
// written.
func async.write(handle, data){
  return async.wrap(func(cb){
    handle:write(data, cb)
  })
}

// shutdown(handle) -> Future
// Ends the writing side of a uv stream handle once pending writes are done.
func async.shutdown(handle){
  return async.wrap(func(cb){
    handle:shutdown(cb)
  })
}

// close(handle) -> Future
// Closes a uv handle; completes when it is closed.
func async.close(handle){
  return async.wrap(func(cb){
    handle:close(func(){ cb(null, null) })
  })
}

// reader(handle, options?: {high_water?: int}) -> Stream
// A Stream of the string chunks read from a uv stream handle, ending when
// the other side does. Reading pauses when the consumer falls behind and
// resumes when it catches up.
// [options]: as for [controller]
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

// A listening TCP socket.
// type Listener = {server: any, connections: Stream, close: func()}
// [server]: the uv.tcp handle (server:getsockname().port is the port)
// [connections]: the accepted connections, as uv.tcp handles
// [close]: stops listening and ends connections

// serve(host: string, port: int, options?: {backlog?: int,
//   high_water?: int}) -> Listener
// Listens on host:port. Raises when it cannot bind.
// [port]: 0 picks a free port
// [options]: backlog, pending connections (128); high_water: [controller]
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
  return {
    server: server,
    connections: c.stream,
    close: func(){
      server:close()
      c.close()
    },
  }
}

// ------------------------------------------------------------ files

local fs = {}

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
//   fs.read_stream(path, {chunk_size, start, length}) -> a Stream of the file, read on demand
//
// In a program built by `slang build`, a relative path that names a bundled
// file or directory is read from the bundle (read_file, stat, list_dir,
// exists, read_stream; see slang/bundle); the rest is the disk's.
//
//   local text = async.await(async.fs.read_file("notes.txt"))
async.fs = fs

local bundle = require("slang/bundle")

// What fs.stat gives; times are milliseconds since the epoch.
// type Stat = {size: int, mode: int, mtime: float, atime: float,
//   ctime: float, is_file: bool, is_dir: bool}

// An entry of fs.list_dir.
// type DirEntry = {name: string, type: string}
// [type]: "file", "dir", "link", "unknown" or "other"

// what a relative path is in a built program's bundle: {stat} when the
// bundle holds the file or directory, {path} for a file kept next to the
// executable (slang build --dir), null when it is the disk's
local func bundled(path){
  local st = bundle.stat(path)
  if(st == null){
    return null
  }
  if(st.path != null){
    return {path: st.path}
  }
  return {stat: st}
}

// where a path is on disk: a file kept next to the executable is there
local func disk_path(b, path){
  if(b != null and b.path != null){
    return b.path
  }
  return path
}

// a bundled file's or directory's stat as uv gives it
local func uv_stat(st){
  local mtime = (st.mtime or 0) * 1.0
  return {
    size: st.size or 0, mode: st.is_dir and 16877 or 33188, mtime: mtime,
    atime: mtime, ctime: mtime, is_file: st.is_file, is_dir: st.is_dir
  }
}

local func fs_call(name, ...arguments){
  return async.wrap(func(cb){
    local uv = loop_module()
    uv[name](...arguments, cb)
  })
}

// read_file(path: string) -> Future
// A Future of the file's contents.
func fs.read_file(path){
  local b = bundled(path)
  if(b != null and b.stat != null and b.stat.is_file){
    return async.value(bundle.read(path))
  }
  return fs_call("fs_read_file", disk_path(b, path))
}
// write_file(path: string, data: string) -> Future
// Writes data to the file, replacing what it held.
func fs.write_file(path, data){
  return fs_call("fs_write_file", path, data, false)
}
// append_file(path: string, data: string) -> Future
// Adds data at the end of the file.
func fs.append_file(path, data){
  return fs_call("fs_write_file", path, data, true)
}
// stat(path: string) -> Future
// A Future of the file's or directory's [Stat].
func fs.stat(path){
  local b = bundled(path)
  if(b != null and b.stat != null){
    return async.value(uv_stat(b.stat))
  }
  return fs_call("fs_stat", disk_path(b, path))
}

// list_dir(path: string) -> Future
// A Future of the directory's entries, a list of [DirEntry]. A bundled
// directory lists the bundle's entries and the disk's.
func fs.list_dir(path){
  local b = bundled(path)
  if(b == null or b.stat == null or not b.stat.is_dir){
    return fs_call("fs_scandir", path)
  }
  // the bundle's entries, and the disk's when the directory is there too
  return async.run(func(){
    local out = {}
    local seen = {}
    for(let local name in values(bundle.list(path))){
      seen[name] = true
      local dir = bundle.is_dir(concat(path, "/", name))
      append(out, {name: name, type: dir and "dir" or "file"})
    }
    local disk = pcall(async.await, fs_call("fs_scandir", path))
    if(disk[0] == "ok"){
      for(let local e in values(disk[1])){
        if(not seen[e.name]){
          append(out, e)
        }
      }
    }
    return out
  })
}
// remove(path: string) -> Future
// Deletes a file.
func fs.remove(path){ return fs_call("fs_unlink", path) }
// mkdir(path: string) -> Future
// Makes a directory (its parent must exist).
func fs.mkdir(path){ return fs_call("fs_mkdir", path) }
// rmdir(path: string) -> Future
// Removes an empty directory.
func fs.rmdir(path){ return fs_call("fs_rmdir", path) }
// rename(from: string, to: string) -> Future
// Renames or moves a file or directory.
func fs.rename(from, to){ return fs_call("fs_rename", from, to) }
// open(path: string, flags?: string) -> Future
// A Future of a file descriptor for [fs.read], [fs.write] and [fs.close].
// [flags]: as for fopen: "r" (the default), "w", "a", "r+", ...
func fs.open(path, flags){ return fs_call("fs_open", path, flags or "r") }
// close(fd: int) -> Future
// Closes a file descriptor from [fs.open].
func fs.close(fd){ return fs_call("fs_close", fd) }

// read(fd: int, length: int, offset?: int) -> Future
// A Future of up to length bytes; "" at the end of the file.
// [offset]: where to read; null reads on from the current position
func fs.read(fd, length, offset){
  return async.wrap(func(cb){
    loop_module().fs_read(fd, length, offset or -1, cb)
  })
}

// write(fd: int, data: string, offset?: int) -> Future
// A Future of the number of bytes written.
// [offset]: where to write; null writes on from the current position
func fs.write(fd, data, offset){
  return async.wrap(func(cb){
    loop_module().fs_write(fd, data, offset or -1, cb)
  })
}

// a Stream of data from offset (length bytes, or to the end) in chunks
local func memory_stream(data, size, offset, length){
  local stop = len(data)
  if(length != null and offset + length < stop){
    stop = offset + length
  }
  return async.pull(func(){
    if(offset >= stop){
      return null
    }
    local to = offset + size
    if(to > stop){
      to = stop
    }
    local chunk = str.substring(data, offset, to)
    offset = to
    return chunk
  })
}

// read_stream(path: string, options?: {chunk_size?: int, start?: int,
//   length?: int} | int) -> Stream
// A Stream of the file's contents in chunks, read as they are asked for
// (see [pull]). The file is closed at the end or on an error. options may
// be just the chunk size.
// [options]: chunk_size (64 KiB), start (0), length (bytes; to the end)
func fs.read_stream(path, options){
  if(type(options) == "int"){
    options = {chunk_size: options}
  }
  options = options or {}
  local size = options.chunk_size or 65536
  local offset = options.start or 0
  local left = options.length
  local b = bundled(path)
  if(b != null and b.stat != null and b.stat.is_file){
    return memory_stream(bundle.read(path), size, offset, left)
  }
  path = disk_path(b, path)
  local fd = null
  local finished = false
  return async.pull(func(){
    if(finished){
      return null
    }
    return async.run(func(){
      local r = pcall(func(){
        if(left != null and left <= 0){
          return ""
        }
        if(fd == null){
          fd = async.await(fs.open(path, "r"))
        }
        local want = size
        if(left != null and left < want){
          want = left
        }
        local data = async.await(fs.read(fd, want, offset))
        offset = offset + len(data)
        if(left != null){
          left = left - len(data)
        }
        return data
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

// exists(path: string) -> Future
// A Future of whether the path names a file or directory.
func fs.exists(path){
  local b = bundled(path)
  if(b != null and b.stat != null){
    return async.value(true)
  }
  path = disk_path(b, path)
  return async.wrap(func(cb){
    loop_module().fs_stat(path, func(err, st){ cb(null, err == null) })
  })
}

// ------------------------------------------------------------ signals

// on_signal(name: string, f: func(name: string)) -> the uv.signal handle
// Runs f(name) each time the process gets the signal ("SIGINT", "SIGTERM",
// ...). The handle does not keep the loop running; stop() or close() it
// when done.
func async.on_signal(name, f){
  local h = loop_module().signal()
  h:start(name, func(err, got){ f(got) })
  h:unref()
  return h
}

// ------------------------------------------------------------ processes

// A started program.
// type Process = {process: any, pid: int, stdin?: any, stdout?: any,
//   stderr?: any, pipes: {[int]: any}, exit: Future, kill: func(sig?: string | int)}
// [process]: the uv.process handle
// [stdin]: the uv.pipe for fd 0 when stdio has "pipe" there
// [stdout]: the uv.pipe for fd 1, likewise
// [stderr]: the uv.pipe for fd 2, likewise
// [pipes]: every pipe stdio asked for, by fd
// [exit]: {status, signal} when it ends (signal when a signal ended it)
// [kill]: sends a signal, a number or a name ("SIGTERM" by default)

// spawn(file: string, args?: {string}, options?: table) -> Process
// Starts a program. Raises when it cannot be started. options are as for
// uv.spawn (cwd, env, detached, stdio), except that a stdio entry "pipe"
// makes a pipe. Without stdio the child inherits fds 0, 1 and 2.
//
//   local p = async.spawn("sleep", {"1"})
//   local r = async.await(p.exit)   // {status: 0}
// [args]: the arguments, without the program itself
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
  return {
    process: process, pid: process:pid(), pipes: pipes, stdin: pipes[0],
    stdout: pipes[1], stderr: pipes[2], exit: exit.future,
    kill: func(sig){ process:kill(sig) }
  }
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

// exec(file: string, args?: {string}, options?: table) -> Future
// Runs a program to the end and collects its output: a Future of {status,
// signal, stdout, stderr}. It fails when the program cannot be started.
//
//   local r = async.await(async.exec("git", {"status", "--short"}))
//   print(r.status, r.stdout)
// [options]: input (written to stdin, else empty); cwd and env: [spawn]
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
    return {
      status: all[0].status,
      signal: all[0].signal,
      stdout: all[1],
      stderr: all[2],
    }
  })
}

return async
