// The camps without an audio device: where a camp's fire and its
// pennant are for the listener (sound/layers/camp's watch: only near a
// camp, the fire from further than the pennant, each on its side), and
// the layer as the mixer runs it: silent away from a camp, the fire
// crackling, the pennant flapping the harder the more wind there is and
// hanging in still air, never wild.
// Run with `slang test test` in examples/switchback (or make
// switchback-test).
local t = require("slang/test")
local math = require("slang/math")
local kernel = require("kernel")
local params = require("sound/params")
local around = require("sound/around")
local camp = require("sound/layers/camp")

// a listener looking along z (to its right is -x) and a camp whose
// place is at x, z (yaw 0: its trail runs along z; its fire lies 1.9 m
// to the left of its place, toward +x, and 3 m before it, its pennant
// 4.7 m to the right and 1 m before it)
local func frame(x, z, wind){
  local a = around.new()
  a.wind.strength = wind or 0.2
  local s = {
    around: a,
    view: {
      eye: {x: 0, y: 2.5, z: 0},
      forward: {x: 0, y: 0, z: 1},
      right: {x: -1, y: 0, z: 0},
    },
    world: {camps: {}},
    dt: 1 / 60,
  }
  if(x != null){
    s.world.camps = {{name: "Camp", x: x, y: 0, z: z, yaw: 0}}
    local d = math.sqrt(x * x + z * z)
    a.camp = {distance: d, x: x / d, z: z / d, index: 0}
  }
  return s
}

// what the layer's watch says of a frame
local func watched(s){
  local got = {}
  camp.watch(camp.watcher(), s, func(name, value){ got[name] = value }, null)
  return got
}

// the layer's voice with what a frame's watch says, run for some blocks:
// the level (rms) and the loudest sample of the world's bus (its left)
// over the blocks from `from` on
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
  local voice = camp.voice({
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
  local sum = 0.0
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
        assert(not math.is_nan(l) and not math.is_nan(world.right[i]), "NaN")
        sum = sum + l * l
        peak = math.max(peak, math.abs(l))
      }
      count = count + 128
    }
  }
  return {level: math.sqrt(sum / count), peak: peak}
}

t.group("a camp in the game"){
  t.test("away from every camp there is nothing"){
    local got = watched(frame())
    assert(got.camp_fire_left == 0 and got.camp_fire_right == 0)
    assert(got.camp_flag_left == 0 and got.camp_flag_right == 0)
  }
  t.test("the fire is heard from thirty meters, louder the nearer"){
    // (the camp put so that its fire is straight ahead)
    local near = watched(frame(-1.9, 8))
    local mid = watched(frame(-1.9, 23))
    local far = watched(frame(-1.9, camp.FIRE + 6))
    assert(math.abs(near.camp_fire_left - near.camp_fire_right) < 0.001)
    assert(
      near.camp_fire_left > 0.8 and near.camp_fire_near > 0.8,
      string(near.camp_fire_left),
    )
    assert(
      mid.camp_fire_left > 0.05 and
        mid.camp_fire_left < near.camp_fire_left * 0.3,
    )
    assert(mid.camp_fire_near < 0.5)
    assert(far.camp_fire_left == 0 and far.camp_fire_right == 0)
  }
  t.test("the pennant only from half as far, and each on its side"){
    // the camp's place ten meters ahead: the fire to the left of the
    // trail (the listener's left is +x), the pennant to the right
    local got = watched(frame(0, 10, 0.5))
    assert(got.camp_fire_left > got.camp_fire_right, "the fire on the left")
    assert(got.camp_flag_right > got.camp_flag_left, "the pennant on the right")
    assert(got.camp_wind == 0.5)
    local away = watched(frame(0, 24))
    assert(
      away.camp_flag_left == 0 and away.camp_flag_right == 0 and
        away.camp_fire_left > 0,
    )
  }
  t.test("a camp on a trail has them where the picture has them"){
    // a trail along z, the camp at its fifth point: render/markers sets
    // it up by the point five further on (z = 20): the fire 1.9 m left
    // of it and 3 m before it, the pennant's pole 4 m to the right
    local points = {}
    for(local i = 0; i < 20; i = i + 1){
      append(points, {x: 0, y: 0, z: i * 2, half: 2.3})
    }
    local s = frame(0, 10)
    s.world.camps[0].trail = {points: points}
    s.world.camps[0].at = 5
    local w = camp.watcher()
    camp.watch(w, s, func(name, value){}, null)
    assert(
      math.abs(w.fire.x - 1.9) < 0.001 and math.abs(w.fire.z - 17) < 0.001,
      string(w.fire.z),
    )
    assert(math.abs(w.pennant.x + 4.7) < 0.001 and math.abs(
        w.pennant.z - 19,
      ) < 0.001)
    assert(w.pennant.y > 4)
  }
}

t.group("a camp as it sounds"){
  t.test("away from it there is nothing"){
    local quiet = heard(watched(frame()), 4, 0)
    assert(quiet.level == 0)
  }
  t.test("the fire crackles: a quiet bed and cracks well over it"){
    local got = watched(frame(-1.9, 8))
    got.camp_flag_left = 0
    got.camp_flag_right = 0
    local fire = heard(got, 300, 20)
    assert(fire.level > 0.001 and fire.level < 0.03, string(fire.level))
    assert(fire.peak > fire.level * 5 and fire.peak < 0.4, string(fire.peak))
  }
  t.test("the pennant hangs in still air and flaps harder in more wind"){
    local func flapping(wind){
      local got = watched(frame(4.7, 6, wind))
      got.camp_fire_left = 0
      got.camp_fire_right = 0
      return heard(got, 300, 20)
    }
    assert(flapping(0).level == 0)
    local light = flapping(0.15)
    local strong = flapping(0.8)
    assert(light.level > 0.0001, string(light.level))
    assert(
      strong.level > light.level * 2 and strong.peak < 0.4,
      string(strong.level / light.level),
    )
  }
}
