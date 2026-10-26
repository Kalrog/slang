// Runtime for loot tables declared with dsl/loot.
local math = require("slang/math")
local m = {}

loot_tables = loot_tables or {}

func m.define(name, entries){
  loot_tables[name] = entries
  return entries
}

// roll(name [, random]) -> {item, args} or null; random is a number in [0, 100)
func m.roll(name, random){
  local table = loot_tables[name]
  if(table == null){
    error("unknown loot table ", name)
  }
  if(random == null){
    random = math.random(0, 100)
  }
  local acc = 0
  for(let local e in values(table)){
    acc = acc + e.chance
    if(random < acc){
      return {item: e.item, args: e.args}
    }
  }
  return null
}

return m
