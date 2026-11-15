// tool/scenes/tires_water: the truck drives through a ford: on gravel
// to the water, in over a sloping bank (the front wheels first, the rear
// a wheelbase later), wading across, out again, and on for the tires to
// drain. For seeing the splash (how fast it rises, where its weight
// lies, how loud it is), the wading rush under it, and that both end.
// Arguments: the speed in km/h (15), how deep the ford is in m (0.3),
// then "spin" for wheels spinning in the water, and `number=value` to
// change a number of the grounds (sound/ground.slang).
local math = require("slang/math")
local str = require("slang/string")
local rig = require("tool/scenes/tires_rig")

return func(kit, args){
  args = rig.tune(args)
  local speed = str.to_number(args[0] or "15") / 3.6
  local deep = str.to_number(args[1] or "0.3")
  local spin = args[2] == "spin"
  // the ford, in meters along the way: a bank that falls to the bed over
  // 1.5 m, 3 s of wading, a bank up again
  local bank = 1.5
  local from = 2 * speed
  local wide = bank * 2 + 3 * speed
  local func depth_at(x){
    local d = x - from
    if(d <= 0 or d >= wide){
      return 0
    }
    return deep * math.min(1, d / bank, (wide - d) / bank)
  }
  local seconds = 2 + wide / speed + 2.72 / speed + 4
  local r = rig.new()
  rig.all(r, {surface: "gravel", load: 1})
  return rig.run(kit, r, seconds, func(t, r){
    // (the last second it stands)
    local v = if(t < seconds - 1){ speed } else { 0 }
    for(local i = 0; i < 4; i = i + 1){
      // (the rear wheels are a wheelbase behind the front ones)
      local x = speed * t - (if(i >= 2){ 2.72 } else { 0 })
      local depth = depth_at(x)
      rig.wheel(r, i, {
        speed: v,
        wading: depth,
        surface: if(depth > 0.06){ "riverbed" } else { "gravel" },
        spin: if(spin and depth > 0.1){ 6 } else { 0 },
      })
    }
  })
}
