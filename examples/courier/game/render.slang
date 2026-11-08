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

local m = {}

m.VIEW = 950        // how far chunks are drawn

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
  vec3 haze = vec3(0.36, 0.12, 0.30);
  vec3 col = vec3(0.0);
  float alpha = colDiffuse.a;
  if(kind < 0.5){
    // a facade: the windows are cells of the wall, 2 m by 3 m
    float vertical = 1.0 - abs(n.y);
    vec2 uv;
    if(abs(n.x) > 0.5){
      uv = vec2(fragPosition.z * sign(n.x), fragPosition.y);
    } else if(abs(n.z) > 0.5){
      uv = vec2(-fragPosition.x * sign(n.z), fragPosition.y);
    } else {
      uv = fragPosition.xz;
    }
    vec2 cs = vec2(2.0, 3.0);
    vec2 cell = floor(uv / cs);
    vec2 f = fract(uv / cs);
    float h = hash21(cell + seed * 7.13);
    float lit = step(h, param) * vertical;
    float frame = step(0.16, f.x) * step(f.x, 0.84) * step(0.2, f.y) * step(f.y, 0.8);
    float h2 = hash21(vec2(cell.y, seed));
    vec3 wcol = mix(vec3(1.0, 0.82, 0.55), vec3(0.55, 0.85, 1.0), step(0.55, h2));
    wcol = mix(wcol, vec3(1.0, 0.5, 0.8), step(0.92, h2));
    float flicker = 1.0 + 0.3 * step(0.93, hash21(cell * 1.7 + seed)) * sin(time * 7.0 + h * 50.0);
    float bright = lit * frame * (0.6 + 0.7 * hash21(cell + 3.0)) * flicker;
    vec3 wall = base * 0.2 * (0.7 + 0.3 * vertical);
    float band = smoothstep(0.0, 0.08, f.y) * smoothstep(1.0, 0.92, f.y);
    wall *= 0.75 + 0.5 * (1.0 - band);
    wall += haze * low * 0.6 * (0.5 - 0.5 * n.y);
    col = wall + wcol * bright * 1.8 + (1.0 - lit) * frame * vertical * wcol * 0.04;
    float rim = pow(1.0 - max(dot(n, v), 0.0), 4.0);
    col += rim * vec3(0.3, 0.15, 0.45) * 0.35;
  } else if(kind < 1.5){
    // neon
    float blink = 1.0;
    if(param > 0.0){
      blink = step(0.5, fract(time * param));
    }
    col = base * (2.4 * blink + 0.08);
  } else if(kind < 2.5){
    // structure, with running lights along its length
    col = base * 0.3 * (0.6 + 0.4 * max(n.y, 0.0));
    col += haze * low * 0.5 * (0.5 - 0.5 * n.y);
    if(param > 6.0){
      float along = uv2.x * param;
      float dots = step(0.86, fract(along / 6.0 - time * 0.7)) * step(0.5, abs(n.y));
      col += vec3(1.0, 0.6, 0.2) * dots * 1.6;
    }
    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0);
    col += rim * vec3(0.25, 0.12, 0.4) * 0.3;
  } else if(kind < 3.5){
    // a billboard: bands, a drifting blob, scanlines, color cycling
    vec2 u = uv2;
    float t = time * (0.5 + 0.25 * param) + seed;
    vec3 c2 = base.gbr;
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
    col += lane * vec3(1.0, 0.5, 0.2) * 0.9 + center * vec3(0.3, 0.9, 1.0);
    float sparkle = step(0.985, hash21(floor(p / 3.0))) * (1.0 - street);
    col += sparkle * vec3(1.0, 0.8, 0.6) * 0.7;
  } else {
    // painted metal: the cars
    vec3 l = normalize(vec3(0.3, 1.0, 0.2));
    float d = max(dot(n, l), 0.0);
    vec3 h = normalize(l + v);
    float spec = pow(max(dot(n, h), 0.0), 40.0);
    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0);
    col = base * (0.25 + 0.35 * d + 0.15 * (0.5 + 0.5 * n.y));
    col += vec3(0.8, 0.85, 1.0) * spec * 0.6 + rim * vec3(0.4, 0.2, 0.6) * 0.5;
    col += haze * low * 0.3;
  }
  // the fog: by distance, glowing warm where the city's light is
  float fog = 1.0 - exp(-dist * 0.0017);
  float lowf = exp(-max(fragPosition.y, 0.0) * 0.009);
  vec3 fogc = mix(vec3(0.02, 0.015, 0.05), vec3(0.24, 0.085, 0.22), lowf);
  col = mix(col, fogc, fog);
  finalColor = vec4(col, alpha);
}
"""

// the traffic's vertex shader: every car is in the mesh where it was at
// time zero; the shader slides it along its lane by its speed times the
// time, wrapped at the city's edge (the whole car by the same shift, so
// it stays in one piece). texcoord2.x is the signed speed, texcoord2.y
// the car's id doubled plus the axis (0 along x, 1 along z), texcoord.y
// the car's start along it; the cars in `hidden` (wrecks drawn on their
// own) collapse to nothing.
local traffic_vs = """#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec2 vertexTexCoord;
in vec2 vertexTexCoord2;
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
uniform float trafficTime;
uniform float limit;
uniform int hidden[32];
out vec3 fragPosition;
out vec3 fragNormal;
out vec4 fragColor;
out vec2 fragTexCoord;
out vec2 fragTexCoord2;
void main(){
  float speed = vertexTexCoord2.x;
  float idf = floor(vertexTexCoord2.y / 2.0);
  float axis = vertexTexCoord2.y - idf * 2.0;
  int id = int(idf + 0.5);
  for(int i = 0; i < 32; i++){
    if(hidden[i] == id){
      gl_Position = vec4(0.0, 0.0, -2.0, 1.0);
      fragPosition = vec3(0.0);
      fragNormal = vec3(0.0, 1.0, 0.0);
      fragColor = vec4(0.0);
      fragTexCoord = vec2(0.0);
      fragTexCoord2 = vec2(0.0);
      return;
    }
  }
  float s0 = vertexTexCoord.y;
  float s = s0 + speed * trafficTime + limit;
  s = s - floor(s / (2.0 * limit)) * 2.0 * limit - limit;
  float shift = s - s0;
  vec3 p = vertexPosition;
  if(axis < 0.5){
    p.x += shift;
  } else {
    p.z += shift;
  }
  fragTexCoord = vec2(vertexTexCoord.x, 0.0);
  fragTexCoord2 = vec2(0.0);
  fragPosition = vec3(matModel * vec4(p, 1.0));
  fragNormal = normalize(vec3(matNormal * vec4(vertexNormal, 0.0)));
  fragColor = vertexColor;
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
out vec4 finalColor;

float hash21(vec2 p){
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}

void main(){
  vec2 uv = fragTexCoord * 2.0 - 1.0;
  vec3 dir = normalize(camForward + camRight * uv.x * tanHalf.x - camUp * uv.y * tanHalf.y);
  float h = dir.y;
  vec3 top = vec3(0.015, 0.012, 0.04);
  vec3 haze = vec3(0.24, 0.085, 0.22);
  vec3 glow = vec3(0.34, 0.13, 0.26);
  float horizon = exp(-abs(h) * 7.0);
  float lowcam = exp(-max(camY, 0.0) * 0.004);
  vec3 col = mix(top, haze, horizon * (0.55 + 0.45 * lowcam));
  col = mix(col, glow, smoothstep(0.0, -0.35, h) * (0.5 + 0.5 * lowcam));
  // stars
  vec2 cell = floor(dir.xz / max(0.02, abs(h) + 0.02) * 40.0 + dir.y * 100.0);
  vec2 sp = vec2(atan(dir.x, dir.z) * 120.0, h * 300.0);
  float s = hash21(floor(sp));
  float star = step(0.985, s) * smoothstep(0.05, 0.3, h) * (0.5 + 0.5 * sin(time * 2.0 + s * 60.0));
  col += vec3(0.8, 0.85, 1.0) * star * 0.8;
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

local func new_lists(){
  return {vertices: {}, normals: {}, colors: {}, texcoords: {}, texcoords2: {}, indices: {}, count: 0}
}

// a model of boxes, under the shader
local func boxes_model(boxes){
  local out = new_lists()
  for(let local b in values(boxes)){
    add_box(out, b)
  }
  local mesh = rl.mesh({
    vertices: out.vertices, normals: out.normals, colors: out.colors,
    texcoords: out.texcoords, texcoords2: out.texcoords2, indices: out.indices,
  })
  local model = mesh:to_model()
  model.materials[0].shader = shader
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
  traffic_shader:set_value(traffic_shader:location("kindOverride"), -1, rl.SHADER_UNIFORM_FLOAT)
  traffic_shader:set_value(traffic_shader:location("paramOverride"), 0, rl.SHADER_UNIFORM_FLOAT)
  post.sky = rl.shader({vertex: post_vs, fragment: sky_fs})
  post.sky_forward = post.sky:location("camForward")
  post.sky_right = post.sky:location("camRight")
  post.sky_up = post.sky:location("camUp")
  post.sky_tan = post.sky:location("tanHalf")
  post.sky_y = post.sky:location("camY")
  post.sky_time = post.sky:location("time")
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
  models.car = boxes_model(m.car_boxes())
  // a wrecked traffic car, drawn on its own: the body tinted the car's
  // color, the lights, the strips tinted its accent
  models.wreck_body = boxes_model(m.traffic_boxes({255, 255, 255}, null, null, "body"))
  models.wreck_lights = boxes_model(m.traffic_boxes(null, {255, 240, 200}, null, "lights"))
  models.wreck_strips = boxes_model(m.traffic_boxes(null, null, {255, 255, 255}, "strips"))
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

// build_traffic(t): every car as boxes where it starts, in meshes of up
// to 65535 vertices, for the traffic shader to slide along the lanes
func m.build_traffic(t){
  m.unload_traffic()
  local out = new_lists()
  local per_car = 6 * 24
  for(let local car in values(t.cars)){
    local lane = car.lane
    local p = m.position(car, 0)
    local axis = 0
    if(lane.axis == "z"){
      axis = 1
    }
    for(let local b in values(m.traffic_boxes(car.color, car.light, car.accent))){
      // into the world: the car's frame turned to its lane
      local world = {kind: b.kind, color: b.color, seed: 3, param: car.s0, speed: lane.speed, axis: car.id * 2 + axis}
      local c0 = vec.rotate(lane.q, {x: b.x0, y: b.y0, z: b.z0})
      local c1 = vec.rotate(lane.q, {x: b.x1, y: b.y1, z: b.z1})
      world.x0 = p.x + math.min(c0.x, c1.x)
      world.x1 = p.x + math.max(c0.x, c1.x)
      world.y0 = p.y + math.min(c0.y, c1.y)
      world.y1 = p.y + math.max(c0.y, c1.y)
      world.z0 = p.z + math.min(c0.z, c1.z)
      world.z1 = p.z + math.max(c0.z, c1.z)
      add_box(out, world)
    }
    if(out.count + per_car > 65000){
      append(traffic_models, lists_model(out, traffic_shader))
      out = new_lists()
    }
  }
  if(out.count > 0){
    append(traffic_models, lists_model(out, traffic_shader))
  }
}

func m.unload_traffic(){
  for(let local model in values(traffic_models)){
    model:unload()
  }
  traffic_models = {}
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
  models.car:unload()
  models.wreck_body:unload()
  models.wreck_lights:unload()
  models.wreck_strips:unload()
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

// ------------------------------------------------------------ the cars

local METAL = 6

// the player's car, as boxes in its own frame (forward is +z)
func m.car_boxes(){
  local paint = {44, 48, 66}
  local glass = {16, 22, 34}
  local cyan = {0, 230, 255}
  return {
    {x0: -1.0, y0: -0.3, z0: -2.0, x1: 1.0, y1: 0.22, z1: 1.5, kind: METAL, color: paint, seed: 1},
    {x0: -0.8, y0: -0.3, z0: 1.5, x1: 0.8, y1: 0.0, z1: 2.2, kind: METAL, color: paint, seed: 1},
    {x0: -0.6, y0: 0.22, z0: -0.9, x1: 0.6, y1: 0.58, z1: 0.9, kind: METAL, color: glass, seed: 1},
    {x0: -1.15, y0: -0.2, z0: -2.2, x1: -1.0, y1: 0.08, z1: 0.6, kind: METAL, color: paint, seed: 1},
    {x0: 1.0, y0: -0.2, z0: -2.2, x1: 1.15, y1: 0.08, z1: 0.6, kind: METAL, color: paint, seed: 1},
    // the fins at the back
    {x0: -1.1, y0: 0.2, z0: -2.1, x1: -0.9, y1: 0.7, z1: -1.4, kind: METAL, color: paint, seed: 1},
    {x0: 0.9, y0: 0.2, z0: -2.1, x1: 1.1, y1: 0.7, z1: -1.4, kind: METAL, color: paint, seed: 1},
    // neon trim
    {x0: -1.18, y0: -0.06, z0: -1.9, x1: -1.13, y1: 0.0, z1: 0.5, kind: city.NEON, color: cyan, seed: 1},
    {x0: 1.13, y0: -0.06, z0: -1.9, x1: 1.18, y1: 0.0, z1: 0.5, kind: city.NEON, color: cyan, seed: 1},
    // headlights and tail lights
    {x0: -0.7, y0: -0.2, z0: 2.18, x1: -0.3, y1: -0.05, z1: 2.24, kind: city.NEON, color: {255, 245, 220}, seed: 1},
    {x0: 0.3, y0: -0.2, z0: 2.18, x1: 0.7, y1: -0.05, z1: 2.24, kind: city.NEON, color: {255, 245, 220}, seed: 1},
    {x0: -0.95, y0: 0.0, z0: -2.06, x1: -0.2, y1: 0.14, z1: -2.0, kind: city.NEON, color: {255, 40, 40}, seed: 1},
    {x0: 0.2, y0: 0.0, z0: -2.06, x1: 0.95, y1: 0.14, z1: -2.0, kind: city.NEON, color: {255, 40, 40}, seed: 1},
    // the hover pads underneath
    {x0: -0.85, y0: -0.34, z0: 1.0, x1: -0.45, y1: -0.3, z1: 1.4, kind: city.NEON, color: cyan, seed: 1},
    {x0: 0.45, y0: -0.34, z0: 1.0, x1: 0.85, y1: -0.3, z1: 1.4, kind: city.NEON, color: cyan, seed: 1},
    {x0: -0.85, y0: -0.34, z0: -1.6, x1: -0.45, y1: -0.3, z1: -1.2, kind: city.NEON, color: cyan, seed: 1},
    {x0: 0.45, y0: -0.34, z0: -1.6, x1: 0.85, y1: -0.3, z1: -1.2, kind: city.NEON, color: cyan, seed: 1},
  }
}

// a traffic car: a tall body with a cabin, headlights and tail lights,
// and strips of light down both sides so it can be seen side-on; in its
// own frame (forward is +z). part: "body", "lights", "strips" or all
func m.traffic_boxes(color, light, accent, part){
  local out = {}
  if(part == null or part == "body"){
    append(out, {x0: -1.25, y0: -0.85, z0: -2.3, x1: 1.25, y1: 0.2, z1: 2.3, kind: METAL, color: color})
    append(out, {x0: -0.95, y0: 0.2, z0: -1.4, x1: 0.95, y1: 0.85, z1: 1.0, kind: METAL, color: color})
  }
  if(part == null or part == "lights"){
    append(out, {x0: -1.0, y0: -0.5, z0: 2.3, x1: 1.0, y1: -0.2, z1: 2.42, kind: city.NEON, color: light})
    append(out, {x0: -1.1, y0: -0.3, z0: -2.42, x1: 1.1, y1: -0.05, z1: -2.3, kind: city.NEON, color: {255, 40, 30}})
  }
  if(part == null or part == "strips"){
    append(out, {x0: -1.33, y0: -0.45, z0: -2.0, x1: -1.25, y1: -0.2, z1: 2.0, kind: city.NEON, color: accent})
    append(out, {x0: 1.25, y0: -0.45, z0: -2.0, x1: 1.33, y1: -0.2, z1: 2.0, kind: city.NEON, color: accent})
  }
  return out
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

// car(car, time): the player's car with its thrusters
func m.car(car, time){
  draw_model(models.car, car.pos, car.q, unit, rl.WHITE)
  local axes = vec.axes(car.q)
  local t = car.thrust
  if(car.boosting){
    t = 1
  }
  local flame = 0.14 + t * 0.42
  local length = 0.4 + t * 1.6 + math.sin(time * 40) * 0.1 * t
  local color = {120, 220, 255}
  if(car.boosting){
    color = {255, 160, 80}
    length = length + 1.2
  }
  local a = to_int(80 + t * 175)
  for(let local side in values({-0.6, 0.6})){
    local p = vec.add(car.pos, vec.rotate(car.q, {x: side, y: -0.05, z: -2.1 - length / 2}))
    m.box(p, car.q, {x: flame, y: flame * 0.6, z: length}, {color[0], color[1], color[2], a}, city.NEON)
  }
  // the magnet's glow under the car
  if(car.magnet){
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
  for(let local model in values(traffic_models)){
    model:draw(origin, 1, rl.WHITE)
  }
  for(let local wr in values(t.wrecks)){
    local car = wr.car
    draw_model(models.wreck_body, wr.pos, wr.q, unit, car.color)
    draw_model(models.wreck_lights, wr.pos, wr.q, unit, rl.WHITE)
    draw_model(models.wreck_strips, wr.pos, wr.q, unit, car.accent)
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

return m
