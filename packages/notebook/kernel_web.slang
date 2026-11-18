// notebook/kernel_web: a notebook's kernel in a browser: slang.wasm in a
// worker of the notebook's page (web/worker.js starts it, bin/
// kernel_web.slang is its main file), instead of a process of its own.
//
// It runs the cells as notebook/kernel does (notebook/runner), and talks
// through slang/web's messages instead of standard input and output: a
// command is a message from the page ({op: "execute", id, code, origin?,
// line?}, {op: "variables", id}, {op: "shutdown"}, as JSON), an event one
// to it. What the cells print is the worker's output; the page gets both
// in the order they were made.
//
// Between commands the kernel hands the page control (web.frame()), and
// the page resumes it when the next command is there. A browser has no
// event loop a program could wait on, so a cell cannot await; and the
// files it sees are the ones the page gave the worker. An interrupt is
// the page's to raise (slang/vm's catch_interrupt asks it); a page that
// cannot (it is not cross-origin isolated) ends the worker instead.
local json = require("slang/json")
local time = require("slang/time")
local runner = require("notebook/runner")

local kernel = {}

// main(arguments: {string})
// Runs a kernel until it is told to shut down: arguments[0] is the
// notebook's file (or its folder) among the worker's files, whose project
// the cells run in.
func kernel.main(arguments){
  local web = require("slang/web")
  local func send(event){
    web.send(json.encode(event))
  }
  local cells = runner.new(arguments[0] or ".", send)
  cells.ready.interrupts = cells.can_interrupt
  send(cells.ready)
  for(true){
    local text = web.receive()
    if(text == null){
      web.frame()
    } else {
      local msg = try { json.decode(text) } catch { null }
      if(type(msg) == "table"){
        if(msg.op == "execute"){
          send({event: "start", id: msg.id})
          local started = time.clock()
          local status = cells.run(msg)
          send({
            event: "done", id: msg.id, status: status,
            ms: time.clock() - started
          })
        } else if(msg.op == "variables"){
          cells.variables(msg)
        } else if(msg.op == "shutdown"){
          break
        }
      }
    }
  }
}

return kernel
