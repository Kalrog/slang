// notebook/client: starts the kernel of a notebook and talks to it.
//
//   local client = require("notebook/client")
//   local k = client.start({path: "notes.md", on_event: func(e){ ... }})
//   local r = async.await(k:execute("1 + 1", {id: "c1"}))   // {status: "ok"}
//   async.await(k:shutdown())
//
// A kernel is a slang process of its own (notebook/kernel) that keeps the
// notebook's state and runs its cells one after another, in the
// notebook's folder and under that folder's project. What it has to say
// arrives as events, in order, through on_event:
//
//   {event: "ready", project?: string, error?: string}   it started
//   {event: "start", id}                 a cell begins to run
//   {event: "stream", id, name, text}    it printed (name: "stdout" or "stderr")
//   {event: "display", id, data}         it showed something (notebook.display)
//   {event: "result", id, data}          its value; data: forms by MIME type
//   {event: "update", id, output, data}  an output it showed gets new data
//   {event: "clear", id}                 what it showed so far is taken back
//   {event: "error", id, error}          it failed: {kind, message, location, stack}
//   {event: "done", id, status, ms}      it ended: "ok", "error", "interrupted"
//   {event: "calling", id}               a control the cell made is called
//   {event: "called", id, call, control, status, result?, error?}
//                                        and that call ended
//   {event: "exit", status, signal}      the kernel itself ended
//
// Needs slang/async: start a kernel inside async.main or async.run.
local async = require("slang/async")
local json = require("slang/json")
local os = require("slang/os")
local str = require("slang/string")
local hash = require("slang/hash")
local time = require("slang/time")
local math = require("slang/math")
local encoding = require("slang/encoding")
local compiler = require("slang/compiler")
local protocol = require("notebook/protocol")

local client = {}

// A running kernel, from [start].
// type Kernel = {status: string, ready: async.Future, exit: async.Future,
//   project?: string, pid: int}
// [status]: "starting", "idle", "busy" or "dead"
// [ready]: completes with the ready event; fails when the kernel dies
//   before it is ready
// [exit]: completes with {status, signal} when the process ends
// [project]: the project file the cells run under, once ready
local kernel_methods = {}
local kernel_meta = {__index: kernel_methods, __type: "notebook.Kernel"}

// How [start] starts a kernel.
// type StartOptions = {path: string, on_event?: func(event: table),
//   slang?: string}
// [path]: the notebook's file, or a folder: the kernel runs in the folder
//   and under the project found from it
// [on_event]: called with each event, see the module doc
// [slang]: the slang to run the kernel with; this one by default

local counter = 0

local func new_token(){
  counter = counter + 1
  return str.substring(encoding.hex.encode(hash.sha256(concat(
    string(time.now()), ":", string(math.random()), ":", string(counter)
  ))), 0, 24)
}

// start(options: StartOptions) -> Kernel
// Starts a kernel. Raises when the process cannot be started.
func client.start(options){
  local path = compiler.absolute_path(options.path)
  local dir = path
  if(not os.is_dir(path)){
    dir = compiler.dirname(path)
  }
  // the kernel's main file, next to this module
  local here = compiler.dirname(compiler.module_path("notebook/client"))
  local main = concat(here, "/bin/kernel.slang")
  local token = new_token()
  local k = {
    status: "starting", project: null, path: path, pending: {}, running: 0,
    current: null, on_event: options.on_event or func(event){}, next_id: 0,
    stopping: false
  }
  k.@meta = kernel_meta
  local ready = async.completer()
  k.ready = ready.future
  // nobody has to await it
  k.ready:catch(func(e){ return null })
  local func deliver(event){
    k.on_event(event)
  }
  local parser = protocol.parser(token, func(text){
    deliver({event: "stream", id: k.current, name: "stdout", text: text})
  }, func(event){
    if(event.event == "ready"){
      k.project = event.project
      if(k.status == "starting"){
        k.status = "idle"
        if(k.running > 0){
          k.status = "busy"
        }
      }
      deliver(event)
      ready.complete(event)
    } else if(event.event == "start"){
      k.current = event.id
      k.status = "busy"
      deliver(event)
    } else if(event.event == "calling"){
      // what a control's function prints is its cell's
      if(event.id != null){
        k.current = event.id
      }
      deliver(event)
    } else if(event.event == "done"){
      k.running = k.running - 1
      if(k.running <= 0){
        k.running = 0
        k.status = "idle"
      }
      deliver(event)
      local waiter = k.pending[event.id]
      if(waiter != null){
        delete(k.pending, event.id)
        waiter.complete({status: event.status, ms: event.ms})
      }
    } else if(event.event == "variables"){
      local waiter = k.pending[event.id]
      if(waiter != null){
        delete(k.pending, event.id)
        waiter.complete(event.variables)
      }
    } else {
      deliver(event)
    }
  })
  local p = async.spawn(
    options.slang or os.executable(), {"run", main, path, token},
    {cwd: dir, stdio: {"pipe", "pipe", "pipe"}},
  )
  k.process = p
  k.pid = p.pid
  // the output read to its end
  local drained = async.completer()
  p.stdout:read_start(func(err, chunk){
    if(err != null or chunk == null){
      parser.finish()
      p.stdout:close()
      drained.complete(null)
    } else {
      parser.feed(chunk)
    }
  })
  local startup = {}
  p.stderr:read_start(func(err, chunk){
    if(err != null or chunk == null){
      p.stderr:close()
    } else {
      if(k.status == "starting"){
        append(startup, chunk)
      }
      deliver({event: "stream", id: k.current, name: "stderr", text: chunk})
    }
  })
  // (something the cells started may hold the output open: not for long)
  k.exit = p.exit:then(func(r){
    return async.timeout(drained.future, 500):then(
      func(v){ return r }, func(e){ return r },
    )
  }):then(func(r){
    k.status = "dead"
    try { p.stdin:close() } catch {}
    deliver({event: "exit", status: r.status, signal: r.signal})
    if(not ready.future:is_done()){
      ready.fail(error.new(error.kinds.io, concat(
        "the kernel did not start: ", str.trim(str.join(startup, ""))
      )))
    }
    // what was still running ended with the kernel
    local waiting = k.pending
    k.pending = {}
    for(let local e in entries(waiting)){
      e[1].complete({status: "dead"})
    }
    return r
  })
  return k
}

local func send(k, msg){
  if(k.status == "dead"){
    raise(error.new(error.kinds.closed, "the kernel has ended"))
  }
  k.process.stdin:write(concat(json.encode(msg), "\n"))
}

// How [Kernel.execute] runs a cell.
// type ExecuteOptions = {id?: string, origin?: string, line?: int}
// [id]: what the cell's events carry; one is made up by default
// [origin]: the name in the locations of errors: the notebook's file
// [line]: the lines before the cell's code in that file

// execute(code: string, options?: ExecuteOptions) -> async.Future
// Runs code as the notebook's next cell, after those asked for before it.
// The future completes when the cell ended, with {status, ms}: status is
// "ok", "error", "interrupted", or "dead" when the kernel ended first. It
// does not fail for a cell that fails: the error is an event.
func kernel_methods.execute(k, code, options){
  options = options or {}
  if(k.status == "dead"){
    return async.value({status: "dead"})
  }
  local id = options.id
  if(id == null){
    k.next_id = k.next_id + 1
    id = concat("x", string(k.next_id))
  }
  local waiter = async.completer()
  k.pending[id] = waiter
  k.running = k.running + 1
  if(k.status == "idle"){
    k.status = "busy"
  }
  send(k, {
    op: "execute", id: id, code: code, origin: options.origin,
    line: options.line
  })
  return waiter.future
}

// How [Kernel.call] calls a control or a handler of the page's.
// type CallOptions = {call: string, control: string, value?: any}
// [call]: what the called event of the answer carries
// [control]: the name of the control or the handler (notebook's on)
// [value]: what the control was set to, or what the handler gets

// call(options: CallOptions)
// Calls what a cell made for the page, after the cells asked for before
// it. What happens arrives as events: calling, what it shows, called.
func kernel_methods.call(k, options){
  send(k, {
    op: "call", call: options.call, control: options.control,
    value: options.value
  })
}

// variables() -> async.Future
// The session's locals when the cells asked for before have run: a list
// of {name, type, text}.
func kernel_methods.variables(k){
  k.next_id = k.next_id + 1
  local id = concat("v", string(k.next_id))
  local waiter = async.completer()
  k.pending[id] = waiter
  send(k, {op: "variables", id: id})
  return waiter.future
}

// interrupt()
// Stops the running cell: it ends with status "interrupted" at its next
// call or loop. A cell stuck inside C code does not notice; [kill] ends
// the kernel then.
func kernel_methods.interrupt(k){
  if(k.status != "dead"){
    k.process.kill("SIGINT")
  }
}

// kill()
// Ends the kernel at once. Its state is lost.
func kernel_methods.kill(k){
  if(k.status != "dead"){
    k.process.kill("SIGKILL")
  }
}

// shutdown(ms?: int) -> async.Future
// Tells the kernel to end after the cells asked for so far, and ends it
// by force when it has not within ms milliseconds (2000). Completes when
// the process is gone.
func kernel_methods.shutdown(k, ms){
  if(k.status == "dead"){
    return k.exit
  }
  if(not k.stopping){
    k.stopping = true
    try {
      send(k, {op: "shutdown"})
    } catch {}
  }
  local timer = require("uv").timer()
  timer:start(ms or 2000, 0, func(){
    timer:close()
    kernel_methods.kill(k)
  })
  return k.exit:then(func(r){
    if(not timer:is_closing()){
      timer:close()
    }
    return r
  })
}

return client
