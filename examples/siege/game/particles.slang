// game/particles: debris when things break, dust where things land,
// fireballs and smoke from explosions, splashes. Simple bodies of their
// own: a position, a velocity, gravity and drag, a life; drawn as small
// cubes, spheres and sprites with the renderer.
local math = require("slang/math")
local vec = require("game/vec")
local render = require("game/render")

local m = {}

local list = {}
local MAX = 600
local rng = vec.random(99)

local func add(p){
  if(len(list) >= MAX){
    remove(list, 0)
  }
  p.age = 0
  append(list, p)
}

// debris(pos, velocity, size, color, texture, kind): pieces of a thing
// that broke, flying from where it was with its speed and more
func m.debris(pos, velocity, size, color, texture, kind){
  local volume = size.x * size.y * size.z
  if(kind == "sphere"){
    volume = size.x * size.x * size.x * 4
  }
  local count = vec.clamp(to_int(4 + volume * 6), 4, 14)
  local piece = (volume / count) ^ (1 / 3) * 0.9
  for(local i = 0; i < count; i = i + 1){
    local off = {
      x: rng:range(-size.x, size.x) * 0.5,
      y: rng:range(-size.y, size.y) * 0.5,
      z: rng:range(-size.z, size.z) * 0.5,
    }
    add({
      kind: "cube",
      pos: vec.add(pos, off),
      vel: vec.add(vec.scale(velocity, 0.6), {
        x: rng:range(-3, 3) + off.x * 3,
        y: rng:range(1, 5) + off.y * 2,
        z: rng:range(-3, 3) + off.z * 3,
      }),
      size: piece * rng:range(0.6, 1.3),
      color: color,
      texture: texture,
      life: rng:range(1.8, 3.2),
      spin: vec.normalize({x: rng:range(-1, 1), y: rng:range(-1, 1), z: rng:range(-1, 1)}),
      spin_speed: rng:range(2, 9),
      angle: rng:range(0, 6),
      gravity: 1,
    })
  }
}

// puff(pos, size): dust where something hit
func m.puff(pos, size){
  local n = 2 + to_int(size * 2)
  for(local i = 0; i < n; i = i + 1){
    add({
      kind: "puff",
      pos: vec.add(pos, {x: rng:range(-0.3, 0.3), y: 0.1, z: rng:range(-0.3, 0.3)}),
      vel: {x: rng:range(-1.5, 1.5), y: rng:range(0.5, 1.5), z: rng:range(-1.5, 1.5)},
      size: size * rng:range(0.3, 0.6),
      grow: size * 0.8,
      color: {196, 184, 160},
      life: rng:range(0.6, 1.1),
      gravity: -0.05,
      drag: 2,
    })
  }
}

// explosion(pos, radius): a fireball, sparks and smoke
func m.explosion(pos, radius){
  for(local i = 0; i < 6; i = i + 1){
    local d = vec.normalize({x: rng:range(-1, 1), y: rng:range(0, 1), z: rng:range(-1, 1)})
    add({
      kind: "fire",
      pos: vec.add(pos, vec.scale(d, rng:range(0, radius * 0.25))),
      vel: vec.scale(d, rng:range(1, 4)),
      size: radius * rng:range(0.25, 0.45),
      grow: radius * 0.6,
      color: {255, 200, 60},
      life: rng:range(0.35, 0.6),
      gravity: -0.3,
      drag: 3,
    })
  }
  for(local i = 0; i < 14; i = i + 1){
    local d = vec.normalize({x: rng:range(-1, 1), y: rng:range(-0.2, 1), z: rng:range(-1, 1)})
    add({
      kind: "puff",
      pos: vec.add(pos, vec.scale(d, rng:range(0, radius * 0.3))),
      vel: vec.scale(d, rng:range(2, 7)),
      size: radius * rng:range(0.15, 0.35),
      grow: radius * 0.5,
      color: {70, 64, 60},
      life: rng:range(1.2, 2.4),
      gravity: -0.15,
      drag: 1.5,
    })
  }
  for(local i = 0; i < 24; i = i + 1){
    local d = vec.normalize({x: rng:range(-1, 1), y: rng:range(0.1, 1), z: rng:range(-1, 1)})
    add({
      kind: "spark",
      pos: pos,
      vel: vec.scale(d, rng:range(8, 22)),
      size: 0.12,
      color: {255, 230, 120},
      life: rng:range(0.5, 1.2),
      gravity: 1,
      drag: 0.5,
    })
  }
}

// splash(pos): water thrown up
func m.splash(pos){
  for(local i = 0; i < 10; i = i + 1){
    add({
      kind: "drop",
      pos: pos,
      vel: {x: rng:range(-3, 3), y: rng:range(3, 8), z: rng:range(-3, 3)},
      size: rng:range(0.12, 0.3),
      color: {160, 210, 240, 200},
      life: rng:range(0.6, 1.2),
      gravity: 1,
    })
  }
  add({
    kind: "puff",
    pos: pos,
    vel: {x: 0, y: 0.5, z: 0},
    size: 1.2,
    grow: 2.5,
    color: {220, 236, 246},
    life: 0.9,
    gravity: 0,
    drag: 1,
  })
}

func m.update(dt){
  local kept = {}
  for(let local p in values(list)){
    p.age = p.age + dt
    if(p.age < p.life){
      local v = p.vel
      if(p.gravity != null and p.gravity != 0){
        v.y = v.y - 9.81 * p.gravity * dt
      }
      if(p.drag != null){
        local k = math.max(0, 1 - p.drag * dt)
        v.x = v.x * k
        v.y = v.y * k
        v.z = v.z * k
      }
      p.pos = vec.add(p.pos, vec.scale(v, dt))
      if(p.angle != null){
        p.angle = p.angle + p.spin_speed * dt
      }
      append(kept, p)
    }
  }
  list = kept
}

func m.count(){
  return len(list)
}

func m.clear(){
  list = {}
}

local identity = {x: 0, y: 0, z: 0, w: 1}

// draw(ground: Terrain): after the world (the puffs are translucent)
func m.draw(ground){
  local terrain = require("game/terrain")
  for(let local p in values(list)){
    local t = p.age / p.life
    if(p.kind == "cube"){
      local g = terrain.height_at(ground, p.pos.x, p.pos.z)
      if(p.pos.y < g + p.size / 2){
        p.pos.y = g + p.size / 2
        p.vel.y = -p.vel.y * 0.3
        p.vel.x = p.vel.x * 0.8
        p.vel.z = p.vel.z * 0.8
        p.spin_speed = p.spin_speed * 0.7
      }
      local shrink = 1
      if(t > 0.75){
        shrink = (1 - t) / 0.25
      }
      render.draw("cube", vec.matrix(p.pos, vec.quat_axis(p.spin, p.angle), {
        x: p.size * shrink, y: p.size * shrink, z: p.size * shrink
      }), p.color, p.texture)
    } else if(p.kind == "drop"){
      render.sphere(p.pos, p.size * (1 - t * 0.5), p.color)
    } else if(p.kind == "spark"){
      local a = to_int(255 * (1 - t))
      render.draw("cube", vec.matrix(p.pos, identity, {
        x: p.size, y: p.size, z: p.size
      }), {p.color[0], p.color[1], p.color[2], a})
    } else {
      // puffs and fire grow and fade
      local size = p.size + p.grow * t
      local a = to_int(200 * (1 - t) * (1 - t))
      local c = p.color
      if(p.kind == "fire"){
        c = {255, to_int(220 - t * 160), to_int(80 - t * 70)}
        a = to_int(240 * (1 - t))
      }
      render.sphere(p.pos, size, {c[0], c[1], c[2], a})
    }
  }
}

return m
