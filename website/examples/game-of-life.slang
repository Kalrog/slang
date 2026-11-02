// Game of Life

// Conway's Game of Life on raylib: a cell with three live neighbours is
// born, one with two or three survives, the rest die. The grid wraps
// around at the edges. Click or drag to draw cells; space pauses, N steps
// once, R fills the grid at random and C clears it.
local rl = require("raylib")
local math = require("slang/math")
local os = require("slang/os")

local size = 10
local cols = 80
local rows = 45
rl.init_window(cols * size, rows * size, "game of life")
rl.set_target_fps(60)

local func grid(fill){
  local g = {}
  for(local y = 0; y < rows; y = y + 1){
    local row = {}
    for(local x = 0; x < cols; x = x + 1){
      append(row, fill(x, y))
    }
    append(g, row)
  }
  return g
}

local func random_grid(){
  return grid(func(x, y){ return math.random() < 0.25 })
}

local cells = random_grid()

local func alive(x, y){
  return cells[(y + rows) % rows][(x + cols) % cols]
}

local func step(){
  cells = grid(func(x, y){
    local n = 0
    for(local dy = -1; dy <= 1; dy = dy + 1){
      for(local dx = -1; dx <= 1; dx = dx + 1){
        if((dx != 0 or dy != 0) and alive(x + dx, y + dy)){
          n = n + 1
        }
      }
    }
    return n == 3 or (n == 2 and cells[y][x])
  })
}

local paused = false
local generation = 0
local clock = 0
local per_second = 12
// LIFE_FRAMES=n quits after n frames (a smoke test without a player)
local frames = to_int(os.getenv("LIFE_FRAMES") or "0")
local frame = 0
for(not rl.window_should_close()){
  if(rl.is_key_pressed(rl.KEY_SPACE)){ paused = not paused }
  if(rl.is_key_pressed(rl.KEY_R)){
    cells = random_grid()
    generation = 0
  }
  if(rl.is_key_pressed(rl.KEY_C)){
    cells = grid(func(x, y){ return false })
    generation = 0
  }
  // drawing with the mouse
  if(rl.is_mouse_button_down(rl.MOUSE_BUTTON_LEFT)){
    local m = rl.get_mouse_position()
    local x = to_int(m.x / size)
    local y = to_int(m.y / size)
    if(x >= 0 and x < cols and y >= 0 and y < rows){
      cells[y][x] = true
    }
  }
  // a fixed number of generations a second, whatever the frame rate
  clock = clock + rl.get_frame_time()
  local stepping = rl.is_key_pressed(rl.KEY_N)
  if(not paused and clock >= 1 / per_second){
    clock = 0
    stepping = true
  }
  if(stepping){
    step()
    generation = generation + 1
  }

  rl.begin_drawing()
  rl.clear_background({14, 14, 22})
  local living = 0
  for(local y = 0; y < rows; y = y + 1){
    for(local x = 0; x < cols; x = x + 1){
      if(cells[y][x]){
        living = living + 1
        local hue = (x * 3 + y * 5 + generation) % 360
        local color = rl.color_from_hsv(hue, 0.6, 1)
        rl.draw_rectangle(x * size, y * size, size - 1, size - 1, color)
      }
    }
  }
  local status = concat("generation ", generation, "   ", living, " alive")
  rl.draw_text(
    concat(status, paused and "   (paused)" or ""), 10, 10, 20, rl.RAYWHITE
  )
  rl.draw_text(
    "drag: draw   space: pause   N: step   R: random   C: clear", 10,
    rows * size - 26, 18, rl.LIGHTGRAY
  )
  rl.end_drawing()

  frame = frame + 1
  if(frames > 0 and frame >= frames){
    break
  }
}
rl.close_window()
