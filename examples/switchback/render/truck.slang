// render/truck: the truck drawn. Its body is built from code once
// (render/truck_body), what a setup of the garage adds to it whenever the
// setup changes (render/truck_gear), and the parts that move are meshes
// of their own, placed every frame where the physics has them: four
// wheels (turning, steering, riding up and down), two live axles that
// tilt between their wheels, a spring over a damper at each wheel, and
// the links and shafts between the axles and the frame.
//
//   truck.init()
//   truck.draw(view, car, setup)      // setup: game/garage's, or null
//   truck.unload()
//
// One shader draws all of it: a vertex says what it is made of (lacquer
// in the setup's color, plastic, steel, glass, a lamp's lens, rubber),
// and the lamps light with the car's brakes, its gear and its lights.
local rl = require("raylib")
local math = require("slang/math")
local time = require("slang/time")
local vec = require("game/vec")
local car_lib = require("game/car")
local garage = require("game/garage")
local shaders = require("render/shaders")
local kit = require("render/truck_mesh")
local body = require("render/truck_body")
local gear = require("render/truck_gear")
local wheels = require("render/truck_wheels")

local m = {}

local vertex = """
in vec3 vertexPosition;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec2 vertexTexCoord;
in vec2 vertexTexCoord2;
uniform mat4 matModel;
out vec3 worldPos;
out vec3 localPos;
out vec3 normal;
out vec3 tint;
out vec2 what;
void main(){
  vec4 p = matModel * vec4(vertexPosition, 1.0);
  worldPos = p.xyz;
  localPos = vertexPosition;
  // (the springs are stretched: their normals need the inverse)
  normal = normalize(transpose(inverse(mat3(matModel))) * vertexNormal);
  tint = vertexColor.rgb;
  what = vertexTexCoord;
  gl_Position = viewProj * p;
}
"""

local fragment = """
in vec3 worldPos;
in vec3 localPos;
in vec3 normal;
in vec3 tint;
in vec2 what;
uniform vec3 paint;
uniform vec3 roofPaint;
uniform vec3 lampsA;      // head, tail, brake
uniform vec3 lampsB;      // reverse, blink, bar
uniform float dirt;
uniform float dust;
out vec4 finalColor;

void main(){
  if(depthPass > 0.5){
    finalColor = packDepth(gl_FragCoord.z);
    return;
  }
  vec3 n = normalize(normal);
  float shadow = sunShadow(worldPos, n);
  int material = int(what.x + 0.5);
  // (the mesh's colors are the screen's: to light)
  vec3 own = pow(tint, vec3(2.2));
  vec3 albedo = own;
  float gloss = 0.1;
  float metal = 0.0;
  vec3 glow = vec3(0.0);
  float mirror = 0.0;
  if(material == 0){
    albedo = paint;
    mirror = 0.3;
  } else if(material == 1){
    albedo = roofPaint;
    mirror = 0.3;
  } else if(material == 3){
    gloss = what.y > 0.0 ? what.y : 0.45;
    metal = 0.65;
  } else if(material == 4){
    albedo = vec3(0.012, 0.016, 0.02);
    mirror = 0.8;
  } else if(material == 5){
    int group = int(what.y + 0.5);
    float level = 0.0;
    if(group == 0){
      level = lampsA.x;
    } else if(group == 1){
      level = max(lampsA.y * 0.35, lampsA.z);
    } else if(group == 3){
      level = lampsB.x;
    } else if(group == 4){
      level = lampsB.y;
    } else {
      level = lampsB.z;
    }
    // unlit, a lens is glass over its color (a head lamp's over its
    // bright bowl)
    albedo = own * (group == 0 ? 0.5 : 0.22);
    mirror = group == 0 ? 0.5 : 0.25;
    glow = own * level * (group == 0 || group == 5 ? 9.0 : 4.5);
  } else if(material == 6){
    albedo = vec3(0.016, 0.016, 0.017);
    gloss = 0.16;
  } else if(material == 7){
    gloss = 0.94;
    metal = 1.0;
  }
  // dust: a pale film all over, thicker low down and where it gathers
  if(dust > 0.0 && material != 5){
    float low = 1.0 - smoothstep(-0.1, 1.3, localPos.y);
    float gathers = vnoise(localPos.zy * 5.0 + localPos.x * 3.0);
    float f = clamp(dust * (0.3 + 0.5 * low + 0.35 * gathers), 0.0, 0.8);
    albedo = mix(albedo, vec3(0.3, 0.255, 0.19), f);
    gloss = mix(gloss, 0.08, f);
    mirror *= 1.0 - f * 0.85;
  }
  // dirt: on what is low, in patches
  if(dirt > 0.0 && material != 5){
    float low = 1.0 - smoothstep(-0.1, 1.0, localPos.y);
    float patchy = vnoise(localPos.zy * 9.0 + localPos.x * 5.0) * 0.6 + vnoise(localPos.zy * 31.0) * 0.4;
    float d = clamp(dirt * (low * 1.7 + 0.15) - patchy * 0.75 * (1.0 - dirt * 0.6), 0.0, 1.0);
    albedo = mix(albedo, vec3(0.09, 0.066, 0.045), d);
    gloss = mix(gloss, 0.06, d);
    metal *= 1.0 - d;
    mirror *= 1.0 - d * 0.97;
  }
  vec3 color;
  if(mirror > 0.0){
    // lacquer, glass, a lens: a matte color under a clear coat that
    // mirrors the sky above and the ground below, more at a glance
    vec3 v = normalize(eye - worldPos);
    vec3 r = reflect(-v, n);
    float ndl = max(dot(n, sunDir), 0.0);
    float fres = pow(1.0 - max(dot(n, v), 0.0), 4.0);
    float coat = mirror * (0.3 + 0.7 * fres);
    vec3 ground = vec3(0.13, 0.115, 0.095) * (0.5 + 0.5 * sunColor * sunDir.y);
    vec3 env = mix(ground, skyLight(r), smoothstep(-0.08, 0.1, r.y));
    vec3 h = normalize(v + sunDir);
    float spec = pow(max(dot(n, h), 0.0), 420.0) * 9.0 + pow(max(dot(n, h), 0.0), 40.0) * 0.25;
    color = albedo * (sunColor * ndl * shadow + ambientLight(n)) * (1.0 - coat * 0.5);
    color += coat * env + sunColor * spec * shadow * (0.25 + mirror);
  } else {
    color = shadeGloss(albedo, n, worldPos, shadow, gloss, metal);
  }
  color += glow;
  finalColor = vec4(finish(color, worldPos), 1.0);
}
"""

local state = {}
local unit = {x: 1, y: 1, z: 1}

// where the springs hang from the frame: over the axle, under the arch
local SPRING_TOP = 0.585
local SPRING_SEAT = {x: 0.5, y: 0.07}
// where the links and the shafts hold the frame and the transfer case
local LINK_AXLE = {x: 0.4, y: -0.05}
local LINK_FRAME = {x: 0.43, y: -0.02, z: 0.6}
local SHAFT_CASE = {x: -0.06, y: 0.0, front: 0.36, rear: -0.12}

local func model_of(build){
  local b = kit.new()
  build(b)
  local mesh = b:mesh()
  local model = mesh:to_model()
  return {model: model, mesh: model.meshes[0], material: shaders.use(model, state.shader), vertices: b.count}
}

local func unload_part(part){
  if(part != null){
    part.model:unload()
  }
}

// init(): the shader, the body, and the parts that every setup shares
func m.init(){
  state.shader = shaders.load(vertex, fragment)
  local from = time.clock()
  state.body = model_of(body.build)
  state.axle_front = model_of(func(b){
    wheels.axle(b, true)
  })
  state.axle_rear = model_of(func(b){
    wheels.axle(b, false)
  })
  state.spring = model_of(wheels.spring)
  state.rod = model_of(wheels.rod)
  state.wheels = {}
  state.gears = {}
  state.gear_count = 0
  state.gear = null
  state.gear_key = null
  state.build_time = time.clock() - from
}

// the setup's own meshes: its gear (the last few setups' are kept: a
// garage's menu goes back and forth) and its kind of wheel
local KEPT = 12

local func prepare(setup){
  local key = garage.key(setup)
  if(key == state.gear_key){
    return
  }
  local kept = state.gears[key]
  if(kept == null){
    local from = time.clock()
    if(state.gear_count >= KEPT){
      for(let local old in values(state.gears)){
        unload_part(old)
      }
      state.gears = {}
      state.gear_count = 0
    }
    kept = model_of(func(b){
      gear.build(b, setup)
    })
    state.gears[key] = kept
    state.gear_count = state.gear_count + 1
    if(state.wheels[setup.wheels] == null){
      state.wheels[setup.wheels] = model_of(func(b){
        wheels.wheel(b, setup.wheels)
      })
    }
    state.gear_time = time.clock() - from
  }
  state.gear = kept
  state.gear_key = key
}

// a color of the screen (0..255) as light
local func linear(c){
  return {(c[0] / 255) ^ 2.2, (c[1] / 255) ^ 2.2, (c[2] / 255) ^ 2.2}
}

// the quaternion that turns the y axis (or the z axis) to a direction
local func from_y(d){
  // y x d = (d.z, 0, -d.x)
  local q = {x: d.z, y: 0, z: -d.x, w: 1 + d.y}
  if(q.w < 1.0e-6){
    return {x: 1, y: 0, z: 0, w: 0}
  }
  return vec.quat_normalize(q)
}

local func from_z(d){
  // z x d = (-d.y, d.x, 0)
  local q = {x: -d.y, y: d.x, z: 0, w: 1 + d.z}
  if(q.w < 1.0e-6){
    return {x: 0, y: 1, z: 0, w: 0}
  }
  return vec.quat_normalize(q)
}

local half_turn = {x: 0, y: 1, z: 0, w: 0}

// draw(view, car: car.Car, setup?: garage.Setup): the truck where the
// car is, as the setup has it (the garage's default without one). The
// car's lights (car.lights), its brake and its gear light the lamps;
// car.dirt (0 to 1) is mud, browning it from the sills up, car.dust (0
// to 1) a pale film of dust all over.
func m.draw(view, car, setup){
  setup = setup or state.default_setup
  if(setup == null){
    state.default_setup = garage.default()
    setup = state.default_setup
  }
  prepare(setup)
  local shader = state.shader
  shaders.apply(shader, view)
  if(not view.depth_pass){
    shader:set("paint", linear(garage.paint_color(setup)), rl.SHADER_UNIFORM_VEC3)
    shader:set("roofPaint", linear(garage.roof_color(setup)), rl.SHADER_UNIFORM_VEC3)
    local lights = if(car.lights){ 1 } else { 0 }
    local brake = if((car.brake or 0) > 0.05){ 1 } else { 0 }
    local reverse = if((car.direction or 1) < 0){ 1 } else { 0 }
    local bar = if(car.lights and setup.light_bar != "none"){ 1 } else { 0 }
    shader:set("lampsA", {lights, lights, brake}, rl.SHADER_UNIFORM_VEC3)
    shader:set("lampsB", {reverse, car.blink or 0, bar}, rl.SHADER_UNIFORM_VEC3)
    shader:set("dirt", (car.dirt or 0) * 1.0)
    shader:set("dust", (car.dust or 0) * 1.0)
  }
  local q = car.q
  local pos = car.pos
  // a part of the truck: at p in its frame, turned by r, scaled by s
  local func part(model, p, r, s){
    local at = vec.rotate(q, p)
    at.x = at.x + pos.x
    at.y = at.y + pos.y
    at.z = at.z + pos.z
    local turn = q
    if(r != null){
      turn = vec.quat_multiply(q, r)
    }
    rl.draw.mesh(model.mesh, model.material, vec.matrix(at, turn, s or unit))
  }
  local origin = {x: 0, y: 0, z: 0}
  part(state.body, origin)
  part(state.gear, origin)

  // the wheels: each at the end of its suspension
  local wheel = state.wheels[setup.wheels]
  local centers = {}
  for(local i = 0; i < 4; i = i + 1){
    local w = car.wheels[i]
    local at = w.at
    local c = {x: at.x, y: car_lib.SUSPENSION_REST - w.length, z: at.z}
    centers[i] = c
    local r = vec.quat_multiply(
      vec.quat_axis({x: 0, y: 1, z: 0}, w.steer), vec.quat_axis({x: 1, y: 0, z: 0}, w.angle)
    )
    if(at.x < 0){
      // the right side's wheels show their face the other way
      r = vec.quat_multiply(r, half_turn)
    }
    part(wheel, c, r)
  }

  // the axles: between their wheels, tilted as they stand
  for(local a = 0; a < 2; a = a + 1){
    local left = centers[a * 2]
    local right = centers[a * 2 + 1]
    local front = a == 0
    local mid = {x: 0, y: (left.y + right.y) / 2, z: left.z}
    local roll = math.atan2(left.y - right.y, left.x - right.x)
    local tilt = vec.quat_axis({x: 0, y: 0, z: 1}, roll)
    part(if(front){ state.axle_front } else { state.axle_rear }, mid, tilt)
    if(view.depth_pass){
      continue
    }
    local toward = if(front){ -1 } else { 1 }
    for(let local side in values({1, -1})){
      // the spring: from its seat on the axle up to the frame
      local seat = vec.add(mid, vec.rotate(tilt, {x: side * SPRING_SEAT.x, y: SPRING_SEAT.y, z: 0}))
      local top = {x: side * 0.47, y: SPRING_TOP, z: left.z}
      local d = vec.sub(top, seat)
      local l = vec.length(d)
      part(state.spring, seat, from_y(vec.scale(d, 1 / l)), {x: 1, y: l, z: 1})
      // the link: from the axle back (or forward) to the frame
      local hold = vec.add(mid, vec.rotate(tilt, {x: side * LINK_AXLE.x, y: LINK_AXLE.y, z: toward * 0.03}))
      local frame = {x: side * LINK_FRAME.x, y: LINK_FRAME.y, z: left.z + toward * (body.AXLE - LINK_FRAME.z)}
      d = vec.sub(frame, hold)
      l = vec.length(d)
      part(state.rod, hold, from_z(vec.scale(d, 1 / l)), {x: 0.022, y: 0.022, z: l})
    }
    // the shaft: from the transfer case to the differential's nose
    local nose = vec.add(mid, vec.rotate(tilt, {x: if(front){ -0.2 } else { 0 }, y: 0.02, z: toward * 0.3}))
    local case = {x: SHAFT_CASE.x, y: SHAFT_CASE.y, z: if(front){ SHAFT_CASE.front } else { SHAFT_CASE.rear }}
    local d = vec.sub(nose, case)
    local l = vec.length(d)
    part(state.rod, case, from_z(vec.scale(d, 1 / l)), {x: 0.03, y: 0.03, z: l})
  }
}

// winch_point(setup?) -> Vec3: where the winch's rope leaves the truck,
// in the truck's frame (the fairlead of the winch bumper; the same place
// on the others)
func m.winch_point(setup){
  return {x: gear.FAIRLEAD.x, y: gear.FAIRLEAD.y, z: gear.FAIRLEAD.z}
}

// stats() -> {body, gear, wheel: vertices; build, gear_build: ms}
func m.stats(){
  local wheel = null
  for(let local w in values(state.wheels)){
    wheel = w
  }
  return {
    body: state.body.vertices,
    gear: if(state.gear != null){ state.gear.vertices } else { 0 },
    wheel: if(wheel != null){ wheel.vertices } else { 0 },
    build: state.build_time,
    gear_build: state.gear_time or 0,
  }
}

func m.unload(){
  if(state.shader == null){
    return
  }
  unload_part(state.body)
  for(let local g in values(state.gears)){
    unload_part(g)
  }
  unload_part(state.axle_front)
  unload_part(state.axle_rear)
  unload_part(state.spring)
  unload_part(state.rod)
  for(let local w in values(state.wheels)){
    unload_part(w)
  }
  state.shader:unload()
  state.shader = null
  state.gear = null
  state.gear_key = null
  state.gears = {}
  state.gear_count = 0
  state.wheels = {}
}

return m
