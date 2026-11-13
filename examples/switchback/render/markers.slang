// render/markers: the trail's checkpoints as things in the world: at each
// a gate of two posts and a beam over the track, with a banner hanging
// from it that stirs in the wind. The banner of the gate to reach next is
// amber and glows, those passed are green, those further on the color of
// canvas.
//
//   markers.init(world)
//   markers.next = 3            // the checkpoint to reach (main sets it)
//   markers.draw(view, world)
local rl = require("raylib")
local math = require("slang/math")
local vec = require("game/vec")
local terrain_lib = require("game/terrain")
local route = require("game/route")
local kit = require("render/truck_mesh")
local shaders = require("render/shaders")

local m = {}

// the checkpoint to reach next (an index into the trail's checkpoints)
m.next = 1

// a material of this module's own beside the mesh kit's: cloth
local CLOTH = 9
// the trail's point the trailhead's gate stands at (the truck starts at
// its fourth)
local START_GATE = 13

local vertex = """
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec2 vertexTexCoord;   // x: what it is made of (9: cloth)
uniform vec4 stir;        // which way the cloth moves (x, z), how much, how high it is tied
uniform vec2 pole;        // of a pennant (material 10): where its pole stands (x, z)
out vec3 worldPos;
out vec3 normal;
out vec3 tint;
out float cloth;
out float hang;           // of cloth: how far over its lower edge, m

void main(){
  vec3 p = vertexPosition;
  hang = p.y - (stir.w - 0.85);
  cloth = vertexTexCoord.x > 8.5 ? 1.0 : 0.0;
  if(cloth > 0.5){
    // the wind in the cloth: more the further from where it is tied (a
    // banner to its beam, a pennant to its pole)
    float free = max(stir.w - p.y, 0.0);
    if(vertexTexCoord.x > 9.5){
      free = distance(p.xz, pole) * 1.4;
      hang = 1.0;
    }
    float wave = sin(time * 3.1 + p.x * 1.3 + p.z * 1.7 + free * 4.0) * 0.6 + sin(time * 5.3 + free * 7.0) * 0.4;
    p.xz += stir.xy * wave * free * stir.z;
  }
  worldPos = p;
  normal = vertexNormal;
  tint = vertexColor.rgb;
  gl_Position = viewProj * vec4(p, 1.0);
}
"""

local fragment = """
in vec3 worldPos;
in vec3 normal;
in vec3 tint;
in float cloth;
in float hang;
uniform vec4 banner;      // the cloth's color, and how much it glows
out vec4 finalColor;

void main(){
  if(depthPass > 0.5){
    finalColor = packDepth(gl_FragCoord.z);
    return;
  }
  vec3 n = normalize(normal);
  if(!gl_FrontFacing){
    n = -n;
  }
  float shadow = sunShadow(worldPos, n);
  vec3 color;
  if(cloth > 0.5){
    // cloth lets the sun through; a darker band along its lower edge
    vec3 dye = banner.rgb * (1.0 - 0.45 * step(hang, 0.24) * step(0.06, hang));
    color = shadeLeaf(dye, n, worldPos, shadow, 0.5) + dye * banner.a;
  } else {
    // (the mesh's colors are the screen's: to light)
    color = shade(pow(tint, vec3(2.2)), n, worldPos, shadow);
  }
  finalColor = vec4(finish(color, worldPos), 1.0);
}
"""

local state = {}

// a point across the track from the checkpoint's middle, on the ground
local func beside(land, c, lx, lz, off){
  local x = c.x + lx * off
  local z = c.z + lz * off
  return {x: x, y: terrain_lib.height_at(land, x, z), z: z}
}

// init(world): a gate at every checkpoint of the world's trail
func m.init(world){
  m.unload()
  local trail = world.trail
  if(trail == null){
    return
  }
  local land = world.land
  state.shader = shaders.load(vertex, fragment)
  state.gates = {}
  local count = len(trail.checkpoints)
  for(local k = 0; k < count; k = k + 1){
    local c = trail.checkpoints[k]
    if(k == 0){
      // the trailhead's gate stands a little way up the trail: the truck
      // starts before it and drives through
      local index = math.min(len(trail.points) - 1, START_GATE)
      local p = trail.points[index]
      c = {index: index, x: p.x, y: p.y, z: p.z}
    }
    local yaw = route.direction(trail, c.index)
    // across the track: to the left of the way it runs
    local lx = math.cos(yaw)
    local lz = -math.sin(yaw)
    // (no wider than a track: at the summit the track opens into a place)
    local half = math.min(trail.points[c.index].half or route.HALF_WIDTH, route.HALF_WIDTH + 0.5) + 0.9
    local left = beside(land, c, lx, lz, half)
    local right = beside(land, c, lx, lz, -half)
    local top = math.max(left.y, right.y) + 3.7
    local b = kit.new()
    b:paint(kit.MATTE)
    // the posts: thicker at the foot, set into the ground
    b:color(116, 84, 56)
    for(let local foot in values({left, right})){
      b:rod({x: foot.x, y: foot.y - 0.4, z: foot.z}, {x: foot.x, y: top + 0.25, z: foot.z}, 0.13, 8, 0.1, false, true)
    }
    // the beam, a little past the posts
    b:color(132, 98, 66)
    b:rod(
      {x: left.x + lx * 0.4, y: top, z: left.z + lz * 0.4},
      {x: right.x - lx * 0.4, y: top, z: right.z - lz * 0.4}, 0.085, 8, 0.085, true, true,
    )
    // the banner: cloth hanging from the beam over the track's middle
    local wide = half - 0.7
    local drop = 0.85
    local parts = 10
    b:paint(CLOTH)
    for(local i = 0; i < parts; i = i + 1){
      local a = -wide + 2 * wide * i / parts
      local e = -wide + 2 * wide * (i + 1) / parts
      b:quad(
        {x: c.x + lx * a, y: top - 0.1, z: c.z + lz * a},
        {x: c.x + lx * e, y: top - 0.1, z: c.z + lz * e},
        {x: c.x + lx * e, y: top - 0.1 - drop, z: c.z + lz * e},
        {x: c.x + lx * a, y: top - 0.1 - drop, z: c.z + lz * a},
      )
    }
    local pole = {0, 0}
    if(k == count - 1 and trail.summit != null){
      // the summit: a pole in the cairn beyond the gate, a pennant on it
      local px = trail.summit.x + math.sin(yaw) * 4.6
      local pz = trail.summit.z + math.cos(yaw) * 4.6
      pole = {px, pz}
      local foot = terrain_lib.height_at(land, px, pz)
      b:paint(kit.MATTE)
      b:color(92, 70, 50)
      b:rod({x: px, y: foot + 0.3, z: pz}, {x: px, y: foot + 4.3, z: pz}, 0.035, 8, 0.025, false, true)
      b:paint(CLOTH + 1)
      local parts = 8
      for(local i = 0; i < parts; i = i + 1){
        // (a long triangle, tied along the pole, its point downwind)
        local a = i / parts
        local e = (i + 1) / parts
        local wx = lx * 1.5
        local wz = lz * 1.5
        b:quad(
          {x: px + wx * a, y: foot + 4.25 - 0.28 * a, z: pz + wz * a},
          {x: px + wx * e, y: foot + 4.25 - 0.28 * e, z: pz + wz * e},
          {x: px + wx * e, y: foot + 3.65 + 0.28 * e, z: pz + wz * e},
          {x: px + wx * a, y: foot + 3.65 + 0.28 * a, z: pz + wz * a},
        )
      }
    }
    local mesh = b:mesh()
    local gate = {
      mesh: mesh, model: mesh:to_model(), index: k, stir: {math.sin(yaw), math.cos(yaw)},
      tied: top - 0.1,
      pole: pole,
      x: c.x, z: c.z,
    }
    gate.material = shaders.use(gate.model, state.shader)
    append(state.gates, gate)
  }
}

// draw(view, world): the gates (they cast shadows)
func m.draw(view, world){
  if(state.shader == null){
    return
  }
  local shader = state.shader
  shaders.apply(shader, view)
  local identity = {
    m0: 1, m1: 0, m2: 0, m3: 0, m4: 0, m5: 1, m6: 0, m7: 0,
    m8: 0, m9: 0, m10: 1, m11: 0, m12: 0, m13: 0, m14: 0, m15: 1,
  }
  local trail = world.trail
  for(let local gate in values(state.gates)){
    local dx = gate.x - view.eye.x
    local dz = gate.z - view.eye.z
    if(dx * dx + dz * dz > 700 * 700){
      continue
    }
    local banner = {0.56, 0.5, 0.38, 0}
    if(gate.index < m.next){
      banner = {0.09, 0.2, 0.08, 0}
    } else if(gate.index == m.next){
      local pulse = 0.5 + 0.5 * math.sin(view.time * 2.6)
      banner = {0.85, 0.38, 0.04, 0.06 + 0.1 * pulse}
    }
    shader:set("banner", banner, rl.SHADER_UNIFORM_VEC4)
    shader:set("stir", {gate.stir[0], gate.stir[1], 0.16, gate.tied}, rl.SHADER_UNIFORM_VEC4)
    shader:set("pole", gate.pole, rl.SHADER_UNIFORM_VEC2)
    rl.draw.mesh(gate.mesh, gate.material, identity)
  }
}

func m.unload(){
  if(state.shader != null){
    for(let local gate in values(state.gates)){
      gate.model:unload()
    }
    state.shader:unload()
    state.shader = null
    state.gates = {}
  }
}

return m
