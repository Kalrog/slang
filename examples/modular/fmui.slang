// The FM module on screen: the algorithm diagram on its panel, and the
// editor page (E, or a click on the panel's face) that shows every
// parameter of its patch as a cell to drag, wheel or click, the six
// envelopes and the pitch envelope as graphs, and the bank's 32 presets to
// pick from. In pixels of the 640 x 360 screen, with the 3x5 font.
//
//   fmui.draw_panel(r, m, grid, color, hot)      the diagram in a panel's grid
//   fmui.draw(r, m, state)                       the editor page
//   fmui.hit(r, m, x, y)                         what the mouse is over on it
//   fmui.tip(r, m, hover)                        the status line for it
local rl = require("raylib")
local math = require("slang/math")
local font = require("font")
local rack = require("rack")
local patch = require("patch")
local algorithms = require("algorithms")

local fmui = {}

local VW = 640
local BOTTOM = 343

local colors = {
  bg: {36, 32, 44},
  cell: {30, 28, 36},
  cell_hot: {70, 64, 84},
  cell_drag: {96, 88, 112},
  panel: {22, 20, 28},
  light: {236, 232, 220},
  dim: {120, 114, 110},
  text: {40, 36, 44},
  yellow: {210, 170, 50},
  orange: {215, 120, 40},
  teal: {70, 200, 190},
  line: {52, 48, 62},
  graph: {110, 230, 130},
  white: {255, 255, 255},
}

// the labels of the fields, short enough for a cell
local labels = {
  on: "ON", mode: "MODE", coarse: "CRS", fine: "FINE", detune: "DET", level: "LVL",
  vel: "VEL", rs: "RS", ams: "AMS", r1: "R1", r2: "R2", r3: "R3", r4: "R4",
  l1: "L1", l2: "L2", l3: "L3", l4: "L4", ["break"]: "BRK", ldepth: "LDEP",
  rdepth: "RDEP", lcurve: "LCRV", rcurve: "RCRV",
  algorithm: "ALG", feedback: "FB", osc_sync: "SYNC", transpose: "TRNS",
  wave: "WAVE", speed: "SPD", delay: "DLY", pmd: "PMD", amd: "AMD",
  lfo_sync: "LSYN", pms: "PMS", pr1: "PR1", pr2: "PR2", pr3: "PR3", pr4: "PR4",
  pl1: "PL1", pl2: "PL2", pl3: "PL3", pl4: "PL4",
}

// the page's layout
local TX = 146           // the operator table
local CW = 20            // a cell
local RH = 12            // a row
local HEAD_Y = 28
local ROW_Y = 36
local EGX = TX + 16 + len(patch.OP_FIELDS) * CW + 2    // the small envelope at a row's end
local VOICE_Y = 116      // the voice's row: labels, values 8 below
local VCW = 24
local EG_Y = 142         // the six envelope graphs
local EG_W = 76
local EG_H = 44
local EG_DX = 82
local DIAG = {x: 6, y: 26, w: 132, h: 100}
local PEG = {x: 6, y: 132, w: 132, h: 54}
local BANK_Y = 208
local BANK_ROWS = 8
local BANK_CW = 158
local BANK_RH = 13

// the cells, once: {x, y, w, h, op (0..5 or null), field}
local cells = {}
for(local k = 0; k < 6; k = k + 1){
  for(local i = 0; i < len(patch.OP_FIELDS); i = i + 1){
    append(cells, {x: TX + 16 + i * CW, y: ROW_Y + k * RH, w: CW - 1, h: RH - 1, op: k, field: patch.OP_FIELDS[i]})
  }
}
for(local i = 0; i < len(patch.VOICE_FIELDS); i = i + 1){
  append(cells, {x: TX + i * VCW, y: VOICE_Y + 8, w: VCW - 1, h: 10, op: null, field: patch.VOICE_FIELDS[i]})
}

local func rect(x, y, w, h, color){
  rl.draw.rectangle(to_int(x), to_int(y), to_int(w), to_int(h), color)
}

local func line(x1, y1, x2, y2, color){
  rl.draw.line(to_int(x1), to_int(y1), to_int(x2), to_int(y2), color)
}

local func inside(x, y, rx, ry, rw, rh){
  return x >= rx and x < rx + rw and y >= ry and y < ry + rh
}

// name(mod) -> the patch's name, starred when edited
func fmui.name(mod){
  if(mod.fm_edited){
    return concat(mod.fm.name, "*")
  }
  return mod.fm.name
}

// ------------------------------------------------------------ the diagram

// boxes(p, x, y, w, h, cw, ch, bw, bh) -> {[op 1..6]: {x, y, w, h}}: where
// each operator's box of bw x bh sits in cells of cw x ch, the layout
// centered in the area; carriers at the bottom
local func boxes(p, x, y, w, h, cw, ch, bw, bh){
  local alg = algorithms.get(p.algorithm)
  local lay = algorithms.layout(alg)
  local rows = 1
  for(local k = 1; k <= 6; k = k + 1){
    if(lay[k].row + 1 > rows){
      rows = lay[k].row + 1
    }
  }
  local ox = x + to_int((w - lay.cols * cw) / 2)
  local oy = y + to_int((h - rows * ch) / 2)
  local out = {}
  for(local k = 1; k <= 6; k = k + 1){
    out[k] = {
      x: ox + lay[k].col * cw + to_int((cw - bw) / 2),
      y: oy + (rows - 1 - lay[k].row) * ch + to_int((ch - bh) / 2),
      w: bw, h: bh,
    }
  }
  return out
}

// draw_algorithm(p, area, cw, ch, bw, bh, scale, hot): the operators as
// numbered boxes (dim when off or silent), a line from a modulator down
// to what it modulates, the feedback loop in teal; hot (1..6) outlined
local func draw_algorithm(p, area, cw, ch, bw, bh, scale, hot){
  local alg = algorithms.get(p.algorithm)
  local b = boxes(p, area.x, area.y, area.w, area.h, cw, ch, bw, bh)
  for(local k = 1; k <= 6; k = k + 1){
    for(let local m in values(alg.mods[k])){
      local from = b[m]
      local to = b[k]
      line(from.x + from.w / 2, from.y + from.h, to.x + to.w / 2, to.y - 1, colors.light)
    }
  }
  // the feedback: a loop on the box's right, or from the source's right
  // up to the target's
  local from = b[alg.fb_from]
  local to = b[alg.fb_to]
  local fx = from.x + from.w + 1
  local out = fx + 2
  if(alg.fb_from != alg.fb_to and to.x + to.w + 3 > out){
    out = to.x + to.w + 3
  }
  if(alg.fb_from == alg.fb_to){
    line(fx, from.y + from.h - 1, out, from.y + from.h - 1, colors.teal)
    line(out, from.y + from.h - 1, out, from.y + 1, colors.teal)
    line(out, from.y + 1, fx, from.y + 1, colors.teal)
  } else {
    line(fx, from.y + from.h / 2, out, from.y + from.h / 2, colors.teal)
    line(out, from.y + from.h / 2, out, to.y + to.h / 2, colors.teal)
    line(out, to.y + to.h / 2, to.x + to.w + 1, to.y + to.h / 2, colors.teal)
  }
  for(local k = 1; k <= 6; k = k + 1){
    local o = p.ops[k - 1]
    local box = b[k]
    local color = colors.orange
    if(o.on == 0 or o.level == 0){
      color = colors.dim
    }
    rect(box.x, box.y, box.w, box.h, color)
    font.center(string(k), box.x + box.w / 2, box.y + to_int((box.h - 5 * scale) / 2), colors.text, scale)
    if(hot == k){
      rl.draw.rectangle_lines(box.x - 1, box.y - 1, box.w + 2, box.h + 2, colors.white)
    }
  }
}

// draw_panel(r, m, grid, hot): the diagram in a module's grid area
func fmui.draw_panel(r, m, grid, hot){
  rect(grid.x, grid.y, grid.w, grid.h, colors.cell)
  draw_algorithm(r.modules[m].fm, grid, 14, 11, 9, 7, 1, hot)
}

// ------------------------------------------------------------ envelopes

// an envelope as a line in a box: from start through l1, l2, l3, a hold,
// and l4; each segment's time compressed (a logarithm) so slow ones fit
local func draw_eg(rates, levels, x, y, w, h, start, color){
  local points = {}
  local lv = start
  local t = 0.0
  append(points, {t, lv})
  for(local s = 0; s < 4; s = s + 1){
    if(s == 3){
      t = t + 0.8
      append(points, {t, lv})
    }
    local target = levels[s]
    local seconds = math.abs(target - lv) / patch.speed(rates[s])
    t = t + math.log2(1 + seconds * 8) + 0.05
    lv = target
    append(points, {t, lv})
  }
  local sx = (w - 2) / t
  for(local i = 1; i < len(points); i = i + 1){
    local a = points[i - 1]
    local b = points[i]
    line(x + 1 + a[0] * sx, y + h - 2 - a[1] / 99 * (h - 4), x + 1 + b[0] * sx, y + h - 2 - b[1] / 99 * (h - 4), color)
  }
}

local func op_eg(o, x, y, w, h, color){
  draw_eg({o.r1, o.r2, o.r3, o.r4}, {o.l1, o.l2, o.l3, o.l4}, x, y, w, h, 0, color)
}

// ------------------------------------------------------------ the page

local func cell_text(c, v){
  return patch.field_text(c.field, v)
}

local func draw_cell(r, m, c, state){
  local v = r:fm_get(m, c.op, c.field.id)
  local bg = colors.cell
  local hover = state.hover
  local drag = state.drag
  if(drag != null and drag.kind == "fmcell" and drag.cell == c){
    bg = colors.cell_drag
  } else if(hover != null and hover.kind == "cell" and hover.cell == c){
    bg = colors.cell_hot
  }
  rect(c.x, c.y, c.w, c.h, bg)
  local color = colors.light
  if(c.op != null){
    local o = r.modules[m].fm.ops[c.op]
    if(o.on == 0){
      color = colors.dim
    }
  }
  if(c.field.kind == "bool" or c.field.kind == "enum"){
    color = colors.yellow
    if(c.op != null and r.modules[m].fm.ops[c.op].on == 0){
      color = colors.dim
    }
  }
  font.center(cell_text(c, v), c.x + c.w / 2 + 0.5, c.y + to_int((c.h - 5) / 2), color)
}

// draw(r, m, state): the editor page for module m, between the top bar and
// the status line; state.hover is what fmui.hit returned, state.drag the
// drag in progress
func fmui.draw(r, m, state){
  local mod = r.modules[m]
  local p = mod.fm
  local hover = state.hover
  rect(0, 12, VW, BOTTOM - 12, colors.bg)
  // the title
  font.text(concat("FM  SLOT ", m, "  PRESET ", to_int(mod.params[0]) + 1, ":"), 6, 16, colors.dim)
  font.text(fmui.name(mod), 102, 16, colors.yellow)
  font.right("E OR ESC CLOSES  (THE KEYS STILL PLAY)", VW - 6, 16, colors.dim)
  // the diagram
  rect(DIAG.x, DIAG.y, DIAG.w, DIAG.h, colors.panel)
  font.text(concat("ALGORITHM ", p.algorithm), DIAG.x + 3, DIAG.y + 3, colors.dim)
  local hot = null
  if(hover != null and hover.kind == "op"){
    hot = hover.k + 1
  }
  draw_algorithm(p, {x: DIAG.x, y: DIAG.y + 10, w: DIAG.w, h: DIAG.h - 12}, 22, 18, 14, 12, 2, hot)
  // the pitch envelope
  rect(PEG.x, PEG.y, PEG.w, PEG.h, colors.panel)
  font.text("PITCH EG", PEG.x + 3, PEG.y + 3, colors.dim)
  local mid = PEG.y + 10 + (PEG.h - 12) / 2
  rect(PEG.x + 1, mid, PEG.w - 2, 1, colors.line)
  draw_eg({p.pr1, p.pr2, p.pr3, p.pr4}, {p.pl1, p.pl2, p.pl3, p.pl4}, PEG.x, PEG.y + 10, PEG.w, PEG.h - 12, p.pl4, colors.teal)
  // the operator table
  for(local i = 0; i < len(patch.OP_FIELDS); i = i + 1){
    font.center(labels[patch.OP_FIELDS[i].id], TX + 16 + i * CW + CW / 2, HEAD_Y, colors.dim)
  }
  for(local k = 0; k < 6; k = k + 1){
    local o = p.ops[k]
    local y = ROW_Y + k * RH
    local color = colors.orange
    if(o.on == 0){
      color = colors.dim
    }
    font.text(concat("OP", k + 1), TX, y + 3, color)
    rect(EGX, y, VW - 4 - EGX, RH - 1, colors.panel)
    op_eg(o, EGX, y, VW - 4 - EGX, RH - 1, color)
  }
  for(local i = 0; i < len(patch.VOICE_FIELDS); i = i + 1){
    font.center(labels[patch.VOICE_FIELDS[i].id], TX + i * VCW + VCW / 2, VOICE_Y, colors.dim)
  }
  for(let local c in values(cells)){
    draw_cell(r, m, c, state)
  }
  // the envelopes
  for(local k = 0; k < 6; k = k + 1){
    local o = p.ops[k]
    local x = TX + k * EG_DX
    rect(x, EG_Y, EG_W, EG_H, colors.panel)
    local color = colors.graph
    if(o.on == 0 or o.level == 0){
      color = colors.dim
    }
    font.text(concat("OP", k + 1, " ENV"), x + 3, EG_Y + 3, colors.dim)
    op_eg(o, x, EG_Y + 9, EG_W, EG_H - 10, color)
  }
  // the bank
  font.text("PRESETS  (CLICK ONE: ITS SOUND, THE EDITS UNDONE)", 6, BANK_Y - 10, colors.dim)
  local chosen = to_int(mod.params[0])
  for(local i = 0; i < len(rack.bank); i = i + 1){
    local x = 6 + to_int(i / BANK_ROWS) * BANK_CW
    local y = BANK_Y + (i % BANK_ROWS) * BANK_RH
    local bg = colors.panel
    if(hover != null and hover.kind == "bank" and hover.i == i){
      bg = colors.cell_hot
    }
    rect(x, y, BANK_CW - 2, BANK_RH - 1, bg)
    local color = colors.light
    if(i == chosen){
      rect(x, y, 3, BANK_RH - 1, colors.orange)
      color = colors.yellow
    }
    local n = string(i + 1)
    if(i < 9){
      n = concat("0", n)
    }
    font.text(concat(n, " ", rack.bank[i].name), x + 6, y + 4, color)
  }
  font.text("DRAG A VALUE UP OR DOWN (SHIFT: ONE STEP) OR WHEEL OVER IT.  CLICK A SWITCH.  DOUBLE CLICK: THE PRESET'S VALUE.  CLICK AN OPERATOR IN THE DIAGRAM TO MUTE IT.", 6, BOTTOM - 10, colors.dim)
}

// ------------------------------------------------------------ hit tests

// hit(r, m, x, y) -> {kind: "cell", cell}, {kind: "bank", i},
// {kind: "op", k (0..5)}, or null
func fmui.hit(r, m, x, y){
  for(let local c in values(cells)){
    if(inside(x, y, c.x, c.y, c.w, c.h)){
      return {kind: "cell", cell: c}
    }
  }
  for(local i = 0; i < len(rack.bank); i = i + 1){
    local bx = 6 + to_int(i / BANK_ROWS) * BANK_CW
    local by = BANK_Y + (i % BANK_ROWS) * BANK_RH
    if(inside(x, y, bx, by, BANK_CW - 2, BANK_RH - 1)){
      return {kind: "bank", i: i}
    }
  }
  local b = boxes(r.modules[m].fm, DIAG.x, DIAG.y + 10, DIAG.w, DIAG.h - 12, 22, 18, 14, 12)
  for(local k = 1; k <= 6; k = k + 1){
    if(inside(x, y, b[k].x - 2, b[k].y - 2, b[k].w + 4, b[k].h + 4)){
      return {kind: "op", k: k - 1}
    }
  }
  return null
}

// tip(r, m, hover) -> the status line
func fmui.tip(r, m, hover){
  if(hover == null){
    return "FM EDITOR: EVERY VALUE OF THE PATCH; E OR ESC CLOSES"
  }
  if(hover.kind == "cell"){
    local c = hover.cell
    local where = "VOICE"
    if(c.op != null){
      where = concat("OP", c.op + 1)
    }
    local v = r:fm_get(m, c.op, c.field.id)
    local how = "(DRAG, WHEEL, DOUBLE CLICK: THE PRESET'S)"
    if(c.field.kind == "bool" or c.field.kind == "enum"){
      how = "(CLICK, WHEEL)"
    }
    return concat(where, " ", c.field.label, ": ", cell_text(c, v), "  ", how)
  }
  if(hover.kind == "bank"){
    return concat("PRESET ", hover.i + 1, ": ", rack.bank[hover.i].name, "  (CLICK TO LOAD IT)")
  }
  local o = r.modules[m].fm.ops[hover.k]
  local state = "ON"
  if(o.on == 0){
    state = "OFF"
  }
  return concat("OPERATOR ", hover.k + 1, " ", state, "  (CLICK TO MUTE OR UNMUTE IT)")
}

return fmui
