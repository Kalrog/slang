// The rack on screen: where every module, knob, jack and step is (the
// layout), how they are drawn, in pixels of the 640 x 360 screen that
// main.slang scales up, and what the mouse is over. Everything is drawn
// with rectangles, lines and the 3x5 font: a pixel look by construction.
local rl = require("raylib")
local math = require("slang/math")
local str = require("slang/string")
local font = require("font")
local rack = require("rack")
local engine = require("engine")
local fmui = require("fmui")

local ui = {}

local VW = 640
local VH = 360
ui.VW = VW
ui.VH = VH

local MH = 106                 // a module's height
local ROWS = {13, 123, 233}    // where the three rows of the rack start
local RAIL = 4                 // the rack's side rails
local IN_Y = 66                // the inputs row (two-row modules)
local OUT_Y = 86               // the outputs row
local BOTTOM = 343             // the status line

local colors = {
  bg: {36, 32, 44},
  bar: {16, 14, 20},
  rail: {72, 68, 84},
  screw: {130, 128, 140},
  face: {208, 200, 180},
  face_dark: {184, 176, 156},
  edge: {110, 100, 92},
  band: {44, 40, 52},
  band_text: {196, 192, 180},
  text: {40, 36, 44},
  dim: {120, 114, 110},
  light: {236, 232, 220},
  knob: {40, 36, 44},
  pointer: {250, 250, 240},
  hole: {12, 10, 16},
  ring: {160, 160, 172},
  grid: {30, 28, 36},
  grid_line: {52, 48, 62},
  grid_off: {72, 68, 84},
  playhead: {70, 64, 84},
  scope: {110, 230, 130},
  white: {255, 255, 255},
  menu: {22, 20, 28},
  warn: {240, 110, 90},
  kinds: {
    red: {190, 60, 70}, orange: {215, 120, 40}, green: {70, 150, 100},
    blue: {70, 110, 190}, yellow: {210, 170, 50}, purple: {140, 80, 170},
    grey: {110, 110, 125},
  },
  cables: {
    {235, 70, 70}, {70, 150, 240}, {240, 200, 60}, {80, 200, 110},
    {240, 240, 240}, {200, 90, 220}, {255, 150, 60}, {90, 220, 220},
  },
}
ui.colors = colors

// letter(p) -> a pattern's letter, A..H
func ui.letter(p){
  return str.substring("ABCDEFGH", p, p + 1)
}

local func kind_color(spec){
  return colors.kinds[spec.color]
}

// ------------------------------------------------------------ the layout

// a module's drawn area under its title (sequencer grids, the song chain,
// the output's scope): {w, h}
local func grid_size(spec){
  if(spec.kind == engine.kinds.SEQ){
    return {w: 96, h: 50}
  }
  if(spec.kind == engine.kinds.TRIGS){
    return {w: 96, h: 28}
  }
  if(spec.kind == engine.kinds.CLOCK){
    return {w: 80, h: 16}
  }
  if(spec.kind == engine.kinds.SCOPE){
    return {w: 96, h: 50}
  }
  if(spec.kind == engine.kinds.OUT){
    return {w: 36, h: 24}
  }
  if(spec.kind == engine.kinds.FM){
    return {w: 96, h: 50}
  }
  return {w: 0, h: 0}
}

// a tall grid puts inputs and outputs in one row at the bottom
local func one_row(spec){
  return grid_size(spec).h > 30
}

// where the knobs start, and how many rows of them fit
local func knob_rows(spec){
  local g = grid_size(spec)
  local y0 = 10
  if(g.h > 0){
    y0 = 12 + g.h
  }
  local until = IN_Y - 2
  if(one_row(spec)){
    until = OUT_Y - 2
  }
  local rows = to_int((until - y0) / 20)
  if(rows < 1){
    rows = 1
  }
  return {y0: y0, rows: rows}
}

// width(spec) -> the panel's width: room for its knobs, jacks and grid
func ui.width(spec){
  local kr = knob_rows(spec)
  local cols = math.ceil(len(spec.params) / kr.rows)
  local jacks = len(spec.inputs)
  if(len(spec.outputs) > jacks){
    jacks = len(spec.outputs)
  }
  if(one_row(spec)){
    jacks = len(spec.inputs) + len(spec.outputs)
  }
  local w = cols * 20
  if(jacks * 16 > w){
    w = jacks * 16
  }
  local g = grid_size(spec)
  if(g.w > w){
    w = g.w
  }
  w = w + 4
  w = to_int((w + 7) / 8) * 8
  if(w < 24){
    w = 24
  }
  return w
}

// place(r) -> {mods: {slot -> M}, overflow}: the modules in slot order,
// left to right, row by row; M = {x, y, w, h, spec, knobs, ins, outs,
// grid} with the positions of its knobs (20 x 20 cells), jacks (9 x 9)
// and grid. A module that does not fit is not placed (overflow is true).
func ui.place(r){
  local out = {mods: {}, overflow: false}
  local row = 0
  local x = RAIL + 2
  for(let local m in values(r:slots())){
    local spec = r.modules[m].spec
    local w = ui.width(spec)
    if(x + w > VW - RAIL - 2){
      row = row + 1
      x = RAIL + 2
    }
    if(row >= len(ROWS)){
      out.overflow = true
      break
    }
    local y = ROWS[row] + 2
    local M = {x: x, y: y, w: w, h: MH, spec: spec, knobs: {}, ins: {}, outs: {}}
    local kr = knob_rows(spec)
    local cols = math.ceil(len(spec.params) / kr.rows)
    local kx0 = x + (w - cols * 20) / 2
    for(local i = 0; i < len(spec.params); i = i + 1){
      local col = i % cols
      local krow = to_int(i / cols)
      append(M.knobs, {x: kx0 + col * 20, y: y + kr.y0 + krow * 20})
    }
    if(one_row(spec)){
      local n = len(spec.inputs) + len(spec.outputs)
      local jx0 = x + (w - n * 16) / 2
      for(local i = 0; i < len(spec.inputs); i = i + 1){
        append(M.ins, {x: jx0 + i * 16 + 4, y: y + OUT_Y + 1})
      }
      for(local i = 0; i < len(spec.outputs); i = i + 1){
        append(M.outs, {x: jx0 + (len(spec.inputs) + i) * 16 + 4, y: y + OUT_Y + 1})
      }
    } else {
      local jx0 = x + (w - len(spec.inputs) * 16) / 2
      for(local i = 0; i < len(spec.inputs); i = i + 1){
        append(M.ins, {x: jx0 + i * 16 + 4, y: y + IN_Y + 1})
      }
      jx0 = x + (w - len(spec.outputs) * 16) / 2
      for(local i = 0; i < len(spec.outputs); i = i + 1){
        append(M.outs, {x: jx0 + i * 16 + 4, y: y + OUT_Y + 1})
      }
    }
    local g = grid_size(spec)
    if(g.h > 0){
      M.grid = {x: x + (w - g.w) / 2, y: y + 10, w: g.w, h: g.h}
    }
    out.mods[m] = M
    x = x + w + 2
  }
  return out
}

// fits(r, spec) -> whether one more module of this kind has room
func ui.fits(r, spec){
  local row = 0
  local x = RAIL + 2
  for(let local m in values(r:slots())){
    local w = ui.width(r.modules[m].spec)
    if(x + w > VW - RAIL - 2){
      row = row + 1
      x = RAIL + 2
    }
    x = x + w + 2
  }
  local w = ui.width(spec)
  if(x + w > VW - RAIL - 2){
    row = row + 1
  }
  return row < len(ROWS)
}

// ------------------------------------------------------------ drawing

local func rect(x, y, w, h, color){
  rl.draw.rectangle(to_int(x), to_int(y), to_int(w), to_int(h), color)
}

local func dim_color(c, f){
  return {to_int(c[0] * f), to_int(c[1] * f), to_int(c[2] * f)}
}

local func lerp_color(a, b, t){
  return {to_int(a[0] + (b[0] - a[0]) * t), to_int(a[1] + (b[1] - a[1]) * t), to_int(a[2] + (b[2] - a[2]) * t)}
}

// the cable into input i of module m, with its color, or null
local func cable_in(r, m, i){
  for(local k = 0; k < len(r.cables); k = k + 1){
    local c = r.cables[k]
    if(c.to.m == m and c.to.i == i){
      return {cable: c, color: colors.cables[k % len(colors.cables)]}
    }
  }
  return null
}

local func draw_knob(k, p, v, hot){
  local cx = k.x + 10
  local cy = k.y + 6
  local body = colors.knob
  if(hot){
    body = {80, 72, 90}
  }
  rl.draw.circle(cx, cy, 4.5, colors.hole)
  rl.draw.circle(cx, cy, 3.5, body)
  // the pointer: from 7 o'clock (0) round to 5 o'clock (1)
  local t = v
  if(p.kind == "steps"){
    t = v / (p.n - 1)
  }
  local ang = (-135 + t * 270 - 90) * math.pi / 180
  local dx = math.cos(ang)
  local dy = math.sin(ang)
  rl.draw.line(to_int(cx + dx), to_int(cy + dy), to_int(cx + dx * 4), to_int(cy + dy * 4), colors.pointer)
  font.center(p.label, cx, k.y + 13, colors.text)
}

local func draw_jack(j, label, ring, led, label_color){
  rect(j.x, j.y, 9, 9, ring)
  rect(j.x + 1, j.y + 1, 7, 7, colors.hole)
  rect(j.x + 2, j.y + 2, 5, 5, led)
  font.center(label, j.x + 4, j.y + 10, label_color)
}

local func note_name(semis){
  local n = ((semis % 12) + 12) % 12
  local oct = 4 + math.floor(semis / 12)
  return concat(rack.note_names[n], oct)
}
ui.note_name = note_name

// the SEQ's grid: a column a step, the note's row (-12..12 shown), the
// gate as its color, the playhead when this pattern plays
local func draw_seq(r, m, M, pattern, state){
  local g = M.grid
  local mod = r.modules[m]
  local steps = to_int(mod.params[0]) + 1
  local a = r.a
  local playing = -1
  if(state.running and to_int(a.status[m * 4 + 1]) == pattern){
    playing = to_int(a.status[m * 4])
  }
  rect(g.x, g.y, g.w, g.h, colors.grid)
  for(local row = 0; row < 25; row = row + 1){
    local note = 12 - row
    if(note % 12 == 0){
      rect(g.x, g.y + row * 2, g.w, 2, colors.grid_line)
    }
  }
  local color = kind_color(mod.spec)
  for(local s = 0; s < 16; s = s + 1){
    local x = g.x + s * 6
    if(s >= steps){
      rect(x, g.y, 6, g.h, {22, 20, 26})
      continue
    }
    if(s == playing){
      rect(x, g.y, 6, g.h, colors.playhead)
    }
    local note = r:seq_note(m, pattern, s)
    local gate = r:seq_gate(m, pattern, s)
    local shown = note
    if(shown > 12){
      shown = 12
    } else if(shown < -12){
      shown = -12
    }
    local y = g.y + (12 - shown) * 2
    if(gate == 0){
      rect(x + 1, y, 4, 2, colors.grid_off)
    } else if(gate == 2){
      rect(x, y, 6, 2, color)
    } else {
      rect(x + 1, y, 4, 2, color)
    }
    if(note != shown){
      // out of the shown range: a mark at the edge
      rect(x + 2, y, 2, 2, colors.light)
    }
  }
}

local func draw_trigs(r, m, M, pattern, state){
  local g = M.grid
  local mod = r.modules[m]
  local steps = to_int(mod.params[0]) + 1
  local a = r.a
  local playing = -1
  if(state.running and to_int(a.status[m * 4 + 1]) == pattern){
    playing = to_int(a.status[m * 4])
  }
  rect(g.x, g.y, g.w, g.h, colors.grid)
  local color = kind_color(mod.spec)
  for(local s = 0; s < 16; s = s + 1){
    local x = g.x + s * 6
    if(s >= steps){
      rect(x, g.y, 6, g.h, {22, 20, 26})
      continue
    }
    if(s == playing){
      rect(x, g.y, 6, g.h, colors.playhead)
    }
    for(local row = 0; row < 4; row = row + 1){
      local y = g.y + row * 7
      if(r:trig(m, pattern, row, s) == 1){
        rect(x + 1, y + 1, 4, 5, color)
      } else {
        rect(x + 2, y + 3, 2, 1, colors.grid_off)
      }
    }
  }
}

// the clock's song chain: 32 slots of a pattern letter
local func draw_song(r, m, M, state){
  local g = M.grid
  local a = r.a
  local mod = r.modules[m]
  rect(g.x, g.y, g.w, g.h, colors.grid)
  local at = -1
  if(state.running and mod.params[3] > 0.5 and len(r.song) > 0){
    local per = 1 << to_int(mod.params[2])
    at = to_int(a.status[m * 4 + 2] / per) % len(r.song)
  }
  for(local s = 0; s < 32; s = s + 1){
    local x = g.x + (s % 16) * 5
    local y = g.y + to_int(s / 16) * 8
    if(s == at){
      rect(x, y, 5, 8, colors.playhead)
    }
    if(s < len(r.song)){
      local color = kind_color(mod.spec)
      if(mod.params[3] < 0.5){
        color = colors.grid_off
      }
      font.text(ui.letter(r.song[s]), x + 1, y + 1, color)
    } else {
      rect(x + 2, y + 4, 1, 1, colors.grid_off)
    }
  }
}

local func draw_scope(r, m, M){
  local g = M.grid
  rect(g.x, g.y, g.w, g.h, colors.grid)
  local scope = r.a.scope
  local n = len(scope)
  local at = to_int(r.a.status[m * 4])
  local stride = 6
  local last = null
  local mid = g.y + g.h / 2
  for(local x = 0; x < g.w; x = x + 1){
    local i = ((at - (g.w - x) * stride) % n + n) % n
    local v = scope[i]
    local y = to_int(mid - v * (g.h / 2 - 1))
    if(y < g.y){
      y = g.y
    } else if(y >= g.y + g.h){
      y = g.y + g.h - 1
    }
    if(last != null){
      rl.draw.line(g.x + x - 1, last, g.x + x, y, colors.scope)
    } else {
      rect(g.x + x, y, 1, 1, colors.scope)
    }
    last = y
  }
}

// a SCOPE module: the captured window, each column from its least to its
// most, the trigger level dotted
local func draw_scope_module(r, m, M){
  local g = M.grid
  local mod = r.modules[m]
  rect(g.x, g.y, g.w, g.h, colors.grid)
  local mid = g.y + g.h / 2
  rect(g.x, mid, g.w, 1, colors.grid_line)
  for(local x = 0; x < g.w; x = x + 12){
    rect(g.x + x, g.y, 1, g.h, colors.grid_line)
  }
  local gain = 0.25 * 2 ^ (mod.params[2] * 4)
  local half = g.h / 2 - 1
  local level = to_int(mid - (mod.params[1] * 2 - 1) * gain * half)
  if(level >= g.y and level < g.y + g.h){
    for(local x = 0; x < g.w; x = x + 4){
      rect(g.x + x, level, 2, 1, colors.dim)
    }
  }
  local scopes = r.a.scopes
  local base = m * engine.SCOPE_W * 2
  for(local x = 0; x < engine.SCOPE_W; x = x + 1){
    local lo = scopes[base + x * 2] * gain
    local hi = scopes[base + x * 2 + 1] * gain
    local y1 = to_int(mid - hi * half)
    local y2 = to_int(mid - lo * half)
    if(y1 < g.y){
      y1 = g.y
    }
    if(y2 >= g.y + g.h){
      y2 = g.y + g.h - 1
    }
    if(y2 >= y1){
      rect(g.x + x, y1, 1, y2 - y1 + 1, colors.scope)
    }
  }
}

local func draw_module(r, m, M, state){
  local mod = r.modules[m]
  local spec = mod.spec
  local a = r.a
  local kc = kind_color(spec)
  // the panel, its screws and its title band
  rect(M.x, M.y, M.w, M.h, colors.edge)
  rect(M.x + 1, M.y + 1, M.w - 2, M.h - 2, colors.face)
  rect(M.x + 1, M.y + 1, M.w - 2, 8, kc)
  local title_color = colors.light
  if(spec.color == "yellow"){
    title_color = colors.text
  }
  font.text(spec.name, M.x + 3, M.y + 3, title_color)
  if(spec.kind == engine.kinds.SEQ or spec.kind == engine.kinds.TRIGS){
    font.right(ui.letter(state.pattern), M.x + M.w - 3, M.y + 3, title_color)
  } else if(spec.kind == engine.kinds.FM){
    font.right(fmui.name(mod), M.x + M.w - 3, M.y + 3, title_color)
  }
  rect(M.x + 1, M.y + M.h - 1 - 22, M.w - 2, 22, colors.band)
  rect(M.x + 2, M.y + 2, 1, 1, colors.screw)
  rect(M.x + M.w - 3, M.y + 2, 1, 1, colors.screw)
  rect(M.x + 2, M.y + M.h - 3, 1, 1, colors.screw)
  rect(M.x + M.w - 3, M.y + M.h - 3, 1, 1, colors.screw)
  local hover = state.hover
  // the grid
  if(spec.kind == engine.kinds.SEQ){
    draw_seq(r, m, M, state.pattern, state)
  } else if(spec.kind == engine.kinds.TRIGS){
    draw_trigs(r, m, M, state.pattern, state)
  } else if(spec.kind == engine.kinds.CLOCK){
    draw_song(r, m, M, state)
  } else if(spec.kind == engine.kinds.OUT){
    draw_scope(r, m, M)
  } else if(spec.kind == engine.kinds.SCOPE){
    draw_scope_module(r, m, M)
  } else if(spec.kind == engine.kinds.FM){
    fmui.draw_panel(r, m, M.grid, null)
    if(hover != null and hover.kind == "fm" and hover.m == m){
      rl.draw.rectangle_lines(M.grid.x, M.grid.y, M.grid.w, M.grid.h, colors.white)
    }
  }
  // knobs
  for(local i = 0; i < len(spec.params); i = i + 1){
    local hot = hover != null and hover.kind == "knob" and hover.m == m and hover.i == i
    draw_knob(M.knobs[i], spec.params[i], mod.params[i], hot)
  }
  // jacks: an input's ring takes its cable's color, an output's LED its
  // signal
  for(local i = 0; i < len(spec.inputs); i = i + 1){
    local ring = colors.ring
    local led = colors.hole
    local c = cable_in(r, m, i)
    if(c != null){
      ring = c.color
      led = dim_color(c.color, 0.5)
    }
    local label_color = colors.text
    if(one_row(spec)){
      label_color = colors.band_text
    }
    draw_jack(M.ins[i], spec.inputs[i], ring, led, label_color)
  }
  for(local i = 0; i < len(spec.outputs); i = i + 1){
    local v = a.meters[m * engine.NO + i]
    if(v < 0){
      v = -v
    }
    if(v > 1){
      v = 1
    }
    local led = lerp_color(colors.hole, kc, v)
    draw_jack(M.outs[i], spec.outputs[i], colors.ring, led, colors.band_text)
  }
  if(hover != null and hover.kind == "title" and hover.m == m){
    rl.draw.rectangle_lines(M.x, M.y, M.w, M.h, colors.white)
  }
}

// a sagging cable from (x1, y1) to (x2, y2), with a dark outline
local func draw_cable(x1, y1, x2, y2, color){
  local dx = x2 - x1
  local dy = y2 - y1
  local dist = math.sqrt(dx * dx + dy * dy)
  local sag = 10 + dist * 0.12
  local cx = (x1 + x2) / 2
  local cy = (y1 + y2) / 2 + sag
  local pts = {}
  local n = 14
  for(local i = 0; i <= n; i = i + 1){
    local t = i / n
    local u = 1 - t
    append(pts, {x: u * u * x1 + 2 * u * t * cx + t * t * x2, y: u * u * y1 + 2 * u * t * cy + t * t * y2})
  }
  local dark = dim_color(color, 0.35)
  for(local i = 1; i <= n; i = i + 1){
    rl.draw.line_ex(pts[i - 1], pts[i], 3, dark)
  }
  for(local i = 1; i <= n; i = i + 1){
    rl.draw.line_ex(pts[i - 1], pts[i], 1, color)
  }
  rl.draw.circle(to_int(x1), to_int(y1), 2.5, dark)
  rl.draw.circle(to_int(x2), to_int(y2), 2.5, dark)
  rl.draw.circle(to_int(x1), to_int(y1), 1.5, color)
  rl.draw.circle(to_int(x2), to_int(y2), 1.5, color)
}

local func draw_cables(r, L, state){
  for(local k = 0; k < len(r.cables); k = k + 1){
    local c = r.cables[k]
    local from = L.mods[c.from.m]
    local to = L.mods[c.to.m]
    if(from == null or to == null){
      continue
    }
    local o = from.outs[c.from.o]
    local i = to.ins[c.to.i]
    draw_cable(o.x + 4.5, o.y + 4.5, i.x + 4.5, i.y + 4.5, colors.cables[k % len(colors.cables)])
  }
  local d = state.drag
  if(d != null and d.kind == "cable"){
    local color = colors.cables[len(r.cables) % len(colors.cables)]
    if(d.from != null){
      local M = L.mods[d.from.m]
      if(M != null){
        local o = M.outs[d.from.o]
        draw_cable(o.x + 4.5, o.y + 4.5, state.mouse.x, state.mouse.y, color)
      }
    } else {
      local M = L.mods[d.to.m]
      if(M != null){
        local i = M.ins[d.to.i]
        draw_cable(state.mouse.x, state.mouse.y, i.x + 4.5, i.y + 4.5, color)
      }
    }
  }
}

local func draw_rack_bg(){
  rect(0, 0, VW, VH, colors.bg)
  for(let local y in values(ROWS)){
    rect(0, y, VW, 2, colors.rail)
    rect(0, y + MH + 2, VW, 2, colors.rail)
    rect(0, y, RAIL, MH + 4, colors.rail)
    rect(VW - RAIL, y, RAIL, MH + 4, colors.rail)
    for(local x = 8; x < VW; x = x + 32){
      rect(x, y, 1, 2, colors.screw)
      rect(x, y + MH + 2, 1, 2, colors.screw)
    }
  }
}

// the top bar: the patch, the transport, the load
local func draw_top(r, state){
  rect(0, 0, VW, 12, colors.bar)
  font.text("SLANG MODULAR", 4, 3, colors.light)
  font.text(r.name, 64, 3, colors.kinds.yellow)
  local t = state.transport
  local x = 200
  if(state.running){
    font.text("}", x, 3, colors.scope)
  } else {
    font.text("{", x, 3, colors.dim)
  }
  x = x + 8
  if(t != null){
    font.text(concat("", t.bpm, " BPM  BAR ", t.bar + 1, ".", t.beat + 1), x, 3, colors.light)
    x = x + 80
  }
  font.text(concat("PAT ", ui.letter(state.pattern)), x + 8, 3, colors.light)
  if(state.song_on){
    font.text("SONG", x + 36, 3, colors.kinds.yellow)
  }
  local load = concat("DSP ", to_int(state.load * 100), "%")
  local color = colors.dim
  if(state.underruns > 0){
    load = concat(load, " ", state.underruns, " DROPS")
    color = colors.warn
  }
  font.right(load, VW - 4, 3, color)
  font.right(concat("", len(r:slots()), " MODULES  ", len(r.cables), " CABLES"), VW - 72, 3, colors.dim)
}

local func draw_bottom(state){
  rect(0, BOTTOM, VW, VH - BOTTOM, colors.bar)
  local line = state.message
  local color = colors.kinds.yellow
  if(line == null){
    line = state.tip
    color = colors.light
  }
  if(line == null){
    line = "SPACE PLAY  1-8 PATTERN  A ADD  DEL REMOVE  TAB PATCH  F2 SAVE  F3 WAV  F4 NEW  F5/F6 COPY/PASTE  Z.. PLAY  </> OCTAVE"
    color = colors.dim
  }
  font.text(line, 4, BOTTOM + 6, color)
}

// the menu of kinds to add
local MENU_X = 160
local MENU_Y = 70
local MENU_W = 320
local MENU_ROWS = 11
local MENU_H = 12 + MENU_ROWS * 11 + 6

local func draw_menu(state){
  rect(MENU_X - 1, MENU_Y - 1, MENU_W + 2, MENU_H + 2, colors.light)
  rect(MENU_X, MENU_Y, MENU_W, MENU_H, colors.menu)
  font.text("ADD A MODULE  (A OR ESC CLOSES)", MENU_X + 4, MENU_Y + 3, colors.light)
  for(local i = 0; i < len(rack.catalog); i = i + 1){
    local spec = rack.catalog[i]
    local col = to_int(i / MENU_ROWS)
    local row = i % MENU_ROWS
    local x = MENU_X + 4 + col * 160
    local y = MENU_Y + 12 + row * 11
    if(state.hover != null and state.hover.kind == "menu" and state.hover.i == i){
      rect(x - 2, y - 2, 158, 11, colors.playhead)
    }
    rect(x, y, 3, 5, kind_color(spec))
    font.text(spec.name, x + 6, y, colors.light)
  }
  if(state.hover != null and state.hover.kind == "menu"){
    font.text(rack.catalog[state.hover.i].tip, MENU_X + 4, MENU_Y + MENU_H - 8, colors.kinds.yellow)
  }
}

// draw(r, L, state): the whole screen. state: {hover, drag, mouse,
// pattern, running, transport?: {bpm, bar, beat}, song_on, load,
// underruns, tip?, message?, menu, editor?: {m} (the FM editor page over
// the rack)}
func ui.draw(r, L, state){
  draw_rack_bg()
  for(let local m in values(r:slots())){
    local M = L.mods[m]
    if(M != null){
      draw_module(r, m, M, state)
    }
  }
  draw_cables(r, L, state)
  if(state.editor != null){
    fmui.draw(r, state.editor.m, state)
  }
  draw_top(r, state)
  draw_bottom(state)
  if(state.menu){
    draw_menu(state)
  }
}

// ------------------------------------------------------------ hit tests

local func inside(x, y, rx, ry, rw, rh){
  return x >= rx and x < rx + rw and y >= ry and y < ry + rh
}

// hit(r, L, x, y, menu) -> what is at x, y: {kind: "knob", m, i},
// {kind: "in" | "out", m, i}, {kind: "step", m, step, note},
// {kind: "trig", m, row, step}, {kind: "song", m, slot}, {kind: "fm", m}
// (an FM module's face), {kind: "title", m}, {kind: "module", m},
// {kind: "menu", i}, or null
func ui.hit(r, L, x, y, menu){
  if(menu){
    for(local i = 0; i < len(rack.catalog); i = i + 1){
      local col = to_int(i / MENU_ROWS)
      local row = i % MENU_ROWS
      if(inside(x, y, MENU_X + 2 + col * 160, MENU_Y + 10 + row * 11, 158, 11)){
        return {kind: "menu", i: i}
      }
    }
    return null
  }
  for(let local m in values(r:slots())){
    local M = L.mods[m]
    if(M == null or not inside(x, y, M.x, M.y, M.w, M.h)){
      continue
    }
    local spec = M.spec
    for(local i = 0; i < len(M.knobs); i = i + 1){
      local k = M.knobs[i]
      if(inside(x, y, k.x + 3, k.y, 14, 18)){
        return {kind: "knob", m: m, i: i}
      }
    }
    for(local i = 0; i < len(M.ins); i = i + 1){
      local j = M.ins[i]
      if(inside(x, y, j.x - 3, j.y - 2, 15, 16)){
        return {kind: "in", m: m, i: i}
      }
    }
    for(local i = 0; i < len(M.outs); i = i + 1){
      local j = M.outs[i]
      if(inside(x, y, j.x - 3, j.y - 2, 15, 16)){
        return {kind: "out", m: m, i: i}
      }
    }
    local g = M.grid
    if(g != null and inside(x, y, g.x, g.y, g.w, g.h)){
      if(spec.kind == engine.kinds.SEQ){
        return {kind: "step", m: m, step: to_int((x - g.x) / 6), note: 12 - to_int((y - g.y) / 2)}
      }
      if(spec.kind == engine.kinds.TRIGS){
        return {kind: "trig", m: m, row: to_int((y - g.y) / 7), step: to_int((x - g.x) / 6)}
      }
      if(spec.kind == engine.kinds.CLOCK){
        return {kind: "song", m: m, slot: to_int((x - g.x) / 5) + to_int((y - g.y) / 8) * 16}
      }
      if(spec.kind == engine.kinds.FM){
        return {kind: "fm", m: m}
      }
    }
    if(y < M.y + 9){
      return {kind: "title", m: m}
    }
    return {kind: "module", m: m}
  }
  return null
}

return ui
