# raylib for slang

All of [raylib](https://www.raylib.com) and raymath: windows and input,
2D and 3D drawing, textures and images, fonts and text, models and
animations, shaders, audio, and the vector/matrix/quaternion math. The
package has no native code. It calls the raylib installed on the machine
through `slang/ffi`, and it reads raylib's own headers when it loads (about
0.1 s), so it always matches the installed version.

```slang
local rl = require("raylib")

rl.init_window(800, 450, "hello")
rl.set_target_fps(60)
local camera = {offset: {400, 225}, target: {0, 0}, rotation: 0, zoom: 1}
for(not rl.window_should_close()){
  rl.begin_drawing()
  rl.clear_background(rl.RAYWHITE)
  rl.begin_mode_2d(camera)
  rl.draw_circle_v(rl.get_screen_to_world_2d(rl.get_mouse_position(), camera), 20, rl.MAROON)
  rl.end_mode_2d()
  rl.draw_text(rl.text_format("%d fps", rl.get_fps()), 10, 10, 20, rl.DARKGRAY)
  rl.end_drawing()
}
rl.close_window()
```

## Using it

Install raylib:

- macOS: `brew install raylib`
- Debian/Ubuntu: `apt install libraylib-dev`
- elsewhere: build raylib as a shared library

`RAYLIB_PREFIX` names an installation in an unusual place (the directory
with `include/raylib.h` and `lib/libraylib.dylib` or `.so`). Then add the
package to the project's `slang.project`:

```
dependencies: {raylib: {git: "<repository>", version: "^1.0"}}
```

Inside the slang repository, use `{path: "../packages/raylib"}` instead, as
`examples/breakout` does. Then run `slang get`.

## How raylib maps to slang

- **Names** are snake_case: `DrawTextEx` is `draw_text_ex`, `BeginMode2D`
  `begin_mode_2d`, `Vector2Add` `vector2_add`, and struct fields too
  (`offsetX` is `offset_x`). Constants and colors keep their names:
  `rl.KEY_SPACE`, `rl.FLAG_WINDOW_RESIZABLE`, `rl.RAYWHITE`, `rl.PI`.
- **Structs** are tables, read by field name or by position, so
  `{x: 1, y: 2}` and `{1, 2}` are the same `Vector2`. A color's alpha
  defaults to 255. Results are tables with named fields. This includes
  structs that own memory (`Image`, `Model`, `Shader`, `Sound`, ...): they
  are values, as in C, and are freed with their `unload_*` function.
- **Pointer fields** reach into raylib's memory and write it in place, as in
  C:
  - `model.materials[0].maps[rl.MATERIAL_MAP_ALBEDO].texture = tex`
  - `shader.locs[rl.SHADER_LOC_VECTOR_VIEW] = loc`
- **Pointer parameters:**
  - A list and its count are one argument: `draw_triangle_strip(points,
    color)`, `load_image_from_memory(".png", bytes)` with the bytes as a
    string.
  - `T *value` takes a table that raylib updates:
    `update_camera(camera, rl.CAMERA_ORBITAL)` moves `camera`, and
    `image_resize(img, w, h)` changes `img`.
- **Strings** raylib allocates (`text_replace`, `load_file_text`) come back
  as slang strings. Directory listings are lists of strings. `text_format`
  and `trace_log` take their arguments as in C (`trace_log` takes plain
  text).
- **Written by hand:**
  - `set_shader_value` and `set_shader_value_v` take numbers, lists or
    vector tables.
  - `load_image_colors` returns a list of colors.
  - `get_image_data` returns an image's pixels as a string.
  - `load_model_animations` returns a list of animations.
- **Not bound:** callbacks (`SetTraceLogCallback`, the audio stream
  callbacks), which slang/ffi does not support yet.

- **Buffers** (`slang/buffer`) go where lists go, as their memory with no
  conversion: `draw_triangle_strip(points, color)` with `points` a buffer
  of `Vector2`. `examples/terrain.slang` builds a mesh in buffers and
  uploads it.

`rl.decls` holds the declarations, for `slang/ffi` and `slang/buffer`:

```slang
local ffi = require("slang/ffi")
local buffer = require("slang/buffer")
local points = buffer.new("Vector2", 100, rl.decls)
local pixels = ffi.cast(image.data, "Color", rl.decls)
```

Wrong arguments are slang errors that say what was expected, for example
`bad argument #1 to 'check_collision_recs' (Rectangle expected, got string)`.
A wrong *value*, such as a texture that was already unloaded, crashes as it
would in C.

The language server and `slang doc` read `stubs/init.slang`. It declares
every function with raylib's description and its C signature, and
`tool/gen_stubs.slang` generates it from the installed headers:

```
slang run tool/gen_stubs.slang     # after raylib or the package changes
slang test test                    # the binding without a window
```

```
init.slang          require("raylib"): finds raylib, reads its headers, binds
names.slang         raylib's names in slang (snake_case)
stubs/init.slang    generated: declarations and docs for tools
tool/gen_stubs.slang
test/raylib_test.slang
examples/terrain.slang  a mesh built in slang buffers
```
