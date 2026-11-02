// The synth of main.slang in 3D: the same sound, panel and controls, as a
// keyboard instrument on a desk. The panel's face (labels, scales, the
// oscilloscope) is drawn by panel.slang into a texture every frame, just as
// the flat version draws it on the screen; knobs, rocker switches, wheels
// and keys are meshes on top of it, lit by a small shader, in a case of
// walnut made by wood.slang.
//
//   make synth3d      (or: cd examples/synth && slang run main3d.slang)
//
// Playing it is as in main.slang: drag knobs up and down (shift: finely),
// the mouse wheel turns them too, double click resets, click switches,
// click and glide over the keys, Z..M and Q..I on the computer keyboard.
// Drag with the right button to look around, the mouse wheel off the
// controls moves closer.
//
// The mouse picks by rays: one that meets the panel becomes a position on
// the face, where panel.slang's 2D hit tests decide; keys and wheels are
// boxes the ray may enter.
local rl = require("raylib")
local buffer = require("slang/buffer")
local math = require("slang/math")
local params = require("params")
local panel = require("panel")
local wood = require("wood")

local W = 1280
local H = 760
local colors = panel.colors
local controls = panel.controls

// ------------------------------------------------------------ the shader

// the vertex shader: the fragment's position in the world and in the
// object's own space (world units, for the wood)
local vertex_shader = """#version 330
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

// the fragment shader: textured by the mesh's coordinates (the face), solid
// walnut (woodSeed > 0, see wood.slang, its grain along the object's axis
// grainAxis: 0 x, 1 y, 2 z) or plain; lit by a sun, a sky tint from above
// and a highlight
local fragment_shader = concat("""#version 330
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
uniform float texScale;
uniform float shine;
uniform float grainAxis;
uniform float woodSeed;
out vec4 finalColor;
""", wood.glsl, """
void main(){
  vec4 tex = vec4(1.0);
  if(woodSeed > 0.0){
    vec3 p = fragObject;
    vec3 q = grainAxis < 0.5 ? p : (grainAxis < 1.5 ? p.yxz : p.zyx);
    tex = vec4(woodColor(q, woodSeed), 1.0);
  } else if(texScale == 0.0){
    tex = texture(texture0, fragTexCoord);
  }
  vec3 n = normalize(fragNormal);
  float d = max(dot(n, lightDir), 0.0);
  float hemi = 0.5 + 0.5 * n.y;
  vec3 light = vec3(0.30, 0.31, 0.36) * hemi + vec3(0.20) + vec3(0.85, 0.80, 0.72) * d;
  vec3 v = normalize(viewPos - fragPosition);
  vec3 h = normalize(lightDir + v);
  float spec = pow(max(dot(n, h), 0.0), 48.0) * shine;
  vec3 c = fragColor.rgb * colDiffuse.rgb * tex.rgb * light + vec3(spec);
  finalColor = vec4(c, fragColor.a * colDiffuse.a * tex.a);
}
""")

local shader = null
local locs = {}
local light = rl.vector3_normalize({-0.35, 0.85, 0.55})

// ------------------------------------------------------------ matrices

local func mul(...ms){
  local m = ms[0]
  for(local i = 1; i < len(ms); i = i + 1){
    m = rl.matrix_multiply(m, ms[i])
  }
  return m
}

local func T(x, y, z){
  return rl.matrix_translate(x, y, z)
}

local func S(x, y, z){
  return rl.matrix_scale(x, y, z)
}

local RX90 = rl.matrix_rotate_x(math.pi / 2)

// ------------------------------------------------------------ the scene's frame

// world units: 100 window pixels each, x centered on the window's middle
local SCALE = 0.01
local CENTER = panel.W / 2

// the face: the panel and the strip, as panel.draw_face draws them
local FACE_X = 40
local FACE_Y = params.top
local FACE_W = panel.W - 80
local FACE_H = panel.STRIP_Y + panel.STRIP_H - params.top
// the panel leans back from upright by this much, its lower edge at HINGE
local TILT = 0.62
local HINGE = {x: 0.0, y: 0.95, z: -0.35}

// the face's frame: x right and y up in face pixels (a face y of py is
// -py), z out of the face
local panel_matrix = mul(
  T(-CENTER, FACE_Y + FACE_H, 0), S(SCALE, SCALE, SCALE),
  rl.matrix_rotate_x(-TILT), T(HINGE.x, HINGE.y, HINGE.z)
)

// a face position (window pixels) and a height above the face, in the world
local func on_face(px, py, z){
  return rl.vector3_transform({px, -py, z}, panel_matrix)
}

// the keyboard, in world units
local KEY_TOP = 0.58
local KEY_BACK = 0.15
local WHITE_LEN = 2.55
local BLACK_LEN = 1.6
local WHITE_THICK = 0.24
local CASE_FRONT = 2.95

local func key_x(px){
  return (px - CENTER) * SCALE
}

// ------------------------------------------------------------ meshes and models

local models = {}
local textures = {}
// buffers a mesh of ours points into stay referenced as long as it is used
local keep = {}

local func shaded(mesh, texture){
  local model = rl.load_model_from_mesh(mesh)
  model.materials[0].shader = shader
  if(texture != null){
    model.materials[0].maps[rl.MATERIAL_MAP_ALBEDO].texture = texture
  }
  return model
}

// the face: a quad in face pixels whose texture coordinates read the
// render texture upside down (OpenGL keeps those bottom up)
local func face_mesh(){
  local vertices = buffer.new("float", 12)
  local texcoords = buffer.new("float", 8)
  local normals = buffer.new("float", 12)
  local indices = buffer.new("unsigned short", 6)
  local x0 = FACE_X
  local x1 = FACE_X + FACE_W
  local y0 = FACE_Y
  local y1 = FACE_Y + FACE_H
  vertices:set({x0, -y0, 0.0, x1, -y0, 0.0, x1, -y1, 0.0, x0, -y1, 0.0}, 0)
  texcoords:set({0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0}, 0)
  normals:set({0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1}, 0)
  indices:set({0, 2, 1, 0, 3, 2}, 0)
  append(keep, {vertices, texcoords, normals, indices})
  local mesh = {
    vertex_count: 4,
    triangle_count: 2,
    vertices: vertices,
    texcoords: texcoords,
    normals: normals,
    indices: indices,
  }
  rl.upload_mesh(mesh, false)
  return mesh
}

// the render texture the face is drawn into, twice the window's pixels
local FACE_SCALE = 2
local face_target = null

local func setup(){
  shader = rl.load_shader_from_memory(vertex_shader, fragment_shader)
  for(let local name in values({"lightDir", "viewPos", "texScale", "shine", "grainAxis", "woodSeed"})){
    locs[name] = rl.get_shader_location(shader, name)
  }
  rl.set_shader_value(shader, locs.lightDir, light, rl.SHADER_UNIFORM_VEC3)
  face_target = rl.load_render_texture(FACE_W * FACE_SCALE, FACE_H * FACE_SCALE)
  models.cube = shaded(rl.gen_mesh_cube(1, 1, 1))
  models.cylinder = shaded(rl.gen_mesh_cylinder(1, 1, 40))
  models.face = shaded(face_mesh(), face_target.texture)
}

local current = {scale: -1.0, shine: -1.0, axis: -1.0, seed: -1.0}

local func uniform(name, v){
  if(current[name] != v){
    current[name] = v
    local loc = {scale: locs.texScale, shine: locs.shine, axis: locs.grainAxis, seed: locs.woodSeed}[name]
    rl.set_shader_value(shader, loc, v, rl.SHADER_UNIFORM_FLOAT)
  }
}

local origin = {0, 0, 0}

// draw(model, matrix, color, shine, tex_scale?, wood?): wood is {seed,
// axis} for a board of walnut
local func draw(model, matrix, color, shine, tex_scale, wood_board){
  uniform("scale", tex_scale or 1.0)
  uniform("shine", shine)
  if(wood_board != null){
    uniform("seed", wood_board.seed)
    uniform("axis", wood_board.axis)
  } else {
    uniform("seed", 0.0)
  }
  model.transform = matrix
  rl.draw_model(model, origin, 1, color)
}

// a box from corner a to corner b (world, unturned)
local func box(a, b, model, color, shine, tex_scale, wood_board){
  draw(model, mul(
    S(b.x - a.x, b.y - a.y, b.z - a.z),
    T((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
  ), color, shine, tex_scale, wood_board)
}

// a box in face pixels: x0..x1, y0..y1 (face y, down), z0..z1 off the face
local func face_box(x0, x1, y0, y1, z0, z1, model, color, shine, tex_scale, wood_board){
  draw(model, mul(
    S(x1 - x0, y1 - y0, z1 - z0),
    T((x0 + x1) / 2, -(y0 + y1) / 2, (z0 + z1) / 2),
    panel_matrix
  ), color, shine, tex_scale, wood_board)
}

// ------------------------------------------------------------ the case

local WHITE = {255, 255, 255}
local WOOD_SHINE = 0.22

// a board: its seed (which part of the log) and its grain's axis
local func board(seed, axis){
  return {seed: seed, axis: axis}
}
local ALONG_X = 0.0
local ALONG_Y = 1.0
local ALONG_Z = 2.0

// No two parts that overlap share a face's plane (the depth buffer could
// not tell which is in front, and the joint would flicker): the base ends
// inside the cheeks, the panel's cheeks are set in a little from the lower
// ones, the rail and the body stop short of the cheeks' faces.
local func draw_case(){
  local m = models.cube
  // the base under the keys and its front, grain along the width
  box({x: -5.8, y: 0.0, z: -0.6}, {x: 5.8, y: 0.34, z: CASE_FRONT}, m, WHITE, WOOD_SHINE, 1.0, board(1, ALONG_X))
  box({x: -5.6, y: 0.34, z: 2.82}, {x: 5.6, y: 0.44, z: CASE_FRONT}, m, WHITE, WOOD_SHINE, 1.0, board(2, ALONG_X))
  // the cheeks at both ends, grain front to back, a little proud of the base
  local seeds = {3, 4}
  local sides = {-1.0, 1.0}
  for(local k = 0; k < 2; k = k + 1){
    local x0 = sides[k] * 5.6
    local x1 = sides[k] * 6.05
    box({x: math.min(x0, x1), y: 0.0, z: -0.9}, {x: math.max(x0, x1), y: 1.15, z: CASE_FRONT + 0.03}, m, WHITE, WOOD_SHINE, 1.0, board(seeds[k], ALONG_Z))
  }
  // the panel's cheeks, along its sides (its y), set in 3 pixels from the
  // lower cheeks' faces; the top rail between them, below their top
  face_box(-2, FACE_X - 3, FACE_Y - 18, FACE_Y + FACE_H + 60, -60, 14, m, WHITE, WOOD_SHINE, 1.0, board(5, ALONG_Y))
  face_box(FACE_X + FACE_W + 3, panel.W + 2, FACE_Y - 18, FACE_Y + FACE_H + 60, -60, 14, m, WHITE, WOOD_SHINE, 1.0, board(6, ALONG_Y))
  face_box(FACE_X - 3, FACE_X + FACE_W + 3, FACE_Y - 15, FACE_Y, -57, 8, m, WHITE, WOOD_SHINE, 1.0, board(7, ALONG_X))
  // the body behind the face (to the cheeks' inner faces), the face
  face_box(FACE_X - 3, FACE_X + FACE_W + 3, FACE_Y, FACE_Y + FACE_H + 60, -57, -1, models.cube, {20, 20, 22}, 0.05)
  draw(models.face, panel_matrix, WHITE, 0.08, 0.0)
  // red felt behind the keys, the black plate the wheels sit in
  box({x: key_x(panel.KEYS_X) - 0.02, y: 0.34, z: -0.05}, {x: 5.6, y: KEY_TOP + 0.08, z: KEY_BACK}, models.cube, colors.felt, 0.02)
  box({x: -5.6, y: 0.34, z: -0.05}, {x: key_x(panel.KEYS_X) - 0.04, y: 0.4, z: 2.82}, models.cube, {16, 16, 17}, 0.15)
}

// ------------------------------------------------------------ knobs and switches

// how far each rocker leans (it moves to the side it is pressed to)
local rocker = {}

local func draw_knob(c, v){
  local r = panel.knob_radius(c)
  local angle = 0.0
  if(c.kind == "steps"){
    angle = panel.step_angle(to_int(v), len(c.labels))
  } else {
    angle = panel.knob_angle(v)
  }
  // turned about the face's normal, clockwise as on the face
  local place = mul(rl.matrix_rotate_z(-angle), T(c.x, -c.y, 0), panel_matrix)
  // the skirt, the cap, a lighter top, the pointer
  draw(models.cylinder, mul(S(r + 6.0, 4.0, r + 6.0), RX90, place), {52, 52, 55}, 0.3)
  draw(models.cylinder, mul(S(r, 17.0, r), RX90, place), {16, 16, 17}, 0.2)
  draw(models.cylinder, mul(S(r - 2.5, 1.0, r - 2.5), RX90, T(0, 0, 17.0), place), {30, 30, 32}, 0.12)
  draw(models.cube, mul(S(3.0, r * 0.72, 1.6), T(0, r * 0.5, 18.2), place), colors.pointer, 0.2)
}

local func draw_switch(c, v){
  local target = -0.28
  if(v > 0.5){
    target = 0.28
  }
  local a = rocker[c.id] or target
  a = a + (target - a) * 0.35
  rocker[c.id] = a
  local sc = panel.switch_colors(c)
  local place = mul(T(c.x, -c.y, 0), panel_matrix)
  draw(models.cube, mul(S(26, 36, 4), T(0, 0, 2), place), {10, 10, 10}, 0.1)
  // the rocker: two halves turned together about the switch's middle; the
  // half pressed in is the lit one
  local turn = mul(rl.matrix_rotate_x(a), T(0, 0, 7), place)
  local top = sc[1]
  local bottom = sc[0]
  if(v > 0.5){
    top = sc[0]
    bottom = sc[1]
  }
  draw(models.cube, mul(S(20, 15, 8), T(0, 7.5, 0), turn), top, 0.15)
  draw(models.cube, mul(S(20, 15, 8), T(0, -7.5, 0), turn), bottom, 0.15)
}

local func draw_controls(){
  for(local i = 0; i < params.count; i = i + 1){
    local c = params.list[i]
    if(c.kind == "knob" or c.kind == "steps"){
      draw_knob(c, controls[i])
    } else if(c.kind == "switch"){
      draw_switch(c, controls[i])
    }
  }
}

// ------------------------------------------------------------ keys and wheels

// how far down each key is (0..1), following what sounds
local press = {}

// a key's box at rest: {min, max, hinge y}
local func key_box(k){
  if(k.black){
    local x = key_x(k.x + k.w / 2)
    local w = k.w * SCALE / 2
    return {
      min: {x: x - w, y: KEY_TOP - 0.02, z: KEY_BACK},
      max: {x: x + w, y: KEY_TOP + 0.2, z: KEY_BACK + BLACK_LEN},
    }
  }
  local x0 = key_x(k.x) + 0.012
  local x1 = key_x(k.x + k.w) - 0.012
  return {
    min: {x: x0, y: KEY_TOP - WHITE_THICK, z: KEY_BACK},
    max: {x: x1, y: KEY_TOP, z: KEY_BACK + WHITE_LEN},
  }
}

local key_boxes = {}
for(let local k in values(panel.keys)){
  append(key_boxes, key_box(k))
}

local func draw_keys(){
  for(local i = 0; i < len(panel.keys); i = i + 1){
    local k = panel.keys[i]
    local b = key_boxes[i]
    local target = 0.0
    if(panel.key_down(k.note)){
      target = 1.0
    }
    local p = press[k.note] or 0.0
    p = p + (target - p) * 0.45
    press[k.note] = p
    // a key turns down about its back end
    local angle = p * 0.075
    if(k.black){
      angle = p * 0.1
    }
    local hinge_y = b.min.y
    local size = {x: b.max.x - b.min.x, y: b.max.y - b.min.y, z: b.max.z - b.min.z}
    local center = {x: (b.min.x + b.max.x) / 2, y: (b.min.y + b.max.y) / 2, z: (b.min.z + b.max.z) / 2}
    local m = mul(
      S(size.x, size.y, size.z),
      T(0, center.y - hinge_y, center.z - KEY_BACK),
      rl.matrix_rotate_x(angle),
      T(center.x, hinge_y, KEY_BACK)
    )
    if(k.black){
      draw(models.cube, m, {24, 24, 26}, 0.9)
    } else {
      draw(models.cube, m, {238, 234, 222}, 0.35)
    }
  }
}

// the wheels: in the plate left of the keys, turning about x
local WHEEL_R = 0.5
local WHEEL_WIDTH = 0.24
local WHEEL_Z = 1.45
local WHEEL_Y = 0.12

local func wheel_x(wh){
  return key_x(wh.x + panel.WHEEL_W / 2) + 0.02
}

local func wheel_box(wh){
  local x = wheel_x(wh)
  return {
    min: {x: x - WHEEL_WIDTH, y: 0.3, z: WHEEL_Z - WHEEL_R},
    max: {x: x + WHEEL_WIDTH, y: WHEEL_Y + WHEEL_R + 0.05, z: WHEEL_Z + WHEEL_R},
  }
}

local func draw_wheels(){
  for(let local wh in values(panel.wheels)){
    local v = controls[wh.index]
    local x = wheel_x(wh)
    // the slot, then the wheel: a cylinder on its side, turned by the value
    box({x: x - WHEEL_WIDTH / 2 - 0.05, y: 0.4, z: WHEEL_Z - 0.62},
      {x: x + WHEEL_WIDTH / 2 + 0.05, y: 0.42, z: WHEEL_Z + 0.62},
      models.cube, {4, 4, 4}, 0.0)
    local turn = mul(rl.matrix_rotate_x((0.5 - v) * 1.4), T(x, WHEEL_Y, WHEEL_Z))
    local side = mul(rl.matrix_rotate_z(math.pi / 2), T(WHEEL_WIDTH / 2, 0, 0))
    draw(models.cylinder, mul(S(WHEEL_R, WHEEL_WIDTH, WHEEL_R), side, turn), {30, 30, 32}, 0.4)
    // the white mark on top of its rim
    draw(models.cube, mul(S(WHEEL_WIDTH + 0.01, 0.03, 0.06), T(0, WHEEL_R, 0), turn), colors.pointer, 0.5)
  }
}

// ------------------------------------------------------------ picking

local func sub(a, b){
  return {x: a.x - b.x, y: a.y - b.y, z: a.z - b.z}
}

local func dot(a, b){
  return a.x * b.x + a.y * b.y + a.z * b.z
}

// where a ray meets the plane z = height above the face: the face
// position {x, y} (window pixels), or null
local func face_point(ray, height){
  local o = on_face(0, 0, height)
  local u = sub(on_face(1, 0, height), o)
  local v = sub(on_face(0, 1, height), o)
  local n = rl.vector3_cross_product(u, v)
  local denom = dot(ray.direction, n)
  if(math.abs(denom) < 0.000001){
    return null
  }
  local t = dot(sub(o, ray.position), n) / denom
  if(t < 0){
    return null
  }
  local hit = {
    x: ray.position.x + ray.direction.x * t,
    y: ray.position.y + ray.direction.y * t,
    z: ray.position.z + ray.direction.z * t,
  }
  local d = sub(hit, o)
  return {x: dot(d, u) / dot(u, u), y: dot(d, v) / dot(v, v)}
}

// the distance along the ray into a box, or null (slabs)
local func ray_box(ray, b){
  local near = -1.0e30
  local far = 1.0e30
  for(let local axis in values({"x", "y", "z"})){
    local o = ray.position[axis]
    local d = ray.direction[axis]
    local lo = b.min[axis]
    local hi = b.max[axis]
    if(math.abs(d) < 0.0000001){
      if(o < lo or o > hi){
        return null
      }
    } else {
      local t1 = (lo - o) / d
      local t2 = (hi - o) / d
      if(t1 > t2){
        local s = t1
        t1 = t2
        t2 = s
      }
      if(t1 > near){
        near = t1
      }
      if(t2 < far){
        far = t2
      }
      if(near > far or far < 0){
        return null
      }
    }
  }
  return near
}

// the key under the ray: the nearest box it enters
local func key_hit(ray){
  local best = null
  local best_t = 1.0e30
  for(local i = 0; i < len(panel.keys); i = i + 1){
    local t = ray_box(ray, key_boxes[i])
    if(t != null and t < best_t){
      best_t = t
      best = panel.keys[i].note
    }
  }
  return best
}

// the control under the ray: on the face (a little above it, where the
// knobs' tops are) or a wheel; its index or null
local func control_hit(ray){
  local p = face_point(ray, 12.0)
  if(p != null){
    local i = panel.control_at(p.x, p.y)
    if(i != null){
      return i
    }
  }
  // the nearest wheel the ray enters
  local best = null
  local best_t = 1.0e30
  for(let local wh in values(panel.wheels)){
    local t = ray_box(ray, wheel_box(wh))
    if(t != null and t < best_t){
      best_t = t
      best = wh.index
    }
  }
  return best
}

// ------------------------------------------------------------ the camera

local view = {yaw: 0.0, pitch: 0.55, distance: 14.0}
local target = {x: 0.0, y: 1.7, z: 0.4}
// SYNTH_VIEW=yaw,pitch,distance[,x,y,z]: where the camera starts (for
// screenshots)
local view_env = require("slang/os").getenv("SYNTH_VIEW")
if(view_env != null){
  local str = require("slang/string")
  local parts = str.split(view_env, ",")
  view.yaw = str.to_number(parts[0])
  view.pitch = str.to_number(parts[1])
  view.distance = str.to_number(parts[2])
  if(len(parts) >= 6){
    target = {x: str.to_number(parts[3]), y: str.to_number(parts[4]), z: str.to_number(parts[5])}
  }
}
local camera = {
  position: {0, 0, 0}, target: target, up: {0, 1, 0}, fovy: 40,
  projection: rl.CAMERA_PERSPECTIVE,
}

local func place_camera(){
  local cp = math.cos(view.pitch)
  camera.position = {
    x: target.x + math.sin(view.yaw) * cp * view.distance,
    y: target.y + math.sin(view.pitch) * view.distance,
    z: target.z + math.cos(view.yaw) * cp * view.distance,
  }
}

local func clamp(v, lo, hi){
  if(v < lo){
    return lo
  }
  if(v > hi){
    return hi
  }
  return v
}

// ------------------------------------------------------------ input

local func handle_mouse(){
  local m = rl.get_mouse_position()
  local ray = rl.get_screen_to_world_ray(m, camera)
  local left = rl.MOUSE_BUTTON_LEFT
  if(rl.is_mouse_button_pressed(left)){
    local i = control_hit(ray)
    if(i != null){
      panel.press(i, m.y)
    } else {
      local n = key_hit(ray)
      if(n != null){
        panel.press_key(n)
      }
    }
  }
  if(rl.is_mouse_button_down(left)){
    panel.drag(m.y)
    if(panel.dragging() == null){
      panel.slide_key(key_hit(ray))
    }
  }
  if(rl.is_mouse_button_released(left)){
    panel.release()
  }
  local w = rl.get_mouse_wheel_move()
  if(w != 0.0){
    local i = control_hit(ray)
    if(i != null){
      panel.scroll(i, w)
    } else {
      view.distance = clamp(view.distance - w * 0.6, 5.0, 22.0)
    }
  }
  // the right button looks around
  if(rl.is_mouse_button_down(rl.MOUSE_BUTTON_RIGHT)){
    local d = rl.get_mouse_delta()
    view.yaw = clamp(view.yaw - d.x * 0.005, -1.3, 1.3)
    view.pitch = clamp(view.pitch + d.y * 0.004, 0.1, 1.35)
  }
  panel.spring()
}

// ------------------------------------------------------------ the frame

// the face into its texture: the flat panel's own drawing, scaled, without
// the knobs' caps and the rockers
local face_camera = {
  offset: {-FACE_X * FACE_SCALE, -FACE_Y * FACE_SCALE}, target: {0, 0},
  rotation: 0, zoom: FACE_SCALE,
}

local func draw_face(){
  rl.begin_texture_mode(face_target)
  rl.clear_background(colors.panel)
  rl.begin_mode_2d(face_camera)
  panel.draw_face(false)
  rl.end_mode_2d()
  rl.end_texture_mode()
  // mipmaps, so the face stays clean at a slant
  rl.gen_texture_mipmaps(face_target.texture)
  rl.set_texture_filter(face_target.texture, rl.TEXTURE_FILTER_TRILINEAR)
}

// (clearing also clears the depth buffer, which the 3D view needs)
local func draw_backdrop(){
  rl.clear_background({14, 13, 15})
  rl.draw_rectangle_gradient_v(0, 0, W, H, {44, 42, 46}, {14, 13, 15})
}

local func draw_scene(){
  rl.set_shader_value(shader, locs.viewPos, camera.position, rl.SHADER_UNIFORM_VEC3)
  current = {scale: -1.0, shine: -1.0, axis: -1.0, seed: -1.0}
  rl.begin_mode_3d(camera)
  // the desk, and a shadow under the synth
  box({x: -80, y: -0.2, z: -60}, {x: 80, y: -0.01, z: 60}, models.cube, {36, 33, 31}, 0.03)
  box({x: -6.4, y: -0.01, z: -1.4}, {x: 6.4, y: 0.0, z: 3.35}, models.cube, {12, 11, 11}, 0.0)
  draw_case()
  draw_controls()
  draw_keys()
  draw_wheels()
  rl.end_mode_3d()
}

local func draw_hud(){
  panel.text("right drag: look around    wheel: closer    arrows: octave    space: all notes off",
    16, H - 26, 10, colors.dim)
  panel.text(concat("OCTAVE C", to_int(panel.octave / 12) - 1), W - 110, H - 26, 10, colors.dim)
}

rl.set_config_flags(rl.FLAG_MSAA_4X_HINT)
rl.init_window(W, H, "slang mini 3D")
rl.set_target_fps(60)
panel.load_font()
setup()
panel.start()
if(panel.autoplay){
  panel.play_song()
}

// SYNTH_PICKTEST=1: every control, key and wheel is projected to the
// screen and picked back from there; the misses are printed
local func pick_test(){
  place_camera()
  local misses = 0
  local func check(what, expected, got){
    if(got != expected){
      misses = misses + 1
      print("pick test: ", what, " gave ", got, "\n")
    }
  }
  for(local i = 0; i < params.count; i = i + 1){
    local c = params.list[i]
    if(c.kind == "knob" or c.kind == "steps" or c.kind == "switch"){
      local at = rl.get_world_to_screen(on_face(c.x, c.y, 12.0), camera)
      check(c.id, i, control_hit(rl.get_screen_to_world_ray(at, camera)))
    }
  }
  for(local i = 0; i < len(panel.keys); i = i + 1){
    local b = key_boxes[i]
    local top = {x: (b.min.x + b.max.x) / 2, y: b.max.y, z: b.max.z - 0.2}
    local at = rl.get_world_to_screen(top, camera)
    check(concat("key ", panel.keys[i].note), panel.keys[i].note, key_hit(rl.get_screen_to_world_ray(at, camera)))
  }
  for(let local wh in values(panel.wheels)){
    local at = rl.get_world_to_screen({x: wheel_x(wh), y: WHEEL_Y + WHEEL_R, z: WHEEL_Z}, camera)
    check("wheel", wh.index, control_hit(rl.get_screen_to_world_ray(at, camera)))
  }
  print("pick test: ", misses, " misses\n")
}
if(require("slang/os").getenv("SYNTH_PICKTEST") != null){
  pick_test()
}

local frame = 0
panel.mark_start()
for(not rl.window_should_close() and frame != panel.max_frames){
  place_camera()
  handle_mouse()
  panel.handle_keys()
  panel.demo(frame)
  panel.update_stats()
  draw_face()
  rl.begin_drawing()
  draw_backdrop()
  draw_scene()
  draw_hud()
  rl.end_drawing()
  frame = frame + 1
  if(panel.screenshot != null and frame == panel.max_frames){
    rl.take_screenshot(panel.screenshot)
  }
}

rl.unload_render_texture(face_target)
rl.unload_shader(shader)
panel.mark_end()
panel.unload_font()
rl.close_window()
panel.finish(frame)
