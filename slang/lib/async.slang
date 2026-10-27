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

// connect(host, port) -> Future of a connected uv.tcp handle
func async.connect(host, port){
  local conn = loop_module().tcp()
  return async.wrap(func(cb){
    conn:connect(host, port, func(err){ cb(err, conn) })
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

return async
