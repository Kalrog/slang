// tool/scenes/camp_fire: a camp's fire ahead of the listener, twelve
// seconds each: 3, 10 and 25 m away, in a light wind (its cracks at
// random, a few a second, most of them faint; the hiss and the flame's
// flutter only near; from far away only the cracks, duller), then at
// 3 m in a strong wind, which fans it. The pennant is left out.
local math = require("slang/math")

// {distance, wind}
local STEPS = {{3, 0.15}, {10, 0.15}, {25, 0.15}, {3, 0.7}}

return func(kit, args){
  local world = require("tool/scenes/air_kit")
  local last = null
  return world.hear(
    kit,
    12 * len(STEPS),
    {"camp"},
    func(t, frame){
      local step = STEPS[math.min(to_int(t / 12), len(STEPS) - 1)]
      // (a camp that moved is another camp: the layer looks again)
      if(not same(step, last)){
        last = step
        world.camp(frame, step[0])
      }
      world.blow(frame.around, t, step[1])
    },
    func(t, set){
      set("camp_flag_left", 0)
      set("camp_flag_right", 0)
    },
  )
}
