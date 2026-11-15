// The body's sound without an audio device: silent while the truck
// stands; a knock heard once, the harder the louder, a landing's row of
// knocks as one or two, and none when the truck was put somewhere; what
// the truck carries rattling when it is jolted, by what the garage put
// on it, and settling; the frame's creak only at a crawl with the axles
// twisting; the winch's hook, motor and line following game/winch's line.
// A crash (a knock that does harm, all of one when it breaks the truck)
// in place of the knock, bigger and much longer; the suspension: springs
// creaking when worked slowly and far, one bang for a landing on the
// bump stops, by how fast, a clack when a wheel drops into its straps.
// Run with `slang test test` in examples/switchback (or make
// switchback-test).
local t = require("slang/test")
local math = require("slang/math")
local kernel = require("kernel")
local params = require("sound/params")
local body = require("sound/layers/body")

local RATE = 48000
local BLOCK = 128
local PLACES = {
  "mid",
  "roof",
  "tail",
  "front",
  "knock",
  "brush",
  "hook",
  "work",
  "corner1",
  "corner2",
  "corner3",
  "corner4",
}

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
  local voice = body.voice(ctx)
  local func set(name, value){
    now[layout.slot[name]] = value
  }
  for(let local name in values(PLACES)){
    set(concat("body_", name, "_left"), 0.62)
    set(concat("body_", name, "_right"), 0.62)
  }
  return {
    set: set,
    send: func(kind, a, b, c){
      voice.on(kind, a or 0, b or 0, c or 0)
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

// the loudest sample and the level (rms) of a buffer
local func measure(b){
  local peak = 0.0
  local sum = 0.0
  local n = len(b)
  for(local i = 0; i < n; i = i + 1){
    local v = b[i]
    peak = math.max(peak, math.abs(v))
    sum = sum + v * v
  }
  return {peak: peak, rms: math.sqrt(sum / math.max(n, 1))}
}

local VIEW = {
  eye: {x: 0, y: 2.5, z: -7.6},
  forward: {x: 0, y: -0.2, z: 0.98},
  right: {x: -1, y: 0, z: 0},
}

// The layer's watcher on a truck as it sees one (standing at the origin
// on four wheels, looking along z) in a world that only says how hard it
// was knocked: {car, world, setup, got (the parameters), sent (the
// events: {kind, a, b}), frames(n): n frames of the game}. The first
// second (in which nothing is a knock yet) has passed.
local func watched(setup){
  local w = body.watcher()
  local wheels = {}
  for(local i = 0; i < 4; i = i + 1){
    wheels[i] = {length: 0.23, contact: true}
  }
  local r = {
    car: {
      pos: {x: 0, y: 0, z: 0},
      velocity: {x: 0, y: 0, z: 0},
      spin: {x: 0, y: 0, z: 0},
      forward: {x: 0, y: 0, z: 1},
      up: {x: 0, y: 1, z: 0},
      left: {x: 1, y: 0, z: 0},
      speed: 0,
      wheels: wheels,
    },
    world: {knock: 0},
    setup: setup,
    events: {},
    got: {},
    sent: {},
  }
  local set = func(name, value){ r.got[name] = value }
  local send = func(kind, a, b, c){
    append(r.sent, {kind: kind, a: a or 0, b: b or 0, c: c or 0})
  }
  r.frames = func(n){
    for(local i = 0; i < n; i = i + 1){
      body.watch(w, {
        car: r.car,
        world: r.world,
        view: VIEW,
        dt: 1 / 60,
        setup: r.setup,
        events: r.events,
      }, set, send)
      // (the game's events are a frame's)
      r.events = {}
    }
  }
  r.frames(60)
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

// a frame in which the truck's speed changes by `change` upward at once
// (and the world says so)
local func jolt(w, change){
  w.world.knock = change
  w.car.velocity.y = w.car.velocity.y + change
  w.frames(1)
  w.world.knock = 0
}

t.group("knocks"){
  t.test("a truck that stands makes no sound of its body"){
    local r = rig()
    assert(measure(r.run(40)).peak == 0)
    local w = watched()
    w.frames(120)
    assert(len(w.sent) == 0)
    assert(
      w.got.body_creak == 0 and w.got.body_leaves == 0 and w.got.body_winch == 0,
    )
  }
  t.test("a knock is heard, the harder the louder, and gone again"){
    local r = rig()
    local last = 0
    for(let local strength in values({0.15, 0.4, 1.0, 3.0})){
      r.send(body.KNOCK, strength, 0.2)
      local m = measure(r.run(120))
      assert(m.peak > last * 1.3, concat(
        "a knock of ", string(strength), ": ", string(m.peak)
      ))
      assert(m.peak < 0.6)
      last = m.peak
    }
    assert(last > 0.15, string(last))
    // (a crash's crackle takes a little longer)
    r.run(150)
    assert(measure(r.run(10)).peak == 0)
  }
  t.test("a knock from below is less of a thud than one from the side"){
    local r = rig()
    r.send(body.KNOCK, 0.4, 1)
    local below = measure(r.run(100)).peak
    r.send(body.KNOCK, 0.4, 0)
    local side = measure(r.run(100)).peak
    assert(side > below * 1.5, concat(string(below), " ", string(side)))
  }
  t.test("the game's knock is sent once, a row of them as its hardest"){
    local w = watched()
    jolt(w, 0.3)
    w.frames(3)
    local knocks = of(w.sent, body.KNOCK)
    assert(len(knocks) == 1 and math.abs(knocks[0].a - 0.3) < 0.001)
    // (from below: all of it along the truck's up)
    assert(knocks[0].b > 0.9)
    // a landing: twenty frames of the springs taking it, with the bump
    // stops in the middle
    w.sent = {}
    w.frames(60)
    for(local i = 0; i < 20; i = i + 1){
      jolt(w, if(i == 8){ 0.75 } else { 0.25 })
    }
    w.frames(3)
    knocks = of(w.sent, body.KNOCK)
    assert(
      len(knocks) == 2 and knocks[0].a == 0.25 and knocks[1].a == 0.75,
      string(len(knocks)),
    )
    // what is less than the physics does to a truck in the air is none
    w.sent = {}
    w.frames(60)
    jolt(w, 0.09)
    w.frames(3)
    assert(len(of(w.sent, body.KNOCK)) == 0)
  }
  t.test("a truck put somewhere else is set down without a sound"){
    local w = watched()
    // towed: far away at once
    w.car.pos.x = 400
    w.frames(1)
    jolt(w, 0.3)
    w.frames(3)
    assert(len(w.sent) == 0)
    // righted where it is, from a drive: its speed gone at once
    w.frames(60)
    w.car.velocity.z = 6
    w.frames(30)
    w.sent = {}
    w.car.velocity.z = 0
    w.frames(1)
    jolt(w, 0.3)
    w.frames(3)
    assert(len(w.sent) == 0, string(len(w.sent)))
    // and a second later a knock is a knock again
    w.frames(60)
    jolt(w, 0.3)
    w.frames(3)
    assert(len(of(w.sent, body.KNOCK)) == 1)
  }
}

t.group("what the truck carries"){
  t.test("a jolt rattles what the garage put on it, and it settles"){
    // the game's own truck: a basket rack, the spare on the tailgate,
    // the winch's hook
    local w = watched({roof: "rack", spare: "tailgate", bumper: "winch"})
    jolt(w, 0.6)
    w.frames(2)
    local rattles = of(w.sent, body.RATTLE)
    local which = {}
    for(let local e in values(rattles)){
      which[body.THINGS[to_int(e.a)].name] = true
      assert(e.b > 0 and e.b <= 1)
    }
    assert(
      which.rack and which.spare and which.hook and not which.cans and
        not which.bar,
    )
    // the same jolt at once again finds them settled
    local before = len(rattles)
    w.frames(20)
    jolt(w, 0.25)
    w.frames(2)
    assert(len(of(w.sent, body.RATTLE)) == before)
    // a bare truck carries next to nothing
    local bare = watched({roof: "none", spare: "none", bumper: "stock"})
    jolt(bare, 0.6)
    bare.frames(2)
    for(let local e in values(of(bare.sent, body.RATTLE))){
      assert(body.THINGS[to_int(e.a)].category == null)
    }
    // and gentle ground rattles nothing
    local calm = watched({roof: "expedition", spare: "tailgate", bumper: "bar"})
    for(local i = 0; i < 60; i = i + 1){
      calm.car.velocity.y = 0.05 * math.sin(i * 0.5)
      calm.frames(1)
    }
    assert(len(of(calm.sent, body.RATTLE)) == 0)
  }
  t.test("every thing is heard and is short"){
    local r = rig()
    for(local i = 0; i < len(body.THINGS); i = i + 1){
      r.send(body.RATTLE, i, 1)
      local m = measure(r.run(60))
      assert(
        m.peak > 0.003 and m.peak < 0.2,
        concat(body.THINGS[i].name, ": ", string(m.peak)),
      )
    }
    r.run(190)
    assert(measure(r.run(10)).peak == 0)
  }
}

t.group("the frame's creak"){
  t.test(
    "it creaks when the axles twist at a crawl, here and there, and not at speed",
  ){
    local w = watched()
    local creaked = 0
    // one diagonal's springs let out over two seconds, the other's
    // pushed in
    for(local i = 0; i < 120; i = i + 1){
      local twist = 0.12 * i / 120
      w.car.wheels[0].length = 0.23 + twist / 4
      w.car.wheels[3].length = 0.23 + twist / 4
      w.car.wheels[1].length = 0.23 - twist / 4
      w.car.wheels[2].length = 0.23 - twist / 4
      w.car.speed = 1
      w.frames(1)
      if(w.got.body_creak > 0.05){
        creaked = creaked + 1
        assert(w.got.body_creak_rate > 6 and w.got.body_creak_rate < 140)
      }
    }
    assert(creaked > 5 and creaked < 100, string(creaked))
    // the same at 8 m/s
    for(local i = 0; i < 120; i = i + 1){
      local twist = 0.12 - 0.12 * i / 120
      w.car.wheels[0].length = 0.23 + twist / 4
      w.car.wheels[3].length = 0.23 + twist / 4
      w.car.wheels[1].length = 0.23 - twist / 4
      w.car.wheels[2].length = 0.23 - twist / 4
      w.car.speed = 8
      w.frames(1)
      assert(w.got.body_creak == 0)
    }
  }
  t.test("it is heard while it creaks"){
    local r = rig()
    r.set("body_creak", 1)
    r.set("body_creak_rate", 40)
    local m = measure(r.run(80))
    assert(m.peak > 0.003 and m.peak < 0.3, string(m.peak))
    r.set("body_creak", 0)
    r.run(190)
    assert(measure(r.run(10)).peak == 0)
  }
}

t.group("bushes and the winch"){
  t.test("leaves are heard by how fast the truck goes through them"){
    local r = rig()
    r.set("body_leaves", 1)
    r.set("body_twigs", 0.5)
    r.set("body_brush_speed", 0.2)
    local slow = measure(r.run(80)).rms
    r.set("body_brush_speed", 1)
    r.run(40)
    local fast = measure(r.run(80)).rms
    assert(
      slow > 0.0003 and fast > slow * 2 and fast < 0.2,
      concat(string(slow), " ", string(fast)),
    )
  }
  t.test(
    "the hook is set, the motor pulls and slows under load, the line runs in",
  ){
    local w = watched()
    w.world.winch = {
      anchor: {x: 0, y: 0.5, z: 12}, kind: "tree", length: 10, tension: 0
    }
    w.frames(1)
    local hook = of(w.sent, body.HOOK)
    assert(len(hook) == 1 and hook[0].a == 0)
    // the drum takes the line in
    for(local i = 0; i < 30; i = i + 1){
      w.world.winch.length = w.world.winch.length - 0.55 / 60
      w.frames(1)
    }
    assert(
      math.abs(w.got.body_winch - 1) < 0.1 and w.got.body_strain == 0,
      string(w.got.body_winch),
    )
    w.world.winch.tension = 30000
    w.world.winch.length = w.world.winch.length - 0.55 / 60
    w.frames(1)
    assert(w.got.body_strain > 0.6 and w.got.body_line > 0.2)
    // unhooked
    w.world.winch = null
    w.frames(1)
    local reel = of(w.sent, body.REEL)
    assert(len(reel) == 1 and reel[0].a > 9 and reel[0].a < 10)
    assert(w.got.body_winch == 0)
    // the motor is lower under load
    local r = rig()
    r.set("body_winch", 1)
    local free = measure(r.run(200))
    assert(free.rms > 0.001 and free.peak < 0.3, string(free.rms))
    r.set("body_winch", 0)
    r.run(500)
    assert(measure(r.run(10)).peak == 0)
  }
}

t.group("a crash"){
  // a frame in which the truck is stopped from `speed` at once, as the
  // rules tell of it (broken: it was the knock that broke the truck)
  local func hit(w, speed, broken){
    // (brought to speed at once, it counts as put there: a second for
    // that to pass)
    w.car.velocity.z = speed
    w.frames(60)
    w.sent = {}
    w.world.knock = speed
    w.car.velocity.z = 0
    w.events = {{kind: "knock", strength: speed, harm: (speed - 0.55) * 0.11}}
    if(broken){
      append(w.events, {kind: "broken"})
    }
    w.frames(1)
    w.world.knock = 0
    w.frames(3)
  }
  t.test(
    "a knock that does harm is one, the one that breaks the truck all of it",
  ){
    local w = watched({roof: "rack", spare: "tailgate", bumper: "winch"})
    // (a hard knock is a knock)
    hit(w, 0.9, false)
    assert(len(of(w.sent, body.CRASH)) == 0 and len(
        of(w.sent, body.KNOCK),
      ) == 1)
    w.frames(240)
    hit(w, 3, false)
    local crash = of(w.sent, body.CRASH)
    assert(
      len(crash) == 1 and crash[0].a > 0.15 and crash[0].a < 0.6,
      string(len(crash)),
    )
    // it is heard in place of the knock, and what the truck carries is
    // thrown about: at once, and again a moment later
    assert(len(of(w.sent, body.KNOCK)) == 0)
    local later = 0
    for(let local e in values(of(w.sent, body.RATTLE))){
      if(e.c > 0){
        later = later + 1
      }
    }
    assert(later >= 3, string(later))
    w.frames(240)
    hit(w, 3, true)
    crash = of(w.sent, body.CRASH)
    assert(len(crash) == 1 and crash[0].a >= 0.75 and crash[0].a <= 1)
  }
  t.test("it is bigger than the hardest knock, and much longer"){
    local r = rig()
    r.send(body.KNOCK, 1, 0.2)
    local knock = measure(r.run(60)).peak
    local tail = measure(r.run(150)).peak
    assert(tail < 0.001, "a knock is over in a sixth of a second")
    r.send(body.CRASH, 1, 0.2)
    local blow = measure(r.run(60)).peak
    assert(
      blow > knock * 1.8 and blow < 1.2,
      concat(string(knock), " ", string(blow)),
    )
    // half a second on things still give way and come to rest
    r.run(130)
    assert(measure(r.run(190)).peak > 0.002)
    // and four seconds on all is still
    r.run(1100)
    assert(measure(r.run(10)).peak == 0)
  }
}

t.group("the suspension"){
  // the four springs set to a length
  local func springs(w, a, b, c, d){
    w.car.wheels[0].length = a
    w.car.wheels[1].length = b
    w.car.wheels[2].length = c
    w.car.wheels[3].length = d
  }
  t.test(
    "a spring worked slowly and far creaks here and there; a quick stroke does not",
  ){
    local w = watched()
    local creaked = 0
    // the front left let out over three seconds, 5 cm/s
    for(local i = 0; i < 180; i = i + 1){
      springs(w, 0.23 + 0.13 * i / 180, 0.23, 0.23, 0.23)
      w.car.speed = 1
      w.frames(1)
      if(w.got.body_spring1 > 0.05){
        creaked = creaked + 1
      }
      assert(w.got.body_spring2 == 0 and w.got.body_spring4 == 0)
    }
    assert(creaked > 8 and creaked < 150, string(creaked))
    // the same way back in a fifth of a second: the damper breathes
    local breathed = false
    for(local i = 0; i < 12; i = i + 1){
      springs(w, 0.36 - 0.13 * i / 12, 0.23, 0.23, 0.23)
      w.frames(1)
      // (it may speak as the stroke begins; at speed it does not)
      if(i >= 6){
        assert(w.got.body_spring1 < 0.05)
      }
      breathed = breathed or w.got.body_breath > 0
    }
    assert(breathed)
  }
  t.test(
    "a landing on the bump stops is one bang, by how fast, and carries the knock",
  ){
    local w = watched()
    w.sent = {}
    // all four come up 4 cm a frame (2.4 m/s), the rear a frame later
    for(local i = 1; i <= 5; i = i + 1){
      local front = math.max(0.23 - 0.04 * i, 0.07)
      local rear = math.max(0.27 - 0.04 * i, 0.07)
      springs(w, front, front, rear, rear)
      w.frames(1)
    }
    local stops = of(w.sent, body.BOTTOM)
    assert(
      len(stops) == 1 and stops[0].b > 2 and stops[0].b < 3.2,
      string(len(stops)),
    )
    // the knock that comes with it says that a stop carries it
    jolt(w, 0.4)
    w.frames(2)
    local knocks = of(w.sent, body.KNOCK)
    assert(len(knocks) == 1 and knocks[0].c == 1)
    // a spring let out to the end of its travel at speed: the straps
    w.frames(60)
    w.sent = {}
    for(local i = 1; i <= 6; i = i + 1){
      springs(w, 0.07, 0.07, math.min(0.07 + 0.05 * i, 0.331), 0.07)
      w.frames(1)
    }
    local tops = of(w.sent, body.TOP)
    assert(len(tops) == 1 and tops[0].a == 2 and tops[0].b > 2)
    assert(len(of(w.sent, body.BOTTOM)) == 0)
  }
  t.test(
    "the bang grows with the speed and stops growing; a drop is a clack beside it",
  ){
    local r = rig()
    local func heard(kind, speed){
      r.send(kind, 1, speed)
      local m = measure(r.run(100))
      r.run(60)
      return m.peak
    }
    local slow = heard(body.BOTTOM, 1)
    local fast = heard(body.BOTTOM, 4.5)
    local most = heard(body.BOTTOM, 12)
    assert(
      slow > 0.01 and fast > slow * 2.5,
      concat(string(slow), " ", string(fast)),
    )
    assert(most < fast * 1.3 and most < 0.4, string(most))
    local drop = heard(body.TOP, 1)
    assert(drop > 0.002 and drop < slow, string(drop))
    local clunk = heard(body.LINK, 0.5)
    assert(clunk > 0.002 and clunk < slow)
  }
}
