// notebook/kernel: the process that runs a notebook's cells. Started by
// notebook/client (bin/kernel.slang is its main file); see
// notebook/protocol for how the two talk.
//
// The cells are run by notebook/runner: one session, in the project of
// the notebook's folder.
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
local vm = require("slang/vm")
local protocol = require("notebook/protocol")
local runner = require("notebook/runner")

local kernel = {}

// main(arguments: {string})
// Runs a kernel until its standard input ends or it is told to shut down:
// arguments are the notebook's file (or its folder), whose project the
// cells run in, and the token of the events.
func kernel.main(arguments){
  local target = arguments[0] or "."
  local token = arguments[1] or ""
  local uv = require("uv")
  local func send(event){
    print(protocol.frame(token, event))
  }
  local cells = runner.new(target, send)
  local ready = cells.ready
  ready.pid = uv.getpid()
  send(ready)
  local can_interrupt = cells.can_interrupt
  // the cell being run: {abandoned, abandon: a Completer}
  local running = null

  local func execute(msg){
    send({event: "start", id: msg.id})
    local started = time.clock()
    local state = {abandoned: false, abandon: async.completer()}
    running = state
    local status = async.await(async.race({
      // (a coroutine of its own: an interrupt raises in it)
      async.run(func(){ return cells.run(msg, state) }), state.abandon.future
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
          cells.variables(msg)
        } else if(msg.op == "shutdown"){
          break
        }
      }
    }
  })
  os.exit(0)
}

return kernel
