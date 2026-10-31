// game/hud: what is drawn over the world: the score with its rolling
// counter and the notes of what scored, the target bar, the ammo, the
// charge; and the screens: the title with the levels, cleared, out of
// ammo, paused, help. The screens return what was chosen.
local rl = require("raylib")
local math = require("slang/math")
local os = require("slang/os")
local str = require("slang/string")
local ui = require("game/ui")
local ammo = require("game/ammo")
local vec = require("game/vec")

local m = {}

local font = null
local shown_score = 0
local popups = {}
local flash = 0
local messages = {}

// init(): the font (assets/Fredoka.ttf when it is there)
func m.init(){
  local path = concat(m.dir or ".", "/assets/Fredoka.ttf")
  if(os.exists(path)){
    font = rl.load_font_ex(path, 64, null)
    rl.set_texture_filter(font.texture, rl.TEXTURE_FILTER_BILINEAR)
    ui.set_font(font)
  }
}

func m.unload(){
  if(font != null){
    rl.unload_font(font)
    font = null
    ui.set_font(null)
  }
}

// reset(score): a new level
func m.reset(score){
  shown_score = score or 0
  popups = {}
  messages = {}
  flash = 0
}

// ------------------------------------------------------------ events

// take(events, sound): the world's scoring events become notes; the
// bigger ones ding
func m.take(events, sound){
  for(let local ev in values(events)){
    append(popups, {label: ev.label, points: ev.points, age: 0})
    if(len(popups) > 8){
      remove(popups, 0)
    }
    flash = 1
    if(sound != null){
      if(ev.points >= 500){
        sound.play("ding_big", null, 0.6)
      } else {
        sound.play("ding", null, 0.35)
      }
    }
  }
}

// message(text, seconds): a line in the middle of the screen for a while
func m.message(text, seconds){
  append(messages, {text: text, age: 0, life: seconds or 2.5})
}

func m.update(dt, score){
  // the counter rolls toward the score
  local gap = score - shown_score
  if(gap != 0){
    local step = math.max(1, math.abs(gap) * dt * 6)
    if(math.abs(gap) <= step){
      shown_score = score
    } else if(gap > 0){
      shown_score = shown_score + step
    } else {
      shown_score = shown_score - step
    }
  }
  local kept = {}
  for(let local p in values(popups)){
    p.age = p.age + dt
    if(p.age < 3){
      append(kept, p)
    }
  }
  popups = kept
  kept = {}
  for(let local msg in values(messages)){
    msg.age = msg.age + dt
    if(msg.age < msg.life){
      append(kept, msg)
    }
  }
  messages = kept
  flash = math.max(0, flash - dt * 3)
}

// ------------------------------------------------------------ in play

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

m.thousands = thousands

// play(state): state = {score, target, ammo: {{type, count}}, selected:
// int, charge: float, charging: bool, level: Level, cleared: bool,
// aim: {x, y} (the pointer), hint?: string}
func m.play(state){
  local w = rl.get_screen_width()
  local h = rl.get_screen_height()
  // the score, top left
  local size = 44 + flash * 10
  ui.shadowed(24, 14, thousands(shown_score), size, {255, 236, 150})
  local t = 0
  if(state.target > 0){
    t = state.score / state.target
  }
  local bar_w = 260
  ui.bar(24, 70, bar_w, 12, t, {255, 196, 64})
  local target_text = concat("target ", thousands(state.target))
  if(state.cleared){
    target_text = "target reached!"
  }
  ui.shadowed(24, 86, target_text, 18, {230, 230, 240})
  // what scored, sliding in under it
  local y = 116
  for(local i = len(popups) - 1; i >= 0; i = i - 1){
    local p = popups[i]
    local a = 255
    if(p.age > 2.2){
      a = to_int(255 * (3 - p.age) / 0.8)
    }
    local slide = 0
    if(p.age < 0.2){
      slide = (0.2 - p.age) / 0.2 * -40
    }
    local scale = 1
    if(p.age < 0.25){
      scale = 1 + (0.25 - p.age) * 1.6
    }
    ui.shadowed(24 + slide, y, concat("+", thousands(p.points)), 22 * scale, {255, 240, 120, a})
    ui.shadowed(110 + slide, y + 3, p.label, 18, {240, 240, 248, a})
    y = y + 26
  }
  // the ammo, bottom center
  local n = len(state.ammo)
  local bw = 118
  local bh = 54
  local total = n * bw + (n - 1) * 8
  local x0 = (w - total) / 2
  for(local i = 0; i < n; i = i + 1){
    local a = state.ammo[i]
    local kind = ammo.types[a.type]
    local x = x0 + i * (bw + 8)
    local by = h - bh - 18
    local color = {24, 28, 40, 200}
    if(i == state.selected){
      color = {255, 196, 64, 230}
    }
    if(a.count <= 0){
      color = {24, 28, 40, 120}
    }
    rl.draw_rectangle_rounded({x, by, bw, bh}, 0.25, 6, color)
    local tc = {236, 238, 244}
    if(i == state.selected){
      tc = {30, 24, 12}
    }
    if(a.count <= 0){
      tc = {120, 120, 130}
    }
    ui.text(x + 10, by + 6, kind.name, 17, tc)
    ui.text(x + 10, by + 28, concat("x ", string(a.count)), 20, tc)
    ui.text_right(x + bw - 8, by + 4, kind.key, 14, tc)
  }
  // the charge, over the ammo
  if(state.charging or state.charge > 0){
    local cw = 320
    local cx = (w - cw) / 2
    local cy = h - bh - 50
    local c = state.charge
    local color = {to_int(80 + c * 175), to_int(220 - c * 120), 60}
    ui.bar(cx, cy, cw, 16, c, color)
    ui.shadowed_centered(w / 2, cy - 24, concat("power ", string(to_int(c * 100)), "%"), 18, {255, 255, 255})
  }
  // the level's name, top right, a hint, and the frame rate
  ui.shadowed(w - 24 - ui.measure(state.level.name, 22), 14, state.level.name, 22, {230, 230, 240})
  local fps = concat(string(rl.get_fps()), " fps")
  ui.shadowed(w - 24 - ui.measure(fps, 14), h - 26, fps, 14, {200, 204, 216, 160})
  if(state.hint != null){
    ui.shadowed(w - 24 - ui.measure(state.hint, 16), 42, state.hint, 16, {200, 204, 216})
  }
  for(let local msg in values(messages)){
    local a = 255
    if(msg.age < 0.3){
      a = to_int(255 * msg.age / 0.3)
    } else if(msg.age > msg.life - 0.5){
      a = to_int(255 * (msg.life - msg.age) / 0.5)
    }
    ui.shadowed_centered(w / 2, h * 0.3, msg.text, 40, {255, 240, 200, a})
  }
}

// ------------------------------------------------------------ screens

local func dim(alpha){
  rl.draw_rectangle(0, 0, rl.get_screen_width(), rl.get_screen_height(), {8, 10, 16, alpha or 150})
}

local func title_text(w, y){
  ui.shadowed_centered(w / 2 + 4, y + 4, "SIEGE", 110, {0, 0, 0, 120})
  ui.text_centered(w / 2, y, "SIEGE", 110, {255, 204, 72})
  ui.text_centered(w / 2, y + 108, "drive the catapult, wreck the place", 24, {236, 238, 244})
}

// title(levels, selected, best) -> {start?: int, editor?: bool, edit?:
// int, selected: int, quit?: bool}: the title screen with the levels
func m.title(levels, selected, best){
  local w = rl.get_screen_width()
  local h = rl.get_screen_height()
  dim(90)
  title_text(w, 40)
  local result = {selected: selected}
  local pw = 520
  local px = (w - pw) / 2
  local py = 200
  local row = 46
  local ph = 70 + len(levels) * row + 60
  ui.panel(px, py, pw, ph, "Levels")
  for(local i = 0; i < len(levels); i = i + 1){
    local lv = levels[i]
    local y = py + 44 + i * row
    local label = lv.name
    if(ui.button(px + 16, y, pw - 32 - 90, row - 8, label, {active: i == selected})){
      result.selected = i
      result.start = i
    }
    local b = best[lv.key]
    local tc = ui.colors.dim
    local text = concat("target ", thousands(lv.target))
    if(b != null){
      text = concat(thousands(b), " best")
      if(b >= lv.target){
        tc = {120, 230, 140}
      }
    }
    ui.text_right(px + pw - 20, y + 10, text, 15, tc)
  }
  local y = py + 44 + len(levels) * row + 12
  if(ui.button(px + 16, y, (pw - 40) / 2, 38, "Level editor", {size: 18})){
    result.editor = true
  }
  if(ui.button(px + 16 + (pw - 40) / 2 + 8, y, (pw - 40) / 2, 38, "Edit selected", {size: 18})){
    result.edit = selected
  }
  ui.text_centered(w / 2, h - 60, "WASD drive · mouse aims · hold the left button to wind, release to fire · 1-4 ammo", 16, {200, 204, 216})
  ui.text_centered(w / 2, h - 38, "space handbrake · right drag looks around · R flips the catapult · Esc pauses", 16, {200, 204, 216})
  return result
}

local func stars(score, target){
  if(score >= target * 2){
    return 3
  }
  if(score >= target * 1.4){
    return 2
  }
  if(score >= target){
    return 1
  }
  return 0
}

m.stars = stars

local func draw_stars(cx, y, n){
  for(local i = 0; i < 3; i = i + 1){
    local color = {70, 76, 96}
    if(i < n){
      color = {255, 204, 72}
    }
    local x = cx + (i - 1) * 54
    rl.draw_poly({x, y}, 5, 20, -90, color)
    rl.draw_poly({x, y}, 5, 11, 90, color)
  }
}

// cleared(score, target, has_next) -> {next?, replay?, levels?, keep?}
func m.cleared(score, target, has_next){
  local w = rl.get_screen_width()
  local h = rl.get_screen_height()
  local r = {}
  local pw = 460
  local ph = 300
  local px = (w - pw) / 2
  local py = (h - ph) / 2
  ui.panel(px, py, pw, ph)
  ui.text_centered(w / 2, py + 22, "Level cleared!", 40, {255, 204, 72})
  draw_stars(w / 2, py + 100, stars(score, target))
  ui.text_centered(w / 2, py + 130, concat(thousands(score), " of ", thousands(target)), 22)
  local bw = (pw - 56) / 2
  if(has_next){
    if(ui.button(px + 20, py + 180, bw, 42, "Next level")){
      r.next = true
    }
  } else {
    if(ui.button(px + 20, py + 180, bw, 42, "Levels")){
      r.levels = true
    }
  }
  if(ui.button(px + 36 + bw, py + 180, bw, 42, "Keep wrecking")){
    r.keep = true
  }
  if(ui.button(px + 20, py + 234, bw, 42, "Replay")){
    r.replay = true
  }
  if(ui.button(px + 36 + bw, py + 234, bw, 42, "Level list")){
    r.levels = true
  }
  return r
}

// failed(score, target) -> {retry?, levels?}
func m.failed(score, target){
  local w = rl.get_screen_width()
  local h = rl.get_screen_height()
  local r = {}
  local pw = 460
  local ph = 230
  local px = (w - pw) / 2
  local py = (h - ph) / 2
  ui.panel(px, py, pw, ph)
  ui.text_centered(w / 2, py + 22, "Out of ammo", 40, {255, 120, 90})
  ui.text_centered(w / 2, py + 84, concat(thousands(score), " of ", thousands(target)), 22)
  ui.text_centered(w / 2, py + 112, "not enough wreckage", 18, ui.colors.dim)
  local bw = (pw - 56) / 2
  if(ui.button(px + 20, py + 160, bw, 42, "Retry")){
    r.retry = true
  }
  if(ui.button(px + 36 + bw, py + 160, bw, 42, "Level list")){
    r.levels = true
  }
  return r
}

// paused(editing: bool) -> {resume?, restart?, edit?, levels?, back?}
func m.paused(editing){
  local w = rl.get_screen_width()
  local h = rl.get_screen_height()
  local r = {}
  dim(120)
  local pw = 360
  local items = {{"Resume", "resume"}, {"Restart", "restart"}}
  if(editing){
    append(items, {"Back to the editor", "back"})
  } else {
    append(items, {"Edit this level", "edit"})
  }
  append(items, {"Level list", "levels"})
  local ph = 70 + len(items) * 50
  local px = (w - pw) / 2
  local py = (h - ph) / 2
  ui.panel(px, py, pw, ph)
  ui.text_centered(w / 2, py + 16, "Paused", 30, {255, 204, 72})
  for(local i = 0; i < len(items); i = i + 1){
    if(ui.button(px + 20, py + 60 + i * 50, pw - 40, 42, items[i][0])){
      r[items[i][1]] = true
    }
  }
  return r
}

// help(): the controls, over the game
func m.help(){
  local w = rl.get_screen_width()
  local h = rl.get_screen_height()
  local lines = {
    "W A S D or the arrows: drive, space: handbrake",
    "the mouse aims: left and right turn the arm, up and down lift it",
    "hold the left button to wind the catapult, let go to throw",
    "the line shows where the shot lands",
    "1 2 3 4 or Tab: choose the ammo",
    "right drag: look around, wheel: zoom",
    "R: put the catapult back on its wheels",
    "points for parts knocked loose, smashed, or blown up",
    "furniture inside the buildings is worth the most",
    "Esc: pause, F1: this help",
  }
  local pw = 620
  local ph = 70 + len(lines) * 26
  local px = (w - pw) / 2
  local py = (h - ph) / 2
  ui.panel(px, py, pw, ph, "How to play")
  for(local i = 0; i < len(lines); i = i + 1){
    ui.text(px + 20, py + 46 + i * 26, lines[i], 18)
  }
}

return m
