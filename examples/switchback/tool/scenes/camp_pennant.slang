// tool/scenes/camp_pennant: a camp's pennant, its pole five meters ahead
// of the listener, ten seconds each: in nearly still air (it hangs), a
// light wind, a moderate one and a strong one with the game's gusts
// (the flaps come quicker and harder, the tip begins to snap), then
// from 12 m in the strong wind. The fire is left out.
local math = require("slang/math")

// {distance, wind}
local STEPS = {{5, 0.02}, {5, 0.12}, {5, 0.3}, {5, 0.8}, {12, 0.8}}

return func(kit, args){
  local world = require("tool/scenes/air_kit")
  local last = null
  return world.hear(
    kit,
    10 * len(STEPS),
    {"camp"},
    func(t, frame){
      local step = STEPS[math.min(to_int(t / 10), len(STEPS) - 1)]
      if(not same(step, last)){
        last = step
        world.camp(frame, step[0], "pennant")
      }
      world.blow(frame.around, t, step[1])
    },
    func(t, set){
      set("camp_fire_left", 0)
      set("camp_fire_right", 0)
    },
  )
}
