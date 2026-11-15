// The water without an audio device: what the game's side makes of the
// river and the lake around the listener (sound/layers/water's watch:
// quieter and duller with distance, silent far away, on the side the
// water lies, wide when the listener stands in it; the lake only at its
// shore), and the layer as the mixer runs it: silent with no water in
// earshot, a river louder from near than from far, never wild.
// Run with `slang test test` in examples/switchback (or make
// switchback-test).
local t = require("slang/test")
local math = require("slang/math")
local kernel = require("kernel")
local params = require("sound/params")
local around = require("sound/around")
local water = require("sound/layers/water")

// a listener looking along z (to its right is -x), with the water as
// the test says: {distance, x, z, flow, lake}
local func frame(change){
  local a = around.new()
  a.water.distance = 1000
  if(change != null){
    change(a.water)
  }
  return {
    around: a,
    view: {
      eye: {x: 0, y: 2.5, z: 0},
      forward: {x: 0, y: 0, z: 1},
      right: {x: -1, y: 0, z: 0},
    },
    dt: 1 / 60,
  }
}

// what the layer's watch says of a frame
local func watched(s){
  local got = {}
  water.watch(water.watcher(), s, func(name, value){ got[name] = value }, null)
  return got
}

// a river running along z at the distance d ahead: where sound/around
// has it
local func river(d, flow){
  return watched(frame(func(w){
    w.distance = d
    w.x = 0
    w.z = 1
    w.flow = flow or 0.6
    w.lake = 0
  }))
}

// the layer's voice with what a frame's watch says, run for some blocks:
// the level (rms) and the loudest sample of each side of the world's
// bus over the blocks from `from` on
local func heard(got, blocks, from){
  local layout = params.layout()
  local now = kernel.double:array(layout.count)
  for(local i = 0; i < layout.count; i = i + 1){
    now[i] = layout.list[i][1]
  }
  for(let local e in entries(got)){
    now[layout.slot[e[0]]] = e[1]
  }
  local world = {left: kernel.float:array(128), right: kernel.float:array(128)}
  local voice = water.voice({
    rate: 48000,
    size: 128,
    now: now,
    slot: layout.slot,
    world: world,
    place: func(bus, source, was, to, n){
      for(local i = 0; i < n; i = i + 1){
        bus.left[i] = bus.left[i] + source[i] * to.left
        bus.right[i] = bus.right[i] + source[i] * to.right
      }
      was.left = to.left
      was.right = to.right
    },
  })
  local sums = {0.0, 0.0}
  local peak = 0.0
  local count = 0
  for(local b = 0; b < blocks; b = b + 1){
    for(local i = 0; i < 128; i = i + 1){
      world.left[i] = 0
      world.right[i] = 0
    }
    voice.block(128)
    if(b >= from){
      for(local i = 0; i < 128; i = i + 1){
        local l = world.left[i]
        local r = world.right[i]
        assert(not math.is_nan(l) and not math.is_nan(r), "NaN")
        sums[0] = sums[0] + l * l
        sums[1] = sums[1] + r * r
        peak = math.max(peak, math.max(math.abs(l), math.abs(r)))
      }
      count = count + 128
    }
  }
  return {
    left: math.sqrt(sums[0] / count),
    right: math.sqrt(sums[1] / count),
    peak: peak,
  }
}

t.group("the water in the game"){
  t.test("no water in earshot: nothing"){
    local got = watched(frame())
    assert(
      got.water_river == 0 and got.water_lake == 0 and got.water_bubbles == 0,
    )
    got = river(water.REACH + 20)
    assert(got.water_river == 0 and got.water_bubbles == 0)
  }
  t.test(
    "a river is quieter and duller the further it is, its bubbles lost first",
  ){
    local near = river(2)
    local mid = river(10)
    local far = river(50)
    assert(math.abs(mid.water_river - 1) < 0.01, string(mid.water_river))
    assert(near.water_river > 1.5 and near.water_river < 2.5)
    // (11 dB under at fifty meters)
    assert(
      far.water_river > 0.2 and far.water_river < 0.35,
      string(far.water_river),
    )
    assert(
      near.water_dull > mid.water_dull and mid.water_dull > far.water_dull * 2,
    )
    assert(far.water_dull < 1200)
    assert(
      near.water_bubbles > 0.9 and mid.water_bubbles > 0.4 and
        mid.water_bubbles < 0.6,
    )
    assert(far.water_bubbles < 0.05)
    assert(mid.water_rate > 40 and mid.water_lake == 0)
  }
  t.test("it lies where it is: ahead in the middle, to the right on the right"){
    local ahead = river(30)
    local left = ahead.water_a_left + ahead.water_b_left
    local right = ahead.water_a_right + ahead.water_b_right
    assert(math.abs(left - right) < 0.001)
    // (its two halves stand apart: one more on each side)
    assert(
      ahead.water_a_left > ahead.water_a_right * 1.5 and
        ahead.water_b_right > ahead.water_b_left * 1.5,
    )
    // to the listener's right is -x
    local beside = watched(frame(func(w){
      w.distance = 30
      w.x = -1
      w.z = 0
      w.flow = 0.6
    }))
    assert(
      beside.water_a_right > beside.water_a_left and
        beside.water_b_right > beside.water_b_left,
    )
  }
  t.test("standing in it, it is on both sides whichever way it lies"){
    local got = watched(frame(func(w){
      w.distance = 0
      w.x = -1
      w.z = 0
      w.flow = 0.6
    }))
    assert(
      got.water_a_left > got.water_a_right * 4 and
        got.water_b_right > got.water_b_left * 4,
    )
  }
  t.test("the lake is heard at its shore only, and has no river's rush"){
    local func lake(d){
      return watched(frame(func(w){
        w.distance = d
        w.lake = 1
        w.flow = 0
      }))
    }
    local shore = lake(3)
    assert(
      shore.water_lake == 1 and shore.water_river == 0 and
        shore.water_still == 1,
    )
    assert(
      shore.water_bubbles > 0.5 and shore.water_rate < 5 and
        shore.water_high < 1500,
    )
    assert(lake(20).water_lake < 0.8 and lake(20).water_lake > 0.3)
    local away = lake(water.SHORE + 5)
    assert(away.water_lake == 0 and away.water_bubbles == 0)
  }
  t.test("the river is the line through its points, not the points"){
    // a river along z at x = 20, a point every 22 m, 4 m wide; the
    // listener stands between two of its points
    local points = {}
    for(local i = 0; i < 8; i = i + 1){
      append(points, {x: 20, z: 77 - i * 22, level: 30 - i * 0.4, half: 2})
    }
    local s = frame()
    s.world = {land: {river: {points: points, lake: null}}}
    local w = water.watcher()
    water.watch(w, s, func(name, value){}, null)
    // (18 m to its bank, straight to the side: at a point it would be
    // 11 m further up or down)
    assert(math.abs(w.near.distance - 18) < 0.01, string(w.near.distance))
    assert(math.abs(w.near.x - 1) < 0.001 and math.abs(w.near.z) < 0.001)
    assert(w.near.still == 0 and w.near.flow > 0.5)
  }
}

t.group("the water as it sounds"){
  t.test("with no water in earshot there is nothing"){
    local quiet = heard(watched(frame()), 4, 0)
    assert(quiet.left == 0 and quiet.right == 0)
  }
  t.test(
    "a river is louder from near than from far, and under full scale in it",
  ){
    local near = heard(river(0), 150, 100)
    local far = heard(river(60), 150, 100)
    assert(near.left > 0.004 and near.right > 0.004, string(near.left))
    assert(
      far.left > 0.00005 and far.left < near.left * 0.2,
      string(far.left / near.left),
    )
    assert(near.peak < 0.5, string(near.peak))
  }
  t.test("the lake's waves come in at its shore"){
    local shore = heard(watched(frame(func(w){
      w.distance = 2
      w.lake = 1
      w.flow = 0
    })), 300, 40)
    assert(
      shore.left > 0.0002 and shore.right > 0.0002 and shore.peak < 0.3,
      string(shore.left),
    )
  }
}
