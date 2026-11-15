// sound/around: what is around the listener, for the layers that sound
// the world (the wind in the trees, the river, the birds, a camp's fire,
// the echo off a rock wall). The land is looked at a few times a second,
// not every frame; the wind is the same for all of them.
//
//   local around = require("sound/around")
//   local a = around.new()
//   around.look(a, world, view, dt)      // every frame
//   a.trees.conifer, a.water.distance, a.walls[2].distance, a.wind.strength
//
// What it says (see [Around]): distances in meters, directions as unit
// vectors on the ground (x, z) from the listener, shares from 0 to 1.
local math = require("slang/math")
local terrain = require("game/terrain")
local plants = require("game/plants")
local surfaces = require("game/surfaces")

local m = {}

// how often the land is looked at, s
m.EVERY = 0.25
// how far the trees count, how far a wall is looked for, how far a camp
// is heard at all, m
m.TREES = 100
m.WALL = 96
m.CAMP = 160

// the kinds of game/plants by what they sound like in the wind
local CONIFER = {}
local BROADLEAF = {}
local BUSH = {}
for(local k = 0; k < len(plants.KINDS); k = k + 1){
  local kind = plants.KINDS[k]
  if(kind.name == "spruce" or kind.name == "fir" or kind.name == "pine"){
    append(CONIFER, k)
  } else if(kind.name == "birch" or kind.name == "oak" or kind.name == "sapling"){
    append(BROADLEAF, k)
  } else if(kind.group == "bush"){
    append(BUSH, k)
  }
}

// What is around.
// type Around = {height: float, ground: float, alpine: float,
//   trees: {conifer: float, broadleaf: float, bush: float},
//   cover: {grass: float, snow: float, rock: float, loose: float, wet: float},
//   water: {distance: float, x: float, z: float, flow: float, lake: float, width: float},
//   camp: {distance: float, x: float, z: float, index: int}?,
//   walls: {{distance: float, rise: float, x: float, z: float}},
//   shelter: float,
//   wind: {strength: float, steady: float, x: float, z: float}}
// [height]: the listener's, m; [ground]: the land's under it
// [alpine]: 0 on the valley's floor to 1 among the summits
// [trees]: how thick each kind stands within TREES (1: a wood)
// [cover]: the shares of the ground about the listener: meadow, snow,
//   bare rock and scree, loose (dirt, gravel, sand), wet (mud, water)
// [water]: the nearest of the river: how far its bank is (0: over it),
//   where, how fast it runs there (0: still, 1: rapids), how much of it is
//   the lake (0 or 1), how wide
// [camp]: the nearest camp within CAMP, its number in world.camps
// [walls]: eight ways around (north first, then by 45 degrees toward the
//   east): how far the land rises over the listener's ears that way
//   (WALL and more: it does not), and how high it then stands over them
// [shelter]: how much of the wind the land and the woods keep off
// [wind]: how hard it blows now, with its gusts (0 to 1), and without
//   them, and where to

// new() -> Around, with nothing around yet
func m.new(){
  local walls = {}
  for(local k = 0; k < 8; k = k + 1){
    local angle = k * math.pi / 4
    append(walls, {distance: 1000, rise: 0, x: math.sin(angle), z: math.cos(angle)})
  }
  return {
    height: 0, ground: 0, alpine: 0,
    trees: {conifer: 0, broadleaf: 0, bush: 0},
    cover: {grass: 0, snow: 0, rock: 0, loose: 0, wet: 0},
    water: {distance: 1000, x: 0, z: 1, flow: 0, lake: 0, width: 0},
    camp: null,
    walls: walls,
    shelter: 0,
    wind: {strength: 0.2, steady: 0.2, x: 0.8, z: 0.55},
    since: 1000,
    time: 0,
  }
}

local func smoothstep(a, b, v){
  local t = (v - a) / (b - a)
  if(t <= 0){
    return 0
  }
  if(t >= 1){
    return 1
  }
  return t * t * (3 - 2 * t)
}

// the trees about a place: each kind's count in the squares around,
// nearer squares counting more, as a share of a wood's
local func trees(a, p, x, z){
  local sums = {0, 0, 0}
  local total = 0
  local lists = {CONIFER, BROADLEAF, BUSH}
  for(let local chunk in values(plants.near(p, x, z, m.TREES))){
    local cx = chunk.x0 + p.size / 2 - x
    local cz = chunk.z0 + p.size / 2 - z
    local w = 1 - math.sqrt(cx * cx + cz * cz) / (m.TREES + p.size / 2)
    if(w <= 0){
      continue
    }
    total = total + w
    if(chunk.count == 0){
      continue
    }
    for(local g = 0; g < 3; g = g + 1){
      for(let local k in values(lists[g])){
        sums[g] = sums[g] + w * (chunk.starts[k + 1] - chunk.starts[k])
      }
    }
  }
  if(total <= 0){
    total = 1
  }
  // (a wood: some forty trees on a square, a thicket twenty bushes)
  a.trees.conifer = math.min(sums[0] / total / 40, 1)
  a.trees.broadleaf = math.min(sums[1] / total / 40, 1)
  a.trees.bush = math.min(sums[2] / total / 20, 1)
}

// the ground about a place: what lies at nine points around it
local func cover(a, land, x, z){
  local c = a.cover
  c.grass = 0
  c.snow = 0
  c.rock = 0
  c.loose = 0
  c.wet = 0
  for(local j = -1; j <= 1; j = j + 1){
    for(local i = -1; i <= 1; i = i + 1){
      local s = terrain.surface_at(land, x + i * 14, z + j * 14)
      if(s == surfaces.grass){
        c.grass = c.grass + 1 / 9
      } else if(s == surfaces.snow or s == surfaces.ice){
        c.snow = c.snow + 1 / 9
      } else if(s == surfaces.rock){
        c.rock = c.rock + 1 / 9
      } else if(s == surfaces.mud or s == surfaces.riverbed){
        c.wet = c.wet + 1 / 9
      } else {
        c.loose = c.loose + 1 / 9
      }
    }
  }
}

// the river's nearest stretch
local func water(a, land, x, z){
  local w = a.water
  local river = land.river
  if(river == null){
    w.distance = 1000
    return
  }
  local points = river.points
  local best = 0
  local least = 1.0e18
  for(local i = 0; i < len(points); i = i + 1){
    local dx = points[i].x - x
    local dz = points[i].z - z
    local d = dx * dx + dz * dz
    if(d < least){
      least = d
      best = i
    }
  }
  local p = points[best]
  local d = math.sqrt(least)
  w.distance = math.max(0, d - p.half)
  w.width = p.half * 2
  if(d > 0.01){
    w.x = (p.x - x) / d
    w.z = (p.z - z) / d
  }
  // how fast it falls there: over the points before and after
  local up = points[math.max(best - 2, 0)]
  local down = points[math.min(best + 2, len(points) - 1)]
  local run = math.sqrt((up.x - down.x) * (up.x - down.x) + (up.z - down.z) * (up.z - down.z))
  local fall = if(run > 1){ math.abs(up.level - down.level) / run } else { 0 }
  w.lake = if(river.lake != null and math.abs(p.z - river.lake.z) < 130){ 1 } else { 0 }
  w.flow = if(w.lake > 0){ 0 } else { math.min(0.25 + fall / 0.05, 1) }
}

// the nearest camp
local func camp(a, world, x, z){
  local best = null
  local least = m.CAMP * m.CAMP
  local camps = world.camps or {}
  for(local i = 0; i < len(camps); i = i + 1){
    local dx = camps[i].x - x
    local dz = camps[i].z - z
    local d = dx * dx + dz * dz
    if(d < least){
      least = d
      best = i
    }
  }
  if(best == null){
    a.camp = null
    return
  }
  local d = math.sqrt(least)
  local c = camps[best]
  a.camp = {
    distance: d, index: best,
    x: if(d > 0.01){ (c.x - x) / d } else { 0 },
    z: if(d > 0.01){ (c.z - z) / d } else { 1 },
  }
}

// where the land rises over the ears, eight ways around
local func walls(a, land, x, y, z){
  local step = 6
  for(let local wall in values(a.walls)){
    wall.distance = 1000
    wall.rise = 0
    for(local d = step; d <= m.WALL; d = d + step){
      local h = terrain.height_at(land, x + wall.x * d, z + wall.z * d)
      if(h > y - 0.5){
        if(wall.distance > m.WALL){
          wall.distance = d
        }
        // how high it stands over the ears in the next twenty meters
        if(d <= wall.distance + 20){
          wall.rise = math.max(wall.rise, h - y)
        }
      }
    }
  }
}

// look(a, world, view, dt): a frame. world: game/world.World, view:
// scene.View (the listener). The wind moves every frame, the land is
// looked at every EVERY seconds.
func m.look(a, world, view, dt){
  a.time = a.time + dt
  a.since = a.since + dt
  local eye = view.eye
  local land = world.land
  if(a.since >= m.EVERY){
    a.since = 0
    a.height = eye.y
    a.ground = terrain.height_at(land, eye.x, eye.z)
    a.alpine = smoothstep(230, 430, a.ground)
    if(world.plants != null){
      trees(a, world.plants, eye.x, eye.z)
    }
    cover(a, land, eye.x, eye.z)
    water(a, land, eye.x, eye.z)
    camp(a, world, eye.x, eye.z)
    walls(a, land, eye.x, eye.y, eye.z)
    // what keeps the wind off: woods, and land standing over the ears
    // on several sides
    local closed = 0
    for(let local wall in values(a.walls)){
      if(wall.distance < 60){
        closed = closed + math.min(wall.rise / 10, 1) / 8
      }
    }
    a.shelter = math.min(1, closed * 0.9 + (a.trees.conifer + a.trees.broadleaf) * 0.45)
  }
  // the wind: it comes and goes over minutes, in gusts over seconds,
  // harder up high, less where there is shelter; it veers slowly
  local t = a.time
  local steady = 0.32 + 0.16 * math.sin(t / 53) + 0.1 * math.sin(t / 17 + 1.3)
  local gust = math.sin(t / 3.7) * math.sin(t / 2.3 + 2) + 0.5 * math.sin(t / 0.9 + 0.7) * math.sin(t / 6.1)
  gust = math.max(gust, 0)
  local where = (0.55 + 0.75 * a.alpine) * (1 - 0.6 * a.shelter)
  local w = a.wind
  w.steady = math.min(steady * where, 1)
  w.strength = math.min((steady + 0.33 * gust * gust) * where, 1)
  local angle = 0.95 + 0.5 * math.sin(t / 71) + 0.2 * math.sin(t / 23)
  w.x = math.sin(angle)
  w.z = math.cos(angle)
}

return m
