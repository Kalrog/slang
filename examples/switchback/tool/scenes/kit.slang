// tool/scenes/kit: what the scenarios of tool/sound.slang are made with:
// a program or the whole mix rendered into arrays, with the game (the bot
// driving, the director watching) or with parameters set by hand.
//
// A scenario is a module tool/scenes/<name>.slang that returns
// func(kit, args) -> {channels: {Buffer}, load: float} (args: the command
// line after the output directory); its channels become the WAV's.
local kernel = require("kernel")
local math = require("slang/math")
local time = require("slang/time")

local kit = {}

kit.RATE = 48000
kit.BLOCK = 128

// along(points, t): a value gliding through points {t, v}
func kit.along(points, t){
  local n = len(points)
  if(t <= points[0][0]){
    return points[0][1]
  }
  for(local i = 1; i < n; i = i + 1){
    if(t <= points[i][0]){
      local p = points[i - 1]
      local q = points[i]
      return p[1] + (q[1] - p[1]) * (t - p[0]) / (q[0] - p[0])
    }
  }
  return points[n - 1][1]
}

// program(program, seconds, each) -> {channels, load}: a dsp program's
// outputs over seconds; each(instance, t) sets its controls before every
// block. A program with inputs gets silence.
func kit.program(program, seconds, each){
  local v = program:new({sample_rate: kit.RATE})
  local frames = to_int(seconds * kit.RATE / kit.BLOCK) * kit.BLOCK
  local outs = {}
  local blocks = {}
  local ins = {}
  for(local j = 0; j < program.outputs; j = j + 1){
    append(outs, kernel.float:array(frames))
    append(blocks, kernel.float:array(kit.BLOCK))
  }
  for(local j = 0; j < program.inputs; j = j + 1){
    append(ins, kernel.float:array(kit.BLOCK))
  }
  local spent = 0
  for(local at = 0; at < frames; at = at + kit.BLOCK){
    if(each != null){
      each(v, at / kit.RATE)
    }
    local t0 = time.clock()
    v:compute(kit.BLOCK, ins, blocks)
    spent = spent + time.clock() - t0
    for(local j = 0; j < program.outputs; j = j + 1){
      outs[j]:set(blocks[j], at)
    }
  }
  return {channels: outs, load: spent / 1000 / seconds}
}

// mix(seconds, each, options?: {only?: {string}}) -> {channels, load}
// The mixer's stereo over seconds, the parameters set by hand: each(t,
// set, send) is called sixty times a second, as the game's frames would
// (set(name, value): a parameter; send(kind, a, b, c): an event). only:
// the layers that sound.
func kit.mix(seconds, each, options){
  options = options or {}
  local director = require("sound/director")
  local mixer = require("sound/mixer")
  local sound = director.offline()
  local costs = mixer.costs()
  local block = mixer.new(sound.shared.values, sound.shared.events, {
    sample_rate: kit.RATE, block: kit.BLOCK, only: options.only, costs: costs,
  })
  sound.set("awake", 1)
  local r = kit.run(seconds, block, func(t, dt){
    each(t, sound.set, sound.send)
  })
  r.costs = costs
  return r
}

// run(seconds, block, frame) -> {channels, load}: frame(t, dt) sixty
// times a second, and the block function's stereo between them
func kit.run(seconds, block, frame){
  local frames = to_int(seconds * kit.RATE / kit.BLOCK) * kit.BLOCK
  local left = kernel.float:array(frames)
  local right = kernel.float:array(frames)
  local out = kernel.float:array(kit.BLOCK * 2)
  local dt = 1 / 60
  local at = 0
  local owed = 0.0
  local spent = 0
  local t = 0.0
  for(at < frames){
    frame(t, dt)
    t = t + dt
    owed = owed + dt * kit.RATE
    for(owed >= kit.BLOCK and at < frames){
      local t0 = time.clock()
      block(out, kit.BLOCK)
      spent = spent + time.clock() - t0
      for(local i = 0; i < kit.BLOCK; i = i + 1){
        left[at + i] = out[2 * i]
        right[at + i] = out[2 * i + 1]
      }
      at = at + kit.BLOCK
      owed = owed - kit.BLOCK
    }
  }
  return {channels: {left, right}, load: spent / 1000 / seconds}
}

// behind(car, distance, height) -> a view (the listener) behind the
// truck, as the game's camera follows it
func kit.behind(car, distance, height){
  local f = car.forward
  local flat = math.max(math.sqrt(f.x * f.x + f.z * f.z), 0.001)
  local fx = f.x / flat
  local fz = f.z / flat
  local eye = {x: car.pos.x - fx * distance, y: car.pos.y + height, z: car.pos.z - fz * distance}
  local to = {x: car.pos.x - eye.x, y: car.pos.y + 0.6 - eye.y, z: car.pos.z - eye.z}
  local d = math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z)
  local forward = {x: to.x / d, y: to.y / d, z: to.z / d}
  // (to the right of where it looks, on the ground)
  local r = math.max(math.sqrt(forward.x * forward.x + forward.z * forward.z), 0.001)
  return {eye: eye, forward: forward, right: {x: -forward.z / r, y: 0, z: forward.x / r}}
}

// drive(options) -> {channels, load, world}: the game as it sounds, the
// bot driving the Summit Run and the camera behind the truck listening.
// options: {seed?: int (7), from?: float (m along the trail, 0),
//   seconds?: float (30), heavy?: bool, only?: {string},
//   input?: func(t, world, input) -> input, before?: func(world),
//   each?: func(t, world, sound), keep?: bool}
// [heavy]: a heavy foot: wherever the bot gives gas it is all of it (a
//   player drives harder than the bot)
// [only]: the layers that sound
// [input]: changes what the bot does (or does it all: the bot's input is
//   handed in)
// [before]: before the first frame (the truck set somewhere else)
// [each]: after every frame (sound: the director)
// [keep]: the world is not destroyed (it is in the result)
func kit.drive(options){
  options = options or {}
  local world = require("game/world")
  local bot = require("game/bot")
  local explore = require("game/explore")
  local director = require("sound/director")
  local mixer = require("sound/mixer")
  local seconds = options.seconds or 30
  local w = world.new({seed: options.seed or 7})
  local driver = bot.new()
  if((options.from or 0) > 0){
    driver.index = to_int(options.from / 2)
    world.recover(w, driver.index)
  }
  if(options.before != null){
    options.before(w)
  }
  // (nothing read from the player's save, and nothing written to it)
  local rules = explore.new(w, {keep: false})
  local sound = director.offline()
  local costs = mixer.costs()
  local block = mixer.new(sound.shared.values, sound.shared.events, {
    sample_rate: kit.RATE, block: kit.BLOCK, only: options.only, costs: costs,
  })
  local r = kit.run(seconds, block, func(t, dt){
    // the engine is started a moment in, the truck driven once it runs
    local input = if(t < 2.2){ {} } else { driver:drive(w, dt) }
    if(options.heavy and (input.forward or 0) > 0.15 and (input.back or 0) < 0.1){
      input.forward = 1
    }
    if(options.input != null){
      input = options.input(t, w, input)
    }
    world.step(w, input, dt)
    local events = explore.step(rules, w, input, dt)
    sound:engine(t > 0.5)
    sound:frame({
      world: w, car: w.car, view: kit.behind(w.car, 7.6, 2.5), dt: dt, damage: rules.damage,
      input: input, events: events, screen: "drive",
    })
    if(options.each != null){
      options.each(t, w, sound)
    }
  })
  r.costs = costs
  if(options.keep){
    r.world = w
  } else {
    world.destroy(w)
  }
  return r
}

return kit
