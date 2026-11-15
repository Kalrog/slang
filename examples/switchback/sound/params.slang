// sound/params: what the game tells the sound. The game (sound/director,
// in the main isolate) and the mixer (sound/mixer, in the audio isolate)
// share two buffers of numbers: the parameters, one slot each, which the
// game writes once a frame and the mixer glides toward at every block;
// and a ring of events (a knock, a click in a menu), which happen once.
//
// The sound is made in layers (sound/layers/<name>.slang), each with its
// own parameters after the ones here; layout() puts them all in a row, the
// same in both isolates.
local kernel = require("kernel")

local m = {}

// the layers, in the order they are mixed: the truck's (its engine, what
// turns its wheels, its tires on the ground, its body), the world's (the
// air, the water, what lives there, the camps), the interface's
m.LAYERS = {
  "engine", "driveline", "tires", "body", "air", "water", "life", "camp", "interface",
}

// the parameters every layer may read: {name, start value, glide}
// (glide: the seconds a change takes to arrive; 0: at once)
m.CORE = {
  // the volumes of the settings, 0 to 1
  {"master", 0.8, 0.05},
  {"truck_volume", 1, 0.05},
  {"world_volume", 1, 0.05},
  {"interface_volume", 1, 0.05},
  // 1 while the game is paused (the world goes dull and quiet), and 1
  // while there is anything to hear at all (0: fading out)
  {"paused", 0, 0.12},
  {"awake", 0, 0.5},
}

// An event is four numbers: its kind, then three of its own. Every layer
// has a hundred kinds from its base here (its own list says which is
// what): a layer's watch sends them, its voice hears them.
m.EVENTS = {
  engine: 100, driveline: 200, tires: 300, body: 400, air: 500, water: 600,
  life: 700, camp: 800, interface: 900,
}
// how many events the ring holds: more than a frame can make
m.RING = 128

// layout() -> {list, slot, count}: every parameter in a row
// list: {{name, start, glide}}, slot: the index of each by name
local built = null
func m.layout(){
  if(built != null){
    return built
  }
  local list = {}
  local slot = {}
  local func add(p, owner){
    if(slot[p[0]] != null){
      raise(error.new(error.kinds.state, concat("sound: two parameters named ", p[0], " (", owner, ")")))
    }
    slot[p[0]] = len(list)
    append(list, p)
  }
  for(let local p in values(m.CORE)){
    add(p, "sound/params")
  }
  for(let local p in values(require("sound/space").params)){
    add(p, "sound/space")
  }
  // a switch for every layer (1: it sounds), for listening to some alone
  for(let local name in values(m.LAYERS)){
    add({concat("layer_", name), 1, 0}, "sound/params")
  }
  for(let local name in values(m.LAYERS)){
    local layer = require(concat("sound/layers/", name))
    for(let local p in values(layer.params or {})){
      add(p, name)
    }
  }
  built = {list: list, slot: slot, count: len(list)}
  return built
}

// shared() -> {values, events}: the two buffers, the parameters at their
// start values (what the director writes and a mixer reads)
func m.shared(){
  local layout = m.layout()
  local targets = kernel.double:array(layout.count, {shared: true})
  for(local i = 0; i < layout.count; i = i + 1){
    targets[i] = layout.list[i][1]
  }
  // (the count of events sent so far, then four numbers an event)
  local events = kernel.double:array(1 + m.RING * 4, {shared: true})
  return {values: targets, events: events}
}

// send(events, kind, a?, b?, c?): an event into the ring
func m.send(events, kind, a, b, c){
  local count = to_int(events[0])
  local at = 1 + (count % m.RING) * 4
  events[at] = kind
  events[at + 1] = a or 0
  events[at + 2] = b or 0
  events[at + 3] = c or 0
  events[0] = count + 1
}

return m
