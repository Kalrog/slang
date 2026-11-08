// A modular synthesizer in pixel art: a rack of modules (oscillators,
// filters, envelopes, sequencers, drums, delay, a clock with a song
// chain) patched with cables, sounding through one kernel (engine.slang)
// in the render isolate of raylib/stream, drawn with raylib into a
// 640 x 360 screen scaled up by whole pixels.
//
//   make modular        (or: cd examples/modular && slang run main.slang)
//   slang run main.slang patches/first_song.json
//
// Drag from a jack to a jack to patch; drag a knob up and down (shift:
// finely), wheel over it, double click to reset. SPACE runs the clock,
// 1-8 pick the pattern, A opens the menu of modules, DEL removes the one
// under the mouse, TAB loads the next patch of patches/, F2 saves, F3
// renders the song to a WAV, F4 empties the rack, F5 and F6 copy and
// paste the sequencers' pattern. Z S X D C V G B H N J M , L . ; / play
// notes (< and > shift the octave) through the KBD module. E (or a click
// on its face) opens an FM module's editor page: its patch, cell by cell,
// and the bank of presets.
//
// MODULAR_FRAMES=n quits after n frames, MODULAR_SCREENSHOT=file.png saves
// the last frame, MODULAR_RUN=1 starts the clock, MODULAR_EDIT=slot opens
// that FM module's editor page.
local rl = require("raylib")
local stream = require("raylib/stream")
local isolate = require("slang/isolate")
local buffer = require("slang/buffer")
local os = require("slang/os")
local path = require("slang/path")
local str = require("slang/string")
local table = require("slang/table")
local font = require("font")
local rack = require("rack")
local engine = require("engine")
local ui = require("ui")
local fmui = require("fmui")

local SAMPLE_RATE = 48000
local K = engine.kinds
local L = engine.live
local here = __PACKAGES.search_paths[0]
local patches_dir = path.join(here, "patches")

// ------------------------------------------------------------ the rack

local r = rack.new(buffer.shared)
local live = r.a.live
live[L.VEL] = 1

local patch_files = {}
local patch_index = -1

local func list_patches(){
  patch_files = {}
  for(let local f in values(try { os.list_dir(patches_dir) } catch { {} })){
    if(str.ends_with(f, ".json")){
      append(patch_files, f)
    }
  }
  patch_files = table.sort(patch_files)
}

local message = null
local message_until = 0.0

local func say(text){
  message = text
  message_until = rl.time + 3.0
}

local func load_patch(file){
  r:load(path.join(patches_dir, file))
  for(local i = 0; i < len(patch_files); i = i + 1){
    if(patch_files[i] == file){
      patch_index = i
    }
  }
  say(concat("LOADED ", r.name))
}

local func next_patch(){
  list_patches()
  if(len(patch_files) == 0){
    say("NO PATCHES IN PATCHES/")
    return
  }
  patch_index = (patch_index + 1) % len(patch_files)
  load_patch(patch_files[patch_index])
}

local func save_patch(){
  if(r.path == null){
    list_patches()
    local n = 1
    for(true){
      local f = concat("patch_", n, ".json")
      if(not table.contains(patch_files, f)){
        r.path = path.join(patches_dir, f)
        r.name = str.upper(concat("PATCH_", n))
        break
      }
      n = n + 1
    }
  }
  r:save()
  say(concat("SAVED ", r.path))
}

// ------------------------------------------------------------ the sound

local player = stream.play(func(a, rate){
  local engine = require("engine")
  return engine.new(a, rate, {midi: true})
}, {args: {r.a, SAMPLE_RATE}, sample_rate: SAMPLE_RATE, channels: 2})

local stats = {load: 0.0, underruns: 0}
local stats_at = -1.0

// the first clock module, for the transport
local func clock_module(){
  for(let local m in values(r:slots())){
    if(r.modules[m].kind == K.CLOCK){
      return m
    }
  }
  return null
}

local func transport(){
  local m = clock_module()
  if(m == null){
    return null
  }
  local mod = r.modules[m]
  return {
    bpm: to_int(40 + mod.params[0] * 200 + 0.5),
    bar: to_int(r.a.status[m * 4 + 2]),
    beat: to_int(r.a.status[m * 4 + 1]),
    song_on: mod.params[3] > 0.5,
    bars: 1 << to_int(mod.params[2]),
  }
}

// ---- rendering the song to a file, in an isolate of its own

local exporting = null
local export_done = isolate.channel()

local func export(){
  if(exporting != null){
    return
  }
  local t = transport()
  local seconds = 8.0
  if(t != null){
    local bars = 8
    if(t.song_on and len(r.song) > 0){
      bars = len(r.song) * t.bars
    }
    seconds = bars * 16 * 60 / t.bpm / 4 + 2
  }
  local out = path.join(patches_dir, concat(str.lower(r.name), ".wav"))
  exporting = isolate.spawn(func(a, out, seconds, rate, done){
    local engine = require("engine")
    local block = engine.offline(a, rate)
    local s = engine.render(block, to_int(seconds * rate), rate)
    require("wav").write(out, {s.left, s.right}, rate, 0.9)
    done:send(out)
  }, r.a, out, seconds, SAMPLE_RATE, export_done)
  say(concat("RENDERING ", to_int(seconds), " S TO ", out))
}

local func poll_export(){
  if(exporting == null){
    return
  }
  local done = export_done:try_receive()
  if(done != null){
    exporting:join()
    exporting = null
    say(concat("WROTE ", done))
  }
}

// ------------------------------------------------------------ the keys

local key_notes = {
  {rl.KEY_Z, 0}, {rl.KEY_S, 1}, {rl.KEY_X, 2}, {rl.KEY_D, 3}, {rl.KEY_C, 4},
  {rl.KEY_V, 5}, {rl.KEY_G, 6}, {rl.KEY_B, 7}, {rl.KEY_H, 8}, {rl.KEY_N, 9},
  {rl.KEY_J, 10}, {rl.KEY_M, 11}, {rl.KEY_COMMA, 12}, {rl.KEY_L, 13},
  {rl.KEY_PERIOD, 14}, {rl.KEY_SEMICOLON, 15}, {rl.KEY_SLASH, 16},
}
local octave = 0
local held = {}        // semitones held, in the order pressed
local key_down = {}    // key -> semitones

local func note_on(semis){
  local rest = {}
  for(let local h in values(held)){
    if(h != semis){
      append(rest, h)
    }
  }
  held = rest
  append(held, semis)
  live[L.PITCH] = semis / 12
  live[L.GATE] = 1
}

local func note_off(semis){
  local rest = {}
  for(let local h in values(held)){
    if(h != semis){
      append(rest, h)
    }
  }
  held = rest
  if(len(held) > 0){
    live[L.PITCH] = held[len(held) - 1] / 12
  } else {
    live[L.GATE] = 0
  }
}

local selected = 0     // the pattern the keys 1-8 chose
local pattern = 0      // the pattern shown and edited: the song's while it plays
local menu = false
local editor = null        // {m}: the FM module whose editor page is open
local hover = null
local drag = null
local clipboard = null     // {slot -> the 64 ints of a pattern}
local layout = ui.place(r)
local last_click = {at: -1.0, on: null}

local func set_pattern(p){
  selected = p
  live[L.PATTERN] = p
}

// in song mode the sequencers show the pattern the song is at
local func follow_song(t){
  pattern = selected
  if(t != null and t.song_on and live[L.RUN] > 0.5){
    pattern = to_int(r.a.status[clock_module() * 4 + 3])
  }
}

local func same_target(a, b){
  if(a == null or b == null){
    return false
  }
  return a.kind == b.kind and a.m == b.m and a.i == b.i and a.cell == b.cell
}

// after the rack changed under the mouse: what was hovered or dragged may
// be gone, and the layout is new
local func rack_changed(){
  layout = ui.place(r)
  hover = null
  drag = null
  editor = null
}

local func open_editor(m){
  editor = {m: m}
  hover = null
  drag = null
}

local func add_module(name){
  local spec = rack.spec(name)
  if(not ui.fits(r, spec)){
    say("THE RACK IS FULL")
    return
  }
  local m = r:add(name)
  rack_changed()
  say(concat("ADDED ", name, " IN SLOT ", m))
}

local func remove_hovered(){
  if(hover == null or hover.m == null){
    return
  }
  local name = r.modules[hover.m].spec.name
  r:remove(hover.m)
  rack_changed()
  say(concat("REMOVED ", name))
}

local func copy_patterns(){
  clipboard = {}
  for(let local m in values(r:slots())){
    local mod = r.modules[m]
    if(mod.seq != null){
      clipboard[m] = table.slice(mod.seq, pattern * 64, pattern * 64 + 64)
    }
  }
  say(concat("COPIED PATTERN ", str.substring("ABCDEFGH", pattern, pattern + 1)))
}

local func paste_patterns(){
  if(clipboard == null){
    say("NOTHING COPIED (F5 COPIES)")
    return
  }
  for(let local m in values(r:slots())){
    local mod = r.modules[m]
    if(mod.seq != null and clipboard[m] != null){
      for(local i = 0; i < 64; i = i + 1){
        mod.seq[pattern * 64 + i] = clipboard[m][i]
      }
      r:write_module(m)
    }
  }
  say(concat("PASTED INTO PATTERN ", str.substring("ABCDEFGH", pattern, pattern + 1)))
}

// the piano keys, the octave and the transport: at work on the FM editor
// page too, to hear what is edited
local func play_keys(){
  for(let local kn in values(key_notes)){
    if(rl.key.pressed(kn[0]) and key_down[kn[0]] == null){
      local n = octave + kn[1]
      key_down[kn[0]] = n
      note_on(n)
    }
    if(rl.key.released(kn[0]) and key_down[kn[0]] != null){
      note_off(key_down[kn[0]])
      delete(key_down, kn[0])
    }
  }
  if(rl.key.pressed(rl.KEY_LEFT) and octave > -36){
    octave = octave - 12
  }
  if(rl.key.pressed(rl.KEY_RIGHT) and octave < 36){
    octave = octave + 12
  }
  if(rl.key.pressed(rl.KEY_SPACE)){
    live[L.RUN] = 1 - live[L.RUN]
  }
}

local func handle_keys(){
  if(editor != null){
    if(rl.key.pressed(rl.KEY_ESCAPE) or rl.key.pressed(rl.KEY_E)){
      editor = null
      hover = null
      drag = null
    }
    play_keys()
    if(rl.key.pressed(rl.KEY_F2)){
      save_patch()
    }
    return
  }
  if(rl.key.pressed(rl.KEY_A)){
    menu = not menu
  }
  if(menu and rl.key.pressed(rl.KEY_ESCAPE)){
    menu = false
  }
  if(menu){
    return
  }
  if(rl.key.pressed(rl.KEY_E) and hover != null and hover.m != null and r.modules[hover.m].kind == K.FM){
    open_editor(hover.m)
    return
  }
  play_keys()
  for(local p = 0; p < 8; p = p + 1){
    if(rl.key.pressed(rl.KEY_ONE + p)){
      set_pattern(p)
    }
  }
  if(rl.key.pressed(rl.KEY_DELETE) or rl.key.pressed(rl.KEY_BACKSPACE)){
    remove_hovered()
  }
  if(rl.key.pressed(rl.KEY_TAB)){
    next_patch()
    rack_changed()
  }
  if(rl.key.pressed(rl.KEY_F2)){
    save_patch()
  }
  if(rl.key.pressed(rl.KEY_F3)){
    export()
  }
  if(rl.key.pressed(rl.KEY_F4)){
    r:clear()
    r.name = "UNTITLED"
    r.path = null
    rack_changed()
    say("AN EMPTY RACK")
  }
  if(rl.key.pressed(rl.KEY_F5)){
    copy_patterns()
  }
  if(rl.key.pressed(rl.KEY_F6)){
    paste_patterns()
  }
}

// ------------------------------------------------------------ the mouse

// a press on the FM editor page: a switch flips, a number starts a drag
// (a double click puts the preset's value back), a preset loads, an
// operator in the diagram mutes
local func press_editor(y, double){
  local m = editor.m
  if(hover.kind == "cell"){
    local c = hover.cell
    local f = c.field
    local v = r:fm_get(m, c.op, f.id)
    if(double){
      r:fm_set(m, c.op, f.id, r:fm_preset_value(m, c.op, f.id))
    } else if(f.kind == "bool" or f.kind == "enum"){
      v = v + 1
      if(v > f.max){
        v = f.min
      }
      r:fm_set(m, c.op, f.id, v)
    } else {
      drag = {kind: "fmcell", cell: c, y: y, v: v}
    }
  } else if(hover.kind == "bank"){
    r:fm_select(m, hover.i)
    say(concat("FM: ", rack.bank[hover.i].name))
  } else if(hover.kind == "op"){
    r:fm_set(m, hover.k, "on", 1 - r:fm_get(m, hover.k, "on"))
  }
}

local func press(m, x, y, shift){
  if(hover == null){
    return
  }
  local now = rl.time
  local double = same_target(last_click.on, hover) and now - last_click.at < 0.35
  last_click = {at: now, on: hover}
  if(editor != null){
    press_editor(y, double)
    return
  }
  if(hover.kind == "fm"){
    open_editor(hover.m)
  } else if(hover.kind == "menu"){
    add_module(rack.catalog[hover.i].name)
    menu = false
  } else if(hover.kind == "knob"){
    local mod = r.modules[hover.m]
    if(double){
      r:set_param(hover.m, hover.i, mod.spec.params[hover.i].default)
      return
    }
    drag = {kind: "knob", m: hover.m, i: hover.i, y: y, v: mod.params[hover.i], acc: 0.0}
  } else if(hover.kind == "out"){
    drag = {kind: "cable", from: {m: hover.m, o: hover.i}}
  } else if(hover.kind == "in"){
    local c = r:cable_to(hover.m, hover.i)
    if(c != null){
      // pick the cable up by this end
      r:disconnect(hover.m, hover.i)
      drag = {kind: "cable", from: {m: c.from.m, o: c.from.o}}
    } else {
      drag = {kind: "cable", to: {m: hover.m, i: hover.i}}
    }
  } else if(hover.kind == "step"){
    local gate = r:seq_gate(hover.m, pattern, hover.step)
    local note = r:seq_note(hover.m, pattern, hover.step)
    if(gate == 0){
      r:set_step(hover.m, pattern, hover.step, note, 1)
      drag = {kind: "note", m: hover.m, step: hover.step, y: y, note: note, fresh: true}
    } else {
      drag = {kind: "note", m: hover.m, step: hover.step, y: y, note: note, fresh: false}
    }
  } else if(hover.kind == "trig"){
    local on = 1 - r:trig(hover.m, pattern, hover.row, hover.step)
    r:set_trig(hover.m, pattern, hover.row, hover.step, on)
    drag = {kind: "paint", m: hover.m, row: hover.row, on: on}
  } else if(hover.kind == "song"){
    local s = hover.slot
    if(s < len(r.song)){
      r.song[s] = (r.song[s] + 1) % 8
    } else if(s == len(r.song)){
      append(r.song, 0)
    }
    r:write_song()
  }
}

local func press_right(){
  if(hover == null){
    return
  }
  if(hover.kind == "in"){
    r:disconnect(hover.m, hover.i)
  } else if(hover.kind == "step"){
    local gate = r:seq_gate(hover.m, pattern, hover.step)
    local note = r:seq_note(hover.m, pattern, hover.step)
    if(gate == 1){
      gate = 2
    } else if(gate == 2){
      gate = 1
    }
    r:set_step(hover.m, pattern, hover.step, note, gate)
  } else if(hover.kind == "song"){
    if(hover.slot < len(r.song)){
      // the chain ends here
      local keep = {}
      for(local i = 0; i < hover.slot; i = i + 1){
        append(keep, r.song[i])
      }
      r.song = keep
      r:write_song()
    }
  }
}

local func dragging(x, y, shift){
  if(drag == null){
    return
  }
  if(drag.kind == "fmcell"){
    // pixels per step: small ranges take bigger steps; shift one at a time
    local f = drag.cell.field
    local px = 2
    if(f.max - f.min < 20){
      px = 6
    }
    if(shift){
      px = 12
    }
    r:fm_set(editor.m, drag.cell.op, f.id, drag.v + to_int((drag.y - y) / px))
  } else if(drag.kind == "knob"){
    local mod = r.modules[drag.m]
    local p = mod.spec.params[drag.i]
    local dy = drag.y - y
    if(p.kind == "steps"){
      r:set_param(drag.m, drag.i, drag.v + to_int(dy / 6))
    } else {
      local scale = 0.01
      if(shift){
        scale = 0.001
      }
      r:set_param(drag.m, drag.i, drag.v + dy * scale)
    }
  } else if(drag.kind == "note"){
    local d = to_int((drag.y - y) / 2)
    if(d != 0){
      drag.moved = true
    }
    local gate = r:seq_gate(drag.m, pattern, drag.step)
    r:set_step(drag.m, pattern, drag.step, drag.note + d, gate)
  } else if(drag.kind == "paint"){
    if(hover != null and hover.kind == "trig" and hover.m == drag.m){
      r:set_trig(drag.m, pattern, hover.row, hover.step, drag.on)
    }
  }
}

local func release(){
  if(drag == null){
    return
  }
  if(drag.kind == "cable"){
    if(hover != null){
      if(drag.from != null and hover.kind == "in"){
        r:connect(drag.from.m, drag.from.o, hover.m, hover.i)
      } else if(drag.to != null and hover.kind == "out"){
        r:connect(hover.m, hover.i, drag.to.m, drag.to.i)
      }
    }
  } else if(drag.kind == "note"){
    // a click on a step that was on, without a drag: off
    if(not drag.fresh and not drag.moved){
      local note = r:seq_note(drag.m, pattern, drag.step)
      r:set_step(drag.m, pattern, drag.step, note, 0)
    }
  }
  drag = null
}

local func wheel(w){
  if(hover == null){
    return
  }
  if(hover.kind == "cell"){
    local c = hover.cell
    local step = 1
    if(w < 0){
      step = -1
    }
    r:fm_set(editor.m, c.op, c.field.id, r:fm_get(editor.m, c.op, c.field.id) + step)
  } else if(hover.kind == "knob"){
    local mod = r.modules[hover.m]
    local p = mod.spec.params[hover.i]
    local step = 0.02
    if(p.kind == "steps"){
      step = 1
    }
    if(w > 0){
      r:set_param(hover.m, hover.i, mod.params[hover.i] + step)
    } else {
      r:set_param(hover.m, hover.i, mod.params[hover.i] - step)
    }
  } else if(hover.kind == "step"){
    local note = r:seq_note(hover.m, pattern, hover.step)
    local gate = r:seq_gate(hover.m, pattern, hover.step)
    if(w > 0){
      note = note + 1
    } else {
      note = note - 1
    }
    r:set_step(hover.m, pattern, hover.step, note, gate)
  }
}

// what the status line says about what the mouse is over
local func tip(){
  if(editor != null){
    return fmui.tip(r, editor.m, hover)
  }
  if(hover == null){
    return null
  }
  if(hover.kind == "menu"){
    return null
  }
  local mod = r.modules[hover.m]
  if(mod == null){
    return null
  }
  local spec = mod.spec
  if(hover.kind == "knob"){
    local p = spec.params[hover.i]
    return concat(spec.name, " ", p.label, ": ", rack.shown(spec, hover.i, mod.params[hover.i]), "  (DRAG, WHEEL, DOUBLE CLICK RESETS)")
  }
  if(hover.kind == "in"){
    local c = r:cable_to(hover.m, hover.i)
    local from = "NOTHING (DRAG A CABLE HERE)"
    if(c != null){
      local fs = r.modules[c.from.m].spec
      from = concat(fs.name, " ", fs.outputs[c.from.o], " (DRAG TO MOVE, RIGHT CLICK UNPLUGS)")
    }
    return concat(spec.name, " IN ", spec.inputs[hover.i], " FROM ", from)
  }
  if(hover.kind == "out"){
    return concat(spec.name, " OUT ", spec.outputs[hover.i], "  (DRAG TO AN INPUT)")
  }
  if(hover.kind == "step"){
    local gate = r:seq_gate(hover.m, pattern, hover.step)
    local note = r:seq_note(hover.m, pattern, hover.step)
    local g = "OFF"
    if(gate == 1){
      g = "ON"
    } else if(gate == 2){
      g = "TIED"
    }
    return concat("STEP ", hover.step + 1, ": ", ui.note_name(note), " ", g, "  (CLICK, DRAG THE NOTE, RIGHT CLICK TIES)")
  }
  if(hover.kind == "trig"){
    return concat("ROW ", hover.row + 1, " STEP ", hover.step + 1, "  (CLICK OR PAINT)")
  }
  if(hover.kind == "song"){
    local s = hover.slot
    if(s < len(r.song)){
      return concat("SONG SLOT ", s + 1, ": PATTERN ", str.substring("ABCDEFGH", r.song[s], r.song[s] + 1), "  (CLICK: NEXT PATTERN, RIGHT CLICK: THE CHAIN ENDS HERE)")
    }
    return "SONG CHAIN  (CLICK TO ADD A PATTERN; SONG ON THE CLOCK FOLLOWS IT)"
  }
  if(hover.kind == "fm"){
    return concat("FM ", fmui.name(mod), ": CLICK (OR E) TO EDIT THE PATCH AND PICK A PRESET")
  }
  return concat(spec.name, ": ", spec.tip, "  (DEL REMOVES)")
}

local func handle_mouse(scale){
  local m = rl.mouse.position
  local x = m.x / scale
  local y = m.y / scale
  local shift = rl.key.down(rl.KEY_LEFT_SHIFT) or rl.key.down(rl.KEY_RIGHT_SHIFT)
  if(editor != null){
    hover = fmui.hit(r, editor.m, x, y)
  } else {
    hover = ui.hit(r, layout, x, y, menu)
  }
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)){
    if(menu and hover == null){
      menu = false
    } else {
      press(m, x, y, shift)
    }
  }
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_RIGHT)){
    press_right()
  }
  if(rl.mouse.down(rl.MOUSE_BUTTON_LEFT)){
    dragging(x, y, shift)
  }
  if(rl.mouse.released(rl.MOUSE_BUTTON_LEFT)){
    release()
  }
  local w = rl.mouse.wheel
  if(w != 0.0){
    wheel(w)
  }
  return {x: x, y: y}
}

// ------------------------------------------------------------ the loop

local max_frames = -1
if(os.getenv("MODULAR_FRAMES") != null){
  max_frames = to_int(os.getenv("MODULAR_FRAMES"))
}
local screenshot = os.getenv("MODULAR_SCREENSHOT")

rl.window.open(ui.VW * 2, ui.VH * 2, "slang modular")
local scale = 2
local mon = rl.window.monitor
if(rl.monitor.width(mon) >= ui.VW * 3 and rl.monitor.height(mon) >= ui.VH * 3 + 120){
  scale = 3
  rl.window.size = {ui.VW * 3, ui.VH * 3}
}
rl.target_fps = 60
rl.window.exit_key = rl.KEY_NULL
font.load()
local target = rl.render_texture(ui.VW, ui.VH)
target.texture.filter = rl.TEXTURE_FILTER_POINT

list_patches()
if(len(args()) > 0){
  r:load(args()[0])
  say(concat("LOADED ", r.name))
} else if(len(patch_files) > 0){
  load_patch(patch_files[0])
}
layout = ui.place(r)
if(os.getenv("MODULAR_RUN") != null){
  live[L.RUN] = 1
}
if(os.getenv("MODULAR_EDIT") != null){
  // the FM editor page of this slot at the start (for screenshots)
  local m = to_int(os.getenv("MODULAR_EDIT"))
  if(r.modules[m] != null and r.modules[m].kind == K.FM){
    open_editor(m)
  }
}

local frame = 0
for(not rl.window.should_close and frame != max_frames){
  follow_song(transport())
  local mouse = handle_mouse(scale)
  handle_keys()
  poll_export()
  local now = rl.time
  if(now - stats_at > 0.5){
    stats_at = now
    stats = player:stats()
  }
  if(message != null and now > message_until){
    message = null
  }
  local t = transport()
  local state = {
    hover: hover, drag: drag, mouse: mouse, pattern: pattern,
    running: live[L.RUN] > 0.5, transport: t,
    song_on: t != null and t.song_on, load: stats.load, underruns: stats.underruns,
    tip: tip(), message: message, menu: menu, editor: editor,
  }
  if(exporting != null){
    state.message = "RENDERING THE SONG..."
  }
  rl.texture_mode(target){
    ui.draw(r, layout, state)
  }
  rl.drawing{
    rl.draw.clear({0, 0, 0})
    target.texture:draw_pro({0, 0, ui.VW, -ui.VH}, {0, 0, ui.VW * scale, ui.VH * scale}, {0, 0}, 0, rl.WHITE)
  }
  frame = frame + 1
  if(screenshot != null and frame == max_frames){
    rl.window.screenshot(screenshot)
  }
}

local last = player:stats()
player:stop()
if(max_frames > 0){
  print(concat("frames ", frame, "  dsp ", to_int(last.load * 100), "%  underruns ", last.underruns, "\n"))
}
target:unload()
font.unload()
rl.window.close()
