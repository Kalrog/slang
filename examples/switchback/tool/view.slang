// tool/view: the valley alone, without the game around it: the bot
// drives the trail (or the truck stands) and the camera follows it or
// stays where it is told. For looking at the land, the light and the
// truck, and for pictures.
//
//   cd examples/switchback && ../../bin/slang run tool/view.slang
//
// From the environment:
//   VIEW_SEED=n               the valley's seed (7)
//   VIEW_AT=m                 the truck starts m meters along the trail
//   VIEW_DRIVE=0              the truck stands still (it drives by default)
//   VIEW_PLANTS=0             a bare land: no trees, bushes or rocks
//   VIEW_WINCH=1              the winch is hooked up after a moment
//   VIEW_ANCHOR=1             and the camera goes to what it is hooked to
//   VIEW_CAMERA=x,y,z,tx,ty,tz  a fixed camera: where it is, what it looks at
//   VIEW_ORBIT=distance,height,angle  the camera round the truck (degrees)
//   VIEW_SETUP=text           the truck's setup, as "paint=moss,roof=tent"
//   VIEW_FRAMES=n             quit after n frames
//   VIEW_SHOT=n:file.png      save a screenshot at frame n (several, comma
//                             separated; into the working directory)
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local time = require("slang/time")
local vec = require("game/vec")
local world = require("game/world")
local terrain = require("game/terrain")
local route = require("game/route")
local bot = require("game/bot")
local garage = require("game/garage")
local scene = require("render/scene")

local func numbers(name){
  local text = os.getenv(name)
  if(text == null){
    return null
  }
  local out = {}
  for(let local part in values(str.split(text, ","))){
    append(out, str.to_number(part))
  }
  return out
}

local seed = to_int(str.to_number(os.getenv("VIEW_SEED") or "7"))
local at = str.to_number(os.getenv("VIEW_AT") or "0")
local driving = os.getenv("VIEW_DRIVE") != "0"
local frame_limit = os.getenv("VIEW_FRAMES")
local fixed = numbers("VIEW_CAMERA")
local orbit = numbers("VIEW_ORBIT")
local shots = {}
if(os.getenv("VIEW_SHOT") != null){
  for(let local part in values(str.split(os.getenv("VIEW_SHOT"), ","))){
    local colon = str.index_of(part, ":")
    shots[to_int(str.to_number(str.substring(part, 0, colon)))] = str.substring(part, colon + 1)
  }
}

rl.window.open({width: 1280, height: 720, title: "Switchback: view", msaa: true, vsync: true, fps: 60})
local started = time.clock()
local w = world.new({seed: seed, plants: os.getenv("VIEW_PLANTS") != "0"})
if(os.getenv("VIEW_SETUP") != null){
  w.setup = garage.parse(os.getenv("VIEW_SETUP"))
}
scene.init(rl.c.GetRenderWidth(), rl.c.GetRenderHeight(), w)
print("view: the valley of seed ", seed, " in ", to_int(time.clock() - started), " ms\n")
local driver = bot.new()
if(at > 0){
  driver.index = math.min(len(w.trail.points) - 1, to_int(at / route.STEP))
  world.recover(w, driver.index)
}

local cam = {yaw: null, pos: null}
local func camera(dt){
  local car = w.car
  if(fixed != null){
    return {position: {x: fixed[0], y: fixed[1], z: fixed[2]}, target: {x: fixed[3], y: fixed[4], z: fixed[5]}, focus: car.pos}
  }
  local heading = math.atan2(car.forward.x, car.forward.z)
  if(w.winch != null and os.getenv("VIEW_ANCHOR") != null){
    // (close to what the winch is hooked to, looking back along the line)
    local a = w.winch.anchor
    local back = vec.normalize(vec.sub(w.winch.from, a))
    local side = {x: back.z, y: 0, z: -back.x}
    return {
      position: {x: a.x + back.x * 0.6 + side.x * 2.2, y: a.y + 0.35, z: a.z + back.z * 0.6 + side.z * 2.2},
      target: {x: a.x - back.x * 0.25, y: a.y - 0.1, z: a.z - back.z * 0.25},
      fovy: 46,
      focus: car.pos,
    }
  }
  if(orbit != null){
    local a = heading + orbit[2] * math.pi / 180
    return {
      position: {x: car.pos.x + math.sin(a) * orbit[0], y: car.pos.y + orbit[1], z: car.pos.z + math.cos(a) * orbit[0]},
      target: {x: car.pos.x, y: car.pos.y + 0.8, z: car.pos.z},
      fovy: 50,
      focus: car.pos,
    }
  }
  if(cam.yaw == null){
    cam.yaw = heading
  }
  local turn = heading - cam.yaw
  if(turn > math.pi){
    turn = turn - 2 * math.pi
  } else if(turn < -math.pi){
    turn = turn + 2 * math.pi
  }
  cam.yaw = cam.yaw + turn * (1 - math.exp(-dt * 3))
  local want = {
    x: car.pos.x - math.sin(cam.yaw) * 7.6,
    y: car.pos.y + 2.9,
    z: car.pos.z - math.cos(cam.yaw) * 7.6,
  }
  cam.pos = if(cam.pos == null){ want } else { vec.lerp(cam.pos, want, 1 - math.exp(-dt * 8)) }
  return {position: cam.pos, target: {x: car.pos.x, y: car.pos.y + 1.1, z: car.pos.z}, fovy: 58, focus: car.pos}
}

local frames = 0
local clock = 0
local work = 0
for(not rl.window.should_close){
  if(frame_limit != null and frames >= to_int(str.to_number(frame_limit))){
    break
  }
  if(rl.key.pressed(rl.KEY_ESCAPE)){
    break
  }
  local dt = math.min(rl.frame_time, 0.05)
  clock = clock + dt
  local from = time.clock()
  local input = if(driving){ driver:drive(w, dt) } else { {} }
  if(frames == 40 and os.getenv("VIEW_WINCH") != null){
    print("view: the winch hooked to a ", require("game/winch").attach(w), "\n")
    local a = w.winch.anchor
    print("view: the anchor at ", a.x, " ", a.y, " ", a.z, "; the ground there ", terrain.height_at(w.land, a.x, a.z),
      "; the truck at ", w.car.pos.x, " ", w.car.pos.y, " ", w.car.pos.z, ", the ground under it ",
      terrain.height_at(w.land, w.car.pos.x, w.car.pos.z), "\n")
  }
  world.step(w, input, dt)
  local view = scene.view(camera(dt), clock)
  rl.drawing{
    scene.draw(view, w)
    work = work + time.clock() - from
  }
  if(shots[frames] != null){
    rl.window.screenshot(shots[frames])
  }
  frames = frames + 1
}
if(frame_limit != null){
  print("view: ", frames, " frames, ", to_int(work * 100 / math.max(1, frames)) / 100, " ms of work a frame, ", driver.index * 2, " m along the trail\n")
  local costs = scene.costs()
  print("view: effects ", to_int(costs.effects * 100) / 100, " ms, shadows ", to_int(costs.shadows * 100) / 100, " ms, scene ",
    to_int(costs.scene * 100) / 100, " ms, post ", to_int(costs.post * 100) / 100, " ms\n")
}
scene.unload()
world.destroy(w)
rl.window.close()
