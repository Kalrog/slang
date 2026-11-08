// game/hud: what is drawn over the frame: the speed and the boost and
// hull bars, the credits, the job with its clock, the marker over the
// pad to fly to (an arrow at the edge when it is off the screen), the
// messages, and the title, pause and help screens. raylib's default font,
// spaced out, suits the neon.
local rl = require("raylib")
local math = require("slang/math")
local str = require("slang/string")
local vec = require("game/vec")
local world = require("game/world")

local m = {}

local font = null
local messages = {}

m.colors = {
  cyan: {0, 230, 255},
  magenta: {255, 60, 200},
  orange: {255, 150, 40},
  green: {90, 255, 150},
  red: {255, 70, 70},
  white: {235, 240, 255},
  dim: {140, 150, 180},
  panel: {8, 8, 20, 170},
}

func m.init(){
  font = rl.font.default
}

func m.unload(){
}

// ------------------------------------------------------------ text

local func spacing(size){
  return math.max(1, size / 10)
}

func m.measure(text, size){
  return font:measure(text, size, spacing(size)).x
}

func m.text(x, y, text, size, color){
  font:draw_text_ex(text, {x, y}, size, spacing(size), color)
}

func m.text_centered(cx, y, text, size, color){
  m.text(cx - m.measure(text, size) / 2, y, text, size, color)
}

func m.text_right(right, y, text, size, color){
  m.text(right - m.measure(text, size), y, text, size, color)
}

// text with a dark shadow and a faint glow
func m.glow(x, y, text, size, color){
  local c = {color[0], color[1], color[2], 60}
  m.text(x + 2, y + 2, text, size, {0, 0, 0, 160})
  m.text(x - 1, y, text, size, c)
  m.text(x + 1, y, text, size, c)
  m.text(x, y, text, size, color)
}

local func fade(color, a){
  return {color[0], color[1], color[2], to_int(vec.clamp(a, 0, 255))}
}

// a bar with a label
local func bar(x, y, w, h, t, color, label){
  rl.draw.rectangle(x, y, w, h, {20, 22, 36, 200})
  local fill = to_int(w * vec.clamp(t, 0, 1))
  if(fill > 0){
    rl.draw.rectangle(x, y, fill, h, color)
    rl.draw.rectangle(x, y, fill, 2, {255, 255, 255, 120})
  }
  rl.draw.rectangle_lines(x, y, w, h, {color[0], color[1], color[2], 110})
  if(label != null){
    m.text(x + w + 8, y - 2, label, 14, m.colors.dim)
  }
}

// ------------------------------------------------------------ messages

// message(text, color?, seconds?): a line in the middle for a while
func m.message(text, color, seconds){
  append(messages, {text: text, color: color or m.colors.white, age: 0, life: seconds or 2.5})
  if(len(messages) > 4){
    remove(messages, 0)
  }
}

func m.update(dt){
  local kept = {}
  for(let local msg in values(messages)){
    msg.age = msg.age + dt
    if(msg.age < msg.life){
      append(kept, msg)
    }
  }
  messages = kept
}

func m.clear(){
  messages = {}
}

local func draw_messages(w, h){
  local y = h * 0.3
  for(local i = len(messages) - 1; i >= 0; i = i - 1){
    local msg = messages[i]
    local a = 255
    if(msg.age < 0.15){
      a = msg.age / 0.15 * 255
    } else if(msg.age > msg.life - 0.5){
      a = (msg.life - msg.age) / 0.5 * 255
    }
    local size = 30
    if(msg.age < 0.2){
      size = 30 + (0.2 - msg.age) * 60
    }
    m.text_centered(w / 2 + 2, y + 2, msg.text, size, {0, 0, 0, to_int(a * 0.7)})
    m.text_centered(w / 2, y, msg.text, size, fade(msg.color, a))
    y = y + 40
  }
}

// ------------------------------------------------------------ in play

local func clock(seconds){
  local s = math.max(0, to_int(seconds))
  local mm = to_int(s / 60)
  local ss = s % 60
  local pad = ""
  if(ss < 10){
    pad = "0"
  }
  return concat(string(mm), ":", pad, string(ss))
}

local func thousands(n){
  local s = string(to_int(n))
  local out = ""
  local count = 0
  for(local i = len(s) - 1; i >= 0; i = i - 1){
    out = concat(str.substring(s, i, i + 1), out)
    count = count + 1
    if(count % 3 == 0 and i > 0){
      out = concat(",", out)
    }
  }
  return out
}

// the marker over the pad to fly to
local func marker(wld, camera, w, h, pad, color){
  local cam = camera.position
  local forward = vec.normalize(vec.sub(camera.target, cam))
  local up = camera.up
  local right = vec.normalize(vec.cross(forward, up))
  local to = vec.sub({x: pad.x, y: pad.y + 6, z: pad.z}, cam)
  local dist = vec.length(to)
  local ahead = vec.dot(to, forward)
  local label = concat(string(to_int(dist)), " m")
  local on_screen = false
  local sx = 0
  local sy = 0
  if(ahead > 1){
    local p = rl.world_to_screen({pad.x, pad.y + 6, pad.z}, camera)
    sx = p.x
    sy = p.y
    on_screen = sx > 30 and sx < w - 30 and sy > 30 and sy < h - 60
  }
  if(on_screen){
    local s = 10 + 300 / math.max(20, dist)
    rl.draw.triangle({sx, sy - s}, {sx - s * 0.7, sy}, {sx, sy + s}, fade(color, 200))
    rl.draw.triangle({sx, sy - s}, {sx, sy + s}, {sx + s * 0.7, sy}, fade(color, 200))
    rl.draw.triangle_lines({sx, sy - s - 3}, {sx - s * 0.7 - 3, sy}, {sx, sy + s + 3}, fade(color, 120))
    rl.draw.triangle_lines({sx, sy - s - 3}, {sx, sy + s + 3}, {sx + s * 0.7 + 3, sy}, fade(color, 120))
    m.text_centered(sx, sy + s + 6, label, 16, color)
  } else {
    // an arrow at the edge, in the direction of the pad on the screen
    local dx = vec.dot(to, right)
    local dy = -vec.dot(to, up)
    if(ahead < 0){
      dx = -dx
      dy = -dy
    }
    local l = math.sqrt(dx * dx + dy * dy)
    if(l < 0.001){
      return
    }
    dx = dx / l
    dy = dy / l
    local cx = w / 2
    local cy = h / 2
    local rx = w / 2 - 50
    local ry = h / 2 - 60
    local k = 1 / math.max(math.abs(dx) / rx, math.abs(dy) / ry)
    local ax = cx + dx * k
    local ay = cy + dy * k
    local px = -dy
    local py = dx
    rl.draw.triangle({ax + dx * 16, ay + dy * 16}, {ax + px * 10, ay + py * 10}, {ax - px * 10, ay - py * 10}, fade(color, 230))
    m.text_centered(ax - dx * 24, ay - dy * 24 - 8, label, 15, color)
  }
}

// the mouse's reticle: the dead zone ring in the middle, the stick where
// the mouse has pushed it
local func reticle(w, h, stick){
  local cx = w / 2
  local cy = h / 2
  local r = 150
  local c = {0, 230, 255, 90}
  rl.draw.ring({cx, cy}, r * 0.06 - 1, r * 0.06 + 1, 0, 360, 24, c)
  rl.draw.ring({cx, cy}, r - 1, r + 1, 0, 360, 48, {0, 230, 255, 35})
  local sx = cx + stick.x * r
  local sy = cy + stick.y * r
  rl.draw.line_ex({cx, cy}, {sx, sy}, 1, {0, 230, 255, 60})
  local s = 9
  rl.draw.triangle_lines({sx, sy - s}, {sx - s, sy}, {sx, sy + s}, {0, 230, 255, 220})
  rl.draw.triangle_lines({sx, sy - s}, {sx, sy + s}, {sx + s, sy}, {0, 230, 255, 220})
}

// play(wld, camera, o: {autoplay, stick?}): the overlay of a frame
func m.play(wld, camera, o){
  local w = rl.window.width
  local h = rl.window.height
  local car = wld.car
  local job = wld.job
  if(o != null and o.stick != null and wld.state == "play"){
    reticle(w, h, o.stick)
  }
  // the pad to fly to
  local target = world.target(wld)
  if(target != null and wld.state == "play"){
    local color = m.colors.cyan
    if(job.phase == "deliver"){
      color = m.colors.orange
    }
    marker(wld, camera, w, h, target, color)
  }
  // the speed, bottom left
  local kmh = to_int(car.speed * 3.6)
  local size = 54
  local color = m.colors.white
  if(car.boosting){
    color = m.colors.orange
  }
  m.glow(28, h - 118, string(kmh), size, color)
  m.text(28 + m.measure(string(kmh), size) + 10, h - 86, "km/h", 18, m.colors.dim)
  bar(28, h - 56, 220, 10, car.boost, m.colors.cyan, "BOOST")
  local hull_color = m.colors.green
  if(car.hull < 0.5){
    hull_color = m.colors.orange
  }
  if(car.hull < 0.25){
    hull_color = m.colors.red
  }
  bar(28, h - 36, 220, 10, car.hull, hull_color, "HULL")
  // the magnet
  if(car.magnet){
    local t = "MAGNET"
    local c = m.colors.green
    if(car.mode == "stick"){
      t = "LOCKED"
    } else {
      c = fade(m.colors.green, 140 + 100 * math.sin(wld.time * 8))
    }
    m.text(300, h - 60, t, 18, c)
  }
  if(car.skimming){
    m.text(300, h - 38, "SKIMMING  +boost", 16, m.colors.cyan)
  }
  // the credits and the district, top left
  m.glow(28, 20, concat("$ ", thousands(wld.credits)), 30, m.colors.green)
  m.text(28, 54, concat("LEVEL ", string(wld.level_index + 1), "  ", wld.level.name), 16, m.colors.orange)
  m.text(28, 74, concat(string(wld.level_deliveries), " / ", string(wld.level.deliveries),
    " deliveries to the next district"), 15, m.colors.dim)
  // the job, top center
  if(job != null){
    local line1 = null
    local pad = null
    local c = m.colors.cyan
    if(job.phase == "pickup"){
      line1 = concat("PICK UP ", job.what)
      pad = job.from
    } else {
      line1 = concat("DELIVER ", job.what)
      pad = job.to
      c = m.colors.orange
    }
    if(job.fragile){
      line1 = concat(line1, "  [fragile]")
    }
    local pw = 520
    rl.draw.rectangle(to_int(w / 2 - pw / 2), 14, pw, 74, m.colors.panel)
    rl.draw.rectangle(to_int(w / 2 - pw / 2), 14, pw, 2, c)
    m.text_centered(w / 2, 22, line1, 20, c)
    m.text_centered(w / 2, 46, pad.name, 17, m.colors.white)
    local tc = m.colors.white
    if(job.late){
      tc = m.colors.red
    } else if(job.left < 10){
      tc = fade(m.colors.red, 150 + 100 * math.sin(wld.time * 10))
    }
    local time_text = clock(job.left)
    if(job.late){
      time_text = "LATE"
    }
    m.text_centered(w / 2, 66, concat(time_text, "    $ ", string(job.pay)), 17, tc)
    if(job.phase == "deliver" and job.condition < 0.999){
      local cond = concat("package ", string(to_int(job.condition * 100)), "%")
      m.text_right(w / 2 + pw / 2 - 10, 66, cond, 15, m.colors.orange)
    }
  }
  if(wld.state == "wrecked"){
    m.glow(w / 2 - m.measure("WRECKED", 64) / 2, h / 2 - 40, "WRECKED", 64, m.colors.red)
  }
  if(o != null and o.autoplay){
    m.text_right(w - 24, h - 30, "autopilot", 16, m.colors.dim)
  }
  draw_messages(w, h)
}

// ------------------------------------------------------------ screens

local levels = require("game/levels")

local controls = {
  {"mouse", "steer: the car turns toward the reticle"},
  {"W", "thrust"},
  {"S", "brake, reverse"},
  {"A / D", "roll        Q / E  yaw        arrows  pitch and roll"},
  {"Space  or  left button", "boost (close calls and skimming refill it)"},
  {"F  or  right button", "magnet: lock onto the nearest surface and drive on it"},
  {"R", "back to the last pad (costs $20)"},
  {"Esc", "pause"},
  {"gamepad", "sticks, triggers, A boost, X magnet"},
}

// title(time, selected) -> {hover: index or null}: the title with the
// districts to choose from (selected is highlighted) and the controls
func m.title(time, selected){
  local w = rl.window.width
  local h = rl.window.height
  rl.draw.rectangle(0, 0, w, h, {0, 0, 10, 110})
  local title = "COURIER"
  local size = 96
  local x = w / 2 - m.measure(title, size) / 2
  local y = h * 0.08
  m.text(x + 6, y + 6, title, size, {0, 0, 0, 180})
  m.text(x - 3, y, title, size, fade(m.colors.magenta, 160))
  m.text(x + 3, y, title, size, fade(m.colors.cyan, 160))
  m.text(x, y, title, size, m.colors.white)
  m.text_centered(w / 2, y + 104, "deliveries by flying car, at night, fast", 20, m.colors.dim)
  // the districts
  local ly = h * 0.33
  m.text_centered(w / 2, ly, "DISTRICT", 15, m.colors.dim)
  ly = ly + 24
  local mouse = rl.mouse.position
  local hover = null
  local row_h = 28
  for(local i = 0; i < len(levels.list); i = i + 1){
    local lv = levels.list[i]
    local label = concat(string(i + 1), "  ", lv.name)
    local detail = concat(string(len(lv.lane_offsets)), " lane", "")
    if(len(lv.lane_offsets) > 1){
      detail = concat(detail, "s")
    }
    detail = concat(detail, " each way at ", string(len(lv.lane_levels)), " heights, ",
      string(lv.cars), " cars, ", string(to_int(lv.speed[1] * 3.6)), " km/h")
    local over = mouse.y >= ly - 4 and mouse.y < ly + row_h - 4 and mouse.x > w / 2 - 330 and mouse.x < w / 2 + 330
    if(over){
      hover = i
    }
    local c = m.colors.white
    local dc = m.colors.dim
    if(i == selected){
      rl.draw.rectangle(to_int(w / 2 - 330), to_int(ly - 4), 660, row_h, {0, 230, 255, 30})
      rl.draw.rectangle(to_int(w / 2 - 330), to_int(ly - 4), 3, row_h, m.colors.cyan)
      c = m.colors.cyan
      dc = m.colors.white
    }
    m.text(w / 2 - 310, ly, label, 20, c)
    m.text_right(w / 2 + 318, ly + 3, detail, 14, dc)
    ly = ly + row_h
  }
  m.text_centered(w / 2, ly + 2, "up / down or the mouse choose, Enter or a click starts", 14, m.colors.dim)
  // the controls
  ly = ly + 40
  for(let local c in values(controls)){
    m.text_right(w / 2 - 16, ly, c[0], 16, m.colors.cyan)
    m.text(w / 2 + 16, ly, c[1], 16, m.colors.white)
    ly = ly + 22
  }
  local a = 170 + 85 * math.sin(time * 4)
  m.text_centered(w / 2, h - 48, "press Enter to start", 22, fade(m.colors.orange, a))
  return {hover: hover}
}

func m.paused(){
  local w = rl.window.width
  local h = rl.window.height
  rl.draw.rectangle(0, 0, w, h, {0, 0, 10, 150})
  m.glow(w / 2 - m.measure("PAUSED", 60) / 2, h * 0.2, "PAUSED", 60, m.colors.white)
  local ly = h * 0.38
  for(let local c in values(controls)){
    m.text_right(w / 2 - 16, ly, c[0], 18, m.colors.cyan)
    m.text(w / 2 + 16, ly, c[1], 18, m.colors.white)
    ly = ly + 26
  }
  m.text_centered(w / 2, h - 90, "Esc resumes    Enter: back to the menu    Q quits", 20, m.colors.dim)
}

return m
