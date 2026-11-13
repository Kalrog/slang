// granular: a granular synthesizer that plays what the microphone heard.
// Record a few seconds (R), then play it from the keyboard: every key held
// is a voice that scatters short grains of the recording, each at its own
// place, pitch, direction and pan. In live mode (L) the grains come from
// the last six seconds the microphone heard, as it hears them.
//
//   make granular       (or: cd examples/granular && slang run main.slang)
//   slang run main.slang some.wav       start from a WAV file
//
// Keys (by position): A W S E D F T G Y H U J K play an octave (A plays the
// sound at its own pitch in octave 4), Z / X move it down / up, space holds
// the notes (again: lets them go), R starts and stops recording, P plays
// the whole recording as it is (again: stops), L switches live mode, Q
// freezes (live mode stops listening, scan stands still), 1-8 morph to a
// snapshot of the knobs and shift+1-8 store one (takes/snapshots.json).
// Two LFOs move a knob each; a green mark on a slider is where the sound
// has it. A click on the waveform sets the position, the sliders turn
// with the mouse, a WAV file dropped on the window is loaded. MIDI notes
// play too, and knobs on CC 70-77 turn position, size, density, spray,
// pitch, detune, scan and mix.
//
// The take is kept in takes/last.wav and loaded at the next start.
// GRANULAR_DEVICE=name picks the microphone (part of its name),
// GRANULAR_MIC=0 opens none; GRANULAR_FRAMES=n quits after n frames,
// GRANULAR_SCREENSHOT=file.png saves the last, GRANULAR_NOTE=1 holds a
// note, GRANULAR_PLAY=1 plays the recording, GRANULAR_LIVE=1 starts in
// live mode (for smoke tests).
extension "kernel/syntax"
local rl = require("raylib")
local os = require("slang/os")
local path = require("slang/path")
local math = require("slang/math")
local isolate = require("slang/isolate")
local kernel = require("kernel")
local stream = require("raylib/stream")
local engine = require("engine")
local sample = require("sample")
local snapshots = require("snapshots")

local W = 1100
local H = 770
local RATE = engine.RATE
local c = engine.cells

local C = {
  back: {18, 19, 24},
  panel: {28, 30, 38},
  line: {48, 52, 66},
  text: {218, 222, 232},
  dim: {124, 130, 150},
  wave: {104, 150, 210},
  wave_dim: {58, 80, 112},
  grain: {255, 196, 96},
  accent: {255, 168, 64},
  rec: {240, 72, 72},
  live: {96, 220, 160},
  key: {226, 228, 236},
  key_dark: {40, 42, 52},
}

// ------------------------------------------------------------ the sound

local shared = engine.shared()
local messages = isolate.channel()
local use_mic = os.getenv("GRANULAR_MIC") != "0"
local player = stream.play(
  func(shared, device, use_mic, messages){
    return require("engine").new(shared, {
      device: device,
      mic: use_mic,
      report: func(m){
        messages:send(m)
      },
    })
  },
  {
    args: {shared, os.getenv("GRANULAR_DEVICE"), use_mic, messages},
    sample_rate: RATE,
    channels: 2,
    block: 128,
  },
)
local ctl = shared.ctl

// where the sound came from, for the header
local source = "demo sample"
local status = ""
local mic_name = if(use_mic){ "opening the microphone..." } else { "no microphone (GRANULAR_MIC=0)" }

local func load(file){
  local n = try { sample.load(file, shared.sample) } catch(e) { string(e) }
  if(type(n) == "string"){
    status = n
    return false
  }
  if(n > 0){
    ctl[c.LENGTH] = n
    source = path.base(file)
    status = concat(
      "loaded ", source, ", ", string(math.round(n / RATE * 10) / 10), " s"
    )
  }
  return n > 0
}

local TAKE = "takes/last.wav"
local loaded = false
if(len(args()) > 0){
  loaded = load(args()[0])
}
if(not loaded and os.exists(TAKE)){
  loaded = load(TAKE)
  source = "your last take"
}
if(not loaded){
  ctl[c.LENGTH] = sample.demo(shared.sample)
}

local recording = false

local func toggle_record(){
  if(ctl[c.RECORD] > 0.0){
    ctl[c.RECORD] = 0.0
  } else if(ctl[c.MIC] > 0.0){
    ctl[c.PLAY] = 0.0
    ctl[c.RECORD] = 1.0
    recording = true
    status = "recording: R again to stop"
  } else {
    status = "there is no microphone to record from"
  }
}

// P: the whole recording once, as it was recorded (again: stop)
local func toggle_play(){
  if(ctl[c.PLAY] > 0.0){
    ctl[c.PLAY] = 0.0
  } else if(ctl[c.RECORD] == 0.0 and ctl[c.LENGTH] > 0.0){
    ctl[c.PLAYPOS] = 0.0
    ctl[c.PLAY] = 1.0
  }
}

// the engine stops recording itself when the buffer is full: either way
// the take is saved once it ends
local func check_record(){
  if(recording and ctl[c.RECORD] == 0.0){
    recording = false
    local n = to_int(ctl[c.LENGTH])
    os.mkdir_all("takes")
    sample.save(TAKE, shared.sample, n)
    source = "your take"
    status = concat(
      "recorded ", string(math.round(n / RATE * 10) / 10), " s, saved to ", TAKE
    )
  }
}

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
local hold = false
// per voice slot: the note it plays (null: free), whether its key is
// down, and when it started (the oldest is taken when all are busy)
local slots = {}
for(local v = 0; v < engine.NV; v = v + 1){
  append(slots, {note: null, down: false, at: 0})
}
local serial = 0

local func midi_of(semitone){
  return (octave + 1) * 12 + semitone
}

local func note_on(note, velocity){
  serial = serial + 1
  local best = null
  for(local v = 0; v < engine.NV; v = v + 1){
    local s = slots[v]
    if(s.note == note){
      best = v
      break
    }
    if(best == null or (s.note == null and slots[best].note != null) or
      ((s.note == null) == (slots[best].note == null) and s.at < slots[best].at)){
      best = v
    }
  }
  local s = slots[best]
  s.note = note
  s.down = true
  s.at = serial
  shared.keys[best * 4] = note
  shared.keys[best * 4 + 1] = 1.0
  shared.keys[best * 4 + 2] = velocity
  shared.keys[best * 4 + 3] = serial
}

local func release(v){
  slots[v].note = null
  shared.keys[v * 4 + 1] = 0.0
}

local func note_off(note){
  for(local v = 0; v < engine.NV; v = v + 1){
    if(slots[v].note == note and slots[v].down){
      slots[v].down = false
      if(not hold){
        release(v)
      }
    }
  }
}

local func toggle_hold(){
  hold = not hold
  if(not hold){
    for(local v = 0; v < engine.NV; v = v + 1){
      if(slots[v].note != null and not slots[v].down){
        release(v)
      }
    }
  }
}

local func sounding(note){
  for(let local s in values(slots)){
    if(s.note == note){
      return true
    }
  }
  return false
}

// MIDI where there is some: notes, and the MPK mini's eight knobs
local midi_in = null
local CC_KNOBS = {
  "position", "size", "density", "spray", "pitch", "detune", "scan", "mix"
}
// (a controller is optional: when CoreMIDI does not start, there is none)
local func open_midi(){
  local midi = require("midi")
  if(midi.available() and len(midi.inputs()) > 0){
    return midi.open()
  }
  return null
}
midi_in = try { open_midi() } catch { null }

// ------------------------------------------------------------ knobs

// slider position (0..1) and value, through the knob's curve
local value_of = engine.value_of
local t_of = engine.t_of

// the snapshots, kept in takes/snapshots.json
local SNAPS = "takes/snapshots.json"
local snaps = snapshots.new(ctl)
ctl[c.GLIDE] = 2.0
snaps:load(SNAPS)

local GLIDE_KNOB = {
  name: "glide", cell: c.GLIDE, min: 0.0, max: 10.0, init: 2.0, unit: "s",
  curve: 2.0
}
local MORPH_KNOB = {
  name: "morph",
  cell: c.MORPH,
  min: 0.0,
  max: 1.0,
  init: 0.0,
  unit: "",
  set: func(v){
    snaps:morph(v)
  },
}

local func store(slot){
  snaps:store(slot)
  os.mkdir_all("takes")
  snaps:save(SNAPS)
  status = concat("stored snapshot ", string(slot), " (", SNAPS, ")")
}

local func recall(slot){
  if(snaps:recall(slot)){
    status = concat("snapshot ", string(slot))
  } else {
    status = concat(
      "snapshot ", string(slot), " is empty: shift+", string(slot),
      " stores one"
    )
  }
}

// the knob at cell was set by hand
local func set_knob(k, v){
  ctl[k.cell] = v
  snaps:touch(k.cell)
}

local func shown(k, v){
  if(k.unit == "ms"){
    return concat(string(to_int(math.round(v))), " ms")
  }
  local r = math.round(v * 100) / 100
  if(k.unit == "" or k.unit == null){
    return string(r)
  }
  return concat(string(r), " ", k.unit)
}

local drag = null

local func slider(k, x, y, w){
  local v = ctl[k.cell]
  local t = t_of(k, v)
  local bar_y = y + 16
  rl.draw.text(k.name, x, y, 10, C.dim)
  local label = shown(k, v)
  rl.draw.text(label, x + w - rl.text.measure(label, 10), y, 10, C.text)
  rl.draw.rectangle(x, bar_y, w, 6, C.line)
  if(k.bipolar){
    // filled from the middle
    local mid = t_of(k, 0.0)
    local a = math.min(mid, t)
    rl.draw.rectangle(
      x + to_int(w * a), bar_y, to_int(w * (math.max(mid, t) - a)), 6, C.accent
    )
  } else {
    rl.draw.rectangle(x, bar_y, to_int(w * t), 6, C.accent)
  }
  // where the sound has it, when an LFO moves it (or it is gliding there)
  if(k.cell < len(engine.knobs)){
    local te = t_of(k, ctl[c.EFF + k.cell])
    if(math.abs(te - t) > 0.004){
      rl.draw.rectangle(x + to_int(w * te) - 1, bar_y - 2, 3, 10, C.live)
    }
  }
  rl.draw.rectangle(x + to_int(w * t) - 2, bar_y - 3, 5, 12, C.text)
  local m = rl.mouse.position
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT) and m.x >= x - 4 and
    m.x <= x + w + 4 and m.y >= bar_y - 6 and m.y <= bar_y + 12){
    drag = {knob: k, x: x, w: w}
  }
}

local func update_drag(){
  if(drag == null){
    return null
  }
  if(not rl.mouse.down(rl.MOUSE_BUTTON_LEFT)){
    drag = null
    return null
  }
  local t = math.clamp((rl.mouse.position.x - drag.x) / drag.w, 0.0, 1.0)
  if(drag.wave){
    set_knob(engine.knob.position, t)
    ctl[c.RESET] = 1.0
  } else if(drag.knob.set != null){
    drag.knob.set(value_of(drag.knob, t))
  } else {
    set_knob(drag.knob, value_of(drag.knob, t))
  }
}

local GROUPS = {
  {"GRAIN", {"size", "density", "spray", "skew"}},
  {"PITCH", {"pitch", "detune", "reverse", "stereo"}},
  {"MOTION", {"position", "scan", "attack", "release"}},
  {"SPACE", {"cutoff", "delay", "feedback", "mix", "gain"}},
}

local func draw_knobs(){
  local x = 24
  local y = 330
  local w = 236
  for(let local g in values(GROUPS)){
    rl.draw.text(g[0], x, y, 10, C.accent)
    local yy = y + 18
    for(let local name in values(g[1])){
      slider(engine.knob[name], x, yy, w)
      yy = yy + 30
    }
    x = x + w + 30
  }
}

// ------------------------------------------------------------ the waveform

local WX = 16
local WY = 64
local WW = W - 32
local WH = 240
local cols = kernel.float:array(WW * 2)
local seen = {length: -1, mode: -1, loudest: 1.0}

// a choice: click for the next, right click (or the wheel) to go back
local func choice(label, cell, options, x, y, w){
  local at = 0
  for(local i = 0; i < len(options); i = i + 1){
    if(options[i][0] == ctl[cell]){
      at = i
    }
  }
  rl.draw.text(label, x, y + 3, 10, C.dim)
  local bx = x + rl.text.measure(label, 10) + 8
  local bw = x + w - bx
  rl.draw.rectangle(bx, y, bw, 16, C.line)
  rl.draw.text(options[at][1], bx + 6, y + 3, 10, C.text)
  rl.draw.text(">", bx + bw - 12, y + 3, 10, C.dim)
  local m = rl.mouse.position
  if(m.x >= bx and m.x < bx + bw and m.y >= y and m.y < y + 16){
    local step = 0
    if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)){
      step = 1
    } else if(rl.mouse.pressed(rl.MOUSE_BUTTON_RIGHT)){
      step = -1
    } else if(rl.mouse.wheel > 0.5){
      step = -1
    } else if(rl.mouse.wheel < -0.5){
      step = 1
    }
    if(step != 0){
      ctl[cell] = options[(at + step + len(options)) % len(options)][0]
      snaps:touch(cell)
    }
  }
}

local SHAPE_OPTIONS = {}
for(local i = 0; i < len(engine.SHAPES); i = i + 1){
  append(SHAPE_OPTIONS, {i, engine.SHAPES[i]})
}
local DEST_OPTIONS = {{-1, "nothing"}}
for(let local k in values(engine.knobs)){
  append(DEST_OPTIONS, {k.cell, k.name})
}

local func draw_lfo(o, i, x, y, w){
  rl.draw.text(concat("LFO ", string(i + 1)), x, y, 10, C.accent)
  // where it is now
  local lx = x + 50
  local lw = w - 50
  rl.draw.rectangle(lx, y + 4, lw, 2, C.line)
  local v = ctl[o.out]
  local on = ctl[o.depth.cell] != 0.0 and ctl[o.dest] >= 0
  rl.draw.circle(
    lx + to_int((v + 1) * 0.5 * lw),
    y + 5,
    4.0,
    if(on){ C.live } else { C.dim },
  )
  choice("shape", o.shape, SHAPE_OPTIONS, x, y + 18, w / 2 - 8)
  choice("moves", o.dest, DEST_OPTIONS, x + w / 2 + 8, y + 18, w / 2 - 8)
  slider(o.rate, x, y + 42, w)
  slider(o.depth, x, y + 72, w)
}

local func draw_snapshots(x, y, w){
  rl.draw.text("SNAPSHOTS", x, y, 10, C.accent)
  rl.draw.text(
    "1-8 morphs to one, shift+1-8 stores (or click, shift+click)", x + 90, y,
    10, C.dim
  )
  local gap = 8
  local bw = to_int((w - gap * (snapshots.SLOTS - 1)) / snapshots.SLOTS)
  local m = rl.mouse.position
  local shift = rl.key.down(rl.KEY_LEFT_SHIFT) or
    rl.key.down(rl.KEY_RIGHT_SHIFT)
  for(local i = 1; i <= snapshots.SLOTS; i = i + 1){
    local bx = x + (i - 1) * (bw + gap)
    local by = y + 18
    local here = snaps.current == i
    local color = C.line
    if(here){
      color = C.accent
    } else if(snaps:has(i)){
      color = C.wave_dim
    }
    rl.draw.rectangle(bx, by, bw, 26, color)
    rl.draw.text(
      string(
        i,
      ),
      bx + bw / 2 - 3,
      by + 8,
      10,
      if(here){ C.back } else if(snaps:has(
        i,
      )){ C.text } else { C.dim },
    )
    if(here and snaps.gliding){
      // how far the glide is
      rl.draw.rectangle(bx, by + 22, to_int(bw * ctl[c.MORPH]), 4, C.text)
    }
    if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT) and m.x >= bx and
      m.x < bx + bw and m.y >= by and m.y < by + 26){
      if(shift){
        store(i)
      } else {
        recall(i)
      }
    }
  }
  local half = to_int((w - 30) / 2)
  slider(MORPH_KNOB, x, y + 54, half)
  slider(GLIDE_KNOB, x + half + 30, y + 54, half)
}

local func draw_panels(){
  local y = 516
  local w = 236
  draw_lfo(engine.lfos[0], 0, 24, y, w)
  draw_lfo(engine.lfos[1], 1, 24 + w + 30, y, w)
  draw_snapshots(24 + (w + 30) * 2, y, w * 2 + 30)
}

local func draw_wave(){
  local live = ctl[c.MODE] > 0.0
  local length = to_int(ctl[c.LENGTH])
  local shown_len = length
  local start = 0
  local ring = engine.MAXS
  local src = shared.sample
  if(live){
    local head = to_int(ctl[c.LIVEHEAD])
    shown_len = engine.LIVE
    start = head - engine.LIVE
    ring = engine.LIVE
    src = shared.live
  } else if(ctl[c.RECORD] > 0.0){
    // a take as it grows: ten seconds wide, wider when it gets longer
    shown_len = math.max(length, 10 * RATE)
  }
  rl.draw.rectangle(WX, WY, WW, WH, C.panel)
  local mid = WY + WH / 2
  // the waveform: recomputed when it may have changed
  if(live or ctl[c.RECORD] > 0.0 or seen.length != length or
    seen.mode != ctl[c.MODE]){
    seen.length = length
    seen.mode = ctl[c.MODE]
    if(live){
      // before the ring is full, its older part is silence
      engine.peaks(src, start + engine.LIVE * 4, shown_len, ring, WW, cols)
    } else if(length > 0){
      engine.peaks(src, 0, shown_len, ring, WW, cols)
    } else {
      cols:fill(0.0)
    }
    // quiet sound is drawn larger, up to 4 times
    seen.loudest = 0.25
    for(local i = 0; i < WW * 2; i = i + 1){
      seen.loudest = math.max(seen.loudest, math.abs(cols[i]))
    }
  }
  local scale = WH * 0.45 / seen.loudest
  for(local i = 0; i < WW; i = i + 1){
    local lo = cols[i * 2]
    local hi = cols[i * 2 + 1]
    rl.draw.line(
      WX + i, to_int(mid - hi * scale), WX + i, to_int(mid - lo * scale) + 1,
      C.wave_dim
    )
  }
  // where grains start: the position (moved by scan) and the spray around it
  local frac = 1.0
  if(not live and shown_len > 0){
    frac = length / shown_len
  }
  // where the sound has them (an LFO may move them)
  local pos = ctl[c.EFF + engine.knob.position.cell]
  if(not live){
    pos = (pos + ctl[c.SCANPOS]) % 1.0
  }
  local px = WX + to_int(pos * frac * WW)
  local spray = ctl[c.EFF + engine.knob.spray.cell] * 0.5 * RATE
  local sw = 0
  if(shown_len > 0){
    sw = to_int(spray / shown_len * WW)
  }
  rl.draw.rectangle(px - sw, WY, sw * 2 + 1, WH, {255, 168, 64, 28})
  rl.draw.line(px, WY, px, WY + WH, C.accent)
  // the playhead, while P plays the recording
  if(not live and ctl[c.PLAY] > 0.0 and shown_len > 0){
    local hx = WX + to_int(ctl[c.PLAYPOS] / shown_len * WW)
    rl.draw.line(hx, WY, hx, WY + WH, C.text)
  }
  // the grains, scattered over the height so a cloud of them shows
  local view = shared.view
  for(local s = 0; s < engine.MAXG; s = s + 1){
    local a = view[s * 2 + 1]
    if(a > 0.002){
      local x = WX + to_int(view[s * 2] * frac * WW)
      if(x >= WX and x < WX + WW){
        local y = WY + 18 + ((s * 53) % 97) / 97.0 * (WH - 36)
        local alpha = to_int(math.clamp(a * 400, 40, 255))
        rl.draw.line(x, mid - 6, x, mid + 6, {255, 196, 96, alpha / 3})
        rl.draw.circle(x, to_int(y), 2.0 + a * 6.0, {255, 196, 96, alpha})
      }
    }
  }
  // labels
  local secs = math.round(length / RATE * 10) / 10
  local label = concat(source, "  ", string(secs), " s")
  local color = C.dim
  if(live){
    label = "LIVE  the last six seconds the microphone heard, now at the right"
    color = C.live
    if(ctl[c.FREEZE] > 0.0){
      label = "LIVE, FROZEN  the six seconds before Q (Q again: listen on)"
      color = C.grain
    }
  } else if(ctl[c.FREEZE] > 0.0 and ctl[c.RECORD] == 0.0){
    label = concat(label, "   FROZEN: scan stands still (Q)")
  } else if(ctl[c.RECORD] > 0.0){
    label = concat("RECORDING  ", string(secs), " s  (R to stop)")
    color = C.rec
    local rx = WX + to_int(length / shown_len * WW)
    rl.draw.line(rx, WY, rx, WY + WH, C.rec)
  }
  rl.draw.text(label, WX + 8, WY + 6, 10, color)
  // a click on the waveform moves the position
  local m = rl.mouse.position
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT) and m.x >= WX and m.x < WX + WW and
    m.y >= WY and m.y < WY + WH){
    drag = {wave: true, x: WX, w: to_int(WW * frac)}
  }
}

// ------------------------------------------------------------ header

local meters = {input: 0.0, left: 0.0, right: 0.0}
local stats = {load: 0.0, underruns: 0}

local func meter(x, y, w, v, color){
  rl.draw.rectangle(x, y, w, 6, C.line)
  rl.draw.rectangle(x, y, to_int(w * math.clamp(v, 0.0, 1.0)), 6, color)
}

local func draw_header(){
  rl.draw.text("granular", 16, 14, 24, C.accent)
  rl.draw.text(
    "grains of what the microphone heard, on kernels", 130, 24, 10, C.dim
  )
  // decaying meters: the engine keeps the peaks until we take them
  meters.input = math.max(meters.input * 0.9, ctl[c.LEVEL])
  meters.left = math.max(meters.left * 0.9, ctl[c.PEAKL])
  meters.right = math.max(meters.right * 0.9, ctl[c.PEAKR])
  ctl[c.LEVEL] = 0.0
  ctl[c.PEAKL] = 0.0
  ctl[c.PEAKR] = 0.0
  local x = W - 430
  local mic_color = if(ctl[c.MIC] > 0.0){ C.text } else { C.rec }
  rl.draw.text(concat("MIC  ", mic_name), x, 14, 10, mic_color)
  meter(
    x, 30, 180, meters.input, if(ctl[c.RECORD] > 0.0){ C.rec } else { C.live }
  )
  rl.draw.text("OUT", x + 220, 14, 10, C.dim)
  meter(x + 220, 30, 180, meters.left, C.wave)
  meter(x + 220, 40, 180, meters.right, C.wave)
  if(ctl[c.RECORD] > 0.0 and to_int(rl.time * 2) % 2 == 0){
    rl.draw.circle(x - 16, 33, 6.0, C.rec)
  }
}

// ------------------------------------------------------------ keyboard

local func draw_keyboard(){
  local x0 = 24
  local y = 632
  local kw = 52
  for(let local pass in values({false, true})){
    local white = 0
    for(let local k in values(KEYS)){
      local semitone = k[1]
      local m = semitone % 12
      local black = m == 1 or m == 3 or m == 6 or m == 8 or m == 10
      local note = midi_of(semitone)
      if(black == pass){
        if(black){
          local x = x0 + white * kw - 16
          rl.draw.rectangle(
            x, y, 32, 64, if(sounding(note)){ C.accent } else { C.key_dark }
          )
          rl.draw.text(k[2], x + 12, y + 48, 10, C.dim)
        } else {
          local x = x0 + white * kw
          rl.draw.rectangle(
            x, y, kw - 2, 110, if(sounding(note)){ C.accent } else { C.key }
          )
          rl.draw.text(k[2], x + 20, y + 78, 10, C.key_dark)
          rl.draw.text(
            concat(NAMES[m], string(octave + to_int(semitone / 12))), x + 16,
            y + 92, 10, C.dim
          )
        }
      }
      if(not black){
        white = white + 1
      }
    }
  }
  local tx = x0 + 8 * kw + 28
  local lines = {
    concat(
      "octave ", string(octave),
      "  (Z / X)     A is the sound at its own pitch in octave 4"
    ),
    concat(
      "space  hold ",
      if(hold){ "ON" } else { "off" },
      "     R  record     P  play it     L  live ",
      if(ctl[c.MODE] > 0.0){ "ON" } else { "off" },
      "     Q  freeze ",
      if(ctl[c.FREEZE] > 0.0){ "ON" } else { "off" },
    ),
    "click the waveform to set the position; drop a WAV file to load it",
    concat(
      "grains ",
      string(to_int(ctl[c.GRAINS])),
      "     load ",
      string(math.round(stats.load * 1000) / 10),
      "% of real time",
      if(stats.underruns > 0){ concat(
        "     underruns ",
        string(stats.underruns),
      ) } else { "" },
      if(midi_in != null){ "     MIDI in" } else { "" },
    ),
  }
  for(local i = 0; i < len(lines); i = i + 1){
    rl.draw.text(lines[i], tx, y + 4 + i * 20, 10, C.dim)
  }
  rl.draw.text(status, tx, y + 92, 10, C.text)
}

// ------------------------------------------------------------ the loop

rl.window.open(W, H, "granular")
rl.target_fps = 60
local max_frames = null
if(os.getenv("GRANULAR_FRAMES") != null){
  max_frames = to_int(os.getenv("GRANULAR_FRAMES"))
}
local screenshot = os.getenv("GRANULAR_SCREENSHOT")
if(os.getenv("GRANULAR_NOTE") != null){
  note_on(midi_of(0), 1.0)
}
if(os.getenv("GRANULAR_PLAY") != null){
  toggle_play()
}
if(os.getenv("GRANULAR_LIVE") == "1"){
  ctl[c.MODE] = 1.0
}
local frame = 0
local stats_at = 0.0
local last_time = 0.0
for(not rl.window.should_close){
  frame = frame + 1
  // what the render isolate says about the microphone
  for(true){
    local m = messages:try_receive()
    if(m == null){
      break
    }
    if(m.error != null){
      mic_name = "none"
      status = m.error
    } else {
      mic_name = m.name
    }
  }
  for(let local k in values(KEYS)){
    if(rl.key.pressed(k[0])){
      note_on(midi_of(k[1]), 0.9)
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
  if(rl.key.pressed(rl.KEY_SPACE)){
    toggle_hold()
  }
  if(rl.key.pressed(rl.KEY_R)){
    toggle_record()
  }
  if(rl.key.pressed(rl.KEY_P)){
    toggle_play()
  }
  if(rl.key.pressed(rl.KEY_Q)){
    ctl[c.FREEZE] = if(ctl[c.FREEZE] > 0.0){ 0.0 } else { 1.0 }
  }
  local shift = rl.key.down(rl.KEY_LEFT_SHIFT) or
    rl.key.down(rl.KEY_RIGHT_SHIFT)
  for(local i = 1; i <= snapshots.SLOTS; i = i + 1){
    if(rl.key.pressed(rl.KEY_ONE + i - 1)){
      if(shift){
        store(i)
      } else {
        recall(i)
      }
    }
  }
  snaps:step(rl.time - last_time)
  last_time = rl.time
  if(rl.key.pressed(rl.KEY_L)){
    ctl[c.MODE] = if(ctl[c.MODE] > 0.0){ 0.0 } else { 1.0 }
  }
  if(midi_in != null){
    for(let local m in values(midi_in:read())){
      if(m.kind == "note_on"){
        note_on(m.note, m.velocity / 127)
      } else if(m.kind == "note_off"){
        note_off(m.note)
      } else if(m.kind == "cc" and m.controller >= 70 and m.controller < 78){
        local k = engine.knob[CC_KNOBS[m.controller - 70]]
        set_knob(k, value_of(k, m.value / 127))
      }
    }
  }
  if(rl.file_dropped){
    local files = rl.load_dropped_files()
    if(len(files) > 0 and ctl[c.RECORD] == 0.0){
      load(files[0])
    }
  }
  check_record()
  update_drag()
  if(rl.time - stats_at > 0.5){
    stats_at = rl.time
    stats = player:stats()
  }
  rl.drawing{
    rl.draw.clear(C.back)
    draw_header()
    draw_wave()
    draw_knobs()
    draw_panels()
    draw_keyboard()
  }
  if(max_frames != null and frame >= max_frames){
    if(screenshot != null){
      rl.window.screenshot(screenshot)
    }
    break
  }
}
if(ctl[c.RECORD] > 0.0){
  // the take so far
  ctl[c.RECORD] = 0.0
  check_record()
}
local last = player:stats()
player:stop()
if(midi_in != null){
  midi_in:close()
}
rl.window.close()
print(concat(
  "frames ", string(frame), ", load ", string(last.load), ", underruns ",
  string(last.underruns), "\n"
))
