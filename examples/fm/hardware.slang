// The 3D synth's front panel, as hardware has it: a backlit display, eight
// encoders under it that turn whatever the display shows, buttons that
// choose the page (OSC, ENV, SCALE, VOICE, LFO, PITCH EG) and the operator
// it shows, and a bank of 32 patch buttons with their names printed above
// them. A volume knob, the wheels and the keys complete it.
//
// Everything here is in face pixels (the window of 1200 x 700 the face is
// laid out for): main3d.slang draws the face into a texture with draw_face
// and turns its mouse rays into face positions for control_at. The knobs,
// buttons, LEDs, keys and wheels are its meshes; this module says where
// they are and what they do.
local rl = require("raylib")
local math = require("slang/math")
local patch = require("patch")
local algorithms = require("algorithms")
local engine = require("engine")
local gfx = require("gfx")

local hw = {}

hw.W = 1200
hw.H = 700
// the face: x 40..1160, y 20..FACE_BOTTOM
hw.FACE_TOP = 20
hw.FACE_BOTTOM = 446

local colors = {
  panel: {30, 28, 29},
  print: {214, 206, 192},
  dim: {140, 132, 122},
  faint: {88, 82, 78},
  accent: {232, 118, 64},
  lcd: {34, 62, 52},
  lcd_dark: {22, 42, 36},
  lcd_text: {176, 246, 212},
  lcd_dim: {96, 156, 130},
  line: {74, 68, 66},
}
hw.colors = colors

// ------------------------------------------------------------ the pages

local field_of = {}
for(let local f in values(patch.OP_FIELDS)){
  field_of[f.id] = f
}
for(let local f in values(patch.VOICE_FIELDS)){
  field_of[f.id] = f
}

// each page: its button's label, its title on the display, whether it
// shows the selected operator, and the field of each encoder ("" for none)
hw.PAGES = {
  {label: "OSC", title: "OSCILLATOR", op: true,
    fields: {"mode", "coarse", "fine", "detune", "level", "vel", "rs", "ams"}},
  {label: "ENV", title: "ENVELOPE", op: true,
    fields: {"r1", "r2", "r3", "r4", "l1", "l2", "l3", "l4"}},
  {label: "SCALE", title: "KEY SCALING", op: true,
    fields: {"break", "ldepth", "rdepth", "lcurve", "rcurve", "", "", ""}},
  {label: "VOICE", title: "VOICE", op: false,
    fields: {"algorithm", "feedback", "osc_sync", "transpose", "", "", "", ""}},
  {label: "LFO", title: "LFO", op: false,
    fields: {"wave", "speed", "delay", "pmd", "amd", "lfo_sync", "pms", ""}},
  {label: "P.EG", title: "PITCH ENVELOPE", op: false,
    fields: {"pr1", "pr2", "pr3", "pr4", "pl1", "pl2", "pl3", "pl4"}},
}
// shorter labels for the display's slots
local slot_labels = {
  mode: "MODE", coarse: "COARSE", fine: "FINE", detune: "DETUNE",
  level: "LEVEL", vel: "VELO", rs: "RATE SC", ams: "AMS",
  r1: "RATE 1", r2: "RATE 2", r3: "RATE 3", r4: "RATE 4",
  l1: "LEVEL 1", l2: "LEVEL 2", l3: "LEVEL 3", l4: "LEVEL 4",
  ["break"]: "BREAK", ldepth: "L DEPTH", rdepth: "R DEPTH", lcurve: "L CURVE", rcurve: "R CURVE",
  algorithm: "ALGORITHM", feedback: "FEEDBACK", osc_sync: "OSC SYNC", transpose: "TRANSPOSE",
  wave: "WAVE", speed: "SPEED", delay: "DELAY", pmd: "PITCH MD", amd: "AMP MD",
  lfo_sync: "KEY SYNC", pms: "PITCH SNS",
  pr1: "RATE 1", pr2: "RATE 2", pr3: "RATE 3", pr4: "RATE 4",
  pl1: "LEVEL 1", pl2: "LEVEL 2", pl3: "LEVEL 3", pl4: "LEVEL 4",
}

// the page shown (0..5; FM_PAGE=n starts on page n, 1..6) and the
// operator chosen (0..5)
hw.page = 0
if(require("slang/os").getenv("FM_PAGE") != null){
  hw.page = to_int(require("slang/os").getenv("FM_PAGE")) - 1
}
hw.op = 0

// ------------------------------------------------------------ the layout

local LCD = {x: 210, y: 40, w: 540, h: 156}
hw.LCD = LCD
local SLOT_W = LCD.w / 8

// controls: {kind, index, x, y (center), w, h (buttons), r (knobs)}
hw.knobs = {}
for(local i = 0; i < 8; i = i + 1){
  append(hw.knobs, {kind: "encoder", index: i, x: LCD.x + SLOT_W * (i + 0.5), y: 240, r: 19})
}
append(hw.knobs, {kind: "volume", index: 0, x: 120, y: 176, r: 24})

hw.buttons = {}
local BUTTON_W = 54
local BUTTON_H = 24
for(local i = 0; i < 6; i = i + 1){
  append(hw.buttons, {kind: "page", index: i, x: 798 + (i % 3) * 68, y: 92 + to_int(i / 3) * 62, w: BUTTON_W, h: BUTTON_H})
}
for(local i = 0; i < 6; i = i + 1){
  append(hw.buttons, {kind: "op", index: i, x: 1018 + (i % 3) * 58, y: 92 + to_int(i / 3) * 62, w: 46, h: BUTTON_H})
}
local BANK_X = 72
local BANK_STEP = (1128 - BANK_X) / 15
for(local i = 0; i < 32; i = i + 1){
  append(hw.buttons, {kind: "patch", index: i, x: BANK_X + (i % 16) * BANK_STEP, y: 334 + to_int(i / 16) * 70, w: 52, h: 22})
}

// the keys: {note, black, x, w} in face pixels, 61 from C2
local KEYS_X = 160
local FIRST_NOTE = 36
local LAST_NOTE = 96
hw.KEYS_X = KEYS_X
hw.keys = {}
local is_black = {false, true, false, true, false, false, true, false, true, false, true, false}
local whites = 0
for(local n = FIRST_NOTE; n <= LAST_NOTE; n = n + 1){
  if(not is_black[n % 12]){
    whites = whites + 1
  }
}
local white_w = (hw.W - 48 - KEYS_X) / whites
local j = 0
for(local n = FIRST_NOTE; n <= LAST_NOTE; n = n + 1){
  if(is_black[n % 12]){
    append(hw.keys, {note: n, black: true, x: KEYS_X + j * white_w - white_w * 0.3, w: white_w * 0.6})
  } else {
    append(hw.keys, {note: n, black: false, x: KEYS_X + j * white_w, w: white_w})
    j = j + 1
  }
}

// the wheels left of the keys: {index (the engine's control), x}
hw.wheels = {
  {index: engine.BEND, x: 52, spring: true},
  {index: engine.WHEEL, x: 100, spring: false},
}
hw.WHEEL_W = 28

// ------------------------------------------------------------ values

// the field and the value of encoder i on the current page (null: none)
local func encoder_field(app, i){
  local id = hw.PAGES[hw.page].fields[i]
  if(id == ""){
    return null
  }
  return field_of[id]
}

local func get(app, f){
  if(hw.PAGES[hw.page].op){
    return app.patch.ops[hw.op][f.id]
  }
  return app.patch[f.id]
}

local func set(app, f, v){
  v = to_int(math.clamp(v, f.min, f.max))
  if(v == get(app, f)){
    return null
  }
  if(hw.PAGES[hw.page].op){
    app.patch.ops[hw.op][f.id] = v
  } else {
    app.patch[f.id] = v
  }
  app.changed()
}

// target_of(knob) -> its name for MIDI learn: "encoder1".."encoder8",
// "volume"
func hw.target_of(k){
  if(k.kind == "volume"){
    return "volume"
  }
  return concat("encoder", string(k.index + 1))
}

// set_target(app, target, value): a controller (0..127) bound to a knob
// turns it: an encoder sets its parameter on the current page
func hw.set_target(app, target, value){
  if(target == "volume"){
    app.controls[engine.VOLUME] = value / 127
    return null
  }
  if(not require("slang/string").starts_with(target, "encoder")){
    return null
  }
  local i = to_int(require("slang/string").substring(target, 7)) - 1
  local f = encoder_field(app, i)
  if(f != null){
    set(app, f, app.cc_value(f, value))
  }
}

// knob_fraction(app, knob) -> 0..1 where its pointer is, or null (an
// encoder without a parameter on this page points straight up)
func hw.knob_fraction(app, k){
  if(k.kind == "volume"){
    return app.controls[engine.VOLUME]
  }
  local f = encoder_field(app, k.index)
  if(f == null){
    return null
  }
  return (get(app, f) - f.min) / (f.max - f.min)
}

// lit(app, button) -> whether its LED is on
func hw.lit(app, b){
  if(b.kind == "page"){
    return b.index == hw.page
  }
  if(b.kind == "op"){
    return app.patch.ops[b.index].on == 1
  }
  return b.index == app.choice
}

// ------------------------------------------------------------ input

// control_at(x, y) -> the knob or button at a face position, or null
func hw.control_at(x, y){
  for(let local k in values(hw.knobs)){
    local dx = x - k.x
    local dy = y - k.y
    if(dx * dx + dy * dy <= (k.r + 7) * (k.r + 7)){
      return k
    }
  }
  for(let local b in values(hw.buttons)){
    if(x >= b.x - b.w / 2 - 3 and x <= b.x + b.w / 2 + 3 and y >= b.y - b.h / 2 - 3 and y <= b.y + b.h / 2 + 3){
      return b
    }
  }
  return null
}

// what the mouse holds: {control, y, value}
local drag = null
local last_click = {control: null, time: -1.0}
// the button held down (drawn pressed)
hw.held = null

// press(app, control, y, shift): a click on a control at screen height y.
// An operator button chooses the operator (with shift: turns it on or
// off); a double click on an encoder puts its parameter back as the bank
// has it
func hw.press(app, c, y, shift){
  if(app.learning and (c.kind == "encoder" or c.kind == "volume")){
    // MIDI learn: the next controller to move turns this knob
    app.learn(hw.target_of(c))
    return null
  }
  local now = rl.get_time()
  local double = last_click.control == c and now - last_click.time < 0.35
  last_click = {control: c, time: now}
  if(c.kind == "page"){
    hw.page = c.index
    hw.held = c
  } else if(c.kind == "op"){
    if(shift){
      local o = app.patch.ops[c.index]
      o.on = 1 - o.on
      app.changed()
    } else {
      hw.op = c.index
    }
    hw.held = c
  } else if(c.kind == "patch"){
    app.choose(c.index)
    hw.held = c
  } else if(c.kind == "volume"){
    drag = {control: c, y: y, value: app.controls[engine.VOLUME]}
  } else {
    local f = encoder_field(app, c.index)
    if(f == null){
      return null
    }
    if(double){
      local original = app.original()
      if(hw.PAGES[hw.page].op){
        set(app, f, original.ops[hw.op][f.id])
      } else {
        set(app, f, original[f.id])
      }
      return null
    }
    drag = {control: c, y: y, value: get(app, f)}
  }
}

// drag(app, y, shift): the mouse, held, at screen height y: up turns right
func hw.drag(app, y, shift){
  if(drag == null){
    return null
  }
  local c = drag.control
  local dy = drag.y - y
  if(c.kind == "volume"){
    app.controls[engine.VOLUME] = math.clamp(drag.value + dy / 200, 0, 1)
    return null
  }
  local f = encoder_field(app, c.index)
  if(f == null){
    return null
  }
  // pixels per step: small ranges take bigger steps
  local px = 4
  if(f.max - f.min <= 10){
    px = 18
  }
  if(shift){
    px = 18
  }
  set(app, f, drag.value + math.floor(dy / px))
}

func hw.dragging(){
  return drag != null
}

// held_knob() -> the knob the mouse turns, or null
func hw.held_knob(){
  if(drag == null){
    return null
  }
  return drag.control
}

func hw.release(){
  drag = null
  hw.held = null
}

// scroll(app, control, w): the mouse wheel over a control
func hw.scroll(app, c, w){
  local step = 1
  if(w < 0){
    step = -1
  }
  if(c.kind == "volume"){
    app.controls[engine.VOLUME] = math.clamp(app.controls[engine.VOLUME] + step * 0.02, 0, 1)
  } else if(c.kind == "encoder"){
    local f = encoder_field(app, c.index)
    if(f != null){
      set(app, f, get(app, f) + step)
    }
  } else if(c.kind == "page"){
    hw.page = (hw.page + 6 - step) % 6
  } else if(c.kind == "op"){
    hw.op = (hw.op + 6 - step) % 6
  }
}

// ------------------------------------------------------------ the display

local text = gfx.text
local text_center = gfx.text_center
local two = gfx.two

// the algorithm as boxes, the chosen operator inverted, muted ones dim
local func draw_algorithm(app, x, y, w, h){
  local a = algorithms.get(app.patch.algorithm)
  local lay = algorithms.layout(a)
  local bw = 18
  local bh = 13
  local gap_x = 23
  local gap_y = 19
  local width = lay.cols * gap_x - (gap_x - bw)
  local x0 = x + (w - width) / 2
  local boxes = {}
  for(local k = 1; k <= 6; k = k + 1){
    boxes[k] = {x: x0 + lay[k].col * gap_x, y: y + h - bh - 6 - lay[k].row * gap_y}
  }
  for(local k = 1; k <= 6; k = k + 1){
    for(let local m in values(a.mods[k])){
      rl.draw_line_ex({x: boxes[m].x + bw / 2, y: boxes[m].y + bh}, {x: boxes[k].x + bw / 2, y: boxes[k].y}, 1.5, colors.lcd_dim)
    }
  }
  local bottom = y + h - 3
  for(let local c in values(a.carriers)){
    rl.draw_line_ex({x: boxes[c].x + bw / 2, y: boxes[c].y + bh}, {x: boxes[c].x + bw / 2, y: bottom}, 1.5, colors.lcd_dim)
  }
  local s = boxes[a.fb_from]
  local d = boxes[a.fb_to]
  local fx = math.max(s.x, d.x) + bw + 4
  rl.draw_line_ex({x: s.x + bw, y: s.y + bh / 2}, {x: fx, y: s.y + bh / 2}, 1.5, colors.lcd_dim)
  rl.draw_line_ex({x: fx, y: s.y + bh / 2}, {x: fx, y: d.y - 3}, 1.5, colors.lcd_dim)
  rl.draw_line_ex({x: fx, y: d.y - 3}, {x: d.x + bw / 2, y: d.y - 3}, 1.5, colors.lcd_dim)
  for(local k = 1; k <= 6; k = k + 1){
    local b = boxes[k]
    local on = app.patch.ops[k - 1].on == 1
    if(k - 1 == hw.op and hw.PAGES[hw.page].op){
      rl.draw_rectangle(to_int(b.x), to_int(b.y), bw, bh, colors.lcd_text)
      text_center(string(k), b.x + bw / 2, b.y + 2, 9, colors.lcd_dark)
    } else {
      local col = colors.lcd_text
      if(not on){
        col = colors.lcd_dim
      }
      rl.draw_rectangle_lines(to_int(b.x), to_int(b.y), bw, bh, col)
      text_center(string(k), b.x + bw / 2, b.y + 2, 9, col)
    }
  }
}

// what the page shows above its slots
local func draw_page_view(app, x, y, w, h){
  local page = hw.PAGES[hw.page]
  local p = app.patch
  if(page.label == "ENV"){
    local o = p.ops[hw.op]
    gfx.draw_eg({o.r1, o.r2, o.r3, o.r4}, {o.l1, o.l2, o.l3, o.l4}, x, y, w, h, o.l4, colors.lcd_text, 2)
  } else if(page.label == "P.EG"){
    rl.draw_line(to_int(x), to_int(y + h / 2), to_int(x + w), to_int(y + h / 2), colors.lcd_dim)
    gfx.draw_eg({p.pr1, p.pr2, p.pr3, p.pr4}, {p.pl1, p.pl2, p.pl3, p.pl4}, x, y, w, h, p.pl4, colors.lcd_text, 2)
  } else if(page.label == "OSC"){
    local o = p.ops[hw.op]
    local what = "RATIO"
    if(o.mode == 1){
      what = "FIXED"
    }
    text(what, x, y + 6, 9, colors.lcd_dim)
    text(patch.frequency_text(o), x, y + 18, 22, colors.lcd_text)
    text("LEVEL", x + 130, y + 6, 9, colors.lcd_dim)
    text(string(o.level), x + 130, y + 18, 22, colors.lcd_text)
    local role = "MODULATOR"
    if(algorithms.is_carrier(algorithms.get(p.algorithm), hw.op + 1)){
      role = "CARRIER"
    }
    if(o.on == 0){
      role = concat(role, " (OFF)")
    }
    text(role, x + 210, y + 26, 9, colors.lcd_dim)
  } else if(page.label == "SCALE"){
    // the level across the keyboard
    local o = p.ops[hw.op]
    local prev = null
    for(local n = 21; n <= 108; n = n + 2){
      local d = (n - o["break"]) / 12
      local depth = o.rdepth
      local curve = o.rcurve
      if(d < 0){
        d = -d
        depth = o.ldepth
        curve = o.lcurve
      }
      local shape = d
      if(curve == 1 or curve == 2){
        shape = ((2 ^ d) - 1) * 0.5
      }
      local k = depth / 99 * shape
      if(curve < 2){
        k = -k
      }
      local py = y + h / 2 - math.clamp(k, -4, 2) * h / 8
      local px = x + (n - 21) / 87 * w
      if(prev != null){
        rl.draw_line_ex(prev, {x: px, y: py}, 2, colors.lcd_text)
      }
      prev = {x: px, y: py}
    }
    local bx = x + (o["break"] - 21) / 87 * w
    rl.draw_line(to_int(bx), to_int(y), to_int(bx), to_int(y + h), colors.lcd_dim)
  } else if(page.label == "LFO"){
    // one cycle of the wave
    local prev = null
    local seed = 7
    for(local i = 0; i <= 64; i = i + 1){
      local ph = i / 64
      local v = 0.0
      if(p.wave == 0){
        v = 1 - 4 * math.abs(ph - 0.5)
      } else if(p.wave == 1){
        v = 1 - 2 * ph
      } else if(p.wave == 2){
        v = 2 * ph - 1
      } else if(p.wave == 3){
        v = 1.0
        if(ph >= 0.5){
          v = -1.0
        }
      } else if(p.wave == 4){
        v = math.sin(ph * 2 * math.pi)
      } else {
        // steps of a made-up random sequence
        local step = to_int(ph * 6)
        v = ((step * 37 + seed) % 11) / 5.5 - 1
      }
      local pt = {x: x + ph * (w - 140), y: y + h / 2 - v * (h / 2 - 3)}
      if(prev != null){
        rl.draw_line_ex(prev, pt, 2, colors.lcd_text)
      }
      prev = pt
    }
    text(concat(string(math.round(patch.lfo_hz(p.speed) * 10) / 10), " Hz"), x + w - 120, y + 18, 16, colors.lcd_text)
  } else {
    text("ALGORITHM", x, y + 6, 9, colors.lcd_dim)
    text(two(p.algorithm), x, y + 18, 22, colors.lcd_text)
    text("FEEDBACK", x + 100, y + 6, 9, colors.lcd_dim)
    text(string(p.feedback), x + 100, y + 18, 22, colors.lcd_text)
    text(concat("VOICES ", string(app.voices), "/", string(engine.VOICES)), x + 200, y + 26, 9, colors.lcd_dim)
  }
}

local func draw_lcd(app){
  local x = LCD.x
  local y = LCD.y
  // the bezel and the glass
  rl.draw_rectangle(x - 8, y - 8, LCD.w + 16, LCD.h + 16, {10, 10, 10})
  rl.draw_rectangle_gradient_v(x, y, LCD.w, LCD.h, colors.lcd, colors.lcd_dark)
  local p = app.patch
  local name = p.name
  if(app.edited){
    name = concat(name, " *")
  }
  text(concat("INT ", two(app.choice + 1)), x + 10, y + 10, 10, colors.lcd_dim)
  text(name, x + 60, y + 6, 16, colors.lcd_text)
  local page = hw.PAGES[hw.page]
  local title = page.title
  if(page.op){
    title = concat("OP", string(hw.op + 1), "  ", title)
  }
  if(app.learning){
    title = "MIDI LEARN: CLICK A KNOB, TURN ONE"
  }
  text(title, x + LCD.w - 10 - gfx.measure(title, 10), y + 10, 10, colors.lcd_text)
  rl.draw_line(x + 6, y + 30, x + LCD.w - 6, y + 30, colors.lcd_dim)
  draw_algorithm(app, x + 6, y + 34, 140, 72)
  draw_page_view(app, x + 160, y + 38, LCD.w - 172, 62)
  rl.draw_line(x + 6, y + 108, x + LCD.w - 6, y + 108, colors.lcd_dim)
  // the slots, over the encoders
  for(local i = 0; i < 8; i = i + 1){
    local cx = x + SLOT_W * (i + 0.5)
    local f = encoder_field(app, i)
    if(f != null){
      text_center(slot_labels[f.id], cx, y + 114, 8, colors.lcd_dim)
      text_center(patch.field_text(f, get(app, f)), cx, y + 128, 16, colors.lcd_text)
    } else {
      text_center("-", cx, y + 128, 16, colors.lcd_dim)
    }
    if(i > 0){
      rl.draw_line(to_int(x + SLOT_W * i), y + 112, to_int(x + SLOT_W * i), y + LCD.h - 6, {44, 80, 66})
    }
  }
}

// draw_face(app, caps): the panel's face, the display and everything
// printed on it, x from 40 to 1160 and y from FACE_TOP to FACE_BOTTOM;
// caps: also flat knobs and buttons (for a 2D view of the face; the 3D
// synth makes its own)
func hw.draw_face(app, caps){
  rl.draw_rectangle(40, hw.FACE_TOP, 1120, hw.FACE_BOTTOM - hw.FACE_TOP, colors.panel)
  // a band of colour along the top, as on the panels of the time
  rl.draw_rectangle(40, hw.FACE_TOP, 1120, 6, colors.accent)
  text("slang", 64, 40, 26, colors.print)
  text("six", 64 + gfx.measure("slang ", 26), 40, 26, colors.accent)
  text("SIX-OPERATOR", 64, 76, 8, colors.dim)
  text("FM SYNTHESIZER", 64, 88, 8, colors.dim)
  local s = app.stats
  text(concat("DSP ", string(math.floor(s.load * 1000) / 10), "%"), 64, 108, 8, colors.faint)
  text_center("VOLUME", 120, 214, 9, colors.print)
  // scales around the knobs: the volume's ticks, the encoders' dots
  for(let local k in values(hw.knobs)){
    if(k.kind == "volume"){
      for(local t = 0; t <= 10; t = t + 1){
        local a = (t / 10 * 300 - 150) * math.pi / 180
        rl.draw_line_ex(
          {x: k.x + math.sin(a) * (k.r + 6), y: k.y - math.cos(a) * (k.r + 6)},
          {x: k.x + math.sin(a) * (k.r + 11), y: k.y - math.cos(a) * (k.r + 11)},
          1.5, colors.dim)
      }
    } else {
      for(local t = 0; t < 16; t = t + 1){
        local a = t / 16 * 2 * math.pi
        rl.draw_circle(to_int(k.x + math.sin(a) * (k.r + 7)), to_int(k.y - math.cos(a) * (k.r + 7)), 1.2, colors.faint)
      }
    }
  }
  draw_lcd(app)
  if(not app.learning){
    text("DATA", LCD.x, 266, 8, colors.faint)
  } else {
    for(let local k in values(hw.knobs)){
      local target = hw.target_of(k)
      if(app.armed(target)){
        rl.draw_circle_lines(to_int(k.x), to_int(k.y), k.r + 12, colors.accent)
        rl.draw_circle_lines(to_int(k.x), to_int(k.y), k.r + 13, colors.accent)
      }
      local b = app.binding(target)
      if(b != null){
        text_center(b, k.x, k.y + k.r + 12, 8, colors.accent)
      }
    }
  }
  // the buttons' headings and labels
  text("PAGE", 798 - BUTTON_W / 2, 38, 9, colors.print)
  text("OPERATOR", 1018 - 23, 38, 9, colors.print)
  rl.draw_line(798 - BUTTON_W / 2, 50, 798 + 136 + BUTTON_W / 2, 50, colors.line)
  rl.draw_line(1018 - 23, 50, 1018 + 116 + 23, 50, colors.line)
  text("SHIFT + OPERATOR: ON / OFF", 1018 - 23, 202, 7, colors.faint)
  for(let local b in values(hw.buttons)){
    local label = null
    if(b.kind == "page"){
      label = hw.PAGES[b.index].label
    } else if(b.kind == "op"){
      label = concat("OP", string(b.index + 1))
    } else {
      label = concat(string(b.index + 1), " ", app.bank[b.index].name)
      // as much of the name as fits over the button
      for(len(label) > 2 and gfx.measure(label, 7) > BANK_STEP - 6){
        label = require("slang/string").substring(label, 0, len(label) - 1)
      }
    }
    if(b.kind == "patch"){
      text(label, b.x - b.w / 2, b.y - b.h / 2 - 15, 7, colors.print)
    } else {
      text_center(label, b.x, b.y - b.h / 2 - 15, 8, colors.print)
    }
    if(caps){
      rl.draw_rectangle(to_int(b.x - b.w / 2), to_int(b.y - b.h / 2), b.w, b.h, {70, 66, 64})
      if(hw.lit(app, b)){
        rl.draw_rectangle(to_int(b.x + b.w / 2 - 10), to_int(b.y - b.h / 2 + 3), 6, 4, colors.accent)
      }
    }
  }
  text("INTERNAL MEMORY", BANK_X - 26, 290, 9, colors.print)
  rl.draw_line(BANK_X + 80, 296, 1134, 296, colors.line)
  if(caps){
    for(let local k in values(hw.knobs)){
      rl.draw_circle(to_int(k.x), to_int(k.y), k.r, {16, 16, 16})
    }
  }
}

return hw
