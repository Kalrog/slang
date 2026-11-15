// The sound without an audio device: the parameters the game and the
// mixer share, the engine (silent at rest, louder under load, never
// wild), the engine as the game starts and stops it, the place (a wall on
// the right is heard on the right, the open adds next to nothing), and
// the whole mix: silent until the game says otherwise, under full scale
// with everything flat out.
// Run with `slang test test` in examples/switchback (or make
// switchback-test). The layers have tests of their own (sound_*_test).
local t = require("slang/test")
local math = require("slang/math")
local kernel = require("kernel")
local drivetrain = require("game/drivetrain")
local params = require("sound/params")
local director = require("sound/director")
local mixer = require("sound/mixer")
local engine = require("sound/engine")
local engine_layer = require("sound/layers/engine")
local space = require("sound/space")
local around = require("sound/around")

// the loudest sample and the level (rms) of n frames of a buffer, from
// `from`; a NaN fails the test
local func measure(b, n, from, step){
  local peak = 0.0
  local sum = 0.0
  local count = 0
  for(local i = from or 0; i < n; i = i + (step or 1)){
    local v = b[i]
    assert(not math.is_nan(v), "NaN")
    peak = math.max(peak, math.abs(v))
    sum = sum + v * v
    count = count + 1
  }
  return {peak: peak, rms: math.sqrt(sum / math.max(count, 1))}
}

// a truck as the layers see one: standing at the origin, looking along z
local func truck(rpm, torque){
  local d = drivetrain.new()
  d.rpm = rpm
  d.torque = torque
  return {
    drive: d,
    pos: {x: 0, y: 0, z: 0},
    forward: {x: 0, y: 0, z: 1}, up: {x: 0, y: 1, z: 0}, left: {x: 1, y: 0, z: 0},
    velocity: {x: 0, y: 0, z: 0}, speed: 0,
  }
}

// the camera behind it
local VIEW = {
  eye: {x: 0, y: 2.5, z: -7.6}, forward: {x: 0, y: -0.2, z: 0.98}, right: {x: -1, y: 0, z: 0},
}

t.group("the sound's parameters"){
  t.test("every parameter has its slot, the layers' after the core's"){
    local layout = params.layout()
    assert(layout.count > 20)
    assert(layout.slot.master == 0)
    for(local i = 0; i < layout.count; i = i + 1){
      assert(layout.slot[layout.list[i][0]] == i, layout.list[i][0])
    }
    assert(layout.slot.rpm != null and layout.slot.space_tail != null)
    local shared = params.shared()
    assert(shared.values[layout.slot.master] == 0.8)
  }
  t.test("events go round the ring in order"){
    local shared = params.shared()
    for(local i = 0; i < params.RING + 3; i = i + 1){
      params.send(shared.events, 100 + i, i, 2, 3)
    }
    assert(shared.events[0] == params.RING + 3)
    // (the newest lies where the fourth-oldest lay)
    local at = 1 + ((params.RING + 2) % params.RING) * 4
    assert(shared.events[at] == 100 + params.RING + 2 and shared.events[at + 1] == params.RING + 2)
  }
}

t.group("the engine"){
  local e = engine.new({sample_rate: 48000, block: 256})
  local func run(rpm, fuel, boost, blocks){
    e:set("rpm", rpm)
    e:set("fuel", fuel)
    e:set("boost", boost)
    local level = {0, 0, 0, 0}
    for(local b = 0; b < blocks; b = b + 1){
      e:compute(256)
      if(b >= blocks - 12){
        for(local j = 0; j < 4; j = j + 1){
          local m = measure(e.out[j], 256)
          assert(m.peak < 2, "a stem far over full scale")
          level[j] = level[j] + m.rms / 12
        }
      }
    }
    return level
  }
  t.test("it is silent standing still"){
    local level = run(0, 0, 0, 40)
    for(local j = 0; j < 4; j = j + 1){
      assert(level[j] < 1.0e-4, concat("stem ", string(j), " at ", string(level[j])))
    }
  }
  t.test("it idles, and is louder under load, in its exhaust and its block"){
    local idle = run(750, 0.09, 0, 120)
    local load = run(2800, 1, 1, 120)
    assert(idle[engine.EXHAUST] > 0.002 and idle[engine.MECHANICS] > 0.001)
    assert(load[engine.EXHAUST] > idle[engine.EXHAUST] * 3)
    assert(load[engine.MECHANICS] > idle[engine.MECHANICS] * 3)
    // (the turbocharger is only heard with boost)
    assert(load[engine.TURBO] > idle[engine.TURBO] * 10)
  }
  t.test("without fuel it only pumps: quieter than pulling at the same speed"){
    local pulling = run(2800, 1, 1, 80)
    local coasting = run(2800, 0, 0, 80)
    assert(coasting[engine.EXHAUST] < pulling[engine.EXHAUST] * 0.5)
    assert(coasting[engine.MECHANICS] < pulling[engine.MECHANICS])
  }
}

t.group("the engine in the game"){
  t.test("the fuel is what the drivetrain's torque takes; none on the overrun"){
    local got = {}
    local set = func(name, value){ got[name] = value }
    local w = engine_layer.watcher()
    w.running = true
    w.phase = "running"
    local spec = drivetrain.SPEC
    local full = drivetrain.full_torque(spec, 2000)
    engine_layer.watch(w, {car: truck(2000, full), view: VIEW, dt: 1 / 60}, set, null)
    assert(math.abs(got.fuel - 1) < 0.01 and got.rpm == 2000, string(got.fuel))
    engine_layer.watch(w, {car: truck(3000, -drivetrain.drag_torque(spec, 3000)), view: VIEW, dt: 1 / 60}, set, null)
    assert(got.fuel == 0, string(got.fuel))
    // behind the truck the tailpipe is nearer than the engine: louder
    assert(got.exhaust_left + got.exhaust_right > got.bay_left + got.bay_right)
  }
  t.test("the starter turns it, it catches, runs, and runs down when it dies"){
    local got = {}
    local set = func(name, value){ got[name] = value }
    local w = engine_layer.watcher()
    local car = truck(750, 30)
    local s = {car: car, view: VIEW, dt: 1 / 60}
    engine_layer.watch(w, s, set, null)
    assert(got.rpm == 0 and got.starter == 0)
    w.running = true
    local cranked = false
    for(local i = 0; i < 150; i = i + 1){
      engine_layer.watch(w, s, set, null)
      if(got.starter == 1){
        cranked = true
        assert(got.rpm > 100 and got.rpm < 500, string(got.rpm))
      }
    }
    assert(cranked and got.starter == 0 and w.phase == "running" and got.rpm == 750)
    w.running = false
    for(local i = 0; i < 80; i = i + 1){
      engine_layer.watch(w, s, set, null)
      assert(got.fuel == 0)
    }
    assert(got.rpm == 0 and w.phase == "off")
  }
}

t.group("the place"){
  local func watched(change){
    local a = around.new()
    a.height = 3
    a.cover.grass = 1
    change(a)
    local got = {}
    space.watch(space.watcher(), {around: a, view: VIEW}, func(name, value){ got[name] = value })
    return got
  }
  t.test("out in the open it adds next to nothing"){
    local got = watched(func(a){})
    assert(got.space_wall1_left == 0 and got.space_wall2_right == 0)
    assert(got.space_tail < 0.2)
  }
  t.test("a cliff to the right echoes on the right, later the farther it is"){
    // (the view looks along z: its right is -x, where walls[6] stands)
    local near = watched(func(a){
      a.walls[6].distance = 12
      a.walls[6].rise = 40
    })
    assert(near.space_wall1_right > near.space_wall1_left * 2 and near.space_wall1_right > 0.05)
    local far = watched(func(a){
      a.walls[6].distance = 60
      a.walls[6].rise = 40
    })
    assert(far.space_wall1_delay > near.space_wall1_delay * 4)
    assert(far.space_wall1_right < near.space_wall1_right * 0.4)
  }
  t.test("a hillside is no wall"){
    local got = watched(func(a){
      a.walls[2].distance = 12
      a.walls[2].rise = 8
    })
    assert(got.space_wall1_left == 0 and got.space_wall1_right == 0)
  }
}

t.group("the mix"){
  t.test("it is silent until the game is heard, then sounds, under full scale flat out"){
    local sound = director.offline()
    local block = mixer.new(sound.shared.values, sound.shared.events, {sample_rate: 48000, block: 128})
    local out = kernel.float:array(256)
    for(local b = 0; b < 8; b = b + 1){
      block(out, 128)
      assert(measure(out, 256).peak == 0)
    }
    // everything the engine has, right at the listener
    local set = sound.set
    set("awake", 1)
    set("rpm", 4400)
    set("fuel", 1)
    set("boost", 1)
    for(let local name in values({"exhaust", "bay", "intake"})){
      set(concat(name, "_left"), 2)
      set(concat(name, "_right"), 2)
    }
    local loudest = 0.0
    local level = 0.0
    for(local b = 0; b < 300; b = b + 1){
      block(out, 128)
      local m = measure(out, 256)
      loudest = math.max(loudest, m.peak)
      level = m.rms
    }
    assert(level > 0.05, string(level))
    assert(loudest < 1.0, string(loudest))
  }
}
