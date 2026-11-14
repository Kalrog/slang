// Switchback: an off-road expedition through a valley made from a seed,
// on the raylib, jolt and kernel packages. Trails lead from the meadow by
// the river through fords, mud, washouts and humps, along the lake, up
// the hillsides in switchbacks, between rock walls and over ledges, to
// lookouts, the headwaters and the summit of the highest mountain; they
// split and meet again. Exploring (the first mode) the valley is the
// player's to drive through: camps are found by coming to them, a truck
// that breaks down is towed to the nearest one, and the map has markers
// and the way to them. The Summit Run is the race: the clock runs from
// the trailhead to the summit, with checkpoints between.
//
//   make switchback      (or: bin/slang run examples/switchback/main.slang)
//
// W and S (or the arrows up and down) drive and brake; S again reverses.
// A and D steer. Space is the hand brake, Q the low range, E the
// differential locks (none, rear, rear and front), F the winch (it hooks
// to a tree ahead and pulls; F again lets go), R held puts the truck back
// on the trail (exploring: rights the truck where it is), C changes the
// camera, M opens the map (exploring), the mouse looks around, Esc
// pauses. A gamepad: right trigger drive, left trigger brake, left stick
// steer, A hand brake, X low range, Y locks, d-pad up the winch, B back on
// the trail, Back the map, right stick look.
//
// For tests and screenshots, from the environment:
//   SWITCHBACK_SEED=n          the valley's seed
//   SWITCHBACK_START=1         straight into the drive (no title)
//   SWITCHBACK_AUTOPLAY=1      the same with the bot driving (the Summit Run)
//   SWITCHBACK_MODE=trail      the Summit Run, not exploring
//   SWITCHBACK_AT=m            the truck starts m meters along the trail
//   SWITCHBACK_SETUP=text      the truck's setup, as "paint=moss,roof=tent"
//   SWITCHBACK_FRAMES=n        quit after n frames
//   SWITCHBACK_SHOT=n:file.png save a screenshot at frame n (several,
//                              comma separated; into the working directory)
//   SWITCHBACK_VIEW=x,y,z,tx,ty,tz  a fixed camera: where it is, what it looks at
//   SWITCHBACK_SCALE=f         the picture's size over the window's pixels
//                              (1 by default; 0.75 is lighter on the GPU)
//   SWITCHBACK_PLAIN=1         no HUD (for pictures of the land)
//   SWITCHBACK_FPS=1           the frames a second in the HUD
//   SWITCHBACK_UNCAPPED=1      no vsync and no frame cap (to measure; with
//                              SWITCHBACK_FRAMES the time of each part of a
//                              frame is printed at the end)
//   SWITCHBACK_DEBUG=1         for testing: the frames a second, and on the
//                              map G (or the middle button) puts the truck
//                              where it points
//   SWITCHBACK_SCREEN=name     starts on a screen: title, drive, pause,
//                              finish, garage, controls, map
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local time = require("slang/time")
local json = require("slang/json")
local vec = require("game/vec")
local world = require("game/world")
local terrain = require("game/terrain")
local route = require("game/route")
local run = require("game/run")
local explore = require("game/explore")
local bot = require("game/bot")
local garage = require("game/garage")
local winch = require("game/winch")
local plants = require("game/plants")
local scene = require("render/scene")
local hud = require("render/hud")
local menu = require("render/menu")
local markers = require("render/markers")
local map = require("render/map")

local WIDTH = 1280
local HEIGHT = 720

local func env_number(name, default){
  local v = os.getenv(name)
  if(v == null){
    return default
  }
  return str.to_number(v)
}

local seed = to_int(env_number("SWITCHBACK_SEED", 7))
local frame_limit = os.getenv("SWITCHBACK_FRAMES")
local autoplay = os.getenv("SWITCHBACK_AUTOPLAY") != null
local skip_title = autoplay or os.getenv("SWITCHBACK_START") != null
local start_at = env_number("SWITCHBACK_AT", 0)
local plain = os.getenv("SWITCHBACK_PLAIN") != null
local debug = os.getenv("SWITCHBACK_DEBUG") != null
local show_fps = debug or os.getenv("SWITCHBACK_FPS") != null
local first_screen = os.getenv("SWITCHBACK_SCREEN")
local uncapped = os.getenv("SWITCHBACK_UNCAPPED") != null
// what the parts of the drive's frames took, ms in all (see SWITCHBACK_FRAMES)
local spent = {driver: 0, physics: 0, rules: 0, scene: 0, hud: 0, present: 0}
local first_mode = if(autoplay or os.getenv("SWITCHBACK_MODE") == "trail"){ "trail" } else { "explore" }
local shots = {}
if(os.getenv("SWITCHBACK_SHOT") != null){
  for(let local part in values(str.split(os.getenv("SWITCHBACK_SHOT"), ","))){
    local colon = str.index_of(part, ":")
    shots[to_int(str.to_number(str.substring(part, 0, colon)))] = str.substring(
      part, colon + 1
    )
  }
}
local fixed_view = null
if(os.getenv("SWITCHBACK_VIEW") != null){
  local v = {}
  for(let local part in values(str.split(os.getenv("SWITCHBACK_VIEW"), ","))){
    append(v, str.to_number(part))
  }
  fixed_view = {
    position: {x: v[0], y: v[1], z: v[2]},
    target: {x: v[3], y: v[4], z: v[5]},
  }
}

// ------------------------------------------------------------ what is kept

// the player's truck and valley, kept between runs of the game
local func settings_file(){
  return concat(os.getenv("HOME") or ".", "/.switchback/settings.json")
}

local func load_settings(){
  local file = settings_file()
  if(not os.exists(file)){
    return {}
  }
  return try { json.decode(os.read_file(file)) } catch { {} }
}

local func save_settings(settings){
  try {
    os.mkdir_all(concat(os.getenv("HOME") or ".", "/.switchback"))
    os.write_file(settings_file(), json.encode(settings))
  } catch {
    null
  }
}

local settings = load_settings()
local setup = garage.complete(settings.setup)
if(os.getenv("SWITCHBACK_SETUP") != null){
  setup = garage.parse(os.getenv("SWITCHBACK_SETUP"))
}
if(os.getenv("SWITCHBACK_SEED") == null and type(settings.seed) == "int"){
  seed = settings.seed
}

// ------------------------------------------------------------ the game

local game = {
  screen: "title", // title, drive, pause, finish, garage, controls, map
  mode: "explore", // explore, or trail (the Summit Run)
  explore: null,   // what was found and marked (game/explore)
  back_to: "title", // where the garage and the controls return to
  world: null,
  run: null,
  driver: null, // the bot, when it drives
  time: 0,
  quit: false,
  fade: 0, // the picture coming up out of black
  camera: {
    yaw: null, pitch: 0.24, distance: 7.6, pos: null, look: 0, look_up: 0,
    idle: 9, mode: 0
  },
  low: false,
  locks: 0, // 0 none, 1 rear, 2 rear and front
  finish_wait: 0,
  title_turn: 0,
}

// new_world(seed): the valley made, shown as it is made
local func new_world(s){
  if(game.world != null){
    scene.unload()
    world.destroy(game.world)
    game.world = null
  }
  local started = time.clock()
  local w = world.new({
    seed: s,
    progress: func(share, what){
      rl.drawing{
        rl.draw.clear({12, 14, 16})
        menu.loading(share, what)
      }
    },
  })
  w.setup = setup
  rl.drawing{
    rl.draw.clear({12, 14, 16})
    menu.loading(0.95, "Opening the view")
  }
  local scale = env_number("SWITCHBACK_SCALE", 1)
  scene.init(
    to_int(rl.c.GetRenderWidth() * scale),
    to_int(rl.c.GetRenderHeight() * scale),
    w,
  )
  game.world = w
  game.run = run.new(w)
  game.explore = explore.new(w)
  markers.found = game.explore.found
  map.init(w.land, {view: settings.map_view})
  map.look(w.car.pos.x, w.car.pos.z)
  game.driver = null
  game.camera.yaw = null
  game.camera.pos = null
  game.fade = 0
  game.low = false
  game.locks = 0
  if(start_at > 0 and w.trail != null){
    local index = math.min(
      len(w.trail.points) - 1,
      to_int(start_at / route.STEP),
    )
    world.recover(w, index)
    game.run.index = index
  }
  print(
    "switchback: the valley of seed ", s, " in ",
    to_int(time.clock() - started), " ms\n"
  )
}

// restart(): the truck back at the trailhead, the clock at zero; or,
// exploring, at the camp it was last at
local func restart(){
  local w = game.world
  markers.gates = game.mode == "trail"
  if(game.mode == "explore"){
    explore.start(game.explore, w)
  } else {
    world.recover(w, 4)
  }
  // (a clean truck for a new run)
  w.car.dirt = 0
  w.car.dust = 0
  hud.clear()
  game.run = run.new(w)
  game.driver = null
  game.camera.yaw = null
  game.camera.pos = null
  game.low = false
  game.locks = 0
}

// ------------------------------------------------------------ input

local func key_down(...keys){
  for(let local k in values(keys)){
    if(rl.key.down(k)){
      return true
    }
  }
  return false
}

local func dead(v){
  if(math.abs(v) < 0.14){
    return 0
  }
  return (v - math.sign(v) * 0.14) / 0.86
}

// the keys' steering is all or nothing: eased in and out, quicker back
// to the middle
local steer = 0

local func player_input(dt){
  local want = 0
  if(key_down(rl.KEY_A, rl.KEY_LEFT)){
    want = want - 1
  }
  if(key_down(rl.KEY_D, rl.KEY_RIGHT)){
    want = want + 1
  }
  local rate = if(want == 0 or want * steer < 0){ 5.5 } else { 3.2 }
  steer = steer + vec.clamp(want - steer, -rate * dt, rate * dt)
  local input = {
    forward: if(key_down(rl.KEY_W, rl.KEY_UP)){ 1 } else { 0 },
    back: if(key_down(rl.KEY_S, rl.KEY_DOWN)){ 1 } else { 0 },
    steer: steer,
    hand_brake: rl.key.down(rl.KEY_SPACE),
    recover: rl.key.down(rl.KEY_R),
  }
  if(rl.key.pressed(rl.KEY_Q)){
    game.low = not game.low
    hud.message(if(game.low){ "Low range" } else { "High range" }, "info", 1.6)
  }
  if(rl.key.pressed(rl.KEY_E)){
    game.locks = (game.locks + 1) % 3
    hud.message(({
      "Differentials open",
      "Rear differential locked",
      "Front and rear locked",
    })[game.locks], "info", 1.8)
  }
  local wants_winch = rl.key.pressed(rl.KEY_F) or
    (rl.gamepad.available(0) and rl.gamepad.pressed(0, rl.GAMEPAD_BUTTON_LEFT_FACE_UP))
  if(wants_winch){
    local w = game.world
    if(w.winch != null){
      winch.release(w)
      hud.message("Winch released", "info", 1.8)
    } else if(setup.bumper != "winch"){
      hud.message("No winch fitted: see the garage", "warn", 2.4)
    } else if(winch.attach(w) == "tree"){
      hud.message("Winch hooked to a tree", "info", 2.2)
    } else {
      hud.message("Winch hooked to a ground anchor", "info", 2.2)
    }
  }
  if(rl.gamepad.available(0)){
    local lx = dead(rl.gamepad.axis(0, rl.GAMEPAD_AXIS_LEFT_X))
    local go = (rl.gamepad.axis(0, rl.GAMEPAD_AXIS_RIGHT_TRIGGER) + 1) / 2
    local stop = (rl.gamepad.axis(0, rl.GAMEPAD_AXIS_LEFT_TRIGGER) + 1) / 2
    if(lx != 0){
      input.steer = lx
      steer = lx
    }
    if(go > 0.04){
      input.forward = go
    }
    if(stop > 0.04){
      input.back = stop
    }
    if(rl.gamepad.down(0, rl.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)){
      input.hand_brake = true
    }
    if(rl.gamepad.down(0, rl.GAMEPAD_BUTTON_RIGHT_FACE_RIGHT)){
      input.recover = true
    }
    if(rl.gamepad.pressed(0, rl.GAMEPAD_BUTTON_RIGHT_FACE_LEFT)){
      game.low = not game.low
      hud.message(
        if(game.low){ "Low range" } else { "High range" }, "info", 1.6
      )
    }
    if(rl.gamepad.pressed(0, rl.GAMEPAD_BUTTON_RIGHT_FACE_UP)){
      game.locks = (game.locks + 1) % 3
      hud.message(({
        "Differentials open",
        "Rear differential locked",
        "Front and rear locked",
      })[game.locks], "info", 1.8)
    }
  }
  input.low = game.low
  input.lock_rear = game.locks >= 1
  input.lock_front = game.locks >= 2
  return input
}

// ------------------------------------------------------------ the camera

// the three views: how far behind, how high, how wide
local VIEWS = {
  {distance: 7.6, height: 2.5, fovy: 58},
  {distance: 11.5, height: 4.2, fovy: 56},
  {distance: 4.6, height: 1.9, fovy: 66},
}

// the camera behind the truck: it follows the truck's heading (not its
// rocking), the mouse turns it away for a look around and it comes back
// by itself, and it stays over the ground and out of the hillside
local func chase_camera(dt){
  local w = game.world
  local car = w.car
  local cam = game.camera
  local view = VIEWS[cam.mode]
  local heading = math.atan2(car.forward.x, car.forward.z)
  if(cam.yaw == null){
    cam.yaw = heading
    cam.look = 0
    cam.look_up = 0
  }
  // the mouse (or the right stick) looks around
  local dx = 0
  local dy = 0
  if(rl.mouse.locked){
    local d = rl.mouse.delta
    dx = d.x * 0.0035
    dy = d.y * 0.0028
  }
  if(rl.gamepad.available(0)){
    dx = dx + dead(rl.gamepad.axis(0, rl.GAMEPAD_AXIS_RIGHT_X)) * 2.4 * dt
    dy = dy + dead(rl.gamepad.axis(0, rl.GAMEPAD_AXIS_RIGHT_Y)) * 1.6 * dt
  }
  if(dx != 0 or dy != 0){
    cam.idle = 0
    cam.look = cam.look - dx
    cam.look_up = vec.clamp(cam.look_up + dy, -0.25, 0.9)
  } else {
    cam.idle = cam.idle + dt
  }
  if(cam.idle > 1.6 and math.abs(car.speed) > 1){
    // back behind the truck once it drives on
    local k = math.exp(-dt * 2.2)
    cam.look = cam.look * k
    cam.look_up = cam.look_up * k
  }
  if(cam.look > math.pi){
    cam.look = cam.look - 2 * math.pi
  } else if(cam.look < -math.pi){
    cam.look = cam.look + 2 * math.pi
  }
  // behind where the truck is heading; backing up, it stays where it was
  local turn = heading - cam.yaw
  if(turn > math.pi){
    turn = turn - 2 * math.pi
  } else if(turn < -math.pi){
    turn = turn + 2 * math.pi
  }
  local follow = if(car.speed > -0.5){ 2.6 +
    math.min(math.abs(car.speed), 12) * 0.14 } else { 0.4 }
  cam.yaw = cam.yaw + turn * (1 - math.exp(-dt * follow))
  local yaw = cam.yaw + cam.look
  // a little higher on a climb, lower on a descent: along the slope
  local slope = math.asin(vec.clamp(car.forward.y, -1, 1))
  local pitch = 0.3 + cam.look_up - slope * 0.5
  local distance = view.distance
  local focus = {x: car.pos.x, y: car.pos.y + 1.0, z: car.pos.z}
  local want = {
    x: focus.x - math.sin(yaw) * math.cos(pitch) * distance,
    y: focus.y + math.sin(pitch) * distance + view.height - 2.2,
    z: focus.z - math.cos(yaw) * math.cos(pitch) * distance,
  }
  // not under the ground, nor with a hill between it and the truck
  local floor = terrain.height_at(w.land, want.x, want.z) + 0.7
  if(want.y < floor){
    want.y = floor
  }
  for(local k = 1; k <= 3; k = k + 1){
    local t = k / 4
    local x = focus.x + (want.x - focus.x) * t
    local z = focus.z + (want.z - focus.z) * t
    local over = terrain.height_at(w.land, x, z) + 0.5 -
      (focus.y + (want.y - focus.y) * t)
    if(over > 0){
      want.y = want.y + over / t
    }
  }
  if(cam.pos == null){
    cam.pos = want
  } else {
    cam.pos = vec.lerp(cam.pos, want, 1 - math.exp(-dt * 9))
  }
  local speed = math.abs(car.speed)
  return {
    position: cam.pos,
    target: {x: focus.x, y: focus.y + 0.25, z: focus.z},
    fovy: view.fovy + vec.clamp(speed / 22, 0, 1) * 9,
    focus: car.pos,
  }
}

// the camera of the title and the garage: slowly round the truck
local func turning_camera(dt, distance, height, speed){
  local w = game.world
  local car = w.car
  game.title_turn = game.title_turn + dt * speed
  local a = game.title_turn + math.atan2(car.forward.x, car.forward.z) + 2.5
  local pos = {
    x: car.pos.x + math.sin(a) * distance,
    y: car.pos.y + height,
    z: car.pos.z + math.cos(a) * distance,
  }
  // not inside a tree: pushed out of the way of every trunk it comes to
  if(w.plants != null){
    for(let local chunk in values(plants.near(w.plants, pos.x, pos.z, 4))){
      for(let local solid in values(plants.solids(w.plants, chunk))){
        if(solid.kind == "cylinder" and solid.half_height > 1.5){
          local dx = pos.x - solid.position.x
          local dz = pos.z - solid.position.z
          local d = math.sqrt(dx * dx + dz * dz)
          local clear = solid.radius + 1.4
          if(d < clear and d > 0.001){
            pos.x = solid.position.x + dx / d * clear
            pos.z = solid.position.z + dz / d * clear
          }
        }
      }
    }
  }
  local floor = terrain.height_at(w.land, pos.x, pos.z) + 0.8
  if(pos.y < floor){
    pos.y = floor
  }
  return {
    position: pos,
    target: {x: car.pos.x, y: car.pos.y + 0.7, z: car.pos.z},
    fovy: 46,
    focus: car.pos,
  }
}

// ------------------------------------------------------------ the screens

local func clock(seconds){
  local m = to_int(seconds / 60)
  local s = seconds - m * 60
  return str.format("%d:%04.1f", m, s)
}

local func handle(events){
  for(let local e in values(events)){
    if(e.kind == "checkpoint"){
      local text = concat(e.name, "  ", clock(e.time))
      if(e.delta != null){
        text = concat(
          text,
          "  ",
          if(e.delta <= 0){ "-" } else { "+" },
          str.format("%.1f", math.abs(e.delta)),
        )
      }
      hud.message(
        text, if(e.delta != null and e.delta > 0){ "warn" } else { "good" }, 3.5
      )
    } else if(e.kind == "section"){
      hud.message(e.name, "title", 2.6)
    } else if(e.kind == "recover"){
      if(game.mode == "explore"){
        hud.message("Back on its wheels", "info", 2.2)
      } else {
        hud.message(
          concat("Back on the trail  +", string(run.RECOVER_PENALTY), " s"),
          "warn", 2.5
        )
      }
      game.camera.yaw = null
      game.camera.pos = null
    } else if(e.kind == "camp"){
      hud.message(e.name, "title", 3)
      if(e.new){
        hud.message("Camp found", "good", 3.5)
      }
    } else if(e.kind == "mended"){
      hud.message("Truck mended", "good", 2.5)
    } else if(e.kind == "breakdown"){
      hud.message(concat("Broken down: towed to ", e.camp), "bad", 4.5)
      game.camera.yaw = null
      game.camera.pos = null
    } else if(e.kind == "trail"){
      hud.message(e.name, "title", 2.6)
    } else if(e.kind == "arrived"){
      hud.message(concat(e.name, " reached"), "good", 3)
    } else if(e.kind == "wreck"){
      hud.message(
        concat("Wrecked: patched up  +", string(run.WRECK_PENALTY), " s"),
        "bad", 3.5
      )
      game.camera.yaw = null
      game.camera.pos = null
    } else if(e.kind == "finish"){
      hud.message(concat("Summit  ", clock(e.time)), "good", 4)
      game.finish_wait = 2.5
    }
  }
}

// a frame of the world drawn through a camera, and what the HUD needs
local func draw_world(camera, options){
  markers.next = game.run.next
  markers.gates = game.mode == "trail"
  local view = scene.view(fixed_view or camera, game.time)
  scene.draw(view, game.world, options)
}

// the map: opened while exploring, the game held behind it
local func open_map(){
  game.screen = "map"
  rl.mouse.locked = false
}

local func update_map(dt){
  local w = game.world
  local e = game.explore
  draw_world(chase_camera(0), {fade: game.fade})
  local view = explore.map(e, w)
  view.land = w.land
  view.debug = debug
  view.truck = {x: w.car.pos.x, z: w.car.pos.z, heading: math.atan2(w.car.forward.x, w.car.forward.z)}
  local action = map.draw(view)
  if(map.view != settings.map_view){
    settings.map_view = map.view
    save_settings(settings)
  }
  if(action == null){
    return
  }
  if(action.kind == "place"){
    local index = explore.mark(e, w, action.x, action.z)
    if(index == null){
      hud.message(concat("No more than ", string(explore.MARKERS), " markers"), "warn", 2.5)
    } else if(e.target == null){
      // (the first marker is the one the way leads to)
      explore.aim(e, w, index)
    }
  } else if(action.kind == "remove"){
    explore.unmark(e, w, action.index)
  } else if(action.kind == "target"){
    explore.aim(e, w, action.index)
  } else if(action.kind == "teleport"){
    // (testing: the truck put there, looking the way it did)
    world.place(w, {x: action.x, z: action.z}, math.atan2(w.car.forward.x, w.car.forward.z))
    explore.aim(e, w, e.target)
    game.camera.yaw = null
    game.camera.pos = null
    hud.message("Teleported", "info", 1.5)
  } else if(action.kind == "close"){
    game.screen = "drive"
    rl.mouse.locked = fixed_view == null
  }
}

local func update_drive(dt){
  local w = game.world
  if(rl.key.pressed(rl.KEY_ESCAPE) or
    (rl.gamepad.available(0) and
      rl.gamepad.pressed(0, rl.GAMEPAD_BUTTON_MIDDLE_RIGHT))){
    game.screen = "pause"
    rl.mouse.locked = false
    draw_world(chase_camera(0), {fade: game.fade})
    return
  }
  if(rl.key.pressed(rl.KEY_C)){
    game.camera.mode = (game.camera.mode + 1) % len(VIEWS)
  }
  if(game.mode == "explore" and (rl.key.pressed(rl.KEY_M) or
    (rl.gamepad.available(0) and rl.gamepad.pressed(0, rl.GAMEPAD_BUTTON_MIDDLE_LEFT)))){
    open_map()
    draw_world(chase_camera(0), {fade: game.fade})
    return
  }
  local input = null
  local t0 = time.clock()
  if(autoplay){
    if(game.driver == null){
      game.driver = bot.new()
      game.driver.index = game.run.index
    }
    input = game.driver:drive(w, dt)
    game.low = input.low == true
    game.locks = if(input.lock_front){ 2 } else if(input.lock_rear){ 1 } else { 0 }
  } else {
    input = player_input(dt)
  }
  local t1 = time.clock()
  world.step(w, input, dt)
  local t2 = time.clock()
  if(w.winch_done){
    w.winch_done = false
    hud.message("Winch in", "info", 1.8)
  }
  local info = null
  if(game.mode == "explore"){
    handle(explore.step(game.explore, w, input, dt))
  } else {
    handle(run.step(game.run, w, input, dt))
  }
  local t3 = time.clock()
  draw_world(chase_camera(dt), {fade: game.fade})
  local t4 = time.clock()
  if(not plain){
    if(game.mode == "explore"){
      info = explore.info(game.explore, w)
    } else {
      info = run.info(game.run, w)
    }
    info.fps = rl.fps
    info.debug = show_fps
    hud.draw(info)
  }
  spent.driver = spent.driver + t1 - t0
  spent.physics = spent.physics + t2 - t1
  spent.rules = spent.rules + t3 - t2
  spent.scene = spent.scene + t4 - t3
  spent.hud = spent.hud + time.clock() - t4
  if(game.run.phase == "finished"){
    game.finish_wait = game.finish_wait - dt
    if(game.finish_wait <= 0){
      game.screen = "finish"
      rl.mouse.locked = false
    }
  }
}

local func update_title(dt){
  local w = game.world
  world.step(w, {}, dt)
  draw_world(turning_camera(dt, 9.5, 2.6, 0.07), {fade: game.fade})
  local best = game.run.best
  local total = 0
  for(let local t in values(w.trails)){
    total = total + t.length
  }
  local action = menu.title({
    seed: seed,
    best: if(best != null){ best.time } else { null },
    trail_length: if(w.trail != null){ w.trail.length } else { 0 },
    trails_length: total,
    camps_found: explore.found(game.explore, w),
    camps_total: len(w.camps),
  })
  if(action == "explore" or action == "drive"){
    game.mode = if(action == "explore"){ "explore" } else { "trail" }
    restart()
    game.screen = "drive"
    rl.mouse.locked = true
  } else if(action == "garage"){
    game.back_to = "title"
    game.screen = "garage"
  } else if(action == "controls"){
    game.back_to = "title"
    game.screen = "controls"
  } else if(action == "seed"){
    seed = seed + 1
    settings.seed = seed
    save_settings(settings)
    new_world(seed)
  } else if(action == "quit"){
    game.quit = true
  }
}

local func update_pause(dt){
  draw_world(chase_camera(0), {fade: game.fade * 0.6})
  local action = menu.pause(game.mode)
  if(action == "resume"){
    game.screen = "drive"
    rl.mouse.locked = true
  } else if(action == "map"){
    open_map()
  } else if(action == "restart"){
    restart()
    game.screen = "drive"
    rl.mouse.locked = true
  } else if(action == "garage"){
    game.back_to = "pause"
    game.screen = "garage"
  } else if(action == "title"){
    restart()
    game.screen = "title"
  } else if(action == "quit"){
    game.quit = true
  }
}

local func update_finish(dt){
  local w = game.world
  world.step(w, {back: 1}, dt)
  draw_world(turning_camera(dt, 10, 3.2, 0.12), {fade: game.fade})
  local action = menu.finish(run.result(game.run))
  if(action == "again"){
    restart()
    game.screen = "drive"
    rl.mouse.locked = true
  } else if(action == "title"){
    restart()
    game.screen = "title"
  }
}

// the garage: the truck turning slowly, what it wears chosen in a menu
local garage_list = null

local func update_garage(dt){
  local w = game.world
  if(game.back_to == "title"){
    world.step(w, {}, dt)
  }
  if(garage_list == null){
    garage_list = {}
    for(let local category in values(garage.categories)){
      append(garage_list, {
        id: category.id,
        name: category.name,
        options: category.options,
        value: math.max(0, garage.index_of(category.id, setup[category.id])),
      })
    }
  }
  draw_world(turning_camera(dt, 8.2, 2.0, 0.16), {fade: game.fade})
  local action = menu.garage(garage_list)
  for(let local entry in values(garage_list)){
    setup[entry.id] = garage.category(entry.id).options[entry.value].id
  }
  w.setup = setup
  if(action == "back"){
    settings.setup = setup
    save_settings(settings)
    garage_list = null
    game.screen = game.back_to
  }
}

local func update_controls(dt){
  local w = game.world
  world.step(w, {}, dt)
  draw_world(turning_camera(dt, 9.5, 2.6, 0.07), {fade: game.fade * 0.5})
  if(menu.controls() == "back"){
    game.screen = game.back_to
  }
}

// ------------------------------------------------------------ main

rl.window.open({
  width: WIDTH, height: HEIGHT, title: "Switchback", msaa: true, vsync: not uncapped,
  fps: if(uncapped){ 0 } else { 60 }
})
rl.window.exit_key = rl.KEY_NULL
hud.init()
menu.init()
game.mode = first_mode
new_world(seed)
markers.gates = game.mode == "trail"
if(skip_title){
  if(game.mode == "explore"){
    explore.start(game.explore, game.world)
  }
  game.screen = "drive"
  rl.mouse.locked = not autoplay and fixed_view == null
}
if(first_screen != null){
  game.screen = first_screen
  if(first_screen == "finish"){
    game.run.phase = "finished"
  }
}

local frames = 0
local work = 0
local began = time.clock()
for(not rl.window.should_close and not game.quit){
  if(frame_limit != null and frames >= to_int(str.to_number(frame_limit))){
    break
  }
  local dt = math.min(rl.frame_time, 0.05)
  game.time = game.time + dt
  game.fade = math.min(1, game.fade + dt * 1.2)
  local from = time.clock()
  rl.drawing{
    if(game.screen == "title"){
      update_title(dt)
    } else if(game.screen == "drive"){
      update_drive(dt)
    } else if(game.screen == "pause"){
      update_pause(dt)
    } else if(game.screen == "finish"){
      update_finish(dt)
    } else if(game.screen == "garage"){
      update_garage(dt)
    } else if(game.screen == "map"){
      update_map(dt)
    } else {
      update_controls(dt)
    }
    work = work + time.clock() - from
  }
  // (the frame handed over: waiting for the graphics card, when it is behind)
  spent.present = spent.present + time.clock() - from
  if(shots[frames] != null){
    rl.window.screenshot(shots[frames])
  }
  frames = frames + 1
}
if(frame_limit != null){
  local r = game.run
  print(
    "switchback: ", frames, " frames, ",
    to_int(work * 100 / math.max(1, frames)) / 100, " ms of work a frame; ",
    to_int(r.index * route.STEP), " m along the trail, checkpoint ", r.next - 1,
    ", ", r.recoveries, " recoveries\n"
  )
  local n = math.max(1, frames)
  local func ms(v){
    return str.format("%.2f", v / n)
  }
  local costs = scene.costs()
  spent.present = spent.present - work
  print(
    "switchback: a frame took ", ms(time.clock() - began), " ms (", to_int(frames * 1000 / math.max(1, time.clock() - began)),
    " a second): bot ", ms(spent.driver), ", physics ", ms(spent.physics), ", rules ", ms(spent.rules),
    ", scene ", ms(spent.scene), " (effects ", str.format("%.2f", costs.effects), ", shadows ", str.format("%.2f", costs.shadows),
    ", scene ", str.format("%.2f", costs.scene), ", post ", str.format("%.2f", costs.post), "), HUD ", ms(spent.hud),
    ", handing over (waiting for the graphics card) ", ms(spent.present), " ms\n"
  )
}
scene.unload()
map.unload()
world.destroy(game.world)
hud.unload()
menu.unload()
rl.window.close()
