// render/grass: the grass. One mesh of several thousand blades over a
// square of eight meters is drawn on every such square around the eye;
// the vertex shader stands each blade on the land (its height from the
// height map), makes it as tall as there is grass there (the land's
// cover: none on the track, on rock, in the mud), turns it to face the
// eye, bends it in the wind and lays it flat near the truck. Near the
// eye the blades are many and thin, farther off fewer and broader, and
// past fifty meters they sink into the ground, which has their color.
local rl = require("raylib")
local math = require("slang/math")
local buffer = require("slang/buffer")
local vec = require("game/vec")
local shaders = require("render/shaders")
local tracks = require("render/tracks")

local m = {}

m.TILE = 8.0        // meters along a side of a square of blades
m.NEAR_TILES = 2    // squares around the eye's own drawn with every blade
m.FAR_TILES = 7     // and with the far mesh's fewer, broader blades
m.NEAR_BLADES = 7200
m.FAR_BLADES = 1800

local vertex = """
in vec3 vertexPosition;   // where the blade stands in its square (x, z), how far up it this vertex is (y)
in vec2 vertexTexCoord;   // which side of the blade (-1, 1; 0 at the tip), the blade's own random number
in vec3 vertexNormal;     // three more of them
in mat4 instanceTransform;
uniform sampler2D heightMap;
uniform sampler2D cover2Map;
uniform sampler2D trackMap;
uniform vec4 trackInfo;   // 1 / the track map's side (m), its middle's x and z, on (1) or off
uniform vec4 land;
uniform vec4 blades;      // how far they reach, their width's factor, whether they thin out (1), 0
uniform vec3 truck;
out vec3 worldPos;
out vec3 tint;
out vec3 normal;
out float lit;
out float along;

void main(){
  vec2 root = vec2(instanceTransform[3][0], instanceTransform[3][2]) + vertexPosition.xz;
  float t = vertexPosition.y;
  float rnd = vertexTexCoord.y;
  vec2 uv = (root + land.x) * land.y + 0.5 * land.z;
  float ground = textureLod(heightMap, uv, 0.0).r;
  vec4 cover = textureLod(cover2Map, uv, 0.0);
  vec3 base = vec3(root.x, ground, root.y);
  float dist = distance(base, eye);

  // how much grass: the cover's share against the blade's number, so the
  // meadow thins out at its edges; none where the blades end
  // (a track's middle and its edges are part grass: little of it there,
  // and short)
  float share = smoothstep(0.5, 1.0, cover.a);
  float keep = smoothstep(rnd * 0.8, rnd * 0.8 + 0.2, share) * mix(0.55, 1.0, share);
  keep *= 1.0 - smoothstep(blades.x * 0.55, blades.x, dist);
  // near the eye three blades of four shrink with the distance and the
  // fourth broadens: farther off there are fewer, wider ones
  float width = blades.y;
  if(blades.z > 0.5){
    float far = smoothstep(11.0, 19.0, dist);
    if(vertexNormal.z > 0.25){
      keep *= 1.0 - far;
    } else {
      width *= 1.0 + far;
    }
  }
  float macro = vnoise(root * 0.0043 + 3.0);
  float patchy = vnoise(root * 0.21);
  float high = smoothstep(170.0, 400.0, ground + 80.0 * (macro - 0.5));
  float height = (0.2 + 0.42 * vertexNormal.x * vertexNormal.x + 0.2 * patchy) * mix(1.0, 0.55, high) * keep;
  // the truck lays it flat, and where its wheels went it stays down
  float pressed = 1.0 - smoothstep(1.3, 2.9, distance(base, truck));
  height *= 1.0 - 0.82 * pressed;
  if(trackInfo.w > 0.5){
    vec2 q = abs(root - trackInfo.yz) * trackInfo.x;
    float track = textureLod(trackMap, root * trackInfo.x, 0.0).r * (1.0 - smoothstep(0.36, 0.45, max(q.x, q.y)));
    height *= 1.0 - 0.9 * smoothstep(0.1, 0.5, track);
  }

  // the wind: gusts running over the meadow, and each blade's own flutter
  vec2 wind = normalize(vec2(0.8, 0.55));
  float gust = vnoise(root * 0.06 - wind * time * 0.55) * 0.75 + vnoise(root * 0.23 - wind * time * 1.3) * 0.25;
  float lean = 0.1 + 0.75 * gust * gust + 0.05 * sin(time * 3.3 + rnd * 43.0);
  vec2 own = vec2(cos(rnd * 6.2831), sin(rnd * 6.2831)) * (0.1 + 0.25 * vertexNormal.y);
  vec2 bend = (wind * lean + own) * t * t * height;

  // facing the eye, turned a little each
  vec2 to_eye = normalize(eye.xz - root + vec2(0.0001));
  float turn = (vertexNormal.y - 0.5) * 1.5;
  vec2 facing = vec2(to_eye.x * cos(turn) - to_eye.y * sin(turn), to_eye.x * sin(turn) + to_eye.y * cos(turn));
  vec2 side = vec2(facing.y, -facing.x);
  float w = vertexTexCoord.x * width * (1.0 - 0.8 * t * t) * step(0.001, height);
  vec3 pos = base + vec3(side.x * w + bend.x, t * height * (1.0 - 0.25 * lean * t), side.y * w + bend.y);
  worldPos = pos;
  along = t;

  // the meadow's colors (the ground has the same from afar): greener low
  // down, drier up high, paler toward the tips
  vec3 lush = mix(vec3(0.05, 0.1, 0.024), vec3(0.11, 0.16, 0.04), patchy * 0.5 + macro * 0.5);
  vec3 dry = mix(vec3(0.12, 0.125, 0.045), vec3(0.2, 0.18, 0.07), patchy * 0.5 + macro * 0.5);
  vec3 c = mix(lush, dry, high);
  c *= 0.8 + 0.5 * vertexNormal.x;
  tint = c * mix(0.5, 1.45, t) + vec3(0.02, 0.022, 0.0) * t;
  // a few flowers: the tip of one blade in some hundreds
  if(vertexNormal.z > 0.993 && t > 0.9 && high < 0.6){
    tint = mix(vec3(0.75, 0.7, 0.2), vec3(0.7, 0.72, 0.78), step(0.5, rnd));
  }
  // lit like the ground it stands on, a little toward the eye
  normal = normalize(vec3(facing.x * 0.35 + bend.x, 1.0, facing.y * 0.35 + bend.y));
  lit = 1.0;
  gl_Position = viewProj * vec4(pos, 1.0);
}
"""

local fragment = """
in vec3 worldPos;
in vec3 tint;
in vec3 normal;
in float lit;
in float along;
out vec4 finalColor;

void main(){
  vec3 n = normalize(normal);
  float shadow = sunShadow(worldPos, vec3(0.0, 1.0, 0.0));
  vec3 color = shadeLeaf(tint, n, worldPos, shadow, 0.55);
  // darker down between the blades
  color *= 0.55 + 0.45 * along;
  finalColor = vec4(finish(color, worldPos), 1.0);
}
"""

local state = {}

// a square of blades as a mesh: count blades scattered over it, each
// three segments tall
local func blades_mesh(count, seed){
  local rng = vec.random(seed)
  local vertices = {}
  local texcoords = {}
  local normals = {}
  local indices = {}
  local v = 0
  for(local b = 0; b < count; b = b + 1){
    local x = rng:next() * m.TILE
    local z = rng:next() * m.TILE
    local r0 = rng:next()
    local r1 = rng:next()
    local r2 = rng:next()
    local r3 = rng:next()
    for(local k = 0; k < 3; k = k + 1){
      local t = k / 3
      for(local side = -1; side <= 1; side = side + 2){
        append(vertices, x)
        append(vertices, t)
        append(vertices, z)
        append(texcoords, side)
        append(texcoords, r0)
        append(normals, r1)
        append(normals, r2)
        append(normals, r3)
      }
    }
    append(vertices, x)
    append(vertices, 1)
    append(vertices, z)
    append(texcoords, 0)
    append(texcoords, r0)
    append(normals, r1)
    append(normals, r2)
    append(normals, r3)
    // (left and right at each height: 0 1, 2 3, 4 5; the tip 6)
    for(let local i in values({0, 1, 2, 1, 3, 2, 2, 3, 4, 3, 5, 4, 4, 5, 6})){
      append(indices, v + i)
    }
    v = v + 7
  }
  return rl.mesh({vertices: vertices, texcoords: texcoords, normals: normals, indices: indices})
}

// init(land, textures: {height, cover2}): the blades and their shader;
// the textures are the land's (render/terrain's)
func m.init(land, textures){
  state.land = land
  state.shader = shaders.load(vertex, fragment)
  local shader = state.shader
  shader.locs[rl.SHADER_LOC_MATRIX_MODEL] = shader:location_attrib("instanceTransform")
  shader.locs[rl.SHADER_LOC_MAP_ALBEDO] = shader:location("heightMap")
  shader.locs[rl.SHADER_LOC_MAP_METALNESS] = shader:location("cover2Map")
  shader.locs[rl.SHADER_LOC_MAP_NORMAL] = shader:location("trackMap")
  shader:set("land", {land.half, 1 / (land.n * land.spacing), 1 / land.n, land.spacing}, rl.SHADER_UNIFORM_VEC4)
  state.near = blades_mesh(m.NEAR_BLADES, 11):to_model()
  state.far = blades_mesh(m.FAR_BLADES, 23):to_model()
  for(let local model in values({state.near, state.far})){
    local material = shaders.use(model, shader)
    material.maps[rl.MATERIAL_MAP_ALBEDO].texture = textures.height
    material.maps[rl.MATERIAL_MAP_METALNESS].texture = textures.cover2
    material.maps[rl.MATERIAL_MAP_NORMAL].texture = tracks.texture() or textures.cover2
  }
  local most = (2 * m.FAR_TILES + 1) * (2 * m.FAR_TILES + 1)
  state.near_tiles = buffer.new("Matrix", most, rl.decls)
  state.far_tiles = buffer.new("Matrix", most, rl.decls)
}

// draw(view, world): the grass around the eye (it casts no shadow)
func m.draw(view, world){
  if(view.depth_pass){
    return
  }
  local shader = state.shader
  shaders.apply(shader, view)
  local car = world.car.pos
  shader:set("truck", {car.x, car.y - 0.4, car.z}, rl.SHADER_UNIFORM_VEC3)
  shader:set("trackInfo", if(tracks.texture() != null){ tracks.info() } else { {0, 0, 0, 0} }, rl.SHADER_UNIFORM_VEC4)
  local t = m.TILE
  local cx = math.floor(view.eye.x / t)
  local cz = math.floor(view.eye.z / t)
  local near = 0
  local far = 0
  local fx = view.forward.x
  local fz = view.forward.z
  local reach = m.FAR_TILES * t
  for(local dz = -m.FAR_TILES; dz <= m.FAR_TILES; dz = dz + 1){
    for(local dx = -m.FAR_TILES; dx <= m.FAR_TILES; dx = dx + 1){
      local x = (cx + dx) * t
      local z = (cz + dz) * t
      // not the squares behind the eye
      local ahead = (x + t / 2 - view.eye.x) * fx + (z + t / 2 - view.eye.z) * fz
      if(ahead > -t * 1.5){
        local tiles = state.far_tiles
        local at = far
        if(math.abs(dx) <= m.NEAR_TILES and math.abs(dz) <= m.NEAR_TILES){
          tiles = state.near_tiles
          at = near
          near = near + 1
        } else {
          far = far + 1
        }
        tiles[at] = {
          m0: 1, m1: 0, m2: 0, m3: 0, m4: 0, m5: 1, m6: 0, m7: 0,
          m8: 0, m9: 0, m10: 1, m11: 0, m12: x, m13: 0, m14: z, m15: 1,
        }
      }
    }
  }
  if(near > 0){
    shader:set("blades", {reach, 0.016, 1, 0}, rl.SHADER_UNIFORM_VEC4)
    rl.draw.mesh_instanced(state.near.meshes[0], state.near.materials[0], state.near_tiles:slice(0, near))
  }
  if(far > 0){
    shader:set("blades", {reach, 0.032, 0, 0}, rl.SHADER_UNIFORM_VEC4)
    rl.draw.mesh_instanced(state.far.meshes[0], state.far.materials[0], state.far_tiles:slice(0, far))
  }
}

func m.unload(){
  if(state.shader != null){
    state.near:unload()
    state.far:unload()
    state.shader:unload()
    state.shader = null
  }
}

return m
