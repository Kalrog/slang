# raylib for slang

All of [raylib](https://www.raylib.com) and raymath: windows and input,
2D and 3D drawing, textures and images, fonts and text, models and
animations, shaders, audio, and the vector/matrix/quaternion math. The
package has no native code. It calls the raylib installed on the machine
through `slang/ffi`, and it reads raylib's own headers when it loads (about
0.1 s), so it always matches the installed version.

```slang
local rl = require("raylib")

rl.window.open({width: 800, height: 450, title: "hello", fps: 60})
local camera = rl.camera_2d({offset: {400, 225}})
for(not rl.window.should_close){
  rl.drawing{
    rl.draw.clear(rl.RAYWHITE)
    rl.mode_2d(camera){
      rl.draw.circle_v(camera:screen_to_world(rl.mouse.position), 20, rl.MAROON)
    }
    rl.draw.text(concat(rl.fps, " fps"), 10, 10, 20, rl.DARKGRAY)
  }
}
rl.window.close()
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
wasm-gfx`). The package is the same; there, the end of `rl.drawing{ ... }`
also ends the program's turn so the page can show the frame and deliver
input, `rl.target_fps` does nothing (the browser paces frames), a page
never asks to close (`rl.window.should_close` is false), and raylib logs
only errors.

## How raylib maps to slang

Every raylib function has one place, which its name says:

- **Namespaces** hold a family of functions, named without the family's
  word: `DrawRectangle` is `rl.draw.rectangle`, `IsKeyPressed`
  `rl.key.pressed`, `IsMouseButtonDown` `rl.mouse.down`,
  `CheckCollisionRecs` `rl.collision.recs`, `MeasureText`
  `rl.text.measure`, `ColorFromHSV` `rl.color.from_hsv`, `Vector3Add`
  `rl.vector3.add`, `MatrixRotateX` `rl.matrix.rotate_x`, `GenMeshCube`
  `rl.mesh.cube`, `LoadTexture` `rl.texture.load`, `ClearBackground`
  `rl.draw.clear`. There are `window`, `monitor`, `clipboard`, `key`,
  `mouse`, `gamepad`, `touch`, `gesture`, `draw`, `text`, `color`,
  `collision`, `camera`, `audio`, the math (`vector2`, `vector3`,
  `vector4`, `matrix`, `quaternion`) and one per resource type (`image`,
  `texture`, `render_texture`, `font`, `mesh`, `model`,
  `model_animation`, `shader`, `material`, `wave`, `sound`, `music`,
  `audio_stream`). The rest stays on `rl` itself (`rl.random(1, 6)`,
  `rl.load_file_text(path)`, `rl.wait_time(0.5)`).
- **Properties** are raylib's getters without arguments and setters of one
  value: `rl.mouse.position`, `rl.mouse.wheel`, `rl.window.width`,
  `rl.window.should_close`, `rl.time`, `rl.frame_time`, `rl.fps`,
  `rl.window.title = "x"`, `rl.target_fps = 60`, `rl.audio.volume = 0.5`.
  A setter of two numbers takes a vector: `rl.window.position = {100,
  80}`, `rl.mouse.position = {x, y}`. Setters raylib has no getter for
  are write-only. Written in slang: `rl.window.size`,
  `rl.window.fullscreen = true`, `rl.window.event_waiting = true`,
  `rl.mouse.visible = false` (ShowCursor, HideCursor), `rl.mouse.locked =
  true` (DisableCursor: the cursor is captured for a first-person
  camera).
- **Begin/End pairs** are functions that take a block: the block draws
  in between, and the End is called however it ends.

  ```slang
  rl.drawing{
    rl.draw.clear(rl.BLACK)
    rl.mode_3d(camera){
      rl.draw.grid(10, 1)
    }
    rl.texture_mode(target){ ... }
    rl.shader_mode(shader){ ... }
    rl.blend_mode(rl.BLEND_ADDITIVE){ ... }
    rl.scissor_mode({x, y, w, h}){ ... }
    rl.depth_mask(false){ ... }     // draws without writing depths (smoke, glass)
  }
  ```

  A block is a function, so `return` in one leaves the block only.
- **Resources** (`Image`, `Texture`, `RenderTexture`, `Font`, `Mesh`,
  `Model`, `ModelAnimation`, `Shader`, `Material`, `Wave`, `Sound`,
  `Music`, `AudioStream`, `Camera3D`, `Camera2D`) are their structs as
  tables, with the functions that take them first as methods, named
  without the type's word: `texture:draw(x, y, tint)` is `DrawTexture`,
  `image:resize(w, h)` `ImageResize`, `music:play()` `PlayMusicStream`,
  `camera:update(mode)` `UpdateCamera`, `mesh:to_model()`
  `LoadModelFromMesh`, `shader:location(name)` `GetShaderLocation`.
  Their getters and setters are properties: `music.time_length`,
  `sound.playing`, `texture.valid`, `sound.volume = 0.5`, `texture.filter
  = rl.TEXTURE_FILTER_BILINEAR`. The resources inside one are resources
  too: `target.texture:draw_rec(...)`, `font.texture.filter = ...`.
  Resources are values, as in C, freed with their `unload` method; the GPU
  and the audio device need them freed before `rl.window.close()` and
  `rl.audio.close()`.
- **Made in slang:**
  - `rl.window.open({width, height, title, msaa, resizable, vsync,
    highdpi, fullscreen, hidden, flags, fps})` sets the config flags,
    opens the window and sets the frame rate (`open(w, h, title)` works
    too).
  - A resource's namespace called makes one: `rl.texture(path or
    image)`, `rl.image(path)`, `rl.font(path, {size, filter})`,
    `rl.model(path or mesh)`, `rl.shader({vertex, fragment})` (GLSL code;
    `vertex_file` and `fragment_file` for files), `rl.render_texture(w,
    h)`, `rl.music(path)`, `rl.sound(path)`.
  - `rl.mesh({vertices, normals, texcoords, colors, indices})` copies
    lists (or buffers) of numbers into memory the mesh owns and uploads
    it; `rl.wave({samples, sample_rate, channels})` and `rl.sound({...})`
    make sound from samples in -1..1. No memory to allocate or keep alive.
  - `rl.camera_3d({position, target, up, fovy, projection})` and
    `rl.camera_2d({offset, target, rotation, zoom})` fill in defaults;
    `camera:screen_to_world_ray(point)` and `camera:world_to_screen(p)`
    (`camera:screen_to_world(p)` in 2D) map between the screen and the
    world.
  - `shader:set(name, value, uniform_type?)` sets a uniform by name (its
    location looked up once), the type inferred from the value (a number,
    a vector, a matrix or a texture).
  - `rl.random_sequence(count, min, max)` is a list.
- **Old names** raise with where they went: `rl.get_mouse_position()` is
  `raylib: rl.get_mouse_position is now rl.mouse.position`.
- **Pointer fields** reach into raylib's memory and write it in place, as in
  C:
  - `model.materials[0].maps[rl.MATERIAL_MAP_ALBEDO].texture = tex`
  - `shader.locs[rl.SHADER_LOC_VECTOR_VIEW] = loc`
- **Pointer parameters:**
  - A list and its count are one argument: `rl.draw.triangle_strip(points,
    color)`, `rl.image.load_from_memory(".png", bytes)` with the bytes as
    a string.
  - `T *value` takes a table that raylib updates: `camera:update(
    rl.CAMERA_ORBITAL)` moves `camera`, and `image:resize(w, h)` changes
    `image`.
- **Strings** raylib allocates (`rl.text.replace`, `rl.load_file_text`)
  come back as slang strings. Directory listings are lists of strings.
  `rl.text.format` and `rl.trace_log` take their arguments as in C
  (`trace_log` takes plain text).
- **Written by hand:** `shader:set_value(loc, value, type)` and
  `set_value_v` take numbers, lists or vector tables; `image:colors()` is a
  list of colors; `image:pixel_data()` the pixels as a string;
  `rl.model_animation.load(path)` a list of animations.
- **Callbacks** are slang functions: `stream.callback = func(buffer,
  frames){ ... }` fills an audio stream from slang. raylib calls it from
  its audio thread; it runs while the program is in a raylib call (every
  frame is many), one at a time with the rest of the program, so a frame
  that draws for long makes the sound stutter. For sound that must not,
  use `raylib/stream` (above). `SetTraceLogCallback` takes a `va_list`,
  which slang/ffi cannot pass: not bound.
- **Buffers** (`slang/buffer`) go where lists go, as their memory with no
  conversion: `rl.draw.triangle_strip(points, color)` with `points` a
  buffer of `Vector2`. `examples/terrain.slang` builds a mesh with
  `rl.mesh`.
- **Names** are snake_case, struct fields too (`offsetX` is `offset_x`).
  Constants and colors keep raylib's names: `rl.KEY_SPACE`,
  `rl.FLAG_WINDOW_RESIZABLE`, `rl.RAYWHITE`, `rl.PI`.
- **Structs** are tables, read by field name or by position, so
  `{x: 1, y: 2}` and `{1, 2}` are the same `Vector2`. A color's alpha
  defaults to 255. Results are tables with named fields.
- **C names:** `rl.c` holds every raylib function and constant under its C
  name, for whoever knows raylib's API as written:
  `rl.c.DrawText("hi", 10, 10, 20, rl.c.RED)`.

`rl.decls` holds the declarations, for `slang/ffi` and `slang/buffer`:
`buffer.new("Vector2", 100, rl.decls)`.

Wrong arguments are slang errors that say what was expected, for example
`bad argument #1 to 'rl.collision.recs' (Rectangle expected, got string)`.
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
