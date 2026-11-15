// tool/scenes/tires_sweep: one wheel (the rear left) rolling on one
// ground with the load it stands with: from standing up to a speed, held
// there, and back to standing. For seeing that the sound's spectrum
// moves with the speed while the tire's resonances stay, that its level
// grows as it should, and that a wheel that stands is silent.
// Arguments: the surface ("dirt"), the top speed in km/h (60), the
// seconds the way up takes (12); then `number=value` to change a number
// of the ground (sound/ground.slang: `grit=0`).
local str = require("slang/string")
local rig = require("tool/scenes/tires_rig")

return func(kit, args){
  args = rig.tune(args)
  local surface = args[0] or "dirt"
  local top = str.to_number(args[1] or "60") / 3.6
  local rise = str.to_number(args[2] or "12")
  local speed = {
    {0, 0}, {0.5, 0}, {0.5 + rise, top}, {1.5 + rise, top}, {2.5 + rise, 0},
    {4 + rise, 0}
  }
  local r = rig.new()
  rig.wheel(r, 2, {surface: surface, load: 1})
  return rig.run(kit, r, rise + 4, func(t, r){
    rig.wheel(r, 2, {speed: kit.along(speed, t)})
  })
}
