// The driveline's sound without an audio device: silent while the truck
// stands; the gears' tone where the teeth and the shaft's speed put it,
// louder under load, the transfer case's tones with it in low range;
// what happens once (the slack, the levers, the lockers, the hand brake)
// sent as the drivetrain's state changes, each heard and gone again; the
// brakes' squeak only at the end of some stops.
// Run with `slang test test` in examples/switchback (or make
// switchback-test).
local t = require("slang/test")
local math = require("slang/math")
local kernel = require("kernel")
local drivetrain = require("game/drivetrain")
local params = require("sound/params")
local driveline = require("sound/layers/driveline")

local RATE = 48000
local BLOCK = 128

// The layer's voice by itself, as the mixer runs it (without the place
// and the master after it): {set(name, value): a parameter, at once;
// send(kind, a, b): an event; run(blocks) -> the truck bus's left channel
// over that many blocks}
local func rig(){
  local layout = params.layout()
  local now = kernel.double:array(layout.count)
  for(local i = 0; i < layout.count; i = i + 1){
    now[i] = layout.list[i][1]
  }
  local func pair(){
    return {left: kernel.float:array(BLOCK), right: kernel.float:array(BLOCK)}
  }
  local ctx = {
    rate: RATE,
    size: BLOCK,
    now: now,
    slot: layout.slot,
    truck: pair(),
    world: pair(),
    interface: pair(),
    place: func(bus, source, was, to, n){
      for(local i = 0; i < n; i = i + 1){
        bus.left[i] = bus.left[i] + source[i] * to.left
        bus.right[i] = bus.right[i] + source[i] * to.right
      }
      was.left = to.left
      was.right = to.right
    },
  }
  local voice = driveline.voice(ctx)
  local func set(name, value){
    now[layout.slot[name]] = value
  }
  for(let local name in values({"mid", "front", "rear"})){
    set(concat("driveline_", name, "_left"), 0.6)
    set(concat("driveline_", name, "_right"), 0.6)
  }
  return {
    set: set,
    send: func(kind, a, b){
      voice.on(kind, a or 0, b or 0, 0)
    },
    run: func(blocks){
      local heard = kernel.float:array(blocks * BLOCK)
      for(local b = 0; b < blocks; b = b + 1){
        for(local i = 0; i < BLOCK; i = i + 1){
          ctx.truck.left[i] = 0
          ctx.truck.right[i] = 0
        }
        voice.block(BLOCK)
        for(local i = 0; i < BLOCK; i = i + 1){
          local v = ctx.truck.left[i]
          assert(not math.is_nan(v), "NaN")
          heard[b * BLOCK + i] = v
        }
      }
      return heard
    },
  }
}

// the loudest sample and the level (rms) of a buffer from `from` on
local func measure(b, from){
  local peak = 0.0
  local sum = 0.0
  local n = len(b)
  for(local i = from or 0; i < n; i = i + 1){
    local v = b[i]
    peak = math.max(peak, math.abs(v))
    sum = sum + v * v
  }
  return {peak: peak, rms: math.sqrt(sum / math.max(n - (from or 0), 1))}
}

// how much of a buffer (from `from` on) is at f Hz: the amplitude of a
// tone there (Goertzel's sum)
local func at(b, f, from){
  local w = 2 * math.pi * f / RATE
  local c = 2 * math.cos(w)
  local s1 = 0.0
  local s2 = 0.0
  local n = len(b)
  for(local i = from; i < n; i = i + 1){
    local s0 = b[i] + c * s1 - s2
    s2 = s1
    s1 = s0
  }
  return math.sqrt(math.max(s1 * s1 + s2 * s2 - c * s1 * s2, 0)) * 2 /
    (n - from)
}

// a truck as the layer sees one: standing at the origin, looking along z
local func truck(){
  return {
    drive: drivetrain.new(),
    pos: {x: 0, y: 0, z: 0},
    forward: {x: 0, y: 0, z: 1},
    up: {x: 0, y: 1, z: 0},
    left: {x: 1, y: 0, z: 0},
    velocity: {x: 0, y: 0, z: 0},
    speed: 0,
    brake: 0,
    hand_brake: 0,
  }
}

local VIEW = {
  eye: {x: 0, y: 2.5, z: -7.6},
  forward: {x: 0, y: -0.2, z: 0.98},
  right: {x: -1, y: 0, z: 0},
}

// the layer's watcher on a truck: {car, got (the parameters), sent (the
// events: {kind, a, b}), frames(n): n frames of the game}
local func watched(){
  local w = driveline.watcher()
  local r = {car: truck(), got: {}, sent: {}}
  local set = func(name, value){ r.got[name] = value }
  local send = func(kind, a, b, c){
    append(r.sent, {kind: kind, a: a or 0, b: b or 0})
  }
  r.frames = func(n){
    for(local i = 0; i < n; i = i + 1){
      driveline.watch(w, {car: r.car, view: VIEW, dt: 1 / 60}, set, send)
    }
  }
  // (the first frame only looks)
  r.frames(1)
  return r
}

// the events of a kind among what was sent
local func of(sent, kind){
  local list = {}
  for(let local e in values(sent)){
    if(e.kind == kind){
      append(list, e)
    }
  }
  return list
}

t.group("the gears"){
  t.test("nothing turns, nothing sounds"){
    local r = rig()
    assert(measure(r.run(40)).peak == 0)
    // nor with torque on shafts that stand
    r.set("driveline_torque", 1)
    r.set("driveline_pull", 1)
    r.set("driveline_teeth", 50)
    assert(measure(r.run(40)).peak < 1.0e-6)
  }
  t.test("the engaged pair's tone is where its teeth and the shaft put it"){
    local r = rig()
    r.set("driveline_teeth", 47)
    r.set("driveline_ratio", 2.34)
    r.set("driveline_torque", 0.9)
    // second gear at 2000 and at 3000 rpm: 47 teeth on a shaft at 14.2
    // and 21.4 turns a second
    for(let local rpm in values({2000, 3000})){
      local shaft = rpm / 60 / 2.34
      r.set("driveline_shaft", shaft)
      r.set("driveline_prop", shaft)
      local heard = r.run(90)
      local from = 40 * BLOCK
      local tone = at(heard, 47 * shaft, from)
      assert(
        tone > 0.0002,
        concat("the tone at ", string(rpm), ": ", string(tone)),
      )
      assert(
        tone > 8 * at(heard, 47 * shaft * 1.31, from),
        "a tone, not a noise",
      )
      assert(tone > 8 * at(heard, 47 * shaft * 0.77, from))
      assert(measure(heard).peak < 0.5)
    }
  }
  t.test("it is louder under load, and low range adds the transfer case"){
    local r = rig()
    local shaft = 21.4
    r.set("driveline_teeth", 47)
    r.set("driveline_ratio", 2.34)
    r.set("driveline_shaft", shaft)
    r.set("driveline_prop", shaft / 2.72)
    r.set("driveline_torque", 0.1)
    local light = r.run(80)
    r.set("driveline_torque", 1)
    local pulling = r.run(80)
    local from = 40 * BLOCK
    assert(measure(pulling, from).rms > 3 * measure(light, from).rms)
    // (the transfer case's first pair: 22 teeth on the same shaft)
    local high = at(pulling, 22 * shaft, from)
    r.set("driveline_low", 1)
    local low = r.run(80)
    assert(at(low, 22 * shaft, from) > 10 * high + 0.0005)
    assert(measure(low, from).rms > measure(pulling, from).rms)
  }
}

t.group("what happens once in the driveline"){
  t.test("a gear change is the lever out and in; a change from rest one click"){
    local w = watched()
    local d = w.car.drive
    d.gear = 1
    w.frames(1)
    local lever = of(w.sent, driveline.LEVER)
    assert(len(lever) == 1 and lever[0].a == 2)
    d.shift = {to: 2, time: 0, total: 0.3, from: 1}
    w.frames(3)
    d.shift = null
    d.gear = 2
    w.frames(3)
    lever = of(w.sent, driveline.LEVER)
    assert(len(lever) == 3 and lever[1].a == 0 and lever[2].a == 1)
  }
  t.test("the torque changing sides takes up the slack, harder the faster"){
    local func swing(frames){
      local w = watched()
      local d = w.car.drive
      d.gear = 2
      d.clutch = 1
      d.clutch_torque = 250
      w.frames(30)
      w.sent = {}
      for(local i = 1; i <= frames; i = i + 1){
        d.clutch_torque = 250 - 350 * i / frames
        w.frames(1)
      }
      w.frames(20)
      return of(w.sent, driveline.LASH)
    }
    local fast = swing(4)
    local slow = swing(40)
    assert(len(fast) == 1 and fast[0].a > 0.3, "one clunk")
    assert(len(slow) <= 1)
    if(len(slow) == 1){
      assert(slow[0].a < fast[0].a * 0.5)
    }
    // (a torque that stays on its side takes up nothing)
    local w = watched()
    w.car.drive.gear = 2
    w.car.drive.clutch = 1
    w.car.drive.clutch_torque = 250
    w.frames(30)
    w.sent = {}
    w.car.drive.clutch_torque = 60
    w.frames(30)
    assert(len(of(w.sent, driveline.LASH)) == 0)
  }
  t.test(
    "the transfer lever, the lockers and the hand brake are heard when they are moved",
  ){
    local w = watched()
    local d = w.car.drive
    d.low = true
    w.frames(1)
    local range = of(w.sent, driveline.RANGE)
    assert(len(range) == 1 and range[0].a == 2, "the lever at once")
    w.frames(20)
    range = of(w.sent, driveline.RANGE)
    assert(len(range) == 2 and range[1].a == 1, "then the range")
    // a lever flicked there and back moves nothing
    d.low = false
    w.frames(2)
    d.low = true
    w.frames(30)
    assert(len(of(w.sent, driveline.RANGE)) == 3)
    d.locks.rear = true
    w.frames(10)
    d.locks.front = true
    w.frames(10)
    d.locks.rear = false
    w.frames(10)
    local lock = of(w.sent, driveline.LOCK)
    assert(len(lock) == 3)
    assert(
      lock[0].a == 1 and lock[0].b == 1 and lock[1].a == 0 and
        lock[1].b == 1 and lock[2].b == 0,
    )
    w.car.hand_brake = 1
    w.frames(2)
    w.car.hand_brake = 0
    w.frames(2)
    local hand = of(w.sent, driveline.HAND)
    assert(len(hand) == 2 and hand[0].a == 1 and hand[1].a == 0)
  }
  t.test("each is heard, the harder the louder, and gone again"){
    local r = rig()
    r.send(driveline.LASH, 0.3)
    local soft = measure(r.run(40)).peak
    r.send(driveline.LASH, 1)
    local hard = measure(r.run(40)).peak
    assert(
      soft > 0.001 and hard > soft * 1.8 and hard < 0.5,
      concat(string(soft), " ", string(hard)),
    )
    for(let local e in values({
      {driveline.LEVER, 0},
      {driveline.LEVER, 1},
      {driveline.RANGE, 1},
      {driveline.LOCK, 1, 1},
      {driveline.LOCK, 0, 0},
      {driveline.HAND, 1},
      {driveline.HAND, 0},
    })){
      r.send(e[0], e[1], e[2] or 0)
      local m = measure(r.run(60))
      assert(
        m.peak > 0.001 and m.peak < 0.5,
        concat("event ", string(e[0]), ": ", string(m.peak)),
      )
    }
    // half a second later nothing rings
    r.run(190)
    assert(measure(r.run(10)).peak == 0)
  }
}

t.group("the brakes"){
  t.test("the pads are heard on turning wheels only"){
    local r = rig()
    r.set("driveline_brake", 1)
    assert(measure(r.run(40)).peak < 1.0e-6)
    r.set("driveline_wheel", 5)
    local m = measure(r.run(60), 30 * BLOCK)
    assert(m.rms > 0.0002 and m.peak < 0.3, string(m.rms))
  }
  t.test("some stops end in a squeak, most do not, and none squeaks at speed"){
    local w = watched()
    local d = w.car.drive
    local radius = d.spec.wheel_radius
    local squeaked = 0
    for(local stop = 0; stop < 40; stop = stop + 1){
      // from 6 m/s to a stand in a second and a half, the pedal half down
      local heard = false
      w.car.brake = 0.5
      for(local i = 0; i < 90; i = i + 1){
        local speed = 6 * (1 - i / 90)
        d.wheel_side = speed / radius
        w.frames(1)
        if(w.got.driveline_squeak > 0){
          heard = true
          assert(speed < 2.3, "a squeak at speed")
        }
      }
      if(heard){
        squeaked = squeaked + 1
      }
      // and the pedal let go
      w.car.brake = 0
      d.wheel_side = 0
      w.frames(40)
      assert(w.got.driveline_squeak == 0)
    }
    assert(squeaked >= 4 and squeaked <= 24, string(squeaked))
  }
}
