// The binding without a window: worlds and bodies, results Jolt writes
// through pointers, queries and the helpers (run with `slang test test` in
// packages/jolt)
local t = require("slang/test")
local jolt = require("jolt")

local func near(a, b, eps){
  eps = eps or 0.001
  return a - b < eps and b - a < eps
}

// a world with a floor whose top is at y = 0 and a ball above it
local func scene(){
  local world = jolt.create_world({gravity: {0, -9.81, 0}})
  local floor = jolt.create_body(world, {
    shape: jolt.box_shape_create({50, 1, 50}),
    position: {0, -1, 0},
  })
  local ball = jolt.create_body(world, {
    shape: jolt.sphere_shape_create(0.5),
    position: {0, 3, 0},
    motion: "dynamic",
  })
  return {world: world, floor: floor, ball: ball}
}

local func run(world, steps){
  for(local i = 0; i < steps; i = i + 1){
    jolt.step(world, 1 / 60)
  }
}

t.group("jolt: worlds and bodies"){
  t.test("a ball falls, rests on the floor and goes to sleep"){
    local s = scene()
    local bodies = s.world.bodies
    assert(jolt.body_interface_is_active(bodies, s.ball))
    run(s.world, 240)
    local p = jolt.body_interface_get_position(bodies, s.ball)
    assert(near(p.x, 0) and near(p.y, 0.5, 0.03) and near(p.z, 0), p)
    assert(not jolt.body_interface_is_active(bodies, s.ball))
    jolt.destroy_world(s.world)
  }
  t.test("several results come back as a table by name"){
    local s = scene()
    local both = jolt.body_interface_get_position_and_rotation(
      s.world.bodies, s.ball
    )
    assert(near(both.position.y, 3) and near(both.rotation.w, 1))
    jolt.destroy_world(s.world)
  }
  t.test("other def fields call the creation settings' setters"){
    local s = scene()
    local id = jolt.create_body(s.world, {
      shape: jolt.sphere_shape_create(0.25),
      position: {5, 5, 0},
      motion: "dynamic",
      linear_velocity: {1, 0, 0},
      friction: 0.1,
      gravity_factor: 0,
      linear_damping: 0,
    })
    local v = jolt.body_interface_get_linear_velocity(s.world.bodies, id)
    assert(near(v.x, 1))
    assert(near(jolt.body_interface_get_friction(s.world.bodies, id), 0.1))
    run(s.world, 60)
    // no gravity: it moved one meter along x only
    local p = jolt.body_interface_get_position(s.world.bodies, id)
    assert(near(p.x, 6, 0.02) and near(p.y, 5, 0.001), p)
    local r = pcall(jolt.create_body, s.world, {
      shape: jolt.sphere_shape_create(1),
      bounciness: 1,
    })
    assert(r[0] == "err")
    jolt.destroy_world(s.world)
  }
}

t.group("jolt: queries"){
  t.test("a ray hits the ball; a miss is null"){
    local s = scene()
    local hit = jolt.narrow_phase_query_cast_ray(
      s.world.narrow_phase, {0, 10, 0}, {0, -20, 0}
    )
    assert(hit != null and hit.body_id == s.ball)
    // the top of the ball: 6.5 of the 20 meters down
    assert(near(hit.fraction, 6.5 / 20))
    local miss = jolt.narrow_phase_query_cast_ray(
      s.world.narrow_phase, {10, 10, 0}, {0, 5, 0}
    )
    assert(miss == null)
    jolt.destroy_world(s.world)
  }
}

t.group("jolt: helpers"){
  t.test("a body's transform as sixteen fields"){
    local s = scene()
    local m = jolt.mat4_to_matrix(jolt.body_interface_get_world_transform(
      s.world.bodies, s.ball
    ))
    assert(m.m0 == 1 and m.m5 == 1 and m.m10 == 1 and near(m.m13, 3))
    jolt.destroy_world(s.world)
  }
  t.test("names and constants"){
    assert(jolt.motion_type_dynamic == 2)
    assert(jolt.DEFAULT_CONVEX_RADIUS > 0)
    assert(
      require("jolt/names").snake("JPH_BodyInterface_GetPosition") ==
        "body_interface_get_position",
    )
  }
}

t.group("jolt: contact events (callbacks from Jolt's threads)"){
  t.test("a ball lands: one contact added, with its normal and point"){
    local world = jolt.create_world({
      gravity: {0, -9.81, 0},
      contact_events: true,
    })
    local floor = jolt.create_body(world, {
      shape: jolt.box_shape_create({50, 1, 50}),
      position: {0, -1, 0},
    })
    local ball = jolt.create_body(world, {
      shape: jolt.sphere_shape_create(0.5), position: {0, 2, 0},
      motion: "dynamic"
    })
    local added = {}
    for(local i = 0; i < 120; i = i + 1){
      jolt.step(world, 1 / 60)
      for(let local c in values(jolt.world_get_contact_events(world).added)){
        append(added, c)
      }
    }
    assert(len(added) == 1, len(added))
    local c = added[0]
    assert(
      (c.body1 == floor and c.body2 == ball) or
        (c.body1 == ball and c.body2 == floor),
    )
    assert(near(c.normal.y * c.normal.y, 1) and len(c.points) >= 1)
    assert(near(c.points[0].y, 0, 0.05), c.points[0])
    jolt.destroy_world(world)
  }
  t.test("many bodies at once, and contacts that end"){
    local world = jolt.create_world({
      gravity: {0, -9.81, 0},
      contact_events: "all",
    })
    jolt.create_body(world, {
      shape: jolt.box_shape_create({50, 1, 50}),
      position: {0, -1, 0},
    })
    local shape = jolt.box_shape_create({0.4, 0.4, 0.4})
    local ids = {}
    for(local i = 0; i < 40; i = i + 1){
      append(ids, jolt.create_body(world, {
        shape: shape,
        position: {(i % 8) - 4, 1 + to_int(i / 8) * 1.2, 0},
        motion: "dynamic",
      }))
    }
    local added = 0
    local persisted = 0
    for(local i = 0; i < 90; i = i + 1){
      jolt.step(world, 1 / 60)
      local ev = jolt.world_get_contact_events(world)
      added = added + len(ev.added)
      persisted = persisted + len(ev.persisted)
    }
    assert(added >= 40 and persisted > added, added)
    // thrown apart: their contacts end
    for(local i = 0; i < len(ids); i = i + 1){
      jolt.body_interface_set_linear_velocity(world.bodies, ids[i], {
        (i % 8) - 4, 10 + i, 0
      })
    }
    local removed = 0
    for(local i = 0; i < 10; i = i + 1){
      jolt.step(world, 1 / 60)
      removed = removed + len(jolt.world_get_contact_events(world).removed)
    }
    assert(removed >= 40, removed)
    jolt.destroy_world(world)
  }
}
