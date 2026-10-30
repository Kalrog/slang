// Hearts, inventory, messages, the dialogue box and the title screens.
local gfx = require("engine/gfx")
local color = require("engine/color")
local dlg = require("engine/dialogue")
local world = require("engine/world")

local m = {}

local white = color.of("#f4f4f4")
local grey = color.of("#9a9aaa")
local gold = color.of("#e9c46a")
local dark = color.of("#101018")
local box = color.of("#1c1c2ae0")
local shade = color.of("#00000090")

local msg = {text: null, time: 0}

func m.message(text, seconds){
  msg.text = text
  msg.time = seconds or 2.5
}

func m.update(dt){
  if(msg.time > 0){
    msg.time = msg.time - dt
    if(msg.time <= 0){
      msg.text = null
    }
  }
}

// wrap(text, width, size) -> lines that fit into width logical pixels
local func wrap(text, width, size){
  local str = require("slang/string")
  local words = str.split(text, " ")
  local lines = {}
  local line = ""
  for(let local word in values(words)){
    local candidate = word
    if(line != ""){
      candidate = concat(line, " ", word)
    }
    if(gfx.text_width(candidate, size) > width and line != ""){
      append(lines, line)
      line = word
    } else {
      line = candidate
    }
  }
  if(line != ""){
    append(lines, line)
  }
  return lines
}

local func draw_bar(){
  local p = world.state.player
  gfx.rect(0, 176, 320, 16, dark)
  for(local i = 0; i < p.max_hp; i = i + 1){
    local spr = sprites.heart_empty
    if(i < p.hp){
      spr = sprites.heart
    }
    gfx.draw_sprite(spr, 2 + i * 11, 176, false, 1, 0.75)
  }
  gfx.draw_sprite(sprites.key, 120, 176, false, 1, 0.75)
  gfx.text(concat("x", p.keys), 132, 177, 8, white)
  gfx.draw_sprite(sprites.coins, 160, 176, false, 1, 0.75)
  gfx.text(string(p.coins), 174, 177, 8, gold)
  gfx.text(world.state.name, 240, 177, 8, grey)
}

local func draw_message(){
  if(msg.text == null){
    return null
  }
  local w = gfx.text_width(msg.text, 8) + 8
  gfx.rect(160 - w / 2, 156, w, 14, shade)
  gfx.text_centered(msg.text, 160, 157, 8, white)
}

local func draw_dialogue(){
  if(not dlg.active()){
    return null
  }
  local c = dlg.current()
  gfx.rect(8, 112, 304, 68, box)
  gfx.rect(8, 112, 304, 1, grey)
  if(c.text != null){
    local y = 118
    for(let local line in values(wrap(c.text, 292, 8))){
      gfx.text(line, 14, y, 8, white)
      y = y + 11
    }
    gfx.text("[enter]", 268, 168, 7, grey)
  } else {
    local y = 118
    for(local i = 0; i < len(c.options); i = i + 1){
      local col = grey
      local prefix = "   "
      if(i == c.selected){
        col = gold
        prefix = " > "
      }
      gfx.text(concat(prefix, c.options[i]), 14, y, 8, col)
      y = y + 12
    }
  }
}

func m.draw(){
  draw_bar()
  draw_message()
  draw_dialogue()
}

func m.draw_title(){
  gfx.rect(0, 0, 320, 192, dark)
  gfx.text_centered("SLANG DUNGEON", 160, 40, 20, gold)
  gfx.text_centered("a scripting language example", 160, 70, 8, grey)
  gfx.draw_sprite(sprites.player, 120, 96, false, 1, 2)
  gfx.draw_sprite(sprites.goblin, 168, 96, true, 1, 2)
  gfx.text_centered(
    "arrows / wasd to move, bump to fight and talk", 160, 140, 8, white
  )
  gfx.text_centered("press enter", 160, 160, 8, gold)
}

func m.draw_end(title, line){
  gfx.rect(0, 0, 320, 192, shade)
  gfx.rect(60, 60, 200, 72, box)
  gfx.text_centered(title, 160, 70, 16, gold)
  gfx.text_centered(line, 160, 96, 8, white)
  gfx.text_centered("press R to play again", 160, 114, 8, grey)
}

return m
