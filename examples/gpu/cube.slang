// A lit, spinning cube: vertex and index buffers, a uniform buffer written
// every frame, a depth buffer that follows the window's size, and input.
// Drag with the mouse to turn it, scroll to zoom, space to pause the
// spin, escape to quit.
//   cd examples/gpu && ../../bin/slang run cube.slang
local gpu = require("gpu")
local window = require("window")
local buffer = require("slang/buffer")
local math = require("slang/math")
local os = require("slang/os")
local str = require("slang/string")

local win = window.open({
  title: "cube", width: 900, height: 640, resizable: true
})
local device = gpu.device()
local surface = device:surface(win)

// ---- the mesh: 6 faces of 4 vertices, position and normal each
local vertices = {}
local indices = {}
local faces = {
  {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}},
  {{-1, 0, 0}, {0, 1, 0}, {0, 0, -1}},
  {{0, 1, 0}, {0, 0, 1}, {1, 0, 0}},
  {{0, -1, 0}, {0, 0, -1}, {1, 0, 0}},
  {{0, 0, 1}, {1, 0, 0}, {0, 1, 0}},
  {{0, 0, -1}, {-1, 0, 0}, {0, 1, 0}},
}
for(let local f in values(faces)){
  local n = f[0]
  local u = f[1]
  local v = f[2]
  local base = len(vertices) / 6
  for(let local c in values({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}})){
    for(local k = 0; k < 3; k = k + 1){
      append(vertices, n[k] + u[k] * c[0] + v[k] * c[1])
    }
    for(local k = 0; k < 3; k = k + 1){
      append(vertices, n[k])
    }
  }
  for(let local i in values({0, 1, 2, 0, 2, 3})){
    append(indices, base + i)
  }
}
local vertex_buffer = device:buffer({contents: vertices, usage: "vertex"})
local index_buffer = device:buffer({
  contents: indices, type: "uint16_t", usage: "index"
})

local shader = device:shader("""
  struct Uniforms {
    view_proj: mat4x4f,
    model: mat4x4f,
    light: vec4f,
  };
  @group(0) @binding(0) var<uniform> u: Uniforms;

  struct Out {
    @builtin(position) position: vec4f,
    @location(0) normal: vec3f,
  };

  @vertex
  fn vs(@location(0) position: vec3f, @location(1) normal: vec3f) -> Out {
    var out: Out;
    out.position = u.view_proj * u.model * vec4f(position, 1.0);
    out.normal = (u.model * vec4f(normal, 0.0)).xyz;
    return out;
  }

  @fragment
  fn fs(in: Out) -> @location(0) vec4f {
    let n = normalize(in.normal);
    let diffuse = max(dot(n, normalize(u.light.xyz)), 0.0);
    let base = vec3f(0.95, 0.55, 0.2) * (0.5 + 0.5 * n * n);
    return vec4f(base * (0.15 + 0.85 * diffuse), 1.0);
  }""")

local pipeline = device:render_pipeline({
  shader: shader,
  vertex: {
    buffers: {
      {
        array_stride: 24,
        attributes: {
          {format: "float32x3", offset: 0, shader_location: 0},
          {format: "float32x3", offset: 12, shader_location: 1},
        },
      },
    },
  },
  fragment: {targets: {{format: surface.format}}},
  primitive: {topology: "triangle_list", cull_mode: "back"},
  depth_stencil: {
    format: "depth24_plus",
    depth_write_enabled: true,
    depth_compare: "less",
  },
})

local uniform_data = buffer.new("float", 36)
local uniforms = device:buffer({
  size: uniform_data.size,
  usage: "uniform|copy_dst",
})
local bind_group = device:bind_group({
  layout: pipeline:bind_group_layout(0),
  entries: {{binding: 0, resource: uniforms}},
})

// ---- matrices, column-major as WGSL reads them, written at offset
local func perspective(out, at, fovy, aspect, near, far){
  local f = 1 / math.tan(fovy / 2)
  for(local i = 0; i < 16; i = i + 1){
    out[at + i] = 0
  }
  out[at + 0] = f / aspect
  out[at + 5] = f
  out[at + 10] = far / (near - far)
  out[at + 11] = -1
  out[at + 14] = near * far / (near - far)
}

// rotation about y by yaw, then x by pitch, moved back by distance
local func model_view(yaw, pitch){
  local cy = math.cos(yaw)
  local sy = math.sin(yaw)
  local cp = math.cos(pitch)
  local sp = math.sin(pitch)
  return {
    cy,
    sp * sy,
    -cp * sy,
    0,
    0,
    cp,
    sp,
    0,
    sy,
    -sp * cy,
    cp * cy,
    0,
    0,
    0,
    0,
    1,
  }
}

local func multiply(out, at, a, b){
  // out = a * b, column-major
  for(local c = 0; c < 4; c = c + 1){
    for(local r = 0; r < 4; r = r + 1){
      local s = 0
      for(local k = 0; k < 4; k = k + 1){
        s = s + a[k * 4 + r] * b[c * 4 + k]
      }
      out[at + c * 4 + r] = s
    }
  }
}

local depth = null
local depth_size = {0, 0}
local func depth_view(w, h){
  if(depth_size[0] != w or depth_size[1] != h){
    depth = device:texture({
      size: {w, h},
      format: "depth24_plus",
      usage: "render_attachment",
    }):view()
    depth_size = {w, h}
  }
  return depth
}

local yaw = 0.6
local pitch = 0.4
local distance = 5.0
local spin = true
local dragging = false
local frames = 0
// CUBE_FRAMES=n stops after n frames (for tests)
local limit = os.getenv("CUBE_FRAMES")
local proj = buffer.new("float", 16)
local view = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}

for(win.open){
  for(let local e in values(win:events())){
    if(e.type == "key_down" and e.key == "escape"){
      win:close()
    } else if(e.type == "key_down" and e.key == "space"){
      spin = not spin
    } else if(e.type == "mouse_down" and e.button == "left"){
      dragging = true
    } else if(e.type == "mouse_up" and e.button == "left"){
      dragging = false
    } else if(e.type == "mouse_move" and dragging){
      yaw = yaw + e.dx * 0.01
      pitch = math.clamp(pitch + e.dy * 0.01, -1.5, 1.5)
    } else if(e.type == "wheel"){
      distance = math.clamp(distance - e.dy * 0.3, 2.5, 20)
    }
  }
  if(not win.open){
    break
  }
  if(spin and not dragging){
    yaw = yaw + 0.01
  }
  local frame = surface:texture()
  if(frame != null){
    perspective(proj, 0, 0.9, surface.width / surface.height, 0.1, 100)
    view[14] = -distance
    multiply(uniform_data, 0, proj, view)
    local model = model_view(yaw, pitch)
    for(local i = 0; i < 16; i = i + 1){
      uniform_data[16 + i] = model[i]
    }
    uniform_data[32] = 0.4
    uniform_data[33] = 0.8
    uniform_data[34] = 0.6
    uniforms:write(uniform_data)

    local encoder = device:encoder()
    local pass = encoder:render_pass({
      color_attachments: {
        {view: frame:view(), clear_value: {0.07, 0.08, 0.1, 1}},
      },
      depth_stencil_attachment: {
        view: depth_view(surface.width, surface.height),
      },
    })
    pass:set_pipeline(pipeline)
    pass:set_bind_group(0, bind_group)
    pass:set_vertex_buffer(0, vertex_buffer)
    pass:set_index_buffer(index_buffer, "uint16")
    pass:draw_indexed(len(indices))
    pass:finish()
    device.queue:submit(encoder:finish())
    surface:present()
  }
  frames = frames + 1
  if(limit != null and frames >= str.to_number(limit)){
    win:close()
  }
}
