// game/car: the flying car, a Jolt rigid body (packages/jolt) that the
// controls push and turn with forces and torques: thrust with a boost,
// drag that lets it drift through turns, pitch, roll and yaw (banking
// turns it a little, like a plane; it levels itself when the stick is let
// go), and the magnet: near a wall, a roof or a bridge the car is pulled
// onto the surface and drives along it as if that were the ground, until
// it drives off the edge or lets go. Jolt resolves the collisions with
// the city and the traffic; the contacts it reports become hits here.
local math = require("slang/math")
local jolt = require("jolt")
local vec = require("game/vec")

local m = {}

m.HALF = {x: 1.1, y: 0.45, z: 2.2} // the body's box
m.MASS = 900
m.CLEARANCE = 1.0 // the center's height over a surface it sticks to
m.STICK_RANGE = 4.5 // how near a surface the magnet reaches
m.JUMP = 25 // m/s off a surface when the jump (magnet) button is pressed
m.GRAB_SPEED = 12 // m/s toward a surface over which the magnet does not grab
m.BELLY = 0.65 // ... unless the car comes at it belly first (its up this
// near the surface's normal): then it grabs at any speed
m.GLIDE = 3.2 // s the car keeps its attitude after leaving a wall at its edge
m.SLOT_THRUST = 1.3 // thrust riding a wall with another one just over the car
m.HEADROOM = 6 // how far over the tallest building the car may climb
m.BOOST_HEADROOM = 18 // ... and while boosting
m.ACCEL = 28 // m/s^2 of thrust
m.TOP_SPEED = 80 // m/s where thrust and drag balance
m.BOOST_FACTOR = 1.9 // thrust with the boost
m.BOOST_DRAIN = 0.32 // of the meter per second
m.BRAKE = 34 // m/s^2
m.PITCH_RATE = 2.3 // rad/s at full stick
m.ROLL_RATE = 3.4
m.YAW_RATE = 1.5
m.STEER_RATE = 2.2 // on a surface
m.DAMAGE_SPEED = 5 // impacts slower than this scratch the paint only
m.DAMAGE_PER_MS = 0.002 // hull lost per m/s of impact above that
m.RADIUS = 2.5 // about, for things that keep a distance

// the body's moments of inertia about its own axes (a box of MASS)
local inertia = {
  x: m.MASS * (m.HALF.y * m.HALF.y + m.HALF.z * m.HALF.z) / 3,
  y: m.MASS * (m.HALF.x * m.HALF.x + m.HALF.z * m.HALF.z) / 3,
  z: m.MASS * (m.HALF.x * m.HALF.x + m.HALF.y * m.HALF.y) / 3,
}

// new(phys: {jw, by_id}, pos, yaw) -> Car, its body in the world
func m.new(phys, pos, yaw){
  local q = vec.quat_yaw(yaw or 0)
  local body = phys.jw:create_body({
    shape: jolt.box({m.HALF.x, m.HALF.y, m.HALF.z}, {convex_radius: 0.05}),
    position: {pos.x, pos.y, pos.z},
    rotation: q,
    motion: "dynamic",
    mass: m.MASS,
    friction: 0.3,
    restitution: 0.1,
    linear_damping: 0,
    angular_damping: 0.6,
    gravity_factor: 0,
    motion_quality: jolt.motion_quality_linear_cast,
  })
  local car = {
    body: body,
    pos: {x: pos.x, y: pos.y, z: pos.z},
    vel: {x: 0, y: 0, z: 0},
    q: q,
    omega: {x: 0, y: 0, z: 0}, // angular velocity, world frame
    mode: "fly", // or "stick"
    magnet: true, // on: it grabs surfaces near it (the jump lets go)
    stick: null, // {box, normal} while stuck
    cooldown: 0, // before the magnet grabs again
    boost: 1,
    boosting: false,
    hull: 1,
    speed: 0,
    thrust: 0, // 0..1, for the visuals and sound
    brake: 0,
    nearest: 1e9, // distance to the nearest surface
    skimming: false,
    in_slot: false, // riding a wall with another one just over it
    glide: 0, // s left holding glide_q, after leaving a wall at its edge
    glide_q: null,
    events: {},
    time: 0,
  }
  phys.by_id[body.id] = {car: car}
  return car
}

local func event(car, kind, extra){
  local e = {kind: kind}
  if(extra != null){
    for(let local en in entries(extra)){
      e[en[0]] = en[1]
    }
  }
  append(car.events, e)
}

// ------------------------------------------------------------ faces

// the face of box b that p is outside of, if it is outside exactly one:
// {normal, dist} or null (edges and corners do not hold a car)
local func face_toward(b, p){
  local out = 0
  local n = null
  local d = 0
  if(p.x > b.x1){
    out = out + 1
    n = {x: 1, y: 0, z: 0}
    d = p.x - b.x1
  }
  if(p.x < b.x0){
    out = out + 1
    n = {x: -1, y: 0, z: 0}
    d = b.x0 - p.x
  }
  if(p.y > b.y1){
    out = out + 1
    n = {x: 0, y: 1, z: 0}
    d = p.y - b.y1
  }
  if(p.y < b.y0){
    out = out + 1
    n = {x: 0, y: -1, z: 0}
    d = b.y0 - p.y
  }
  if(p.z > b.z1){
    out = out + 1
    n = {x: 0, y: 0, z: 1}
    d = p.z - b.z1
  }
  if(p.z < b.z0){
    out = out + 1
    n = {x: 0, y: 0, z: -1}
    d = b.z0 - p.z
  }
  if(out != 1){
    return null
  }
  return {normal: n, dist: d}
}

// whether p's projection along the face normal lies on the face (with a
// margin outward, so the car hangs over an edge a little before it falls)
local func on_face(b, n, p, margin){
  if(n.x != 0){
    return p.y >= b.y0 - margin and p.y <= b.y1 + margin and
      p.z >= b.z0 - margin and p.z <= b.z1 + margin
  }
  if(n.y != 0){
    return p.x >= b.x0 - margin and p.x <= b.x1 + margin and
      p.z >= b.z0 - margin and p.z <= b.z1 + margin
  }
  return p.x >= b.x0 - margin and p.x <= b.x1 + margin and
    p.y >= b.y0 - margin and p.y <= b.y1 + margin
}

// the distance from p to the plane of face n of box b
local func face_distance(b, n, p){
  if(n.x > 0){ return p.x - b.x1 }
  if(n.x < 0){ return b.x0 - p.x }
  if(n.y > 0){ return p.y - b.y1 }
  if(n.y < 0){ return b.y0 - p.y }
  if(n.z > 0){ return p.z - b.z1 }
  return b.z0 - p.z
}

// ------------------------------------------------------------ the magnet

// the rays the car feels around with: directions and where each starts,
// just outside its own body (a ray from the center would hit itself)
local func feelers(car){
  local axes = vec.axes(car.q)
  return {
    {dir: vec.scale(axes.up, -1), from: m.HALF.y + 0.1},
    {dir: axes.up, from: m.HALF.y + 0.1},
    {dir: axes.right, from: m.HALF.x + 0.1},
    {dir: vec.scale(axes.right, -1), from: m.HALF.x + 0.1},
    {dir: axes.forward, from: m.HALF.z + 0.1},
    {dir: vec.scale(axes.forward, -1), from: m.HALF.z + 0.1},
  }
}

// the surface the magnet would grab: rays from the car in six directions
// find the nearest box face it floats over within range
local func find_surface(car, phys){
  local best = null
  local bd = m.STICK_RANGE
  // gliding off a wall, only a surface under the car (the next slot's
  // wall, not the one across from it)
  local up = vec.axes(car.q).up
  for(let local f in values(feelers(car))){
    local hit = phys.jw:cast_ray(
      vec.add_scaled(car.pos, f.dir, f.from),
      vec.scale(f.dir, m.STICK_RANGE + 1),
    )
    if(hit != null){
      local what = phys.by_id[hit.body.id]
      // (a slot line's funnel walls do not hold: game/city)
      if(what != null and what.box != null and not what.box.slick){
        local f = face_toward(what.box, car.pos)
        // a surface met head-on at speed is a crash, not a landing: the
        // magnet takes only a glancing or gentle approach
        local closing = 0
        local belly = false
        if(f != null){
          closing = -vec.dot(car.vel, f.normal)
          belly = vec.dot(f.normal, up) > m.BELLY
        }
        local under = car.glide <= 0 or
          (f != null and vec.dot(f.normal, up) > 0.7)
        if(f != null and f.dist < bd and (closing < m.GRAB_SPEED or belly) and
          under){
          bd = f.dist
          best = {box: what.box, normal: f.normal, dist: f.dist}
        }
      }
    }
  }
  return best
}

// attach(car, surface): stuck to it. Coming at it fast (belly first), the
// magnet takes the speed into it at once: a slam, not a crash
local func attach(car, surface){
  car.mode = "stick"
  car.stick = surface
  car.glide = 0
  local n = surface.normal
  local into = -vec.dot(car.vel, n)
  local slam = 0
  if(into > m.GRAB_SPEED){
    slam = into
    car.vel = vec.add_scaled(car.vel, n, into)
    car.body.linear_velocity = car.vel
  }
  event(car, "attach", {normal: n, slam: slam, pos: car.pos})
}

local func detach(car, why, hop){
  if(car.mode != "stick"){
    return
  }
  local n = car.stick.normal
  car.left_box = car.stick.box
  car.mode = "fly"
  car.stick = null
  car.cooldown = 0.5
  // off the end of a wall: the car flies on as it was, on its side, so
  // it can cross a street into the next slot of a line (the magnet
  // ready again soon)
  if(why == "edge" and n.y == 0){
    car.glide = m.GLIDE
    car.glide_q = car.q
    car.cooldown = 0.25
  }
  if(hop != null and hop > 0){
    car.body:add_impulse(vec.scale(n, hop * m.MASS))
  }
  event(car, "detach", {why: why})
}

// ------------------------------------------------------------ control

// the torque that brings the body's rates to the target rates (body
// frame), as the first-order approach at rate k
local func rate_torque(car, target, k){
  local wb = vec.unrotate(car.q, car.omega)
  local tb = {
    x: (target.x - wb.x) * k * inertia.x,
    y: (target.y - wb.y) * k * inertia.y,
    z: (target.z - wb.z) * k * inertia.z,
  }
  return vec.rotate(car.q, tb)
}

// the body rates that turn the car to an orientation at rate k
local func rates_toward(car, target_q, k){
  local d = vec.quat_multiply(target_q, vec.quat_conjugate(car.q))
  if(d.w < 0){
    d = {x: -d.x, y: -d.y, z: -d.z, w: -d.w}
  }
  local s = math.sqrt(math.max(0, 1 - d.w * d.w))
  if(s < 0.0001){
    return {x: 0, y: 0, z: 0}
  }
  local angle = 2 * math.acos(math.min(1, d.w))
  local axis = {x: d.x / s, y: d.y / s, z: d.z / s}
  return vec.unrotate(car.q, vec.scale(axis, angle * k))
}

// control(car, phys, input, dt): the forces for the coming step. input =
// {pitch (+ nose down), roll (+ right), yaw (+ right), throttle 0..1,
// brake 0..1, boost: bool, magnet: bool (pressed this frame)}
func m.control(car, phys, input, dt){
  car.events = {}
  car.time = car.time + dt
  car.cooldown = math.max(0, car.cooldown - dt)
  // the magnet is always on; its button jumps off the surface it holds
  // (along the surface and up a little), and in the air keeps it from
  // grabbing for a moment, to pass close by a wall
  if(input.magnet){
    // (held off after a jump, a belly-first landing on another box still
    // takes; pressed in the air, the magnet holds off altogether)
    car.jumped = false
    if(car.mode == "stick"){
      local n = car.stick.normal
      detach(car, "jump", 0)
      local dir = vec.normalize(vec.add(n, {x: 0, y: 0.6, z: 0}))
      car.body:add_impulse(vec.scale(dir, m.JUMP * m.MASS))
      event(car, "jump")
      car.jumped = true
    }
    car.cooldown = 0.8
  }
  local axes = vec.axes(car.q)
  local speed = car.speed
  local body = car.body

  // ---- boost
  car.boosting = false
  local thrust_scale = 1
  if(input.boost and car.boost > 0 and input.throttle > 0){
    car.boosting = true
    thrust_scale = m.BOOST_FACTOR
    car.boost = math.max(0, car.boost - m.BOOST_DRAIN * dt)
  }
  if(car.in_slot){
    thrust_scale = thrust_scale * m.SLOT_THRUST
  }

  // ---- the magnet grabbing, holding, letting go at an edge
  if(car.mode == "stick"){
    local s = car.stick
    if(not on_face(s.box, s.normal, car.pos, 0.8)){
      detach(car, "edge", 0)
    }
  } else if(car.magnet and car.cooldown <= 0){
    local s = find_surface(car, phys)
    if(s != null){
      attach(car, s)
    }
  }

  // ---- turning
  local torque = null
  if(car.mode == "fly" and car.glide > 0){
    // gliding: the attitude it left the wall with, until the time is up
    // or the stick is pushed well over
    car.glide = car.glide - dt
    local pushed = math.max(
      math.max(math.abs(input.pitch), math.abs(input.roll)),
      math.abs(input.yaw),
    )
    if(pushed > 0.35){
      car.glide = 0
    }
    torque = rate_torque(car, rates_toward(car, car.glide_q, 6), 7)
  } else if(car.mode == "fly"){
    // (the body's +x is its left side: looking along +z with y up, x
    // points left, so a turn to the right is a negative yaw rate and a
    // bank to the right a positive roll rate)
    local target = {
      x: input.pitch * m.PITCH_RATE,
      y: -input.yaw * m.YAW_RATE,
      z: input.roll * m.ROLL_RATE,
    }
    // banking turns the car, as it does a plane
    target.y = target.y - axes.right.y * 1.1
    // let go, and it levels itself (the roll faster than the pitch): the
    // turn that brings its up to the world's up, in its own frame
    local e = vec.unrotate(car.q, vec.cross(axes.up, {x: 0, y: 1, z: 0}))
    if(math.abs(input.roll) < 0.05){
      target.z = target.z + e.z * 2.2
      if(axes.up.y < -0.3){
        target.z = target.z + 1.5
      }
    }
    if(math.abs(input.pitch) < 0.05){
      target.x = target.x + e.x * 0.8
    }
    torque = rate_torque(car, target, 7)
  } else {
    // on a surface: steering turns about its normal; the car settles
    // flat onto it
    local n = car.stick.normal
    local steer = vec.clamp(input.yaw + input.roll, -1, 1)
    local rate = m.STEER_RATE * (0.5 + 0.5 * math.min(1, speed / 25))
    local fwd = vec.reject(axes.forward, n)
    if(vec.length(fwd) < 0.05){
      fwd = vec.reject(axes.up, n)
    }
    // in a slot, with the stick let go, the heading settles level along
    // it: a rail
    if(car.in_slot and math.abs(steer) < 0.1 and math.abs(fwd.y) < 0.8){
      fwd = {x: fwd.x, y: 0, z: fwd.z}
    }
    fwd = vec.normalize(fwd)
    // a slot's wall (game/city) takes the car flat faster: the gap is
    // short
    local settle = 9
    if(car.stick.box.slot){
      settle = 18
    }
    local target = rates_toward(car, vec.quat_look(fwd, n), settle)
    target.y = target.y - steer * rate
    torque = rate_torque(car, target, settle)
  }
  body:add_torque(torque)

  // ---- thrust, brakes, drag
  local accel = vec.scale(axes.forward, input.throttle * m.ACCEL * thrust_scale)
  car.thrust = input.throttle * thrust_scale / m.BOOST_FACTOR
  car.brake = input.brake
  if(input.brake > 0 and speed > 0.5){
    local b = math.min(speed / dt, m.BRAKE * input.brake)
    accel = vec.add_scaled(accel, vec.normalize(car.vel), -b)
  }
  // the brake at a standstill backs the car up
  if(input.brake > 0 and vec.dot(car.vel, axes.forward) < 3){
    accel = vec.add_scaled(accel, axes.forward, -m.ACCEL * 0.45 * input.brake)
  }
  // drag in the body's frame: forward a little (it sets the top speed),
  // sideways and up a lot (grip), less of it the faster it goes (drift)
  local vb = vec.unrotate(car.q, car.vel)
  local k_forward = m.ACCEL / (m.TOP_SPEED * m.TOP_SPEED)
  local grip = 4.5 * vec.clamp(1 - speed / 160, 0.45, 1)
  if(car.mode == "stick"){
    grip = 7 * vec.clamp(1 - speed / 180, 0.5, 1)
  }
  local drag = {
    x: -vb.x * grip,
    y: -vb.y * grip * 0.8,
    z: -vb.z * math.abs(vb.z) * k_forward - vb.z * 0.12,
  }
  accel = vec.add(accel, vec.rotate(car.q, drag))
  // ---- held to a surface: a spring to its clearance
  if(car.mode == "stick"){
    local n = car.stick.normal
    local d = face_distance(car.stick.box, n, car.pos)
    local vn = vec.dot(car.vel, n)
    if(car.stick.box.slot){
      accel = vec.add_scaled(accel, n, (m.CLEARANCE - d) * 260 - vn * 27)
    } else {
      accel = vec.add_scaled(accel, n, (m.CLEARANCE - d) * 80 - vn * 14)
    }
  }
  // ---- the city limits: a soft wall, and a ceiling
  local limit = phys.limit
  local pushed = false
  if(math.abs(car.pos.x) > limit){
    accel.x = accel.x - math.sign(car.pos.x) * 40
    pushed = true
  }
  if(math.abs(car.pos.z) > limit){
    accel.z = accel.z - math.sign(car.pos.z) * 40
    pushed = true
  }
  // the ceiling: over the tallest building (more of it while boosting)
  // the car is pulled down, harder the higher it is, and its climb fades
  local ceiling = (phys.ceiling or 360) + m.HEADROOM
  if(car.boosting){
    ceiling = ceiling + m.BOOST_HEADROOM - m.HEADROOM
  }
  local over = car.pos.y - ceiling
  if(over > 0){
    accel.y = accel.y - 25 - over * 5
    if(car.vel.y > 0){
      accel.y = accel.y - car.vel.y * 3
    }
    pushed = true
  }
  if(pushed){
    event(car, "limits")
  }
  body:add_force(vec.scale(accel, m.MASS))
}

// ------------------------------------------------------------ after the step

// read(car, phys, contacts): the body's state, and what it hit
func m.read(car, phys, contacts){
  local body = car.body
  car.pos = body.position
  car.q = body.rotation
  car.vel = body.linear_velocity
  car.omega = body.angular_velocity
  car.speed = vec.length(car.vel)
  local axes = vec.axes(car.q)
  // the contacts: how hard, along the normal, with what
  for(let local c in values(contacts)){
    local other = null
    local n = null
    local rel = null
    if(c.body1 == body){
      other = phys.by_id[c.body2.id]
      n = c.normal
      rel = vec.sub(c.velocity1, c.velocity2)
    } else if(c.body2 == body){
      other = phys.by_id[c.body1.id]
      n = vec.scale(c.normal, -1)
      rel = vec.sub(c.velocity2, c.velocity1)
    } else {
      continue
    }
    // the surface the car sticks to touching is not a hit
    if(car.stick != null and other != null and other.box == car.stick.box){
      continue
    }
    local impact = math.abs(vec.dot(rel, n))
    // into a box belly first: it lands, however fast (even while the
    // magnet is held off after a jump, unless it is the box just left)
    if(other != null and other.box != null and not other.box.slick and car.mode != "stick" and
      car.magnet and (car.cooldown <= 0 or (car.jumped and other.box != car.left_box)) and
      vec.dot(axes.up, n) < -m.BELLY){
      local f = face_toward(other.box, car.pos)
      if(f != null){
        attach(car, {box: other.box, normal: f.normal, dist: f.dist})
        continue
      }
    }
    local at = c.points[0] or car.pos
    if(impact > m.DAMAGE_SPEED){
      car.hull = math.max(
        0,
        car.hull - (impact - m.DAMAGE_SPEED) * m.DAMAGE_PER_MS,
      )
      car.boost = car.boost * 0.4
      event(car, "hit", {
        impact: impact,
        normal: n,
        pos: at,
        box: other and other.box,
        car: other and other.car,
        traffic: other != null and other.traffic != null,
      })
      if(car.mode == "stick" and impact > 12){
        detach(car, "knocked", 0)
      }
    } else if(impact > 0.8){
      event(car, "scrape", {impact: impact, normal: n, pos: at})
    }
  }
  // the nearest surface: for skimming, from the rays (not forward: a
  // wall ahead is a crash, not a skim)
  local nearest = 1e9
  local over = 1e9
  local fs = feelers(car)
  for(local i = 0; i < 4; i = i + 1){
    local f = fs[i]
    local hit = phys.jw:cast_ray(
      vec.add_scaled(car.pos, f.dir, f.from),
      vec.scale(f.dir, 6),
    )
    if(hit != null){
      nearest = math.min(nearest, hit.fraction * 6)
      if(i == 1){
        over = hit.fraction * 6
      }
    }
  }
  car.nearest = nearest
  // in a slot: on a wall, the other wall just over the roof
  car.in_slot = car.mode == "stick" and car.stick.normal.y == 0 and over < 1.2
  // the boost meter refills: slowly by itself, fast when skimming a
  // surface at speed or riding one
  car.skimming = false
  local regen = 0.045
  if(car.mode == "stick"){
    if(car.speed > 20){
      regen = regen + 0.14
      car.skimming = true
    }
  } else if(nearest < 3.5 and car.speed > 28){
    regen = regen + 0.3
    car.skimming = true
  }
  car.boost = math.min(1, car.boost + regen * (1 / 60))
}

// place(car, pos, yaw): set down somewhere, at rest, flying
func m.place(car, pos, yaw){
  car.pos = {x: pos.x, y: pos.y, z: pos.z}
  car.vel = {x: 0, y: 0, z: 0}
  car.q = vec.quat_yaw(yaw or 0)
  car.omega = {x: 0, y: 0, z: 0}
  car.mode = "fly"
  car.stick = null
  car.cooldown = 0.5
  car.glide = 0
  car.body:set_position_rotation_and_velocity(
    car.pos, car.q, car.vel, car.omega
  )
}

func m.axes(car){
  return vec.axes(car.q)
}

return m
