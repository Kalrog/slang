// Actions mapped to keys. Without the host (in tests) nothing is pressed.
local eb = null
if(let {"ok", local host} = pcall(require, "ebiten")){
  eb = host
}

local m = {}

local bindings = {
  left: {"ArrowLeft", "A"},
  right: {"ArrowRight", "D"},
  up: {"ArrowUp", "W"},
  down: {"ArrowDown", "S"},
  confirm: {"Enter", "Space", "E"},
  cancel: {"Escape"},
  restart: {"R"},
  reload: {"F5"},
}

func m.bind(action, keys){
  bindings[action] = keys
}

local func any(action, test){
  if(eb == null){
    return false
  }
  local keys = bindings[action]
  if(keys == null){
    error("unknown input action ", action)
  }
  for(let local k in values(keys)){
    if(test(k)){
      return true
    }
  }
  return false
}

// down(action) -> whether any key of the action is held
func m.down(action){
  return any(action, func(k){ return eb.key_down(k) })
}

// pressed(action) -> whether any key of the action went down this frame
func m.pressed(action){
  return any(action, func(k){ return eb.key_pressed(k) })
}

return m
