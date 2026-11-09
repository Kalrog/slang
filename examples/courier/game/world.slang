// game/world: the physics of the game, with no window. A world holds the
// city (every box a static Jolt body), the car, the traffic, and the
// other cars the missions bring (game/missions: the jobs and the board
// of offers live there, on top of this). Hits cost hull; near misses
// with traffic fill the boost and chain into cash (game/near_miss); the
// hull gone, the car is wrecked and set down at the last pad.
local math = require("slang/math")
local jolt = require("jolt")
local vec = require("game/vec")
local city = require("game/city")
local car_lib = require("game/car")
local traffic_lib = require("game/traffic")
local near_miss = require("game/near_miss")
local levels = require("game/levels")

local m = {}

m.PAD_RADIUS = 7          // how near a pad the car must come
m.PAD_SPEED = 18          // and how slowly, m/s
m.WRECK_TIME = 3
m.STEP = 1 / 60           // the physics step

// the physics world with the city's boxes in it
local func physics(c){
  local jw = jolt.world({
    gravity: {0, 0, 0},
    contact_events: true,
    max_bodies: 8192,
  })
  // ceiling: the top of the tallest building; the car may not climb much
  // over it (game/car), so the traffic is flown through, not over
  local phys = {jw: jw, by_id: {}, limit: c.half + c.street, ceiling: 0}
  for(let local b in values(c.boxes)){
    if(b.y1 > phys.ceiling and b.y1 < 2000){
      phys.ceiling = b.y1
    }
    local body = jw:create_body({
      shape: jolt.box({(b.x1 - b.x0) / 2, (b.y1 - b.y0) / 2, (b.z1 - b.z0) / 2}),
      position: {(b.x0 + b.x1) / 2, (b.y0 + b.y1) / 2, (b.z0 + b.z1) / 2},
      friction: 0.4,
    })
    phys.by_id[body.id] = {box: b}
  }
  jw:optimize_broad_phase()
  return phys
}

// new(options: {seed, level?: index, traffic?: count, flyers?: count,
// credits?, jobs?}) -> World (credits and jobs done carried over from the
// level before)
func m.new(options){
  options = options or {}
  local seed = options.seed or 1
  local level_index = options.level or 0
  local level = levels.get(level_index)
  local c = city.generate(seed, level)
  local phys = physics(c)
  local w = {
    seed: seed,
    level_index: level_index,
    level: level,
    level_jobs: 0,             // jobs done in this district
    city: c,
    phys: phys,
    car: null,
    traffic: traffic_lib.new(c, phys, seed, options.traffic),
    rng: vec.random(seed * 101 + 5),
    time: 0,
    credits: options.credits or 0,
    jobs: options.jobs or 0,   // jobs done in all
    job: null,                 // the mission under way (game/missions)
    npcs: {},                  // the other cars: {car, input, wrecked}
    flyers: null,              // the cars flying free (game/flyers)
    flyer_count: level.flyers or 0,
    state: "play",             // or "wrecked"
    wreck_timer: 0,
    events: {},
    last_pad: null,
    near_miss: near_miss.new(), // the misses and their chain
    slot_run: null,            // {slot, dir} while threading a slot
    skim_time: 0,
    best_speed: 0,
    pending: 0,
  }
  // start on a roof pad near the middle
  local start = null
  local bd = 1e18
  for(let local p in values(c.pads)){
    local d = math.abs(p.x) + math.abs(p.z)
    if(p.what == "roof" and d < bd){
      bd = d
      start = p
    }
  }
  w.last_pad = start
  w.car = car_lib.new(phys, {x: start.x, y: start.y + car_lib.CLEARANCE + 0.2, z: start.z}, 0)
  // the cars flying free: the level's, none in a world without traffic
  // unless asked for
  if(options.flyers != null){
    w.flyer_count = options.flyers
  } else if(options.traffic == 0){
    w.flyer_count = 0
  }
  return w
}

local func event(w, kind, extra){
  local e = {kind: kind}
  if(extra != null){
    for(let local en in entries(extra)){
      e[en[0]] = en[1]
    }
  }
  append(w.events, e)
}

local func flat_distance(a, b){
  local dx = a.x - b.x
  local dz = a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
}

// ------------------------------------------------------------ pads

// at_pad(car, pad): whether a car is at a pad: near it, over it, slow
// enough
func m.at_pad(car, pad){
  if(flat_distance(car.pos, pad) > m.PAD_RADIUS){
    return false
  }
  local h = car.pos.y - pad.y
  if(h < -1 or h > 9){
    return false
  }
  return car.speed < m.PAD_SPEED
}

// ------------------------------------------------------------ wrecks

local func wreck(w){
  w.state = "wrecked"
  w.wreck_timer = m.WRECK_TIME
  w.car.body.gravity_factor = 1
  w.car.body.angular_velocity = {2, 0.5, 4}
  event(w, "wreck")
  w.credits = math.max(0, w.credits - 50)
}

local func respawn(w){
  local pad = w.last_pad or city.nearest_pad(w.city, w.car.pos)
  w.car.body.gravity_factor = 0
  car_lib.place(w.car, {x: pad.x, y: pad.y + car_lib.CLEARANCE + 0.2, z: pad.z}, w.rng:range(0, 6.28))
  w.car.hull = 1
  w.car.boost = 0.5
  w.car.magnet = true
  w.state = "play"
  event(w, "respawn")
}

// ------------------------------------------------------------ other cars

// spawn(w, pos, yaw, o?) -> the other car: a car of its own in the
// physics, flown by whatever sets its input each frame (game/missions,
// with game/bot); o is kept on it (its role, its tint)
func m.spawn(w, pos, yaw, o){
  local npc = o or {}
  npc.car = car_lib.new(w.phys, pos, yaw or 0)
  npc.car.cooldown = 0.5
  npc.input = null
  npc.wrecked = false
  append(w.npcs, npc)
  return npc
}

// despawn(w, npc): out of the world
func m.despawn(w, npc){
  local kept = {}
  for(let local o in values(w.npcs)){
    if(o != npc){
      append(kept, o)
    }
  }
  w.npcs = kept
  npc.car.body:destroy()
}

// wreck_npc(w, npc): it falls out of the sky, tumbling
func m.wreck_npc(w, npc){
  if(npc.wrecked){
    return
  }
  npc.wrecked = true
  npc.car.body.gravity_factor = 1
  npc.car.body.angular_velocity = {3, 1, 5}
  event(w, "npc_wreck", {npc: npc, pos: npc.car.pos})
}

// ------------------------------------------------------------ the step

// a traffic car hit by the player's car: told by the contacts
local func traffic_hits(w, contacts){
  local car = w.car
  for(let local c in values(contacts)){
    local other = null
    local n = null
    if(c.body1 == car.body){
      other = w.phys.by_id[c.body2.id]
      n = c.normal
    } else if(c.body2 == car.body){
      other = w.phys.by_id[c.body1.id]
      n = vec.scale(c.normal, -1)
    }
    if(other != null and other.traffic != null){
      local t = other.traffic.car
      local impact = math.abs(vec.dot(vec.sub(c.velocity1, c.velocity2), c.normal))
      if(t != null){
        near_miss.touch(w.near_miss, t)
        if(traffic_lib.wreck(w.traffic, t, n, impact, car.vel)){
          event(w, "smash", {pos: t.pos, impact: impact})
        }
      }
    }
  }
}

// the slot p is in (between its walls, under its top), and how far
// along it
local func slot_at(w, p){
  for(let local s in values(w.city.slots)){
    local along = p.x
    local across = p.z
    if(s.axis == "z"){
      along = p.z
      across = p.x
    }
    if(math.abs(across - s.at) < city.SLOT / 2 and along >= s.lo and along <= s.hi and p.y < s.top){
      return {slot: s, along: along}
    }
  }
  return null
}

// threading a slot: in at one end, out at the other, without a hit
local func slot_step(w){
  local car = w.car
  local at = slot_at(w, car.pos)
  local run = w.slot_run
  if(run == null){
    if(at != null){
      local v = car.vel.x
      if(at.slot.axis == "z"){
        v = car.vel.z
      }
      local from = at.slot.lo
      if(v < 0){
        from = at.slot.hi
      }
      if(math.abs(v) > 5 and math.abs(at.along - from) < 8){
        w.slot_run = {slot: at.slot, dir: math.sign(v)}
      }
    }
  } else if(at == null or at.slot != run.slot){
    local s = run.slot
    local along = car.pos.x
    if(s.axis == "z"){
      along = car.pos.z
    }
    if((run.dir > 0 and along > s.hi) or (run.dir < 0 and along < s.lo)){
      near_miss.thread(w.near_miss, w, car.speed)
    }
    w.slot_run = null
  }
}

// one fixed step of everything physical
local idle = {pitch: 0, roll: 0, yaw: 0, throttle: 0, brake: 0, boost: false, magnet: false}

local func physics_step(w, input, dt){
  local car = w.car
  traffic_lib.step(w.traffic, dt, w.time, car.pos)
  // the other cars, by their own inputs (a wreck by none: it falls)
  for(let local npc in values(w.npcs)){
    if(not npc.wrecked){
      car_lib.control(npc.car, w.phys, npc.input or idle, dt)
      if(npc.input != null){
        npc.input.magnet = false
      }
    } else {
      npc.car.events = {}
    }
  }
  if(w.state == "wrecked"){
    w.phys.jw:step(dt)
    car_lib.read(car, w.phys, {})
    for(let local npc in values(w.npcs)){
      car_lib.read(npc.car, w.phys, {})
    }
    return
  }
  car_lib.control(car, w.phys, input, dt)
  w.phys.jw:step(dt)
  local contacts = w.phys.jw:contact_events().added
  car_lib.read(car, w.phys, contacts)
  for(let local npc in values(w.npcs)){
    car_lib.read(npc.car, w.phys, contacts)
  }
  traffic_hits(w, contacts)
  for(let local e in values(car.events)){
    if(e.kind == "hit"){
      near_miss.crash(w.near_miss, w)
      w.slot_run = null
      // into one of the other cars: a ram
      if(e.car != null){
        for(let local npc in values(w.npcs)){
          if(npc.car == e.car){
            event(w, "ram", {npc: npc, impact: e.impact, pos: e.pos})
          }
        }
      }
    }
    append(w.events, e)
  }
  // passing the traffic close
  near_miss.step(w.near_miss, w, dt)
  slot_step(w)
}

// step(w, input, dt): the frame's time, in fixed physics steps (the
// other cars' inputs set on them before)
func m.step(w, input, dt){
  w.events = {}
  local car = w.car
  w.pending = math.min(w.pending + dt, 0.1)
  local once = {...input}
  for(w.pending >= m.STEP){
    w.time = w.time + m.STEP
    physics_step(w, once, m.STEP)
    once.magnet = false
    w.pending = w.pending - m.STEP
  }
  if(w.state == "wrecked"){
    w.wreck_timer = w.wreck_timer - dt
    if(w.wreck_timer <= 0){
      respawn(w)
    }
    return
  }
  w.best_speed = math.max(w.best_speed, car.speed)
  if(car.skimming){
    w.skim_time = w.skim_time + dt
  }
  if(car.hull <= 0){
    wreck(w)
  }
}

// destroy(w): the physics world and everything in it
func m.destroy(w){
  w.phys.jw:destroy()
}

return m
