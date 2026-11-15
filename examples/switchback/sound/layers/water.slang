// sound/layers/water: the river and the lake, as far as they are heard
// from where the listener is. Near by a river babbles: bubbles
// (sound/water/bubbles.dsp) over a bed of rushing noise
// (sound/water.dsp), louder and brighter the faster it runs; further off
// the bubbles go first, then the highs, and from far away only a dull
// rush is left, and beyond 170 m nothing. The lake does not flow: at its
// shore small waves come in (sound/water/lake.dsp), with a few low
// bubbles, and forty meters from it there is nothing to hear.
//
// The water lies somewhere for the listener: its sound comes in two
// halves, one to the left and one to the right of where its nearest
// place is, wide apart when it is near (a river is a line, not a
// point), and all around when the listener stands at or over it.
//
// What moves by itself is made in the voice, a block at a time: the
// eddies (the bed's wash and hiss swell and sink, each half by itself)
// and the lake's waves (when the next one comes, how large it is).
// (The truck's own splashing through a ford is the tires'.)
local math = require("slang/math")
local kernel = require("kernel")

local m = {}

m.params = {
  // where the two halves are heard: each one's gain on each side
  {"water_a_left", 0, 0.3},
  {"water_a_right", 0, 0.3},
  {"water_b_left", 0, 0.3},
  {"water_b_right", 0, 0.3},
  // the river: how loud its bed is (by distance: 1 at ten meters), how
  // fast it runs (0 to 1), and the highest the distance leaves, Hz
  {"water_river", 0, 0.5},
  {"water_flow", 0.5, 1.0},
  {"water_dull", 8000, 0.5},
  // the lake: how loud its waves are (1 at the shore), and how much of
  // the water here is lake (0 to 1)
  {"water_lake", 0, 0.8},
  {"water_still", 0, 1.0},
  // the bubbles: how many a second, their pitches from low to high, Hz,
  // and how loud
  {"water_rate", 0, 0.5},
  {"water_low", 400, 1.0},
  {"water_high", 2600, 1.0},
  {"water_bubbles", 0, 0.5},
}

// ------------------------------------------------------------ the game's side

// how far the river is heard at all, m
m.REACH = 170.0
// how far the lake's shore is heard, m
m.SHORE = 40.0

local func smoothstep(a, b, v){
  local t = math.min(math.max((v - a) / (b - a), 0), 1)
  return t * t * (3 - 2 * t)
}

// watcher() -> the layer's state in the main isolate: the water's
// nearest place as it was found last
func m.watcher(){
  return {near: {distance: 1000, x: 0, z: 1, flow: 0, still: 0}}
}

// nearest(near, river, x, z): the river's (game/terrain: a line of
// points, each with its water's level and half its width) nearest place
// to x, z, into near: how far its bank is, which way it lies, how fast
// it runs there and how much of it is lake. sound/around says the same
// of the nearest of the points; a listener who moves along the river
// would hear it swing from one point to the next, so here it is the
// nearest place on the line between them.
local func nearest(near, river, x, z){
  local points = river.points
  local count = len(points)
  // the point whose bank is nearest (not whose middle is: the lake is
  // a hundred meters and more wide where the river is ten)
  local best = 0
  local least = 1.0e18
  for(local i = 0; i < count; i = i + 1){
    local p = points[i]
    local d = math.sqrt((p.x - x) * (p.x - x) + (p.z - z) * (p.z - z)) - p.half
    if(d < least){
      least = d
      best = i
    }
  }
  // (the two stretches that meet there)
  local bank = 1.0e18
  local along = points[best].z
  for(local i = math.max(best - 1, 0); i <= best and i < count - 1; i = i + 1){
    local p = points[i]
    local q = points[i + 1]
    local sx = q.x - p.x
    local sz = q.z - p.z
    local t = math.min(
      math.max(((x - p.x) * sx + (z - p.z) * sz) / (sx * sx + sz * sz), 0),
      1,
    )
    local px = p.x + sx * t
    local pz = p.z + sz * t
    local d = math.sqrt((px - x) * (px - x) + (pz - z) * (pz - z))
    local to_bank = math.max(d - (p.half + (q.half - p.half) * t), 0)
    if(to_bank < bank){
      bank = to_bank
      along = pz
      if(d > 0.01){
        near.x = (px - x) / d
        near.z = (pz - z) / d
      }
    }
  }
  near.distance = bank
  // how fast it falls there (as sound/around has it), and the lake: all
  // lake in its middle, river again beyond its ends
  local up = points[math.max(best - 2, 0)]
  local down = points[math.min(best + 2, count - 1)]
  local run = math.sqrt(
    (up.x - down.x) * (up.x - down.x) + (up.z - down.z) * (up.z - down.z),
  )
  local fall = if(run > 1){ math.abs(up.level - down.level) / run } else { 0 }
  near.still = if(river.lake != null){ 1 -
    smoothstep(110, 150, math.abs(along - river.lake.z)) } else { 0 }
  near.flow = (1 - near.still) * math.min(0.25 + fall / 0.05, 1)
}

// pan(side, ahead) -> left, right gains of a sound that way (side: 1 to
// the right, ahead: 1 in front), as sound/listener places a point: never
// all on one side, a little quieter behind
local func pan_left(side, ahead){
  local gain = if(ahead < 0){ 1 + 0.3 * ahead } else { 1 }
  return gain * math.cos((side * 0.8 + 1) * math.pi / 4)
}

local func pan_right(side, ahead){
  local gain = if(ahead < 0){ 1 + 0.3 * ahead } else { 1 }
  return gain * math.sin((side * 0.8 + 1) * math.pi / 4)
}

// watch(w, s, set, send): a frame (s: sound/director's Frame)
func m.watch(w, s, set, send){
  local a = s.around
  local view = s.view
  if(a == null or view == null){
    return
  }
  // the water's nearest place: on the river's line where the world has
  // one, else as sound/around says
  local near = w.near
  local river = null
  if(s.world != null and s.world.land != null){
    river = s.world.land.river
  }
  if(river != null){
    nearest(near, river, view.eye.x, view.eye.z)
  } else {
    near.distance = a.water.distance
    near.x = a.water.x
    near.z = a.water.z
    near.still = a.water.lake
    near.flow = a.water.flow
  }
  local d = near.distance
  local still = near.still
  // the river's bed: 11 dB quieter at fifty meters than at ten, 7 dB
  // louder standing in it, and gone at REACH; the distance takes the
  // highs (6 kHz left in it, under 3 at ten meters, 800 Hz at fifty)
  local far = 1 - smoothstep(70, m.REACH, d)
  local carry = math.exp(1.25 * math.log(22 / (d + 12))) * far * far
  set("water_river", (1 - still) * carry)
  set("water_flow", near.flow)
  set("water_dull", 6000 * math.exp(-1.1 * math.log(1 + d / 10)))
  // the lake's waves: only near its shore
  local shore = still * (1 - smoothstep(8, m.SHORE, d))
  set("water_lake", shore)
  set("water_still", still)
  // the bubbles: a river's are lost sooner than its rush (not half as
  // loud at ten meters as beside it, and none from thirty on); the
  // lake's are few and low
  local babble = (1 - still) * math.max(1.11 / (1 + d * d / 100) - 0.11, 0)
  set("water_rate", (1 - still) * (25 + 70 * near.flow) + still * 2.5)
  set("water_low", 400 - 180 * still)
  set("water_high", 2600 - 1500 * still)
  set("water_bubbles", babble + 0.7 * shore)
  // where it lies: the two halves to the left and to the right of its
  // nearest place, 80 degrees each way beside it, 38 at fifty meters;
  // at or over it they are simply left and right
  local right = view.right
  local f = view.forward
  local flat = math.max(math.sqrt(f.x * f.x + f.z * f.z), 0.001)
  local side = near.x * right.x + near.z * right.z
  local ahead = (near.x * f.x + near.z * f.z) / flat
  local spread = (25 + 55 / (1 + d / 15)) * math.pi / 180
  local c = math.cos(spread)
  local sn = math.sin(spread)
  local over = 1 - smoothstep(0, 12, d)
  local wide_near = pan_left(-1, 0)
  local wide_far = pan_right(-1, 0)
  local al = pan_left(side * c - ahead * sn, ahead * c + side * sn)
  local ar = pan_right(side * c - ahead * sn, ahead * c + side * sn)
  local bl = pan_left(side * c + ahead * sn, ahead * c - side * sn)
  local br = pan_right(side * c + ahead * sn, ahead * c - side * sn)
  set("water_a_left", al + (wide_near - al) * over)
  set("water_a_right", ar + (wide_far - ar) * over)
  set("water_b_left", bl + (wide_far - bl) * over)
  set("water_b_right", br + (wide_near - br) * over)
}

// ------------------------------------------------------------ the mixer's side

// The water's level in the mix. At 1 it is as loud as the sound's plan
// has it (a river at ten meters -34 dB re full scale on the world's
// bus, at fifty -45); the user turned the truck down by ear, and the
// water with it: at 0.3 a river being forded is no louder than the
// truck's own wading through it (the tires'), and one thirty meters off
// is a bed under an engine that idles.
local LEVEL = 0.3
// how loud the bubbles are (a river's at its bank -44 dB re full scale
// together, the largest single ones 20 dB over that)
local BUBBLES = 0.04
// under this nothing is heard
local QUIET = 0.0003
// how much the bed's wash and hiss swell and sink (as a share)
local WASH = 0.4
local HISS = 0.5
// the lake's waves: one every so many seconds on each shore, and how
// many times more bubbles a wave at its highest brings
local PERIODS = {2.1, 2.9}
local SPLASH = 3.0

// voice(ctx) -> {block}: see sound/mixer
func m.voice(ctx){
  local rate = ctx.rate
  local size = ctx.size
  local now = ctx.now
  local slot = ctx.slot
  local func made(program, inputs, outputs){
    local inst = program:new({sample_rate: rate})
    local p = {
      program: program, inst: inst, state: inst.state, ins: {}, outs: {},
      field: {}
    }
    for(local i = 0; i < inputs; i = i + 1){
      append(p.ins, kernel.float:array(1))
    }
    for(local i = 0; i < outputs; i = i + 1){
      append(p.outs, kernel.float:array(size))
    }
    for(let local c in values(program.controls)){
      p.field[c.label] = c.field
    }
    return p
  }
  local river = made(require("sound/water"), 4, 2)
  local bubbles = made(require("sound/water/bubbles"), 0, 2)
  local lake = made(require("sound/water/lake"), 0, 2)
  local river_river = river.field.river
  local river_flow = river.field.flow
  local river_dull = river.field.dull
  local river_eddies = {
    river.field.wash_a, river.field.hiss_a, river.field.wash_b,
    river.field.hiss_b
  }
  local bubbles_rate = bubbles.field.rate
  local bubbles_low = bubbles.field.low
  local bubbles_high = bubbles.field.high
  local bubbles_level = bubbles.field.level
  local lake_level = lake.field.level
  local lake_surges = {lake.field.surge_a, lake.field.surge_b}
  local s_a_left = slot.water_a_left
  local s_a_right = slot.water_a_right
  local s_b_left = slot.water_b_left
  local s_b_right = slot.water_b_right
  local s_river = slot.water_river
  local s_flow = slot.water_flow
  local s_dull = slot.water_dull
  local s_lake = slot.water_lake
  local s_still = slot.water_still
  local s_rate = slot.water_rate
  local s_low = slot.water_low
  local s_high = slot.water_high
  local s_bubbles = slot.water_bubbles
  local silent = kernel.float:array(size)
  // numbers at random, from -1 to 1
  local seed = 19141108
  local func random(){
    seed = (seed * 69069 + 12345) & 0xffffffff
    return seed / 2147483648.0 - 1
  }
  // the eddies: four slow random signals about 0 (the wash and the hiss
  // of each half), each a noise that forgets itself and is smoothed once
  // more (as the air's weather is: sound/layers/air)
  local rough = {0.0, 0.0, 0.0, 0.0}
  local eddy = {0.0, 0.0, 0.0, 0.0}
  // the lake's waves, one train on each shore: where each wave is in its
  // time (0 to 1), how large it is (0 to 1), and how its timing wanders
  local at = {0.3, 0.8}
  local large = {0.5, 0.8}
  local wander = {0.0, 0.0}
  local was_a = {left: 0, right: 0}
  local was_b = {left: 0, right: 0}
  local to_a = {left: 0, right: 0}
  local to_b = {left: 0, right: 0}
  return {
    block: func(n){
      local bed = now[s_river]
      local shore = now[s_lake]
      local babble = now[s_bubbles]
      // (no water within earshot: nothing to compute)
      if(bed < QUIET and shore < QUIET and babble < QUIET){
        return
      }
      local dt = n / rate
      local ins = river.ins
      ins[0] = silent
      ins[1] = silent
      ins[2] = silent
      ins[3] = silent
      local splash = 0
      if(shore >= QUIET){
        // the waves: each runs up the shore in the first sixth of its
        // time, back down over the next half, then there is nothing till
        // the next, which comes a third sooner or later and is of its own
        // size
        local state = lake.state
        local keep = math.exp(-dt / 0.7)
        local push = math.sqrt((1 - keep * keep) * 3)
        for(local k = 0; k < 2; k = k + 1){
          wander[k] = wander[k] * keep + random() * push
          local t = at[k] + dt / PERIODS[k] * math.max(1 + 0.3 * wander[k], 0.3)
          if(t >= 1){
            t = t - 1
            large[k] = math.abs(random())
          }
          at[k] = t
          local up = math.min(t / 0.16, 1)
          local down = math.min(math.max(1 - (t - 0.16) / 0.55, 0), 1)
          local surge = up * up * (3 - 2 * up) * down * down *
            (0.25 + 0.75 * large[k] * large[k])
          state[lake_surges[k]] = surge
          splash = splash + surge
        }
        state[lake_level] = shore
        lake.inst:compute(n, lake.ins, lake.outs)
        ins[2] = lake.outs[0]
        ins[3] = lake.outs[1]
      }
      if(babble >= QUIET){
        local state = bubbles.state
        state[bubbles_rate] = now[s_rate] * (1 + SPLASH * splash * now[s_still])
        state[bubbles_low] = now[s_low]
        state[bubbles_high] = now[s_high]
        state[bubbles_level] = babble * BUBBLES
        bubbles.inst:compute(n, bubbles.ins, bubbles.outs)
        ins[0] = bubbles.outs[0]
        ins[1] = bubbles.outs[1]
      }
      // the eddies: quicker the faster the water runs
      local state = river.state
      local flow = now[s_flow]
      local keep = math.exp(-dt * 6.2832 * (0.5 + 2.2 * flow))
      local push = math.sqrt((1 - keep * keep) * 3) * 1.118
      local ease = 1 - keep * keep * keep * keep
      for(local k = 0; k < 4; k = k + 1){
        local r = rough[k] * keep + random() * push
        rough[k] = r
        local e = eddy[k] + (r - eddy[k]) * ease
        eddy[k] = e
        local depth = if(k == 0 or k == 2){ WASH } else { HISS }
        state[river_eddies[k]] = math.max(1 + depth * e, 0.15)
      }
      state[river_river] = bed
      state[river_flow] = flow
      state[river_dull] = now[s_dull]
      river.inst:compute(n, ins, river.outs)
      to_a.left = now[s_a_left] * LEVEL
      to_a.right = now[s_a_right] * LEVEL
      to_b.left = now[s_b_left] * LEVEL
      to_b.right = now[s_b_right] * LEVEL
      ctx.place(ctx.world, river.outs[0], was_a, to_a, n)
      ctx.place(ctx.world, river.outs[1], was_b, to_b, n)
    },
  }
}

return m
