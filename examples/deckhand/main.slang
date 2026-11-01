// Deckhand: a first-person heist game in the spirit of Quadrilateral
// Cowboy. Plug your deck into hack ports and program the building in
// slang: doors, cameras and lasers are objects on the port's network.
//
//   make deckhand        (or: bin/slang run examples/deckhand/main.slang)
//
// WASD or arrows move, the mouse looks, E jacks into the port you look
// at. On the deck: Enter runs, Shift+Enter starts a new line, Up/Down
// recall, Ctrl+C stops scripts, Esc unplugs (scripts keep running).
//
// For tests and screenshots, from the environment:
//   DECKHAND_DEMO=<mission>   the autopilot plays that mission's solution
//   DECKHAND_FRAMES=n         quit after n frames
//   DECKHAND_SHOT=n:file.png  save a screenshot at frame n (comma separated
//                             for several; raylib saves into the working
//                             directory)
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local missions = require("game/missions")
local world = require("game/world")
local render = require("game/render")
local hud = require("game/hud")
local editor = require("game/editor")
local autopilot = require("game/autopilot")
local solutions = require("game/solutions")
local utf8 = require("slang/utf8")

local width = 1280
local height = 720
local MOUSE = 0.0025

local game = {
  screen: "title", selected: 0, index: 0, w: null, level: null, ed: null,
  best: {}, pilot: null, typed_at: 0.0
}

// ------------------------------------------------------------ the demo

local demo = os.getenv("DECKHAND_DEMO")
local frame_limit = os.getenv("DECKHAND_FRAMES")
local shots = {}
if(os.getenv("DECKHAND_SHOT") != null){
  for(let local part in values(str.split(os.getenv("DECKHAND_SHOT"), ","))){
    local colon = str.index_of(part, ":")
    shots[to_int(str.to_number(str.substring(part, 0, colon)))] = str.substring(
      part, colon + 1
    )
  }
}

// ------------------------------------------------------------ flow

local func mission_index(name){
  for(local i = 0; i < len(missions); i = i + 1){
    if(missions[i].name == name){
      return i
    }
  }
  error("no mission called ", name)
}

local func start(i){
  if(game.level != null){
    render.unload(game.level)
  }
  game.index = i
  game.w = world.new(missions[i])
  game.level = render.load(game.w)
  game.ed = editor.new()
  game.screen = "play"
  game.pilot = null
  if(demo != null){
    game.pilot = autopilot.new(game.w, solutions[missions[i].name])
  } else {
    rl.disable_cursor()
  }
}

local func to_menu(screen){
  game.screen = screen
  rl.enable_cursor()
}

// ------------------------------------------------------------ the deck's keys

local func pressed(key){
  return rl.is_key_pressed(key) or rl.is_key_pressed_repeat(key)
}

// drain(): forgets typed characters (the E that jacked in)
local func drain(){
  for(rl.get_char_pressed() > 0){ }
}

local func deck_keys(){
  local w = game.w
  local ed = game.ed
  local ctrl = rl.is_key_down(rl.KEY_LEFT_CONTROL) or
    rl.is_key_down(rl.KEY_RIGHT_CONTROL)
  local cmd = rl.is_key_down(rl.KEY_LEFT_SUPER) or
    rl.is_key_down(rl.KEY_RIGHT_SUPER)
  local shift = rl.is_key_down(rl.KEY_LEFT_SHIFT) or
    rl.is_key_down(rl.KEY_RIGHT_SHIFT)
  if(rl.is_key_pressed(rl.KEY_ESCAPE)){
    w:unjack()
    drain()
    return
  }
  if((ctrl or cmd) and rl.is_key_pressed(rl.KEY_C)){
    w.deck:stop_all()
    drain()
    return
  }
  if((ctrl or cmd) and rl.is_key_pressed(rl.KEY_V)){
    local clip = rl.get_clipboard_text()
    if(clip != null){
      ed:insert(str.replace(clip, "\r", ""))
    }
    drain()
    return
  }
  for(local c = rl.get_char_pressed(); c > 0; c = rl.get_char_pressed()){
    if(c >= 32 and c < 127 and not ctrl and not cmd){
      ed:insert(utf8.char(c))
    }
  }
  if(rl.is_key_pressed(rl.KEY_ENTER) or rl.is_key_pressed(rl.KEY_KP_ENTER)){
    if(shift){
      ed:insert("\n")
    } else {
      w:type_code(ed:take())
    }
  }
  if(pressed(rl.KEY_BACKSPACE)){ ed:backspace() }
  if(pressed(rl.KEY_DELETE)){ ed:delete() }
  if(pressed(rl.KEY_LEFT)){ ed:left() }
  if(pressed(rl.KEY_RIGHT)){ ed:right() }
  if(pressed(rl.KEY_HOME)){ ed:home() }
  if(pressed(rl.KEY_END)){ ed:end_() }
  if(pressed(rl.KEY_UP)){ ed:up() }
  if(pressed(rl.KEY_DOWN)){ ed:down() }
}

// ------------------------------------------------------------ input

local func player_input(){
  local f = 0
  local s = 0
  if(rl.is_key_down(rl.KEY_W) or rl.is_key_down(rl.KEY_UP)){ f = f + 1 }
  if(rl.is_key_down(rl.KEY_S) or rl.is_key_down(rl.KEY_DOWN)){ f = f - 1 }
  if(rl.is_key_down(rl.KEY_D)){ s = s + 1 }
  if(rl.is_key_down(rl.KEY_A)){ s = s - 1 }
  local turn = 0
  if(rl.is_key_down(rl.KEY_RIGHT)){ turn = turn + 2.2 * rl.get_frame_time() }
  if(rl.is_key_down(rl.KEY_LEFT)){ turn = turn - 2.2 * rl.get_frame_time() }
  local mouse = rl.get_mouse_delta()
  return {
    forward: f,
    strafe: s,
    turn: turn + mouse.x * MOUSE,
    look: -mouse.y * MOUSE,
    use: rl.is_key_pressed(rl.KEY_E),
  }
}

// demo_input(dt) -> the autopilot's input; it types code at a readable pace
local func demo_input(dt){
  local pilot = game.pilot
  local step = pilot.steps[pilot.index]
  if(step != null and step.type != null and game.ed.text != step.type){
    game.typed_at = game.typed_at + dt
    if(game.typed_at > 0.05){
      game.typed_at = 0.0
      game.ed:insert(str.substring(
        step.type, len(game.ed.text), len(game.ed.text) + 1
      ))
    }
    return {}
  }
  if(step != null and step.type != null){
    // linger on what was typed before running it (not after: scripts run
    // on the clock, and the solutions have little slack)
    game.typed_at = game.typed_at + dt
    if(game.typed_at < 0.8){
      return {}
    }
    game.ed:take()
  }
  game.typed_at = 0.0
  return pilot:input(dt)
}

local func update_play(dt){
  local w = game.w
  local input = {}
  if(game.pilot != null){
    input = demo_input(dt)
  } else if(w.jacked != null){
    deck_keys()
  } else {
    if(rl.is_key_pressed(rl.KEY_ESCAPE)){
      to_menu("paused")
      return
    }
    input = player_input()
  }
  local was = w.jacked
  w:update(dt, input)
  if(was == null and w.jacked != null){
    drain()
  }
  if(w.state == "caught"){
    to_menu("caught")
  } else if(w.state == "complete"){
    local name = missions[game.index].name
    game.previous_best = game.best[name]
    if(game.best[name] == null or w.time < game.best[name]){
      game.best[name] = w.time
    }
    to_menu("complete")
  }
}

local func update(dt){
  local s = game.screen
  if(s == "title"){
    if(rl.is_key_pressed(rl.KEY_UP)){
      game.selected = (game.selected + len(missions) - 1) % len(missions)
    }
    if(rl.is_key_pressed(rl.KEY_DOWN)){
      game.selected = (game.selected + 1) % len(missions)
    }
    for(local k = 0; k < len(missions) and k < 9; k = k + 1){
      if(rl.is_key_pressed(rl.KEY_ONE + k)){
        game.selected = k
      }
    }
    if(rl.is_key_pressed(rl.KEY_ENTER)){
      game.screen = "briefing"
    }
    if(rl.is_key_pressed(rl.KEY_ESCAPE)){
      game.quit = true
    }
  } else if(s == "briefing"){
    if(rl.is_key_pressed(rl.KEY_ENTER)){
      start(game.selected)
    }
    if(rl.is_key_pressed(rl.KEY_ESCAPE)){
      game.screen = "title"
    }
  } else if(s == "play"){
    update_play(dt)
  } else if(s == "paused"){
    if(rl.is_key_pressed(rl.KEY_ESCAPE)){
      game.screen = "play"
      rl.disable_cursor()
    }
    if(rl.is_key_pressed(rl.KEY_R)){
      start(game.index)
    }
    if(rl.is_key_pressed(rl.KEY_Q)){
      game.screen = "title"
    }
  } else if(s == "caught"){
    if(rl.is_key_pressed(rl.KEY_R)){
      start(game.index)
    }
    if(rl.is_key_pressed(rl.KEY_ESCAPE)){
      game.screen = "title"
    }
  } else if(s == "complete"){
    if(rl.is_key_pressed(rl.KEY_ENTER)){
      if(game.index + 1 < len(missions)){
        game.selected = game.index + 1
        game.screen = "briefing"
      } else {
        game.screen = "title"
      }
    }
    if(rl.is_key_pressed(rl.KEY_R)){
      start(game.index)
    }
    if(rl.is_key_pressed(rl.KEY_ESCAPE)){
      game.screen = "title"
    }
  }
}

// ------------------------------------------------------------ drawing

// the title screen shows the first job's map behind it
local backdrop = null

local func draw(){
  rl.begin_drawing()
  local s = game.screen
  if(game.w != null and s != "title" and s != "briefing"){
    local cam = render.camera(game.w)
    render.draw(game.w, game.level, cam)
    render.labels(game.w, cam)
    if(s == "play" or s == "paused"){
      hud.play(game.w, missions[game.index])
      if(game.w.jacked != null){
        hud.deck(game.w, game.ed, math.floor(rl.get_time() * 2.5) % 2 == 0)
      }
    }
    if(s == "paused"){
      hud.paused()
    } else if(s == "caught"){
      hud.caught(game.w)
    } else if(s == "complete"){
      hud.complete(game.w, game.previous_best, game.index + 1 >= len(missions))
    }
  } else {
    if(backdrop == null){
      local w = world.new(missions[0])
      backdrop = {w: w, level: render.load(w)}
    }
    // a slow look around the first job
    local p = backdrop.w.player
    p.yaw = rl.get_time() * 0.15
    backdrop.w.time = rl.get_time()
    render.draw(backdrop.w, backdrop.level, render.camera(backdrop.w))
    if(s == "title"){
      hud.title(missions, game.selected, game.best)
    } else {
      hud.briefing(missions[game.selected])
    }
  }
  rl.end_drawing()
}

// ------------------------------------------------------------ main

rl.set_config_flags(rl.FLAG_MSAA_4X_HINT)
rl.init_window(width, height, "Deckhand")
rl.set_exit_key(rl.KEY_NULL)
rl.set_target_fps(60)
if(demo != null){
  start(mission_index(demo))
}

local frames = 0
local outcome = "quit"
for(; not rl.window_should_close() and not game.quit; frames = frames + 1){
  if(frame_limit != null and frames >= to_int(str.to_number(frame_limit))){
    break
  }
  // a long frame (a window drag) would let you walk through a closing door
  update(math.min(rl.get_frame_time(), 0.05))
  draw()
  if(shots[frames] != null){
    rl.take_screenshot(shots[frames])
  }
  if(demo != null and game.screen != "play"){
    outcome = game.screen
    if(game.end_frames == null){
      game.end_frames = frames + 90
    }
    if(frames >= game.end_frames){
      break
    }
  }
}
rl.close_window()
if(demo != null){
  print("deckhand: ", frames, " frames, ", outcome, "\n")
}
