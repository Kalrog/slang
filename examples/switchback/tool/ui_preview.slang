// tool/ui_preview: the HUD and the menus on their own, over a made-up
// picture and with made-up numbers, for looking at them without the
// game.
//
//   cd examples/switchback && ../../bin/slang run tool/ui_preview.slang
//
// The keys 1 to 9 choose the screen: 1 the HUD, 2 the title, 3 the pause,
// 4 the result, 5 the garage, 6 the controls, 7 the loading screen, 8
// the HUD again in trouble (leaning, wheels in the air, a penalty), 9
// the HUD given nothing, 0 the HUD while exploring; M the map (of a real
// valley: made when it is first shown, a few seconds); B changes the
// picture behind (a bright day, a dark wood, a plain grey).
//
// From the environment, for screenshots:
//   UI_SCREEN=name     hud, title, pause, finish, garage, controls,
//                      loading, trouble, bare, explore, map, pause_explore
//                      or bench
//   UI_SEED=n          the valley of the map (7)
//   UI_VIEW=name       the map's view: relief or topo
//   UI_ZOOM=f          the map's zoom to start at (pixels a meter)
//   UI_MOUSE=x,y       the map: the mouse held still there (for the hover)
//   UI_BG=name         bright, dark or plain
//   UI_FRAMES=n        quit after n frames
//   UI_SHOT=file.png   save the last frame (into the working directory)
//   UI_TIME=seconds    the made-up clock starts there
//   UI_SIZE=WxH        the window's size (1280x720)
//   UI_KEYS=a,b,...    keys pressed by themselves, one every ten frames
//                      from the thirtieth on: up, down, left, right,
//                      enter, esc (what a menu answers is printed)
// The screen "bench" draws the HUD driving and in trouble in turns and
// says what each costs, and what sending it to the graphics card costs.
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local time = require("slang/time")
local table = require("slang/table")
local ui = require("render/ui")
local hud = require("render/hud")
local menu = require("render/menu")
local map = require("render/map")
local terrain = require("game/terrain")

local screen = os.getenv("UI_SCREEN") or "hud"
local background = os.getenv("UI_BG") or "bright"
local frame_limit = os.getenv("UI_FRAMES")
local shot = os.getenv("UI_SHOT")
local clock = str.to_number(os.getenv("UI_TIME") or "0")

local width = 1280
local height = 720
if(os.getenv("UI_SIZE") != null){
  local parts = str.split(os.getenv("UI_SIZE"), "x")
  width = to_int(str.to_number(parts[0]))
  height = to_int(str.to_number(parts[1]))
}
rl.window.open({width: width, height: height, title: "Switchback: interface", msaa: true, vsync: true, fps: 60, resizable: true})
rl.window.exit_key = rl.KEY_NULL

// keys pressed by themselves: the menus ask raylib, so raylib's answer
// is what is changed
local script = {}
local script_key = null
if(os.getenv("UI_KEYS") != null){
  local codes = {
    up: rl.KEY_UP, down: rl.KEY_DOWN, left: rl.KEY_LEFT, right: rl.KEY_RIGHT,
    enter: rl.KEY_ENTER, esc: rl.KEY_ESCAPE,
  }
  for(let local name in values(str.split(os.getenv("UI_KEYS"), ","))){
    append(script, codes[name])
  }
  local real = rl.key.pressed
  rl.key.pressed = func(key){
    return key == script_key or real(key)
  }
}
hud.init()
menu.init()

// a trail that winds, a point every 2 m
local points = {}
local x = 0
local z = 0
local heading = 0.3
for(local i = 0; i < 1200; i = i + 1){
  append(points, {x: x, z: z})
  heading = 0.3 + 1.1 * math.sin(i * 0.017) + 0.7 * math.sin(i * 0.0061 + 1.0)
  x = x + math.sin(heading) * 2
  z = z + math.cos(heading) * 2
}
local checkpoints = {}
local names = {"Trailhead", "River Camp", "Lakeside", "Timber Camp", "High Bench", "The Shoulder", "Summit"}
for(local i = 0; i < len(names); i = i + 1){
  local at = to_int((len(points) - 1) * i / (len(names) - 1))
  local p = points[at]
  append(checkpoints, {x: p.x, z: p.z, index: at, name: names[i]})
}

local categories = {
  {name: "Paint", value: 2, options: {
    {name: "Dune", color: {196, 168, 122}}, {name: "Moss", color: {88, 104, 62}},
    {name: "Ember", color: {196, 84, 32}}, {name: "Glacier", color: {150, 176, 190}},
    {name: "Night", color: {24, 26, 30}},
  }},
  {name: "Roof", options: {"Body color", "Chalk", "Night"}, value: 0},
  {name: "Wheels", value: 1, options: {
    {name: "Steel", about: "pressed steel, painted"},
    {name: "Beadlock", about: "black, a bolted ring holds the bead"},
    {name: "Six spoke", about: "cast alloy"},
  }},
  {name: "Front bumper", options: {"Stock", "Bull bar", "Winch bumper"}, value: 2},
  {name: "Roof load", options: {"Bare", "Basket rack", "Expedition", "Roof tent"}, value: 1},
  {name: "Light bar", options: {"None", "Over the windscreen"}, value: 0},
  {name: "Snorkel", options: {"None", "Raised intake"}, value: 1},
  {name: "Spare wheel", options: {"On the tailgate", "None"}, value: 0},
  {name: "Sills", options: {"Bare", "Rock sliders", "Side steps"}, value: 1},
  {name: "Mud flaps", options: {"None", "Fitted"}, value: 0},
}

// the picture behind: something like a day in the valley, a dark wood,
// or a plain grey
local func backdrop(){
  local w = to_int(ui.w) + 1
  local h = to_int(ui.h) + 1
  if(background == "plain"){
    rl.draw.clear({120, 124, 128})
    return
  }
  if(background == "dark"){
    rl.draw.rectangle_gradient_v(0, 0, w, to_int(h * 0.45), {18, 26, 44, 255}, {40, 52, 60, 255})
    rl.draw.rectangle_gradient_v(0, to_int(h * 0.45), w, h - to_int(h * 0.45), {22, 34, 24, 255}, {10, 16, 10, 255})
    rl.draw.triangle({w * 0.1, h * 0.45}, {w * 0.55, h * 0.45}, {w * 0.3, h * 0.2}, {30, 40, 52, 255})
    rl.draw.triangle({w * 0.45, h * 0.45}, {w * 0.95, h * 0.45}, {w * 0.72, h * 0.14}, {26, 34, 46, 255})
    return
  }
  rl.draw.rectangle_gradient_v(0, 0, w, to_int(h * 0.42), {96, 150, 214, 255}, {196, 216, 232, 255})
  rl.draw.rectangle_gradient_v(0, to_int(h * 0.42), w, h - to_int(h * 0.42), {120, 150, 70, 255}, {70, 104, 40, 255})
  rl.draw.triangle({w * 0.05, h * 0.42}, {w * 0.5, h * 0.42}, {w * 0.26, h * 0.16}, {150, 150, 150, 255})
  rl.draw.triangle({w * 0.4, h * 0.42}, {w * 0.98, h * 0.42}, {w * 0.7, h * 0.08}, {176, 176, 182, 255})
  rl.draw.triangle({w * 0.62, h * 0.2}, {w * 0.78, h * 0.2}, {w * 0.7, h * 0.08}, {240, 244, 250, 255})
  // the track and something truck-sized in the lower middle
  rl.draw.triangle({w * 0.5, h * 0.44}, {w * 0.4, h}, {w * 0.62, h}, {150, 116, 80, 255})
  rl.draw.rectangle_rounded({w * 0.44, h * 0.56, w * 0.13, h * 0.2}, 0.2, 6, {206, 104, 44, 255})
}

// made-up numbers for the HUD at a time
local func info_at(t, trouble){
  local speed = 6 + 4 * math.sin(t * 0.4)
  local gear = 2 + to_int(speed / 5)
  local rpm = 1400 + 2600 * (0.5 + 0.5 * math.sin(t * 1.7))
  local index = to_int((t * 6) % (len(points) - 200)) + 20
  local a = points[index]
  local b = points[index + 2]
  local next = 0
  for(local i = 0; i < len(checkpoints); i = i + 1){
    if(checkpoints[i].index > index){
      next = i
      break
    }
  }
  local c = checkpoints[next]
  local yaw = math.atan2(b.x - a.x, b.z - a.z)
  local info = {
    speed: speed, rpm: rpm, redline: 4500, limiter: 4650, idle: 750, gear: gear, low: false,
    shifting: false, clutch: 1, throttle: 0.5 + 0.5 * math.sin(t * 1.1), brake: 0,
    hand_brake: false, holding: false, locks: {front: false, rear: false, center: false},
    pitch: 0.12 * math.sin(t * 0.7), roll: 0.08 * math.sin(t * 0.9 + 1), heading: yaw,
    wheels: {
      {contact: true, slip: 0.02, load: 1.1}, {contact: true, slip: 0.03, load: 0.9},
      {contact: true, slip: 0.05, load: 1.0}, {contact: true, slip: 0.04, load: 1.0},
    },
    surface: "dirt", time: clock + t, running: true, penalty: 0,
    checkpoint: {
      name: c.name, distance: math.sqrt((c.x - a.x) * (c.x - a.x) + (c.z - a.z) * (c.z - a.z)),
      bearing: math.atan2(c.x - a.x, c.z - a.z), index: next, total: len(checkpoints) - 1,
    },
    splits: {{name: "River Camp", time: 119.1, best: 122.3}, {name: "Lakeside", time: 236.5, best: 233.1}},
    progress: index / (len(points) - 1),
    trail: {points: points, position: {x: a.x, z: a.z}, index: index, checkpoints: checkpoints},
    damage: 0, fps: rl.fps, debug: true,
  }
  if(trouble){
    info.speed = 0.8
    info.gear = 1
    info.low = true
    info.rpm = 4480 + 60 * math.sin(t * 9)
    info.throttle = 1
    info.locks = {front: false, rear: true, center: true}
    info.pitch = 0.36
    info.roll = -0.58
    info.wheels = {
      {contact: true, slip: 0.9, load: 0.5}, {contact: false, slip: 0, load: 0},
      {contact: true, slip: 0.8, load: 1.3}, {contact: true, slip: 0.1, load: 1.2},
    }
    info.surface = "rock"
    info.penalty = 20
    info.damage = 0.42
    info.recover = true
    info.recover_hold = (t * 0.8) % 1
    info.section = {name: "Rock Steps"}
    info.holding = false
    info.hand_brake = false
  }
  return info
}

local result = {
  time: 821.4, penalty: 20, best: 842.7, new_best: true, recoveries: 1, damage: 0.12,
  splits: {
    {name: "River Camp", time: 119.1, best: 122.3}, {name: "Lakeside", time: 236.5, best: 233.1},
    {name: "Timber Camp", time: 364.3, best: 371.0}, {name: "High Bench", time: 492.7, best: 498.2},
    {name: "The Shoulder", time: 636.8, best: 651.5}, {name: "Summit", time: 821.4, best: 842.7},
  },
}

// ------------------------------------------------------------ exploring

// made-up trails that meet and part: the trail above, and others leaving
// it to wind off somewhere, each a point every 2 m
local func branch(from, turn, count, seed){
  local out = {}
  local p = points[from]
  local x = p.x
  local z = p.z
  local q = points[from + 1]
  local yaw = math.atan2(q.x - p.x, q.z - p.z) + turn
  for(local i = 0; i < count; i = i + 1){
    append(out, {x: x, z: z})
    yaw = yaw + 0.02 * math.sin(i * 0.031 + seed) + 0.012 * math.sin(i * 0.007 + seed * 3)
    x = x + math.sin(yaw) * 2
    z = z + math.cos(yaw) * 2
  }
  return out
}

local network = {
  trails: {
    {name: "Summit Trail", kind: "main", points: points},
    {name: "Bear Ridge Trail", kind: "branch", points: branch(60, 1.1, 500, 1)},
    {name: "Lake Loop", kind: "loop", points: branch(420, -1.2, 700, 2)},
    {name: "Cedar Gully", kind: "branch", points: branch(800, 0.9, 400, 3)},
  },
}
network.camps = {}
for(local i = 0; i < len(checkpoints); i = i + 1){
  local c = checkpoints[i]
  append(network.camps, {name: c.name, x: c.x, z: c.z, found: i < 3})
}
for(let local t in values(network.trails)){
  if(t.kind != "main"){
    local p = t.points[len(t.points) - 1]
    append(network.camps, {name: concat(t.name, " Camp"), x: p.x, z: p.z, found: false})
  }
}
local ends = network.trails[1].points
network.markers = {
  {x: ends[len(ends) - 1].x + 30, z: ends[len(ends) - 1].z + 10, name: "the ledge"},
  {x: points[900].x - 60, z: points[900].z + 40},
}
network.target = 0

local func explore_info(t){
  local info = info_at(t, false)
  local index = info.trail.index
  info.mode = "explore"
  info.place = "Bear Ridge Trail"
  info.camps_found = 3
  info.camps_total = len(network.camps)
  info.repair = (t * 0.25) % 1
  // the way to the marker: down the trail to the branch and up it
  local route = {}
  for(local i = index; i >= 60; i = i - 1){
    append(route, points[i])
  }
  for(let local p in values(ends)){
    append(route, p)
  }
  info.network = {
    position: info.trail.position, trails: network.trails, route: route, camps: network.camps,
    markers: network.markers, target: 0,
  }
  info.trail = null
  local m = network.markers[0]
  local a = info.network.position
  info.checkpoint = {name: "Marker 1", distance: 1840, bearing: math.atan2(m.x - a.x, m.z - a.z)}
  info.recover_text = "hold to right the truck"
  info.recover = t % 6 > 4
  info.damage = 0.3
  return info
}

// the map of a real valley, with made-up trails laid on it where the
// valley's own cannot be had
local real = null

local func real_view(){
  if(real != null){
    return real
  }
  local seed = to_int(str.to_number(os.getenv("UI_SEED") or "7"))
  rl.drawing{
    rl.draw.clear({12, 14, 16})
    menu.loading(0.3, "raising the mountains")
  }
  local land = terrain.generate(seed)
  local trails = {}
  try {
    local route = require("game/route")
    local trail = route.plan(land)
    route.carve(land, trail)
    append(trails, {name: "Summit Trail", kind: "main", points: trail.points})
  } catch {
    null
  }
  terrain.finish(land)
  local from = time.clock()
  map.init(land, {view: os.getenv("UI_VIEW")})
  print("ui_preview: the map's picture in ", to_int(time.clock() - from), " ms\n")
  // (and the made-up trails moved to the trailhead's side of the valley)
  local main = if(len(trails) > 0){ trails[0].points } else { points }
  if(len(trails) == 0){
    append(trails, network.trails[0])
  }
  local start = main[0]
  for(local k = 1; k < len(network.trails); k = k + 1){
    local t = network.trails[k]
    local at = to_int(len(main) * (0.15 + 0.25 * k))
    local o = main[at]
    local shifted = {}
    local first = t.points[0]
    for(let local p in values(t.points)){
      append(shifted, {x: p.x - first.x + o.x, z: p.z - first.z + o.z})
    }
    append(trails, {name: t.name, kind: t.kind, points: shifted})
  }
  local camps = {}
  local names = {}
  for(local k = 0; k < len(trails); k = k + 1){
    local p = trails[k].points
    local e = p[len(p) - 1]
    append(camps, {name: concat(trails[k].name, " Camp"), x: e.x, z: e.z, found: k < 2})
    append(names, {name: trails[k].name, x: p[to_int(len(p) / 2)].x, z: p[to_int(len(p) / 2)].z})
  }
  append(camps, {name: "Trailhead", x: start.x, z: start.z, found: true})
  local truck = main[to_int(len(main) * 0.3)]
  local next = main[to_int(len(main) * 0.3) + 2]
  local b = trails[1].points
  local route = {}
  for(local i = to_int(len(main) * 0.3); i >= to_int(len(main) * 0.4) - 1 and i >= 0; i = i - 1){
    append(route, main[i])
  }
  for(local i = to_int(len(main) * 0.3); i <= to_int(len(main) * 0.4); i = i + 1){
    append(route, main[i])
  }
  for(let local p in values(b)){
    append(route, p)
  }
  local last = b[len(b) - 1]
  real = {
    land: land, trails: trails, camps: camps, names: names,
    truck: {x: truck.x, z: truck.z, heading: math.atan2(next.x - truck.x, next.z - truck.z)},
    markers: {{x: last.x + 40, z: last.z + 25, name: "the ledge"}, {x: truck.x - 300, z: truck.z + 200}},
    target: 0, route: route,
  }
  if(os.getenv("UI_ZOOM") != null){
    map.look(truck.x, truck.z, str.to_number(os.getenv("UI_ZOOM")))
  }
  return real
}

local screens = {"hud", "title", "pause", "finish", "garage", "controls", "loading", "trouble", "bare", "explore"}
local frames = 0
local t = 0
local costs = {}
local costs_trouble = {}
local costs_sent = {}
local said = false
for(not rl.window.should_close){
  if(frame_limit != null and frames >= to_int(str.to_number(frame_limit))){
    break
  }
  local dt = rl.frame_time
  t = t + dt
  for(local i = 0; i < 9; i = i + 1){
    if(rl.key.pressed(rl.KEY_ONE + i)){
      screen = screens[i]
    }
  }
  if(rl.key.pressed(rl.KEY_ZERO)){
    screen = "explore"
  }
  if(screen != "map" and rl.key.pressed(rl.KEY_M)){
    screen = "map"
  }
  script_key = null
  if(frames >= 30 and frames % 10 == 0 and (frames - 30) / 10 < len(script)){
    script_key = script[to_int((frames - 30) / 10)]
  }
  if(rl.key.pressed(rl.KEY_B)){
    background = if(background == "bright"){ "dark" } else if(background == "dark"){ "plain" } else { "bright" }
  }
  if((screen == "hud" or screen == "trouble" or screen == "bench") and not said and t > 0.6){
    said = true
    hud.message("River Camp  1:59.1  -3.2", "good")
    if(screen == "trouble"){
      hud.message("Back on the trail  +20 s", "warn")
      hud.message("Wrecked: patched up  +45 s", "bad")
    } else {
      hud.message("Low range", "info")
    }
  }
  rl.drawing{
    ui.begin()
    backdrop()
    local action = null
    if(screen == "hud" or screen == "trouble"){
      local info = info_at(t, screen == "trouble")
      local from = time.clock()
      hud.draw(info)
      append(costs, time.clock() - from)
    } else if(screen == "bench"){
      // (what was drawn before is sent to the graphics card first, and
      // the HUD after it, so that sending it is timed by itself)
      local trouble = frames % 2 == 1
      local info = info_at(t, trouble)
      rl.c.rlDrawRenderBatchActive()
      local from = time.clock()
      hud.draw(info)
      local drawn = time.clock()
      rl.c.rlDrawRenderBatchActive()
      append(if(trouble){ costs_trouble } else { costs }, drawn - from)
      append(costs_sent, time.clock() - drawn)
    } else if(screen == "bare"){
      hud.draw({})
      hud.draw(null)
    } else if(screen == "title"){
      action = menu.title({seed: 7, best: 801.4, trail_length: 4796, trails_length: 21430, camps_found: 3, camps_total: 14})
    } else if(screen == "pause"){
      action = menu.pause()
    } else if(screen == "pause_explore"){
      action = menu.pause("explore")
    } else if(screen == "explore"){
      hud.draw(explore_info(t))
    } else if(screen == "map"){
      local view = real_view()
      if(os.getenv("UI_MOUSE") != null){
        local xy = str.split(os.getenv("UI_MOUSE"), ",")
        rl.mouse.position = {x: str.to_number(xy[0]), y: str.to_number(xy[1])}
      }
      local done = map.draw(view)
      if(done != null){
        print("ui_preview: map -> ", done.kind, " ", done.index or "", " ", done.x or "", " ", done.z or "", "\n")
        if(done.kind == "place"){
          append(view.markers, {x: done.x, z: done.z})
        } else if(done.kind == "remove"){
          remove(view.markers, done.index)
          view.target = null
        } else if(done.kind == "target"){
          view.target = done.index
        } else if(done.kind == "view"){
          null
        } else if(done.kind == "close"){
          screen = "explore"
        }
      }
    } else if(screen == "finish"){
      action = menu.finish(result)
    } else if(screen == "garage"){
      action = menu.garage(categories)
    } else if(screen == "controls"){
      action = menu.controls()
    } else if(screen == "loading"){
      menu.loading((t * 0.3) % 1, "raising the mountains")
    }
    if(action != null){
      print("ui_preview: ", screen, " -> ", action, "\n")
      if(action == "quit"){
        frame_limit = "0"
      }
    }
    if(screen == "garage" and menu.changed){
      local list = {}
      for(let local category in values(categories)){
        append(list, string(category.value))
      }
      print("ui_preview: garage changed: ", str.join(list, " "), "\n")
    }
  }
  frames = frames + 1
  if(shot != null and frame_limit != null and frames == to_int(str.to_number(frame_limit)) - 1){
    rl.window.screenshot(shot)
  }
}
// (the mean has the collector's work and whatever else the machine did
// in it; the median is a frame of the HUD alone)
local func say_cost(name, list){
  if(len(list) == 0){
    return
  }
  local sum = 0
  for(let local c in values(list)){
    sum = sum + c
  }
  table.sort(list, func(a, b){ return a < b })
  print(
    "ui_preview: ", name, " ", str.format("%.3f", sum / len(list)), " ms a frame (median ",
    str.format("%.3f", list[to_int(len(list) / 2)]), ", slowest ", str.format("%.3f", list[len(list) - 1]),
    ") over ", len(list), " frames\n"
  )
}
say_cost("hud.draw", costs)
say_cost("hud.draw in trouble", costs_trouble)
say_cost("sending the HUD to the graphics card", costs_sent)
map.unload()
hud.unload()
menu.unload()
rl.window.close()
