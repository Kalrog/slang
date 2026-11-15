// tool/scenes/tires_rig: what the tire scenarios (tool/scenes/tires_*)
// are made with (not a scenario itself): a truck that is only what the
// tires' layer looks at: four wheels whose speed, slip, load and ground
// a scenario sets by hand, the camera behind it; and the layer's own
// watch turning that into the parameters, frame by frame, as in the
// game. So a scenario hears the game's rules, not a copy of them.
//
//   local rig = require("tool/scenes/tires_rig")
//   local r = rig.new()
//   rig.wheel(r, 0, {surface: "gravel", speed: 5, load: 1})
//   return rig.run(kit, r, 10, func(t, r){ ... })       // -> {channels, load, costs}
local math = require("slang/math")
local str = require("slang/string")
local surfaces = require("game/surfaces")
local drivetrain = require("game/drivetrain")
local layer = require("sound/layers/tires")

local rig = {}

local RADIUS = drivetrain.SPEC.wheel_radius
local STANDING = drivetrain.SPEC.mass * 9.81 / 4
// where the wheels are on the truck (game/car: x to its left, z forward)
local PLACES = {{0.8, 1.36}, {-0.8, 1.36}, {0.8, -1.36}, {-0.8, -1.36}}

// new() -> Rig: a truck standing at the origin, looking along z, its
// wheels in the air; the camera behind it as the game's follows
func rig.new(){
  local wheels = {}
  for(local i = 0; i < 4; i = i + 1){
    append(wheels, {
      index: i,
      at: {x: PLACES[i][0], z: PLACES[i][1]},
      omega: 0,
      steer: 0,
      length: 0.23,
      contact: false,
      load: 0,
      along_speed: 0,
      across_speed: 0,
      surface: surfaces.rock,
      point: {x: PLACES[i][0], y: -RADIUS, z: PLACES[i][1]},
      wading: 0,
    })
  }
  local car = {
    wheels: wheels,
    pos: {x: 0, y: 0, z: 0},
    speed: 0,
    forward: {x: 0, y: 0, z: 1},
    up: {x: 0, y: 1, z: 0},
    left: {x: 1, y: 0, z: 0},
  }
  return {
    car: car,
    frame: {
      car: car,
      dt: 1 / 60,
      view: {
        eye: {x: 0, y: 2.5, z: -7.6},
        forward: {x: 0, y: -0.2, z: 0.98},
        right: {x: -1, y: 0, z: 0},
      },
    },
    state: layer.watcher(),
  }
}

// What a scenario says of a wheel (all optional; what is left out stays).
// type Wheel = {surface?: string, speed?: float, spin?: float,
//   side?: float, load?: float, contact?: bool, length?: float,
//   steer?: float, wading?: float}
// [surface]: by name (game/surfaces)
// [speed]: how fast the ground passes under it, m/s
// [spin]: how much faster than that its tread runs, m/s (a locked wheel:
//   minus the speed)
// [side]: how fast it slides sideways, m/s
// [load]: over what it carries when the truck stands (setting one puts
//   the wheel on the ground; contact false lifts it)
// [length]: the suspension's, m (0.23 at rest; shorter: pushed in)
// [steer]: its steering angle, rad
// [wading]: how deep it stands in water, m

// wheel(r, i, o: Wheel): wheel i (0 front left, 1 front right, 2 rear
// left, 3 rear right) as o says
func rig.wheel(r, i, o){
  local w = r.car.wheels[i]
  if(o.surface != null){
    w.surface = surfaces.by_name[o.surface]
  }
  if(o.load != null){
    w.load = o.load * STANDING
    w.contact = true
  }
  if(o.contact != null){
    w.contact = o.contact
    if(not o.contact){
      w.load = 0
    }
  }
  if(o.speed != null){
    w.along_speed = o.speed
    w.spin = w.spin or 0
  }
  if(o.spin != null){
    w.spin = o.spin
  }
  w.omega = (w.along_speed + (w.spin or 0)) / RADIUS
  if(o.side != null){
    w.across_speed = o.side
  }
  if(o.length != null){
    w.length = o.length
  }
  if(o.steer != null){
    w.steer = o.steer
  }
  if(o.wading != null){
    w.wading = o.wading
  }
}

// tune(args, from?) -> the arguments that are not `number=value`: those
// that are change that number of every ground (sound/ground.tune), for
// hearing what a number does, or a part of the sound alone: `grit=0
// swish=0 tack=0` leaves the tire's own rumble
func rig.tune(args, from){
  local ground = require("sound/ground")
  local rest = {}
  for(local i = from or 0; i < len(args); i = i + 1){
    local at = str.index_of(args[i], "=")
    if(at == null or at < 0){
      append(rest, args[i])
      continue
    }
    local changes = {}
    changes[str.substring(args[i], 0, at)] = str.to_number(
      str.substring(args[i], at + 1),
    )
    for(let local surface in values(surfaces.list)){
      ground.tune(surface.name, changes)
    }
  }
  return rest
}

// all(r, o: Wheel): every wheel as o says
func rig.all(r, o){
  for(local i = 0; i < 4; i = i + 1){
    rig.wheel(r, i, o)
  }
}

// run(kit, r, seconds, each) -> {channels, load, costs}: the tires alone
// through the mixer; each(t, r) sets the wheels before every frame
func rig.run(kit, r, seconds, each){
  return kit.mix(seconds, func(t, set, send){
    each(t, r)
    layer.watch(r.state, r.frame, set, send)
  }, {only: {"tires"}})
}

return rig
