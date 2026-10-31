// game/vehicle: the catapult. A Jolt wheeled vehicle (ray-cast
// suspension, four driven wheels, the front pair steering) carries a
// turret: an arm that turns toward where you aim and lifts to the pitch
// you choose. Holding fire winds it; letting go throws. Everything is
// drawn from the chassis' transform with the renderer's primitives.
local math = require("slang/math")
local ffi = require("slang/ffi")
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
local ARM = 2.3
local PIVOT = {x: 0, y: 1.05, z: -0.35}
m.MIN_SPEED = 12
m.MAX_SPEED = 36
m.CHARGE_TIME = 1.5
m.MIN_PITCH = 0.25
m.MAX_PITCH = 1.25
m.MAX_YAW = 1.1

// new(w: World, spawn: {x, z, yaw}) -> Vehicle
func m.new(w, spawn){
  local D = jolt.decls
  local jw = w.jw
  local y = terrain.height_at(w.terrain, spawn.x, spawn.z) + 1.2
  local shape = jolt.box_shape_create({
    m.CHASSIS.x / 2, m.CHASSIS.y / 2, m.CHASSIS.z / 2
  })
  // the center of mass low: a box under the chassis in a compound shape
  local compound = jolt.static_compound_shape_settings_create()
  jolt.compound_shape_settings_add_shape2(compound, {0, 0, 0}, {0, 0, 0, 1},
    shape, 0)
  local keel = jolt.box_shape_create({0.5, 0.2, 1})
  jolt.compound_shape_settings_add_shape2(compound, {0, -0.45, 0},
    {0, 0, 0, 1}, keel, 0)
  local body_shape = jolt.static_compound_shape_create(compound)
  local settings = jolt.body_creation_settings_create3(
    body_shape, {spawn.x, y, spawn.z}, vec.quat_yaw(spawn.yaw or 0),
    jolt.motion_type_dynamic, jolt.layers.moving
  )
  jolt.body_creation_settings_set_override_mass_properties(
    settings, jolt.override_mass_properties_calculate_inertia
  )
  local mp = ffi.new("JPH_MassProperties", 1, D)
  mp.mass = MASS
  jolt.body_creation_settings_set_mass_properties_override(settings, mp)
  jolt.body_creation_settings_set_friction(settings, 0.5)
  jolt.body_creation_settings_set_linear_damping(settings, 0.2)
  jolt.body_creation_settings_set_angular_damping(settings, 0.8)
  local body = jolt.body_interface_create_body(jw.bodies, settings)
  local id = jolt.body_get_id(body)
  jolt.body_interface_add_body(jw.bodies, id, jolt.activation_activate)
  jolt.body_creation_settings_destroy(settings)

  local wheels = ffi.new("JPH_WheelSettings *", 4, D)
  local wx = m.CHASSIS.x / 2 - 0.05
  local wz = m.CHASSIS.z / 2 - 0.55
  local wy = -m.CHASSIS.y / 2 + 0.1
  local positions = {
    {-wx, wy, wz}, {wx, wy, wz}, {-wx, wy, -wz}, {wx, wy, -wz}
  }
  local spring = ffi.new("JPH_SpringSettings", 1, D)
  spring.mode = jolt.spring_mode_frequency_and_damping
  spring.frequency_or_stiffness = 1.8
  spring.damping = 0.6
  for(local i = 0; i < 4; i = i + 1){
    local ws = jolt.wheel_settings_wv_create()
    jolt.wheel_settings_set_position(ws, positions[i])
    jolt.wheel_settings_set_radius(ws, m.WHEEL_RADIUS)
    jolt.wheel_settings_set_width(ws, m.WHEEL_WIDTH)
    jolt.wheel_settings_set_suspension_min_length(ws, 0.2)
    jolt.wheel_settings_set_suspension_max_length(ws, 0.45)
    jolt.wheel_settings_set_suspension_spring(ws, spring)
    if(i < 2){
      jolt.wheel_settings_wv_set_max_steer_angle(ws, 0.6)
    } else {
      jolt.wheel_settings_wv_set_max_steer_angle(ws, 0)
    }
    jolt.wheel_settings_wv_set_max_brake_torque(ws, 1500)
    jolt.wheel_settings_wv_set_max_hand_brake_torque(ws, 4000)
    wheels[i] = ws
  }
  local ctrl = jolt.wheeled_vehicle_controller_settings_create()
  jolt.wheeled_vehicle_controller_settings_add_differential(ctrl, 0, 1)
  jolt.wheeled_vehicle_controller_settings_add_differential(ctrl, 2, 3)
  local engine = ffi.new("JPH_VehicleEngineSettings", 1, D)
  jolt.vehicle_engine_settings_init(engine)
  engine.max_torque = 520
  engine.min_rpm = 800
  engine.max_rpm = 5000
  jolt.wheeled_vehicle_controller_settings_set_engine(ctrl, engine)
  local vs = ffi.new("JPH_VehicleConstraintSettings", 1, D)
  jolt.vehicle_constraint_settings_init(vs)
  vs.wheels_count = 4
  vs.wheels = wheels
  vs.controller = ctrl
  vs.up = {0, 1, 0}
  vs.forward = {0, 0, 1}
  vs.max_pitch_roll_angle = 1.2
  local bars = ffi.new("JPH_VehicleAntiRollBar", 2, D)
  for(local i = 0; i < 2; i = i + 1){
    jolt.vehicle_anti_roll_bar_init(bars[i])
    bars[i].left_wheel = i * 2
    bars[i].right_wheel = i * 2 + 1
    bars[i].stiffness = 3000
  }
  vs.anti_roll_bars_count = 2
  vs.anti_roll_bars = bars
  local constraint = jolt.vehicle_constraint_create(body, vs)
  local tester = jolt.vehicle_collision_tester_cast_cylinder_create(
    jolt.layers.moving, 0.05
  )
  jolt.vehicle_constraint_set_vehicle_collision_tester(constraint, tester)
  jolt.physics_system_add_constraint(jw.system, constraint)
  local listener = jolt.vehicle_constraint_as_physics_step_listener(constraint)
  jolt.physics_system_add_step_listener(jw.system, listener)
  local v = {
    world: w,
    id: id,
    constraint: constraint,
    listener: listener,
    controller: jolt.vehicle_constraint_get_controller(constraint),
    tester: tester,
    keep: {wheels: wheels, spring: spring, engine: engine, vs: vs, bars: bars, mp: mp},
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
    pos: {x: spawn.x, y: y, z: spawn.z},
    yaw: spawn.yaw or 0,
    speed: 0,
    wheel_speed: 0,
    loaded: true,
    meta: vehicle_meta,
  }
  w.vehicle_id = id
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
    jolt.body_interface_activate_body(v.world.bodies, v.id)
    jolt.body_interface_add_impulse(v.world.bodies, v.id,
      vec.scale(dir, strength * k * MASS * 0.5))
  }
}

// read(v): the chassis' and wheels' transforms after a step
func Vehicle.read(v){
  local bodies = v.world.bodies
  local jm = jolt.body_interface_get_world_transform(bodies, v.id)
  v.matrix = vec.jolt_matrix(jm, {x: 1, y: 1, z: 1})
  v.pos = {x: v.matrix.m12, y: v.matrix.m13, z: v.matrix.m14}
  local forward = vec.transform_direction(v.matrix, {x: 0, y: 0, z: 1})
  v.yaw = math.atan2(forward.x, forward.z)
  v.up = vec.transform_direction(v.matrix, {x: 0, y: 1, z: 0})
  local vel = jolt.body_interface_get_linear_velocity(bodies, v.id)
  v.speed = vec.dot(vel, forward)
  for(local i = 0; i < 4; i = i + 1){
    v.wheel_matrices[i] = vec.jolt_matrix(
      jolt.vehicle_constraint_get_wheel_world_transform(v.constraint, i,
        {1, 0, 0}, {0, 1, 0}),
      {x: 1, y: 1, z: 1},
    )
  }
  v.wheel_speed = jolt.wheel_get_angular_velocity(
    jolt.vehicle_constraint_get_wheel(v.constraint, 2)
  )
}

// What the player does this frame.
// type Input = {forward: float, right: float, brake: float, handbrake:
//   float, aim_yaw: float, aim_pitch: float, charging: bool}

// update(v, input, dt) -> {pos, direction, speed}? what was fired
func Vehicle.update(v, input, dt){
  if(input.forward != 0 or input.right != 0 or input.handbrake != 0){
    jolt.body_interface_activate_body(v.world.bodies, v.id)
  }
  // a reversing catapult steers the other way, as a car does
  jolt.wheeled_vehicle_controller_set_driver_input(
    v.controller, input.forward, input.right, input.brake, input.handbrake
  )
  v.aim_yaw = vec.clamp(input.aim_yaw, -m.MAX_YAW, m.MAX_YAW)
  v.aim_pitch = vec.clamp(input.aim_pitch, m.MIN_PITCH, m.MAX_PITCH)
  // the arm follows the aim with a little lag
  local k = math.min(1, dt * 10)
  v.arm_yaw = v.arm_yaw + (v.aim_yaw - v.arm_yaw) * k
  v.arm_pitch = v.arm_pitch + (v.aim_pitch - v.arm_pitch) * k
  local fired = null
  if(v.swing > 0){
    v.swing = math.max(0, v.swing - dt * 2.4)
  }
  if(input.charging and v.loaded and v.swing == 0){
    v.charging = true
    v.charge = math.min(1, v.charge + dt / m.CHARGE_TIME)
  } else if(v.charging){
    v.charging = false
    if(v.loaded){
      fired = v:fire()
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

// launch_point(v) -> where a thrown thing starts: the bucket
func Vehicle.launch_point(v){
  local p = vec.add(PIVOT, vec.scale(vec.direction(v.arm_yaw, v.arm_pitch), ARM))
  return vec.transform(v.matrix, p)
}

func Vehicle.fire(v){
  v.swing = 1
  local shot = {
    pos: v:launch_point(),
    direction: v:aim(),
    speed: m.speed_of(v.charge),
    charge: v.charge,
  }
  // the throw pushes the catapult back a little
  jolt.body_interface_add_impulse(v.world.bodies, v.id,
    vec.scale(shot.direction, -shot.speed * 60))
  return shot
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
    if(hit != null and hit.body != v.id){
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
  jolt.body_interface_set_position_rotation_and_velocity(w.bodies, v.id,
    {x, y, z}, vec.quat_yaw(yaw), {0, 0, 0}, {0, 0, 0})
  jolt.body_interface_activate_body(w.bodies, v.id)
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
  part(v, "cylinder", {x: 0, y: c.y / 2, z: PIVOT.z}, identity, {x: 0.9, y: 0.2, z: 0.9}, dark_wood, "planks")
  // two uprights holding the pivot
  for(local side = -1; side <= 1; side = side + 2){
    local lp = vec.rotate(qy, {x: side * 0.42, y: 0, z: 0})
    part(v, "cube", {x: lp.x, y: (c.y / 2 + PIVOT.y) / 2 + 0.1, z: PIVOT.z + lp.z},
      vec.quat_multiply(qy, vec.quat_axis({x: 0, y: 0, z: 1}, side * 0.12)),
      {x: 0.14, y: PIVOT.y - c.y / 2, z: 0.3}, wood, "planks")
  }
  // the axle of the arm
  part(v, "cylinder", {x: 0, y: PIVOT.y, z: PIVOT.z},
    vec.quat_multiply(qy, vec.quat_axis({x: 0, y: 0, z: 1}, math.pi / 2)),
    {x: 0.07, y: 1, z: 0.07}, iron, "rough")
  // the arm: it lifts with the pitch, and whips up when it throws
  local pitch = v.arm_pitch + v.swing * 0.9 * math.sin(v.swing * math.pi)
  local q = vec.quat_multiply(qy, vec.quat_axis({x: 1, y: 0, z: 0}, -pitch))
  local arm_dir = vec.rotate(q, {x: 0, y: 0, z: 1})
  local mid = vec.add(PIVOT, vec.scale(arm_dir, ARM / 2 - 0.3))
  part(v, "cube", mid, q, {x: 0.2, y: 0.2, z: ARM + 0.6}, wood, "planks")
  // a counterweight at the back of the arm
  local back = vec.add(PIVOT, vec.scale(arm_dir, -0.7))
  part(v, "cube", back, q, {x: 0.5, y: 0.5, z: 0.5}, iron, "rough")
  // the bucket at the end, with the stone in it when loaded
  local tip = vec.add(PIVOT, vec.scale(arm_dir, ARM))
  part(v, "cube", tip, q, {x: 0.55, y: 0.18, z: 0.55}, dark_wood, "planks")
  for(local side = -1; side <= 1; side = side + 2){
    local lp = vec.rotate(q, {x: side * 0.25, y: 0.1, z: 0})
    part(v, "cube", vec.add(tip, lp), q, {x: 0.06, y: 0.3, z: 0.55}, dark_wood, "planks")
  }
  if(ammo != null and v.loaded and v.swing == 0){
    local lp = vec.rotate(q, {x: 0, y: 0.32, z: 0})
    local r = ammo.radius or 0.4
    render.draw("sphere", vec.matrix_multiply(v.matrix, vec.matrix(vec.add(tip, lp), identity, {
      x: r, y: r, z: r
    })), ammo.color, ammo.texture)
  }
  // the winding rope grows taut as it charges
  local tension = v.charge
  local rope_q = vec.quat_multiply(qy, vec.quat_axis({x: 1, y: 0, z: 0}, 0.4 + tension * 0.3))
  part(v, "cube", {x: 0, y: c.y / 2 + 0.35, z: PIVOT.z + 0.7}, rope_q,
    {x: 0.05, y: 0.05, z: 1 + tension * 0.3}, rope, "white")
  render.shadow(v.pos, 1.6, terrain.height_at(v.world.terrain, v.pos.x, v.pos.z))
}

func Vehicle.destroy(v){
  local jw = v.world.jw
  jolt.physics_system_remove_step_listener(jw.system, v.listener)
  jolt.physics_system_remove_constraint(jw.system, v.constraint)
  jolt.body_interface_remove_and_destroy_body(v.world.bodies, v.id)
}

return m
