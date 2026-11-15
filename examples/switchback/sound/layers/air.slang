// sound/layers/air: the air. Two things are heard of it. One is the air
// past the listener, who rides behind the truck (sound/air.dsp): the
// truck's speed against the wind's, next to nothing at a crawl, most of
// what is heard on a fast stretch or into a headwind, and a rumble when
// it blows a gale. The other is the valley's own wind in what it blows
// through around the listener: the open (sound/air/breath.dsp),
// conifers (sound/air/conifer.dsp), leaves and grass
// (sound/air/leaves.dsp), bare heights (sound/air/ridge.dsp). It is what
// is left when the truck stands.
//
// The game says how hard the wind blows and what stands around
// (sound/around: gusts over seconds, the land four times a second).
// Here the air is made to move as air does: a gust reaches the side the
// wind comes from a moment before it reaches the other, and everything
// that sounds has a slow, random turbulence of its own, part of it
// shared with what else is on its side (the voice's weather). A program
// is told the wind's strength where each of its parts is; what that
// sounds like is the program's.
extension "kernel/syntax"
local math = require("slang/math")
local kernel = require("kernel")

local m = {}

// the wind's strength 1 as a speed, m/s: a gale
m.GALE = 20.0
// up to this speed, m/s, the air past the listener is as fast as it is;
// what is over it counts less and less, and all of it never more than
// ROOM (the truck is seldom that fast; the air should not cover the
// engine, and a fall should not roar)
m.KNEE = 22.0
m.ROOM = 6.0

m.params = {
  // the air past the listener: how fast, m/s, and which side it comes
  // from (-1: the left, 1: the right)
  {"air_speed", 0, 0.4},
  {"air_cross", 0, 0.5},
  // the valley's wind: its strength now, gusts and all (0 to 1), and
  // whether it blows toward the listener's left (-1) or right (1)
  {"air_wind", 0, 0.5},
  {"air_drift", 0, 0.6},
  // how much harder it blows in the trees' crowns than down where the
  // listener stands in their shelter (1: as hard)
  {"air_aloft", 1, 1.5},
  // what it blows through here, 0 to 1 each: the open, conifers,
  // broadleaf trees and bushes, grass, bare heights
  {"air_open", 0, 1.5},
  {"air_conifer", 0, 1.5},
  {"air_broadleaf", 0, 1.5},
  {"air_grass", 0, 1.5},
  {"air_ridge", 0, 1.5},
  // how much on the truck whistles, 0 to 1
  {"air_rack", 0.35, 0},
}

// ------------------------------------------------------------ the game's side

func m.watcher(){
  return {}
}

// watch(w, s, set, send): a frame (s: sound/director's Frame)
func m.watch(w, s, set, send){
  local a = s.around
  if(a == null or s.view == null){
    return
  }
  local wind = a.wind
  local right = s.view.right
  // the air past the listener: the truck's velocity (the listener rides
  // with it) against the wind's
  local rx = -wind.x * wind.strength * m.GALE
  local ry = 0
  local rz = -wind.z * wind.strength * m.GALE
  if(s.car != null){
    local v = s.car.velocity
    rx = rx + v.x
    ry = v.y
    rz = rz + v.z
  }
  local speed = math.sqrt(rx * rx + ry * ry + rz * rz)
  local over = math.max(speed - m.KNEE, 0)
  set("air_speed", speed - over + over / (1 + over / m.ROOM))
  // (it comes from where the listener moves to through it; slow air has
  // no side)
  set("air_cross", (rx * right.x + rz * right.z) / math.max(speed, 3))
  set("air_wind", wind.strength)
  set("air_drift", wind.x * right.x + wind.z * right.z)
  // what stands in the wind: bushes rustle as broadleaf trees do, half as
  // much; under trees the grass is out of the wind; the heights moan
  // where nothing shelters them
  local trees = a.trees
  local broadleaf = math.min(trees.broadleaf + 0.5 * trees.bush, 1)
  local wooded = math.min(trees.conifer + broadleaf, 1)
  // (sound/around takes six tenths of the wind off in full shelter: the
  // crowns have none of the shelter the trees themselves give)
  local sheltering = math.min(
    (trees.conifer + trees.broadleaf) * 0.45,
    a.shelter,
  )
  set("air_aloft", 1 / (1 - 0.6 * sheltering))
  // (the open is everywhere, less so in a wood; and up high there is
  // less and less for the wind to blow through)
  set("air_open", (1 - 0.35 * a.shelter) * (1 - 0.55 * a.alpine))
  set("air_conifer", trees.conifer)
  set("air_broadleaf", broadleaf)
  set("air_grass", a.cover.grass * (1 - 0.6 * wooded))
  set("air_ridge", a.alpine * (1 - a.shelter))
  // a load on the roof and a light bar sing in the air; a bare truck
  // hardly does
  local rack = 0.35
  if(s.setup != null){
    if(s.setup.roof != null and s.setup.roof != "none"){
      rack = rack + 0.35
    }
    if(s.setup.light_bar != null and s.setup.light_bar != "none"){
      rack = rack + 0.3
    }
  }
  set("air_rack", rack)
}

// ------------------------------------------------------------ the mixer's side

// The air's level in the mix. At 1 the programs are as loud as the
// sound's plan has them (a moderate day in the valley -43 dB re full
// scale on the world's bus, the air past the listener at 60 km/h -38);
// the user turned the truck down by ear, and the air with it: it is a
// bed under the truck, there when the engine idles.
local LEVEL = 0.5

// below these nothing is heard: wind (its strength) and air past the
// listener (m/s). Air slower than FAINT is 60 dB and more under full
// scale; from there down it is taken to be fainter still than it is,
// down to nothing at SLOWEST, where it is no longer computed.
local CALM = 0.004
local SLOWEST = 5.5
local FAINT = 7.5
// how long a gust takes from one side of the listener to the other, s
local CROSSING = 1.2
// how much louder the side the air comes from is (as a share of its speed)
local LEAN = 0.08
// how much the air past the listener varies (the turbulence, as a share
// of its speed)
local GUSTY = 0.13

// The weather: slow random signals about 0 (their spread 1), one for
// everything that swells by itself. Which is whose, and how slow each is
// (the time it remembers, s: 0.25 is quick as grass, 1.1 slow as a whole
// hillside):
local SIDES = 0 // shared by everything on the left, on the right
local AERO = 2 // the air past the listener: both ears', the left's, the right's
local BREATH = 5 // the open: how loud left, how bright left, the same right
local CONIFER = 9 // the needles left, their tops left, the same right
local LEAVES = 13 // the leaves left and right, the grass left and right
local RIDGE = 17 // the heights: low left, high left, low right, high right
local SLOW = {
  1.1,
  1.1,
  0.8,
  0.6,
  0.6,
  0.9,
  0.6,
  0.9,
  0.6,
  0.9,
  0.6,
  0.9,
  0.6,
  0.45,
  0.45,
  0.25,
  0.25,
  0.8,
  0.5,
  0.8,
  0.5,
}

// The programs' parts, each a control that is the wind's strength
// somewhere: {program, label, the side it is on (0 left, 1 right), how
// much turbulence it has, which of the weather's signals is its own, and
// 1 if it is up in the trees' crowns}
local PARTS = {
  {"breath", "left_low", 0, 0.3, BREATH},
  {"breath", "left_high", 0, 0.35, BREATH + 1},
  {"breath", "right_low", 1, 0.3, BREATH + 2},
  {"breath", "right_high", 1, 0.35, BREATH + 3},
  {"conifer", "needles_left", 0, 0.3, CONIFER, 1},
  {"conifer", "tops_left", 0, 0.35, CONIFER + 1, 1},
  {"conifer", "needles_right", 1, 0.3, CONIFER + 2, 1},
  {"conifer", "tops_right", 1, 0.35, CONIFER + 3, 1},
  {"leaves", "leaves_left", 0, 0.4, LEAVES, 1},
  {"leaves", "leaves_right", 1, 0.4, LEAVES + 1, 1},
  {"leaves", "blades_left", 0, 0.5, LEAVES + 2},
  {"leaves", "blades_right", 1, 0.5, LEAVES + 3},
  {"ridge", "left_low", 0, 0.3, RIDGE},
  {"ridge", "left_high", 0, 0.35, RIDGE + 1},
  {"ridge", "right_low", 1, 0.3, RIDGE + 2},
  {"ridge", "right_high", 1, 0.35, RIDGE + 3},
}

kernel {
  // where the weather's noise is in its sequence
  local seed = 20261114

  // stir: the weather a block on. Each of the n signals is noise that
  // forgets itself in its time (an Ornstein-Uhlenbeck process: most of
  // its movement is slower than 1 / (2 pi time) Hz), smoothed once more
  // so that nothing in it is quick: value is what it is now, rough the
  // noise behind it, keep, push and ease how much of each a block keeps,
  // adds and lets through.
  func stir(
    value: double[], rough: double[], keep: double[], push: double[],
    ease: double[], n: int
  ){
    for(local i = 0; i < n; i += 1){
      seed = (seed * 69069 + 12345) & 4294967295
      local r = rough[i] * keep[i] +
        (float(seed) / 2147483648.0 - 1.0) * push[i]
      rough[i] = r
      value[i] = value[i] + (r - value[i]) * ease[i]
    }
  }

  // winds: the wind's strength at each of the n parts, into out: what
  // its side has of the gust (left, right; lift times more up in the
  // crowns), and its turbulence: six tenths its side's, eight its own
  func winds(
    out: double[], value: double[], side: int32[], own: int32[],
    depth: double[], crown: double[], left: float, right: float, lift: float,
    n: int
  ){
    for(local i = 0; i < n; i += 1){
      local s = side[i]
      local u = select(s == 0, left, right) * (1.0 + crown[i] * lift) *
        (1.0 + depth[i] * (0.6 * value[s] + 0.8 * value[own[i]]))
      out[i] = clamp(u, 0.0, 1.5)
    }
  }
}

// voice(ctx) -> {block}: see sound/mixer
func m.voice(ctx){
  local rate = ctx.rate
  local size = ctx.size
  local now = ctx.now
  local slot = ctx.slot
  // a program as it runs here: its instance, its pair of outputs, and
  // where its parts are among PARTS (the fields their strengths go to)
  local func wired(name, program){
    local inst = program:new({sample_rate: rate})
    local p = {
      program: program,
      inst: inst,
      state: inst.state,
      first: 0,
      count: 0,
      fields: {},
      ins: {kernel.float:array(1), kernel.float:array(1)},
      outs: {kernel.float:array(size), kernel.float:array(size)},
    }
    for(local i = 0; i < len(PARTS); i = i + 1){
      if(PARTS[i][0] == name){
        if(p.count == 0){
          p.first = i
        }
        p.count = p.count + 1
        append(p.fields, program.by_label[PARTS[i][1]].field)
      }
    }
    return p
  }
  local aero = wired("aero", require("sound/air"))
  local breath = wired("breath", require("sound/air/breath"))
  local conifer = wired("conifer", require("sound/air/conifer"))
  local leaves = wired("leaves", require("sound/air/leaves"))
  local ridge = wired("ridge", require("sound/air/ridge"))
  local aero_left = aero.program.by_label.left.field
  local aero_right = aero.program.by_label.right.field
  local aero_rack = aero.program.by_label.rack.field
  local breath_open = breath.program.by_label.open.field
  local conifer_conifer = conifer.program.by_label.conifer.field
  local leaves_broadleaf = leaves.program.by_label.broadleaf.field
  local leaves_grass = leaves.program.by_label.grass.field
  local ridge_ridge = ridge.program.by_label.ridge.field
  local s_speed = slot.air_speed
  local s_cross = slot.air_cross
  local s_wind = slot.air_wind
  local s_drift = slot.air_drift
  local s_aloft = slot.air_aloft
  local s_open = slot.air_open
  local s_conifer = slot.air_conifer
  local s_broadleaf = slot.air_broadleaf
  local s_grass = slot.air_grass
  local s_ridge = slot.air_ridge
  local s_rack = slot.air_rack
  // the weather
  local signals = len(SLOW)
  local value = kernel.double:array(signals)
  local rough = kernel.double:array(signals)
  local keep = kernel.double:array(signals)
  local push = kernel.double:array(signals)
  local ease = kernel.double:array(signals)
  local stirred_for = 0
  // the parts
  local parts = len(PARTS)
  local part_side = kernel.int32:array(parts)
  local part_own = kernel.int32:array(parts)
  local part_depth = kernel.double:array(parts)
  local part_crown = kernel.double:array(parts)
  local strength = kernel.double:array(parts)
  for(local i = 0; i < parts; i = i + 1){
    part_side[i] = PARTS[i][2]
    part_depth[i] = PARTS[i][3]
    part_own[i] = PARTS[i][4]
    part_crown[i] = PARTS[i][5] or 0
  }
  // the wind's strength over the last seconds, a block apart: what each
  // side has of a gust is what the listener had a moment ago
  local MASK = 1023
  local gusts = kernel.double:array(MASK + 1)
  local head = 0
  local func reached(ago){
    ago = math.min(ago, MASK - 1)
    local whole = to_int(ago)
    local a = gusts[(head - whole) & MASK]
    local b = gusts[(head - whole - 1) & MASK]
    return a + (b - a) * (ago - whole)
  }
  // the programs add to a pair one after the other: what the last one
  // that ran put out
  local silent = {kernel.float:array(size), kernel.float:array(size)}
  local chain = {left: silent[0], right: silent[1], any: false}
  // run(p, n): the program p told the wind where each of its parts is,
  // and n frames of it added to the pair
  local func run(p, n){
    local state = p.state
    local fields = p.fields
    local first = p.first
    for(local i = 0; i < p.count; i = i + 1){
      state[fields[i]] = strength[first + i]
    }
    p.ins[0] = chain.left
    p.ins[1] = chain.right
    p.inst:compute(n, p.ins, p.outs)
    chain.left = p.outs[0]
    chain.right = p.outs[1]
    chain.any = true
  }
  local was_left = {left: 0, right: 0}
  local was_right = {left: 0, right: 0}
  local to_left = {left: LEVEL, right: 0}
  local to_right = {left: 0, right: LEVEL}
  return {
    block: func(n){
      local wind = now[s_wind]
      local speed = now[s_speed]
      // (still air and a truck at a crawl: nothing to compute)
      if(wind < CALM and speed < SLOWEST){
        return
      }
      local dt = n / rate
      if(dt != stirred_for){
        stirred_for = dt
        for(local i = 0; i < signals; i = i + 1){
          local e = math.exp(-dt / SLOW[i])
          keep[i] = e
          // (noise from -1 to 1 has the spread 1 / sqrt(3); the
          // smoothing takes a tenth of what is left)
          push[i] = math.sqrt((1 - e * e) * 3) * 1.118
          ease[i] = 1 - math.exp(-dt * 4 / SLOW[i])
        }
      }
      stir(value, rough, keep, push, ease, signals)
      chain.left = silent[0]
      chain.right = silent[1]
      chain.any = false
      if(speed >= SLOWEST){
        // (faint air fades out: as if it were slower than it is, by so
        // much that its loudness, which goes with its speed to the power
        // of two and a half, falls evenly to nothing)
        if(speed < FAINT){
          local fade = math.max((speed - SLOWEST) / (FAINT - SLOWEST), 0.0001)
          speed = speed * math.exp(0.4 * math.log(fade))
        }
        // each ear's air: a little faster on the side it comes from,
        // and its turbulence, some of it both ears'
        local cross = now[s_cross]
        local both = 0.6 * value[AERO]
        local state = aero.state
        state[aero_left] = math.max(
          speed * (1 - LEAN * cross) *
            (1 + GUSTY * (both + 0.8 * value[AERO + 1])),
          0,
        )
        state[aero_right] = math.max(
          speed * (1 + LEAN * cross) *
            (1 + GUSTY * (both + 0.8 * value[AERO + 2])),
          0,
        )
        state[aero_rack] = now[s_rack]
        run(aero, n)
      }
      if(wind >= CALM){
        // a gust reaches the side the wind comes from first
        head = (head + 1) & MASK
        gusts[head] = wind
        local drift = now[s_drift]
        winds(
          strength,
          value,
          part_side,
          part_own,
          part_depth,
          part_crown,
          reached(CROSSING * (1 - drift) / 2 / dt),
          reached(CROSSING * (1 + drift) / 2 / dt),
          now[s_aloft] - 1,
          parts,
        )
        if(now[s_open] > 0.01){
          breath.state[breath_open] = now[s_open]
          run(breath, n)
        }
        if(now[s_conifer] > 0.01){
          conifer.state[conifer_conifer] = now[s_conifer]
          run(conifer, n)
        }
        if(now[s_broadleaf] + now[s_grass] > 0.01){
          leaves.state[leaves_broadleaf] = now[s_broadleaf]
          leaves.state[leaves_grass] = now[s_grass]
          run(leaves, n)
        }
        if(now[s_ridge] > 0.01){
          ridge.state[ridge_ridge] = now[s_ridge]
          run(ridge, n)
        }
      }
      if(chain.any){
        ctx.place(ctx.world, chain.left, was_left, to_left, n)
        ctx.place(ctx.world, chain.right, was_right, to_right, n)
      }
    },
  }
}

return m
