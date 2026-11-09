// game/flyers: cars that fly the city as the player does, out of the
// lanes, going nowhere in particular: something else to dodge, and to
// see now and then. Each wanders the clear network of game/nav (the
// middles of the streets, in the bands between the levels of lanes): at
// each crossing on, left or right, now and then up or down a band, its
// path a list of points it keeps adding to ahead.
//
// A third of them are dashers: fast and boosting, changing bands
// often. Near the player every path is pulled tight as the autopilot's
// routes are (corners cut, over the lower blocks, climbs on a slant), a
// dasher's through the lanes' levels too: those cut through the traffic,
// the autopilot's watch timing them through its gaps.
//
// Rules keep the cruisers apart without them seeing each other: in a street a
// flyer keeps to the right of the middle (KEEP), so those coming the
// other way pass beside it; along x it flies a little higher in the band
// than along z (RISE), so at a crossing those going across pass over or
// under it; it changes bands in the middle of a crossing, where no lane
// of traffic runs. Whatever the rules miss, the autopilot's watch takes
// (game/bot: the one behind gives way, and crossing the lower rank).
//
// Far from the player a flyer only slides along its path (as the traffic
// does: nothing to hit there). Within NEAR of the player it is a car of
// the world (world.spawn) the autopilot flies along the same path, which
// bumps into things and is bumped; past FAR it slides again from where
// it got to.
local math = require("slang/math")
local vec = require("game/vec")
local world = require("game/world")
local bot = require("game/bot")
local nav_lib = require("game/nav")

local m = {}

m.NEAR = 200      // m from the player where a flyer becomes a car
m.FAR = 260       // ... and where it stops being one
m.KEEP = 4.5      // m to the right of a street's middle
m.RISE = 1.25     // m over the band along x, under it along z
m.TURN_IN = 10    // m before and after a crossing a turn cuts across
m.AHEAD = 400     // m of path kept ahead
m.CLIMB = 0.12    // the chance of a band up or down at a crossing
m.SPEED = {28, 55} // m/s its cruising speed, from to
m.DASH = 0.35     // the share of dashers: fast, boosting, through the lanes
m.DASH_SPEED = {62, 88}
m.DASH_CLIMB = 0.4 // their chance of a band up or down at a crossing
m.TIGHTEN = 700   // m from the player within which paths are pulled tight
m.TIGHTEN_EACH = 3 // paths pulled tight a frame, at most

// cruisers: muted bodies like the traffic's, a little lighter (the model
// is the player's, tinted); dashers: the city's neons
local tints = {
  {170, 180, 200}, {120, 130, 150}, {200, 160, 180}, {140, 170, 190},
  {190, 190, 170}, {150, 140, 170},
}
local dash_tints = {
  {255, 90, 210}, {60, 235, 255}, {255, 170, 60}, {170, 255, 110},
}

local func right_of(h){
  return {x: -h.z, y: 0, z: h.x}
}

// where along a heading h the flyer keeps, about a point c at band height y
local func kept(c, h, y){
  local rise = -m.RISE
  if(h.x != 0){
    rise = m.RISE
  }
  return vec.add_scaled({x: c.x, y: y + rise, z: c.z}, right_of(h), m.KEEP)
}

local headings = {{x: 1, y: 0, z: 0}, {x: -1, y: 0, z: 0}, {x: 0, y: 0, z: 1}, {x: 0, y: 0, z: -1}}

// the crossing's point
local func node_pos(nav, i, j, b){
  return {x: nav.lines[i], y: nav.bands[b], z: nav.lines[j]}
}

// the path on from the crossing the flyer is heading into: which way
// next, the points through the crossing, the crossing after
local func extend(f, nav, rng){
  local c = node_pos(nav, f.i, f.j, f.b)
  local h = f.h
  // the ways out: on, left, right (back only at a corner of the city)
  local ways = {}
  for(let local g in values(headings)){
    local back = g.x == -h.x and g.z == -h.z
    local ni = f.i + g.x
    local nj = f.j + g.z
    if(not back and ni >= 0 and nj >= 0 and ni <= nav.n and nj <= nav.n){
      local weight = 1
      if(g.x == h.x and g.z == h.z){
        weight = 3
      }
      append(ways, {g: g, weight: weight})
    }
  }
  local g = {x: -h.x, y: 0, z: -h.z}
  if(len(ways) > 0){
    local total = 0
    for(let local w in values(ways)){
      total = total + w.weight
    }
    local r = rng:range(0, total)
    for(let local w in values(ways)){
      r = r - w.weight
      if(r <= 0){
        g = w.g
        break
      }
    }
  }
  // up or down a band, now and then, in the middle of the crossing
  local b = f.b
  local climb = m.CLIMB
  if(f.style == "dash"){
    climb = m.DASH_CLIMB
  }
  if(rng:chance(climb)){
    local nb = b + rng:pick({-1, 1})
    if(nb >= 0 and nb < len(nav.bands)){
      b = nb
    }
  }
  append(f.path, kept(vec.add_scaled(c, h, -m.TURN_IN), h, nav.bands[f.b]))
  if(b != f.b){
    append(f.path, {x: c.x, y: nav.bands[f.b], z: c.z})
    append(f.path, {x: c.x, y: nav.bands[b], z: c.z})
  }
  append(f.path, kept(vec.add_scaled(c, g, m.TURN_IN), g, nav.bands[b]))
  f.i = f.i + g.x
  f.j = f.j + g.z
  f.b = b
  f.h = g
}

// the length of the path ahead of the flyer
local func ahead(f){
  local total = 0
  local p = f.pos
  for(local k = f.k + 1; k < len(f.path); k = k + 1){
    total = total + vec.distance(p, f.path[k])
    p = f.path[k]
  }
  return total
}

local func keep_ahead(f, nav, rng){
  // (only when it has moved on to another segment)
  if(f.ahead_k == f.k){
    return
  }
  f.ahead_k = f.k
  for(ahead(f) < m.AHEAD){
    extend(f, nav, rng)
    f.loose = true
  }
  // the points well behind, dropped
  if(f.k > 8){
    local kept_pts = {}
    for(local k = f.k - 2; k < len(f.path); k = k + 1){
      append(kept_pts, f.path[k])
    }
    f.path = kept_pts
    f.k = 2
    f.ahead_k = 2
    f.corner_k = null
    f.look_k = null
  }
}

// a flyer put somewhere on the network, on its way along a street
local func new_flyer(w, nav, rng, id){
  local f = {
    id: id,
    rank: id,
    i: rng:int(nav.n + 1), j: rng:int(nav.n + 1), b: rng:int(len(nav.bands)),
    h: rng:pick(headings),
    style: "cruise",
    cruise: rng:range(m.SPEED[0], m.SPEED[1]),
    tint: rng:pick(tints),
    path: {},
    k: 0,
    npc: null,
  }
  if(rng:chance(m.DASH)){
    f.style = "dash"
    f.cruise = rng:range(m.DASH_SPEED[0], m.DASH_SPEED[1])
    f.tint = rng:pick(dash_tints)
  }
  // the crossing it came from, if in the city; else the way back
  local pi = f.i - f.h.x
  local pj = f.j - f.h.z
  if(pi < 0 or pj < 0 or pi > nav.n or pj > nav.n){
    f.h = {x: -f.h.x, y: 0, z: -f.h.z}
    pi = f.i - f.h.x
    pj = f.j - f.h.z
  }
  // somewhere along the street from there
  local from = kept(vec.add_scaled(node_pos(nav, pi, pj, f.b), f.h, m.TURN_IN), f.h, nav.bands[f.b])
  local to = kept(vec.add_scaled(node_pos(nav, f.i, f.j, f.b), f.h, -m.TURN_IN), f.h, nav.bands[f.b])
  f.pos = vec.lerp(from, to, rng:range(0, 0.9))
  f.path = {f.pos}
  f.speed = f.cruise
  f.vel = vec.scale(f.h, f.speed)
  f.q = vec.quat_look(f.h, {x: 0, y: 1, z: 0})
  keep_ahead(f, nav, rng)
  // what render.car draws while it only slides
  f.ghost = {pos: f.pos, q: f.q, vel: f.vel, speed: f.speed, thrust: 0.5, boosting: false, mode: "fly"}
  return f
}

// new(w, count) -> the flyers of a world (w.flyers), count of them
func m.new(w, count){
  local nav = bot.nav(w)
  local rng = vec.random(w.seed * 977 + 13)
  local list = {}
  for(local k = 0; k < count; k = k + 1){
    append(list, new_flyer(w, nav, rng, k))
  }
  w.flyers = {list: list, rng: rng}
  return w.flyers
}

// ------------------------------------------------------------ sliding

// how fast to take the corner at the end of segment k
local func corner_speed(f, k){
  local pts = f.path
  if(k + 2 >= len(pts)){
    return f.cruise
  }
  local d0 = vec.normalize(vec.sub(pts[k + 1], pts[k]))
  local d1 = vec.normalize(vec.sub(pts[k + 2], pts[k + 1]))
  local a = math.acos(vec.clamp(vec.dot(d0, d1), -1, 1))
  if(a < 0.1){
    return f.cruise
  }
  return math.min(f.cruise, 12 + (math.pi / 2 - math.min(a, math.pi / 2)) * 30)
}

// along its path at its speed, slowing for its corners; turned smoothly
// only where it can be seen well (smooth: within some hundreds of meters)
local func slide(f, dt, smooth){
  local pts = f.path
  local target = pts[f.k + 1]
  local to_end = vec.distance(f.pos, target)
  if(f.corner_k != f.k){
    f.corner_k = f.k
    f.corner_v = corner_speed(f, f.k)
  }
  local cv = f.corner_v
  local want = math.min(f.cruise, math.sqrt(cv * cv + 2 * 14 * to_end))
  f.speed = vec.approach(f.speed, want, 2, dt)
  local step = f.speed * dt
  local p = f.pos
  for(step > 0 and f.k + 1 < len(pts)){
    local q = pts[f.k + 1]
    local d = vec.distance(p, q)
    if(d > step){
      p = vec.add_scaled(p, vec.normalize(vec.sub(q, p)), step)
      step = 0
    } else {
      p = q
      step = step - d
      f.k = f.k + 1
    }
  }
  local moved = vec.sub(p, f.pos)
  if(dt > 0){
    f.vel = vec.scale(moved, 1 / dt)
  }
  f.pos = p
  // turned to where it goes (level when it climbs straight up)
  if(f.k + 1 < len(pts) and (smooth or f.look_k != f.k)){
    f.look_k = f.k
    local dir = vec.normalize(vec.sub(pts[f.k + 1], f.pos))
    local up = {x: 0, y: 1, z: 0}
    if(math.abs(dir.y) > 0.9){
      up = vec.axes(f.q).forward
    }
    local want_q = vec.quat_look(dir, up)
    if(smooth){
      f.q = vec.quat_slerp(f.q, want_q, 1 - math.exp(-dt * 5))
    } else {
      f.q = want_q
    }
  }
  local g = f.ghost
  g.pos = f.pos
  g.q = f.q
  g.vel = f.vel
  g.speed = f.speed
  g.boosting = f.style == "dash" and f.speed > 60
  g.thrust = math.min(1, 0.3 + f.speed / 80)
}

// ------------------------------------------------------------ flying

// the nearest point of its path to where its car is: the segment it is on
local func catch_up(f){
  local pts = f.path
  local best = f.k
  local bd = 1e18
  for(local k = math.max(0, f.k - 1); k < math.min(len(pts) - 1, f.k + 6); k = k + 1){
    local a = pts[k]
    local b = pts[k + 1]
    local ab = vec.sub(b, a)
    local l2 = vec.dot(ab, ab)
    local t = 0
    if(l2 > 0.0001){
      t = vec.clamp(vec.dot(vec.sub(f.pos, a), ab) / l2, 0, 1)
    }
    local d = vec.distance(f.pos, vec.add_scaled(a, ab, t))
    if(d < bd){
      bd = d
      best = k
    }
  }
  f.k = best
}

local func become_car(w, f){
  local yaw = math.atan2(f.vel.x, f.vel.z)
  f.npc = world.spawn(w, f.pos, yaw, {role: "flyer", tint: f.tint, rank: f.rank})
  local car = f.npc.car
  car.q = f.q
  car.body:set_position_rotation_and_velocity(f.pos, f.q, f.vel, {0, 0, 0})
  car.trail = f.ghost.trail
  local aggression = 0.2
  if(f.style == "dash"){
    aggression = 0.7
  }
  f.pilot = bot.new({aggression: aggression})
}

local func become_ghost(w, f){
  local car = f.npc.car
  f.pos = car.pos
  f.q = car.q
  f.vel = car.vel
  f.speed = car.speed
  f.ghost.trail = car.trail
  world.despawn(w, f.npc)
  f.npc = null
  f.pilot = null
  catch_up(f)
}

// the path ahead pulled tight (nav.smooth): corners cut, across the
// lower blocks, climbs on a slant; a dasher's through the lanes' levels
// too, nearer the buildings
local func tighten(f, nav){
  local from = f.k + 1
  local rest = {}
  for(local k = from; k < len(f.path); k = k + 1){
    append(rest, f.path[k])
  }
  f.loose = false
  if(len(rest) < 4){
    return
  }
  local o = {}
  if(f.style == "dash"){
    o = {lanes: false, short_r: 3}
  }
  local tight = nav_lib.smooth(nav, rest, o)
  local path = {}
  for(local k = 0; k < from; k = k + 1){
    append(path, f.path[k])
  }
  for(let local p in values(tight)){
    append(path, p)
  }
  f.path = path
  f.corner_k = null
  f.look_k = null
  // (shorter now: more ahead, at once)
  f.ahead_k = null
}

// step(w, dt): the flyers on: sliding, or flown (their inputs set for
// the world's step); cars near the player, slides far from it
func m.step(w, dt){
  local fl = w.flyers
  if(fl == null){
    return
  }
  local nav = bot.nav(w)
  local player = w.car.pos
  local tightened = 0
  for(let local f in values(fl.list)){
    // (a few a frame, those that can be seen first)
    if(f.loose and tightened < m.TIGHTEN_EACH and vec.distance(f.pos, player) < m.TIGHTEN){
      tighten(f, nav)
      tightened = tightened + 1
    }
    if(f.npc != null){
      local car = f.npc.car
      f.pos = car.pos
      catch_up(f)
      keep_ahead(f, nav, fl.rng)
      if(f.npc.wrecked or vec.distance(f.pos, player) > m.FAR){
        become_ghost(w, f)
      } else {
        local path = {car.pos}
        for(local k = f.k + 1; k < len(f.path); k = k + 1){
          append(path, f.path[k])
        }
        f.npc.input = bot.drive(w, car, f.pilot, path[len(path) - 1], dt,
          {land: false, path: path, top: f.cruise, rank: f.rank})
      }
    } else {
      local d = vec.distance(f.pos, player)
      slide(f, dt, d < 400)
      keep_ahead(f, nav, fl.rng)
      if(d < m.NEAR){
        become_car(w, f)
      }
    }
  }
}

// cars(w) -> what to draw for each flyer: {car, tint}
func m.cars(w){
  local out = {}
  if(w.flyers == null){
    return out
  }
  for(let local f in values(w.flyers.list)){
    if(f.npc == null){
      append(out, {car: f.ghost, tint: f.tint})
    }
  }
  return out
}

// clear(w): the flyers' cars out of the world
func m.clear(w){
  if(w.flyers == null){
    return
  }
  for(let local f in values(w.flyers.list)){
    if(f.npc != null){
      world.despawn(w, f.npc)
      f.npc = null
    }
  }
  w.flyers = null
}

return m
