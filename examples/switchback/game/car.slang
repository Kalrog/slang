// game/car: the truck as the physics has it. A Jolt body on four wheels:
// Jolt finds the ground under each wheel (a cylinder cast along the
// suspension), carries the truck on springs that are part of its solver
// (so they neither blow up nor ring), and holds each tire to the ground
// as a contact that may not slip until it is asked for more than the
// tire has. What the tires have comes from game/tires and the ground
// (game/surfaces), what turns the wheels from game/drivetrain; this
// module passes the numbers between them and Jolt once a step, and
// turns the driver's keys into pedals, steering and brakes.
//
//   local car = car_lib.new(world, {x: 0, y: 1, z: 0}, 0)
//   car:step(input, dt)      // then world.jw:step(dt)
//   car:read()               // where it is now
//
// The frame of the truck: x to its left, y up, z forward; its origin is
// between the axles at the height of the wheel centers when it stands.
local math = require("slang/math")
local jolt = require("jolt")
local vec = require("game/vec")
local drivetrain = require("game/drivetrain")
local tires = require("game/tires")
local surfaces = require("game/surfaces")

local m = {}

// ------------------------------------------------------------ the truck

m.MASS = drivetrain.SPEC.mass
m.WHEEL_RADIUS = drivetrain.SPEC.wheel_radius
m.WHEEL_WIDTH = 0.29
m.HALF_WHEELBASE = 1.36
m.HALF_TRACK = 0.8
// the suspension: its length is how far the wheel's center hangs under
// where the spring is fixed to the body. The wheel can come up to MIN (the
// bump stop) and drop to its axle's MAX; standing still the truck rides
// at REST (the springs and the MAX of each axle are chosen for that), so
// the wheels' centers are at the height of the truck's origin.
m.SUSPENSION_MIN = 0.07
m.SUSPENSION_REST = 0.23
m.SUSPENSION_MAX = {front: 0.362, rear: 0.331}
// the springs as how fast a corner would bounce on them, Hz, and how
// much of the bounce the dampers take (1: all of it)
local SPRING = {front: 1.25, rear: 1.35}
local DAMPING = {front: 0.86, rear: 0.9}
// the anti-roll bars: what one adds to a wheel's spring when the other
// wheel of its axle is a meter longer, N/m (see bar_stiffness)
local ANTI_ROLL = {front: 14000, rear: 5000}
// the center of mass: low and a little forward
m.CENTER_OF_MASS = {x: 0, y: 0.25, z: 0.07}
// where the wheels are: front left, front right, rear left, rear right
m.WHEELS = {
  {x: m.HALF_TRACK, z: m.HALF_WHEELBASE, front: true, left: true},
  {x: -m.HALF_TRACK, z: m.HALF_WHEELBASE, front: true, left: false},
  {x: m.HALF_TRACK, z: -m.HALF_WHEELBASE, front: false, left: true},
  {x: -m.HALF_TRACK, z: -m.HALF_WHEELBASE, front: false, left: false},
}
// the brakes, N m at a wheel with the pedal down
local BRAKE = {front: 3400, rear: 2100}
local HAND_BRAKE = 4200
local HOLD_BRAKE = 4500
// steering: the most the front wheels turn, how fast, and the speed at
// which the driver uses half of it
local STEER_MAX = 0.62
local STEER_RATE = 2.4
local STEER_HALF_SPEED = 13
// air: half the density times drag area, N per (m/s)^2
local AIR_DRAG = 0.72
// what every body of the world has as friction: Jolt mixes it with the
// tire's (the root of their product), and the tire's is set so that the
// mix is what game/tires says
m.WORLD_FRICTION = 0.8

// the hull as convex pieces in the truck's frame: the frame and floor
// between the wheels (with the bumpers' undersides cut for the approach
// and departure angles), the body over the wheels, the cabin
local func hull_points(){
  local frame = {}
  for(let local x in values({-0.6, 0.6})){
    append(frame, {x, -0.1, 1.72})
    append(frame, {x, -0.1, -1.62})
    append(frame, {x, 0.16, 2.2})
    append(frame, {x, 0.2, -2.16})
    append(frame, {x, 0.52, 2.22})
    append(frame, {x, 0.52, -2.18})
  }
  local body = {}
  for(let local x in values({-0.92, 0.92})){
    append(body, {x, 0.5, 2.24})
    append(body, {x, 0.5, -2.2})
    append(body, {x, 0.98, 2.2})
    append(body, {x, 0.98, -2.2})
  }
  local cabin = {}
  for(let local x in values({-0.82, 0.82})){
    append(cabin, {x, 0.98, 0.95})
    append(cabin, {x, 0.98, -2.16})
    append(cabin, {x, 1.5, 0.52})
    append(cabin, {x, 1.5, -2.1})
  }
  return {frame, body, cabin}
}

// Jolt adds a bar's push to the spring's constraint as a bias, where the
// solver multiplies it with the constraint's own mass (the corner's mass
// beside the spring's softness, about 50 kg at 120 steps a second): the
// stiffness it is given is the bar's rate in N/m over that mass. Taken as
// N/m the bar would be some fifty times too stiff, and a wheel on a bump
// would throw the truck over.
local func bar_stiffness(rate, end, dt){
  local corner = m.MASS / 4
  local omega = 2 * math.pi * SPRING[end]
  local stiffness = corner * omega * omega
  local damping = 2 * corner * DAMPING[end] * omega
  local softness = 1 / (dt * (damping + dt * stiffness))
  return rate * (1 / corner + softness)
}

// ------------------------------------------------------------ making one

local Car = {}
local meta = {__index: Car, __type: "Car"}

// new(world: {jw: jolt.World, surface_at?: func(x: float, z: float,
//   y: float): Surface, step_time?: float}, position: Vec3,
//   yaw?: float) -> Car
// A truck standing at position (where its origin goes), turned by yaw.
// The world's surface_at says what the ground is at a point (rock when
// it is left out), its step_time how long a step of the physics is
// (1/120 s when it is left out).
func m.new(world, position, yaw){
  local jw = world.jw
  local step_time = world.step_time or 1 / 120
  local parts = {}
  for(let local points in values(hull_points())){
    append(parts, {shape: jolt.convex_hull(points, {max_convex_radius: 0.03})})
  }
  local shape = jolt.compound(parts)
  // the center of mass where it should be, not where the hull's is
  local com = shape.center_of_mass
  shape = jolt.offset_center_of_mass(shape, {
    m.CENTER_OF_MASS.x - com.x, m.CENTER_OF_MASS.y - com.y, m.CENTER_OF_MASS.z - com.z
  })
  // (a quaternion in place of the yaw stands it on a slope)
  local q = if(type(yaw) == "table"){ yaw } else { vec.quat_yaw(yaw or 0) }
  local body = jw:create_body({
    shape: shape,
    position: {position.x, position.y, position.z},
    rotation: q,
    motion: "dynamic",
    mass: m.MASS,
    friction: 0.45,
    restitution: 0.02,
    linear_damping: 0,
    angular_damping: 0.12,
    allow_sleeping: false,
    motion_quality: jolt.motion_quality_linear_cast,
  })
  local wheel_defs = {}
  for(let local w in values(m.WHEELS)){
    local end = if(w.front){ "front" } else { "rear" }
    append(wheel_defs, {
      position: {w.x, m.SUSPENSION_REST, w.z},
      suspension_direction: {0, -1, 0},
      steering_axis: {0, 1, 0},
      wheel_up: {0, 1, 0},
      wheel_forward: {0, 0, 1},
      radius: m.WHEEL_RADIUS,
      width: m.WHEEL_WIDTH,
      suspension_min_length: m.SUSPENSION_MIN,
      suspension_max_length: m.SUSPENSION_MAX[end],
      suspension_spring: {
        mode: jolt.spring_mode_frequency_and_damping,
        frequency_or_stiffness: SPRING[end],
        damping: DAMPING[end],
      },
      inertia: drivetrain.SPEC.wheel_inertia,
      angular_damping: 0,
      max_steer_angle: 0,
      max_brake_torque: 0,
      max_hand_brake_torque: 0,
      longitudinal_friction: {{0, 1}},
      lateral_friction: {{0, 1}},
    })
  }
  local vehicle = jw:create_vehicle({
    body: body,
    wheels: wheel_defs,
    // no engine of Jolt's: game/drivetrain turns the wheels
    differentials: {},
    transmission: {mode: jolt.transmission_mode_manual},
    anti_roll_bars: {
      {left_wheel: 0, right_wheel: 1, stiffness: bar_stiffness(ANTI_ROLL.front, "front", step_time)},
      {left_wheel: 2, right_wheel: 3, stiffness: bar_stiffness(ANTI_ROLL.rear, "rear", step_time)},
    },
    collision_tester: {type: "cast_cylinder", convex_radius_fraction: 0.25},
  })
  // the wheels steer by their own most angle (see steer), and brake by
  // their own most torque with the pedal always down (see step)
  vehicle.controller.right_input = -1
  vehicle.controller.brake_input = 1
  local wheels = {}
  for(local i = 0; i < 4; i = i + 1){
    local jwheel = vehicle.wheels[i]
    local settings = jwheel.settings
    append(wheels, {
      index: i,
      at: m.WHEELS[i],
      jolt: jwheel,
      settings: settings,
      along_curve: settings.longitudinal_friction,
      across_curve: settings.lateral_friction,
      // as read after each step
      omega: 0,
      angle: 0,
      steer: 0,
      length: m.SUSPENSION_REST,
      contact: false,
      point: {x: 0, y: 0, z: 0},
      normal: {x: 0, y: 1, z: 0},
      load: 0,
      drive_force: 0,
      side_force: 0,
      along_speed: 0,
      across_speed: 0,
      slip_ratio: 0,
      side_slip: 0,
      surface: surfaces.rock,
      hold: drivetrain.AIR,
      ground: 0,
      // as set before each step
      grip_along: 1,
      grip_across: 1,
      brake: 0,
      resist: 0,
      torque: 0,
    })
  }
  local c = {
    world: world,
    body: body,
    vehicle: vehicle,
    wheels: wheels,
    drive: drivetrain.new(),
    // the pedals and the wheel as they are after the driver's keys
    throttle: 0,
    brake: 0,
    hand_brake: 0,
    dead: false,       // broken down: no pedal does anything (game/run sets it)
    steer: 0,          // -1 (left) to 1 (right) of what the speed allows
    steer_angle: 0,    // the angle of the turn, rad (left positive)
    direction: 1,      // 1 forward, -1 reverse
    holding: false,    // the brakes hold it by themselves at a stop
    still: 0,          // how hard they hold, 0 to 1 (they come on over a moment)
    anchored: null,    // how far it has moved from where it stopped (see anchor)
    winched: false,    // the winch is pulling it (game/winch): no holding by the brakes
    last_dt: 1 / 120,
    // where it is (read)
    pos: {x: position.x, y: position.y, z: position.z},
    q: q,
    velocity: {x: 0, y: 0, z: 0},
    spin: {x: 0, y: 0, z: 0},
    forward: {x: 0, y: 0, z: 1},
    up: {x: 0, y: 1, z: 0},
    left: {x: 1, y: 0, z: 0},
    speed: 0,          // along its forward, m/s
    accel: 0,          // how that changes, m/s^2 (smoothed)
    last_speed: 0,
    @meta: meta,
  }
  c:read()
  return c
}

// read(c): where the truck and its wheels are, after a step
func Car.read(c){
  local body = c.body
  c.pos = body.position
  c.q = body.rotation
  c.velocity = body.linear_velocity
  c.spin = body.angular_velocity
  local q = c.q
  c.forward = vec.rotate(q, {x: 0, y: 0, z: 1})
  c.up = vec.rotate(q, {x: 0, y: 1, z: 0})
  c.left = vec.rotate(q, {x: 1, y: 0, z: 0})
  c.speed = vec.dot(c.velocity, c.forward)
  local com = body.center_of_mass_position
  local dt = c.last_dt
  for(local i = 0; i < 4; i = i + 1){
    local w = c.wheels[i]
    local jw = w.jolt
    w.omega = jw.angular_velocity
    w.angle = jw.rotation_angle
    w.steer = jw.steer_angle
    w.length = jw.suspension_length
    w.contact = jw.contact
    if(w.contact){
      local p = jw.contact_position
      local along = jw.contact_longitudinal
      local across = jw.contact_lateral
      w.point = p
      w.normal = jw.contact_normal
      w.along = along
      w.across = across
      local push = jw.suspension_lambda
      local drive = jw.longitudinal_lambda
      w.load = push / dt
      w.drive_force = drive / dt
      w.side_force = jw.lateral_lambda / dt
      // how fast the truck passes over the ground at the contact
      local rx = p.x - com.x
      local ry = p.y - com.y
      local rz = p.z - com.z
      local s = c.spin
      local vx = c.velocity.x + s.y * rz - s.z * ry
      local vy = c.velocity.y + s.z * rx - s.x * rz
      local vz = c.velocity.z + s.x * ry - s.y * rx
      w.along_speed = vx * along.x + vy * along.y + vz * along.z
      w.across_speed = vx * across.x + vy * across.y + vz * across.z
      local slips = tires.slips(w.along_speed, w.across_speed, w.omega * m.WHEEL_RADIUS)
      w.slip_ratio = slips.ratio
      w.side_slip = slips.side
      // what holds the wheel: a brake, the ground, or the ground sliding
      local limit = w.grip_along * push
      if(w.omega == 0 and w.brake > 0 and math.abs(w.along_speed) < 0.6){
        w.hold = drivetrain.FIXED
      } else if(math.abs(drive) >= limit * 0.97 or math.abs(w.omega * m.WHEEL_RADIUS - w.along_speed) > 0.6){
        w.hold = drivetrain.SLIP
        w.ground = -drive / dt * m.WHEEL_RADIUS
      } else {
        w.hold = drivetrain.GRIP
      }
    } else {
      w.load = 0
      w.drive_force = 0
      w.side_force = 0
      w.along_speed = 0
      w.across_speed = 0
      w.slip_ratio = 0
      w.side_slip = 0
      w.hold = drivetrain.AIR
    }
  }
}

// What the driver does.
// type Input = {forward?: float, back?: float, steer?: float,
//   hand_brake?: bool, low?: bool, lock_front?: bool, lock_rear?: bool}
// [forward]: the key (or trigger) that means go, 0 to 1
// [back]: the one that means stop, and then go backward
// [steer]: -1 left to 1 right

// the angles of the two front wheels for a turn of angle (left positive):
// the inner wheel turns more, so both roll around one center
local func ackermann(angle){
  if(math.abs(angle) < 0.0005){
    return {angle, angle}
  }
  local l = m.HALF_WHEELBASE * 2
  local t = math.tan(angle)
  local left = math.atan(l * t / (l - m.HALF_TRACK * t))
  local right = math.atan(l * t / (l + m.HALF_TRACK * t))
  return {left, right}
}

// step(c, input: Input, dt): what the truck does in the next step of the
// physics: call it, then step the world, then [read]
func Car.step(c, input, dt){
  local d = c.drive
  local forward = vec.clamp(input.forward or 0, 0, 1)
  local back = vec.clamp(input.back or 0, 0, 1)
  // (broken down: the engine gives nothing, and it rolls to a stop)
  if(c.dead){
    forward = 0
    back = 0
  }
  local speed = c.speed

  // ---- the keys as pedals: back brakes while it rolls forward and
  // reverses once it stands (and the other way round)
  local throttle = 0
  local brake = 0
  if(c.direction > 0){
    throttle = forward
    brake = back
    if(back > 0.05 and forward < 0.05 and speed < 0.4){
      c.direction = -1
    }
  } else {
    throttle = back
    brake = forward
    if(forward > 0.05 and back < 0.05 and speed > -0.4){
      c.direction = 1
    }
  }
  c.throttle = throttle
  c.brake = brake
  c.hand_brake = if(input.hand_brake){ 1 } else { 0 }

  // ---- standing: with no throttle the brakes hold the truck once it is
  // down to a crawl, and let go when the driver wants to move
  local limit = if(c.holding){ 0.7 } else { 0.3 }
  // (not while the winch pulls: the wheels must roll)
  c.holding = throttle < 0.02 and math.abs(speed) < limit and not c.winched
  if(c.holding){
    c.still = math.min(1, c.still + dt * 5)
  } else {
    // let go as the clutch takes up the load, so a start on a hill does
    // not roll back
    c.still = math.max(0, c.still - dt * (1.2 + 9 * d.clutch))
  }
  c:anchor(dt)

  // ---- steering: toward what the driver asks, less of it at speed
  local want = vec.clamp(input.steer or 0, -1, 1)
  local most = STEER_MAX / (1 + (speed / STEER_HALF_SPEED) * (speed / STEER_HALF_SPEED))
  local target = -want * most
  local step = STEER_RATE * dt
  if(math.abs(target) < math.abs(c.steer_angle)){
    // back to the middle faster than out of it
    step = step * 1.6
  }
  c.steer_angle = c.steer_angle + vec.clamp(target - c.steer_angle, -step, step)
  c.steer = want
  local angles = ackermann(c.steer_angle)
  c.wheels[0].settings.max_steer_angle = angles[0]
  c.wheels[1].settings.max_steer_angle = angles[1]

  // ---- the tires: what each has, on the ground it stands on
  local share = m.MASS * 9.81 / 4
  local states = {}
  for(local i = 0; i < 4; i = i + 1){
    local w = c.wheels[i]
    local resist = 0
    if(w.contact){
      local surface = surfaces.rock
      if(c.world.surface_at != null){
        surface = c.world.surface_at(w.point.x, w.point.z, w.point.y)
      }
      w.surface = surface
      local grip = tires.grip(surface, w.slip_ratio, w.side_slip, w.load / share)
      w.grip_along = grip.along
      w.grip_across = grip.across
      resist = surface.rolling * w.load * m.WHEEL_RADIUS
      if(surface.drag > 0){
        // wading: the ground (or the water) drags at the wheel
        local v = math.sqrt(w.along_speed * w.along_speed + w.across_speed * w.across_speed)
        if(v > 0.05){
          local f = -surface.drag * v
          c.body:add_force2({
            (w.along.x * w.along_speed + w.across.x * w.across_speed) * f,
            (w.along.y * w.along_speed + w.across.y * w.across_speed) * f,
            (w.along.z * w.along_speed + w.across.z * w.across_speed) * f,
          }, {w.point.x, w.point.y, w.point.z})
        }
      }
    }
    // Jolt takes the root of the tire's friction times the ground's
    local along = w.grip_along * w.grip_along / m.WORLD_FRICTION
    local across = w.grip_across * w.grip_across / m.WORLD_FRICTION
    w.along_curve:clear()
    w.along_curve:add_point(0, along)
    w.across_curve:clear()
    w.across_curve:add_point(0, across)
    // the brakes: the pedal, the hand brake at the back, the hold, and
    // what rolling over this ground costs
    local at = w.at
    local pedal = brake * (if(at.front){ BRAKE.front } else { BRAKE.rear })
    // no harder than the tire holds: a locked wheel neither stops the
    // truck sooner nor steers it
    local holds = w.surface.grip * w.surface.bite * w.load * m.WHEEL_RADIUS * 0.96
    if(pedal > holds and w.contact){
      pedal = holds
    }
    local torque = pedal + resist
    if(not at.front){
      torque = torque + c.hand_brake * HAND_BRAKE
    }
    torque = torque + c.still * HOLD_BRAKE
    w.brake = torque
    w.resist = resist
    w.settings.max_brake_torque = torque
    states[i] = {omega: w.omega, hold: w.hold, ground: w.ground, brake: torque}
  }

  // ---- the drivetrain: what it puts on each wheel. The road's load on
  // it is what the tires push with, less what speeds the truck up, plus
  // what rolling costs
  local push = 0
  local rolling = 0
  for(local i = 0; i < 4; i = i + 1){
    push = push + c.wheels[i].drive_force
    rolling = rolling + c.wheels[i].resist
  }
  c.accel = c.accel + ((speed - c.last_speed) / dt - c.accel) * (1 - math.exp(-dt * 8))
  c.last_speed = speed
  local road_load = ((push - m.MASS * c.accel) * m.WHEEL_RADIUS + rolling) * c.direction
  d.locks.front = input.lock_front == true
  d.locks.rear = input.lock_rear == true
  local torques = d:step({
    throttle: throttle, direction: c.direction, low: input.low == true, road_load: road_load,
    speed: speed,
  }, states, dt)
  for(local i = 0; i < 4; i = i + 1){
    local w = c.wheels[i]
    w.torque = torques[i]
    if(torques[i] != 0){
      w.jolt.angular_velocity = w.omega + torques[i] * dt / drivetrain.SPEC.wheel_inertia
    }
  }

  // ---- the air
  local v = c.velocity
  local air = vec.length(v)
  if(air > 1){
    c.body:add_force({-v.x * air * AIR_DRAG, -v.y * air * AIR_DRAG, -v.z * air * AIR_DRAG})
  }
  c.last_dt = dt
}

// The brakes of a standing truck hold it through the solver, which leaves
// a few millimeters a second of creep on a steep hill. What a real tire
// does at rest is hold its patch of ground like a brush: the anchor is a
// stiff spring from where the truck stood when it stopped, pulling it
// back along and across the ground with no more force than the tires
// have left. So a parked truck stays parked, and one parked on more slope
// than its tires can hold still slides.
local ANCHOR_STIFFNESS = 1.2e6    // N/m
local ANCHOR_DAMPING = 6.0e4      // N s/m

func Car.anchor(c, dt){
  if(not c.holding){
    c.anchored = null
    return
  }
  // the ground under the truck: where it touches, which way it faces,
  // and what the tires have left along and across
  local n = 0
  local px = 0
  local py = 0
  local pz = 0
  local nx = 0
  local ny = 0
  local nz = 0
  local spare_along = 0
  local spare_across = 0
  local weight = 0
  for(local i = 0; i < 4; i = i + 1){
    local w = c.wheels[i]
    if(w.contact){
      n = n + 1
      local l = math.max(w.load, 1)
      weight = weight + l
      px = px + w.point.x * l
      py = py + w.point.y * l
      pz = pz + w.point.z * l
      nx = nx + w.normal.x
      ny = ny + w.normal.y
      nz = nz + w.normal.z
      spare_along = spare_along + math.max(0, w.grip_along * w.load - math.abs(w.drive_force))
      spare_across = spare_across + math.max(0, w.grip_across * w.load - math.abs(w.side_force))
    }
  }
  if(n < 2){
    c.anchored = null
    return
  }
  local normal = vec.normalize({x: nx, y: ny, z: nz})
  local along = vec.normalize(vec.reject(c.forward, normal))
  local across = vec.cross(normal, along)
  local point = {x: px / weight, y: py / weight, z: pz / weight}
  // how fast the truck passes over that point
  local com = c.body.center_of_mass_position
  local r = vec.sub(point, com)
  local v = vec.add(c.velocity, vec.cross(c.spin, r))
  local v_along = vec.dot(v, along)
  local v_across = vec.dot(v, across)
  local a = c.anchored
  if(a == null){
    if(math.abs(v_along) > 0.25 or math.abs(v_across) > 0.25){
      return
    }
    a = {along: 0, across: 0}
    c.anchored = a
  }
  a.along = a.along + v_along * dt
  a.across = a.across + v_across * dt
  local f_along = -ANCHOR_STIFFNESS * a.along - ANCHOR_DAMPING * v_along
  if(math.abs(f_along) > spare_along){
    // more than the tires hold: the patch lets go and is dragged along
    f_along = if(f_along > 0){ spare_along } else { -spare_along }
    a.along = -f_along / ANCHOR_STIFFNESS
  }
  local f_across = -ANCHOR_STIFFNESS * a.across - ANCHOR_DAMPING * v_across
  if(math.abs(f_across) > spare_across){
    f_across = if(f_across > 0){ spare_across } else { -spare_across }
    a.across = -f_across / ANCHOR_STIFFNESS
  }
  c.body:add_force2({
    along.x * f_along + across.x * f_across,
    along.y * f_along + across.y * f_across,
    along.z * f_along + across.z * f_across,
  }, {point.x, point.y, point.z})
}

// place(c, position: Vec3, yaw: float): the truck put somewhere, at rest
func Car.place(c, position, yaw){
  c.body:set_position_rotation_and_velocity(
    {position.x, position.y, position.z}, vec.quat_yaw(yaw or 0), {0, 0, 0}, {0, 0, 0}
  )
  for(local i = 0; i < 4; i = i + 1){
    c.wheels[i].jolt.angular_velocity = 0
  }
  c.steer_angle = 0
  c.still = 0
  c.direction = 1
  c:read()
}

// upside_down(c) -> whether it lies on its side or roof
func Car.upside_down(c){
  return c.up.y < 0.25
}

func Car.destroy(c){
  c.vehicle:destroy()
  c.body:destroy()
}

return m
