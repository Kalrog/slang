// tool/scenes/water_river: the river ahead of the listener, eight
// seconds each: at 2, 10, 40 and 120 m (the bubbles go first, then the
// highs, then the level: -34 dB at ten meters on the plan's scale, half
// of that as the layer is mixed), then at 10 m rapids, and a slow
// stretch.
local math = require("slang/math")

// {distance, flow}
local STEPS = {
  {2, 0.6}, {10, 0.6}, {40, 0.6}, {120, 0.6}, {10, 1.0}, {10, 0.25}
}

return func(kit, args){
  local world = require("tool/scenes/air_kit")
  return world.hear(kit, 8 * len(STEPS), {"water"}, func(t, frame){
    local step = STEPS[math.min(to_int(t / 8), len(STEPS) - 1)]
    local w = frame.around.water
    w.distance = step[0]
    w.flow = step[1]
    w.lake = 0
    w.x = 0
    w.z = 1
  })
}
