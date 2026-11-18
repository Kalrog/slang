// notebook/runner: what runs a notebook's cells, inside a kernel. The two
// kernels are built on it: notebook/kernel (a process, over standard
// input and output) and notebook/kernel_web (in a browser's worker, over
// slang/web's messages).
//
// A runner is one session (compiler.session): the cells run one after
// another as pieces of one program, a cell's top-level locals stay for
// the cells after it, and a cell's value is what its last expression
// gives. The cells run in the project of the notebook's folder: the
// runner enters it (compiler.enter_project) when it is made, so make it
// once the kernel's own modules are loaded.
local json = require("slang/json")
local str = require("slang/string")
local compiler = require("slang/compiler")
local vm = require("slang/vm")
local nb = require("notebook")
local inspect = require("notebook/inspect")

local runner = {}

// an error as the events carry it; the trace ends where the runner's own
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
      if(str.contains(line, "(notebook/runner:")){
        break
      }
      append(lines, line)
    }
    out.stack = str.join(lines, "\n")
  }
  return out
}

// What runs the cells, from [new].
// type Runner = {ready: table, can_interrupt: bool,
//   run: func(msg: table, state?: table): string,
//   variables: func(msg: table)}
// [ready]: the kernel's ready event: {event, project?, error?}
// [can_interrupt]: whether a running cell can be stopped (slang/vm's
//   catch_interrupt)
// [run]: runs the cell of an execute command ({id, code, origin?, line?})
//   and sends its result or its error; gives "ok", "error" or
//   "interrupted". A cell whose state.abandoned became true sends neither.
// [variables]: sends the session's locals: {event: "variables", id,
//   variables: {name, type, text}}

// new(target: string, send: func(event: table)) -> Runner
// A runner for the notebook at target (its file, or its folder), whose
// project the cells run in. Events go to send; what the cells show with
// notebook.display goes there too, under the id of the cell being run.
func runner.new(target, send){
  local r = {current: null}
  nb.attach(func(kind, data){
    send({event: kind, id: r.current, data: data})
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
  r.ready = {event: "ready"}
  if(project != null){
    r.ready.project = project.path
  }
  if(failure != null){
    r.ready.error = failure
  }

  // an interrupt stops the running cell, not the kernel, where the VM can
  // catch it; between cells it is only noted, and forgotten
  r.can_interrupt = vm.catch_interrupt != null
  if(r.can_interrupt){
    try {
      vm.catch_interrupt(null)
    } catch {
      r.can_interrupt = false
    }
  }

  // (in the coroutine that calls it: an interrupt raises there)
  func r.run(msg, state){
    state = state or {}
    local status = "ok"
    r.current = msg.id
    if(r.can_interrupt){
      vm.interrupted(true)
      vm.catch_interrupt(true)
    }
    try {
      local f = session:compile(msg.code, msg.origin or "cell", msg.line)
      local value = f()
      if(r.can_interrupt){
        vm.catch_interrupt(null)
      }
      if(value != null and not state.abandoned){
        send({event: "result", id: msg.id, data: nb.bundle(value)})
      }
    } catch(local e) {
      if(r.can_interrupt){
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

  func r.variables(msg){
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
  return r
}

return runner
