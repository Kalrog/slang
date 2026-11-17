// The binding without a window: devices, buffers, compute, rendering into
// a texture read back, enums, defaults and errors (run with
// `slang test test` in packages/gpu)
local t = require("slang/test")
local gpu = require("gpu")

local device = gpu.device()

local func near(a, b){
  return a - b < 0.01 and b - a < 0.01
}

t.group("gpu: devices"){
  t.test("a device on an adapter, with its queue"){
    assert(type(device) == "gpu.Device")
    assert(type(device.queue) == "gpu.Queue")
    assert(device.queue == device.queue)
    local info = device.adapter.info
    assert(type(info.device) == "string" and info.device != "")
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
    assert(
      a.usage == gpu.c.WGPUBufferUsage_Uniform | gpu.c.WGPUBufferUsage_CopyDst,
    )
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
      layout: pipeline:get_bind_group_layout(0),
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
      layout: pipeline:get_bind_group_layout(0),
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

t.group("gpu: errors"){
  t.test("WGSL that does not compile raises with the compiler's message"){
    local e = t.raises(func(){
      device:shader("fn broken( {")
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
  t.test("a validation error raises at the call"){
    t.raises(func(){
      device:buffer({size: 4, usage: "map_read|storage"})
    })
  }
}
