// tool/scenes/tires_grounds: the truck on every ground in turn (rock,
// dirt, gravel, grass, sand, mud, snow, ice, riverbed, wood: the order
// of game/surfaces), four seconds on each and a second of standing
// between them. For comparing the grounds: how loud each is, where its
// sound lies, how ticked or how even it is.
// Arguments: the speed in km/h (25), how fast the wheels slip, m/s (0:
// they roll), then `number=value` to change a number of the grounds
// (sound/ground.slang).
local str = require("slang/string")
local surfaces = require("game/surfaces")
local rig = require("tool/scenes/tires_rig")

return func(kit, args){
  args = rig.tune(args)
  local speed = str.to_number(args[0] or "25") / 3.6
  local spin = str.to_number(args[1] or "0")
  local count = len(surfaces.list)
  local r = rig.new()
  rig.all(r, {load: 1})
  return rig.run(kit, r, count * 5, func(t, r){
    local k = to_int(t / 5)
    local moving = t - k * 5 < 4
    rig.all(r, {
      surface: surfaces.list[k].name,
      speed: if(moving){ speed } else { 0 },
      spin: if(moving){ spin } else { 0 },
    })
  })
}
