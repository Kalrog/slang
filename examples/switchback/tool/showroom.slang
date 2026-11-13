// tool/showroom: the truck alone, on a plain floor under the game's sky
// and sun, to look at it and at what the garage puts on it.
//
//   cd examples/switchback && ../../bin/slang run tool/showroom.slang
//
// Drag with the left button to walk around it, the wheel zooms. The keys
// 1 to 9 and 0 move a category of the garage to its next option (with
// shift: the one before); L the lights, B the brake, V reverse, F flexes
// the axles, the left and right arrows steer, D adds dirt, R turns the
// truck slowly, Esc leaves.
//
// For scripted pictures, from the environment:
//   SHOWROOM_SETUPS="paint=moss,roof=tent;paint=dune"   one truck per
//                           setup (over the garage's default), in a grid
//   SHOWROOM_YAWS=35,90,145 each truck's turn, degrees (the last one for
//                           the rest; as many trucks as there are of either)
//   SHOWROOM_COLUMNS=3      trucks in a row of the grid
//   SHOWROOM_CAMERA=az,el,dist,fov   where the camera is: degrees around
//                           and up, meters away, its angle of view
//   SHOWROOM_TARGET=x,y,z   what it looks at
//   SHOWROOM_STEER=deg, SHOWROOM_FLEX=0..1, SHOWROOM_DIRT=0..1,
//   SHOWROOM_LIGHTS=1, SHOWROOM_BRAKE=1, SHOWROOM_REVERSE=1
//   SHOWROOM_SHOT=file.png  save a picture (into the working directory)
//                           and leave
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local time = require("slang/time")
local vec = require("game/vec")
local car_lib = require("game/car")
local garage = require("game/garage")
local shaders = require("render/shaders")
local sky = require("render/sky")
local truck = require("render/truck")

local WIDTH = 1280
local HEIGHT = 720
local SUN = vec.normalize({x: -0.52, y: 0.5, z: -0.62})
local SUN_COLOR = {2.5, 2.25, 1.9}

local func numbers(text){
  local out = {}
  for(let local part in values(str.split(text, ","))){
    append(out, str.to_number(str.trim(part)))
  }
  return out
}

local func env_number(name, fallback){
  local v = os.getenv(name)
  if(v == null){
    return fallback
  }
  return str.to_number(v)
}

// ---- the trucks on show
local setups = {}
if(os.getenv("SHOWROOM_SETUPS") != null){
  for(let local text in values(str.split(os.getenv("SHOWROOM_SETUPS"), ";"))){
    append(setups, garage.parse(text))
  }
} else {
  append(setups, garage.default())
}
local yaws = {35}
if(os.getenv("SHOWROOM_YAWS") != null){
  yaws = numbers(os.getenv("SHOWROOM_YAWS"))
}
local count = math.max(len(setups), len(yaws))
local columns = to_int(env_number("SHOWROOM_COLUMNS", 3))
local spacing = {x: 6.4, z: 7.6}
local scripted = os.getenv("SHOWROOM_SHOT") != null

local state = {
  steer: env_number("SHOWROOM_STEER", 0) * math.pi / 180,
  flex: env_number("SHOWROOM_FLEX", 0),
  dirt: env_number("SHOWROOM_DIRT", 0),
  lights: os.getenv("SHOWROOM_LIGHTS") != null,
  brake: os.getenv("SHOWROOM_BRAKE") != null,
  reverse: os.getenv("SHOWROOM_REVERSE") != null,
  turning: false,
  turn: 0,
  roll: 0,
}

// a truck as the renderer wants a car: standing at a place of the grid
local func car_at(i){
  local col = i % columns
  local row = to_int(i / columns)
  local cols = math.min(columns, count)
  local rows = to_int((count + columns - 1) / columns)
  local x = (col - (cols - 1) / 2) * spacing.x
  local z = ((rows - 1) / 2 - row) * spacing.z
  local yaw = (yaws[math.min(i, len(yaws) - 1)] + state.turn) * math.pi / 180
  local wheels = {}
  // the axles cross: front left and rear right up, the others down
  local flex = {1, -1, -1, 1}
  for(local k = 0; k < 4; k = k + 1){
    local at = car_lib.WHEELS[k]
    append(wheels, {
      at: at,
      steer: if(at.front){ state.steer } else { 0 },
      angle: state.roll,
      length: car_lib.SUSPENSION_REST - flex[k] * state.flex * 0.13,
    })
  }
  return {
    pos: {x: x, y: car_lib.WHEEL_RADIUS, z: z},
    q: vec.quat_yaw(yaw),
    yaw: yaw,
    wheels: wheels,
    brake: if(state.brake){ 1 } else { 0 },
    direction: if(state.reverse){ -1 } else { 1 },
    lights: state.lights,
    dirt: state.dirt,
    blink: 0,
  }
}

// ---- the floor: fine gravel, darker under each truck
local floor_vertex = """
in vec3 vertexPosition;
uniform mat4 matModel;
out vec3 worldPos;
void main(){
  vec4 p = matModel * vec4(vertexPosition, 1.0);
  worldPos = p.xyz;
  gl_Position = viewProj * p;
}
"""

local floor_fragment = """
in vec3 worldPos;
uniform vec4 trucks[12];
uniform int truckCount;
out vec4 finalColor;
void main(){
  vec2 p = worldPos.xz;
  float grain = vnoise(p * 23.0) * 0.5 + vnoise(p * 71.0) * 0.5;
  vec3 albedo = mix(vec3(0.2, 0.185, 0.16), vec3(0.3, 0.285, 0.255), grain);
  albedo *= 0.85 + 0.3 * vnoise(p * 0.7);
  float light = 1.0;
  float sun = 1.0;
  for(int i = 0; i < truckCount; i++){
    vec2 d = p - trucks[i].xy;
    vec2 q = vec2(d.x * trucks[i].z - d.y * trucks[i].w, d.x * trucks[i].w + d.y * trucks[i].z);
    vec2 e = abs(q) - vec2(0.8, 2.05);
    float sd = length(max(e, 0.0)) + min(max(e.x, e.y), 0.0);
    light *= 1.0 - 0.8 * (1.0 - smoothstep(-0.4, 0.9, sd));
    // the truck's shadow, laid away from the sun
    vec2 off = -sunDir.xz / sunDir.y;
    vec2 d2 = p - trucks[i].xy - off * 0.75;
    vec2 q2 = vec2(d2.x * trucks[i].z - d2.y * trucks[i].w, d2.x * trucks[i].w + d2.y * trucks[i].z);
    vec2 e2 = abs(q2) - vec2(0.9, 2.2) - abs(vec2(off.x * trucks[i].z - off.y * trucks[i].w, off.x * trucks[i].w + off.y * trucks[i].z)) * 0.75;
    float sd2 = length(max(e2, 0.0)) + min(max(e2.x, e2.y), 0.0);
    sun *= 0.3 + 0.7 * smoothstep(-0.5, 0.7, sd2);
  }
  vec3 n = vec3(0.0, 1.0, 0.0);
  vec3 color = albedo * (sunColor * max(dot(n, sunDir), 0.0) * sun + ambientLight(n) * light);
  finalColor = vec4(finish(color, worldPos), 1.0);
}
"""

// ---- the camera
local camera = {azimuth: 0, elevation: 14, distance: 9.5, fov: 34, target: {x: 0, y: 0.85, z: 0}}
if(count > 1){
  // far off through a long lens, so that every truck is seen alike
  local cols = math.min(columns, count)
  local rows = to_int((count + columns - 1) / columns)
  camera.elevation = 15
  camera.fov = 15
  local wide = ((cols - 1) / 2 * spacing.x + 2.9) / (math.tan(camera.fov / 2 * math.pi / 180) * WIDTH / HEIGHT)
  local high = ((rows - 1) / 2 * spacing.z * math.sin(camera.elevation * math.pi / 180) + 1.5) / math.tan(camera.fov / 2 * math.pi / 180)
  camera.distance = math.max(wide, high)
  camera.target.y = 0.75
}
if(os.getenv("SHOWROOM_CAMERA") != null){
  // (a distance or an angle of 0 keeps what fits the trucks)
  local c = numbers(os.getenv("SHOWROOM_CAMERA"))
  camera.azimuth = c[0]
  camera.elevation = c[1]
  if(c[2] != null and c[2] > 0){
    camera.distance = c[2]
  }
  if(c[3] != null and c[3] > 0){
    camera.fov = c[3]
  }
}
if(os.getenv("SHOWROOM_TARGET") != null){
  local c = numbers(os.getenv("SHOWROOM_TARGET"))
  camera.target = {x: c[0], y: c[1], z: c[2]}
}

local func make_view(t){
  local az = camera.azimuth * math.pi / 180
  local el = camera.elevation * math.pi / 180
  local target = camera.target
  local eye = {
    x: target.x + math.sin(az) * math.cos(el) * camera.distance,
    y: target.y + math.sin(el) * camera.distance,
    z: target.z + math.cos(az) * math.cos(el) * camera.distance,
  }
  local up = {x: 0, y: 1, z: 0}
  local fovy = camera.fov * math.pi / 180
  local aspect = WIDTH / HEIGHT
  local forward = vec.normalize(vec.sub(target, eye))
  local right = vec.normalize(vec.cross(forward, up))
  local proj = vec.perspective(fovy, aspect, 0.2, 600)
  return {
    eye: eye,
    forward: forward,
    right: right,
    up: vec.cross(right, forward),
    fovy: fovy,
    aspect: aspect,
    view_proj: vec.matrix_multiply(proj, vec.look_at(eye, target, up)),
    sun_dir: SUN,
    sun_color: SUN_COLOR,
    time: t,
    width: WIDTH,
    height: HEIGHT,
  }
}

rl.window.open({width: WIDTH, height: HEIGHT, title: "Switchback: the showroom", msaa: true, vsync: true, fps: 60})
rl.window.exit_key = rl.KEY_NULL
sky.init()
local started = time.clock()
truck.init()
local built = time.clock() - started
local floor_shader = shaders.load(floor_vertex, floor_fragment)
local floor = rl.mesh.plane(400, 400, 1, 1):to_model()
local floor_material = shaders.use(floor, floor_shader)
local raylib_camera = rl.camera_3d({position: {x: 0, y: 10, z: 10}})

local category_keys = {
  rl.KEY_ONE, rl.KEY_TWO, rl.KEY_THREE, rl.KEY_FOUR, rl.KEY_FIVE, rl.KEY_SIX, rl.KEY_SEVEN,
  rl.KEY_EIGHT, rl.KEY_NINE, rl.KEY_ZERO,
}

local frames = 0
local t = 0
local draw_time = 0
local drawn = 0
for(not rl.window.should_close){
  local dt = math.min(rl.frame_time, 0.05)
  t = t + dt
  if(rl.key.pressed(rl.KEY_ESCAPE)){
    break
  }
  // ---- the keys
  local shift = rl.key.down(rl.KEY_LEFT_SHIFT) or rl.key.down(rl.KEY_RIGHT_SHIFT)
  for(local i = 0; i < len(category_keys) and i < len(garage.categories); i = i + 1){
    if(rl.key.pressed(category_keys[i])){
      for(let local setup in values(setups)){
        garage.next(setup, garage.categories[i].id, if(shift){ -1 } else { 1 })
      }
    }
  }
  if(rl.key.pressed(rl.KEY_L)){ state.lights = not state.lights }
  if(rl.key.pressed(rl.KEY_B)){ state.brake = not state.brake }
  if(rl.key.pressed(rl.KEY_V)){ state.reverse = not state.reverse }
  if(rl.key.pressed(rl.KEY_R)){ state.turning = not state.turning }
  if(rl.key.pressed(rl.KEY_F)){ state.flex = if(state.flex > 0.5){ 0 } else { 1 } }
  if(rl.key.pressed(rl.KEY_D)){ state.dirt = if(state.dirt > 0.9){ 0 } else { state.dirt + 0.34 } }
  if(rl.key.down(rl.KEY_LEFT)){ state.steer = math.min(0.62, state.steer + dt * 1.5) }
  if(rl.key.down(rl.KEY_RIGHT)){ state.steer = math.max(-0.62, state.steer - dt * 1.5) }
  if(state.turning){
    state.turn = state.turn + dt * 25
    state.roll = state.roll + dt * 2
  }
  if(not scripted){
    // (a scripted picture is not for the mouse to spoil)
    if(rl.mouse.down(rl.MOUSE_BUTTON_LEFT)){
      local d = rl.mouse.delta
      camera.azimuth = camera.azimuth - d.x * 0.35
      camera.elevation = vec.clamp(camera.elevation + d.y * 0.3, -12, 88)
    }
    camera.distance = vec.clamp(camera.distance * (1 - rl.mouse.wheel * 0.08), 2.5, 120)
  }

  // ---- the frame
  local view = make_view(t)
  local cars = {}
  local places = {}
  for(local i = 0; i < count; i = i + 1){
    local car = car_at(i)
    append(cars, car)
    append(places, {car.pos.x, car.pos.z, math.cos(car.yaw), math.sin(car.yaw)})
  }
  rl.drawing{
    sky.draw(view)
    rl.mode_3d(raylib_camera){
      shaders.apply(floor_shader, view)
      floor_shader:set_value_v(floor_shader:location("trucks"), places, rl.SHADER_UNIFORM_VEC4)
      floor_shader:set("truckCount", count, rl.SHADER_UNIFORM_INT)
      rl.draw.mesh(floor.meshes[0], floor_material, vec.identity_matrix)
      local from = time.clock()
      for(local i = 0; i < count; i = i + 1){
        truck.draw(view, cars[i], setups[math.min(i, len(setups) - 1)])
      }
      // (the first frames build the meshes)
      if(frames >= 3){
        draw_time = draw_time + time.clock() - from
        drawn = drawn + count
      }
    }
    if(not scripted){
      local setup = setups[0]
      local y = 12
      for(local i = 0; i < len(garage.categories); i = i + 1){
        local c = garage.categories[i]
        local key = if(i < 9){ string(i + 1) } else { "0" }
        rl.draw.text(concat(key, "  ", c.name, ": ", garage.option(c.id, setup[c.id]).name), 14, y, 20, rl.WHITE)
        y = y + 24
      }
      rl.draw.text(concat(string(rl.fps), " fps"), WIDTH - 90, 12, 20, rl.WHITE)
    }
  }
  frames = frames + 1
  if(scripted and frames == 20){
    rl.window.screenshot(os.getenv("SHOWROOM_SHOT"))
  }
  if(scripted and frames >= 22){
    break
  }
}
local stats = truck.stats()
print("showroom: built in ", to_int(built), " ms (the body ", to_int(stats.build), " ms, a setup's gear ", to_int(stats.gear_build),
  " ms); vertices: body ", stats.body, ", gear ", stats.gear, ", a wheel ", stats.wheel, "; drawing a truck takes ",
  to_int(draw_time * 1000 / math.max(1, drawn)), " us\n")
truck.unload()
floor:unload()
floor_shader:unload()
sky.unload()
rl.window.close()
