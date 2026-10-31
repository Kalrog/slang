// game/ammo: what the catapult throws. A rock; a triple shot of three
// smaller rocks; a bomb that goes off when it lands (or after a while);
// a chain shot, two balls on a rope that wrap around what they hit.
local math = require("slang/math")
local vec = require("game/vec")

local m = {}

m.types = {
  rock: {
    name: "Rock",
    key: "1",
    radius: 0.42,
    density: 2600,
    color: {150, 146, 140},
    texture: "rough",
    describe: "a plain heavy stone",
  },
  triple: {
    name: "Triple shot",
    key: "2",
    radius: 0.28,
    density: 2600,
    color: {150, 146, 140},
    texture: "rough",
    describe: "three stones at once, spread wide",
  },
  bomb: {
    name: "Bomb",
    key: "3",
    radius: 0.4,
    density: 1400,
    color: {46, 44, 48},
    texture: "barrel",
    describe: "explodes where it lands",
  },
  chain: {
    name: "Chain shot",
    key: "4",
    radius: 0.3,
    density: 2600,
    color: {120, 118, 124},
    texture: "rough",
    describe: "two balls on a chain: they whip through walls",
  },
}

m.order = {"rock", "triple", "bomb", "chain"}

local func projectile(w, kind, pos, velocity, extra){
  local t = m.types[kind]
  local spec = {
    kind: "sphere",
    material: "rock",
    pos: pos,
    size: {x: t.radius, y: t.radius, z: t.radius},
    velocity: velocity,
    projectile: true,
    density: t.density,
    color: t.color,
    restitution: 0.1,
  }
  if(extra != null){
    for(let local e in entries(extra)){
      spec[e[0]] = e[1]
    }
  }
  local e = w:add(spec)
  e.texture = t.texture
  e.ammo = kind
  return e
}

// a direction turned a little: by yaw and pitch angles about the world up
// and the direction's own right
local func spread(dir, yaw, pitch){
  local right = vec.normalize(vec.cross(dir, {x: 0, y: 1, z: 0}))
  local up = vec.cross(right, dir)
  return vec.normalize(vec.add(dir, vec.add(vec.scale(right, math.tan(yaw)),
    vec.scale(up, math.tan(pitch)))))
}

// fire(w, kind, shot) -> {Entity}: the projectiles of a shot ({pos,
// direction, speed}) in the world
func m.fire(w, kind, shot){
  local out = {}
  local v = vec.scale(shot.direction, shot.speed)
  if(kind == "triple"){
    for(let local a in values({-0.12, 0, 0.12})){
      local d = spread(shot.direction, a, math.abs(a) * 0.3)
      append(out, projectile(w, kind, vec.add(shot.pos, vec.scale(d, 0.1)),
        vec.scale(d, shot.speed * 0.95)))
    }
  } else if(kind == "bomb"){
    local e = projectile(w, kind, shot.pos, v)
    e.fuse = 5
    append(out, e)
  } else if(kind == "chain"){
    local right = vec.normalize(vec.cross(shot.direction, {x: 0, y: 1, z: 0}))
    local gap = 1.4
    local a = projectile(w, kind, vec.add(shot.pos, vec.scale(right, -gap / 2)),
      vec.add(v, vec.scale(right, -6)))
    local b = projectile(w, kind, vec.add(shot.pos, vec.scale(right, gap / 2)),
      vec.add(v, vec.scale(right, 6)))
    w:add_joint({type: "distance", a: a, b: b, min: 0, max: 3})
    a.chained = b
    b.chained = a
    append(out, a)
    append(out, b)
  } else {
    append(out, projectile(w, kind, shot.pos, v))
  }
  for(let local e in values(out)){
    e.born = w.time
  }
  return out
}

// damping as the projectiles are made: the trajectory line uses it too
m.damping = 0.05

return m
