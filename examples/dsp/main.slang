// The player: five instruments written as dsp blocks (instruments.slang),
// played from the computer keyboard through an echo and a stereo reverb
// (a .dsp file), with the sliders each program declares and the kernel
// code the compiler made of it beside them.
//
//   make dsp        (or: cd examples/dsp && slang run main.slang)
//
// Keys: A W S E D F T G Y H U J K play an octave (the keys of a piano, by
// position), Z / X move it down / up, 1-5 or a click on a tab picks the
// instrument, the wheel scrolls the code. DSP_FRAMES=n quits after n
// frames, DSP_SCREENSHOT=file.png saves the last one, DSP_NOTE=1 holds a
// note (both for smoke tests).
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local stream = require("raylib/stream")
local engine = require("engine")
local instruments = require("instruments")

local W = 1040
local H = 680
local RATE = 48000

local C = {
  back: {22, 24, 30},
  panel: {32, 35, 44},
  line: {52, 56, 70},
  text: {214, 218, 228},
  dim: {130, 136, 156},
  accent: {255, 176, 72},
  accent2: {96, 196, 255},
  key: {226, 228, 236},
  key_dark: {40, 42, 52},
  held: {255, 176, 72},
  code_keyword: {255, 140, 120},
  code_number: {150, 210, 140},
  code_comment: {110, 116, 136},
}

local layout = engine.layout()
local params = engine.params(layout)
local player = stream.play(func(params, rate){
  return require("engine").new(params, rate)
}, {args: {params, RATE}, sample_rate: RATE, channels: 2, block: 128})

// ------------------------------------------------------------ playing

// the keys of an octave, by position, as semitones from C
local KEYS = {
  {rl.KEY_A, 0, "A"},
  {rl.KEY_W, 1, "W"},
  {rl.KEY_S, 2, "S"},
  {rl.KEY_E, 3, "E"},
  {rl.KEY_D, 4, "D"},
  {rl.KEY_F, 5, "F"},
  {rl.KEY_T, 6, "T"},
  {rl.KEY_G, 7, "G"},
  {rl.KEY_Y, 8, "Y"},
  {rl.KEY_H, 9, "H"},
  {rl.KEY_U, 10, "U"},
  {rl.KEY_J, 11, "J"},
  {rl.KEY_K, 12, "K"},
}
local NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

local octave = 4
local held = {}
local notes = 0

local func midi_of(semitone){
  return (octave + 1) * 12 + semitone
}

local func hz(note){
  return 440.0 * 2.0 ^ ((note - 69) / 12.0)
}

local func note_on(note){
  append(held, note)
  notes = notes + 1
  params[engine.FREQ] = hz(note)
  params[engine.NOTE] = notes
  params[engine.GATE] = 1.0
}

local func note_off(note){
  for(local i = len(held) - 1; i >= 0; i = i - 1){
    if(held[i] == note){
      remove(held, i)
      break
    }
  }
  if(len(held) == 0){
    params[engine.GATE] = 0.0
  } else {
    // legato back to the note still held
    params[engine.FREQ] = hz(held[len(held) - 1])
  }
}

local func is_held(note){
  for(let local n in values(held)){
    if(n == note){
      return true
    }
  }
  return false
}

local func choose(k){
  params[engine.PROGRAM] = k
}

// ------------------------------------------------------------ the code view

local code_lines = {}
local code_for = -1
local scroll = 0

local KERNEL_WORDS = {["func"]: true, ["struct"]: true, ["for(local"]: true}

local func code_color(line){
  local t = str.trim(line)
  if(str.starts_with(t, "//")){
    return C.code_comment
  }
  local first = str.split(t, " ")[0]
  local word = str.split(first, "(")[0]
  if(KERNEL_WORDS[word]){
    return C.code_keyword
  }
  return C.text
}

// ------------------------------------------------------------ widgets

local drag = null

// a slider of the program's: label, value and bar; returns its height
local func slider(s, x, y, w){
  local c = s.control
  local v = params[s.slot]
  local t = 0.0
  if(c.max > c.min){
    t = (v - c.min) / (c.max - c.min)
  }
  local bar_y = y + 16
  rl.draw.text(c.label, x, y, 10, C.dim)
  local shown = string(math.round(v * 100) / 100)
  rl.draw.text(shown, x + w - rl.text.measure(shown, 10), y, 10, C.text)
  rl.draw.rectangle(x, bar_y, w, 6, C.line)
  rl.draw.rectangle(x, bar_y, to_int(w * t), 6, C.accent2)
  rl.draw.rectangle(x + to_int(w * t) - 2, bar_y - 3, 5, 12, C.text)
  local m = rl.mouse.position
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT) and m.x >= x - 4 and
    m.x <= x + w + 4 and m.y >= bar_y - 6 and m.y <= bar_y + 12){
    drag = {slot: s.slot, x: x, w: w, c: c}
  }
  return 30
}

local func update_drag(){
  if(drag == null){
    return
  }
  if(not rl.mouse.down(rl.MOUSE_BUTTON_LEFT)){
    drag = null
    return
  }
  local c = drag.c
  local t = math.clamp((rl.mouse.position.x - drag.x) / drag.w, 0.0, 1.0)
  local v = c.min + t * (c.max - c.min)
  if(c.step > 0){
    v = c.min + math.round((v - c.min) / c.step) * c.step
  }
  params[drag.slot] = math.clamp(v, c.min, c.max)
}

// ------------------------------------------------------------ drawing

local stats = {load: 0.0}

local func draw_tabs(k){
  local x = 16
  for(local i = 0; i < len(instruments.names); i = i + 1){
    local name = concat(string(i + 1), " ", instruments.names[i])
    local w = rl.text.measure(name, 20) + 24
    local on = i == k
    rl.draw.rectangle(x, 52, w, 32, if(on){ C.panel } else { C.back })
    if(on){
      rl.draw.rectangle(x, 82, w, 2, C.accent)
    }
    rl.draw.text(name, x + 12, 58, 20, if(on){ C.text } else { C.dim })
    local m = rl.mouse.position
    if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT) and m.x >= x and m.x < x + w and
      m.y >= 52 and m.y < 84){
      choose(i)
    }
    x = x + w + 6
  }
}

local func draw_sliders(k){
  local x = 24
  local y = 104
  local w = 340
  rl.draw.text("SLIDERS", x, y, 10, C.accent)
  y = y + 18
  for(let local s in values(layout.by_program[k])){
    y = y + slider(s, x, y, w)
  }
  local n = len(instruments.list)
  y = y + 10
  rl.draw.text("ECHO  (a dsp block)", x, y, 10, C.accent)
  y = y + 18
  for(let local s in values(layout.by_program[n])){
    y = y + slider(s, x, y, w)
  }
  y = y + 10
  rl.draw.text("REVERB  (programs/stereo_reverb.dsp)", x, y, 10, C.accent)
  y = y + 18
  for(let local s in values(layout.by_program[n + 1])){
    y = y + slider(s, x, y, w)
  }
}

local func draw_code(k){
  local p = instruments.list[k]
  if(code_for != k){
    code_for = k
    code_lines = str.split(p.source, "\n")
    scroll = 0
  }
  local x = 392
  local y = 104
  local h = 432
  rl.draw.rectangle(x - 8, y - 8, W - x - 8, h + 16, C.panel)
  local title = concat(
    "KERNEL  ", string(len(code_lines)), " lines, ", string(p.ring * 4 / 1024),
    " KB of delay lines"
  )
  rl.draw.text(title, x, y, 10, C.accent)
  local rows = to_int((h - 20) / 12)
  local wheel = rl.mouse.wheel
  if(wheel != 0.0){
    scroll = to_int(math.clamp(
      scroll - wheel * 3, 0, math.max(0, len(code_lines) - rows)
    ))
  }
  for(local i = 0; i < rows and scroll + i < len(code_lines); i = i + 1){
    local line = code_lines[scroll + i]
    rl.draw.text(line, x, y + 20 + i * 12, 10, code_color(line))
  }
}

local func draw_keyboard(){
  local x0 = 24
  local y = 560
  local kw = 52
  local white = 0
  // white keys first, then the black ones over them
  for(let local pass in values({false, true})){
    white = 0
    for(let local k in values(KEYS)){
      local semitone = k[1]
      local black = semitone % 12 == 1 or semitone % 12 == 3 or
        semitone % 12 == 6 or semitone % 12 == 8 or semitone % 12 == 10
      local note = midi_of(semitone)
      if(black == pass){
        if(black){
          local x = x0 + white * kw - 16
          rl.draw.rectangle(
            x, y, 32, 60, if(is_held(note)){ C.held } else { C.key_dark }
          )
          rl.draw.text(k[2], x + 12, y + 44, 10, C.dim)
        } else {
          local x = x0 + white * kw
          rl.draw.rectangle(
            x, y, kw - 2, 100, if(is_held(note)){ C.held } else { C.key }
          )
          rl.draw.text(k[2], x + 20, y + 70, 10, C.key_dark)
          rl.draw.text(concat(
            NAMES[semitone % 12],
            string(octave + to_int(semitone / 12)),
          ), x + 16, y + 84, 10, C.dim)
        }
      }
      if(not black){
        white = white + 1
      }
    }
  }
  local info = concat(
    "octave ", string(octave), "  (Z / X)    load ",
    string(math.round(stats.load * 1000) / 10), "% of real time"
  )
  rl.draw.text(info, x0 + 8 * kw + 24, y + 6, 10, C.dim)
  rl.draw.text(
    "A W S E D F T G Y H U J K play", x0 + 8 * kw + 24, y + 24, 10, C.dim
  )
}

// ------------------------------------------------------------ the loop

rl.window.open(W, H, "dsp: block diagrams compiled to kernels")
rl.target_fps = 60
local max_frames = null
if(os.getenv("DSP_FRAMES") != null){
  max_frames = to_int(os.getenv("DSP_FRAMES"))
}
local screenshot = os.getenv("DSP_SCREENSHOT")
if(os.getenv("DSP_NOTE") != null){
  note_on(midi_of(0))
}
local frame = 0
local stats_at = 0.0
for(not rl.window.should_close){
  frame = frame + 1
  for(let local k in values(KEYS)){
    if(rl.key.pressed(k[0])){
      note_on(midi_of(k[1]))
    }
    if(rl.key.released(k[0])){
      note_off(midi_of(k[1]))
    }
  }
  if(rl.key.pressed(rl.KEY_Z) and octave > 1){
    octave = octave - 1
  }
  if(rl.key.pressed(rl.KEY_X) and octave < 7){
    octave = octave + 1
  }
  for(local i = 0; i < len(instruments.list); i = i + 1){
    if(rl.key.pressed(rl.KEY_ONE + i)){
      choose(i)
    }
  }
  update_drag()
  if(rl.time - stats_at > 0.5){
    stats_at = rl.time
    stats = player:stats()
  }
  local k = to_int(params[engine.PROGRAM])
  rl.drawing{
    rl.draw.clear(C.back)
    rl.draw.text("dsp", 16, 14, 24, C.accent)
    rl.draw.text(
      "block diagrams in slang, compiled to kernels when the file is", 70, 22,
      10, C.dim
    )
    draw_tabs(k)
    draw_sliders(k)
    draw_code(k)
    draw_keyboard()
  }
  if(max_frames != null and frame >= max_frames){
    if(screenshot != null){
      rl.window.screenshot(screenshot)
    }
    break
  }
}
local last = player:stats()
player:stop()
rl.window.close()
print(concat(
  "frames ", string(frame), ", load ", string(last.load), ", underruns ",
  string(last.underruns), "\n"
))
