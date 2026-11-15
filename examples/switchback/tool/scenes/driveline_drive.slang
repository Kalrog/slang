// tool/scenes/driveline_drive: the driveline in the real game, a driver
// working everything it has. The bot drives with a heavy foot; then
//   12 s   it brakes to a stop
//   14 s   low range; 15 s the rear locker; 16 s the front one too
//   17 s   on up the trail, flat out
//   23 s   the lockers let go, and it brakes to a stop
//   25 s   the hand brake, for a second
//   27 s   backward, flat out, for three seconds; then it stops
//   32 s   high range, and on up the trail
// Arguments: seed (25), from (m along the trail, 300), then the layers
// to hear (the driveline alone when none are given).
local str = require("slang/string")

return func(kit, args){
  local only = {}
  for(local i = 2; i < len(args); i = i + 1){
    append(only, args[i])
  }
  if(len(only) == 0){
    only = {"driveline"}
  }
  return kit.drive({
    seed: to_int(str.to_number(args[0] or "25")),
    from: str.to_number(args[1] or "300"),
    seconds: 40,
    heavy: true,
    only: only,
    input: func(t, world, input){
      local speed = world.car.speed
      if(t < 12){
        input.low = false
        return input
      }
      local out = {steer: input.steer or 0}
      out.low = t >= 14 and t < 32
      out.lock_rear = t >= 15 and t < 23
      out.lock_front = t >= 16 and t < 23
      if(t < 17){
        // stopping, and standing
        out.back = if(speed > 0.3){ 0.8 } else { 0 }
      } else if(t < 23){
        out.forward = 1
      } else if(t < 27){
        out.back = if(speed > 0.3){ 0.8 } else { 0 }
        out.hand_brake = t >= 25 and t < 26
      } else if(t < 30){
        out.back = 1
        out.steer = 0
      } else if(t < 32){
        out.forward = if(speed < -0.3){ 0.8 } else { 0 }
        out.steer = 0
      } else {
        out.forward = input.forward
        out.back = input.back
      }
      return out
    },
  })
}
