// The sprite DSL: pixel art written as ASCII, baked into RGBA bytes while
// the file is compiled. No image files are needed.
//
//   palette main {                      // a named palette (compile time only)
//     g: "#3a7d44", k: "#1b1b1b",
//   }
//   sprite goblin main {                // sprite NAME [PALETTE] { rows }
//     ..gg..
//     .gkkg.
//   }
//
// `.` is transparent. Every row must have the same width and every other
// character must be in the palette; violations are reported as compile errors
// on the offending row. A sprite expands to
//   require("engine/sprites").define("goblin", {w: 6, h: 2, pixels: "<bytes>"})
// and is drawn with gfx.sprite(sprites.goblin, x, y).
local p = require("slang/parser")
local str = require("slang/string")
local util = require("dsl/util")

local palettes = {}
local m = {palettes: palettes}

// palette NAME { key: "#hex", ... }
p.add_extension_statement("palette",
  p.seq(p.keyword("palette"), p.identifier(), p.table_literal()),
  func(r){
    local token = r[0]
    local name = r[1].value
    local colors = {}
    for(let local field in values(r[2].fields)){
      if(field.key == null or field.key.type != "String" or field.value.type != "String"){
        p.error_at(token, "palette ", name, ": entries must look like  k: \"#rrggbb\"")
      }
      local key = field.key.value
      if(len(key) != 1){
        p.error_at(token, "palette ", name, ": the key \"", key, "\" must be a single character")
      }
      local color = util.hex_color(field.value.value)
      if(color == null){
        p.error_at(token, "palette ", name, ": \"", field.value.value, "\" is not a color (#rrggbb or #rrggbbaa)")
      }
      colors[key] = color
    }
    palettes[name] = colors
    return null
  }
)

// bake(rows, palette, where) -> {w, h, pixels}; where reports errors
func m.bake(rows, palette, fail){
  local h = len(rows.rows)
  if(h == 0){
    fail(0, "a sprite needs at least one row")
  }
  local w = len(rows.rows[0])
  local bytes = {}
  for(local y = 0; y < h; y = y + 1){
    local row = rows.rows[y]
    if(len(row) != w){
      fail(y, "row ", y + 1, " is ", len(row), " characters wide, the first row is ", w)
    }
    for(local x = 0; x < w; x = x + 1){
      local ch = str.char_at(row, x)
      if(ch == "."){
        append(bytes, 0) append(bytes, 0) append(bytes, 0) append(bytes, 0)
      } else {
        local c = palette[ch]
        if(c == null){
          fail(y, "row ", y + 1, " column ", x + 1, ": \"", ch, "\" is not in the palette")
        }
        append(bytes, c.r) append(bytes, c.g) append(bytes, c.b) append(bytes, c.a)
      }
    }
  }
  return {w: w, h: h, pixels: str.from_bytes(bytes)}
}

// sprite NAME [PALETTE] { rows }
p.add_extension_statement("sprite",
  p.seq(p.keyword("sprite"), p.identifier(), p.identifier():optional(), util.raw_block()),
  func(r){
    local token = r[0]
    local name = r[1].value
    local palette_name = "default"
    if(r[2] != null){
      palette_name = r[2].value
    }
    local palette = palettes[palette_name]
    if(palette == null){
      p.error_at(token, "sprite ", name, ": unknown palette \"", palette_name, "\"")
    }
    local rows = util.rows(r[3])
    local baked = m.bake(rows, palette, func(row, ...message){
      util.error_at_row(rows, row, concat("sprite ", name, ": ", util.text(message)))
    })
    return {
      token: token,
      ast: util.define("engine/sprites", name, util.table_node({
        name: util.string_node(name),
        w: util.int_node(baked.w),
        h: util.int_node(baked.h),
        pixels: util.string_node(baked.pixels),
      })),
    }
  }
)

return m
