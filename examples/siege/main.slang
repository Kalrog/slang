// Siege: a 3D catapult game on the raylib and jolt packages. Drive a
// catapult (a Jolt wheeled vehicle) around a height-map world, aim with
// the mouse, hold to wind and let go to throw at buildings of stone,
// wood and glass with furniture inside and barrels that explode. Points
// for everything knocked loose, smashed or blown up; each level has a
// target and limited ammo. A level editor sculpts the ground, places
// parts, whole buildings, decorations and joints, and saves levels as
// JSON.
//
//   make siege        (or: bin/slang run examples/siege/main.slang)
//
// WASD drive, the mouse aims, hold the left button to wind, release to
// fire; 1-4 choose the ammo; right drag looks around; R rights the
// catapult; Esc pauses; F1 shows the help.
//
// For tests and screenshots, from the environment:
//   SIEGE_FRAMES=n          quit after n frames
//   SIEGE_LEVEL=n           start in level n (from 1) at once
//   SIEGE_AUTOPLAY=1        the catapult drives and fires by itself
//   SIEGE_DEBUG=1           print every scoring event
//   SIEGE_EDITOR=n          open level n in the editor (0: a new level)
//   SIEGE_SHOT=n:file.png   save a screenshot at frame n (comma separated
//                           for several)
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local vec = require("game/vec")
local terrain = require("game/terrain")
local render = require("game/render")
local world = require("game/world")
local vehicle = require("game/vehicle")
local ammo = require("game/ammo")
local particles = require("game/particles")
local sound = require("game/sound")
local ui = require("game/ui")
local hud = require("game/hud")
local levels = require("game/levels")
local time = require("slang/time")
local path_lib = require("slang/path")

local WIDTH = 1280
local HEIGHT = 720
local STEP = 1 / 60

// where the game's files are: levels/ and assets/ next to this file
local dir_of = path_lib.dir

local here = dir_of(dir_of(__PACKAGES.find_source("game/levels").path))
levels.dir = here
hud.dir = here

// ------------------------------------------------------------ the game

local game = {
  screen: "title", // title, play, paused, cleared, failed, editor
  levels: {},
  selected: 0,
  index: 0,
  level: null,
  built: null, // {w, v, t}
  best: {},
  ammo: {},
  ammo_index: 0,
  camera: null,
  cam: {yaw_offset: 0, pitch: 0.42, distance: 12, position: null},
  aim: {yaw: 0, pitch: 0.7},
  pending: 0,
  help: false,
  cleared: false,
  settled_for: 0,
  editing: null, // the editor, while a level is edited (test play returns)
  editor_test: false,
  quit: false,
  time: 0,
}

local autoplay = os.getenv("SIEGE_AUTOPLAY") != null
local debug = os.getenv("SIEGE_DEBUG") != null
local frame_limit = os.getenv("SIEGE_FRAMES")
local shots = {}
if(os.getenv("SIEGE_SHOT") != null){
  for(let local part in values(str.split(os.getenv("SIEGE_SHOT"), ","))){
    local colon = str.index_of(part, ":")
    shots[to_int(str.to_number(str.substring(part, 0, colon)))] = str.substring(part, colon + 1)
  }
}

local func destroy_built(){
  if(game.built != null){
    if(game.built.v != null){
      game.built.v:destroy()
    }
    game.built.w:destroy()
    terrain.unload(game.built.t)
    game.built = null
  }
  particles.clear()
}

local func ammo_left(){
  local n = 0
  for(let local a in values(game.ammo)){
    n = n + a.count
  }
  return n
}

// start(level, options?): play a level
local func start(level, options){
  options = options or {}
  destroy_built()
  game.level = level
  game.built = levels.build(level)
  game.ammo = {}
  for(let local a in values(level.ammo)){
    append(game.ammo, {type: a.type, count: a.count})
  }
  game.ammo_index = 0
  for(local i = 0; i < len(game.ammo); i = i + 1){
    if(game.ammo[i].count > 0){
      game.ammo_index = i
      break
    }
  }
  game.screen = "play"
  game.cleared = false
  game.shown_cleared = false
  game.settled_for = 0
  game.pending = 0
  game.editor_test = options.test or false
  game.cam.yaw_offset = 0
  game.cam.position = null
  hud.reset(0)
  if(not options.test){
    hud.message(level.name, 2.5)
  }
  game.aim = {yaw: 0, pitch: 0.7}
  rl.disable_cursor()
}

local func to_title(){
  destroy_built()
  game.editing = null
  game.screen = "title"
  game.levels = levels.all()
  rl.enable_cursor()
  sound.stop_engine()
}

// ------------------------------------------------------------ the camera

local func update_camera(dt){
  local v = game.built.v
  local w = game.built.w
  local cam = game.cam
  if(rl.is_mouse_button_down(rl.MOUSE_BUTTON_RIGHT)){
    local d = rl.get_mouse_delta()
    cam.yaw_offset = cam.yaw_offset - d.x * 0.006
    cam.pitch = vec.clamp(cam.pitch + d.y * 0.004, 0.12, 1.1)
  } else {
    // the offset eases back behind the catapult while driving
    if(v.speed > 1 or v.speed < -1){
      cam.yaw_offset = cam.yaw_offset * math.max(0, 1 - dt * 1.5)
    }
  }
  cam.distance = vec.clamp(cam.distance - rl.get_mouse_wheel_move() * 0.8, 6, 22)
  // over the shoulder: behind, a little to the side, and high enough to
  // see the arc of a throw
  local yaw = v.yaw + v.arm_yaw * 0.35 + cam.yaw_offset - 0.35
  local pitch = cam.pitch
  local back = {
    x: -math.sin(yaw) * math.cos(pitch) * cam.distance,
    y: math.sin(pitch) * cam.distance + 1.5,
    z: -math.cos(yaw) * math.cos(pitch) * cam.distance,
  }
  local desired = vec.add(v.pos, back)
  // never under the ground
  local ground = terrain.height_at(w.terrain, desired.x, desired.z)
  if(desired.y < ground + 1.2){
    desired.y = ground + 1.2
  }
  if(desired.y < w.terrain.water + 0.8){
    desired.y = w.terrain.water + 0.8
  }
  if(cam.position == null){
    cam.position = desired
  } else {
    cam.position = vec.lerp(cam.position, desired, 1 - math.exp(-dt * 6))
  }
  local aim = v:aim()
  local target = vec.add(v.pos, {x: aim.x * 5, y: 1.6 + aim.y * 2, z: aim.z * 5})
  local shake = w.shake
  local pos = cam.position
  if(shake > 0){
    local s = shake * shake * 0.5
    pos = vec.add(pos, {
      x: math.sin(game.time * 71) * s,
      y: math.cos(game.time * 53) * s,
      z: math.sin(game.time * 67) * s,
    })
  }
  game.camera = {
    position: pos,
    target: target,
    up: {x: 0, y: 1, z: 0},
    fovy: 50,
    projection: rl.CAMERA_PERSPECTIVE,
  }
  sound.listen(pos)
}

// ------------------------------------------------------------ input

local func key_down(...keys){
  for(let local k in values(keys)){
    if(rl.is_key_down(k)){
      return true
    }
  }
  return false
}

local func player_input(dt){
  local w = rl.get_screen_width()
  local h = rl.get_screen_height()
  local mouse = rl.get_mouse_position()
  local forward = 0
  local right = 0
  if(key_down(rl.KEY_W, rl.KEY_UP)){ forward = forward + 1 }
  if(key_down(rl.KEY_S, rl.KEY_DOWN)){ forward = forward - 1 }
  if(key_down(rl.KEY_D, rl.KEY_RIGHT)){ right = right + 1 }
  if(key_down(rl.KEY_A, rl.KEY_LEFT)){ right = right - 1 }
  local v = game.built.v
  // reversing: the wheels turn the other way, as the player expects
  if(v.speed < -0.5 and forward <= 0){
    right = -right
  }
  local handbrake = 0
  if(rl.is_key_down(rl.KEY_SPACE)){
    handbrake = 1
  }
  local brake = 0
  if(forward < 0 and v.speed > 1){
    brake = 1
    forward = 0
  }
  // no throttle: the brakes come on, so it stops when the key is let go
  if(forward == 0){
    brake = math.max(brake, 0.6)
  }
  // the mouse (captured) turns and lifts the arm: moving it right turns
  // right (a negative yaw here: +x is to the left of +z), up lifts
  local delta = rl.get_mouse_delta()
  if(not rl.is_mouse_button_down(rl.MOUSE_BUTTON_RIGHT)){
    game.aim.yaw = vec.clamp(game.aim.yaw - delta.x * 0.0022, -vehicle.MAX_YAW, vehicle.MAX_YAW)
    game.aim.pitch = vec.clamp(game.aim.pitch - delta.y * 0.0018, vehicle.MIN_PITCH, vehicle.MAX_PITCH)
  }
  local charging = rl.is_mouse_button_down(rl.MOUSE_BUTTON_LEFT) and not ui.over_ui() and
    not rl.is_mouse_button_down(rl.MOUSE_BUTTON_RIGHT)
  return {
    forward: forward,
    right: right,
    brake: brake,
    handbrake: handbrake,
    aim_yaw: game.aim.yaw,
    aim_pitch: game.aim.pitch,
    charging: charging,
  }
}

local auto = {phase: 0, timer: 0}

local func auto_input(dt){
  local v = game.built.v
  auto.timer = auto.timer + dt
  local charging = false
  local forward = 0
  if(auto.timer < 1.5){
    forward = 1
  } else if(auto.timer < 3.2){
    charging = true
  } else {
    auto.timer = 0
  }
  return {
    forward: forward,
    right: 0,
    brake: 0,
    handbrake: 0,
    aim_yaw: 0.1 * math.sin(game.time),
    aim_pitch: 0.75,
    charging: charging,
  }
}

local func select_ammo(i){
  if(i >= 0 and i < len(game.ammo) and game.ammo[i].count > 0){
    game.ammo_index = i
    sound.play("ui")
  }
}

local func next_ammo(){
  local n = len(game.ammo)
  for(local k = 1; k <= n; k = k + 1){
    local i = (game.ammo_index + k) % n
    if(game.ammo[i].count > 0){
      game.ammo_index = i
      sound.play("ui")
      return
    }
  }
}

// ------------------------------------------------------------ play

local func fire(shot){
  local kind = game.ammo[game.ammo_index].type
  local a = game.ammo[game.ammo_index]
  if(a.count <= 0){
    return
  }
  a.count = a.count - 1
  local w = game.built.w
  ammo.fire(w, kind, shot)
  sound.play("launch", shot.pos)
  sound.play("thump", shot.pos, 0.6)
  particles.puff(shot.pos, 0.8)
  if(a.count <= 0){
    next_ammo()
  }
  game.built.v.loaded = ammo_left() > 0
}

local func update_play(dt){
  local b = game.built
  local w = b.w
  local v = b.v
  game.time = game.time + dt
  if(rl.is_key_pressed(rl.KEY_ESCAPE)){
    game.screen = "paused"
    rl.enable_cursor()
    sound.stop_engine()
    return
  }
  if(rl.is_key_pressed(rl.KEY_F1) or rl.is_key_pressed(rl.KEY_H)){
    game.help = not game.help
  }
  for(local i = 0; i < 4; i = i + 1){
    if(rl.is_key_pressed(rl.KEY_ONE + i)){
      select_ammo(i)
    }
  }
  if(rl.is_key_pressed(rl.KEY_TAB)){
    next_ammo()
  }
  if(rl.is_key_pressed(rl.KEY_R)){
    v:reset()
    hud.message("back on its wheels", 1.5)
  }
  local input = null
  if(autoplay){
    input = auto_input(dt)
  } else {
    input = player_input(dt)
  }
  if(game.help){
    input.charging = false
  }
  v.loaded = ammo_left() > 0
  // winding clicks
  if(input.charging and v.loaded){
    if(math.floor(v.charge * 12) != math.floor(math.min(1, v.charge + dt / vehicle.CHARGE_TIME) * 12)){
      sound.play("click", null, 0.5)
    }
  }
  local shot = v:update(input, dt)
  if(shot != null){
    fire(shot)
  }
  sound.engine(input.forward, v.speed)
  // fixed physics steps
  game.pending = math.min(game.pending + dt, 0.1)
  for(game.pending >= STEP){
    w:step(STEP)
    game.pending = game.pending - STEP
  }
  v:read()
  particles.update(dt)
  // the world's sounds and points
  for(let local s in values(w.sounds)){
    sound.play(s.name, s.pos, s.volume)
  }
  w.sounds = {}
  if(debug){
    for(let local ev in values(w.events)){
      print("event ", ev.label, " +", ev.points, " at ", ev.pos, " t=", w.time, "\n")
    }
  }
  hud.take(w.events, sound)
  w.events = {}
  hud.update(dt, w.score)
  // into the water: back to the start
  if(v:in_water()){
    particles.splash(v.pos)
    sound.play("splash", v.pos)
    v:reset(game.level.spawn)
    hud.message("Splash! Back to the start", 2.5)
  }
  // the target reached: the screen waits for the wreckage to come to rest
  // (two seconds at least, eight at most), so the fall can be watched
  if(not game.cleared and w.score >= game.level.target and game.level.target > 0){
    game.cleared = true
    game.cleared_at = game.time
    hud.message("target reached!", 2)
  }
  if(game.cleared and game.screen == "play" and not game.shown_cleared){
    local waited = game.time - game.cleared_at
    if((waited > 2 and w:settled()) or waited > 8){
      game.shown_cleared = true
      sound.play("fanfare")
      local key = game.level.key or game.level.name
      if(game.best[key] == null or w.score > game.best[key]){
        game.best[key] = w.score
      }
      game.screen = "cleared"
      rl.enable_cursor()
      sound.stop_engine()
    }
  }
  if(not game.cleared and ammo_left() == 0 and not v:swinging()){
    if(w:settled()){
      game.settled_for = game.settled_for + dt
    } else {
      game.settled_for = 0
    }
    if(game.settled_for > 2.5 or (ammo_left() == 0 and game.time - (game.last_shot or 0) > 12)){
      game.screen = "failed"
      sound.play("lost")
      rl.enable_cursor()
      sound.stop_engine()
    }
  }
  if(shot != null){
    game.last_shot = game.time
  }
  update_camera(dt)
}

local func draw_world(camera, options){
  local b = game.built
  render.backdrop(camera, game.time)
  render.begin(camera)
  render.terrain(b.t)
  b.w:draw({...(options or {}), camera: camera})
  if(b.v != null){
    local a = null
    if(len(game.ammo) > 0){
      a = ammo.types[game.ammo[game.ammo_index].type]
    }
    b.v:draw(a)
  }
  particles.draw(b.t)
  render.water(b.t, game.time)
  if(options != null and options.after != null){
    options.after()
  }
  render.end()
}

local func draw_play(){
  local b = game.built
  local v = b.v
  draw_world(game.camera, {
    after: func(){
      if(v.loaded and not v:swinging() and game.screen == "play"){
        local speed = vehicle.speed_of(v.charge)
        if(not v.charging){
          speed = vehicle.speed_of(0.5)
        }
        local color = {255, 240, 120, 150}
        if(v.charging){
          color = {255, 200, 80, 230}
        }
        render.parabola(v:trajectory(speed, ammo.damping), color)
      }
    },
  })
  local hint = null
  if(game.editor_test){
    hint = "Esc: back to the editor"
  }
  hud.play({
    score: b.w.score,
    target: game.level.target,
    ammo: game.ammo,
    selected: game.ammo_index,
    charge: v.charge,
    charging: v.charging,
    level: game.level,
    cleared: game.cleared,
    hint: hint,
  })
  if(game.help){
    hud.help()
  }
}

// ------------------------------------------------------------ screens

local backdrop = null

local func title_backdrop(){
  local lv = game.levels[game.selected]
  if(lv == null){
    rl.clear_background({30, 34, 44})
    return
  }
  if(backdrop == null or backdrop.level != lv){
    if(backdrop != null){
      backdrop.built.w:destroy()
      terrain.unload(backdrop.built.t)
    }
    backdrop = {level: lv, built: levels.build(lv, {no_vehicle: true}), time: 0}
  }
  backdrop.time = backdrop.time + rl.get_frame_time()
  local b = backdrop.built
  // a slow circle around the middle of the level
  local center = {x: 0, y: 0, z: 0}
  local n = 0
  for(let local e in values(b.w.entities)){
    center = vec.add(center, e.start)
    n = n + 1
  }
  if(n > 0){
    center = vec.scale(center, 1 / n)
  }
  local a = backdrop.time * 0.08
  local camera = {
    position: {x: center.x + math.sin(a) * 34, y: center.y + 14, z: center.z + math.cos(a) * 34},
    target: {x: center.x, y: center.y + 2, z: center.z},
    up: {x: 0, y: 1, z: 0},
    fovy: 45,
    projection: rl.CAMERA_PERSPECTIVE,
  }
  render.backdrop(camera, backdrop.time)
  render.begin(camera)
  render.terrain(b.t)
  b.w:draw({camera: camera})
  render.water(b.t, backdrop.time)
  render.end()
}

local func drop_backdrop(){
  if(backdrop != null){
    backdrop.built.w:destroy()
    terrain.unload(backdrop.built.t)
    backdrop = null
  }
}

local func open_editor(level){
  drop_backdrop()
  destroy_built()
  local editor = require("game/editor")
  game.editing = editor.new(level, {
    test: func(lv){
      start(lv, {test: true})
    },
    exit: func(){
      to_title()
    },
    sound: sound,
    here: here,
  })
  game.screen = "editor"
  rl.enable_cursor()
}

local func update_title(){
  title_backdrop()
  ui.begin()
  local r = hud.title(game.levels, game.selected, game.best)
  game.selected = r.selected
  if(r.start != null){
    drop_backdrop()
    game.index = r.start
    sound.play("ui")
    start(game.levels[r.start])
  } else if(r.editor){
    open_editor(levels.new("New level"))
  } else if(r.edit != null){
    open_editor(levels.copy(game.levels[r.edit]))
  }
  if(rl.is_key_pressed(rl.KEY_ENTER)){
    drop_backdrop()
    game.index = game.selected
    start(game.levels[game.selected])
  }
  if(rl.is_key_pressed(rl.KEY_DOWN)){
    game.selected = (game.selected + 1) % len(game.levels)
  }
  if(rl.is_key_pressed(rl.KEY_UP)){
    game.selected = (game.selected + len(game.levels) - 1) % len(game.levels)
  }
}

local func update_screens(){
  local s = game.screen
  draw_play()
  ui.begin()
  if(s == "paused"){
    local r = hud.paused(game.editor_test)
    if(r.resume or rl.is_key_pressed(rl.KEY_ESCAPE)){
      game.screen = "play"
      rl.disable_cursor()
    } else if(r.restart){
      start(game.level, {test: game.editor_test})
    } else if(r.edit){
      open_editor(levels.copy(game.level))
    } else if(r.back){
      destroy_built()
      game.screen = "editor"
      game.editing:resume()
    } else if(r.levels){
      to_title()
    }
  } else if(s == "cleared"){
    local has_next = not game.editor_test and game.index + 1 < len(game.levels)
    local r = hud.cleared(game.built.w.score, game.level.target, has_next)
    if(r.next or (rl.is_key_pressed(rl.KEY_ENTER) and has_next)){
      game.index = game.index + 1
      game.selected = game.index
      start(game.levels[game.index])
    } else if(r.keep){
      game.screen = "play"
      rl.disable_cursor()
    } else if(r.replay){
      start(game.level, {test: game.editor_test})
    } else if(r.levels){
      if(game.editor_test){
        destroy_built()
        game.screen = "editor"
        game.editing:resume()
      } else {
        to_title()
      }
    }
  } else if(s == "failed"){
    local r = hud.failed(game.built.w.score, game.level.target)
    if(r.retry or rl.is_key_pressed(rl.KEY_R) or rl.is_key_pressed(rl.KEY_ENTER)){
      start(game.level, {test: game.editor_test})
    } else if(r.levels){
      if(game.editor_test){
        destroy_built()
        game.screen = "editor"
        game.editing:resume()
      } else {
        to_title()
      }
    }
  }
}

// ------------------------------------------------------------ main

rl.set_config_flags(rl.FLAG_MSAA_4X_HINT)
rl.init_window(WIDTH, HEIGHT, "Siege")
rl.set_exit_key(rl.KEY_NULL)
rl.set_target_fps(60)
render.init()
hud.init()
sound.init()
game.levels = levels.all()
if(os.getenv("SIEGE_LEVEL") != null){
  game.index = to_int(str.to_number(os.getenv("SIEGE_LEVEL"))) - 1
  game.selected = game.index
  start(game.levels[game.index])
}
if(os.getenv("SIEGE_EDITOR") != null){
  local n = to_int(str.to_number(os.getenv("SIEGE_EDITOR")))
  if(n > 0){
    open_editor(levels.copy(game.levels[n - 1]))
  } else {
    open_editor(levels.new("New level"))
  }
}

local frames = 0
local started = time.clock()
for(not rl.window_should_close() and not game.quit){
  if(frame_limit != null and frames >= to_int(str.to_number(frame_limit))){
    break
  }
  local dt = math.min(rl.get_frame_time(), 0.05)
  rl.begin_drawing()
  if(game.screen == "title"){
    update_title()
  } else if(game.screen == "play"){
    ui.begin()
    update_play(dt)
    // (a screen that opened this frame is handled from the next one: the
    // key that opened it must not close it again)
    draw_play()
  } else if(game.screen == "editor"){
    ui.begin()
    game.editing:frame(dt)
  } else {
    update_screens()
  }
  rl.end_drawing()
  if(shots[frames] != null){
    rl.take_screenshot(shots[frames])
  }
  frames = frames + 1
}
if(frame_limit != null and game.built != null){
  print("siege: ", frames, " frames, score ", game.built.w.score, ", ",
    len(game.built.w.entities), " parts, ", to_int(frames * 1000 / (time.clock() - started)),
    " frames/s\n")
}
destroy_built()
drop_backdrop()
hud.unload()
sound.close()
render.unload()
rl.close_window()
