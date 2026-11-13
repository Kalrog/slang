// render/shaders: what every shader of the game shares. The world is
// drawn by the game's own shaders, not raylib's: each one starts with the
// code here (noise, the sky's color in a direction, the light of the sun
// and the sky on a surface, the haze of the air between it and the eye,
// the curve that turns light into a color for the screen), and each
// frame gets the same uniforms (where the eye is, the matrix of its
// view, the sun, the time).
//
//   local shader = shaders.load(vertex, fragment)   // GLSL without a #version
//   shaders.apply(shader, view)                     // before drawing with it
local rl = require("raylib")

local m = {}

local common = """#version 330
uniform mat4 viewProj;
uniform vec3 eye;
uniform vec3 sunDir;      // toward the sun
uniform vec3 sunColor;
uniform float time;
uniform float depthPass;  // 1 while the sun's shadow map is drawn
uniform sampler2D shadowMap;
uniform mat4 shadowProj;  // from the world into the shadow map
uniform vec4 shadowInfo;  // texel, how far it reaches from the eye, on (1) or off, 0
uniform sampler2D landLight;  // the land's shape map: in its alpha, the mountains' shadows
uniform vec4 landInfo;    // half the land's side, 1 / its side, a texel, on (1) or off

float hash12(vec2 p){
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

// smooth noise, 0..1
float vnoise(vec2 p){
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
             mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm2(vec2 p){
  float v = 0.0;
  float a = 0.5;
  for(int i = 0; i < 4; i++){
    v += a * vnoise(p);
    p = p * 2.03 + vec2(17.1, 9.2);
    a *= 0.5;
  }
  return v;
}

// a depth as a color, for the shadow map (a texture of colors), and
// back: in red, green and blue; the alpha stays 1, or blending would
// spoil the number
vec4 packDepth(float d){
  vec3 e = fract(d * vec3(1.0, 255.0, 65025.0));
  e -= e.yzz * vec3(1.0 / 255.0, 1.0 / 255.0, 0.0);
  return vec4(e, 1.0);
}

float unpackDepth(vec4 c){
  return dot(c.rgb, vec3(1.0, 1.0 / 255.0, 1.0 / 65025.0));
}

// the sky's light from a direction (no sun disc, no clouds): what the
// haze takes its color from and what shiny things mirror
vec3 skyLight(vec3 dir){
  float h = max(dir.y, 0.0);
  vec3 zenith = vec3(0.10, 0.26, 0.62);
  vec3 horizon = vec3(0.50, 0.66, 0.84);
  vec3 col = mix(horizon, zenith, pow(h, 0.5));
  // warmer and brighter toward the sun
  float s = max(dot(dir, sunDir), 0.0);
  col += sunColor * (0.07 * pow(s, 6.0) + 0.2 * pow(s, 48.0)) * vec3(1.0, 0.82, 0.6);
  // below the horizon: the haze over the land
  col = mix(col, vec3(0.42, 0.52, 0.62), smoothstep(0.0, -0.25, dir.y));
  return col;
}

// the light of the sky and of the ground's bounce on a surface facing n
vec3 ambientLight(vec3 n){
  vec3 sky = vec3(0.34, 0.47, 0.68) * (0.5 + 0.5 * n.y);
  vec3 bounce = vec3(0.2, 0.175, 0.115) * (0.5 - 0.5 * n.y);
  // (and what comes from all around: haze, the slopes across the valley)
  return sky + bounce + vec3(0.06, 0.065, 0.07);
}

// the light on a matte surface: the sun (shadow: how much of it
// arrives), the sky from above and the ground's bounce from below
vec3 shade(vec3 albedo, vec3 n, vec3 pos, float shadow){
  float ndl = max(dot(n, sunDir), 0.0);
  return albedo * (sunColor * ndl * shadow + ambientLight(n));
}

// the same for a leaf or a blade of grass: the sun also shines through
// it from behind (through: how much, 0 to 1)
vec3 shadeLeaf(vec3 albedo, vec3 n, vec3 pos, float shadow, float through){
  float ndl = dot(n, sunDir);
  float front = max(ndl, 0.0);
  float back = max(-ndl, 0.0) * through;
  vec3 v = normalize(eye - pos);
  float glow = pow(max(dot(-v, sunDir), 0.0), 4.0) * through;
  vec3 lit = sunColor * shadow * (front + back * 0.7 + glow * 0.5);
  return albedo * (lit + ambientLight(n)) + albedo * vec3(0.5, 0.6, 0.1) * sunColor * shadow * back * 0.25;
}

// the same for something that shines (lacquer, glass, wet rock): gloss 0
// (matte) to 1 (a mirror), metal 0 or 1
vec3 shadeGloss(vec3 albedo, vec3 n, vec3 pos, float shadow, float gloss, float metal){
  vec3 v = normalize(eye - pos);
  vec3 h = normalize(v + sunDir);
  float ndl = max(dot(n, sunDir), 0.0);
  float ndv = max(dot(n, v), 0.0);
  float fres = pow(1.0 - ndv, 5.0);
  vec3 f0 = mix(vec3(0.04), albedo, metal);
  vec3 f = f0 + (1.0 - f0) * fres;
  float power = exp2(2.0 + gloss * 10.0);
  float spec = pow(max(dot(n, h), 0.0), power) * (power + 8.0) / 25.0;
  vec3 mirror = skyLight(reflect(-v, n));
  vec3 diffuse = albedo * (1.0 - metal) * (sunColor * ndl * shadow + ambientLight(n));
  return diffuse * (1.0 - f * gloss) + f * (sunColor * spec * ndl * shadow + mirror * gloss);
}

// the air between a point and the eye, then the curve to the screen
vec3 toScreen(vec3 color){
  color = color * 0.62;
  color = (color * (2.51 * color + 0.03)) / (color * (2.43 * color + 0.59) + 0.14);
  return pow(clamp(color, 0.0, 1.0), vec3(1.0 / 2.2));
}

vec3 finish(vec3 color, vec3 pos){
  vec3 v = pos - eye;
  float d = length(v);
  vec3 dir = v / max(d, 0.001);
  // thicker low down: the haze lies in the valley
  float low = exp(-max(pos.y + eye.y, 0.0) * 0.5 * 0.006);
  float fog = 1.0 - exp(-d * 0.00030 * (0.35 + low));
  vec3 air = skyLight(normalize(vec3(dir.x, max(dir.y, 0.02) * 0.4, dir.z)));
  color = mix(color, air, fog);
  return toScreen(color);
}
"""

// what only the fragment stage can do
local fragment_common = """
// the shadows of the clouds, drifting over the land
float cloudShadow(vec3 pos){
  vec2 p = (pos.xz + sunDir.xz * (900.0 - pos.y) / sunDir.y) * 0.0011 + vec2(time * 0.006, time * 0.002);
  float d = fbm2(p) * 0.7 + fbm2(p * 3.1 + 4.0) * 0.3;
  return 1.0 - 0.6 * smoothstep(0.5, 0.74, d);
}

// the shadows of the mountains (soft and far; baked into the land's
// shape map)
float landShadow(vec3 pos){
  if(landInfo.w < 0.5){
    return 1.0;
  }
  return texture(landLight, (pos.xz + landInfo.x) * landInfo.y + 0.5 * landInfo.z).a;
}

// the shadows of the things near the eye (trees, rocks, the truck), from
// the shadow map: 1 in the light, 0 in shadow, soft at the edge
float mapShadow(vec3 pos, vec3 n){
  if(shadowInfo.z < 0.5){
    return 1.0;
  }
  vec3 q = pos + n * 0.06;
  vec4 sp = shadowProj * vec4(q, 1.0);
  vec3 uvz = sp.xyz * 0.5 + 0.5;
  if(uvz.x < 0.0 || uvz.x > 1.0 || uvz.y < 0.0 || uvz.y > 1.0 || uvz.z > 1.0){
    return 1.0;
  }
  float bias = 0.00035;
  float lit = 0.0;
  float turn = hash12(gl_FragCoord.xy) * 6.2831;
  mat2 rot = mat2(cos(turn), sin(turn), -sin(turn), cos(turn));
  for(int i = 0; i < 6; i++){
    float a = float(i) * 2.399963;
    float r = sqrt((float(i) + 0.5) / 6.0) * 1.8;
    vec2 o = rot * vec2(cos(a), sin(a)) * r * shadowInfo.x;
    lit += step(uvz.z - bias, unpackDepth(texture(shadowMap, uvz.xy + o)));
  }
  lit /= 6.0;
  // fading out where the map ends
  float edge = distance(pos, eye) / shadowInfo.y;
  return mix(lit, 1.0, smoothstep(0.8, 1.0, edge));
}

// how much of the sun reaches a point: all three
float sunShadow(vec3 pos, vec3 n){
  return mapShadow(pos, n) * landShadow(pos) * cloudShadow(pos);
}
"""

// the same for a pass that only needs the functions
m.common = common

// load(vertex: string, fragment: string) -> Shader
// A shader from the two stages' code, each after the shared code. A
// fragment stage that draws something solid starts its main with
//   if(depthPass > 0.5){ finalColor = packDepth(gl_FragCoord.z); return; }
// (after discarding what is cut out), so that the same shader draws the
// thing into the sun's shadow map.
func m.load(vertex, fragment){
  local shader = rl.shader({
    vertex: concat(common, vertex), fragment: concat(common, fragment_common, fragment),
  })
  // the shadow map is every material's last texture, the land's shape
  // map the one before the cube maps (see use)
  shader.locs[rl.SHADER_LOC_MAP_BRDF] = shader:location("shadowMap")
  shader.locs[rl.SHADER_LOC_MAP_HEIGHT] = shader:location("landLight")
  return shader
}

// what the sun's shadows are read from, once render/shadows has made it
m.shadow_texture = null
// the land's shape map and {half its side, 1 / its side, a texel, 1},
// once render/terrain has made it
m.land_texture = null
m.land_info = {0, 0, 0, 0}

// use(model: Model, shader: Shader) -> Material
// The model's material drawing with shader (and reading the shadow map):
// what rl.draw.mesh and rl.draw.mesh_instanced take.
func m.use(model, shader){
  local material = model.materials[0]
  material.shader = shader
  if(m.shadow_texture != null){
    material.maps[rl.MATERIAL_MAP_BRDF].texture = m.shadow_texture
  }
  if(m.land_texture != null){
    material.maps[rl.MATERIAL_MAP_HEIGHT].texture = m.land_texture
  }
  return material
}

// apply(shader, view: scene.View): the frame's uniforms (the sun's own
// view while its shadow map is drawn)
func m.apply(shader, view){
  shader:set("viewProj", view.view_proj)
  shader:set("eye", view.eye, rl.SHADER_UNIFORM_VEC3)
  shader:set("sunDir", view.sun_dir, rl.SHADER_UNIFORM_VEC3)
  shader:set("sunColor", view.sun_color, rl.SHADER_UNIFORM_VEC3)
  shader:set("time", view.time * 1.0)
  shader:set("depthPass", if(view.depth_pass){ 1.0 } else { 0.0 })
  if(view.shadow != null){
    shader:set("shadowProj", view.shadow.proj)
    shader:set("shadowInfo", {view.shadow.texel, view.shadow.reach, 1, 0}, rl.SHADER_UNIFORM_VEC4)
  } else {
    shader:set("shadowInfo", {0, 0, 0, 0}, rl.SHADER_UNIFORM_VEC4)
  }
  shader:set("landInfo", m.land_info, rl.SHADER_UNIFORM_VEC4)
}

return m
