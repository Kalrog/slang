// slang six in 3D: the FM synth of main.slang as a keyboard on a desk, with
// the panel hardware of its time: a backlit display, eight encoders that
// turn what the display shows, buttons for the page and the operator, and
// 32 patch buttons. The sound is the same (app.slang, engine.slang); the
// face is drawn by hardware.slang into a texture every frame, and the
// knobs, buttons, LEDs, keys and wheels are meshes on it, in a walnut case
// (wood.slang).
//
//   make fm3d         (or: cd examples/fm && slang run main3d.slang)
//
// Choose a page (OSC, ENV, SCALE, VOICE, LFO, P.EG) and an operator with
// the buttons; the display shows its eight values over the encoders: drag
// one up or down (shift: one step at a time) or turn the mouse wheel over
// it; a double click puts it back as the bank has it. Shift and an
// operator button turn the operator on or off. A patch button chooses the
// patch (again: undoes the edits). Play the keys with the mouse (nearer
// the front is louder) or the computer keyboard, as in main.slang. Drag
// with the right button to look around, the mouse wheel off the controls
// moves closer.
//
// FM_VIEW=yaw,pitch,distance[,x,y,z] places the camera (for screenshots);
// FM_PAGE=n starts on page n (1..6); FM_FRAMES, FM_DEMO, FM_PATCH and
// FM_SCREENSHOT work as in main.slang.
local rl = require("raylib")
local math = require("slang/math")
local os = require("slang/os")
local app = require("app")
local hw = require("hardware")
local gfx = require("gfx")
local wood = require("wood")
local engine = require("engine")

local W = 1280
local H = 760

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
out vec2 fragTexCoord;
void main(){
  fragTexCoord = vertexTexCoord;
  vec3 scale = vec3(length(matModel[0].xyz), length(matModel[1].xyz), length(matModel[2].xyz));
  fragObject = vertexPosition * scale;
  fragPosition = vec3(matModel * vec4(vertexPosition, 1.0));
  fragNormal = normalize(vec3(matNormal * vec4(vertexNormal, 0.0)));
  fragColor = vertexColor;
  gl_Position = mvp * vec4(vertexPosition, 1.0);
}
"""

// the fragment shader: textured by the mesh's coordinates (the face), solid
// walnut (woodSeed > 0, grain along grainAxis: 0 x, 1 y, 2 z) or plain; lit
// by a sun, a sky tint from above and a highlight; glow adds the color
// unlit (LEDs, the display)
local fragment_shader = concat("""#version 330
in vec3 fragPosition;
in vec3 fragNormal;
in vec4 fragColor;
in vec3 fragObject;
in vec2 fragTexCoord;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec3 lightDir;
uniform vec3 viewPos;
uniform float texScale;
uniform float shine;
uniform float grainAxis;
uniform float woodSeed;
uniform float glow;
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
  vec3 base = fragColor.rgb * colDiffuse.rgb * tex.rgb;
  vec3 c = mix(base * light, base, glow) + vec3(spec);
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

// world units: 100 face pixels each, x centered on the face's middle
local SCALE = 0.01
local CENTER = hw.W / 2

local FACE_X = 40
local FACE_Y = hw.FACE_TOP
local FACE_W = 1120
local FACE_H = hw.FACE_BOTTOM - hw.FACE_TOP
// the panel leans back from upright by this much, its lower edge at HINGE
local TILT = 0.62
local HINGE = {x: 0.0, y: 0.95, z: -0.35}

// the face's frame: x right and y up in face pixels (a face y of py is
// -py), z out of the face
local panel_matrix = mul(
  T(-CENTER, FACE_Y + FACE_H, 0), S(SCALE, SCALE, SCALE),
  rl.matrix_rotate_x(-TILT), T(HINGE.x, HINGE.y, HINGE.z)
)

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
  local x0 = FACE_X
  local x1 = FACE_X + FACE_W
  local y0 = FACE_Y
  local y1 = FACE_Y + FACE_H
  return rl.mesh({
    vertices: {x0, -y0, 0.0, x1, -y0, 0.0, x1, -y1, 0.0, x0, -y1, 0.0},
    texcoords: {0.0, 1.0, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0},
    normals: {0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1},
    indices: {0, 2, 1, 0, 3, 2},
  })
}

// the render texture the face is drawn into, twice its pixels
local FACE_SCALE = 2
local face_target = null

local func setup(){
  shader = rl.load_shader_from_memory(vertex_shader, fragment_shader)
  for(let local name in values({"lightDir", "viewPos", "texScale", "shine", "grainAxis", "woodSeed", "glow"})){
    locs[name] = rl.get_shader_location(shader, name)
  }
  rl.set_shader_value(shader, locs.lightDir, light, rl.SHADER_UNIFORM_VEC3)
  face_target = rl.load_render_texture(FACE_W * FACE_SCALE, FACE_H * FACE_SCALE)
  models.cube = shaded(rl.gen_mesh_cube(1, 1, 1))
  models.cylinder = shaded(rl.gen_mesh_cylinder(1, 1, 40))
  models.face = shaded(face_mesh(), face_target.texture)
}

local current = {scale: -1.0, shine: -1.0, axis: -1.0, seed: -1.0, glow: -1.0}

local func uniform(name, v){
  if(current[name] != v){
    current[name] = v
    local loc = {scale: locs.texScale, shine: locs.shine, axis: locs.grainAxis, seed: locs.woodSeed, glow: locs.glow}[name]
    rl.set_shader_value(shader, loc, v, rl.SHADER_UNIFORM_FLOAT)
  }
}

local origin = {0, 0, 0}

// draw(model, matrix, color, shine, tex_scale?, wood?, glow?): wood is
// {seed, axis} for a board of walnut; glow 0..1 is how unlit it is
local func draw(model, matrix, color, shine, tex_scale, wood_board, glow){
  uniform("scale", tex_scale or 1.0)
  uniform("shine", shine)
  uniform("glow", glow or 0.0)
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
local func face_box(x0, x1, y0, y1, z0, z1, model, color, shine, tex_scale, wood_board, glow){
  draw(model, mul(
    S(x1 - x0, y1 - y0, z1 - z0),
    T((x0 + x1) / 2, -(y0 + y1) / 2, (z0 + z1) / 2),
    panel_matrix
  ), color, shine, tex_scale, wood_board, glow)
}

// ------------------------------------------------------------ the case

local WHITE = {255, 255, 255}
local WOOD_SHINE = 0.22

local func board(seed, axis){
  return {seed: seed, axis: axis}
}
local ALONG_X = 0.0
local ALONG_Y = 1.0
local ALONG_Z = 2.0

// No two parts that overlap share a face's plane (the depth buffer could
// not tell which is in front, and the joint would flicker).
local func draw_case(){
  local m = models.cube
  // the base under the keys and its front, grain along the width
  box({x: -5.8, y: 0.0, z: -0.6}, {x: 5.8, y: 0.34, z: CASE_FRONT}, m, WHITE, WOOD_SHINE, 1.0, board(11, ALONG_X))
  box({x: -5.6, y: 0.34, z: 2.82}, {x: 5.6, y: 0.44, z: CASE_FRONT}, m, WHITE, WOOD_SHINE, 1.0, board(12, ALONG_X))
  // the cheeks at both ends, a little proud of the base
  local seeds = {13, 14}
  local sides = {-1.0, 1.0}
  for(local k = 0; k < 2; k = k + 1){
    local x0 = sides[k] * 5.6
    local x1 = sides[k] * 6.05
    box({x: math.min(x0, x1), y: 0.0, z: -0.9}, {x: math.max(x0, x1), y: 1.15, z: CASE_FRONT + 0.03}, m, WHITE, WOOD_SHINE, 1.0, board(seeds[k], ALONG_Z))
  }
  // the panel's cheeks and the top rail
  face_box(-2, FACE_X - 3, FACE_Y - 18, FACE_Y + FACE_H + 60, -60, 14, m, WHITE, WOOD_SHINE, 1.0, board(15, ALONG_Y))
  face_box(FACE_X + FACE_W + 3, hw.W + 2, FACE_Y - 18, FACE_Y + FACE_H + 60, -60, 14, m, WHITE, WOOD_SHINE, 1.0, board(16, ALONG_Y))
  face_box(FACE_X - 3, FACE_X + FACE_W + 3, FACE_Y - 15, FACE_Y, -57, 8, m, WHITE, WOOD_SHINE, 1.0, board(17, ALONG_X))
  // the body behind the face, the face
  face_box(FACE_X - 3, FACE_X + FACE_W + 3, FACE_Y, FACE_Y + FACE_H + 60, -57, -1, models.cube, {20, 20, 22}, 0.05)
  draw(models.face, panel_matrix, WHITE, 0.08, 0.0)
  // the display's glass: a dark pane over it, a little in front, lit
  // from inside (glow), so that it reads as a screen
  local l = hw.LCD
  face_box(l.x - 8, l.x + l.w + 8, l.y - 8, l.y - 4, 0, 3, models.cube, {12, 12, 12}, 0.1)
  face_box(l.x - 8, l.x + l.w + 8, l.y + l.h + 4, l.y + l.h + 8, 0, 3, models.cube, {12, 12, 12}, 0.1)
  face_box(l.x - 8, l.x - 4, l.y - 4, l.y + l.h + 4, 0, 3, models.cube, {12, 12, 12}, 0.1)
  face_box(l.x + l.w + 4, l.x + l.w + 8, l.y - 4, l.y + l.h + 4, 0, 3, models.cube, {12, 12, 12}, 0.1)
  // the felt behind the keys, the plate the wheels sit in
  box({x: key_x(hw.KEYS_X) - 0.02, y: 0.34, z: -0.05}, {x: 5.6, y: KEY_TOP + 0.08, z: KEY_BACK}, models.cube, {104, 40, 26}, 0.02)
  box({x: -5.6, y: 0.34, z: -0.05}, {x: key_x(hw.KEYS_X) - 0.04, y: 0.4, z: 2.82}, models.cube, {16, 16, 17}, 0.15)
}

// ------------------------------------------------------------ knobs and buttons

// where each knob is turned (radians, by knob): the knobs move to their
// values as motorized ones do, so a new page turns them into place; the
// one in the hand follows it
local knob_angles = {}
// how fast they move: an easing of this many per second, at most this
// many radians a second
local KNOB_EASE = 7.0
local KNOB_SPEED = 5.0

local func knob_angle(k){
  local f = hw.knob_fraction(app, k)
  local target = 0.0
  if(f != null){
    target = (f * 300.0 - 150.0) * math.pi / 180.0
  }
  local key = concat(k.kind, string(k.index))
  local a = knob_angles[key]
  if(a == null or hw.held_knob() == k){
    a = target
  } else {
    local dt = rl.get_frame_time()
    local step = (target - a) * (1 - math.exp(-dt * KNOB_EASE))
    local most = KNOB_SPEED * dt
    a = a + math.clamp(step, -most, most)
    if(math.abs(target - a) < 0.001){
      a = target
    }
  }
  knob_angles[key] = a
  return a
}

local func draw_knob(k){
  local f = hw.knob_fraction(app, k)
  local angle = knob_angle(k)
  local r = k.r
  local place = mul(rl.matrix_rotate_z(-angle), T(k.x, -k.y, 0), panel_matrix)
  if(k.kind == "volume"){
    draw(models.cylinder, mul(S(r + 6.0, 4.0, r + 6.0), RX90, place), {58, 54, 52}, 0.3)
    draw(models.cylinder, mul(S(r, 18.0, r), RX90, place), {18, 17, 17}, 0.2)
  } else {
    // an encoder: a knurled-looking ring and a lighter cap
    draw(models.cylinder, mul(S(r, 14.0, r), RX90, place), {26, 25, 25}, 0.25)
    draw(models.cylinder, mul(S(r - 3, 2.0, r - 3), RX90, T(0, 0, 14.0), place), {64, 61, 60}, 0.35)
  }
  // the pointer, dark on an encoder without a parameter
  local pointer = {245, 240, 230}
  if(f == null){
    pointer = {70, 68, 66}
  }
  local top = 18.2
  if(k.kind == "encoder"){
    top = 16.4
  }
  draw(models.cube, mul(S(3.0, r * 0.7, 1.6), T(0, r * 0.5, top), place), pointer, 0.2)
}

// a button: a cap that goes down while held, and its LED
local press_depth = {}

local func draw_button(b){
  local key = concat(b.kind, string(b.index))
  local target = 0.0
  if(hw.held == b){
    target = 1.0
  }
  local d = press_depth[key] or 0.0
  d = d + (target - d) * 0.5
  press_depth[key] = d
  local height = 8.0 - d * 4.0
  local cap = {78, 74, 72}
  if(b.kind == "op"){
    cap = {216, 208, 192}
  } else if(b.kind == "page"){
    cap = {52, 50, 50}
  }
  local place = mul(T(b.x, -b.y, 0), panel_matrix)
  draw(models.cube, mul(S(b.w + 4, b.h + 4, 2), T(0, 0, 1), place), {10, 10, 10}, 0.05)
  draw(models.cube, mul(S(b.w, b.h, height), T(0, 0, height / 2), place), cap, 0.25)
  // the LED on the cap's right end
  local lit = hw.lit(app, b)
  local led = {70, 22, 14}
  local glow = 0.0
  if(lit){
    led = {255, 96, 40}
    glow = 0.9
  }
  draw(models.cube, mul(S(9, 5, 1.5), T(b.w / 2 - 9, b.h / 2 - 6, height + 0.6), place), led, 0.4, 1.0, null, glow)
}

local func draw_controls(){
  for(let local k in values(hw.knobs)){
    draw_knob(k)
  }
  for(let local b in values(hw.buttons)){
    draw_button(b)
  }
}

// ------------------------------------------------------------ keys and wheels

local press = {}

// a key's box at rest: {min, max}
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
for(let local k in values(hw.keys)){
  append(key_boxes, key_box(k))
}

local func draw_keys(){
  for(local i = 0; i < len(hw.keys); i = i + 1){
    local k = hw.keys[i]
    local b = key_boxes[i]
    local target = 0.0
    if(app.held(k.note)){
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

local WHEEL_R = 0.5
local WHEEL_WIDTH = 0.24
local WHEEL_Z = 1.45
local WHEEL_Y = 0.12

local func wheel_x(wh){
  return key_x(wh.x + hw.WHEEL_W / 2) + 0.02
}

local func wheel_box(wh){
  local x = wheel_x(wh)
  return {
    min: {x: x - WHEEL_WIDTH, y: 0.3, z: WHEEL_Z - WHEEL_R},
    max: {x: x + WHEEL_WIDTH, y: WHEEL_Y + WHEEL_R + 0.05, z: WHEEL_Z + WHEEL_R},
  }
}

// a wheel's position 0..1 (the pitch wheel's -1..1 mapped)
local func wheel_value(wh){
  local v = app.controls[wh.index]
  if(wh.index == engine.BEND){
    return (v + 1) / 2
  }
  return v
}

local func draw_wheels(){
  for(let local wh in values(hw.wheels)){
    local v = wheel_value(wh)
    local x = wheel_x(wh)
    box({x: x - WHEEL_WIDTH / 2 - 0.05, y: 0.4, z: WHEEL_Z - 0.62},
      {x: x + WHEEL_WIDTH / 2 + 0.05, y: 0.42, z: WHEEL_Z + 0.62},
      models.cube, {4, 4, 4}, 0.0)
    local turn = mul(rl.matrix_rotate_x((0.5 - v) * 1.4), T(x, WHEEL_Y, WHEEL_Z))
    local side = mul(rl.matrix_rotate_z(math.pi / 2), T(WHEEL_WIDTH / 2, 0, 0))
    draw(models.cylinder, mul(S(WHEEL_R, WHEEL_WIDTH, WHEEL_R), side, turn), {30, 30, 32}, 0.4)
    draw(models.cube, mul(S(WHEEL_WIDTH + 0.01, 0.03, 0.06), T(0, WHEEL_R, 0), turn), {232, 118, 64}, 0.5)
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
// position {x, y}, or null
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

// the key under the ray: {note, vel} (nearer the front is louder), or null
local func key_hit(ray){
  local best = null
  local best_t = 1.0e30
  for(local i = 0; i < len(hw.keys); i = i + 1){
    local t = ray_box(ray, key_boxes[i])
    if(t != null and t < best_t){
      best_t = t
      best = i
    }
  }
  if(best == null){
    return null
  }
  local b = key_boxes[best]
  local z = ray.position.z + ray.direction.z * best_t
  local along = math.clamp((z - b.min.z) / (b.max.z - b.min.z), 0, 1)
  return {note: hw.keys[best].note, vel: to_int(30 + along * 97)}
}

// the control under the ray (a little above the face, where the caps are)
local func control_hit(ray){
  local p = face_point(ray, 8.0)
  if(p == null){
    return null
  }
  return hw.control_at(p.x, p.y)
}

local func wheel_hit(ray){
  local best = null
  local best_t = 1.0e30
  for(let local wh in values(hw.wheels)){
    local t = ray_box(ray, wheel_box(wh))
    if(t != null and t < best_t){
      best_t = t
      best = wh
    }
  }
  return best
}

// ------------------------------------------------------------ the camera

local view = {yaw: 0.0, pitch: 0.55, distance: 14.0}
local target = {x: 0.0, y: 1.7, z: 0.4}
local view_env = os.getenv("FM_VIEW")
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

// ------------------------------------------------------------ input

local mouse_note = null
local wheel_drag = null

local func handle_mouse(){
  local m = rl.get_mouse_position()
  local ray = rl.get_screen_to_world_ray(m, camera)
  local left = rl.MOUSE_BUTTON_LEFT
  local shift = rl.is_key_down(rl.KEY_LEFT_SHIFT) or rl.is_key_down(rl.KEY_RIGHT_SHIFT)
  if(rl.is_mouse_button_pressed(left)){
    local c = control_hit(ray)
    if(c != null){
      hw.press(app, c, m.y, shift)
    } else {
      local wh = wheel_hit(ray)
      if(wh != null){
        wheel_drag = {wheel: wh, y: m.y, value: wheel_value(wh)}
        if(wh.index == engine.BEND){
          app.bend_from_midi = false
        }
      } else {
        local k = key_hit(ray)
        if(k != null){
          mouse_note = k.note
          app.note_on(k.note, k.vel)
        }
      }
    }
  }
  if(rl.is_mouse_button_down(left)){
    hw.drag(app, m.y, shift)
    if(wheel_drag != null){
      local v = math.clamp(wheel_drag.value + (wheel_drag.y - m.y) / 150, 0, 1)
      if(wheel_drag.wheel.index == engine.BEND){
        v = v * 2 - 1
      }
      app.controls[wheel_drag.wheel.index] = v
    } else if(mouse_note != null and not hw.dragging()){
      // gliding over the keys
      local k = key_hit(ray)
      if(k != null and k.note != mouse_note){
        app.note_on(k.note, k.vel)
        app.note_off(mouse_note)
        mouse_note = k.note
      }
    }
  }
  if(rl.is_mouse_button_released(left)){
    hw.release()
    wheel_drag = null
    if(mouse_note != null){
      app.note_off(mouse_note)
      mouse_note = null
    }
  }
  local w = rl.get_mouse_wheel_move()
  if(w != 0.0){
    local c = control_hit(ray)
    if(c != null){
      hw.scroll(app, c, w)
    } else {
      view.distance = math.clamp(view.distance - w * 0.6, 5.0, 22.0)
    }
  }
  // the right button looks around
  if(rl.is_mouse_button_down(rl.MOUSE_BUTTON_RIGHT)){
    local d = rl.get_mouse_delta()
    view.yaw = math.clamp(view.yaw - d.x * 0.005, -1.3, 1.3)
    view.pitch = math.clamp(view.pitch + d.y * 0.004, 0.1, 1.35)
  }
  // the pitch wheel springs back (unless the controller holds it)
  if(not app.bend_from_midi and (wheel_drag == null or wheel_drag.wheel.index != engine.BEND)){
    local b = app.controls[engine.BEND]
    if(b != 0){
      local nb = b * 0.65
      if(math.abs(nb) < 0.003){
        nb = 0
      }
      app.controls[engine.BEND] = nb
    }
  }
}

// ------------------------------------------------------------ the frame

local face_camera = {
  offset: {-FACE_X * FACE_SCALE, -FACE_Y * FACE_SCALE}, target: {0, 0},
  rotation: 0, zoom: FACE_SCALE,
}

local func draw_face(){
  rl.begin_texture_mode(face_target)
  rl.clear_background(hw.colors.panel)
  rl.begin_mode_2d(face_camera)
  hw.draw_face(app, false)
  rl.end_mode_2d()
  rl.end_texture_mode()
  rl.gen_texture_mipmaps(face_target.texture)
  rl.set_texture_filter(face_target.texture, rl.TEXTURE_FILTER_TRILINEAR)
}

local func draw_scene(){
  rl.set_shader_value(shader, locs.viewPos, camera.position, rl.SHADER_UNIFORM_VEC3)
  current = {scale: -1.0, shine: -1.0, axis: -1.0, seed: -1.0, glow: -1.0}
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
  if(app.learning){
    gfx.text("MIDI LEARN: click a knob, then turn one on the controller    F1: done    BACKSPACE: unbind it",
      16, H - 26, 10, {232, 118, 64})
  } else {
    gfx.text("right drag: look around    wheel: closer    left/right: octave    up/down: patch    TAB: sustain    SPACE: all off    F1: MIDI learn",
      16, H - 26, 10, {150, 142, 132})
  }
  gfx.text(concat("OCTAVE ", require("patch").note_name(app.octave)), W - 110, H - 26, 10, {150, 142, 132})
}

rl.set_config_flags(rl.FLAG_MSAA_4X_HINT)
rl.init_window(W, H, "slang six 3D")
rl.set_target_fps(60)
rl.set_exit_key(rl.KEY_NULL)
gfx.load_font()
setup()
// the knobs of many small controllers (an MPK mini's among them) send
// CC 70 to 77: they turn the encoders until MIDI learn says otherwise
local default_map = {}
for(local i = 0; i < 8; i = i + 1){
  default_map[concat("1:", string(70 + i))] = concat("encoder", string(i + 1))
}
app.start("midi_map_3d.json", default_map)
app.on_cc = func(target, value){
  hw.set_target(app, target, value)
}

// FM_PICKTEST=1: every control and key is projected to the screen and
// picked back from there; the misses are printed
if(os.getenv("FM_PICKTEST") != null){
  place_camera()
  local misses = 0
  for(let local c in values(hw.knobs)){
    local at = rl.get_world_to_screen(on_face(c.x, c.y, 8.0), camera)
    if(control_hit(rl.get_screen_to_world_ray(at, camera)) != c){
      misses = misses + 1
      print("pick test: ", c.kind, " ", c.index, "\n")
    }
  }
  for(let local c in values(hw.buttons)){
    local at = rl.get_world_to_screen(on_face(c.x, c.y, 8.0), camera)
    if(control_hit(rl.get_screen_to_world_ray(at, camera)) != c){
      misses = misses + 1
      print("pick test: ", c.kind, " ", c.index, "\n")
    }
  }
  for(local i = 0; i < len(hw.keys); i = i + 1){
    local b = key_boxes[i]
    local top = {x: (b.min.x + b.max.x) / 2, y: b.max.y, z: b.max.z - 0.2}
    local k = key_hit(rl.get_screen_to_world_ray(rl.get_world_to_screen(top, camera), camera))
    if(k == null or k.note != hw.keys[i].note){
      misses = misses + 1
      print("pick test: key ", hw.keys[i].note, "\n")
    }
  }
  print("pick test: ", misses, " misses\n")
}

local frame = 0
app.mark_start()
for(not rl.window_should_close() and frame != app.max_frames){
  place_camera()
  handle_mouse()
  app.handle_keys()
  app.update(frame)
  draw_face()
  rl.begin_drawing()
  rl.clear_background({14, 13, 15})
  rl.draw_rectangle_gradient_v(0, 0, W, H, {44, 42, 46}, {14, 13, 15})
  draw_scene()
  draw_hud()
  rl.end_drawing()
  frame = frame + 1
  app.end_frame(frame)
}

rl.unload_render_texture(face_target)
rl.unload_shader(shader)
gfx.unload_font()
app.finish(frame)
rl.close_window()
