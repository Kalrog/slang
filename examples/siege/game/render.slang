// game/render: everything drawn in 3D. One lighting shader (a sun, a sky
// tint from above, a little specular, fog toward the horizon) samples each
// texture three ways (triplanar, in the object's own space, in meters),
// so every generated shape is textured without texture coordinates. The
// models (a cube, a sphere, a cylinder, a cone) are drawn with per-draw
// transforms, colors and textures; then the sky, the water, the aim line.
local rl = require("raylib")
local math = require("slang/math")
local vec = require("game/vec")
local textures = require("game/textures")

local m = {}

// the shader: GLSL 330 on the desktop, 100 (WebGL 1) in the browser
local web = __PACKAGES.preloaded["slang/web"] != null

local vertex_330 = """#version 330
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec2 vertexTexCoord;
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
out vec3 fragPosition;
out vec3 fragNormal;
out vec4 fragColor;
out vec3 fragObject;
out vec3 fragObjectNormal;
out vec2 fragTexCoord;
void main(){
  fragTexCoord = vertexTexCoord;
  vec3 scale = vec3(length(matModel[0].xyz), length(matModel[1].xyz), length(matModel[2].xyz));
  fragObject = vertexPosition * scale;
  fragObjectNormal = vertexNormal;
  fragPosition = vec3(matModel * vec4(vertexPosition, 1.0));
  fragNormal = normalize(vec3(matNormal * vec4(vertexNormal, 0.0)));
  fragColor = vertexColor;
  gl_Position = mvp * vec4(vertexPosition, 1.0);
}
"""

local fragment_330 = """#version 330
in vec3 fragPosition;
in vec3 fragNormal;
in vec4 fragColor;
in vec3 fragObject;
in vec3 fragObjectNormal;
in vec2 fragTexCoord;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec3 lightDir;
uniform vec3 viewPos;
uniform vec3 fogColor;
uniform float texScale;
uniform float shine;
out vec4 finalColor;
void main(){
  vec3 w = abs(fragObjectNormal);
  w = w / (w.x + w.y + w.z + 0.0001);
  vec3 p = fragObject * texScale;
  vec4 tex = texture(texture0, p.zy) * w.x + texture(texture0, p.xz) * w.y + texture(texture0, p.xy) * w.z;
  if(texScale == 0.0){ tex = texture(texture0, fragTexCoord); }
  vec3 n = normalize(fragNormal);
  float d = max(dot(n, lightDir), 0.0);
  float hemi = 0.5 + 0.5 * n.y;
  vec3 light = vec3(0.42, 0.45, 0.52) * hemi + vec3(0.16) + vec3(0.72, 0.68, 0.60) * d;
  vec3 v = normalize(viewPos - fragPosition);
  vec3 h = normalize(lightDir + v);
  float spec = pow(max(dot(n, h), 0.0), 32.0) * shine * d;
  vec3 c = fragColor.rgb * colDiffuse.rgb * tex.rgb * light + vec3(spec);
  float dist = distance(viewPos, fragPosition);
  float f = smoothstep(80.0, 300.0, dist);
  finalColor = vec4(mix(c, fogColor, f), fragColor.a * colDiffuse.a * tex.a);
}
"""

local vertex_100 = """#version 100
attribute vec3 vertexPosition;
attribute vec3 vertexNormal;
attribute vec4 vertexColor;
attribute vec2 vertexTexCoord;
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
varying vec3 fragPosition;
varying vec3 fragNormal;
varying vec4 fragColor;
varying vec3 fragObject;
varying vec3 fragObjectNormal;
varying vec2 fragTexCoord;
void main(){
  fragTexCoord = vertexTexCoord;
  vec3 scale = vec3(length(matModel[0].xyz), length(matModel[1].xyz), length(matModel[2].xyz));
  fragObject = vertexPosition * scale;
  fragObjectNormal = vertexNormal;
  fragPosition = vec3(matModel * vec4(vertexPosition, 1.0));
  fragNormal = normalize(vec3(matNormal * vec4(vertexNormal, 0.0)));
  fragColor = vertexColor;
  gl_Position = mvp * vec4(vertexPosition, 1.0);
}
"""

local fragment_100 = """#version 100
precision mediump float;
varying vec3 fragPosition;
varying vec3 fragNormal;
varying vec4 fragColor;
varying vec3 fragObject;
varying vec3 fragObjectNormal;
varying vec2 fragTexCoord;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec3 lightDir;
uniform vec3 viewPos;
uniform vec3 fogColor;
uniform float texScale;
uniform float shine;
void main(){
  vec3 w = abs(fragObjectNormal);
  w = w / (w.x + w.y + w.z + 0.0001);
  vec3 p = fragObject * texScale;
  vec4 tex = texture2D(texture0, p.zy) * w.x + texture2D(texture0, p.xz) * w.y + texture2D(texture0, p.xy) * w.z;
  if(texScale == 0.0){ tex = texture2D(texture0, fragTexCoord); }
  vec3 n = normalize(fragNormal);
  float d = max(dot(n, lightDir), 0.0);
  float hemi = 0.5 + 0.5 * n.y;
  vec3 light = vec3(0.42, 0.45, 0.52) * hemi + vec3(0.16) + vec3(0.72, 0.68, 0.60) * d;
  vec3 v = normalize(viewPos - fragPosition);
  vec3 h = normalize(lightDir + v);
  float spec = pow(max(dot(n, h), 0.0), 32.0) * shine * d;
  vec3 c = fragColor.rgb * colDiffuse.rgb * tex.rgb * light + vec3(spec);
  float dist = distance(viewPos, fragPosition);
  float f = smoothstep(80.0, 300.0, dist);
  gl_FragColor = vec4(mix(c, fogColor, f), fragColor.a * colDiffuse.a * tex.a);
}
"""

m.sky = {
  top: {84, 142, 218},
  horizon: {200, 222, 238},
  fog: {200, 222, 238},
  sun: {255, 246, 214},
}

// how the textures tile: repeats per meter (0: by the mesh's own texture
// coordinates, for sprites), and how shiny their surfaces are
local tiling = {
  bricks: 0.9, planks: 1, grass: 0.12, rough: 0.5, barrel: 1, water: 0.08,
  leaves: 0.7, white: 1, blob: 0, cloud: 0, spark: 0,
}
local shines = {water: 1.2, glass: 1, white: 0.25}

local shader = null
local locs = {}
local meshes = {}
local models = {}
local light = vec.normalize({x: 0.45, y: 0.75, z: 0.35})
local current_scale = -1
local current_shine = -1

// init(): the shader, the textures and the meshes; after init_window
func m.init(){
  if(web){
    shader = rl.load_shader_from_memory(vertex_100, fragment_100)
  } else {
    shader = rl.load_shader_from_memory(vertex_330, fragment_330)
  }
  locs.light = rl.get_shader_location(shader, "lightDir")
  locs.view = rl.get_shader_location(shader, "viewPos")
  locs.fog = rl.get_shader_location(shader, "fogColor")
  locs.scale = rl.get_shader_location(shader, "texScale")
  locs.shine = rl.get_shader_location(shader, "shine")
  rl.set_shader_value(shader, locs.light, light, rl.SHADER_UNIFORM_VEC3)
  local f = m.sky.fog
  rl.set_shader_value(
    shader, locs.fog, {f[0] / 255, f[1] / 255, f[2] / 255}, rl.SHADER_UNIFORM_VEC3
  )
  textures.all()
  meshes.cube = rl.gen_mesh_cube(1, 1, 1)
  meshes.sphere = rl.gen_mesh_sphere(1, 12, 16)
  meshes.cylinder = rl.gen_mesh_cylinder(1, 1, 18)
  meshes.cone = rl.gen_mesh_cone(1, 1, 14)
  meshes.plane = rl.gen_mesh_plane(1, 1, 1, 1)
}

func m.light(){
  return light
}

// model(shape, texture) -> the model of a mesh with a texture, under the
// shader, made the first time
func m.model(shape, texture){
  local key = concat(shape, "/", texture)
  local model = models[key]
  if(model == null){
    local mesh = meshes[shape]
    if(mesh == null){
      error("no mesh called ", shape)
    }
    model = rl.load_model_from_mesh(mesh)
    model.materials[0].shader = shader
    model.materials[0].maps[rl.MATERIAL_MAP_ALBEDO].texture = textures.get(
      texture
    )
    model.texture = texture
    models[key] = model
  }
  return model
}

// a model of a mesh of the game's own (the terrain), textured
func m.own_model(mesh, texture){
  local model = rl.load_model_from_mesh(mesh)
  model.materials[0].shader = shader
  model.materials[0].maps[rl.MATERIAL_MAP_ALBEDO].texture = textures.get(
    texture
  )
  model.texture = texture
  return model
}

func m.shader(){
  return shader
}

func m.unload(){
  for(let local e in entries(models)){
    // the meshes are shared: raylib would free each once per model
    e[1].mesh_count = 0
    rl.unload_model(e[1])
  }
  models = {}
  for(let local e in entries(meshes)){
    rl.unload_mesh(e[1])
  }
  meshes = {}
  textures.unload()
  rl.unload_shader(shader)
}

// ------------------------------------------------------------ the frame

// backdrop(camera, time): the sky behind everything (before begin): a
// gradient, the sun, clouds that slide with the camera's heading
func m.backdrop(camera, time){
  local w = rl.get_screen_width()
  local h = rl.get_screen_height()
  rl.clear_background(m.sky.horizon)
  local horizon = to_int(h * 0.62)
  rl.draw_rectangle_gradient_v(0, 0, w, horizon, m.sky.top, m.sky.horizon)
  local forward = vec.normalize(vec.sub(camera.target, camera.position))
  local yaw = vec.yaw_of(forward)
  local pitch = math.asin(vec.clamp(forward.y, -1, 1))
  // the sun: where the light comes from, on the screen
  local sun_yaw = vec.yaw_of(light)
  local dyaw = sun_yaw - yaw
  for(dyaw > math.pi){ dyaw = dyaw - 2 * math.pi }
  for(dyaw < -math.pi){ dyaw = dyaw + 2 * math.pi }
  local px = w / 2 + dyaw * w / 1.6
  local py = horizon * 0.5 - (math.asin(light.y) - pitch) * h / 1.4
  local cloud = textures.get("cloud")
  local spark = textures.get("spark")
  if(math.abs(dyaw) < 1.2){
    rl.draw_texture_pro(spark, {0, 0, 32, 32}, {px - 160, py - 160, 320, 320},
      {0, 0}, 0, {255, 250, 230, 90})
    rl.draw_texture_pro(spark, {0, 0, 32, 32}, {px - 40, py - 40, 80, 80},
      {0, 0}, 0, m.sky.sun)
  }
  // clouds, on a band above the horizon
  for(local i = 0; i < 9; i = i + 1){
    local a = (i * 0.7 + time * 0.004) % (2 * math.pi)
    local d = a - yaw
    for(d > math.pi){ d = d - 2 * math.pi }
    for(d < -math.pi){ d = d + 2 * math.pi }
    local cx = w / 2 + d * w / 1.6
    local cy = horizon * (0.32 + 0.3 * ((i * 7) % 5) / 5) + pitch * h / 1.4
    local size = 220 + ((i * 13) % 7) * 40
    if(cx > -size and cx < w + size){
      rl.draw_texture_pro(cloud, {0, 0, 256, 256},
        {cx - size / 2, cy - size * 0.25, size, size * 0.5}, {0, 0}, 0,
        {255, 255, 255, 200})
    }
  }
}

// begin(camera): the 3D view with the shader knowing where the camera is
func m.begin(camera){
  rl.set_shader_value(shader, locs.view, camera.position, rl.SHADER_UNIFORM_VEC3)
  current_scale = -1
  current_shine = -1
  rl.begin_mode_3d(camera)
}

func m.end(){
  rl.end_mode_3d()
}

// ------------------------------------------------------------ primitives

local origin = {0, 0, 0}

local func uniforms(texture){
  local s = tiling[texture] or 1
  if(s != current_scale){
    rl.set_shader_value(shader, locs.scale, s, rl.SHADER_UNIFORM_FLOAT)
    current_scale = s
  }
  local sh = shines[texture] or 0.12
  if(sh != current_shine){
    rl.set_shader_value(shader, locs.shine, sh, rl.SHADER_UNIFORM_FLOAT)
    current_shine = sh
  }
}

// draw(shape, matrix, color, texture?)
func m.draw(shape, matrix, color, texture){
  texture = texture or "white"
  local model = m.model(shape, texture)
  uniforms(texture)
  model.transform = matrix
  rl.draw_model(model, origin, 1, color)
}

// draw_model(model, matrix, color): a model made with own_model
func m.draw_model(model, matrix, color){
  uniforms(model.texture)
  model.transform = matrix
  rl.draw_model(model, origin, 1, color)
}

local identity = {x: 0, y: 0, z: 0, w: 1}

// box(p, q, size: Vec3, color, texture?): a box centered at p, turned by q
func m.box(p, q, size, color, texture){
  m.draw("cube", vec.matrix(p, q, size), color, texture)
}

// sphere(p, radius, color, texture?)
func m.sphere(p, radius, color, texture){
  m.draw("sphere", vec.matrix(p, identity, {x: radius, y: radius, z: radius}),
    color, texture)
}

// the generated cylinder and cone stand on y = 0: centered, their base
// moves down half the height
local func centered(p, q, height){
  return vec.add(p, vec.rotate(q, {x: 0, y: -height / 2, z: 0}))
}

// cylinder(p, q, radius, height, color, texture?): centered at p, its axis
// along q's y
func m.cylinder(p, q, radius, height, color, texture){
  m.draw("cylinder", vec.matrix(centered(p, q, height), q, {
    x: radius, y: height, z: radius
  }), color, texture)
}

// cone(p, q, radius, height, color, texture?): base at p, pointing along
// q's y
func m.cone(p, q, radius, height, color, texture){
  m.draw("cone", vec.matrix(p, q, {x: radius, y: height, z: radius}), color,
    texture)
}

// wheel(p, q, radius, width, color, texture?): a cylinder whose axis is q's x
local turn_x = vec.quat_axis({x: 0, y: 0, z: 1}, -math.pi / 2)
func m.wheel(p, q, radius, width, color, texture){
  local qw = vec.quat_multiply(q, turn_x)
  m.draw("cylinder", vec.matrix(centered(p, qw, width), qw, {
    x: radius, y: width, z: radius
  }), color, texture)
}

// plane(p, s, color, texture?): a flat square of side s at p, facing up
func m.plane(p, s, color, texture){
  m.draw("plane", vec.matrix(p, identity, {x: s, y: 1, z: s}), color, texture)
}

// ------------------------------------------------------------ the scene

func m.terrain(t){
  if(t.model == null or t.built != t.version){
    require("game/terrain").build(t)
  }
  m.draw_model(t.model, vec.matrix({x: 0, y: 0, z: 0}, identity, {
    x: 1, y: 1, z: 1
  }), rl.WHITE)
}

// water(t, time): two rippled planes sliding over each other, a little
// above and below the level; after everything opaque
func m.water(t, time){
  if(t.water == null){
    return
  }
  local size = t.half * 2 + 600
  local bob = math.sin(time * 0.7) * 0.03
  m.plane({x: time * 0.4, y: t.water + bob, z: time * 0.25}, size,
    {46, 128, 184, 150}, "water")
  m.plane({x: -time * 0.3, y: t.water - 0.3 - bob, z: time * 0.35}, size,
    {22, 76, 128, 200}, "water")
}

// shadow(p, radius, height): a soft dark blob on the ground under a thing
// at p (height over the ground: higher is fainter and wider)
func m.shadow(p, radius, ground){
  local h = vec.clamp(p.y - ground, 0, 12)
  local a = 110 * (1 - h / 12)
  if(a <= 2){
    return
  }
  local r = radius * (1 + h * 0.08)
  m.draw("plane", vec.matrix({x: p.x, y: ground + 0.04, z: p.z}, identity, {
    x: r * 2, y: 1, z: r * 2
  }), {0, 0, 0, to_int(a)}, "blob")
}

// parabola(points, color): the aim line, as dots that shrink along the
// way, with a ring where the shot lands
func m.parabola(points, color){
  local n = len(points)
  for(local i = 0; i < n; i = i + 1){
    local k = 1 - i / math.max(1, n) * 0.5
    m.sphere(points[i], 0.2 * k, color)
  }
  if(n > 0){
    local last = points[n - 1]
    m.sphere(last, 0.35, {255, 255, 255, 230})
    m.draw("cylinder", vec.matrix({x: last.x, y: last.y - 0.02, z: last.z}, identity, {
      x: 1.2, y: 0.04, z: 1.2
    }), {color[0], color[1], color[2], 120})
  }
}

return m
