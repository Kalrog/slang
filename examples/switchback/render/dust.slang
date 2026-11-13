// render/dust: what the wheels throw up: dust behind them on dry ground,
// clods where they spin in mud, spray where they wade, powder in the
// snow. Each puff is a small picture facing the eye. Where a puff began,
// how it flew off and what it looks like is written once, into a texture
// of numbers; the vertex shader works out from the time where it is by
// now, so that a thousand of them cost the program nothing while they
// drift. The truck gets dirty here too (car.dirt and car.dust, which
// render/truck shows): mud sticks until a ford washes it off, dust
// settles on it as a film of its own.
//
//   dust.init()
//   dust.update(world, time)    // once a frame, after the physics
//   dust.draw(view, world)      // after everything solid
local rl = require("raylib")
local math = require("slang/math")
local buffer = require("slang/buffer")
local vec = require("game/vec")
local terrain_lib = require("game/terrain")
local shaders = require("render/shaders")

local m = {}

m.COUNT = 1024      // puffs at a time: the oldest make room

local vertex = """
in vec3 vertexPosition;   // the corner (x, y: -1 or 1) and which puff (z)
uniform sampler2D dataMap;
uniform vec3 camRight;
uniform vec3 camUp;
out vec2 corner;
out vec4 tint;
out vec3 worldPos;
out float own;

void main(){
  int i = int(vertexPosition.z + 0.5);
  vec4 a = texelFetch(dataMap, ivec2(0, i), 0);   // where it began, and when
  vec4 b = texelFetch(dataMap, ivec2(1, i), 0);   // how it flew off, how long it lasts
  vec4 c = texelFetch(dataMap, ivec2(2, i), 0);   // its color, how thick it is
  vec4 d = texelFetch(dataMap, ivec2(3, i), 0);   // its size at first and at last, its weight, the air's hold on it
  float age = time - a.w;
  if(age < 0.0 || age > b.w || b.w <= 0.0){
    // not there: nowhere on the screen
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
    corner = vec2(0.0);
    tint = vec4(0.0);
    worldPos = vec3(0.0);
    own = 0.0;
    return;
  }
  float t = age / b.w;
  // the air slows it: it gets as far as its speed over the air's hold
  float moved = (1.0 - exp(-d.w * age)) / max(d.w, 0.001);
  vec3 pos = a.xyz + b.xyz * moved;
  pos.y -= 4.9 * d.z * age * age;
  // a breeze takes what is light
  pos.xz += vec2(0.55, 0.38) * age * (1.0 - d.z);
  float size = mix(d.x, d.y, sqrt(t));
  pos += (camRight * vertexPosition.x + camUp * vertexPosition.y) * size;
  worldPos = pos;
  corner = vertexPosition.xy;
  own = fract(a.w * 7.31 + a.x * 0.37);
  // in at once, out slowly
  float fade = smoothstep(0.0, 0.06, t) * (1.0 - t) * (1.0 - t * t);
  tint = vec4(c.rgb, c.a * fade);
  gl_Position = viewProj * vec4(pos, 1.0);
}
"""

local fragment = """
in vec2 corner;
in vec4 tint;
in vec3 worldPos;
in float own;
out vec4 finalColor;

void main(){
  float r = length(corner);
  if(r > 1.0){
    discard;
  }
  // soft at the edge, and lumpy, each its own way
  float lumps = vnoise(corner * 2.1 + own * 31.0) * 0.6 + vnoise(corner * 5.3 - own * 17.0) * 0.4;
  float a = tint.a * smoothstep(1.0, 0.3, r) * (0.5 + 0.8 * lumps);
  if(a < 0.004){
    discard;
  }
  float shadow = landShadow(worldPos) * cloudShadow(worldPos);
  vec3 color = tint.rgb * (sunColor * 0.4 * shadow + ambientLight(vec3(0.0, 1.0, 0.0)));
  finalColor = vec4(finish(color, worldPos), min(a, 1.0));
}
"""

local state = {}

// init(): the puffs' mesh, their numbers, the shader
func m.init(){
  local n = m.COUNT
  local vertices = {}
  local indices = {}
  for(local i = 0; i < n; i = i + 1){
    for(let local corner in values({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}})){
      append(vertices, corner[0])
      append(vertices, corner[1])
      append(vertices, i)
    }
    for(let local k in values({0, 1, 2, 0, 2, 3})){
      append(indices, i * 4 + k)
    }
  }
  state.model = rl.mesh({vertices: vertices, indices: indices}):to_model()
  state.data = buffer.new("float", n * 16)
  state.texture = rl.texture.load_from_image({
    data: state.data, width: 4, height: n, mipmaps: 1,
    format: rl.PIXELFORMAT_UNCOMPRESSED_R32G32B32A32,
  })
  state.texture.filter = rl.TEXTURE_FILTER_POINT
  state.texture.wrap = rl.TEXTURE_WRAP_CLAMP
  state.shader = shaders.load(vertex, fragment)
  state.shader.locs[rl.SHADER_LOC_MAP_ALBEDO] = state.shader:location("dataMap")
  state.material = shaders.use(state.model, state.shader)
  state.material.maps[rl.MATERIAL_MAP_ALBEDO].texture = state.texture
  state.head = 0
  state.changed = false
  state.rng = vec.random(4711)
  state.owed = {0, 0, 0, 0}
  state.time = null
}

// A puff as it is thrown.
// type Puff = {x, y, z, vx, vy, vz, life: float, color: {float},
//   thick: float, size: float, grown: float, weight: float, hold: float}
// [color]: red, green and blue of 255
// [thick]: how much it hides, 0 to 1
// [size]: its half width at first, [grown]: at last, m
// [weight]: how it falls: 0 floats, 1 falls like a stone
// [hold]: how fast the air stops it, 1/s

// throw(puff: Puff, time: float): one more puff in the air
func m.throw(puff, time){
  local d = state.data
  local at = state.head * 16
  d[at] = puff.x
  d[at + 1] = puff.y
  d[at + 2] = puff.z
  d[at + 3] = time
  d[at + 4] = puff.vx
  d[at + 5] = puff.vy
  d[at + 6] = puff.vz
  d[at + 7] = puff.life
  // (the colors are written as the screen has them: to light they are
  // the square of that, about)
  local c = puff.color
  d[at + 8] = (c[0] / 255) * (c[0] / 255)
  d[at + 9] = (c[1] / 255) * (c[1] / 255)
  d[at + 10] = (c[2] / 255) * (c[2] / 255)
  d[at + 11] = puff.thick
  d[at + 12] = puff.size
  d[at + 13] = puff.grown
  d[at + 14] = puff.weight
  d[at + 15] = puff.hold
  state.head = (state.head + 1) % m.COUNT
  state.changed = true
}

// what a wheel throws up in dt seconds on the ground it is on
local func wheel(world, w, i, time, dt){
  local car = world.car
  local rng = state.rng
  local p = w.point
  local f = car.forward
  local l = car.left
  local speed = math.abs(car.speed)
  local spin = math.abs(w.omega * 0.42 - w.along_speed)
  local slide = math.abs(w.across_speed)
  local surface = w.surface
  local depth = terrain_lib.water_at(world.land, p.x, p.z)
  // which way the tread throws: back when it drives forward
  local back = if(w.omega >= 0){ -1 } else { 1 }
  local side = if(w.at.left){ 1 } else { -1 }
  local rate = 0
  local kind = null
  if(depth > 0.06){
    kind = "spray"
    rate = math.min(60, speed * 9 + spin * 6)
  } else if(surface.name == "mud"){
    kind = "clod"
    rate = math.min(34, spin * 9 + math.max(0, speed - 3) * 2.5)
  } else if(surface.name == "snow"){
    kind = "powder"
    rate = math.min(30, speed * 1.4 + spin * 6 + slide * 5)
  } else if(surface.dust > 0){
    kind = "dust"
    rate = math.min(30, surface.dust * (math.max(0, speed - 1.5) * 0.9 + spin * 5 + slide * 4))
    // (the front wheels' dust is in the rear wheels' anyway)
    if(w.at.front){
      rate = rate * 0.4
    }
  }
  state.owed[i] = math.min(3, state.owed[i] + rate * dt)
  for(state.owed[i] >= 1){
    state.owed[i] = state.owed[i] - 1
    local jx = rng:range(-0.14, 0.14)
    local jz = rng:range(-0.2, 0.2)
    local puff = {
      x: p.x + l.x * jx + f.x * jz, y: p.y + 0.08, z: p.z + l.z * jx + f.z * jz,
      color: surface.spray,
    }
    if(kind == "spray"){
      local out = rng:range(1.2, 2.6) + speed * 0.3
      local up = rng:range(1.4, 2.8) + speed * 0.22
      local along = speed * rng:range(0.2, 0.7) * math.sign(car.speed)
      puff.vx = l.x * side * out + f.x * along
      puff.vy = up
      puff.vz = l.z * side * out + f.z * along
      // (from the water's surface)
      puff.y = p.y + depth
      puff.life = rng:range(0.45, 0.85)
      puff.color = {176, 190, 200}
      puff.thick = 0.2
      puff.size = rng:range(0.06, 0.13)
      puff.grown = rng:range(0.28, 0.6)
      puff.weight = 0.8
      puff.hold = 1.3
    } else if(kind == "clod"){
      local throw = rng:range(1.0, 2.2) + spin * 0.45
      puff.vx = f.x * back * throw + l.x * rng:range(-1.1, 1.1) + car.velocity.x * 0.6
      puff.vy = rng:range(1.6, 3.6) + spin * 0.25
      puff.vz = f.z * back * throw + l.z * rng:range(-1.1, 1.1) + car.velocity.z * 0.6
      puff.life = rng:range(0.55, 1.0)
      puff.thick = 1.0
      puff.size = rng:range(0.035, 0.085)
      puff.grown = puff.size
      puff.weight = 1.0
      puff.hold = 0.25
    } else {
      local throw = rng:range(0.2, 0.9) + spin * 0.4
      puff.vx = f.x * back * throw + l.x * rng:range(-0.5, 0.5) + car.velocity.x * 0.25
      puff.vy = rng:range(0.35, 1.3)
      puff.vz = f.z * back * throw + l.z * rng:range(-0.5, 0.5) + car.velocity.z * 0.25
      puff.life = rng:range(1.5, 2.9)
      puff.thick = if(kind == "powder"){ 0.3 } else { 0.16 + 0.2 * surface.dust }
      puff.size = rng:range(0.22, 0.38)
      puff.grown = rng:range(1.1, 2.1)
      puff.weight = if(kind == "powder"){ 0.12 } else { 0.015 }
      puff.hold = 1.7
    }
    m.throw(puff, time)
  }
  // what sticks to the truck, and what washes off: mud (car.dirt) stays
  // until water takes it; dust (car.dust) settles slowly on a dry road
  // and is gone in a ford
  local dirt = car.dirt or 0
  local film = car.dust or 0
  if(depth > 0.12){
    local wash = dt * (0.05 + 0.03 * speed)
    dirt = math.max(0, dirt - wash)
    film = math.max(0, film - wash * 3)
  } else if(surface.name == "mud"){
    // (each wheel on it adds its share: a mud hole at a walk leaves the
    // truck half covered, spinning in it all of it)
    dirt = math.min(1, dirt + dt * (0.006 + 0.012 * math.min(3, spin) + 0.002 * speed))
  } else if(surface.dust > 0.5 and speed > 2){
    // (a minute of dry road for the whole film)
    film = math.min(0.7, film + dt * 0.0008 * surface.dust * (speed - 2))
  }
  car.dirt = dirt
  car.dust = film
}

// update(world, time: float): what the wheels throw up since the last
// frame (time: the clock the view is drawn with)
func m.update(world, time){
  if(state.shader == null){
    return
  }
  local dt = if(state.time == null){ 0 } else { math.min(0.05, time - state.time) }
  state.time = time
  local car = world.car
  if(dt > 0){
    for(local i = 0; i < 4; i = i + 1){
      local w = car.wheels[i]
      if(w.contact){
        wheel(world, w, i, time, dt)
      }
    }
  }
  if(state.changed){
    state.texture:update(state.data)
    state.changed = false
  }
}

// draw(view, world): the puffs, after everything solid (they are seen
// through and hide nothing from each other)
func m.draw(view, world){
  if(view.depth_pass or state.shader == null){
    return
  }
  local shader = state.shader
  shaders.apply(shader, view)
  shader:set("camRight", view.right, rl.SHADER_UNIFORM_VEC3)
  shader:set("camUp", view.up, rl.SHADER_UNIFORM_VEC3)
  rl.depth_mask(false){
    rl.draw.mesh(state.model.meshes[0], state.material, {
      m0: 1, m1: 0, m2: 0, m3: 0, m4: 0, m5: 1, m6: 0, m7: 0,
      m8: 0, m9: 0, m10: 1, m11: 0, m12: 0, m13: 0, m14: 0, m15: 1,
    })
  }
}

func m.unload(){
  if(state.shader != null){
    state.model:unload()
    state.shader:unload()
    state.texture:unload()
    state.shader = null
  }
}

return m
