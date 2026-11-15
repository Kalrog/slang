// tool/scenes/tires_steer: parking: the truck stands and its front
// wheels are turned from lock to lock and back, then again while it
// creeps at 2 km/h, then at 8 km/h (where the wheels roll and the
// twisting is gone). For seeing the groan of the patch held and let go,
// and on loose ground the grit crushed under it.
// Arguments: the surface ("rock"), then `number=value` to change a
// number of the ground (sound/ground.slang).
local math = require("slang/math")
local rig = require("tool/scenes/tires_rig")

return func(kit, args){
  args = rig.tune(args)
  local surface = args[0] or "rock"
  local r = rig.new()
  rig.all(r, {surface: surface, load: 1})
  local steer = 0
  return rig.run(kit, r, 15, func(t, r){
    local k = to_int(t / 5)
    local speed = ({0, 2 / 3.6, 8 / 3.6})[k]
    local since = t - k * 5
    // out to the lock and back, at the rate the game steers with
    local want = if(since > 0.5 and since < 2.2){ 0.6 } else if(since >= 2.2 and
      since < 3.9){ -0.6 } else { 0 }
    steer = steer + math.max(math.min(want - steer, 2.4 / 60), -2.4 / 60)
    for(local i = 0; i < 4; i = i + 1){
      rig.wheel(r, i, {speed: speed, steer: if(i < 2){ steer } else { 0 }})
    }
  })
}
