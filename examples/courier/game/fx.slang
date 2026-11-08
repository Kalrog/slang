// game/fx: sparks where the car hits, the glow of a pickup, and the
// streaks that fly past at speed. Small things with a life, drawn as
// neon cubes and lines with the renderer.
local rl = require("raylib")
local math = require("slang/math")
local vec = require("game/vec")
local city = require("game/city")
local render = require("game/render")

local m = {}

local sparks = {}
local streaks = {}
local rng = vec.random(5)
local identity = {x: 0, y: 0, z: 0, w: 1}

// sparks(pos, normal, strength): bits of hot metal
func m.sparks(pos, n, strength){
  local count = vec.clamp(to_int(6 + strength * 1.2), 6, 30)
  for(local i = 0; i < count; i = i + 1){
    local d = vec.normalize(vec.add(n, {x: rng:range(-1, 1), y: rng:range(-0.5, 1), z: rng:range(-1, 1)}))
    append(sparks, {
      pos: {x: pos.x, y: pos.y, z: pos.z},
      vel: vec.scale(d, rng:range(4, 10 + strength * 0.4)),
      life: rng:range(0.3, 0.8),
      age: 0,
      size: rng:range(0.08, 0.2),
      color: rng:pick({{255, 200, 90}, {255, 240, 180}, {255, 130, 50}}),
    })
  }
  if(len(sparks) > 400){
    for(local i = 0; i < len(sparks) - 400; i = i + 1){
      remove(sparks, 0)
    }
  }
}

// burst(pos, color): a ring of motes rising, for a pickup or a delivery
func m.burst(pos, color){
  for(local i = 0; i < 24; i = i + 1){
    local a = i / 24 * 2 * math.pi
    append(sparks, {
      pos: {x: pos.x, y: pos.y + 1, z: pos.z},
      vel: {x: math.cos(a) * 6, y: 4 + rng:range(0, 3), z: math.sin(a) * 6},
      life: 1.2,
      age: 0,
      size: 0.25,
      color: color,
      float: true,
    })
  }
}

// update(dt, car, camera)
func m.update(dt, car, camera){
  local kept = {}
  for(let local s in values(sparks)){
    s.age = s.age + dt
    if(s.age < s.life){
      if(s.float == null){
        s.vel.y = s.vel.y - 12 * dt
      }
      s.vel = vec.scale(s.vel, math.exp(-dt * 1.5))
      s.pos = vec.add_scaled(s.pos, s.vel, dt)
      append(kept, s)
    }
  }
  sparks = kept
  // the streaks: motes around the camera that the car's speed sweeps
  // past; the faster, the longer
  local speed = car.speed
  local want = 0
  if(speed > 25){
    want = to_int(vec.clamp((speed - 25) * 1.4, 0, 70))
  }
  for(len(streaks) < want){
    local f = vec.normalize(vec.sub(camera.target, camera.position))
    append(streaks, {
      pos: vec.add(vec.add_scaled(camera.position, f, rng:range(10, 60)), {
        x: rng:range(-25, 25), y: rng:range(-14, 14), z: rng:range(-25, 25),
      }),
      life: rng:range(0.3, 0.7),
      age: 0,
    })
  }
  kept = {}
  for(let local s in values(streaks)){
    s.age = s.age + dt
    if(s.age < s.life and len(kept) < want){
      append(kept, s)
    }
  }
  streaks = kept
}

func m.clear(){
  sparks = {}
  streaks = {}
}

// draw(car): inside the 3D scene
func m.draw(car){
  for(let local s in values(sparks)){
    local k = 1 - s.age / s.life
    render.box(s.pos, identity, {x: s.size, y: s.size, z: s.size},
      {s.color[0], s.color[1], s.color[2], to_int(255 * k)}, city.NEON)
  }
  if(len(streaks) > 0){
    local v = car.vel
    local l = vec.length(v)
    if(l > 1){
      local d = vec.scale(v, math.min(0.09, 6 / l))
      for(let local s in values(streaks)){
        local k = math.sin(s.age / s.life * math.pi)
        rl.draw.line_3d(s.pos, vec.add(s.pos, d), {180, 220, 255, to_int(110 * k)})
      }
    }
  }
}

return m
