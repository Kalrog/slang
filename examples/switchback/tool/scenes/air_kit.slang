// tool/scenes/air_kit: what the scenes of the air, the water and the
// camps are made with (not a scene itself): a listener standing in a
// place described by hand (a sound/around.Around filled in, a truck, a
// view), heard through the layers' own watch, as the game's frames are.
//
//   local world = require("tool/scenes/air_kit")
//   return world.hear(kit, 30, {"air"}, func(t, frame){
//     frame.around.trees.conifer = 1
//     world.blow(frame.around, t, 0.3)
//   })
local math = require("slang/math")
local around = require("sound/around")

local w = {}

// frame() -> a sound/director Frame with nothing in it: still air, no
// trees, the water and the camps far away, a truck standing at the
// origin, and the listener over it looking along z (to its right is -x)
func w.frame(){
  local a = around.new()
  a.wind.strength = 0
  a.wind.steady = 0
  return {
    around: a,
    view: {
      eye: {x: 0, y: 2.5, z: 0},
      forward: {x: 0, y: 0, z: 1},
      right: {x: -1, y: 0, z: 0},
      up: {x: 0, y: 1, z: 0},
    },
    car: {
      pos: {x: 0, y: 0, z: 7.6},
      velocity: {x: 0, y: 0, z: 0},
      speed: 0,
      forward: {x: 0, y: 0, z: 1},
      up: {x: 0, y: 1, z: 0},
      left: {x: 1, y: 0, z: 0},
    },
    world: {camps: {}},
    dt: 1 / 60,
    events: {},
    input: {},
  }
}

// blow(a, t, steady): the wind of the Around a at the time t, as
// sound/around makes it (its gusts over seconds), about the strength
// steady (0 to 1); the gusts are as large a share of it as on the
// game's moderate day
func w.blow(a, t, steady){
  local gust = math.sin(t / 3.7) * math.sin(t / 2.3 + 2) +
    0.5 * math.sin(t / 0.9 + 0.7) * math.sin(t / 6.1)
  gust = math.max(gust, 0)
  a.wind.steady = math.min(steady, 1)
  a.wind.strength = math.min(steady * (1 + gust * gust), 1)
}

// turn(view, angle): the listener looking angle (radians) to the right
// of along z
func w.turn(view, angle){
  view.forward.x = -math.sin(angle)
  view.forward.z = math.cos(angle)
  view.right.x = -math.cos(angle)
  view.right.z = -math.sin(angle)
}

// camp(frame, distance, what?): a camp put so that its fire (or, with
// what "pennant", the foot of its pole) is distance meters ahead of the
// listener (sound/layers/camp: the fire lies 1.9 m to the left of the
// camp's place and 3 m before it, the pole 4.7 m to the right and 1 m
// before it)
func w.camp(frame, distance, what){
  local x = -1.9
  local z = distance + 3.0
  if(what == "pennant"){
    x = 4.7
    z = distance + 1.0
  }
  frame.world.camps = {{x: x, y: 0, z: z, yaw: 0, name: "Camp"}}
  local d = math.sqrt(x * x + z * z)
  frame.around.camp = {distance: d, x: x / d, z: z / d, index: 0}
}

// hear(kit, seconds, layers, each, after?) -> what kit.mix gives: before
// every frame each(t, frame) changes what is around, then the layers
// watch it, then after(t, set) may set parameters over theirs. The
// levels are the bus's: the master open, the place adding nothing.
func w.hear(kit, seconds, layers, each, after){
  local frame = w.frame()
  local watching = {}
  for(let local name in values(layers)){
    local layer = require(concat("sound/layers/", name))
    append(watching, {layer: layer, state: layer.watcher()})
  }
  return kit.mix(seconds, func(t, set, send){
    set("master", 1)
    set("space_ground", 0)
    set("space_tail", 0)
    each(t, frame)
    for(let local e in values(watching)){
      e.layer.watch(e.state, frame, set, send)
    }
    if(after != null){
      after(t, set)
    }
  }, {only: layers})
}

return w
