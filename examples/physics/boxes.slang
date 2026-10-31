// Boxes: 2D physics with Box2D, drawn with raylib
//
// A pyramid of boxes in a room. Click to drop a box (or a ball, with
// shift) at the pointer; hold the right button on a body to grab it, then
// let go to throw it. Box2D works in meters with y up; the screen is pixels
// with y down, so `screen` and `world` convert between them.
//
//   slang run boxes.slang      (in examples/physics)
//
// PHYSICS_FRAMES=n quits after n frames (a smoke test without a player).
local rl = require("raylib")
local b2 = require("box2d")
local math = require("slang/math")
local os = require("slang/os")

local width = 800
local height = 450
local scale = 30
rl.init_window(width, height, "boxes")
rl.set_target_fps(60)

local func screen(p){
  return {width / 2 + p.x * scale, height - 20 - p.y * scale}
}
local func world(p){
  return {x: (p.x - width / 2) / scale, y: (height - 20 - p.y) / scale}
}

local space = b2 .create_world({gravity: {0, -10}})

// the room: a floor and two walls on one static body
local room = b2 .create_body(space, {})
b2 .create_polygon_shape(
  room, {}, b2 .make_offset_box(14, 0.5, {0, -0.5}, b2 .make_rot(0))
)
b2 .create_polygon_shape(
  room, {}, b2 .make_offset_box(0.5, 10, {-13.8, 10}, b2 .make_rot(0))
)
b2 .create_polygon_shape(
  room, {}, b2 .make_offset_box(0.5, 10, {13.8, 10}, b2 .make_rot(0))
)

// what is drawn: {body, shape, kind, size, color}
local things = {}

local func add(kind, x, y, size){
  local body = b2 .create_body(space, {
    type: b2 .dynamic_body,
    position: {x, y},
    rotation: b2 .make_rot(0),
  })
  local def = {density: 1, material: {friction: 0.6, restitution: 0.1}}
  local shape = null
  if(kind == "ball"){
    shape = b2 .create_circle_shape(body, def, {center: {0, 0}, radius: size})
  } else {
    shape = b2 .create_polygon_shape(body, def, b2 .make_box(size, size))
  }
  local hue = (len(things) * 37) % 360
  append(things, {
    body: body,
    shape: shape,
    kind: kind,
    size: size,
    color: rl.color_from_hsv(hue, 0.55, 0.95),
  })
}

// the pyramid
local rows = 9
for(local row = 0; row < rows; row = row + 1){
  for(local i = 0; i < rows - row; i = i + 1){
    add("box", (i - (rows - row - 1) / 2) * 1.05, 0.5 + row * 1.0, 0.5)
  }
}

local func thing_at(p){
  for(let local t in values(things)){
    if(b2 .shape_test_point(t.shape, p)){
      return t
    }
  }
  return null
}

local frames = to_int(os.getenv("PHYSICS_FRAMES") or "0")
local frame = 0
local held = null
local step = 1 / 60
local pending = 0
for(not rl.window_should_close()){
  local mouse = world(rl.get_mouse_position())

  if(rl.is_mouse_button_pressed(rl.MOUSE_BUTTON_LEFT) and len(things) < 300){
    local shift = rl.is_key_down(rl.KEY_LEFT_SHIFT) or
      rl.is_key_down(rl.KEY_RIGHT_SHIFT)
    if(shift){
      add("ball", mouse.x, mouse.y, 0.3 + math.random() * 0.4)
    } else {
      add("box", mouse.x, mouse.y, 0.3 + math.random() * 0.5)
    }
  }
  if(rl.is_mouse_button_pressed(rl.MOUSE_BUTTON_RIGHT)){
    held = thing_at(mouse)
  }
  if(rl.is_mouse_button_released(rl.MOUSE_BUTTON_RIGHT)){
    held = null
  }
  if(held != null){
    // pulled toward the pointer: its velocity points there, so letting go
    // throws it
    local p = b2 .body_get_position(held.body)
    b2 .body_set_linear_velocity(held.body, b2 .mul_sv(12, b2 .sub(mouse, p)))
    b2 .body_set_awake(held.body, true)
  }

  // fixed steps of 1/60 s, however fast frames come
  pending = math.min(pending + rl.get_frame_time(), 0.1)
  for(pending >= step){
    b2 .world_step(space, step, 4)
    pending = pending - step
  }

  rl.begin_drawing()
  rl.clear_background({28, 30, 40})
  local floor = screen({x: -13.3, y: 0})
  rl.draw_rectangle(floor[0], floor[1], 26.6 * scale, 20, {60, 64, 82})
  for(let local t in values(things)){
    local p = screen(b2 .body_get_position(t.body))
    local angle = b2 .rot_get_angle(b2 .body_get_rotation(t.body))
    local color = t.color
    if(t == held){
      color = rl.WHITE
    }
    if(t.kind == "ball"){
      local r = t.size * scale
      rl.draw_circle_v(p, r, color)
      // a spoke shows the ball turn
      rl.draw_line_ex(
        p, {p[0] + math.cos(angle) * r, p[1] - math.sin(angle) * r}, 2, {
          0, 0, 0, 90
        }
      )
    } else {
      local s = t.size * 2 * scale
      rl.draw_rectangle_pro(
        {p[0], p[1], s, s}, {s / 2, s / 2}, -angle * 180 / math.pi, color
      )
    }
  }
  rl.draw_text(
    "click: drop a box   shift+click: a ball   right drag: throw", 12, 12, 18,
    rl.LIGHTGRAY
  )
  rl.draw_text(concat(string(len(things)), " bodies"), 12, 36, 16, rl.GRAY)
  rl.end_drawing()

  frame = frame + 1
  if(frames > 0 and frame >= frames){
    break
  }
}
b2 .destroy_world(space)
rl.close_window()
