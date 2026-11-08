// game/world: the rules, with no window. A world holds the city (every
// box a static Jolt body), the car, the traffic and the current job: a
// package to pick up at one pad and deliver to another against the
// clock. Pay comes from the distance, the time left and the state of
// the package; hits cost hull and the package; close calls with traffic
// fill the boost. The hull gone, the car is wrecked and set down at the
// nearest pad.
local math = require("slang/math")
local jolt = require("jolt")
local vec = require("game/vec")
local city = require("game/city")
local car_lib = require("game/car")
local traffic_lib = require("game/traffic")
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
  local phys = {jw: jw, by_id: {}, limit: c.half + c.street}
  for(let local b in values(c.boxes)){
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

// new(options: {seed, level?: index, traffic?: count, credits?,
// deliveries?}) -> World (credits and deliveries carried over from the
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
    level_deliveries: 0,
    city: c,
    phys: phys,
    car: null,
    traffic: traffic_lib.new(c, phys, seed, options.traffic),
    rng: vec.random(seed * 101 + 5),
    time: 0,
    credits: options.credits or 0,
    deliveries: options.deliveries or 0,
    job: null,
    state: "play",             // or "wrecked"
    wreck_timer: 0,
    events: {},
    last_pad: null,
    close_calls: 0,
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
  m.new_job(w)
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

// ------------------------------------------------------------ jobs

// a pad at a distance from p within [lo, hi] (the nearest fit when none)
local func pad_from(w, p, lo, hi, not_this){
  local fits = {}
  for(let local pad in values(w.city.pads)){
    if(pad != not_this){
      local d = vec.distance(pad, p)
      if(d >= lo and d <= hi){
        append(fits, pad)
      }
    }
  }
  if(len(fits) > 0){
    return w.rng:pick(fits)
  }
  local best = null
  local bd = 1e18
  for(let local pad in values(w.city.pads)){
    if(pad != not_this){
      local d = math.abs(vec.distance(pad, p) - (lo + hi) / 2)
      if(d < bd){
        bd = d
        best = pad
      }
    }
  }
  return best
}

local packages = {
  "noodles", "a kidney", "spare parts", "contraband", "a cat", "legal papers",
  "a wedding cake", "medicine", "synth strings", "a drone battery", "sushi",
  "a sealed crate", "film reels", "a bonsai",
}

// new_job(w): a pickup within reach and a delivery farther off
func m.new_job(w){
  local car = w.car
  local from = pad_from(w, car.pos, 120, 420, null)
  local to = pad_from(w, from, 250, 750, from)
  local total = vec.distance(car.pos, from) + vec.distance(from, to)
  local fragile = w.rng:chance(0.3)
  local limit = total / w.level.time_speed + 14
  local job = {
    phase: "pickup",
    from: from,
    to: to,
    what: w.rng:pick(packages),
    fragile: fragile,
    limit: limit,
    left: limit,
    pay: to_int((40 + total * 0.22) * (1 + 0.25 * w.level_index)),
    condition: 1,
    distance: total,
    late: false,
  }
  if(fragile){
    job.pay = to_int(job.pay * 1.4)
  }
  w.job = job
  event(w, "job", {job: job})
  return job
}

// the pad the car should fly to now
func m.target(w){
  if(w.job == null){
    return null
  }
  if(w.job.phase == "pickup"){
    return w.job.from
  }
  return w.job.to
}

// whether the car is at a pad: near it, over it, slow enough
local func at_pad(car, pad){
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
  if(w.job != null){
    event(w, "lost", {job: w.job})
    w.job = null
  }
  w.credits = math.max(0, w.credits - 50)
}

local func respawn(w){
  local pad = w.last_pad or city.nearest_pad(w.city, w.car.pos)
  w.car.body.gravity_factor = 0
  car_lib.place(w.car, {x: pad.x, y: pad.y + car_lib.CLEARANCE + 0.2, z: pad.z}, w.rng:range(0, 6.28))
  w.car.hull = 1
  w.car.boost = 0.5
  w.car.magnet = false
  w.state = "play"
  event(w, "respawn")
  m.new_job(w)
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
        t.last_close = w.time
        if(traffic_lib.wreck(w.traffic, t, n, impact, car.vel)){
          event(w, "smash", {pos: t.pos, impact: impact})
        }
      }
      if(w.job != null and w.job.phase == "deliver"){
        w.job.condition = math.max(0, w.job.condition - impact * 0.015)
      }
    }
  }
}

// one fixed step of everything physical
local func physics_step(w, input, dt){
  local car = w.car
  traffic_lib.step(w.traffic, dt, w.time, car.pos)
  if(w.state == "wrecked"){
    w.phys.jw:step(dt)
    car_lib.read(car, w.phys, {})
    return
  }
  car_lib.control(car, w.phys, input, dt)
  w.phys.jw:step(dt)
  local contacts = w.phys.jw:contact_events().added
  car_lib.read(car, w.phys, contacts)
  traffic_hits(w, contacts)
  for(let local e in values(car.events)){
    if(e.kind == "hit" and w.job != null and w.job.phase == "deliver"){
      local loss = e.impact * 0.012
      if(w.job.fragile){
        loss = loss * 2
      }
      w.job.condition = math.max(0, w.job.condition - loss)
    }
    append(w.events, e)
  }
  // close calls with the traffic
  local R = car_lib.RADIUS + traffic_lib.RADIUS
  for(let local t in values(w.traffic.near)){
    local d = vec.distance(t.pos, car.pos)
    if(d < R + 4 and w.time - t.last_close > 3){
      local rel = vec.length(vec.sub(car.vel, t.vel))
      if(rel > 14){
        t.last_close = w.time
        car_lib.close_call(car)
        w.close_calls = w.close_calls + 1
        event(w, "close_call", {speed: rel, pos: t.pos})
      }
    }
  }
}

// step(w, input, dt): the frame's time, in fixed physics steps
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
  // the job
  local job = w.job
  if(job != null){
    job.left = job.left - dt
    if(job.left <= 0 and not job.late){
      job.late = true
      event(w, "late", {job: job})
    }
    if(job.phase == "pickup"){
      if(at_pad(car, job.from)){
        job.phase = "deliver"
        w.last_pad = job.from
        event(w, "pickup", {job: job})
      }
    } else if(at_pad(car, job.to)){
      local pay = job.pay * (0.5 + 0.5 * job.condition)
      if(job.late){
        pay = pay * 0.3
      } else {
        pay = pay * (1 + 0.6 * job.left / job.limit)
      }
      pay = to_int(pay)
      w.credits = w.credits + pay
      w.deliveries = w.deliveries + 1
      w.level_deliveries = w.level_deliveries + 1
      w.last_pad = job.to
      event(w, "deliver", {job: job, pay: pay})
      if(w.level_deliveries >= w.level.deliveries){
        event(w, "level_up", {next: w.level_index + 1, level: levels.get(w.level_index + 1)})
      } else {
        m.new_job(w)
      }
    }
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
