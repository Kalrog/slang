// sound/layers/body: what the truck's body sounds like, apart from its
// engine, its driveline and its tires: knocks (whatever changes the
// truck's speed at once: a rock, a tree, a landing; a thud for the small
// ones, a panel's clang for the hard ones), a crash (the whole shell
// struck, sheet metal buckling, what was loose thrown about and coming
// to rest), the things it carries rattling when it is shaken (by what
// the garage put on it: a roof rack, cans and a shovel, the spare wheel,
// the winch's hook), its suspension at work (springs and bushings
// creaking as they are worked slowly and far, the frame with them when
// the axles twist against each other, a spring driven into its bump
// stop, an axle dropping into its straps), bushes taking its sides, and
// the winch.
//
// Everything that is a blow is sound/body/struck.dsp with the numbers
// below; what goes on for a while has programs of its own
// (sound/body/crunch.dsp, springs.dsp, creak.dsp, brush.dsp, winch.dsp).
//
// The game's side (watch) reads the knocks game/world measures, the
// truck's motion, its suspension, the plants around it and the winch's
// line; the mixer's side (voice) runs the programs, only those that
// have something to say, and places them where they are on the truck.
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
  // the frame's creak: how often it slips, times a second, and how loud
  {"body_creak", 0, 0.05},
  {"body_creak_rate", 0, 0.05},
  // the suspension at work: for each corner (1 front left, 2 front
  // right, 3 rear left, 4 rear right) how hard its springs and bushings
  // stick and slip and how often, times a second; the dampers' breath
  {"body_spring1", 0, 0.04},
  {"body_spring1_rate", 0, 0.04},
  {"body_spring2", 0, 0.04},
  {"body_spring2_rate", 0, 0.04},
  {"body_spring3", 0, 0.04},
  {"body_spring3_rate", 0, 0.04},
  {"body_spring4", 0, 0.04},
  {"body_spring4_rate", 0, 0.04},
  {"body_breath", 0, 0.08},
  // a bush on the truck's side: how much of it, how fast through it (0
  // to 1), how much wood
  {"body_leaves", 0, 0.06},
  {"body_brush_speed", 0, 0.06},
  {"body_twigs", 0, 0.06},
  // the winch: its drum's speed (1: pulling in), how hard the line pulls
  // (0 to 1), the line's creak on the drum (times a second, how loud)
  {"body_winch", 0, 0.03},
  {"body_strain", 0, 0.08},
  {"body_line", 0, 0.05},
  {"body_line_rate", 0, 0.05},
  // the gains of the places on the truck: under its middle, its roof,
  // its tailgate, its front bumper; where the last knock hit it; where
  // the bush is; and where the winch's hook is set
  {"body_mid_left", 0, 0.03},
  {"body_mid_right", 0, 0.03},
  {"body_roof_left", 0, 0.03},
  {"body_roof_right", 0, 0.03},
  {"body_tail_left", 0, 0.03},
  {"body_tail_right", 0, 0.03},
  {"body_front_left", 0, 0.03},
  {"body_front_right", 0, 0.03},
  {"body_knock_left", 0, 0},
  {"body_knock_right", 0, 0},
  {"body_brush_left", 0, 0.05},
  {"body_brush_right", 0, 0.05},
  {"body_hook_left", 0, 0.03},
  {"body_hook_right", 0, 0.03},
  // where the suspension is at work, and each corner (as a blow there
  // finds it)
  {"body_work_left", 0, 0.06},
  {"body_work_right", 0, 0.06},
  {"body_corner1_left", 0, 0},
  {"body_corner1_right", 0, 0},
  {"body_corner2_left", 0, 0},
  {"body_corner2_right", 0, 0},
  {"body_corner3_left", 0, 0},
  {"body_corner3_right", 0, 0},
  {"body_corner4_left", 0, 0},
  {"body_corner4_right", 0, 0},
}

// what happens once: an event each
local BASE = params.EVENTS.body
m.KNOCK = BASE // the truck was hit: a = how hard (m/s), b = how much of it from below (0 to 1), c = 1 when a bump stop carries it
m.RATTLE = BASE + 1 // something it carries was shaken: a = which (its place in THINGS), b = how hard (0 to 1), c = in how many seconds
m.SNAP = BASE + 2 // a twig snapped on it: a = how hard (0 to 1)
m.HOOK = BASE + 3 // the winch's hook was set: a = 0 on a tree's strap, 1 on a ground anchor
m.REEL = BASE + 4 // the winch's line was unhooked and runs in: a = how much of it was out, m
m.CRASH = BASE + 5 // a crash: a = how much of one (0 to 1: 1 breaks the truck), b = how much of it from below
m.BOTTOM = BASE + 6 // a spring driven into its bump stop: a = which corner (0 to 3), b = how fast it arrived, m/s
m.TOP = BASE + 7 // a wheel dropped to the end of its travel: a = which corner, b = how fast, m/s
m.LINK = BASE + 8 // a stroke turned round hard: a = which corner, b = how hard (0 to 1)

// where things are on the truck (its frame: x left, y up, z forward)
local MIDDLE = {x: 0, y: 0.3, z: 0}
local ROOF = {x: 0, y: 1.75, z: -0.4}
local TAIL = {x: 0, y: 0.9, z: -2.35}
local FRONT = {x: 0, y: 0.35, z: 2.35}
// the places a blow can be heard from, as the voice counts them
local AT_MIDDLE = 0
local AT_ROOF = 1
local AT_TAIL = 2
local AT_FRONT = 3
local AT_KNOCK = 4
local AT_BRUSH = 5
local AT_HOOK = 6
local AT_WORK = 7
local AT_CORNER = 8 // and the three after it: the corners
// the corners, as game/car counts its wheels: front left, front right,
// rear left, rear right (under the floor, at the springs)
local CORNERS = {
  {x: 0.8, y: -0.1, z: 1.36},
  {x: -0.8, y: -0.1, z: 1.36},
  {x: 0.8, y: -0.1, z: -1.36},
  {x: -0.8, y: -0.1, z: -1.36},
}
// the places things are carried at
local POINTS = {[AT_ROOF]: ROOF, [AT_TAIL]: TAIL, [AT_FRONT]: FRONT}
local CARRYING = {AT_ROOF, AT_TAIL, AT_FRONT}
local STILL_SPIN = {x: 0, y: 0, z: 0}

// ---- knocks
// the least change of the truck's speed in one step of the physics that
// is a knock, m/s (a truck in the air changes it by 0.08 a step, one
// that brakes or turns hard by as much)
local KNOCK = 0.12
// a knock is heard again only if it is this much harder than the last
// one heard, which is forgotten over HEARD seconds (a landing is many
// steps of the physics, and one thud)
local HARDER = 1.5
local HEARD = 0.25
// after the truck was put somewhere (towed, righted) it is set down on
// its wheels: not a knock; for this long nothing is, s
local SET_DOWN = 0.7

// ---- a crash
// A knock this hard (m/s) begins to be a crash, and one CRASHED harder
// is as much of one as a truck takes without breaking (LIMIT of a whole
// one); the knock that breaks the truck (the rules' "broken") is at
// least BROKEN of one.
local CRASH = 1.0
local CRASHED = 5.0
local LIMIT = 0.6
local BROKEN = 0.75
// under this much of one it is a hard knock and nothing more
local LEAST_CRASH = 0.15
// a crash is heard again only if it is this much more of one than the
// last, which is forgotten over AFTERMATH seconds (a truck that hits a
// tree hits it for several frames, and then the ground)
local MORE_CRASH = 0.25
local AFTERMATH = 1.5
// springs and bushings are heard at a crawl: all of them under CRAWLING
// m/s, nothing of them over ROLLING
local CRAWLING = 4
local ROLLING = 9

// ---- the suspension (game/car's SUSPENSION_MIN, _REST and _MAX: how
// long a spring is on its bump stop, with the truck standing, and with
// its wheel hanging, front and rear, m)
local STOP = 0.07
local REST = 0.23
local HANG = {0.362, 0.362, 0.331, 0.331}
// a spring is on its stop, or its wheel hangs, within this much of it, m
local NEAR = 0.004
// the least speed a spring comes to its stop with to be heard, the least
// a wheel drops into its straps with, and the least a stroke has before
// it turns round with a clunk of its links, m/s
local BOTTOMS = 0.35
local DROPS = 0.45
local TURNS = 0.9
// a stop, a drop or a turn is heard again only if it is this much harder
// than the last one heard, which is forgotten over AGAIN seconds (a
// landing is four springs on their stops within a few frames, and one
// bang)
local STOPS_HARDER = 1.4
local AGAIN = 0.3
// springs and bushings creak when they are worked far (more than FAR_OFF
// from where they rest, all of it FAR beyond that, m) and slowly (from
// CREEP to SLOW m/s all of it, nothing over QUICK); they slip this many
// times for a meter of travel
local FAR_OFF = 0.025
local FAR = 0.07
local CREEP = 0.012
local SLOW = 0.2
local QUICK = 0.55
local SPRING_SLIPS = 200
// the dampers breathe on strokes faster than this, all they can at
// PUMPED more, m/s
local PUMPS = 0.4
local PUMPED = 3.0

// ---- what it carries
// A thing the truck carries: where it is, how hard it must be shaken
// (jolt: the least change of the force on it between two frames, m/s^2)
// before it is heard, which of the setup's choices puts it there (null:
// always there).
// type Thing = {name: string, at: int, jolt: float, category?: string,
//   option?: string, recipe: string, level: float, bounces: int}
// [recipe]: its numbers in RECIPES; [level]: how loud its hardest
// rattle is; [bounces]: how often it comes down again after one
m.THINGS = {
  {
    name: "rack", at: AT_ROOF, jolt: 9, category: "roof", option: "rack",
    recipe: "rack", level: 0.05, bounces: 2
  },
  {
    name: "platform", at: AT_ROOF, jolt: 14, category: "roof",
    option: "expedition", recipe: "rack", level: 0.045, bounces: 1
  },
  {
    name: "cans", at: AT_ROOF, jolt: 10, category: "roof", option: "expedition",
    recipe: "can", level: 0.06, bounces: 1
  },
  {
    name: "case", at: AT_ROOF, jolt: 12, category: "roof", option: "expedition",
    recipe: "box", level: 0.06, bounces: 1
  },
  {
    name: "shovel", at: AT_ROOF, jolt: 13, category: "roof",
    option: "expedition", recipe: "shovel", level: 0.035, bounces: 2
  },
  {
    name: "tent", at: AT_ROOF, jolt: 14, category: "roof", option: "tent",
    recipe: "tent", level: 0.06, bounces: 0
  },
  {
    name: "spare", at: AT_TAIL, jolt: 16, category: "spare", option: "tailgate",
    recipe: "spare", level: 0.07, bounces: 1
  },
  {
    name: "tailgate", at: AT_TAIL, jolt: 19, recipe: "latch", level: 0.035,
    bounces: 1
  },
  {
    name: "hook", at: AT_FRONT, jolt: 12, category: "bumper", option: "winch",
    recipe: "hook", level: 0.03, bounces: 2
  },
  {
    name: "bar", at: AT_FRONT, jolt: 22, category: "bumper", option: "bar",
    recipe: "bar", level: 0.06, bounces: 0
  },
  {
    name: "load",
    at: AT_TAIL,
    jolt: 26,
    recipe: "box",
    level: 0.05,
    bounces: 1,
  },
}
// a thing that was heard has settled: it takes this many times its jolt
// to shake it again at once, which wears off over SETTLED seconds (rough
// ground is a rattle now and then, never a jingle)
local SETTLES = 4
local SETTLED = 3.0

// ---- the frame's creak
// the axles' twist: how much longer one diagonal's springs are than the
// other's, m. Under LEVEL the frame is not twisted enough to creak, at
// TWISTED and more it creaks its loudest; it creaks at a crawl only
// (under CRAWL m/s all of it, none over RUN)
local LEVEL = 0.02
local TWISTED = 0.09
local CRAWL = 2.5
local RUN = 4.5
// it slips this many times for a meter of twist, and not at all when
// the twist changes slower than STILL m/s
local SLIPS = 400
local STILL = 0.008

// ---- bushes
// what the truck can push through: game/plants' kinds 6 to 8 (saplings,
// bushes, shrubs), how wide each is at scale 1, m, and how much wood is
// in it (0 to 1)
local FIRST_SOFT = 6
local LAST_SOFT = 8
local SPREAD = {[6]: 0.9, [7]: 1.05, [8]: 1.15}
local WOOD = {[6]: 0.9, [7]: 0.6, [8]: 0.3}
// they are looked up again when the truck has moved this far, within
// this distance, m
local LOOK_AGAIN = 4
local LOOK = 10
// the truck's outline: half its width and half its length, m
local HALF_WIDTH = 0.95
local HALF_LENGTH = 2.3

// ---- the winch (game/winch): its most pull, N, and its drum's speed, m/s
local PULL = 42000
local DRUM = 0.55

// ------------------------------------------------------------ the game's side

// watcher() -> the layer's state in the main isolate
func m.watcher(){
  local w = {
    seen: false,
    quiet: SET_DOWN, // how long nothing is a knock yet, s
    pos: {x: 0, y: 0, z: 0},
    velocity: {x: 0, y: 0, z: 0},
    // the knock of the frame before (it is heard once the next frame
    // shows it was the hardest), which way it pushed the truck (in the
    // truck's frame), and the hardest heard lately
    knock: 0,
    push: {x: 0, y: 0, z: 0},
    heard: 0,
    // what the setup puts on the truck: the things of THINGS that are
    // there (their places in it), and each one's state
    setup: {roof: null, spare: null, bumper: null},
    carried: {},
    things: {},
    // the points the things are at: each one's velocity and the force on
    // it the frame before
    points: {},
    // the axles' twist, and how fast it changes
    twist: 0,
    twisting: 0,
    // the springs: each corner's length, how fast it changes (as it
    // was the frame before, and smoothed), which way its stroke goes and
    // the most speed it had, how long until its links clunk again; the
    // hardest stop, drop and turn heard lately; how long since a spring
    // was last on its stop
    corners: {},
    stopped: 0,
    crashed: 0, // how much of a crash was heard lately
    dropped: 0,
    turned: 0,
    bottomed: 10,
    // the plants near the truck that it can push through: x, z, reach
    // and wood of each, and where they were looked up
    soft: {x: {}, z: {}, reach: {}, wood: {}, inside: {}, count: 0},
    looked: null,
    // the winch's line the frame before: whether it was out, how long
    line: false,
    length: 0,
    seed: 2468,
  }
  for(local i = 0; i < len(m.THINGS); i = i + 1){
    w.things[i] = {settled: 0, wait: 0}
  }
  for(let local at in values(CARRYING)){
    w.points[at] = {vx: 0, vy: 0, vz: 0, fx: 0, fy: 0, fz: 0, jolt: 0}
  }
  for(local i = 0; i < 4; i = i + 1){
    w.corners[i] = {
      length: REST, before: 0, rate: 0, way: 0, stroke: 0, wait: 0
    }
  }
  return w
}

// a number from 0 to 1, another every time
local func chance(w){
  w.seed = (w.seed * 1103515245 + 12345) & 2147483647
  return w.seed / 2147483648
}

// a number from -1 to 1 for every place x along a line, the same for the
// same place, changing smoothly from one whole number to the next
local func grain(x){
  local cell = math.floor(x)
  local t = x - cell
  local i = to_int(cell)
  local a = ((i * 374761393 + 1013) & 2147483647)
  a = ((a ~ (a >> 13)) * 1274126177) & 2147483647
  local b = (((i + 1) * 374761393 + 1013) & 2147483647)
  b = ((b ~ (b >> 13)) * 1274126177) & 2147483647
  local s = t * t * (3 - 2 * t)
  return ((a & 65535) / 32768 - 1) * (1 - s) + ((b & 65535) / 32768 - 1) * s
}

local func clamp(v, lo, hi){
  if(v < lo){
    return lo
  }
  if(v > hi){
    return hi
  }
  return v
}

// the things the setup puts on the truck, when it has changed
local func load(w, setup){
  local roof = if(setup != null){ setup.roof } else { "rack" }
  local spare = if(setup != null){ setup.spare } else { "tailgate" }
  local bumper = if(setup != null){ setup.bumper } else { "winch" }
  local had = w.setup
  if(had.roof == roof and had.spare == spare and had.bumper == bumper){
    return
  }
  had.roof = roof
  had.spare = spare
  had.bumper = bumper
  w.carried = {}
  for(local i = 0; i < len(m.THINGS); i = i + 1){
    local thing = m.THINGS[i]
    if(thing.category == null or had[thing.category] == thing.option){
      append(w.carried, i)
    }
  }
}

// the plants the truck can push through near it, looked up in its own
// squares of game/plants
local func look(w, world, pos){
  local soft = w.soft
  soft.count = 0
  w.looked = {x: pos.x, z: pos.z}
  local p = world.plants
  if(p == null){
    return
  }
  local plants = require("game/plants")
  for(let local chunk in values(plants.near(p, pos.x, pos.z, LOOK))){
    local d = chunk.data
    if(d != null){
      for(local r = chunk.starts[FIRST_SOFT]; r < chunk.starts[LAST_SOFT + 1]; r = r +
        1){
        local at = r * plants.STRIDE
        local dx = d[at + plants.X] - pos.x
        local dz = d[at + plants.Z] - pos.z
        if(dx * dx + dz * dz < LOOK * LOOK){
          local kind = to_int(d[at + plants.KIND])
          local n = soft.count
          soft.x[n] = d[at + plants.X]
          soft.z[n] = d[at + plants.Z]
          soft.reach[n] = SPREAD[kind] * d[at + plants.SCALE]
          soft.wood[n] = WOOD[kind]
          soft.inside[n] = false
          soft.count = n + 1
        }
      }
    }
  }
}

// watch(w, s, set, send): a frame (s: sound/director's Frame)
func m.watch(w, s, set, send){
  local car = s.car
  local world = s.world
  local dt = math.max(s.dt or 1 / 60, 0.001)
  local pos = car.pos
  local v = car.velocity
  local left = car.left
  local up = car.up
  local forward = car.forward
  local speed = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
  load(w, s.setup)

  // ---- was it put somewhere (towed, righted, set on the trail)? Then
  // it is set down on its wheels, which is no knock, and nothing it
  // carries is shaken. It was, if it is far from where it was, or if
  // its velocity changed by more than the physics' steps changed it
  // (game/world's knock: the most one step did; a frame is at most six).
  local dx = pos.x - w.pos.x
  local dy = pos.y - w.pos.y
  local dz = pos.z - w.pos.z
  local moved = math.sqrt(dx * dx + dy * dy + dz * dz)
  local cx = v.x - w.velocity.x
  local cy = v.y - w.velocity.y
  local cz = v.z - w.velocity.z
  local changed = math.sqrt(cx * cx + cy * cy + cz * cz)
  local stepped = if(world != null){ world.knock or 0 } else { 0 }
  local put = not w.seen or moved > 3 + 3 * speed * dt or
    changed > 0.6 + 6 * stepped
  for(let local e in values(s.events or {})){
    if(e.kind == "recover" or e.kind == "breakdown" or e.kind == "wreck"){
      put = true
    }
  }
  if(put){
    w.quiet = SET_DOWN
    w.knock = 0
    w.heard = 0
    w.looked = null
  }
  w.quiet = math.max(0, w.quiet - dt)
  local awake = w.quiet == 0

  // ---- where it all is for the listener
  local view = s.view
  local mid = listener.place(view, listener.at(car, MIDDLE))
  set("body_mid_left", mid.left)
  set("body_mid_right", mid.right)
  local roof = listener.place(view, listener.at(car, ROOF))
  set("body_roof_left", roof.left)
  set("body_roof_right", roof.right)
  local tail = listener.place(view, listener.at(car, TAIL))
  set("body_tail_left", tail.left)
  set("body_tail_right", tail.right)
  local front = listener.place(view, listener.at(car, FRONT))
  set("body_front_left", front.left)
  set("body_front_right", front.right)

  // (the change of its velocity over the frame, in its own frame: which
  // way it was pushed)
  local pushed_x = cx * left.x + cy * left.y + cz * left.z
  local pushed_y = cx * up.x + cy * up.y + cz * up.z
  local pushed_z = cx * forward.x + cy * forward.y + cz * forward.z
  w.bottomed = w.bottomed + dt

  // ---- a crash: a knock that does harm (the rules' knock event), by
  // how hard it is, and all of one when it breaks the truck (the rules'
  // "broken", in the same frame). It is heard at once, in place of the
  // knock; what the truck carries is thrown about once more, and again
  // as it all comes to rest.
  local knock = if(awake and world != null){ world.knock or 0 } else { 0 }
  w.heard = w.heard * math.exp(-dt / HEARD)
  local hit = 0
  local broken = false
  for(let local e in values(s.events or {})){
    if(e.kind == "knock"){
      hit = math.max(hit, e.strength or 0)
    } else if(e.kind == "broken"){
      broken = true
    }
  }
  local crash = clamp((hit - CRASH) / (CRASHED - CRASH), 0, 1) * LIMIT
  if(broken){
    crash = clamp(BROKEN + hit / 12, BROKEN, 1)
  }
  w.crashed = w.crashed * math.exp(-dt / AFTERMATH)
  if(awake and crash >= LEAST_CRASH and
    (broken or crash > w.crashed + MORE_CRASH)){
    w.crashed = crash
    local size = math.max(math.sqrt(
      pushed_x * pushed_x + pushed_y * pushed_y + pushed_z * pushed_z,
    ), 0.001)
    local from = listener.place(view, listener.at(car, {
      x: -pushed_x / size * 0.9,
      y: 0.3 - pushed_y / size * 0.4,
      z: -pushed_z / size * 2.2,
    }))
    set("body_knock_left", from.left)
    set("body_knock_right", from.right)
    send(m.CRASH, crash, math.abs(pushed_y) / size)
    for(let local i in values(w.carried)){
      send(m.RATTLE, i, 0.5 + 0.5 * chance(w), 0.12 + 0.5 * chance(w))
      if(crash > 0.5){
        send(m.RATTLE, i, 0.25 + 0.35 * chance(w), 0.7 + 1.2 * chance(w))
      }
    }
    // (it is not a knock as well, nor is what follows of it)
    w.heard = math.max(w.heard, math.max(hit, knock))
    w.knock = 0
    knock = 0
  }

  // ---- knocks: how much the truck's speed changed in one step of the
  // physics (game/world). A knock is heard a frame late, once the next
  // frame shows that it was the hardest of its moment, and only if it is
  // harder than what was just heard. One that a spring on its bump stop
  // carries (see below) says so: the stop's bang is its weight.
  if(w.knock >= KNOCK and w.knock >= knock and w.knock > w.heard * HARDER){
    // which way it pushed the truck says where it was hit: the other way
    local p = w.push
    local size = math.max(math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z), 0.001)
    local from = listener.place(view, listener.at(car, {
      x: -p.x / size * 0.9,
      y: 0.3 - p.y / size * 0.4,
      z: -p.z / size * 2.2,
    }))
    set("body_knock_left", from.left)
    set("body_knock_right", from.right)
    send(
      m.KNOCK,
      w.knock,
      math.abs(p.y) / size,
      if(w.bottomed < 0.2){ 1 } else { 0 },
    )
    w.heard = w.knock
  }
  w.knock = knock
  w.push.x = pushed_x
  w.push.y = pushed_y
  w.push.z = pushed_z

  // ---- what it carries: each thing is where the truck's motion throws
  // it about: the force on it (per kg) is how its place on the truck is
  // sped up, with what holds it up against its weight; a thing rattles
  // when that force changes at once
  local spin = car.spin or STILL_SPIN
  for(let local at in values(CARRYING)){
    local point = w.points[at]
    local o = POINTS[at]
    // the point's place from the truck's middle, in the world, and its
    // velocity: the truck's and what its turning adds
    local rx = left.x * o.x + up.x * o.y + forward.x * o.z
    local ry = left.y * o.x + up.y * o.y + forward.y * o.z
    local rz = left.z * o.x + up.z * o.y + forward.z * o.z
    local vx = v.x + spin.y * rz - spin.z * ry
    local vy = v.y + spin.z * rx - spin.x * rz
    local vz = v.z + spin.x * ry - spin.y * rx
    local fx = (vx - point.vx) / dt
    local fy = (vy - point.vy) / dt + 9.81
    local fz = (vz - point.vz) / dt
    local jx = fx - point.fx
    local jy = fy - point.fy
    local jz = fz - point.fz
    point.jolt = if(awake and w.seen){ math.sqrt(
      jx * jx + jy * jy + jz * jz,
    ) } else { 0 }
    point.vx = vx
    point.vy = vy
    point.vz = vz
    point.fx = fx
    point.fy = fy
    point.fz = fz
  }
  for(let local i in values(w.carried)){
    local thing = m.THINGS[i]
    local state = w.things[i]
    state.settled = state.settled * math.exp(-dt / SETTLED)
    state.wait = state.wait - dt
    local jolt = w.points[thing.at].jolt
    // (no two things let go at quite the same jolt)
    local least = thing.jolt * (1 + state.settled) * (0.8 + 0.4 * chance(w))
    if(jolt > least and state.wait <= 0){
      send(m.RATTLE, i, clamp((jolt / least - 1) / 3, 0.1, 1))
      state.settled = state.settled + SETTLES
      state.wait = 0.25
    }
  }

  // ---- the frame's creak: the axles twisting against each other at a
  // crawl. The frame's joints do not creak all the way: they stick at
  // some places of the twist and not at others, the same places every
  // time.
  local creak = 0
  local slips = 0
  if(car.wheels != null){
    local wheels = car.wheels
    local twist = (wheels[0].length - wheels[1].length) -
      (wheels[2].length - wheels[3].length)
    local grounded = 0
    for(local i = 0; i < 4; i = i + 1){
      if(wheels[i].contact){
        grounded = grounded + 1
      }
    }
    if(w.seen and awake){
      w.twisting = w.twisting +
        ((twist - w.twist) / dt - w.twisting) * (1 - math.exp(-dt / 0.1))
    } else {
      w.twisting = 0
    }
    w.twist = twist
    local rate = math.abs(w.twisting)
    local along = math.abs(car.speed or speed)
    if(grounded >= 3 and rate > STILL and along < RUN){
      local sticky = clamp((grain(twist * 55) - 0.25) / 0.3, 0, 1)
      creak = sticky *
        clamp((math.abs(twist) - LEVEL) / (TWISTED - LEVEL), 0, 1) *
        clamp((rate - STILL) / STILL, 0, 1) *
        clamp((RUN - along) / (RUN - CRAWL), 0, 1)
      slips = math.min(6 + SLIPS * rate, 140)
    }
  }
  set("body_creak", creak)
  set("body_creak_rate", slips)

  // ---- the suspension at work. Each corner's spring and bushings stick
  // and slip when they are worked slowly and far from where they rest,
  // at some places of their travel and not at others (each corner its
  // own); the dampers breathe on quick strokes; a stroke that turns
  // round hard clunks in its links; a spring driven onto its bump stop
  // bangs, by how fast it arrived, and a wheel that drops to the end of
  // its travel clacks in its straps. Of several at once (a landing) the
  // hardest is heard, once.
  local breath = 0
  local crawl = math.abs(car.speed or speed)
  local working = creak
  local work_x = 0
  local work_z = 0
  local stop_at = -1
  local stop_speed = 0
  local stops = 0
  local drop_at = -1
  local drop_speed = 0
  w.stopped = w.stopped * math.exp(-dt / AGAIN)
  w.dropped = w.dropped * math.exp(-dt / AGAIN)
  w.turned = w.turned * math.exp(-dt / AGAIN)
  for(local i = 0; i < 4; i = i + 1){
    local level = 0
    local often = 0
    if(car.wheels != null){
      local c = w.corners[i]
      local length = car.wheels[i].length
      local moving = if(w.seen and awake){ (length - c.length) / dt } else { 0 }
      c.rate = c.rate + (moving - c.rate) * (1 - math.exp(-dt / 0.05))
      c.wait = c.wait - dt
      // onto the stop, coming up
      if(length <= STOP + NEAR and c.length > STOP + NEAR){
        local speed = math.max(-moving, -c.before)
        if(speed > BOTTOMS){
          stops = stops + 1
          if(speed > stop_speed){
            stop_speed = speed
            stop_at = i
          }
        }
      }
      // into the straps, going down
      if(length >= HANG[i] - NEAR and c.length < HANG[i] - NEAR){
        local speed = math.max(moving, c.before)
        if(speed > DROPS and speed > drop_speed){
          drop_speed = speed
          drop_at = i
        }
      }
      // the stroke turning round
      if(math.abs(moving) > 0.1){
        local way = if(moving > 0){ 1 } else { -1 }
        if(c.way != 0 and way != c.way){
          if(c.stroke > TURNS and c.wait <= 0 and
            c.stroke > w.turned * STOPS_HARDER){
            local where = listener.place(view, listener.at(car, CORNERS[i]))
            set(concat("body_corner", string(i + 1), "_left"), where.left)
            set(concat("body_corner", string(i + 1), "_right"), where.right)
            send(m.LINK, i, clamp((c.stroke - TURNS) / 2.5, 0.1, 1))
            w.turned = c.stroke
            c.wait = 0.5
          }
          c.stroke = 0
        }
        c.way = way
      }
      c.stroke = math.max(c.stroke, math.abs(moving))
      // the creak
      local rate = math.abs(c.rate)
      local far = clamp((math.abs(length - REST) - FAR_OFF) / FAR, 0, 1)
      if(far > 0 and rate > CREEP and rate < QUICK){
        local sticky = clamp((grain(length * 60 + 31 * i) - 0.15) / 0.3, 0, 1)
        level = far * sticky * clamp((rate - CREEP) / (2 * CREEP), 0, 1) *
          clamp((QUICK - rate) / (QUICK - SLOW), 0, 1) *
          clamp((ROLLING - crawl) / (ROLLING - CRAWLING), 0, 1)
        often = 5 + SPRING_SLIPS * rate
      }
      breath = breath + clamp((math.abs(moving) - PUMPS) / PUMPED, 0, 1)
      c.length = length
      c.before = moving
    }
    set(concat("body_spring", string(i + 1)), level)
    set(concat("body_spring", string(i + 1), "_rate"), often)
    working = working + level
    work_x = work_x + level * CORNERS[i].x
    work_z = work_z + level * CORNERS[i].z
  }
  breath = math.min(breath / 2, 1)
  set("body_breath", breath)
  if(working > 0.001 or breath > 0.01){
    // (heard from where most of it is)
    local where = listener.place(view, listener.at(car, {
      x: work_x / math.max(working, 0.001),
      y: -0.1,
      z: work_z / math.max(working, 0.001),
    }))
    set("body_work_left", where.left)
    set("body_work_right", where.right)
  }
  if(stop_at >= 0){
    w.bottomed = 0
    // (every spring more on its stop adds a little)
    stop_speed = stop_speed * (1 + 0.1 * (stops - 1))
    if(stop_speed > w.stopped * STOPS_HARDER){
      local where = listener.place(view, listener.at(car, CORNERS[stop_at]))
      set(concat("body_corner", string(stop_at + 1), "_left"), where.left)
      set(concat("body_corner", string(stop_at + 1), "_right"), where.right)
      send(m.BOTTOM, stop_at, stop_speed)
      w.stopped = stop_speed
    }
  }
  if(drop_at >= 0 and drop_speed > w.dropped * STOPS_HARDER){
    local where = listener.place(view, listener.at(car, CORNERS[drop_at]))
    set(concat("body_corner", string(drop_at + 1), "_left"), where.left)
    set(concat("body_corner", string(drop_at + 1), "_right"), where.right)
    send(m.TOP, drop_at, drop_speed)
    w.dropped = drop_speed
  }

  // ---- bushes: the plants near the truck that it can push through,
  // looked up again every few meters; how far each reaches into the
  // truck's outline is how much of it is on the panels
  local leaves = 0
  local wood = 0
  local side = 0
  local ahead = 0
  local flat = math.sqrt(v.x * v.x + v.z * v.z)
  if(world != null and world.plants != null){
    local was = w.looked
    if(was == null or
      (pos.x - was.x) * (pos.x - was.x) + (pos.z - was.z) * (pos.z - was.z) >
        LOOK_AGAIN * LOOK_AGAIN){
      look(w, world, pos)
    }
    local soft = w.soft
    for(local i = 0; i < soft.count; i = i + 1){
      local px = soft.x[i] - pos.x
      local pz = soft.z[i] - pos.z
      local reach = soft.reach[i]
      // (in the truck's frame, flat)
      local lx = px * left.x + pz * left.z
      local lz = px * forward.x + pz * forward.z
      local over = math.min(
        (HALF_WIDTH + reach - math.abs(lx)) / reach,
        (HALF_LENGTH + reach - math.abs(lz)) / reach,
      )
      if(over > 0){
        local share = math.min(over, 1)
        leaves = leaves + share
        wood = wood + share * soft.wood[i]
        side = side + share * clamp(lx, -HALF_WIDTH, HALF_WIDTH)
        ahead = ahead + share * clamp(lz, -HALF_LENGTH, HALF_LENGTH)
        if(not soft.inside[i]){
          // the truck goes into it: its first twigs snap
          soft.inside[i] = true
          if(awake and flat > 1.5){
            send(m.SNAP, clamp(flat / 10, 0.2, 1) * soft.wood[i])
          }
        } else if(awake and flat > 1.5 and
          chance(w) < dt * 0.7 * soft.wood[i] * math.min(flat / 4, 2)){
          // and more as it goes through
          send(
            m.SNAP,
            clamp(flat / 10, 0.2, 1) * soft.wood[i] * (0.4 + 0.6 * chance(w)),
          )
        }
      } else {
        soft.inside[i] = false
      }
    }
  }
  local through = clamp(flat / 8, 0, 1)
  if(leaves > 0 and awake){
    local where = listener.place(view, listener.at(car, {
      x: side / leaves, y: 0.6, z: ahead / leaves
    }))
    set("body_brush_left", where.left)
    set("body_brush_right", where.right)
    set("body_leaves", math.min(leaves, 1) * clamp(flat / 0.6, 0, 1))
    set("body_twigs", math.min(wood, 1))
  } else {
    set("body_leaves", 0)
    set("body_twigs", 0)
  }
  set("body_brush_speed", through)

  // ---- the winch: its motor turns while the drum takes the line in,
  // slower the harder the line pulls; the line creaks on the drum under
  // load; the hook is heard when it is set and when it comes home
  local line = if(world != null){ world.winch } else { null }
  local run = 0
  local strain = 0
  local groan = 0
  if(line != null){
    if(not w.line){
      send(m.HOOK, if(line.kind == "ground"){ 1 } else { 0 })
      w.length = line.length
    }
    strain = clamp((line.tension or 0) / PULL, 0, 1)
    // how fast the line comes in; held by its most pull the drum stands
    // and the motor strains
    local taken = clamp((w.length - line.length) / dt / DRUM, 0, 1.3)
    run = if(strain > 0.97){ 0.15 } else { math.max(taken, 0.3) }
    w.length = line.length
    groan = strain * strain * clamp(taken + 0.2, 0, 1)
    local hook = listener.place(view, line.anchor)
    set("body_hook_left", hook.left)
    set("body_hook_right", hook.right)
  } else if(w.line){
    send(m.REEL, w.length)
  }
  w.line = line != null
  set("body_winch", run)
  set("body_strain", strain)
  set("body_line", groan)
  set("body_line_rate", 5 + 22 * run)

  w.pos.x = pos.x
  w.pos.y = pos.y
  w.pos.z = pos.z
  w.velocity.x = v.x
  w.velocity.y = v.y
  w.velocity.z = v.z
  w.seen = true
}

// ------------------------------------------------------------ what is struck

// The numbers of sound/body/struck.dsp for each thing that is struck
// here: how high the blow reaches (hard, Hz), six modes (f: Hz, t: the
// seconds each rings, g: its share), the blow's own noise (rough: its
// share, rise and fall in seconds, band in Hz, width), how loud a blow of
// power 1 comes out (peak, measured: tool/scenes/body_things prints it),
// and how long after a blow there is something to hear (tail, s).
// type Recipe = {hard: float, f: {float}, t: {float}, g: {float},
//   rough: float, rise: float, fall: float, band: float, width: float,
//   peak: float, tail: float}
m.RECIPES = {
  // the body taking a knock: its floor and its frame, low and short
  thud: {
    hard: 260,
    f: {58, 92, 148, 236, 410, 620},
    t: {0.09, 0.08, 0.07, 0.05, 0.035, 0.03},
    g: {1, 0.9, 0.6, 0.35, 0.2, 0.1},
    rough: 0.5,
    rise: 0.001,
    fall: 0.03,
    band: 180,
    width: 0.7,
    peak: 1.13,
    tail: 0.3,
  },
  // a panel of it: sheet steel with its trim on, a clang that is gone in
  // a tenth of a second
  clang: {
    hard: 1500,
    f: {187, 263, 412, 587, 1090, 1420},
    t: {0.1, 0.09, 0.08, 0.07, 0.055, 0.045},
    g: {0.8, 1, 0.8, 0.6, 0.4, 0.3},
    rough: 0.25,
    rise: 0.0004,
    fall: 0.02,
    band: 1500,
    width: 0.6,
    peak: 2.07,
    tail: 0.3,
  },
  // the roof rack's tubes and mesh
  rack: {
    hard: 3500,
    f: {430, 780, 1330, 2150, 3300, 4700},
    t: {0.06, 0.05, 0.045, 0.035, 0.03, 0.02},
    g: {0.7, 1, 0.7, 0.45, 0.25, 0.12},
    rough: 0.3,
    rise: 0.0003,
    fall: 0.01,
    band: 2500,
    width: 0.7,
    peak: 1.68,
    tail: 0.2,
  },
  // a jerry can, half full
  can: {
    hard: 2500,
    f: {172, 398, 655, 1210, 1950, 2900},
    t: {0.12, 0.09, 0.07, 0.05, 0.04, 0.03},
    g: {1, 0.7, 0.5, 0.35, 0.2, 0.1},
    rough: 0.2,
    rise: 0.0004,
    fall: 0.012,
    band: 1200,
    width: 0.7,
    peak: 1.65,
    tail: 0.3,
  },
  // a case and boards: wood and plastic, dull
  box: {
    hard: 900,
    f: {135, 290, 520, 840, 1300, 2100},
    t: {0.05, 0.04, 0.03, 0.025, 0.02, 0.015},
    g: {1, 0.8, 0.5, 0.3, 0.15, 0.08},
    rough: 0.3,
    rise: 0.0005,
    fall: 0.012,
    band: 500,
    width: 0.7,
    peak: 1.12,
    tail: 0.15,
  },
  // a shovel's blade on the rack: it rings
  shovel: {
    hard: 6000,
    f: {1180, 2310, 3890, 5200, 640, 7100},
    t: {0.14, 0.11, 0.08, 0.06, 0.05, 0.04},
    g: {1, 0.6, 0.35, 0.2, 0.3, 0.1},
    rough: 0.15,
    rise: 0.0002,
    fall: 0.006,
    band: 4000,
    width: 0.8,
    peak: 1.61,
    tail: 0.35,
  },
  // the roof tent: canvas and a mattress, a soft thump
  tent: {
    hard: 300,
    f: {95, 170, 310, 520, 800, 1200},
    t: {0.06, 0.05, 0.04, 0.03, 0.02, 0.015},
    g: {1, 0.6, 0.3, 0.1, 0.04, 0.02},
    rough: 0.6,
    rise: 0.002,
    fall: 0.04,
    band: 250,
    width: 0.6,
    peak: 0.78,
    tail: 0.2,
  },
  // the spare wheel on its carrier: heavy, on rubber
  spare: {
    hard: 500,
    f: {88, 165, 320, 610, 1150, 1900},
    t: {0.08, 0.06, 0.05, 0.035, 0.025, 0.015},
    g: {1, 0.8, 0.45, 0.25, 0.15, 0.06},
    rough: 0.3,
    rise: 0.0006,
    fall: 0.015,
    band: 300,
    width: 0.7,
    peak: 1.0,
    tail: 0.25,
  },
  // the tailgate in its latch
  latch: {
    hard: 3500,
    f: {720, 1500, 2450, 380, 3600, 5100},
    t: {0.03, 0.025, 0.02, 0.035, 0.015, 0.01},
    g: {1, 0.7, 0.4, 0.5, 0.2, 0.1},
    rough: 0.3,
    rise: 0.0003,
    fall: 0.006,
    band: 2000,
    width: 0.8,
    peak: 1.4,
    tail: 0.15,
  },
  // the winch's hook against the fairlead: small and bright
  hook: {
    hard: 7000,
    f: {1750, 3050, 4600, 6300, 880, 8200},
    t: {0.05, 0.04, 0.03, 0.02, 0.03, 0.015},
    g: {1, 0.7, 0.4, 0.2, 0.3, 0.1},
    rough: 0.2,
    rise: 0.0002,
    fall: 0.004,
    band: 5000,
    width: 0.8,
    peak: 1.54,
    tail: 0.15,
  },
  // the bull bar: a hoop of steel tube
  bar: {
    hard: 2500,
    f: {235, 590, 1290, 2050, 3100, 4400},
    t: {0.16, 0.12, 0.09, 0.06, 0.04, 0.03},
    g: {1, 0.7, 0.4, 0.25, 0.12, 0.06},
    rough: 0.2,
    rise: 0.0004,
    fall: 0.01,
    band: 1500,
    width: 0.7,
    peak: 1.79,
    tail: 0.4,
  },
  // the hook set on a strap's shackle or an anchor's eye: a clank
  shackle: {
    hard: 4500,
    f: {610, 1450, 2700, 4300, 310, 5900},
    t: {0.07, 0.09, 0.07, 0.05, 0.05, 0.03},
    g: {0.6, 1, 0.7, 0.4, 0.4, 0.15},
    rough: 0.25,
    rise: 0.0003,
    fall: 0.008,
    band: 3000,
    width: 0.8,
    peak: 1.58,
    tail: 0.3,
  },
  // a spring on its bump stop: a block of rubber between the axle and
  // the frame, and the frame taking it: dull and heavy, nothing bright
  stop: {
    hard: 200,
    f: {46, 71, 118, 185, 290, 430},
    t: {0.13, 0.12, 0.09, 0.07, 0.05, 0.035},
    g: {0.8, 1, 0.8, 0.5, 0.3, 0.15},
    rough: 0.5,
    rise: 0.002,
    fall: 0.04,
    band: 150,
    width: 0.6,
    peak: 1.12,
    tail: 0.4,
  },
  // an axle at the end of its travel, hanging in its straps and its
  // dampers: a light clack
  strap: {
    hard: 700,
    f: {160, 310, 520, 880, 1300, 1900},
    t: {0.05, 0.04, 0.03, 0.025, 0.02, 0.015},
    g: {1, 0.8, 0.5, 0.25, 0.12, 0.05},
    rough: 0.3,
    rise: 0.0008,
    fall: 0.01,
    band: 400,
    width: 0.7,
    peak: 1.13,
    tail: 0.2,
  },
  // a link in its bushings as the stroke turns round: a soft clunk
  link: {
    hard: 500,
    f: {110, 190, 330, 560, 900, 1400},
    t: {0.05, 0.045, 0.035, 0.025, 0.02, 0.015},
    g: {1, 0.9, 0.5, 0.25, 0.1, 0.04},
    rough: 0.3,
    rise: 0.001,
    fall: 0.012,
    band: 300,
    width: 0.7,
    peak: 1.12,
    tail: 0.2,
  },
  // a crash: the whole shell struck, low and long, with weight
  shell: {
    hard: 170,
    f: {33, 51, 77, 118, 182, 290},
    t: {0.28, 0.24, 0.2, 0.15, 0.11, 0.08},
    g: {0.5, 1, 0.9, 0.6, 0.35, 0.2},
    rough: 0.5,
    rise: 0.004,
    fall: 0.09,
    band: 140,
    width: 0.6,
    peak: 1.18,
    tail: 0.7,
  },
  // sheet metal giving way: it buckles and tears, each fold a noise of
  // its own with what it is part of ringing under it
  buckle: {
    hard: 900,
    f: {210, 340, 520, 790, 1180, 1650},
    t: {0.09, 0.08, 0.07, 0.06, 0.05, 0.04},
    g: {0.6, 1, 0.9, 0.7, 0.45, 0.3},
    rough: 1.4,
    rise: 0.008,
    fall: 0.11,
    band: 900,
    width: 0.5,
    peak: 1.72,
    tail: 0.4,
  },
  // a panel left ringing after it: bent, it sings a while
  ring: {
    hard: 500,
    f: {143, 212, 331, 452, 640, 870},
    t: {0.9, 0.75, 0.6, 0.45, 0.3, 0.2},
    g: {1, 0.8, 0.5, 0.3, 0.15, 0.08},
    rough: 0,
    rise: 0.001,
    fall: 0.01,
    band: 500,
    width: 0.7,
    peak: 1.64,
    tail: 1.2,
  },
  // a bit of trim or glass coming down
  bit: {
    hard: 5000,
    f: {1900, 3100, 4300, 880, 5600, 2500},
    t: {0.02, 0.015, 0.012, 0.03, 0.008, 0.015},
    g: {1, 0.7, 0.4, 0.4, 0.2, 0.5},
    rough: 0.3,
    rise: 0.0003,
    fall: 0.006,
    band: 3000,
    width: 0.8,
    peak: 1.93,
    tail: 0.1,
  },
  // a twig snapping
  twig: {
    hard: 6000,
    f: {2600, 3900, 1400, 5600, 800, 7400},
    t: {0.012, 0.01, 0.015, 0.008, 0.02, 0.006},
    g: {1, 0.6, 0.5, 0.3, 0.3, 0.15},
    rough: 0.8,
    rise: 0.0002,
    fall: 0.01,
    band: 3200,
    width: 0.7,
    peak: 1.55,
    tail: 0.1,
  },
}

// ------------------------------------------------------------ the mixer's side

// the levels in the mix
local KNOCKS = 1.0 // the knocks, over what [knock_level] says
local RATTLES = 0.8 // the things the truck carries, over their own levels
local CRASHES = 1.0 // a crash, over what [crash_level] says
local SPRINGS = 0.065 // the suspension at work and the frame's creak
local STOPS = 1.0 // springs on their stops, wheels in their straps, links
local BRUSH = 0.032
local WINCH = 0.06
local LINE = 0.03

// how many things can ring at once (a hard knock is two of them, a
// crash many)
local VOICES = 10
// how many blows can wait their turn (a crash's aftermath is some thirty)
local WAITING = 48

// knock_level(strength) -> how loud a knock is (about its peak on the
// truck's bus when the truck is where the camera usually has it): from
// next to nothing for the least knock (-44 dB re full scale at 0.12 m/s)
// to a bang for one that does damage (-12 dB at 1.2 m/s: 32 dB for ten
// times the knock), and little more for a crash, whatever its speed
func m.knock_level(strength){
  local db = -44 + 32 * math.log(math.max(strength, 0.12) / 0.12) / math.log(10)
  if(db > -12){
    db = math.min(-12 + (db + 12) * 0.25, -8)
  }
  return math.exp(db / 20 * math.log(10))
}

// crash_level(amount) -> how loud a crash's blow is (about its peak on
// the truck's bus): from a hard knock's (-10 dB re full scale for the
// least of one) to the loudest thing there is (-3 dB for the one that
// breaks the truck)
func m.crash_level(amount){
  return math.exp((-10 + 7 * amount) / 20 * math.log(10))
}

// stop_level(speed) -> how loud a spring on its bump stop is (about its
// peak on the truck's bus), by how fast it arrived, m/s: -27 dB re full
// scale at 1 m/s, 6.5 dB more for twice the speed, and no more than -15
// (a landing from a meter's fall is 4.4 m/s)
func m.stop_level(speed){
  local db = -27 + 6.5 * math.log(math.max(speed, 0.3)) / math.log(2)
  return math.exp(math.min(db, -15) / 20 * math.log(10))
}

// voice(ctx) -> {block, on}: see sound/mixer
func m.voice(ctx){
  local kernel = require("kernel")
  local struck = require("sound/body/struck")
  local crunch = require("sound/body/crunch")
  local creak = require("sound/body/creak")
  local springs = require("sound/body/springs")
  local brush = require("sound/body/brush")
  local winch = require("sound/body/winch")
  local now = ctx.now
  local slot = ctx.slot
  local rate = ctx.rate
  local none = {}

  // a program's field for one of its controls
  local func field(program, label){
    return program.by_label[label].field
  }

  // the gains of each place
  local places = {
    [AT_MIDDLE]: {left: slot.body_mid_left, right: slot.body_mid_right},
    [AT_ROOF]: {left: slot.body_roof_left, right: slot.body_roof_right},
    [AT_TAIL]: {left: slot.body_tail_left, right: slot.body_tail_right},
    [AT_FRONT]: {left: slot.body_front_left, right: slot.body_front_right},
    [AT_KNOCK]: {left: slot.body_knock_left, right: slot.body_knock_right},
    [AT_BRUSH]: {left: slot.body_brush_left, right: slot.body_brush_right},
    [AT_HOOK]: {left: slot.body_hook_left, right: slot.body_hook_right},
    [AT_WORK]: {left: slot.body_work_left, right: slot.body_work_right},
    [AT_CORNER]: {left: slot.body_corner1_left, right: slot.body_corner1_right},
    [AT_CORNER + 1]: {
      left: slot.body_corner2_left,
      right: slot.body_corner2_right,
    },
    [AT_CORNER + 2]: {
      left: slot.body_corner3_left,
      right: slot.body_corner3_right,
    },
    [AT_CORNER + 3]: {
      left: slot.body_corner4_left,
      right: slot.body_corner4_right,
    },
  }

  // ---- what goes on for a while: each program runs while it has
  // something to say and a moment longer (linger, s: what it takes to
  // fall silent); those that have nothing high in them at half the
  // sample rate, stretched
  // a program at the full rate
  local func whole(program, place, level, linger){
    return {
      inst: program:new({sample_rate: rate}),
      out: {kernel.float:array(ctx.size)},
      idle: 1000.0,
      level: level,
      linger: linger,
      place: places[place],
      was: {left: 0, right: 0},
      to: {left: 0, right: 0},
    }
  }
  // and one at half of it
  local func halved(program, place, level, linger){
    return {
      inst: program:new({sample_rate: to_int(rate / 2)}),
      half: {kernel.float:array(to_int(ctx.size / 2) + 1)},
      out: {kernel.float:array(ctx.size + 2)},
      last: kernel.float:array(1),
      idle: 1000.0,
      level: level,
      linger: linger,
      place: places[place],
      was: {left: 0, right: 0},
      to: {left: 0, right: 0},
    }
  }
  // wakes(p, busy, n) -> whether a program is to be computed for the
  // next n frames: it is busy, or was a moment ago
  local func wakes(p, busy, n){
    if(busy){
      p.idle = 0
    } else {
      p.idle = p.idle + n / rate
    }
    p.to.left = now[p.place.left] * p.level
    p.to.right = now[p.place.right] * p.level
    if(p.idle < p.linger){
      return true
    }
    p.was.left = p.to.left
    p.was.right = p.to.right
    return false
  }
  // play(p, n): n frames of a program into the truck's bus
  local func play(p, n){
    if(p.half != null){
      local count = to_int((n + 1) / 2)
      p.inst:compute(count, none, p.half)
      stretch(p.out[0], p.half[0], p.last, count)
    } else {
      p.inst:compute(n, none, p.out)
    }
    ctx.place(ctx.truck, p.out[0], p.was, p.to, n)
  }

  // the suspension at work, the frame's creak with it: the program's
  // five voices and the parameter each follows
  local work = halved(springs, AT_WORK, SPRINGS, 0.3)
  local work_breath = field(springs, "breath")
  local workers = {
    {level: slot.body_creak, rate: slot.body_creak_rate},
    {level: slot.body_spring1, rate: slot.body_spring1_rate},
    {level: slot.body_spring2, rate: slot.body_spring2_rate},
    {level: slot.body_spring3, rate: slot.body_spring3_rate},
    {level: slot.body_spring4, rate: slot.body_spring4_rate},
  }
  for(local i = 0; i < 5; i = i + 1){
    workers[i].level_field = field(springs, concat("level", string(i)))
    workers[i].rate_field = field(springs, concat("rate", string(i)))
  }
  local creak_rate = field(creak, "rate")
  local creak_level = field(creak, "level")
  // (the winch's line on its drum: the same sticking and slipping, of
  // something smaller and drier)
  local line = halved(creak, AT_FRONT, LINE, 0.3)
  line.inst.tune = 3.2
  line.inst.dry = 0.5
  local bush = whole(brush, AT_BRUSH, BRUSH, 0.3)
  local bush_leaves = field(brush, "leaves")
  local bush_speed = field(brush, "speed")
  local bush_twigs = field(brush, "twigs")
  // (the winch's motor takes a second to run down)
  local motor = halved(winch, AT_FRONT, WINCH, 1.2)
  local motor_run = field(winch, "run")
  local motor_strain = field(winch, "strain")
  // the crash
  local smash = whole(crunch, AT_KNOCK, 1, 0.1)
  local smash_hit = field(crunch, "hit")
  local smash_power = field(crunch, "power")
  local smash_length = field(crunch, "length")
  local smashes = 0
  local smash_until = 0

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
      place: places[AT_MIDDLE],
      was: {left: 0, right: 0},
      to: {left: 0, right: 0},
    }
  }
  local clock = 0.0
  local seed = 1357
  // a number from -1 to 1, another every time
  local func scatter(){
    seed = (seed * 1103515245 + 12345) & 2147483647
    return seed / 1073741824 - 1
  }

  // strike(recipe, loud, place, tune, reach): a blow now, on the voice
  // that has been silent longest. loud: about its peak; tune: its modes
  // this many times higher; reach: how high the blow reaches, over the
  // recipe's own
  local func strike(recipe, loud, place, tune, reach){
    local v = voices[0]
    for(local i = 1; i < VOICES; i = i + 1){
      if(voices[i].until < v.until){
        v = voices[i]
      }
    }
    local st = v.state
    // (no two blows alike: each a little higher or lower, its modes'
    // shares a little other)
    local pitch = tune * (1 + 0.04 * scatter())
    for(local i = 0; i < 6; i = i + 1){
      st[fields.f[i]] = recipe.f[i] * pitch
      st[fields.t[i]] = recipe.t[i]
      st[fields.g[i]] = recipe.g[i] * (1 + 0.3 * scatter())
    }
    st[hard] = recipe.hard * reach
    st[rough] = recipe.rough
    st[rise] = recipe.rise
    st[fall] = recipe.fall
    st[band] = recipe.band * pitch
    st[width] = recipe.width
    st[power] = loud / recipe.peak
    v.hits = v.hits + 1
    st[hit] = v.hits
    v.until = clock + recipe.tail
    v.place = places[place]
  }

  // the blows that wait their turn
  local waiting = {}
  for(local i = 0; i < WAITING; i = i + 1){
    waiting[i] = {
      live: false, at: 0, recipe: null, loud: 0, place: 0, tune: 1, reach: 1
    }
  }
  local queued = 0
  // later(after, recipe, loud, place, tune, reach): a blow in `after`
  // seconds
  local func later(after, recipe, loud, place, tune, reach){
    for(local i = 0; i < WAITING; i = i + 1){
      local e = waiting[i]
      if(not e.live){
        e.live = true
        e.at = clock + after
        e.recipe = recipe
        e.loud = loud
        e.place = place
        e.tune = tune
        e.reach = reach
        queued = queued + 1
        return
      }
    }
  }

  // the winch's line running in after it was unhooked: until when, and
  // whether the hook has come home
  local reel_until = 0
  local reeling = false

  local R = m.RECIPES
  local things = m.THINGS
  return {
    // on(kind, a, b, c): what happened once
    on: func(kind, x, y, z){
      if(kind == m.KNOCK){
        // A thud, which a hard knock from the side makes a clang as
        // well, and a crash a crunch. A knock from below is a landing or
        // a bump: the tires and the springs thump for that themselves
        // (sound/layers/tires), and the body only adds its own boom.
        local loud = m.knock_level(x) * KNOCKS / 0.62
        local panel = math.min(math.max((x - 0.25) / 0.6, 0), 1) *
          (1 - 0.55 * y)
        local hardness = math.min(x / 1.2, 1)
        // (and one that a spring on its stop carries, next to nothing)
        local below = if(z > 0){ (1 - 0.9 * y) * 0.6 } else { 1 - 0.75 * y }
        strike(
          R.thud, loud * (1 - 0.45 * panel) * below, AT_KNOCK,
          1 + 0.08 * scatter(), 0.6 + 1.4 * hardness
        )
        if(panel > 0.02){
          strike(
            R.clang, loud * 0.75 * panel, AT_KNOCK, 1 + 0.15 * scatter(),
            0.6 + 0.8 * hardness
          )
        }
        local crash = math.min(math.max((x - 0.9) / 1.6, 0), 1)
        if(crash > 0){
          local st = smash.inst.state
          st[smash_power] = loud * 0.45 * crash
          st[smash_length] = 0.12 +
            0.25 * math.min(math.max((x - 0.9) / 3, 0), 1)
          smashes = smashes + 1
          st[smash_hit] = smashes
          smash_until = clock + 0.6
        }
      } else if(kind == m.RATTLE){
        local thing = things[to_int(x)]
        if(thing != null){
          local recipe = R[thing.recipe]
          local loud = thing.level * RATTLES *
            math.exp(0.8 * math.log(math.max(y, 0.05)))
          local tune = 1 + 0.06 * scatter()
          // (thrown about in a crash, it is heard when it lands: z)
          if(z > 0){
            later(z, recipe, loud, thing.at, tune, 0.5 + 0.5 * y)
          } else {
            strike(recipe, loud, thing.at, tune, 0.5 + 0.5 * y)
          }
          // it comes down again, less each time and sooner
          local after = z + 0.07 + 0.05 * y
          for(local i = 0; i < thing.bounces; i = i + 1){
            loud = loud * (0.35 + 0.15 * scatter())
            later(
              after * (1 + 0.2 * scatter()), recipe, loud, thing.at, tune, 0.4
            )
            after = after + (0.05 + 0.03 * y) / (i + 1)
          }
        }
      } else if(kind == m.CRASH){
        // The whole shell struck: low, long, and all at once but for
        // the first thousandths of a second. A panel with it; the sheet
        // metal buckling and tearing after it, in folds, no two alike
        // nor evenly apart; and then what it leaves: a bent panel
        // ringing, bits coming down.
        local loud = m.crash_level(x) * CRASHES / 0.62
        strike(R.shell, loud, AT_KNOCK, 1 + 0.06 * scatter(), 0.7 + 0.5 * x)
        strike(
          R.clang, loud * 0.35 * (1 - 0.5 * y), AT_KNOCK,
          0.8 + 0.15 * scatter(), 0.9
        )
        local st = smash.inst.state
        st[smash_power] = loud * (0.3 + 0.25 * x)
        st[smash_length] = 0.25 + 0.5 * x
        smashes = smashes + 1
        st[smash_hit] = smashes
        smash_until = clock + 1.2
        local folds = 2 + to_int(6 * x)
        local at = 0.02
        local fold = loud * 0.5
        for(local i = 0; i < folds; i = i + 1){
          later(
            at,
            R.buckle,
            fold * (0.7 + 0.3 * scatter()),
            AT_KNOCK,
            1.05 + 0.45 * scatter(),
            0.7 + 0.3 * scatter(),
          )
          at = at + 0.035 + 0.07 * math.abs(scatter())
          fold = fold * 0.82
        }
        if(x > 0.3){
          later(0.05, R.ring, loud * 0.1, AT_KNOCK, 1 + 0.2 * scatter(), 0.6)
        }
        if(x > 0.45){
          local bits = 3 + to_int(6 * x)
          for(local i = 0; i < bits; i = i + 1){
            later(
              0.35 + (0.3 + 1.6 * x) * math.abs(scatter()),
              R.bit,
              0.012 + 0.02 * math.abs(scatter()),
              AT_KNOCK,
              1.1 + 0.45 * scatter(),
              1,
            )
          }
        }
      } else if(kind == m.BOTTOM){
        // rubber and frame, under the floor: the faster it came, the
        // louder and the fuller (never bright)
        local corner = AT_CORNER + math.min(math.max(to_int(x), 0), 3)
        strike(
          R.stop, m.stop_level(y) * STOPS / 0.62, corner, 1 + 0.08 * scatter(),
          0.7 + 0.12 * math.min(y, 4)
        )
      } else if(kind == m.TOP){
        // -40 dB re full scale at the least drop, 5.5 dB more for twice
        // the speed, no more than -22 (a wheel falls into its straps at
        // several meters a second when the truck leaves the ground)
        local corner = AT_CORNER + math.min(math.max(to_int(x), 0), 3)
        local db = math.min(
          -40 + 5.5 * math.log(math.max(y, 0.4) / 0.4) / math.log(2),
          -22,
        )
        strike(
          R.strap, math.exp(db / 20 * math.log(10)) * STOPS / 0.62, corner,
          1 + 0.1 * scatter(), 0.8 + 0.1 * math.min(y, 4)
        )
      } else if(kind == m.LINK){
        // -42 dB re full scale for the least, -24 for the hardest
        local corner = AT_CORNER + math.min(math.max(to_int(x), 0), 3)
        strike(
          R.link, math.exp((-42 + 18 * y) / 20 * math.log(10)) * STOPS / 0.62,
          corner, 1 + 0.1 * scatter(), 0.7 + 0.5 * y
        )
      } else if(kind == m.SNAP){
        strike(
          R.twig, 0.05 * math.max(x, 0.1), AT_BRUSH, 1 + 0.3 * scatter(),
          0.6 + 0.4 * x
        )
      } else if(kind == m.HOOK){
        // on the shackle of a tree's strap it rings; on a ground anchor
        // it is duller. The hook's latch after it.
        local tune = if(x > 0){ 0.8 } else { 1 }
        strike(R.shackle, 0.11, AT_HOOK, tune, 1)
        later(0.09 + 0.02 * scatter(), R.hook, 0.05, AT_HOOK, 1.1, 1)
        reeling = false
      } else if(kind == m.REEL){
        // the line runs in at some 8 m/s, and the hook comes home
        reel_until = clock + math.min(math.max(x / 8, 0.4), 2.5)
        reeling = true
      }
    },
    // block(n): n frames of the body into the truck's bus
    block: func(n){
      clock = clock + n / rate
      // the blows whose time has come
      if(queued > 0){
        for(local i = 0; i < WAITING; i = i + 1){
          local e = waiting[i]
          if(e.live and e.at <= clock){
            e.live = false
            queued = queued - 1
            strike(e.recipe, e.loud, e.place, e.tune, e.reach)
          }
        }
      }
      // the suspension at work
      local breathing = now[slot.body_breath]
      local busy = breathing > 0.002
      for(local i = 0; i < 5; i = i + 1){
        busy = busy or now[workers[i].level] > 0.001
      }
      if(wakes(work, busy, n)){
        local st = work.inst.state
        for(local i = 0; i < 5; i = i + 1){
          local k = workers[i]
          st[k.level_field] = now[k.level]
          st[k.rate_field] = now[k.rate]
        }
        st[work_breath] = breathing
        play(work, n)
      }
      // the bush
      local leaves = now[slot.body_leaves]
      if(wakes(bush, leaves > 0.001, n)){
        local st = bush.inst.state
        st[bush_leaves] = leaves
        st[bush_speed] = now[slot.body_brush_speed]
        st[bush_twigs] = now[slot.body_twigs]
        play(bush, n)
      }
      // the winch: pulling, or its line running in after it was unhooked
      local turning = now[slot.body_winch]
      local strain = now[slot.body_strain]
      if(reeling){
        if(clock < reel_until){
          turning = 1.5
          strain = 0
        } else {
          // the hook comes home
          reeling = false
          strike(R.hook, 0.07, AT_FRONT, 0.9, 1)
          later(0.06, R.latch, 0.03, AT_FRONT, 1.2, 1)
        }
      }
      if(wakes(motor, turning > 0.001, n)){
        local st = motor.inst.state
        st[motor_run] = turning
        st[motor_strain] = strain
        play(motor, n)
      }
      local groan = now[slot.body_line]
      if(wakes(line, groan > 0.001, n)){
        local st = line.inst.state
        st[creak_rate] = now[slot.body_line_rate]
        st[creak_level] = groan
        play(line, n)
      }
      // the crash
      if(wakes(smash, clock < smash_until, n)){
        play(smash, n)
      }
      // what was struck and still rings
      for(local i = 0; i < VOICES; i = i + 1){
        local v = voices[i]
        v.to.left = now[v.place.left]
        v.to.right = now[v.place.right]
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
