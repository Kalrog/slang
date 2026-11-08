// Courier: deliveries by flying car through a night city, on the raylib
// and jolt packages. The city is made from a seed: towers in tiers with
// ledges, fins, billboards and halos sticking out of them, skybridges
// and glass tubes across the streets, traffic in lanes at six heights.
// Pick up a package at one pad, deliver it to another before the clock
// runs out; pay for the distance, the time left and the package in one
// piece. The car flies with pitch, roll and yaw, boosts, and its magnet
// locks it onto any surface to drive along walls and under bridges.
// Close calls with traffic and skimming walls at speed refill the boost;
// hits cost hull, and the wreck costs the job.
//
//   make courier      (or: bin/slang run examples/courier/main.slang)
//
// The mouse steers: it moves a reticle, and the car turns toward it
// (pitch and a banked turn). W thrust, S brake and reverse, A/D roll,
// Q/E yaw, the arrow keys pitch and roll too; Space or the left button
// boosts, F or the right button is the magnet, R goes back to the last
// pad, Esc pauses. A gamepad: left stick pitch and roll, right stick yaw,
// triggers thrust and brake, A boost, X magnet.
//
// For tests and screenshots, from the environment:
//   COURIER_FRAMES=n        quit after n frames
//   COURIER_SEED=n          the city's seed
//   COURIER_LEVEL=n         start in level n (from 1); the title has the menu
//   COURIER_AUTOPLAY=1      start at once with the autopilot flying
//   COURIER_START=1         start at once (no title screen)
//   COURIER_SHOT=n:file.png save a screenshot at frame n (comma separated
//                           for several; relative to the working directory)
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local time = require("slang/time")
local vec = require("game/vec")
local world = require("game/world")
local car_lib = require("game/car")
local bot = require("game/bot")
local render = require("game/render")
local levels = require("game/levels")
local hud = require("game/hud")
local sound = require("game/sound")
local fx = require("game/fx")

local WIDTH = 1280
local HEIGHT = 720

local autoplay = os.getenv("COURIER_AUTOPLAY") != null
local frame_limit = os.getenv("COURIER_FRAMES")
local seed = to_int(str.to_number(os.getenv("COURIER_SEED") or "7"))
local start_level = to_int(str.to_number(os.getenv("COURIER_LEVEL") or "1")) - 1
local shots = {}
if(os.getenv("COURIER_SHOT") != null){
  for(let local part in values(str.split(os.getenv("COURIER_SHOT"), ","))){
    local colon = str.index_of(part, ":")
    shots[to_int(str.to_number(str.substring(part, 0, colon)))] = str.substring(part, colon + 1)
  }
}

// ------------------------------------------------------------ the game

local game = {
  screen: "title",     // title, play, paused
  world: null,
  time: 0,
  quit: false,
  cam: {pos: null, q: null, fov: 62, shake: 0},
  flash: {0, 0, 0},
  hit_time: -10,
  title_angle: 0,
  selected: 0,     // the district chosen on the title
  fresh: false,    // the world was built and not played yet
  level_up: null,
}

// new_world(seed, level, carry?): a city of the level; carry = the world
// before, whose credits and deliveries come along
local func new_world(s, level, carry){
  local options = {seed: s, level: level}
  if(carry != null){
    options.credits = carry.credits
    options.deliveries = carry.deliveries
  }
  if(game.world != null){
    world.destroy(game.world)
  }
  game.world = world.new(options)
  render.build_city(game.world.city)
  render.build_traffic(game.world.traffic)
  game.fresh = true
  game.cam.pos = null
  game.cam.q = null
  fx.clear()
  hud.clear()
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

local func axis(negative, positive){
  local v = 0
  if(negative){ v = v - 1 }
  if(positive){ v = v + 1 }
  return v
}

local func dead(v){
  if(math.abs(v) < 0.12){
    return 0
  }
  return v
}

// the mouse as a stick: its movement shifts a reticle, the car turns
// toward the reticle, and the reticle drifts back to the middle when the
// mouse rests
local stick = {x: 0, y: 0}
local MOUSE_SENSITIVITY = 0.0022
local DEAD_ZONE = 0.06

local func update_stick(dt){
  local d = rl.mouse.delta
  stick.x = stick.x + d.x * MOUSE_SENSITIVITY
  stick.y = stick.y + d.y * MOUSE_SENSITIVITY
  local l = math.sqrt(stick.x * stick.x + stick.y * stick.y)
  if(l > 1){
    stick.x = stick.x / l
    stick.y = stick.y / l
  }
  local k = math.exp(-dt * 1.4)
  stick.x = stick.x * k
  stick.y = stick.y * k
}

// a stick axis past its dead zone, back on the full range
local func deflection(v){
  if(math.abs(v) < DEAD_ZONE){
    return 0
  }
  return (v - math.sign(v) * DEAD_ZONE) / (1 - DEAD_ZONE)
}

local func player_input(dt){
  update_stick(dt)
  local input = {
    pitch: axis(rl.key.down(rl.KEY_DOWN), rl.key.down(rl.KEY_UP)),
    roll: axis(key_down(rl.KEY_A, rl.KEY_LEFT), key_down(rl.KEY_D, rl.KEY_RIGHT)),
    yaw: axis(rl.key.down(rl.KEY_Q), rl.key.down(rl.KEY_E)),
    throttle: 0,
    brake: 0,
    boost: rl.key.down(rl.KEY_SPACE) or rl.mouse.down(rl.MOUSE_BUTTON_LEFT),
    magnet: rl.key.pressed(rl.KEY_F) or rl.mouse.pressed(rl.MOUSE_BUTTON_RIGHT),
  }
  // the mouse: down on the screen is nose down, sideways a banked turn
  local sx = deflection(stick.x)
  local sy = deflection(stick.y)
  input.pitch = vec.clamp(input.pitch + sy, -1, 1)
  input.yaw = vec.clamp(input.yaw + sx, -1, 1)
  input.roll = vec.clamp(input.roll + sx * 0.55, -1, 1)
  if(key_down(rl.KEY_W, rl.KEY_LEFT_SHIFT, rl.KEY_RIGHT_SHIFT)){
    input.throttle = 1
  }
  if(key_down(rl.KEY_S, rl.KEY_X, rl.KEY_LEFT_CONTROL, rl.KEY_RIGHT_CONTROL)){
    input.brake = 1
  }
  if(rl.gamepad.available(0)){
    local lx = dead(rl.gamepad.axis(0, rl.GAMEPAD_AXIS_LEFT_X))
    local ly = dead(rl.gamepad.axis(0, rl.GAMEPAD_AXIS_LEFT_Y))
    local rx = dead(rl.gamepad.axis(0, rl.GAMEPAD_AXIS_RIGHT_X))
    local rt = (rl.gamepad.axis(0, rl.GAMEPAD_AXIS_RIGHT_TRIGGER) + 1) / 2
    local lt = (rl.gamepad.axis(0, rl.GAMEPAD_AXIS_LEFT_TRIGGER) + 1) / 2
    if(lx != 0){ input.roll = lx }
    if(ly != 0){ input.pitch = -ly }
    if(rx != 0){ input.yaw = rx }
    if(rt > 0.05){ input.throttle = rt }
    if(lt > 0.05){ input.brake = lt }
    if(rl.gamepad.down(0, rl.GAMEPAD_BUTTON_RIGHT_FACE_DOWN)){ input.boost = true }
    if(rl.gamepad.pressed(0, rl.GAMEPAD_BUTTON_RIGHT_FACE_LEFT)){ input.magnet = true }
  }
  return input
}

// ------------------------------------------------------------ the camera

local func update_camera(dt){
  local w = game.world
  local car = w.car
  local cam = game.cam
  local speed = car.speed
  if(cam.q == null){
    cam.q = car.q
  }
  // the view turns after the car, slower when the magnet turns it onto
  // a wall, so the roll can be felt
  local follow = 5
  if(car.mode == "stick"){
    follow = 3.5
  }
  cam.q = vec.quat_slerp(cam.q, car.q, 1 - math.exp(-dt * follow))
  local axes = vec.axes(cam.q)
  local car_axes = vec.axes(car.q)
  local back = 6.5 + speed * 0.05
  local lift = 2.2 + speed * 0.012
  local desired = vec.add(vec.add_scaled(car.pos, axes.forward, -back), vec.scale(axes.up, lift))
  // not through a wall: pull in to what the ray from the car hits
  local to = vec.sub(desired, car.pos)
  local from = vec.add_scaled(car.pos, vec.normalize(to), 2.6)
  local hit = w.phys.jw:cast_ray(from, vec.sub(desired, from))
  if(hit != null){
    local what = w.phys.by_id[hit.body.id]
    if(what != null and what.box != null){
      desired = vec.lerp(from, desired, math.max(0, hit.fraction - 0.1))
    }
  }
  if(cam.pos == null){
    cam.pos = desired
  } else {
    cam.pos = vec.lerp(cam.pos, desired, 1 - math.exp(-dt * 14))
  }
  local pos = cam.pos
  cam.shake = math.max(0, cam.shake - dt * 2.5)
  if(cam.shake > 0){
    local s = cam.shake * cam.shake * 0.4
    pos = vec.add(pos, {
      x: math.sin(game.time * 83) * s,
      y: math.cos(game.time * 61) * s,
      z: math.sin(game.time * 71) * s,
    })
  }
  local boost = 0
  if(car.boosting){
    boost = 1
  }
  local want_fov = 60 + 26 * vec.clamp(speed / 95, 0, 1) + boost * 6
  cam.fov = vec.approach(cam.fov, want_fov, 4, dt)
  return {
    position: pos,
    target: vec.add(vec.add_scaled(car.pos, car_axes.forward, 10), vec.scale(car_axes.up, 0.6)),
    up: axes.up,
    fovy: cam.fov,
    projection: rl.CAMERA_PERSPECTIVE,
  }
}

// the title's camera: a slow turn around the start pad
local func title_camera(dt){
  local w = game.world
  local car = w.car
  game.title_angle = game.title_angle + dt * 0.12
  local a = game.title_angle
  local r = 30
  return {
    position: {x: car.pos.x + math.sin(a) * r, y: car.pos.y + 8, z: car.pos.z + math.cos(a) * r},
    target: {x: car.pos.x, y: car.pos.y + 2, z: car.pos.z},
    up: {x: 0, y: 1, z: 0},
    fovy: 55,
    projection: rl.CAMERA_PERSPECTIVE,
  }
}

// ------------------------------------------------------------ events

local func handle_events(w){
  for(let local e in values(w.events)){
    if(e.kind == "hit"){
      sound.play("hit", vec.clamp(e.impact / 25, 0.3, 1))
      fx.sparks(e.pos, e.normal, e.impact)
      game.cam.shake = math.min(1.5, game.cam.shake + e.impact * 0.03)
      game.flash = {0.35, 0.02, 0.0}
      game.hit_time = game.time
    } else if(e.kind == "scrape"){
      if(game.time - game.hit_time > 0.3){
        sound.play("scrape", 0.4)
        fx.sparks(e.pos, e.normal, 2)
        game.hit_time = game.time
      }
    } else if(e.kind == "smash"){
      sound.play("hit", 1)
      fx.sparks(e.pos, {x: 0, y: 1, z: 0}, e.impact + 10)
      hud.message("SMASH", hud.colors.orange, 1.2)
      game.cam.shake = math.min(1.5, game.cam.shake + 0.4)
    } else if(e.kind == "close_call"){
      sound.play("whoosh", 0.9)
      hud.message("CLOSE CALL  +boost", hud.colors.cyan, 1.2)
      game.flash = {0.0, 0.08, 0.12}
    } else if(e.kind == "pickup"){
      sound.play("pickup")
      fx.burst(e.job.from, {0, 230, 255})
      hud.message(concat("picked up ", e.job.what), hud.colors.cyan, 2.5)
      hud.message(concat("deliver to ", e.job.to.name), hud.colors.orange, 3)
    } else if(e.kind == "deliver"){
      sound.play("deliver")
      fx.burst(e.job.to, {255, 150, 40})
      hud.message(concat("DELIVERED  +$", string(e.pay)), hud.colors.green, 3)
      game.flash = {0.05, 0.12, 0.05}
    } else if(e.kind == "late"){
      sound.play("late")
      hud.message("LATE: a third of the pay", hud.colors.red, 3)
    } else if(e.kind == "job"){
      if(w.deliveries > 0 or w.time > 1){
        hud.message(concat("new job: ", e.job.what, " at ", e.job.from.name), hud.colors.white, 3)
      }
    } else if(e.kind == "attach"){
      sound.play("clunk", 0.8)
      game.cam.shake = math.min(1.5, game.cam.shake + 0.25)
    } else if(e.kind == "detach"){
      if(e.why == "released"){
        sound.play("release", 0.6)
      }
    } else if(e.kind == "magnet"){
      sound.play("ui", 0.5)
    } else if(e.kind == "wreck"){
      sound.play("wreck")
      sound.stop_loops()
      game.cam.shake = 1.5
      game.flash = {0.5, 0.05, 0.0}
      hud.message("WRECKED  -$50", hud.colors.red, 3)
    } else if(e.kind == "respawn"){
      hud.message("back at the pad", hud.colors.white, 2)
    } else if(e.kind == "level_up"){
      sound.play("deliver")
      game.level_up = e.next
    }
  }
}

// ------------------------------------------------------------ frames

local func draw_world(camera){
  local w = game.world
  render.scene(camera, game.time){
    render.city(camera)
    render.traffic(w.traffic, camera, game.time)
    render.car(w.car, game.time)
    local target = world.target(w)
    if(target != null){
      local color = {0, 230, 255}
      if(w.job.phase == "deliver"){
        color = {255, 150, 40}
      }
      render.beacon(target, color, game.time)
    }
    fx.draw(w.car)
  }
}

local func present(o){
  // the flash fades
  local f = game.flash
  local k = math.exp(-rl.frame_time * 6)
  game.flash = {f[0] * k, f[1] * k, f[2] * k}
  render.present(o)
}

local func update_play(dt){
  local w = game.world
  if(rl.key.pressed(rl.KEY_ESCAPE)){
    game.screen = "paused"
    sound.stop_loops()
    rl.mouse.locked = false
    return
  }
  local input = null
  if(autoplay){
    input = bot.input(w, dt)
  } else {
    input = player_input(dt)
  }
  if(rl.key.pressed(rl.KEY_R) and w.state == "play"){
    local pad = w.last_pad
    car_lib.place(w.car, {x: pad.x, y: pad.y + car_lib.CLEARANCE + 0.2, z: pad.z}, 0)
    w.credits = math.max(0, w.credits - 20)
    hud.message("back to the pad  -$20", hud.colors.dim, 2)
  }
  world.step(w, input, dt)
  handle_events(w)
  if(game.level_up != null){
    // on to the next district: a new city, the earnings kept
    local next = game.level_up
    game.level_up = null
    seed = seed + 1
    new_world(seed, next, w)
    w = game.world
    sound.stop_loops()
    hud.message(concat("LEVEL ", string(next + 1), ": ", w.level.name), hud.colors.orange, 4)
    hud.message(concat("pick up ", w.job.what, " at ", w.job.from.name), hud.colors.cyan, 4)
  }
  if(w.state == "play"){
    sound.engine(w.car)
  }
  hud.update(dt)
  local camera = update_camera(dt)
  fx.update(dt, w.car, camera)
  draw_world(camera)
  local car = w.car
  local speed_k = vec.clamp((car.speed - 30) / 70, 0, 1)
  local aberration = 0
  if(car.boosting){
    aberration = 1
    speed_k = math.min(1, speed_k + 0.3)
  }
  present({speed: speed_k, aberration: aberration, flash: game.flash})
  local shown = null
  if(not autoplay){
    shown = stick
  }
  hud.play(w, camera, {autoplay: autoplay, stick: shown})
}

local func update_title(dt){
  local w = game.world
  local idle = {pitch: 0, roll: 0, yaw: 0, throttle: 0, brake: 0, boost: false, magnet: false}
  world.step(w, idle, dt)
  w.job.left = w.job.limit
  game.world.events = {}
  local camera = title_camera(dt)
  fx.update(dt, w.car, camera)
  draw_world(camera)
  present({dim: 0.8})
  local menu = hud.title(game.time, game.selected)
  // choosing a district
  local count = len(levels.list)
  if(rl.key.pressed(rl.KEY_DOWN) or rl.key.pressed(rl.KEY_S)){
    game.selected = (game.selected + 1) % count
    sound.play("ui", 0.5)
  }
  if(rl.key.pressed(rl.KEY_UP) or rl.key.pressed(rl.KEY_W)){
    game.selected = (game.selected + count - 1) % count
    sound.play("ui", 0.5)
  }
  if(menu.hover != null and menu.hover != game.selected){
    game.selected = menu.hover
    sound.play("ui", 0.3)
  }
  local clicked = menu.hover != null and rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT)
  if(clicked or rl.key.pressed(rl.KEY_ENTER) or rl.key.pressed(rl.KEY_SPACE) or
    (rl.gamepad.available(0) and rl.gamepad.pressed(0, rl.GAMEPAD_BUTTON_MIDDLE_RIGHT))){
    if(not game.fresh or game.selected != w.level_index){
      seed = seed + 1
      new_world(seed, game.selected)
      w = game.world
    }
    game.fresh = false
    game.screen = "play"
    sound.play("ui")
    hud.message(concat("LEVEL ", string(w.level_index + 1), ": ", w.level.name), hud.colors.orange, 3)
    hud.message(concat("pick up ", w.job.what, " at ", w.job.from.name), hud.colors.cyan, 4)
    if(not autoplay){
      rl.mouse.locked = true
      stick = {x: 0, y: 0}
    }
  }
}

local func update_paused(dt){
  local camera = update_camera(0)
  draw_world(camera)
  present({dim: 0.5})
  hud.play(game.world, camera, {autoplay: autoplay})
  hud.paused()
  if(rl.key.pressed(rl.KEY_ESCAPE)){
    game.screen = "play"
    if(not autoplay){
      rl.mouse.locked = true
      stick = {x: 0, y: 0}
    }
  } else if(rl.key.pressed(rl.KEY_ENTER)){
    // back to the menu; the game goes on behind it until a district is chosen
    game.screen = "title"
    rl.mouse.locked = false
  } else if(rl.key.pressed(rl.KEY_Q)){
    game.quit = true
  }
}

// ------------------------------------------------------------ main

rl.window.open({width: WIDTH, height: HEIGHT, title: "Courier", msaa: true, vsync: true, fps: 60})
rl.window.exit_key = rl.KEY_NULL
render.init(WIDTH, HEIGHT)
hud.init()
sound.init()
game.selected = math.min(start_level, len(levels.list) - 1)
new_world(seed, start_level)
if(autoplay or os.getenv("COURIER_START") != null){
  game.screen = "play"
  if(not autoplay){
    rl.mouse.locked = true
  }
}

local frames = 0
local started = time.clock()
for(not rl.window.should_close and not game.quit){
  if(frame_limit != null and frames >= to_int(str.to_number(frame_limit))){
    break
  }
  local dt = math.min(rl.frame_time, 0.05)
  game.time = game.time + dt
  rl.drawing{
    if(game.screen == "title"){
      update_title(dt)
    } else if(game.screen == "play"){
      update_play(dt)
    } else {
      update_paused(dt)
    }
  }
  if(shots[frames] != null){
    rl.window.screenshot(shots[frames])
  }
  frames = frames + 1
}
if(frame_limit != null){
  local w = game.world
  print("courier: ", frames, " frames, ", to_int(frames * 1000 / math.max(1, time.clock() - started)),
    " frames/s, $", w.credits, ", ", w.deliveries, " delivered, hull ", to_int(w.car.hull * 100),
    "%, level ", w.level_index + 1, " ", w.level.name, "\n")
}
world.destroy(game.world)
sound.close()
render.unload()
hud.unload()
rl.window.close()
