// sound/layers/tires: the truck's four tires on the ground. Each wheel
// runs two programs (sound/tire.dsp: the tire shaken by the ground;
// sound/tire/ground.dsp: grit, dust, what a sliding tire tears loose) and
// is placed for the listener where it touches the ground; each axle
// runs one more for the water its wheels wade through
// (sound/tire/water.dsp).
//
// The game's side (watch) turns what a wheel does into what the programs
// are told: how fast its tread runs, how fast it slides along and
// across, its load, what it stands on (sound/ground.slang: the ground's
// numbers, blended where grounds meet), how deep it is in water; a jolt
// of the suspension is a thump, a wheel going into water a splash, the
// front wheels steered where the truck stands a groan. The rules are
// in [controls]: one function from a wheel's motion and its ground to
// the programs' controls.
//
// The mixer's side (voice) runs a wheel's programs only while there is
// something to hear of it: a truck that stands is silent, and costs
// nothing. The tire's own program runs at a quarter of the mixer's rate
// (nothing of it is high), with lines drawn between its samples.
extension "kernel/syntax"
local math = require("slang/math")
local drivetrain = require("game/drivetrain")
local listener = require("sound/listener")
local params = require("sound/params")

local m = {}

m.WHEELS = 4
m.AXLES = 2

// the tire's radius, m, and the load a wheel carries when the truck
// stands, N
local RADIUS = drivetrain.SPEC.wheel_radius
local STANDING = drivetrain.SPEC.mass * 9.81 / 4

// the events: a wheel (a) thumps with a strength (b), a wheel (a)
// splashes into water with a strength (b)
m.THUMP = params.EVENTS.tires
m.SPLASH = params.EVENTS.tires + 1

// The programs' controls, as parameters: {label, start, glide, program}.
// Every wheel has the tire's and the ground's ("tire<wheel>_<label>"),
// every axle the water's ("wade<axle>_<label>"). What follows the
// wheel's motion arrives fast, what the ground is like slowly (a wheel
// crossing from grass onto gravel is a blend, not a switch).
local QUICK = 0.03
local SLOW = 0.12
local CONTROLS = {
  // sound/tire.dsp
  {"speed", 0, QUICK, "tire"},
  {"lumps", 0, QUICK, "tire"},
  {"shake", 0, QUICK, "tire"},
  {"slap", 0, QUICK, "tire"},
  {"groan", 0, 0.06, "tire"},
  // sound/tire/ground.dsp
  {"ticks", 0, QUICK, "ground"},
  {"tick_pitch", 2500, SLOW, "ground"},
  {"tick_damped", 0.1, SLOW, "ground"},
  {"tick_fade", 1000, SLOW, "ground"},
  {"tick_hard", 1, SLOW, "ground"},
  {"tick_puff", 0, SLOW, "ground"},
  {"tick_glide", 0, SLOW, "ground"},
  {"tick_even", 0.05, SLOW, "ground"},
  {"gritty", 0, QUICK, "ground"},
  {"knocks", 0, QUICK, "ground"},
  {"knock_pitch", 2500, 0.06, "ground"},
  {"knock_damped", 0.1, 0.06, "ground"},
  {"knock_fade", 1000, 0.06, "ground"},
  {"knock_hard", 1, 0.06, "ground"},
  {"knock_puff", 0, 0.06, "ground"},
  {"knock_glide", 0, 0.06, "ground"},
  {"knock_even", 0.05, 0.06, "ground"},
  {"knocking", 0, QUICK, "ground"},
  {"dust", 0, QUICK, "ground"},
  {"swish", 0, QUICK, "ground"},
  {"peel", 0, QUICK, "ground"},
  {"rasp", 0, QUICK, "ground"},
  {"rasp_pitch", 2000, SLOW, "ground"},
  {"rasp_damped", 2, SLOW, "ground"},
  {"squeal", 0, QUICK, "ground"},
  {"squeal_pitch", 700, QUICK, "ground"},
  {"squeal_damped", 0.25, QUICK, "ground"},
  {"damp", 16000, SLOW, "ground"},
}
local WATER = {
  // sound/tire/water.dsp
  {"rush", 0, 0.05, "water"},
  {"rush_pitch", 900, 0.05, "water"},
  {"drops", 0, 0.05, "water"},
  {"dripping", 0, 0.05, "water"},
  {"bubbles", 0, 0.05, "water"},
  {"bubbling", 0, 0.05, "water"},
}
m.CONTROLS = CONTROLS
m.WATER = WATER

local func wheel_name(wheel, label){
  return concat("tire", string(wheel), "_", label)
}

local func axle_name(axle, label){
  return concat("wade", string(axle), "_", label)
}

// and beside the controls, for every wheel and every axle: its gains for
// the listener, and whether there is anything to hear of it (awake)
m.params = {}
for(local i = 0; i < m.WHEELS; i = i + 1){
  for(let local c in values(CONTROLS)){
    append(m.params, {wheel_name(i, c[0]), c[1], c[2]})
  }
  append(m.params, {wheel_name(i, "left"), 0, QUICK})
  append(m.params, {wheel_name(i, "right"), 0, QUICK})
  append(m.params, {wheel_name(i, "awake"), 0, 0})
}
for(local a = 0; a < m.AXLES; a = a + 1){
  for(let local c in values(WATER)){
    append(m.params, {axle_name(a, c[0]), c[1], c[2]})
  }
  append(m.params, {axle_name(a, "left"), 0, QUICK})
  append(m.params, {axle_name(a, "right"), 0, QUICK})
  append(m.params, {axle_name(a, "awake"), 0, 0})
}

// ------------------------------------------------------------ the rules

// how loud each part of the sound is (found by measuring: see
// tool/scenes/tires_*)
local SHAKE = 1.0 // the ground's lumps through the tire
local SLAP = 1.0 // the tread's blocks
local WHIR = 0.05 // of that, in the air
local GROAN = 0.5 // the wheel steered standing
local GRIT = 0.42 // crumbs crushed
local SWISH = 0.5 // the fine of the ground
local PEEL = 0.25 // the tread peeling off
local RASP = 0.12 // what a sliding tire tears loose
local SQUEAL = 0.6 // its squeal
local KNOCK = 0.3 // what it throws against the truck
local RUSH = 0.024 // wading
local DRIP = 0.15 // drops
local BUBBLE = 0.12 // bubbles

// How the rolling's loudness grows with the speed. What the ground does
// to the tire comes more often the faster it rolls, which alone makes
// its sound grow with the root of the speed (and more in the bands the
// blows only reach when they are sharp); each blow is harder too, by
// this: 1 at 10 m/s. Together the level goes with v^1.5 to v^2: far more
// gently than the wind's.
local func fast(v){
  return v * 0.1
}

// how wide a band the programs' resonator can be at a pitch (as its
// damping): wider, it would not hold
local func widest(hz){
  local f = 2 * math.sin(math.pi * math.min(hz, 9000) / 44100)
  return 0.8 * (2 / f - f / 2)
}

local func smoothstep(a, b, v){
  local t = (v - a) / (b - a)
  if(t <= 0){
    return 0
  }
  if(t >= 1){
    return 1
  }
  return t * t * (3 - 2 * t)
}

local func mix(a, b, t){
  return a + (b - a) * t
}

// What a wheel does, as the sound needs it.
// type Motion = {contact: bool, roll: float, pass: float, crush: float,
//   slide: float, load: float, scrub: float, depth: float, flow: float,
//   wet: float, spray: float, waver: float}
// [roll]: the tread's speed, m/s (in the air too)
// [pass]: how fast the ground passes under the wheel, m/s (a wheel
//   spinning on the spot: 0)
// [crush]: how fast ground comes under the tread to be crushed, m/s:
//   rolling, sliding, and the patch twisting when the wheel is steered
// [slide]: how fast the tire slides over the ground, m/s (spinning,
//   locked, sideways)
// [load]: its load over what it carries when the truck stands (0 in
//   the air)
// [scrub]: the wheel steered where it stands, 0 to 1
// [depth]: how deep it stands in water, m
// [flow]: how fast it moves that water, m/s
// [wet]: 1 in the water, falling off once it is out (it drains)
// [spray]: what is left in the air of its last splash, 0 to 1
// [waver]: a number that wanders between -1 and 1 a few times a second
//   (nothing that holds and lets go does it evenly)

// controls(c, g, w: Motion) -> c: the programs' controls (by their
// labels, see CONTROLS and WATER) for a wheel moving as w on the ground
// g (sound/ground's numbers). The water's are this wheel's share of its
// axle's.
func m.controls(c, g, w){
  local roll = w.roll
  local pass = w.pass
  local slide = w.slide
  local crush = w.crush
  // what a load presses out of tire and ground: all of it up to the
  // load the wheel stands with, half of what is more
  local pressed = math.min(w.load, 1) + 0.5 * math.max(w.load - 1, 0)
  local root = math.sqrt(pressed)

  // ---- the tire: the ground's lumps come as fast as the ground passes,
  // over their length (a wheel spinning on the spot rolls over none);
  // the tread's blocks strike hard ground as fast as the tread runs,
  // less cleanly the more it slides, and whir in the air
  c.speed = roll
  c.lumps = pass / g.grain
  c.shake = g.rumble * pressed * fast(pass) * SHAKE
  c.slap = (g.lugs * pressed / (1 + slide / 3) +
    (if(w.contact){ 0 } else { WHIR })) * fast(roll) * SLAP
  // (the patch twisted on the ground groans where the ground holds it:
  // on rock and wood; loose and soft ground gives way instead)
  local held = math.min(g.lugs, 1)
  c.groan = w.scrub * root * held * math.sqrt(held) * GROAN

  // ---- grit: so many to a meter. Louder the harder the tire is
  // pressed and the more it slides; with the speed they first grow, then
  // no more: fast, they are so many that they are a noise, and the
  // tire's roar is over them
  local rate = g.grit * crush
  local gritty = g.tick_level * root * (1 + 0.15 * math.min(slide, 4)) *
    math.sqrt(crush / (1 + crush * crush / 36)) * GRIT
  c.tick_pitch = g.tick_pitch
  c.tick_damped = 1 / g.tick_ring
  c.tick_fade = 2 * math.pi * g.tick_pitch / g.tick_ring
  c.tick_hard = 1 - g.tick_soft
  c.tick_puff = g.tick_soft * 1.6 /
    math.sqrt(2 * math.pi * g.tick_pitch * g.tick_ring)
  c.tick_glide = g.tick_glide
  c.tick_even = g.tick_even
  c.gritty = gritty
  // The second voice: crumbs too, half of them, while the tire rolls.
  // Once it slides, the voice goes over to what the tire throws against
  // the truck: so many to a meter of sliding, with a sound of their own.
  local thrown = smoothstep(0.4, 2.0, slide) * math.min(g.fling, 1)
  c.ticks = rate * (1 + thrown) / 2
  c.knocks = rate * (1 - thrown) / 2 + g.fling * slide * thrown
  local pitch = g.tick_pitch *
    math.exp(math.log(g.knock_pitch / g.tick_pitch) * thrown)
  local ring = g.tick_ring *
    math.exp(math.log(g.knock_ring / g.tick_ring) * thrown)
  local soft = mix(g.tick_soft, g.knock_soft, thrown)
  c.knock_pitch = pitch
  c.knock_damped = 1 / ring
  c.knock_fade = 2 * math.pi * pitch / ring
  c.knock_hard = 1 - soft
  c.knock_puff = soft * 1.6 / math.sqrt(2 * math.pi * pitch * ring)
  c.knock_glide = mix(g.tick_glide, 0.3 * g.knock_soft, thrown)
  c.knock_even = mix(g.tick_even, 0.15, thrown)
  c.knocking = mix(
    gritty, g.knock_level * root * math.sqrt(math.min(slide / 6, 1.5)) * KNOCK,
    thrown
  )

  // ---- the hiss: the fine of the ground at the speed over a grain's
  // length; the tread peeling off hardly cares for the speed
  c.dust = pass / g.fine
  c.swish = g.swish * root * fast(pass) * SWISH
  c.peel = g.tack * pressed * roll / (roll + 3) * PEEL

  // ---- sliding: what is torn loose (as loud whether its band is
  // narrow or wide)
  c.rasp = g.rasp * root * slide / (slide + 4) * (1 + 0.04 * slide) /
    math.sqrt(g.rasp_pitch * g.rasp_ring) * RASP
  c.rasp_pitch = g.rasp_pitch
  c.rasp_damped = math.min(1 / g.rasp_ring, widest(g.rasp_pitch))
  // the squeal: how hard the tire works the ground (sliding, or on snow
  // just rolling), 0 to 1; the harder, the narrower the resonance, to a
  // tone; its pitch rises a little with the sliding and never stands
  // still. It is the sound of rubber that still holds now and then: it
  // comes in short cries (a third of the time), and a tire that only
  // spins has less and less of it
  local worked = slide + g.pack * 2 * math.min(roll, 4)
  local hard = worked * worked / (worked * worked + 4)
  local sharp = 4 + 36 * hard
  local sung = g.squeak_pitch * (1 + 0.012 * math.min(slide, 10)) *
    (1 + 0.035 * w.waver)
  c.squeal = g.squeak * root * hard / (1 + slide * slide / 64) /
    math.sqrt(sharp * sung) * math.min(math.max(w.waver * 2 - 0.4, 0), 1) *
    SQUEAL
  c.squeal_pitch = sung
  c.squeal_damped = 1 / sharp
  c.damp = g.damp

  // ---- water: the deeper the tire is in and the faster it moves the
  // water, the louder the rush, and a little brighter (it sloshes); a
  // few drops where spray flies and where the tire drains; bubbles under
  // it
  local wade = smoothstep(0.03, 0.22, w.depth)
  local flow = w.flow
  local rush_pitch = 200 + 30 * math.min(flow, 12)
  c.rush = wade * math.min(flow / 8, 1) / math.sqrt(0.7 * rush_pitch) *
    (1 + 0.4 * w.waver) * RUSH
  c.rush_pitch = rush_pitch
  c.drops = wade * 5 * flow + 60 * w.spray + 25 * w.wet * w.wet * (1 - wade)
  c.bubbles = wade * (2 + 1.5 * flow) + 12 * w.spray
  return c
}

// ------------------------------------------------------------ the game's side

// what counts as moving at all, m/s: under it a wheel stands (the
// physics never holds a truck quite still)
local STILL = 0.03
// how hard the suspension must be hit for a thump, m/s (how much faster
// it is pushed in than a moment before), and how soon the next may come
local JOLT = 0.12
local AGAIN = 0.085
// how deep the water must be for a splash, m, and how fast a wheel must
// go in for the biggest, m/s
local SPLASH_DEPTH = 0.05
local SPLASH_SPEED = 6

// (sound/ground and game/terrain are the game's side's alone: the mixer's
// isolate never loads them)
local ground = null
local terrain = null

// watcher() -> the layer's state in the main isolate
func m.watcher(){
  ground = require("sound/ground")
  terrain = require("game/terrain")
  local wheels = {}
  for(local i = 0; i < m.WHEELS; i = i + 1){
    local names = {}
    for(let local c in values(CONTROLS)){
      append(names, wheel_name(i, c[0]))
    }
    append(wheels, {
      names: names,
      left: wheel_name(i, "left"),
      right: wheel_name(i, "right"),
      awake: wheel_name(i, "awake"),
      // what it stands on, what it does, what the programs are told
      ground: ground.set(ground.material(), require("game/surfaces").rock),
      motion: {
        contact: false,
        roll: 0,
        pass: 0,
        crush: 0,
        slide: 0,
        load: 0,
        scrub: 0,
        depth: 0,
        flow: 0,
        wet: 0,
        spray: 0,
        waver: 0,
      },
      controls: {},
      // the suspension's length and the wheel's turn a frame ago, how
      // fast the suspension was pushed in lately, how long since a thump
      length: null,
      steer: null,
      pushed: 0,
      since: 1,
      // how long there is still something to hear of it, s; whether it
      // is wet; its gains
      stir: 0,
      wet: false,
      gain_left: 0,
      gain_right: 0,
    })
  }
  local axles = {}
  for(local a = 0; a < m.AXLES; a = a + 1){
    local names = {}
    for(let local c in values(WATER)){
      names[c[0]] = axle_name(a, c[0])
    }
    append(axles, {
      names: names,
      left: axle_name(a, "left"),
      right: axle_name(a, "right"),
      awake: axle_name(a, "awake"),
    })
  }
  return {wheels: wheels, axles: axles, at: null, time: 0}
}

// how deep a wheel stands in water: the land's water over where the
// wheel touches (a wheel of a truck that is on no land says so itself:
// `wading`)
local func depth_of(world, wheel){
  if(not wheel.contact){
    return 0
  }
  if(world == null or world.land == null or world.land.water == null){
    return wheel.wading or 0
  }
  local land = world.land
  local p = wheel.point
  local over = math.max(0, p.y - terrain.height_at(land, p.x, p.z))
  return math.max(0, terrain.water_at(land, p.x, p.z) - over)
}

// watch(w, s, set, send): a frame (s: sound/director's Frame)
func m.watch(w, s, set, send){
  local car = s.car
  if(car == null or car.wheels == null){
    return
  }
  local dt = math.max(s.dt or 1 / 60, 0.001)
  w.time = w.time + dt
  // the truck set down somewhere else (towed, started again): nothing
  // on the way there was a bump or a splash
  local moved = false
  local pos = car.pos
  if(w.at == null){
    w.at = {x: pos.x, y: pos.y, z: pos.z}
    moved = true
  } else {
    local dx = pos.x - w.at.x
    local dy = pos.y - w.at.y
    local dz = pos.z - w.at.z
    moved = dx * dx + dy * dy + dz * dz > 9
    w.at.x = pos.x
    w.at.y = pos.y
    w.at.z = pos.z
  }
  for(local i = 0; i < m.WHEELS; i = i + 1){
    local wheel = car.wheels[i]
    local st = w.wheels[i]
    local motion = st.motion
    local contact = wheel.contact == true
    local tread = (wheel.omega or 0) * RADIUS
    local along = if(contact){ wheel.along_speed or 0 } else { 0 }
    local across = if(contact){ wheel.across_speed or 0 } else { 0 }
    local roll = math.abs(tread)
    if(roll < STILL){
      roll = 0
    }
    // how fast the tire slides: along (spinning or locked) and across
    local slide = 0
    if(contact){
      local spin = tread - along
      slide = math.max(math.sqrt(spin * spin + across * across) - STILL, 0)
    }
    // the front wheels steered: how fast, and how much of that is on
    // the spot (rolling, a wheel turns without twisting its patch)
    local steer = wheel.steer or 0
    local turned = if(st.steer == null or moved){ 0 } else { math.abs(
      steer - st.steer,
    ) / dt }
    st.steer = steer
    local ground_speed = math.max(roll, math.abs(along))
    local scrub = 0
    local crush = 0
    if(contact){
      scrub = math.min(turned / 1.5, 1) /
        (1 + ground_speed * ground_speed / 1.44)
      crush = math.max(
        ground_speed + math.abs(across) + turned * 0.12 - STILL,
        0,
      )
    }
    // the water
    local depth = depth_of(s.world, wheel)
    local flow = math.abs(along) + 0.6 * slide
    // the ground under it (in the air: what it last stood on)
    if(contact){
      ground.under(s.world, wheel, st.ground, depth)
    }
    local g = st.ground

    // ---- a thump: the suspension pushed in faster than a moment ago (a
    // rock, a ledge, a landing)
    local pushing = 0
    if(st.length != null and not moved){
      pushing = (st.length - wheel.length) / dt
    }
    st.length = wheel.length
    local jolt = pushing - st.pushed
    st.pushed = st.pushed + (pushing - st.pushed) * (1 - math.exp(-dt / 0.04))
    st.since = st.since + dt
    local stirred = false
    if(contact and jolt > JOLT and st.since > AGAIN){
      // (soft ground gives: the same jolt is a duller thump)
      send(m.THUMP, i, math.min(jolt, 2) * (0.6 + 0.4 * math.min(g.lugs, 1)))
      st.since = 0
      stirred = true
    }

    // ---- a splash: the wheel comes into water. How big it is grows
    // faster than how fast the wheel goes in: at a walk next to nothing,
    // all of it from some 20 km/h (or dropped in)
    if(not moved and depth >= SPLASH_DEPTH and motion.depth < SPLASH_DEPTH){
      local hard = (flow + 2 * math.max(pushing, 0)) / SPLASH_SPEED
      local size = math.min(hard * math.sqrt(hard), 1)
      if(size > 0.03){
        send(m.SPLASH, i, size)
        motion.spray = math.max(motion.spray, size)
        stirred = true
      }
    }
    motion.spray = motion.spray * math.exp(-dt / 0.45)
    if(motion.spray < 0.005){
      motion.spray = 0
    }
    // (out of the water the tire drains for a moment)
    if(depth >= SPLASH_DEPTH){
      motion.wet = 1
    } else {
      motion.wet = motion.wet * math.exp(-dt / 0.9)
      if(motion.wet < 0.02){
        motion.wet = 0
      }
    }

    motion.contact = contact
    motion.roll = roll
    motion.pass = math.max(math.abs(along) - STILL, 0)
    motion.crush = crush
    motion.slide = slide
    motion.load = if(contact){ math.min(
      math.max((wheel.load or 0) / STANDING, 0),
      3,
    ) } else { 0 }
    motion.scrub = scrub
    motion.depth = depth
    motion.flow = flow
    // (each wheel wanders its own way)
    local t = w.time
    motion.waver = 0.5 * math.sin(t * 10.7 + i * 1.9) +
      0.3 * math.sin(t * 19.5 + i * 4.1) + 0.2 * math.sin(t * 33.3 + i * 2.3)

    // ---- what the programs are told
    local c = m.controls(st.controls, g, motion)
    local names = st.names
    for(local k = 0; k < len(CONTROLS); k = k + 1){
      set(names[k], c[CONTROLS[k][0]])
    }
    // where it is heard from: where it touches the ground
    local spot = wheel.point
    if(not contact or spot == null){
      local at = wheel.at
      spot = listener.at(car, {x: at.x, y: -RADIUS, z: at.z})
    }
    local p = listener.place(s.view, spot)
    st.gain_left = p.left
    st.gain_right = p.right
    set(st.left, p.left)
    set(st.right, p.right)
    // whether there is anything to hear of it: while it moves, and a
    // moment after
    st.wet = depth > 0.02 or motion.wet > 0 or motion.spray > 0
    if(roll > 0 or slide > 0 or crush > 0 or scrub > 0.001 or stirred){
      st.stir = 0.3
    } else {
      st.stir = math.max(st.stir - dt, 0)
    }
    set(st.awake, if(st.stir > 0){ 1 } else { 0 })
  }

  // ---- the water, an axle at a time: its two wheels' together, heard
  // from where the wetter one is
  for(local a = 0; a < m.AXLES; a = a + 1){
    local axle = w.axles[a]
    local one = w.wheels[a * 2]
    local other = w.wheels[a * 2 + 1]
    local c1 = one.controls
    local c2 = other.controls
    local names = axle.names
    local rush = math.sqrt(c1.rush * c1.rush + c2.rush * c2.rush)
    set(names.rush, rush)
    set(
      names.rush_pitch,
      if(rush > 0){ (c1.rush_pitch * c1.rush + c2.rush_pitch * c2.rush) /
        (c1.rush + c2.rush) } else { (c1.rush_pitch + c2.rush_pitch) / 2 },
    )
    set(names.drops, c1.drops + c2.drops)
    set(names.dripping, DRIP)
    set(names.bubbles, c1.bubbles + c2.bubbles)
    set(names.bubbling, BUBBLE)
    local w1 = c1.rush * 20 + c1.drops / 200 + 0.001
    local w2 = c2.rush * 20 + c2.drops / 200 + 0.001
    set(axle.left, (one.gain_left * w1 + other.gain_left * w2) / (w1 + w2))
    set(axle.right, (one.gain_right * w1 + other.gain_right * w2) / (w1 + w2))
    set(axle.awake, if(one.wet or other.wet){ 1 } else { 0 })
  }
}

// ------------------------------------------------------------ the mixer's side

kernel {
  // a slow signal as a fast one, `by` samples for each of its own: lines
  // from sample to sample. low: m samples; out: m * by of them from
  // `at`; before: the sample before low[0]
  func stretch(
    out: float[], at: int, low: float[], before: float, m: int, by: int
  ){
    local a = before
    local o = at
    local step = 1.0 / by
    for(local k = 0; k < m; k += 1){
      local b = low[k]
      local d = (b - a) * step
      for(local j = 1; j <= by; j += 1){
        out[o] = a + d * j
        o += 1
      }
      a = b
    }
  }
}

// the tires' level in the mix
local LEVEL = 0.6

// how many of the mixer's samples the tire's own program makes one for
local SLOWER = 4

// how long a wheel's programs run on after there is nothing more to
// hear of it (its last ring dies away), and the water's after the wheels
// are dry, s
local TAIL = 1.2
local WET_TAIL = 1.5

// voice(ctx) -> {block, on}: see sound/mixer
func m.voice(ctx){
  local kernel = require("kernel")
  local tire = require("sound/tire")
  local ground_program = require("sound/tire/ground")
  local water = require("sound/tire/water")
  local now = ctx.now
  local slot = ctx.slot
  local rate = ctx.rate
  // (a mixer too slow for a quarter of its rate runs the tire at its own)
  local by = if(rate % SLOWER == 0 and rate / SLOWER >= 8000){ SLOWER } else { 1 }
  // each control: the parameter's slot, the program's state and the
  // field in it, and what was last written there
  local func controls_of(list, name, instances){
    local out = {}
    for(let local c in values(list)){
      local inst = instances[c[3]]
      append(out, {
        slot: slot[name(c[0])],
        state: inst.state,
        field: inst.dsp.by_label[c[0]].field,
        last: c[1],
      })
    }
    return out
  }
  local wheels = {}
  for(local i = 0; i < m.WHEELS; i = i + 1){
    local instances = {
      tire: tire:new({sample_rate: to_int(rate / by)}),
      ground: ground_program:new({sample_rate: rate}),
    }
    instances.tire.seed = i
    instances.ground.seed = i
    local sets = controls_of(CONTROLS, func(label){
      return wheel_name(i, label)
    }, instances)
    // the tire's sound at its own rate, the same at the mixer's, and
    // with the ground's
    local slow = kernel.float:array(to_int(ctx.size / by) + 2)
    local fast = kernel.float:array(ctx.size + by)
    local out = kernel.float:array(ctx.size)
    append(wheels, {
      tire: instances.tire,
      ground: instances.ground,
      sets: sets,
      count: len(sets),
      none: {},
      slow: slow,
      slow_out: {slow},
      fast: fast,
      ground_in: {fast},
      out: out,
      ground_out: {out},
      // the tire's last sample of the block before, and how many of
      // the mixer's samples were made ahead
      before: 0.0,
      ahead: 0,
      awake: slot[wheel_name(i, "awake")],
      left: slot[wheel_name(i, "left")],
      right: slot[wheel_name(i, "right")],
      was: {left: 0, right: 0},
      to: {left: 0, right: 0},
      // how long it has been quiet, s; a thump waiting for the next block
      quiet: TAIL,
      thump: 0,
    })
  }
  local axles = {}
  for(local a = 0; a < m.AXLES; a = a + 1){
    local instances = {water: water:new({sample_rate: rate})}
    instances.water.seed = a
    local sets = controls_of(WATER, func(label){
      return axle_name(a, label)
    }, instances)
    local out = kernel.float:array(ctx.size)
    append(axles, {
      water: instances.water,
      sets: sets,
      count: len(sets),
      none: {},
      out: out,
      water_out: {out},
      awake: slot[axle_name(a, "awake")],
      left: slot[axle_name(a, "left")],
      right: slot[axle_name(a, "right")],
      was: {left: 0, right: 0},
      to: {left: 0, right: 0},
      quiet: WET_TAIL,
      splash: 0,
    })
  }
  // (counted loops and no tables made in here: this runs some four
  // hundred times a second)
  local func write(list, count){
    for(local k = 0; k < count; k = k + 1){
      local e = list[k]
      local v = now[e.slot]
      if(v != e.last){
        e.last = v
        e.state[e.field] = v
      }
    }
  }
  return {
    block: func(n){
      local seconds = n / rate
      for(local i = 0; i < m.WHEELS; i = i + 1){
        local w = wheels[i]
        if(now[w.awake] > 0.5){
          w.quiet = 0
        } else if(w.quiet < TAIL){
          w.quiet = w.quiet + seconds
        }
        if(w.quiet >= TAIL){
          // nothing to hear: nothing computed (its gains follow, so that
          // it does not start from where it once was)
          w.was.left = now[w.left] * LEVEL
          w.was.right = now[w.right] * LEVEL
          continue
        }
        if(w.thump > 0){
          w.tire.strength = w.thump
          w.tire.hit = 1 - w.tire.hit
          w.thump = 0
        }
        write(w.sets, w.count)
        // the tire: as many of its own samples as fill the block (with
        // what was made ahead), stretched to the mixer's rate
        local ahead = w.ahead
        local slow = to_int((n - ahead + by - 1) / by)
        if(slow > 0){
          w.tire:compute(slow, w.none, w.slow_out)
          stretch(w.fast, ahead, w.slow, w.before, slow, by)
          w.before = w.slow[slow - 1]
        }
        w.ground:compute(n, w.ground_in, w.ground_out)
        // (what was made past the block's end is the next block's start)
        ahead = ahead + slow * by - n
        for(local k = 0; k < ahead; k = k + 1){
          w.fast[k] = w.fast[n + k]
        }
        w.ahead = ahead
        w.to.left = now[w.left] * LEVEL
        w.to.right = now[w.right] * LEVEL
        ctx.place(ctx.truck, w.out, w.was, w.to, n)
      }
      for(local a = 0; a < m.AXLES; a = a + 1){
        local w = axles[a]
        if(now[w.awake] > 0.5){
          w.quiet = 0
        } else if(w.quiet < WET_TAIL){
          w.quiet = w.quiet + seconds
        }
        if(w.quiet >= WET_TAIL){
          w.was.left = now[w.left] * LEVEL
          w.was.right = now[w.right] * LEVEL
          continue
        }
        if(w.splash > 0){
          w.water.strength = w.splash
          w.water.hit = 1 - w.water.hit
          w.splash = 0
        }
        write(w.sets, w.count)
        w.water:compute(n, w.none, w.water_out)
        w.to.left = now[w.left] * LEVEL
        w.to.right = now[w.right] * LEVEL
        ctx.place(ctx.truck, w.out, w.was, w.to, n)
      }
    },
    on: func(kind, a, b, c){
      if(kind == m.THUMP){
        local w = wheels[to_int(a)]
        if(w != null){
          w.thump = math.max(w.thump, b)
          w.quiet = 0
        }
      } else if(kind == m.SPLASH){
        local w = axles[to_int(a / 2)]
        if(w != null){
          w.splash = math.max(w.splash, b)
          w.quiet = 0
        }
      }
    },
  }
}

return m
