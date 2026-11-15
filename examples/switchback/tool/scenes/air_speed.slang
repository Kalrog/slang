// tool/scenes/air_speed: the air past the listener in still air: the
// truck's speed rising evenly from 0 to 30 m/s in twenty seconds (the
// bands should rise with it, the level by 18 dB for every doubling),
// then held at 3.75, 7.5, 15 and 30 m/s for five seconds each.
local math = require("slang/math")

return func(kit, args){
  local world = require("tool/scenes/air_kit")
  local steps = {3.75, 7.5, 15, 30}
  return world.hear(kit, 40, {"air"}, func(t, frame){
    if(t < 20){
      frame.car.velocity.z = 30 * t / 20
    } else {
      frame.car.velocity.z = steps[math.min(to_int((t - 20) / 5), 3)]
    }
  })
}
