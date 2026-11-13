// render/scene: a frame of the world. The view (where the eye is and
// what it sees) is made here with matrices of the game's own, so that
// the mountains ten kilometers off are inside it. A frame is drawn in
// passes: what stands near the eye into the sun's shadow map (seen from
// the sun), then the sky, the land and everything on it into a picture
// of the scene, then that picture onto the screen with its bright parts
// glowing, its edges smoothed and its colors graded (render/post).
//
//   scene.init(width, height, world)
//   local view = scene.view(camera, time)
//   scene.draw(view, world)
local rl = require("raylib")
local math = require("slang/math")
local time = require("slang/time")
local vec = require("game/vec")
local terrain_lib = require("game/terrain")
local shaders = require("render/shaders")
local terrain = require("render/terrain")
local sky = require("render/sky")
local post = require("render/post")
local grass = require("render/grass")
local water = require("render/water")
local truck = require("render/truck")
local flora = require("render/flora")
local tracks = require("render/tracks")
local dust = require("render/dust")
local markers = require("render/markers")
local cable = require("render/cable")

local m = {}

m.NEAR = 0.4
m.FAR = 14000
// the sun's shadow map: a square of this many pixels a side over the
// ground within SHADOW_REACH meters of where the eye looks
m.SHADOW_SIZE = 2048
m.SHADOW_REACH = 56

local state = {width: 0, height: 0, cost: {frames: 0, effects: 0, shadows: 0, scene: 0, post: 0}}

m.SUN = terrain_lib.SUN
m.SUN_COLOR = {2.5, 2.25, 1.9}

// what draws itself in the world, in order: each a module with
// draw(view, world)
local layers = {}

// init(width, height, world): the passes' shaders and what they draw.
// width and height are the picture's, in pixels.
func m.init(width, height, world){
  state.width = width
  state.height = height
  // the shadow map first: every material made after it reads it
  state.shadow = rl.render_texture(m.SHADOW_SIZE, m.SHADOW_SIZE)
  state.shadow.texture.filter = rl.TEXTURE_FILTER_POINT
  state.shadow.texture.wrap = rl.TEXTURE_WRAP_CLAMP
  shaders.shadow_texture = state.shadow.texture
  sky.init()
  // (before the land and the grass: both read the wheels' tracks)
  tracks.init()
  terrain.init(world.land)
  grass.init(world.land, terrain.textures())
  water.init(world.land, terrain.textures(), terrain.grid())
  truck.init()
  state.flora = world.plants != null
  if(state.flora){
    flora.init(world.land, world.plants)
    flora.prepare(world.car.pos)
  }
  state.last = world.car.pos
  markers.init(world)
  cable.init()
  dust.init()
  post.init(width, height)
  // (a camera of raylib's: only its depth test is used)
  state.camera = rl.camera_3d({position: {x: 0, y: 10, z: 10}})
}

// What a frame is seen through.
// type View = {eye: Vec3, forward: Vec3, right: Vec3, up: Vec3,
//   fovy: float, aspect: float, view_proj: Matrix, sun_dir: Vec3,
//   sun_color: {float}, time: float, width: int, height: int,
//   depth_pass?: bool, shadow?: {proj: Matrix, texel: float, reach: float},
//   focus: Vec3}
// [depth_pass]: this is the sun's view: draw depths for the shadow map
// [shadow]: where the shadow map lies, for the shaders
// [focus]: what the eye looks at (the truck): shadows are centered on it

// view(camera: {position: Vec3, target: Vec3, up?: Vec3, fovy?: float},
//   clock: float) -> View
// (clock: the time the frame shows, s: wind, clouds and dust go by it)
func m.view(camera, clock){
  local eye = camera.position
  local up = camera.up or {x: 0, y: 1, z: 0}
  local fovy = (camera.fovy or 60) * math.pi / 180
  local aspect = state.width / state.height
  local forward = vec.normalize(vec.sub(camera.target, eye))
  local right = vec.normalize(vec.cross(forward, up))
  local look = vec.look_at(eye, camera.target, up)
  local proj = vec.perspective(fovy, aspect, m.NEAR, m.FAR)
  return {
    eye: eye,
    forward: forward,
    right: right,
    up: vec.cross(right, forward),
    fovy: fovy,
    aspect: aspect,
    view_proj: vec.matrix_multiply(proj, look),
    sun_dir: m.SUN,
    sun_color: m.SUN_COLOR,
    time: clock,
    width: state.width,
    height: state.height,
    focus: camera.focus or camera.target,
  }
}

// the sun's view of the ground around a point: a box seen straight on,
// moved in whole pixels of the shadow map so that the shadows' edges do
// not crawl as the eye moves
local func sun_view(view){
  local sun = view.sun_dir
  local reach = m.SHADOW_REACH
  local depth = 420
  local side = vec.normalize(vec.cross({x: 0, y: 1, z: 0}, sun))
  local up = vec.cross(sun, side)
  local texel = 2 * reach / m.SHADOW_SIZE
  // the middle: a little ahead of the focus, on the map's own grid
  local c = vec.add_scaled(view.focus, {x: view.forward.x, y: 0, z: view.forward.z}, reach * 0.35)
  local cx = math.floor(vec.dot(c, side) / texel) * texel
  local cy = math.floor(vec.dot(c, up) / texel) * texel
  local cz = vec.dot(c, sun)
  local center = vec.add(vec.add(vec.scale(side, cx), vec.scale(up, cy)), vec.scale(sun, cz))
  local eye = vec.add_scaled(center, sun, depth / 2)
  local look = vec.look_at(eye, center, up)
  local proj = vec.orthographic(-reach, reach, -reach, reach, 1, depth)
  local view_proj = vec.matrix_multiply(proj, look)
  return {
    eye: view.eye,
    forward: view.forward,
    right: view.right,
    up: view.up,
    fovy: view.fovy,
    aspect: 1,
    view_proj: view_proj,
    sun_dir: view.sun_dir,
    sun_color: view.sun_color,
    time: view.time,
    width: m.SHADOW_SIZE,
    height: m.SHADOW_SIZE,
    focus: view.focus,
    depth_pass: true,
    center: center,
    reach: reach,
  }
}

// add(layer: {draw: func(view, world)}): something more that is drawn
// in the world, after what is there
func m.add(layer){
  append(layers, layer)
}

local func draw_world(view, world){
  terrain.draw(view)
  truck.draw(view, world.car, world.setup)
  if(state.flora){
    flora.draw(view)
  }
  markers.draw(view, world)
  cable.draw(view, world)
  grass.draw(view, world)
  for(let local layer in values(layers)){
    layer.draw(view, world)
  }
  // (last: they are seen through)
  water.draw(view, world)
  dust.draw(view, world)
}

// draw(view, world, options?: {fade?: float}): the frame, onto the
// screen (fade: 1 as it is, toward 0 into black)
func m.draw(view, world, options){
  // the truck set down somewhere else: the woods there all at once, not
  // tree by tree over the next frames
  local at = world.car.pos
  if(state.flora and vec.length(vec.sub(at, state.last)) > 30){
    flora.prepare(at)
  }
  state.last = at
  // the truck's lamps: on in the mountains' shadow (the land's shape map
  // knows how much sun reaches a place)
  local land = world.land
  if(land.shape != null){
    local n = land.n
    local i = to_int(vec.clamp((at.x + land.half) / land.spacing + 0.5, 0, n - 1))
    local j = to_int(vec.clamp((at.z + land.half) / land.spacing + 0.5, 0, n - 1))
    local sun = land.shape[(j * n + i) * 4 + 3]
    // (not flickering at a shadow's edge)
    if(sun < 70){
      world.car.lights = true
    } else if(sun > 120){
      world.car.lights = false
    }
  }
  // what the wheels did to the ground and threw into the air
  local t0 = time.clock()
  tracks.update(world)
  dust.update(world, view.time)
  local t1 = time.clock()
  // the shadows of what is near
  local sun = sun_view(view)
  rl.texture_mode(state.shadow){
    rl.draw.clear(rl.WHITE)
    rl.mode_3d(state.camera){
      draw_world(sun, world)
    }
  }
  local t2 = time.clock()
  view.shadow = {
    proj: sun.view_proj,
    texel: 1 / m.SHADOW_SIZE,
    reach: m.SHADOW_REACH * 0.95,
    center: sun.center,
  }
  // the scene
  post.scene{
    sky.draw(view)
    rl.mode_3d(state.camera){
      draw_world(view, world)
    }
  }
  local t3 = time.clock()
  post.present(view, options)
  local cost = state.cost
  cost.frames = cost.frames + 1
  cost.effects = cost.effects + t1 - t0
  cost.shadows = cost.shadows + t2 - t1
  cost.scene = cost.scene + t3 - t2
  cost.post = cost.post + time.clock() - t3
}

// costs() -> {effects, shadows, scene, post: float}: what the parts of a
// frame have cost the program on average, in ms (not the graphics card's
// work, which is done later)
func m.costs(){
  local cost = state.cost
  local n = math.max(1, cost.frames)
  return {
    effects: cost.effects / n, shadows: cost.shadows / n, scene: cost.scene / n, post: cost.post / n,
  }
}

func m.unload(){
  terrain.unload()
  grass.unload()
  water.unload()
  sky.unload()
  truck.unload()
  flora.unload()
  markers.unload()
  cable.unload()
  tracks.unload()
  dust.unload()
  post.unload()
  if(state.shadow != null){
    state.shadow:unload()
    state.shadow = null
    shaders.shadow_texture = null
  }
}

return m
