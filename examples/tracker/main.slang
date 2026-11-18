// A tracker: songs as patterns of rows, played by the instruments and
// effects of packages/studio. The window is a picture of 752 x 444 scaled
// by whole pixels, in raylib's own pixel font.
//
//   slang run main.slang [songs/dusk.json]        (make tracker)
//
// TRACKER_FRAMES=n quits after n frames, TRACKER_SCREENSHOT=file.png saves
// the last frame, TRACKER_PLAY=1 starts playing, TRACKER_MUTE=1 keeps the
// sound card silent, TRACKER_SCALE=n sets the pixel size, TRACKER_VIEW
// says what is shown at the start (see below).
local rl = require("raylib")
local stream = require("raylib/stream")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local path = require("slang/path")
local tbl = require("slang/table")
local buffer = require("slang/buffer")
local isolate = require("slang/isolate")
local song = require("song")
local player = require("player")
local grid = require("grid")
local view = require("view")
local panel = require("panel")
local gfx = require("gfx")
local layout = require("layout")

local VW = 752
local VH = 444
local CW = gfx.CW
local CH = gfx.CH
local C = gfx.colors
local TOP = CH * 2 // the bar at the top
local ORDER_W = CW * 6 // the order list at the left
local STATUS = CH // the line at the bottom
local PANEL_W = panel.COLS * CW

local here = __PACKAGES.search_paths[0]
local songs_dir = path.join(here, "songs")

// ------------------------------------------------------------- the song

local func song_files(){
  local out = {}
  for(let local f in values(try { os.list_dir(songs_dir) } catch { {} })){
    if(str.ends_with(f, ".json")){
      append(out, path.join(songs_dir, f))
    }
  }
  return tbl.sort(out)
}

local A = {
  song: null,
  P: null,
  path: null,
  order_pos: 0,
  cursor: {t: 0, f: 0, row: 0},
  anchor: null,
  octave: 4,
  step: 1,
  follow: true,
  panel_open: true,
  first_track: 0,
  ref: {kind: "track", index: 0},
  slot: -1,
  param_scroll: 0,
  menu: null,
  drag: null,
  hover_x: 0,
  hover_y: 0,
  clip: null,
  typing: null,
  play_row: null,
  play_pattern: null,
  message: "",
  message_until: 0.0,
  message_color: C.text,
  help: false,
  asked: null,
  asked_until: 0.0,
}

func A.say(text, color){
  A.message = text
  A.message_color = color or C.text
  A.message_until = rl.time + 4
}

local muted = os.getenv("TRACKER_MUTE") != null

// open(s, file): the song s is the one shown and played from here on
local func open(s, file){
  if(A.P != null){
    A.P:stop()
    A.P.studio:stop()
  }
  A.song = s
  A.path = file
  A.P = player.new(s, {mute: muted})
  A.P.studio:start(stream, {latency: 1024})
  A.missing = A.P.missing
  A.P.missing = null
  A.order_pos = 0
  A.cursor = {t: 0, f: 0, row: 0}
  A.anchor = null
  A.first_track = 0
  A.ref = {kind: "track", index: 0}
  A.slot = -1
  A.param_scroll = 0
  A.menu = null
  A.midi_track = null
  A.load_after = rl.time + 2
}

local func load(file){
  local r = try { {song: song.load(file)} } catch(local e) { {error: e} }
  if(r.song != null){
    open(r.song, file)
    if(A.missing != null){
      A.say(
        concat("opened ", path.base(file), ", without ", path.base(A.missing)),
        C.warn,
      )
    } else {
      A.say(concat("opened ", path.base(file)))
    }
  } else {
    A.say(
      concat(
        "cannot open ", path.base(file), ": ",
        string(r.error.message or r.error)
      ),
      C.bad,
    )
  }
}

local func save(){
  if(A.path == null){
    local name = "untitled"
    local n = 1
    for(os.exists(path.join(songs_dir, concat(name, ".json")))){
      n = n + 1
      name = concat("untitled_", string(n))
    }
    A.song.name = name
    A.path = path.join(songs_dir, concat(name, ".json"))
  }
  song.save(A.song, A.path)
  A.say(concat("saved ", path.base(A.path)), C.good)
}

// unsaved(what) -> true when the song has changes that `what` would
// lose and it was not asked for twice in a row
local func unsaved(what){
  if(not A.song.dirty or (A.asked == what and rl.time < A.asked_until)){
    A.asked = null
    return false
  }
  A.asked = what
  A.asked_until = rl.time + 4
  A.say("unsaved changes: the same again leaves them behind", C.warn)
  return true
}

// a new song: four tracks, two buses, one empty pattern; saved as
// untitled (or untitled_2, ...) until its file is renamed
local func new_song(){
  if(unsaved("new")){
    return null
  }
  open(song.new(), null)
  A.say("a new song: command+S saves it as songs/untitled.json")
}

// the next song of songs/ after the one that is open
local func open_next(){
  if(unsaved("open")){
    return null
  }
  local files = song_files()
  if(len(files) == 0){
    return null
  }
  local at = -1
  for(local i = 0; i < len(files); i = i + 1){
    if(files[i] == A.path){
      at = i
    }
  }
  load(files[(at + 1) % len(files)])
}

// ------------------------------------------------------------- the window

local argv = args()
rl.trace_log_level = rl.LOG_WARNING
rl.window.open({
  width: VW, height: VH, title: "slang tracker", resizable: true, vsync: true
})
rl.window.exit_key = 0
local scale = os.getenv("TRACKER_SCALE")
if(scale != null){
  scale = str.to_number(scale)
} else {
  local mw = rl.monitor.width(rl.window.monitor)
  local mh = rl.monitor.height(rl.window.monitor)
  scale = math.max(1, math.min(to_int(mw / VW), to_int((mh - 80) / VH)))
}
rl.window.size = {VW * scale, VH * scale}
rl.window.position = {
  to_int((rl.monitor.width(rl.window.monitor) - VW * scale) / 2),
  60,
}
rl.target_fps = 60
local screen = rl.render_texture(VW, VH)
screen.texture.filter = rl.TEXTURE_FILTER_POINT

local max_frames = os.getenv("TRACKER_FRAMES")
if(max_frames != null){
  max_frames = str.to_number(max_frames)
}

if(len(argv) > 0){
  local file = argv[0]
  if(not path.is_abs(file)){
    file = path.join(os.cwd(), file)
  }
  load(file)
}
if(A.song == null){
  local files = song_files()
  if(len(files) > 0){
    load(files[0])
  }
}
if(A.song == null){
  open(song.new(), null)
}
A.message = "space plays. command+G (or F1) shows the keys"
A.message_until = 8.0

// ------------------------------------------------------------- playing

local func playing(){
  return A.P.playing
}

local func toggle_play(mode, row){
  if(playing()){
    A.P:stop()
    A.play_row = null
  } else {
    A.P:play(mode, A.order_pos, row or 0)
  }
}

// an export in an isolate, while the program plays on
local exporting = null
local export_done = isolate.channel()
local func export(){
  if(exporting != null){
    return null
  }
  local out = path.join(here, concat(A.song.name, ".wav"))
  if(A.path != null){
    out = concat(str.substring(A.path, 0, len(A.path) - 5), ".wav")
  }
  exporting = isolate.spawn(func(t, out, done){
    require("player").export(t, out)
    done:send(out)
  }, song.to_table(A.song), out, export_done)
  A.say(concat("rendering ", path.base(out), " ..."), C.warn)
}

// ------------------------------------------------------------- the keys

// the keys that play notes, by their place: the bottom rows from C, the
// top rows an octave up
local piano = {
  {rl.KEY_Z, 0},
  {rl.KEY_S, 1},
  {rl.KEY_X, 2},
  {rl.KEY_D, 3},
  {rl.KEY_C, 4},
  {rl.KEY_V, 5},
  {rl.KEY_G, 6},
  {rl.KEY_B, 7},
  {rl.KEY_H, 8},
  {rl.KEY_N, 9},
  {rl.KEY_J, 10},
  {rl.KEY_M, 11},
  {rl.KEY_COMMA, 12},
  {rl.KEY_L, 13},
  {rl.KEY_PERIOD, 14},
  {rl.KEY_SEMICOLON, 15},
  {rl.KEY_SLASH, 16},
  {rl.KEY_Q, 12},
  {rl.KEY_TWO, 13},
  {rl.KEY_W, 14},
  {rl.KEY_THREE, 15},
  {rl.KEY_E, 16},
  {rl.KEY_R, 17},
  {rl.KEY_FIVE, 18},
  {rl.KEY_T, 19},
  {rl.KEY_SIX, 20},
  {rl.KEY_Y, 21},
  {rl.KEY_SEVEN, 22},
  {rl.KEY_U, 23},
  {rl.KEY_I, 24},
}
local digits = {
  rl.KEY_ZERO,
  rl.KEY_ONE,
  rl.KEY_TWO,
  rl.KEY_THREE,
  rl.KEY_FOUR,
  rl.KEY_FIVE,
  rl.KEY_SIX,
  rl.KEY_SEVEN,
  rl.KEY_EIGHT,
  rl.KEY_NINE,
}
local sounding = {} // key -> {t, note}: notes held by hand

local func hit(k){
  return rl.key.pressed(k) or rl.key.pressed_repeat(k)
}

local func release_keys(){
  for(let local e in entries(sounding)){
    if(A.P.tracks[e[1].t] != null){
      A.P:note_off(e[1].t, e[1].note)
    }
  }
  sounding = {}
}

local func command_keys(shift){
  local s = A.song
  local key = layout.key
  if(rl.key.pressed(key("s"))){
    save()
  } else if(rl.key.pressed(key("o"))){
    open_next()
  } else if(hit(key("z"))){
    local did = if(shift){ song.redo(s) } else { song.undo(s) }
    if(not did){
      A.say(if(shift){ "nothing to redo" } else { "nothing to undo" })
    }
    grid.clamp(A)
  } else if(rl.key.pressed(key("c"))){
    grid.copy(A)
    A.say("copied")
  } else if(rl.key.pressed(key("x"))){
    grid.copy(A)
    grid.clear(A)
  } else if(hit(key("v"))){
    if(not grid.paste(A)){
      A.say("nothing to paste")
    }
  } else if(rl.key.pressed(key("a"))){
    grid.select_all(A)
  } else if(rl.key.pressed(key("d"))){
    song.duplicate_pattern(s, grid.pattern(A), A.order_pos)
    A.order_pos = A.order_pos + 1
    A.say(concat("pattern ", song.two(grid.pattern(A)), ", a copy"))
  } else if(shift and rl.key.pressed(key("n"))){
    new_song()
  } else if(rl.key.pressed(key("n"))){
    song.add_pattern(s, s.patterns[grid.pattern(A)].rows, A.order_pos)
    A.order_pos = A.order_pos + 1
    A.say(concat("pattern ", song.two(grid.pattern(A)), ", empty"))
  } else if(rl.key.pressed(key("t"))){
    A.panel_open = true
    A.menu = {kind: "track"}
  } else if(rl.key.pressed(key("k"))){
    if(len(s.tracks) > 1){
      local name = s.tracks[A.cursor.t].name
      release_keys()
      A.P:remove_track(A.cursor.t)
      grid.clamp(A)
      A.ref = {kind: "track", index: A.cursor.t}
      A.slot = -1
      A.say(concat("removed ", name))
    }
  } else if(hit(key("u"))){
    grid.transpose(A, if(shift){ 12 } else { 1 })
  } else if(hit(key("j"))){
    grid.transpose(A, if(shift){ -12 } else { -1 })
  } else if(rl.key.pressed(key("i"))){
    if(not grid.interpolate(A)){
      A.say("select rows of a velocity or a lane to fill between")
    }
  } else if(rl.key.pressed(key("f"))){
    A.follow = not A.follow
    A.say(if(A.follow){ "follows the song" } else { "stays where it is" })
  } else if(rl.key.pressed(key("p"))){
    A.panel_open = not A.panel_open
  } else if(rl.key.pressed(key("e"))){
    export()
  }
}

local func plain_keys(shift){
  local s = A.song
  if(hit(rl.KEY_UP)){
    grid.move(A, 0, -1, shift)
  } else if(hit(rl.KEY_DOWN)){
    grid.move(A, 0, 1, shift)
  } else if(hit(rl.KEY_LEFT)){
    grid.move(A, -1, 0, shift)
  } else if(hit(rl.KEY_RIGHT)){
    grid.move(A, 1, 0, shift)
  } else if(hit(rl.KEY_PAGE_UP)){
    grid.move(A, 0, -math.min(16, A.cursor.row), shift)
  } else if(hit(rl.KEY_PAGE_DOWN)){
    grid.move(
      A, 0, math.min(16, s.patterns[grid.pattern(A)].rows - 1 - A.cursor.row),
      shift
    )
  } else if(rl.key.pressed(rl.KEY_HOME)){
    grid.move(A, 0, -A.cursor.row, shift)
  } else if(rl.key.pressed(rl.KEY_END)){
    grid.move(A, 0, s.patterns[grid.pattern(A)].rows - 1 - A.cursor.row, shift)
  } else if(hit(rl.KEY_TAB)){
    grid.track(A, if(shift){ -1 } else { 1 })
  } else if(rl.key.pressed(rl.KEY_SPACE)){
    toggle_play(if(shift){ "song" } else { "pattern" }, 0)
  } else if(rl.key.pressed(rl.KEY_ENTER) or rl.key.pressed(rl.KEY_KP_ENTER)){
    // from the cursor's row
    if(playing()){
      A.P:stop()
    }
    A.P:play("pattern", A.order_pos, A.cursor.row)
  } else if(rl.key.pressed(rl.KEY_ESCAPE)){
    A.menu = null
    A.anchor = null
  } else if(hit(rl.KEY_BACKSPACE) or hit(rl.KEY_DELETE)){
    local had = A.anchor != null
    grid.clear(A)
    if(not had){
      grid.move(A, 0, A.step, false)
    }
  }
  local f = grid.field(A)
  if(f.kind == "note"){
    if(rl.key.pressed(rl.KEY_ONE)){
      grid.note(A, song.OFF)
    } else if(rl.key.pressed(rl.KEY_NINE)){
      A.octave = math.max(0, A.octave - 1)
    } else if(rl.key.pressed(rl.KEY_ZERO)){
      A.octave = math.min(8, A.octave + 1)
    }
  } else {
    for(local d = 0; d < 10; d = d + 1){
      if(rl.key.pressed(digits[d])){
        grid.digit(A, d)
      }
    }
  }
  // the keys that play: heard at once on the cursor's track, and written
  // where the cursor is in a note column
  for(let local k in values(piano)){
    if(rl.key.pressed(k[0]) and sounding[k[0]] == null){
      local note = math.clamp((A.octave + 1) * 12 + k[1], 0, 127)
      if(s.tracks[A.cursor.t].unit == "drums"){
        // the drums are where the keys are, whatever the octave: Z is the
        // bass drum (the first key a heavy one would be below)
        note = song.DRUM_BASE + 1 + k[1]
      }
      if(f.kind != "note" and k[0] >= rl.KEY_ZERO and k[0] <= rl.KEY_NINE){
        // a digit typed into a value, not a black key
        continue
      }
      local t = A.cursor.t
      local row = A.cursor.row
      A.P:note_on(t, note, song.get(s, grid.pattern(A), t, "vel", f.col, row))
      sounding[k[0]] = {t: t, note: note}
      if(f.kind == "note"){
        grid.note(A, note)
      }
    }
  }
  local let_go = {}
  for(let local e in entries(sounding)){
    if(not rl.key.down(e[0])){
      append(let_go, e[0])
    }
  }
  for(let local k in values(let_go)){
    local held = sounding[k]
    if(A.P.tracks[held.t] != null){
      A.P:note_off(held.t, held.note)
    }
    delete(sounding, k)
  }
}

// ------------------------------------------------------------- the top

// the numbers of the top bar: the wheel (or a click: left up, right down)
// changes them
local fields = {
  {
    label: "BPM",
    get: func(){ return A.song.bpm },
    set: func(d, big){
      local by = if(big){ 10 } else { 1 }
      A.song.bpm = math.clamp(A.song.bpm + d * by, 30, 300)
      A.song.dirty = true
    },
  },
  {
    label: "LPB",
    get: func(){ return A.song.lpb },
    set: func(d){
      A.song.lpb = math.clamp(A.song.lpb + d, 1, 16)
      A.song.dirty = true
    },
  },
  {
    label: "SWING",
    get: func(){ return to_int(A.song.swing * 100 + 0.5) },
    set: func(d){
      A.song.swing = math.clamp(
        to_int(A.song.swing * 100 + 0.5) + d * 5, 0, 100
      ) / 100
      A.song.dirty = true
    },
  },
  {
    label: "OCT",
    get: func(){ return A.octave },
    set: func(d){
      A.octave = math.clamp(A.octave + d, 0, 8)
    },
  },
  {
    label: "STEP",
    get: func(){ return A.step },
    set: func(d){
      A.step = math.clamp(A.step + d, 0, 16)
    },
  },
  {
    label: "ROWS",
    get: func(){ return A.song.patterns[grid.pattern(A)].rows },
    set: func(d){
      local p = grid.pattern(A)
      song.set_rows(
        A.song, p, math.clamp(A.song.patterns[p].rows + d * 4, 4, 128)
      )
      grid.clamp(A)
    },
  },
}

local scope = buffer.new("float", 2048)
local load_shown = 0.0
local load_at = 0.0

local func strip_buttons(){
  local out = {}
  for(local b = 0; b < len(A.song.buses); b = b + 1){
    append(out, {label: A.song.buses[b].name, ref: {kind: "bus", index: b}})
  }
  append(out, {label: "master", ref: {kind: "master"}})
  return out
}

local func draw_top(mx, my){
  gfx.rect(0, 0, VW, TOP, C.panel)
  gfx.rect(0, TOP - 1, VW, 1, C.line)
  gfx.text("slang tracker", 4, 0, C.cursor)
  local name = A.song.name
  if(A.song.dirty){
    name = concat(name, " *")
  }
  gfx.text(gfx.fit(name, 18), 16 * CW, 0, C.title)
  // what it plays
  local pos = A.P:position()
  if(pos != null){
    local what = concat(
      "> ", A.P.mode, "  ", song.two(pos.order), "/",
      song.two(len(A.song.order) - 1), "  row ", song.two(pos.row)
    )
    gfx.text(what, 36 * CW, 0, C.good)
  } else {
    gfx.text("stopped", 36 * CW, 0, C.faint)
  }
  // the keys, on a click
  local keys_hot = gfx.inside(mx, my, 62 * CW, 0, 4 * CW + 6, CH)
  gfx.rect(62 * CW, 1, 4 * CW + 6, CH - 2, if(A.help){ {
    90, 100, 130
  } } else { C.line })
  gfx.text(
    "keys", 62 * CW + 3, 0, if(A.help or keys_hot){ C.title } else { C.dim }
  )
  // the load, twice a second
  if(rl.time - load_at > 0.5){
    load_at = rl.time
    local now = math.min(A.P.studio:stats().load, 9.99)
    // (a song's first second loads its units' kernels: not its load)
    load_shown = if(rl.time > A.load_after){ now } else { 0.0 }
  }
  local load_color = C.dim
  if(load_shown > 0.6){
    load_color = C.bad
  }
  gfx.text(
    concat("cpu ", string(to_int(load_shown * 100 + 0.5)), "%"), 69 * CW, 0,
    load_color
  )
  // the numbers
  local x = 4
  for(let local f in values(fields)){
    local text = concat(f.label, " ", string(f.get()))
    f.x = x
    f.w = len(text) * CW
    local hot = gfx.inside(mx, my, x - 2, CH, f.w + 4, CH)
    gfx.text(f.label, x, CH, if(hot){ C.text } else { C.dim })
    gfx.text(string(f.get()), x + (len(f.label) + 1) * CW, CH, C.warn)
    x = x + f.w + CW * 2
  }
  // the strips that are no tracks, and a + for one more bus
  x = 49 * CW
  for(let local b in values(strip_buttons())){
    local w = len(b.label) * CW + 6
    local on = A.ref.kind == b.ref.kind and A.ref.index == b.ref.index
    gfx.rect(x, CH, w, CH - 1, if(on){ {90, 100, 130} } else { C.line })
    gfx.text(b.label, x + 3, CH - 1, if(on){ C.title } else { C.dim })
    b.x = x
    x = x + w + 3
  }
  if(len(A.song.buses) < 4){
    local hot = gfx.inside(mx, my, x, CH, CW + 6, CH)
    gfx.rect(x, CH, CW + 6, CH - 1, C.line)
    gfx.text("+", x + 3, CH - 1, if(hot){ C.title } else { C.good })
  }
  // the master: its scope and its meters
  local sx = VW - 13 * CW
  local sw = 13 * CW - 12
  gfx.rect(sx, 2, sw, TOP - 5, C.back)
  A.P.studio:scope(scope)
  local last = TOP / 2
  for(local i = 0; i < sw; i = i + 1){
    local v = scope[2048 - sw * 4 + i * 4]
    local y = to_int(TOP / 2 - 1 - math.clamp(v, -1, 1) * (TOP / 2 - 3))
    local lo = math.min(y, last)
    rl.draw.rectangle(sx + i, lo, 1, math.max(1, math.abs(y - last)), C.good)
    last = y
  }
  local pk = A.P.studio.master.peak
  local func meter(mxx, level){
    local hgt = to_int(math.min(1.0, math.sqrt(level)) * (TOP - 5))
    gfx.rect(mxx, 2, 3, TOP - 5, C.line)
    gfx.rect(
      mxx, 2 + (TOP - 5) - hgt, 3, hgt, if(level > 0.9){ C.bad } else { C.good }
    )
  }
  meter(VW - 9, pk.left)
  meter(VW - 5, pk.right)
}

local func top_mouse(mx, my){
  if(my >= TOP){
    return false
  }
  local wheel = rl.mouse.wheel
  local d = 0
  if(wheel > 0 or rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)){
    d = 1
  } else if(wheel < 0 or rl.mouse.pressed(rl.MOUSE_BUTTON_RIGHT)){
    d = -1
  }
  if(my >= CH and d != 0){
    for(let local f in values(fields)){
      if(f.x != null and mx >= f.x - 2 and mx < f.x + f.w + 2){
        f.set(d, rl.key.down(rl.KEY_LEFT_SHIFT) or rl.key.down(
            rl.KEY_RIGHT_SHIFT,
          ))
      }
    }
  }
  if(my >= CH and rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)){
    local x = 49 * CW
    for(let local b in values(strip_buttons())){
      local w = len(b.label) * CW + 6
      if(mx >= x and mx < x + w){
        A.ref = b.ref
        A.slot = 0
        A.param_scroll = 0
        A.menu = null
        A.panel_open = true
      }
      x = x + w + 3
    }
    if(len(A.song.buses) < 4 and mx >= x and mx < x + CW + 6){
      // one more bus: the panel asks what it starts with
      A.panel_open = true
      A.menu = {kind: "bus"}
    }
  }
  if(my < CH and rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT) and
    gfx.inside(mx, my, 62 * CW, 0, 4 * CW + 6, CH)){
    A.help = not A.help
  }
  return true
}

// ------------------------------------------------------------- the order

local order_buttons = {
  {
    label: "+ add", run: func(){
      local k = len(A.song.order)
      for(k > A.order_pos + 1){
        A.song.order[k] = A.song.order[k - 1]
        k = k - 1
      }
      A.song.order[A.order_pos + 1] = A.song.order[A.order_pos]
      A.order_pos = A.order_pos + 1
      A.song.dirty = true
    }
  },
  {
    label: "- del", run: func(){
      if(len(A.song.order) > 1){
        remove(A.song.order, A.order_pos)
        A.song.dirty = true
        grid.clamp(A)
      }
    }
  },
  {
    label: "new", run: func(){
      song.add_pattern(
        A.song, A.song.patterns[grid.pattern(A)].rows, A.order_pos
      )
      A.order_pos = A.order_pos + 1
    }
  },
  {
    label: "copy", run: func(){
      song.duplicate_pattern(A.song, grid.pattern(A), A.order_pos)
      A.order_pos = A.order_pos + 1
    }
  },
}

local func order_lines(){
  return to_int((VH - TOP - STATUS) / CH) - 2 - len(order_buttons)
}

local func order_first(){
  local n = order_lines()
  return math.clamp(
    A.order_pos - to_int(n / 2),
    0,
    math.max(0, len(A.song.order) - n),
  )
}

local func draw_order(mx, my){
  local y = TOP
  gfx.rect(0, y, ORDER_W, VH - TOP - STATUS, C.panel)
  gfx.rect(ORDER_W - 1, y, 1, VH - TOP - STATUS, C.line)
  gfx.text("ORDER", 4, y, C.dim)
  local first = order_first()
  local pos = A.P:position()
  for(local i = 0; i < order_lines(); i = i + 1){
    local at = first + i
    if(at >= len(A.song.order)){
      break
    }
    local ly = y + CH * (i + 1)
    if(at == A.order_pos){
      gfx.rect(1, ly, ORDER_W - 3, CH, C.cursor_row)
    }
    if(pos != null and pos.order == at){
      gfx.rect(1, ly, 2, CH, C.good)
    }
    gfx.text(song.two(at), 4, ly, C.faint)
    gfx.text(
      song.two(A.song.order[at]),
      4 + 3 * CW,
      ly,
      if(at == A.order_pos){ C.title } else { C.text },
    )
  }
  local by = VH - STATUS - len(order_buttons) * CH
  for(local i = 0; i < len(order_buttons); i = i + 1){
    local hot = gfx.inside(mx, my, 0, by + i * CH, ORDER_W - 1, CH)
    gfx.text(
      order_buttons[i].label,
      4,
      by + i * CH,
      if(hot){ C.title } else { C.dim },
    )
  }
}

local func order_mouse(mx, my){
  if(mx >= ORDER_W or my < TOP or my >= VH - STATUS){
    return false
  }
  local by = VH - STATUS - len(order_buttons) * CH
  local wheel = rl.mouse.wheel
  if(my >= by){
    if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)){
      order_buttons[to_int((my - by) / CH)].run()
    }
    return true
  }
  local at = order_first() + to_int((my - TOP) / CH) - 1
  if(at < 0 or at >= len(A.song.order)){
    return true
  }
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)){
    A.order_pos = at
    A.anchor = null
    grid.clamp(A)
  } else if(wheel != 0){
    // which pattern plays at this place
    local n = len(A.song.patterns)
    local d = if(wheel > 0){ 1 } else { -1 }
    A.song.order[at] = ((A.song.order[at] + d) % n + n) % n
    A.song.dirty = true
    grid.clamp(A)
  }
  return true
}

// ------------------------------------------------------------- the grid

local selecting = false

local func grid_mouse(L, mx, my){
  local h = view.hit(A, L, mx, my)
  if(rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)){
    if(h == null){
      return null
    }
    if(h.header){
      // a track's header: the track is the panel's; its M mutes it
      A.cursor.t = h.t
      A.cursor.f = math.min(
        A.cursor.f,
        len(grid.fields_of(A.song.tracks[h.t])) - 1,
      )
      A.ref = {kind: "track", index: h.t}
      A.slot = -1
      A.param_scroll = 0
      A.menu = null
      return null
    }
    A.cursor = {t: h.t, f: h.f, row: h.row}
    A.anchor = null
    selecting = true
  } else if(rl.mouse.pressed(rl.MOUSE_BUTTON_RIGHT) and h != null and h.header){
    local ref = {kind: "track", index: h.t}
    A.P:set_strip(ref, "mute", not A.song.tracks[h.t].mute)
  } else if(selecting and rl.mouse.down(rl.MOUSE_BUTTON_LEFT)){
    if(h != null and not h.header and
      (h.t != A.cursor.t or h.f != A.cursor.f or h.row != A.cursor.row)){
      if(A.anchor == null){
        A.anchor = {t: A.cursor.t, f: A.cursor.f, row: A.cursor.row}
      }
      A.cursor = {t: h.t, f: h.f, row: h.row}
    }
  } else {
    selecting = false
  }
}

// ------------------------------------------------------------- the keys' page

// what the keys do, shown over the pattern: {keys, what they do}, a line
// each; one string alone is a heading
local help = {
  "IN THE PATTERN",
  {"arrows", "move; with shift, select"},
  {"tab, shift+tab", "next track, the one before"},
  {"Z S X D C V G B H N J M ,", "notes from C, by key position"},
  {"Q 2 W 3 E R 5 T 6 Y 7 U I", "the same an octave up"},
  {"1", "===: the note ends here"},
  {"9, 0", "an octave down, up"},
  {"digits", "a velocity's or a lane's value"},
  {"backspace", "clear the cell or selection"},
  {"space", "loop the pattern; stop"},
  {"shift+space", "play the song from this place"},
  {"enter", "play from the cursor's row"},
  {"on a drums track", "Z kick, X snare, G hat, D clap"},
  "WITH COMMAND (OR CONTROL), BY YOUR LAYOUT'S LETTER",
  {"S, O, shift+N", "save; next song; new song"},
  {"Z, shift+Z", "undo, redo"},
  {"C, X, V", "copy, cut, paste"},
  {"A", "select the track; the pattern"},
  {"U, J", "notes up, down (shift: octave)"},
  {"I", "fill between first and last row"},
  {"N, D", "new pattern; copy of this one"},
  {"T, K", "new track; remove this track"},
  {"F, P", "follow or stay; the panel"},
  {"E", "render the song to a WAV file"},
  {"G, or F1", "this page"},
  "THE MOUSE",
  {"numbers at the top", "wheel, or click left/right"},
  {"+ beside master", "a new bus (its panel removes it)"},
  {"a track's header", "its panel; right click mutes"},
  {"ORDER", "click: go there; wheel: pattern"},
  {"the panel", "drag; right click: the default"},
}

local func draw_help(w){
  local x = ORDER_W + 4
  local y = TOP + 4
  local h = VH - TOP - STATUS - 8
  gfx.rect(x, y, w, h, {16, 19, 30})
  rl.draw.rectangle_lines(x, y, w, h, C.dim)
  gfx.right("escape closes", x + w - 6, y + 3, C.faint)
  local line = y + 3
  for(let local row in values(help)){
    if(type(row) == "string"){
      line = line + 3
      gfx.text(row, x + 8, line, C.cursor)
      line = line + CH + 1
    } else {
      gfx.text(row[0], x + 8, line, C.warn)
      gfx.text(
        gfx.fit(row[1], to_int((w - 16) / CW) - 27), x + 8 + 27 * CW, line,
        C.text
      )
      line = line + CH
    }
  }
}

// ------------------------------------------------------------- the loop

local func status_line(){
  local y = VH - STATUS
  gfx.rect(0, y, VW, STATUS, C.panel)
  gfx.rect(0, y, VW, 1, C.line)
  if(rl.time < A.message_until){
    gfx.text(gfx.fit(A.message, 60), 4, y + 1, A.message_color)
  } else if(A.song.tracks[A.cursor.t].unit == "drums"){
    // where the drums are
    gfx.text(
      "Z kick  X snare  D clap  G hat  J open  S rim  V B N M toms", 4, y + 1,
      C.dim
    )
  } else {
    gfx.text("command+G (or F1) shows the keys", 4, y + 1, C.faint)
  }
  local f = grid.field(A)
  local what = concat("lane: ", A.song.tracks[A.cursor.t].lane or "none")
  if(f.kind == "note"){
    what = concat("note ", string(f.col + 1))
  } else if(f.kind == "vel"){
    what = "velocity"
  }
  local where = concat(A.song.tracks[A.cursor.t].name, "  ", what)
  if(not A.follow){
    where = concat("stays  ", where)
  }
  gfx.right(gfx.fit(where, 32), VW - 4, y + 1, C.dim)
}

if(os.getenv("TRACKER_PLAY") != null){
  A.P:play("song", 0, 0)
}
// TRACKER_VIEW, for pictures of it: "master" or a bus's name shows that
// strip in the panel, "fx" a track's first insert, "menu" the list of
// instruments, "closed" no panel, "select" a selection, a number that
// track
local show = os.getenv("TRACKER_VIEW")
if(show != null){
  for(let local what in values(str.split(show, ","))){
    if(what == "master"){
      A.ref = {kind: "master"}
      A.slot = 0
    } else if(what == "fx"){
      A.slot = 0
    } else if(what == "menu"){
      A.menu = {kind: "track"}
    } else if(what == "keys"){
      A.help = true
    } else if(what == "bus"){
      A.menu = {kind: "bus"}
    } else if(what == "closed"){
      A.panel_open = false
    } else if(what == "select"){
      A.anchor = {t: A.cursor.t, f: 0, row: 4}
      A.cursor.f = len(grid.fields_of(A.song.tracks[A.cursor.t])) - 1
      A.cursor.row = 11
    } else if(str.to_number(what) != null){
      A.cursor.t = math.clamp(
        to_int(str.to_number(what)),
        0,
        len(A.song.tracks) - 1,
      )
      A.ref = {kind: "track", index: A.cursor.t}
      A.slot = -1
    } else {
      for(local b = 0; b < len(A.song.buses); b = b + 1){
        if(A.song.buses[b].name == what){
          A.ref = {kind: "bus", index: b}
          A.slot = 0
        }
      }
    }
  }
}

local frames = 0
for(not rl.window.should_close){
  scale = math.max(1, math.min(
    to_int(rl.window.width / VW),
    to_int(rl.window.height / VH),
  ))
  local ox = to_int((rl.window.width - VW * scale) / 2)
  local oy = to_int((rl.window.height - VH * scale) / 2)
  local mx = (rl.mouse.x - ox) / scale
  local my = (rl.mouse.y - oy) / scale
  A.hover_x = mx
  A.hover_y = my

  // a song dropped on the window
  if(rl.file_dropped){
    for(let local f in values(rl.load_dropped_files())){
      if(str.ends_with(f, ".json")){
        load(f)
      } else if(str.ends_with(str.lower(f), ".wav")){
        // a recording for the cursor's track, when its instrument plays one
        local unit = A.song.tracks[A.cursor.t].unit
        if(unit == "sampler" or unit == "grains"){
          release_keys()
          A.P:set_sample(A.cursor.t, f)
          if(A.P.missing != null){
            A.say(concat("cannot read ", path.base(f)), C.bad)
            A.P.missing = null
          } else {
            A.say(concat(
              A.song.tracks[A.cursor.t].name, " plays ", path.base(f)
            ))
          }
        } else {
          A.say("a WAV file is for a sampler or grains track", C.warn)
        }
      }
    }
  }
  local done = export_done:try_receive()
  if(done != null){
    exporting:join()
    exporting = null
    A.say(concat("rendered ", path.base(done)), C.good)
  }

  // what plays, and the rows to come
  A.P:tick()
  local pos = A.P:position()
  A.play_row = null
  A.play_pattern = null
  if(pos != null){
    A.play_row = pos.row
    A.play_pattern = pos.pattern
    if(A.follow and A.P.mode == "song" and pos.order != A.order_pos){
      A.order_pos = pos.order
      grid.clamp(A)
    }
  }
  // a MIDI controller plays the cursor's track
  if(A.midi_track != A.cursor.t){
    A.midi_track = A.cursor.t
    try {
      A.P.studio:midi(A.P.tracks[A.cursor.t])
    } catch {
      null
    }
  }

  local shift = rl.key.down(rl.KEY_LEFT_SHIFT) or
    rl.key.down(rl.KEY_RIGHT_SHIFT)
  local cmd = rl.key.down(rl.KEY_LEFT_SUPER) or
    rl.key.down(rl.KEY_RIGHT_SUPER) or rl.key.down(rl.KEY_LEFT_CONTROL) or
    rl.key.down(rl.KEY_RIGHT_CONTROL)
  // the keys' page: command+G or F1 shows it, they or escape close it; no
  // other key means anything while it is up
  if(rl.key.pressed(rl.KEY_F1) or (cmd and rl.key.pressed(layout.key("g")))){
    A.help = not A.help
  } else if(A.help){
    if(rl.key.pressed(rl.KEY_ESCAPE)){
      A.help = false
    }
  } else if(cmd){
    command_keys(shift)
  } else {
    plain_keys(shift)
  }
  for(rl.key.next_char() != 0){ }
  grid.clamp(A)

  local panel_x = VW
  if(A.panel_open){
    panel_x = VW - PANEL_W
  }
  local L = view.layout(
    A, ORDER_W + 4, TOP, panel_x - ORDER_W - 8, VH - TOP - STATUS
  )
  local taken = false
  if(A.panel_open){
    taken = panel.mouse(A, panel_x, TOP, PANEL_W, VH - TOP - STATUS, mx, my)
  }
  if(not taken){
    taken = top_mouse(mx, my) or order_mouse(mx, my)
  }
  if(not taken){
    grid_mouse(L, mx, my)
  }
  grid.clamp(A)

  rl.texture_mode(screen){
    rl.draw.clear(C.back)
    view.draw(A, L)
    draw_order(mx, my)
    if(A.panel_open){
      panel.draw(A, panel_x, TOP, PANEL_W, VH - TOP - STATUS)
    }
    if(A.help){
      draw_help(panel_x - ORDER_W - 8)
    }
    draw_top(mx, my)
    status_line()
  }
  rl.drawing{
    rl.draw.clear({0, 0, 0})
    screen.texture:draw_pro(
      {x: 0, y: 0, width: VW, height: -VH},
      {x: ox, y: oy, width: VW * scale, height: VH * scale}, {0, 0}, 0, rl.WHITE
    )
  }

  frames = frames + 1
  if(max_frames != null and frames >= max_frames){
    local shot = os.getenv("TRACKER_SCREENSHOT")
    if(shot != null){
      rl.window.screenshot(shot)
    }
    break
  }
}

local st = A.P.studio:stats()
if(max_frames != null){
  print(concat(
    "frames ", string(frames), " dsp ", string(to_int(st.load * 100)),
    "% underruns ", string(st.underruns), " dropped ",
    string(A.P.studio.dropped), "\n"
  ))
}
A.P:stop()
A.P.studio:stop()
screen:unload()
rl.window.close()
