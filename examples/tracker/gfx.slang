// Drawing in character cells: raylib's own pixel font, each glyph centered
// in a cell of 8 by 12, and the few shapes the tracker is made of.
//
//   gfx.text("C-4", x, y, gfx.colors.note)
//   gfx.right("120", x, y, color)            // ending at x
//   gfx.bar(x, y, w, h, 0.7, color, back)    // a meter or a slider
local rl = require("raylib")
local str = require("slang/string")

local gfx = {}

gfx.CW = 8 // a character cell
gfx.CH = 12
gfx.FONT_SIZE = 10

gfx.colors = {
  back: {13, 15, 22},
  panel: {19, 22, 32},
  line: {36, 41, 58},
  beat: {21, 25, 37},
  bar: {28, 33, 49},
  cursor: {255, 220, 120},
  cursor_row: {34, 40, 60},
  select: {52, 72, 120},
  play: {44, 90, 70},
  text: {214, 220, 235},
  dim: {110, 120, 145},
  faint: {58, 65, 88},
  note: {238, 240, 248},
  off: {150, 110, 120},
  vel: {110, 190, 190},
  fx: {240, 170, 90},
  good: {130, 220, 130},
  warn: {250, 200, 90},
  bad: {250, 110, 100},
  title: {255, 255, 255},
}

// a color for each track, by its index
local hues = {
  {250, 120, 110},
  {250, 180, 90},
  {240, 225, 110},
  {140, 220, 120},
  {100, 210, 200},
  {110, 170, 250},
  {170, 140, 250},
  {240, 140, 220},
}
func gfx.hue(i){
  return hues[i % len(hues)]
}

// shade(color, k) -> the color times k (0..1), for backgrounds
func gfx.shade(c, k){
  return {to_int(c[0] * k), to_int(c[1] * k), to_int(c[2] * k)}
}

local font = null
local offsets = {}

local func load_font(){
  font = rl.font.default
  for(local c = 32; c < 127; c = c + 1){
    local rec = font:glyph_atlas_rec(c)
    offsets[c] = to_int((gfx.CW - rec.width) / 2)
  }
}

// text(s, x, y, color): a line of text, a cell per byte
func gfx.text(s, x, y, color){
  if(font == null){
    load_font()
  }
  for(local i = 0; i < len(s); i = i + 1){
    local c = str.byte_at(s, i)
    if(c > 32 and c < 127){
      font:draw_text_codepoint(
        c, {x + i * gfx.CW + (offsets[c] or 0), y + 1}, gfx.FONT_SIZE, color
      )
    }
  }
}

// right(s, x, y, color): text that ends at x
func gfx.right(s, x, y, color){
  gfx.text(s, x - len(s) * gfx.CW, y, color)
}

// fit(s, n) -> s cut to n characters
func gfx.fit(s, n){
  if(len(s) > n){
    return str.substring(s, 0, n)
  }
  return s
}

func gfx.rect(x, y, w, h, color){
  rl.draw.rectangle(x, y, w, h, color)
}

// bar(x, y, w, h, t, color, back): a bar filled from the left to t (0..1)
func gfx.bar(x, y, w, h, t, color, back){
  rl.draw.rectangle(x, y, w, h, back)
  if(t > 0){
    if(t > 1){
      t = 1
    }
    rl.draw.rectangle(x, y, to_int(w * t + 0.5), h, color)
  }
}

// center(x, y, w, h, t, color, back): a bar from its middle to t (-1..1)
func gfx.center(x, y, w, h, t, color, back){
  rl.draw.rectangle(x, y, w, h, back)
  local mid = x + to_int(w / 2)
  if(t >= 0){
    rl.draw.rectangle(mid, y, to_int(w / 2 * t + 0.5), h, color)
  } else {
    local n = to_int(w / 2 * -t + 0.5)
    rl.draw.rectangle(mid - n, y, n, h, color)
  }
  rl.draw.rectangle(mid, y - 1, 1, h + 2, color)
}

// inside(mx, my, x, y, w, h) -> whether the point is in the rectangle
func gfx.inside(mx, my, x, y, w, h){
  return mx >= x and mx < x + w and my >= y and my < y + h
}

return gfx
