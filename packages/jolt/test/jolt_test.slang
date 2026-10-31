// The binding without a window: worlds and bodies as objects, shapes,
// queries, constraints, a vehicle, characters, contact events and the raw
// layer (run with `slang test test` in packages/jolt)
local t = require("slang/test")
local jolt = require("jolt")

local func near(a, b, eps){
  eps = eps or 0.001
  return a - b < eps and b - a < eps
}

// a world with a floor whose top is at y = 0 and a ball above it
local func scene(options){
  local def = {gravity: {0, -9.81, 0}}
  for(let local e in entries(options or {})){
    def[e[0]] = e[1]
  }
  local world = jolt.world(def)
  local floor = world:create_body({
    shape: jolt.box({50, 1, 50}),
    position: {0, -1, 0},
  })
  local ball = world:create_body({
    shape: jolt.sphere(0.5),
    position: {0, 3, 0},
    motion: "dynamic",
  })
  return {world: world, floor: floor, ball: ball}
}

local func run(world, steps){
  for(local i = 0; i < steps; i = i + 1){
    world:step(1 / 60)
  }
}

t.group("jolt: worlds and bodies"){
  t.test("a ball falls, rests on the floor and goes to sleep"){
    local s = scene()
    assert(type(s.world) == "jolt.World" and type(s.ball) == "jolt.Body")
    assert(s.ball:is_active())
    run(s.world, 240)
    local p = s.ball:get_position()
    assert(near(p.x, 0) and near(p.y, 0.5, 0.03) and near(p.z, 0), p)
    assert(not s.ball:is_active())
    assert(len(s.world:get_bodies()) == 2)
    assert(len(s.world:get_active_bodies()) == 0)
    s.world:destroy()
  }
  t.test("several results come back as a table by name"){
    local s = scene()
    local both = s.ball:get_position_and_rotation()
    assert(near(both.position.y, 3) and near(both.rotation.w, 1))
    s.world:destroy()
  }
  t.test("other def fields are the creation settings' setters"){
    local s = scene()
    local body = s.world:create_body({
      shape: jolt.sphere(0.25),
      position: {5, 5, 0},
      motion: "dynamic",
      linear_velocity: {1, 0, 0},
      friction: 0.1,
      gravity_factor: 0,
      linear_damping: 0,
    })
    assert(near(body:get_linear_velocity().x, 1))
    assert(near(body:get_friction(), 0.1))
    run(s.world, 60)
    // no gravity: it moved one meter along x only
    local p = body:get_position()
    assert(near(p.x, 6, 0.02) and near(p.y, 5, 0.001), p)
    local r = pcall(s.world.create_body, s.world, {
      shape: jolt.sphere(1),
      bounciness: 1,
    })
    assert(r[0] == "err" and r[1].message == "jolt.create_body: no setter for bounciness",
      r[1].message)
    s.world:destroy()
  }
  t.test("mass, the shape and the body's id"){
    local s = scene()
    local heavy = s.world:create_body({
      shape: jolt.box({0.5, 0.5, 0.5}), position: {3, 1, 0}, motion: "dynamic",
      mass: 100,
    })
    assert(near(1 / heavy:get_motion_properties():get_inverse_mass_unchecked(), 100))
    assert(heavy:get_shape().kind == "box")
    assert(heavy:get_shape():get_half_extent().x == 0.5)
    assert(s.world:get_body(heavy.id) == heavy)
    assert(heavy:get_body_type() == jolt.body_type_rigid and heavy:is_dynamic())
    heavy:destroy()
    assert(len(s.world:get_bodies()) == 2)
    s.world:destroy()
  }
  t.test("a destroyed world refuses"){
    local s = scene()
    s.world:destroy()
    local r = pcall(s.world.step, s.world, 1 / 60)
    assert(r[0] == "err")
  }
}

t.group("jolt: shapes"){
  t.test("every kind, with density on the convex ones"){
    local box = jolt.box({1, 2, 3}, {convex_radius: 0.01, density: 500})
    assert(near(box:get_convex_radius(), 0.01) and near(box:get_density(), 500))
    assert(near(box:get_volume(), 48, 0.5))
    assert(jolt.sphere(2):get_radius() == 2)
    assert(jolt.capsule(1, 0.5):get_half_height_of_cylinder() == 1)
    assert(jolt.cylinder(1, 0.5, {convex_radius: 0.02}):get_half_height() == 1)
    assert(jolt.tapered_capsule(1, 0.5, 0.3):get_top_radius() == 0.5)
    assert(near(jolt.tapered_cylinder(1, 0.5, 0.3):get_bottom_radius(), 0.3))
    assert(jolt.triangle({0, 0, 0}, {1, 0, 0}, {0, 1, 0}).kind == "triangle")
    local hull = jolt.convex_hull({
      {0, 0, 0}, {1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 1, 1}
    })
    assert(hull:get_num_points() == 5)
    local mesh = jolt.mesh({{v1: {0, 0, 0}, v2: {1, 0, 0}, v3: {0, 0, 1}}})
    assert(mesh.kind == "mesh" and mesh:must_be_static())
    local field = jolt.height_field({
      0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0
    }, {size: 4, scale: {2, 1, 2}})
    assert(field:get_sample_count() == 4 and near(field:get_max_height_value(), 1))
    assert(jolt.scaled(box, {2, 2, 2}):get_scale().x == 2)
    assert(jolt.rotated_translated(box, {1, 0, 0}, {0, 0, 0, 1}):get_position().x == 1)
    assert(jolt.offset_center_of_mass(box, {0, -1, 0}):get_offset().y == -1)
    assert(jolt.empty().kind == "empty")
  }
  t.test("a compound of shapes"){
    local c = jolt.compound({
      {shape: jolt.box({1, 0.5, 1})},
      {shape: jolt.box({0.2, 0.2, 0.2}), position: {0, -0.7, 0}},
    })
    assert(c.kind == "static_compound" and c:get_num_sub_shapes() == 2)
    local m = jolt.mutable_compound({{shape: jolt.sphere(1)}})
    m:add_shape({0, 2, 0}, {0, 0, 0, 1}, jolt.sphere(0.5), 0, 1)
    assert(m:get_num_sub_shapes() == 2)
    local s = scene()
    local body = s.world:create_body({shape: c, position: {0, 2, 0}, motion: "dynamic"})
    assert(body:get_shape() == c)
    s.world:destroy()
  }
}

t.group("jolt: queries"){
  t.test("a ray hits the ball; a miss is null"){
    local s = scene()
    local hit = s.world:cast_ray({0, 10, 0}, {0, -20, 0})
    assert(hit != null and hit.body == s.ball)
    // the top of the ball: 6.5 of the 20 meters down
    assert(near(hit.fraction, 6.5 / 20) and near(hit.point.y, 3.5))
    assert(s.world:cast_ray({10, 10, 0}, {0, 5, 0}) == null)
    s.world:destroy()
  }
  t.test("points inside, shapes cast and overlapping"){
    local s = scene()
    local inside = s.world:collide_point({0, 3, 0})
    assert(len(inside) == 1 and inside[0].body == s.ball)
    assert(len(s.world:collide_point({0, 8, 0})) == 0)
    local hits = s.world:cast_shape(
      jolt.sphere(0.2), jolt.mat4.translation({0, 10, 0}), {0, -20, 0}
    )
    assert(len(hits) == 2, len(hits))
    local overlaps = s.world:collide_shape(jolt.box({1, 1, 1}), jolt.mat4.translation({0, 3, 0}))
    assert(len(overlaps) == 1 and overlaps[0].body == s.ball)
    s.world:destroy()
  }
}

t.group("jolt: constraints"){
  t.test("a hinge with limits, and a rope to the world"){
    local s = scene()
    local a = s.world:create_body({
      shape: jolt.box({0.5, 0.5, 0.5}), position: {0, 5, 0}, motion: "dynamic",
    })
    local b = s.world:create_body({
      shape: jolt.box({0.5, 0.5, 0.5}), position: {1.5, 5, 0}, motion: "dynamic",
    })
    local hinge = s.world:create_constraint({
      type: "hinge", body1: a, body2: b,
      point1: {0.75, 5, 0}, point2: {0.75, 5, 0},
      hinge_axis1: {0, 0, 1}, hinge_axis2: {0, 0, 1},
      normal_axis1: {1, 0, 0}, normal_axis2: {1, 0, 0},
      limits_min: -0.5, limits_max: 0.5,
    })
    assert(type(hinge) == "jolt.Constraint" and hinge.kind == "hinge")
    assert(hinge:has_limits() and near(hinge:get_limits_max(), 0.5))
    assert(hinge:get_body1() == a and hinge:get_body2() == b)
    assert(s.world:get_num_constraints() == 1)
    local rope = s.world:create_constraint({
      type: "distance", body1: a,
      point1: {0, 5, 0}, point2: {0, 8, 0}, min_distance: 0, max_distance: 3,
    })
    assert(near(rope:get_max_distance(), 3))
    run(s.world, 120)
    // hanging from the rope: a stayed up, and b with it
    assert(a:get_position().y > 4 and b:get_position().y > 3, b:get_position())
    hinge:destroy()
    rope:destroy()
    assert(s.world:get_num_constraints() == 0)
    local r = pcall(s.world.create_constraint, s.world, {type: "rope", body1: a})
    assert(r[0] == "err")
    s.world:destroy()
  }
}

t.group("jolt: vehicles"){
  t.test("a car drives forward"){
    local s = scene()
    local chassis = s.world:create_body({
      shape: jolt.box({1, 0.3, 2}), position: {5, 1, 0}, motion: "dynamic",
      mass: 1000,
    })
    local wheels = {}
    for(let local p in values({
      {-1, -0.3, 1.5}, {1, -0.3, 1.5}, {-1, -0.3, -1.5}, {1, -0.3, -1.5}
    })){
      append(wheels, {
        position: p, radius: 0.4, width: 0.3,
        suspension_min_length: 0.2, suspension_max_length: 0.5,
        suspension_spring: {
          mode: jolt.spring_mode_frequency_and_damping,
          frequency_or_stiffness: 2, damping: 1,
        },
        max_steer_angle: 0.5, max_brake_torque: 1000, max_hand_brake_torque: 1000,
      })
    }
    local car = s.world:create_vehicle({
      body: chassis, wheels: wheels,
      engine: {max_torque: 500, min_rpm: 800, max_rpm: 5000},
      transmission: {gear_ratios: {2.5, 1.5, 1}},
      anti_roll_bars: {{left_wheel: 0, right_wheel: 1, stiffness: 1000}},
      max_pitch_roll_angle: 1.2,
    })
    assert(type(car) == "jolt.Vehicle" and car:get_wheels_count() == 4)
    assert(car.body == chassis and car:get_vehicle_body() == chassis)
    car:set_driver_input(1, 0, 0, 0)
    run(s.world, 120)
    local p = chassis:get_position()
    assert(p.z > 3, p)
    assert(car.wheels[2]:get_angular_velocity() > 1)
    assert(near(car:get_wheel(0):get_settings():get_radius(), 0.4))
    assert(car.controller:get_engine():get_current_rpm() > 800)
    assert(car.controller:get_transmission():get_current_gear() >= 1)
    local m = jolt.mat4_to_matrix(car:get_wheel_world_transform(0))
    assert(near(m.m13, p.y - 0.3, 0.5))
    car:destroy()
    s.world:destroy()
  }
}

t.group("jolt: characters"){
  t.test("a character stands on the floor, a virtual one walks"){
    local s = scene()
    local walker = s.world:create_character({
      shape: jolt.capsule(0.5, 0.3), position: {-5, 2, 0}, mass: 70,
    })
    for(local i = 0; i < 90; i = i + 1){
      s.world:step(1 / 60)
      walker:post_simulation(0.05)
    }
    assert(walker:get_ground_state() == jolt.ground_state_on_ground)
    assert(near(walker:get_position().y, 0.8, 0.05))
    local ghost = s.world:create_character_virtual({
      shape: jolt.capsule(0.5, 0.3), position: {-8, 1, 0},
    })
    for(local i = 0; i < 60; i = i + 1){
      ghost:set_linear_velocity({1, -1, 0})
      ghost:update(1 / 60)
      s.world:step(1 / 60)
    }
    local p = ghost:get_position()
    assert(p.x > -7.5 and near(p.y, 0.8, 0.05), p)
    walker:destroy()
    ghost:destroy()
    s.world:destroy()
  }
}

t.group("jolt: contact events (callbacks from Jolt's threads)"){
  t.test("a ball lands: one contact added, with its normal and point"){
    local s = scene({contact_events: true})
    local added = {}
    for(local i = 0; i < 120; i = i + 1){
      s.world:step(1 / 60)
      for(let local c in values(s.world:get_contact_events().added)){
        append(added, c)
      }
    }
    assert(len(added) == 1, len(added))
    local c = added[0]
    assert(
      (c.body1 == s.floor and c.body2 == s.ball) or
        (c.body1 == s.ball and c.body2 == s.floor),
    )
    assert(near(c.normal.y * c.normal.y, 1) and len(c.points) >= 1)
    assert(near(c.points[0].y, 0, 0.05), c.points[0])
    s.world:destroy()
  }
  t.test("many bodies at once, and contacts that end"){
    local world = jolt.world({
      gravity: {0, -9.81, 0},
      contact_events: "all",
    })
    world:create_body({
      shape: jolt.box({50, 1, 50}),
      position: {0, -1, 0},
    })
    local shape = jolt.box({0.4, 0.4, 0.4})
    local bodies = {}
    for(local i = 0; i < 40; i = i + 1){
      append(bodies, world:create_body({
        shape: shape,
        position: {(i % 8) - 4, 1 + to_int(i / 8) * 1.2, 0},
        motion: "dynamic",
      }))
    }
    local added = 0
    local persisted = 0
    for(local i = 0; i < 90; i = i + 1){
      world:step(1 / 60)
      local ev = world:get_contact_events()
      added = added + len(ev.added)
      persisted = persisted + len(ev.persisted)
    }
    assert(added >= 40 and persisted > added, added)
    // thrown apart: their contacts end
    for(local i = 0; i < len(bodies); i = i + 1){
      bodies[i]:set_linear_velocity({(i % 8) - 4, 10 + i, 0})
    }
    local removed = 0
    for(local i = 0; i < 10; i = i + 1){
      world:step(1 / 60)
      removed = removed + len(world:get_contact_events().removed)
    }
    assert(removed >= 40, removed)
    world:destroy()
  }
}

t.group("jolt: helpers and the raw layer"){
  t.test("a body's transform as sixteen fields; the math namespaces"){
    local s = scene()
    local m = jolt.mat4_to_matrix(s.ball:get_world_transform())
    assert(m.m0 == 1 and m.m5 == 1 and m.m10 == 1 and near(m.m13, 3))
    local q = jolt.quat.multiply({0, 0, 0, 1}, {0, 0.707, 0, 0.707})
    assert(near(q.y, 0.707))
    assert(jolt.vec3.cross({1, 0, 0}, {0, 1, 0}).z == 1)
    assert(jolt.mat4.identity().column[0].x == 1)
    s.world:destroy()
  }
  t.test("names, constants and raw"){
    assert(jolt.motion_type_dynamic == 2)
    assert(jolt.DEFAULT_CONVEX_RADIUS > 0)
    assert(
      require("jolt/names").snake("JPH_BodyInterface_GetPosition") ==
        "body_interface_get_position",
    )
    assert(require("jolt/names").snake("JPH_BodyCreationSettings_SetAllowedDOFs") ==
      "body_creation_settings_set_allowed_dofs")
    local s = scene()
    local p = jolt.raw.body_interface_get_position(s.world.body_interface, s.ball.id)
    assert(near(p.y, 3))
    assert(jolt.raw.physics_system_get_num_bodies(s.world.system) == 2)
    assert(jolt.raw.no_such_function == null)
    s.world:destroy()
  }
}
