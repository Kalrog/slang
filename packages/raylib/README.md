# raylib for slang

All of [raylib](https://www.raylib.com) and raymath: windows and input,
2D and 3D drawing, textures and images, fonts and text, models and
animations, shaders, audio, and the vector/matrix/quaternion math. The
package has no native code. It calls the raylib installed on the machine
through `slang/ffi`, and it reads raylib's own headers when it loads (about
0.1 s), so it always matches the installed version.

```slang
local rl = require("raylib")

rl.init_window({width: 800, height: 450, title: "hello", fps: 60})
local camera = rl.camera_2d({offset: {400, 225}})
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

## Audio computed in slang: raylib/stream

`require("raylib/stream")` plays sound computed in slang in isolates of its
own (`slang/isolate`), so the program's frames, its collector and raylib's
audio thread never wait for each other:

```
local stream = require("raylib/stream")
local player = stream.play(func(freq){
  local math = require("slang/math")      // runs in a new isolate
  local phase = 0.0
  return func(out, frames){               // called for every block
    for(local i = 0; i < frames; i = i + 1){
      out[i] = math.sin(phase * 2 * math.pi) * 0.2
      phase = (phase + freq / 48000.0) % 1.0
    }
  }
}, {args: {440.0}})
player:stats().load                       // share of real time computing
player:stop()
```

A render isolate calls the block function and fills a ring a little ahead
of the device (`latency`, 1024 frames by default); raylib's stream callback
runs in a second isolate and only copies from the ring. The callback is not
where the sound is computed because raylib's audio thread runs slang about
three times slower than an ordinary thread (macOS gives it a slow core).
Parameters cross as shared buffers (`buffer.shared`) and events as
channels, passed in `args`. `examples/synth` is a synthesizer built on it,
and `examples/fm` an FM synthesizer whose sound is computed by kernels
(packages/kernel).

## In the browser

The website's playground runs programs that use this package on a slang
built with Emscripten, with raylib's web platform linked in (`make
wasm-gfx`). The package is the same; there, `end_drawing` also ends the
program's turn so the page can show the frame and deliver input,
`set_target_fps` does nothing (the browser paces frames), a page never asks
to close (`window_should_close` is false), and raylib logs only errors.

## How raylib maps to slang

- **Names** are snake_case: `DrawTextEx` is `draw_text_ex`, `BeginMode2D`
  `begin_mode_2d`, `Vector2Add` `vector2_add`, and struct fields too
  (`offsetX` is `offset_x`). Constants and colors keep their names:
  `rl.KEY_SPACE`, `rl.FLAG_WINDOW_RESIZABLE`, `rl.RAYWHITE`, `rl.PI`.
- **Structs** are tables, read by field name or by position, so
  `{x: 1, y: 2}` and `{1, 2}` are the same `Vector2`. A color's alpha
  defaults to 255. Results are tables with named fields.
- **Resources** (`Image`, `Texture`, `RenderTexture`, `Font`, `Mesh`,
  `Model`, `ModelAnimation`, `Shader`, `Material`, `Wave`, `Sound`,
  `Music`, `AudioStream`, `Camera3D`, `Camera2D`) are those tables with the
  functions that take them first as methods, named without the type's
  word: `texture:draw(x, y, tint)` is `DrawTexture`, `image:resize(w, h)`
  `ImageResize`, `music:play()` `PlayMusicStream`, `camera:update(mode)`
  `UpdateCamera`, `mesh:to_model()` `LoadModelFromMesh`. A getter without
  arguments and a setter of one value are a property:
  `music.time_length`, `texture.valid`, `sound.volume = 0.5`,
  `texture.filter = rl.TEXTURE_FILTER_BILINEAR` (raylib's setters without
  a getter are write-only). They are values, as in C, freed with their
  `unload` method (`texture:unload()`, the same as `unload_texture`); the
  GPU and the audio device need them freed before `close_window()` and
  `close_audio_device()`. The flat functions stay: `rl.draw_texture(t, x,
  y, tint)` is `t:draw(x, y, tint)`.
- **Made in slang:**
  - `rl.init_window({width, height, title, msaa, resizable, vsync,
    highdpi, fullscreen, fps})` sets the config flags, opens the window
    and sets the frame rate (`init_window(w, h, title)` works too).
  - `rl.camera_3d({position, target, up, fovy, projection})` and
    `rl.camera_2d({offset, target, rotation, zoom})` fill in defaults.
  - `rl.mesh({vertices, normals, texcoords, colors, indices})` copies
    lists (or buffers) of numbers into memory the mesh owns and uploads
    it; `rl.wave({samples, sample_rate, channels})` and `rl.sound({...})`
    make sound from samples in -1..1. No memory to allocate or keep alive.
  - `shader:set(name, value, uniform_type?)` sets a uniform by name (its
    location looked up once), the type inferred from the value.
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
- **Callbacks** are slang functions: `set_audio_stream_callback(stream,
  func(buffer, frames){ ... })` fills audio from slang. raylib calls it
  from its audio thread; it runs while the program is in a raylib call
  (every frame is many), one at a time with the rest of the program, so a
  frame that draws for long makes the sound stutter. For sound that must
  not, use `raylib/stream` (below). `SetTraceLogCallback` takes a
  `va_list`, which slang/ffi cannot pass: not bound.

- **Buffers** (`slang/buffer`) go where lists go, as their memory with no
  conversion: `draw_triangle_strip(points, color)` with `points` a buffer
  of `Vector2`. `examples/terrain.slang` builds a mesh with `rl.mesh`.
- **C names:** `rl.c` holds every raylib function and constant under its C
  name, for whoever knows raylib's API as written:
  `rl.c.DrawText("hi", 10, 10, 20, rl.c.RED)`.

`rl.decls` holds the declarations, for `slang/ffi` and `slang/buffer`:
`buffer.new("Vector2", 100, rl.decls)`.

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
examples/terrain.slang  a mesh built in slang
examples/cubes.slang    3D: a generated cube model drawn many times, an orbiting camera
examples/sparks.slang   the mouse: particles that follow, spray and gather
```
