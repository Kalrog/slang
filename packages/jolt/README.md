# Jolt Physics for slang

[Jolt Physics](https://github.com/jrouwe/JoltPhysics), the 3D physics
engine of Horizon Forbidden West and Godot: rigid bodies, shapes (boxes,
spheres, capsules, cylinders, convex hulls, meshes, height fields),
constraints, vehicles, characters, ray and shape casts, multithreaded
simulation. The package reaches Jolt through
[joltc](https://github.com/amerkoleci/joltc), its C API, by `slang/ffi`,
and ships joltc built for macOS and Linux, so there is nothing to install.

```slang
local jolt = require("jolt")

local world = jolt.world({gravity: {0, -9.81, 0}})
world:create_body({shape: jolt.box({50, 1, 50}), position: {0, -1, 0}})
local ball = world:create_body({
  shape: jolt.sphere(0.5), position: {0, 5, 0},
  motion: "dynamic", restitution: 0.5,
})
for(local i = 0; i < 120; i = i + 1){
  world:step(1 / 60)
}
print(ball:get_position(), "\n")
world:destroy()
```

Jolt draws nothing: draw the bodies with raylib (`examples/physics` in the
slang repository does, and `examples/siege` is a whole game on it), or
anything else.

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

Jolt's things are slang values with methods. Each is made from an option
table and keeps its C side out of sight: no pointers, no settings objects
to fill and free.

- **Worlds:** `jolt.world(options)` makes a physics system with what it
  needs: a job system (`threads` worker threads), two object layers
  (`jolt.layers.non_moving` and `.moving`: static bodies do not collide
  with each other) and the broad phase tables. `world:step(dt)` advances
  it, `world:destroy()` frees it with everything in it. Every
  `physics_system_*` function of joltc is a method: `world:get_gravity()`,
  `world:set_gravity(v)`, `world:get_num_bodies()`.
- **Bodies:** `world:create_body(def)` takes `shape`, `position`,
  `rotation`, `motion` (`"static"`, `"kinematic"` or `"dynamic"`), `layer`,
  `activate` and `mass`; any other field names a creation setting, so
  `{friction: 0.2, linear_velocity: {1, 0, 0}}` sets both. It returns a
  `Body`: every `body_interface_*` function of joltc is a method without
  the interface and the id (`body:get_position()`,
  `body:set_linear_velocity(v)`, `body:add_impulse(i)`, `body:activate()`,
  `body:is_active()`), and so is every `body_*` function
  (`body:get_motion_properties()`, `body:is_dynamic()`).
  `body:destroy()` takes it out of the world. `body.id` is Jolt's id, an
  int to key tables by; `world:get_body(id)` finds the body again.
- **Shapes:** `jolt.box(half_extent)`, `jolt.sphere(r)`,
  `jolt.capsule(half_height, r)`, `jolt.cylinder(half_height, r)`,
  `jolt.tapered_capsule`, `jolt.tapered_cylinder`, `jolt.triangle`,
  `jolt.convex_hull(points)`, `jolt.plane`, `jolt.mesh(triangles)`,
  `jolt.height_field(samples, {size, offset, scale})`,
  `jolt.compound(parts)`, `jolt.mutable_compound(parts)`,
  `jolt.scaled(shape, s)`, `jolt.rotated_translated(shape, p, q)`,
  `jolt.offset_center_of_mass(shape, o)` and `jolt.empty()`. An option
  table may follow (`{density: 8000, convex_radius: 0.02}`). A shape's
  `shape_*` functions and those of its kind are methods
  (`shape:get_volume()`, `box:get_half_extent()`, `shape:set_density(d)`);
  one shape can serve many bodies, and it is freed once nothing refers to
  it.
- **Constraints:** `world:create_constraint(def)` with `type` (`"fixed"`,
  `"distance"`, `"point"`, `"hinge"`, `"slider"`, `"cone"`,
  `"swing_twist"`, `"six_dof"` or `"gear"`), `body1`, `body2` (left out:
  the world) and the fields of joltc's settings struct of that kind
  (`point1`, `hinge_axis1`, `limits_min`, ...). The constraint's functions
  are methods (`hinge:set_limits(a, b)`, `hinge:set_motor_state(s)`,
  `c:get_body1()`); `c:destroy()` removes it.
- **Vehicles:** `world:create_vehicle(def)` with the chassis `body`, its
  `wheels` (each the wheel settings' fields: `position`, `radius`, `width`,
  `suspension_min_length`, `suspension_spring`, `max_steer_angle`, ...),
  an `engine`, a `transmission`, `differentials`, `anti_roll_bars`, the
  `collision_tester` and the `controller` kind (`"wheeled"`,
  `"motorcycle"` or `"tracked"`). `vehicle:set_driver_input(forward, right,
  brake, hand_brake)` drives it, `vehicle:get_wheel_world_transform(i)`
  places a wheel, `vehicle.wheels[i]:get_angular_velocity()` and
  `vehicle.controller:get_engine():get_current_rpm()` read it.
- **Characters:** `world:create_character(def)` (on a body of its own) and
  `world:create_character_virtual(def)` (moved by `character:update(dt)`),
  with the fields of joltc's character settings; their functions are
  methods (`get_ground_state()`, `set_linear_velocity(v)`).
- **Queries:** `world:cast_ray(origin, direction)` is the first hit
  (`body`, `fraction`, `point`) or null; `world:collide_point(p)`,
  `world:cast_shape(shape, transform, direction)` and
  `world:collide_shape(shape, transform)` are lists of hits with their
  `body`. `world.narrow_phase` and `world.broad_phase` have the rest of
  joltc's query functions as methods.
- **Contacts:** `jolt.world({contact_events: true})` collects the
  contacts that begin and end in each step, and
  `world:get_contact_events()` returns them after `step`: `added` (each
  with `body1`, `body2`, `normal`, `depth`, `points`, and `velocity1` and
  `velocity2`, the bodies' velocities as they hit) and `removed`;
  `contact_events: "all"` adds `persisted`, the contacts that go on. Jolt
  reports them from its worker threads; slang runs them one at a time.
- **Names** lose joltc's `JPH_` prefix and the type's, and are snake_case:
  `JPH_BodyInterface_GetPosition` is `body:get_position()`,
  `JPH_HingeConstraint_SetLimits` is `hinge:set_limits()`. Struct fields
  too (`maxBodies` is `max_bodies`) and enum values
  (`JPH_MotionType_Dynamic` is `jolt.motion_type_dynamic`). Macros keep
  their case without the prefix: `jolt.DEFAULT_CONVEX_RADIUS`.
- **Structs** are tables, by field name or by position: `{0, 1, 0}` is a
  `Vec3`, `{0, 0, 0, 1}` a `Quat` (x, y, z, w). Results are tables with
  named fields, and results Jolt writes through pointers are returned:
  `body:get_position_and_rotation()` is `{position, rotation}`. Arguments
  Jolt makes optional (filters, `lock_bodies`, an activation) may be left
  out.
- **Math:** `jolt.quat`, `jolt.vec3` and `jolt.mat4` hold Jolt's
  quaternion, vector and matrix functions (`jolt.quat.multiply(a, b)`,
  `jolt.mat4.translation(v)`); `jolt.mat4_to_matrix(m)` turns a Jolt
  matrix into sixteen fields in raylib's `Matrix` layout, for a model's
  `transform`.
- **Memory:** what Jolt hands out is freed once nothing in slang refers to
  it any more (shapes, materials, curves, skeletons). Where Jolt needs an
  order, there is a `destroy` method: bodies, constraints, vehicles and
  characters belong to their world and go with `world:destroy()`.
- **The rest:** materials (`jolt.material`), curves (`jolt.linear_curve`),
  group filters, skeletons, poses, animations and ragdolls have
  constructors and their joltc functions as methods. `jolt.raw` holds every
  joltc function under its snake_case name, on pointers and ids as C has
  them (`jolt.raw.body_interface_get_position(world.body_interface,
  body.id)`), for the corners the objects do not cover: soft bodies, the
  debug renderer, custom filters and listeners. Callbacks given to them
  are slang functions (slang/ffi); Jolt calls them from its worker threads
  during `step`, where they should only read what they are given.

`jolt.decls` holds the declarations, for `slang/ffi`.

The language server and `slang doc` read `stubs/init.slang`, generated
from joltc's header and `init.slang`:

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
names.slang         joltc's names in slang, and which parameters are results
include/joltc.h     joltc's header, read at load
lib/<platform>/     joltc and Jolt, built by tool/build.sh
stubs/init.slang    generated: the API with its docs, for tools
tool/build.sh       builds lib/ and include/
tool/gen_stubs.slang
test/jolt_test.slang
```
