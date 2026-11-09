// game/traffic: the other cars, thousands of them. Every lane is a
// conveyor: its cars share its speed and keep their order, so where a
// car is at any moment is a formula of the time (its start along the
// lane plus the lane's speed times the time, wrapped at the city's
// edge). Nothing is stepped: the renderer moves every car in the vertex
// shader from the same formula, and only the cars near the player are
// given kinematic Jolt bodies, from a small pool, so the player's car
// bounces off them. Dodging them is the player's job; they mind nothing.
// One that is hit becomes a wreck: its body turns dynamic, spun and
// thrown out of its lane, until it is taken away a few seconds later.
local math = require("slang/math")
local jolt = require("jolt")
local vec = require("game/vec")
local city = require("game/city")

local m = {}

m.BODIES = 220           // the pool of bodies for the cars near the player
m.NEAR = 100             // how near the player a car gets a body
m.HALF_WIDTH = 1.25
m.HALF_HEIGHT = 0.85
m.HALF_LENGTH = 2.3
m.RADIUS = 2.6           // about, for keeping a distance
m.WRECK_TIME = 6         // seconds a wreck tumbles before it is taken away

// the cars in the city's palette: muted bodies, warm headlights, side
// strips in its two neons
local palettes = {
  {{200, 205, 215}, {255, 236, 200}, {0, 220, 255}},   // body, headlights, side strips
  {{48, 52, 66}, {255, 236, 200}, {255, 50, 170}},
  {{90, 100, 120}, {255, 236, 200}, {0, 220, 255}},
  {{28, 30, 38}, {255, 236, 200}, {0, 220, 255}},
  {{150, 60, 110}, {255, 236, 200}, {255, 50, 170}},
  {{40, 90, 120}, {220, 236, 255}, {0, 220, 255}},
  {{120, 124, 136}, {255, 236, 200}, {255, 50, 170}},
}

// where along the lane a start s0 is at a time: wrapped into -limit..limit
local func along(lane, s0, time, limit){
  local s = s0 + lane.speed * time + limit
  s = s - math.floor(s / (2 * limit)) * 2 * limit
  return s - limit
}

// the position of a car at a time
func m.position(car, time){
  local lane = car.lane
  local s = along(lane, car.s0, time, lane.limit)
  if(lane.axis == "x"){
    return {x: s, y: lane.y, z: lane.at}
  }
  return {x: lane.at, y: lane.y, z: s}
}

// new(c: City, phys: {jw, by_id}, seed, count?) -> Traffic, with the
// city's level's count of cars and speeds unless told a count
func m.new(c, phys, seed, count){
  local rng = vec.random((seed or 1) * 31 + 7)
  local limit = c.half + c.street / 2
  local t = {lanes: {}, cars: {}, limit: limit, pool: {}, near: {}, wrecks: {}, time: 0, rng: rng}
  local level = c.level
  count = count or level.cars
  // the lanes, each with its speed and direction
  for(let local l in values(c.lanes)){
    local dir = {x: 0, y: 0, z: 0}
    if(l.axis == "x"){
      dir.x = l.dir
    } else {
      dir.z = l.dir
    }
    append(t.lanes, {
      axis: l.axis, at: l.at, y: l.y, dir: l.dir,
      speed: rng:range(level.speed[0], level.speed[1]) * l.dir,
      direction: dir,
      q: vec.quat_yaw(vec.yaw_of(dir)),
      cars: {},
      limit: limit,
    })
  }
  // the cars, spread over the lanes in order along each (so a lane's
  // list is sorted by s0 and the cars never meet)
  local per = count / len(t.lanes)
  for(let local lane in values(t.lanes)){
    local n = to_int(per * rng:range(0.5, 1.5))
    for(local i = 0; i < n; i = i + 1){
      local palette = rng:pick(palettes)
      local car = {
        id: len(t.cars),
        lane: lane,
        s0: -limit + (i + rng:range(0.15, 0.85)) * 2 * limit / n,
        color: palette[0],
        light: palette[1],
        accent: palette[2],
        vel: vec.scale(lane.direction, math.abs(lane.speed)),
        body: null,
        pos: null,
        wrecked: false,
      }
      append(lane.cars, car)
      append(t.cars, car)
    }
  }
  // the pool of bodies, parked under the city
  if(phys != null){
    local shape = jolt.box({m.HALF_WIDTH, m.HALF_HEIGHT, m.HALF_LENGTH}, {density: 120})
    for(local i = 0; i < m.BODIES; i = i + 1){
      local body = phys.jw:create_body({
        shape: shape, position: {0, -60 - i * 3, 0}, motion: "kinematic", friction: 0.2,
        allow_dynamic_or_kinematic: true, gravity_factor: 0,
      })
      local slot = {body: body, car: null}
      phys.by_id[body.id] = {traffic: slot}
      append(t.pool, slot)
    }
  }
  return t
}

// the first index in a lane's cars whose s0 is at least s
local func lower_bound(cars, s){
  local lo = 0
  local hi = len(cars)
  for(lo < hi){
    local mid = to_int((lo + hi) / 2)
    if(cars[mid].s0 < s){
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  return lo
}

// the cars of a lane within radius of the coordinate f along it, now
local func window(lane, f, time, radius, out){
  local limit = lane.limit
  local cars = lane.cars
  local n = len(cars)
  if(n == 0){
    return
  }
  // the window, clipped to the lane (the lane wraps, the city does not:
  // a car about to come round at the far edge is far away)
  local lo = math.max(-limit, f - radius)
  local hi = math.min(limit, f + radius)
  if(hi <= lo){
    return
  }
  // the starts that are now within it, as a range of s0 in -limit..limit
  local shift = lane.speed * time
  local span = 2 * limit
  local a = lo - shift
  a = a - math.floor((a + limit) / span) * span
  local b = a + (hi - lo)
  local func take(from, to){
    local i = lower_bound(cars, from)
    for(i < n and cars[i].s0 <= to){
      if(not cars[i].wrecked){
        append(out, cars[i])
      }
      i = i + 1
    }
  }
  if(b <= limit){
    take(a, b)
  } else {
    take(a, limit)
    take(-limit, b - span)
  }
}

// step(t, dt, time, focus): the cars near the player (focus) get bodies
// and their positions; the rest are only a formula
func m.step(t, dt, time, focus){
  t.time = time
  local near = {}
  for(let local lane in values(t.lanes)){
    local across = 0
    local f = 0
    if(lane.axis == "x"){
      across = lane.at - focus.z
      f = focus.x
    } else {
      across = lane.at - focus.x
      f = focus.z
    }
    local dy = lane.y - focus.y
    if(across * across + dy * dy < m.NEAR * m.NEAR){
      window(lane, f, time, m.NEAR, near)
    }
  }
  // bodies: the cars that left the near set give theirs back
  local keep = {}
  for(let local car in values(near)){
    car.pos = m.position(car, time)
    car.mark = time
  }
  for(let local slot in values(t.pool)){
    if(slot.car != null and not slot.car.wrecked){
      if(slot.car.mark != time){
        slot.car.body = null
        slot.car = null
        slot.body:set_position_rotation_and_velocity({0, -60, 0}, {0, 0, 0, 1}, {0, 0, 0}, {0, 0, 0})
      }
    }
  }
  local free = 0
  for(let local car in values(near)){
    if(car.body == null){
      // a free slot
      for(free < len(t.pool) and t.pool[free].car != null){
        free = free + 1
      }
      if(free < len(t.pool)){
        local slot = t.pool[free]
        slot.car = car
        car.body = slot.body
        slot.body:set_position_rotation_and_velocity(car.pos, car.lane.q, car.vel, {0, 0, 0})
      }
    } else {
      car.body:move_kinematic(car.pos, car.lane.q, dt)
    }
  }
  t.near = near
  // the wrecks tumble on their own; after a while they are taken away
  // and the car is back on its lane, wherever that has carried it
  local kept = {}
  for(let local wr in values(t.wrecks)){
    local car = wr.car
    wr.timer = wr.timer - dt
    wr.pos = car.body.position
    wr.q = car.body.rotation
    if(wr.timer > 0 and wr.pos.y > -5){
      append(kept, wr)
    } else {
      local body = car.body
      body.motion_type = jolt.motion_type_kinematic
      body.gravity_factor = 0
      body:set_position_rotation_and_velocity({0, -60, 0}, {0, 0, 0, 1}, {0, 0, 0}, {0, 0, 0})
      for(let local slot in values(t.pool)){
        if(slot.car == car){
          slot.car = null
        }
      }
      car.body = null
      car.wrecked = false
    }
  }
  t.wrecks = kept
}

// wreck(t, car, n, impact, player_vel): hit from direction n (toward the
// player) at an impact speed: the car's body turns dynamic, is knocked
// away and set spinning
func m.wreck(t, car, n, impact, player_vel){
  if(car.wrecked or car.body == null){
    return false
  }
  car.wrecked = true
  local body = car.body
  body.motion_type = jolt.motion_type_dynamic
  body.gravity_factor = 0.6
  local kick = impact * 0.7 + 8
  local vel = vec.add_scaled(vec.add_scaled(car.vel, player_vel, 0.3), n, -kick)
  vel.y = vel.y + 3
  local rng = t.rng
  local spin = {
    x: rng:range(-1, 1) * (1 + impact * 0.1),
    y: rng:range(-1, 1) * (1 + impact * 0.1),
    z: rng:range(-1, 1) * (2 + impact * 0.15),
  }
  body:set_linear_and_angular_velocity(vel, spin)
  append(t.wrecks, {car: car, timer: m.WRECK_TIME, pos: car.pos, q: car.lane.q})
  return true
}

// the car a body slot holds, if any
func m.car_of(slot){
  return slot.car
}

return m
