// game/hud: what is drawn over the frame: the speed and the boost and
// hull bars, the credits, the job with its clock, the marker over the
// pad to fly to (an arrow at the edge when it is off the screen), the
// messages, and the title, pause and help screens. raylib's default font,
// spaced out, suits the neon.
local rl = require("raylib")
local math = require("slang/math")
local str = require("slang/string")
local vec = require("game/vec")
local missions = require("game/missions")

local m = {}

local font = null
local messages = {}
local popups = {}

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

// near_miss(e): a near miss pops up right of the car and rises away
func m.near_miss(e){
  local color = m.colors.cyan
  local size = 22
  if(e.tier == "RAZOR"){
    color = m.colors.magenta
    size = 34
  } else if(e.tier == "TIGHT"){
    color = m.colors.orange
    size = 28
  } else if(e.tier == "THREAD"){
    color = m.colors.green
    size = 30
  }
  local text = e.tier
  if(e.oncoming){
    text = concat(text, "  ONCOMING")
  }
  append(popups, {text: concat(text, "  +$", string(e.cash)), color: color, size: size, age: 0, life: 1.1})
  if(len(popups) > 3){
    remove(popups, 0)
  }
}

func m.update(dt){
  local up = {}
  for(let local p in values(popups)){
    p.age = p.age + dt
    if(p.age < p.life){
      append(up, p)
    }
  }
  popups = up
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
  popups = {}
}

local func draw_popups(w, h){
  local n = len(popups)
  for(local i = 0; i < n; i = i + 1){
    local p = popups[i]
    local u = p.age / p.life
    local a = 255
    if(u > 0.6){
      a = (1 - u) / 0.4 * 255
    }
    // a pop as it comes, then a drift up; older ones a line higher
    local size = p.size
    if(p.age < 0.12){
      size = size * (1 + (0.12 - p.age) * 3)
    }
    // right of the car, clear of it and of the reticle's middle
    local y = h * 0.52 - u * 50 - (n - 1 - i) * 38
    m.text_centered(w * 0.76 + 2, y + 2, p.text, size, {0, 0, 0, to_int(a * 0.7)})
    m.text_centered(w * 0.76, y, p.text, size, fade(p.color, a))
  }
}

// the chain under way: its count, multiplier and cash, and its clock
local func draw_chain(wld, w, h){
  local s = wld.near_miss
  if(s.chain == 0){
    return
  }
  local cx = w / 2
  local y = h - 112
  local bw = 280
  local left = cx - bw / 2
  rl.draw.rectangle(to_int(left - 14), to_int(y - 10), bw + 28, 62, m.colors.panel)
  m.text(left, y, concat("CHAIN ", string(s.chain)), 20, m.colors.white)
  // the multiplier in quarters: x1, x1.25, x1.5 ...
  local whole = to_int(math.floor(s.mult))
  local quarters = to_int(math.floor((s.mult - whole) * 100 + 0.5))
  local mult = concat("x", string(whole))
  if(quarters > 0){
    if(quarters % 10 == 0){
      quarters = quarters / 10
    }
    mult = concat(mult, ".", string(to_int(quarters)))
  }
  m.text_centered(cx + 10, y, mult, 20, m.colors.magenta)
  m.glow(cx + bw / 2 - m.measure(concat("$", string(to_int(s.cash))), 22), y - 1,
    concat("$", string(to_int(s.cash))), 22, m.colors.green)
  // the clock, which holds (green) while skimming
  local k = vec.clamp(s.clock / 3.5, 0, 1)
  local c = m.colors.cyan
  if(wld.car.skimming){
    c = m.colors.green
  } else if(k < 0.3){
    c = m.colors.orange
  }
  rl.draw.rectangle(to_int(left), to_int(y + 32), bw, 4, {255, 255, 255, 30})
  rl.draw.rectangle(to_int(left), to_int(y + 32), to_int(bw * k), 4, c)
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

// ------------------------------------------------------------ icons

local func icon_line(a, b, t, color){
  rl.draw.line_ex(a, b, t, color)
}

// icon(kind, x, y, s, color): a mission's icon, s its half size: a
// package, a chequered flag, a crosshair, an eye
func m.icon(kind, x, y, s, color){
  local t = math.max(1.5, s * 0.16)
  if(kind == "delivery"){
    local x0 = x - s
    local x1 = x + s
    local y0 = y - s * 0.75
    local y1 = y + s * 0.75
    icon_line({x0, y0}, {x1, y0}, t, color)
    icon_line({x1, y0}, {x1, y1}, t, color)
    icon_line({x1, y1}, {x0, y1}, t, color)
    icon_line({x0, y1}, {x0, y0}, t, color)
    icon_line({x0, y - s * 0.25}, {x1, y - s * 0.25}, t, color)
    icon_line({x, y0}, {x, y - s * 0.25}, t * 1.6, color)
  } else if(kind == "race"){
    local px = x - s * 0.8
    icon_line({px, y + s}, {px, y - s}, t, color)
    local cw = s * 0.55
    local ch = s * 0.45
    for(local r = 0; r < 2; r = r + 1){
      for(local c = 0; c < 3; c = c + 1){
        local cx = px + c * cw
        local cy = y - s + r * ch
        if((r + c) % 2 == 0){
          rl.draw.rectangle_v({cx, cy}, {cw, ch}, color)
        } else {
          rl.draw.rectangle_v({cx, cy}, {cw, ch}, fade(color, 60))
        }
      }
    }
  } else if(kind == "takedown"){
    rl.draw.ring({x, y}, s * 0.62 - t / 2, s * 0.62 + t / 2, 0, 360, 32, color)
    icon_line({x - s * 1.1, y}, {x - s * 0.35, y}, t, color)
    icon_line({x + s * 0.35, y}, {x + s * 1.1, y}, t, color)
    icon_line({x, y - s * 1.1}, {x, y - s * 0.35}, t, color)
    icon_line({x, y + s * 0.35}, {x, y + s * 1.1}, t, color)
    rl.draw.circle_v({x, y}, t * 0.8, color)
  } else {
    // an eye: two arcs and the pupil
    local n = 10
    for(local k = 0; k < n; k = k + 1){
      local u0 = -1 + 2 * k / n
      local u1 = -1 + 2 * (k + 1) / n
      local h0 = s * 0.6 * (1 - u0 * u0)
      local h1 = s * 0.6 * (1 - u1 * u1)
      icon_line({x + u0 * s, y - h0}, {x + u1 * s, y - h1}, t, color)
      icon_line({x + u0 * s, y + h0}, {x + u1 * s, y + h1}, t, color)
    }
    rl.draw.circle_v({x, y}, s * 0.3, color)
  }
}

// ------------------------------------------------------------ markers

// marker(camera, w, h, p, color, o?: {icon, lines, alpha, size}): what to
// fly to, over a point of the world: a diamond (or the icon of a kind),
// with lines of text under it; an arrow at the edge of the screen when
// it is off it
local func marker(camera, w, h, p, color, o){
  o = o or {}
  local alpha = o.alpha or 1
  local cam = camera.position
  local forward = vec.normalize(vec.sub(camera.target, cam))
  local up = camera.up
  local right = vec.normalize(vec.cross(forward, up))
  local to = vec.sub(p, cam)
  local dist = vec.length(to)
  local ahead = vec.dot(to, forward)
  local label = concat(string(to_int(dist)), " m")
  local on_screen = false
  local sx = 0
  local sy = 0
  if(ahead > 1){
    local sp = rl.world_to_screen({p.x, p.y, p.z}, camera)
    sx = sp.x
    sy = sp.y
    on_screen = sx > 30 and sx < w - 30 and sy > 30 and sy < h - 60
  }
  local c = fade(color, to_int(220 * alpha))
  if(on_screen){
    local s = (o.size or 10) + 300 / math.max(20, dist)
    if(o.icon != null){
      m.icon(o.icon, sx, sy, s, c)
    } else {
      rl.draw.triangle({sx, sy - s}, {sx - s * 0.7, sy}, {sx, sy + s}, fade(color, to_int(200 * alpha)))
      rl.draw.triangle({sx, sy - s}, {sx, sy + s}, {sx + s * 0.7, sy}, fade(color, to_int(200 * alpha)))
      rl.draw.triangle_lines({sx, sy - s - 3}, {sx - s * 0.7 - 3, sy}, {sx, sy + s + 3}, fade(color, to_int(120 * alpha)))
      rl.draw.triangle_lines({sx, sy - s - 3}, {sx, sy + s + 3}, {sx + s * 0.7 + 3, sy}, fade(color, to_int(120 * alpha)))
    }
    local y = sy + s + 6
    for(let local line in values(o.lines or {label})){
      m.text_centered(sx, y, line, 16, c)
      y = y + 18
    }
  } else {
    // an arrow at the edge, in the direction of the point on the screen
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
    rl.draw.triangle({ax + dx * 16, ay + dy * 16}, {ax + px * 10, ay + py * 10}, {ax - px * 10, ay - py * 10}, fade(color, to_int(230 * alpha)))
    if(o.icon != null){
      m.icon(o.icon, ax - dx * 30, ay - dy * 30, 8, c)
      m.text_centered(ax - dx * 30, ay - dy * 30 + 12, label, 14, c)
    } else {
      m.text_centered(ax - dx * 24, ay - dy * 24 - 8, label, 15, color)
    }
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

// ------------------------------------------------------------ jobs

local func kind_color(kind){
  return missions.KINDS[kind].color
}

local func over(p, up){
  return {x: p.x, y: p.y + up, z: p.z}
}

// the offers over their pads: the icon, the kind, the pay and the time
// left (blinking when it runs out); small and faint during a job
local func draw_offers(wld, camera, w, h){
  if(wld.board == null){
    return
  }
  local busy = wld.job != null
  for(let local o in values(wld.board.offers)){
    local c = kind_color(o.kind)
    local alpha = 1
    if(o.left < 10){
      alpha = 0.55 + 0.45 * math.sin(wld.time * 10)
    }
    if(busy){
      marker(camera, w, h, over(o.pad, 8), c, {icon: o.kind, lines: {}, alpha: 0.3, size: 4})
    } else {
      marker(camera, w, h, over(o.pad, 8), c, {
        icon: o.kind, alpha: alpha, size: 8,
        lines: {
          concat(missions.KINDS[o.kind].name, "  $", string(o.pay)),
          concat(clock(o.left), "   ", string(to_int(vec.distance(o.pad, wld.car.pos))), " m"),
        },
      })
    }
  }
}

// what the job wants flown to: its pad, or the car to follow or ram (and
// a race's rival)
local func draw_target(wld, camera, w, h){
  local job = wld.job
  local t = missions.target(wld)
  if(t == null){
    return
  }
  if(t.pad != null){
    marker(camera, w, h, over(t.pad, 6), t.color)
  } else {
    marker(camera, w, h, over(t.pos, 2.5), t.color, {icon: job.kind, size: 6})
  }
  if(job.kind == "race" and job.rival != null){
    local r = job.rival.car.pos
    marker(camera, w, h, over(r, 2.5), kind_color("race"), {lines: {"RIVAL"}, alpha: 0.7, size: 3})
  }
}

local panel_w = 520

local func panel(w, color, rows){
  local ph = 22 + rows * 22
  rl.draw.rectangle(to_int(w / 2 - panel_w / 2), 14, panel_w, ph, m.colors.panel)
  rl.draw.rectangle(to_int(w / 2 - panel_w / 2), 14, panel_w, 2, color)
}

// a bar inside the panel, from its left
local func panel_bar(w, y, t, color, label){
  local x = w / 2 - panel_w / 2 + 120
  local bw = panel_w - 240
  rl.draw.rectangle(to_int(x), to_int(y), to_int(bw), 8, {255, 255, 255, 30})
  rl.draw.rectangle(to_int(x), to_int(y), to_int(bw * vec.clamp(t, 0, 1)), 8, color)
  m.text_right(x - 10, y - 4, label, 14, m.colors.dim)
}

// no job: the board, one offer a row
local func draw_board(wld, w, h){
  local offers = wld.board.offers
  panel(w, m.colors.white, len(offers) + 1)
  m.text_centered(w / 2, 22, "FLY TO AN OFFER TO TAKE IT", 18, m.colors.white)
  local y = 48
  for(let local o in values(offers)){
    local c = kind_color(o.kind)
    local x = w / 2 - panel_w / 2 + 30
    m.icon(o.kind, x, y + 8, 8, c)
    m.text(x + 22, y, missions.KINDS[o.kind].name, 16, c)
    m.text(x + 140, y, concat("$", string(o.pay)), 16, m.colors.white)
    local tc = m.colors.dim
    if(o.left < 10){
      tc = m.colors.red
    }
    m.text(x + 230, y, clock(o.left), 16, tc)
    m.text_right(w / 2 + panel_w / 2 - 20, y, concat(string(to_int(vec.distance(o.pad, wld.car.pos))), " m"), 16, m.colors.dim)
    y = y + 22
  }
}

local func draw_job(wld, job, w, h){
  local c = kind_color(job.kind)
  if(job.kind == "delivery"){
    c = m.colors.orange
    panel(w, c, 2)
    local line1 = concat("DELIVER ", job.what)
    if(job.fragile){
      line1 = concat(line1, "  [fragile]")
    }
    m.text_centered(w / 2, 22, line1, 20, c)
    m.text_centered(w / 2, 46, job.to.name, 17, m.colors.white)
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
    if(job.condition < 0.999){
      local cond = concat("package ", string(to_int(job.condition * 100)), "%")
      m.text_right(w / 2 + panel_w / 2 - 10, 66, cond, 15, m.colors.orange)
    }
  } else if(job.kind == "race"){
    panel(w, c, 2)
    m.text_centered(w / 2, 22, "RACE", 20, c)
    m.text_centered(w / 2, 46, concat("first to ", job.to.name), 17, m.colors.white)
    if(job.phase == "count"){
      m.text_centered(w / 2, 66, concat("get ready    $ ", string(job.pay)), 17, m.colors.white)
      // the count, big in the middle
      local n = string(to_int(-math.floor(-job.count)))
      m.glow(w / 2 - m.measure(n, 120) / 2, h / 2 - 30, n, 120, c)
    } else {
      local mine = vec.distance(wld.car.pos, job.to)
      local theirs = vec.distance(job.rival.car.pos, job.to)
      local text = concat("rival ", string(to_int(math.abs(theirs - mine))), " m behind")
      local tc = m.colors.green
      if(theirs < mine){
        text = concat("rival ", string(to_int(mine - theirs)), " m ahead")
        tc = m.colors.red
      }
      m.text_centered(w / 2, 66, concat(text, "    $ ", string(job.pay)), 17, tc)
    }
  } else if(job.kind == "takedown"){
    panel(w, c, 2)
    m.text_centered(w / 2, 22, "TAKEDOWN: ram it until it goes down", 20, c)
    panel_bar(w, 50, job.hull, c, "TARGET")
    local tc = m.colors.white
    if(job.left < 10){
      tc = fade(m.colors.red, 150 + 100 * math.sin(wld.time * 10))
    }
    m.text_centered(w / 2, 66, concat(clock(job.left), "    $ ", string(job.pay)), 17, tc)
  } else {
    panel(w, c, 3)
    m.text_centered(w / 2, 22, concat("TAIL it to ", job.to.name), 20, c)
    local d = job.distance or 0
    local dc = m.colors.white
    if(d < missions.TAIL_NEAR){
      dc = m.colors.red
    } else if(d > missions.TAIL_FAR){
      dc = m.colors.orange
    }
    m.text_centered(w / 2, 44, concat(string(to_int(d)), " m    $ ", string(job.pay)), 17, dc)
    panel_bar(w, 70, job.suspicion, m.colors.red, "TOO CLOSE")
    panel_bar(w, 88, job.lost, m.colors.orange, "LOSING IT")
  }
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
  // the offers (faint while a job is under way), and what to fly to
  if(wld.state == "play"){
    draw_offers(wld, camera, w, h)
    draw_target(wld, camera, w, h)
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
  if(car.in_slot){
    m.text(345, h - 60, "IN THE SLOT  +thrust", 18, m.colors.orange)
  } else if(car.mode == "stick"){
    m.text(345, h - 60, "LOCKED  F jumps off", 18, m.colors.green)
  }
  if(car.skimming){
    m.text(345, h - 38, "SKIMMING  +boost", 16, m.colors.cyan)
  }
  if(wld.state == "play"){
    draw_chain(wld, w, h)
    draw_popups(w, h)
  }
  // the credits and the district, top left
  m.glow(28, 20, concat("$ ", thousands(wld.credits)), 30, m.colors.green)
  m.text(28, 54, concat("LEVEL ", string(wld.level_index + 1), "  ", wld.level.name), 16, m.colors.orange)
  m.text(28, 74, concat(string(wld.level_jobs), " / ", string(wld.level.jobs),
    " jobs to the next district"), 15, m.colors.dim)
  // the job, top center (or the board, when there is none)
  if(job != null){
    draw_job(wld, job, w, h)
  } else if(wld.board != null){
    draw_board(wld, w, h)
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
  {"Space  or  left button", "boost (near misses and skimming refill it)"},
  {"F  or  right button", "jump off a surface (the magnet grabs walls and roofs by itself)"},
  {"amber slots", "too tight to fly level: ride a wall through, on your side"},
  {"R", "back to the last pad (costs $20)"},
  {"M", "music on or off"},
  {"Esc", "pause"},
  {"gamepad", "sticks, triggers, A boost, X jump"},
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
  m.text_centered(w / 2, y + 104, "jobs by flying car, at night, fast", 20, m.colors.dim)
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
