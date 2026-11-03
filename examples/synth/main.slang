// A little monophonic analog-style synthesizer: three oscillators, noise, a
// ladder filter and two contours, played from the computer keyboard or the
// keys on screen, with knobs to turn. Its sound is computed in slang in an
// isolate of its own (engine.slang, run by the raylib package's
// raylib/stream), so drawing the panel never makes it stutter. This is the
// flat version; main3d.slang is the same synth in 3D.
//
//   make synth        (or: cd examples/synth && slang run main.slang)
//
// Knobs turn by dragging up and down (shift: finely) or with the mouse
// wheel; a double click puts one back where it started. Switches flip with
// a click. Keys: Z S X D C V G B H N J M , for one octave, Q 2 W 3 E R 5 T
// 6 Y 7 U I for the next; left and right shift the octave, space lets go
// of every note. The wheels left of the keyboard bend the pitch (it springs
// back) and set the modulation. Up and down (or the arrows on the strip)
// step through the premade patches of patches.slang.
//
// SYNTH_FRAMES=n quits after n frames, SYNTH_DEMO=1 plays a phrase by
// itself (both for trying it without a player), SYNTH_SCREENSHOT=file.png
// saves the last frame.
local rl = require("raylib")
local params = require("params")
local panel = require("panel")

local W = panel.W
local H = panel.H
local colors = panel.colors
local controls = panel.controls

// ------------------------------------------------------------ the keyboard

local func key_at(x, y){
  local top = panel.KEYS_Y
  if(y < top or y > top + panel.WHITE_H){
    return null
  }
  if(y < top + panel.BLACK_H){
    for(let local k in values(panel.keys)){
      if(k.black and x >= k.x and x < k.x + k.w){
        return k.note
      }
    }
  }
  for(let local k in values(panel.keys)){
    if(not k.black and x >= k.x and x < k.x + k.w){
      return k.note
    }
  }
  return null
}

local func wheel_at(x, y){
  for(let local wh in values(panel.wheels)){
    if(x >= wh.x - 4 and x <= wh.x + panel.WHEEL_W + 4 and
      y >= panel.WHEEL_Y and y <= panel.WHEEL_Y + panel.WHEEL_H){
      return wh.index
    }
  }
  return null
}

local func draw_wheel(wh){
  local v = controls[wh.index]
  local x = wh.x
  local y0 = panel.WHEEL_Y
  local h = panel.WHEEL_H
  local w = panel.WHEEL_W
  rl.draw_rectangle(x - 4, y0 - 4, w + 8, h + 8, {8, 8, 8})
  rl.draw_rectangle_gradient_v(x, y0, w, h, {40, 40, 42}, {16, 16, 16})
  // ridges that move with the wheel
  local offset = v * 60.0
  for(local k = 0; k < 14; k = k + 1){
    local y = y0 + ((k * 12.0 + offset) % h)
    rl.draw_line(x + 2, to_int(y), x + w - 2, to_int(y), {70, 70, 72})
  }
  local my = to_int(y0 + h - v * h)
  rl.draw_rectangle(x, my - 3, w, 6, colors.pointer)
  panel.text_center(params.list[wh.index].label, x + w / 2, y0 + h + 12, 10, colors.text)
}

local func draw_keyboard(){
  local bed = panel.BED_Y
  local top = panel.KEYS_Y
  rl.draw_rectangle(40, bed - 6, W - 80, H - bed + 6, colors.bed)
  for(let local wh in values(panel.wheels)){
    draw_wheel(wh)
  }
  panel.text_center(concat("OCTAVE C", to_int(panel.octave / 12) - 1), 96, bed + 16, 10, colors.dim)
  for(let local k in values(panel.keys)){
    if(not k.black){
      local color = colors.white_key
      if(panel.key_down(k.note)){
        color = colors.white_down
      }
      rl.draw_rectangle(to_int(k.x), top, to_int(k.w) - 1, panel.WHITE_H, color)
      if(k.note % 12 == 0){
        panel.text_center(concat("C", to_int(k.note / 12) - 1), k.x + k.w / 2, top + panel.WHITE_H - 18, 10, colors.dim)
      }
    }
  }
  for(let local k in values(panel.keys)){
    if(k.black){
      local color = colors.black_key
      if(panel.key_down(k.note)){
        color = colors.black_down
      }
      rl.draw_rectangle(to_int(k.x), top, to_int(k.w), panel.BLACK_H, color)
    }
  }
  rl.draw_rectangle(panel.KEYS_X, top - 4, W - 48 - panel.KEYS_X, 4, colors.felt)
}

local func draw_cheeks(){
  rl.draw_rectangle(0, 0, 40, H, colors.wood)
  rl.draw_rectangle(W - 40, 0, 40, H, colors.wood)
  rl.draw_rectangle(36, 0, 4, H, colors.wood_dark)
  rl.draw_rectangle(W - 40, 0, 4, H, colors.wood_dark)
}

// ------------------------------------------------------------ input

local func handle_mouse(){
  local m = rl.get_mouse_position()
  local left = rl.MOUSE_BUTTON_LEFT
  if(rl.is_mouse_button_pressed(left)){
    local i = panel.control_at(m.x, m.y) or wheel_at(m.x, m.y)
    if(i != null){
      panel.press(i, m.y)
    } else if(not panel.press_strip(m.x, m.y)){
      local n = key_at(m.x, m.y)
      if(n != null){
        panel.press_key(n)
      }
    }
  }
  if(rl.is_mouse_button_down(left)){
    panel.drag(m.y)
    // gliding over the keys plays the one under the mouse
    panel.slide_key(key_at(m.x, m.y))
  }
  if(rl.is_mouse_button_released(left)){
    panel.release()
  }
  // the wheel turns the knob under the mouse
  local w = rl.get_mouse_wheel_move()
  if(w != 0.0){
    local i = panel.control_at(m.x, m.y) or wheel_at(m.x, m.y)
    if(i != null){
      panel.scroll(i, w)
    }
  }
  panel.spring()
}

// ------------------------------------------------------------ the loop

rl.set_config_flags(rl.FLAG_MSAA_4X_HINT)
rl.init_window(W, H, "slang mini")
rl.set_target_fps(60)
panel.load_font()
panel.start()
if(panel.autoplay){
  panel.play_song()
}

local frame = 0
panel.mark_start()
for(not rl.window_should_close() and frame != panel.max_frames){
  handle_mouse()
  panel.handle_keys()
  panel.handle_midi()
  panel.demo(frame)
  panel.update_stats()
  rl.begin_drawing()
  rl.clear_background(colors.bed)
  draw_cheeks()
  panel.draw_face(true)
  draw_keyboard()
  rl.end_drawing()
  frame = frame + 1
  if(panel.screenshot != null and frame == panel.max_frames){
    rl.take_screenshot(panel.screenshot)
  }
}

panel.mark_end()
panel.unload_font()
rl.close_window()
panel.finish(frame)
