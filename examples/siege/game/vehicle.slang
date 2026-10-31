// game/vehicle: the catapult. A Jolt wheeled vehicle (ray-cast
// suspension, four driven wheels, the front pair steering) carries a
// turret: an arm that turns toward where you aim and lifts to the pitch
// you choose. Holding fire winds it; letting go throws. Everything is
// drawn from the chassis' transform with the renderer's primitives.
local math = require("slang/math")
local jolt = require("jolt")
local vec = require("game/vec")
local render = require("game/render")
local terrain = require("game/terrain")

local m = {}
local Vehicle = {}
local vehicle_meta = {__index: Vehicle, __type: "Vehicle"}

m.CHASSIS = {x: 2.1, y: 0.55, z: 3.4}
m.WHEEL_RADIUS = 0.48
m.WHEEL_WIDTH = 0.34
local MASS = 1100
// the arm turns on an axle low on the frame: ARM of it reaches up to the
// bucket, TAIL of it down to the counterweight. At rest it leans back
// (REST past the aim's pitch); a throw whips it forward to the aim's
// pitch, where the stone leaves, and it drops back
local ARM = 2.3
local TAIL = 0.6
local PIVOT = {x: 0, y: 0.8, z: 0.1}
local REST = 1.35
local SWING_TIME = 0.16
local RELEASE = 0.78
m.MIN_SPEED = 12
m.MAX_SPEED = 36
m.CHARGE_TIME = 1.5
m.MIN_PITCH = 0.25
m.MAX_PITCH = 1.25
m.MAX_YAW = 1.1

// new(w: World, spawn: {x, z, yaw}) -> Vehicle
func m.new(w, spawn){
  local jw = w.jw
  local y = terrain.height_at(w.terrain, spawn.x, spawn.z) + 1.2
  // the center of mass low: a keel under the chassis in a compound shape
  local body = jw:create_body({
    shape: jolt.compound({
      {shape: jolt.box({m.CHASSIS.x / 2, m.CHASSIS.y / 2, m.CHASSIS.z / 2})},
      {shape: jolt.box({0.5, 0.2, 1}), position: {0, -0.45, 0}},
    }),
    position: {spawn.x, y, spawn.z},
    rotation: vec.quat_yaw(spawn.yaw or 0),
    motion: "dynamic",
    mass: MASS,
    friction: 0.5,
    linear_damping: 0.3,
    angular_damping: 0.8,
  })
  local wx = m.CHASSIS.x / 2 - 0.05
  local wz = m.CHASSIS.z / 2 - 0.55
  local wy = -m.CHASSIS.y / 2 + 0.1
  local positions = {
    {-wx, wy, wz}, {wx, wy, wz}, {-wx, wy, -wz}, {wx, wy, -wz}
  }
  local wheels = {}
  for(local i = 0; i < 4; i = i + 1){
    // the front pair steers
    local steer = 0
    if(i < 2){
      steer = 0.6
    }
    append(wheels, {
      position: positions[i],
      radius: m.WHEEL_RADIUS,
      width: m.WHEEL_WIDTH,
      suspension_min_length: 0.2,
      suspension_max_length: 0.45,
      suspension_spring: {
        mode: jolt.spring_mode_frequency_and_damping,
        frequency_or_stiffness: 2.2,
        damping: 1.0,
      },
      max_steer_angle: steer,
      max_brake_torque: 4000,
      max_hand_brake_torque: 4000,
    })
  }
  local vehicle = jw:create_vehicle({
    body: body,
    wheels: wheels,
    differentials: {{0, 1}, {2, 3}},
    engine: {max_torque: 1600, min_rpm: 800, max_rpm: 5000},
    up: {0, 1, 0},
    forward: {0, 0, 1},
    max_pitch_roll_angle: 1.2,
    anti_roll_bars: {
      {left_wheel: 0, right_wheel: 1, stiffness: 3000},
      {left_wheel: 2, right_wheel: 3, stiffness: 3000},
    },
    collision_tester: {type: "cast_cylinder", convex_radius_fraction: 0.05},
  })
  local v = {
    world: w,
    body: body,
    id: body.id,
    vehicle: vehicle,
    spawn: spawn,
    matrix: null,
    wheel_matrices: {},
    aim_yaw: 0,
    aim_pitch: 0.7,
    arm_yaw: 0,
    arm_pitch: 0.7,
    charge: 0,
    charging: false,
    swing: 0,
    pending: null,
    pos: {x: spawn.x, y: y, z: spawn.z},
    yaw: spawn.yaw or 0,
    speed: 0,
    wheel_speed: 0,
    loaded: true,
    meta: vehicle_meta,
  }
  w.vehicle_id = body.id
  w.blast = func(pos, radius, strength){
    v:blast(pos, radius, strength)
  }
  v:read()
  return v
}

// blast(v, pos, radius, strength): an explosion's push on the catapult
func Vehicle.blast(v, pos, radius, strength){
  local d = vec.distance(v.pos, pos)
  if(d < radius){
    local k = 1 - d / radius
    local dir = vec.normalize(vec.add(vec.sub(v.pos, pos), {x: 0, y: 0.5, z: 0}))
    v.body:activate()
    v.body:add_impulse(vec.scale(dir, strength * k * MASS * 0.5))
  }
}

// read(v): the chassis' and wheels' transforms after a step
func Vehicle.read(v){
  local jm = v.body:get_world_transform()
  v.matrix = vec.jolt_matrix(jm, {x: 1, y: 1, z: 1})
  v.pos = {x: v.matrix.m12, y: v.matrix.m13, z: v.matrix.m14}
  local forward = vec.transform_direction(v.matrix, {x: 0, y: 0, z: 1})
  v.yaw = math.atan2(forward.x, forward.z)
  v.up = vec.transform_direction(v.matrix, {x: 0, y: 1, z: 0})
  local vel = v.body:get_linear_velocity()
  v.speed = vec.dot(vel, forward)
  for(local i = 0; i < 4; i = i + 1){
    v.wheel_matrices[i] = vec.jolt_matrix(
      v.vehicle:get_wheel_world_transform(i), {x: 1, y: 1, z: 1}
    )
  }
  v.wheel_speed = v.vehicle:get_wheel(2):get_angular_velocity()
}

// What the player does this frame.
// type Input = {forward: float, right: float, brake: float, handbrake:
//   float, aim_yaw: float, aim_pitch: float, charging: bool}

// update(v, input, dt) -> {pos, direction, speed}? what was fired
func Vehicle.update(v, input, dt){
  if(input.forward != 0 or input.right != 0 or input.handbrake != 0){
    v.body:activate()
  }
  // a reversing catapult steers the other way, as a car does
  v.vehicle:set_driver_input(input.forward, input.right, input.brake,
    input.handbrake)
  v.aim_yaw = vec.clamp(input.aim_yaw, -m.MAX_YAW, m.MAX_YAW)
  v.aim_pitch = vec.clamp(input.aim_pitch, m.MIN_PITCH, m.MAX_PITCH)
  // the arm follows the aim with a little lag
  local k = math.min(1, dt * 10)
  v.arm_yaw = v.arm_yaw + (v.aim_yaw - v.arm_yaw) * k
  v.arm_pitch = v.arm_pitch + (v.aim_pitch - v.arm_pitch) * k
  local fired = null
  if(v.swing > 0){
    // the swing: forward fast, then back over the rest of a second
    local before = v.swing
    if(v.swing > RELEASE){
      v.swing = math.max(RELEASE, v.swing - dt / SWING_TIME * (1 - RELEASE))
    } else {
      v.swing = math.max(0, v.swing - dt * 1.1)
    }
    if(before > RELEASE and v.swing <= RELEASE and v.pending != null){
      // the arm hits its stop: the stone flies
      fired = v.pending
      fired.pos = v:launch_point()
      v.pending = null
    }
  }
  if(input.charging and v.loaded and v.swing == 0){
    v.charging = true
    v.charge = math.min(1, v.charge + dt / m.CHARGE_TIME)
  } else if(v.charging){
    v.charging = false
    if(v.loaded){
      v:fire()
    }
    v.charge = 0
  }
  return fired
}

// the speed a charge gives
func m.speed_of(charge){
  return m.MIN_SPEED + (m.MAX_SPEED - m.MIN_SPEED) * charge
}

// aim(v) -> the direction the arm points, in the world
func Vehicle.aim(v){
  local local_dir = vec.direction(v.arm_yaw, v.arm_pitch)
  return vec.normalize(vec.transform_direction(v.matrix, local_dir))
}

// the arm's angle from the forward horizontal: leaning back at rest, at
// the aim's pitch as it releases (swing goes 1 -> RELEASE -> 0)
func Vehicle.arm_angle(v){
  local rest = v.arm_pitch + REST
  if(v.swing <= 0){
    return rest
  }
  if(v.swing > RELEASE){
    local k = (1 - v.swing) / (1 - RELEASE)
    // whipping forward, fastest at the end
    return rest - (rest - v.arm_pitch) * k * k
  }
  local k = v.swing / RELEASE
  // dropping back
  return rest - (rest - v.arm_pitch) * k * k
}

// launch_point(v) -> where a thrown thing leaves: the bucket as the arm
// hits its stop (at the aim's pitch)
func Vehicle.launch_point(v){
  local q = vec.quat_multiply(vec.quat_yaw(v.arm_yaw),
    vec.quat_axis({x: 1, y: 0, z: 0}, -v.arm_pitch))
  local p = vec.add(PIVOT, vec.add(vec.scale(vec.direction(v.arm_yaw, v.arm_pitch), ARM),
    vec.rotate(q, {x: 0, y: -0.38, z: 0})))
  return vec.transform(v.matrix, p)
}

// bucket(v) -> where the bucket is now
func Vehicle.bucket(v){
  local p = vec.add(PIVOT, vec.scale(vec.direction(v.arm_yaw, v:arm_angle()), ARM))
  return vec.transform(v.matrix, p)
}

// fire(v): the arm starts its swing; the shot comes from update once the
// arm is at its stop
func Vehicle.fire(v){
  v.swing = 1
  v.pending = {
    direction: v:aim(),
    speed: m.speed_of(v.charge),
    charge: v.charge,
  }
  // the throw rocks the catapult back a little
  v.body:activate()
  v.body:add_impulse(vec.scale(v.pending.direction, -v.pending.speed * 60))
}

// swinging(v) -> whether the arm is in a throw
func Vehicle.swinging(v){
  return v.swing > 0
}

// trajectory(v, speed, damping) -> points of the flight of a thing thrown
// at speed, until it hits the ground or something in the world
func Vehicle.trajectory(v, speed, damping){
  local w = v.world
  local p = v:launch_point()
  local vel = vec.scale(v:aim(), speed)
  local points = {p}
  local dt = 0.06
  for(local i = 0; i < 110; i = i + 1){
    vel.y = vel.y - 9.81 * dt
    local k = math.max(0, 1 - (damping or 0.05) * dt)
    vel = vec.scale(vel, k)
    local next = vec.add(p, vec.scale(vel, dt))
    local hit = w:ray(p, vec.sub(next, p), vec.distance(p, next))
    if(hit != null and hit.body != v.body){
      append(points, hit.point)
      return points
    }
    if(next.y < terrain.height_at(w.terrain, next.x, next.z)){
      append(points, next)
      return points
    }
    if(next.y < w.terrain.water){
      append(points, next)
      return points
    }
    p = next
    append(points, p)
  }
  return points
}

// reset(v, spawn?): back on its wheels at the spawn (or where it is)
func Vehicle.reset(v, spawn){
  local w = v.world
  local x = v.pos.x
  local z = v.pos.z
  local yaw = v.yaw
  if(spawn != null){
    x = spawn.x
    z = spawn.z
    yaw = spawn.yaw or 0
  }
  local y = terrain.height_at(w.terrain, x, z) + 1.3
  v.body:set_position_rotation_and_velocity({x, y, z}, vec.quat_yaw(yaw),
    {0, 0, 0}, {0, 0, 0})
  v.body:activate()
  v.charge = 0
  v.charging = false
  v:read()
}

// upside_down(v) -> whether it lies on its roof (or side)
func Vehicle.upside_down(v){
  return v.up.y < 0.3
}

// in_water(v) -> whether it drove into the water
func Vehicle.in_water(v){
  return v.pos.y < v.world.terrain.water + 0.1
}

// ------------------------------------------------------------ drawing

local wood = {160, 118, 70}
local dark_wood = {104, 74, 46}
local iron = {58, 58, 64}
local rope = {196, 176, 130}
local identity = {x: 0, y: 0, z: 0, w: 1}

local turn_x = vec.quat_axis({x: 0, y: 0, z: 1}, -math.pi / 2)
local wheel_local = vec.matrix(vec.rotate(turn_x, {x: 0, y: -m.WHEEL_WIDTH / 2, z: 0}),
  turn_x, {x: m.WHEEL_RADIUS, y: m.WHEEL_WIDTH, z: m.WHEEL_RADIUS})
local hub_local = vec.matrix(vec.rotate(turn_x, {x: 0, y: -m.WHEEL_WIDTH / 2 - 0.02, z: 0}),
  turn_x, {x: m.WHEEL_RADIUS * 0.45, y: m.WHEEL_WIDTH + 0.04, z: m.WHEEL_RADIUS * 0.45})

// a part in the chassis' frame
local func part(v, shape, p, q, s, color, texture){
  render.draw(shape, vec.matrix_multiply(v.matrix, vec.matrix(p, q, s)), color,
    texture)
}

// draw(v, ammo_color?): the catapult; a loaded stone in the bucket
func Vehicle.draw(v, ammo){
  local c = m.CHASSIS
  // the chassis: planks on an iron frame
  part(v, "cube", {x: 0, y: 0, z: 0}, identity, {x: c.x, y: c.y, z: c.z}, wood, "planks")
  part(v, "cube", {x: 0, y: -0.2, z: 0}, identity, {x: c.x + 0.1, y: 0.12, z: c.z + 0.1}, iron, "rough")
  // the axles
  for(let local z in values({c.z / 2 - 0.55, -c.z / 2 + 0.55})){
    part(v, "cube", {x: 0, y: -0.25, z: z}, identity, {x: c.x + 0.3, y: 0.14, z: 0.14}, iron, "rough")
  }
  for(local i = 0; i < 4; i = i + 1){
    local wm = v.wheel_matrices[i]
    render.draw("cylinder", vec.matrix_multiply(wm, wheel_local), {70, 68, 66}, "rough")
    render.draw("cylinder", vec.matrix_multiply(wm, hub_local), dark_wood, "planks")
  }
  // the turret: a round base that turns with the aim
  local qy = vec.quat_yaw(v.arm_yaw)
  part(v, "cylinder", {x: 0, y: c.y / 2, z: PIVOT.z}, identity, {x: 0.95, y: 0.2, z: 0.95}, dark_wood, "planks")
  // the frame: two A-shaped uprights holding the axle, and the crossbar
  // in front the arm stops against
  for(local side = -1; side <= 1; side = side + 2){
    local lp = vec.rotate(qy, {x: side * 0.5, y: 0, z: 0})
    part(v, "cube", {x: lp.x, y: (c.y / 2 + PIVOT.y) / 2 + 0.1, z: PIVOT.z + lp.z},
      vec.quat_multiply(qy, vec.quat_axis({x: 0, y: 0, z: 1}, side * 0.1)),
      {x: 0.14, y: PIVOT.y - c.y / 2 + 0.1, z: 0.3}, wood, "planks")
    // a leaning strut from the base forward up to the crossbar
    local sp = vec.rotate(qy, {x: side * 0.5, y: 0, z: 0.9})
    part(v, "cube", {x: sp.x, y: c.y / 2 + 0.55, z: PIVOT.z + sp.z},
      vec.quat_multiply(qy, vec.quat_axis({x: 1, y: 0, z: 0}, 0.55)),
      {x: 0.12, y: 1.25, z: 0.12}, wood, "planks")
  }
  local bar = vec.rotate(qy, {x: 0, y: 0, z: 1.2})
  part(v, "cylinder", {x: bar.x, y: c.y / 2 + 1.05, z: PIVOT.z + bar.z},
    vec.quat_multiply(qy, vec.quat_axis({x: 0, y: 0, z: 1}, math.pi / 2)),
    {x: 0.08, y: 1.2, z: 0.08}, dark_wood, "planks")
  // the axle
  part(v, "cylinder", {x: 0, y: PIVOT.y, z: PIVOT.z},
    vec.quat_multiply(qy, vec.quat_axis({x: 0, y: 0, z: 1}, math.pi / 2)),
    {x: 0.07, y: 1.2, z: 0.07}, iron, "rough")
  // the arm: leaning back at rest, whipping forward in a throw
  local angle = v:arm_angle()
  local q = vec.quat_multiply(qy, vec.quat_axis({x: 1, y: 0, z: 0}, -angle))
  local arm_dir = vec.rotate(q, {x: 0, y: 0, z: 1})
  local mid = vec.add(PIVOT, vec.scale(arm_dir, (ARM - TAIL) / 2))
  part(v, "cube", mid, q, {x: 0.18, y: 0.22, z: ARM + TAIL}, wood, "planks")
  // the counterweight at the tail, an iron block
  local tail = vec.add(PIVOT, vec.scale(arm_dir, -TAIL - 0.15))
  part(v, "cube", tail, q, {x: 0.5, y: 0.45, z: 0.45}, iron, "rough")
  // the bucket at the top, on the side of the arm that faces the target
  // (the arm's local -y: up and forward while it leans back), with the
  // stone in it when loaded
  local tip = vec.add(PIVOT, vec.scale(arm_dir, ARM))
  part(v, "cube", tip, q, {x: 0.56, y: 0.16, z: 0.56}, dark_wood, "planks")
  for(local side = -1; side <= 1; side = side + 2){
    local lp = vec.rotate(q, {x: side * 0.25, y: -0.2, z: 0})
    part(v, "cube", vec.add(tip, lp), q, {x: 0.06, y: 0.3, z: 0.56}, dark_wood, "planks")
    local bp = vec.rotate(q, {x: 0, y: -0.2, z: side * 0.25})
    part(v, "cube", vec.add(tip, bp), q, {x: 0.56, y: 0.3, z: 0.06}, dark_wood, "planks")
  }
  if(ammo != null and v.loaded and v.pending == null){
    local lp = vec.rotate(q, {x: 0, y: -0.38, z: 0})
    local r = ammo.radius or 0.4
    render.draw("sphere", vec.matrix_multiply(v.matrix, vec.matrix(vec.add(tip, lp), identity, {
      x: r, y: r, z: r
    })), ammo.color, ammo.texture)
  }
  // the winding rope, from a winch at the back up to the arm, taut as it
  // charges
  local winch = vec.rotate(qy, {x: 0, y: 0, z: -1.2})
  part(v, "cylinder", {x: winch.x, y: c.y / 2 + 0.25, z: PIVOT.z + winch.z},
    vec.quat_multiply(qy, vec.quat_axis({x: 0, y: 0, z: 1}, math.pi / 2)),
    {x: 0.12, y: 0.8, z: 0.12}, dark_wood, "planks")
  local hook = vec.add(PIVOT, vec.scale(arm_dir, ARM * 0.55))
  local from = {x: winch.x, y: c.y / 2 + 0.25, z: PIVOT.z + winch.z}
  local rope_dir = vec.sub(hook, from)
  local rope_len = vec.length(rope_dir)
  local rope_mid = vec.lerp(from, hook, 0.5)
  local sag = 0.25 * (1 - v.charge)
  rope_mid.y = rope_mid.y - sag
  local rq = vec.quat_yaw(math.atan2(rope_dir.x, rope_dir.z))
  rq = vec.quat_multiply(rq, vec.quat_axis({x: 1, y: 0, z: 0},
    -math.atan2(rope_dir.y, math.sqrt(rope_dir.x * rope_dir.x + rope_dir.z * rope_dir.z))))
  part(v, "cube", rope_mid, rq, {x: 0.05, y: 0.05, z: rope_len}, rope, "white")
  render.shadow(v.pos, 1.6, terrain.height_at(v.world.terrain, v.pos.x, v.pos.z))
}

func Vehicle.destroy(v){
  v.vehicle:destroy()
  v.body:destroy()
  v.world.blast = null
}

return m
