// What both panels draw with: a TrueType font (sharper when the 3D face is
// a scaled texture), text, and an envelope as a line.
local rl = require("raylib")
local os = require("slang/os")
local math = require("slang/math")
local patch = require("patch")

local gfx = {}

local font_files = {
  "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf",
  "/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed-Bold.ttf",
  "/usr/share/fonts/TTF/DejaVuSansCondensed-Bold.ttf",
}
local font = null

// load_font(): after init_window (raylib's own font when none is found)
func gfx.load_font(){
  for(let local f in values(font_files)){
    if(font == null and os.exists(f)){
      font = rl.load_font_ex(f, 48, null)
      rl.gen_texture_mipmaps(font.texture)
      rl.set_texture_filter(font.texture, rl.TEXTURE_FILTER_TRILINEAR)
    }
  }
}

func gfx.unload_font(){
  if(font != null){
    rl.unload_font(font)
    font = null
  }
}

func gfx.measure(s, size){
  if(font == null){
    return rl.measure_text(s, size)
  }
  return rl.measure_text_ex(font, s, size * 1.3, 0.6).x
}

func gfx.text(s, x, y, size, color){
  if(font == null){
    rl.draw_text(s, to_int(x), to_int(y), size, color)
  } else {
    rl.draw_text_ex(font, s, {x: x, y: y - size * 0.1}, size * 1.3, 0.6, color)
  }
}

func gfx.text_center(s, x, y, size, color){
  gfx.text(s, x - gfx.measure(s, size) / 2, y, size, color)
}

// two(n) -> "07"
func gfx.two(n){
  if(n < 10){
    return concat("0", string(n))
  }
  return string(n)
}

// draw_eg(rates, levels, x, y, w, h, start, color, thick?): an envelope as
// a line: from start through l1, l2, l3, a hold, and l4; each segment's
// time compressed (a logarithm) so that slow ones fit
func gfx.draw_eg(rates, levels, x, y, w, h, start, color, thick){
  local points = {}
  local lv = start
  local t = 0.0
  append(points, {t, lv})
  for(local s = 0; s < 4; s = s + 1){
    if(s == 3){
      // the key is held
      t = t + 0.8
      append(points, {t, lv})
    }
    local target = levels[s]
    local seconds = math.abs(target - lv) / patch.speed(rates[s])
    t = t + math.log2(1 + seconds * 8) + 0.05
    lv = target
    append(points, {t, lv})
  }
  local scale = (w - 2) / t
  for(local i = 1; i < len(points); i = i + 1){
    local a = points[i - 1]
    local b = points[i]
    rl.draw_line_ex(
      {x: x + 1 + a[0] * scale, y: y + h - 2 - a[1] / 99 * (h - 4)},
      {x: x + 1 + b[0] * scale, y: y + h - 2 - b[1] / 99 * (h - 4)},
      thick or 1.5, color)
  }
}

return gfx
