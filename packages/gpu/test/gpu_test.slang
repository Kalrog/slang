// The binding without a window: devices, buffers, compute, rendering into
// a texture read back, enums, defaults and errors (run with
// `slang test test` in packages/gpu). The same tests pass in a browser, on
// slang's graphics VM (`make gpu-web-test`).
local t = require("slang/test")
local async = require("slang/async")
local gpu = require("gpu")

local device = gpu.device()
// in a browser WebGPU is the browser's own, which tells less about the
// adapter and reports mistakes later
local in_browser = gpu.version() == "browser"

local func near(a, b){
  return a - b < 0.01 and b - a < 0.01
}

t.group("gpu: devices"){
  t.test("a device on an adapter, with its queue"){
    assert(type(device) == "gpu.Device")
    assert(type(device.queue) == "gpu.Queue")
    assert(device.queue == device.queue)
    local info = device.adapter.info
    assert(type(info.device) == "string" and (in_browser or info.device != ""))
    assert(type(info.backend_type) == "string")
  }
  t.test("enums are listed by name"){
    local formats = gpu.enums.texture_format
    assert(len(formats) > 50)
    local found = false
    for(let local f in values(formats)){
      if(f == "bgra8_unorm"){
        found = true
      }
    }
    assert(found)
  }
  t.test("a version"){
    assert(len(gpu.version()) >= 7)
  }
}

t.group("gpu: buffers"){
  t.test("contents are written and read back"){
    local b = device:buffer({contents: {1, 2, 3, 4}, usage: "storage|copy_src"})
    assert(b.size == 16)
    assert(b:read("float"):to_list() == {1.0, 2.0, 3.0, 4.0})
    b:write({9, 8}, 4)
    assert(b:read("float"):to_list() == {1.0, 9.0, 8.0, 4.0})
  }
  t.test("usage is flags: names joined by |, or a list"){
    local a = device:buffer({size: 64, usage: "uniform|copy_dst"})
    local b = device:buffer({size: 64, usage: {"uniform", "copy_dst"}})
    assert(a.usage == b.usage)
    assert(a.usage == "copy_dst|uniform", a.usage)
  }
  t.test("a label is a property the object remembers"){
    local b = device:buffer({size: 16, usage: "uniform", label: "named"})
    assert(b.label == "named")
    b.label = "renamed"
    assert(b.label == "renamed")
  }
}

t.group("gpu: mapped buffers"){
  t.test("a buffer mapped at creation is filled through its view"){
    local b = device:buffer({
      size: 16,
      usage: "vertex|copy_src",
      mapped_at_creation: true,
    })
    assert(b.map_state == "mapped")
    local view = b:view("float")
    assert(len(view) == 4 and b:view("float") == view)
    view:set({1, 2, 3, 4})
    b:unmap()
    // the view lets go of the GPU's memory
    assert(b.map_state == "unmapped" and len(view) == 0)
    t.raises(func(){ return view[0] })
    assert(b:read("float"):to_list() == {1.0, 2.0, 3.0, 4.0})
  }
  t.test("map is a future of a view: written, unmapped, mapped to read"){
    local b = device:buffer({size: 16, usage: "map_write|copy_src"})
    local out = device:buffer({size: 16, usage: "map_read|copy_dst"})
    local got = async.main(func(){
      local view = async.await(b:map("write", {type: "uint32_t"}))
      assert(b.map_state == "mapped")
      view:set({7, 8, 9, 10})
      b:unmap()
      local encoder = device:encoder()
      encoder:copy_buffer_to_buffer(b, 0, out, 0, 16)
      device.queue:submit(encoder:finish())
      async.await(device.queue:work_done())
      local back = async.await(out:map("read", {type: "uint32_t", offset: 8}))
      local list = back:to_list()
      out:unmap()
      return list
    })
    assert(got == {9, 10}, got)
  }
  t.test("what is not mapped has no view; a second map fails its future"){
    local b = device:buffer({size: 16, usage: "map_read|copy_dst"})
    local e = t.raises(func(){ b:view() }, "gpu: the buffer is not mapped")
    assert(e.kind == error.kinds.state)
    local first = b:map()
    assert(b.map_state == "pending")
    local second = b:map()
    assert(second:is_done() and second.error.kind == error.kinds.state)
    second:catch(func(e){ })
    // a program with a loop of its own polls
    for(not first:is_done()){
      device:poll(true)
    }
    assert(b.map_state == "mapped" and len(first.value) == 16)
    b:unmap()
    b:unmap()
  }
  t.test("read_async is read as a future"){
    local data = device:buffer({contents: {5, 6}, usage: "storage|copy_src"})
    local got = async.main(func(){
      return async.await(data:read_async("float")):to_list()
    })
    assert(got == {5.0, 6.0}, got)
  }
}

t.group("gpu: compute"){
  t.test("a compute shader doubles numbers"){
    local shader = device:shader("""
      @group(0) @binding(0) var<storage, read_write> v: array<f32>;
      @compute @workgroup_size(64)
      fn main(@builtin(global_invocation_id) id: vec3u) {
        if (id.x < arrayLength(&v)) { v[id.x] = v[id.x] * 2.0; }
      }""")
    local pipeline = device:compute_pipeline({shader: shader})
    local data = device:buffer({
      contents: {1, 2, 3, 4, 5},
      usage: "storage|copy_src",
    })
    local encoder = device:encoder()
    local pass = encoder:compute_pass()
    pass:set_pipeline(pipeline)
    pass:set_bind_group(0, device:bind_group({
      layout: pipeline:bind_group_layout(0),
      entries: {{binding: 0, resource: data}},
    }))
    pass:dispatch_workgroups(1)
    pass:finish()
    device.queue:submit(encoder:finish())
    assert(data:read("float"):to_list() == {2.0, 4.0, 6.0, 8.0, 10.0})
  }
}

t.group("gpu: rendering"){
  t.test("a triangle drawn into a texture, read back"){
    local size = 64
    local target = device:texture({
      size: {size, size},
      format: "rgba8_unorm",
      usage: "render_attachment|copy_src",
    })
    assert(target.width == size and target.format == "rgba8_unorm")
    local shader = device:shader("""
      @vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
        var p = array(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
        return vec4f(p[i], 0.0, 1.0);
      }
      @group(0) @binding(0) var<uniform> color: vec4f;
      @fragment fn fs() -> @location(0) vec4f { return color; }""")
    local pipeline = device:render_pipeline({
      shader: shader,
      fragment: {targets: {{format: "rgba8_unorm"}}},
    })
    local uniforms = device:buffer({contents: {1, 0.5, 0, 1}, usage: "uniform"})
    local encoder = device:encoder()
    local pass = encoder:render_pass({
      color_attachments: {
        {view: target:view(), clear_value: {0, 0, 1, 1}},
      },
    })
    pass:set_pipeline(pipeline)
    pass:set_bind_group(0, device:bind_group({
      layout: pipeline:bind_group_layout(0),
      entries: {{binding: 0, resource: uniforms}},
    }))
    pass:draw(3)
    pass:finish()
    // rows are copied 256 bytes apart
    local readback = device:buffer({
      size: 256 * size,
      usage: "copy_dst|map_read",
    })
    encoder:copy_texture_to_buffer(
      {texture: target},
      {buffer: readback, layout: {bytes_per_row: 256, rows_per_image: size}},
      {size, size},
    )
    device.queue:submit(encoder:finish())
    local pixels = readback:read()
    local at = 256 * 10 + 4 * 10
    assert({
      pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]
    } == {255, 128, 0, 255}, {
      pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]
    })
  }
  t.test("textures are written and sampled"){
    local tex = device:texture({
      size: {2, 2},
      format: "rgba8_unorm",
      usage: "texture_binding|copy_dst|copy_src",
    })
    local buffer = require("slang/buffer")
    tex:write(buffer.from(
      {255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255},
      "uint8_t",
    ))
    local sampler = device:sampler({mag_filter: "nearest"})
    assert(type(sampler) == "gpu.Sampler")
  }
}

t.group("gpu: the header's functions as methods"){
  t.test("a count and its pointer are one list; results are slang values"){
    local shader = device:shader("""
      @vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
        return vec4f(0.0, 0.0, 0.0, 1.0);
      }
      @fragment fn fs() -> @location(0) vec4f { return vec4f(1.0); }""")
    local pipeline = device:render_pipeline({
      shader: shader,
      fragment: {targets: {{format: "rgba8_unorm"}}},
    })
    local target = device:texture({
      size: {4, 4},
      format: "rgba8_unorm",
      usage: "render_attachment",
    })
    assert(target.usage == "render_attachment", target.usage)
    local bundler = device:render_bundle_encoder({
      color_formats: {"rgba8_unorm"},
    })
    bundler:set_pipeline(pipeline)
    bundler:draw(3, 1, 0, 0)
    local bundle = bundler:finish()
    assert(type(bundle) == "gpu.RenderBundle")
    local encoder = device:encoder()
    local pass = encoder:render_pass({
      color_attachments: {
        {view: target:view(), clear_value: {0, 0, 0, 1}},
      },
    })
    pass:execute_bundles({bundle})
    pass:finish()
    device.queue:submit(encoder:finish())
    device:poll(true)
    assert(type(device:has_feature("timestamp_query")) == "bool")
    assert(type(device.adapter.features) == "table")
  }
  t.test("a pipeline as a future; the compiler's messages in a browser"){
    local shader = device:shader("""
      @group(0) @binding(0) var<storage, read_write> v: array<f32>;
      @compute @workgroup_size(1) fn main() { v[0] = 1.0; }""")
    local made = async.main(func(){
      local pipeline = async.await(device:compute_pipeline_async({
        shader: shader,
      }))
      local messages = null
      if(in_browser){
        messages = async.await(shader:compilation_info())
      }
      return {pipeline: pipeline, messages: messages}
    })
    assert(type(made.pipeline) == "gpu.ComputePipeline")
    assert(type(made.pipeline:bind_group_layout(0)) == "gpu.BindGroupLayout")
    if(in_browser){
      assert(raw_type(made.messages) == "table" and len(made.messages) == 0)
    } else {
      local e = t.raises(func(){ shader:compilation_info() })
      assert(e.kind == error.kinds.unsupported)
    }
  }
  t.test("what a C program would call is not a method"){
    local b = device:buffer({size: 16, usage: "uniform"})
    for(let local name in values({
      "release",
      "add_ref",
      "map_async",
      "get_mapped_range",
      "set_label",
    })){
      assert(b[name] == null, name)
    }
    assert(device.create_buffer == null and device.encoder != null)
  }
  t.test("what wgpu-native does not implement raises"){
    if(not in_browser){
      local tex = device:texture({
        size: {4, 4},
        format: "rgba8_unorm",
        usage: "texture_binding",
      })
      local e = t.raises(func(){ return tex.texture_binding_view_dimension })
      assert(e.kind == error.kinds.unsupported, e.kind)
    }
  }
}

t.group("gpu: errors"){
  t.test("WGSL that does not compile raises with the compiler's message"){
    local e = t.raises(func(){
      device:shader("fn broken( {")
      // (a browser says so later: by the time the queue was waited for)
      device:poll(true)
    })
    assert(require("slang/string").contains(e.message, "gpu:"), e.message)
  }
  t.test("an unknown enum name raises"){
    t.raises(func(){
      device:texture({
        size: {4, 4}, format: "no_such_format", usage: "copy_dst"
      })
    }, "gpu: no_such_format is not a texture_format")
  }
  t.test(
    "a validation error raises: at the call, in a browser by the next wait",
  ){
    local e = t.raises(func(){
      device:buffer({size: 4, usage: "map_read|storage"})
      device:poll(true)
    })
    assert(require("slang/string").contains(e.message, "gpu:"), e.message)
    assert(e.kind == "validation", e.kind)
    // and what comes after it works
    assert(
      device
        :buffer({contents: {1, 2}, usage: "storage|copy_src"})
        :read("float")[1] == 2.0,
    )
  }
  t.test("an error scope catches an error as a future's value"){
    device:push_error_scope("validation")
    device:buffer({size: 4, usage: "map_read|storage"})
    local e = async.main(func(){
      return async.await(device:pop_error_scope())
    })
    assert(e.kind == "validation", e)
    device:push_error_scope("validation")
    device:buffer({size: 16, usage: "uniform"})
    assert(async.main(func(){
      return async.await(device:pop_error_scope())
    }) == null)
  }
}
