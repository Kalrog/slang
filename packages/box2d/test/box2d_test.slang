// The binding without a window: worlds, bodies and shapes as objects,
// defs over Box2D's defaults, joints, events, arrays, queries, callbacks
// and the header's helpers (run with `slang test test` in packages/box2d)
local t = require("slang/test")
local math = require("slang/math")
local b2 = require("box2d")

local func near(a, b, eps){
  eps = eps or 0.001
  return a - b < eps and b - a < eps
}

// a world with ground at y = 0 (its top) and a 1x1 box above it
local func scene(def){
  local world = b2.world(def or {})
  local ground = world:create_body({position: {0, -1}})
  ground:create_polygon_shape({}, b2.make_box(50, 1))
  local box = world:create_body({type: b2.dynamic_body, position: {0, 4}})
  local shape = box:create_polygon_shape(
    {density: 1, enable_contact_events: true},
    b2.make_box(0.5, 0.5),
  )
  return {world: world, ground: ground, box: box, shape: shape}
}

local func run(world, steps){
  for(local i = 0; i < steps; i = i + 1){
    world:step(1 / 60, 4)
  }
}

t.group("box2d: worlds and bodies"){
  t.test("a box falls and rests on the ground"){
    local s = scene()
    assert(type(s.world) == "box2d.World" and type(s.box) == "box2d.Body")
    assert(type(s.shape) == "box2d.Shape" and s.shape.body == s.box)
    run(s.world, 120)
    local p = s.box.position
    assert(near(p.x, 0, 0.02) and near(p.y, 0.5, 0.02), p)
    assert(near(b2.rot_get_angle(s.box.rotation), 0))
    assert(s.box.world == s.world and s.shape.body == s.box)
    s.world:destroy()
  }
  t.test("a def is laid over the defaults, nested tables too"){
    local s = scene({gravity: {0, 0}})
    assert(s.world.gravity.y == 0)
    run(s.world, 30)
    // no gravity: the box stays where it was made
    assert(near(s.box.position.y, 4))
    local body = s.world:create_body({
      type: b2.dynamic_body,
      linear_velocity: {2, 0},
      gravity_scale: 0,
    })
    assert(body.linear_velocity.x == 2)
    local shape = body:create_circle_shape({material: {friction: 0.25}}, {
      center: {0, 0}, radius: 0.5
    })
    assert(near(shape.friction, 0.25))
    // the rest of the material keeps its defaults
    assert(shape.restitution == 0)
    local r = pcall(s.world.create_body, s.world, {bounciness: 1})
    assert(r[0] == "err" and r[1].message == "box2d.create_body: b2BodyDef has no field bounciness",
      r[1].message)
    s.world:destroy()
  }
  t.test("destroying, keys and finding things again"){
    local s = scene()
    assert(s.world:get_body(s.box.key) == s.box)
    assert(s.world:get_shape(s.shape.key) == s.shape)
    assert(s.box.valid)
    s.box:destroy()
    assert(not s.box.valid)
    assert(s.world:get_body(s.box.key) == null)
    assert(s.world.awake_body_count == 0)
    s.world:destroy()
    assert(s.world.id == null)
  }
  t.test("enum values, macros and the version"){
    assert(b2.static_body == 0 and b2.dynamic_body == 2)
    assert(type(b2.version) == "string")
    assert(b2.default_body_def().type == b2.static_body)
    assert(b2.body_get_position == null)
  }
}

t.group("box2d: joints"){
  t.test("a revolute joint holds a pendulum, bodies given as themselves"){
    local s = scene({gravity: {0, -10}})
    local bob = s.world:create_body({type: b2.dynamic_body, position: {3, 4}})
    bob:create_circle_shape({density: 1}, {center: {0, 0}, radius: 0.25})
    local joint = s.world:create_revolute_joint({
      body_a: s.ground, body_b: bob,
      local_frame_a: {p: {0, 5}, q: b2.make_rot(0)},
      local_frame_b: {p: {-3, 0}, q: b2.make_rot(0)},
      enable_limit: true, lower_angle: -1, upper_angle: 1,
    })
    assert(type(joint) == "box2d.Joint" and joint.kind == "revolute")
    assert(joint.body_a == s.ground and joint.body_b == bob)
    assert(joint.limit_enabled and near(joint.upper_limit, 1))
    run(s.world, 120)
    // swinging on a 3 m arm: still about 3 m from the pivot
    assert(near(b2.distance(bob.position, {0, 4}), 3, 0.05), bob.position)
    local joints = bob:joints()
    assert(len(joints) == 1 and joints[0] == joint)
    joint:destroy()
    assert(len(bob:joints()) == 0)
    local rope = s.world:create_distance_joint({
      body_a: s.ground, body_b: bob, length: 2, enable_spring: true, hertz: 2,
    })
    assert(rope.kind == "distance" and near(rope.rest_length, 2))
    s.world:destroy()
  }
}

t.group("box2d: events and arrays are lists of objects"){
  t.test("contact events of the last step"){
    local s = scene()
    local began = 0
    for(local i = 0; i < 120; i = i + 1){
      s.world:step(1 / 60, 4)
      local ev = s.world:contact_events()
      began = began + len(ev.begin_events)
      for(let local e in values(ev.begin_events)){
        assert(e.shape_a == s.shape or e.shape_b == s.shape)
        assert(e.shape_id_a == null)
      }
    }
    assert(began == 1, began)
    local moved = s.world:body_events().move_events
    assert(len(moved) >= 0)
    s.world:destroy()
  }
  t.test("a body's shapes and contacts"){
    local s = scene()
    run(s.world, 120)
    local shapes = s.box:shapes()
    assert(len(shapes) == 1 and shapes[0] == s.shape)
    local contacts = s.box:contact_data()
    assert(len(contacts) == 1)
    assert(contacts[0].manifold.point_count == 2)
    assert(contacts[0].shape_a == s.shape or contacts[0].shape_b == s.shape)
    s.world:destroy()
  }
}

t.group("box2d: queries"){
  t.test("a ray hits the box (the filter left out is the default)"){
    local s = scene()
    local hit = s.world:cast_ray_closest({0, 10}, {0, -20})
    assert(hit.hit and hit.shape == s.shape)
    assert(near(hit.point.y, 4.5))
    local miss = s.world:cast_ray_closest({5, 10}, {0, 5})
    assert(not miss.hit and miss.shape == null)
    assert(s.shape:test_point({0, 4}) and not s.shape:test_point({2, 4}))
    s.world:destroy()
  }
}

t.group("box2d: the header's helpers"){
  t.test("vectors and rotations"){
    assert(b2.dot({1, 2}, {3, 4}) == 11 and b2.cross({1, 0}, {0, 1}) == 1)
    local q = b2.make_rot(math.pi / 2)
    local v = b2.rotate_vector(q, {1, 0})
    assert(near(v.x, 0) and near(v.y, 1))
    local back = b2.inv_rotate_vector(q, v)
    assert(near(back.x, 1) and near(back.y, 0))
    assert(near(b2.rot_get_angle(q), math.pi / 2))
    assert(near(b2.length(b2.normalize({3, 4})), 1))
    local p = b2.transform_point({p: {1, 1}, q: q}, {1, 0})
    assert(near(p.x, 1) and near(p.y, 2))
    assert(b2.make_box(1, 2).count == 4)
  }
  t.test("raw ids and the raw layer"){
    local s = scene()
    local key = b2.store_body_id(s.box.id)
    assert(key == s.box.key)
    local id = b2.load_body_id(key)
    assert(b2.id_equals(id, s.box) and b2.body_of(id) == s.box)
    assert(not b2.is_null(s.box.id) and b2.is_null({index1: 0}))
    local p = b2.raw.body_get_position(s.box.id)
    assert(near(p.y, 4))
    assert(b2.raw.no_such_function == null)
    s.world:destroy()
  }
}

t.group("box2d: callbacks see objects"){
  t.test("an overlap query calls back for each shape"){
    local s = scene()
    local found = {}
    s.world:overlap_aabb(
      {0, 0},
      {lower_bound: {-1, 3}, upper_bound: {1, 5}},
      null,
      func(shape, context){
        append(found, shape)
        return true
      },
      null,
    )
    assert(len(found) == 1 and found[0] == s.shape)
    s.world:destroy()
  }
  t.test("a ray cast collects every hit along the ray"){
    local s = scene()
    local hits = {}
    s.world:cast_ray(
      {0, 10},
      {0, -20},
      null,
      func(shape, point, normal, fraction, context){
        append(hits, shape)
        // go on: report every shape, not the closest only
        return 1
      },
      null,
    )
    // the box and the ground
    assert(len(hits) == 2, len(hits))
    assert(hits[0] == s.shape or hits[1] == s.shape)
    s.world:destroy()
  }
  t.test("a custom filter decides what collides"){
    local s = scene()
    local asked = 0
    s.world:set_custom_filter_callback(func(a, b, context){
      asked = asked + 1
      assert(type(a) == "box2d.Shape")
      return false
    }, null)
    local box = s.world:create_body({
      type: b2.dynamic_body,
      position: {3, 2},
    })
    box:create_polygon_shape(
      {density: 1, enable_custom_filtering: true},
      b2.make_box(0.5, 0.5),
    )
    run(s.world, 120)
    // the filter said no: it fell through the ground
    assert(asked > 0 and box.position.y < -5)
    s.world:destroy()
  }
  t.test("debug draw: a def of functions"){
    local s = scene()
    local polygons = 0
    s.world:draw({
      draw_shapes: true,
      draw_solid_polygon_fcn: func(
        transform, vertices, count, radius, color, context
      ){
        polygons = polygons + 1
        assert(count == 4 and vertices[3] != null)
      },
    })
    assert(polygons == 2, polygons)
    s.world:destroy()
  }
}
