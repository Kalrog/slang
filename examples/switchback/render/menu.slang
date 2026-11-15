// render/menu: the screens that are not driving: the title over the
// valley, the pause, the result at the summit, the garage, the list of
// controls, and what is shown while a valley is made. Each is one
// function that draws the screen and says what the player chose in this
// frame, or null: the game calls it every frame while the screen is up.
//
//   menu.init()
//   local action = menu.title({seed: 7, best: 801.4, trail_length: 4796})
//   if(action == "drive"){ ... }
//
// A screen is drawn inside rl.drawing{ }, over the scene when there is
// one behind it. The key that brought the screen up must not be pressed
// any more when its function is first called (so: from the next frame
// on), or it is taken as a key for the screen.
//
// The arrow keys (or W, A, S, D, or the gamepad's cross or left stick)
// move, Enter or Space (or the gamepad's A) choose, Esc or Backspace (or
// B) go back; the mouse points and clicks. The screens know nothing of
// the game: they get plain numbers and names.
//
// The title and the pause have a row for the sound's volume ([volume]):
// left and right change it by tenths, down to off; the screen then
// answers "volume". What the player did in a screen (the bar moved, an
// entry chosen...) is kept for the game to make heard: see [did].
local rl = require("raylib")
local math = require("slang/math")
local str = require("slang/string")
local ui = require("render/ui")

local m = {}

local colors = ui.colors

// where the player is in each screen, kept between frames
local state = {
  selected: {},      // by screen: the entry the bar is on
  seen: {},          // by screen: the frame it was last shown in
  frame: 0,
  row: 0,            // the garage's row
  mouse: {x: -1, y: -1},
  stick: {x: 0, y: 0},   // where the gamepad's stick was pushed to: -1, 0, 1
  did: {},           // what the player did in this frame's screen: see [did]
}

// garage: whether the player changed an option in the last call of
// [garage] (so the game knows to rebuild the truck)
m.changed = false

// the sound's volume, 0 (off) to 1, as the Sound row of the title and of
// the pause shows it: the game sets it once, and takes it from here when
// a screen answers "volume" (the player changed it)
m.volume = 0.8

// did() -> {string}: what the player did in the screens since this was
// last asked, for the game to make heard: "move" (the bar on another
// entry), "select" (an entry chosen), "back", "step" (a setting changed
// by a step), and in the garage "part" or "paint" (an option changed)
func m.did(){
  local list = state.did
  state.did = {}
  return list
}

local func note(what){
  append(state.did, what)
}

// init(): the fonts (the HUD's are the same ones)
func m.init(){
  ui.init()
}

// unload(): the fonts given back (when the window closes)
func m.unload(){
  state.selected = {}
  state.seen = {}
  state.row = 0
  ui.unload()
}

// ------------------------------------------------------------ input

local func any_key(...keys){
  for(let local k in values(keys)){
    if(rl.key.pressed(k)){
      return true
    }
  }
  return false
}

local func pad(...buttons){
  if(not rl.gamepad.available(0)){
    return false
  }
  for(let local b in values(buttons)){
    if(rl.gamepad.pressed(0, b)){
      return true
    }
  }
  return false
}

// the gamepad's left stick as steps: pushed past most of its way it
// counts once, and again only after it came back
local func stick(){
  local out = {x: 0, y: 0}
  if(not rl.gamepad.available(0)){
    return out
  }
  local now = {
    x: rl.gamepad.axis(0, rl.GAMEPAD_AXIS_LEFT_X),
    y: rl.gamepad.axis(0, rl.GAMEPAD_AXIS_LEFT_Y),
  }
  for(let local axis in values({"x", "y"})){
    local v = now[axis]
    local was = state.stick[axis]
    if(math.abs(v) < 0.3){
      state.stick[axis] = 0
    } else if(math.abs(v) > 0.6){
      local way = if(v > 0){ 1 } else { -1 }
      if(was != way){
        out[axis] = way
      }
      state.stick[axis] = way
    }
  }
  return out
}

// what the player did this frame, from the keyboard, the gamepad and the
// mouse
local func moves(){
  ui.begin()
  state.frame = state.frame + 1
  // (what was done in a frame nobody asked about is forgotten)
  state.did = {}
  local mouse = ui.mouse
  local moved = mouse.x != state.mouse.x or mouse.y != state.mouse.y
  state.mouse = mouse
  local pushed = stick()
  return {
    up: any_key(rl.KEY_UP, rl.KEY_W) or pad(rl.GAMEPAD_BUTTON_LEFT_FACE_UP) or pushed.y < 0,
    down: any_key(rl.KEY_DOWN, rl.KEY_S) or pad(rl.GAMEPAD_BUTTON_LEFT_FACE_DOWN) or pushed.y > 0,
    left: any_key(rl.KEY_LEFT, rl.KEY_A) or pad(rl.GAMEPAD_BUTTON_LEFT_FACE_LEFT) or pushed.x < 0,
    right: any_key(rl.KEY_RIGHT, rl.KEY_D) or pad(rl.GAMEPAD_BUTTON_LEFT_FACE_RIGHT) or pushed.x > 0,
    accept: any_key(rl.KEY_ENTER, rl.KEY_KP_ENTER, rl.KEY_SPACE) or pad(rl.GAMEPAD_BUTTON_RIGHT_FACE_DOWN),
    back: any_key(rl.KEY_ESCAPE, rl.KEY_BACKSPACE) or pad(rl.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT),
    start: pad(rl.GAMEPAD_BUTTON_MIDDLE_RIGHT),
    moved: moved,
    click: ui.click,
  }
}

// whether a screen is shown for the first time after another was (its
// bar then goes back to the first entry)
local func opened(key){
  local last = state.seen[key]
  state.seen[key] = state.frame
  return last == null or last < state.frame - 1
}

// ------------------------------------------------------------ parts

// the game's mark: a trail that doubles back on itself up a slope, with
// the place it leads to at its end
local func mark(x, y, size, color){
  local k = size / 60
  local points = {}
  for(let local p in values({
    {0, 52}, {6, 50}, {44, 44}, {56, 36}, {46, 29}, {16, 27}, {5, 20}, {14, 13}, {40, 9}, {52, 3}, {55, 1},
  })){
    append(points, {x + p[0] * k, y + p[1] * k})
  }
  rl.draw.spline_catmull_rom(points, math.max(1.5, 3.2 * k), color)
  rl.draw.circle_v({x + 54 * k, y + 2 * k}, 4.2 * k, colors.paper)
}

// a setting's row: after its name a bar (with an arrow at either end
// while the bar of the column is on the row) and its figure: how wide
// the bar is, and what stands between the parts, in a window 720 high
local SETTING_BAR = 64
local SETTING_ARROW = 14
local SETTING_GAP = 16

// a column of entries: the bar moves with the keys and follows the
// mouse; returns the index of the entry chosen in this frame, or null.
// align -1: from x on, 0: centered on x.
// An entry is its name, or a setting from 0 to 1: {name: string, value:
// float}, shown with a bar and a figure ("off" at 0). A setting is not
// chosen but changed, in place, by tenths: left and right (or a click
// on its arrows) take a step down or up, Enter (or a click elsewhere on
// it) a step up, and from the top round to off.
local func column(key, entries, x, y, input, options){
  options = options or {}
  local s = ui.s
  local size = options.size or 27
  local step = (options.step or 46) * s
  local align = options.align or -1
  local count = len(entries)
  local selected = state.selected[key] or 0
  if(selected >= count){
    selected = 0
  }
  local was = selected
  if(input.down){
    selected = (selected + 1) % count
  }
  if(input.up){
    selected = (selected + count - 1) % count
  }
  local chosen = null
  // (a click on a setting's arrows: a step down, a step up)
  local down = false
  local up = false
  for(local i = 0; i < count; i = i + 1){
    local entry = entries[i]
    local setting = null
    if(type(entry) == "table"){
      setting = entry
      entry = setting.name
    }
    local w = ui.measure(entry, size)
    // (all of a setting's row: its name, the bar between its arrows, its
    // figure at its widest)
    local all = w
    if(setting != null){
      all = w + (SETTING_GAP + 2 * SETTING_ARROW + SETTING_BAR + 10) * s + ui.measure("100%", 13)
    }
    local ex = if(align == 0){ x - all / 2 } else { x }
    local ey = y + i * step
    local over = ui.inside(ex - 18 * s, ey - 6 * s, all + 36 * s, step - 4 * s)
    if(over and input.moved){
      selected = i
    }
    if(over and input.click){
      selected = i
      chosen = i
    }
    if(i == selected){
      if(align == 0){
        rl.draw.rectangle_rec({ex - 20 * s, ey + size * s * 0.52, 8 * s, 2.5 * s}, colors.amber)
        rl.draw.rectangle_rec({ex + all + 12 * s, ey + size * s * 0.52, 8 * s, 2.5 * s}, colors.amber)
        ui.text(ex, ey, entry, size, colors.amber)
      } else {
        rl.draw.rectangle_rec({ex - 2 * s, ey + 3 * s, 3 * s, size * s * 0.94}, colors.amber)
        ui.text(ex + 14 * s, ey, entry, size, colors.amber)
      }
    } else {
      ui.text(ex, ey, entry, size, {242, 234, 216, 205})
    }
    if(setting != null){
      // (the bar stays where it is when the name moves aside for the
      // column's bar)
      local bx = ex + w + (SETTING_GAP + SETTING_ARROW) * s + (if(align == 0){ 0 } else { 14 * s })
      local bw = SETTING_BAR * s
      local ay = ey + size * s * 0.52 + 1 * s
      local value = math.max(0, math.min(1, setting.value or 0))
      local color = if(i == selected){ colors.amber } else { colors.dim }
      ui.bar(bx, ay - 2 * s, bw, 4 * s, value, color)
      if(i == selected){
        local over_left = ui.inside(bx - (SETTING_ARROW + 6) * s, ey - 6 * s, (SETTING_ARROW + 6) * s, step - 4 * s)
        local over_right = ui.inside(bx + bw, ey - 6 * s, (SETTING_ARROW + 6) * s, step - 4 * s)
        rl.draw.triangle({bx - 11 * s, ay}, {bx - 5 * s, ay + 5 * s}, {bx - 5 * s, ay - 5 * s},
          if(over_left){ colors.amber } else { colors.paper })
        rl.draw.triangle({bx + bw + 11 * s, ay}, {bx + bw + 5 * s, ay - 5 * s}, {bx + bw + 5 * s, ay + 5 * s},
          if(over_right){ colors.amber } else { colors.paper })
        down = over_left and input.click
        up = over_right and input.click
      }
      local figure = if(value < 0.05){ "off" } else { concat(string(to_int(value * 100 + 0.5)), "%") }
      ui.text(bx + bw + (SETTING_ARROW + 10) * s, ey + (size - 13) * 0.55 * s, figure, 13, colors.dim)
    }
  }
  if(input.accept){
    chosen = selected
  }
  local setting = entries[selected]
  local stepped = false
  if(type(setting) == "table"){
    local value = setting.value or 0
    if(input.left or down){
      value = value - 0.1
    } else if(input.right or up){
      value = value + 0.1
    } else if(chosen == selected){
      value = if(value > 0.95){ 0 } else { value + 0.1 }
    }
    chosen = null
    value = math.max(0, math.min(1, math.floor(value * 10 + 0.5) / 10))
    if(value != setting.value){
      setting.value = value
      stepped = true
      note("step")
    }
  }
  if(chosen != null){
    note("select")
  } else if(selected != was and not stepped){
    note("move")
  }
  state.selected[key] = selected
  return chosen
}

// a line of keys and what they do: {{keys}, text} one after another;
// returns where it ended
local func hints(x, y, list, size){
  return ui.hints(x, y, list, size)
}

// a figure with its name over it
local func stat(x, y, name, value, color){
  ui.label(x, y, name, 9, colors.dim)
  ui.text(x, y + 13 * ui.s, value, 19, color or colors.paper)
  return math.max(ui.measure(value, 19), ui.measure(str.upper(name), 9, 0.14))
}

local func dim_scene(alpha){
  rl.draw.rectangle(0, 0, to_int(ui.w) + 1, to_int(ui.h) + 1, {12, 14, 16, alpha or 150})
}

// ------------------------------------------------------------ the title

// title(state: {seed?: int, best?: float, trail_length?: float,
//   trails_length?: float, camps_found?: int, camps_total?: int})
//   -> "explore" | "drive" | "garage" | "seed" | "controls" | "volume" |
//   "quit" | null
// The title over the valley (the scene shows through on the right): the
// game's name, what there is to do (exploring the valley first, then the
// run to the summit), the valley's number, how long its trails are, the
// camps found in it, the best time to the summit, and the controls along
// the bottom. Esc puts the bar on Quit, and quits from there. "volume":
// the player changed the sound's volume ([volume] is the new one).
// [best]: seconds, or null when the summit run has not been driven
// [trail_length]: m, of the trail to the summit (shown when
//   [trails_length] is not given)
// [trails_length]: m, of all the valley's trails
// [daily]: the daily run ({day, date, counted?}): the day's Summit Run
//   comes first, and there is no other valley to choose (nor Quit, in a
//   browser)
func m.title(info){
  info = info or {}
  local input = moves()
  local s = ui.s
  local w = ui.w
  local h = ui.h
  // dark on the left, where the words are, and along the bottom
  rl.draw.rectangle_gradient_h(0, 0, to_int(w * 0.68), to_int(h) + 1, {12, 14, 16, 232}, {12, 14, 16, 0})
  rl.draw.rectangle_gradient_v(0, to_int(h - 150 * s), to_int(w) + 1, to_int(150 * s) + 1, {12, 14, 16, 0}, {12, 14, 16, 215})
  local x = 76 * s
  mark(x + 2 * s, 74 * s, 54 * s, colors.amber)
  ui.text(x - 4 * s, 132 * s, "SWITCHBACK", 80, colors.paper, 0.07)
  ui.label(x, 222 * s, "an off-road expedition", 12, colors.amber)
  rl.draw.rectangle_rec({x, 250 * s, 44 * s, 1.5 * s}, colors.dim)

  if(input.start){
    input.accept = true
  }
  local daily = info.daily
  local sound = {name: "Sound", value: m.volume}
  local entries = {"Explore", "Summit Run", "Garage", "New valley", "Controls", sound, "Quit"}
  local actions = {"explore", "drive", "garage", "seed", "controls", "volume", "quit"}
  local quit_row = 6
  if(daily != null){
    entries = {"Daily run", "Explore", "Garage", "Controls", sound}
    actions = {"drive", "explore", "garage", "controls", "volume"}
    quit_row = null
  }
  // (Esc puts the bar on Quit; there it quits)
  local quit = false
  if(input.back and quit_row != null){
    note("back")
    if(state.selected.title == quit_row){
      quit = true
    } else {
      state.selected.title = quit_row
    }
  }
  local chosen = column("title", entries, x, 270 * s, input, {step: 40})

  // the valley
  local sy = h - 152 * s
  local sx = x
  if(daily != null){
    sx = sx + stat(sx, sy, "daily run", concat("No. ", string(daily.day))) + 34 * s
    if(daily.date != null){
      sx = sx + stat(sx, sy, "date", m.date(daily.date)) + 34 * s
    }
  } else {
    sx = sx + stat(sx, sy, "valley", concat("No. ", string(info.seed or 0))) + 34 * s
  }
  if(info.trails_length != null){
    sx = sx + stat(sx, sy, "trails", concat(str.format("%.1f", info.trails_length / 1000), " km")) + 34 * s
  } else if(info.trail_length != null){
    sx = sx + stat(sx, sy, "trail", concat(str.format("%.1f", info.trail_length / 1000), " km")) + 34 * s
  }
  if(info.camps_total != null){
    sx = sx + stat(sx, sy, "camps found", concat(string(info.camps_found or 0), " / ", string(info.camps_total))) + 34 * s
  }
  if(daily != null){
    if(daily.counted != null){
      stat(sx, sy, "today's run", ui.clock(daily.counted), colors.amber)
    } else {
      stat(sx, sy, "today's run", "not driven yet", colors.dim)
    }
  } else if(info.best != null){
    stat(sx, sy, "summit run", ui.clock(info.best), colors.amber)
  } else {
    stat(sx, sy, "summit run", "not driven yet", colors.dim)
  }
  // the controls
  hints(x, h - 58 * s, {
    {{"W", "S"}, "drive, brake"}, {{"A", "D"}, "steer"}, {{"Space"}, "hand brake"}, {{"Q"}, "low range"},
    {{"E"}, "locks"}, {{"F"}, "winch"}, {{"R"}, "recover"}, {{"M"}, "map"}, {{"C"}, "camera"}, {{"Esc"}, "pause"},
  })
  if(quit){
    return "quit"
  }
  if(sound.value != m.volume){
    m.volume = sound.value
    return "volume"
  }
  if(chosen != null){
    return actions[chosen]
  }
  return null
}

local MONTHS = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}

// date(iso: string) -> "17 Nov 2026"
func m.date(iso){
  local parts = str.split(iso, "-")
  if(len(parts) != 3){
    return iso
  }
  local month = to_int(str.to_number(parts[1]) or 1)
  return concat(string(to_int(str.to_number(parts[2]) or 1)), " ", MONTHS[math.max(0, math.min(11, month - 1))], " ", parts[0])
}

// ------------------------------------------------------------ the pause

// pause(mode?: string, options?: {quit?: bool}) -> "resume" | "restart" | "map" | "garage" |
//   "volume" | "title" | "quit" | null
// The game held: the scene dimmed, the choices in the middle. Exploring
// (mode "explore") the map is among them and there is nothing to
// restart. Esc (or the gamepad's B or Start) resumes. "volume": the
// player changed the sound's volume ([volume] is the new one).
func m.pause(mode, options){
  local input = moves()
  local s = ui.s
  if(opened("pause")){
    state.selected.pause = 0
  }
  dim_scene(150)
  local sound = {name: "Sound", value: m.volume}
  local entries = {"Resume", "Restart", "Garage", sound, "Title", "Quit"}
  local actions = {"resume", "restart", "garage", "volume", "title", "quit"}
  if(mode == "explore"){
    entries = {"Resume", "Map", "Garage", sound, "Title", "Quit"}
    actions = {"resume", "map", "garage", "volume", "title", "quit"}
  }
  // (options.quit false: no Quit, as on the daily site)
  if(options != null and options.quit == false){
    remove(entries, len(entries) - 1)
    remove(actions, len(actions) - 1)
  }
  local pw = 320 * s
  local ph = (88 + len(entries) * 42) * s
  local px = (ui.w - pw) / 2
  local py = (ui.h - ph) / 2
  ui.panel(px, py, pw, ph, {16, 18, 20, 225})
  ui.label(ui.w / 2, py + 26 * s, "paused", 13, colors.amber, 0)
  rl.draw.rectangle_rec({ui.w / 2 - 22 * s, py + 52 * s, 44 * s, 1.5 * s}, colors.dim)
  local chosen = column("pause", entries, ui.w / 2, py + 74 * s, input, {align: 0, size: 24, step: 42})
  if(input.back or input.start){
    note("back")
    return "resume"
  }
  if(sound.value != m.volume){
    m.volume = sound.value
    return "volume"
  }
  if(chosen != null){
    return actions[chosen]
  }
  return null
}

// ------------------------------------------------------------ the day

// 1 -> "1st", 22 -> "22nd", 113 -> "113th"
local func ordinal(n){
  local tens = n % 100
  local suffix = "th"
  if(tens < 11 or tens > 13){
    local last = n % 10
    if(last == 1){
      suffix = "st"
    } else if(last == 2){
      suffix = "nd"
    } else if(last == 3){
      suffix = "rd"
    }
  }
  return concat(string(n), suffix)
}

// 1234 -> "1,234"
local func thousands(n){
  local text = string(n)
  local out = ""
  local k = 0
  for(local i = len(text) - 1; i >= 0; i = i - 1){
    if(k > 0 and k % 3 == 0){
      out = concat(",", out)
    }
    out = concat(str.substring(text, i, i + 1), out)
    k = k + 1
  }
  return out
}

// the day's times beside the result: where the player's run stands among
// everyone's of the day, as bars of how many took how long, the fastest
// with names (d: game/daily's view())
local func daily_panel(x, y, w, h, d){
  local s = ui.s
  ui.panel(x, y, w, h, {16, 18, 20, 230})
  local left = x + 32 * s
  local right = x + w - 32 * s
  local cx = x + w / 2
  ui.label(cx, y + 26 * s, concat("daily run no. ", string(d.day or 0)), 13, colors.amber, 0)
  if(d.date != null){
    ui.label(cx, y + 46 * s, m.date(d.date), 10, colors.dim, 0)
  }
  local r = d.results
  if(d.status == "sending" or (d.status == null)){
    ui.label(cx, y + h / 2 - 8 * s, "sending your time...", 12, colors.dim, 0)
    return null
  }
  if(d.status == "offline" or r == null){
    ui.label(cx, y + h / 2 - 20 * s, "the day's times could not be reached", 12, colors.paper, 0)
    ui.label(cx, y + h / 2 + 4 * s, d.error or "", 9, colors.dim, 0)
    return null
  }
  // where the player stands
  local yy = y + 74 * s
  if(r.you != null){
    ui.text_center(cx, yy, concat(ordinal(r.you.rank), " of ", thousands(r.count)), 34, colors.paper, 0.03)
    yy = yy + 46 * s
    local share = to_int(r.you.ahead_of * 100 + 0.5)
    local line = if(r.count > 1){ concat("faster than ", string(share), "% of today's drivers") } else { "the first to the summit today" }
    ui.label(cx, yy, line, 11, colors.amber, 0)
  } else {
    ui.text_center(cx, yy, thousands(r.count), 34, colors.paper, 0.03)
    yy = yy + 46 * s
    ui.label(cx, yy, "drivers today", 11, colors.dim, 0)
  }
  yy = yy + 22 * s
  if(d.practice and d.counted != null){
    ui.label(cx, yy, concat("practice: today's counted run was ", ui.clock(d.counted)), 9, colors.dim, 0)
  } else if(d.counted_now){
    ui.label(cx, yy, "this run is your run of the day", 9, colors.dim, 0)
  }
  // the bars
  local counts = r.bins.counts
  local n = len(counts)
  local gy = yy + 26 * s
  local gh = 120 * s
  local base = gy + gh
  if(n > 0){
    local most = 1
    for(let local c in values(counts)){
      most = math.max(most, c)
    }
    local bw = (right - left) / n
    local mine = null
    if(r.you != null){
      mine = math.min(n - 1, math.max(0, to_int(math.floor((r.you.time - r.bins.from) / r.bins.width))))
    }
    for(local k = 0; k < n; k = k + 1){
      local bh = math.max(if(counts[k] > 0){ 2 * s } else { 0 }, gh * counts[k] / most)
      local color = if(k == mine){ colors.amber } else { {242, 234, 216, 110} }
      rl.draw.rectangle_rec({left + k * bw + 1 * s, base - bh, math.max(1, bw - 2 * s), bh}, color)
    }
    rl.draw.rectangle_rec({left, base, right - left, 1 * s}, colors.edge)
    // this run's time, when it is practice (not among the bars)
    local at_time = func(t){
      return left + (t - r.bins.from) / (r.bins.width * n) * (right - left)
    }
    if(d.practice and d.time != null){
      local px = math.max(left, math.min(right, at_time(d.time)))
      rl.draw.rectangle_rec({px - 1 * s, gy - 6 * s, 2 * s, gh + 6 * s}, colors.paper)
      ui.label(px, gy - 20 * s, concat("this run ", ui.clock(d.time)), 9, colors.paper, 0)
    }
    ui.label(left, base + 8 * s, ui.clock(r.bins.from, false), 9, colors.dim)
    ui.label(right, base + 8 * s, concat(ui.clock(r.bins.from + r.bins.width * n, false), "+"), 9, colors.dim, 1)
    if(r.median != null){
      ui.label(cx, base + 8 * s, concat("median ", ui.clock(r.median)), 9, colors.dim, 0)
    }
  }
  // the fastest, by name
  local ty = base + 36 * s
  local top = r.top or {}
  if(len(top) > 0){
    rl.draw.rectangle_rec({left, ty - 6 * s, right - left, 1 * s}, colors.edge)
    for(local i = 0; i < len(top) and ty + 22 * s < y + h - 12 * s; i = i + 1){
      local row = top[i]
      local color = if(row.you){ colors.amber } else { colors.paper }
      // (names as their players wrote them, not in capitals)
      ui.figures(left + 14 * s, ty, concat(string(i + 1), "."), 13, colors.dim, 1)
      ui.text(left + 24 * s, ty - 1 * s, row.name, 16, color)
      ui.figures(right, ty, ui.clock(row.time), 13, color, 1)
      ty = ty + 22 * s
    }
  }
}

// ------------------------------------------------------------ the result

// finish(result: {time?: float, penalty?: float, splits?: {{name: string,
//   time: float, best?: float}}, best?: float, new_best?: bool,
//   recoveries?: int, damage?: float}) -> "again" | "title" | null
// The run's result at the summit: the time (penalties included), the
// best time or that this is it, the splits against the best run's, what
// it cost in recoveries and damage.
// [best]: the best time before this run, seconds
// [daily]: the daily run's view (game/daily's view()): the day's times
//   are drawn beside the result, as a graph with the player's among them
func m.finish(result){
  result = result or {}
  local input = moves()
  local s = ui.s
  if(opened("finish")){
    state.selected.finish = 0
  }
  if(input.start){
    input.accept = true
  }
  dim_scene(165)
  local splits = result.splits or {}
  local rows = len(splits)
  local pw = 560 * s
  local ph = (312 + rows * 23) * s
  local px = (ui.w - pw) / 2
  local py = (ui.h - ph) / 2
  if(result.daily != null){
    local gw = 460 * s
    local gap = 20 * s
    ph = math.max(ph, 470 * s)
    py = (ui.h - ph) / 2
    px = (ui.w - pw - gap - gw) / 2
    daily_panel(px + pw + gap, py, gw, ph, result.daily)
  }
  local cx = px + pw / 2
  ui.panel(px, py, pw, ph, {16, 18, 20, 230})
  mark(cx - 20 * s, py + 20 * s, 40 * s, colors.amber)
  ui.label(cx, py + 66 * s, "summit reached", 13, colors.amber, 0)
  ui.text_center(cx, py + 84 * s, ui.clock(result.time or 0), 60, colors.paper, 0.04)
  local y = py + 152 * s
  if(result.new_best){
    local bw = 96 * s
    ui.pill(cx - bw / 2, y, bw, 20 * s, "new best", true)
  } else if(result.best != null){
    ui.label(cx, y + 4 * s, concat("best ", ui.clock(result.best)), 11, colors.dim, 0)
  }
  y = y + 30 * s
  if((result.penalty or 0) > 0.05){
    ui.label(cx, y - 4 * s, concat("with ", ui.clock(result.penalty, false), " of penalties"), 9, colors.red, 0)
  }
  y = y + 12 * s
  rl.draw.rectangle_rec({px + 36 * s, y, pw - 72 * s, 1 * s}, colors.edge)
  y = y + 12 * s
  // the splits: name, time, against the best
  for(let local split in values(splits)){
    ui.label(px + 40 * s, y + 2 * s, split.name, 10, colors.dim)
    ui.figures(px + pw - 150 * s, y, ui.clock(split.time), 13, colors.paper, 1)
    if(split.best != null){
      local d = split.time - split.best
      ui.figures(px + pw - 40 * s, y, ui.delta(d), 13, if(d <= 0){ colors.green } else { colors.red }, 1)
    }
    y = y + 23 * s
  }
  y = y + 2 * s
  rl.draw.rectangle_rec({px + 36 * s, y, pw - 72 * s, 1 * s}, colors.edge)
  y = y + 12 * s
  local recoveries = result.recoveries or 0
  local damage = to_int((result.damage or 0) * 100 + 0.5)
  ui.label(px + 40 * s, y, concat("recoveries ", string(recoveries)), 10, if(recoveries > 0){ colors.paper } else { colors.dim })
  ui.label(px + pw - 40 * s, y, concat("damage ", string(damage), "%"), 10, if(damage > 0){ colors.paper } else { colors.dim }, 1)
  // the two ways on, side by side
  y = y + 30 * s
  local entries = {"Drive again", "Title"}
  local selected = state.selected.finish or 0
  local was = selected
  if(input.left or input.up){
    selected = 0
  }
  if(input.right or input.down){
    selected = 1
  }
  local chosen = null
  for(local i = 0; i < 2; i = i + 1){
    local w = ui.measure(entries[i], 22)
    local ex = if(i == 0){ cx - 40 * s - w } else { cx + 40 * s }
    local over = ui.inside(ex - 16 * s, y - 6 * s, w + 32 * s, 38 * s)
    if(over and input.moved){
      selected = i
    }
    if(over and input.click){
      selected = i
      chosen = i
    }
    if(i == selected){
      rl.draw.rectangle_rec({ex, y + 28 * s, w, 2.5 * s}, colors.amber)
      ui.text(ex, y, entries[i], 22, colors.amber)
    } else {
      ui.text(ex, y, entries[i], 22, {242, 234, 216, 205})
    }
  }
  if(input.accept){
    chosen = selected
  }
  state.selected.finish = selected
  if(input.back){
    note("back")
    return "title"
  }
  if(chosen != null){
    note("select")
    local actions = {"again", "title"}
    return actions[chosen]
  }
  if(selected != was){
    note("move")
  }
  return null
}

// ------------------------------------------------------------ the garage

// whether a category's options are paints: some have a color
local func paints(options){
  for(let local option in values(options)){
    if(type(option) == "table" and option.color != null){
      return true
    }
  }
  return false
}

// garage(categories: {Category}) -> "back" | null
// The truck's fittings on the left of the screen (the truck itself is
// the game's to show, in the middle and on the right): a row for each
// category with the option it has now. Up and down choose a row, left
// and right (or a click on the arrows, or Enter) change its option:
// `value` is changed in place, and [changed] says whether it was in this
// call. Esc leaves.
// type Category = {name: string, options: {string | Option}, value: int}
// [value]: the index of the option it has, from 0
// type Option = {name: string, color?: {int}, about?: string}
// [color]: shown as a dab of paint before the name
// [about]: a line on the option, shown under the rows while its row is
//   chosen
func m.garage(categories){
  local input = moves()
  local s = ui.s
  m.changed = false
  local count = len(categories)
  // (rows as high as there is room for)
  local row_h = math.max(30, math.min(48, (ui.h / s - 72 - 186) / math.max(1, count))) * s
  local pw = 384 * s
  local ph = 186 * s + count * row_h
  local px = 40 * s
  local py = math.max(16 * s, (ui.h - ph) / 2)
  ui.panel(px, py, pw, ph, {16, 18, 20, 215})
  ui.text(px + 28 * s, py + 20 * s, "Garage", 34, colors.paper)
  ui.label(px + 30 * s, py + 62 * s, "fit out the truck", 10, colors.amber)
  local row = state.row
  if(opened("garage") or row >= count){
    row = 0
  }
  local was = row
  if(input.down and count > 0){
    row = (row + 1) % count
  }
  if(input.up and count > 0){
    row = (row + count - 1) % count
  }
  local about = null
  local y = py + 92 * s
  for(local i = 0; i < count; i = i + 1){
    local category = categories[i]
    local options = category.options or {}
    local n = math.max(1, len(options))
    local over = ui.inside(px + 8 * s, y, pw - 16 * s, row_h - 2 * s)
    if(over and input.moved){
      row = i
    }
    local step = 0
    // the arrows at the row's right end
    local ax = px + pw - 76 * s
    local ay = y + row_h / 2
    local over_left = ui.inside(ax - 12 * s, y, 28 * s, row_h)
    local over_right = ui.inside(ax + 28 * s, y, 32 * s, row_h)
    if(over and input.click){
      row = i
      step = if(over_left){ -1 } else { 1 }
    }
    if(i == row){
      if(input.left){
        step = -1
      }
      if(input.right or input.accept){
        step = 1
      }
      rl.draw.rectangle_rounded({px + 10 * s, y + 1 * s, pw - 20 * s, row_h - 4 * s}, 0.3, 6, {242, 234, 216, 20})
      rl.draw.rectangle_rec({px + 10 * s, y + 9 * s, 3 * s, row_h - 20 * s}, colors.amber)
    }
    if(step != 0 and len(options) > 1){
      category.value = ((category.value or 0) + step + n) % n
      m.changed = true
      note(if(paints(options)){ "paint" } else { "part" })
    }
    local value = category.value or 0
    local option = options[value]
    local name = "-"
    local dab = null
    if(type(option) == "string"){
      name = option
    } else if(option != null){
      name = option.name or "-"
      dab = option.color
      if(i == row){
        about = option.about
      }
    }
    local mid = y + row_h / 2
    ui.label(px + 30 * s, mid - 17 * s, category.name, 9, colors.dim)
    local nx = px + 30 * s
    if(dab != null){
      rl.draw.circle_v({nx + 7 * s, mid + 7 * s}, 7 * s, {dab[0], dab[1], dab[2], 255})
      rl.draw.ring({nx + 7 * s, mid + 7 * s}, 7 * s, 8 * s, 0, 360, 24, colors.dim)
      nx = nx + 23 * s
    }
    ui.text(nx, mid - 4 * s, name, 18, if(i == row){ colors.amber } else { colors.paper })
    local arrow = if(i == row){ colors.paper } else { colors.faint }
    rl.draw.triangle({ax - 4 * s, ay}, {ax + 4 * s, ay + 6 * s}, {ax + 4 * s, ay - 6 * s},
      if(over_left and over){ colors.amber } else { arrow })
    rl.draw.triangle({ax + 48 * s, ay}, {ax + 40 * s, ay - 6 * s}, {ax + 40 * s, ay + 6 * s},
      if(over_right and over){ colors.amber } else { arrow })
    ui.figures(ax + 22 * s, ay - 6 * s, concat(string(value + 1), "/", string(n)), 10, colors.dim, 0)
    y = y + row_h
  }
  state.row = row
  // (a click that changes another row's option is heard as the change)
  if(row != was and not m.changed){
    note("move")
  }
  if(about != null){
    ui.text(px + 30 * s, y + 10 * s, about, 12, colors.dim)
  }
  hints(px + 28 * s, py + ph - 42 * s, {{{"up", "down"}, "choose"}, {{"left", "right"}, "change"}, {{"Esc"}, "done"}}, 11)
  if(input.back){
    note("back")
    return "back"
  }
  return null
}

// ------------------------------------------------------------ controls

local keyboard = {
  {{"W", "S"}, "drive, brake and reverse"},
  {{"A", "D"}, "steer"},
  {{"Space"}, "hand brake"},
  {{"Q"}, "low range"},
  {{"E"}, "differential locks: off, rear, both"},
  {{"F"}, "winch: hook to a tree ahead, release"},
  {{"R"}, "hold: right the truck, or back on the trail"},
  {{"M"}, "map (exploring)"},
  {{"C"}, "camera"},
  {{"Mouse"}, "look around"},
  {{"Esc"}, "pause"},
}

local gamepad = {
  {{"RT"}, "drive"},
  {{"LT"}, "brake and reverse"},
  {{"L stick"}, "steer"},
  {{"A"}, "hand brake"},
  {{"X"}, "low range"},
  {{"Y"}, "differential locks"},
  {{"D-pad up"}, "winch"},
  {{"B"}, "hold: right the truck, or back on the trail"},
  {{"Back"}, "map (exploring)"},
  {{"R stick"}, "look around"},
  {{"Start"}, "pause"},
}

// controls() -> "back" | null
// What the keys and the gamepad do. Any of Esc, Enter or a click leaves.
func m.controls(){
  local input = moves()
  local s = ui.s
  dim_scene(165)
  local pw = 800 * s
  local ph = (140 + len(keyboard) * 34) * s
  local px = (ui.w - pw) / 2
  local py = (ui.h - ph) / 2
  ui.panel(px, py, pw, ph, {16, 18, 20, 230})
  ui.text(px + 40 * s, py + 24 * s, "Controls", 32, colors.paper)
  local sides = {{"keyboard", keyboard, px + 40 * s}, {"gamepad", gamepad, px + pw / 2 + 20 * s}}
  for(let local side in values(sides)){
    local x = side[2]
    local y = py + 84 * s
    ui.label(x, y, side[0], 10, colors.amber)
    y = y + 24 * s
    for(let local line in values(side[1])){
      local kx = x
      for(let local key in values(line[0])){
        kx = kx + ui.key_cap(kx, y, key, 12) + 4 * s
      }
      ui.text(x + 92 * s, y + 4 * s, line[1], 14, colors.paper)
      y = y + 34 * s
    }
  }
  ui.label(px + pw - 40 * s, py + ph - 30 * s, "esc: back", 9, colors.dim, 1)
  if(input.back or input.accept or (input.click and not ui.inside(px, py, pw, ph))){
    note("back")
    return "back"
  }
  return null
}

// ------------------------------------------------------------ loading

// loading(progress: float, text?: string)
// The screen while a valley is made: the game's mark and name, a bar
// filled by progress (0 to 1) and a word on what is being made.
func m.loading(progress, text){
  ui.begin()
  local s = ui.s
  local cx = ui.w / 2
  local cy = ui.h / 2
  // (a rectangle, not a clearing: it covers what was drawn before it in
  // the frame)
  rl.draw.rectangle(0, 0, to_int(ui.w) + 1, to_int(ui.h) + 1, {16, 18, 20, 255})
  mark(cx - 27 * s, cy - 118 * s, 54 * s, colors.amber)
  local name = "SWITCHBACK"
  ui.text(cx - ui.measure(name, 44, 0.09) / 2, cy - 54 * s, name, 44, colors.paper, 0.09)
  local bw = 340 * s
  ui.bar(cx - bw / 2, cy + 22 * s, bw, 3 * s, math.max(0, math.min(1, progress or 0)), colors.amber)
  if(text != null){
    ui.label(cx, cy + 38 * s, text, 10, colors.dim, 0)
  }
}

return m
