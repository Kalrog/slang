// notebook/kernel: the process that runs a notebook's cells. Started by
// notebook/client (bin/kernel.slang is its main file); see
// notebook/protocol for how the two talk.
//
// A kernel is one session (compiler.session): the cells run one after
// another as pieces of one program, a cell's top-level locals stay for
// the cells after it, and a cell's value is what its last expression
// gives. The cells run in the project of the notebook's folder: the
// kernel enters it (compiler.enter_project) once its own modules are
// loaded, so `require` finds the project's packages and files, and its
// extensions are in effect.
//
// Cells run inside an async function (slang/async), so a cell may await.
// What a cell left running (a timer, a server) keeps running between
// cells, and what it prints then is shown under the cell run last.
//
// An interrupt (SIGINT, what the client's interrupt sends) stops the
// running cell with an error of kind interrupted at its next call or
// loop. A cell that is waiting (in an await) is left behind instead: the
// kernel goes on, and what the cell waited for may still happen.
local async = require("slang/async")
local json = require("slang/json")
local os = require("slang/os")
local str = require("slang/string")
local time = require("slang/time")
local tbl = require("slang/table")
local compiler = require("slang/compiler")
local vm = require("slang/vm")
local nb = require("notebook")
local inspect = require("notebook/inspect")
local protocol = require("notebook/protocol")

local kernel = {}

// an error as the events carry it; the trace ends where the kernel's own
// frames begin
local func describe(e){
  if(raw_type(e) != "table"){
    return {kind: "error", message: string(e)}
  }
  local out = {kind: "error", message: error.message(e)}
  if(type(e.kind) == "string"){
    out.kind = e.kind
  }
  if(raw_type(e.location) == "table"){
    out.location = {
      origin: e.location.origin, line: e.location.line,
      column: e.location.column
    }
  }
  if(type(e.stack) == "string" and e.stack != ""){
    local lines = {}
    for(let local line in values(str.split(e.stack, "\n"))){
      if(str.contains(line, "(notebook/kernel:")){
        break
      }
      append(lines, line)
    }
    out.stack = str.join(lines, "\n")
  }
  return out
}

// main(arguments: {string})
// Runs a kernel until its standard input ends or it is told to shut down:
// arguments are the notebook's file (or its folder), whose project the
// cells run in, and the token of the events.
func kernel.main(arguments){
  local target = arguments[0] or "."
  local token = arguments[1] or ""
  local uv = require("uv")
  local current = null
  local func send(event){
    print(protocol.frame(token, event))
  }
  nb.attach(func(kind, data){
    send({event: kind, id: current, data: data})
  })
  // from here on, the notebook's project
  local project = null
  local failure = null
  try {
    project = compiler.enter_project(target)
  } catch(local e) {
    failure = error.message(e)
  }
  local session = compiler.session()
  local ready = {event: "ready", pid: uv.getpid()}
  if(project != null){
    ready.project = project.path
  }
  if(failure != null){
    ready.error = failure
  }
  send(ready)

  // ctrl-c (SIGINT) stops the running cell, not the kernel, where the VM
  // can catch it; between cells it is only noted, and forgotten
  local can_interrupt = vm.catch_interrupt != null
  if(can_interrupt){
    try {
      vm.catch_interrupt(null)
    } catch {
      can_interrupt = false
    }
  }
  // the cell being run: {abandoned, abandon: a Completer}
  local running = null

  // runs in a coroutine of its own: an interrupt raises in it
  local func run_cell(msg, state){
    local status = "ok"
    if(can_interrupt){
      vm.interrupted(true)
      vm.catch_interrupt(true)
    }
    try {
      local f = session:compile(msg.code, msg.origin or "cell", msg.line)
      local value = f()
      if(can_interrupt){
        vm.catch_interrupt(null)
      }
      if(value != null and not state.abandoned){
        send({event: "result", id: msg.id, data: nb.bundle(value)})
      }
    } catch(local e) {
      if(can_interrupt){
        vm.catch_interrupt(null)
      }
      status = "error"
      local d = describe(e)
      if(d.kind == "interrupted"){
        status = "interrupted"
      }
      if(not state.abandoned){
        send({event: "error", id: msg.id, error: d})
      }
    }
    return status
  }

  local func execute(msg){
    current = msg.id
    send({event: "start", id: msg.id})
    local started = time.clock()
    local state = {abandoned: false, abandon: async.completer()}
    running = state
    local status = async.await(async.race({
      async.run(func(){ return run_cell(msg, state) }), state.abandon.future
    }))
    running = null
    if(status == "abandoned"){
      // interrupted while it waited for something: the kernel goes on
      // without it
      status = "interrupted"
      send({event: "error", id: msg.id, error: {
        kind: "interrupted",
        message: "interrupted while it waited; what it started may still be running"
      }})
    }
    send({
      event: "done", id: msg.id, status: status, ms: time.clock() - started
    })
  }

  // between two rounds of the event loop no cell's code is running: an
  // interrupt that nobody took by then found the cell waiting
  async.set_driver(func(){
    local more = uv.run("once")
    if(can_interrupt and vm.interrupted(true) and running != null and
      not running.abandoned){
      running.abandoned = true
      running.abandon.complete("abandoned")
    }
    return more
  })

  // the session's locals: {name, type, text}
  local func variables(msg){
    local out = json.array({})
    for(let local name in values(session:names())){
      local v = get_raw(session.env, name)
      append(out, {
        name: name, type: type(v),
        text: inspect.text(v, {width: 60, depth: 1, items: 8, string: 60})
      })
    }
    send({event: "variables", id: msg.id, variables: out})
  }

  async.main(func(){
    local queue = {}
    local waiting = null
    local closed = false
    local pending = ""
    local stdin = uv.pipe()
    stdin:open(0)
    stdin:read_start(func(err, chunk){
      if(err != null or chunk == null){
        closed = true
      } else {
        pending = concat(pending, chunk)
        for(true){
          local nl = str.index_of(pending, "\n")
          if(nl < 0){
            break
          }
          local line = str.substring(pending, 0, nl)
          pending = str.substring(pending, nl + 1)
          if(str.trim(line) != ""){
            append(queue, line)
          }
        }
      }
      if(waiting != null and (closed or len(queue) > 0)){
        local w = waiting
        waiting = null
        w.complete(null)
      }
    })
    for(true){
      for(len(queue) == 0 and not closed){
        waiting = async.completer()
        async.await(waiting.future)
      }
      if(len(queue) == 0){
        break
      }
      local msg = try { json.decode(remove(queue, 0)) } catch { null }
      if(type(msg) == "table"){
        if(msg.op == "execute"){
          execute(msg)
        } else if(msg.op == "variables"){
          variables(msg)
        } else if(msg.op == "shutdown"){
          break
        }
      }
    }
  })
  os.exit(0)
}

return kernel
