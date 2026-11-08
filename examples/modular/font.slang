// A 3x5 pixel font, drawn from a texture built at start: capitals, digits
// and the signs the panels need. Lowercase letters draw as capitals.
//
//   font.load()                       // after init_window
//   font.text("VCO", x, y, color)     // 4 px per character
//   font.text("BIG", x, y, color, 2)  // twice the size
//   font.width("VCO")                 // 11
local rl = require("raylib")
local str = require("slang/string")

local font = {}

// each glyph: 5 rows of 3, # for a pixel
local glyphs = {
  {"A", ".#.", "#.#", "###", "#.#", "#.#"},
  {"B", "##.", "#.#", "##.", "#.#", "##."},
  {"C", ".##", "#..", "#..", "#..", ".##"},
  {"D", "##.", "#.#", "#.#", "#.#", "##."},
  {"E", "###", "#..", "##.", "#..", "###"},
  {"F", "###", "#..", "##.", "#..", "#.."},
  {"G", ".##", "#..", "#.#", "#.#", ".##"},
  {"H", "#.#", "#.#", "###", "#.#", "#.#"},
  {"I", "###", ".#.", ".#.", ".#.", "###"},
  {"J", "..#", "..#", "..#", "#.#", ".#."},
  {"K", "#.#", "#.#", "##.", "#.#", "#.#"},
  {"L", "#..", "#..", "#..", "#..", "###"},
  {"M", "#.#", "###", "###", "#.#", "#.#"},
  {"N", "##.", "#.#", "#.#", "#.#", "#.#"},
  {"O", ".#.", "#.#", "#.#", "#.#", ".#."},
  {"P", "##.", "#.#", "##.", "#..", "#.."},
  {"Q", ".#.", "#.#", "#.#", ".#.", "..#"},
  {"R", "##.", "#.#", "##.", "#.#", "#.#"},
  {"S", ".##", "#..", ".#.", "..#", "##."},
  {"T", "###", ".#.", ".#.", ".#.", ".#."},
  {"U", "#.#", "#.#", "#.#", "#.#", "###"},
  {"V", "#.#", "#.#", "#.#", "#.#", ".#."},
  {"W", "#.#", "#.#", "###", "###", "#.#"},
  {"X", "#.#", "#.#", ".#.", "#.#", "#.#"},
  {"Y", "#.#", "#.#", ".#.", ".#.", ".#."},
  {"Z", "###", "..#", ".#.", "#..", "###"},
  {"0", "###", "#.#", "#.#", "#.#", "###"},
  {"1", ".#.", "##.", ".#.", ".#.", "###"},
  {"2", "##.", "..#", ".#.", "#..", "###"},
  {"3", "###", "..#", ".##", "..#", "###"},
  {"4", "#.#", "#.#", "###", "..#", "..#"},
  {"5", "###", "#..", "##.", "..#", "##."},
  {"6", ".##", "#..", "###", "#.#", "###"},
  {"7", "###", "..#", ".#.", ".#.", ".#."},
  {"8", "###", "#.#", "###", "#.#", "###"},
  {"9", "###", "#.#", "###", "..#", "##."},
  {" ", "...", "...", "...", "...", "..."},
  {".", "...", "...", "...", "...", ".#."},
  {":", "...", ".#.", "...", ".#.", "..."},
  {"-", "...", "...", "###", "...", "..."},
  {"+", "...", ".#.", "###", ".#.", "..."},
  {"/", "..#", "..#", ".#.", "#..", "#.."},
  {"%", "#.#", "..#", ".#.", "#..", "#.#"},
  {"#", "#.#", "###", "#.#", "###", "#.#"},
  {"*", "#.#", ".#.", "###", ".#.", "#.#"},
  {"&", ".#.", "#.#", ".#.", "#.#", ".##"},
  {">", "#..", ".#.", "..#", ".#.", "#.."},
  {"<", "..#", ".#.", "#..", ".#.", "..#"},
  {"(", ".#.", "#..", "#..", "#..", ".#."},
  {")", ".#.", "..#", "..#", "..#", ".#."},
  {"'", ".#.", ".#.", "...", "...", "..."},
  {"!", ".#.", ".#.", ".#.", "...", ".#."},
  {"?", "##.", "..#", ".#.", "...", ".#."},
  {"_", "...", "...", "...", "...", "###"},
  {"=", "...", "###", "...", "###", "..."},
  {"|", ".#.", ".#.", ".#.", ".#.", ".#."},
  {",", "...", "...", "...", ".#.", "#.."},
  {"\"", "#.#", "#.#", "...", "...", "..."},
  {"}", "#..", "##.", "###", "##.", "#.."},     // play
  {"{", "###", "###", "###", "###", "###"},     // stop
  {"~", "...", "#..", "###", "..#", "..."},     // a tie
  {"^", ".#.", "###", ".#.", ".#.", ".#."},     // up
  {"[", ".#.", ".#.", ".#.", "###", ".#."},     // down
}

local index = {}      // byte -> glyph column
for(local i = 0; i < len(glyphs); i = i + 1){
  index[str.byte_at(glyphs[i][0], 0)] = i
}
local UNKNOWN = index[str.byte_at("?", 0)]

local texture = null

// load(): the glyphs into a texture (needs the window)
func font.load(){
  local img = rl.image.color(len(glyphs) * 4, 5, {0, 0, 0, 0})
  for(local i = 0; i < len(glyphs); i = i + 1){
    for(local row = 0; row < 5; row = row + 1){
      local bits = glyphs[i][row + 1]
      for(local col = 0; col < 3; col = col + 1){
        if(str.byte_at(bits, col) == 35){
          img:draw_pixel(i * 4 + col, row, {255, 255, 255, 255})
        }
      }
    }
  }
  texture = img:to_texture()
  img:unload()
}

func font.unload(){
  if(texture != null){
    texture:unload()
    texture = null
  }
}

local func glyph(b){
  if(b >= 97 and b <= 122){
    b = b - 32
  }
  return index[b] or UNKNOWN
}

// width(s, scale?) -> pixels
func font.width(s, scale){
  scale = scale or 1
  local n = len(s)
  if(n == 0){
    return 0
  }
  return (n * 4 - 1) * scale
}

// text(s, x, y, color, scale?): draws s with its top left at x, y
func font.text(s, x, y, color, scale){
  scale = scale or 1
  x = to_int(x)
  y = to_int(y)
  for(local i = 0; i < len(s); i = i + 1){
    local g = glyph(str.byte_at(s, i))
    if(scale == 1){
      texture:draw_rec({g * 4, 0, 3, 5}, {x, y}, color)
    } else {
      texture:draw_pro({g * 4, 0, 3, 5}, {x, y, 3 * scale, 5 * scale}, {0, 0}, 0, color)
    }
    x = x + 4 * scale
  }
}

// center(s, cx, y, color, scale?): s centered on cx
func font.center(s, cx, y, color, scale){
  font.text(s, cx - font.width(s, scale) / 2, y, color, scale)
}

// right(s, rx, y, color, scale?): s ending at rx
func font.right(s, rx, y, color, scale){
  font.text(s, rx - font.width(s, scale), y, color, scale)
}

return font
