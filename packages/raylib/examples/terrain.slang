// A terrain mesh built in slang: vertices, normals, colors and indices are
// written into buffers over memory raylib allocates (unload_model frees it
// with raylib's allocator), then uploaded to the GPU.
//
//   slang run examples/terrain.slang      (in packages/raylib)
//
// TERRAIN_FRAMES=n quits after n frames (a smoke test without a player).
local rl = require("raylib")
local buffer = require("slang/buffer")
local math = require("slang/math")
local os = require("slang/os")

local size = 64
local scale = 0.25

// a buffer of n elements of type in memory raylib frees with the mesh
local func raylib_buffer(type, n, bytes_each){
  return buffer.wrap(rl.mem_alloc(n * bytes_each), n, type)
}

local func height(x, z){
  return math.sin(x * 0.2) * 1.5 + math.cos(z * 0.15) * 1.2 +
    math.sin((x + z) * 0.07) * 2
}

local func terrain_mesh(){
  local side = size + 1
  local vertex_count = side * side
  local triangle_count = size * size * 2
  local vertices = raylib_buffer("float", vertex_count * 3, 4)
  local normals = raylib_buffer("float", vertex_count * 3, 4)
  local colors = raylib_buffer("unsigned char", vertex_count * 4, 1)
  local indices = raylib_buffer("unsigned short", triangle_count * 3, 2)
  for(local z = 0; z < side; z = z + 1){
    for(local x = 0; x < side; x = x + 1){
      local i = z * side + x
      local h = height(x, z)
      vertices[i * 3] = (x - size / 2) * scale
      vertices[i * 3 + 1] = h * scale
      vertices[i * 3 + 2] = (z - size / 2) * scale
      // the normal from the slopes around the vertex
      local dx = height(x + 1, z) - height(x - 1, z)
      local dz = height(x, z + 1) - height(x, z - 1)
      local n = rl.vector3_normalize({-dx, 2, -dz})
      normals[i * 3] = n.x
      normals[i * 3 + 1] = n.y
      normals[i * 3 + 2] = n.z
      // low is green, high is snow
      local t = (h + 4.7) / 9.4
      colors[i * 4] = to_int(60 + t * 190)
      colors[i * 4 + 1] = to_int(140 + t * 110)
      colors[i * 4 + 2] = to_int(60 + t * 190)
      colors[i * 4 + 3] = 255
    }
  }
  local k = 0
  for(local z = 0; z < size; z = z + 1){
    for(local x = 0; x < size; x = x + 1){
      local a = z * side + x
      local b = a + 1
      local c = a + side
      local d = c + 1
      indices:set({a, c, b, b, c, d}, k)
      k = k + 6
    }
  }
  local mesh = {
    vertex_count: vertex_count,
    triangle_count: triangle_count,
    vertices: vertices,
    normals: normals,
    colors: colors,
    indices: indices,
  }
  // raylib fills in the GPU buffers' ids
  rl.upload_mesh(mesh, false)
  return mesh
}

rl.set_config_flags(rl.FLAG_MSAA_4X_HINT)
rl.init_window(960, 600, "terrain from slang buffers")
rl.set_target_fps(60)
local model = rl.load_model_from_mesh(terrain_mesh())
local camera = {
  position: {16, 12, 16}, target: {0, 0, 0}, up: {0, 1, 0}, fovy: 45,
  projection: rl.CAMERA_PERSPECTIVE
}
local frames = to_int(require("slang/string").to_number(
  os.getenv("TERRAIN_FRAMES") or "0",
))
local frame = 0
for(not rl.window_should_close()){
  rl.update_camera(camera, rl.CAMERA_ORBITAL)
  rl.begin_drawing()
  rl.clear_background({30, 34, 44})
  rl.begin_mode_3d(camera)
  rl.draw_model(model, {0, 0, 0}, 1, rl.WHITE)
  rl.draw_model_wires(model, {0, 0.01, 0}, 1, rl.fade(rl.BLACK, 0.15))
  rl.end_mode_3d()
  rl.draw_text(rl.text_format(
    "%d vertices from slang buffers",
    model.meshes[0].vertex_count,
  ), 12, 12, 20, rl.RAYWHITE)
  rl.draw_fps(12, 40)
  rl.end_drawing()
  frame = frame + 1
  if(frames > 0 and frame >= frames){
    break
  }
}
rl.unload_model(model)
rl.close_window()
