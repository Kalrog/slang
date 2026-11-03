// What the 2D and the 3D synth share: the sound (engine.slang in
// raylib/stream's isolates), the bank and the patch being played and
// edited, the notes held, the computer keyboard, and how a run is
// measured and ends.
//
// app.start() starts the sound; the panels read the fields below and call
// its functions:
//   patch (edited in place; call changed() after), bank, choice (0..31),
//   edited, stats ({load, peak, underruns}), scope, voices, controls (the
//   engine's shared buffer), octave
//   choose(i), changed(), note_on(n, vel), note_off(n), held(n),
//   original(): the patch as the bank has it
//
// A MIDI controller (the midi package; MIDI_INPUT=name picks one, else
// every one is heard) plays notes in the engine itself, read every block;
// here, once a frame, its pitch bend and mod wheel (CC 1) move the wheels
// and the controllers bound by MIDI learn move their targets: F1 (or `)
// starts and ends learning, the panel arms a target when one of its
// controls is clicked (app.learn), the next controller to move is bound to
// it, BACKSPACE unbinds it. A panel names its targets (strings) and sets
// app.on_cc(target, value 0..127) to move them.
local rl = require("raylib")
local stream = require("raylib/stream")
local isolate = require("slang/isolate")
local buffer = require("slang/buffer")
local os = require("slang/os")
local patch = require("patch")
local engine = require("engine")

local SAMPLE_RATE = 48000

local controls = buffer.shared("double", engine.CONTROLS)
controls[engine.BEND] = 0
controls[engine.WHEEL] = 0
controls[engine.VOLUME] = 0.7
local events = isolate.channel()
local scope = buffer.shared("float", 2049)
local status = buffer.shared("double", 4)
// the notes the controller holds (the engine writes them)
local midi_keys = buffer.shared("uint8", 128)
local player = null

local bank = require("patches")
local app = {
  bank: bank,
  choice: 0,
  edited: false,
  stats: {load: 0.0, peak: 0.0, underruns: 0},
  scope: scope,
  voices: 0,
  controls: controls,
  octave: 48,
  learning: false,
  // the bindings (midi/map), when there is MIDI here
  map: null,
  // the pitch wheel springs back unless the controller holds it
  bend_from_midi: false,
  on_cc: func(target, value){},
}
local midi_ctl = null
// the notes held, by the mouse and the keyboard (a count each)
local held = {}
// an edit: the engine gets the patch once the frame ends
local dirty = false

// start(map_file, defaults?): the sound starts, on the patch FM_PATCH
// names (1..32) or the first; MIDI learn keeps its bindings in map_file
// (next to the program), which starts from defaults ({["channel:cc"]:
// target}) when it does not exist yet
func app.start(map_file, defaults){
  player = stream.play(func(controls, events, scope, rate, status, options){
    return require("engine").new(controls, events, scope, rate, status, options)
  }, {args: {controls, events, scope, SAMPLE_RATE, status, {midi: true, keys: midi_keys}}, sample_rate: SAMPLE_RATE, block: 64})
  local r = pcall(func(){
    return require("midi").open(os.getenv("MIDI_INPUT"))
  })
  if(r[0] == "ok"){
    midi_ctl = r[1]
    local path = require("slang/path").join(__PACKAGES.search_paths[0], map_file)
    local fresh = not os.exists(path)
    app.map = require("midi/map").load(path)
    if(fresh and defaults != null){
      app.map.bindings = defaults
    }
  }
  local start = os.getenv("FM_PATCH")
  if(start != null){
    app.choose(to_int(start) - 1)
  } else {
    app.choose(0)
  }
}

func app.choose(i){
  app.choice = i
  app.patch = patch.copy(bank[i])
  app.edited = false
  events:send({patch: app.patch})
}

func app.original(){
  return bank[app.choice]
}

func app.changed(){
  app.edited = true
  dirty = true
}

func app.note_on(n, vel){
  held[n] = (held[n] or 0) + 1
  events:send({on: n, vel: vel})
}

func app.note_off(n){
  local c = held[n] or 0
  if(c <= 1){
    held[n] = null
  } else {
    held[n] = c - 1
  }
  events:send({off: n})
}

func app.held(n){
  return held[n] != null or midi_keys[n] > 0
}

// learn(target): in learning, the panel's click on a control: the next
// controller to move is bound to it
func app.learn(target){
  if(app.map != null){
    app.map:arm(target)
  }
}

// binding(target) -> "CC 74" or null, armed(target) -> bool: for drawing
func app.binding(target){
  if(app.map == null){
    return null
  }
  return app.map:binding(target)
}

func app.armed(target){
  return app.map != null and app.map.armed == target
}

// cc_value(field, value) -> a controller's 0..127 in a field's range
func app.cc_value(f, value){
  return to_int(f.min + require("slang/math").floor(value / 127 * (f.max - f.min) + 0.5))
}

local func handle_midi(){
  if(midi_ctl == null){
    return null
  }
  for(let local m in values(midi_ctl:read())){
    if(m.kind == "bend"){
      controls[engine.BEND] = m.value
      app.bend_from_midi = true
    } else if(m.kind == "cc" and m.controller == 1){
      controls[engine.WHEEL] = m.value / 127
    } else if(m.kind == "cc" and m.controller != 64){
      local target = app.map:target(m)
      if(target != null){
        app.on_cc(target, m.value)
      }
    }
  }
}

// ------------------------------------------------------------ the keyboard

local key_notes = {}
local lower = {"Z", "S", "X", "D", "C", "V", "G", "B", "H", "N", "J", "M", "COMMA", "L", "PERIOD", "SEMICOLON", "SLASH"}
local upper = {"Q", "TWO", "W", "THREE", "E", "R", "FIVE", "T", "SIX", "Y", "SEVEN", "U", "I", "NINE", "O", "ZERO", "P"}
for(local i = 0; i < len(lower); i = i + 1){
  append(key_notes, {key: rl[concat("KEY_", lower[i])], semis: i})
}
for(local i = 0; i < len(upper); i = i + 1){
  append(key_notes, {key: rl[concat("KEY_", upper[i])], semis: 12 + i})
}
local key_down = {}

// handle_keys(): notes, octave, patch, sustain, all notes off
func app.handle_keys(){
  for(let local k in values(key_notes)){
    if(rl.is_key_pressed(k.key) and key_down[k.key] == null){
      local n = app.octave + k.semis
      key_down[k.key] = n
      app.note_on(n, 100)
    }
    if(rl.is_key_released(k.key) and key_down[k.key] != null){
      app.note_off(key_down[k.key])
      key_down[k.key] = null
    }
  }
  if(rl.is_key_pressed(rl.KEY_LEFT) and app.octave > 24){
    app.octave = app.octave - 12
  }
  if(rl.is_key_pressed(rl.KEY_RIGHT) and app.octave < 84){
    app.octave = app.octave + 12
  }
  if(rl.is_key_pressed(rl.KEY_UP)){
    app.choose((app.choice + 1) % len(bank))
  }
  if(rl.is_key_pressed(rl.KEY_DOWN)){
    app.choose((app.choice + len(bank) - 1) % len(bank))
  }
  if(rl.is_key_pressed(rl.KEY_TAB)){
    events:send({sustain: true})
  }
  if(rl.is_key_released(rl.KEY_TAB)){
    events:send({sustain: false})
  }
  if((rl.is_key_pressed(rl.KEY_F1) or rl.is_key_pressed(rl.KEY_GRAVE)) and app.map != null){
    app.learning = not app.learning
    app.map:arm(null)
  }
  if(rl.is_key_pressed(rl.KEY_BACKSPACE) and app.learning and app.map.armed != null){
    app.map:clear(app.map.armed)
    app.map:arm(null)
  }
  if(rl.is_key_pressed(rl.KEY_SPACE)){
    key_down = {}
    held = {}
    events:send({panic: true})
  }
}

// ------------------------------------------------------------ running

// FM_DEMO: chords by themselves, {frame, notes, frames held}
local demo = null
if(os.getenv("FM_DEMO") != null){
  demo = {}
  local chords = {{48, 55, 64, 71}, {45, 52, 60, 67}, {50, 57, 65, 72}, {43, 55, 62, 71}}
  for(local i = 0; i < 8; i = i + 1){
    append(demo, {at: 20 + i * 45, notes: chords[i % 4], hold: 36})
  }
}

local stats_at = -1.0
local started = 0.0

// how a run ends: FM_FRAMES=n quits after n frames (-1: never),
// FM_SCREENSHOT=file.png saves the last one
app.max_frames = -1
if(os.getenv("FM_FRAMES") != null){
  app.max_frames = to_int(os.getenv("FM_FRAMES"))
}
app.screenshot = os.getenv("FM_SCREENSHOT")

func app.mark_start(){
  started = rl.get_time()
}

// update(frame): once a frame, before drawing: the demo's notes, the
// patch to the engine after an edit, the stream's numbers
func app.update(frame){
  if(demo != null){
    for(let local d in values(demo)){
      if(d.at == frame){
        for(let local n in values(d.notes)){
          app.note_on(n, 90)
        }
      } else if(d.at + d.hold == frame){
        for(let local n in values(d.notes)){
          app.note_off(n)
        }
      }
    }
  }
  handle_midi()
  if(dirty){
    events:send({patch: app.patch})
    dirty = false
  }
  local now = rl.get_time()
  if(now - stats_at > 0.5){
    stats_at = now
    app.stats = player:stats()
  }
  app.voices = to_int(status[0])
}

// end_frame(frame): after drawing (frame counted from 1): the screenshot
func app.end_frame(frame){
  if(app.screenshot != null and frame == app.max_frames){
    rl.take_screenshot(app.screenshot)
  }
}

// finish(frame): the sound stops; a counted run says how it went
func app.finish(frame){
  local seconds = rl.get_time() - started
  local stats = player:stats()
  player:stop()
  if(app.max_frames > 0){
    print("frames ", frame, ", DSP load ", stats.load, ", underruns ", stats.underruns, ", FPS ", to_int(frame / seconds), "\n")
  }
}

return app
