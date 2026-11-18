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

## WGSL in slang files

With the extension `gpu/syntax`, a shader is written in the slang file
that uses it, as WGSL and nothing but WGSL:

```slang
extension "gpu/syntax"
local gpu = require("gpu")

wgsl doubler {
  @group(0) @binding(0) var<storage, read_write> v: array<f32>;

  @compute @workgroup_size(64)
  fn main(@builtin(global_invocation_id) id: vec3u) {
    v[id.x] = v[id.x] * 2.0;
  }
}

local device = gpu.device()
local pipeline = device:compute_pipeline({shader: device:shader(doubler)})
```

- The block is parsed with the file, by a grammar of WGSL written with
  `slang/peg` (`gpu/wgsl`): a mistake in its syntax is a compile error at
  its line.
- Editors highlight it and `slang fmt` formats it, like the slang code
  around it.
- After the block its name is a local: the program, for `device:shader`.
- What WGSL's own compiler finds later (a type that does not fit, a name
  it does not know) it reports with the line and the column of the slang
  file.

The grammar takes the language as the specification gives it, with
wgpu's 64-bit number suffixes besides. It does not check what WGSL's
compiler checks: types, names, and where WGSL asks for parentheses between
operators. `require("gpu/wgsl").parse(text)` gives the declarations of a
WGSL text (structs with their members, variables with their bindings,
functions with their parameters), which is what a later version will
build struct values and bindings by name from.

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

## In a browser

The package also runs in a browser, on the browser's own WebGPU: slang's
graphics VM (`make wasm-gfx`, the VM of the playground and of pages made
by `website/web/game.slang`) has
[Dawn's `webgpu.h` for Emscripten](https://dawn.googlesource.com/dawn/+/refs/heads/main/src/emdawnwebgpu/)
linked in, and the package reads that header there instead of
wgpu-native's. The API is the same, and programs run unchanged
(`examples/gpu` does, with the `window` package). What differs:

- **A surface draws into the page's canvas.** A window of the `window`
  package is that canvas. Without it, `gpu.canvas()` is the target:
  `device:surface(gpu.canvas())`, and `canvas.pixel_size = {800, 600}`
  sizes it.
- **`surface:present()` ends the program's turn.** The browser shows the
  frame, handles input, and the program goes on at the next animation
  frame. What waits for the GPU (`gpu.device()`, `buffer:read()`,
  `device:poll(true)`) hands the page control the same way. So these are
  called from the program itself, not from a coroutine it made. The calls
  that return a future (`buffer:map()`, `buffer:read_async()`) have no
  such limit: `slang/async` runs on the page's frames there, so they are
  awaited as anywhere else.
- **Validation errors come later.** The browser checks a call after it
  returned, so the error raises at a later call. `device:poll(true)` waits
  for the browser and raises what went wrong before it.
- **The browser must have WebGPU** (Chrome and Edge do, Safari and Firefox
  in their newer versions). Without it `gpu.device()` raises "no adapter".

`make gpu-web-test` runs this package's tests and the examples on the
graphics VM in headless Chrome.

## How WebGPU maps to slang

The package reads `webgpu.h` when it loads, and the API follows from it:

- **Objects are slang values with methods.** A method is the C function
  without its type's prefix, in snake_case: `pass:set_pipeline(p)` is
  `wgpuRenderPassEncoderSetPipeline`. `create_` and `get_` are left off:
  `device:query_set(options)` is `wgpuDeviceCreateQuerySet`, and
  `pipeline:bind_group_layout(0)` is `wgpuRenderPipelineGetBindGroupLayout`.
- **Getters without arguments are properties:** `buffer.size`,
  `buffer.usage`, `texture.width`, `texture.format`,
  `device.adapter.info`, `device.limits`. Enums come back as names and
  flags as names joined by `|` (`"copy_dst|uniform"`), as a descriptor
  takes them. `label` is a property of every object, which remembers it.
- **A count and its pointer are one list** in a method's arguments as in a
  descriptor: `pass:execute_bundles({bundle})`.
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
  compiler's diagnostics. The error's `kind` is `"validation"`,
  `"out_of_memory"`, `"internal"` or `"device_lost"`.
- **What the GPU answers later is a future** of `slang/async`:
  `await buffer:map("read")`, `await device.queue:work_done()`. Where a
  method that waits has a twin that does not, the twin ends in `_async`
  (`buffer:read()` and `buffer:read_async()`, as WebGPU names
  `createRenderPipelineAsync`). See "Waiting for the GPU" below.
- **What wgpu-native does not implement raises** an error of kind
  `unsupported` instead of ending the process (`include/unimplemented.txt`
  lists those functions; a browser's WebGPU has them all).

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
  staging buffer. `buffer:read_async(...)` is the same as a future.
- **Mapped buffers.** `buffer:map(mode, {offset, size, type})` is a future
  of a view: a slang/buffer over the GPU's memory, without a copy.
  `buffer:view(type, offset, size)` is that view for a buffer that is
  mapped already (one made with `mapped_at_creation: true`, say).
  `buffer:unmap()` hands the buffer back to the GPU and empties the views,
  so a view used afterwards raises instead of reading freed memory.
  `buffer.map_state` is `"unmapped"`, `"pending"` or `"mapped"`.
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
  - `device:render_pipeline_async(options)` and
    `device:compute_pipeline_async(options)` are futures of the pipeline,
    for shaders that take long to compile.
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
C name, including the ones that are not methods because the package has
its own form for them (`wgpuBufferMapAsync`, `wgpuBufferGetMappedRange`,
`AddRef` and `Release`). Each object's C pointer is its `handle`.

## Waiting for the GPU

A buffer is mapped, work is done and a scope's error is known some time
after the call that asked. Those calls return a `slang/async` future:

| call | the future's value |
|---|---|
| `buffer:map(mode, options)` | a view of the mapped bytes |
| `buffer:read_async(type, offset, size)` | a copy of the contents |
| `device.queue:work_done()` | null, once the submitted work is done |
| `device:pop_error_scope()` | the scope's error, or null |
| `device:render_pipeline_async(options)`, `device:compute_pipeline_async(options)` | the pipeline |
| `shader:compilation_info()` | the compiler's messages (a browser only) |
| `device.lost` | `{reason, message}`, if the device is ever lost |

Under `async.main` they are awaited, and nothing else is needed: while a
request is open, the package asks the GPU for its answers from the loop.

```slang
extension "extensions/async"
local aio = require("slang/async")
local gpu = require("gpu")

aio.main(func(){
  local device = gpu.device()
  local staging = device:buffer({size: 16, usage: "map_write|copy_src"})
  local floats = await staging:map("write", {type: "float"})
  floats:set({1, 2, 3, 4})
  staging:unmap()
  print((await staging:read_async("float")):to_list(), "\n")
})
```

A program that draws frames has a loop of its own. There
`surface:present()` and `device:poll()` ask for the answers, and a future's
`then` runs when its answer has come:

```slang
energy:read_async("uint32_t"):then(func(sums){
  level = sums[0]
})
```

For `await` in such a program, start the function with `async.run` and
call `async.poll()` once a frame.

`gpu.device()`, `gpu.adapter()`, `buffer:read()` and `device:poll(true)`
wait where they are called. They give up with an error of kind `timeout`
when the GPU has not answered for ten seconds.

## Not yet

- `.wgsl` files as modules, and structs and bindings of a `wgsl` block as
  slang values.
- Errors are raised at the next call on any device: with several devices,
  an error can surface at a call on another one.
- `gpu.device()` and `gpu.adapter()` have no future form.
- Linux and Windows builds have not been run yet. The surface code knows
  their window handles.
