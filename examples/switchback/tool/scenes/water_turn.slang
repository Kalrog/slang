// tool/scenes/water_turn: a river ten meters ahead while the listener
// turns once round to the right in twenty seconds (the river goes round
// to the left, behind, and comes back on the right), then walks up to it
// and stands in it (it opens to both sides).
local math = require("slang/math")

return func(kit, args){
  local world = require("tool/scenes/air_kit")
  return world.hear(kit, 30, {"water"}, func(t, frame){
    local w = frame.around.water
    w.flow = 0.6
    w.lake = 0
    w.x = 0
    w.z = 1
    world.turn(frame.view, math.min(t / 20, 1) * 2 * math.pi)
    w.distance = math.max(10 - math.max(t - 22, 0) * 2.5, 0)
  })
}
