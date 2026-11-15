// tool/scenes/tires_probe: what the wheels do on a real drive, as numbers:
// the bot drives (as tool/scenes/drive) and every frame's wheels are
// written to a CSV file, one line a wheel: for looking at what the tire
// sound is given (how fast wheels spin, how hard they land, where the
// water is) without listening.
// Arguments: the CSV's path, seed (25), from (m along the trail, 0),
// seconds (30), then "heavy" for a heavy foot and layers to hear.
local os = require("slang/os")
local str = require("slang/string")
local terrain = require("game/terrain")
local car_lib = require("game/car")

return func(kit, args){
  local path = args[0] or "tires_probe.csv"
  local only = null
  local heavy = false
  for(local i = 4; i < len(args); i = i + 1){
    if(args[i] == "heavy"){
      heavy = true
    } else {
      only = only or {}
      append(only, args[i])
    }
  }
  local lines = {
    "t,wheel,contact,tread,along,across,load,length,surface,water,steer,speed,x,z",
  }
  local r = kit.drive({
    seed: to_int(str.to_number(args[1] or "25")),
    from: str.to_number(args[2] or "0"),
    seconds: str.to_number(args[3] or "30"),
    heavy: heavy,
    only: only or {"tires"},
    each: func(t, world, sound){
      local car = world.car
      for(local i = 0; i < 4; i = i + 1){
        local w = car.wheels[i]
        append(lines, str.format(
          "%.3f,%d,%d,%.3f,%.3f,%.3f,%.0f,%.4f,%s,%.3f,%.4f,%.3f,%.1f,%.1f", t,
          i, if(w.contact){ 1 } else { 0 }, w.omega * car_lib.WHEEL_RADIUS,
          w.along_speed, w.across_speed, w.load, w.length, w.surface.name,
          terrain.water_at(world.land, w.point.x, w.point.z), w.steer,
          car.speed, w.point.x, w.point.z
        ))
      }
    },
  })
  os.write_file(path, str.join(lines, "\n"))
  return r
}
