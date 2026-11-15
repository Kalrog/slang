// tool/scenes/driveline_events: what happens once in the driveline, by
// hand, a second apart, the truck standing (nothing else sounds):
//   1, 2, 3 s   the slack taken up: soft, middling, hard
//   4 s         a gear change: the lever out, 0.3 s later in, then the slack
//   5 s         into a gear from rest
//   6, 7 s      the transfer case into low range, and back into high
//   8, 9 s      the rear axle's locker in, then the front's
//   10 s        both let go
//   11, 12 s    the hand brake pulled, and let go
// then the brakes: from 13 s a hard stop from 60 km/h, from 17 s a soft
// one from 30 km/h that ends in a squeak. The listener is behind the
// truck.
local math = require("slang/math")
local driveline = require("sound/layers/driveline")

return func(kit, args){
  local at = 0
  // what is sent when: {seconds, kind, a, b}
  local script = {
    {1, driveline.LASH, 0.2},
    {2, driveline.LASH, 0.5},
    {3, driveline.LASH, 1},
    {4, driveline.LEVER, 0},
    {4.3, driveline.LEVER, 1},
    {4.55, driveline.LASH, 0.5},
    {5, driveline.LEVER, 2},
    {6, driveline.RANGE, 2},
    {6.1, driveline.RANGE, 1},
    {7, driveline.RANGE, 2},
    {7.1, driveline.RANGE, 0},
    {8, driveline.LOCK, 1, 1},
    {9, driveline.LOCK, 0, 1},
    {10, driveline.LOCK, 1, 0},
    {10, driveline.LOCK, 0, 0},
    {11, driveline.HAND, 1},
    {12, driveline.HAND, 0},
  }
  return kit.mix(22, func(t, set, send){
    for(at < len(script) and script[at][0] <= t){
      send(script[at][1], script[at][2], script[at][3] or 0)
      at = at + 1
    }
    // the brakes
    local speed = 0
    local press = 0
    local squeak = 0
    if(t >= 13 and t < 16){
      speed = 16.7 * (1 - (t - 13) / 3)
      press = 1
    } else if(t >= 17 and t < 21){
      speed = 8.3 * (1 - (t - 17) / 4)
      press = 0.4
      if(speed < 2.2){
        squeak = math.min((2.2 - speed) / 0.6, 1) * math.min(speed / 0.25, 1)
      }
    }
    set("driveline_brake", press)
    set("driveline_wheel", speed / 0.42 / (2 * math.pi))
    set("driveline_squeak", squeak)
    set("driveline_pitch", 2300 * (0.95 + 0.05 * math.min(speed / 2.2, 1)))
    for(let local name in values({"mid", "front", "rear"})){
      set(concat("driveline_", name, "_left"), 0.6)
      set(concat("driveline_", name, "_right"), 0.6)
    }
  }, {only: {"driveline"}})
}
