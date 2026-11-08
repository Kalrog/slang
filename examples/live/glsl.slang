// The fragment shader of a piece, assembled from what shader(...) gave:
// the uniforms every piece has, the piece's own (uniform(name, v)), the
// helpers, and the code in one of three shapes:
//
// - the body of main: `uv` (0..1, up), `p` (centered, the picture's
//   aspect) and `last` (this pixel of the last frame) are given, `color`
//   is the result;
// - a whole program with `void main`, writing finalColor;
// - a Shadertoy program with `mainImage(out vec4, in vec2)`: iResolution,
//   iTime, iMouse, iTimeDelta and iFrame are defined from the uniforms, so
//   a shader from there runs as it is (and may read beat, env and the rest).
//
// The picture is a rectangle of raylib's shapes texture, so fragTexCoord
// is useless: gl_FragCoord over resolution is the position. A helper the
// code defines itself (its own `mat2 rot(`) is left out of the prelude.
local str = require("slang/string")

local glsl = {}

glsl.uniforms = """
#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
out vec4 finalColor;
uniform sampler2D texture0;
uniform sampler2D prev;
uniform vec2 resolution;
uniform vec2 mouse;
uniform vec4 imouse;
uniform float time;
uniform float beat;
uniform float level;
uniform float env[8];
"""

// each helper with the start of its definition, by which the code's own
// is recognized
glsl.helpers = {
  {"float hash(", "float hash(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }"},
  {"float noise(", "float noise(vec2 p){ vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);\n  return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y); }"},
  {"vec3 pal(", "vec3 pal(float t, vec3 a, vec3 b, vec3 c, vec3 d){ return a + b * cos(6.28318 * (c * t + d)); }"},
  {"vec3 hsv(", "vec3 hsv(float h, float s, float v){ vec3 k = vec3(1.0, 2.0 / 3.0, 1.0 / 3.0);\n  vec3 p = abs(fract(vec3(h) + k) * 6.0 - 3.0); return v * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), s); }"},
  {"mat2 rot(", "mat2 rot(float a){ float c = cos(a); float s = sin(a); return mat2(c, -s, s, c); }"},
}

glsl.shadertoy = """
#define iResolution vec3(resolution, 1.0)
#define iTime time
#define iMouse imouse
#define iTimeDelta (1.0 / 60.0)
#define iFrame int(time * 60.0)
"""

// kind(source) -> "image" (a mainImage), "main" (a void main) or "body"
func glsl.kind(source){
  if(str.contains(source, "mainImage")){
    return "image"
  }
  if(str.contains(source, "void main")){
    return "main"
  }
  return "body"
}

// program(source, names) -> the fragment shader's text; names lists the
// piece's own float uniforms
func glsl.program(source, names){
  local parts = {glsl.uniforms}
  for(let local name in values(names or {})){
    append(parts, concat("uniform float ", name, ";"))
  }
  // noise needs hash: a code that writes its own hash gets no noise either
  local own_hash = str.contains(source, "float hash(")
  for(let local h in values(glsl.helpers)){
    if(not str.contains(source, h[0]) and not (h[0] == "float noise(" and own_hash)){
      append(parts, h[1])
    }
  }
  local kind = glsl.kind(source)
  if(kind == "image"){
    append(parts, glsl.shadertoy)
    append(parts, source)
    append(parts, "\nvoid main(){ mainImage(finalColor, gl_FragCoord.xy); }\n")
  } else if(kind == "main"){
    append(parts, source)
  } else {
    append(parts, """
void main(){
  vec2 uv = gl_FragCoord.xy / resolution;
  vec2 p = (uv - 0.5) * vec2(resolution.x / resolution.y, 1.0);
  vec3 last = texture(prev, uv).rgb;
  vec3 color = vec3(0.0);
""")
    append(parts, source)
    append(parts, "\n  finalColor = vec4(color, 1.0);\n}\n")
  }
  return str.join(parts, "\n")
}

return glsl
