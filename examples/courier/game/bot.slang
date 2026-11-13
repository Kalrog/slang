// game/bot: the autopilot. It plans a route (game/nav: along the middles
// of the streets, in the bands between the levels of lanes) and flies
// it: it aims at a point a little way ahead on the route (further the
// faster it goes), leading its own slide; it takes the speed from the
// corners ahead (as fast as it can still slow down for them in time) and
// comes in slow at the end; it banks a little into its turns and boosts
// on long straights and to get up to speed. It keeps the magnet from grabbing what it
// passes, and jumps off what it sticks to anyway. Two watches keep it
// whole between the plan and the world: a traffic car about to come
// close makes it brake short of the lane (braking lets it by), or hurry
// out of the lane if it is already in it, and
// a wall in its way within its stopping distance makes it brake and plan
// again. It plans again when it strays from the route, stalls, or hits
// something, and when its goal moves.
//
// drive(w, car, pilot, goal, dt) flies any car to any goal (a rival, a
// car to chase, the player's car through its jobs: game/missions).
local math = require("slang/math")
local vec = require("game/vec")
local car_lib = require("game/car")
local nav_lib = require("game/nav")

local m = {}

m.DECEL = 22          // m/s^2 it counts on to slow down for what is ahead
m.ARRIVE = 10         // m/s at the end of a route that lands (a pad takes 18)
m.ARRIVE_DOWN = 3     // ... coming down onto it
m.STRAY = 7           // m off its route before it plans again
m.LOOK_MIN = 6        // m it aims ahead on its route, at a standstill
m.LOOK_TIME = 0.45    // s of its speed further at speed
m.CORNER = 20         // m/s through a right angle (more through less)

// new(o?: {aggression: 0..1}) -> the state of a pilot: its route and how
// it is doing. Aggression (0, the careful default) makes it boost more,
// take its corners faster and brake later, run its routes closer to the
// lanes and the buildings, and give way to traffic later and less: a
// rival in a hurry.
func m.new(o){
  o = o or {}
  local a = vec.clamp(o.aggression or 0, 0, 1)
  return {
    route: null, k: 0, goal: null, stall: 0, backing: 0, plans: 0, failed: 0, brake_time: 0,
    aggression: a,
    decel: m.DECEL + 8 * a,
    corner: m.CORNER + 9 * a,
    // threat: how near a traffic car may pass before it reacts, and how
    // much it slows then
    threat_miss: 4.2 - 1.2 * a,
    threat_slow: 0.4 + 0.4 * a,
    // boost: the straight it wants, the meter it keeps, getting up to speed
    boost_straight: 220 - 150 * a,
    boost_keep: 0.25 * (1 - a),
    boost_gap: 20 - 12 * a,
    route_o: {
      lane_cost: nav_lib.LANE_COST * (1 - a) + 40,
      lane_across: nav_lib.LANE_ACROSS - 0.7 * a,
      lane_up: nav_lib.LANE_UP - 1.0 * a,
      short_r: nav_lib.SHORT_R - 1.5 * a,
    },
  }
}

// the navigation of a world's city, made once
func m.nav(w){
  if(w.nav == null){
    w.nav = nav_lib.new(w.city, w.phys.ceiling + car_lib.HEADROOM - 3)
  }
  return w.nav
}

// ------------------------------------------------------------ the route

local func plan(w, car, p, goal, land){
  p.plans = p.plans + 1
  local skip_to = 0
  if(land){
    skip_to = 3
  }
  local ro = p.route_o
  local route = nav_lib.route(m.nav(w), car.pos, goal, {
    skip_from: 3, skip_to: skip_to, lane_cost: ro.lane_cost, lane_across: ro.lane_across,
    lane_up: ro.lane_up, short_r: ro.short_r,
  })
  if(route == null){
    // nowhere to go from here: straight at it, and try again soon
    p.failed = p.failed + 1
    route = {car.pos, goal}
  }
  p.route = route
  p.k = 0
  p.goal = goal
}

// the closest point of segment a-b to q, as a fraction along it
local func along(a, b, q){
  local d = vec.sub(b, a)
  local l2 = vec.dot(d, d)
  if(l2 < 0.0001){
    return 1
  }
  return vec.clamp(vec.dot(vec.sub(q, a), d) / l2, 0, 1)
}

// how fast it may take a corner turning by angle a (corner: through a
// right angle)
local func corner_speed(a, corner){
  if(a < 0.12){
    return 200
  }
  if(a > math.pi / 2){
    return 9
  }
  return corner + (math.pi / 2 - a) * 28
}

// where it is on its route: the segment (moving on past the ones it is
// done with), how far off it is, the point to aim at, and the speed it
// can go for what is ahead (stop: whether the route ends in a stop)
local func follow(p, car, look, stop){
  local pts = p.route
  local n = len(pts)
  // on to the next segment once past this one, or nearer that one
  for(p.k < n - 2){
    local t = along(pts[p.k], pts[p.k + 1], car.pos)
    local here = vec.distance(car.pos, vec.lerp(pts[p.k], pts[p.k + 1], t))
    local u = along(pts[p.k + 1], pts[p.k + 2], car.pos)
    local there = vec.distance(car.pos, vec.lerp(pts[p.k + 1], pts[p.k + 2], u))
    if(t >= 0.999 or there < here){
      p.k = p.k + 1
    } else {
      break
    }
  }
  local a = pts[p.k]
  local b = pts[math.min(p.k + 1, n - 1)]
  local q = vec.lerp(a, b, along(a, b, car.pos))
  local off = vec.distance(car.pos, q)
  // the aim: look meters on from q along the route
  local left = look
  local aim = q
  local from = q
  local k = p.k
  for(k < n - 1){
    local to = pts[k + 1]
    local d = vec.distance(from, to)
    if(d >= left){
      aim = vec.add_scaled(from, vec.normalize(vec.sub(to, from)), left)
      break
    }
    left = left - d
    from = to
    aim = to
    k = k + 1
  }
  // the speed: what it can still slow down from for each corner ahead,
  // and for the end
  local fast = 200
  local s = vec.distance(q, b)
  for(local c = p.k + 1; c < n and s < 300; c = c + 1){
    local v = 200
    if(c == n - 1){
      if(stop){
        v = m.ARRIVE
        // coming down onto it: slow, or it carries on into the roof
        if(pts[c].y < pts[c - 1].y - 0.5 * vec.distance(pts[c], pts[c - 1])){
          v = m.ARRIVE_DOWN
        }
      }
    } else {
      local d0 = vec.normalize(vec.sub(pts[c], pts[c - 1]))
      local d1 = vec.normalize(vec.sub(pts[c + 1], pts[c]))
      v = corner_speed(math.acos(vec.clamp(vec.dot(d0, d1), -1, 1)), p.corner)
    }
    fast = math.min(fast, math.sqrt(v * v + 2 * p.decel * s))
    if(c + 1 < n){
      s = s + vec.distance(pts[c], pts[c + 1])
    }
  }
  local straight = vec.distance(q, b)
  return {aim: aim, off: off, speed: fast, straight: straight, rest: vec.distance(car.pos, pts[n - 1])}
}

// ------------------------------------------------------------ the watches

// a traffic car about to come close: the soonest, as seconds, or null
// how soon (s) something moving at vel from pos comes within near of the
// car, if it does in the next moments
local func closing(car, pos, vel, near){
  // (most are far: out before anything is made)
  local dx = pos.x - car.pos.x
  local dy = pos.y - car.pos.y
  local dz = pos.z - car.pos.z
  if(dx * dx + dy * dy + dz * dz > 3600){
    return null
  }
  local r = {x: dx, y: dy, z: dz}
  local v = vec.sub(vel, car.vel)
  local vv = vec.dot(v, v)
  local tca = 0
  if(vv > 0.01){
    tca = vec.clamp(-vec.dot(r, v) / vv, 0, 2)
  }
  local miss = vec.length(vec.add_scaled(r, v, tca))
  if(tca < 1.3 and miss < near){
    return tca
  }
  return null
}

// the soonest something is about to come close that this car should
// give way to, as seconds, or null: a traffic car (they mind nothing),
// or another car flying free (game/flyers, game/missions) or the
// player's. Between two cars flying free, the one behind gives way to
// the one ahead; crossing, the lower rank gives way (the player's car
// outranks them all).
local func traffic_threat(w, car, near_miss, rank, ignore){
  local soonest = null
  for(let local t in values(w.traffic.near)){
    if(t.pos != null and not t.wrecked){
      // (a long or tall car reaches further from its middle)
      local extra = 0
      if(t.half != null){
        extra = math.max(0, math.max(t.half.z - 2.3, t.half.y - 0.85))
      }
      local tca = closing(car, t.pos, t.vel, near_miss + extra)
      if(tca != null and (soonest == null or tca < soonest)){
        soonest = tca
      }
    }
  }
  local func other(o, o_rank){
    if(o == car or o == ignore){
      return
    }
    local tca = closing(car, o.pos, o.vel, near_miss + 0.8)
    if(tca == null){
      return
    }
    local r = vec.sub(o.pos, car.pos)
    local ahead = vec.dot(r, car.vel)
    local behind = -vec.dot(r, o.vel)
    local give = false
    if(ahead > 0 and ahead > behind){
      give = true
    } else if(behind > 0 and behind >= ahead){
      give = false
    } else {
      give = rank < o_rank
    }
    if(give and (soonest == null or tca < soonest)){
      soonest = tca
    }
  }
  for(let local npc in values(w.npcs)){
    if(not npc.wrecked){
      other(npc.car, npc.rank or 1e9)
    }
  }
  other(w.car, 1e12)
  return soonest
}

// how far ahead along the velocity the city is clear, up to length
local func clear_ahead(w, car, length){
  if(car.speed < 2){
    return length
  }
  local dir = vec.scale(car.vel, 1 / car.speed)
  local hit = w.phys.jw:cast_ray(vec.add_scaled(car.pos, dir, 2.6), vec.scale(dir, length))
  if(hit == null){
    return length
  }
  local what = w.phys.by_id[hit.body.id]
  if(what == null or what.box == null){
    return length
  }
  return hit.fraction * length + 2.6
}

// ------------------------------------------------------------ the stick

// the stick, throttle and brake to fly along dir at speed want
local func steer(car, input, dir, want){
  local axes = car_lib.axes(car)
  local f = axes.forward
  // lead the slide: aim past dir by how far the velocity is off it
  local d = dir
  if(car.speed > 4){
    local v = vec.scale(car.vel, 1 / car.speed)
    d = vec.normalize(vec.add_scaled(dir, vec.sub(dir, v), 0.8))
  }
  // (axes.right is the car's left side)
  local yaw_err = math.atan2(-vec.dot(d, axes.right), vec.dot(d, f))
  local pitch_err = math.atan2(vec.dot(d, axes.up), vec.dot(d, f))
  input.yaw = vec.clamp(yaw_err * 2.5, -1, 1)
  input.pitch = vec.clamp(-pitch_err * 3, -1, 1)
  // level, banked a little into the turn
  local bank = math.asin(vec.clamp(axes.right.y, -1, 1))
  local want_bank = vec.clamp(yaw_err * 0.6, -0.5, 0.5)
  input.roll = vec.clamp((want_bank - bank) * 2.5, -1, 1)
  // turned well away from where it goes: slow, turn first
  local off = math.max(math.abs(yaw_err), math.abs(pitch_err))
  if(off > 0.9){
    want = math.min(want, 8)
  } else if(off > 0.4){
    want = math.min(want, 25)
  }
  if(car.speed < want - 1){
    input.throttle = vec.clamp((want - car.speed) / 5, 0.25, 1)
  } else if(car.speed > want + 1.5 and car.speed > 3){
    input.brake = vec.clamp((car.speed - want) / 4, 0.3, 1)
  }
  return off
}

// ------------------------------------------------------------ driving

// drive(w, car, p (from new), goal, dt, o?: {land: true (stop at the goal; else fly
// through it), top: m/s, every: s between plans for a goal that moves
// (0.5), path: points to fly instead of a route of its own (a trail to
// follow; its last is the goal), rank: who gives way to whom between cars
// flying free (lower gives way), ignore: a car not to give way to (one to
// ram)}) -> the input for car this frame
func m.drive(w, car, p, goal, dt, o){
  o = o or {}
  local land = o.land != false
  local input = {pitch: 0, roll: 0, yaw: 0, throttle: 0, brake: 0, boost: false, magnet: false}
  local dist = vec.distance(car.pos, goal)
  // stuck to something: off it, unless it is where it lands
  if(car.mode == "stick" and (not land or dist > 10)){
    input.magnet = true
    p.route = null
    return input
  }
  // hits, a goal that moved, or nothing to fly yet: plan
  local hit = false
  for(let local e in values(car.events)){
    if(e.kind == "hit"){
      hit = true
    }
  }
  // (a goal on the move: its route is planned again now and then, and
  // in between the end of the route follows it)
  p.since = (p.since or 0) + dt
  local moved = p.goal != null and vec.distance(p.goal, goal) > 4
  if(o.path != null){
    // a path given (a trail to follow): flown as it is
    p.route = o.path
    p.k = 0
    p.goal = goal
  } else if(p.route == null or hit or p.goal == null or (moved and p.since >= (o.every or 0.5))){
    plan(w, car, p, goal, land)
    p.since = 0
  } else if(moved){
    p.route[len(p.route) - 1] = goal
  }
  local look = m.LOOK_MIN + car.speed * m.LOOK_TIME
  local f = follow(p, car, look, land)
  if(f.off > m.STRAY and o.path == null){
    plan(w, car, p, goal, land)
    f = follow(p, car, look, land)
  }
  // stalled (against something, or stopped where it should not be):
  // back off a moment, then plan again
  if(p.backing > 0){
    p.backing = p.backing - dt
    input.brake = 1
    if(p.backing <= 0 and o.path == null){
      plan(w, car, p, goal, land)
    }
    return input
  }
  if(car.speed < 1.5 and f.speed > 6 and f.rest > 6){
    p.stall = p.stall + dt
  } else {
    p.stall = 0
  }
  if(p.stall > 1.2){
    p.stall = 0
    p.backing = 0.5
    return input
  }
  local want = math.min(f.speed, o.top or 200)
  // the watches
  local stopping = car.speed * car.speed / (2 * p.decel) + 4
  local ahead = clear_ahead(w, car, stopping + 8)
  if(ahead < stopping and f.rest > ahead + 3){
    want = math.min(want, math.max(0, car.speed - 10))
    p.brake_time = p.brake_time + dt
    if(p.brake_time > 0.6){
      p.brake_time = 0
      plan(w, car, p, goal, land)
    }
  } else {
    p.brake_time = 0
  }
  // traffic about to come close: wait short of its lane; once in the
  // lane, get out of it
  local threat = traffic_threat(w, car, p.threat_miss, o.rank or 1e10, o.ignore)
  if(threat != null){
    if(nav_lib.crosses(m.nav(w), car.pos, car.pos)){
      want = math.max(want, 30)
    } else {
      want = math.min(want, car.speed * p.threat_slow)
    }
  }
  // what holds it back, for tool/autopilot
  local why = "route"
  if(threat != null){
    why = "traffic"
  } else if(p.brake_time > 0){
    why = "wall"
  } else if(f.rest < 60){
    why = "arriving"
  } else if(math.abs(car.vel.y) > 0.5 * car.speed and car.speed > 3){
    why = "climbing"
  }
  // the end of a landing: hold over it
  local dir = vec.normalize(vec.sub(f.aim, car.pos))
  if(land and f.rest < 2.5){
    want = 0
  }
  local turned = steer(car, input, dir, want)
  if(why == "route" and turned > 0.4){
    why = "turning"
  }
  if(p.trace){
    p.trace_t = (p.trace_t or 0) + dt
    if(p.trace_t > 0.5){
      p.trace_t = 0
      print("  ", why, " v ", to_int(car.speed), " want ", to_int(want), " route ", to_int(f.speed), " turned ", to_int(turned * 100) / 100,
        " k ", p.k, "/", len(p.route), " off ", to_int(f.off * 10) / 10, " y ", to_int(car.pos.y), " thr ", input.throttle, " br ", input.brake, "\n")
    }
  }
  p.time = p.time or {}
  p.time[why] = (p.time[why] or 0) + dt
  // a long clear straight, lined up: boost
  input.boost = turned < 0.1 and threat == null and (
    (f.straight > p.boost_straight and car.speed > 40 and want > 75 and car.boost > p.boost_keep) or
    (want > car.speed + p.boost_gap and f.straight > 60 and car.boost > 0.5 - 0.4 * p.aggression))
  // keep the magnet from grabbing walls it passes (pressed in the air, it
  // holds off a moment), except coming in to land
  if(car.mode == "fly" and car.cooldown < 0.05 and (not land or dist > 14)){
    input.magnet = true
  }
  return input
}

return m
