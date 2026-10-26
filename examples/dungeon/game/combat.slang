// Bump combat: walking into something strikes it.
local world = require("engine/world")
local events = require("engine/events")

local m = {}

func m.attack(attacker, target){
  local damage = attacker.damage or 1
  target.hp = target.hp - damage
  target.flash = 0.3
  events.emit({kind: "attacked", attacker: attacker, target: target, damage: damage})
  if(target.hp <= 0){
    world.remove(target)
    events.emit({kind: "died", entity: target, x: target.x, y: target.y})
  }
}

return m
