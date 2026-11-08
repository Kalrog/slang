// Tower: 3D physics with Jolt, drawn with raylib
//
// A tower of boxes on a floor. Click to throw a ball from the camera
// through the pointer; hold the right button and move the mouse to walk
// around the tower; R builds it again. Each frame asks Jolt for every
// body's transform and draws one cube or sphere model with it.
//
//   slang run tower.slang      (in examples/physics)
//
// PHYSICS_FRAMES=n quits after n frames (a smoke test without a player).
local rl = require("raylib")
local jolt = require("jolt")
local math = require("slang/math")
local os = require("slang/os")

rl.config_flags = rl.FLAG_MSAA_4X_HINT
rl.window.open(800, 450, "tower")
rl.target_fps = 60

local cube = rl.model(rl.mesh.cube(1, 1, 1))
local sphere = rl.model(rl.mesh.sphere(1, 12, 16))

local world = jolt.world({gravity: {0, -9.81, 0}})
world:create_body({
  shape: jolt.box({30, 1, 30}),
  position: {0, -1, 0},
})

// what is drawn: {body, model, size, color}
local things = {}
local balls = {}

local func add(def, model, size, color){
  local body = world:create_body(def)
  local thing = {body: body, model: model, size: size, color: color}
  append(things, thing)
  return thing
}

local box_shape = jolt.box({0.5, 0.5, 0.5})
local func build(){
  for(local level = 0; level < 8; level = level + 1){
    for(local i = 0; i < 3; i = i + 1){
      for(local j = 0; j < 3; j = j + 1){
        local hue = (level * 40 + (i + j) * 8) % 360
        add({
          shape: box_shape,
          position: {i - 1, 0.5 + level, j - 1},
          motion: "dynamic",
          friction: 0.6,
        }, cube, {1, 1, 1}, rl.color.from_hsv(hue, 0.5, 0.95))
      }
    }
  }
}

local func clear(){
  for(let local t in values(things)){
    t.body:destroy()
  }
  things = {}
  balls = {}
}

// heavy (iron, not water): a ball knocks boxes over
local ball_shape = jolt.sphere(0.35, {density: 8000})
local func throw(camera){
  local ray = rl.screen_to_world_ray(rl.mouse.position, camera)
  local d = ray.direction
  local ball = add({
    shape: ball_shape,
    position: ray.position,
    motion: "dynamic",
    linear_velocity: {d.x * 30, d.y * 30, d.z * 30},
    restitution: 0.3,
  }, sphere, {0.35, 0.35, 0.35}, rl.color.from_hsv(10, 0.7, 1))
  append(balls, ball)
  // the oldest balls go once there are many
  if(len(balls) > 30){
    local old = remove(balls, 0)
    old.body:destroy()
    local kept = {}
    for(let local t in values(things)){
      if(t != old){
        append(kept, t)
      }
    }
    things = kept
  }
}

build()

local yaw = 0.8
local pitch = 0.45
local distance = 18
local camera = {
  position: {0, 0, 0},
  target: {0, 3, 0},
  up: {0, 1, 0},
  fovy: 45,
  projection: rl.CAMERA_PERSPECTIVE,
}

local frames = to_int(os.getenv("PHYSICS_FRAMES") or "0")
local frame = 0
local step = 1 / 60
local pending = 0
for(not rl.window.should_close){
  if(rl.mouse.down(rl.MOUSE_BUTTON_RIGHT)){
    local delta = rl.mouse.delta
    yaw = yaw - delta.x * 0.01
    pitch = math.max(0.05, math.min(1.4, pitch + delta.y * 0.01))
  }
  distance = math.max(6, math.min(40, distance - rl.mouse.wheel))
  camera.position = {
    math.cos(yaw) * math.cos(pitch) * distance,
    3 + math.sin(pitch) * distance,
    math.sin(yaw) * math.cos(pitch) * distance,
  }
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)){
    throw(camera)
  }
  if(rl.key.pressed(rl.KEY_R)){
    clear()
    build()
  }

  // fixed steps of 1/60 s, however fast frames come
  pending = math.min(pending + rl.frame_time, 0.1)
  for(pending >= step){
    world:step(step)
    pending = pending - step
  }

  rl.drawing{
    rl.draw.clear({24, 26, 36})
    rl.mode_3d(camera){
      rl.draw.plane({0, 0, 0}, {60, 60}, {52, 56, 72})
      rl.draw.grid(30, 2)
      for(let local t in values(things)){
        local m = jolt.mat4_to_matrix(t.body.world_transform)
        local model = t.model
        model.transform = rl.matrix.multiply(
          rl.matrix.scale(t.size[0], t.size[1], t.size[2]),
          m,
        )
        model:draw({0, 0, 0}, 1, t.color)
        model:draw_wires({0, 0, 0}, 1, {0, 0, 0, 70})
      }
    }
    rl.draw.text(
      "click: throw a ball   right drag: walk around   R: rebuild", 12, 12, 18,
      rl.LIGHTGRAY
    )
    rl.draw.text(concat(string(len(things)), " bodies"), 12, 36, 16, rl.GRAY)
    rl.draw.fps(12, 420)
  }

  frame = frame + 1
  if(frames > 0 and frame >= frames){
    break
  }
}
world:destroy()
cube:unload()
sphere:unload()
rl.window.close()
