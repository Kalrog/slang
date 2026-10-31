// 3D cubes: a wave of spinning cubes under an orbiting camera
//
// One cube model (a mesh raylib generates) drawn many times, each with its
// own position, rotation, height and color. The camera circles the scene
// by itself; the mouse wheel zooms.
//
//   slang run examples/cubes.slang      (in packages/raylib)
//
// CUBES_FRAMES=n quits after n frames (a smoke test without a player).
local rl = require("raylib")
local math = require("slang/math")
local os = require("slang/os")

rl.set_config_flags(rl.FLAG_MSAA_4X_HINT)
rl.init_window(800, 450, "cubes")
rl.set_target_fps(60)

local cube = rl.load_model_from_mesh(rl.gen_mesh_cube(1, 1, 1))
local camera = {
  position: {12, 9, 12},
  target: {0, 1, 0},
  up: {0, 1, 0},
  fovy: 45,
  projection: rl.CAMERA_PERSPECTIVE,
}

local frames = to_int(os.getenv("CUBES_FRAMES") or "0")
local frame = 0
local time = 0
for(not rl.window_should_close()){
  local dt = rl.get_frame_time()
  time = time + dt
  rl.update_camera(camera, rl.CAMERA_ORBITAL)
  // the wheel moves the camera toward the target or away
  local wheel = rl.get_mouse_wheel_move()
  if(wheel != 0){
    local p = camera.position
    local k = 1 - wheel * 0.1
    camera.position = {p.x * k, p.y * k, p.z * k}
  }

  rl.begin_drawing()
  rl.clear_background({22, 24, 34})
  rl.begin_mode_3d(camera)
  rl.draw_grid(16, 1)
  for(local x = -3; x <= 3; x = x + 1){
    for(local z = -3; z <= 3; z = z + 1){
      local wave = math.sin(time * 2 + x * 0.7 + z * 0.5)
      local h = 1.5 + wave
      local position = {x * 1.6, h / 2, z * 1.6}
      local angle = time * 60 + (x + z) * 15
      local hue = ((x + 3) * 30 + (z + 3) * 12 + time * 40) % 360
      local color = rl.color_from_hsv(hue, 0.65, 0.95)
      local size = {0.9, h, 0.9}
      rl.draw_model_ex(cube, position, {0, 1, 0}, angle, size, color)
      rl.draw_model_wires_ex(cube, position, {0, 1, 0}, angle, size, {
        0, 0, 0, 90
      })
    }
  }
  rl.end_mode_3d()
  rl.draw_text("cubes, drawn by slang", 12, 12, 20, rl.RAYWHITE)
  rl.draw_text("mouse wheel: zoom", 12, 38, 16, rl.LIGHTGRAY)
  rl.draw_fps(12, 420)
  rl.end_drawing()

  frame = frame + 1
  if(frames > 0 and frame >= frames){
    break
  }
}
rl.unload_model(cube)
rl.close_window()
