// Slang Dungeon: a small dungeon crawler whose content is written in slang
// DSLs (see dsl/), running on the Ebitengine host in host/. The game flow
// itself is a state machine, the same DSL the monsters use.
extension "dsl/machine"
local eb = require("ebiten")
eb.window("Slang Dungeon", 320, 192, 3)

local input = require("engine/input")
local world = require("engine/world")
local events = require("engine/events")
local scheduler = require("engine/scheduler")
local dlg = require("engine/dialogue")
local machines_api = require("engine/machines")
local hud = require("game/hud")
local os = require("slang/os")

flags = {}
require("game/sprites")
require("game/tiles")
require("game/entities")
require("game/brains")
require("game/dialogues")
require("game/loot")
require("game/rules")
require("game/levels")

// scripts waiting for an event name are woken when it is emitted
events.on_emit = func(e){ scheduler.signal(e.kind) }

local func load_level(game, index){
  game.level_index = index
  world.load(levels.order[index])
  local p = world.state.player
  if(game.stats != null){
    p.hp = game.stats.hp
    p.damage = game.stats.damage
    p.coins = game.stats.coins
  }
  scheduler.clear()
  flags.exit_requested = false
}

// DUNGEON_LEVEL=name starts at that level (handy while editing levels)
local func first_level(){
  local wanted = os.getenv("DUNGEON_LEVEL")
  if(wanted != null){
    for(local i = 0; i < len(levels.order); i = i + 1){
      if(levels.order[i] == wanted){
        return i
      }
    }
    error("DUNGEON_LEVEL: unknown level ", wanted)
  }
  return 0
}

local func handle_dialogue(){
  if(input.pressed("up")){ dlg.move(- 1) }
  if(input.pressed("down")){ dlg.move(1) }
  if(input.pressed("confirm")){ dlg.confirm() }
}

local func handle_movement(p, dt){
  p.move_cooldown = (p.move_cooldown or 0) - dt
  local dirs = {
    {"left", - 1, 0}, {"right", 1, 0}, {"up", 0, - 1}, {"down", 0, 1},
  }
  for(let local d in values(dirs)){
    if(input.pressed(d[0])){
      world.move(p, d[1], d[2])
      p.move_cooldown = 0.2
      return null
    }
  }
  if(p.move_cooldown <= 0){
    for(let local d in values(dirs)){
      if(input.down(d[0])){
        world.move(p, d[1], d[2])
        p.move_cooldown = 0.12
        return null
      }
    }
  }
}

machine game_flow {
  state title {
    update(dt) {
      if(input.pressed("confirm")){ goto start }
    }
  }
  state start {
    enter {
      flags = {}
      self.stats = null
      load_level(self, first_level())
      goto playing
    }
  }
  state playing {
    update(dt) {
      if(dlg.active()){
        handle_dialogue()
        return null
      }
      local p = world.state.player
      handle_movement(p, dt)
      world.update(dt)
      scheduler.update(dt)
      hud.update(dt)
      if(p.hp <= 0){ goto dead }
      if(flags.exit_requested){
        self.stats = {hp: p.hp, damage: p.damage, coins: p.coins}
        if(self.level_index + 1 >= len(levels.order)){ goto won }
        load_level(self, self.level_index + 1)
      }
    }
  }
  state dead {
    update(dt) {
      hud.update(dt)
      if(input.pressed("restart")){ goto start }
    }
  }
  state won {
    update(dt) {
      if(input.pressed("restart")){ goto start }
    }
  }
}

game = {}

func update(dt){
  if(input.pressed("reload")){
    eb.reload()
  }
  machines_api.run(machines.game_flow, game, dt)
}

func draw(){
  if(game.state == "title" or game.state == null){
    hud.draw_title()
    return null
  }
  world.draw()
  hud.draw()
  if(game.state == "dead"){
    hud.draw_end("YOU DIED", "The mines keep their secrets.")
  } else if(game.state == "won"){
    hud.draw_end(
      "YOU WON",
      concat("You escaped with ", game.stats.coins, " gold.")
    )
  }
}
