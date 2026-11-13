// game/render: everything drawn in 3D, and the look of the night. One
// shader paints every surface from what its vertices say it is: facades
// grow their lit windows in the fragment shader (a grid of cells, each
// lit or dark by a hash, warm or cold, a few flickering), neon strips
// glow, billboards animate, bridges run their lights, pads pulse, the
// street grid shines up through the haze; the fog glows warm near the
// ground. The frame is drawn to a texture, its bright parts blurred into
// a bloom, and composited with a radial blur that grows with speed, a
// touch of chromatic aberration when boosting, and a vignette. The
// city's boxes become one mesh per block (vertex colors carry the tint
// and a seed, the texture coordinates the kind and a parameter, the
// second set the position on the face).
local rl = require("raylib")
local math = require("slang/math")
local vec = require("game/vec")
local city = require("game/city")
local designs = require("game/designs")
local buffer = require("slang/buffer")

local m = {}

m.VIEW = 950        // how far chunks are drawn
m.TRAFFIC_NEAR = 90 // traffic nearer the player than this is drawn in full (game/traffic NEAR is more)

// ------------------------------------------------------------ shaders

local scene_vs = """#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec2 vertexTexCoord;
in vec2 vertexTexCoord2;
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
out vec3 fragPosition;
out vec3 fragNormal;
out vec4 fragColor;
out vec2 fragTexCoord;
out vec2 fragTexCoord2;
void main(){
  fragTexCoord = vertexTexCoord;
  fragTexCoord2 = vertexTexCoord2;
  fragPosition = vec3(matModel * vec4(vertexPosition, 1.0));
  fragNormal = normalize(vec3(matNormal * vec4(vertexNormal, 0.0)));
  fragColor = vertexColor;
  gl_Position = mvp * vec4(vertexPosition, 1.0);
}
"""

local scene_fs = """#version 330
in vec3 fragPosition;
in vec3 fragNormal;
in vec4 fragColor;
in vec2 fragTexCoord;
in vec2 fragTexCoord2;
uniform vec4 colDiffuse;
uniform vec3 viewPos;
uniform float time;
uniform float kindOverride;
uniform float paramOverride;
uniform float streetPitch;
uniform float streetHalf;
uniform vec3 laneOffsets;
out vec4 finalColor;

float hash21(vec2 p){
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

void main(){
  vec3 n = normalize(fragNormal);
  float kind = fragTexCoord.x;
  float param = fragTexCoord.y;
  if(kindOverride >= 0.0){
    kind = kindOverride;
    param = paramOverride;
  }
  vec2 uv2 = fragTexCoord2;
  vec3 base = fragColor.rgb * colDiffuse.rgb;
  float seed = fragColor.a * 255.0;
  vec3 v = normalize(viewPos - fragPosition);
  float dist = distance(viewPos, fragPosition);
  float low = exp(-max(fragPosition.y, 0.0) * 0.012);
  vec3 haze = vec3(0.24, 0.09, 0.22);
  vec3 col = vec3(0.0);
  float alpha = colDiffuse.a;
  if(kind < 0.5){
    // a facade: the windows are cells of the wall, 2 m by 3 m
    float vertical = 1.0 - abs(n.y);
    // (along the wall, whichever way it faces: a cut corner too)
    vec2 uv;
    if(abs(n.y) < 0.5){
      vec2 t = normalize(vec2(-n.z, n.x));
      uv = vec2(dot(fragPosition.xz, t), fragPosition.y);
    } else {
      uv = fragPosition.xz;
    }
    vec2 cs = vec2(2.0, 3.0);
    vec2 cell = floor(uv / cs);
    vec2 f = fract(uv / cs);
    float h = hash21(cell + seed * 7.13);
    // fewer lit, and most of those dim: a city at night, not a lamp
    float lit = step(h, param * 0.6) * vertical;
    float frame = step(0.16, f.x) * step(f.x, 0.84) * step(0.2, f.y) * step(f.y, 0.8);
    float h2 = hash21(vec2(cell.y * 0.37 + cell.x * 0.11, seed));
    vec3 wcol = mix(vec3(1.0, 0.74, 0.42), vec3(1.0, 0.86, 0.62), hash21(cell * 0.7 + seed));
    wcol = mix(wcol, vec3(0.62, 0.84, 1.0), step(0.86, h2));
    float flicker = 1.0 + 0.15 * step(0.97, hash21(cell * 1.7 + seed)) * sin(time * 5.0 + h * 50.0);
    float level = pow(hash21(cell + 3.0), 2.0);
    float bright = lit * frame * (0.15 + 0.75 * level) * flicker;
    vec3 wall = base * 0.16 * (0.7 + 0.3 * vertical);
    float band = smoothstep(0.0, 0.08, f.y) * smoothstep(1.0, 0.92, f.y);
    wall *= 0.8 + 0.4 * (1.0 - band);
    wall += haze * low * 0.45 * (0.5 - 0.5 * n.y);
    // the glass between the floors mirrors the night, as the cars do
    vec3 r = reflect(-v, n);
    vec3 env = mix(vec3(0.20, 0.075, 0.19), vec3(0.04, 0.05, 0.12), smoothstep(0.0, 0.5, r.y));
    float fres = pow(1.0 - max(dot(n, v), 0.0), 4.0);
    wall += env * frame * vertical * (0.18 + 0.6 * fres) * (1.0 - lit);
    col = wall + wcol * bright * 0.95;
  } else if(kind < 1.5){
    // neon
    float blink = 1.0;
    if(param > 0.0){
      blink = step(0.5, fract(time * param));
    }
    col = base * (1.3 * blink + 0.06);
  } else if(kind < 2.5){
    // structure, with running lights along its length
    col = base * 0.3 * (0.6 + 0.4 * max(n.y, 0.0));
    col += haze * low * 0.5 * (0.5 - 0.5 * n.y);
    if(param > 6.0){
      // small lamps along it, a slow pulse running through them
      float along = uv2.x * param;
      float lamp = smoothstep(0.12, 0.0, abs(fract(along / 8.0) - 0.5)) * step(0.5, abs(n.y));
      float pulse = 0.5 + 0.5 * sin(along * 0.05 - time * 0.8);
      col += vec3(0.55, 0.8, 1.0) * lamp * (0.15 + 0.2 * pulse);
    }
    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0);
    col += rim * vec3(0.14, 0.11, 0.28) * 0.3;
  } else if(kind < 3.5){
    // a billboard: bands, a drifting blob, scanlines, color cycling
    vec2 u = uv2;
    float t = time * (0.5 + 0.25 * param) + seed;
    vec3 c2 = mix(vec3(0.0, 0.86, 1.0), vec3(1.0, 0.2, 0.67), step(base.r, 0.5));
    float band = 0.5 + 0.5 * sin(u.y * 8.0 - t * 3.0 + sin(u.x * 5.0 + t));
    float scan = 0.85 + 0.15 * step(0.5, fract(u.y * 40.0 + time * 10.0));
    float blob = smoothstep(0.35, 0.1, distance(u, vec2(0.5 + 0.25 * sin(t), 0.5 + 0.2 * cos(t * 1.3))));
    col = mix(base, c2, band) * (0.7 + blob * 1.6) * scan * 1.5;
    float edge = step(0.03, u.x) * step(u.x, 0.97) * step(0.04, u.y) * step(u.y, 0.96);
    col = mix(vec3(0.05), col, edge);
    if(abs(n.y) > 0.5){
      col = vec3(0.05);
    }
  } else if(kind < 4.5){
    // a pad: rings and a cross that pulse outward
    vec2 u = uv2 - 0.5;
    float r = length(u) * 2.0;
    float ring = smoothstep(0.07, 0.0, abs(r - 0.82)) + smoothstep(0.05, 0.0, abs(r - 0.4));
    float cross_ = (step(abs(u.x), 0.025) + step(abs(u.y), 0.025)) * step(r, 0.82);
    float pulse = 0.55 + 0.45 * sin(time * 3.0 - r * 5.0);
    col = vec3(0.05, 0.05, 0.07) + base * (ring + cross_) * 2.2 * pulse;
    if(n.y < 0.5){
      col = vec3(0.06);
    }
  } else if(kind < 5.5){
    // the ground: streets drawn as lanes of light in the haze
    vec2 p = fragPosition.xz;
    vec2 g = abs(fract(p / streetPitch + 0.5) - 0.5) * streetPitch;
    float d = min(g.x, g.y);
    float street = smoothstep(streetHalf, streetHalf - 4.0, d);
    float lane = smoothstep(0.8, 0.0, abs(d - laneOffsets.x)) * street;
    if(laneOffsets.y > 0.0){
      lane += smoothstep(0.8, 0.0, abs(d - laneOffsets.y)) * street;
    }
    if(laneOffsets.z > 0.0){
      lane += smoothstep(0.8, 0.0, abs(d - laneOffsets.z)) * street;
    }
    float center = smoothstep(0.5, 0.0, d);
    col = vec3(0.03, 0.025, 0.05) + street * vec3(0.09, 0.05, 0.1);
    col += lane * vec3(1.0, 0.55, 0.25) * 0.5 + center * vec3(0.3, 0.9, 1.0) * 0.6;
    float sparkle = step(0.985, hash21(floor(p / 3.0))) * (1.0 - street);
    col += sparkle * vec3(1.0, 0.8, 0.6) * 0.7;
  } else if(kind > 7.5 && kind < 8.5){
    // a slope (a roof, a skirt between tiers): panels with seams, in
    // metal or (param 1) glass with lit rooms under it, mirroring the night
    vec3 tt = abs(n.y) > 0.95 ? vec3(1.0, 0.0, 0.0) : normalize(cross(vec3(0.0, 1.0, 0.0), n));
    vec3 bt = cross(n, tt);
    vec2 uv = vec2(dot(fragPosition, tt), dot(fragPosition, bt));
    vec2 cs = vec2(3.0, 2.0);
    vec2 cell = floor(uv / cs);
    vec2 f = fract(uv / cs);
    float seam = 1.0 - step(0.04, f.x) * step(f.x, 0.96) * step(0.07, f.y) * step(f.y, 0.93);
    vec3 r = reflect(-v, n);
    vec3 env = mix(vec3(0.20, 0.075, 0.19), vec3(0.04, 0.05, 0.12), smoothstep(0.0, 0.5, r.y));
    float fres = pow(1.0 - max(dot(n, v), 0.0), 4.0);
    float h = hash21(cell + seed * 3.1);
    if(param > 0.5){
      col = vec3(0.012, 0.016, 0.03) + env * (0.3 + 0.6 * fres);
      col += vec3(1.0, 0.75, 0.45) * step(0.8, h) * (0.25 + 0.2 * hash21(cell * 1.3)) * (1.0 - seam);
      col += vec3(0.4, 0.8, 1.0) * seam * 0.07;
    } else {
      col = base * (0.18 + 0.1 * h) + env * (0.08 + 0.45 * fres);
      col *= 1.0 - seam * 0.5;
    }
    col += haze * low * 0.4 * (0.5 - 0.5 * n.y);
  } else {
    // the cars: lacquer that mirrors the night (the sky above, the city's
    // glow at the horizon, the dark below) and glass that mirrors it more
    vec3 r = reflect(-v, n);
    vec3 env = mix(vec3(0.20, 0.075, 0.19), vec3(0.04, 0.05, 0.12), smoothstep(0.0, 0.5, r.y));
    env = mix(env, vec3(0.02, 0.015, 0.03), smoothstep(0.0, -0.3, r.y));
    // a band of light from the street lamps and windows, sliding over
    env += vec3(1.0, 0.7, 0.45) * smoothstep(0.08, 0.0, abs(r.y - 0.12)) * 0.5;
    vec3 l = normalize(vec3(-0.4, 0.35, 0.75));
    vec3 h = normalize(l + v);
    float fres = pow(1.0 - max(dot(n, v), 0.0), 4.0);
    float spec = pow(max(dot(n, h), 0.0), 60.0);
    bool glass = abs(seed - 7.0) < 0.5;
    if(glass){
      col = vec3(0.01, 0.015, 0.03) + env * (0.35 + 0.65 * fres) + vec3(0.85, 0.9, 1.0) * spec * 1.2;
      col += vec3(0.0, 0.25, 0.3) * 0.08;
    } else {
      float d = max(dot(n, l), 0.0) * 0.5 + 0.5;
      col = base * (0.10 + 0.22 * d) + env * (0.12 + 0.7 * fres) * mix(vec3(1.0), base * 1.5 + 0.2, 0.4);
      col += vec3(0.85, 0.9, 1.0) * spec * 0.8;
    }
  }
  // the fog: by distance, glowing warm where the city's light is
  float fog = 1.0 - exp(-dist * 0.0017);
  float lowf = exp(-max(fragPosition.y, 0.0) * 0.009);
  vec3 fogc = mix(vec3(0.03, 0.035, 0.08), vec3(0.17, 0.065, 0.16), lowf * 0.9);
  col = mix(col, fogc, fog);
  finalColor = vec4(col, alpha);
}
"""

// the traffic's vertex shader: each design is one mesh drawn once per
// car (instanced); the car's data comes as its instance matrix (see
// build_traffic): where its lane runs, its start along it, its speed and
// colors. The shader turns the car to its lane's heading, slides it along
// the lane by its speed times the time, wrapped at the city's edge, and
// paints the design's slots (texcoord2 x: 1 body, 2 accent, 3 headlights)
// in the car's colors; the cars in `hidden` (wrecks drawn on their own)
// collapse to nothing.
local traffic_vs = """#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec2 vertexTexCoord;
in vec2 vertexTexCoord2;
in mat4 instanceTransform;
uniform mat4 mvp;
uniform float trafficTime;
uniform float limit;
uniform int hidden[32];
uniform vec3 focus;        // where the player is
uniform float split;       // cars nearer the player than this are not drawn (-1: all)
out vec3 fragPosition;
out vec3 fragNormal;
out vec4 fragColor;
out vec2 fragTexCoord;
out vec2 fragTexCoord2;
void main(){
  vec4 lane = instanceTransform[0];   // s0, speed, at, y
  vec4 info = instanceTransform[1];   // axis, id
  vec4 body = instanceTransform[2];   // rgb, headlights cold
  vec4 accent = instanceTransform[3]; // rgb
  int id = int(info.y + 0.5);
  float speed = lane.y;
  float dir = speed < 0.0 ? -1.0 : 1.0;
  float s = lane.x + speed * trafficTime + limit;
  s = s - floor(s / (2.0 * limit)) * 2.0 * limit - limit;
  vec3 center = info.x < 0.5 ? vec3(s, lane.w, lane.z) : vec3(lane.z, lane.w, s);
  // the near ones are drawn in full by a draw of their own; a wreck's
  // place on its lane (near enough to have been hit) is empty
  float d = distance(center, focus);
  bool gone = d < split;
  if(!gone && d < 400.0){
    for(int i = 0; i < 32; i++){
      if(hidden[i] == id){
        gone = true;
      }
    }
  }
  if(gone){
    gl_Position = vec4(0.0, 0.0, -2.0, 1.0);
    fragPosition = vec3(0.0);
    fragNormal = vec3(0.0, 1.0, 0.0);
    fragColor = vec4(0.0);
    fragTexCoord = vec2(0.0);
    fragTexCoord2 = vec2(0.0);
    return;
  }
  vec3 p = vertexPosition;
  vec3 n = vertexNormal;
  vec3 world;
  if(info.x < 0.5){
    // along x: the car's forward (+z) turned to +x or -x
    p = vec3(p.z * dir, p.y, -p.x * dir);
    n = vec3(n.z * dir, n.y, -n.x * dir);
    world = vec3(s, lane.w, lane.z);
  } else {
    p = vec3(p.x * dir, p.y, p.z * dir);
    n = vec3(n.x * dir, n.y, n.z * dir);
    world = vec3(lane.z, lane.w, s);
  }
  p += world;
  vec3 c = vertexColor.rgb;
  float slot = vertexTexCoord2.x;
  if(slot > 0.5 && slot < 1.5){
    c = body.rgb;
  } else if(slot > 1.5 && slot < 2.5){
    c = accent.rgb;
  } else if(slot > 2.5){
    c = mix(vec3(1.0, 0.925, 0.784), vec3(0.863, 0.925, 1.0), body.w);
  }
  fragTexCoord = vec2(vertexTexCoord.x, 0.0);
  fragTexCoord2 = vec2(0.0);
  fragPosition = p;
  fragNormal = normalize(n);
  fragColor = vec4(c, vertexColor.a);
  gl_Position = mvp * vec4(p, 1.0);
}
"""

local post_vs = """#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec4 vertexColor;
uniform mat4 mvp;
out vec2 fragTexCoord;
out vec4 fragColor;
void main(){
  fragTexCoord = vertexTexCoord;
  fragColor = vertexColor;
  gl_Position = mvp * vec4(vertexPosition, 1.0);
}
"""

// the sky: drawn flat behind everything, each pixel's direction from
// the camera's basis; a haze at the horizon, the city's glow below it,
// stars above
local sky_fs = """#version 330
in vec2 fragTexCoord;
uniform vec3 camForward;
uniform vec3 camRight;
uniform vec3 camUp;
uniform vec2 tanHalf;
uniform float camY;
uniform float time;
uniform vec2 resolution;
out vec4 finalColor;

float hash21(vec2 p){
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p){
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), u.x),
             mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p){
  float v = 0.0;
  float a = 0.5;
  for(int i = 0; i < 5; i++){
    v += a * noise(p);
    p = p * 2.03 + vec2(17.1, 9.2);
    a *= 0.5;
  }
  return v;
}

void main(){
  // the pixel's place on the screen (-1..1, y up): from the fragment's
  // own coordinates, not the rectangle's texture coordinates (a raylib
  // rectangle has the same one all over)
  vec2 uv = gl_FragCoord.xy / resolution * 2.0 - 1.0;
  vec3 dir = normalize(camForward + camRight * uv.x * tanHalf.x + camUp * uv.y * tanHalf.y);
  float h = dir.y;
  // the night: deep blue at the top, the city's glow at the horizon
  vec3 zenith = vec3(0.004, 0.008, 0.026);
  vec3 mid = vec3(0.025, 0.03, 0.075);
  vec3 glow = vec3(0.17, 0.065, 0.16);
  vec3 col = mix(mid, zenith, smoothstep(0.03, 0.6, h));
  col = mix(col, glow, exp(-max(h, 0.0) * 16.0));
  // below the horizon: the haze over the city, as the fog has it
  col = mix(col, glow, smoothstep(0.0, -0.05, h));
  // the moon, its halo
  vec3 moon_dir = normalize(vec3(-0.45, 0.32, 0.83));
  float md = dot(dir, moon_dir);
  float disc = smoothstep(0.99935, 0.9996, md);
  float halo = pow(max(md, 0.0), 300.0) * 0.5 + pow(max(md, 0.0), 24.0) * 0.08;
  // stars
  vec2 sp = vec2(atan(dir.x, dir.z) * 160.0, h * 320.0);
  float s = hash21(floor(sp));
  vec2 sf = fract(sp) - 0.5;
  float star = step(0.992, s) * smoothstep(0.3, 0.0, length(sf)) * smoothstep(0.06, 0.35, h) * (0.6 + 0.4 * sin(time * 1.5 + s * 80.0));
  vec3 lights = vec3(0.75, 0.82, 1.0) * star * 0.9 + vec3(0.85, 0.9, 1.0) * (disc * 1.6 + halo);
  // clouds: a layer high over the city, drifting, lit from below by its
  // glow and on their edges by the moon
  float cover = 0.0;
  if(h > 0.01){
    vec2 p = dir.xz / (h + 0.08) * 3.2 + vec2(time * 0.03, time * 0.012);
    float d = fbm(p) * 0.75 + fbm(p * 3.1 + vec2(time * 0.05, 0.0)) * 0.25;
    float dd = fbm(p + vec2(0.12, 0.08)) * 0.75 + fbm(p * 3.1 + vec2(time * 0.05 + 0.3, 0.2)) * 0.25;
    cover = smoothstep(0.5, 0.75, d) * smoothstep(0.02, 0.12, h);
    float lit = clamp((d - dd) * 6.0 + 0.5, 0.0, 1.0);
    // the undersides catch the city's light (warmer, brighter low over
    // the horizon), the thick parts stay dark, the moon silvers the edges
    float thick = smoothstep(0.55, 0.9, d);
    vec3 under = mix(vec3(0.42, 0.16, 0.30), vec3(0.10, 0.07, 0.16), smoothstep(0.02, 0.45, h));
    vec3 cloud = mix(under, vec3(0.015, 0.015, 0.035), thick * 0.75);
    cloud += vec3(0.55, 0.6, 0.75) * lit * (halo * 5.0 + pow(max(md, 0.0), 8.0) * 0.12) * (1.0 - thick);
    col = mix(col, cloud, cover * 0.9);
  }
  col += lights * (1.0 - cover);
  // (the same at every height and angle: it belongs to the world)
  finalColor = vec4(col, 1.0);
}
"""

local bright_fs = """#version 330
in vec2 fragTexCoord;
uniform sampler2D texture0;
out vec4 finalColor;
void main(){
  vec3 c = texture(texture0, fragTexCoord).rgb;
  float l = dot(c, vec3(0.3, 0.59, 0.11));
  float k = smoothstep(0.5, 0.95, l);
  finalColor = vec4(c * k, 1.0);
}
"""

local blur_fs = """#version 330
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

local composite_fs = """#version 330
in vec2 fragTexCoord;
uniform sampler2D texture0;
uniform sampler2D bloom;
uniform float speedBlur;
uniform float aberration;
uniform vec3 flash;
uniform float dim;
out vec4 finalColor;
void main(){
  vec2 uv = fragTexCoord;
  vec2 c = uv - 0.5;
  float r = length(c);
  vec3 scene = vec3(0.0);
  for(int i = 0; i < 6; i++){
    float t = float(i) / 5.0;
    vec2 o = c * (1.0 - t * speedBlur * 0.11 * r);
    scene += texture(texture0, o + 0.5).rgb;
  }
  scene /= 6.0;
  float ab = aberration * r * 0.012;
  float red = texture(texture0, 0.5 + c * (1.0 + ab)).r;
  float blue = texture(texture0, 0.5 + c * (1.0 - ab)).b;
  scene = mix(scene, vec3(red, scene.g, blue), clamp(aberration, 0.0, 1.0) * 0.5);
  vec3 bl = texture(bloom, uv).rgb;
  vec3 col = scene + bl * 1.15;
  col = col / (col + 0.5) * 1.4;
  float vig = 1.0 - 0.55 * smoothstep(0.35, 1.0, r * 1.5);
  col *= vig;
  col += flash;
  col *= 0.97 + 0.03 * sin(uv.y * 900.0);
  finalColor = vec4(col * dim, 1.0);
}
"""

// ------------------------------------------------------------ state

local shader = null
local locs = {}
local traffic_shader = null
local traffic_locs = {}
local traffic_models = {}
local wreck_models = {}    // design:palette -> the model of a wreck
local post = {}
local targets = null
local width = 0
local height = 0
local chunk_models = {}
local meshes = {}      // the generated ones: cube
local models = {}      // cube under the shader, car, traffic
local current_kind = -2
local current_param = -1

local func set_kind(kind, param){
  if(kind != current_kind){
    shader:set_value(locs.kind, kind, rl.SHADER_UNIFORM_FLOAT)
    current_kind = kind
  }
  param = param or 0
  if(param != current_param){
    shader:set_value(locs.param, param, rl.SHADER_UNIFORM_FLOAT)
    current_param = param
  }
}

// ------------------------------------------------------------ meshing

// the faces of a box: normal, the corner order (counter clockwise seen
// from outside), and which axes are u and v on the face
local func face_uv(b, n, p){
  if(n.x != 0){
    return {(p.z - b.z0) / math.max(0.001, b.z1 - b.z0), (p.y - b.y0) / math.max(0.001, b.y1 - b.y0)}
  }
  if(n.z != 0){
    return {(p.x - b.x0) / math.max(0.001, b.x1 - b.x0), (p.y - b.y0) / math.max(0.001, b.y1 - b.y0)}
  }
  // horizontal: u along the longer side
  if(b.x1 - b.x0 >= b.z1 - b.z0){
    return {(p.x - b.x0) / math.max(0.001, b.x1 - b.x0), (p.z - b.z0) / math.max(0.001, b.z1 - b.z0)}
  }
  return {(p.z - b.z0) / math.max(0.001, b.z1 - b.z0), (p.x - b.x0) / math.max(0.001, b.x1 - b.x0)}
}

// add_box(out, b): the box's 24 vertices and 12 triangles into the lists
local func add_box(out, b){
  local x0 = b.x0
  local y0 = b.y0
  local z0 = b.z0
  local x1 = b.x1
  local y1 = b.y1
  local z1 = b.z1
  local faces = {
    {n: {x: 1, y: 0, z: 0}, p: {{x1, y0, z0}, {x1, y1, z0}, {x1, y1, z1}, {x1, y0, z1}}},
    {n: {x: -1, y: 0, z: 0}, p: {{x0, y0, z1}, {x0, y1, z1}, {x0, y1, z0}, {x0, y0, z0}}},
    {n: {x: 0, y: 1, z: 0}, p: {{x0, y1, z0}, {x0, y1, z1}, {x1, y1, z1}, {x1, y1, z0}}},
    {n: {x: 0, y: -1, z: 0}, p: {{x0, y0, z1}, {x0, y0, z0}, {x1, y0, z0}, {x1, y0, z1}}},
    {n: {x: 0, y: 0, z: 1}, p: {{x1, y0, z1}, {x1, y1, z1}, {x0, y1, z1}, {x0, y0, z1}}},
    {n: {x: 0, y: 0, z: -1}, p: {{x0, y0, z0}, {x0, y1, z0}, {x1, y1, z0}, {x1, y0, z0}}},
  }
  local c = b.color
  local seed = b.seed or 0
  for(let local f in values(faces)){
    local start = out.count
    for(let local p in values(f.p)){
      append(out.vertices, p[0])
      append(out.vertices, p[1])
      append(out.vertices, p[2])
      append(out.normals, f.n.x)
      append(out.normals, f.n.y)
      append(out.normals, f.n.z)
      append(out.colors, c[0])
      append(out.colors, c[1])
      append(out.colors, c[2])
      append(out.colors, seed)
      append(out.texcoords, b.kind)
      append(out.texcoords, b.param or 0)
      if(b.speed != null){
        append(out.texcoords2, b.speed)
        append(out.texcoords2, b.axis)
      } else {
        local uv = face_uv(b, f.n, {x: p[0], y: p[1], z: p[2]})
        append(out.texcoords2, uv[0])
        append(out.texcoords2, uv[1])
      }
      out.count = out.count + 1
    }
    for(let local i in values({0, 1, 2, 0, 2, 3})){
      append(out.indices, start + i)
    }
  }
}

// add_solid(out, b): a solid's faces (game/city), each flat, as fans
local func add_solid(out, b){
  local c = b.color
  local seed = b.seed or 0
  for(let local f in values(city.solid_faces(b.solid))){
    local start = out.count
    for(let local p in values(f.points)){
      append(out.vertices, p.x)
      append(out.vertices, p.y)
      append(out.vertices, p.z)
      append(out.normals, f.n.x)
      append(out.normals, f.n.y)
      append(out.normals, f.n.z)
      append(out.colors, c[0])
      append(out.colors, c[1])
      append(out.colors, c[2])
      append(out.colors, seed)
      append(out.texcoords, b.kind)
      append(out.texcoords, b.param or 0)
      append(out.texcoords2, 0)
      append(out.texcoords2, 0)
      out.count = out.count + 1
    }
    for(local k = 1; k + 1 < len(f.points); k = k + 1){
      append(out.indices, start)
      append(out.indices, start + k)
      append(out.indices, start + k + 1)
    }
  }
}

local func new_box_lists(){
  return {vertices: {}, normals: {}, colors: {}, texcoords: {}, texcoords2: {}, indices: {}, count: 0}
}

local func new_lists(){
  return {vertices: {}, normals: {}, colors: {}, texcoords: {}, texcoords2: {}, indices: {}, count: 0}
}

// ring(sec, n): a profile of n points around (sec.xc, sec.yc), half width
// sec.w and half height sec.h, counter clockwise seen from the front;
// sec.e under 1 squares the corners (1 is an ellipse)
local func ring(sec, n){
  local pts = {}
  local e = sec.e or 0.5
  for(local k = 0; k < n; k = k + 1){
    local a = (k + 0.5) / n * 2 * math.pi
    local c = math.cos(a)
    local sn = math.sin(a)
    append(pts, {
      x: (sec.xc or 0) + sec.w * math.sign(c) * math.abs(c) ^ e,
      y: sec.yc + sec.h * math.sign(sn) * math.abs(sn) ^ e,
    })
  }
  return pts
}

// geometry(part) -> {positions, normals, uvs, tris}: a box ({x0 .. z1})
// or a loft ({sections: {{z, w, h, yc, xc?, e?}}, n}) in its own frame. A
// loft joins the profiles of its sections along z with one ring of
// vertices each, shaded smooth, and closes both ends.
local func geometry(part){
  local g = {positions: {}, normals: {}, uvs: {}, tris: {}}
  if(part.sections == null){
    local lists = new_box_lists()
    add_box(lists, part)
    for(local i = 0; i < lists.count; i = i + 1){
      append(g.positions, {x: lists.vertices[i * 3], y: lists.vertices[i * 3 + 1], z: lists.vertices[i * 3 + 2]})
      append(g.normals, {x: lists.normals[i * 3], y: lists.normals[i * 3 + 1], z: lists.normals[i * 3 + 2]})
      append(g.uvs, {lists.texcoords2[i * 2], lists.texcoords2[i * 2 + 1]})
    }
    g.tris = lists.indices
    return g
  }
  local n = part.n or 10
  local secs = part.sections
  local count = len(secs)
  local acc = {}
  for(local si = 0; si < count; si = si + 1){
    local pts = ring(secs[si], n)
    for(local k = 0; k < n; k = k + 1){
      append(g.positions, {x: pts[k].x, y: pts[k].y, z: secs[si].z})
      append(acc, {x: 0, y: 0, z: 0})
      append(g.uvs, {k / n, si / (count - 1)})
    }
  }
  // the sides: quads between rings, their normals summed at the corners
  for(local si = 0; si + 1 < count; si = si + 1){
    for(local k = 0; k < n; k = k + 1){
      local a = si * n + k
      local b = si * n + (k + 1) % n
      local c = (si + 1) * n + (k + 1) % n
      local d = (si + 1) * n + k
      local fa = vec.cross(vec.sub(g.positions[b], g.positions[a]), vec.sub(g.positions[c], g.positions[a]))
      local fb = vec.cross(vec.sub(g.positions[c], g.positions[a]), vec.sub(g.positions[d], g.positions[a]))
      local f = vec.add(fa, fb)
      for(let local i in values({a, b, c, d})){
        acc[i] = vec.add(acc[i], f)
      }
      for(let local i in values({a, b, c, a, c, d})){
        append(g.tris, i)
      }
    }
  }
  for(let local v in values(acc)){
    append(g.normals, vec.normalize(v))
  }
  // the ends, flat
  for(let local end in values({0, count - 1})){
    local start = len(g.positions)
    local nz = if(end == 0){ -1 } else { 1 }
    for(local k = 0; k < n; k = k + 1){
      append(g.positions, g.positions[end * n + k])
      append(g.normals, {x: 0, y: 0, z: nz})
      append(g.uvs, {0, 0})
    }
    for(local k = 1; k + 1 < n; k = k + 1){
      if(nz > 0){
        append(g.tris, start)
        append(g.tris, start + k)
        append(g.tris, start + k + 1)
      } else {
        append(g.tris, start)
        append(g.tris, start + k + 1)
        append(g.tris, start + k)
      }
    }
  }
  return g
}

// emit(out, part, g, xf?, extra?): a part's geometry into the lists, turned
// by xf.q and moved to xf.pos; extra replaces texcoord2 ({speed, axis})
// and the param (texcoord y) for the traffic
local func emit(out, part, g, xf, extra){
  local c = part.color
  local seed = part.seed or 0
  local start = out.count
  local param = part.param or 0
  if(extra != null){
    param = extra.param
  }
  for(local i = 0; i < len(g.positions); i = i + 1){
    local p = g.positions[i]
    local nn = g.normals[i]
    if(xf != null){
      p = vec.add(xf.pos, vec.rotate(xf.q, p))
      nn = vec.rotate(xf.q, nn)
    }
    append(out.vertices, p.x)
    append(out.vertices, p.y)
    append(out.vertices, p.z)
    append(out.normals, nn.x)
    append(out.normals, nn.y)
    append(out.normals, nn.z)
    append(out.colors, c[0])
    append(out.colors, c[1])
    append(out.colors, c[2])
    append(out.colors, seed)
    append(out.texcoords, part.kind)
    append(out.texcoords, param)
    if(extra != null){
      append(out.texcoords2, extra.speed)
      append(out.texcoords2, extra.axis)
    } else {
      append(out.texcoords2, g.uvs[i][0])
      append(out.texcoords2, g.uvs[i][1])
    }
    out.count = out.count + 1
  }
  for(let local i in values(g.tris)){
    append(out.indices, start + i)
  }
}

// emit_moved(out, part, g, pos, extra): emit, only moved by pos
local func emit_moved(out, part, g, pos, extra){
  local c = part.color
  local start = out.count
  local vs = out.vertices
  local ns = out.normals
  local cs = out.colors
  local ts = out.texcoords
  local t2 = out.texcoords2
  for(local i = 0; i < len(g.positions); i = i + 1){
    local q = g.positions[i]
    local nn = g.normals[i]
    append(vs, pos.x + q.x)
    append(vs, pos.y + q.y)
    append(vs, pos.z + q.z)
    append(ns, nn.x)
    append(ns, nn.y)
    append(ns, nn.z)
    append(cs, c[0])
    append(cs, c[1])
    append(cs, c[2])
    append(cs, part.seed or 0)
    append(ts, part.kind)
    append(ts, extra.param)
    append(t2, extra.speed)
    append(t2, extra.axis)
  }
  out.count = start + len(g.positions)
  for(let local i in values(g.tris)){
    append(out.indices, start + i)
  }
}

// a model of parts (boxes and lofts), under the shader
local func boxes_model(boxes){
  local out = new_lists()
  for(let local b in values(boxes)){
    if(b.solid != null){
      add_solid(out, b)
    } else if(b.sections == null){
      add_box(out, b)
    } else {
      emit(out, b, geometry(b))
    }
  }
  local mesh = rl.mesh({
    vertices: out.vertices, normals: out.normals, colors: out.colors,
    texcoords: out.texcoords, texcoords2: out.texcoords2, indices: out.indices,
  })
  local model = mesh:to_model()
  model.materials[0].shader = shader
  return model
}

// ------------------------------------------------------------ the cars

// the player car's thrusters: where the flames come out, its own frame
m.NOZZLES = {{x: -1.05, y: -0.12, z: -2.3}, {x: 1.05, y: -0.12, z: -2.3}}

// the courier's colors: dark blue lacquer, warm headlights, cyan
local COURIER = {{44, 50, 70}, {255, 236, 200}, {0, 220, 255}}

// a design's slot as the traffic shader reads it (texcoord2 x)
local SLOTS = {body: 1, accent: 2, light: 3}

// the model of a car flying free (designs.FREE), in the courier's colors,
// made when first drawn
local free_models = {}

local func free_model(i){
  local model = free_models[i]
  if(model == null){
    model = boxes_model(designs.parts(designs.FREE[i], COURIER))
    free_models[i] = model
  }
  return model
}

// ------------------------------------------------------------ init

// init(width, height): the shaders, the render targets, the shared models
func m.init(w, h){
  width = w
  height = h
  shader = rl.shader({vertex: scene_vs, fragment: scene_fs})
  locs.view = shader:location("viewPos")
  locs.time = shader:location("time")
  locs.kind = shader:location("kindOverride")
  locs.param = shader:location("paramOverride")
  locs.pitch = shader:location("streetPitch")
  locs.street = shader:location("streetHalf")
  locs.lanes = shader:location("laneOffsets")
  traffic_shader = rl.shader({vertex: traffic_vs, fragment: scene_fs})
  traffic_locs.view = traffic_shader:location("viewPos")
  traffic_locs.time = traffic_shader:location("time")
  traffic_locs.traffic_time = traffic_shader:location("trafficTime")
  traffic_locs.limit = traffic_shader:location("limit")
  traffic_locs.hidden = traffic_shader:location("hidden")
  traffic_locs.focus = traffic_shader:location("focus")
  traffic_locs.split = traffic_shader:location("split")
  traffic_shader:set_value(traffic_shader:location("kindOverride"), -1, rl.SHADER_UNIFORM_FLOAT)
  traffic_shader:set_value(traffic_shader:location("paramOverride"), 0, rl.SHADER_UNIFORM_FLOAT)
  post.sky = rl.shader({vertex: post_vs, fragment: sky_fs})
  post.sky_forward = post.sky:location("camForward")
  post.sky_right = post.sky:location("camRight")
  post.sky_up = post.sky:location("camUp")
  post.sky_tan = post.sky:location("tanHalf")
  post.sky_y = post.sky:location("camY")
  post.sky_time = post.sky:location("time")
  post.sky_resolution = post.sky:location("resolution")
  post.bright = rl.shader({vertex: post_vs, fragment: bright_fs})
  post.blur = rl.shader({vertex: post_vs, fragment: blur_fs})
  post.blur_dir = post.blur:location("dir")
  post.composite = rl.shader({vertex: post_vs, fragment: composite_fs})
  post.bloom_loc = post.composite:location("bloom")
  post.speed_loc = post.composite:location("speedBlur")
  post.aberration_loc = post.composite:location("aberration")
  post.flash_loc = post.composite:location("flash")
  post.dim_loc = post.composite:location("dim")
  targets = {
    scene: rl.render_texture(w, h),
    bright: rl.render_texture(to_int(w / 4), to_int(h / 4)),
    blur: rl.render_texture(to_int(w / 4), to_int(h / 4)),
  }
  targets.scene.texture.filter = rl.TEXTURE_FILTER_BILINEAR
  targets.bright.texture.filter = rl.TEXTURE_FILTER_BILINEAR
  targets.blur.texture.filter = rl.TEXTURE_FILTER_BILINEAR
  meshes.cube = rl.mesh.cube(1, 1, 1)
  models.cube = meshes.cube:to_model()
  models.cube.materials[0].shader = shader
  traffic_locs.model = traffic_shader:location_attrib("instanceTransform")
  buffer.wrap(traffic_shader.locs, 32, "int")[rl.SHADER_LOC_MATRIX_MODEL] = traffic_locs.model
}

// a model of boxes under a shader, from lists already filled
local func lists_model(out, sh){
  local mesh = rl.mesh({
    vertices: out.vertices, normals: out.normals, colors: out.colors,
    texcoords: out.texcoords, texcoords2: out.texcoords2, indices: out.indices,
  })
  local model = mesh:to_model()
  model.materials[0].shader = sh
  return model
}

// a traffic car as its instance matrix (see build_traffic)
local func instance(car){
  local lane = car.lane
  local axis = if(lane.axis == "x"){ 0 } else { 1 }
  local b = car.color
  local a = car.accent
  local cold = if(car.light[0] < 240){ 1 } else { 0 }
  return {
    m0: car.s0, m1: lane.speed, m2: lane.at, m3: lane.y,
    m4: axis, m5: car.id, m6: 0, m7: 0,
    m8: b[0] / 255, m9: b[1] / 255, m10: b[2] / 255, m11: cold,
    m12: a[0] / 255, m13: a[1] / 255, m14: a[2] / 255, m15: 1,
  }
}

// a part as a car far off has it, or null: the hull, the glass and
// the other big shapes with fewer points round, the lights; the small
// things gone
local func lod_part(part){
  if(part.sections != null){
    local big = false
    for(let local sc in values(part.sections)){
      if(sc.w >= 0.45 and sc.h >= 0.08){
        big = true
      }
    }
    if(not big or len(part.sections) < 3){
      return null
    }
    local out = {}
    for(let local e in entries(part)){
      out[e[0]] = e[1]
    }
    out.n = math.max(6, to_int((part.n or 10) / 2))
    return out
  }
  local dx = part.x1 - part.x0
  local dy = part.y1 - part.y0
  local dz = part.z1 - part.z0
  local most = math.max(dx, math.max(dy, dz))
  if(part.kind == city.NEON){
    return if(most >= 0.3){ part } else { null }
  }
  local least = math.min(dx, math.min(dy, dz))
  return if(least >= 0.25 and most >= 1.0){ part } else { null }
}

// build_traffic(t): a mesh per design, the slots for the shader to
// paint, and per design a buffer of its cars, one matrix each, which the
// shader reads as data: column 0 the start along the lane, the signed
// speed, the lane's place across and its height; column 1 the axis (0
// along x), the car's id; column 2 the body's color and how cold the
// headlights are; column 3 the accent. Every car is drawn by one
// instanced call per design and slid along its lane by the shader.
func m.build_traffic(t){
  m.unload_traffic()
  local by_design = {}
  for(let local car in values(t.cars)){
    local list = by_design[car.design]
    if(list == null){
      list = {}
      by_design[car.design] = list
    }
    append(list, car)
  }
  for(local d = 0; d < len(designs.TRAFFIC); d = d + 1){
    local cars = by_design[d]
    if(cars == null){
      continue
    }
    local full = new_lists()
    local far = new_lists()
    for(let local part in values(designs.parts(designs.TRAFFIC[d]))){
      if(part.color == null){
        part.color = {255, 255, 255}
      }
      local extra = {param: 0, speed: SLOTS[part.slot] or 0, axis: 0}
      emit(full, part, geometry(part), null, extra)
      local lp = lod_part(part)
      if(lp != null){
        emit(far, lp, geometry(lp), null, extra)
      }
    }
    local model = lists_model(full, traffic_shader)
    local far_model = lists_model(far, traffic_shader)
    local data = buffer.new("Matrix", len(cars), rl.decls)
    for(local i = 0; i < len(cars); i = i + 1){
      data[i] = instance(cars[i])
    }
    append(traffic_models, {
      design: d, model: model, mesh: model.meshes[0], material: model.materials[0],
      far: far_model, far_mesh: far_model.meshes[0], data: data,
      // the near cars of this design, refilled each frame
      near: buffer.new("Matrix", 256, rl.decls),
    })
  }
}

func m.unload_traffic(){
  for(let local tm in values(traffic_models)){
    tm.model:unload()
    tm.far:unload()
  }
  traffic_models = {}
  for(let local model in values(wreck_models)){
    model:unload()
  }
  wreck_models = {}
}

// the position of a traffic car at a time (the traffic module's, kept
// here so the mesh and the shader agree with the physics)
func m.position(car, time){
  return require("game/traffic").position(car, time)
}

// build_city(c): a model per chunk, and the streets' layout for the
// ground
func m.build_city(c){
  m.unload_city()
  shader:set_value(locs.pitch, c.pitch, rl.SHADER_UNIFORM_FLOAT)
  shader:set_value(locs.street, c.street / 2, rl.SHADER_UNIFORM_FLOAT)
  local lanes = {0, 0, 0}
  for(local i = 0; i < math.min(3, len(c.lane_offsets)); i = i + 1){
    lanes[i] = c.lane_offsets[i]
  }
  shader:set_value(locs.lanes, lanes, rl.SHADER_UNIFORM_VEC3)
  for(let local chunk in values(c.chunks)){
    append(chunk_models, {chunk: chunk, model: boxes_model(chunk.boxes)})
  }
}

func m.unload_city(){
  for(let local cm in values(chunk_models)){
    cm.model:unload()
  }
  chunk_models = {}
}

func m.unload(){
  m.unload_city()
  m.unload_traffic()
  for(let local model in values(free_models)){
    model:unload()
  }
  free_models = {}
  traffic_shader:unload()
  models.cube.mesh_count = 0
  models.cube:unload()
  meshes.cube:unload()
  targets.scene:unload()
  targets.bright:unload()
  targets.blur:unload()
  shader:unload()
  post.sky:unload()
  post.bright:unload()
  post.blur:unload()
  post.composite:unload()
}

// ------------------------------------------------------------ drawing

local origin = {0, 0, 0}
local unit = {x: 1, y: 1, z: 1}
local identity = {x: 0, y: 0, z: 0, w: 1}

local func sky(camera, time){
  rl.draw.clear({6, 5, 12})
  local forward = vec.normalize(vec.sub(camera.target, camera.position))
  local right = vec.normalize(vec.cross(forward, camera.up))
  local up = vec.cross(right, forward)
  local t = math.tan(camera.fovy / 2 * math.pi / 180)
  rl.shader_mode(post.sky){
    post.sky:set_value(post.sky_forward, forward, rl.SHADER_UNIFORM_VEC3)
    post.sky:set_value(post.sky_right, right, rl.SHADER_UNIFORM_VEC3)
    post.sky:set_value(post.sky_up, up, rl.SHADER_UNIFORM_VEC3)
    post.sky:set_value(post.sky_tan, {t * width / height, t}, rl.SHADER_UNIFORM_VEC2)
    post.sky:set_value(post.sky_y, camera.position.y, rl.SHADER_UNIFORM_FLOAT)
    post.sky:set_value(post.sky_time, time, rl.SHADER_UNIFORM_FLOAT)
    post.sky:set_value(post.sky_resolution, {width, height}, rl.SHADER_UNIFORM_VEC2)
    rl.draw.rectangle(0, 0, width, height, rl.WHITE)
  }
  shader:set_value(locs.view, camera.position, rl.SHADER_UNIFORM_VEC3)
  shader:set_value(locs.time, time, rl.SHADER_UNIFORM_FLOAT)
  current_kind = -2
  current_param = -1
  set_kind(-1, 0)
}

// scene(camera, time, block): the block draws the world into the scene
// texture, in 3D through camera, after the sky
func m.scene(camera, time, block){
  rl.texture_mode(targets.scene){
    sky(camera, time)
    rl.mode_3d(camera, block)
  }
}

// city(camera): the chunks in view
func m.city(camera){
  set_kind(-1, 0)
  local cam = camera.position
  local forward = vec.normalize(vec.sub(camera.target, cam))
  local half = camera.fovy / 2 * math.pi / 180
  local aspect = width / height
  local wide = math.atan(math.tan(half) * aspect)
  local cos_limit = math.cos(wide + 0.25)
  local drawn = 0
  for(let local cm in values(chunk_models)){
    local c = cm.chunk
    local to = vec.sub(c.center, cam)
    local d = vec.length(to)
    if(d - c.radius > m.VIEW){
      continue
    }
    if(d > c.radius * 1.2){
      local margin = math.asin(math.min(1, c.radius / d))
      local cosang = vec.dot(to, forward) / d
      if(cosang < math.cos(math.min(math.pi, wide + 0.25 + margin))){
        continue
      }
    }
    cm.model:draw(origin, 1, rl.WHITE)
    drawn = drawn + 1
  }
  return drawn
}

// model(model, pos, q, scale?, color?, kind?, param?)
local func draw_model(model, pos, q, scale, color, kind, param){
  set_kind(kind or -1, param or 0)
  model.transform = vec.matrix(pos, q, scale or unit)
  model:draw(origin, 1, color or rl.WHITE)
}

// box(pos, q, size, color, kind, param?): a cube of the shared mesh
func m.box(pos, q, size, color, kind, param){
  draw_model(models.cube, pos, q, size, color, kind, param)
}

// the thrusters' light trail: where the nozzles were in the last moments,
// {t, points: one per nozzle, width, color}, kept on each car (car.trail)
local TRAIL = 0.35

// a ribbon through points facing the camera, as wide as widths say, in
// colors (both sides drawn: it is seen from anywhere)
local func ribbon(points, widths, colors, eye){
  for(local i = 0; i + 1 < len(points); i = i + 1){
    local a = points[i]
    local b = points[i + 1]
    local along = vec.sub(b, a)
    if(vec.length(along) > 0.01){
      local side = vec.normalize(vec.cross(along, vec.sub(eye, a)))
      local sa = vec.scale(side, widths[i])
      local sb = vec.scale(side, widths[i + 1])
      local a0 = vec.sub(a, sa)
      local a1 = vec.add(a, sa)
      local b0 = vec.sub(b, sb)
      local b1 = vec.add(b, sb)
      local c = colors[i]
      rl.draw.triangle_3d(a0, b1, a1, c)
      rl.draw.triangle_3d(a0, b0, b1, c)
      rl.draw.triangle_3d(a0, a1, b1, c)
      rl.draw.triangle_3d(a0, b1, b0, c)
    }
  }
}

// car(car, time, camera, tint?, simple?): a car (the player's, or another
// tinted), its thrusters' glow and the light trail they leave behind it
// (simple: no trail, for one far off)
func m.car(car, time, camera, tint, simple){
  draw_model(free_model(car.design or 0), car.pos, car.q, unit, tint or rl.WHITE)
  if(simple){
    // far off: the model and its nozzles' glow, no trail
    for(let local nz in values(m.NOZZLES)){
      m.box(vec.add(car.pos, vec.rotate(car.q, nz)), car.q, {x: 0.35, y: 0.35, z: 0.12}, {80, 210, 255, 200}, city.NEON)
    }
    return
  }
  local trail = car.trail or {}
  local t = car.thrust
  if(car.boosting){
    t = 1
  }
  local color = {80, 210, 255}
  if(car.boosting){
    color = {255, 120, 200}
  }
  // the nozzles now, into the trail; the old part of it out
  local now = {}
  for(let local nz in values(m.NOZZLES)){
    append(now, vec.add(car.pos, vec.rotate(car.q, nz)))
  }
  local last = trail[len(trail) - 1]
  if(last != null and vec.length(vec.sub(last.points[0], now[0])) > 30){
    trail = {}
  }
  append(trail, {t: time, points: now, width: 0.07 + 0.17 * t, color: color})
  local keep = {}
  local life = TRAIL
  if(car.boosting){
    life = TRAIL * 1.25
  }
  for(let local sample in values(trail)){
    if(time - sample.t < life){
      append(keep, sample)
    }
  }
  trail = keep
  car.trail = trail
  // newest first: wide and bright at the car, thin and faint behind it
  local n = len(trail)
  if(n >= 2 and camera != null){
    rl.blend_mode(rl.BLEND_ADDITIVE){
      for(local k = 0; k < len(m.NOZZLES); k = k + 1){
        local points = {}
        local widths = {}
        local outer = {}
        local core = {}
        local core_w = {}
        for(local i = n - 1; i >= 0; i = i - 1){
          local sample = trail[i]
          local f = 1 - (time - sample.t) / life
          local c = sample.color
          append(points, sample.points[k])
          append(widths, sample.width * f)
          append(core_w, sample.width * 0.3 * f)
          // fainter the nearer it comes to the camera (it is behind the car)
          local near = vec.clamp(vec.length(vec.sub(sample.points[k], camera.position)) / 6 - 0.3, 0, 1)
          local a = to_int(vec.clamp((40 + 170 * t) * f * f * near, 0, 255))
          append(outer, {c[0], c[1], c[2], a})
          append(core, {255, 255, 255, to_int(a * 0.8)})
        }
        ribbon(points, widths, outer, camera.position)
        ribbon(points, core_w, core, camera.position)
      }
    }
  }
  // the hot glow in each nozzle
  local glow = 0.2 + 0.25 * t
  for(let local p in values(now)){
    m.box(p, car.q, {x: glow, y: glow, z: 0.12}, {color[0], color[1], color[2], to_int(120 + 135 * t)}, city.NEON)
  }
  // the magnet's glow under the car, while it holds a surface
  if(car.mode == "stick"){
    local p = vec.add(car.pos, vec.rotate(car.q, {x: 0, y: -0.4, z: -0.3}))
    local pulse = 0.5 + 0.5 * math.sin(time * 6)
    local c = {80, 255, 160, to_int(60 + 60 * pulse)}
    if(car.mode == "stick"){
      c = {80, 255, 160, 170}
    }
    m.box(p, car.q, {x: 2.0, y: 0.1, z: 3.6}, c, city.NEON)
  }
}

// traffic(t, camera, time): every car, slid along its lane by the shader
func m.traffic(t, camera, time){
  traffic_shader:set_value(traffic_locs.view, camera.position, rl.SHADER_UNIFORM_VEC3)
  traffic_shader:set_value(traffic_locs.time, time, rl.SHADER_UNIFORM_FLOAT)
  traffic_shader:set_value(traffic_locs.traffic_time, t.time, rl.SHADER_UNIFORM_FLOAT)
  traffic_shader:set_value(traffic_locs.limit, t.limit, rl.SHADER_UNIFORM_FLOAT)
  // the wrecks are drawn on their own: hidden in the mesh
  local hidden = {}
  for(local i = 0; i < 32; i = i + 1){
    local id = -1
    if(i < len(t.wrecks)){
      id = t.wrecks[i].car.id
    }
    append(hidden, id)
  }
  traffic_shader:set_value_v(traffic_locs.hidden, hidden, rl.SHADER_UNIFORM_INT)
  // far: every car in its simple shape, but those near the player
  local focus = t.focus or camera.position
  traffic_shader:set_value(traffic_locs.focus, focus, rl.SHADER_UNIFORM_VEC3)
  traffic_shader:set_value(traffic_locs.split, m.TRAFFIC_NEAR, rl.SHADER_UNIFORM_FLOAT)
  for(let local tm in values(traffic_models)){
    rl.draw.mesh_instanced(tm.far_mesh, tm.material, tm.data)
  }
  // near: those in full, from the traffic's near set (the same rule)
  local counts = {}
  local by = {}
  for(let local tm in values(traffic_models)){
    by[tm.design] = tm
    counts[tm.design] = 0
  }
  for(let local car in values(t.near)){
    local tm = by[car.design]
    local n = counts[car.design]
    if(car.pos != null and n < len(tm.near) and vec.distance(car.pos, focus) < m.TRAFFIC_NEAR){
      tm.near[n] = instance(car)
      counts[car.design] = n + 1
    }
  }
  traffic_shader:set_value(traffic_locs.split, -1, rl.SHADER_UNIFORM_FLOAT)
  for(let local tm in values(traffic_models)){
    local n = counts[tm.design]
    if(n > 0){
      rl.draw.mesh_instanced(tm.mesh, tm.material, tm.near:slice(0, n))
    }
  }
  for(let local wr in values(t.wrecks)){
    local car = wr.car
    local key = concat(string(car.design), ":", string(car.palette))
    local model = wreck_models[key]
    if(model == null){
      model = boxes_model(designs.parts(designs.TRAFFIC[car.design], {car.color, car.light, car.accent}))
      wreck_models[key] = model
    }
    draw_model(model, wr.pos, wr.q, unit, rl.WHITE)
  }
  return len(t.cars)
}

// beacon(pad, color, time): a column of light over a pad
func m.beacon(pad, color, time){
  local pulse = 0.7 + 0.3 * math.sin(time * 2)
  m.box({x: pad.x, y: pad.y + 40, z: pad.z}, identity, {x: 0.8, y: 80, z: 0.8},
    {color[0], color[1], color[2], to_int(70 * pulse)}, city.NEON)
  m.box({x: pad.x, y: pad.y + 40, z: pad.z}, identity, {x: 3, y: 80, z: 3},
    {color[0], color[1], color[2], to_int(22 * pulse)}, city.NEON)
  // a ring that falls onto the pad
  local k = (time * 0.7) % 1
  local s = 2 + (1 - k) * 10
  m.box({x: pad.x, y: pad.y + 0.5 + (1 - k) * 6, z: pad.z}, identity, {x: s, y: 0.15, z: s},
    {color[0], color[1], color[2], to_int(120 * k)}, city.NEON)
}

// ------------------------------------------------------------ post

// present(options: {speed: 0..1, aberration: 0..1, flash: {r, g, b}
// 0..1, dim: 0..1}): the scene texture, bloomed, to the screen
func m.present(o){
  o = o or {}
  local scene = targets.scene
  local bright = targets.bright
  local blur = targets.blur
  local bw = bright.texture.width
  local bh = bright.texture.height
  local full = {0, 0, width, -height}
  local small = {0, 0, bw, -bh}
  // the bright parts, small
  rl.texture_mode(bright){
    rl.shader_mode(post.bright){
      scene.texture:draw_pro(full, {0, 0, bw, bh}, {0, 0}, 0, rl.WHITE)
    }
  }
  // blurred across, then down
  rl.texture_mode(blur){
    rl.shader_mode(post.blur){
      post.blur:set_value(post.blur_dir, {1 / bw, 0}, rl.SHADER_UNIFORM_VEC2)
      bright.texture:draw_rec(small, {0, 0}, rl.WHITE)
    }
  }
  rl.texture_mode(bright){
    rl.shader_mode(post.blur){
      post.blur:set_value(post.blur_dir, {0, 1 / bh}, rl.SHADER_UNIFORM_VEC2)
      blur.texture:draw_rec(small, {0, 0}, rl.WHITE)
    }
  }
  // composited onto the screen
  rl.shader_mode(post.composite){
    post.composite:set_value_texture(post.bloom_loc, bright.texture)
    post.composite:set_value(post.speed_loc, o.speed or 0, rl.SHADER_UNIFORM_FLOAT)
    post.composite:set_value(post.aberration_loc, o.aberration or 0, rl.SHADER_UNIFORM_FLOAT)
    local f = o.flash or {0, 0, 0}
    post.composite:set_value(post.flash_loc, {f[0], f[1], f[2]}, rl.SHADER_UNIFORM_VEC3)
    post.composite:set_value(post.dim_loc, o.dim or 1, rl.SHADER_UNIFORM_FLOAT)
    scene.texture:draw_rec(full, {0, 0}, rl.WHITE)
  }
}

// ------------------------------------------------------------ showroom

// the designs by name, for tool/showroom: those flying free (the
// player's first), then the traffic's
m.DESIGNS = {}
for(let local d in values(designs.FREE)){
  append(m.DESIGNS, d.name)
}
for(let local d in values(designs.TRAFFIC)){
  append(m.DESIGNS, d.name)
}

// design_model(i, palette?: {body, light, accent}) -> a model of the
// design i of DESIGNS (in the courier's colors without a palette), for
// the caller to unload
func m.design_model(i, palette){
  local nf = len(designs.FREE)
  if(i < nf){
    return boxes_model(designs.parts(designs.FREE[i], palette or COURIER))
  }
  return boxes_model(designs.parts(designs.TRAFFIC[i - nf], palette or {{200, 205, 215}, {255, 236, 200}, {0, 220, 255}}))
}

// the half extents of design i's box
func m.design_half(i){
  local nf = len(designs.FREE)
  if(i < nf){
    return null
  }
  return designs.half(designs.TRAFFIC[i - nf])
}

// draw(model, pos, q, tint?): a model made here, under the scene shader
func m.draw(model, pos, q, tint){
  draw_model(model, pos, q, unit, tint or rl.WHITE)
}

return m
