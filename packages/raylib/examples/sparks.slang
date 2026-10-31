// Sparks: particles that follow the mouse
//
// Moving the mouse leaves a trail of sparks, holding the left button
// sprays them, the right button pulls every spark toward the pointer, and
// the wheel changes their color. Each spark is a table with a position, a
// velocity and an age; gravity and drag do the rest.
//
//   slang run examples/sparks.slang      (in packages/raylib)
//
// SPARKS_FRAMES=n quits after n frames (a smoke test without a player).
local rl = require("raylib")
local math = require("slang/math")
local os = require("slang/os")

local width = 800
local height = 450
rl.init_window(width, height, "sparks")
rl.set_target_fps(60)

local sparks = {}
local hue = 30
local limit = 1500

local func spawn(x, y, speed){
  if(len(sparks) >= limit){
    return
  }
  local angle = math.random() * math.pi * 2
  local v = speed * (0.3 + math.random() * 0.7)
  append(sparks, {
    x: x,
    y: y,
    vx: math.cos(angle) * v,
    vy: math.sin(angle) * v,
    age: 0,
    life: 0.8 + math.random() * 0.8,
    hue: hue + math.random(-20, 20),
  })
}

local frames = to_int(os.getenv("SPARKS_FRAMES") or "0")
local frame = 0
for(not rl.window_should_close()){
  local dt = rl.get_frame_time()
  local mouse = rl.get_mouse_position()
  local moved = rl.get_mouse_delta()
  hue = (hue + rl.get_mouse_wheel_move() * 15) % 360

  // a trail as the mouse moves; a spray while the button is down
  local trail = to_int(math.min(8, (math.abs(moved.x) + math.abs(moved.y)) / 4))
  for(local i = 0; i < trail; i = i + 1){
    spawn(mouse.x, mouse.y, 60)
  }
  if(rl.is_mouse_button_down(rl.MOUSE_BUTTON_LEFT)){
    for(local i = 0; i < 12; i = i + 1){
      spawn(mouse.x, mouse.y, 320)
    }
  }
  local pull = rl.is_mouse_button_down(rl.MOUSE_BUTTON_RIGHT)

  // move, age, and keep the living ones
  local alive = {}
  for(let local s in values(sparks)){
    s.age = s.age + dt
    if(s.age < s.life){
      if(pull){
        s.vx = s.vx + (mouse.x - s.x) * 4 * dt
        s.vy = s.vy + (mouse.y - s.y) * 4 * dt
      }
      s.vy = s.vy + 220 * dt
      s.vx = s.vx * (1 - 0.8 * dt)
      s.vy = s.vy * (1 - 0.8 * dt)
      s.x = s.x + s.vx * dt
      s.y = s.y + s.vy * dt
      append(alive, s)
    }
  }
  sparks = alive

  rl.begin_drawing()
  rl.clear_background({14, 14, 22})
  for(let local s in values(sparks)){
    local fade = 1 - s.age / s.life
    local color = rl.color_from_hsv(s.hue % 360, 0.8, 1)
    color.a = to_int(255 * fade)
    rl.draw_circle_v({s.x, s.y}, 1 + 3 * fade, color)
  }
  rl.draw_circle_lines(mouse.x, mouse.y, 10, rl.color_from_hsv(hue, 0.6, 1))
  rl.draw_text(
    "move: trail   left: spray   right: pull   wheel: color", 12, 12, 18,
    rl.LIGHTGRAY
  )
  rl.draw_text(
    concat(string(len(sparks)), " sparks"), 12, height - 30, 18, rl.GRAY
  )
  rl.end_drawing()

  frame = frame + 1
  if(frames > 0 and frame >= frames){
    break
  }
}
rl.close_window()
