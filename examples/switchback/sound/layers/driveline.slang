// sound/layers/driveline: what is between the truck's engine and its
// wheels, as it sounds: the gears' whine (the gearbox's engaged pair, the
// transfer case in low range, the reverse gear, the axles' hum:
// sound/driveline/gears.dsp), the brakes (brakes.dsp), and the things
// that happen once, each a blow on something (sound/body/struck.dsp, with
// the numbers below): the clunk of the driveline's slack when the torque
// through it changes sides, the gear lever's clicks as the box changes
// gear, the transfer lever's clonk, the air lockers' hiss and clack, the
// hand brake's ratchet.
//
// The game's side (watch) turns game/drivetrain's state into shaft speeds,
// torques and events; the mixer's side (voice) runs the programs, only
// those that have something to say, and places them under the truck: the
// gearbox and the transfer case under its middle, the lockers and the
// brakes at the axles.
extension "kernel/syntax"
local math = require("slang/math")
local params = require("sound/params")
local listener = require("sound/listener")

local m = {}

kernel {
  // twice as many samples of a sound computed at half the rate: every
  // other one halfway between its neighbors (last: the block before's
  // last sample, kept for the next)
  func stretch(out: float[], source: float[], last: float[], n: int){
    local before = last[0]
    for(local i = 0; i < n; i += 1){
      local x = source[i]
      out[2 * i] = (before + x) * 0.5
      out[2 * i + 1] = x
      before = x
    }
    last[0] = before
  }
}

m.params = {
  // the gearbox's output shaft and the propeller shafts, turns a second
  {"driveline_shaft", 0, 0.05},
  {"driveline_prop", 0, 0.05},
  // the engaged pair: the teeth of its gear on the output shaft, and the
  // input shaft's turns for one of the output shaft
  {"driveline_teeth", 0, 0},
  {"driveline_ratio", 1, 0},
  // the torque through the gearbox over the engine's most, and at the
  // axles over what second gear puts on them (negative: the wheels turn
  // the engine)
  {"driveline_torque", 0, 0.03},
  {"driveline_pull", 0, 0.03},
  {"driveline_low", 0, 0},
  {"driveline_reverse", 0, 0},
  // the brakes: the pedal, the wheels' turns a second, the squeak (how
  // loud, how high)
  {"driveline_brake", 0, 0.03},
  {"driveline_wheel", 0, 0.03},
  {"driveline_squeak", 0, 0.02},
  {"driveline_pitch", 2200, 0},
  // the gains of the truck's middle and of its two axles
  {"driveline_mid_left", 0, 0.03},
  {"driveline_mid_right", 0, 0.03},
  {"driveline_front_left", 0, 0.03},
  {"driveline_front_right", 0, 0.03},
  {"driveline_rear_left", 0, 0.03},
  {"driveline_rear_right", 0, 0.03},
}

// what happens once: an event each
local BASE = params.EVENTS.driveline
m.LASH = BASE // the slack taken up: a = how hard, 0 to 1
m.LEVER = BASE + 1 // the gear lever: a = 0 out of a gear, 1 into the next, 2 into one from rest
m.RANGE = BASE + 2 // the transfer case: a = 1 into low range, 0 into high, 2 its lever moved
m.LOCK = BASE + 3 // an air locker: a = 0 the front axle's, 1 the rear's; b = 1 locked, 0 let go
m.HAND = BASE + 4 // the hand brake: a = 1 pulled, 0 let go

// the gearbox's gears on its output shaft, by gear, and the reverse
// gear's: with the gears on the input shaft they make the ratios of
// game/drivetrain (50 : 12 is 4.17, 47 : 20, 41 : 27, 40 : 35, 34 : 39;
// 48 : 13 through an idler)
m.TEETH = {50, 47, 41, 40, 34}
m.REVERSE_TEETH = 48

// where they are on the truck (its frame: x left, y up, z forward)
local MIDDLE = {x: 0, y: -0.05, z: 0.3}
local FRONT = {x: 0, y: 0, z: 1.36}
local REAR = {x: 0, y: 0, z: -1.36}

// the engine's most torque, N m, and what second gear in high range
// makes of it at the axles: what the torques are told in
local FULL = 400
local SECOND = FULL * 2.34 * 4.10
// under this much torque either way the teeth lie on neither flank, N m
local SLACK = 25
// the torque is felt without its quickest shaking (the wheels of a truck
// that brakes on loose ground chatter, and the clutch's torque with
// them): over this long, s
local FELT = 0.05
// a swing of the torque this fast is the hardest clunk, N m/s
local SWING = 3000
// no two clunks nearer than this, s
local APART = 0.2
// a lever or a switch has to stay where it was put before what it moves
// is heard (one flicked back at once moved nothing): the transfer lever
// this long, a locker's switch this long, s
local THROW = 0.2
local VALVE = 0.1
// after the truck was put somewhere (towed, righted) its driveline is
// not where it was: nothing of that is heard, for this long, s
local PUT = 0.7
// how many stops in a hundred end in a squeak
local SQUEAKS = 30

// ------------------------------------------------------------ the game's side

// watcher() -> the layer's state in the main isolate
func m.watcher(){
  return {
    seen: false, // the first frame only looks
    quiet: 0, // how long nothing that happens once is heard yet, s
    pos: {x: 0, y: 0, z: 0},
    speed: 0,
    gear: 0,
    shifting: false,
    hand: 0,
    // the transfer lever and the lockers' switches: where each is, where
    // it was last heard to be, how long it has been where it is
    low: {is: false, heard: false, time: 1, settle: THROW},
    front: {is: false, heard: false, time: 1, settle: VALVE},
    rear: {is: false, heard: false, time: 1, settle: VALVE},
    flank: 0, // which side the teeth lie on: 1 driving, -1 coasting, 0 slack
    felt: 0, // the clutch's torque without its shaking
    swing: 0, // how fast it changes, N m/s
    open: 0, // how long the clutch has been open, s
    since_lash: 1,
    braking: false, // a stop is under way
    released: 1, // how long the pedal has been up, s
    squeaky: false, // this stop will squeak at its end
    squeaked: 0, // how long it has, s
    pitch: 2200,
    seed: 12345,
  }
}

// a number from 0 to 1, another every time
local func chance(w){
  w.seed = (w.seed * 1103515245 + 12345) & 2147483647
  return w.seed / 2147483648
}

// a lever or a switch (see the watcher) put where it is now: true once it
// has stayed there long enough to be heard
local func settled(sw, is, dt){
  if(is != sw.is){
    sw.is = is
    sw.time = 0
  }
  sw.time = sw.time + dt
  if(sw.time >= sw.settle and sw.is != sw.heard){
    sw.heard = sw.is
    return true
  }
  return false
}

// watch(w, s, set, send): a frame (s: sound/director's Frame)
func m.watch(w, s, set, send){
  local car = s.car
  local d = car.drive
  local spec = d.spec
  local dt = math.max(s.dt or 1 / 60, 0.001)
  local gear = d.gear
  local shifting = d.shift != null
  local low = d.low == true
  local front = d.locks.front == true
  local rear = d.locks.rear == true
  local hand = car.hand_brake or 0
  local clutch = d.clutch_torque or 0

  // ---- was the truck put somewhere (towed, righted, set on the trail)?
  // It was, if it is far from where it was, or its speed changed more
  // in a frame than any driving changes it. Its gears and its torque
  // jump then, which is nothing to hear.
  local pos = car.pos
  local along = car.speed or 0
  local dx = pos.x - w.pos.x
  local dy = pos.y - w.pos.y
  local dz = pos.z - w.pos.z
  local put = dx * dx + dy * dy + dz * dz > 9 + 9 * along * along * dt * dt or
    math.abs(along - w.speed) > 2
  for(let local e in values(s.events or {})){
    if(e.kind == "recover" or e.kind == "breakdown" or e.kind == "wreck"){
      put = true
    }
  }
  if(put and w.seen){
    w.quiet = PUT
  }
  w.quiet = math.max(0, w.quiet - dt)
  local heard = w.seen and w.quiet == 0
  w.pos.x = pos.x
  w.pos.y = pos.y
  w.pos.z = pos.z
  w.speed = along

  // ---- the shafts: the wheels' turns, the propeller shafts', the
  // gearbox's output's
  local wheel = math.abs(d.wheel_side or 0) / (2 * math.pi)
  local prop = wheel * spec.final
  local shaft = if(low){ prop * spec.low } else { prop }
  local teeth = 0
  local ratio = 1
  if(gear > 0){
    teeth = m.TEETH[gear - 1] or 40
    ratio = spec.gears[gear - 1]
  } else if(gear < 0){
    teeth = m.REVERSE_TEETH
    ratio = math.abs(spec.reverse)
  }
  set("driveline_shaft", shaft)
  set("driveline_prop", prop)
  set("driveline_teeth", teeth)
  set("driveline_ratio", ratio)
  set("driveline_torque", clutch / FULL)
  local whole = ratio * spec.final * (if(low){ spec.low } else { 1 })
  set("driveline_pull", clutch * whole / SECOND)
  set("driveline_low", if(low){ 1 } else { 0 })
  set("driveline_reverse", if(gear < 0){ 1 } else { 0 })

  // ---- the slack. The teeth, the splines and the joints from the
  // gearbox to the wheels all have a little play: while the engine pulls
  // they lie on one side of it, while the wheels push on the other, and
  // when the torque changes sides they cross it and meet with a clunk,
  // the harder the faster the torque swings (and the lower the gear).
  w.since_lash = w.since_lash + dt
  local before = w.felt
  w.felt = w.felt + (clutch - w.felt) * (1 - math.exp(-dt / FELT))
  w.swing = w.swing + (math.abs(w.felt - before) / dt - w.swing) * 0.5
  if((d.clutch or 0) < 0.05 or gear == 0 or shifting){
    // nothing holds the teeth: they fall back into the middle
    w.open = w.open + dt
    if(w.open > 0.15){
      w.flank = 0
    }
  } else {
    w.open = 0
  }
  local side = if(w.felt > SLACK){ 1 } else if(w.felt < -SLACK){ -1 } else { 0 }
  if(side != 0 and side != w.flank){
    local strength = math.min(w.swing / SWING, 1) *
      math.min(math.max(math.sqrt(whole / 9.6), 0.7), 1.6)
    if(w.flank == 0){
      // (from the middle it is half the way)
      strength = strength * 0.7
    }
    w.flank = side
    if(heard and strength > 0.05 and w.since_lash > APART){
      send(m.LASH, math.min(strength, 1))
      w.since_lash = 0
    }
  }

  // ---- the levers and the switches
  if(not heard){
    // (the first frame, and a truck just put somewhere: all is as it is
    // found, with nothing to hear)
    w.low.is = low
    w.low.heard = low
    w.front.is = front
    w.front.heard = front
    w.rear.is = rear
    w.rear.heard = rear
  } else {
    if(shifting and not w.shifting){
      send(m.LEVER, 0)
    }
    if(gear != w.gear and gear != 0){
      send(m.LEVER, if(w.shifting){ 1 } else { 2 })
    }
    if(low != w.low.is and w.low.time > VALVE){
      // the transfer lever's click, as it is moved
      send(m.RANGE, 2)
    }
    if(hand != w.hand){
      send(m.HAND, if(hand > 0){ 1 } else { 0 })
    }
  }
  if(settled(w.low, low, dt)){
    send(m.RANGE, if(low){ 1 } else { 0 })
  }
  if(settled(w.front, front, dt)){
    send(m.LOCK, 0, if(front){ 1 } else { 0 })
  }
  if(settled(w.rear, rear, dt)){
    send(m.LOCK, 1, if(rear){ 1 } else { 0 })
  }
  w.gear = gear
  w.shifting = shifting
  w.hand = hand
  w.seen = true

  // ---- the brakes: the pads on the discs, and now and then a squeak in
  // the last meters of a stop
  local press = car.brake or 0
  local speed = wheel * 2 * math.pi * spec.wheel_radius
  set("driveline_brake", press)
  set("driveline_wheel", wheel)
  if(press > 0.2){
    if(not w.braking and w.released > 0.4 and speed > 2.5){
      // a stop begins: whether it will squeak, and how high
      w.braking = true
      w.squeaky = chance(w) * 100 < SQUEAKS
      w.squeaked = 0
      w.pitch = 1750 + 1000 * chance(w)
    }
    w.released = 0
  } else {
    w.released = w.released + dt
    if(w.released > 0.4){
      w.braking = false
      w.squeaky = false
    }
  }
  local squeak = 0
  if(w.squeaky and press > 0.15 and speed < 2.2 and speed > 0.05){
    // (it comes in, wears off after a second or so, and ends with the
    // stop)
    w.squeaked = w.squeaked + dt
    squeak = math.min((2.2 - speed) / 0.6, 1) * math.min(speed / 0.25, 1) *
      math.min(press / 0.4, 1) *
      math.min(math.max((1.6 - w.squeaked) / 0.5, 0), 1)
  }
  set("driveline_squeak", squeak)
  // (a little lower as the disc slows)
  set("driveline_pitch", w.pitch * (0.95 + 0.05 * math.min(speed / 2.2, 1)))

  // ---- where it all is for the listener
  local mid = listener.place(s.view, listener.at(car, MIDDLE))
  set("driveline_mid_left", mid.left)
  set("driveline_mid_right", mid.right)
  local f = listener.place(s.view, listener.at(car, FRONT))
  set("driveline_front_left", f.left)
  set("driveline_front_right", f.right)
  local r = listener.place(s.view, listener.at(car, REAR))
  set("driveline_rear_left", r.left)
  set("driveline_rear_right", r.right)
}

// ------------------------------------------------------------ what is struck

// The numbers of sound/body/struck.dsp for each thing that is struck
// here: how high the blow reaches (hard, Hz), six modes (f: Hz, t: the
// seconds each rings, g: its share), the blow's own noise (rough: its
// share, rise and fall in seconds, band in Hz, width), and how loud a
// blow of strength 1 is (level: about its peak).
// type Recipe = {hard: float, f: {float}, t: {float}, g: {float},
//   rough: float, rise: float, fall: float, band: float, width: float,
//   level: float, tail: float}
// [tail]: how long after a blow there is something to hear, s
m.RECIPES = {
  // the driveline's slack taken up: a dull knock of heavy steel in oil
  lash: {
    hard: 700,
    f: {96, 188, 410, 890, 1650, 2700},
    t: {0.07, 0.06, 0.045, 0.03, 0.02, 0.012},
    g: {1, 0.8, 0.5, 0.26, 0.12, 0.05},
    rough: 0.25,
    rise: 0.0004,
    fall: 0.012,
    band: 700,
    width: 0.8,
    level: 0.14,
    tail: 0.25,
  },
  // the gear lever leaving a gear: a soft click of its gate
  lever_out: {
    hard: 2500,
    f: {320, 760, 1500, 2900, 4100, 5200},
    t: {0.03, 0.02, 0.015, 0.01, 0.008, 0.006},
    g: {0.6, 1, 0.5, 0.25, 0.1, 0.05},
    rough: 0.4,
    rise: 0.0003,
    fall: 0.006,
    band: 2200,
    width: 0.8,
    level: 0.04,
    tail: 0.15,
  },
  // and going into the next: a little heavier, the gear's sleeve with it
  lever_in: {
    hard: 2200,
    f: {240, 610, 1350, 2500, 3600, 4800},
    t: {0.04, 0.025, 0.015, 0.01, 0.008, 0.006},
    g: {0.9, 1, 0.45, 0.2, 0.1, 0.04},
    rough: 0.4,
    rise: 0.0003,
    fall: 0.007,
    band: 1800,
    width: 0.8,
    level: 0.05,
    tail: 0.15,
  },
  // the transfer lever's dogs meeting: light ticks before the clonk
  dogs: {
    hard: 5000,
    f: {1150, 2300, 3500, 4900, 640, 6400},
    t: {0.014, 0.012, 0.01, 0.008, 0.02, 0.006},
    g: {1, 0.7, 0.4, 0.2, 0.4, 0.1},
    rough: 0.4,
    rise: 0.0002,
    fall: 0.004,
    band: 3500,
    width: 0.8,
    level: 0.035,
    tail: 0.1,
  },
  // the transfer case going into a range: a heavy clonk
  range: {
    hard: 1400,
    f: {74, 152, 330, 720, 1500, 2600},
    t: {0.09, 0.08, 0.06, 0.04, 0.025, 0.015},
    g: {1, 0.9, 0.6, 0.4, 0.2, 0.08},
    rough: 0.35,
    rise: 0.0004,
    fall: 0.015,
    band: 600,
    width: 0.7,
    level: 0.2,
    tail: 0.3,
  },
  // an air locker's valve: a short hiss as the air goes in
  air_in: {
    hard: 2000,
    f: {200, 400, 800, 1600, 2400, 3200},
    t: {0.05, 0.05, 0.05, 0.05, 0.05, 0.05},
    g: {0, 0, 0, 0, 0, 0},
    rough: 1,
    rise: 0.004,
    fall: 0.09,
    band: 5200,
    width: 1.1,
    level: 0.1,
    tail: 0.3,
  },
  // and a longer, lower one as it is let out
  air_out: {
    hard: 2000,
    f: {200, 400, 800, 1600, 2400, 3200},
    t: {0.05, 0.05, 0.05, 0.05, 0.05, 0.05},
    g: {0, 0, 0, 0, 0, 0},
    rough: 1,
    rise: 0.006,
    fall: 0.22,
    band: 3800,
    width: 0.9,
    level: 0.08,
    tail: 0.5,
  },
  // the locker's dog clutch going home: a clack
  clack: {
    hard: 6000,
    f: {640, 1480, 2950, 4600, 320, 6100},
    t: {0.03, 0.025, 0.018, 0.012, 0.03, 0.008},
    g: {0.7, 1, 0.6, 0.3, 0.3, 0.1},
    rough: 0.3,
    rise: 0.0002,
    fall: 0.006,
    band: 3000,
    width: 0.8,
    level: 0.09,
    tail: 0.15,
  },
  // a tooth of the hand brake's ratchet
  ratchet: {
    hard: 8000,
    f: {2100, 3700, 5400, 440, 7200, 1150},
    t: {0.012, 0.01, 0.007, 0.02, 0.005, 0.012},
    g: {1, 0.7, 0.35, 0.3, 0.15, 0.3},
    rough: 0.5,
    rise: 0.0002,
    fall: 0.004,
    band: 4500,
    width: 0.8,
    level: 0.05,
    tail: 0.1,
  },
  // the hand brake's lever dropping back
  lever_down: {
    hard: 900,
    f: {180, 420, 950, 1700, 2600, 3400},
    t: {0.04, 0.03, 0.02, 0.015, 0.01, 0.008},
    g: {1, 0.7, 0.3, 0.15, 0.06, 0.03},
    rough: 0.2,
    rise: 0.0004,
    fall: 0.01,
    band: 800,
    width: 0.8,
    level: 0.04,
    tail: 0.15,
  },
}

// ------------------------------------------------------------ the mixer's side

// the levels in the mix: the gears, the brakes, and everything that is
// struck (each thing's own level is in its recipe)
local GEARS = 0.017
local BRAKES = 0.035
local BLOWS = 0.55

// how many things can ring at once
local VOICES = 3
// how many blows can wait their turn (a ratchet is five)
local WAITING = 16
// how long a program runs on after it had something to say (its levels
// glide out in that time), s
local LINGER = 0.25

// the places a blow can be heard from
local AT_MIDDLE = 0
local AT_FRONT = 1
local AT_REAR = 2

// voice(ctx) -> {block, on}: see sound/mixer
func m.voice(ctx){
  local kernel = require("kernel")
  local gears = require("sound/driveline/gears")
  local brakes = require("sound/driveline/brakes")
  local struck = require("sound/body/struck")
  local now = ctx.now
  local slot = ctx.slot
  local rate = ctx.rate
  local none = {}

  // a program's field for one of its controls
  local func field(program, label){
    return program.by_label[label].field
  }

  // ---- the gears: computed at half the sample rate (nothing of them
  // is higher than a few thousand Hz, and they are heard all the time
  // the truck moves) and stretched; they run while a shaft turns
  local g = {
    inst: gears:new({sample_rate: to_int(rate / 2)}),
    half: {kernel.float:array(to_int(ctx.size / 2) + 1)},
    out: kernel.float:array(ctx.size + 2),
    last: kernel.float:array(1),
    idle: 1000.0,
    was: {left: 0, right: 0},
    to: {left: 0, right: 0},
    shaft: field(gears, "shaft"),
    prop: field(gears, "prop"),
    teeth: field(gears, "teeth"),
    ratio: field(gears, "ratio"),
    torque: field(gears, "torque"),
    pull: field(gears, "pull"),
    reverse: field(gears, "reverse"),
    low: field(gears, "low"),
  }
  // ---- the brakes: while the pedal is down
  local b = {
    inst: brakes:new({sample_rate: rate}),
    out: {kernel.float:array(ctx.size)},
    idle: 1000.0,
    was: {left: 0, right: 0},
    to: {left: 0, right: 0},
    press: field(brakes, "press"),
    wheel: field(brakes, "wheel"),
    squeak: field(brakes, "squeak"),
    pitch: field(brakes, "pitch"),
  }

  // ---- the things that are struck: a few voices, each a blow at a time
  local labels = {
    f: {"f1", "f2", "f3", "f4", "f5", "f6"},
    t: {"t1", "t2", "t3", "t4", "t5", "t6"},
    g: {"g1", "g2", "g3", "g4", "g5", "g6"},
  }
  local fields = {f: {}, t: {}, g: {}}
  for(local i = 0; i < 6; i = i + 1){
    fields.f[i] = field(struck, labels.f[i])
    fields.t[i] = field(struck, labels.t[i])
    fields.g[i] = field(struck, labels.g[i])
  }
  local hit = field(struck, "hit")
  local power = field(struck, "power")
  local hard = field(struck, "hard")
  local rough = field(struck, "rough")
  local rise = field(struck, "rise")
  local fall = field(struck, "fall")
  local band = field(struck, "band")
  local width = field(struck, "width")
  local voices = {}
  for(local i = 0; i < VOICES; i = i + 1){
    local inst = struck:new({sample_rate: rate})
    voices[i] = {
      inst: inst,
      state: inst.state,
      out: {kernel.float:array(ctx.size)},
      until: 0,
      hits: 0,
      left: slot.driveline_mid_left,
      right: slot.driveline_mid_right,
      was: {left: 0, right: 0},
      to: {left: 0, right: 0},
    }
  }
  local places = {
    [AT_MIDDLE]: {
      left: slot.driveline_mid_left,
      right: slot.driveline_mid_right,
    },
    [AT_FRONT]: {
      left: slot.driveline_front_left,
      right: slot.driveline_front_right,
    },
    [AT_REAR]: {
      left: slot.driveline_rear_left,
      right: slot.driveline_rear_right,
    },
  }
  local clock = 0.0
  local seed = 4711
  // a number from -1 to 1, another every time
  local func scatter(){
    seed = (seed * 1103515245 + 12345) & 2147483647
    return seed / 1073741824 - 1
  }

  // strike(recipe, strength, place, tune): a blow now, on the voice that
  // has been silent longest
  local func strike(recipe, strength, place, tune){
    local v = voices[0]
    for(local i = 1; i < VOICES; i = i + 1){
      if(voices[i].until < v.until){
        v = voices[i]
      }
    }
    local st = v.state
    // (no two blows alike: each a little higher or lower, its modes'
    // shares a little other)
    local pitch = tune * (1 + 0.03 * scatter())
    for(local i = 0; i < 6; i = i + 1){
      st[fields.f[i]] = recipe.f[i] * pitch
      st[fields.t[i]] = recipe.t[i]
      st[fields.g[i]] = recipe.g[i] * (1 + 0.25 * scatter())
    }
    st[hard] = recipe.hard * (0.6 + 0.4 * strength)
    st[rough] = recipe.rough
    st[rise] = recipe.rise
    st[fall] = recipe.fall
    st[band] = recipe.band * pitch
    st[width] = recipe.width
    st[power] = recipe.level * strength * BLOWS
    v.hits = v.hits + 1
    st[hit] = v.hits
    v.until = clock + recipe.tail
    v.left = places[place].left
    v.right = places[place].right
  }

  // the blows that wait their turn
  local waiting = {}
  for(local i = 0; i < WAITING; i = i + 1){
    waiting[i] = {
      live: false, at: 0, recipe: null, strength: 0, place: 0, tune: 1
    }
  }
  local queued = 0
  // later(after, recipe, strength, place, tune): a blow in `after` seconds
  local func later(after, recipe, strength, place, tune){
    for(local i = 0; i < WAITING; i = i + 1){
      local e = waiting[i]
      if(not e.live){
        e.live = true
        e.at = clock + after
        e.recipe = recipe
        e.strength = strength
        e.place = place
        e.tune = tune
        queued = queued + 1
        return
      }
    }
  }

  local R = m.RECIPES
  return {
    // on(kind, a, b, c): what happened once
    on: func(kind, x, y, z){
      if(kind == m.LASH){
        strike(R.lash, math.max(x, 0.05), AT_MIDDLE, 1)
      } else if(kind == m.LEVER){
        if(x == 0){
          strike(R.lever_out, 1, AT_MIDDLE, 1)
        } else if(x == 1){
          strike(R.lever_in, 1, AT_MIDDLE, 1)
        } else {
          strike(R.lever_in, 1.3, AT_MIDDLE, 0.92)
        }
      } else if(kind == m.RANGE){
        if(x == 2){
          // the lever
          strike(R.lever_out, 1.2, AT_MIDDLE, 0.85)
        } else {
          // the dogs finding each other, the clonk (into low range the
          // heavier)
          strike(R.dogs, 0.7, AT_MIDDLE, 1)
          later(0.035 + 0.01 * scatter(), R.dogs, 1, AT_MIDDLE, 0.94)
          later(
            0.075, R.range, if(x > 0){ 1 } else { 0.7 }, AT_MIDDLE,
            if(x > 0){ 1 } else { 1.12 }
          )
        }
      } else if(kind == m.LOCK){
        // the valve, then the dogs (the front axle's a moment after the
        // rear's, and a little higher)
        local place = if(x > 0){ AT_REAR } else { AT_FRONT }
        local tune = if(x > 0){ 1 } else { 1.09 }
        local wait = if(x > 0){ 0 } else { 0.07 }
        if(y > 0){
          later(wait, R.air_in, 1, place, tune)
          later(wait + 0.11 + 0.02 * scatter(), R.clack, 1, place, tune)
        } else {
          later(wait, R.air_out, 1, place, tune)
          later(
            wait + 0.06 + 0.015 * scatter(), R.clack, 0.5, place, tune * 0.9
          )
        }
      } else if(kind == m.HAND){
        if(x > 0){
          // five teeth, slower and harder as the cable tightens
          local at = 0
          for(local i = 0; i < 5; i = i + 1){
            later(at, R.ratchet, 0.6 + 0.1 * i, AT_MIDDLE, 1 + 0.015 * i)
            at = at + (0.038 + 0.007 * i) * (1 + 0.12 * scatter())
          }
        } else {
          // (let go before it was pulled all the way: the teeth left are
          // never heard)
          for(local i = 0; i < WAITING; i = i + 1){
            local e = waiting[i]
            if(e.live and e.recipe == R.ratchet){
              e.live = false
              queued = queued - 1
            }
          }
          strike(R.ratchet, 0.7, AT_MIDDLE, 0.9)
          later(0.07, R.lever_down, 1, AT_MIDDLE, 1)
        }
      }
    },
    // block(n): n frames of the driveline into the truck's bus
    block: func(n){
      local span = n / rate
      clock = clock + span
      // the blows whose time has come
      if(queued > 0){
        for(local i = 0; i < WAITING; i = i + 1){
          local e = waiting[i]
          if(e.live and e.at <= clock){
            e.live = false
            queued = queued - 1
            strike(e.recipe, e.strength, e.place, e.tune)
          }
        }
      }
      // the gears
      local shaft = now[slot.driveline_shaft]
      if(shaft > 0.02){
        g.idle = 0
      } else {
        g.idle = g.idle + span
      }
      g.to.left = now[slot.driveline_mid_left] * GEARS
      g.to.right = now[slot.driveline_mid_right] * GEARS
      if(g.idle < LINGER){
        local st = g.inst.state
        st[g.shaft] = shaft
        st[g.prop] = now[slot.driveline_prop]
        st[g.teeth] = now[slot.driveline_teeth]
        st[g.ratio] = now[slot.driveline_ratio]
        st[g.torque] = now[slot.driveline_torque]
        st[g.pull] = now[slot.driveline_pull]
        st[g.reverse] = now[slot.driveline_reverse]
        st[g.low] = now[slot.driveline_low]
        local half = to_int((n + 1) / 2)
        g.inst:compute(half, none, g.half)
        stretch(g.out, g.half[0], g.last, half)
        ctx.place(ctx.truck, g.out, g.was, g.to, n)
      } else {
        g.was.left = g.to.left
        g.was.right = g.to.right
      }
      // the brakes (heard from the front axle, which does most of the
      // stopping)
      local press = now[slot.driveline_brake]
      local squeak = now[slot.driveline_squeak]
      if(press > 0.002 or squeak > 0.002){
        b.idle = 0
      } else {
        b.idle = b.idle + span
      }
      b.to.left = now[slot.driveline_front_left] * BRAKES
      b.to.right = now[slot.driveline_front_right] * BRAKES
      if(b.idle < LINGER){
        local st = b.inst.state
        st[b.press] = press
        st[b.wheel] = now[slot.driveline_wheel]
        st[b.squeak] = squeak
        st[b.pitch] = now[slot.driveline_pitch]
        b.inst:compute(n, none, b.out)
        ctx.place(ctx.truck, b.out[0], b.was, b.to, n)
      } else {
        b.was.left = b.to.left
        b.was.right = b.to.right
      }
      // what was struck and still rings
      for(local i = 0; i < VOICES; i = i + 1){
        local v = voices[i]
        v.to.left = now[v.left]
        v.to.right = now[v.right]
        if(v.until > clock){
          v.inst:compute(n, none, v.out)
          ctx.place(ctx.truck, v.out[0], v.was, v.to, n)
        } else {
          v.was.left = v.to.left
          v.was.right = v.to.right
        }
      }
    },
  }
}

return m
