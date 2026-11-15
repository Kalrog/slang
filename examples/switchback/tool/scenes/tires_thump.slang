// tool/scenes/tires_thump: bumps. The truck stands, then rolls at 15
// km/h, and every second and a half something pushes its suspension in:
// the front wheels first, the rear wheels as they reach it, harder each
// time (0.2, 0.4, 0.8, 1.6 m/s). For seeing the thump (the carcass, and
// the wheel hopping on its tire afterwards), how loud it is, and that
// the front is heard before the rear.
// Arguments: the surface ("rock"), then `number=value` to change a
// number of the ground (sound/ground.slang).
local rig = require("tool/scenes/tires_rig")

return func(kit, args){
  args = rig.tune(args)
  local surface = args[0] or "rock"
  local jolts = {0.2, 0.4, 0.8, 1.6}
  local r = rig.new()
  rig.all(r, {surface: surface, load: 1})
  local length = {0.23, 0.23, 0.23, 0.23}
  return rig.run(kit, r, 14, func(t, r){
    // standing for the first half, rolling for the second
    local rolling = t >= 7
    local speed = if(rolling){ 15 / 3.6 } else { 0 }
    local base = if(rolling){ 7.5 } else { 0.5 }
    for(local i = 0; i < 4; i = i + 1){
      // the bumps come to this wheel at: (the rear wheels 0.3 s later)
      local late = if(i >= 2){ 0.3 } else { 0 }
      local pushed = 0
      for(local k = 0; k < len(jolts); k = k + 1){
        local since = t - (base + k * 1.5 + late)
        // (pushed in over three frames, let out slowly)
        if(since >= 0 and since < 0.05){
          pushed = jolts[k]
        } else if(since >= 0.05 and since < 0.6){
          pushed = -jolts[k] * 0.05 / 0.55
        }
      }
      length[i] = length[i] - pushed / 60
      rig.wheel(r, i, {speed: speed, length: length[i]})
    }
  })
}
