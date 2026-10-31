// game/hud: what is drawn over the 3D view: the deck, the crosshair and
// prompts, the alarm meter, and the screens between jobs. raylib's own
// pixel font throughout.
local rl = require("raylib")
local math = require("slang/math")
local str = require("slang/string")

local hud = {}

local colors = {
  text: {230, 230, 236},
  dim: {140, 146, 160},
  accent: {90, 255, 140},
  amber: {255, 190, 80},
  red: {255, 80, 80},
  panel: {8, 12, 10, 236},
  panel_edge: {60, 200, 110},
  shade: {0, 0, 0, 170},
  deck_in: {120, 200, 140},
  deck_out: {200, 255, 210},
  deck_err: {255, 110, 100},
  deck_sys: {255, 200, 100},
}
hud.colors = colors

// text with a shadow, readable on bright walls
local func text(s, x, y, size, color){
  local d = if(size >= 40){ 3 } else { 2 }
  rl.draw_text(s, to_int(x) + d, to_int(y) + d, size, {0, 0, 0, 170})
  rl.draw_text(s, to_int(x), to_int(y), size, color)
}

local func centered(s, y, size, color){
  local w = rl.get_screen_width()
  text(s, w / 2 - rl.measure_text(s, size) / 2, y, size, color)
}
hud.centered = centered

local func clock(t){
  local m = to_int(math.floor(t / 60))
  local s = to_int(math.floor(t % 60))
  local pad = if(s < 10){ "0" } else { "" }
  return concat(string(m), ":", pad, string(s))
}
hud.clock = clock

// ------------------------------------------------------------ in play

local kind_colors = {
  ["in"]: colors.deck_in, out: colors.deck_out, err: colors.deck_err,
  sys: colors.deck_sys
}

local func log_line(entry){
  if(entry.kind == "in"){
    return concat("> ", entry.text)
  }
  return entry.text
}

// deck(w, ed, blink): the deck panel, when jacked in
func hud.deck(w, ed, blink){
  local sw = rl.get_screen_width()
  local sh = rl.get_screen_height()
  local ph = to_int(sh * 0.46)
  local y0 = sh - ph
  rl.draw_rectangle(0, y0, sw, ph, colors.panel)
  rl.draw_rectangle(0, y0, sw, 2, colors.panel_edge)
  local port = w.objects[w.jacked]
  local head = concat(
    "DECK // ", port.name, " // ", str.join(port.network, " ")
  )
  text(head, 16, y0 + 10, 20, colors.accent)
  local keys = "Enter run   Shift+Enter new line   Up/Down history   Ctrl+C stop   Esc unplug"
  text(keys, sw - 16 - rl.measure_text(keys, 10), y0 + 15, 10, colors.dim)
  // the input, at the bottom
  local size = 20
  local lh = 24
  local view = ed:lines()
  local input_lines = len(view.lines)
  local iy = sh - 14 - input_lines * lh
  rl.draw_rectangle(8, iy - 8, sw - 16, input_lines * lh + 12, {
    20, 30, 24, 255
  })
  for(local i = 0; i < input_lines; i = i + 1){
    local prompt = if(i == 0){ "> " } else { ". " }
    text(concat(prompt, view.lines[i]), 16, iy + i * lh, size, colors.text)
  }
  if(blink){
    local line = view.lines[view.line] or ""
    local before = concat("> ", str.substring(line, 0, view.column))
    local cx = 16 + rl.measure_text(before, size)
    rl.draw_rectangle(cx + 1, iy + view.line * lh, 10, size, colors.accent)
  }
  // the log, newest at the bottom, above the input
  local top = y0 + 40
  local room = to_int((iy - 12 - top) / lh)
  local lines = {}
  for(local i = len(w.deck.log) - 1; i >= 0 and len(lines) < room; i = i - 1){
    local e = w.deck.log[i]
    append(lines, {text: log_line(e), color: kind_colors[e.kind]})
  }
  local y = iy - 12 - lh
  for(let local l in values(lines)){
    text(l.text, 16, y, size, l.color)
    y = y - lh
  }
  local running = w.deck:running()
  if(running > 0){
    local s = concat(string(running), " running")
    text(s, sw - 16 - rl.measure_text(s, 20), y0 + 40, 20, colors.amber)
  }
}

// deck_tail(w): the last lines of the deck, small, while it is put away
// and scripts are running
local func deck_tail(w){
  local running = w.deck:running()
  if(running == 0){
    return
  }
  local sh = rl.get_screen_height()
  local log = w.deck.log
  local n = math.min(4, len(log))
  local y = sh - 20 - n * 18
  text(concat("deck: ", running, " running"), 16, y - 22, 20, colors.amber)
  for(local i = len(log) - n; i < len(log); i = i + 1){
    local e = log[i]
    text(log_line(e), 16, y, 10 * 2 - 4, kind_colors[e.kind])
    y = y + 18
  }
}

// play(w, mission): crosshair, prompts, objective, alarm meter, notes
func hud.play(w, mission){
  local sw = rl.get_screen_width()
  local sh = rl.get_screen_height()
  local objective = if(w.has_dossier){ "reach the exit" } else { "take the dossier" }
  text(mission.title, 16, 14, 20, colors.text)
  text(objective, 16, 38, 20, colors.dim)
  local t = clock(w.time)
  text(t, sw - 16 - rl.measure_text(t, 20), 14, 20, colors.text)
  if(w.jacked == null){
    rl.draw_circle(to_int(sw / 2), to_int(sh / 2), 2.5, {255, 255, 255, 200})
    local port = w:port_in_reach()
    if(port != null){
      centered(
        concat("[E] jack into ", port.name), sh / 2 + 24, 20, colors.accent
      )
    }
    deck_tail(w)
  }
  // the alarm meter
  if(w.spotted > 0.01){
    local bw = 260
    local x = sw / 2 - bw / 2
    rl.draw_rectangle(to_int(x), 18, bw, 12, {60, 20, 20, 220})
    rl.draw_rectangle(
      to_int(x), 18, to_int(bw * math.min(1, w.spotted)), 12, colors.red
    )
    centered("SEEN", 36, 20, colors.red)
  }
  local y = sh * 0.3
  for(let local n in values(w.notes)){
    centered(n.text, y, 20, colors.amber)
    y = y + 26
  }
}

// ------------------------------------------------------------ screens

local func veil(color){
  rl.draw_rectangle(0, 0, rl.get_screen_width(), rl.get_screen_height(), color)
}

// title(missions, selected, best): the job list
func hud.title(missions, selected, best){
  local sh = rl.get_screen_height()
  veil({8, 10, 16, 200})
  centered("DECKHAND", sh * 0.12, 80, colors.accent)
  centered("a heist game written in slang", sh * 0.12 + 86, 20, colors.dim)
  local y = sh * 0.36
  for(local i = 0; i < len(missions); i = i + 1){
    local m = missions[i]
    local line = concat(string(i + 1), ". ", m.title)
    if(best[m.name] != null){
      line = concat(line, "   best ", clock(best[m.name]))
    }
    local color = if(i == selected){ colors.text } else { colors.dim }
    if(i == selected){
      line = concat("> ", line, " <")
    }
    centered(line, y, 30, color)
    y = y + 40
  }
  centered("Up/Down choose   Enter brief   Esc quit", sh - 70, 20, colors.dim)
  centered("WASD move   mouse look   E jack in", sh - 44, 20, colors.dim)
}

// briefing(mission)
func hud.briefing(mission){
  local sh = rl.get_screen_height()
  local sw = rl.get_screen_width()
  veil({8, 10, 16, 225})
  centered(mission.title, sh * 0.14, 50, colors.accent)
  local x = sw / 2 - 360
  local y = sh * 0.28
  for(let local line in values(mission.briefing)){
    local color = if(str.starts_with(
      line, "    "
    )){ colors.deck_out } else { colors.text }
    text(line, x, y, 20, color)
    y = y + 28
  }
  centered("Enter go   Esc back", sh - 60, 20, colors.dim)
}

// caught(w)
func hud.caught(w){
  local sh = rl.get_screen_height()
  veil({120, 0, 0, 120})
  centered("ALARM", sh * 0.3, 80, colors.red)
  centered(w.reason or "", sh * 0.3 + 96, 30, colors.text)
  centered("R try again   Esc jobs", sh * 0.3 + 150, 20, colors.dim)
}

// complete(w, best)
func hud.complete(w, best, last){
  local sh = rl.get_screen_height()
  veil({0, 40, 20, 150})
  centered("JOB DONE", sh * 0.3, 80, colors.accent)
  local line = concat("time ", clock(w.time))
  if(best != null and best < w.time){
    line = concat(line, "   best ", clock(best))
  } else {
    line = concat(line, "   a new best")
  }
  centered(line, sh * 0.3 + 96, 30, colors.text)
  local next = if(last){ "Enter jobs" } else { "Enter next job" }
  centered(
    concat(next, "   R again   Esc jobs"), sh * 0.3 + 150, 20, colors.dim
  )
}

// paused()
func hud.paused(){
  local sh = rl.get_screen_height()
  veil({0, 0, 0, 150})
  centered("PAUSED", sh * 0.35, 60, colors.text)
  centered("Esc resume   R restart   Q jobs", sh * 0.35 + 80, 20, colors.dim)
}

return hud
