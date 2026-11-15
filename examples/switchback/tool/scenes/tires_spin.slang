// tool/scenes/tires_spin: the truck crawls at 5 km/h and its wheels
// spin: faster and faster up to 15 m/s over eight seconds, held for two,
// then they catch again. For seeing what a heavy foot sounds like on a
// ground: what the tires tear loose and throw, where it lies, and that
// it stays under the engine.
// Arguments: the surface ("gravel"), how fast the wheels slip at the
// most, m/s (15), then "side" for sliding sideways instead of spinning,
// and `number=value` to change a number of the ground
// (sound/ground.slang).
local str = require("slang/string")
local rig = require("tool/scenes/tires_rig")

return func(kit, args){
  args = rig.tune(args)
  local surface = args[0] or "gravel"
  local most = str.to_number(args[1] or "15")
  local side = args[2] == "side"
  local slip = {{0, 0}, {1, 0}, {9, most}, {11, most}, {11.5, 0}, {13, 0}}
  local r = rig.new()
  rig.all(r, {surface: surface, load: 1, speed: 5 / 3.6})
  return rig.run(kit, r, 14, func(t, r){
    local s = kit.along(slip, t)
    rig.all(r, {
      speed: if(t < 13){ 5 / 3.6 } else { 0 },
      spin: if(side){ 0 } else { s },
      side: if(side){ s } else { 0 },
    })
  })
}
