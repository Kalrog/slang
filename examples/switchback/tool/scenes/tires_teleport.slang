// tool/scenes/tires_teleport: what must not click. The truck drives on
// gravel at 30 km/h with its wheels spinning, and is set down standing
// somewhere else from one frame to the next (a tow); stands; is all at
// once driving again at speed on rock; and its wheels leave the ground
// and come back. Every parameter jumps: the sound must end and begin
// without a click.
// Arguments: `number=value` to change a number of the grounds
// (sound/ground.slang).
local rig = require("tool/scenes/tires_rig")

return func(kit, args){
  args = rig.tune(args)
  local r = rig.new()
  return rig.run(kit, r, 10, func(t, r){
    if(t < 3){
      rig.all(r, {surface: "gravel", load: 1, speed: 30 / 3.6, spin: 6})
    } else if(t < 5){
      // towed: somewhere else, standing
      r.car.pos.x = 500
      rig.all(r, {surface: "dirt", load: 1, speed: 0, spin: 0})
    } else if(t < 7){
      rig.all(r, {surface: "rock", load: 1, speed: 40 / 3.6, spin: 0})
    } else if(t < 8){
      // in the air, the wheels still turning
      rig.all(r, {contact: false})
    } else {
      rig.all(r, {load: 1.6, speed: 40 / 3.6})
    }
  })
}
