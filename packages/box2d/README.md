# Box2D for slang

[Box2D](https://box2d.org) v3, the 2D physics engine: rigid bodies, shapes
(circles, capsules, polygons, chains), joints, sensors, contact events, ray
and shape casts. The package has no native code. It calls the Box2D
installed on the machine through `slang/ffi`, and it reads Box2D's own
headers when it loads, so it always matches the installed version.

```slang
local b2 = require("box2d")

local world = b2.world({gravity: {0, -10}})
local ground = world:create_body({position: {0, -1}})
ground:create_polygon_shape({}, b2.make_box(50, 1))
local box = world:create_body({type: b2.dynamic_body, position: {0, 4}})
box:create_polygon_shape({density: 1, material: {friction: 0.6}}, b2.make_box(0.5, 0.5))
for(local i = 0; i < 60; i = i + 1){
  world:step(1 / 60, 4)
}
print(box.position, "\n")   // {x: 0.0, y: 0.5}
world:destroy()
```

Box2D draws nothing: draw the bodies with raylib (`examples/physics` in the
slang repository does), or anything else.

## Using it

Install Box2D 3:

- macOS: `brew install box2d`
- Linux: your distribution's box2d package, if it is version 3 (older ones
  are Box2D 2, a C++ library), or build Box2D as a shared library
  (`cmake -DBUILD_SHARED_LIBS=ON`)

`BOX2D_PREFIX` names an installation in an unusual place (the directory
with `include/box2d/box2d.h` and `lib/libbox2d.dylib` or `.so`). Then add
the package to the project's `slang.project`:

```
dependencies: {box2d: {git: "<repository>", version: "^1.0"}}
```

Inside the slang repository, use `{path: "../packages/box2d"}` instead, as
`examples/physics` does. Then run `slang get`.

## In the browser

The website's playground runs programs that use this package on a slang
built with Emscripten with Box2D linked in (`make wasm-gfx`); the package is
the same.

## How Box2D maps to slang

Box2D's things are slang values with methods, made from def tables laid
over Box2D's defaults.

- **Worlds:** `b2.world(def)` makes one (`{gravity: {0, -10}}`);
  `world:step(dt, sub_steps)` advances it, `world:destroy()` frees it with
  everything in it. Every `b2World_*` function is a method or property:
  `world.gravity = g`, `world.awake_body_count`, `world:explode(def)`.
- **Bodies:** `world:create_body(def)` returns a `Body`; every `b2Body_*`
  function is a method or property: `body.position`,
  `body.linear_velocity = v`, `body:apply_force(f, point, wake)`,
  `body.mass`, `body.awake = true`. `body:destroy()` takes it out
  of the world. `body.key` is an int, the same for the same body, to key
  tables by; `world:get_body(key)` finds it again.
- **Shapes:** `body:create_circle_shape(def, circle)`,
  `create_capsule_shape`, `create_polygon_shape(def, polygon)`,
  `create_segment_shape` and `create_chain_segment_shape` make a `Shape`
  on the body (`b2.make_box(hw, hh)`, `b2.make_polygon(hull, radius)`,
  `b2.compute_hull(points)` and the other geometry functions are the
  module's); `body:create_chain(def)` a `Chain`. Every `b2Shape_*`
  function is a method or property: `shape.friction`,
  `shape:test_point(p)`, `shape.sensor_events_enabled = true`;
  `shape.body` is its body.
- **Joints:** `world:create_revolute_joint(def)` (and `distance`, `weld`,
  `prismatic`, `wheel`, `motor`, `mover`, `pogo`, `filter`) take the
  joint's def with `body_a` and `body_b` as the bodies themselves and
  Box2D's base fields (`local_frame_a`, `collide_connected`, ...) flat or
  under `base`. Every `b2Joint_*` function is a method or property, and
  so are those of the joint's kind: `joint.motor_speed = s`,
  `joint.limit_enabled = true`, `joint.body_a`.
- **Properties:** a getter without arguments and a setter of one value
  are one property: `b2Body_GetLinearVelocity` and
  `b2Body_SetLinearVelocity` are `body.linear_velocity`, `IsX`/`SetX` and
  `IsXEnabled`/`EnableX` pairs drop the `is_` (`body.awake`,
  `joint.limit_enabled`), `IsEnabled` with `Enable`/`Disable` is
  `body.enabled`. A property without a setter raises when assigned;
  getters and setters that take more arguments stay methods. Box2D has no
  setter of a body's position alone: assigning `body.position` or
  `body.rotation` calls `b2Body_SetTransform`.
- **Names** lose Box2D's `b2` prefix and the type's, and are snake_case:
  `b2World_Step` is `world:step()`, `b2Body_GetPosition`
  `body.position`, `b2DefaultShapeDef` `b2.default_shape_def()`.
  Struct fields too (`linearVelocity` is `linear_velocity`) and enum
  values (`b2_dynamicBody` is `b2.dynamic_body`). Macros keep their case
  without the prefix: `B2_DEFAULT_CATEGORY_BITS` is
  `b2.DEFAULT_CATEGORY_BITS`.
- **Structs** are tables, read by field name or by position, so `{x: 1,
  y: 2}` and `{1, 2}` are the same `b2Vec2`. Results are tables with named
  fields, and ids in them are the objects: a ray result's `shape`, a
  contact's `shape_a` and `shape_b`.
- **Defs** are laid over Box2D's defaults: `world:create_body({type:
  b2.dynamic_body})` starts from `b2DefaultBodyDef()` and changes only
  `type`. Nested tables work the same way (`{material: {friction: 0.2}}`
  keeps the material's other defaults), a def left out is the default, and
  a field the def does not have is an error. So is a query filter left
  out: `world:cast_ray_closest(origin, translation)`.
- **Events** are lists of objects: `world:contact_events().begin_events`
  (each with `shape_a` and `shape_b`), and the same for sensor
  (`sensor_shape`, `visitor_shape`), body move (`body`) and joint
  (`joint`) events. Read them after each `step`.
- **Arrays Box2D fills** are lists: `body:shapes()`,
  `body:joints()`, `body:contact_data()`,
  `shape:contact_data()`, `shape:sensor_data()`,
  `chain:segments()`.
- **The header's helpers** (Box2D defines its vector math inline, so it is
  not in the library) are the module's: `b2.make_rot`,
  `b2.rot_get_angle`, `b2.rotate_vector`, `b2.transform_point`, `b2.add`,
  `b2.sub`, `b2.mul_sv`, `b2.length`, `b2.normalize`, `b2.dot`,
  `b2.cross`, `b2.aabb_center`, ... and so are the library's free
  functions (`b2.make_box`, `b2.compute_hull`, `b2.default_body_def`,
  `b2.is_valid_vec2`).
- **Callbacks** are slang functions that see objects: the callback forms
  of the queries (`world:overlap_aabb`, `world:cast_ray` with a function
  that sees every hit's shape), custom filters
  (`world:set_custom_filter_callback`), pre-solve, and debug draw, whose
  def is a table of functions:

  ```slang
  world:draw({
    draw_shapes: true,
    draw_solid_polygon_fcn: func(transform, vertices, count, radius, color, context){
      ...   // vertices[0] .. vertices[count - 1], in the body's frame
    },
  })
  ```

  Define such functions once, not inside the frame loop: each function
  given to C stays a C callback for good (slang/ffi stops at 1000).
- **Memory:** Box2D's ids are values that only mean something while their
  world lives, so there is nothing for the collector to free: bodies,
  shapes and joints go with `destroy()` or with their world.
- **C names:** `b2.c` holds every Box2D function and constant under its C
  name, on the id structs as C has them (`b2.c.b2Body_GetPosition(
  body.id)`, `b2.c.b2_dynamicBody`), for whoever knows Box2D's API;
  `b2.raw` holds the same functions under snake_case names with defs laid
  over their defaults. `b2.body_of(id)`,
  `b2.shape_of(id)` and `b2.joint_of(id)` turn a raw id back into the
  object; `b2.store_body_id(id)` is its key, `b2.is_null(id)` and
  `b2.id_equals(a, b)` are Box2D's `B2_IS_NULL` and `B2_ID_EQUALS`. User
  data pointers cannot hold slang values; put fields on the object instead
  (`body.thing = ...`: the same body is always the same table).

`b2.decls` holds the declarations, for `slang/ffi`.

The language server and `slang doc` read `stubs/init.slang`, generated
from the installed headers and `init.slang`:

```
slang run tool/gen_stubs.slang     # after Box2D or the package changes
slang test test                    # the binding, no window
```

```
init.slang          require("box2d"): finds Box2D, reads its headers, binds
names.slang         Box2D's names in slang
stubs/init.slang    generated: the API with its docs, for tools
tool/gen_stubs.slang
test/box2d_test.slang
```
