// Breakout on raylib. The window, drawing and keyboard come from the native
// extension extensions/native/raylib.c (loaded as raylib.dylib/.so through
// require); everything else is slang.
//
//   make breakout        (or: SLANG_NATIVE_PATH=zig/zig-out/lib slang run examples/breakout/main.slang)
//
// Left/right or A/D move the paddle, space launches the ball, R restarts,
// escape quits. BREAKOUT_FRAMES=n in the environment quits after n frames
// and BREAKOUT_AUTOPLAY=1 lets the paddle play by itself (both are used to
// smoke-test the extension without a player).
local rl = require("raylib")
local os = require("slang/os")
local math = require("slang/math")

local width = 800
local height = 600

local colors = {
  background: {24, 24, 36},
  paddle: {230, 230, 240},
  ball: {255, 210, 80},
  text: {200, 200, 210},
  dim: {120, 120, 140},
  rows: {{232, 80, 90}, {240, 150, 60}, {240, 220, 80}, {110, 210, 120}, {90, 160, 240}, {170, 110, 230}},
}

local game = {}

local func new_bricks(){
  local bricks = {}
  local rows = len(colors.rows)
  local cols = 10
  local gap = 6
  local w = (width - gap * (cols + 1)) / cols
  local h = 22
  for(local r = 0; r < rows; r = r + 1){
    for(local c = 0; c < cols; c = c + 1){
      append(bricks, {
        x: gap + c * (w + gap),
        y: 60 + r * (h + gap),
        w: w,
        h: h,
        color: colors.rows[r],
        points: (rows - r) * 10,
        alive: true,
      })
    }
  }
  return bricks
}

local func reset_ball(){
  game.ball = {x: game.paddle.x + game.paddle.w / 2, y: game.paddle.y - 12, r: 8, vx: 0, vy: 0, launched: false}
}

local func new_game(){
  game.paddle = {x: width / 2 - 50, y: height - 40, w: 100, h: 14, speed: 520}
  game.bricks = new_bricks()
  game.score = 0
  game.lives = 3
  game.state = "playing"   // playing, won, lost
  reset_ball()
}

local func launch(){
  local angle = math.random(-0.6, 0.6)
  local speed = 380
  game.ball.vx = speed * math.sin(angle)
  game.ball.vy = -speed * math.cos(angle)
  game.ball.launched = true
}

local func clamp(v, lo, hi){
  if(v < lo){ return lo }
  if(v > hi){ return hi }
  return v
}

// circle (ball) against axis aligned rectangle
local func hits(ball, box){
  local cx = clamp(ball.x, box.x, box.x + box.w)
  local cy = clamp(ball.y, box.y, box.y + box.h)
  local dx = ball.x - cx
  local dy = ball.y - cy
  return dx * dx + dy * dy <= ball.r * ball.r
}

local autoplay = os.getenv("BREAKOUT_AUTOPLAY") != null

local func update_paddle(dt){
  local p = game.paddle
  local dir = 0
  if(autoplay){
    local center = p.x + p.w / 2
    if(game.ball.x < center - 4){ dir = -1 } else if(game.ball.x > center + 4){ dir = 1 }
  } else {
    if(rl.is_key_down(rl.KEY_LEFT) or rl.is_key_down(rl.KEY_A)){ dir = dir - 1 }
    if(rl.is_key_down(rl.KEY_RIGHT) or rl.is_key_down(rl.KEY_D)){ dir = dir + 1 }
  }
  p.x = clamp(p.x + dir * p.speed * dt, 0, width - p.w)
  if(not game.ball.launched){
    game.ball.x = p.x + p.w / 2
    if(autoplay or rl.is_key_pressed(rl.KEY_SPACE)){ launch() }
  }
}

local func update_ball(dt){
  local b = game.ball
  if(not b.launched){ return null }
  b.x = b.x + b.vx * dt
  b.y = b.y + b.vy * dt

  // walls
  if(b.x - b.r < 0){ b.x = b.r; b.vx = -b.vx }
  if(b.x + b.r > width){ b.x = width - b.r; b.vx = -b.vx }
  if(b.y - b.r < 0){ b.y = b.r; b.vy = -b.vy }

  // paddle: the hit position steers the ball
  local p = game.paddle
  if(b.vy > 0 and hits(b, p)){
    local rel = (b.x - (p.x + p.w / 2)) / (p.w / 2)
    local speed = math.sqrt(b.vx * b.vx + b.vy * b.vy) * 1.02
    local angle = rel * 1.1
    b.vx = speed * math.sin(angle)
    b.vy = -speed * math.cos(angle)
    b.y = p.y - b.r
  }

  // bricks: one hit per frame
  for(let local brick in values(game.bricks)){
    if(brick.alive and hits(b, brick)){
      brick.alive = false
      game.score = game.score + brick.points
      // bounce on the side that was crossed
      local overlap_x = math.min(b.x + b.r - brick.x, brick.x + brick.w - (b.x - b.r))
      local overlap_y = math.min(b.y + b.r - brick.y, brick.y + brick.h - (b.y - b.r))
      if(overlap_x < overlap_y){ b.vx = -b.vx } else { b.vy = -b.vy }
      break
    }
  }

  if(b.y - b.r > height){
    game.lives = game.lives - 1
    if(game.lives <= 0){ game.state = "lost" } else { reset_ball() }
  }
}

local func bricks_left(){
  local n = 0
  for(let local brick in values(game.bricks)){
    if(brick.alive){ n = n + 1 }
  }
  return n
}

local func update(dt){
  if(rl.is_key_pressed(rl.KEY_R)){ new_game() }
  if(game.state != "playing"){ return null }
  update_paddle(dt)
  update_ball(dt)
  if(bricks_left() == 0){ game.state = "won" }
}

local func text_centered(s, y, size, color){
  rl.draw_text(s, width / 2 - rl.measure_text(s, size) / 2, y, size, color)
}

local func draw(){
  rl.begin_drawing()
  rl.clear_background(colors.background)
  for(let local brick in values(game.bricks)){
    if(brick.alive){
      rl.draw_rectangle(brick.x, brick.y, brick.w, brick.h, brick.color)
    }
  }
  local p = game.paddle
  rl.draw_rectangle(p.x, p.y, p.w, p.h, colors.paddle)
  rl.draw_circle(game.ball.x, game.ball.y, game.ball.r, colors.ball)

  rl.draw_text(concat("Score ", game.score), 16, 16, 24, colors.text)
  local lives = concat("Lives ", game.lives)
  rl.draw_text(lives, width - 16 - rl.measure_text(lives, 24), 16, 24, colors.text)

  if(game.state == "playing" and not game.ball.launched){
    text_centered("Space to launch", height / 2 + 40, 24, colors.dim)
  } else if(game.state == "won"){
    text_centered("You win!", height / 2 - 20, 48, colors.ball)
    text_centered("R to play again", height / 2 + 40, 24, colors.dim)
  } else if(game.state == "lost"){
    text_centered("Game over", height / 2 - 20, 48, colors.rows[0])
    text_centered("R to play again", height / 2 + 40, 24, colors.dim)
  }
  rl.end_drawing()
}

rl.init_window(width, height, "Slang Breakout")
rl.set_target_fps(60)
new_game()

local frame_limit = os.getenv("BREAKOUT_FRAMES")
local frames = 0
for(not rl.window_should_close(); frames = frames + 1){
  if(frame_limit != null and frames >= to_int(frame_limit)){ break }
  update(rl.get_frame_time())
  draw()
}
rl.close_window()
print("breakout: ", frames, " frames, score ", game.score, "\n")
