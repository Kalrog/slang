// Drawing helpers over the host's ebiten module. Sprites are baked pixel
// tables ({w, h, pixels}); their images are created on first use, so sprite
// declarations work without a window (for example in the tests).
local color = require("engine/color")

local eb = null
if(let {"ok", local host} = pcall(require, "ebiten")){
  eb = host
}

local m = {color: color}

func m.available(){
  return eb != null
}

func m.image_of(spr){
  if(spr.image == null){
    spr.image = eb.image(spr.w, spr.h, spr.pixels)
  }
  return spr.image
}

// draw_sprite(spr, x, y [, flip_x, alpha, scale])
func m.draw_sprite(spr, x, y, flip, alpha, scale){
  eb.draw(m.image_of(spr), x, y, flip or false, alpha or 1, scale or 1)
}

func m.rect(x, y, w, h, c){
  eb.rect(x, y, w, h, c)
}

func m.text(s, x, y, size, c){
  eb.text(s, x, y, size, c)
}

func m.text_width(s, size){
  return eb.text_width(s, size)
}

func m.text_centered(s, cx, y, size, c){
  eb.text(s, cx - eb.text_width(s, size) / 2, y, size, c)
}

return m
