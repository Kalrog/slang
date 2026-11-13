// render/cable: the winch's line and what it is hooked to (world.winch,
// see game/winch). The rope runs from the truck's fairlead in a curve
// that hangs while it is slack and straightens as it takes the load; at
// its end a hook sits in a shackle. Around a tree a strap of webbing
// protects the bark, its two ends coming forward to the shackle; where
// no tree stands, a ground anchor is set: a spade driven into the earth
// with its stakes beside it.
//
//   cable.init()
//   cable.draw(view, world)     // nothing while the line is in
local rl = require("raylib")
local math = require("slang/math")
local vec = require("game/vec")
local terrain_lib = require("game/terrain")
local kit = require("render/truck_mesh")
local shaders = require("render/shaders")

local m = {}

m.PARTS = 12        // pieces the rope's curve is drawn in
m.RADIUS = 0.0065   // of the rope, m (a synthetic winch rope: 13 mm)

// a material of this module's own beside the mesh kit's: rope
local ROPE = 9

local vertex = """
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec2 vertexTexCoord;   // x: what it is made of (9: rope)
uniform mat4 matModel;
uniform vec4 lay;         // of rope: how far along the line this piece begins, its length, 0, 0
out vec3 worldPos;
out vec3 normal;
out vec3 tint;
out vec2 what;
out vec2 strand;          // of rope: how far along the line (m), the angle round it

void main(){
  vec4 p = matModel * vec4(vertexPosition, 1.0);
  worldPos = p.xyz;
  normal = normalize(mat3(matModel) * vertexNormal);
  tint = vertexColor.rgb;
  what = vertexTexCoord;
  strand = vec2(lay.x + vertexPosition.z * lay.y, atan(vertexNormal.y, vertexNormal.x));
  gl_Position = viewProj * p;
}
"""

local fragment = """
in vec3 worldPos;
in vec3 normal;
in vec3 tint;
in vec2 what;
in vec2 strand;
out vec4 finalColor;

void main(){
  if(depthPass > 0.5){
    finalColor = packDepth(gl_FragCoord.z);
    return;
  }
  vec3 n = normalize(normal);
  float shadow = sunShadow(worldPos, n);
  // (the mesh's colors are the screen's: to light)
  vec3 own = pow(tint, vec3(2.2));
  int material = int(what.x + 0.5);
  vec3 color;
  if(material == 9){
    // twelve strands laid round each other: darker in the grooves between
    float twist = sin(strand.x * 95.0 + strand.y * 3.0);
    float groove = smoothstep(-0.2, 0.9, twist);
    // (from far off the strands are one color)
    float near = 1.0 - smoothstep(6.0, 22.0, distance(worldPos, eye));
    color = shade(own * mix(0.82, mix(0.5, 1.12, groove), near), n, worldPos, shadow);
  } else if(material == 3){
    color = shadeGloss(own, n, worldPos, shadow, 0.5, 0.75);
  } else {
    color = shade(own, n, worldPos, shadow);
  }
  finalColor = vec4(finish(color, worldPos), 1.0);
}
"""

local state = {}

local func v(x, y, z){
  return {x: x, y: y, z: z}
}

// a ring of tube in the plane across x, around the origin
local func ring(b, radius, thick, sides){
  local points = {}
  for(local k = 0; k <= 16; k = k + 1){
    local a = k * 2 * math.pi / 16
    append(points, v(0, math.cos(a) * radius, math.sin(a) * radius))
  }
  b:tube(points, thick, sides)
}

// init(): the rope's piece, the hook, the shackle, the strap and the
// ground anchor as meshes, and their shader
func m.init(){
  m.unload()
  state.shader = shaders.load(vertex, fragment)
  state.parts = {}
  local func made(name, b){
    local model = b:mesh():to_model()
    state.parts[name] = {model: model, mesh: model.meshes[0], material: shaders.use(model, state.shader)}
  }
  // the rope: a bar one long and one thick along z, drawn stretched
  local b = kit.new()
  b:paint(ROPE)
  b:color(214, 96, 28)
  b:rod(v(0, 0, 0), v(0, 0, 1), 1, 8, 1, false, false)
  made("rope", b)

  // the hook, from its eye (at the origin, the rope spliced into it) to
  // its tip: forged, painted red, with a sprung latch across its mouth
  b = kit.new()
  b:paint(kit.METAL, 0.4)
  b:color(168, 30, 22)
  ring(b, 0.024, 0.008, 6)
  b:rod(v(0, 0, 0.022), v(0, 0, 0.075), 0.011, 8, 0.0125, false, false)
  local bend = {}
  for(local k = 0; k <= 12; k = k + 1){
    // (three quarters of a circle, opening back toward the eye)
    local a = k * 1.5 * math.pi / 12
    append(bend, v(0, -0.042 + math.cos(a) * 0.042, 0.075 + math.sin(a) * 0.05))
  }
  b:tube(bend, 0.0115, 8)
  b:color(190, 190, 186)
  b:rod(v(0, -0.004, 0.07), v(0, -0.078, 0.1), 0.0035, 6, 0.0035, true, true)
  made("hook", b)

  // the shackle: a bow of steel with its pin
  b = kit.new()
  b:paint(kit.METAL, 0.55)
  b:color(150, 152, 156)
  ring(b, 0.034, 0.0085, 8)
  b:rod(v(-0.03, 0, -0.034), v(0.03, 0, -0.034), 0.0095, 8, 0.0095, true, true)
  made("shackle", b)

  // the strap round a trunk: a band one across and one high, drawn as
  // wide as the trunk; and a strip of the same webbing one long
  b = kit.new()
  b:paint(kit.MATTE)
  b:color(206, 172, 38)
  b:rod(v(0, -0.5, 0), v(0, 0.5, 0), 1, 20, 1, false, false)
  made("band", b)
  b = kit.new()
  b:paint(kit.MATTE)
  b:color(206, 172, 38)
  b:box(0, 0, 0.5, 1, 1, 1, 0)
  made("strip", b)

  // the ground anchor, as it sits when it is set: its eye a hand over
  // the ground (at the origin's height, the pull toward -z), the shank
  // slanting back and down from it into the earth to a spade that is all
  // but buried, and two stakes driven in behind
  b = kit.new()
  b:paint(kit.METAL, 0.35)
  b:color(92, 94, 100)
  b:push(0, 0.2, 0, null)
  ring(b, 0.036, 0.009, 8)
  b:pop()
  b:rod(v(0, 0.185, 0.03), v(0, -0.02, 0.44), 0.017, 8, 0.017, false, false)
  b:color(126, 46, 30)
  local slant = vec.quat_axis({x: 1, y: 0, z: 0}, 0.95)
  b:push(0, -0.1, 0.5, slant)
  b:box(0, 0, 0, 0.36, 0.014, 0.52, 0.003)
  b:box(0, 0.022, 0, 0.014, 0.044, 0.5, 0)
  b:pop()
  b:color(92, 94, 100)
  for(let local side in values({-0.17, 0.17})){
    b:rod(v(side, -0.36, 0.58), v(side, 0.07, 0.66), 0.012, 6, 0.012, false, false)
    b:rod(v(side, 0.07, 0.66), v(side, 0.079, 0.662), 0.022, 8, 0.022, true, true)
  }
  // (the earth the spade threw up as it dug in: a low mound before it)
  b:paint(kit.MATTE)
  b:color(84, 72, 62)
  b:push(0, -0.005, 0.3, vec.quat_axis({x: 0, y: 0, z: 1}, math.pi / 2))
  b:turned({{a: 0, r: 0.27}, {a: 0.03, r: 0.21}, {a: 0.052, r: 0.11}, {a: 0.06, r: 0}}, 18)
  b:pop()
  made("anchor", b)
}

// the matrix that sets a mesh at a place: its z along `way`, its y as
// near `up` as that allows, stretched by sx, sy, sz
local func frame(at, way, up, sx, sy, sz){
  local z = vec.normalize(way)
  if(math.abs(vec.dot(z, up)) > 0.97){
    up = {x: 1, y: 0, z: 0}
  }
  local x = vec.normalize(vec.cross(up, z))
  local y = vec.cross(z, x)
  return {
    m0: x.x * sx, m1: x.y * sx, m2: x.z * sx, m3: 0,
    m4: y.x * sy, m5: y.y * sy, m6: y.z * sy, m7: 0,
    m8: z.x * sz, m9: z.y * sz, m10: z.z * sz, m11: 0,
    m12: at.x, m13: at.y, m14: at.z, m15: 1,
  }
}

local UP = {x: 0, y: 1, z: 0}

local func put(name, matrix){
  local part = state.parts[name]
  rl.draw.mesh(part.mesh, part.material, matrix)
}

// draw(view, world): the line while it is out (it casts a shadow)
func m.draw(view, world){
  local line = world.winch
  if(line == null or state.shader == null){
    return
  }
  local shader = state.shader
  shaders.apply(shader, view)
  local from = line.from
  local to = line.anchor
  local way = vec.sub(to, from)
  local far = vec.length(way)
  if(far < 0.2){
    return
  }
  // the hook hangs in the shackle; the rope ends at the hook's eye
  local along = vec.scale(way, 1 / far)
  local eye = vec.add_scaled(to, along, -0.19)
  // how much the rope hangs: by its slack, and a little by its own
  // weight even when it pulls
  local slack = math.max(0, line.length - far)
  local taut = vec.clamp(line.tension / 6000, 0, 1)
  local sag = math.min(far * 0.16, 0.5 * math.sqrt(far * slack) + far * (0.022 - 0.017 * taut))
  local span = vec.sub(eye, from)
  local last = from
  local done = 0
  for(local k = 1; k <= m.PARTS; k = k + 1){
    local t = k / m.PARTS
    local p = vec.add_scaled(from, span, t)
    p.y = p.y - sag * 4 * t * (1 - t)
    // (lying on the ground where it would hang into it)
    local ground = terrain_lib.height_at(world.land, p.x, p.z) + 0.02
    if(p.y < ground and k < m.PARTS){
      p.y = ground
    }
    local piece = vec.sub(p, last)
    local l = vec.length(piece)
    shader:set("lay", {done, l, 0, 0}, rl.SHADER_UNIFORM_VEC4)
    put("rope", frame(last, piece, UP, m.RADIUS, m.RADIUS, l))
    done = done + l
    last = p
  }
  put("hook", frame(eye, along, UP, 1.5, 1.5, 1.5))
  put("shackle", frame(vec.add_scaled(to, along, -0.02), along, UP, 1.4, 1.4, 1.4))
  if(line.trunk != null){
    // the strap: a band round the trunk, and its two ends from the
    // trunk's sides forward to the shackle
    local trunk = line.trunk
    local r = trunk.radius + 0.012
    local middle = {x: trunk.x, y: to.y, z: trunk.z}
    put("band", frame(middle, {x: 0, y: 0, z: 1}, UP, r, 0.085, r))
    local out = vec.normalize({x: to.x - trunk.x, y: 0, z: to.z - trunk.z})
    local side = {x: out.z, y: 0, z: -out.x}
    for(let local s in values({-1, 1})){
      local a = vec.add_scaled(middle, side, s * r)
      local run = vec.sub(to, a)
      // (the webbing on edge: thin across, a hand high)
      put("strip", frame(a, run, UP, 0.006, 0.085, vec.length(run)))
    }
  } else {
    // the ground anchor, dug in facing the pull (its spade and stakes
    // on the far side of its eye)
    local flat = vec.normalize({x: along.x, y: 0, z: along.z})
    local ground = terrain_lib.height_at(world.land, to.x, to.z)
    // (set into the slope as it lies: along the ground, square to it)
    local n = terrain_lib.normal_at(world.land, to.x, to.z)
    local lie = vec.normalize(vec.add_scaled(flat, n, -vec.dot(flat, n)))
    put("anchor", frame({x: to.x, y: ground, z: to.z}, lie, n, 1, 1, 1))
  }
}

func m.unload(){
  if(state.shader != null){
    for(let local e in entries(state.parts)){
      e[1].model:unload()
    }
    state.shader:unload()
    state.shader = null
    state.parts = {}
  }
}

return m
