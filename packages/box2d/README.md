# Box2D for slang

[Box2D](https://box2d.org) v3, the 2D physics engine: rigid bodies, shapes
(circles, capsules, polygons, chains), joints, sensors, contact events, ray
and shape casts. The package has no native code. It calls the Box2D
installed on the machine through `slang/ffi`, and it reads Box2D's own
headers when it loads, so it always matches the installed version.

```slang
local b2 = require("box2d")

local world = b2.create_world({gravity: {0, -10}})
local ground = b2.create_body(world, {position: {0, -1}})
b2.create_polygon_shape(ground, {}, b2.make_box(50, 1))
local box = b2.create_body(world, {type: b2.dynamic_body, position: {0, 4}})
b2.create_polygon_shape(box, {density: 1, material: {friction: 0.6}}, b2.make_box(0.5, 0.5))
for(local i = 0; i < 60; i = i + 1){
  b2.world_step(world, 1 / 60, 4)
}
print(b2.body_get_position(box), "\n")   // {x: 0.0, y: 0.5}
b2.destroy_world(world)
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

## How Box2D maps to slang

- **Names** lose Box2D's `b2` prefix and are snake_case: `b2World_Step` is
  `world_step`, `b2Body_GetPosition` `body_get_position`,
  `b2DefaultShapeDef` `default_shape_def`. Struct fields too
  (`linearVelocity` is `linear_velocity`) and enum values
  (`b2_dynamicBody` is `dynamic_body`). Macros keep their case without the
  prefix: `B2_DEFAULT_CATEGORY_BITS` is `DEFAULT_CATEGORY_BITS`.
- **Structs** are tables, read by field name or by position, so `{x: 1,
  y: 2}` and `{1, 2}` are the same `b2Vec2`. Results are tables with named
  fields. Ids (`b2BodyId`, `b2ShapeId`, ...) are small tables too.
- **Defs** are laid over Box2D's defaults: `create_body(world, {type:
  b2.dynamic_body})` starts from `b2DefaultBodyDef()` and changes only
  `type`. Nested tables work the same way (`{material: {friction: 0.2}}`
  keeps the material's other defaults), and a def left out is the default.
  So is a query filter left out: `world_cast_ray_closest(world, origin,
  translation)`.
- **Events** are lists: `world_get_contact_events(world).begin_events`, and
  the same for sensor, body move and joint events. Read them after each
  `world_step`.
- **Arrays Box2D fills** are lists: `body_get_shapes`, `body_get_joints`,
  `body_get_contact_data`, `shape_get_contact_data`,
  `shape_get_sensor_data`, `chain_get_segments`.
- **The header's helpers** (Box2D defines its vector math and id functions
  inline, so they are not in the library) are written in slang under the
  same names: `make_rot`, `rot_get_angle`, `rotate_vector`,
  `transform_point`, `add`, `sub`, `mul_sv`, `length`, `normalize`,
  `dot`, `cross`, `aabb_center`, ... Calling one that is not there names it.
- **Ids as keys:** `store_body_id(id)` is an int, the same for the same
  body, for tables keyed by body: `things[b2.store_body_id(id)] = thing`.
  `is_null(id)` and `id_equals(a, b)` are Box2D's `B2_IS_NULL` and
  `B2_ID_EQUALS`. User data pointers cannot hold slang values; key a table
  by id instead.
- **Not bound:** callbacks (custom filters, the callback forms of the
  queries, debug draw), which slang/ffi does not support yet. Every query
  has a callback-free form or a sensor that does the same job.

`b2.decls` holds the declarations, for `slang/ffi`: `ffi.new("b2Vec2", 8,
b2.decls)`.

The language server and `slang doc` read `stubs/init.slang`, generated
from the installed headers with Box2D's docs:

```
slang run tool/gen_stubs.slang     # after Box2D or the package changes
slang test test                    # the binding, no window
```

```
init.slang          require("box2d"): finds Box2D, reads its headers, binds
names.slang         Box2D's names in slang
stubs/init.slang    generated: declarations and docs for tools
tool/gen_stubs.slang
test/box2d_test.slang
```
