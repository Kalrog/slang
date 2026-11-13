// render/post: from the picture of the scene to the screen. The scene
// is drawn into a texture; its bright parts are blurred into a glow, and
// the screen gets the scene with its jagged edges smoothed, the glow
// added, the colors graded a little warmer and richer, the corners
// darkened and a fine grain over it against banding in the sky.
//
//   post.init(width, height)        // the picture's size in pixels
//   post.scene{ ... }               // the block draws the scene
//   post.present(view)              // onto the screen
local rl = require("raylib")

local m = {}

local vertex = """#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;
uniform mat4 mvp;
out vec2 fragTexCoord;
void main(){
  fragTexCoord = vertexTexCoord;
  gl_Position = mvp * vec4(vertexPosition, 1.0);
}
"""

// the bright parts, small
local bright = """#version 330
in vec2 fragTexCoord;
uniform sampler2D texture0;
uniform vec2 texel;
out vec4 finalColor;
void main(){
  // (four taps: the average of a block of the scene's pixels)
  vec3 c = texture(texture0, fragTexCoord + texel * vec2(-1.0, -1.0)).rgb +
    texture(texture0, fragTexCoord + texel * vec2(1.0, -1.0)).rgb +
    texture(texture0, fragTexCoord + texel * vec2(-1.0, 1.0)).rgb +
    texture(texture0, fragTexCoord + texel * vec2(1.0, 1.0)).rgb;
  c *= 0.25;
  float l = dot(c, vec3(0.3, 0.59, 0.11));
  finalColor = vec4(c * smoothstep(0.78, 1.0, l), 1.0);
}
"""

local blur = """#version 330
in vec2 fragTexCoord;
uniform sampler2D texture0;
uniform vec2 dir;
out vec4 finalColor;
void main(){
  vec2 uv = fragTexCoord;
  vec3 s = texture(texture0, uv).rgb * 0.227;
  s += (texture(texture0, uv + dir * 1.384).rgb + texture(texture0, uv - dir * 1.384).rgb) * 0.316;
  s += (texture(texture0, uv + dir * 3.23).rgb + texture(texture0, uv - dir * 3.23).rgb) * 0.070;
  finalColor = vec4(s, 1.0);
}
"""

local composite = """#version 330
in vec2 fragTexCoord;
uniform sampler2D texture0;
uniform sampler2D glow;
uniform vec2 texel;
uniform float time;
uniform float fade;       // 1: the scene, 0: black
out vec4 finalColor;

float luma(vec3 c){
  return dot(c, vec3(0.299, 0.587, 0.114));
}

void main(){
  vec2 uv = fragTexCoord;
  // edges smoothed (after FXAA): where the brightness jumps, blend along
  // the edge
  vec3 mid = texture(texture0, uv).rgb;
  float lm = luma(mid);
  float lnw = luma(texture(texture0, uv + texel * vec2(-1.0, -1.0)).rgb);
  float lne = luma(texture(texture0, uv + texel * vec2(1.0, -1.0)).rgb);
  float lsw = luma(texture(texture0, uv + texel * vec2(-1.0, 1.0)).rgb);
  float lse = luma(texture(texture0, uv + texel * vec2(1.0, 1.0)).rgb);
  float lo = min(lm, min(min(lnw, lne), min(lsw, lse)));
  float hi = max(lm, max(max(lnw, lne), max(lsw, lse)));
  vec3 col = mid;
  if(hi - lo > max(0.035, hi * 0.11)){
    vec2 d = vec2(-((lnw + lne) - (lsw + lse)), (lnw + lsw) - (lne + lse));
    float reduce = max((lnw + lne + lsw + lse) * 0.03, 0.008);
    d = clamp(d / (min(abs(d.x), abs(d.y)) + reduce), -8.0, 8.0) * texel;
    vec3 a = 0.5 * (texture(texture0, uv + d * (1.0 / 3.0 - 0.5)).rgb + texture(texture0, uv + d * (2.0 / 3.0 - 0.5)).rgb);
    vec3 b = a * 0.5 + 0.25 * (texture(texture0, uv - d * 0.5).rgb + texture(texture0, uv + d * 0.5).rgb);
    float lb = luma(b);
    col = (lb < lo || lb > hi) ? a : b;
  }
  // the glow laid over it as light over light: what is bright already
  // (snow, a cloud) gains little and does not run into white in steps
  vec3 g3 = clamp(texture(glow, uv).rgb * 0.5, 0.0, 1.0);
  col = 1.0 - (1.0 - col) * (1.0 - g3);
  // the grade: a little more contrast and color, warm lights, cool shadows
  float l = luma(col);
  col = mix(vec3(l), col, 1.12);
  col = (col - 0.5) * 1.06 + 0.5;
  col *= mix(vec3(0.96, 0.99, 1.05), vec3(1.04, 1.0, 0.95), smoothstep(0.1, 0.8, l));
  // the corners
  vec2 c = uv - 0.5;
  col *= 1.0 - 0.32 * smoothstep(0.35, 0.95, length(c) * 1.25);
  // what the grade pushed past white comes back with its color kept (one
  // channel cut off before the others would tint the brightest parts)
  float top = max(col.r, max(col.g, col.b));
  if(top > 1.0){
    col /= top;
  }
  // grain, finer than a byte
  float g = fract(sin(dot(gl_FragCoord.xy + fract(time) * 61.0, vec2(12.9898, 78.233))) * 43758.5453);
  col += (g - 0.5) / 255.0 * 1.5;
  finalColor = vec4(clamp(col, 0.0, 1.0) * fade, 1.0);
}
"""

local state = {}

// init(width, height): the targets and shaders for a picture that size
func m.init(width, height){
  state.width = width
  state.height = height
  state.scene = rl.render_texture(width, height)
  state.scene.texture.filter = rl.TEXTURE_FILTER_BILINEAR
  state.scene.texture.wrap = rl.TEXTURE_WRAP_CLAMP
  local w = to_int(width / 4)
  local h = to_int(height / 4)
  state.small = {rl.render_texture(w, h), rl.render_texture(w, h)}
  for(let local t in values(state.small)){
    t.texture.filter = rl.TEXTURE_FILTER_BILINEAR
    t.texture.wrap = rl.TEXTURE_WRAP_CLAMP
  }
  state.bright = rl.shader({vertex: vertex, fragment: bright})
  state.blur = rl.shader({vertex: vertex, fragment: blur})
  state.composite = rl.shader({vertex: vertex, fragment: composite})
  state.glow_loc = state.composite:location("glow")
}

// scene(block): the block draws into the picture of the scene
func m.scene(block){
  rl.texture_mode(state.scene, block)
}

// present(view, options?: {fade?: float}): the picture onto the screen
// (fade 1: as it is, toward 0: into black)
func m.present(view, options){
  local scene = state.scene
  local a = state.small[0]
  local b = state.small[1]
  local w = a.texture.width
  local h = a.texture.height
  local full = {0, 0, state.width, -state.height}
  local small = {0, 0, w, -h}
  rl.texture_mode(a){
    rl.shader_mode(state.bright){
      state.bright:set("texel", {1 / state.width, 1 / state.height}, rl.SHADER_UNIFORM_VEC2)
      scene.texture:draw_pro(full, {0, 0, w, h}, {0, 0}, 0, rl.WHITE)
    }
  }
  rl.texture_mode(b){
    rl.shader_mode(state.blur){
      state.blur:set("dir", {1 / w, 0}, rl.SHADER_UNIFORM_VEC2)
      a.texture:draw_rec(small, {0, 0}, rl.WHITE)
    }
  }
  rl.texture_mode(a){
    rl.shader_mode(state.blur){
      state.blur:set("dir", {0, 1 / h}, rl.SHADER_UNIFORM_VEC2)
      b.texture:draw_rec(small, {0, 0}, rl.WHITE)
    }
  }
  local screen = rl.window.size
  rl.shader_mode(state.composite){
    state.composite:set_value_texture(state.glow_loc, a.texture)
    state.composite:set("texel", {1 / state.width, 1 / state.height}, rl.SHADER_UNIFORM_VEC2)
    state.composite:set("time", view.time * 1.0)
    state.composite:set("fade", if(options != null and options.fade != null){ options.fade * 1.0 } else { 1.0 })
    scene.texture:draw_pro(full, {0, 0, screen.x, screen.y}, {0, 0}, 0, rl.WHITE)
  }
}

func m.unload(){
  if(state.scene != null){
    state.scene:unload()
    state.small[0]:unload()
    state.small[1]:unload()
    state.bright:unload()
    state.blur:unload()
    state.composite:unload()
    state.scene = null
  }
}

return m
