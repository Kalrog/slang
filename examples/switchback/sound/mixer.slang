// sound/mixer: the sound as it is computed, in the audio isolate of
// raylib/stream (or in a tool or a test, without an audio device): the
// parameters glided toward what the game wrote, the events handed out,
// every layer's voice adding to one of three stereo buses (the truck, the
// world, the interface); the truck and the world put in their place
// (sound/place.dsp: the ground's reflection, echoes, a tail), and the
// master (sound/master.dsp) making one pair of that and the interface.
//
//   local mixer = require("sound/mixer")
//   local block = mixer.new(shared.values, shared.events, {sample_rate: 48000})
//   block(out, 128)        // 128 frames, interleaved, into out
//
// A layer (sound/layers/<name>.slang) gives voice(ctx) -> {block(n),
// on?(kind, a, b, c)}: block adds n frames of it to a bus, on hears every
// event (a layer's own kinds start at params.EVENTS[its name]). ctx is
// what a voice works with:
//   ctx.rate, ctx.size (the most frames of a block)
//   ctx.now          the parameters as they are now (doubles, by slot)
//   ctx.slot         each parameter's slot by name
//   ctx.truck, ctx.world, ctx.interface   the buses: {left, right}
//   ctx.place(bus, source, was, to, n)    source into a bus, its gains
//                    gliding from was to to ({left, right} each)
extension "kernel/syntax"
local kernel = require("kernel")
local math = require("slang/math")
local time = require("slang/time")
local params = require("sound/params")
local place = require("sound/place")
local master = require("sound/master")

local m = {}

kernel {
  // each parameter a step toward its target
  func glide(now: double[], target: double[], rate: double[], n: int){
    for(local i = 0; i < n; i += 1){
      now[i] = now[i] + (target[i] - now[i]) * rate[i]
    }
  }

  func silence(a: float[], n: int){
    for(local i = 0; i < n; i += 1){
      a[i] = 0.0
    }
  }

  // a source into a stereo pair, its gains gliding over the block
  func spread(left: float[], right: float[], source: float[], l0: float, l1: float, r0: float, r1: float, n: int){
    local dl = (l1 - l0) / n
    local dr = (r1 - r0) / n
    local gl = l0
    local gr = r0
    for(local i = 0; i < n; i += 1){
      left[i] = left[i] + source[i] * gl
      right[i] = right[i] + source[i] * gr
      gl = gl + dl
      gr = gr + dr
    }
  }

  func interleave(out: float[], l: float[], r: float[], n: int){
    for(local i = 0; i < n; i += 1){
      out[2 * i] = l[i]
      out[2 * i + 1] = r[i]
    }
  }
}

// costs(layers?) -> Buffer: a shared buffer for options.costs: the mixer
// adds up in it what each layer takes, ms, in the order of params.LAYERS;
// after the layers the place and the master, then the frames computed
func m.costs(){
  return kernel.double:array(len(params.LAYERS) + 3, {shared: true})
}

// new(targets, events, options?: {sample_rate?: int, block?: int,
//   only?: {string}, costs?: Buffer}) -> func(out, frames)
// The block function: frames stereo frames into out (interleaved).
// targets and events: sound/params' shared buffers (the parameters as
// the game wrote them, the ring of events). block: the most frames one
// call makes (1024 by default). only: the layers that sound (all by
// default): for hearing one alone. costs: see [costs].
func m.new(targets, events, options){
  options = options or {}
  local rate = options.sample_rate or 48000
  local size = options.block or 1024
  local layout = params.layout()
  local count = layout.count
  local now = kernel.double:array(count)
  local rates = kernel.double:array(count)
  for(local i = 0; i < count; i = i + 1){
    now[i] = layout.list[i][1]
  }
  local func pair(){
    return {left: kernel.float:array(size), right: kernel.float:array(size)}
  }
  local ctx = {
    rate: rate,
    size: size,
    now: now,
    slot: layout.slot,
    truck: pair(),
    world: pair(),
    interface: pair(),
    place: func(bus, source, was, to, n){
      spread(bus.left, bus.right, source, was.left, to.left, was.right, to.right, n)
      was.left = to.left
      was.right = to.right
    },
  }
  local voices = {}
  local index_of = {}
  for(let local name in values(params.LAYERS)){
    local wanted = options.only == null
    for(let local w in values(options.only or {})){
      wanted = wanted or w == name
    }
    if(wanted){
      local v = require(concat("sound/layers/", name)).voice(ctx)
      v.index = len(index_of)
      v.switch = layout.slot[concat("layer_", name)]
      append(voices, v)
    }
    append(index_of, name)
  }
  local costs = options.costs
  local layers = len(params.LAYERS)
  local where = place:new({sample_rate: rate})
  local placed = pair()
  local where_ins = {ctx.truck.left, ctx.truck.right, ctx.world.left, ctx.world.right}
  local where_outs = {placed.left, placed.right}
  // the place's controls: each parameter's slot and the field it sets
  local where_sets = {}
  for(let local e in values({
    {"truck", "truck_volume"}, {"world", "world_volume"}, {"ground", "space_ground"},
    {"ground delay", "space_ground_delay"}, {"wall1 delay", "space_wall1_delay"},
    {"wall1 left", "space_wall1_left"}, {"wall1 right", "space_wall1_right"},
    {"wall2 delay", "space_wall2_delay"}, {"wall2 left", "space_wall2_left"},
    {"wall2 right", "space_wall2_right"}, {"tail", "space_tail"}, {"size", "space_size"},
    {"damp", "space_damp"},
  })){
    append(where_sets, {field: place.by_label[e[0]].field, slot: layout.slot[e[1]]})
  }
  local last = master:new({sample_rate: rate})
  local out_pair = pair()
  local ins = {placed.left, placed.right, ctx.interface.left, ctx.interface.right}
  local outs = {out_pair.left, out_pair.right}
  local slot = layout.slot
  local buses = {ctx.truck, ctx.world, ctx.interface}
  local glided_for = 0
  local read = 0
  local voice_count = len(voices)
  local set_count = len(where_sets)
  // (plain counted loops in here: this runs some four hundred times a
  // second, and should leave nothing for the collector)
  return func(out, frames){
    // the parameters, each as far toward its target as a block of this
    // length takes it
    if(frames != glided_for){
      glided_for = frames
      for(local i = 0; i < count; i = i + 1){
        local t = layout.list[i][2]
        rates[i] = if(t <= 0){ 1.0 } else { 1 - math.exp(-frames / rate / t) }
      }
    }
    glide(now, targets, rates, count)
    // the events since the last block (a ring that was lapped: the
    // newest only)
    local sent = to_int(events[0])
    if(sent - read > params.RING){
      read = sent - params.RING
    }
    for(read < sent){
      local at = 1 + (read % params.RING) * 4
      local kind = to_int(events[at])
      for(local i = 0; i < voice_count; i = i + 1){
        local v = voices[i]
        if(v.on != null){
          v.on(kind, events[at + 1], events[at + 2], events[at + 3])
        }
      }
      read = read + 1
    }
    for(local i = 0; i < 3; i = i + 1){
      silence(buses[i].left, frames)
      silence(buses[i].right, frames)
    }
    // (a layer switched off is not computed)
    if(costs == null){
      for(local i = 0; i < voice_count; i = i + 1){
        local v = voices[i]
        if(now[v.switch] > 0.5){
          v.block(frames)
        }
      }
    } else {
      for(local i = 0; i < voice_count; i = i + 1){
        local v = voices[i]
        if(now[v.switch] > 0.5){
          local t0 = time.clock()
          v.block(frames)
          costs[v.index] = costs[v.index] + time.clock() - t0
        }
      }
    }
    local t1 = time.clock()
    local state = where.state
    for(local i = 0; i < set_count; i = i + 1){
      local c = where_sets[i]
      state[c.field] = now[c.slot]
    }
    where.paused = now[slot.paused]
    where:compute(frames, where_ins, where_outs)
    local t2 = time.clock()
    last.master = now[slot.master]
    last.interface = now[slot.interface_volume]
    last.paused = now[slot.paused]
    last.awake = now[slot.awake]
    last:compute(frames, ins, outs)
    interleave(out, out_pair.left, out_pair.right, frames)
    if(costs != null){
      costs[layers] = costs[layers] + t2 - t1
      costs[layers + 1] = costs[layers + 1] + time.clock() - t2
      costs[layers + 2] = costs[layers + 2] + frames
    }
  }
}

return m
