// The air without an audio device: the air past the listener (silent at
// rest, 18 dB louder for twice the speed, its middle higher), what the
// game's side makes of a truck's speed, the wind and what stands around
// (sound/layers/air's watch), and the layer as the mixer runs it:
// silent without wind and speed, swelling with the wind, a wood's hiss
// where there is a wood, never wild.
// Run with `slang test test` in examples/switchback (or make
// switchback-test).
local t = require("slang/test")
local math = require("slang/math")
local kernel = require("kernel")
local params = require("sound/params")
local around = require("sound/around")
local air = require("sound/layers/air")

// the level (rms) of n frames of a buffer; a NaN or a sample over `most`
// fails the test
local func level(b, n, most){
  local sum = 0.0
  for(local i = 0; i < n; i = i + 1){
    local v = b[i]
    assert(not math.is_nan(v), "NaN")
    assert(math.abs(v) <= (most or 1), concat("a sample at ", string(v)))
    sum = sum + v * v
  }
  return math.sqrt(sum / n)
}

local func db(ratio){
  return 20 * math.log(math.max(ratio, 1.0e-12)) / math.log(10)
}

// a listener looking along z (to its right is -x), and a frame with
// nothing around it but still air
local func frame(){
  local a = around.new()
  a.wind.strength = 0
  a.wind.x = 1
  a.wind.z = 0
  return {
    around: a,
    view: {
      eye: {x: 0, y: 2.5, z: 0},
      forward: {x: 0, y: 0, z: 1},
      right: {x: -1, y: 0, z: 0},
    },
    car: {velocity: {x: 0, y: 0, z: 0}},
    dt: 1 / 60,
  }
}

// what the layer's watch says of a frame
local func watched(s){
  local got = {}
  air.watch(air.watcher(), s, func(name, value){ got[name] = value }, null)
  return got
}

// the layer's voice on a stage of its own: the parameters as they are
// set, and the world's bus it adds to
local func stage(){
  local layout = params.layout()
  local now = kernel.double:array(layout.count)
  for(local i = 0; i < layout.count; i = i + 1){
    now[i] = layout.list[i][1]
  }
  local world = {left: kernel.float:array(128), right: kernel.float:array(128)}
  local ctx = {
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
  }
  local voice = air.voice(ctx)
  local s = {}
  func s.set(name, value){
    now[layout.slot[name]] = value
  }
  // run(blocks, from?) -> the level of each side over the blocks from
  // `from` on
  func s.run(blocks, from){
    local left = 0.0
    local right = 0.0
    local count = 0
    for(local b = 0; b < blocks; b = b + 1){
      for(local i = 0; i < 128; i = i + 1){
        world.left[i] = 0
        world.right[i] = 0
      }
      voice.block(128)
      if(b >= (from or 0)){
        left = left + level(world.left, 128) * level(world.left, 128)
        right = right + level(world.right, 128) * level(world.right, 128)
        count = count + 1
      }
    }
    return {left: math.sqrt(left / count), right: math.sqrt(right / count)}
  }
  return s
}

t.group("the air past the listener"){
  local program = require("sound/air")
  local inst = program:new({sample_rate: 48000})
  local ins = {kernel.float:array(256), kernel.float:array(256)}
  local outs = {kernel.float:array(256), kernel.float:array(256)}
  // the level at a speed, and how much of it lies over 600 Hz (the
  // difference from sample to sample weighs the highs)
  local func at(speed){
    inst.left = speed
    inst.right = speed
    local sum = 0.0
    local rough = 0.0
    for(local b = 0; b < 40; b = b + 1){
      inst:compute(256, ins, outs)
      if(b >= 8){
        local l = level(outs[0], 256)
        sum = sum + l * l
        for(local i = 1; i < 256; i = i + 1){
          local d = outs[0][i] - outs[0][i - 1]
          rough = rough + d * d / 255
        }
      }
    }
    return {level: math.sqrt(sum / 32), bright: math.sqrt(rough / sum)}
  }
  t.test("still air is silent"){
    assert(at(0).level == 0)
  }
  t.test("twice the speed is 18 dB louder, and brighter"){
    local slow = at(7.5)
    local fast = at(15)
    local faster = at(30)
    assert(
      math.abs(db(fast.level / slow.level) - 18) < 3,
      string(db(fast.level / slow.level)),
    )
    assert(
      math.abs(db(faster.level / fast.level) - 18) < 3,
      string(db(faster.level / fast.level)),
    )
    assert(
      fast.bright > slow.bright * 1.15 and faster.bright > fast.bright * 1.15,
    )
    // (at 60 km/h it is 38 dB under full scale, before the layer's level)
    assert(math.abs(db(at(16.67).level) + 38) < 3, string(db(at(16.67).level)))
  }
}

t.group("the air in the game"){
  t.test("a truck standing in still air hears none"){
    local got = watched(frame())
    assert(got.air_speed == 0 and got.air_wind == 0)
  }
  t.test("the air past the listener is the truck's speed against the wind's"){
    local s = frame()
    s.car.velocity.z = 15
    assert(math.abs(watched(s).air_speed - 15) < 0.01)
    // a wind of 10 m/s in its face, then at its back
    s.around.wind.strength = 0.5
    s.around.wind.x = 0
    s.around.wind.z = -1
    local against = watched(s)
    s.around.wind.z = 1
    local with = watched(s)
    assert(
      against.air_speed > 22 and against.air_speed < 25,
      string(against.air_speed),
    )
    assert(math.abs(with.air_speed - 5) < 0.01, string(with.air_speed))
    assert(against.air_wind == 0.5)
    // however fast it falls, the air is never taken to be much faster
    // than a truck drives
    s.car.velocity.y = -80
    assert(watched(s).air_speed < air.KNEE + air.ROOM)
  }
  t.test(
    "a wind from the left is heard on the left, and its gusts come from there",
  ){
    local s = frame()
    // (to the listener's right is -x: a wind blowing toward -x comes
    // from the left)
    s.around.wind.strength = 0.6
    s.around.wind.x = -1
    s.around.wind.z = 0
    local got = watched(s)
    assert(got.air_cross < -0.9, string(got.air_cross))
    assert(got.air_drift > 0.9, string(got.air_drift))
  }
  t.test("what stands around says which of the wind's sounds there are"){
    local s = frame()
    s.around.cover.grass = 1
    local meadow = watched(s)
    assert(
      meadow.air_grass == 1 and meadow.air_conifer == 0 and
        meadow.air_ridge == 0,
    )
    assert(meadow.air_open == 1 and meadow.air_aloft == 1)
    // a wood: its trees, little of the grass under them, and more wind
    // in their crowns than where the listener stands
    s.around.trees.conifer = 1
    s.around.shelter = 0.45
    local wood = watched(s)
    assert(wood.air_conifer == 1 and wood.air_grass < 0.5 and wood.air_open < 1)
    assert(wood.air_aloft > 1.3, string(wood.air_aloft))
    // bushes rustle as leaves do, half as much
    s.around.trees.conifer = 0
    s.around.trees.bush = 0.6
    assert(math.abs(watched(s).air_broadleaf - 0.3) < 0.001)
    // the heights: bare, and less of everything else
    local high = frame()
    high.around.alpine = 1
    local ridge = watched(high)
    assert(ridge.air_ridge == 1 and ridge.air_open < 0.5)
  }
  t.test("a load on the roof whistles more than a bare truck"){
    local s = frame()
    local bare = watched(s).air_rack
    s.setup = {roof: "rack", light_bar: "roof"}
    assert(watched(s).air_rack > bare + 0.5)
  }
}

t.group("the air as it sounds"){
  t.test("without wind and speed there is nothing"){
    local s = stage()
    local quiet = s.run(4)
    assert(quiet.left == 0 and quiet.right == 0)
  }
  t.test("the wind is heard, more of it the harder it blows"){
    local s = stage()
    s.set("air_open", 1)
    s.set("air_grass", 1)
    // (it blows toward the right: the left has it at once)
    s.set("air_drift", 1)
    s.set("air_wind", 0.15)
    local breeze = s.run(60, 30)
    assert(breeze.left > 0.0003, string(breeze.left))
    s.set("air_wind", 0.6)
    local blow = s.run(60, 30)
    assert(blow.left > breeze.left * 2, string(blow.left / breeze.left))
    // (a strong wind on the plan's scale is some 36 dB under full scale,
    // and the layer is mixed under that)
    assert(blow.left < 0.03, string(blow.left))
  }
  t.test(
    "a gust reaches the side the wind comes from first, the other a second later",
  ){
    local s = stage()
    s.set("air_open", 1)
    s.set("air_drift", 1)
    s.set("air_wind", 0.5)
    local first = s.run(60, 30)
    assert(
      first.left > 0.001 and first.right < first.left * 0.05,
      string(first.right / first.left),
    )
    local later = s.run(440, 420)
    assert(later.right > later.left * 0.3, string(later.right / later.left))
  }
  t.test("a wood hisses where a meadow does not"){
    local func bright(conifer){
      local s = stage()
      s.set("air_open", 1)
      s.set("air_conifer", conifer)
      s.set("air_drift", 1)
      s.set("air_wind", 0.4)
      return s.run(60, 30).left
    }
    assert(bright(1) > bright(0) * 1.3)
  }
  t.test("the air past a fast truck is heard without any wind"){
    local s = stage()
    s.set("air_speed", 20)
    local fast = s.run(60, 20)
    assert(
      fast.left > 0.002 and fast.right > 0.002 and fast.left < 0.05,
      string(fast.left),
    )
  }
}
