// game/props: what is set on the trail by hand, where game/plants only
// scatters beside it: the stones of a rock garden (low ones in the track
// to crawl over, boulders at its edges to steer between), the logs of a
// deadfall lying across it, and a cairn at the summit. All of them are
// records like any plant's: render/flora draws them and the physics
// takes them as solids.
//
//   props.add(plants, props.trail(land, trail))
local math = require("slang/math")
local kernel = require("kernel")
local vec = require("game/vec")
local terrain = require("game/terrain")
local plants = require("game/plants")
local sow = require("game/plants_sow")
local route = require("game/route")

local m = {}

// how a rock shape stands at scale 1: how far its top and its underside
// are from its middle, and how far it reaches sideways
local shapes = null

local func shape_sizes(){
  if(shapes != null){
    return shapes
  }
  shapes = {}
  for(let local rock in values(plants.rock_shapes())){
    local top = -1.0e9
    local bottom = 1.0e9
    local wide = 0
    for(let local p in values(rock.hull)){
      top = math.max(top, p.y)
      bottom = math.min(bottom, p.y)
      wide = math.max(wide, math.sqrt(p.x * p.x + p.z * p.z))
    }
    append(shapes, {top: top, bottom: bottom, wide: wide})
  }
  return shapes
}

// a rock of a size whose top stands `over` meters out of the ground at a
// place (the rest of it is in the ground)
local func rock(land, rng, x, z, size, over){
  local sizes = shape_sizes()
  local shape = rng:int(len(sizes))
  local ground = terrain.height_at(land, x, z)
  return {
    kind: plants.ROCK + shape, x: x, z: z, y: ground + over - sizes[shape].top * size,
    yaw: rng:range(0, 2 * math.pi), scale: size, tint: rng:next(),
  }
}

// trail(land, trail: route.Trail) -> {Record}: what stands on a trail's
// obstacles: for each rock garden its stones, for each deadfall its logs,
// and the summit's cairn. Records as game/plants' place takes them.
func m.trail(land, trail){
  local out = {}
  local points = trail.points
  local count = len(points)
  // a place on the trail: s meters along it, off meters to the left
  local func at(s, off){
    local i = math.min(count - 2, to_int(s / route.STEP))
    local t = s / route.STEP - i
    local a = points[i]
    local b = points[i + 1]
    local yaw = route.direction(trail, i)
    return {
      x: a.x + (b.x - a.x) * t + math.cos(yaw) * off,
      z: a.z + (b.z - a.z) * t - math.sin(yaw) * off,
      yaw: yaw,
    }
  }
  for(let local section in values(trail.sections)){
    local rng = vec.random(land.seed * 977 + to_int(section.from) * 13 + 5)
    if(section.kind == "rocks"){
      // stones in the track: every meter or so a row of them, under one
      // wheel or the other more often than between; none taller than the
      // truck can pass over (lower still between the wheels)
      for(local s = section.from + 4; s < section.to - 4; s = s + rng:range(1.0, 1.5)){
        for(let local lane in values({0.8, -0.8, 0, 1.75, -1.75})){
          local chance = if(lane == 0){ 0.3 } else if(math.abs(lane) < 1){ 0.5 } else { 0.4 }
          if(rng:chance(chance)){
            local p = at(s + rng:range(-0.4, 0.4), lane + rng:range(-0.3, 0.3))
            local over = if(lane == 0){ rng:range(0.08, 0.17) } else { rng:range(0.12, 0.27) }
            append(out, rock(land, rng, p.x, p.z, rng:range(0.55, 0.95), over))
          }
        }
      }
      // boulders at the track's edges, on one side and then the other
      local side = if(rng:chance(0.5)){ 1 } else { -1 }
      for(local s = section.from + 3; s < section.to - 2; s = s + rng:range(6.5, 9.5)){
        local size = rng:range(1.5, 2.4)
        local half = points[math.min(count - 1, to_int(s / route.STEP))].half
        local p = at(s, side * (half + size * 0.28 + rng:range(0, 0.5)))
        append(out, rock(land, rng, p.x, p.z, size, size * rng:range(0.42, 0.55)))
        side = -side
      }
    } else if(section.kind == "logs"){
      // trunks fallen across the track, each a little askew, half sunk in
      local spec = plants.KINDS[plants.LOG]
      for(let local where in values({7, 13.5, 20})){
        local p = at(section.from + where + rng:range(-0.8, 0.8), rng:range(-0.3, 0.3))
        local size = rng:range(0.62, 0.74)
        local radius = spec.radius * size
        append(out, {
          kind: plants.LOG, x: p.x, z: p.z, y: terrain.height_at(land, p.x, p.z) + radius * 0.62,
          yaw: p.yaw + math.pi / 2 + rng:range(0.2, 0.42) * (if(rng:chance(0.5)){ 1 } else { -1 }),
          scale: size, tint: rng:next(),
        })
      }
    }
  }
  // the cairn: stones piled at the far side of the summit
  if(trail.summit != null){
    local rng = vec.random(land.seed * 31 + 3)
    local last = at((count - 1) * route.STEP, 0)
    local cx = trail.summit.x + math.sin(last.yaw) * 4.6
    local cz = trail.summit.z + math.cos(last.yaw) * 4.6
    local ground = terrain.height_at(land, cx, cz)
    local sizes = shape_sizes()
    // (three rings, each smaller and higher, and one on top)
    local rings = {{count: 6, radius: 0.72, size: 0.62, y: 0.12}, {count: 4, radius: 0.4, size: 0.52, y: 0.5},
      {count: 1, radius: 0, size: 0.46, y: 0.86}}
    for(let local ring in values(rings)){
      for(local k = 0; k < ring.count; k = k + 1){
        local a = k * 2 * math.pi / ring.count + rng:range(-0.2, 0.2)
        local shape = rng:int(len(sizes))
        local size = ring.size * rng:range(0.9, 1.1)
        append(out, {
          kind: plants.ROCK + shape, x: cx + math.sin(a) * ring.radius, z: cz + math.cos(a) * ring.radius,
          y: ground + ring.y - sizes[shape].bottom * size * 0.5, yaw: rng:range(0, 6.28), scale: size,
          tint: rng:next(),
        })
      }
    }
  }
  return out
}

// add(p: plants.Plants, records: {Record}): records set down by hand
// (as game/plants' place takes them) added to what stands on a land.
// Before render/flora or the physics have looked at it.
func m.add(p, records){
  local stride = plants.STRIDE
  local kinds = len(plants.KINDS)
  local lists = {}
  for(let local r in values(records)){
    local chunk = plants.chunk_at(p, r.x, r.z)
    if(chunk != null){
      if(lists[chunk.index] == null){
        lists[chunk.index] = {}
      }
      append(lists[chunk.index], r)
    }
  }
  local starts = kernel.int32:array(kinds + 1)
  local bounds = kernel.float:array(2)
  for(let local e in entries(lists)){
    local chunk = p.chunks[e[0]]
    local list = e[1]
    local had = chunk.count
    local n = had + len(list)
    local all = kernel.float:array(n * stride)
    for(local i = 0; i < had * stride; i = i + 1){
      all[i] = chunk.data[i]
    }
    for(local j = 0; j < len(list); j = j + 1){
      local r = list[j]
      local kind = r.kind
      if(type(kind) == "string"){
        kind = plants.by_name[kind].index
      }
      local at = (had + j) * stride
      all[at + plants.X] = r.x
      all[at + plants.Y] = r.y or terrain.height_at(p.land, r.x, r.z)
      all[at + plants.Z] = r.z
      all[at + plants.YAW] = r.yaw or 0
      all[at + plants.PITCH] = r.pitch or 0
      all[at + plants.ROLL] = r.roll or 0
      all[at + plants.SCALE] = r.scale or 1
      all[at + plants.KIND] = kind
      all[at + plants.TINT] = r.tint or 0.5
      all[at + plants.EXTRA] = r.extra or 0
      local spec = plants.KINDS[kind]
      p.counts[spec.name] = (p.counts[spec.name] or 0) + 1
      p.groups[spec.group] = (p.groups[spec.group] or 0) + 1
    }
    // (in the order of their kinds, as every chunk's records are)
    local data = kernel.float:array(n * stride)
    chunk.count = sow.arrange(all, n, data, starts, kinds, bounds)
    chunk.data = data
    chunk.low = bounds[0]
    chunk.high = bounds[1]
    for(local k = 0; k <= kinds; k = k + 1){
      chunk.starts[k] = starts[k]
    }
    chunk.solids = null
    p.total = p.total + len(list)
  }
}

return m
