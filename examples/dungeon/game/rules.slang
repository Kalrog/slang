// The rules of the game as event handlers (dsl/events) and scripts (dsl/script).
extension "dsl/events"
extension "dsl/script"
local world = require("engine/world")
local scheduler = require("engine/scheduler")
local hud = require("game/hud")
local math = require("slang/math")

local item_types = {
  coins: "Coins", potion: "Potion", sword: "Sword", key: "Key",
}

// drop(roll, x, y): places the rolled item on or next to (x, y)
local func drop(roll, x, y){
  local T = entities[item_types[roll.item]]
  if(T == null){
    error("no entity for the item ", roll.item)
  }
  local spot = {x: x, y: y}
  if(world.blocked(x, y) or world.entity_at(x, y) != null){
    spot = world.free_neighbor(x, y)
  }
  if(spot == null){
    return null
  }
  local amount = 1
  if(len(roll.args) == 2){
    amount = to_int(math.random(roll.args[0], roll.args[1] + 1))
  }
  world.add(T(spot.x, spot.y, {amount: amount}))
}

on {kind: "picked_up", item: "key"} {
  local player = world.state.player
  player.keys = player.keys + 1
  hud.message("You found a key!")
  // taking the key wakes the guards
  scheduler.start(func(){
    wait 1
    hud.message("Something stirs in the dark...")
    wait 1.5
    local spot = world.free_neighbor(event.x, event.y)
    if(spot != null){
      world.add(entities.Goblin(spot.x, spot.y))
    }
  })
}

on {kind: "picked_up", item: "potion"} {
  local player = world.state.player
  player.hp = math.min(player.max_hp, player.hp + 2)
  hud.message("You feel better.")
}

on {kind: "picked_up", item: "sword"} {
  world.state.player.damage = 2
  hud.message("A sword! Your strikes hit twice as hard.")
}

on {kind: "picked_up", item: "coins", amount: local n} {
  local player = world.state.player
  player.coins = player.coins + n
  hud.message(concat("+", n, " gold"))
}

on {kind: "died", entity: local e, x: local x, y: local y} {
  if(e.loot != null){
    local roll = require("engine/loot").roll(e.loot)
    if(roll != null){
      drop(roll, x, y)
    }
  }
}

on {kind: "died", entity: 'Player{}} {
  hud.message("You died.")
}

on {kind: "door_opened"} {
  hud.message("The door creaks open.")
}

on {kind: "chest_opened", chest: local chest, drop: local roll} {
  if(roll == null){
    hud.message("The chest is empty.")
  } else {
    drop(roll, chest.x, chest.y)
  }
}

on {kind: "level_started", name: local name} {
  hud.message(concat("~ ", name, " ~"), 3)
}

on {kind: "exit"} {
  flags.exit_requested = true
}
