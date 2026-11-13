// render/terrain: the land drawn. Its heights are a texture; the ground
// is one flat grid of 128 by 128 squares drawn eight times around the
// camera, each time with squares twice as large, and lifted to the
// land's height by the vertex shader. Near the camera a square is half a
// meter (the land's fine heights: the same triangles the truck drives
// on), at the horizon 64. Where a grid ends, the next begins: its
// vertices slide onto the coarser grid's before the edge, so no cracks
// open between them and nothing pops as the camera moves.
//
// What the ground looks like comes from the maps game/terrain bakes: its
// shape (the normal, how much sky it sees, the mountains' shadows) and
// its cover (shares of rock, scree, dirt, mud, sand, snow, forest floor
// and grass). Each cover is a color and a relief made from one small
// repeating picture of grain, stones, blotches and pebbles, read at
// several sizes. Beyond the map the land goes on, coarse and without
// maps: rock, grass and snow by how steep and how high it is.
local rl = require("raylib")
local math = require("slang/math")
local terrain_lib = require("game/terrain")
local shaders = require("render/shaders")
local tracks = require("render/tracks")

local m = {}

m.CELLS = 128      // squares along a side of the grid
m.LEVELS = 8       // grids: squares of 0.5, 1, 2 .. 64 m

// what both stages need: the land's height at a place (the map's, going
// over into the far land's at its edge)
local shared = """
uniform sampler2D heightMap;
uniform sampler2D farMap;
uniform vec4 land;        // half the land's side, 1 / its side, a texel of its maps, the spacing
uniform float heightTexel; // a texel of the height map (finer than the other maps)
uniform vec4 farLand;     // the same of the land beyond the map

// 1 well inside the map, 0 at its edge and beyond
float inside(vec2 p){
  return smoothstep(4.0, 44.0, land.x - max(abs(p.x), abs(p.y)));
}
"""

local vertex = concat(shared, """
in vec3 vertexPosition;
uniform mat4 matModel;
uniform float cells;
out vec3 worldPos;

void main(){
  float size = matModel[0][0];
  vec2 origin = vec2(matModel[3][0], matModel[3][2]);
  vec2 cell = vertexPosition.xz;
  vec2 p = origin + cell * size;
  // toward the grid's edge every other vertex slides onto its neighbor:
  // the grid becomes the next coarser one there
  float reach = cells * size * 0.5;
  float away = max(abs(p.x - eye.x), abs(p.y - eye.z)) / reach;
  float k = smoothstep(0.66, 0.9, away);
  p = origin + mix(cell, floor(cell * 0.5) * 2.0, k) * size;
  float h = textureLod(farMap, (p + farLand.x) * farLand.y + 0.5 * farLand.z, 0.0).r;
  float in_map = inside(p);
  if(in_map > 0.0){
    // a coarse grid takes the mean height of what each of its squares
    // covers (the height map's smaller copies), not one sample of it: a
    // track cut into a far slope does not make the slope jagged
    float lod = log2(size * land.y / heightTexel) + k;
    h = mix(h, textureLod(heightMap, (p + land.x) * land.y + 0.5 * heightTexel, lod).r, in_map);
  }
  worldPos = vec3(p.x, h, p.y);
  gl_Position = viewProj * vec4(worldPos, 1.0);
}
""")

local fragment = concat(shared, """
in vec3 worldPos;
uniform sampler2D trackMap;
uniform vec4 trackInfo;   // 1 / the track map's side (m), its middle's x and z, on (1) or off
uniform sampler2D coverMap;
uniform sampler2D cover2Map;
uniform sampler2D detailMap;
uniform vec4 inner;       // the finer grid's square: drawn by it, not here
out vec4 finalColor;

// a normal tilted by a relief h (a height over the surface, m)
vec3 bumped(vec3 n, vec3 pos, float h){
  vec3 dpx = dFdx(pos);
  vec3 dpy = dFdy(pos);
  float dhx = dFdx(h);
  float dhy = dFdy(h);
  vec3 r1 = cross(dpy, n);
  vec3 r2 = cross(n, dpx);
  float det = dot(dpx, r1);
  vec3 grad = sign(det) * (dhx * r1 + dhy * r2);
  return normalize(abs(det) * n - grad);
}

void main(){
  vec2 p = worldPos.xz;
  if(p.x > inner.x && p.y > inner.y && p.x < inner.z && p.y < inner.w){
    discard;
  }
  float dist = distance(worldPos, eye);
  float in_map = inside(p);
  vec3 n = vec3(0.0, 1.0, 0.0);
  float sky = 1.0;
  float lit = 1.0;
  vec4 c1 = vec4(0.0);
  vec4 c2 = vec4(0.0, 0.0, 0.0, 1.0);
  if(in_map > 0.0){
    vec2 uv = (p + land.x) * land.y + 0.5 * land.z;
    // the normal from the heights themselves, over a step as wide as the
    // eye can tell at this distance (the shape map's has a byte a
    // direction, and snow shows every step of it as a band)
    float step_m = max(0.5, dist * 0.004);
    float lod = log2(step_m * land.y / heightTexel);
    vec2 huv = (p + land.x) * land.y + 0.5 * heightTexel;
    float du = step_m * land.y;
    float hl = textureLod(heightMap, huv - vec2(du, 0.0), lod).r;
    float hr = textureLod(heightMap, huv + vec2(du, 0.0), lod).r;
    float hd = textureLod(heightMap, huv - vec2(0.0, du), lod).r;
    float hu = textureLod(heightMap, huv + vec2(0.0, du), lod).r;
    n = normalize(vec3(hl - hr, 2.0 * step_m, hd - hu));
    // the light from four readings half a texel apart: a meter of the
    // map is wide on the screen near the eye, and its squares would show
    // in a shadow's edge on snow
    float e = 0.5 * land.z;
    vec2 soft = 0.25 * (texture(landLight, uv + vec2(e, e)).ba + texture(landLight, uv + vec2(-e, e)).ba +
      texture(landLight, uv + vec2(e, -e)).ba + texture(landLight, uv + vec2(-e, -e)).ba);
    sky = soft.x;
    lit = soft.y;
    c1 = texture(coverMap, uv);
    c2 = texture(cover2Map, uv);
  }
  if(in_map < 1.0){
    // beyond the map: the far land's own slope, and a cover by rule
    vec2 uv = (p + farLand.x) * farLand.y + 0.5 * farLand.z;
    float t = farLand.z;
    float hl = texture(farMap, uv - vec2(t, 0.0)).r;
    float hr = texture(farMap, uv + vec2(t, 0.0)).r;
    float hd = texture(farMap, uv - vec2(0.0, t)).r;
    float hu = texture(farMap, uv + vec2(0.0, t)).r;
    vec3 fn = normalize(vec3(hl - hr, 2.0 * farLand.w, hd - hu));
    // (the far land is smooth: break its slope up a little)
    float rough = vnoise(p * 0.02) - 0.5;
    float slope = sqrt(max(1.0 / (fn.y * fn.y) - 1.0, 0.0)) + 0.35 * rough;
    float patchy = vnoise(p * 0.011 + 40.0);
    float rock = smoothstep(0.6, 0.95, slope);
    float snow = smoothstep(405.0, 460.0, worldPos.y + 55.0 * (patchy - 0.5)) * (1.0 - smoothstep(0.75, 1.15, slope));
    float scree = smoothstep(0.4, 0.6, slope) * (1.0 - rock) * smoothstep(150.0, 330.0, worldPos.y);
    vec4 f1 = vec4(rock * (1.0 - snow), scree * (1.0 - snow), 0.0, 0.0);
    vec4 f2 = vec4(0.0, snow, 0.0, 0.0);
    // the woods of the far slopes, as a darker green
    float woods = smoothstep(0.35, 0.6, vnoise(p * 0.004 + 9.0)) * (1.0 - smoothstep(280.0, 340.0, worldPos.y)) * (1.0 - rock);
    f2.b = woods * (1.0 - snow) * (1.0 - scree);
    f2.a = max(1.0 - f1.r - f1.g - f2.g - f2.b, 0.0);
    n = normalize(mix(fn, n, in_map));
    c1 = mix(f1, c1, in_map);
    c2 = mix(f2, c2, in_map);
    sky = mix(1.0, sky, in_map);
    lit = mix(1.0, lit, in_map);
  }

  // the small patterns, at three sizes; on a slope they are read from
  // the side it faces, or they would run down it in streaks
  vec3 facing = abs(n);
  facing = facing * facing * facing * facing;
  facing /= facing.x + facing.y + facing.z;
  vec4 fine = texture(detailMap, p * 0.33) * facing.y + texture(detailMap, worldPos.zy * 0.33) * facing.x +
    texture(detailMap, worldPos.xy * 0.33) * facing.z;
  vec4 mid = texture(detailMap, p * 0.052 + 0.37) * facing.y + texture(detailMap, worldPos.zy * 0.052 + 0.37) * facing.x +
    texture(detailMap, worldPos.xy * 0.052 + 0.37) * facing.z;
  float macro = vnoise(p * 0.0043 + 3.0);
  float near = 1.0 - smoothstep(30.0, 90.0, dist);

  // sharper edges between covers than the maps have: the grain decides
  float jitter = (fine.r - 0.5) * 0.6 * near;
  float w_rock = c1.r;
  float w_scree = smoothstep(0.3, 0.7, c1.g + jitter * step(0.02, c1.g));
  float w_dirt = smoothstep(0.3, 0.7, c1.b + jitter * step(0.02, c1.b));
  float w_mud = smoothstep(0.3, 0.7, c1.a + jitter * step(0.02, c1.a));
  float w_sand = c2.r;
  float w_snow = smoothstep(0.35, 0.65, c2.g + jitter * step(0.02, c2.g));
  float w_forest = c2.b;
  float total = w_rock + w_scree + w_dirt + w_mud + w_sand + w_snow + w_forest;
  float w_grass = max(1.0 - total, 0.0);
  total = max(total + w_grass, 0.001);

  vec3 albedo = vec3(0.0);
  float relief = 0.0;
  float gloss = 0.0;

  if(w_rock > 0.004){
    // on a wall the pattern is read from the side it faces
    vec3 an = facing;
    vec4 r = texture(detailMap, worldPos.zy * 0.19) * an.x + texture(detailMap, p * 0.19) * an.y +
      texture(detailMap, worldPos.xy * 0.19) * an.z;
    vec3 c = mix(vec3(0.105, 0.097, 0.088), vec3(0.27, 0.25, 0.225), r.b * 0.4 + mid.b * 0.3 + fine.r * 0.3);
    // the strata: bands by height, bent a little
    float band = vnoise(vec2(worldPos.y * 0.42 + mid.b * 2.5, 3.7));
    c *= 0.8 + 0.4 * band;
    // cracks between the blocks: thin, and not everywhere
    c *= 1.0 - 0.42 * (1.0 - smoothstep(0.02, 0.12, r.g)) * smoothstep(0.3, 0.6, mid.r);
    c *= mix(vec3(1.04, 0.98, 0.9), vec3(0.93, 0.97, 1.03), macro);
    albedo += w_rock * c;
    relief += w_rock * (r.r * 0.04 + smoothstep(0.02, 0.12, r.g) * 0.03 + fine.r * 0.02 + band * 0.02);
  }
  if(w_scree > 0.004){
    vec3 c = mix(vec3(0.085, 0.08, 0.075), vec3(0.29, 0.275, 0.255), fine.g * 0.7 + mid.g * 0.3);
    c *= 0.8 + 0.4 * fine.a;
    albedo += w_scree * c;
    relief += w_scree * (fine.g * 0.05 + mid.g * 0.03);
  }
  if(w_dirt > 0.004){
    vec3 c = mix(vec3(0.115, 0.078, 0.047), vec3(0.235, 0.17, 0.105), fine.r * 0.55 + mid.b * 0.45);
    c = mix(c, vec3(0.27, 0.25, 0.22), smoothstep(0.72, 0.9, fine.a) * 0.8);
    albedo += w_dirt * c;
    relief += w_dirt * (fine.r * 0.02 + smoothstep(0.6, 0.9, fine.a) * 0.03);
  }
  if(w_mud > 0.004){
    vec3 c = mix(vec3(0.075, 0.055, 0.038), vec3(0.15, 0.108, 0.072), fine.r);
    float puddle = smoothstep(0.5, 0.35, mid.b);
    albedo += w_mud * mix(c, c * 0.6, puddle);
    relief += w_mud * fine.r * 0.02 * (1.0 - puddle);
    gloss += w_mud * mix(0.35, 0.92, puddle);
  }
  if(w_sand > 0.004){
    vec3 c = mix(vec3(0.25, 0.215, 0.155), vec3(0.4, 0.355, 0.265), fine.r);
    c = mix(c, vec3(0.2, 0.19, 0.175), smoothstep(0.55, 0.85, fine.a) * 0.7);
    albedo += w_sand * c;
    relief += w_sand * (fine.r * 0.01 + smoothstep(0.55, 0.85, fine.a) * 0.03);
  }
  if(w_snow > 0.004){
    vec3 c = vec3(0.55, 0.57, 0.6) * (0.9 + 0.1 * mid.r);
    albedo += w_snow * c;
    relief += w_snow * mid.r * 0.02;
    gloss += w_snow * 0.25;
  }
  if(w_forest > 0.004){
    vec3 c = mix(vec3(0.045, 0.06, 0.03), vec3(0.075, 0.095, 0.045), fine.r * 0.5 + mid.b * 0.5);
    albedo += w_forest * c;
    relief += w_forest * fine.r * 0.02;
  }
  if(w_grass > 0.004){
    // the ground under the grass, and the meadow seen from afar: greener
    // low down, yellower and drier up high
    vec3 lush = mix(vec3(0.055, 0.105, 0.028), vec3(0.11, 0.155, 0.045), mid.b * 0.5 + macro * 0.5);
    vec3 dry = mix(vec3(0.12, 0.125, 0.05), vec3(0.19, 0.17, 0.075), mid.b * 0.5 + macro * 0.5);
    vec3 c = mix(lush, dry, smoothstep(170.0, 400.0, worldPos.y + 80.0 * (macro - 0.5)));
    // (as dark as the blades are with the shade between them; from afar,
    // where no blades are drawn, as bright as their tips)
    c *= mix(0.62, 0.92, smoothstep(22.0, 60.0, dist)) + 0.3 * fine.r;
    albedo += w_grass * c;
    relief += w_grass * fine.r * 0.03;
  }
  albedo /= total;
  relief /= total;
  gloss /= total;

  // where the wheels have pressed the ground: darker (earth is damp
  // underneath, grass lies flat), bluer in snow, shining in mud, and a
  // dent the light catches
  if(trackInfo.w > 0.5 && dist < 120.0){
    vec2 q = abs(p - trackInfo.yz) * trackInfo.x;
    // (four readings half a texel apart: the map's texels are a hand
    // wide, and their edges would show in the light)
    vec2 tq = p * trackInfo.x;
    float e = trackInfo.x * 0.0625;
    float track = 0.25 * (texture(trackMap, tq + vec2(e, e)).r + texture(trackMap, tq + vec2(-e, e)).r +
      texture(trackMap, tq + vec2(e, -e)).r + texture(trackMap, tq + vec2(-e, -e)).r);
    track *= (1.0 - smoothstep(0.36, 0.45, max(q.x, q.y))) * (1.0 - smoothstep(70.0, 120.0, dist));
    if(track > 0.004){
      float snowy = w_snow / total;
      float muddy = w_mud / total;
      vec3 pressed = albedo * mix(vec3(0.6, 0.58, 0.56), vec3(0.72, 0.8, 0.92), snowy);
      pressed = mix(pressed, albedo * 0.5, muddy);
      albedo = mix(albedo, pressed, track);
      relief -= track * (0.045 + 0.04 * snowy);
      gloss += track * 0.1 * muddy;
    }
  }

  // wet at the water's edge
  // (the banks and the bed: darker, and shining a little)
  float damp = w_sand * 0.5 + w_mud * 0.3;
  albedo *= 1.0 - 0.3 * damp;

  vec3 nb = n;
  if(near > 0.0){
    nb = normalize(mix(n, bumped(n, worldPos, relief * 1.6), near));
  }
  float shadow = lit * mapShadow(worldPos, n) * cloudShadow(worldPos);
  float ndl = max(dot(nb, sunDir), 0.0);
  // (a slope facing away from the sun is not lit through its bumps)
  ndl *= smoothstep(-0.05, 0.1, dot(n, sunDir));
  vec3 color = albedo * (sunColor * ndl * shadow + ambientLight(nb) * (0.35 + 0.65 * sky));
  if(gloss > 0.01){
    vec3 v = normalize(eye - worldPos);
    vec3 h = normalize(v + sunDir);
    float fres = 0.04 + 0.96 * pow(1.0 - max(dot(nb, v), 0.0), 5.0);
    float power = exp2(3.0 + gloss * 8.0);
    // (the sun's glint no brighter than a wet stone's: a rut's edge is
    // not a mirror)
    float glint = min(pow(max(dot(nb, h), 0.0), power) * (power + 8.0) / 25.0, 1.6);
    color += gloss * (sunColor * glint * ndl * shadow * 0.25 + skyLight(reflect(-v, nb)) * fres * sky);
  }
  finalColor = vec4(finish(color, worldPos), 1.0);
}
""")

local state = {}

// a texture of four bytes a pixel from a kernel's array, smooth and with
// smaller copies of itself for the distance
local func byte_texture(data, size, wrap){
  local texture = rl.texture.load_from_image({
    data: data, width: size, height: size, mipmaps: 1,
    format: rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
  })
  texture:gen_mipmaps()
  texture.filter = rl.TEXTURE_FILTER_TRILINEAR
  texture.wrap = wrap
  return texture
}

// (smaller: with smaller copies of itself, for what reads it coarsely)
local func float_texture(data, size, smaller){
  local texture = rl.texture.load_from_image({
    data: data, width: size, height: size, mipmaps: 1,
    format: rl.PIXELFORMAT_UNCOMPRESSED_R32,
  })
  if(smaller){
    texture:gen_mipmaps()
    texture.filter = rl.TEXTURE_FILTER_TRILINEAR
  } else {
    texture.filter = rl.TEXTURE_FILTER_BILINEAR
  }
  texture.wrap = rl.TEXTURE_WRAP_CLAMP
  return texture
}

// init(land: terrain.Terrain): the land's textures, the grid, the shader
func m.init(land){
  state.land = land
  local n = land.n
  local textures = {}
  textures.height = float_texture(land.heights, n)
  // (what the ground itself is drawn from)
  local fine = land.fine or land
  textures.fine = float_texture(fine.heights, fine.n, true)
  state.spacing = fine.spacing
  textures.shape = byte_texture(land.shape, n, rl.TEXTURE_WRAP_CLAMP)
  textures.cover = byte_texture(land.cover, n, rl.TEXTURE_WRAP_CLAMP)
  textures.cover2 = byte_texture(land.cover2, n, rl.TEXTURE_WRAP_CLAMP)
  local detail = terrain_lib.detail(512, land.seed)
  textures.detail = byte_texture(detail.data, detail.size, rl.TEXTURE_WRAP_REPEAT)
  local far = land.far
  textures.far = float_texture(far.heights, far.n)
  state.textures = textures
  // every shader reads the mountains' shadows from the shape map
  shaders.land_texture = textures.shape
  shaders.land_info = {land.half, 1 / (n * land.spacing), 1 / n, 1}

  // the grid: CELLS + 1 vertices a side at whole numbers, two triangles a
  // square
  local c = m.CELLS
  local vertices = {}
  for(local j = 0; j <= c; j = j + 1){
    for(local i = 0; i <= c; i = i + 1){
      append(vertices, i)
      append(vertices, 0)
      append(vertices, j)
    }
  }
  local indices = {}
  local row = c + 1
  for(local j = 0; j < c; j = j + 1){
    for(local i = 0; i < c; i = i + 1){
      local a = j * row + i
      // (counter clockwise seen from above; split from the square's first
      // corner to the one across, as the physics splits it)
      append(indices, a)
      append(indices, a + row)
      append(indices, a + row + 1)
      append(indices, a)
      append(indices, a + row + 1)
      append(indices, a + 1)
    }
  }
  state.mesh = rl.mesh({vertices: vertices, indices: indices})
  state.model = state.mesh:to_model()
  local shader = shaders.load(vertex, fragment)
  state.shader = shader
  state.material = shaders.use(state.model, shader)
  local maps = state.material.maps
  local slots = {
    {rl.MATERIAL_MAP_ALBEDO, rl.SHADER_LOC_MAP_ALBEDO, "heightMap", textures.fine},
    {rl.MATERIAL_MAP_METALNESS, rl.SHADER_LOC_MAP_METALNESS, "trackMap", tracks.texture() or textures.shape},
    {rl.MATERIAL_MAP_NORMAL, rl.SHADER_LOC_MAP_NORMAL, "coverMap", textures.cover},
    {rl.MATERIAL_MAP_ROUGHNESS, rl.SHADER_LOC_MAP_ROUGHNESS, "cover2Map", textures.cover2},
    {rl.MATERIAL_MAP_OCCLUSION, rl.SHADER_LOC_MAP_OCCLUSION, "detailMap", textures.detail},
    {rl.MATERIAL_MAP_EMISSION, rl.SHADER_LOC_MAP_EMISSION, "farMap", textures.far},
  }
  for(let local slot in values(slots)){
    maps[slot[0]].texture = slot[3]
    shader.locs[slot[1]] = shader:location(slot[2])
  }
  shader:set("land", {land.half, 1 / (n * land.spacing), 1 / n, land.spacing}, rl.SHADER_UNIFORM_VEC4)
  shader:set("farLand", {far.half, 1 / (far.n * far.spacing), 1 / far.n, far.spacing}, rl.SHADER_UNIFORM_VEC4)
  shader:set("heightTexel", 1.0 / fine.n)
  shader:set("cells", c * 1.0)
}

// textures() -> {height, fine, shape, cover, cover2, detail, far}: the
// land's maps as textures, for what else is drawn on it (the grass, the
// water); height has a texel per sample like the other maps, fine is the
// fine heights
func m.textures(){
  return state.textures
}

// grid() -> Mesh: the flat grid of squares the land is drawn with
func m.grid(){
  return state.mesh
}

// draw(view: scene.View): the ground around the camera (not into the
// sun's shadow map: the land's own shadows are baked)
func m.draw(view){
  if(view.depth_pass){
    return
  }
  local shader = state.shader
  shaders.apply(shader, view)
  shader:set("trackInfo", if(tracks.texture() != null){ tracks.info() } else { {0, 0, 0, 0} }, rl.SHADER_UNIFORM_VEC4)
  local eye = view.eye
  local c = m.CELLS
  local inner = {1, 1, -1, -1}
  for(local level = 0; level < m.LEVELS; level = level + 1){
    local size = state.spacing * (1 << level)
    // the grid's corner: on a square of the next coarser grid
    local snap = size * 2
    local x0 = math.floor((eye.x - c * size / 2) / snap) * snap
    local z0 = math.floor((eye.z - c * size / 2) / snap) * snap
    shader:set("inner", inner, rl.SHADER_UNIFORM_VEC4)
    rl.draw.mesh(state.mesh, state.material, {
      m0: size, m1: 0, m2: 0, m3: 0,
      m4: 0, m5: 1, m6: 0, m7: 0,
      m8: 0, m9: 0, m10: size, m11: 0,
      m12: x0, m13: 0, m14: z0, m15: 1,
    })
    // the next grid leaves this one's square out, but for a strip at its
    // edge where the two are the same surface
    inner = {x0 + size, z0 + size, x0 + c * size - size, z0 + c * size - size}
  }
}

func m.unload(){
  if(state.model != null){
    state.model:unload()
    state.shader:unload()
    for(let local e in entries(state.textures)){
      e[1]:unload()
    }
    state.model = null
    shaders.land_texture = null
    shaders.land_info = {0, 0, 0, 0}
  }
}

return m
