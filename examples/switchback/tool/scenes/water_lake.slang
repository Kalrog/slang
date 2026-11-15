// tool/scenes/water_lake: the lake's shore ahead of the listener, twelve
// seconds each: standing at it, then 5, 20 and 40 m from it (small waves
// lapping, one every two or three seconds, never on time, a few low
// bubbles with them; nothing at forty meters).
local math = require("slang/math")

local STEPS = {0, 5, 20, 40}

return func(kit, args){
  local world = require("tool/scenes/air_kit")
  return world.hear(kit, 12 * len(STEPS), {"water"}, func(t, frame){
    local w = frame.around.water
    w.distance = STEPS[math.min(to_int(t / 12), len(STEPS) - 1)]
    w.flow = 0
    w.lake = 1
    w.x = 0
    w.z = 1
  })
}
