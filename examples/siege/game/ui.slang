// game/ui: immediate-mode widgets for the menus and the editor: buttons,
// toggles, sliders, choices, a text field, panels. A widget is drawn and
// handled in the same call; the game's own input ignores the mouse while
// it is over a widget.
local rl = require("raylib")
local math = require("slang/math")
local str = require("slang/string")

local m = {}

m.colors = {
  panel: {20, 24, 34, 215},
  panel_edge: {90, 100, 130, 255},
  button: {44, 52, 72, 235},
  button_hover: {66, 78, 108, 245},
  button_active: {228, 160, 52, 245},
  text: {236, 238, 244},
  dim: {150, 156, 172},
  accent: {255, 196, 64},
  track: {30, 34, 44, 255},
  fill: {90, 170, 240, 255},
}

local font = null
local over = false
local mouse = {x: 0, y: 0}
local pressed = false
local down = false
local released = false

func m.set_font(f){
  font = f
}

func m.font(){
  return font
}

// begin(): at the start of a frame, before any widget
func m.begin(){
  mouse = rl.get_mouse_position()
  pressed = rl.is_mouse_button_pressed(rl.MOUSE_BUTTON_LEFT)
  down = rl.is_mouse_button_down(rl.MOUSE_BUTTON_LEFT)
  released = rl.is_mouse_button_released(rl.MOUSE_BUTTON_LEFT)
  over = false
}

// over_ui() -> whether the mouse was over a widget this frame
func m.over_ui(){
  return over
}

func m.mouse(){
  return mouse
}

local func inside(x, y, w, h){
  return mouse.x >= x and mouse.x <= x + w and mouse.y >= y and mouse.y <= y + h
}

// ------------------------------------------------------------ text

// measure(text, size) -> width
func m.measure(text, size){
  if(font != null){
    return rl.measure_text_ex(font, text, size, size * 0.02).x
  }
  return rl.measure_text(text, size)
}

// text(x, y, text, size, color?)
func m.text(x, y, text, size, color){
  color = color or m.colors.text
  if(font != null){
    rl.draw_text_ex(font, text, {x, y}, size, size * 0.02, color)
  } else {
    rl.draw_text(text, to_int(x), to_int(y), to_int(size), color)
  }
}

// text_centered(cx, y, text, size, color?)
func m.text_centered(cx, y, text, size, color){
  m.text(cx - m.measure(text, size) / 2, y, text, size, color)
}

// text_right(right, y, text, size, color?)
func m.text_right(right, y, text, size, color){
  m.text(right - m.measure(text, size), y, text, size, color)
}

// shadowed(x, y, text, size, color?): with a dark drop shadow (over the
// world)
func m.shadowed(x, y, text, size, color){
  m.text(x + 2, y + 2, text, size, {0, 0, 0, 150})
  m.text(x, y, text, size, color)
}

func m.shadowed_centered(cx, y, text, size, color){
  m.shadowed(cx - m.measure(text, size) / 2, y, text, size, color)
}

// ------------------------------------------------------------ widgets

// panel(x, y, w, h, title?)
func m.panel(x, y, w, h, title){
  rl.draw_rectangle_rounded({x, y, w, h}, 0.08, 6, m.colors.panel)
  rl.draw_rectangle_rounded_lines_ex({x, y, w, h}, 0.08, 6, 1.5, m.colors.panel_edge)
  if(inside(x, y, w, h)){
    over = true
  }
  if(title != null){
    m.text(x + 14, y + 10, title, 20, m.colors.accent)
  }
}

// button(x, y, w, h, label, options?: {active?: bool, size?: int,
// color?}) -> whether it was clicked
func m.button(x, y, w, h, label, options){
  options = options or {}
  local hover = inside(x, y, w, h)
  if(hover){
    over = true
  }
  local color = m.colors.button
  if(options.active){
    color = m.colors.button_active
  } else if(hover){
    color = m.colors.button_hover
  }
  if(options.color != null and not options.active){
    color = options.color
  }
  rl.draw_rectangle_rounded({x, y, w, h}, 0.3, 6, color)
  if(hover and down){
    rl.draw_rectangle_rounded({x, y, w, h}, 0.3, 6, {255, 255, 255, 40})
  }
  local size = options.size or 20
  local tc = m.colors.text
  if(options.active){
    tc = {30, 24, 12}
  }
  m.text_centered(x + w / 2, y + (h - size) / 2, label, size, tc)
  return hover and released
}

// toggle(x, y, w, h, label, on) -> on, after a click
func m.toggle(x, y, w, h, label, on){
  if(m.button(x, y, w, h, label, {active: on})){
    return not on
  }
  return on
}

// choice(x, y, w, h, labels, index, options?) -> index, after a click: a
// row of buttons, one active
func m.choice(x, y, w, h, labels, index, options){
  options = options or {}
  local n = len(labels)
  local gap = 4
  local bw = (w - gap * (n - 1)) / n
  for(local i = 0; i < n; i = i + 1){
    if(m.button(x + i * (bw + gap), y, bw, h, labels[i], {
      active: i == index, size: options.size or 18
    })){
      index = i
    }
  }
  return index
}

// slider(x, y, w, h, label, value, lo, hi, options?: {step?, format?})
// -> value, as dragged
local dragging = null

func m.slider(x, y, w, h, label, value, lo, hi, options){
  options = options or {}
  local hover = inside(x, y, w, h)
  if(hover){
    over = true
  }
  local key = concat(label, x, y)
  if(hover and pressed){
    dragging = key
  }
  if(not down){
    if(dragging == key){
      dragging = null
    }
  }
  if(dragging == key){
    over = true
    local t = (mouse.x - x) / w
    value = lo + (hi - lo) * math.max(0, math.min(1, t))
    if(options.step != null){
      value = math.round(value / options.step) * options.step
    }
  }
  rl.draw_rectangle_rounded({x, y, w, h}, 0.5, 6, m.colors.track)
  local t = (value - lo) / (hi - lo)
  if(t > 0){
    rl.draw_rectangle_rounded({x, y, math.max(h, w * t), h}, 0.5, 6, m.colors.fill)
  }
  local shown = string(math.round(value * 100) / 100)
  if(options.step != null and options.step >= 1){
    shown = string(to_int(value))
  }
  if(options.format != null){
    shown = options.format(value)
  }
  m.text(x + 10, y + (h - 16) / 2, label, 16)
  m.text_right(x + w - 10, y + (h - 16) / 2, shown, 16)
  return value
}

// counter(x, y, w, h, label, value, lo, hi) -> value, with - and + buttons
func m.counter(x, y, w, h, label, value, lo, hi){
  m.text(x, y + (h - 16) / 2, label, 16)
  if(m.button(x + w - h * 2 - 44, y, h, h, "-", {size: 18}) and value > lo){
    value = value - 1
  }
  m.text_centered(x + w - h - 22, y + (h - 18) / 2, string(value), 18)
  if(m.button(x + w - h, y, h, h, "+", {size: 18}) and value < hi){
    value = value + 1
  }
  return value
}

// field(x, y, w, h, text, focused) -> {text, focused}: typed into while
// focused (a click focuses it; Enter or a click elsewhere leaves it)
func m.field(x, y, w, h, text, focused){
  local hover = inside(x, y, w, h)
  if(hover){
    over = true
  }
  if(pressed){
    focused = hover
  }
  if(focused){
    for(local c = rl.get_char_pressed(); c > 0; c = rl.get_char_pressed()){
      if(c >= 32 and c < 127 and len(text) < 24){
        text = concat(text, str.chr(c))
      }
    }
    if((rl.is_key_pressed(rl.KEY_BACKSPACE) or rl.is_key_pressed_repeat(rl.KEY_BACKSPACE)) and len(text) > 0){
      text = str.substring(text, 0, len(text) - 1)
    }
    if(rl.is_key_pressed(rl.KEY_ENTER)){
      focused = false
    }
  }
  local color = m.colors.track
  if(focused){
    color = {40, 46, 60, 255}
  }
  rl.draw_rectangle_rounded({x, y, w, h}, 0.3, 6, color)
  if(focused){
    rl.draw_rectangle_rounded_lines_ex({x, y, w, h}, 0.3, 6, 1.5, m.colors.accent)
  }
  local shown = text
  if(focused and math.floor(rl.get_time() * 2) % 2 == 0){
    shown = concat(text, "_")
  }
  m.text(x + 10, y + (h - 18) / 2, shown, 18)
  return {text: text, focused: focused}
}

// bar(x, y, w, h, t, color): a filled bar (0..1)
func m.bar(x, y, w, h, t, color){
  rl.draw_rectangle_rounded({x, y, w, h}, 0.5, 6, m.colors.track)
  if(t > 0){
    rl.draw_rectangle_rounded({x, y, math.max(h, w * math.min(1, t)), h}, 0.5, 6, color)
  }
}

return m
