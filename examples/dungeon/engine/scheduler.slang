// Tasks are coroutines that run across frames. `wait SECONDS` and
// `wait for EVENT` (dsl/script) suspend the running task; update(dt) resumes
// the ones whose time has come and signal(name) the ones waiting for an event.
local thread = require("slang/thread")
local m = {}

local tasks = {}

local func resume(task, value){
  local request = thread.resume(task.co, value)
  if(thread.state(task.co) == "dead"){
    task.done = true
    return null
  }
  task.wait_time = null
  task.wait_event = null
  if(type(request) == "table"){
    if(request.kind == "wait"){
      task.wait_time = request.seconds
    } else if(request.kind == "event"){
      task.wait_event = request.name
    }
  }
}

// start(f, ...args) -> task: runs f as a task until its first wait (up to
// four arguments are passed on)
func m.start(f, ...args){
  local task = {co: thread.create(func(){ return f(args[0], args[1], args[2], args[3]) }), done: false}
  append(tasks, task)
  resume(task, null)
  return task
}

func m.wait(seconds){
  thread.yield({kind: "wait", seconds: seconds})
}

func m.wait_for(name){
  thread.yield({kind: "event", name: name})
}

func m.update(dt){
  local alive = {}
  for(let local task in values(tasks)){
    if(not task.done and task.wait_time != null){
      task.wait_time = task.wait_time - dt
      if(task.wait_time <= 0){
        resume(task, null)
      }
    }
    if(not task.done){
      append(alive, task)
    }
  }
  tasks = alive
}

// signal(name): wakes every task waiting for the event name
func m.signal(name){
  for(let local task in values(tasks)){
    if(not task.done and task.wait_event == name){
      resume(task, null)
    }
  }
}

func m.count(){
  local n = 0
  for(let local task in values(tasks)){
    if(not task.done){
      n = n + 1
    }
  }
  return n
}

func m.clear(){
  tasks = {}
}

return m
