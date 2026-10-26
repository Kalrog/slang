// Runtime for dialogues declared with dsl/dialogue. A dialogue runs as a
// coroutine; `say` and `choice` yield requests that the UI shows, and the
// player's input resumes it.
//
//   dialogue.start("elder")
//   dialogue.active()            // true while a text box is open
//   dialogue.current()           // {text} or {options, selected}
//   dialogue.move(delta)         // moves the selection
//   dialogue.confirm()           // continues, or picks the selected option
local thread = require("slang/thread")
local m = {}

dialogues = dialogues or {}

local current = null

func m.define(name, f){
  dialogues[name] = f
  return f
}

local func step(value){
  local request = thread.resume(current.co, value)
  if(thread.state(current.co) == "dead"){
    current = null
    if(m.on_end != null){
      m.on_end()
    }
    return null
  }
  current.text = request.text
  current.options = request.options
  current.selected = 0
}

func m.start(name){
  local f = dialogues[name]
  if(f == null){
    error("unknown dialogue ", name)
  }
  current = {co: thread.create(f)}
  step(null)
}

func m.say(text){
  thread.yield({text: text})
}

func m.choose(options){
  local picked = thread.yield({options: options})
  return picked
}

func m.active(){
  return current != null
}

func m.current(){
  return current
}

func m.move(delta){
  if(current == null or current.options == null){
    return null
  }
  local n = len(current.options)
  current.selected = (current.selected + delta + n) % n
}

func m.confirm(){
  if(current == null){
    return null
  }
  if(current.options != null){
    step(current.selected)
  } else {
    step(null)
  }
}

func m.cancel(){
  current = null
}

return m
