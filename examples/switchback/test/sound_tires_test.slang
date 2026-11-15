// The tires' sound without an audio device: what each ground's numbers
// blend to, the rules from a wheel's motion to the programs' controls
// (grit by the meter, not by the second; nothing from a wheel that
// stands), what the game's side makes of a truck (a jolt is a thump,
// water a splash, a tow neither), and the sound itself: silent standing,
// louder with the speed, as many ticks to a meter at any speed, and
// never wild with everything at once.
// Run with `slang test test` in examples/switchback (or make
// switchback-test).
local t = require("slang/test")
local math = require("slang/math")
local str = require("slang/string")
local kernel = require("kernel")
local surfaces = require("game/surfaces")
local drivetrain = require("game/drivetrain")
local params = require("sound/params")
local ground = require("sound/ground")
local tires = require("sound/layers/tires")

local RADIUS = drivetrain.SPEC.wheel_radius
local STANDING = drivetrain.SPEC.mass * 9.81 / 4

// the camera behind the truck
local VIEW = {
  eye: {x: 0, y: 2.5, z: -7.6},
  forward: {x: 0, y: -0.2, z: 0.98},
  right: {x: -1, y: 0, z: 0},
}

// a truck as the layer sees one: standing on a ground at the origin,
// looking along z (its left is +x)
local func truck(surface){
  local wheels = {}
  for(local i = 0; i < 4; i = i + 1){
    local x = if(i % 2 == 0){ 0.8 } else { -0.8 }
    local z = if(i < 2){ 1.36 } else { -1.36 }
    append(wheels, {
      index: i,
      at: {x: x, z: z},
      omega: 0,
      steer: 0,
      length: 0.23,
      contact: true,
      load: STANDING,
      along_speed: 0,
      across_speed: 0,
      surface: surface or surfaces.dirt,
      point: {x: x, y: -RADIUS, z: z},
      wading: 0,
    })
  }
  return {
    wheels: wheels,
    pos: {x: 0, y: 0, z: 0},
    speed: 0,
    forward: {x: 0, y: 0, z: 1},
    up: {x: 0, y: 1, z: 0},
    left: {x: 1, y: 0, z: 0},
  }
}

// every wheel rolling at v m/s, its tread `spin` m/s faster
local func roll(car, v, spin){
  for(let local w in values(car.wheels)){
    w.along_speed = v
    w.omega = (v + (spin or 0)) / RADIUS
  }
}

// The layer at work without the mixer: its watcher writes the
// parameters straight to where its voice reads them, its voice adds to a
// bus of its own. frame(car) is a frame of the game, block() 128 samples
// (returned: the bus's left side), sent the events so far.
local func rig(){
  local layout = params.layout()
  local now = kernel.double:array(layout.count)
  for(local i = 0; i < layout.count; i = i + 1){
    now[i] = layout.list[i][1]
  }
  local bus = {left: kernel.float:array(128), right: kernel.float:array(128)}
  local ctx = {
    rate: 48000,
    size: 128,
    now: now,
    slot: layout.slot,
    truck: bus,
    world: bus,
    interface: bus,
    place: func(to, source, was, gains, n){
      for(local i = 0; i < n; i = i + 1){
        to.left[i] = to.left[i] + source[i] * gains.left
        to.right[i] = to.right[i] + source[i] * gains.right
      }
      was.left = gains.left
      was.right = gains.right
    },
  }
  local voice = tires.voice(ctx)
  local state = tires.watcher()
  local r = {sent: {}, now: now, slot: layout.slot}
  local set = func(name, value){
    now[layout.slot[name]] = value
  }
  local send = func(kind, a, b, c){
    append(r.sent, {kind: kind, wheel: a, strength: b})
    voice.on(kind, a, b or 0, c or 0)
  }
  r.frame = func(car){
    tires.watch(state, {car: car, view: VIEW, dt: 1 / 60}, set, send)
  }
  r.get = func(name){
    return now[layout.slot[name]]
  }
  r.block = func(){
    bus.left:fill(0.0)
    bus.right:fill(0.0)
    voice.block(128)
    return bus.left
  }
  return r
}

// the loudest sample and the level (rms) of `blocks` blocks of a rig; a
// NaN fails the test
local func heard(r, blocks){
  local peak = 0.0
  local sum = 0.0
  for(local b = 0; b < blocks; b = b + 1){
    local out = r.block()
    for(local i = 0; i < 128; i = i + 1){
      local v = out[i]
      assert(not math.is_nan(v), "NaN")
      peak = math.max(peak, math.abs(v))
      sum = sum + v * v
    }
  }
  return {peak: peak, rms: math.sqrt(sum / (blocks * 128))}
}

// a wheel's motion for the rules, standing; `changes` says what it does
local func motion(changes){
  local w = {
    contact: true,
    roll: 0,
    pass: 0,
    crush: 0,
    slide: 0,
    load: 1,
    scrub: 0,
    depth: 0,
    flow: 0,
    wet: 0,
    spray: 0,
    waver: 0.6,
  }
  for(let local e in entries(changes or {})){
    w[e[0]] = e[1]
  }
  return w
}

local func ground_of(surface){
  return ground.set(ground.material(), surface)
}

t.group("the grounds"){
  t.test("every surface of the game has every number"){
    for(let local surface in values(surfaces.list)){
      local g = ground.of(surface.name)
      assert(g != null, surface.name)
      for(let local number in values(ground.NUMBERS)){
        assert(
          type(g[number.name]) != "null",
          concat(surface.name, " ", number.name),
        )
      }
      assert(
        g.grain > 0 and g.fine > 0 and g.tick_pitch > 0 and g.tick_ring > 0 and
          g.damp > 0,
      )
    }
  }
  t.test("one surface alone is itself; two blend, levels by their shares"){
    local g = ground_of(surfaces.gravel)
    assert(g.grit == ground.of("gravel").grit)
    assert(math.abs(g.tick_pitch - ground.of("gravel").tick_pitch) < 0.001)
    local both = ground.material()
    both.shares[surfaces.gravel.index] = 0.5
    both.shares[surfaces.grass.index] = 0.5
    ground.blend(both)
    local want = (ground.of("gravel").grit + ground.of("grass").grit) / 2
    assert(math.abs(both.grit - want) < 0.001, string(both.grit))
    assert(both.rumble > ground.of("grass").rumble and both.rumble < ground.of(
          "gravel",
        ).rumble)
  }
  t.test("a tone blends toward the ground that makes more of the sound"){
    // (half gravel, half grass ticks nearly as gravel does: grass has
    // next to no grit to tick with)
    local both = ground.material()
    both.shares[surfaces.gravel.index] = 0.5
    both.shares[surfaces.grass.index] = 0.5
    ground.blend(both)
    local gravel = ground.of("gravel").tick_pitch
    local grass = ground.of("grass").tick_pitch
    assert(
      math.abs(both.tick_pitch - gravel) < math.abs(gravel - grass) * 0.1,
      string(both.tick_pitch),
    )
  }
  t.test(
    "without a land the ground is the wheel's own surface, the river's bed in water",
  ){
    local wheel = truck(surfaces.snow).wheels[0]
    local g = ground.under(null, wheel, ground.material(), 0)
    assert(g.shares[surfaces.snow.index] == 1 and g.squeak == ground.of(
          "snow",
        ).squeak)
    g = ground.under(null, wheel, ground.material(), 0.3)
    assert(g.shares[surfaces.riverbed.index] == 1)
  }
}

t.group("the tires' rules"){
  t.test("a wheel that stands asks for nothing"){
    local c = tires.controls({}, ground_of(surfaces.gravel), motion())
    for(let local name in values({
      "shake",
      "slap",
      "groan",
      "ticks",
      "knocks",
      "gritty",
      "knocking",
      "swish",
      "peel",
      "rasp",
      "squeal",
      "rush",
      "drops",
      "bubbles",
    })){
      assert(c[name] == 0, concat(name, " ", string(c[name])))
    }
  }
  t.test("grit comes by the meter: twice as fast, twice as many a second"){
    local g = ground_of(surfaces.gravel)
    local slow = tires.controls({}, g, motion({roll: 1, pass: 1, crush: 1}))
    local slow_rate = slow.ticks + slow.knocks
    local fast = tires.controls({}, g, motion({roll: 2, pass: 2, crush: 2}))
    assert(
      math.abs(slow_rate - ground.of("gravel").grit) < 0.001,
      string(slow_rate),
    )
    assert(math.abs(fast.ticks + fast.knocks - 2 * slow_rate) < 0.001)
  }
  t.test(
    "rolling faster is louder, and its lumps come faster; a heavier wheel is louder",
  ){
    local g = ground_of(surfaces.rock)
    local slow = tires.controls({}, g, motion({roll: 3, pass: 3, crush: 3}))
    local fast = tires.controls({}, g, motion({roll: 12, pass: 12, crush: 12}))
    assert(fast.shake > slow.shake * 3 and fast.slap > slow.slap * 3)
    assert(math.abs(fast.lumps - 4 * slow.lumps) < 0.001)
    local heavy = tires.controls({}, g, motion({
      roll: 3, pass: 3, crush: 3, load: 2
    }))
    assert(heavy.shake > slow.shake * 1.3)
    local light = tires.controls({}, g, motion({
      roll: 3, pass: 3, crush: 3, load: 0, contact: false
    }))
    // (in the air: nothing of the ground, the tread's whir)
    assert(
      light.shake == 0 and light.gritty == 0 and light.slap > 0 and
        light.slap < slow.slap * 0.2,
    )
  }
  t.test(
    "a sliding tire tears at the ground; on rock it squeals, on sand it does not",
  ){
    local rock = ground_of(surfaces.rock)
    local sand = ground_of(surfaces.sand)
    local rolling = tires.controls({}, rock, motion({
      roll: 5, pass: 5, crush: 5
    }))
    assert(rolling.rasp == 0 and rolling.squeal == 0)
    local sliding = tires.controls({}, rock, motion({
      roll: 5, pass: 5, crush: 8, slide: 3
    }))
    assert(sliding.rasp > 0 and sliding.squeal > 0)
    assert(tires.controls({}, sand, motion({
      roll: 5, pass: 5, crush: 8, slide: 3
    })).squeal == 0)
    // (the harder it slides, the narrower the squeal)
    local harder = tires.controls({}, rock, motion({
      roll: 5, pass: 5, crush: 13, slide: 8
    }))
    assert(harder.squeal_damped < sliding.squeal_damped)
  }
  t.test(
    "a wheel spinning on the spot rolls over no lumps, but throws what it digs out",
  ){
    local g = ground_of(surfaces.gravel)
    local c = tires.controls({}, g, motion({
      roll: 10, pass: 0, crush: 10, slide: 10
    }))
    assert(c.shake == 0 and c.lumps == 0)
    assert(c.rasp > 0 and c.knocks > 0 and c.knocking > 0)
    // (what it throws sounds as the ground says: the second voice went over)
    assert(math.abs(c.knock_pitch - ground.of("gravel").knock_pitch) < 1)
  }
  t.test("water: nothing dry, a rush by the speed in it"){
    local g = ground_of(surfaces.riverbed)
    local dry = tires.controls({}, g, motion({
      roll: 5, pass: 5, crush: 5, flow: 5
    }))
    assert(dry.rush == 0 and dry.drops == 0 and dry.bubbles == 0)
    local slow = tires.controls({}, g, motion({
      roll: 2, pass: 2, crush: 2, flow: 2, depth: 0.3
    }))
    local fast = tires.controls({}, g, motion({
      roll: 6, pass: 6, crush: 6, flow: 6, depth: 0.3
    }))
    assert(
      slow.rush > 0 and fast.rush > slow.rush * 2 and
        fast.rush_pitch > slow.rush_pitch,
    )
  }
}

t.group("the tires in the game"){
  t.test("a truck that stands sets nothing off; one that rolls is told of"){
    local r = rig()
    local car = truck(surfaces.dirt)
    r.frame(car)
    r.frame(car)
    for(local i = 0; i < 4; i = i + 1){
      local name = concat("tire", string(i))
      assert(r.get(concat(name, "_awake")) == 0 and r.get(
          concat(name, "_shake"),
        ) == 0)
      assert(r.get(concat(name, "_ticks")) == 0)
    }
    assert(len(r.sent) == 0)
    roll(car, 5, 0)
    r.frame(car)
    assert(r.get("tire2_awake") == 1 and r.get("tire2_speed") == 5)
    assert(math.abs(r.get("tire2_ticks") + r.get("tire2_knocks") - ground.of(
        "dirt",
      ).grit * 4.97) < 0.01)
    assert(r.get("tire2_shake") > 0 and r.get("tire2_rasp") == 0)
    // spinning: the tread 4 m/s faster than the ground
    roll(car, 5, 4)
    r.frame(car)
    assert(r.get("tire2_speed") == 9 and r.get("tire2_rasp") > 0)
  }
  t.test("each wheel is heard from its side, the rear ones nearer"){
    local r = rig()
    local car = truck(surfaces.dirt)
    r.frame(car)
    // (wheels 0 and 2 are on the truck's left)
    assert(
      r.get("tire0_left") > r.get("tire0_right") and
        r.get("tire2_left") > r.get("tire2_right"),
    )
    assert(
      r.get("tire1_right") > r.get("tire1_left") and
        r.get("tire3_right") > r.get("tire3_left"),
    )
    assert(r.get("tire2_left") > r.get("tire0_left"))
  }
  t.test("a jolt of the suspension is a thump of that wheel; a tow is none"){
    local r = rig()
    local car = truck(surfaces.rock)
    r.frame(car)
    r.frame(car)
    // the front left pushed in by 15 mm in a frame: 0.9 m/s
    car.wheels[0].length = 0.215
    r.frame(car)
    assert(len(
      r.sent,
    ) == 1 and r.sent[0].kind == tires.THUMP and r.sent[0].wheel == 0)
    assert(r.sent[0].strength > 0.5 and r.sent[0].strength <= 2)
    assert(r.get("tire0_awake") == 1 and r.get("tire1_awake") == 0)
    // set down somewhere else, its suspension let out: nothing
    car.pos = {x: 300, y: 4, z: -120}
    for(let local w in values(car.wheels)){
      w.length = 0.1
    }
    r.frame(car)
    assert(len(r.sent) == 1)
  }
  t.test(
    "a wheel driven into water splashes, by how fast; crept in it does not",
  ){
    local r = rig()
    local car = truck(surfaces.sand)
    roll(car, 6, 0)
    r.frame(car)
    car.wheels[1].wading = 0.2
    r.frame(car)
    assert(len(
      r.sent,
    ) == 1 and r.sent[0].kind == tires.SPLASH and r.sent[0].wheel == 1)
    assert(r.sent[0].strength > 0.9)
    assert(r.get("wade0_awake") == 1 and r.get("wade1_awake") == 0)
    assert(r.get("wade0_rush") > 0 and r.get("wade0_drops") > 0)
    local slow = rig()
    local other = truck(surfaces.sand)
    roll(other, 0.5, 0)
    slow.frame(other)
    other.wheels[1].wading = 0.2
    slow.frame(other)
    assert(len(slow.sent) == 0 and slow.get("wade0_awake") == 1)
  }
  t.test(
    "the front wheels turned where the truck stands groan; rolling they do not",
  ){
    local r = rig()
    local car = truck(surfaces.rock)
    r.frame(car)
    car.wheels[0].steer = 0.04
    car.wheels[1].steer = 0.04
    r.frame(car)
    assert(r.get("tire0_groan") > 0 and r.get("tire2_groan") == 0)
    local standing = r.get("tire0_groan")
    roll(car, 6, 0)
    car.wheels[0].steer = 0.08
    r.frame(car)
    assert(r.get("tire0_groan") < standing * 0.1)
  }
}

t.group("the tires' sound"){
  t.test("the programs fit the kernel's registers"){
    for(let local name in values({
      "sound/tire", "sound/tire/ground", "sound/tire/water"
    })){
      local source = require(name).source
      assert(
        not str.contains(source, "tmp["),
        concat(name, " keeps its temporaries in memory"),
      )
      assert(
        not str.contains(source, "d.c"),
        concat(name, " keeps its block values in memory"),
      )
    }
  }
  t.test("a truck that stands is silent; rolling it sounds, louder the faster"){
    local r = rig()
    local car = truck(surfaces.gravel)
    r.frame(car)
    assert(heard(r, 8).peak == 0)
    roll(car, 3, 0)
    r.frame(car)
    heard(r, 30)
    local slow = heard(r, 40)
    roll(car, 12, 0)
    r.frame(car)
    heard(r, 30)
    local fast = heard(r, 40)
    assert(slow.rms > 0.0005, string(slow.rms))
    assert(
      fast.rms > slow.rms * 2,
      concat(string(slow.rms), " ", string(fast.rms)),
    )
    // and it ends: the truck stands again, and after a moment there is
    // nothing at all
    roll(car, 0, 0)
    for(local i = 0; i < 30; i = i + 1){
      r.frame(car)
    }
    heard(r, 600)
    assert(heard(r, 8).peak == 0)
  }
  t.test("as many ticks to a meter at a walk as at twice a walk"){
    // the ground's program alone, its ticks hard, short and all alike:
    // 20 a second for 3 s and 40 a second for 1.5 s are the same stretch
    // of ground
    local program = require("sound/tire/ground")
    local func ticks(rate, seconds){
      local v = program:new({sample_rate: 48000})
      v.ticks = rate
      v.tick_pitch = 3000
      v.tick_damped = 0.3
      v.tick_fade = 4000
      v.tick_even = 4
      v.gritty = 1
      local silence = kernel.float:array(128)
      local out = kernel.float:array(128)
      local count = 0
      local quiet = 1000
      for(local b = 0; b < to_int(seconds * 375); b = b + 1){
        v:compute(128, {silence}, {out})
        for(local i = 0; i < 128; i = i + 1){
          local x = math.abs(out[i])
          assert(not math.is_nan(x), "NaN")
          if(x > 0.15){
            // (a new one after 2 ms of quiet)
            if(quiet > 96){
              count = count + 1
            }
            quiet = 0
          } else if(x < 0.05){
            quiet = quiet + 1
          }
        }
      }
      return count
    }
    local slow = ticks(20, 3)
    local fast = ticks(40, 1.5)
    assert(slow > 36 and slow < 84, string(slow))
    assert(fast > 36 and fast < 84, string(fast))
  }
  t.test("with everything at once it is never wild"){
    local r = rig()
    local car = truck(surfaces.gravel)
    roll(car, 15, 10)
    for(let local w in values(car.wheels)){
      w.load = STANDING * 2.5
      w.across_speed = 3
    }
    r.frame(car)
    // all four into the water, and hit hard
    for(let local w in values(car.wheels)){
      w.wading = 0.4
      w.length = 0.19
    }
    r.frame(car)
    assert(len(r.sent) == 8)
    local m = heard(r, 120)
    assert(
      m.rms > 0.01 and m.peak < 1.5,
      concat(string(m.rms), " ", string(m.peak)),
    )
  }
}
