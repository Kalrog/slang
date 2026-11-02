// What the 2D and the 3D synth share: the sound (raylib/stream running
// engine.slang), the notes held, the face of the panel as raylib draws it
// in 2D, the layout of keys and wheels, and what a click, a drag, the mouse
// wheel and the computer keyboard do. Positions are those of the 2D window
// (W x H); the 3D version draws the face into a texture and maps its mouse
// rays back to them.
local rl = require("raylib")
local stream = require("raylib/stream")
local isolate = require("slang/isolate")
local buffer = require("slang/buffer")
local math = require("slang/math")
local os = require("slang/os")
local params = require("params")

local panel = {}

local W = 1200
local H = 700
local SAMPLE_RATE = 48000
panel.W = W
panel.H = H

local colors = {
  wood: {104, 58, 30},
  wood_dark: {66, 36, 18},
  panel: {24, 24, 26},
  strip: {38, 38, 41},
  bed: {30, 30, 32},
  text: {236, 234, 226},
  dim: {150, 148, 140},
  line: {90, 90, 92},
  skirt: {58, 58, 60},
  cap: {14, 14, 14},
  pointer: {245, 245, 240},
  blue: {70, 140, 230},
  blue_dark: {22, 48, 88},
  orange: {236, 140, 50},
  orange_dark: {80, 46, 18},
  white_key: {244, 242, 234},
  white_down: {200, 212, 232},
  black_key: {22, 22, 22},
  black_down: {70, 86, 116},
  scope: {120, 230, 140},
  warn: {240, 110, 90},
  felt: {120, 24, 24},
}
panel.colors = colors

// ------------------------------------------------------------ the sound

// the controls, shared with the render isolate: written here, read there
// at every block
local controls = buffer.shared("double", params.count)
for(local i = 0; i < params.count; i = i + 1){
  controls[i] = params.list[i].default
}
panel.controls = controls
local notes = isolate.channel()
// the last samples, for the oscilloscope (the last cell: where the next goes)
local scope = buffer.shared("float", 2049)
// what the engine says about the song playing: state {playing, where,
// how long}, the keys it holds
local status = {state: buffer.shared("double", 4), keys: buffer.shared("uint8", 128)}
local player = null

// start(): the sound starts playing (in two isolates of raylib/stream)
func panel.start(){
  player = stream.play(func(controls, notes, scope, rate, status){
    local engine = require("engine")
    return engine.new(controls, notes, scope, rate, status)
  }, {args: {controls, notes, scope, SAMPLE_RATE, status}, sample_rate: SAMPLE_RATE})
}

// stop() -> the last stats: the sound stops
func panel.stop(){
  local s = player:stats()
  player:stop()
  return s
}

panel.stats = {load: 0.0, peak: 0.0, underruns: 0, playing: false}
local stats_at = -1.0

// SYNTH_LOG=1 prints the frame rate, the load and the song's place every
// two seconds
local log = os.getenv("SYNTH_LOG") != null
local log_at = 0.0

// update_stats(): twice a second, what the stream reports
func panel.update_stats(){
  local now = rl.get_time()
  if(now - stats_at > 0.5){
    stats_at = now
    panel.stats = player:stats()
  }
  if(log and now - log_at > 2.0){
    log_at = now
    print(concat("t=", to_int(now), " fps ", rl.get_fps(), " dsp ",
      to_int(panel.stats.load * 100), "% peak ", to_int(panel.stats.peak * 100),
      "% underruns ", panel.stats.underruns, " song ", to_int(status.state[1]),
      " playing ", status.state[0], "\n"))
  }
}

// how many times each note is held (by the mouse and the keyboard)
panel.sounding = {}

func panel.note_on(n){
  panel.sounding[n] = (panel.sounding[n] or 0) + 1
  notes:send({on: n})
}

func panel.note_off(n){
  local c = panel.sounding[n] or 0
  if(c <= 1){
    panel.sounding[n] = null
  } else {
    panel.sounding[n] = c - 1
  }
  notes:send({off: n})
}

func panel.all_off(){
  panel.sounding = {}
  notes:send({panic: true})
}

// whether a key is down: played by hand or by the song
func panel.key_down(n){
  return panel.sounding[n] != null or status.keys[n] > 0
}

// ------------------------------------------------------------ songs

// the song files: the one named on the command line, else those in the
// songs folder next to this file (the project's first search path), from
// wherever the synth was started
local song_files = {}
local song_choice = 0
local loaded = {}
panel.song = null

local func find_songs(){
  local a = args()
  if(len(a) > 0){
    append(song_files, a[0])
    return null
  }
  local dir = require("slang/path").join(__PACKAGES.search_paths[0], "songs")
  if(os.is_dir(dir)){
    local names = require("slang/table").sort(os.list_dir(dir))
    for(let local f in values(names)){
      if(require("slang/string").ends_with(f, ".slang")){
        append(song_files, require("slang/path").join(dir, f))
      }
    }
  }
}
find_songs()

// the chosen song, loaded once
local func chosen(){
  if(len(song_files) == 0){
    return null
  }
  local f = song_files[song_choice]
  if(loaded[f] == null){
    loaded[f] = require("song").load(f)
  }
  panel.song = loaded[f]
  return panel.song
}

// song_playing() -> bool, song_time() -> seconds into it
func panel.song_playing(){
  return status.state[0] > 0.5
}

func panel.song_time(){
  return status.state[1]
}

// play_song(): plays the chosen song from its start (it sets its sound)
func panel.play_song(){
  local s = chosen()
  if(s != null){
    notes:send({song: s})
    status.state[0] = 1
    status.state[1] = 0
  }
}

func panel.stop_song(){
  notes:send({stop_song: true})
  status.state[0] = 0
}

// next_song(): the next song file becomes the chosen one
func panel.next_song(){
  if(len(song_files) > 0){
    local playing = panel.song_playing()
    if(playing){
      panel.stop_song()
    }
    song_choice = (song_choice + 1) % len(song_files)
    chosen()
    if(playing){
      panel.play_song()
    }
  }
}

// the chosen song, for the strip, before anything plays
chosen()

// ------------------------------------------------------------ text

// a TrueType font when the system has one of these (sharper when scaled,
// as on the 3D panel), else raylib's own
local font_files = {
  "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf",
  "/System/Library/Fonts/Supplemental/Arial Narrow Bold.ttf",
  "/usr/share/fonts/truetype/dejavu/DejaVuSansCondensed-Bold.ttf",
  "/usr/share/fonts/TTF/DejaVuSansCondensed-Bold.ttf",
}
local font = null

// load_font(): after init_window
func panel.load_font(){
  for(let local f in values(font_files)){
    if(font == null and os.exists(f)){
      font = rl.load_font_ex(f, 48, null)
      rl.gen_texture_mipmaps(font.texture)
      rl.set_texture_filter(font.texture, rl.TEXTURE_FILTER_TRILINEAR)
    }
  }
}

func panel.unload_font(){
  if(font != null){
    rl.unload_font(font)
    font = null
  }
}

// a size of raylib's font as the TrueType font's
local func ttf_size(size){
  return size * 1.3
}

local func measure(s, size){
  if(font == null){
    return rl.measure_text(s, size)
  }
  return rl.measure_text_ex(font, s, ttf_size(size), 0.6).x
}

func panel.text(s, x, y, size, color){
  if(font == null){
    rl.draw_text(s, to_int(x), to_int(y), size, color)
  } else {
    rl.draw_text_ex(font, s, {x: x, y: y - size * 0.1}, ttf_size(size), 0.6, color)
  }
}
local text = panel.text

local func text_center(s, x, y, size, color){
  text(s, x - measure(s, size) / 2, y, size, color)
}
panel.text_center = text_center

// ------------------------------------------------------------ the face

local func v2(x, y){
  return {x: x, y: y}
}

// a knob's angle: 0 straight up, in radians, over 300 degrees of travel
func panel.knob_angle(v){
  return (v * 300.0 - 150.0) * math.pi / 180.0
}
local knob_angle = panel.knob_angle

// a rotary switch's angle for position i of n: over 200 degrees
func panel.step_angle(i, n){
  return ((i / (n - 1)) * 200.0 - 100.0) * math.pi / 180.0
}
local step_angle = panel.step_angle

func panel.knob_radius(c){
  if(c.kind == "steps"){
    return 18.0
  }
  if(c.small){
    return 15.0
  }
  return 20.0
}
local knob_radius = panel.knob_radius

// a rocker's colors: {on, off}
func panel.switch_colors(c){
  if(c.id == "kbd_ctrl" or c.id == "decay_sw" or c.id == "osc3_ctrl" or
    c.id == "osc_mod" or c.id == "filter_mod"){
    return {colors.orange, colors.orange_dark}
  }
  return {colors.blue, colors.blue_dark}
}

local func polar(cx, cy, angle, r){
  return v2(cx + math.sin(angle) * r, cy - math.cos(angle) * r)
}

local func draw_cap(cx, cy, r, angle){
  rl.draw_circle(to_int(cx), to_int(cy), r + 5.0, colors.skirt)
  rl.draw_circle(to_int(cx), to_int(cy), r, colors.cap)
  rl.draw_circle_lines(to_int(cx), to_int(cy), r, {70, 70, 72})
  rl.draw_line_ex(
    polar(cx, cy, angle, r * 0.25), polar(cx, cy, angle, r - 2.0), 3.0,
    colors.pointer
  )
}

local func draw_knob(c, v, caps){
  local r = knob_radius(c)
  // the scale: eleven ticks, the middle one longer on a bipolar knob
  for(local t = 0; t <= 10; t = t + 1){
    local a = knob_angle(t / 10.0)
    local outer = r + 11.0
    if(c.bipolar and t == 5){
      outer = r + 15.0
    }
    rl.draw_line_ex(polar(c.x, c.y, a, r + 7.0), polar(c.x, c.y, a, outer), 1.5, colors.dim)
  }
  if(caps){
    draw_cap(c.x, c.y, r, knob_angle(v))
  }
  if(c.label != ""){
    text_center(c.label, c.x, c.y + r + 14.0, 10, colors.text)
  }
  if(c.left != null){
    // what the two ends mean, a line under the label
    text(c.left, c.x - r - 18.0, c.y + r + 28.0, 10, colors.dim)
    text(c.right, c.x + r + 18.0 - measure(c.right, 10), c.y + r + 28.0, 10, colors.dim)
  }
}

local func draw_steps(c, v, caps){
  local r = knob_radius(c)
  local n = len(c.labels)
  for(local i = 0; i < n; i = i + 1){
    local a = step_angle(i, n)
    // the side labels move out further, so they clear the knob
    local at = polar(c.x, c.y, a, r + 17.0)
    at.x = at.x + math.sin(a) * 8.0
    local color = colors.dim
    if(i == to_int(v)){
      color = colors.text
    }
    text_center(c.labels[i], at.x, at.y - 4.0, 10, color)
  }
  if(caps){
    draw_cap(c.x, c.y, r, step_angle(to_int(v), n))
  }
  text_center(c.label, c.x, c.y + r + 14.0, 10, colors.text)
}

// a rocker: the lit half is the side it is pressed to
local func draw_switch(c, v, caps){
  local x = to_int(c.x - 10)
  local y = to_int(c.y - 15)
  rl.draw_rectangle(x - 2, y - 2, 24, 34, {8, 8, 8})
  if(caps){
    local sc = panel.switch_colors(c)
    if(v > 0.5){
      rl.draw_rectangle(x, y, 20, 15, sc[0])
      rl.draw_rectangle(x, y + 15, 20, 15, sc[1])
    } else {
      rl.draw_rectangle(x, y, 20, 15, sc[1])
      rl.draw_rectangle(x, y + 15, 20, 15, sc[0])
    }
  }
  if(c.label != ""){
    text_center(c.label, c.x, c.y + 22.0, 10, colors.text)
  }
}

local func clamp_unit(v){
  if(v > 1.0){
    return 1.0
  }
  if(v < -1.0){
    return -1.0
  }
  return v
}

local func draw_scope(x, y, w, h){
  rl.draw_rectangle(x, y, w, h, {10, 16, 12})
  rl.draw_line(x, y + h / 2, x + w, y + h / 2, {30, 60, 40})
  local n = 2048
  local at = to_int(scope[n])
  // a rising zero crossing, so that the wave stands still
  local start = at - w - 1
  local found = false
  for(local k = 0; k < 900 and not found; k = k + 1){
    local i = (start - k + n * 4) % n
    local prev = (i - 1 + n) % n
    if(scope[prev] < 0.0 and scope[i] >= 0.0){
      start = i
      found = true
    }
  }
  local lastx = x
  local lasty = y + h / 2
  for(local k = 0; k < w; k = k + 1){
    local s = scope[(start + k + n * 4) % n]
    local py = to_int(y + h / 2 - clamp_unit(s * 1.4) * (h / 2 - 2))
    if(k > 0){
      rl.draw_line(lastx, lasty, x + k, py, colors.scope)
    }
    lastx = x + k
    lasty = py
  }
}

// the strip under the panel: name, oscilloscope, load
panel.STRIP_Y = params.bottom + 6
panel.STRIP_H = 54

local func draw_strip(){
  local y = panel.STRIP_Y
  local stats = panel.stats
  rl.draw_rectangle(40, y, W - 80, panel.STRIP_H, colors.strip)
  text("slang", 60, y + 10, 20, colors.text)
  text("mini", 60 + measure("slang ", 20), y + 10, 20, colors.orange)
  if(panel.song == null){
    text("analog-style monophonic synthesizer", 60, y + 34, 10, colors.dim)
  } else {
    local s = panel.song
    local func clock(t){
      local m = to_int(t / 60)
      local sec = to_int(t) % 60
      local pad = ""
      if(sec < 10){
        pad = "0"
      }
      return concat("", m, ":", pad, sec)
    }
    if(panel.song_playing()){
      text(concat("> ", s.title, "  ", clock(panel.song_time()), " / ", clock(s.length)), 178, y + 12, 10, colors.text)
      text(concat(s.composer, "    ENTER stop  TAB next"), 178, y + 30, 10, colors.dim)
    } else {
      text(s.title, 178, y + 12, 10, colors.text)
      text(concat(s.composer, "    ENTER play  TAB next"), 178, y + 30, 10, colors.dim)
    }
  }
  draw_scope(450, y + 6, 360, 42)
  local load = concat("DSP ", math.floor(stats.load * 1000) / 10, "%")
  local peak = concat("peak ", math.floor(stats.peak * 1000) / 10, "%")
  text(load, 830, y + 8, 20, colors.text)
  text(peak, 830, y + 32, 10, colors.dim)
  local color = colors.dim
  if(stats.underruns > 0){
    color = colors.warn
  }
  text(concat("underruns ", stats.underruns), 940, y + 32, 10, color)
  text(concat("FPS ", rl.get_fps()), 1080, y + 32, 10, colors.dim)
}

// draw_face(caps): the panel and the strip, x from 40 to W - 40 and y from
// params.top to the strip's end; caps: also the knobs' caps and the
// rockers (the 3D synth makes those of its own)
func panel.draw_face(caps){
  rl.draw_rectangle(40, params.top, W - 80, params.bottom - params.top, colors.panel)
  for(let local s in values(params.sections)){
    text_center(s.name, (s.from + s.to) / 2, params.top + 14, 10, colors.text)
    rl.draw_line(s.from + 6, params.top + 30, s.to - 6, params.top + 30, colors.line)
    if(s.to < 1150){
      rl.draw_line(s.to + 2, params.top + 10, s.to + 2, params.bottom - 10, colors.line)
    }
  }
  // the contours' headings, between the rows
  local rows = params.rows
  text_center("FILTER CONTOUR", 915, (rows[0] + rows[1]) / 2 + 2, 10, colors.dim)
  text_center("LOUDNESS CONTOUR", 915, (rows[1] + rows[2]) / 2 + 2, 10, colors.dim)
  for(local i = 0; i < params.count; i = i + 1){
    local c = params.list[i]
    local v = controls[i]
    if(c.kind == "knob"){
      draw_knob(c, v, caps)
    } else if(c.kind == "steps"){
      draw_steps(c, v, caps)
    } else if(c.kind == "switch"){
      draw_switch(c, v, caps)
    }
  }
  draw_strip()
}

// ------------------------------------------------------------ keys and wheels

local FIRST = 41          // F
local LAST = 84           // C, 44 keys
panel.KEYS_X = 160
panel.BED_Y = params.bottom + 66
panel.KEYS_Y = panel.BED_Y + 10
panel.WHITE_H = H - panel.KEYS_Y - 8
panel.BLACK_H = to_int(panel.WHITE_H * 0.62)
local is_black = {false, true, false, true, false, false, true, false, true, false, true, false}

// each key: {note, black, x, w} (x and w in window pixels)
panel.keys = {}
local func layout_keys(){
  local whites = 0
  for(local n = FIRST; n <= LAST; n = n + 1){
    if(not is_black[n % 12]){
      whites = whites + 1
    }
  }
  local white_w = (W - 48 - panel.KEYS_X) / whites
  panel.white_w = white_w
  local j = 0
  for(local n = FIRST; n <= LAST; n = n + 1){
    if(is_black[n % 12]){
      local bw = white_w * 0.6
      append(panel.keys, {note: n, black: true, x: panel.KEYS_X + j * white_w - bw / 2, w: bw})
    } else {
      append(panel.keys, {note: n, black: false, x: panel.KEYS_X + j * white_w, w: white_w})
      j = j + 1
    }
  }
}
layout_keys()

// the wheels: {param index, x}
panel.wheels = {
  {index: params.index.bend, x: 66, spring: true},
  {index: params.index.mod, x: 110, spring: false},
}
panel.WHEEL_Y = panel.BED_Y + 40
panel.WHEEL_H = 150
panel.WHEEL_W = 28

// the octave the computer keyboard plays from
panel.octave = 48

// ------------------------------------------------------------ input

local func clamp(v, lo, hi){
  if(v < lo){
    return lo
  }
  if(v > hi){
    return hi
  }
  return v
}

// the control at x, y of the face: its index, or null
func panel.control_at(x, y){
  for(local i = 0; i < params.count; i = i + 1){
    local c = params.list[i]
    if(c.kind == "knob" or c.kind == "steps"){
      local r = knob_radius(c) + 8.0
      local dx = x - c.x
      local dy = y - c.y
      if(dx * dx + dy * dy <= r * r){
        return i
      }
    } else if(c.kind == "switch"){
      if(x >= c.x - 14 and x <= c.x + 14 and y >= c.y - 19 and y <= c.y + 19){
        return i
      }
    }
  }
  return null
}

// what the mouse holds: {index, y, value} while a knob or wheel turns
local drag = null
local mouse_note = null
local last_click = {index: -1, time: -1.0}

// press(i, y): the mouse goes down on control i, at screen height y: a
// switch flips, a double click resets, anything else starts to turn
func panel.press(i, y){
  local c = params.list[i]
  local now = rl.get_time()
  if(last_click.index == i and now - last_click.time < 0.35 and c.kind != "switch"){
    controls[i] = c.default
  } else if(c.kind == "switch"){
    controls[i] = 1.0 - controls[i]
  } else {
    drag = {index: i, y: y, value: controls[i]}
  }
  last_click = {index: i, time: now}
}

// drag(y): the mouse, held down, is at screen height y: up turns right
func panel.drag(y){
  if(drag == null){
    return null
  }
  local c = params.list[drag.index]
  local dy = drag.y - y
  if(c.kind == "steps"){
    local n = len(c.labels)
    controls[drag.index] = clamp(math.floor(drag.value + dy / 28.0 + 0.5), 0, n - 1)
  } else {
    local scale = 1.0 / 200.0
    if(rl.is_key_down(rl.KEY_LEFT_SHIFT) or rl.is_key_down(rl.KEY_RIGHT_SHIFT)){
      scale = 1.0 / 1000.0
    }
    if(c.kind == "wheel"){
      scale = 1.0 / panel.WHEEL_H
    }
    controls[drag.index] = clamp(drag.value + dy * scale, 0.0, 1.0)
  }
}

// the control being turned, or null
func panel.dragging(){
  if(drag == null){
    return null
  }
  return drag.index
}

// press_key(n), slide_key(n): the mouse plays note n, or slides onto it
// (null: off the keys, the note stays)
func panel.press_key(n){
  mouse_note = n
  panel.note_on(n)
}

func panel.slide_key(n){
  if(mouse_note != null and n != null and n != mouse_note){
    panel.note_on(n)
    panel.note_off(mouse_note)
    mouse_note = n
  }
}

// release(): the mouse button goes up
func panel.release(){
  drag = null
  if(mouse_note != null){
    panel.note_off(mouse_note)
    mouse_note = null
  }
}

// scroll(i, w): the mouse wheel moves by w over control i
func panel.scroll(i, w){
  local c = params.list[i]
  if(c.kind == "steps"){
    controls[i] = clamp(controls[i] + w / math.abs(w), 0, len(c.labels) - 1)
  } else if(c.kind == "knob" or c.kind == "wheel"){
    controls[i] = clamp(controls[i] + w * 0.02, 0.0, 1.0)
  }
}

// spring(): the pitch wheel, let go, goes back to the middle
func panel.spring(){
  for(let local wh in values(panel.wheels)){
    if(wh.spring and (drag == null or drag.index != wh.index)){
      local v = controls[wh.index]
      if(v != 0.5){
        local nv = v + (0.5 - v) * 0.35
        if(math.abs(nv - 0.5) < 0.002){
          nv = 0.5
        }
        controls[wh.index] = nv
      }
    }
  }
}

// the computer keyboard: the semitone each key plays from the octave
local key_notes = {}
local lower = {"Z", "S", "X", "D", "C", "V", "G", "B", "H", "N", "J", "M", "COMMA", "L", "PERIOD", "SEMICOLON", "SLASH"}
local upper = {"Q", "TWO", "W", "THREE", "E", "R", "FIVE", "T", "SIX", "Y", "SEVEN", "U", "I", "NINE", "O", "ZERO", "P"}
for(local i = 0; i < len(lower); i = i + 1){
  append(key_notes, {key: rl[concat("KEY_", lower[i])], semis: i})
}
for(local i = 0; i < len(upper); i = i + 1){
  append(key_notes, {key: rl[concat("KEY_", upper[i])], semis: 12 + i})
}
// the note each key down plays (the octave may change while it is held)
local key_down = {}

// handle_keys(): notes from the computer keyboard, the octave, space
func panel.handle_keys(){
  for(let local k in values(key_notes)){
    if(rl.is_key_pressed(k.key) and key_down[k.key] == null){
      local n = panel.octave + k.semis
      key_down[k.key] = n
      panel.note_on(n)
    }
    if(rl.is_key_released(k.key) and key_down[k.key] != null){
      panel.note_off(key_down[k.key])
      key_down[k.key] = null
    }
  }
  if(rl.is_key_pressed(rl.KEY_LEFT) and panel.octave > 24){
    panel.octave = panel.octave - 12
  }
  if(rl.is_key_pressed(rl.KEY_RIGHT) and panel.octave < 84){
    panel.octave = panel.octave + 12
  }
  if(rl.is_key_pressed(rl.KEY_SPACE)){
    key_down = {}
    panel.all_off()
  }
  if(rl.is_key_pressed(rl.KEY_ENTER) or rl.is_key_pressed(rl.KEY_KP_ENTER)){
    if(panel.song_playing()){
      panel.stop_song()
    } else {
      panel.play_song()
    }
  }
  if(rl.is_key_pressed(rl.KEY_TAB)){
    panel.next_song()
  }
}

// ------------------------------------------------------------ running

// SYNTH_DEMO: a phrase played by itself, one {frame, note, frames held}
local demo = null
if(os.getenv("SYNTH_DEMO") != null){
  demo = {}
  local phrase = {36, 48, 43, 46, 48, 51, 50, 46, 36, 48, 55, 53, 51, 50, 46, 43}
  for(local i = 0; i < len(phrase); i = i + 1){
    append(demo, {at: 20 + i * 14, note: phrase[i], hold: 10})
  }
}

// demo(frame): with SYNTH_DEMO, the notes of this frame
func panel.demo(frame){
  if(demo == null){
    return null
  }
  for(let local d in values(demo)){
    if(d.at == frame){
      panel.note_on(d.note)
    } else if(d.at + d.hold == frame){
      panel.note_off(d.note)
    }
  }
}

// a song named on the command line plays at once, as does any with
// SYNTH_PLAY=1
panel.autoplay = len(args()) > 0 or os.getenv("SYNTH_PLAY") != null

// how a run ends: SYNTH_FRAMES=n quits after n frames (-1: never),
// SYNTH_SCREENSHOT=file.png saves the last one
panel.max_frames = -1
local frames_env = os.getenv("SYNTH_FRAMES")
if(frames_env != null){
  panel.max_frames = to_int(frames_env)
}
panel.screenshot = os.getenv("SYNTH_SCREENSHOT")

// finish(frame): after the loop: stops the sound, says how it went when
// the run was counted
func panel.finish(frame){
  local stats = panel.stop()
  if(panel.max_frames > 0){
    print("frames ", frame, ", DSP load ", stats.load, ", underruns ",
      stats.underruns, ", FPS ", to_int(frame / panel.seconds), "\n")
  }
}

// mark_start(), mark_end(): the time the frames took, for finish
func panel.mark_start(){
  panel.started = rl.get_time()
}

func panel.mark_end(){
  panel.seconds = rl.get_time() - panel.started
}

return panel
