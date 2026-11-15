// tool/scenes/tires_crawl: one wheel (the rear left) at a crawl on one
// ground: eight seconds each at 3, 5 and 10 km/h (or the speeds given),
// a second of standing between them. At a walk the tire's sound is
// single events (crumbs crushed, lumps thudding): for counting them:
// there must be as many to a meter at every speed.
// Arguments: the surface ("gravel"), then speeds in km/h, and
// `number=value` to change a number of the ground (sound/ground.slang:
// `grit=3 rumble=0 lugs=0 swish=0 tack=0` leaves a few crumbs to count).
local str = require("slang/string")
local rig = require("tool/scenes/tires_rig")

return func(kit, args){
  args = rig.tune(args)
  local surface = args[0] or "gravel"
  local speeds = {}
  for(local i = 1; i < len(args); i = i + 1){
    append(speeds, str.to_number(args[i]) / 3.6)
  }
  if(len(speeds) == 0){
    speeds = {3 / 3.6, 5 / 3.6, 10 / 3.6}
  }
  local r = rig.new()
  rig.wheel(r, 2, {surface: surface, load: 1})
  return rig.run(kit, r, len(speeds) * 9, func(t, r){
    local k = to_int(t / 9)
    rig.wheel(r, 2, {speed: if(t - k * 9 < 8){ speeds[k] } else { 0 }})
  })
}
