// game/missions: the jobs, on top of game/world. A board of offers waits
// around the city, each at a pad with a beacon in its color and an icon
// over it: fly to one to take it (land on it to take a delivery or a
// race; fly through it for the others). Offers run out after a while
// and new ones come up in their place, near wherever the car is. One job
// at a time:
//
// - DELIVERY: the package is taken at the offer's pad, to be landed on
//   another pad against the clock; pay for the distance, the time left
//   and the package in one piece (fragile ones bruise twice as fast).
// - RACE: a rival courier (game/bot) waits over the pad; after a count
//   of three both race to a pad far off. Land there first.
// - TAKEDOWN: a car flees through the city; ram it until it goes down
//   before the time is up. The harder the ram, the more it takes.
// - TAIL: a car flies calmly to a pad of its own; follow it there, near
//   enough not to lose it, not so near that it spots you.
//
// The other cars are cars of the world (world.spawn) flown by
// game/bot. Every job done counts toward the next district.
// autopilot(w, dt) flies the player's car through all of it, for the
// attract mode, the tests and tool/autopilot.
local math = require("slang/math")
local vec = require("game/vec")
local car_lib = require("game/car")
local world = require("game/world")
local bot = require("game/bot")
local near_miss = require("game/near_miss")
local flyers = require("game/flyers")
local levels = require("game/levels")

local m = {}

m.OFFERS = 4             // offers on the board at once
m.OFFER_TIME = {45, 90}  // s an offer stays up
m.REFILL = 4             // s before an empty place gets a new offer
m.ACCEPT = 12            // m from a fly-through offer's pad that takes it
m.RACE_COUNT = 3         // s of the count before a race
m.TAKEDOWN_TIME = 75     // s to bring the target down
m.TAIL_NEAR = 20         // m nearer than this, the target grows suspicious
m.TAIL_FAR = 140         // m further than this, it is getting away
m.TAIL_SPOT = 2.5        // s too near before it spots you
m.TRAIL_STEP = 6        // m between the points of a target's trail
m.TAIL_LOSE = 8          // s too far before it is lost

m.KINDS = {
  delivery: {name: "DELIVERY", color: {0, 230, 255}, weight: 4},
  race: {name: "RACE", color: {90, 255, 150}, weight: 2},
  takedown: {name: "TAKEDOWN", color: {255, 70, 70}, weight: 2},
  tail: {name: "TAIL", color: {200, 110, 255}, weight: 2},
}
m.ORDER = {"delivery", "race", "takedown", "tail"}

local packages = {
  "noodles", "a kidney", "spare parts", "contraband", "a cat", "legal papers",
  "a wedding cake", "medicine", "synth strings", "a drone battery", "sushi",
  "a sealed crate", "film reels", "a bonsai",
}

local func event(w, kind, extra){
  local e = extra or {}
  e.kind = kind
  append(w.events, e)
  return e
}

local func flat_distance(a, b){
  local dx = a.x - b.x
  local dz = a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
}

local func ceil(x){
  return -math.floor(-x)
}

local func level_scale(w){
  return 1 + 0.25 * w.level_index
}

// ------------------------------------------------------------ places

// a pad at a distance from p within [lo, hi], none of avoid (the nearest
// fit when none is)
local func pad_from(w, p, lo, hi, avoid){
  local func ok(pad){
    for(let local a in values(avoid or {})){
      if(a == pad){
        return false
      }
    }
    return true
  }
  local fits = {}
  for(let local pad in values(w.city.pads)){
    local d = vec.distance(pad, p)
    if(d >= lo and d <= hi and ok(pad)){
      append(fits, pad)
    }
  }
  if(len(fits) > 0){
    return w.rng:pick(fits)
  }
  local best = null
  local bd = 1e18
  for(let local pad in values(w.city.pads)){
    local d = math.abs(vec.distance(pad, p) - (lo + hi) / 2)
    if(d < bd and ok(pad)){
      bd = d
      best = pad
    }
  }
  return best
}

// a point of the clear network (game/nav: a crossing, in a band) at a
// distance from p within [lo, hi], not further above or below it than dy
// (45), or as near as there is; of those,
// the furthest from away when given (where a fleeing car heads)
local func node_from(w, p, lo, hi, away, dy){
  dy = dy or 45
  local nav = bot.nav(w)
  local fits = {}
  // (none so near, or none at the height: further, and higher or lower)
  for(local tries = 0; tries < 6 and len(fits) == 0; tries = tries + 1){
    for(local i = 0; i <= nav.n; i = i + 1){
      for(local j = 0; j <= nav.n; j = j + 1){
        for(let local y in values(nav.bands)){
          local q = {x: nav.lines[i], y: y, z: nav.lines[j]}
          local d = vec.distance(q, p)
          if(d >= lo and d <= hi and math.abs(y - p.y) < dy){
            append(fits, q)
          }
        }
      }
    }
    lo = lo * 0.7
    hi = hi * 1.4
    dy = dy * 1.6
  }
  if(len(fits) == 0){
    return {x: nav.lines[to_int(nav.n / 2)], y: nav.bands[1], z: nav.lines[to_int(nav.n / 2)]}
  }
  if(away == null){
    return w.rng:pick(fits)
  }
  local best = null
  for(local k = 0; k < 8; k = k + 1){
    local q = w.rng:pick(fits)
    if(best == null or vec.distance(q, away) > vec.distance(best, away)){
      best = q
    }
  }
  return best
}

// ------------------------------------------------------------ offers

local func pads_in_use(w){
  local used = {}
  for(let local o in values(w.board.offers)){
    append(used, o.pad)
    if(o.to != null){
      append(used, o.to)
    }
  }
  if(w.job != null and w.job.to != null){
    append(used, w.job.to)
  }
  return used
}

// the kind of the next offer: by weight, not three of a kind, a
// delivery when there is none
local func next_kind(w){
  local count = {}
  for(let local o in values(w.board.offers)){
    count[o.kind] = (count[o.kind] or 0) + 1
  }
  if(count.delivery == null){
    return "delivery"
  }
  local total = 0
  for(let local k in values(m.ORDER)){
    if((count[k] or 0) < 2){
      total = total + m.KINDS[k].weight
    }
  }
  local r = w.rng:range(0, total)
  for(let local k in values(m.ORDER)){
    if((count[k] or 0) < 2){
      r = r - m.KINDS[k].weight
      if(r <= 0){
        return k
      }
    }
  }
  return "delivery"
}

// new_offer(w, kind?, near?) -> an offer on the board: a pad within reach
// of the car (near: closer still), its pay, how long it stays up
func m.new_offer(w, kind, near){
  kind = kind or next_kind(w)
  local car = w.car
  local lo = 120
  local hi = 600
  if(near){
    hi = 350
  }
  local pad = pad_from(w, car.pos, lo, hi, pads_in_use(w))
  local life = w.rng:range(m.OFFER_TIME[0], m.OFFER_TIME[1])
  local o = {kind: kind, pad: pad, left: life, life: life}
  local scale = level_scale(w)
  if(kind == "delivery"){
    local used = pads_in_use(w)
    append(used, pad)
    o.to = pad_from(w, pad, 250, 750, used)
    o.what = w.rng:pick(packages)
    o.fragile = w.rng:chance(0.3)
    o.distance = vec.distance(pad, o.to)
    o.pay = to_int((40 + o.distance * 0.25) * scale)
    if(o.fragile){
      o.pay = to_int(o.pay * 1.4)
    }
  } else if(kind == "race"){
    local used = pads_in_use(w)
    append(used, pad)
    o.to = pad_from(w, pad, 500, 900, used)
    o.distance = vec.distance(pad, o.to)
    o.pay = to_int((120 + o.distance * 0.35) * scale)
  } else if(kind == "takedown"){
    o.pay = to_int(260 * scale)
  } else {
    o.pay = to_int(200 * scale)
  }
  append(w.board.offers, o)
  event(w, "offer", {offer: o})
  return o
}

// the board, filled: the first offer a delivery near the car
local func init(w){
  w.board = {offers: {}, refill: 0, leaving: {}}
  m.new_offer(w, "delivery", true)
  for(local k = 1; k < m.OFFERS; k = k + 1){
    m.new_offer(w)
  }
}

// board(w) -> the board ({offers}), filled the first time it is asked for
func m.board(w){
  if(w.board == null){
    init(w)
  }
  return w.board
}

// ------------------------------------------------------------ taking one

local func spawn_npc(w, pos, toward, role, tint){
  local d = vec.sub(toward, pos)
  local npc = world.spawn(w, pos, math.atan2(d.x, d.z), {role: role, tint: tint})
  return npc
}

local func accept(w, o){
  local car = w.car
  local scale = level_scale(w)
  local job = {kind: o.kind, pay: o.pay, offer: o, name: m.KINDS[o.kind].name}
  if(o.kind == "delivery"){
    local limit = o.distance / w.level.time_speed + 14
    job.phase = "deliver"
    job.from = o.pad
    job.to = o.to
    job.what = o.what
    job.fragile = o.fragile
    job.limit = limit
    job.left = limit
    job.condition = 1
    job.late = false
    w.last_pad = o.pad
  } else if(o.kind == "race"){
    // the rival waits over the pad, facing the way to go
    local pos = {x: o.pad.x, y: o.pad.y + 8, z: o.pad.z}
    job.rival = spawn_npc(w, pos, o.to, "rival", {120, 255, 170})
    job.rival.pilot = bot.new({aggression: math.min(0.9, 0.3 + 0.15 * w.level_index)})
    job.rival.top = 55 + 5 * w.level_index
    job.to = o.to
    job.phase = "count"
    job.count = m.RACE_COUNT
    w.last_pad = o.pad
  } else if(o.kind == "takedown"){
    local at = node_from(w, car.pos, 90, 180, null, 30)
    job.target = spawn_npc(w, at, car.pos, "target", {255, 90, 90})
    job.target.pilot = bot.new({aggression: 0.5})
    job.target.top = 46 + 4 * w.level_index
    job.target.goal = node_from(w, at, 250, 600, car.pos)
    job.wait = 1.5
    job.limit = m.TAKEDOWN_TIME
    job.left = m.TAKEDOWN_TIME
    job.hull = 1
  } else {
    local at = node_from(w, car.pos, 40, 70, null, 20)
    job.to = pad_from(w, at, 450, 800, pads_in_use(w))
    job.target = spawn_npc(w, at, job.to, "target", {210, 130, 255})
    job.target.pilot = bot.new()
    job.target.top = 30 + 3 * w.level_index
    job.wait = 3
    job.suspicion = 0
    job.lost = 0
  }
  job.trail = {}
  w.job = job
  // off the board
  local kept = {}
  for(let local other in values(w.board.offers)){
    if(other != o){
      append(kept, other)
    }
  }
  w.board.offers = kept
  event(w, "accept", {job: job})
  return job
}

// whether the car takes an offer now
local func takes(w, o){
  local car = w.car
  if(o.kind == "delivery" or o.kind == "race"){
    return world.at_pad(car, o.pad)
  }
  local h = car.pos.y - o.pad.y
  return flat_distance(car.pos, o.pad) < m.ACCEPT and h > -3 and h < 25
}

// ------------------------------------------------------------ ending one

// the other cars of a job: out of the world (a wreck after it has fallen
// a while)
local func clear_npcs(w, job){
  local func away(npc){
    if(npc != null){
      if(npc.wrecked){
        append(w.board.leaving, {npc: npc, left: 4})
      } else {
        world.despawn(w, npc)
      }
    }
  }
  away(job.rival)
  away(job.target)
}

local func finish(w, job, pay){
  clear_npcs(w, job)
  w.job = null
  w.credits = w.credits + pay
  w.jobs = w.jobs + 1
  w.level_jobs = w.level_jobs + 1
  event(w, "job_done", {job: job, pay: pay})
  if(job.kind == "delivery"){
    event(w, "deliver", {job: job, pay: pay})
  }
  if(w.level_jobs >= w.level.jobs){
    // the chain under way is banked before the district changes
    near_miss.bank(w.near_miss, w)
    event(w, "level_up", {next: w.level_index + 1, level: levels.get(w.level_index + 1)})
  }
}

local func fail(w, job, why){
  clear_npcs(w, job)
  w.job = null
  event(w, "job_failed", {job: job, why: why})
}

// ------------------------------------------------------------ the step

// the other cars' inputs for this frame
local func fly_npcs(w, dt){
  local job = w.job
  if(job == null){
    return
  }
  // a target waits a moment before it sets off, then works up to its
  // speed
  local ease = 1
  if(job.wait != null){
    job.wait = job.wait - dt
    if(job.wait > 0){
      job.target.input = null
      return
    }
    ease = vec.clamp(-job.wait / 6, 0.3, 1)
  }
  if(job.kind == "race"){
    local r = job.rival
    if(job.phase == "race"){
      r.input = bot.drive(w, r.car, r.pilot, {x: job.to.x, y: job.to.y + 2.5, z: job.to.z}, dt, {top: r.top})
    } else {
      r.input = null
    }
  } else if(job.kind == "takedown"){
    local t = job.target
    if(not t.wrecked){
      if(vec.distance(t.car.pos, t.goal) < 30){
        t.goal = node_from(w, t.car.pos, 250, 600, w.car.pos)
      }
      if((t.stunned or 0) > 0){
        t.stunned = t.stunned - dt
        t.input = null
        t.pilot.route = null
      } else {
        local top = t.top * ease * (0.6 + 0.4 * job.hull)
        t.input = bot.drive(w, t.car, t.pilot, t.goal, dt, {land: false, top: top})
      }
    }
  } else if(job.kind == "tail"){
    local t = job.target
    t.input = bot.drive(w, t.car, t.pilot, {x: job.to.x, y: job.to.y + 2.5, z: job.to.z}, dt, {top: t.top * ease})
  }
}

local func job_step(w, dt){
  local job = w.job
  local car = w.car
  if(job == null){
    return
  }
  // the target's trail: where it has flown (clear: it flew there)
  if(job.target != null and not job.target.wrecked){
    local trail = job.trail
    local p = job.target.car.pos
    if(len(trail) == 0 or vec.distance(trail[len(trail) - 1], p) >= m.TRAIL_STEP){
      append(trail, {x: p.x, y: p.y, z: p.z})
      if(len(trail) > 300){
        remove(trail, 0)
      }
    }
  }
  for(let local e in values(w.events)){
    if(e.kind == "wreck"){
      fail(w, job, "wrecked")
      return
    }
    if(e.kind == "hit" and job.kind == "delivery"){
      local loss = e.impact * 0.012
      if(job.fragile){
        loss = loss * 2
      }
      job.condition = math.max(0, job.condition - loss)
    }
    if(e.kind == "ram" and e.npc == job.target and w.time - (job.rammed or -10) > 0.5){
      job.rammed = w.time
      if(job.kind == "takedown"){
        local damage = vec.clamp((e.impact - 4) / 30, 0.05, 0.6)
        job.hull = math.max(0, job.hull - damage)
        // it spins out a moment, and flies slower for the damage
        job.target.stunned = 0.8
        event(w, "target_hit", {job: job, damage: damage, pos: e.pos})
        if(job.hull <= 0){
          world.wreck_npc(w, job.target)
          finish(w, job, job.pay)
          return
        }
      } else if(job.kind == "tail"){
        fail(w, job, "spotted")
        return
      }
    }
  }
  if(job.kind == "delivery"){
    job.left = job.left - dt
    if(job.left <= 0 and not job.late){
      job.late = true
      event(w, "late", {job: job})
    }
    if(world.at_pad(car, job.to)){
      local pay = job.pay * (0.5 + 0.5 * job.condition)
      if(job.late){
        pay = pay * 0.3
      } else {
        pay = pay * (1 + 0.6 * job.left / job.limit)
      }
      w.last_pad = job.to
      finish(w, job, to_int(pay))
    }
  } else if(job.kind == "race"){
    if(job.phase == "count"){
      local before = ceil(job.count)
      job.count = job.count - dt
      if(job.count <= 0){
        job.phase = "race"
        event(w, "race_go", {job: job})
      } else if(ceil(job.count) != before){
        event(w, "count", {n: to_int(ceil(job.count))})
      }
      return
    }
    if(world.at_pad(car, job.to)){
      w.last_pad = job.to
      finish(w, job, job.pay)
    } else if(vec.distance(job.rival.car.pos, {x: job.to.x, y: job.to.y + 2.5, z: job.to.z}) < 6){
      fail(w, job, "the rival got there first")
    }
  } else if(job.kind == "takedown"){
    job.left = job.left - dt
    if(job.left <= 0){
      fail(w, job, "it got away")
    }
  } else if(job.kind == "tail"){
    local d = vec.distance(car.pos, job.target.car.pos)
    job.distance = d
    if(d < m.TAIL_NEAR){
      job.suspicion = job.suspicion + dt / m.TAIL_SPOT
    } else {
      job.suspicion = math.max(0, job.suspicion - dt * 0.15)
    }
    if(d > m.TAIL_FAR){
      job.lost = job.lost + dt / m.TAIL_LOSE
    } else {
      job.lost = math.max(0, job.lost - dt * 0.3)
    }
    if(job.suspicion >= 1){
      fail(w, job, "spotted")
    } else if(job.lost >= 1){
      fail(w, job, "lost it")
    } else if(vec.distance(job.target.car.pos, {x: job.to.x, y: job.to.y + 2.5, z: job.to.z}) < 6){
      w.last_pad = job.to
      finish(w, job, job.pay)
    }
  }
}

local func board_step(w, dt){
  local board = w.board
  local kept = {}
  for(let local o in values(board.offers)){
    o.left = o.left - dt
    if(o.left > 0){
      append(kept, o)
    } else {
      event(w, "offer_gone", {offer: o})
    }
  }
  board.offers = kept
  if(len(board.offers) < m.OFFERS){
    board.refill = board.refill - dt
    if(board.refill <= 0){
      m.new_offer(w)
      board.refill = m.REFILL
    }
  } else {
    board.refill = m.REFILL
  }
  // taking one
  if(w.job == null and w.state == "play"){
    for(let local o in values(board.offers)){
      if(takes(w, o)){
        accept(w, o)
        break
      }
    }
  }
  // wrecks of jobs gone, taken away after they have fallen a while
  local leaving = {}
  for(let local l in values(board.leaving)){
    l.left = l.left - dt
    if(l.left > 0){
      append(leaving, l)
    } else {
      world.despawn(w, l.npc)
    }
  }
  board.leaving = leaving
}

// step(w, input, dt): the flyers (game/flyers) and the other cars'
// inputs, the world's step (the
// player's car held still during a race's count), then the job and the
// board
func m.step(w, input, dt){
  m.board(w)
  if(w.flyers == null and w.flyer_count > 0){
    flyers.new(w, w.flyer_count)
  }
  flyers.step(w, dt)
  fly_npcs(w, dt)
  if(w.job != null and w.job.kind == "race" and w.job.phase == "count"){
    input = {pitch: 0, roll: 0, yaw: 0, throttle: 0, brake: 0, boost: false, magnet: false}
  }
  world.step(w, input, dt)
  job_step(w, dt)
  board_step(w, dt)
}

// ------------------------------------------------------------ where to go

// target(w) -> what the car should fly to now, or null: {pos, color,
// pad?, npc?}
func m.target(w){
  local job = w.job
  if(job == null){
    return null
  }
  local color = m.KINDS[job.kind].color
  if(job.kind == "delivery"){
    return {pos: job.to, pad: job.to, color: {255, 150, 40}}
  }
  if(job.kind == "race"){
    return {pos: job.to, pad: job.to, color: color}
  }
  return {pos: job.target.car.pos, npc: job.target, color: color}
}

// ------------------------------------------------------------ the autopilot

// autopilot(w, dt, o?: {prefer: {kinds}}) -> the input for the player's
// car: to the nearest offer (of the kinds it prefers) when idle, then
// through the job: a delivery or a race to the pad, a takedown at the
// target (rammed, flown at its aggressive best), a tail behind the
// target at a distance; the two last along the target's trail
func m.autopilot(w, dt, o){
  o = o or {}
  local car = w.car
  local idle = {pitch: 0, roll: 0, yaw: 0, throttle: 0, brake: 0, boost: false, magnet: false}
  if(w.state != "play"){
    return idle
  }
  if(w.pilot == null){
    w.pilot = bot.new()
  }
  if(w.chase_pilot == null){
    w.chase_pilot = bot.new({aggression: 1})
  }
  local job = w.job
  if(job == null){
    local best = null
    local bd = 1e18
    for(let local offer in values(m.board(w).offers)){
      local wanted = o.prefer == null
      for(let local k in values(o.prefer or {})){
        if(k == offer.kind){
          wanted = true
        }
      }
      local d = vec.distance(offer.pad, car.pos)
      if(wanted and d < bd and offer.left > d / 40 + 3){
        bd = d
        best = offer
      }
    }
    if(best == null){
      return idle
    }
    return bot.drive(w, car, w.pilot, {x: best.pad.x, y: best.pad.y + 2.5, z: best.pad.z}, dt)
  }
  if(job.kind == "delivery" or job.kind == "race"){
    if(job.phase == "count"){
      return idle
    }
    return bot.drive(w, car, w.pilot, {x: job.to.x, y: job.to.y + 2.5, z: job.to.z}, dt)
  }
  local t = job.target.car
  // onto the last of the target's trail where it is near, then along it:
  // the air the target flew through, so clear (a route of its own to
  // the target until then)
  local trail = job.trail
  local from = len(trail) - 1
  local behind = 0
  for(from > 0 and behind < 150){
    behind = behind + vec.distance(trail[from], trail[from - 1])
    from = from - 1
  }
  local nearest = -1
  local nd = 1e18
  for(local k = math.max(0, from); k < len(trail); k = k + 1){
    local d = vec.distance(car.pos, trail[k])
    if(d < nd){
      nd = d
      nearest = k
    }
  }
  local d = vec.distance(car.pos, t.pos)
  local aim = vec.add_scaled(t.pos, t.vel, 0.3)
  local path = null
  if(nearest >= 0 and nd < 15){
    path = {car.pos}
    for(local k = nearest + 1; k < len(trail); k = k + 1){
      append(path, trail[k])
    }
    append(path, aim)
  }
  // far behind: to where it is going (planned once, not chasing a point
  // that moves), which cuts it off
  local heading = job.target.goal
  if(heading == null and job.to != null){
    heading = {x: job.to.x, y: job.to.y + 6, z: job.to.z}
  }
  if(path == null and d > 120 and heading != null and
      vec.distance(car.pos, heading) > vec.distance(t.pos, heading)){
    aim = heading
  }
  if(job.kind == "takedown"){
    // at it, leading it a little, flat out
    return bot.drive(w, car, w.chase_pilot, aim, dt, {land: false, every: 0.5, path: path, ignore: t})
  }
  // a tail: on the trail, no faster than it once near enough; too near
  // (it coming this way), back off from it
  if(d < 30){
    local away = vec.sub(car.pos, t.pos)
    away.y = 0
    if(vec.length(away) < 1){
      away = {x: 1, y: 0, z: 0}
    }
    local off = vec.add_scaled(t.pos, vec.normalize(away), 45)
    off.y = car.pos.y
    return bot.drive(w, car, w.pilot, off, dt, {land: false, top: 25, every: 0.5})
  }
  local top = t.speed + (d - 50) * 0.8
  top = vec.clamp(top, 0, 80)
  if(path == null){
    return bot.drive(w, car, w.pilot, aim, dt, {land: false, top: top + 20, every: 0.6})
  }
  return bot.drive(w, car, w.pilot, aim, dt, {land: false, top: top, path: path})
}

return m
