// tool/showroom: the cars and the buildings on their own, under the
// game's shaders, to look at while working on them and to take
// screenshots of.
//
//     slang run tool/showroom.slang
//
// Tab switches what is shown: one car on a turntable, every car in a row
// (the lineup), or one block of a district. Left/Right: the next car, or
// the next seed of the block; Up/Down: the car's palette, or the
// district. The mouse orbits (drag with the left button), the wheel
// zooms, Space stops or starts the turn, F frames it again, G shows a
// block's neighbours too (3 x 3), O looks through each hole in turn, B turns the bloom pass off and on, H
// hides the text, P saves a screenshot (showroom-N.png, in the working
// directory).
//
// For screenshots without a hand on the mouse, from the environment:
//   SHOWROOM_MODE=car|lineup|building
//   SHOWROOM_ITEM=n        the car design, or the block's seed
//   SHOWROOM_PALETTE=n     the car's palette
//   SHOWROOM_LEVEL=n       the district (from 1)
//   SHOWROOM_GRID=1        a block's neighbours too
//   SHOWROOM_YAW=deg, SHOWROOM_PITCH=deg, SHOWROOM_DIST=k (times the framed distance)
//   SHOWROOM_LOOK=f        how high on the block the camera looks (0..1)
//   SHOWROOM_SHOT=file.png a screenshot after a few frames, then quit; with
//   SHOWROOM_YAWS=a,b,c    one per yaw (file-a.png, ...)
//   SHOWROOM_TEXT=0        no text in the picture
//   SHOWROOM_HOLE=1        look through the block's first hole
// (raylib keeps only the screenshot's basename: run it from the folder
// the pictures should go to.)
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local vec = require("game/vec")
local city_lib = require("game/city")
local levels = require("game/levels")
local traffic = require("game/traffic")
local render = require("game/render")

local WIDTH = 1280
local HEIGHT = 720

local func env_number(name, default){
  local v = os.getenv(name)
  if(v == null){
    return default
  }
  return str.to_number(v)
}

local MODES = {"car", "lineup", "building"}

local state = {
  mode: os.getenv("SHOWROOM_MODE") or "car",
  design: 0,
  palette: to_int(env_number("SHOWROOM_PALETTE", 0)),
  seed: 1,
  level: to_int(env_number("SHOWROOM_LEVEL", 3)) - 1,
  grid: os.getenv("SHOWROOM_GRID") == "1",
  yaw: env_number("SHOWROOM_YAW", 35) * math.pi / 180,
  pitch: env_number("SHOWROOM_PITCH", 18) * math.pi / 180,
  zoom: env_number("SHOWROOM_DIST", 1),
  look: env_number("SHOWROOM_LOOK", 0.5),   // how high on a block the camera looks
  spin: os.getenv("SHOWROOM_SHOT") == null,
  bloom: true,
  text: os.getenv("SHOWROOM_TEXT") != "0",
  time: 0,
  shots: 0,
  // what is built: the car models, the block
  models: null,
  block: null,
}
if(state.mode == "building"){
  state.seed = to_int(env_number("SHOWROOM_ITEM", 1))
} else {
  state.design = to_int(env_number("SHOWROOM_ITEM", 0))
}

// ------------------------------------------------------------ what is shown

local func unload_models(){
  if(state.models != null){
    for(let local mo in values(state.models)){
      mo:unload()
    }
  }
  state.models = null
}

local func palette(i){
  local ps = traffic.PALETTES
  return ps[((i % len(ps)) + len(ps)) % len(ps)]
}

// the car models: every design in the current palette (the lineup shows
// each in a palette of its own)
local func build_cars(){
  unload_models()
  state.models = {}
  for(local i = 0; i < len(render.DESIGNS); i = i + 1){
    local p = palette(state.palette)
    if(state.mode == "lineup"){
      p = palette(state.palette + i)
    }
    append(state.models, render.design_model(i, p))
  }
}

// one block of the district (or three by three of them), as the game
// makes it, its center and how high it reaches
local func build_block(){
  local base = levels.get(state.level)
  local level = {}
  for(let local e in entries(base)){
    level[e[0]] = e[1]
  }
  level.n = if(state.grid){ 3 } else { 1 }
  // (no slot lines: on so few blocks every one would be split by one)
  level.slots = 0
  local c = city_lib.generate(state.seed, level)
  render.build_city(c)
  local top = 0
  for(let local b in values(c.boxes)){
    if(b.kind != city_lib.GROUND){
      top = math.max(top, b.y1)
    }
  }
  // the holes through its towers, to look through (O)
  local holes = {}
  for(let local block in values(c.blocks)){
    for(let local tw in values(block.towers)){
      for(let local t in values(tw)){
        if(t.hole != null){
          local h = t.hole
          local u = (h.u0 + h.u1) / 2
          local v = (h.v0 + h.v1) / 2
          local center = if(h.axis == "x"){ {x: (t.x0 + t.x1) / 2, y: v, z: u} } else { {x: u, y: v, z: (t.z0 + t.z1) / 2} }
          append(holes, {center: center, axis: h.axis, shape: h.shape})
        }
      }
    }
  }
  state.block = {city: c, top: top, name: c.blocks[to_int(len(c.blocks) / 2)].name, holes: holes}
  state.hole = if(os.getenv("SHOWROOM_HOLE") != null and len(holes) > 0){ 0 } else { null }
}

local func rebuild(){
  if(state.mode == "building"){
    build_block()
  } else {
    build_cars()
  }
}

// ------------------------------------------------------------ the camera

// what the camera turns around, and from how far
local func framing(){
  if(state.mode == "building" and state.hole != null and state.hole < len(state.block.holes)){
    // through a hole, along its axis
    local h = state.block.holes[state.hole]
    return {target: h.center, dist: 70}
  }
  if(state.mode == "building"){
    local b = state.block
    local reach = b.top * 1.3 + 50
    if(state.grid){
      reach = reach + b.city.pitch * 1.5
    }
    return {target: {x: 0, y: b.top * state.look, z: 0}, dist: reach}
  }
  if(state.mode == "lineup"){
    return {target: {x: 0, y: 0.5, z: 0}, dist: 34}
  }
  local half = render.design_half(state.design) or {x: 1.1, y: 0.45, z: 2.2}
  return {target: {x: 0, y: half.y, z: 0}, dist: math.max(8, half.z * 3.6)}
}

local func camera(){
  local f = framing()
  local d = f.dist * state.zoom
  local cp = math.cos(state.pitch)
  return {
    position: {
      x: f.target.x + math.sin(state.yaw) * cp * d,
      y: f.target.y + math.sin(state.pitch) * d,
      z: f.target.z + math.cos(state.yaw) * cp * d,
    },
    target: f.target,
    up: {x: 0, y: 1, z: 0},
    fovy: 45,
    projection: rl.CAMERA_PERSPECTIVE,
  }
}

// ------------------------------------------------------------ drawing

local identity = {x: 0, y: 0, z: 0, w: 1}

// the lineup: rows of COLUMNS cars side by side, facing +z, the rows one
// behind the other; each car standing on the floor
local COLUMNS = 6
local SPACING = 4.2
local ROW = 12

local func lineup_place(i){
  local n = len(state.models)
  local rows = to_int((n + COLUMNS - 1) / COLUMNS)
  local col = i % COLUMNS
  local row = to_int(i / COLUMNS)
  local half = render.design_half(i)
  local lift = if(half == null){ 0.45 } else { half.y }
  return {x: (col - (COLUMNS - 1) / 2) * SPACING, y: lift, z: (row - (rows - 1) / 2) * -ROW}
}

// a dark turntable under a car, its rim lit
local func turntable(pos, r){
  render.box({x: pos.x, y: pos.y - 0.05, z: pos.z}, identity, {x: r * 2, y: 0.1, z: r * 2}, {40, 40, 50}, city_lib.DARK)
  render.box({x: pos.x, y: pos.y, z: pos.z - r}, identity, {x: r * 2, y: 0.04, z: 0.06}, {0, 220, 255}, city_lib.NEON)
  render.box({x: pos.x, y: pos.y, z: pos.z + r}, identity, {x: r * 2, y: 0.04, z: 0.06}, {0, 220, 255}, city_lib.NEON)
}

local func draw_scene(cam){
  render.scene(cam, state.time){
    if(state.mode == "building"){
      render.city(cam)
    } else if(state.mode == "lineup"){
      render.box({x: 0, y: -0.05, z: 0}, identity, {x: 40, y: 0.1, z: 46}, {40, 40, 50}, city_lib.DARK)
      for(local i = 0; i < len(state.models); i = i + 1){
        local p = lineup_place(i)
        render.draw(state.models[i], p, identity)
      }
    } else {
      local half = render.design_half(state.design) or {x: 1.1, y: 0.45, z: 2.2}
      turntable({x: 0, y: 0, z: 0}, half.z * 1.4)
      render.draw(state.models[state.design], {x: 0, y: half.y + 0.25, z: 0}, identity)
    }
  }
  if(state.bloom){
    render.present({})
  } else {
    render.present({dim: 1})
  }
}

local func label(){
  if(state.mode == "building"){
    local level = levels.get(state.level)
    local hole = ""
    if(state.hole != null){
      hole = concat(" | hole ", string(state.hole + 1), "/", string(len(state.block.holes)), ": ", state.block.holes[state.hole].shape)
    } else if(len(state.block.holes) > 0){
      hole = concat(" | ", string(len(state.block.holes)), " holes (O)")
    }
    return concat("building: ", state.block.name, " | seed ", string(state.seed), " | ", level.name,
      if(state.grid){ " | 3 x 3" } else { "" }, hole)
  }
  if(state.mode == "lineup"){
    return concat("lineup: ", str.join(render.DESIGNS, ", "))
  }
  return concat("car ", string(state.design + 1), "/", string(len(render.DESIGNS)), ": ",
    render.DESIGNS[state.design], " | palette ", string(state.palette))
}

local func draw_text(){
  if(not state.text){
    return
  }
  rl.draw.text(label(), 16, 14, 20, {230, 236, 255, 255})
  rl.draw.text("Tab mode   Left/Right item   Up/Down palette/district   drag orbit   wheel zoom   Space spin   G grid   O holes   B bloom   F frame   H text   P shot",
    16, HEIGHT - 26, 14, {150, 160, 190, 255})
}

// ------------------------------------------------------------ input

local func cycle_mode(){
  local i = 0
  for(local k = 0; k < len(MODES); k = k + 1){
    if(MODES[k] == state.mode){
      i = k
    }
  }
  state.mode = MODES[(i + 1) % len(MODES)]
  rebuild()
}

local func input(dt){
  if(rl.key.pressed(rl.KEY_TAB)){
    cycle_mode()
  }
  local step = 0
  if(rl.key.pressed(rl.KEY_RIGHT)){ step = 1 }
  if(rl.key.pressed(rl.KEY_LEFT)){ step = -1 }
  local up = 0
  if(rl.key.pressed(rl.KEY_UP)){ up = 1 }
  if(rl.key.pressed(rl.KEY_DOWN)){ up = -1 }
  if(state.mode == "building"){
    if(step != 0){
      state.seed = math.max(1, state.seed + step)
      build_block()
    }
    if(up != 0){
      state.level = math.max(0, math.min(len(levels.list) - 1, state.level + up))
      build_block()
    }
    if(rl.key.pressed(rl.KEY_O) and len(state.block.holes) > 0){
      // the next hole, looked through along its axis; then the block again
      state.hole = if(state.hole == null){ 0 } else { state.hole + 1 }
      if(state.hole >= len(state.block.holes)){
        state.hole = null
      } else {
        local axis = state.block.holes[state.hole].axis
        state.yaw = if(axis == "x"){ math.pi / 2 + 0.25 } else { 0.25 }
        state.pitch = 0.08
        state.spin = false
      }
    }
    if(rl.key.pressed(rl.KEY_G)){
      state.grid = not state.grid
      build_block()
    }
  } else {
    if(step != 0){
      local n = len(render.DESIGNS)
      state.design = ((state.design + step) % n + n) % n
    }
    if(up != 0){
      state.palette = state.palette + up
      build_cars()
    }
  }
  if(rl.mouse.down(rl.MOUSE_BUTTON_LEFT)){
    local d = rl.mouse.delta
    state.yaw = state.yaw - d.x * 0.006
    state.pitch = vec.clamp(state.pitch + d.y * 0.006, -0.3, 1.5)
    state.spin = false
  }
  local wheel = rl.mouse.wheel
  if(wheel != 0){
    state.zoom = vec.clamp(state.zoom * math.exp(-wheel * 0.1), 0.15, 4)
  }
  if(rl.key.pressed(rl.KEY_SPACE)){ state.spin = not state.spin }
  if(rl.key.pressed(rl.KEY_B)){ state.bloom = not state.bloom }
  if(rl.key.pressed(rl.KEY_H)){ state.text = not state.text }
  if(rl.key.pressed(rl.KEY_F)){
    state.zoom = 1
    state.yaw = 35 * math.pi / 180
    state.pitch = 18 * math.pi / 180
  }
  if(state.spin){
    state.yaw = state.yaw + dt * 0.3
  }
}

// ------------------------------------------------------------ main

rl.window.open({width: WIDTH, height: HEIGHT, title: "Courier showroom", msaa: true, vsync: true, fps: 60})
rl.window.exit_key = rl.KEY_ESCAPE
render.init(WIDTH, HEIGHT)
rebuild()

// the screenshots asked for from the environment: one per yaw
local shot = os.getenv("SHOWROOM_SHOT")
local queue = {}
if(shot != null){
  local yaws = os.getenv("SHOWROOM_YAWS")
  if(yaws == null){
    append(queue, {yaw: state.yaw, file: shot})
  } else {
    local stem = str.substring(shot, 0, len(shot) - 4)
    for(let local y in values(str.split(yaws, ","))){
      append(queue, {yaw: str.to_number(y) * math.pi / 180, file: concat(stem, "-", y, ".png")})
    }
  }
}
local frames = 0
local qi = 0

for(not rl.window.should_close){
  local dt = math.min(rl.frame_time, 0.05)
  state.time = state.time + dt
  if(qi < len(queue)){
    state.yaw = queue[qi].yaw
  } else {
    input(dt)
  }
  local cam = camera()
  rl.drawing{
    draw_scene(cam)
    draw_text()
  }
  frames = frames + 1
  if(qi < len(queue) and frames >= 4){
    rl.window.screenshot(queue[qi].file)
    qi = qi + 1
    frames = 0
    if(qi == len(queue)){
      break
    }
  }
  if(qi >= len(queue) and len(queue) == 0 and rl.key.pressed(rl.KEY_P)){
    rl.window.screenshot(concat("showroom-", string(state.shots), ".png"))
    state.shots = state.shots + 1
  }
}

unload_models()
render.unload()
rl.window.close()
