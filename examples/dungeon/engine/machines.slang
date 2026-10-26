// Runtime for state machines declared with dsl/machine.
//
//   machines.run(machines.goblin_brain, goblin, dt)
//
// The entity keeps its current state name in `state`; hooks receive the
// entity as `self`. An update hook that returns a state name (what `goto`
// compiles to) switches state: the old state's exit hook runs, then the new
// state's enter hook.
local m = {}

machines = machines or {}

func m.define(name, spec){
  spec.name = name
  for(let local state_name in keys(spec.states)){
    spec.states[state_name].name = state_name
  }
  machines[name] = spec
  return spec
}

func __goto(name){
  error("goto ", name, " can only be used inside a machine state")
}

local func call_hook(state, hook, self, dt){
  local f = state[hook]
  if(f == null){
    return null
  }
  return f(self, dt)
}

func m.transition(spec, self, next){
  for(local guard = 0; guard < 16; guard = guard + 1){
    if(spec.states[next] == null){
      error("machine ", spec.name, ": unknown state ", next)
    }
    if(self.state != null){
      call_hook(spec.states[self.state], "exit", self)
    }
    self.state = next
    local again = call_hook(spec.states[next], "enter", self)
    if(type(again) != "string"){
      return null
    }
    next = again
  }
  error("machine ", spec.name, ": enter hooks keep switching states")
}

func m.run(spec, self, dt){
  if(self.state == null){
    m.transition(spec, self, spec.initial)
  }
  local next = call_hook(spec.states[self.state], "update", self, dt)
  if(type(next) == "string" and next != self.state){
    m.transition(spec, self, next)
  }
}

return m
