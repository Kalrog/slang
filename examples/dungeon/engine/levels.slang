// The level registry: levels.NAME = {name, w, h, tiles, spawns}, in the order
// they were declared (levels.order).
local m = {}

levels = levels or {order: {}}

func m.define(name, data){
  if(levels[name] == null){
    append(levels.order, name)
  }
  levels[name] = data
  return data
}

return m
