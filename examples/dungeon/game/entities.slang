// Everything that lives in the mines, declared with dsl/entity. Hooks:
// on_bump(self, mover) when something solid is walked into, on_enter(self,
// mover) when something steps onto a non-solid entity.
extension "dsl/entity"
extension "dsl/script"
local world = require("engine/world")
local events = require("engine/events")
local scheduler = require("engine/scheduler")
local dlg = require("engine/dialogue")
local loot_api = require("engine/loot")
local combat = require("game/combat")
local hud = require("game/hud")

entity Thing {solid: false, sprite: "floor", facing: 1}

entity Player extends Thing {sprite: "player", solid: true, speed: 12, hp: 5, max_hp: 5, damage: 1, keys: 0, coins: 0}

entity Monster extends Thing {
  solid: true, hp: 2, damage: 1, speed: 6, on_bump: func(self, who){
    if(type(who) == "Player"){
      combat.attack(who, self)
    }
  },
}
entity Goblin extends Monster {sprite: "goblin", hp: 3, brain: "goblin", loot: "goblin", sight: 5}
entity Bat extends Monster {sprite: "bat", hp: 1, brain: "bat", loot: "bat", speed: 10}

entity Item extends Thing {
  item: "nothing", amount: 1, on_enter: func(self, who){
    if(type(who) == "Player"){
      world.remove(self)
      events.emit({
        kind: "picked_up", item: self.item, amount: self.amount, x: self.x,
        y: self.y,
      })
    }
  },
}
entity Key extends Item {sprite: "key", item: "key"}
entity Potion extends Item {sprite: "potion", item: "potion"}
entity Sword extends Item {sprite: "sword", item: "sword"}
entity Coins extends Item {sprite: "coins", item: "coins"}

entity Door extends Thing {
  sprite: "door", solid: true, on_bump: func(self, who){
    if(type(who) != "Player"){
      return null
    }
    if(who.keys > 0){
      who.keys = who.keys - 1
      world.remove(self)
      events.emit({kind: "door_opened", x: self.x, y: self.y})
    } else {
      hud.message("The door is locked. Find a key.")
    }
  },
}

entity Chest extends Thing {
  sprite: "chest", solid: true, loot: "chest", opened: false,
  on_bump: func(self, who){
    if(type(who) != "Player" or self.opened){
      return null
    }
    self.opened = true
    // a script: the lid opens, then the loot appears
    scheduler.start(func(){
      self.sprite = "chest_open"
      wait 0.4
      events.emit({
        kind: "chest_opened", chest: self, drop: loot_api.roll(self.loot),
      })
    })
  },
}

entity Elder extends Thing {
  sprite: "elder", solid: true, talk: "elder", on_bump: func(self, who){
    if(type(who) == "Player"){
      dlg.start(self.talk)
    }
  },
}
entity Sage extends Elder {talk: "sage"}
