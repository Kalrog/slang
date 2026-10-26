// Monster behaviour as state machines (dsl/machine). `self` is the monster.
extension "dsl/machine"
local world = require("engine/world")
local combat = require("game/combat")
local math = require("slang/math")

machine goblin {
  state idle {
    enter { self.timer = math.random(0.5, 1.5) }
    update(dt) {
      self.timer = self.timer - dt
      if(self.timer <= 0){
        self.timer = math.random(0.5, 1.5)
        world.random_step(self)
      }
      if(world.distance(self, world.state.player) <= self.sight){ goto chase }
    }
  }
  state chase {
    enter { self.timer = 0.2 }
    update(dt) {
      local player = world.state.player
      self.timer = self.timer - dt
      if(self.timer <= 0){
        if(world.distance(self, player) == 1){
          self.timer = 1.0
          combat.attack(self, player)
        } else {
          self.timer = 0.5
          world.step_towards(self, player)
        }
      }
      if(world.distance(self, player) > self.sight + 2){ goto idle }
    }
  }
}

machine bat {
  state flutter {
    enter { self.timer = math.random(0.1, 0.4) }
    update(dt) {
      self.timer = self.timer - dt
      if(self.timer <= 0){
        self.timer = 0.4
        local player = world.state.player
        local d = world.distance(self, player)
        if(d == 1 and math.random() < 0.3){
          self.timer = 0.8
          combat.attack(self, player)
        } else if(d <= 4 and math.random() < 0.6){
          world.step_towards(self, player)
        } else {
          world.random_step(self)
        }
      }
    }
  }
}
