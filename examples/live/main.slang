// slang live: a live coding environment for music and visuals. The code
// of a piece (pieces/*.slang) is edited in the window, over the picture
// its shader draws; command+enter runs it again while the music plays
// on: the players take their new patterns at the next beat, the sliders
// keep their positions, the shader its last frame.
//
//   make live        (or: cd examples/live && slang run main.slang pieces/first.slang)
//   slang run main.slang --watch pieces/first.slang
//
// With --watch (or LIVE_WATCH=1) there is no editor in the window: the
// picture fills it, and the file is loaded and run whenever it is saved
// from an editor of your own; the keyboard plays the keyboard() players
// without hovering KEYS. command+E shows and hides the editor at any time.
//
// Keys: command+enter (control+enter elsewhere) evaluates, command+S
// saves, escape or command+D hushes every player. The file is watched: a
// change saved from another editor is loaded and run. Sliders drag; a
// right click on one arms MIDI learn, the next knob turned is bound (in
// pieces/midi_map.json). With the mouse over KEYS, the keyboard plays the
// players of keyboard(): asdfghjkl the degrees 0 to 8, qwertyuiop from 7,
// zxcvbnm from -7; shift full, control half velocity, alt a semitone up.
//
// LIVE_FRAMES=n quits after n frames, LIVE_SCREENSHOT=file.png saves the
// last frame, LIVE_SCALE=n the pixel size, MIDI_INPUT=name the controller.
local rl = require("raylib")
local stream = require("raylib/stream")
local os = require("slang/os")
local str = require("slang/string")
local path = require("slang/path")
local math = require("slang/math")
local time = require("slang/time")
local buffer = require("slang/buffer")
local compiler = require("slang/compiler")
local engine = require("engine")
local session = require("session")
local editor = require("editor")
local layout = require("layout")
local glsl = require("glsl")
local pattern = require("pattern")

local VW = 800
local VH = 450
local PANEL_W = 184
local STATUS_H = 14
local SAMPLE_RATE = 48000
local CW = editor.CW
local CH = editor.CH

local here = __PACKAGES.search_paths[0]
local argv = {}
local show_editor = os.getenv("LIVE_WATCH") == null
for(let local a in values(args())){
  if(a == "--watch"){
    show_editor = false
  } else {
    append(argv, a)
  }
}
local piece_path = path.join(here, "pieces", "first.slang")
if(len(argv) > 0){
  piece_path = argv[0]
  if(not path.is_abs(piece_path)){
    piece_path = path.join(os.cwd(), piece_path)
  }
}
local piece_dir = path.dir(piece_path)

local max_frames = os.getenv("LIVE_FRAMES")
if(max_frames != null){
  max_frames = str.to_number(max_frames)
}

// ------------------------------------------------------------- the window

rl.trace_log_level = rl.LOG_WARNING
rl.window.open({
  width: VW, height: VH, title: "slang live", resizable: true, vsync: true
})
rl.window.exit_key = 0
local scale = os.getenv("LIVE_SCALE")
if(scale != null){
  scale = str.to_number(scale)
} else {
  local mw = rl.monitor.width(rl.window.monitor)
  local mh = rl.monitor.height(rl.window.monitor)
  scale = math.max(1, math.min(to_int(mw / VW), to_int((mh - 80) / VH)))
}
rl.window.size = {VW * scale, VH * scale}
rl.window.position = {to_int((rl.monitor.width(rl.window.monitor) - VW * scale) / 2), 60}
rl.target_fps = 60

local func new_target(){
  local t = rl.render_texture(VW, VH)
  t.texture.filter = rl.TEXTURE_FILTER_POINT
  return t
}
local pic_a = new_target()
local pic_b = new_target()
local ui = new_target()

// -------------------------------------------------------------- the sound

local a = engine.arrays(func(ty, n){ return buffer.shared(ty, n) })
local player = stream.play(func(a, rate){
  return require("engine").new(a, rate)
}, {args: {a, SAMPLE_RATE}, sample_rate: SAMPLE_RATE, channels: 2, latency: 1024})
local S = session.new(a, SAMPLE_RATE)
S.midi_map = try { require("midi/map").load(
  path.join(piece_dir, "midi_map.json"),
) } catch { null }
local midi_in = try { require("midi").open(
  os.getenv("MIDI_INPUT"),
) } catch { null }

// -------------------------------------------------------------- the piece

local E = editor.new(try { os.read_file(piece_path) } catch { "" })
local loaded_mtime = (os.stat(piece_path) or {}).mtime
local message = ""
local message_color = {200, 210, 230}
local error_line = null
local tokens = null
local highlight_due = 0.0
local shader = null
local uniform_names = {}
local shader_error = false
// a shader that fails to compile comes back as raylib's default one
local default_shader_id = rl.shader.load(null, null).id

local func say(text, color){
  message = text
  message_color = color or {200, 210, 230}
}

// the mouse as Shadertoy shaders read it: where it is while the button
// is down over the picture (and the last such place after), z while down
local imouse = {0.0, 0.0, 0.0, 0.0}

local func build_shader(){
  if(S.shader_source == null){
    if(shader != null){
      shader:unload()
      shader = null
    }
    shader_error = false
    return
  }
  uniform_names = {}
  for(let local e in entries(S.uniforms)){
    append(uniform_names, e[0])
  }
  local sh = rl.shader({fragment: glsl.program(S.shader_source, uniform_names)})
  if(not sh.valid or sh.id == default_shader_id){
    shader_error = true
    say(
      "the shader does not compile (its errors are in the terminal)",
      editor.colors.error,
    )
    return
  }
  shader_error = false
  if(shader != null){
    shader:unload()
  }
  shader = sh
}

local runs = 0

local func evaluate(){
  runs = runs + 1
  local r = S:eval(E:text(), piece_path)
  if(r.ok){
    error_line = null
    say(
      concat(
        "ran at beat ", to_int(S:beat()), ", ", count(S.players), " players"
      ),
      {150, 230, 150},
    )
    if(S.shader_changed){
      S.shader_changed = false
      build_shader()
    }
  } else {
    error_line = r.line
    local where = ""
    if(r.line != null){
      where = concat("line ", r.line, ": ")
    }
    say(concat(where, r.message), editor.colors.error)
  }
}

local func save(){
  os.write_file(piece_path, E:text())
  loaded_mtime = (os.stat(piece_path) or {}).mtime
  E.dirty = false
  say(concat("saved ", path.base(piece_path)))
}

// the file changed on disk (another editor): loaded and run, unless the
// text here has unsaved changes
local func check_file(){
  local st = os.stat(piece_path)
  if(st == null or st.mtime == loaded_mtime){
    return
  }
  loaded_mtime = st.mtime
  if(E.dirty){
    say(
      "the file changed on disk; save to overwrite it, or reload with command+R",
      {255, 200, 120},
    )
    return
  }
  local text = try { os.read_file(piece_path) } catch { null }
  if(text != null and text != E:text()){
    local cy = E.cy
    local cx = E.cx
    E:set_text(text)
    E.cy = math.min(cy, len(E.lines) - 1)
    E.cx = math.min(cx, len(E.lines[E.cy]))
    E.dirty = false
    evaluate()
  }
}

local func rehighlight(){
  local r = try { compiler.highlight(E:text(), piece_path) } catch { null }
  if(r != null){
    tokens = r.tokens
  }
}

// --------------------------------------------------------------- the panel

local panel_x = VW - PANEL_W
local slider_drag = null
local keys_box = {x: panel_x + 8, y: 0, w: PANEL_W - 16, h: 36}
local key_rows = {
  {keys: "ASDFGHJKL;", from: 0},
  {keys: "QWERTYUIOP", from: 7},
  {keys: "ZXCVBNM,./", from: -7},
}
local keys_hot = false

local func slider_rows(){
  local rows = {}
  local y = 40
  for(let local c in values(S.control_list)){
    append(rows, {c: c, x: panel_x + 8, y: y, w: PANEL_W - 16, h: 22})
    y = y + 26
  }
  return rows
}

local func draw_panel(mx, my){
  local C = editor.colors
  rl.draw.rectangle(panel_x, 0, PANEL_W, VH - STATUS_H, {10, 12, 20, 170})
  editor.text("SLANG LIVE", panel_x + 8, 8, {255, 230, 120})
  editor.text(path.base(piece_path), panel_x + 8, 20, C.gutter)
  local rows = slider_rows()
  for(let local r in values(rows)){
    local c = r.c
    local t = 0.0
    if(c.hi != c.lo){
      t = (c.value - c.lo) / (c.hi - c.lo)
    }
    rl.draw.rectangle(r.x, r.y + 10, r.w, 8, {40, 46, 66})
    rl.draw.rectangle(r.x, r.y + 10, to_int(r.w * t), 8, {120, 200, 255})
    rl.draw.rectangle(r.x + to_int(r.w * t) - 1, r.y + 8, 3, 12, {
      255, 255, 255
    })
    editor.text(c.name, r.x, r.y - 2, C.text)
    local binding = ""
    if(S.midi_map != null){
      if(S.midi_map.armed == c.name){
        binding = "turn a knob"
      } else {
        binding = S.midi_map:binding(c.name) or ""
      }
    }
    local v = concat("", to_int(c.value * 100) / 100)
    local right = concat(binding, " ", v)
    editor.text(right, r.x + r.w - editor.width(right), r.y - 2, C.gutter)
  }
  // the players and their levels
  local y = 40 + len(rows) * 26 + 6
  editor.text("PLAYERS", panel_x + 8, y, C.gutter)
  y = y + 12
  for(local i = 0; i < engine.MAXP; i = i + 1){
    local name = S.by_index[i]
    if(name == null){
      continue
    }
    local p = S.players[name]
    local m = math.min(S:meter(i), 1.0)
    rl.draw.rectangle(panel_x + 8, y + 2, 60, 7, {40, 46, 66})
    rl.draw.rectangle(panel_x + 8, y + 2, to_int(60 * m), 7, {160, 230, 120})
    local label = concat(name, " ", p.wave)
    if(p.source == "midi"){
      label = concat(label, " <midi")
    } else if(p.source == "keyboard"){
      label = concat(label, " <keys")
    }
    editor.text(
      str.substring(label, 0, math.min(len(label), 13)), panel_x + 72, y, C.text
    )
    y = y + 11
  }
  // the keyboard
  y = y + 6
  keys_box.y = y
  // without the editor the keyboard has nothing else to do: it plays
  keys_hot = not show_editor or (mx >= keys_box.x and mx < keys_box.x + keys_box.w and
    my >= keys_box.y and my < keys_box.y + keys_box.h)
  local box_color = {40, 46, 66}
  if(keys_hot){
    box_color = {80, 100, 160}
  }
  rl.draw.rectangle(keys_box.x, keys_box.y, keys_box.w, keys_box.h, box_color)
  editor.text("KEYS", keys_box.x + 6, keys_box.y + 4, C.text)
  local hint = "hover, then asdf..."
  if(not show_editor){
    hint = "asdf... plays"
  }
  editor.text(hint, keys_box.x + 6, keys_box.y + 16, C.gutter)
  // the clock
  y = y + keys_box.h + 8
  local beat = S:beat()
  local bar = to_int(math.floor(beat / 4)) + 1
  local in_bar = to_int(math.floor(beat)) % 4 + 1
  editor.text(
    concat("", to_int(S.bpm), " BPM  ", bar, ".", in_bar), panel_x + 8, y,
    C.text
  )
  for(local k = 0; k < 4; k = k + 1){
    local color = {40, 46, 66}
    if(k + 1 == in_bar){
      color = {255, 230, 120}
    }
    rl.draw.rectangle(panel_x + 8 + k * 12, y + 12, 9, 5, color)
  }
  y = y + 24
  local st = player:stats()
  local load = to_int(st.load * 100)
  editor.text(
    concat("dsp ", load, "%  voices ", to_int(a.ctl[engine.ctl.VOICES])),
    panel_x + 8, y, C.gutter
  )
  y = y + 12
  local mi = "no midi"
  if(midi_in != null){
    mi = "midi in"
  }
  editor.text(mi, panel_x + 8, y, C.gutter)
  y = y + 18
  editor.text("cmd+enter  run", panel_x + 8, y, C.gutter)
  editor.text("cmd+s      save", panel_x + 8, y + 11, C.gutter)
  editor.text("cmd+k      comment", panel_x + 8, y + 22, C.gutter)
  editor.text("cmd+e      editor", panel_x + 8, y + 33, C.gutter)
  editor.text("esc        hush", panel_x + 8, y + 44, C.gutter)
  editor.text("right click  learn", panel_x + 8, y + 55, C.gutter)
}

local func panel_mouse(mx, my){
  local rows = slider_rows()
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)){
    for(let local r in values(rows)){
      if(mx >= r.x - 4 and mx < r.x + r.w + 4 and my >= r.y and my < r.y + r.h){
        slider_drag = r
      }
    }
  }
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_RIGHT) and S.midi_map != null){
    for(let local r in values(rows)){
      if(mx >= r.x - 4 and mx < r.x + r.w + 4 and my >= r.y and my < r.y + r.h){
        if(S.midi_map.armed == r.c.name){
          S.midi_map:arm(null)
        } else {
          S.midi_map:arm(r.c.name)
        }
      }
    }
  }
  if(slider_drag != null){
    local r = slider_drag
    local t = math.clamp((mx - r.x) / r.w, 0.0, 1.0)
    S:set_control(r.c.name, r.c.lo + t * (r.c.hi - r.c.lo))
    if(rl.mouse.released(rl.MOUSE_BUTTON_LEFT)){
      slider_drag = null
    }
  }
}

// the computer keyboard as an instrument while the mouse is over KEYS
local held_keys = {}
local func play_keys(){
  local shift = rl.key.down(rl.KEY_LEFT_SHIFT) or
    rl.key.down(rl.KEY_RIGHT_SHIFT)
  local ctrl = rl.key.down(rl.KEY_LEFT_CONTROL) or
    rl.key.down(rl.KEY_RIGHT_CONTROL)
  local alt = rl.key.down(rl.KEY_LEFT_ALT) or
    rl.key.down(rl.KEY_RIGHT_ALT)
  for(let local row in values(key_rows)){
    for(local i = 0; i < len(row.keys); i = i + 1){
      local k = str.byte_at(row.keys, i)
      if(keys_hot and rl.key.pressed(k) and held_keys[k] == null){
        local vel = 0.75
        if(shift){
          vel = 1.0
        } else if(ctrl){
          vel = 0.5
        }
        local acc = 0
        if(alt){
          acc = 1
        }
        held_keys[k] = true
        S:key_note(row.from + i, acc, vel, true, k)
      } else if(held_keys[k] != null and rl.key.released(k)){
        held_keys[k] = null
        S:key_note(0, 0, 0, false, k)
      }
    }
  }
  for(rl.key.next_char() != 0){ }
}

// ------------------------------------------------------------- the picture

local func draw_picture(mx, my, now){
  local cur = pic_a
  local last = pic_b
  rl.texture_mode(cur){
    if(shader == null){
      rl.draw.clear({8, 10, 18})
    } else {
      rl.shader_mode(shader){
        shader:set("resolution", {VW * 1.0, VH * 1.0})
        shader:set("time", now)
        shader:set("beat", S:beat())
        shader:set(
          "level",
          math.max(S:meter(engine.MAXP), S:meter(engine.MAXP + 1)),
        )
        shader:set("mouse", {mx / VW, 1.0 - my / VH})
        shader:set("imouse", imouse)
        local envs = {}
        for(local i = 0; i < engine.MAXP; i = i + 1){
          append(envs, S:meter(i) * 1.0)
        }
        shader:set_value_v(shader:location("env"), envs, rl.SHADER_UNIFORM_FLOAT)
        local beat = S:beat()
        for(let local name in values(uniform_names)){
          local v = pattern.value_at(S.uniforms[name], beat)
          if(type(v) == "int" or type(v) == "double"){
            shader:set(name, v * 1.0)
          }
        }
        shader:set_value_texture(shader:location("prev"), last.texture)
        rl.draw.rectangle(0, 0, VW, VH, rl.WHITE)
      }
    }
  }
  pic_a = last
  pic_b = cur
  return cur
}

// ----------------------------------------------------------------- the loop

rehighlight()
evaluate()
local frames = 0
local last_check = time.clock()
for(not rl.window.should_close){
  local now = rl.time
  scale = math.max(1, math.min(
    to_int(rl.window.width / VW),
    to_int(rl.window.height / VH),
  ))
  local ox = to_int((rl.window.width - VW * scale) / 2)
  local oy = to_int((rl.window.height - VH * scale) / 2)
  local mx = (rl.mouse.x - ox) / scale
  local my = (rl.mouse.y - oy) / scale

  // the controllers and the keyboard
  if(midi_in != null){
    for(let local m in values(midi_in:read())){
      S:midi_message(m)
    }
  }
  S:tick()
  local cmd = rl.key.down(rl.KEY_LEFT_SUPER) or
    rl.key.down(rl.KEY_RIGHT_SUPER) or rl.key.down(rl.KEY_LEFT_CONTROL) or
    rl.key.down(rl.KEY_RIGHT_CONTROL)
  if(cmd and
    (rl.key.pressed(rl.KEY_ENTER) or rl.key.pressed(rl.KEY_KP_ENTER))){
    evaluate()
  } else if(cmd and rl.key.pressed(layout.key("s"))){
    save()
  } else if(cmd and rl.key.pressed(layout.key("r"))){
    E.dirty = false
    loaded_mtime = null
    check_file()
  } else if(rl.key.pressed(rl.KEY_ESCAPE) or
    (cmd and rl.key.pressed(layout.key("d")))){
    S:hush()
    say("hush")
  } else if(cmd and rl.key.pressed(layout.key("e"))){
    show_editor = not show_editor
    if(show_editor){
      highlight_due = now
      say("the editor; command+E hides it again")
    } else {
      say(concat("watching ", path.base(piece_path), ": save it from your editor to run it"))
    }
  } else if(keys_hot or count(held_keys) > 0){
    play_keys()
  } else {
    E:update()
    if(E.changed){
      E.changed = false
      highlight_due = now + 0.15
    }
  }
  if(highlight_due > 0 and now >= highlight_due){
    highlight_due = 0
    rehighlight()
  }
  if(time.clock() - last_check > 250){
    last_check = time.clock()
    check_file()
  }
  // the mouse
  if(mx < panel_x and my < VH - STATUS_H and rl.mouse.down(rl.MOUSE_BUTTON_LEFT)){
    imouse = {mx * 1.0, VH - my * 1.0, 1.0, 0.0}
  } else {
    imouse[2] = 0.0
  }
  if(mx >= panel_x or slider_drag != null){
    panel_mouse(mx, my)
  } else if(show_editor and my < VH - STATUS_H){
    if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT) or
      rl.mouse.down(rl.MOUSE_BUTTON_LEFT)){
      local pos = E:position(mx, my, 4, 4)
      E:click(pos.line, pos.col, rl.mouse.down(rl.MOUSE_BUTTON_LEFT) and not rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT))
    }
    local wheel = rl.mouse.wheel
    if(wheel != 0){
      E:scroll_by(-to_int(wheel * 2))
    }
  }

  local pic = draw_picture(mx, my, now)
  // the user interface over it
  rl.texture_mode(ui){
    rl.draw.clear({0, 0, 0, 0})
    local rows = to_int((VH - STATUS_H - 8) / CH)
    if(show_editor){
      E:draw(4, 4, to_int((panel_x - 8) / CW), rows, tokens, error_line)
    }
    draw_panel(mx, my)
    rl.draw.rectangle(0, VH - STATUS_H, VW, STATUS_H, {10, 12, 20, 220})
    local dirty = ""
    if(E.dirty){
      dirty = "*"
    }
    local status = concat(path.base(piece_path), dirty, "  ", message)
    if(not show_editor){
      status = concat("watching ", status)
    }
    editor.text(
      str.substring(status, 0, math.min(len(status), to_int(VW / CW) - 1)), 4,
      VH - STATUS_H + 1, message_color
    )
  }

  rl.drawing{
    rl.draw.clear({0, 0, 0})
    local src = {x: 0, y: 0, width: VW, height: -VH}
    local dst = {x: ox, y: oy, width: VW * scale, height: VH * scale}
    pic.texture:draw_pro(src, dst, {0, 0}, 0, rl.WHITE)
    ui.texture:draw_pro(src, dst, {0, 0}, 0, rl.WHITE)
  }

  frames = frames + 1
  if(max_frames != null and frames >= max_frames){
    local shot = os.getenv("LIVE_SCREENSHOT")
    if(shot != null){
      rl.window.screenshot(shot)
    }
    break
  }
}

local st = player:stats()
if(max_frames != null){
  print(concat(
    "frames ", frames, " dsp ", to_int(st.load * 100), "% underruns ",
    st.underruns, " sent ", S.sent, " runs ", runs, "\n"
  ))
}
player:stop()
if(midi_in != null){
  midi_in:close()
}
if(shader != null){
  shader:unload()
}
pic_a:unload()
pic_b:unload()
ui:unload()
rl.window.close()
