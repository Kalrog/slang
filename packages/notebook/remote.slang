// notebook/remote: a kernel that runs somewhere else, in a browser's page
// (notebook/kernel_web in a worker), as a notebook's session sees it
// (notebook/session's Kernel).
//
//   local k = remote.new(func(op){ socket:send(json.encode(op)) }, on_event)
//   k.start({files: ..., target: "/work/notes.md"})
//   k.execute("1 + 1", {id: "c1"})
//   k.receive(event)      // what the page passes on from the worker
//
// What the session asks of the kernel goes out through send as an
// operation for the page: {op: "start", ...}, {op: "execute", id, code,
// origin, line}, {op: "variables", id}, {op: "interrupt"}, {op: "kill"}.
// The page passes the worker's events back to [Remote.receive]: the
// kernel's own (ready, start, display, result, clear, error, done,
// variables), {event: "stream", name, text} for what the cells print, and
// {event: "exit", status, reason?} when the worker is gone (reason: why,
// when the page ended it). on_event gets them as
// notebook/client gives a process's.
local remote = {}

// A kernel in a page, from [new].
// type Remote = {status: func(): string, start: func(options: table),
//   execute: func(code: string, options?: table),
//   variables: func(reply: func(list: table)), interrupt: func(),
//   kill: func(), receive: func(event: table), lost: func()}
// [status]: "starting", "idle", "busy" or "dead"
// [start]: tells the page to start the worker; options are the page's
//   (the files the kernel sees, the notebook among them)
// [receive]: takes an event the page passed on
// [lost]: the page is gone, and the kernel with it

// new(send: func(op: table), on_event: func(event: table)) -> Remote
func remote.new(send, on_event){
  local k = {kind: "wasm"}
  local status = "starting"
  local current = null
  local running = 0
  local replies = {}
  local next_id = 0

  local func ended(event){
    if(status == "dead"){
      return
    }
    status = "dead"
    local waiting = replies
    replies = {}
    for(let local e in entries(waiting)){
      e[1]({})
    }
    on_event(event)
  }

  func k.status(){
    return status
  }
  func k.start(options){
    local op = {op: "start"}
    for(let local e in entries(options or {})){
      op[e[0]] = e[1]
    }
    send(op)
  }
  func k.execute(code, options){
    options = options or {}
    if(status == "dead"){
      return
    }
    running = running + 1
    if(status == "idle"){
      status = "busy"
    }
    send({
      op: "execute", id: options.id, code: code, origin: options.origin,
      line: options.line
    })
  }
  func k.variables(reply){
    if(status == "dead"){
      reply({})
      return
    }
    next_id = next_id + 1
    local id = concat("v", string(next_id))
    replies[id] = reply
    send({op: "variables", id: id})
  }
  func k.interrupt(){
    if(status != "dead"){
      send({op: "interrupt"})
    }
  }
  func k.kill(){
    if(status != "dead"){
      send({op: "kill"})
      ended({event: "exit", status: 0})
    }
  }
  func k.lost(){
    ended({event: "exit", status: 1})
  }
  func k.receive(event){
    if(status == "dead" or raw_type(event) != "table"){
      return
    }
    local kind = event.event
    if(kind == "ready"){
      status = "idle"
      if(running > 0){
        status = "busy"
      }
      on_event(event)
    } else if(kind == "start"){
      current = event.id
      status = "busy"
      on_event(event)
    } else if(kind == "done"){
      running = running - 1
      if(running <= 0){
        running = 0
        status = "idle"
      }
      on_event(event)
    } else if(kind == "variables"){
      local reply = replies[event.id]
      if(reply != null){
        delete(replies, event.id)
        reply(event.variables or {})
      }
    } else if(kind == "stream"){
      on_event({
        event: "stream", id: current, name: event.name,
        text: string(event.text or "")
      })
    } else if(kind == "exit"){
      ended({event: "exit", status: event.status, reason: event.reason})
    } else {
      on_event(event)
    }
  }
  return k
}

return remote
