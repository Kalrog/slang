# gpu for slang

[WebGPU](https://www.w3.org/TR/webgpu/) through
[wgpu-native](https://github.com/gfx-rs/wgpu-native) (Firefox's WebGPU,
with the standard `webgpu.h` C API) and `slang/ffi`. It gives you devices,
buffers, textures, samplers, WGSL shaders, render and compute pipelines,
and surfaces for drawing into windows. It runs on Metal on macOS, and on
Vulkan elsewhere. It ships wgpu-native for macOS, so there is nothing to
install.

```slang
local gpu = require("gpu")
local window = require("window")

local win = window.open({title: "triangle"})
local device = gpu.device()
local surface = device:surface(win)
local pipeline = device:render_pipeline({
  shader: device:shader(wgsl_code),
  fragment: {targets: {{format: surface.format}}},
})
for(win.open){
  win:events()
  local frame = surface:texture()
  if(frame != null){
    local encoder = device:encoder()
    local pass = encoder:render_pass({color_attachments: {
      {view: frame:view(), clear_value: {0.1, 0.1, 0.1, 1}},
    }})
    pass:set_pipeline(pipeline)
    pass:draw(3)
    pass:finish()
    device.queue:submit(encoder:finish())
    surface:present()
  }
}
```

`examples/gpu` in the slang repository has a triangle and a lit cube with
mouse controls (`make gpu`). `examples/compute.slang` in this package runs
a compute shader without a window.

## Using it

Add the package to the project's `slang.project`:

```
dependencies: {gpu: {git: "<repository>", version: "^1.0"}}
```

Inside the slang repository, use `{path: "../packages/gpu"}` instead. Then
run `slang get`. Windows come from the `window` package, or from anything
with a `native` property shaped like a window's.

The package carries `lib/<platform>/libwgpu_native` for macos-aarch64 and
macos-x86_64 (about 7 MB each). `tool/fetch.sh` fetches a pinned,
checksummed release for those and for linux-x86_64 and linux-aarch64.
`lib/VERSION` names the release. `GPU_WGPU` names another wgpu-native
library file.

The language server and `slang doc` read `stubs/init.slang`, generated
from the header and `init.slang` (the objects' methods and properties are
made at run time, so tools cannot see them in the source):

```
slang run tool/gen_stubs.slang     # after wgpu-native or the package changes
```

`gpu.decls` holds the declarations, for `slang/ffi` and `slang/buffer`.

## How WebGPU maps to slang

The package reads `webgpu.h` when it loads, and the API follows from it:

- **Objects are slang values with methods.** A method is the C function
  without its type's prefix, in snake_case: `pass:set_pipeline(p)` is
  `wgpuRenderPassEncoderSetPipeline`, and `pipeline:get_bind_group_layout(0)`
  is `wgpuRenderPipelineGetBindGroupLayout`.
- **Getters without arguments are properties:** `buffer.size`,
  `buffer.usage`, `texture.width`, `texture.format`,
  `device.adapter.info`, `device.limits`.
- **Descriptors are option tables** with `webgpu.h`'s fields in snake_case.
  Fields you leave out take WebGPU's defaults (read from the header's
  `INIT` macros).
  - Enums are strings: `"triangle_list"`, `"bgra8_unorm"`,
    `"depth24_plus"`. WebGPU's JavaScript spelling (`"triangle-list"`) works
    too, and `gpu.enums.texture_format` lists the names.
  - Flags are names joined by `|` (`"vertex|copy_dst"`), or a list of names.
  - A list fills a pointer and its count (`entries`, `targets`,
    `color_attachments`, `attributes`).
  - `{w, h}` lists are accepted for extents, origins and colors.
- **Objects are released** once nothing refers to them.
- **Validation errors raise** at the call that caused them, with
  wgpu's message, as `"gpu: ..."`. WGSL compile errors include the
  compiler's diagnostics.

On top of that, the package adds:

- **Devices.** `gpu.device(options)` picks the adapter and requests a
  device in one step; `options.power_preference` defaults to
  `"high_performance"`. For control over each step, use
  `gpu.adapter(options)` and then `adapter:request_device(options)`.
  `device.queue` is the device's queue.
- **Buffers.** `device:buffer({size, usage})`, or `{contents, usage}` with
  `contents` given as a slang/buffer, a string, or a list of numbers (32-bit
  floats, or of `type`). Write with `buffer:write(data, offset)`. Read with
  `buffer:read(type, offset, size)`, which waits for the GPU and returns a
  slang/buffer; a buffer without `map_read` usage is copied through a
  staging buffer.
- **Textures.** `device:texture({size, format, usage})`, then
  `texture:view()` and `texture:write(data, options)`. `bytes_per_row` is
  worked out for the usual formats.
- **Shaders.** `device:shader(wgsl)` compiles a WGSL module.
- **Pipelines.**
  - `device:render_pipeline(options)`: `shader` serves as both the
    vertex and the fragment module, a target's `blend` can be
    `"alpha"`, `"premultiplied"` or `"additive"`, and `layout` is auto when
    left out.
  - `device:compute_pipeline({shader})`.
- **Bind groups.** `device:bind_group({layout, entries})`, where each
  entry's `resource` is a Buffer, `{buffer, offset, size}`, a TextureView,
  a Texture or a Sampler.
- **Passes.**
  - `encoder:render_pass(options)`: a color attachment clears when it
    has a `clear_value` and loads otherwise, and always stores. A depth
    attachment clears to 1 and stores.
  - `encoder:compute_pass()`.
  - End a pass with `pass:finish()` (WebGPU's `end`), then submit with
    `device.queue:submit(encoder:finish())`.
- **Surfaces.** `device:surface(window, options)` configures the surface
  at the window's size in pixels. `surface:texture()` returns the frame
  to draw into, or null when there is none, and reconfigures the surface
  when the window's size has changed. Show the frame with
  `surface:present()`. Read `surface.format`, `surface.width` and
  `surface.height` for the current setup. `present_mode` is `"fifo"`
  (vsync) by default.

`gpu.c` holds every `webgpu.h` and `wgpu.h` function and constant under its
C name. Each object's C pointer is its `handle`.

## Not yet

- Callback-based functions other than device and adapter requests and
  buffer mapping (`queue:on_submitted_work_done`, compilation info,
  error scopes). Use `gpu.c` for those.
- The browser: the plan is to compile the same `webgpu.h` calls with
  Emscripten against the browser's WebGPU.
- Linux and Windows builds have not been run yet. The surface code knows
  their window handles.
