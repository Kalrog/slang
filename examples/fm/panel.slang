// The front panel: a display, the bank of 32 patches, the algorithm drawn
// as a diagram, a table of the six operators' parameters, the LFO and pitch
// envelope, and a keyboard with pitch and mod wheels. Every number on it is
// a cell: drag it up or down (shift: one step at a time), turn the mouse
// wheel over it, or click it when it is a switch.
//
// panel.new(app) makes one; app gives what the panel shows and changes:
//   {patch (the current patch, edited in place), bank (the 32 patches),
//    choice (the bank number of the patch, 0..31), edited (bool), stats,
//    scope (buffer), voices (int), controls (the engine's shared buffer),
//    choose(i), changed(), note_on(note, vel), note_off(note),
//    held(note) -> bool, octave}
local rl = require("raylib")
local math = require("slang/math")
local patch = require("patch")
local algorithms = require("algorithms")
local engine = require("engine")
local gfx = require("gfx")

local panel = {}

panel.W = 1280
panel.H = 800

local colors = {
  body: {28, 26, 27},
  face: {40, 37, 38},
  line: {78, 72, 72},
  text: {232, 226, 214},
  dim: {150, 142, 132},
  faint: {96, 90, 86},
  lcd: {24, 46, 40},
  lcd_text: {150, 236, 196},
  lcd_dim: {80, 140, 116},
  accent: {232, 118, 64},
  accent_dark: {104, 52, 30},
  teal: {82, 184, 172},
  cell: {22, 21, 22},
  cell_hot: {58, 44, 38},
  button: {64, 60, 58},
  button_on: {232, 118, 64},
  white_key: {242, 238, 228},
  white_down: {236, 190, 160},
  black_key: {24, 22, 22},
  black_down: {150, 80, 50},
  scope: {150, 236, 196},
  warn: {240, 110, 90},
}
panel.colors = colors

// ------------------------------------------------------------ text

panel.load_font = gfx.load_font
panel.unload_font = gfx.unload_font
local measure = gfx.measure
local text = gfx.text
local text_center = gfx.text_center
local two = gfx.two
panel.text = text

// "P.R1" -> "R1"
local func str_tail(s){
  return require("slang/string").substring(s, 2)
}

// ------------------------------------------------------------ layout

local HEADER_Y = 12
local BANK_Y = 76
local BANK_H = 30
local EDIT_Y = 150
local ALG_X = 20
local ALG_W = 300
local TABLE_X = 340
local ROW_H = 30
local CELL_W = 32
local LFO_Y = 392
local KEYS_Y = 490
local KEYS_X = 150
local FIRST_NOTE = 36
local LAST_NOTE = 96
local WHITE_H = panel.H - KEYS_Y - 10
local BLACK_H = to_int(WHITE_H * 0.62)

// the operator table's columns: an id of patch.OP_FIELDS, or "freq" (the
// frequency the coarse, fine and mode give)
local columns = {
  "on", "mode", "freq", "coarse", "fine", "detune", "level", "vel", "rs",
  "ams", "r1", "r2", "r3", "r4", "l1", "l2", "l3", "l4", "break", "ldepth",
  "rdepth", "lcurve", "rcurve",
}
local field_of = {}
for(let local f in values(patch.OP_FIELDS)){
  field_of[f.id] = f
}
for(let local f in values(patch.VOICE_FIELDS)){
  field_of[f.id] = f
}

// the keys: {note, black, x, w}
local is_black = {false, true, false, true, false, false, true, false, true, false, true, false}
local keys = {}
local func layout_keys(){
  local whites = 0
  for(local n = FIRST_NOTE; n <= LAST_NOTE; n = n + 1){
    if(not is_black[n % 12]){
      whites = whites + 1
    }
  }
  local ww = (panel.W - 20 - KEYS_X) / whites
  local j = 0
  for(local n = FIRST_NOTE; n <= LAST_NOTE; n = n + 1){
    if(is_black[n % 12]){
      append(keys, {note: n, black: true, x: KEYS_X + j * ww - ww * 0.3, w: ww * 0.6})
    } else {
      append(keys, {note: n, black: false, x: KEYS_X + j * ww, w: ww})
      j = j + 1
    }
  }
}
layout_keys()

local WHEEL_W = 30
local WHEEL_H = 220
local wheels = {
  {index: engine.BEND, x: 30, label: "PITCH", spring: true},
  {index: engine.WHEEL, x: 86, label: "MOD", spring: false},
}

// ------------------------------------------------------------ cells

// A cell: {x, y, w, h, field, get(), set(v)}; the panel's cells are made
// again every frame from the current patch.
local func clamp(v, lo, hi){
  if(v < lo){
    return lo
  }
  if(v > hi){
    return hi
  }
  return v
}

local func cell_text(c, v){
  return patch.field_text(c.field, v)
}

// ------------------------------------------------------------ the panel

func panel.new(app){
  local self = {}
  local cells = {}
  local drag = null
  local last_click = {time: -1.0, cell: null}
  local mouse_note = null
  local wheel_drag = null
  local p = func(){ return app.patch }

  local func op_cell(i, id, x, y){
    if(id == "freq"){
      // the frequency: dragged, it steps coarse (fine with shift)
      append(cells, {
        target: concat("op", string(i + 1), ".coarse"),
        x: x, y: y, w: CELL_W * 2 - 2, h: ROW_H - 4, field: {id: "freq", min: 0, max: 31},
        get: func(){ return p().ops[i].coarse },
        set: func(v){ p().ops[i].coarse = v },
        show: func(){ return patch.frequency_text(p().ops[i]) },
      })
      return null
    }
    local f = field_of[id]
    append(cells, {
      target: concat("op", string(i + 1), ".", id),
      x: x, y: y, w: CELL_W - 2, h: ROW_H - 4, field: f,
      get: func(){ return p().ops[i][id] },
      set: func(v){ p().ops[i][id] = v },
    })
  }

  local func voice_cell(id, x, y, w){
    append(cells, {
      target: concat("voice.", id),
      x: x, y: y, w: w, h: ROW_H - 4, field: field_of[id],
      get: func(){ return p()[id] },
      set: func(v){ p()[id] = v },
    })
  }

  // the cells of the current patch, where they are drawn
  local func build_cells(){
    cells = {}
    local x0 = TABLE_X + 44
    for(local i = 0; i < 6; i = i + 1){
      local y = EDIT_Y + 26 + i * ROW_H
      local x = x0
      for(let local id in values(columns)){
        op_cell(i, id, x, y)
        if(id == "freq"){
          x = x + CELL_W * 2
        } else {
          x = x + CELL_W
        }
      }
    }
    // the voice's fields under the algorithm
    voice_cell("algorithm", ALG_X + 96, EDIT_Y + 186, 44)
    voice_cell("feedback", ALG_X + 150, EDIT_Y + 186, 44)
    voice_cell("osc_sync", ALG_X + 204, EDIT_Y + 186, 44)
    voice_cell("transpose", ALG_X + 252, EDIT_Y + 186, 44)
    // LFO and pitch envelope
    local x = TABLE_X + 44
    for(let local id in values({"wave", "speed", "delay", "pmd", "amd", "lfo_sync", "pms"})){
      local w = CELL_W - 2
      if(id == "wave"){
        w = CELL_W * 2 - 2
      }
      voice_cell(id, x, LFO_Y + 22, w)
      x = x + w + 2
    }
    x = x + 72
    for(let local id in values({"pr1", "pr2", "pr3", "pr4", "pl1", "pl2", "pl3", "pl4"})){
      voice_cell(id, x, LFO_Y + 22, CELL_W - 2)
      x = x + CELL_W
    }
  }

  local func cell_at(mx, my){
    for(let local c in values(cells)){
      if(mx >= c.x and mx < c.x + c.w and my >= c.y and my < c.y + c.h){
        return c
      }
    }
    return null
  }

  local func set_cell(c, v){
    local f = c.field
    v = clamp(to_int(v), f.min, f.max)
    if(v != c.get()){
      c.set(v)
      app.changed()
    }
  }

  // ---- the algorithm diagram

  // where operator k (1..6) is drawn: {x, y} of its box's top left
  local BOX_W = 34
  local BOX_H = 24
  local func op_boxes(){
    local a = algorithms.get(p().algorithm)
    local lay = algorithms.layout(a)
    local boxes = {}
    local gap_x = 46
    local width = lay.cols * gap_x - (gap_x - BOX_W)
    local x0 = ALG_X + (ALG_W - width) / 2
    for(local k = 1; k <= 6; k = k + 1){
      local l = lay[k]
      boxes[k] = {x: x0 + l.col * gap_x, y: EDIT_Y + 128 - l.row * 34}
    }
    return boxes
  }

  local func draw_algorithm(){
    local a = algorithms.get(p().algorithm)
    local boxes = op_boxes()
    rl.draw_rectangle(ALG_X, EDIT_Y, ALG_W, 212, colors.face)
    text("ALGORITHM", ALG_X + 10, EDIT_Y + 8, 10, colors.dim)
    text(two(p().algorithm), ALG_X + ALG_W - 34, EDIT_Y + 6, 16, colors.accent)
    // connections: from a modulator's bottom to its target's top
    for(local k = 1; k <= 6; k = k + 1){
      for(let local m in values(a.mods[k])){
        local from = boxes[m]
        local to = boxes[k]
        rl.draw_line_ex({x: from.x + BOX_W / 2, y: from.y + BOX_H}, {x: to.x + BOX_W / 2, y: to.y}, 2, colors.line)
      }
    }
    // the output bar under the carriers
    local bar_y = EDIT_Y + 160
    local lo = 10000
    local hi = -10000
    for(let local c in values(a.carriers)){
      local b = boxes[c]
      rl.draw_line_ex({x: b.x + BOX_W / 2, y: b.y + BOX_H}, {x: b.x + BOX_W / 2, y: bar_y}, 2, colors.line)
      lo = math.min(lo, b.x + BOX_W / 2)
      hi = math.max(hi, b.x + BOX_W / 2)
    }
    rl.draw_line_ex({x: lo, y: bar_y}, {x: hi, y: bar_y}, 2, colors.line)
    // the feedback loop: out of the source's right side, into the
    // destination's top
    local src = boxes[a.fb_from]
    local dst = boxes[a.fb_to]
    local fx = math.max(src.x, dst.x) + BOX_W + 8
    local col = colors.teal
    if(p().feedback == 0){
      col = colors.faint
    }
    rl.draw_line_ex({x: src.x + BOX_W, y: src.y + BOX_H / 2}, {x: fx, y: src.y + BOX_H / 2}, 2, col)
    rl.draw_line_ex({x: fx, y: src.y + BOX_H / 2}, {x: fx, y: dst.y - 6}, 2, col)
    rl.draw_line_ex({x: fx, y: dst.y - 6}, {x: dst.x + BOX_W / 2, y: dst.y - 6}, 2, col)
    rl.draw_line_ex({x: dst.x + BOX_W / 2, y: dst.y - 6}, {x: dst.x + BOX_W / 2, y: dst.y}, 2, col)
    for(local k = 1; k <= 6; k = k + 1){
      local b = boxes[k]
      local o = p().ops[k - 1]
      local fill = colors.button
      local fg = colors.text
      if(algorithms.is_carrier(a, k)){
        fill = colors.accent_dark
      }
      if(o.on == 0){
        fill = colors.cell
        fg = colors.faint
      }
      rl.draw_rectangle(to_int(b.x), to_int(b.y), BOX_W, BOX_H, fill)
      text_center(string(k), b.x + BOX_W / 2, b.y + 6, 12, fg)
    }
  }

  // the operator box under the mouse (1..6), or null
  local func op_box_at(mx, my){
    local boxes = op_boxes()
    for(local k = 1; k <= 6; k = k + 1){
      local b = boxes[k]
      if(mx >= b.x and mx < b.x + BOX_W and my >= b.y and my < b.y + BOX_H){
        return k
      }
    }
    return null
  }

  local draw_eg = gfx.draw_eg

  local func draw_table(){
    local x0 = TABLE_X + 44
    rl.draw_rectangle(TABLE_X, EDIT_Y, panel.W - 20 - TABLE_X, 212, colors.face)
    // headings
    local x = x0
    for(let local id in values(columns)){
      local label = "FREQ"
      local w = CELL_W * 2
      if(id != "freq"){
        label = field_of[id].label
        w = CELL_W
      }
      text_center(label, x + (w - 2) / 2, EDIT_Y + 8, 8, colors.dim)
      x = x + w
    }
    text_center("ENVELOPE", x + 50, EDIT_Y + 8, 8, colors.dim)
    local a = algorithms.get(p().algorithm)
    for(local i = 0; i < 6; i = i + 1){
      local y = EDIT_Y + 26 + i * ROW_H
      local color = colors.text
      if(algorithms.is_carrier(a, i + 1)){
        color = colors.accent
      }
      text(concat("OP", string(i + 1)), TABLE_X + 8, y + 7, 12, color)
      local o = p().ops[i]
      rl.draw_rectangle(to_int(x), y, 104, ROW_H - 4, colors.cell)
      local eg_color = colors.teal
      if(o.on == 0 or o.level == 0){
        eg_color = colors.faint
      }
      draw_eg({o.r1, o.r2, o.r3, o.r4}, {o.l1, o.l2, o.l3, o.l4}, x, y, 104, ROW_H - 4, o.l4, eg_color)
    }
  }

  local func draw_lfo(){
    rl.draw_rectangle(TABLE_X, LFO_Y, panel.W - 20 - TABLE_X, 64, colors.face)
    text("LFO", TABLE_X + 8, LFO_Y + 28, 12, colors.text)
    local x = TABLE_X + 44
    for(let local id in values({"wave", "speed", "delay", "pmd", "amd", "lfo_sync", "pms"})){
      local w = CELL_W
      local label = field_of[id].label
      if(id == "wave"){
        w = CELL_W * 2
        label = "WAVE"
      } else if(id == "speed"){
        label = "SPEED"
      } else if(id == "delay"){
        label = "DELAY"
      } else if(id == "pmd"){
        label = "PMD"
      } else if(id == "amd"){
        label = "AMD"
      } else if(id == "lfo_sync"){
        label = "SYNC"
      } else {
        label = "PMS"
      }
      text_center(label, x + (w - 2) / 2, LFO_Y + 8, 8, colors.dim)
      x = x + w
    }
    text("PITCH EG", x + 12, LFO_Y + 28, 10, colors.text)
    x = x + 72
    for(let local id in values({"pr1", "pr2", "pr3", "pr4", "pl1", "pl2", "pl3", "pl4"})){
      text_center(str_tail(field_of[id].label), x + (CELL_W - 2) / 2, LFO_Y + 8, 8, colors.dim)
      x = x + CELL_W
    }
    rl.draw_rectangle(to_int(x), LFO_Y + 22, 104, ROW_H - 4, colors.cell)
    // the pitch envelope around its middle line
    rl.draw_line(to_int(x), LFO_Y + 22 + (ROW_H - 4) / 2, to_int(x) + 104, LFO_Y + 22 + (ROW_H - 4) / 2, colors.faint)
    local q = p()
    draw_eg({q.pr1, q.pr2, q.pr3, q.pr4}, {q.pl1, q.pl2, q.pl3, q.pl4}, x, LFO_Y + 22, 104, ROW_H - 4, q.pl4, colors.teal)
  }

  local func draw_cells(){
    local m = rl.get_mouse_position()
    for(let local c in values(cells)){
      local bg = colors.cell
      if((drag != null and drag.cell.x == c.x and drag.cell.y == c.y) or
        (drag == null and m.x >= c.x and m.x < c.x + c.w and m.y >= c.y and m.y < c.y + c.h)){
        bg = colors.cell_hot
      }
      rl.draw_rectangle(to_int(c.x), to_int(c.y), to_int(c.w), to_int(c.h), bg)
      local s = null
      if(c.show != null){
        s = c.show()
      } else {
        s = cell_text(c, c.get())
      }
      local color = colors.lcd_text
      if(c.field.kind == "bool" and c.get() == 0){
        color = colors.faint
      }
      text_center(s, c.x + c.w / 2, c.y + 7, 10, color)
      if(app.learning){
        if(app.armed(c.target)){
          rl.draw_rectangle_lines(to_int(c.x) - 1, to_int(c.y) - 1, to_int(c.w) + 2, to_int(c.h) + 2, colors.accent)
        }
        local b = app.binding(c.target)
        if(b != null){
          // the controller's number in the cell's corner
          text(require("slang/string").substring(b, 3), c.x + 2, c.y + 1, 7, colors.accent)
        }
      }
    }
  }

  // ---- the display and the bank

  local func draw_scope(x, y, w, h){
    local scope = app.scope
    rl.draw_rectangle(x, y, w, h, colors.lcd)
    local n = len(scope) - 1
    local at = to_int(scope[n])
    local start = at - w - 1
    local found = false
    for(local k = 0; k < 900 and not found; k = k + 1){
      local i = (start - k + n * 4) % n
      local prev = (i - 1 + n) % n
      if(scope[prev] < 0.0 and scope[i] >= 0.0){
        start = i
        found = true
      }
    }
    local lastx = x
    local lasty = y + h / 2
    for(local k = 0; k < w; k = k + 1){
      local s = clamp(scope[(start + k + n * 4) % n] * 1.2, -1, 1)
      local py = to_int(y + h / 2 - s * (h / 2 - 2))
      if(k > 0){
        rl.draw_line(lastx, lasty, x + k, py, colors.scope)
      }
      lastx = x + k
      lasty = py
    }
  }

  local func draw_header(){
    text("slang", 20, HEADER_Y + 4, 24, colors.text)
    text("six", 20 + measure("slang ", 24), HEADER_Y + 4, 24, colors.accent)
    text("six-operator FM synthesizer", 20, HEADER_Y + 34, 9, colors.dim)
    // the display
    local lx = 230
    rl.draw_rectangle(lx - 4, HEADER_Y - 4, 420, 56, {12, 12, 12})
    rl.draw_rectangle(lx, HEADER_Y, 412, 48, colors.lcd)
    local name = app.patch.name
    if(app.edited){
      name = concat(name, " *")
    }
    text(concat("INTERNAL ", two(app.choice + 1)), lx + 10, HEADER_Y + 6, 12, colors.lcd_dim)
    text(name, lx + 104, HEADER_Y + 3, 18, colors.lcd_text)
    text(concat("ALG ", two(app.patch.algorithm), "   FB ", string(app.patch.feedback), "   VOICES ", string(app.voices), "/", string(engine.VOICES)),
      lx + 10, HEADER_Y + 28, 12, colors.lcd_dim)
    draw_scope(660, HEADER_Y, 300, 48)
    local s = app.stats
    text(concat("DSP ", string(math.floor(s.load * 1000) / 10), "%"), 980, HEADER_Y + 2, 16, colors.text)
    local color = colors.dim
    if(s.underruns > 0){
      color = colors.warn
    }
    text(concat("underruns ", string(s.underruns), "   FPS ", string(rl.get_fps())), 980, HEADER_Y + 26, 9, color)
    // the volume, a horizontal bar
    local v = app.controls[engine.VOLUME]
    text("VOLUME", 1160, HEADER_Y + 2, 9, colors.dim)
    rl.draw_rectangle(1160, HEADER_Y + 20, 100, 10, colors.cell)
    rl.draw_rectangle(1160, HEADER_Y + 20, to_int(100 * v), 10, colors.accent)
  }

  local func bank_rect(i){
    local bw = (panel.W - 40) / 16
    local row = to_int(i / 16)
    local col = i % 16
    return {x: 20 + col * bw, y: BANK_Y + row * (BANK_H + 4), w: bw - 4, h: BANK_H}
  }

  local func draw_bank(){
    for(local i = 0; i < len(app.bank); i = i + 1){
      local r = bank_rect(i)
      local fill = colors.button
      local fg = colors.text
      if(i == app.choice){
        fill = colors.button_on
        fg = {20, 16, 14}
      }
      rl.draw_rectangle(to_int(r.x), to_int(r.y), to_int(r.w), r.h, fill)
      text(string(i + 1), r.x + 4, r.y + 3, 9, fg)
      local name = app.bank[i].name
      // as much of the name as fits
      for(len(name) > 1 and measure(name, 8) > r.w - 6){
        name = require("slang/string").substring(name, 0, len(name) - 1)
      }
      text(name, r.x + 4, r.y + 16, 8, fg)
    }
  }

  // ---- keys and wheels

  local func key_at(mx, my){
    if(my < KEYS_Y or my > KEYS_Y + WHITE_H){
      return null
    }
    if(my < KEYS_Y + BLACK_H){
      for(let local k in values(keys)){
        if(k.black and mx >= k.x and mx < k.x + k.w){
          return k.note
        }
      }
    }
    for(let local k in values(keys)){
      if(not k.black and mx >= k.x and mx < k.x + k.w){
        return k.note
      }
    }
    return null
  }

  // a key played further toward its front plays louder
  local func velocity_at(my){
    return to_int(clamp(30 + 97 * (my - KEYS_Y) / WHITE_H, 1, 127))
  }

  local func draw_keyboard(){
    rl.draw_rectangle(10, KEYS_Y - 14, panel.W - 20, panel.H - KEYS_Y + 8, colors.face)
    for(let local k in values(keys)){
      if(not k.black){
        local color = colors.white_key
        if(app.held(k.note)){
          color = colors.white_down
        }
        rl.draw_rectangle(to_int(k.x), KEYS_Y, to_int(k.w) - 1, WHITE_H, color)
        if(k.note % 12 == 0){
          text_center(patch.note_name(k.note), k.x + k.w / 2, KEYS_Y + WHITE_H - 18, 9, colors.dim)
        }
      }
    }
    for(let local k in values(keys)){
      if(k.black){
        local color = colors.black_key
        if(app.held(k.note)){
          color = colors.black_down
        }
        rl.draw_rectangle(to_int(k.x), KEYS_Y, to_int(k.w), BLACK_H, color)
      }
    }
    rl.draw_rectangle(KEYS_X, KEYS_Y - 4, panel.W - 20 - KEYS_X, 4, colors.accent_dark)
    for(let local wh in values(wheels)){
      local v = app.controls[wh.index]
      if(wh.index == engine.BEND){
        v = (v + 1) / 2
      }
      local y0 = KEYS_Y + 20
      rl.draw_rectangle(wh.x - 4, y0 - 4, WHEEL_W + 8, WHEEL_H + 8, {10, 10, 10})
      rl.draw_rectangle_gradient_v(wh.x, y0, WHEEL_W, WHEEL_H, {48, 46, 46}, {18, 18, 18})
      local offset = v * 80.0
      for(local k = 0; k < 16; k = k + 1){
        local y = y0 + ((k * 14.0 + offset) % WHEEL_H)
        rl.draw_line(wh.x + 2, to_int(y), wh.x + WHEEL_W - 2, to_int(y), {76, 72, 72})
      }
      local my = to_int(y0 + WHEEL_H - v * WHEEL_H)
      rl.draw_rectangle(wh.x, my - 3, WHEEL_W, 6, colors.accent)
      text_center(wh.label, wh.x + WHEEL_W / 2, y0 + WHEEL_H + 10, 9, colors.dim)
    }
    text_center(concat("OCTAVE ", patch.note_name(app.octave)), 74, KEYS_Y - 10, 9, colors.dim)
  }

  local func wheel_at(mx, my){
    for(let local wh in values(wheels)){
      if(mx >= wh.x - 4 and mx <= wh.x + WHEEL_W + 4 and my >= KEYS_Y + 20 and my <= KEYS_Y + 20 + WHEEL_H){
        return wh
      }
    }
    return null
  }

  // ---- input

  // handle_mouse(): clicks, drags and the wheel
  func self.handle_mouse(){
    build_cells()
    local m = rl.get_mouse_position()
    local left = rl.MOUSE_BUTTON_LEFT
    local fine = rl.is_key_down(rl.KEY_LEFT_SHIFT) or rl.is_key_down(rl.KEY_RIGHT_SHIFT)
    local volume_hit = m.x >= 1160 and m.x <= 1260 and m.y >= HEADER_Y + 14 and m.y <= HEADER_Y + 36
    if(rl.is_mouse_button_pressed(left) and app.learning){
      // MIDI learn: a click names what the next controller moves
      local c = cell_at(m.x, m.y)
      if(c != null){
        app.learn(c.target)
      } else if(volume_hit){
        app.learn("volume")
      }
    } else if(rl.is_mouse_button_pressed(left)){
      local c = cell_at(m.x, m.y)
      local now = rl.get_time()
      if(c != null){
        local f = c.field
        if(f.kind == "bool" or f.kind == "enum"){
          // a switch steps on a click
          local v = c.get() + 1
          if(v > f.max){
            v = f.min
          }
          set_cell(c, v)
        } else {
          drag = {cell: c, y: m.y, value: c.get()}
        }
        last_click = {time: now, cell: c}
      } else {
        local k = op_box_at(m.x, m.y)
        if(k != null){
          // an operator's box mutes it
          local o = app.patch.ops[k - 1]
          o.on = 1 - o.on
          app.changed()
        } else {
          local wh = wheel_at(m.x, m.y)
          if(wh != null){
            wheel_drag = wh
            if(wh.index == engine.BEND){
              app.bend_from_midi = false
            }
          } else if(m.y >= BANK_Y and m.y < BANK_Y + 2 * (BANK_H + 4)){
            for(local i = 0; i < len(app.bank); i = i + 1){
              local r = bank_rect(i)
              if(m.x >= r.x and m.x < r.x + r.w and m.y >= r.y and m.y < r.y + r.h){
                app.choose(i)
              }
            }
          } else if(volume_hit){
            wheel_drag = {index: engine.VOLUME, volume: true}
          } else {
            local n = key_at(m.x, m.y)
            if(n != null){
              mouse_note = n
              app.note_on(n, velocity_at(m.y))
            }
          }
        }
      }
    }
    if(rl.is_mouse_button_down(left)){
      if(drag != null){
        local f = drag.cell.field
        // pixels per step: small ranges take bigger steps
        local px = 3
        if(f.max - f.min <= 10){
          px = 14
        }
        if(fine){
          px = 18
        }
        local v = drag.value + math.floor((drag.y - m.y) / px)
        set_cell(drag.cell, v)
      } else if(wheel_drag != null){
        if(wheel_drag.volume){
          app.controls[engine.VOLUME] = clamp((m.x - 1160) / 100, 0, 1)
        } else {
          local v = clamp((KEYS_Y + 20 + WHEEL_H - m.y) / WHEEL_H, 0, 1)
          if(wheel_drag.index == engine.BEND){
            v = v * 2 - 1
          }
          app.controls[wheel_drag.index] = v
        }
      } else if(mouse_note != null){
        // gliding over the keys
        local n = key_at(m.x, m.y)
        if(n != null and n != mouse_note){
          app.note_on(n, velocity_at(m.y))
          app.note_off(mouse_note)
          mouse_note = n
        }
      }
    }
    if(rl.is_mouse_button_released(left)){
      drag = null
      wheel_drag = null
      if(mouse_note != null){
        app.note_off(mouse_note)
        mouse_note = null
      }
    }
    local w = rl.get_mouse_wheel_move()
    if(w != 0.0){
      local c = cell_at(m.x, m.y)
      if(c != null){
        local step = 1
        if(w < 0){
          step = -1
        }
        set_cell(c, c.get() + step)
      }
    }
    // the pitch wheel springs back (unless the controller holds it)
    if(not app.bend_from_midi and (wheel_drag == null or wheel_drag.index != engine.BEND)){
      local b = app.controls[engine.BEND]
      if(b != 0){
        local nb = b * 0.65
        if(math.abs(nb) < 0.003){
          nb = 0
        }
        app.controls[engine.BEND] = nb
      }
    }
  }

  // a controller bound to a target moves it
  app.on_cc = func(target, value){
    if(target == "volume"){
      app.controls[engine.VOLUME] = value / 127
      return null
    }
    build_cells()
    for(let local c in values(cells)){
      if(c.target == target){
        set_cell(c, app.cc_value(c.field, value))
      }
    }
  }

  // draw(): the whole panel
  func self.draw(){
    build_cells()
    rl.clear_background(colors.body)
    draw_header()
    draw_bank()
    draw_algorithm()
    draw_table()
    draw_lfo()
    draw_cells()
    // the voice cells' labels under the diagram
    local labels = {{"ALG", 96}, {"FB", 150}, {"SYNC", 204}, {"TRANS", 252}}
    for(let local l in values(labels)){
      text_center(l[0], ALG_X + l[1] + 22, EDIT_Y + 186 - 10, 8, colors.dim)
    }
    draw_keyboard()
    if(app.learning){
      text("MIDI LEARN: click a value, then turn a knob on the controller    F1: done    BACKSPACE: unbind it",
        KEYS_X, KEYS_Y - 13, 8, colors.accent)
    } else {
      text("keys Z..M Q..I   left/right octave   up/down patch   TAB sustain   SPACE all off   F1 MIDI learn",
        KEYS_X, KEYS_Y - 13, 8, colors.faint)
    }
    local vb = app.binding("volume")
    if(app.learning and vb != null){
      text(vb, 1220, HEADER_Y + 2, 8, colors.accent)
    }
  }

  return self
}

return panel
