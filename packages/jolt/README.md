# Jolt Physics for slang

[Jolt Physics](https://github.com/jrouwe/JoltPhysics), the 3D physics
engine of Horizon Forbidden West and Godot: rigid bodies, shapes (boxes,
spheres, capsules, cylinders, convex hulls, meshes, height fields),
constraints, characters, ray and shape casts, multithreaded simulation. The
package reaches Jolt through [joltc](https://github.com/amerkoleci/joltc),
its C API, by `slang/ffi`, and ships joltc built for macOS and Linux, so
there is nothing to install.

```slang
local jolt = require("jolt")

local world = jolt.create_world({gravity: {0, -9.81, 0}})
jolt.create_body(world, {
  shape: jolt.box_shape_create({50, 1, 50}), position: {0, -1, 0},
})
local ball = jolt.create_body(world, {
  shape: jolt.sphere_shape_create(0.5), position: {0, 5, 0},
  motion: "dynamic", restitution: 0.5,
})
for(local i = 0; i < 120; i = i + 1){
  jolt.step(world, 1 / 60)
}
print(jolt.body_interface_get_position(world.bodies, ball), "\n")
jolt.destroy_world(world)
```

Jolt draws nothing: draw the bodies with raylib (`examples/physics` in the
slang repository does), or anything else.

## Using it

Add the package to the project's `slang.project`:

```
dependencies: {jolt: {git: "<repository>", version: "^1.0"}}
```

Inside the slang repository, use `{path: "../packages/jolt"}` instead, as
`examples/physics` does. Then run `slang get`.

The package carries `lib/<platform>/libjoltc` for macos-aarch64,
macos-x86_64, linux-x86_64 and linux-aarch64 (glibc 2.28 or newer), about
1.7 MB each; `lib/VERSION` names the Jolt and joltc versions. `JOLT_PREFIX`
names another build (a directory with `include/joltc.h` and
`lib/libjoltc.*`).

## In the browser

The website's playground runs programs that use this package on a slang
built with Emscripten with Jolt and joltc linked in (`make wasm-gfx`); the
package is the same. A page has no threads, so there Jolt runs its jobs on
the program's thread.

## How Jolt maps to slang

- **Worlds:** `create_world(options)` makes a physics system with what it
  needs: a job system (worker threads), two object layers
  (`jolt.layers.non_moving` and `.moving`: static bodies do not collide
  with each other), the broad phase tables. The world it returns has the
  body interface as `world.bodies` and the queries as
  `world.narrow_phase` and `world.broad_phase`. `step(world, dt)` advances
  it; `destroy_world(world)` frees it.
- **Bodies:** `create_body(world, def)` takes `shape`, `position`,
  `rotation`, `motion` (`"static"`, `"kinematic"` or `"dynamic"`), `layer`
  and `activate`; any other field calls the creation settings' setter of
  that name, so `{friction: 0.2, linear_velocity: {1, 0, 0}}` calls
  `body_creation_settings_set_friction` and
  `body_creation_settings_set_linear_velocity`. It returns the body's id,
  an int, which the `body_interface_*` functions take and tables can be
  keyed by.
- **Names** lose joltc's `JPH_` prefix and are snake_case:
  `JPH_BodyInterface_GetPosition` is `body_interface_get_position`. Struct
  fields too (`maxBodies` is `max_bodies`) and enum values
  (`JPH_MotionType_Dynamic` is `motion_type_dynamic`). Macros keep their
  case without the prefix: `DEFAULT_CONVEX_RADIUS`.
- **Structs** are tables, by field name or by position: `{0, 1, 0}` is a
  `Vec3`, `{0, 0, 0, 1}` a `Quat` (x, y, z, w). Results are tables with
  named fields.
- **Results Jolt writes through pointers are returned.** Leave the result
  argument out: `body_interface_get_position(bodies, id)` returns the
  `Vec3` that `JPH_BodyInterface_GetPosition` writes. Several results come
  back as a table by parameter name (`get_position_and_rotation` returns
  `{position, rotation}`). A function that returns whether it found
  something returns the result or null: `narrow_phase_query_cast_ray(
  world.narrow_phase, origin, direction)` is the hit (`body_id`,
  `fraction`) or null. Arguments after a result, such as the optional
  filters, may be left out.
- **Shapes** are pointers, made by `*_shape_create` (`box_shape_create`
  takes Jolt's default convex radius when it is left out). A body holds on
  to its shape; one shape can serve many bodies.
- **Drawing:** `body_interface_get_world_transform(bodies, id)` is the
  body's matrix; `mat4_to_matrix(m)` turns it into sixteen fields in
  raylib's `Matrix` layout, for a model's `transform`.
- **Contacts:** `create_world({contact_events: true})` collects the
  contacts that begin and end in each step, and
  `world_get_contact_events(world)` returns them after `step`: `added`
  (each with `body1`, `body2`, `normal`, `depth`, `points`, and
  `velocity1` and `velocity2`, the bodies' velocities as they hit) and
  `removed` (`body1`, `body2`); `contact_events: "all"` adds `persisted`,
  the contacts that go on. Jolt reports them from its worker threads; slang
  runs them one at a time.
- **Callbacks** in general are slang functions (slang/ffi): the other
  listeners, the callback forms of the queries, custom filters. Jolt calls
  them from its worker threads during `step`; there they should only read
  what they are given, since a Jolt call that waits for another thread
  would wait forever. joltc keeps the procs tables it is given
  (`contact_listener_set_procs`): make them with `ffi.new` and keep them,
  as the package does for contact events.

`jolt.decls` holds the declarations, for `slang/ffi`:
`ffi.new("JPH_Vec3", 8, jolt.decls)`.

The language server and `slang doc` read `stubs/init.slang`, generated
from joltc's header:

```
slang run tool/gen_stubs.slang     # after joltc or the package changes
slang test test                    # the binding, no window
tool/build.sh [platform...]        # rebuild lib/: pinned, checked sources
```

`tool/build.sh` needs cmake and ninja; Linux builds are cross-compiled with
`zig c++` (`ZIG` names zig). x86_64 builds target SSE4.2 without AVX, so
they run on any x86_64 CPU of the last 15 years.

```
init.slang          require("jolt"): finds joltc, reads its header, binds
names.slang         joltc's names in slang
include/joltc.h     joltc's header, read at load
lib/<platform>/     joltc and Jolt, built by tool/build.sh
stubs/init.slang    generated: declarations and docs for tools
tool/build.sh       builds lib/ and include/
tool/gen_stubs.slang
test/jolt_test.slang
```
