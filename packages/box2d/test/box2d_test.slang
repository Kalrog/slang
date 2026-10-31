// The binding without a window: worlds and bodies, defs over Box2D's
// defaults, events, arrays, queries and the header's helpers (run with
// `slang test test` in packages/box2d)
local t = require("slang/test")
local math = require("slang/math")
local b2 = require("box2d")

local func near(a, b, eps){
  eps = eps or 0.001
  return a - b < eps and b - a < eps
}

// a world with ground at y = 0 (its top) and a 1x1 box above it
local func scene(def){
  local world = b2 .create_world(def or {})
  local ground = b2 .create_body(world, {position: {0, -1}})
  b2 .create_polygon_shape(ground, {}, b2 .make_box(50, 1))
  local box = b2 .create_body(world, {type: b2 .dynamic_body, position: {0, 4}})
  local shape = b2 .create_polygon_shape(
    box,
    {density: 1, enable_contact_events: true},
    b2 .make_box(0.5, 0.5),
  )
  return {world: world, ground: ground, box: box, shape: shape}
}

local func run(world, steps){
  for(local i = 0; i < steps; i = i + 1){
    b2 .world_step(world, 1 / 60, 4)
  }
}

t.group("box2d: worlds and bodies"){
  t.test("a box falls and rests on the ground"){
    local s = scene()
    run(s.world, 120)
    local p = b2 .body_get_position(s.box)
    assert(near(p.x, 0, 0.02) and near(p.y, 0.5, 0.02), p)
    assert(near(b2 .rot_get_angle(b2 .body_get_rotation(s.box)), 0))
    b2 .destroy_world(s.world)
  }
  t.test("a def is laid over the defaults, nested tables too"){
    local s = scene({gravity: {0, 0}})
    assert(b2 .world_get_gravity(s.world).y == 0)
    run(s.world, 30)
    // no gravity: the box stays where it was made
    assert(near(b2 .body_get_position(s.box).y, 4))
    local body = b2 .create_body(s.world, {
      type: b2 .dynamic_body,
      linear_velocity: {2, 0},
      gravity_scale: 0,
    })
    assert(b2 .body_get_linear_velocity(body).x == 2)
    local shape = b2 .create_circle_shape(body, {material: {friction: 0.25}}, {
      center: {0, 0}, radius: 0.5
    })
    assert(near(b2 .shape_get_friction(shape), 0.25))
    // the rest of the material keeps its defaults
    assert(b2 .shape_get_restitution(shape) == 0)
    b2 .destroy_world(s.world)
  }
  t.test("enum values and macros"){
    assert(b2 .static_body == 0 and b2 .dynamic_body == 2)
    assert(type(b2 .version) == "string")
    assert(b2 .default_body_def().type == b2 .static_body)
  }
}

t.group("box2d: events and arrays are lists"){
  t.test("contact events of the last step"){
    local s = scene()
    local began = 0
    for(local i = 0; i < 120; i = i + 1){
      b2 .world_step(s.world, 1 / 60, 4)
      local ev = b2 .world_get_contact_events(s.world)
      began = began + len(ev.begin_events)
      for(let local e in values(ev.begin_events)){
        assert(
          b2 .id_equals(e.shape_id_a, s.shape) or
            b2 .id_equals(e.shape_id_b, s.shape),
        )
      }
    }
    assert(began == 1, began)
    b2 .destroy_world(s.world)
  }
  t.test("a body's shapes and contacts"){
    local s = scene()
    run(s.world, 120)
    local shapes = b2 .body_get_shapes(s.box)
    assert(len(shapes) == 1 and b2 .id_equals(shapes[0], s.shape))
    local contacts = b2 .body_get_contact_data(s.box)
    assert(len(contacts) == 1)
    assert(contacts[0].manifold.point_count == 2)
    b2 .destroy_world(s.world)
  }
}

t.group("box2d: queries"){
  t.test("a ray hits the box (the filter left out is the default)"){
    local s = scene()
    local hit = b2 .world_cast_ray_closest(s.world, {0, 10}, {0, -20})
    assert(hit.hit and b2 .id_equals(hit.shape_id, s.shape))
    assert(near(hit.point.y, 4.5))
    local miss = b2 .world_cast_ray_closest(s.world, {5, 10}, {0, 5})
    assert(not miss.hit)
    b2 .destroy_world(s.world)
  }
}

t.group("box2d: the header's helpers"){
  t.test("vectors and rotations"){
    assert(b2 .dot({1, 2}, {3, 4}) == 11 and b2 .cross({1, 0}, {0, 1}) == 1)
    local q = b2 .make_rot(math.pi / 2)
    local v = b2 .rotate_vector(q, {1, 0})
    assert(near(v.x, 0) and near(v.y, 1))
    local back = b2 .inv_rotate_vector(q, v)
    assert(near(back.x, 1) and near(back.y, 0))
    assert(near(b2 .rot_get_angle(q), math.pi / 2))
    assert(near(b2 .length(b2 .normalize({3, 4})), 1))
    local p = b2 .transform_point({p: {1, 1}, q: q}, {1, 0})
    assert(near(p.x, 1) and near(p.y, 2))
  }
  t.test("ids as table keys"){
    local s = scene()
    local key = b2 .store_body_id(s.box)
    local id = b2 .load_body_id(key)
    assert(b2 .id_equals(id, s.box) and b2 .body_is_valid(id))
    local by_body = {[key]: "box"}
    assert(by_body[b2 .store_body_id(s.box)] == "box")
    assert(not b2 .is_null(s.box) and b2 .is_null({index1: 0}))
    b2 .destroy_world(s.world)
  }
}

t.group("box2d: callbacks"){
  t.test("an overlap query calls back for each shape"){
    local s = scene()
    local found = {}
    b2 .world_overlap_aabb(
      s.world,
      {0, 0},
      {lower_bound: {-1, 3}, upper_bound: {1, 5}},
      null,
      func(shape, context){
        append(found, shape)
        return true
      },
      null,
    )
    assert(len(found) == 1 and b2 .id_equals(found[0], s.shape))
    b2 .destroy_world(s.world)
  }
  t.test("a ray cast collects every hit along the ray"){
    local s = scene()
    local hits = {}
    b2 .world_cast_ray(
      s.world,
      {0, 10},
      {0, -20},
      null,
      func(shape, point, normal, fraction, context){
        append(hits, fraction)
        // go on: report every shape, not the closest only
        return 1
      },
      null,
    )
    // the box and the ground
    assert(len(hits) == 2, len(hits))
    b2 .destroy_world(s.world)
  }
  t.test("a custom filter decides what collides"){
    local s = scene()
    local asked = 0
    b2 .world_set_custom_filter_callback(s.world, func(a, b, context){
      asked = asked + 1
      return false
    }, null)
    local box = b2 .create_body(s.world, {
      type: b2 .dynamic_body,
      position: {3, 2},
    })
    b2 .create_polygon_shape(
      box,
      {density: 1, enable_custom_filtering: true},
      b2 .make_box(0.5, 0.5),
    )
    for(local i = 0; i < 120; i = i + 1){
      b2 .world_step(s.world, 1 / 60, 4)
    }
    // the filter said no: it fell through the ground
    assert(asked > 0 and b2 .body_get_position(box).y < -5)
    b2 .destroy_world(s.world)
  }
  t.test("debug draw: a def of functions"){
    local s = scene()
    local polygons = 0
    b2 .world_draw(s.world, {
      draw_shapes: true,
      draw_solid_polygon_fcn: func(
        transform, vertices, count, radius, color, context
      ){
        polygons = polygons + 1
        assert(count == 4 and vertices[3] != null)
      },
    })
    assert(polygons == 2, polygons)
    b2 .destroy_world(s.world)
  }
}
