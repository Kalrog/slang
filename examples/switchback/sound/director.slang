// sound/director: the game's sound from the game's side. It starts the
// audio stream (raylib/stream: the mixer, sound/mixer, runs in an isolate
// of its own), and once a frame every layer looks at the world and writes
// what it hears into the shared parameters; what happens once (a knock, a
// click) goes as an event.
//
//   local director = require("sound/director")
//   local sound = director.start({volume: 0.8})    // null: no sound
//   sound:frame({world, car, view, dt, ...})       // every frame: see [Frame]
//   sound:engine(true)                             // the engine started
//   sound:rest()                                   // quiet until the next frame
//   sound:stop()
//
// Without an audio device, or with SWITCHBACK_MUTE set, start returns
// null; offline() gives a director without a stream, whose parameters a
// tool or a test hands to a mixer itself.
local os = require("slang/os")
local params = require("sound/params")
local around = require("sound/around")
local space = require("sound/space")

local m = {}

local Director = {}
local meta = {__index: Director, __type: "sound.Director"}

local func make(shared){
  local layout = params.layout()
  local layers = {}
  local by_name = {}
  for(let local name in values(params.LAYERS)){
    local layer = require(concat("sound/layers/", name))
    local entry = {
      name: name, layer: layer,
      state: if(layer.watcher != null){ layer.watcher() } else { {} },
    }
    append(layers, entry)
    by_name[name] = entry
  }
  local targets = shared.values
  local slot = layout.slot
  return {
    shared: shared,
    layers: layers,
    by_name: by_name,
    player: null,
    around: around.new(),
    space: space.watcher(),
    set: func(name, value){
      targets[slot[name]] = value
    },
    send: func(kind, a, b, c){
      params.send(shared.events, kind, a, b, c)
    },
    @meta: meta,
  }
}

// offline() -> Director: no stream; its shared.values and shared.events
// are what a mixer takes
func m.offline(){
  return make(params.shared())
}

// start(options?: {volume?: float}) -> Director?
// The stream started (silent until the first frame). null when the sound
// is off (SWITCHBACK_MUTE) or there is no audio device.
func m.start(options){
  if(os.getenv("SWITCHBACK_MUTE") != null){
    return null
  }
  options = options or {}
  local d = make(params.shared())
  d.set("master", options.volume or 0.8)
  local stream = require("raylib/stream")
  d.costs = require("sound/mixer").costs()
  d.player = stream.play(func(targets, events, costs){
    return require("sound/mixer").new(targets, events, {
      sample_rate: 48000, block: 128, costs: costs,
    })
  }, {
    args: {d.shared.values, d.shared.events, d.costs},
    sample_rate: 48000, channels: 2, block: 128, latency: 1024,
  })
  return d
}

// What a frame gives the layers to look at.
// type Frame = {world: game/world.World, car: game/car.Car,
//   view: scene.View, dt: float, setup?: garage.Setup, damage?: float,
//   paused?: float, input?: car.Input, events?: {Event},
//   screen?: string, around?: sound/around.Around}
// [view]: the listener: the camera (eye, forward, right)
// [damage]: the truck's, 0 to 1
// [paused]: 1 behind a pause menu (the world dull and quiet), 0 driving
// [input]: what the driver does this frame
// [events]: what happened in the game this frame (game/run's and
//   game/explore's events), and in its menus: {kind: "menu", what:
//   "move" | "select" | "back" | ...}
// [screen]: the game's screen: "title", "drive", "pause", "map"...
// [around]: what is around the listener; frame fills it in

// frame(s: Frame): what the listener hears this frame
func Director.frame(d, s){
  d.set("awake", 1)
  d.set("paused", s.paused or 0)
  if(s.world != null){
    around.look(d.around, s.world, s.view, s.dt)
    s.around = d.around
    space.watch(d.space, s, d.set)
  }
  s.around = d.around
  s.events = s.events or {}
  s.input = s.input or {}
  for(let local entry in values(d.layers)){
    if(entry.layer.watch != null){
      entry.layer.watch(entry.state, s, d.set, d.send)
    }
  }
}

// rest(): nothing is heard until the next frame (while the game is busy
// with something else and no frame comes: a valley being made); it fades
func Director.rest(d){
  d.set("awake", 0)
}

// engine(running: bool): the engine started (the starter turns it and it
// catches) or switched off (it runs down)
func Director.engine(d, running){
  d.by_name.engine.state.running = running
}

// volume(v: float): the master volume, 0 to 1
func Director.volume(d, v){
  d.set("master", v)
}

// layer(name: string, on: bool): a layer switched on or off (for
// listening to some alone); heard(name) -> bool: whether it is on
func Director.layer(d, name, on){
  d.set(concat("layer_", name), if(on){ 1 } else { 0 })
}

func Director.heard(d, name){
  return d.shared.values[params.layout().slot[concat("layer_", name)]] > 0.5
}

// event(kind, a?, b?, c?): something that happens once (params.EVENTS)
func Director.event(d, kind, a, b, c){
  params.send(d.shared.events, kind, a, b, c)
}

// stats() -> raylib/stream's Stats?: how the stream is doing
func Director.stats(d){
  if(d.player == null){
    return null
  }
  return d.player:stats()
}

// shares() -> {{name: string, share: float}}: what each layer, the place
// and the master have taken of real time since the start (1: all of it)
func Director.shares(d){
  local out = {}
  if(d.costs == null){
    return out
  }
  local n = len(params.LAYERS)
  local seconds = d.costs[n + 2] / 48000
  local names = {...params.LAYERS, "place", "master"}
  for(local i = 0; i < n + 2; i = i + 1){
    append(out, {name: names[i], share: if(seconds > 0){ d.costs[i] / 1000 / seconds } else { 0 }})
  }
  return out
}

// stop(): the sound fades and the stream ends
func Director.stop(d){
  if(d.player != null){
    d.set("awake", 0)
    require("slang/time").sleep(250)
    d.player:stop()
    d.player = null
  }
}

return m
