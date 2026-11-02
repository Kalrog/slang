// A terrain mesh built in slang: vertices, normals, colors and indices are
// lists of numbers, and rl.mesh copies them into memory the mesh owns and
// uploads them to the GPU (model:unload() frees them).
//
//   slang run examples/terrain.slang      (in packages/raylib)
//
// TERRAIN_FRAMES=n quits after n frames (a smoke test without a player).
local rl = require("raylib")
local math = require("slang/math")
local os = require("slang/os")

local size = 64
local scale = 0.25

local func height(x, z){
  return math.sin(x * 0.2) * 1.5 + math.cos(z * 0.15) * 1.2 +
    math.sin((x + z) * 0.07) * 2
}

local func terrain_mesh(){
  local side = size + 1
  local vertices = {}
  local normals = {}
  local colors = {}
  local indices = {}
  for(local z = 0; z < side; z = z + 1){
    for(local x = 0; x < side; x = x + 1){
      local h = height(x, z)
      append(vertices, (x - size / 2) * scale)
      append(vertices, h * scale)
      append(vertices, (z - size / 2) * scale)
      // the normal from the slopes around the vertex
      local dx = height(x + 1, z) - height(x - 1, z)
      local dz = height(x, z + 1) - height(x, z - 1)
      local n = rl.vector3_normalize({-dx, 2, -dz})
      append(normals, n.x)
      append(normals, n.y)
      append(normals, n.z)
      // low is green, high is snow
      local t = (h + 4.7) / 9.4
      append(colors, to_int(60 + t * 190))
      append(colors, to_int(140 + t * 110))
      append(colors, to_int(60 + t * 190))
      append(colors, 255)
    }
  }
  for(local z = 0; z < size; z = z + 1){
    for(local x = 0; x < size; x = x + 1){
      local a = z * side + x
      local b = a + 1
      local c = a + side
      local d = c + 1
      for(let local v in values({a, c, b, b, c, d})){
        append(indices, v)
      }
    }
  }
  return rl.mesh({
    vertices: vertices,
    normals: normals,
    colors: colors,
    indices: indices,
  })
}

rl.init_window({
  width: 960,
  height: 600,
  title: "terrain built in slang",
  msaa: true,
  fps: 60,
})
local model = terrain_mesh():to_model()
local camera = rl.camera_3d({position: {16, 12, 16}})
local frames = to_int(require("slang/string").to_number(
  os.getenv("TERRAIN_FRAMES") or "0",
))
local frame = 0
for(not rl.window_should_close()){
  camera:update(rl.CAMERA_ORBITAL)
  rl.begin_drawing()
  rl.clear_background({30, 34, 44})
  rl.begin_mode_3d(camera)
  model:draw({0, 0, 0}, 1, rl.WHITE)
  model:draw_wires({0, 0.01, 0}, 1, rl.fade(rl.BLACK, 0.15))
  rl.end_mode_3d()
  rl.draw_text(rl.text_format(
    "%d vertices built in slang",
    model.meshes[0].vertex_count,
  ), 12, 12, 20, rl.RAYWHITE)
  rl.draw_fps(12, 40)
  rl.end_drawing()
  frame = frame + 1
  if(frames > 0 and frame >= frames){
    break
  }
}
model:unload()
rl.close_window()
