// render/water: the river and the lake. The water's surface is the
// land's water level (which only changes along the valley) drawn as flat
// grids around the eye, and each pixel decides what is seen there from
// how deep the water stands over the ground: nothing where the ground is
// higher, the bed through clear shallows, darker and greener with depth,
// and on top the sky mirrored (more at a flat angle), the sun glittering
// on ripples that run downstream, and foam at the banks and where the
// river falls.
local rl = require("raylib")
local math = require("slang/math")
local kernel = require("kernel")
local shaders = require("render/shaders")

local m = {}

local vertex = """
in vec3 vertexPosition;
uniform mat4 matModel;
uniform sampler2D levelMap;
uniform vec4 land;
out vec3 worldPos;
out float fall;

void main(){
  float size = matModel[0][0];
  vec2 p = vec2(matModel[3][0], matModel[3][2]) + vertexPosition.xz * size;
  float u = (p.y + land.x) * land.y + 0.5 * land.z;
  float level = textureLod(levelMap, vec2(u, 0.5), 0.0).r;
  // how steeply the river falls here (per meter)
  fall = abs(textureLod(levelMap, vec2(u + land.z * 4.0, 0.5), 0.0).r - textureLod(levelMap, vec2(u - land.z * 4.0, 0.5), 0.0).r) / (8.0 * land.w);
  worldPos = vec3(p.x, level, p.y);
  gl_Position = viewProj * vec4(worldPos, 1.0);
}
"""

local fragment = """
in vec3 worldPos;
in float fall;
uniform sampler2D heightMap;
uniform sampler2D detailMap;
uniform vec4 land;
uniform vec4 inner;
out vec4 finalColor;

void main(){
  vec2 p = worldPos.xz;
  if(p.x > inner.x && p.y > inner.y && p.x < inner.z && p.y < inner.w){
    discard;
  }
  if(land.x - max(abs(p.x), abs(p.y)) < 6.0 || depthPass > 0.5){
    discard;
  }
  float ground = texture(heightMap, (p + land.x) * land.y + 0.5 * land.z).r;
  float depth = worldPos.y - ground;
  if(depth < 0.004){
    discard;
  }
  vec3 v = normalize(eye - worldPos);
  float dist = distance(eye, worldPos);
  // ripples: two layers of the grain running downstream at different
  // speeds; quick and choppy where the river is shallow or falls, slow
  // and smooth on the deep lake
  float calm = smoothstep(1.2, 3.5, depth) * (1.0 - smoothstep(0.0, 0.02, fall));
  float speed = mix(1.3, 0.12, calm) + fall * 30.0;
  vec2 run = vec2(0.0, time * speed);
  vec2 q1 = p * 0.13 + run * 0.13 + vec2(time * 0.01, 0.0);
  vec2 q2 = p * 0.31 + run * 0.31 * 1.5 + vec2(0.3, 0.1);
  float e = 0.012;
  float h0 = texture(detailMap, q1).b * 0.7 + texture(detailMap, q2).b * 0.3;
  float hx = texture(detailMap, q1 + vec2(e, 0.0)).b * 0.7 + texture(detailMap, q2 + vec2(e, 0.0)).b * 0.3;
  float hz = texture(detailMap, q1 + vec2(0.0, e)).b * 0.7 + texture(detailMap, q2 + vec2(0.0, e)).b * 0.3;
  float rough = mix(0.085, 0.03, calm) * (1.0 - smoothstep(60.0, 400.0, dist) * 0.7);
  vec3 n = normalize(vec3((h0 - hx) / e * rough, 1.0, (h0 - hz) / e * rough));

  float shadow = sunShadow(worldPos, vec3(0.0, 1.0, 0.0));
  float fres = 0.02 + 0.98 * pow(1.0 - max(dot(n, v), 0.0), 5.0);
  // what is under the surface: clear over the bed, then green, then dark
  vec3 shallow = vec3(0.09, 0.16, 0.12);
  vec3 deep = vec3(0.012, 0.05, 0.06);
  vec3 body = mix(shallow, deep, 1.0 - exp(-depth * 0.9));
  body *= sunColor * max(sunDir.y, 0.0) * (0.25 + 0.75 * shadow) * 0.5 + ambientLight(vec3(0.0, 1.0, 0.0));
  float through = exp(-depth * 2.4);
  // what it mirrors: the sky, and the sun on the ripples
  vec3 r = reflect(-v, n);
  r.y = abs(r.y);
  vec3 mirror = skyLight(r);
  vec3 h = normalize(v + sunDir);
  float glint = pow(max(dot(n, h), 0.0), 520.0) * 9.0 + pow(max(dot(n, h), 0.0), 60.0) * 0.1;
  mirror += sunColor * glint * shadow;
  vec3 color = mix(body, mirror, fres);
  float alpha = max(1.0 - through, fres);
  // foam: at the banks, and where the water falls
  float bank = 1.0 - smoothstep(0.02, 0.14, depth);
  float streak = texture(detailMap, p * vec2(0.9, 0.22) + run * 0.3).g;
  float white = bank * smoothstep(0.35, 0.75, streak + 0.3 * sin(time * 1.7 + p.x * 2.0 + p.y * 1.3));
  white += smoothstep(0.012, 0.05, fall) * smoothstep(0.3, 0.8, streak * (0.6 + 0.4 * h0)) * (1.0 - calm);
  white = clamp(white, 0.0, 1.0);
  vec3 foam = vec3(0.82, 0.86, 0.88) * (sunColor * 0.3 * (0.3 + 0.7 * shadow) + ambientLight(vec3(0.0, 1.0, 0.0)) * 1.2);
  color = mix(color, foam, white * 0.85);
  alpha = max(alpha, white * 0.85);
  // thin at the very edge, so the water does not end in a line
  alpha *= smoothstep(0.004, 0.05, depth);
  finalColor = vec4(finish(color, worldPos), alpha);
}
"""

local state = {}

// init(land, textures, mesh): the water's shader; the textures and the
// grid are the land's (render/terrain's)
func m.init(land, textures, mesh){
  state.land = land
  state.mesh = mesh
  local n = land.n
  // the water's level along the valley: one number a row of the land
  local levels = kernel.float:array(n)
  for(local j = 0; j < n; j = j + 1){
    levels[j] = land.water[j * n]
  }
  state.levels = rl.texture.load_from_image({
    data: levels, width: n, height: 1, mipmaps: 1, format: rl.PIXELFORMAT_UNCOMPRESSED_R32,
  })
  state.levels.filter = rl.TEXTURE_FILTER_BILINEAR
  state.levels.wrap = rl.TEXTURE_WRAP_CLAMP
  local shader = shaders.load(vertex, fragment)
  state.shader = shader
  // (a model of its own for a material of its own; the mesh is shared)
  state.model = rl.mesh.plane(1, 1, 1, 1):to_model()
  local material = shaders.use(state.model, shader)
  material.maps[rl.MATERIAL_MAP_ALBEDO].texture = textures.height
  material.maps[rl.MATERIAL_MAP_METALNESS].texture = state.levels
  material.maps[rl.MATERIAL_MAP_NORMAL].texture = textures.detail
  shader.locs[rl.SHADER_LOC_MAP_ALBEDO] = shader:location("heightMap")
  shader.locs[rl.SHADER_LOC_MAP_METALNESS] = shader:location("levelMap")
  shader.locs[rl.SHADER_LOC_MAP_NORMAL] = shader:location("detailMap")
  shader:set("land", {land.half, 1 / (n * land.spacing), 1 / n, land.spacing}, rl.SHADER_UNIFORM_VEC4)
  state.material = material
}

// draw(view, world): the water, after everything solid (it is seen
// through)
func m.draw(view, world){
  if(view.depth_pass){
    return
  }
  local shader = state.shader
  shaders.apply(shader, view)
  local eye = view.eye
  local cells = 128
  local inner = {1, 1, -1, -1}
  for(let local size in values({2, 8, 32})){
    local x0 = math.floor((eye.x - cells * size / 2) / size) * size
    local z0 = math.floor((eye.z - cells * size / 2) / size) * size
    shader:set("inner", inner, rl.SHADER_UNIFORM_VEC4)
    rl.draw.mesh(state.mesh, state.material, {
      m0: size, m1: 0, m2: 0, m3: 0,
      m4: 0, m5: 1, m6: 0, m7: 0,
      m8: 0, m9: 0, m10: size, m11: 0,
      m12: x0, m13: 0, m14: z0, m15: 1,
    })
    inner = {x0 + size, z0 + size, x0 + cells * size - size, z0 + cells * size - size}
  }
}

func m.unload(){
  if(state.shader != null){
    state.model:unload()
    state.shader:unload()
    state.levels:unload()
    state.shader = null
  }
}

return m
