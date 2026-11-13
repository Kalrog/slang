// render/sky: the sky, drawn flat behind everything: each pixel's
// direction from the eye gives its color, the sun's disc and glow, and
// clouds drifting over.
local rl = require("raylib")
local math = require("slang/math")
local shaders = require("render/shaders")

local m = {}

local vertex = """
in vec3 vertexPosition;
uniform mat4 mvp;
void main(){
  gl_Position = mvp * vec4(vertexPosition, 1.0);
}
"""

local fragment = """
uniform vec3 camForward;
uniform vec3 camRight;
uniform vec3 camUp;
uniform vec2 tanHalf;
uniform vec2 resolution;
out vec4 finalColor;

void main(){
  vec2 uv = gl_FragCoord.xy / resolution * 2.0 - 1.0;
  vec3 dir = normalize(camForward + camRight * uv.x * tanHalf.x + camUp * uv.y * tanHalf.y);
  vec3 col = skyLight(dir);
  // the sun
  float s = max(dot(dir, sunDir), 0.0);
  col += sunColor * (smoothstep(0.99955, 0.9998, s) * 4.0 + pow(s, 900.0) * 0.6);
  // clouds: a layer high over the land, drifting: thin at their edges,
  // where the sun shines through them, dense and grey in the middle
  if(dir.y > 0.01){
    vec2 p = dir.xz / (dir.y + 0.12) * 1.5 + vec2(time * 0.006, time * 0.002);
    float d = fbm2(p) * 0.62 + fbm2(p * 2.7 + 4.0) * 0.28 + fbm2(p * 7.3 + 9.0) * 0.1;
    float dense = smoothstep(0.47, 0.8, d);
    float cover = smoothstep(0.0, 0.25, dense) * smoothstep(0.01, 0.14, dir.y);
    vec3 lit = vec3(1.18, 1.14, 1.08);
    vec3 dark = vec3(0.5, 0.56, 0.68);
    vec3 cloud = mix(lit, dark, smoothstep(0.1, 0.95, dense));
    // toward the sun the thin parts glow
    cloud += sunColor * pow(s, 10.0) * 0.35 * (1.0 - dense);
    // far off they sink into the haze
    cloud = mix(skyLight(dir), cloud, smoothstep(0.02, 0.3, dir.y) * 0.85 + 0.15);
    col = mix(col, cloud, cover);
  }
  finalColor = vec4(toScreen(col), 1.0);
}
"""

local state = {}

func m.init(){
  state.shader = shaders.load(vertex, fragment)
}

// draw(view): the whole screen, before anything of the world
func m.draw(view){
  local shader = state.shader
  rl.draw.clear({140, 170, 200})
  rl.shader_mode(shader){
    shaders.apply(shader, view)
    shader:set("camForward", view.forward, rl.SHADER_UNIFORM_VEC3)
    shader:set("camRight", view.right, rl.SHADER_UNIFORM_VEC3)
    shader:set("camUp", view.up, rl.SHADER_UNIFORM_VEC3)
    local t = math.tan(view.fovy / 2)
    shader:set("tanHalf", {t * view.aspect, t}, rl.SHADER_UNIFORM_VEC2)
    shader:set("resolution", {view.width, view.height}, rl.SHADER_UNIFORM_VEC2)
    rl.draw.rectangle(0, 0, view.width, view.height, rl.WHITE)
  }
}

func m.unload(){
  if(state.shader != null){
    state.shader:unload()
    state.shader = null
  }
}

return m
