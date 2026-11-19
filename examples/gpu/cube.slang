// A lit, spinning cube: vertex and index buffers, a uniform buffer written
// every frame, a depth buffer that follows the window's size, and input.
// The shader is WGSL in a `wgsl` block (the extension gpu/syntax), and its
// structs are what slang fills the buffers with: the vertices and the
// uniforms are set by their members' names.
// Drag with the mouse to turn it, scroll to zoom, space to pause the
// spin, escape to quit.
//   cd examples/gpu && ../../bin/slang run cube.slang
extension "gpu/syntax"
local gpu = require("gpu")
local window = require("window")
local math = require("slang/math")
local os = require("slang/os")
local str = require("slang/string")

wgsl shade {
  struct Uniforms {
    view_proj: mat4x4f,
    model: mat4x4f,
    light: vec3f,
  }
  @group(0) @binding(0) var<uniform> u: Uniforms;

  // what the vertex buffer holds
  struct Vertex {
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
  }

  struct Out {
    @builtin(position) position: vec4f,
    @location(0) normal: vec3f,
  }

  @vertex
  fn vs(v: Vertex) -> Out {
    var out: Out;
    out.position = u.view_proj * u.model * vec4f(v.position, 1.0);
    out.normal = (u.model * vec4f(v.normal, 0.0)).xyz;
    return out;
  }

  @fragment
  fn fs(in: Out) -> @location(0) vec4f {
    let n = normalize(in.normal);
    let diffuse = max(dot(n, normalize(u.light)), 0.0);
    let base = vec3f(0.95, 0.55, 0.2) * (0.5 + 0.5 * n * n);
    return vec4f(base * (0.15 + 0.85 * diffuse), 1.0);
  }
}

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
  local base = len(vertices)
  for(let local c in values({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}})){
    local position = {}
    for(local k = 0; k < 3; k = k + 1){
      append(position, n[k] + u[k] * c[0] + v[k] * c[1])
    }
    append(vertices, {position: position, normal: n})
  }
  for(let local i in values({0, 1, 2, 0, 2, 3})){
    append(indices, base + i)
  }
}
local vertex_buffer = device:buffer({
  contents: shade.Vertex:array(vertices),
  usage: "vertex",
})
local index_buffer = device:buffer({
  contents: indices, type: "uint16_t", usage: "index"
})

local pipeline = device:render_pipeline({
  shader: shade,
  // the buffer's layout is the struct's
  vertex: {buffers: {shade.Vertex}},
  fragment: {targets: {{format: surface.format}}},
  primitive: {topology: "triangle_list", cull_mode: "back"},
  depth_stencil: {
    format: "depth24_plus",
    depth_write_enabled: true,
    depth_compare: "less",
  },
})

local uniforms = device:buffer({
  type: shade.Uniforms,
  usage: "uniform|copy_dst",
})
local bind_group = pipeline:bind({u: uniforms})
local u = shade.Uniforms:new({light: {0.4, 0.8, 0.6}})

// ---- matrices: 16 numbers, column after column, as WGSL reads them
local func perspective(fovy, aspect, near, far){
  local f = 1 / math.tan(fovy / 2)
  return {
    f / aspect,
    0,
    0,
    0,
    0,
    f,
    0,
    0,
    0,
    0,
    far / (near - far),
    -1,
    0,
    0,
    near * far / (near - far),
    0,
  }
}

// rotation about y by yaw, then x by pitch
local func rotation(yaw, pitch){
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

// a * b
local func multiply(a, b){
  local out = {}
  for(local c = 0; c < 4; c = c + 1){
    for(local r = 0; r < 4; r = r + 1){
      local s = 0
      for(local k = 0; k < 4; k = k + 1){
        s = s + a[k * 4 + r] * b[c * 4 + k]
      }
      append(out, s)
    }
  }
  return out
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
    // the camera looks down -z from `distance` away
    local view = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, -distance, 1}
    local projection = perspective(
      0.9, surface.width / surface.height, 0.1, 100
    )
    u.view_proj = multiply(projection, view)
    u.model = rotation(yaw, pitch)
    uniforms:write(u)

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
