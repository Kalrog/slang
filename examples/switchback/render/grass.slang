// render/grass: the grass. A mesh of a few thousand blades over a square
// of ground is drawn on every such square around the eye that the eye
// can see; the vertex shader stands each blade on the land (its height
// from the height map), makes it as tall as there is grass there (the
// land's cover: none on the track, on rock, in the mud), turns it to face
// the eye, bends it in the wind and lays it flat near the truck. The
// squares lie in three rings: near the eye the blades are many and thin,
// farther off a quarter of them, broader, then a sixteenth on squares
// twice as wide; from forty meters on they take on the color and the
// light of the ground, and past eighty-five they sink into it.
local rl = require("raylib")
local math = require("slang/math")
local buffer = require("slang/buffer")
local vec = require("game/vec")
local shaders = require("render/shaders")
local tracks = require("render/tracks")

local m = {}

m.TILE = 8.0        // meters along a side of a square of blades
// the rings, out to how far from the eye (m, along the ground): every
// blade on squares of TILE, a quarter of them, a sixteenth on squares of
// twice TILE; within a ring three blades of four thin out toward its
// end, and the fourth broadens, so that the next ring's blades go on
// where they end
m.REACH = {20, 64, 120}
m.BLADES = {7200, 1800, 1800}
// where all blades sink into the ground (m from the eye); from half the
// first on they take on its color and light, so that no line shows where
// they end
m.FADE = {85, 120}

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
uniform vec4 blades;      // the ring: from, to (m from the eye along the ground), the blades' width, 0
uniform vec2 thin;        // where three blades of four thin out (from, to; 0, 0: none do)
uniform vec2 fade;        // where all sink into the ground
uniform vec3 truck;
out vec3 worldPos;
out vec3 tint;
out vec3 normal;
out float sink;
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
  keep *= 1.0 - smoothstep(fade.x, fade.y, dist);
  // (the ring's own blades only: the next ring's square may overlap it)
  float flat_dist = distance(root, eye.xz);
  keep *= step(blades.x, flat_dist) * (1.0 - step(blades.y, flat_dist));
  // three blades of four shrink with the distance and the fourth
  // broadens: farther off there are fewer, wider ones
  float width = blades.z;
  if(thin.y > 0.0){
    float far = smoothstep(thin.x, thin.y, dist);
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
  vec3 meadow = mix(lush, dry, high);
  vec3 c = meadow * (0.8 + 0.5 * vertexNormal.x);
  tint = c * mix(0.5, 1.45, t) + vec3(0.02, 0.022, 0.0) * t;
  // a few flowers: the tip of one blade in some hundreds
  if(vertexNormal.z > 0.993 && t > 0.9 && high < 0.6){
    tint = mix(vec3(0.75, 0.7, 0.2), vec3(0.7, 0.72, 0.78), step(0.5, rnd));
  }
  // farther off, before they sink into the ground, they take on its color
  // from afar (its average in render/terrain) and its light, so that no
  // line shows where they end
  sink = smoothstep(fade.x * 0.5, fade.x, dist);
  tint = mix(tint, meadow * 1.07, sink);
  // lit like the ground it stands on, a little toward the eye
  normal = normalize(vec3(facing.x * 0.35 + bend.x, 1.0, facing.y * 0.35 + bend.y));
  if(sink > 0.0){
    float hx = textureLod(heightMap, uv + vec2(land.z, 0.0), 0.0).r - textureLod(heightMap, uv - vec2(land.z, 0.0), 0.0).r;
    float hz = textureLod(heightMap, uv + vec2(0.0, land.z), 0.0).r - textureLod(heightMap, uv - vec2(0.0, land.z), 0.0).r;
    normal = normalize(mix(normal, normalize(vec3(-hx, 2.0 * land.w, -hz)), sink));
  }
  gl_Position = viewProj * vec4(pos, 1.0);
}
"""

local fragment = """
in vec3 worldPos;
in vec3 tint;
in vec3 normal;
in float sink;
in float along;
out vec4 finalColor;

void main(){
  vec3 n = normalize(normal);
  float shadow = sunShadow(worldPos, vec3(0.0, 1.0, 0.0));
  // (darker down between the blades)
  vec3 color = shadeLeaf(tint, n, worldPos, shadow, 0.55) * (0.55 + 0.45 * along);
  if(sink > 0.0){
    color = mix(color, shade(tint, n, worldPos, shadow), sink);
  }
  finalColor = vec4(finish(color, worldPos), 1.0);
}
"""

local state = {}

// a square of blades as a mesh: count blades scattered over a square of
// side meters, each three segments tall
local func blades_mesh(count, side, seed){
  local rng = vec.random(seed)
  local vertices = {}
  local texcoords = {}
  local normals = {}
  local indices = {}
  local v = 0
  for(local b = 0; b < count; b = b + 1){
    local x = rng:next() * side
    local z = rng:next() * side
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
  shader:set("fade", {m.FADE[0], m.FADE[1]}, rl.SHADER_UNIFORM_VEC2)
  // the rings: the side of their squares, from and to where (m), the
  // blades' width, where three of four thin out (as the shader's uniforms)
  local t = m.TILE
  state.rings = {
    {side: t, from: 0, to: m.REACH[0], width: 0.016, thin: {m.REACH[0] * 0.55, m.REACH[0] * 0.95}, seed: 11},
    {side: t, from: m.REACH[0], to: m.REACH[1], width: 0.032, thin: {m.REACH[1] * 0.55, m.REACH[1] * 0.95}, seed: 23},
    {side: 2 * t, from: m.REACH[1], to: m.REACH[2], width: 0.064, thin: {0, 0}, seed: 37},
  }
  for(local k = 0; k < 3; k = k + 1){
    local ring = state.rings[k]
    ring.model = blades_mesh(m.BLADES[k], ring.side, ring.seed):to_model()
    local material = shaders.use(ring.model, shader)
    material.maps[rl.MATERIAL_MAP_ALBEDO].texture = textures.height
    material.maps[rl.MATERIAL_MAP_METALNESS].texture = textures.cover2
    material.maps[rl.MATERIAL_MAP_NORMAL].texture = tracks.texture() or textures.cover2
    // the squares' transforms: sixteen floats each, column by column (as
    // the shader reads them), only the move changing from frame to frame;
    // and where they are on the graphics card
    local across = to_int(2 * ring.to / ring.side) + 2
    ring.most = across * across
    ring.tiles = buffer.new("float", ring.most * 16)
    for(local i = 0; i < ring.most; i = i + 1){
      ring.tiles[i * 16] = 1
      ring.tiles[i * 16 + 5] = 1
      ring.tiles[i * 16 + 10] = 1
      ring.tiles[i * 16 + 15] = 1
    }
    ring.instances = rl.instances(ring.most)
  }
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
  local land = state.land
  local heights = land.heights
  local n = land.n
  local eye = view.eye
  local f = view.forward
  // the cone the eye sees: its corners' angle
  local th = math.tan(view.fovy / 2) * math.sqrt(1 + view.aspect * view.aspect)
  local sec = math.sqrt(1 + th * th)
  for(let local ring in values(state.rings)){
    local s = ring.side
    // (a square's ground may slope, and its blades lean out of it)
    local round = s * 0.885 + 1.5
    local outer = ring.to * ring.to
    local inner = ring.from * ring.from
    local tiles = ring.tiles
    local count = 0
    local z0 = to_int(math.floor((eye.z - ring.to) / s))
    local z1 = to_int(math.floor((eye.z + ring.to) / s))
    for(local iz = z0; iz <= z1; iz = iz + 1){
      local z = iz * s
      // how near and how far the square's row comes to the eye across
      local near_z = math.max(math.max(z - eye.z, eye.z - z - s), 0)
      local far_z = math.max(math.abs(z - eye.z), math.abs(z + s - eye.z))
      // (the squares of the row that come within the ring's end)
      local wide = math.sqrt(math.max(outer - near_z * near_z, 0))
      local x1 = to_int(math.floor((eye.x + wide) / s))
      for(local ix = to_int(math.floor((eye.x - wide) / s)); ix <= x1; ix = ix + 1){
        local x = ix * s
        local far_x = math.max(math.abs(x - eye.x), math.abs(x + s - eye.x))
        // (not the squares wholly inside the ring before)
        if(far_x * far_x + far_z * far_z >= inner){
          // seen: in the cone, with the ground's height at the square's
          // middle
          local mx = x + s / 2
          local mz = z + s / 2
          local i = to_int(vec.clamp((mx + land.half) / land.spacing, 0, n - 1))
          local j = to_int(vec.clamp((mz + land.half) / land.spacing, 0, n - 1))
          local ex = mx - eye.x
          local ey = heights[j * n + i] + 0.4 - eye.y
          local ez = mz - eye.z
          local along = ex * f.x + ey * f.y + ez * f.z
          if(along > -round){
            local across = ex * ex + ey * ey + ez * ez - along * along
            local limit = math.max(along, 0) * th + round * sec
            if(across <= limit * limit){
              tiles[count * 16 + 12] = x
              tiles[count * 16 + 14] = z
              count = count + 1
            }
          }
        }
      }
    }
    if(count > 0){
      shader:set("blades", {ring.from, ring.to, ring.width, 0}, rl.SHADER_UNIFORM_VEC4)
      shader:set("thin", ring.thin, rl.SHADER_UNIFORM_VEC2)
      ring.instances:set(tiles:slice(0, count * 16))
      rl.draw.mesh_instances(ring.model.meshes[0], ring.model.materials[0], ring.instances, count)
    }
  }
}

func m.unload(){
  if(state.shader != null){
    for(let local ring in values(state.rings)){
      ring.model:unload()
      ring.instances:unload()
    }
    state.rings = null
    state.shader:unload()
    state.shader = null
  }
}

return m
