// tool/scenes/tires_change: the truck at a steady speed drives from one
// ground onto another and back: the front wheels cross first, the rear
// wheels a wheelbase later. For seeing that the sound of one ground
// becomes the other's without a step or a click.
// Arguments: the two surfaces ("grass", "gravel"), the speed in km/h
// (25), then `number=value` to change a number of the grounds
// (sound/ground.slang).
local str = require("slang/string")
local rig = require("tool/scenes/tires_rig")

return func(kit, args){
  args = rig.tune(args)
  local first = args[0] or "grass"
  local second = args[1] or "gravel"
  local speed = str.to_number(args[2] or "25") / 3.6
  local r = rig.new()
  rig.all(r, {surface: first, load: 1, speed: speed})
  return rig.run(kit, r, 12, func(t, r){
    for(local i = 0; i < 4; i = i + 1){
      // (the rear wheels are a wheelbase behind the front ones)
      local at = t - (if(i >= 2){ 2.72 / speed } else { 0 })
      rig.wheel(r, i, {
        surface: if(at >= 4 and at < 8){ second } else { first },
      })
    }
  })
}
