// render/ui: the look of everything flat on the screen (the HUD and the
// menus): the palette, the fonts, text in the three ways the game sets
// it (plain, tracked capitals for labels, figures in fixed columns), and
// the few shapes it is built from: dark panels with a thin edge,
// indicator pills, key caps, bars.
//
//   ui.init()                       // the fonts (assets/Fredoka.ttf)
//   ui.begin()                      // each frame, before anything is drawn
//   ui.text(x, y, "Lakeside", 18, ui.colors.paper)
//   ui.label(x, y, "next checkpoint", 11, ui.colors.dim)
//   ui.figures(x, y, "12:34.5", 34, ui.colors.paper)
//
// Everything is laid out in the window's own coordinates (1280 by 720 at
// its first size; raylib draws them onto however many pixels the screen
// has), from the window's size now: ui.w, ui.h, and ui.s, the size of
// things relative to a window 720 high. The font is kept at three sizes
// and each text drawn from the one nearest above the pixels it takes, so
// that small labels and large figures are both sharp.
local rl = require("raylib")
local os = require("slang/os")
local math = require("slang/math")
local str = require("slang/string")
local path_lib = require("slang/path")

local m = {}

// The palette: warm paper and amber on dark, see-through ink.
m.colors = {
  ink: {16, 18, 20, 204},          // the panels
  ink_solid: {20, 22, 24, 255},
  edge: {240, 232, 214, 56},       // a panel's thin edge
  paper: {242, 234, 216, 255},     // text and strokes
  dim: {242, 234, 216, 150},       // secondary text
  faint: {242, 234, 216, 70},      // what is switched off
  off: {242, 234, 216, 104},       // a lamp's word when it is off
  amber: {240, 170, 62, 255},      // the accent: what is on, where to go
  red: {222, 82, 60, 255},         // the redline, a warning, time lost
  green: {136, 196, 112, 255},     // time gained
  shadow: {0, 0, 0, 120},
}

m.w = 1280
m.h = 720
m.s = 1
// how many pixels of the screen a unit of the window is (2 on a screen
// with twice the pixels)
m.dpi = 1
// the mouse and whether its button went down this frame
m.mouse = {x: 0, y: 0}
m.click = false

// the font at its sizes, the smallest first: {size, font, held}
// [held]: the texts kept back for it, see [hold]
local FONT_SIZES = {28, 56, 132}
local fonts = {}
// whether texts are kept back
local holding = false
// What is worked out once and kept while the window keeps its scale: the
// font each size of text is drawn from, the widths of texts, the
// characters of figures. (Sizes are keys as whole sixteenths.)
local kept = {scale: 0, fonts: {}, widths: {}, count: 0, figures: {}}
// the capitals of labels
local capitals = {}

local func forget(){
  kept.fonts = {}
  kept.widths = {}
  kept.count = 0
  kept.figures = {}
}

// with_alpha(color, k) -> the color with its alpha times k (0..1)
func m.with_alpha(color, k){
  if(k < 0){
    k = 0
  } else if(k > 1){
    k = 1
  }
  return {color[0], color[1], color[2], to_int((color[3] or 255) * k)}
}

// mix(a, b, t) -> the color t of the way from a to b
func m.mix(a, b, t){
  if(t < 0){
    t = 0
  } else if(t > 1){
    t = 1
  }
  return {
    to_int(a[0] + (b[0] - a[0]) * t), to_int(a[1] + (b[1] - a[1]) * t),
    to_int(a[2] + (b[2] - a[2]) * t), to_int((a[3] or 255) + ((b[3] or 255) - (a[3] or 255)) * t),
  }
}

// where the game's files are: the directory above this module's
local func home(){
  local source = __PACKAGES.find_source("render/ui")
  if(source == null){
    return "."
  }
  return path_lib.dir(path_lib.dir(source.path))
}

// init(): the fonts: the same face at three sizes, each with smaller
// copies of itself for when it is drawn small. Without the font's file
// raylib's own font is used.
func m.init(){
  if(len(fonts) > 0){
    return
  }
  local file = concat(home(), "/assets/Fredoka.ttf")
  if(not os.exists(file)){
    return
  }
  // the letters, figures and signs of ASCII, and a few more
  local points = {}
  for(local c = 32; c < 127; c = c + 1){
    append(points, c)
  }
  for(let local c in values({176, 177, 183, 215, 8211, 8212, 8226})){
    append(points, c)
  }
  for(let local size in values(FONT_SIZES)){
    local font = rl.font.load_ex(file, size, points)
    local texture = font.texture
    texture:gen_mipmaps()
    texture.filter = rl.TEXTURE_FILTER_TRILINEAR
    append(fonts, {size: size, font: font, held: {}})
  }
}

// unload(): the fonts given back
func m.unload(){
  for(let local entry in values(fonts)){
    entry.font:unload()
  }
  fonts = {}
  holding = false
  forget()
}

// begin(): the window's size and the mouse, once a frame before anything
// is laid out
func m.begin(){
  local size = rl.window.size
  m.w = size.x
  m.h = size.y
  m.s = math.min(size.x / 1280, size.y / 720)
  m.dpi = math.max(1, rl.window.render_width / math.max(1, size.x))
  // (texts are measured in the font they are drawn from, which goes by
  // the scale)
  if(m.s * m.dpi != kept.scale){
    kept.scale = m.s * m.dpi
    forget()
  }
  m.mouse = rl.mouse.position
  m.click = rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)
}

// inside(x, y, w, h) -> whether the mouse is over a rectangle
func m.inside(x, y, w, h){
  local p = m.mouse
  return p.x >= x and p.x <= x + w and p.y >= y and p.y <= y + h
}

// ------------------------------------------------------------ text

// the font for a size ({size, font, held}): the smallest that has the
// pixels the text takes on the screen (or nearly), null when there is
// none
local func font_for(size){
  local key = to_int(size * 16)
  local entry = kept.fonts[key]
  if(entry == null){
    local px = size * m.s * m.dpi
    for(let local e in values(fonts)){
      entry = e
      if(e.size * 1.12 >= px){
        break
      }
    }
    kept.fonts[key] = entry
  }
  return entry
}

// a text put on the screen, or kept back for [release]
local func put(entry, text, x, y, px, spacing, color){
  if(entry == null){
    rl.draw.text(text, to_int(x), to_int(y), to_int(px), color)
  } else if(holding){
    append(entry.held, {text, {x, y}, px, spacing, color})
  } else {
    rl.draw.text_ex(entry.font, text, {x, y}, px, spacing, color)
  }
}

// hold(): from here on text is not drawn where it is asked for but kept
// back, until [release] draws it, font by font. The graphics card then
// gets the shapes together and the text together, which is much less
// work for it than text and shapes in turns. (All text then lies over
// all shapes: only for a picture where it does anyway, as the HUD.)
func m.hold(){
  holding = true
  for(let local entry in values(fonts)){
    entry.held = {}
  }
}

// release(): the texts kept back since [hold] drawn
func m.release(){
  holding = false
  for(let local entry in values(fonts)){
    local font = entry.font
    for(let local t in values(entry.held)){
      rl.draw.text_ex(font, t[0], t[1], t[2], t[3], t[4])
    }
    entry.held = {}
  }
}

// measure(text, size, spacing?) -> its width (sizes are for a window 720
// high; kept, so asking again costs nothing)
func m.measure(text, size, spacing){
  spacing = spacing or 0.02
  local key = to_int(size * 16) * 1024 + to_int(spacing * 1000 + 0.5)
  local set = kept.widths[key]
  if(set == null){
    set = {}
    kept.widths[key] = set
  }
  local w = set[text]
  if(w == null){
    local entry = font_for(size)
    if(entry != null){
      w = rl.text.measure_ex(entry.font, text, size, size * spacing).x * m.s
    } else {
      w = rl.text.measure(text, to_int(size)) * m.s
    }
    // (not kept without end: texts with numbers in them are many)
    if(kept.count > 3000){
      kept.widths = {}
      kept.count = 0
      set = {}
      kept.widths[key] = set
    }
    set[text] = w
    kept.count = kept.count + 1
  }
  return w
}

// text(x, y, text, size, color?, spacing?): at its left top
func m.text(x, y, text, size, color, spacing){
  local px = size * m.s
  put(font_for(size), text, x, y, px, px * (spacing or 0.02), color or m.colors.paper)
}

// text_center(cx, y, text, size, color?, spacing?), text_right(right, ...)
func m.text_center(cx, y, text, size, color, spacing){
  m.text(cx - m.measure(text, size, spacing) / 2, y, text, size, color, spacing)
}

func m.text_right(right, y, text, size, color, spacing){
  m.text(right - m.measure(text, size, spacing), y, text, size, color, spacing)
}

// label(x, y, text, size, color?, align?): capitals set wide apart, for
// the names of things; align -1 (from x on, the default), 0 (around x),
// 1 (up to x)
func m.label(x, y, text, size, color, align){
  local upper = capitals[text]
  if(upper == null){
    upper = str.upper(text)
    capitals[text] = upper
  }
  if(align == 0){
    x = x - m.measure(upper, size, 0.14) / 2
  } else if(align == 1){
    x = x - m.measure(upper, size, 0.14)
  }
  m.text(x, y, upper, size, color or m.colors.dim, 0.14)
}

// how wide a character is set among figures, in columns: a figure has a
// whole one, a sign most of one, a point or a colon less than half
local func columns(c){
  if(c >= '0' and c <= '9'){
    return 1
  }
  if(c == '+' or c == '-'){
    return 0.74
  }
  if(c == ' '){
    return 0.5
  }
  if(c == ':' or c == '.' or c == '/'){
    return 0.42
  }
  return 0.8
}

// a character of figures at a size: {text, w, pad}: itself as a string
// (null for a space), the width it is given, and how far into that width
// it is drawn
local func figure(size, c){
  local key = to_int(size * 16)
  local set = kept.figures[key]
  if(set == null){
    set = {}
    kept.figures[key] = set
  }
  local glyph = set[c]
  if(glyph == null){
    local w = m.measure("0", size) * columns(c)
    glyph = {text: null, w: w, pad: 0}
    if(c != ' '){
      glyph.text = str.from_bytes({c})
      glyph.pad = (w - m.measure(glyph.text, size)) / 2
    }
    set[c] = glyph
  }
  return glyph
}

// figures_width(text, size) -> how wide [figures] sets a text
func m.figures_width(text, size){
  local w = 0
  for(local i = 0; i < len(text); i = i + 1){
    w = w + figure(size, str.byte_at(text, i)).w
  }
  return w
}

// figures(x, y, text, size, color?, align?): numbers with every figure in
// a column of the same width, so that a running clock does not shiver;
// align as for [label]
func m.figures(x, y, text, size, color, align){
  if(align == 0){
    x = x - m.figures_width(text, size) / 2
  } else if(align == 1){
    x = x - m.figures_width(text, size)
  }
  color = color or m.colors.paper
  local entry = font_for(size)
  local px = size * m.s
  for(local i = 0; i < len(text); i = i + 1){
    local glyph = figure(size, str.byte_at(text, i))
    if(glyph.text != null){
      put(entry, glyph.text, x + glyph.pad, y, px, px * 0.02, color)
    }
    x = x + glyph.w
  }
}

// clock(seconds, tenths?) -> "m:ss.t" (or "m:ss")
func m.clock(seconds, tenths){
  if(seconds == null){
    return "-:--"
  }
  local sign = ""
  if(seconds < 0){
    sign = "-"
    seconds = -seconds
  }
  local whole = to_int(seconds * 10 + 0.0001)
  local minutes = to_int(whole / 600)
  local rest = whole - minutes * 600
  local secs = to_int(rest / 10)
  local out = concat(sign, string(minutes), ":", if(secs < 10){ "0" } else { "" }, string(secs))
  if(tenths != false){
    out = concat(out, ".", string(rest - secs * 10))
  }
  return out
}

// delta(seconds) -> "+0:03.2" or "-0:03.2"
func m.delta(seconds){
  if(seconds >= 0){
    return concat("+", m.clock(seconds))
  }
  return m.clock(seconds)
}

// ------------------------------------------------------------ shapes

// panel(x, y, w, h, color?): a dark see-through plate with a thin edge
func m.panel(x, y, w, h, color){
  local round = math.min(1, 16 * m.s / math.min(w, h))
  rl.draw.rectangle_rounded({x, y, w, h}, round, 8, color or m.colors.ink)
  rl.draw.rectangle_rounded_lines_ex({x, y, w, h}, round, 8, 1, m.colors.edge)
}

// disc(cx, cy, r, color?): the same, round
func m.disc(cx, cy, r, color){
  rl.draw.circle_v({cx, cy}, r, color or m.colors.ink)
  rl.draw.ring({cx, cy}, r - 0.5, r + 0.5, 0, 360, 48, m.colors.edge)
}

// pill(x, y, w, h, text, on, color?): a small lamp with a word: lit (in
// color, amber by default) when on, an outline when off
func m.pill(x, y, w, h, text, on, color){
  local size = h / m.s * 0.56
  if(on){
    rl.draw.rectangle_rounded({x, y, w, h}, 0.5, 6, color or m.colors.amber)
    m.label(x + w / 2, y + (h - size * m.s) / 2, text, size, m.colors.ink_solid, 0)
  } else {
    rl.draw.rectangle_rounded_lines_ex({x, y, w, h}, 0.5, 6, 1, m.colors.faint)
    m.label(x + w / 2, y + (h - size * m.s) / 2, text, size, m.colors.off, 0)
  }
}

// the arrow keys, drawn (the font has no arrows): which way each points
local arrows = {up: {0, -1}, down: {0, 1}, left: {-1, 0}, right: {1, 0}}

// key_cap(x, y, text, size?) -> its width: a key of the keyboard (or a
// button of the gamepad) with its name on it; "up", "down", "left" and
// "right" are the arrow keys
func m.key_cap(x, y, text, size){
  size = size or 13
  local h = size * 1.7 * m.s
  local arrow = arrows[text]
  local w = h
  if(arrow == null){
    w = math.max(h, m.measure(text, size) + size * 0.9 * m.s)
  }
  rl.draw.rectangle_rounded({x, y, w, h}, 0.32, 6, {242, 234, 216, 28})
  rl.draw.rectangle_rounded_lines_ex({x, y, w, h}, 0.32, 6, 1, m.colors.dim)
  if(arrow != null){
    // a small triangle pointing the key's way (counter clockwise on the
    // screen, as raylib wants it)
    local cx = x + w / 2
    local cy = y + h / 2
    local r = h * 0.24
    local dx = arrow[0]
    local dy = arrow[1]
    local tip = {cx + dx * r, cy + dy * r}
    local a = {cx - dx * r - dy * r, cy - dy * r + dx * r}
    local b = {cx - dx * r + dy * r, cy - dy * r - dx * r}
    rl.draw.triangle(tip, b, a, m.colors.paper)
    rl.draw.triangle(tip, a, b, m.colors.paper)
  } else {
    m.text(x + (w - m.measure(text, size)) / 2, y + (h - size * m.s) / 2 - 0.5 * m.s, text, size, m.colors.paper)
  }
  return w
}

// bar(x, y, w, h, share, color, back?): a bar filled from the left by a
// share of 0..1
func m.bar(x, y, w, h, share, color, back){
  rl.draw.rectangle_rec({x, y, w, h}, back or {242, 234, 216, 40})
  if(share > 0){
    rl.draw.rectangle_rec({x, y, w * math.min(share, 1), h}, color)
  }
}

// band(cx, y, w, h, alpha): a dark band that fades out to the left and to
// the right, behind words that stand straight on the scene
func m.band(cx, y, w, h, alpha){
  local dark = {12, 14, 16, to_int(alpha)}
  local none = {12, 14, 16, 0}
  local half = to_int(w / 2)
  rl.draw.rectangle_gradient_h(to_int(cx) - half, to_int(y), half, to_int(h), none, dark)
  rl.draw.rectangle_gradient_h(to_int(cx), to_int(y), half, to_int(h), dark, none)
}

return m
