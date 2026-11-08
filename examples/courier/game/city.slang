// game/city: the night city, made from a seed and a level with no window: blocks of
// towers in tiers with ledges, fins, billboards, halo rings and antennas
// sticking out of them, skybridges and glass tubes between neighbours,
// delivery pads on roofs and balconies, and the lanes the traffic flies.
// Everything solid is an axis-aligned box in a spatial grid, so the car
// finds what is near it fast; the renderer turns the boxes into meshes.
local math = require("slang/math")
local vec = require("game/vec")
local levels = require("game/levels")

local m = {}

// The layout comes from a level (game/levels): n blocks per side, block
// and street widths (their sum, the pitch, even: windows are 2 m), the
// lane heights and the lanes' offsets from a street's middle. A city
// carries its own: c.n, c.pitch, c.block, c.street, c.half (the streets
// at the edge are at +-half), c.lane_levels, c.lane_offsets.
m.CELL = 24              // the spatial grid

// what a box is, for the shader (texcoord u) and the rules
m.WALL = 0        // a facade with windows (param: how many are lit)
m.NEON = 1        // emissive light (param: blink rate, 0 for steady)
m.DARK = 2        // structure: bridges, ledges, struts (param: length)
m.BILLBOARD = 3   // an animated screen (param: style)
m.PAD = 4         // a delivery pad
m.GROUND = 5      // the street level

local facades = {
  {72, 78, 98}, {64, 58, 76}, {88, 72, 80}, {58, 70, 86}, {80, 80, 92},
  {66, 66, 72}, {92, 84, 76},
}
local neons = {
  {0, 230, 255}, {255, 40, 200}, {255, 140, 30}, {150, 255, 60},
  {160, 80, 255}, {255, 60, 60}, {255, 230, 120},
}
local first_names = {
  "Kaito", "Nova", "Helix", "Orion", "Tsuki", "Vektor", "Aurum", "Zenith",
  "Hanzo", "Lumen", "Cobalt", "Ryu", "Mira", "Sato", "Ion", "Delta", "Okami",
  "Pulse", "Nexus", "Kuro", "Astra", "Vire", "Oda", "Halcyon", "Tessen",
}
local second_names = {
  "Tower", "Spire", "Plaza", "Heights", "Works", "Exchange", "Hub",
  "Arcology", "Terminal", "Complex", "Point", "Court",
}

// ------------------------------------------------------------ boxes

local func snap(v, step){
  return math.floor(v / step + 0.5) * step
}

// the cell a coordinate falls in
local OFFSET = 1200

local func cell_key(ix, iy, iz){
  return (ix * 64 + iy) * 1024 + iz
}

local func grid_insert(city, b){
  local c = m.CELL
  local ix0 = to_int(math.floor((b.x0 + OFFSET) / c))
  local ix1 = to_int(math.floor((b.x1 + OFFSET) / c))
  local iy0 = to_int(math.floor(math.max(b.y0, 0) / c))
  local iy1 = to_int(math.floor(math.max(b.y1, 0) / c))
  local iz0 = to_int(math.floor((b.z0 + OFFSET) / c))
  local iz1 = to_int(math.floor((b.z1 + OFFSET) / c))
  for(local ix = ix0; ix <= ix1; ix = ix + 1){
    for(local iy = iy0; iy <= iy1; iy = iy + 1){
      for(local iz = iz0; iz <= iz1; iz = iz + 1){
        local key = cell_key(ix, iy, iz)
        local cell = city.grid[key]
        if(cell == null){
          cell = {}
          city.grid[key] = cell
        }
        append(cell, b)
      }
    }
  }
}

// box(ctx, x0, y0, z0, x1, y1, z1, kind, color, param?) -> the box, added
// to the city, its chunk and the grid
local func box(ctx, x0, y0, z0, x1, y1, z1, kind, color, param){
  local b = {
    x0: math.min(x0, x1), y0: math.min(y0, y1), z0: math.min(z0, z1),
    x1: math.max(x0, x1), y1: math.max(y0, y1), z1: math.max(z0, z1),
    kind: kind, color: color, param: param or 0,
    seed: ctx.rng:int(256), mark: 0,
  }
  b.id = len(ctx.city.boxes)
  append(ctx.city.boxes, b)
  append(ctx.chunk.boxes, b)
  if(kind != m.GROUND){
    grid_insert(ctx.city, b)
  }
  return b
}

// a box attached to a face of b: side 0 +x, 1 -x, 2 +z, 3 -z; gap meters
// off the face, depth meters out from there, a0..a1 fractions along the
// face, y0..y1 absolute
local func attach(ctx, b, side, gap, depth, a0, a1, y0, y1, kind, color, param){
  if(side == 0){
    local z0 = b.z0 + (b.z1 - b.z0) * a0
    local z1 = b.z0 + (b.z1 - b.z0) * a1
    return box(ctx, b.x1 + gap, y0, z0, b.x1 + gap + depth, y1, z1, kind, color, param)
  } else if(side == 1){
    local z0 = b.z0 + (b.z1 - b.z0) * a0
    local z1 = b.z0 + (b.z1 - b.z0) * a1
    return box(ctx, b.x0 - gap - depth, y0, z0, b.x0 - gap, y1, z1, kind, color, param)
  } else if(side == 2){
    local x0 = b.x0 + (b.x1 - b.x0) * a0
    local x1 = b.x0 + (b.x1 - b.x0) * a1
    return box(ctx, x0, y0, b.z1 + gap, x1, y1, b.z1 + gap + depth, kind, color, param)
  }
  local x0 = b.x0 + (b.x1 - b.x0) * a0
  local x1 = b.x0 + (b.x1 - b.x0) * a1
  return box(ctx, x0, y0, b.z0 - gap - depth, x1, y1, b.z0 - gap, kind, color, param)
}

local func face_length(b, side){
  if(side < 2){
    return b.z1 - b.z0
  }
  return b.x1 - b.x0
}

// the outward normal of a side
local normals = {
  {x: 1, y: 0, z: 0}, {x: -1, y: 0, z: 0}, {x: 0, y: 0, z: 1}, {x: 0, y: 0, z: -1},
}

// ------------------------------------------------------------ names

local func unique_name(ctx, base){
  local name = base
  local n = 2
  for(ctx.city.names[name] != null){
    name = concat(base, " ", string(n))
    n = n + 1
  }
  ctx.city.names[name] = true
  return name
}

local func building_name(ctx){
  return unique_name(ctx, concat(ctx.rng:pick(first_names), " ", ctx.rng:pick(second_names)))
}

// ------------------------------------------------------------ pads

// a pad wanted on top of a surface box s (its top face), centered at x,
// z: made at the end, once it is known that nothing hangs over it
local func pad(ctx, s, x, z, name, what){
  append(ctx.city.wanted_pads, {ctx: ctx, surface: s, x: x, z: z, name: name, what: what})
}

local func place_pads(city){
  for(let local p in values(city.wanted_pads)){
    local s = p.surface
    local above = m.query(city, p.x - 5, s.y1 + 0.5, p.z - 5, p.x + 5, s.y1 + 14, p.z + 5)
    if(len(above) == 0){
      local b = box(p.ctx, p.x - 4, s.y1, p.z - 4, p.x + 4, s.y1 + 0.3, p.z + 4, m.PAD, {0, 230, 255})
      append(city.pads, {x: p.x, y: s.y1 + 0.3, z: p.z, name: p.name, what: p.what, box: b})
    }
  }
  city.wanted_pads = null
}

// ------------------------------------------------------------ decoration

local func neon_color(ctx){
  return ctx.rng:pick(neons)
}

// strips of light along the four top edges of a tier
local func crown(ctx, b, color){
  local y0 = b.y1 - 0.2
  local y1 = b.y1 + 0.35
  local t = 0.4
  box(ctx, b.x0 - t, y0, b.z0 - t, b.x1 + t, y1, b.z0, m.NEON, color)
  box(ctx, b.x0 - t, y0, b.z1, b.x1 + t, y1, b.z1 + t, m.NEON, color)
  box(ctx, b.x0 - t, y0, b.z0, b.x0, y1, b.z1, m.NEON, color)
  box(ctx, b.x1, y0, b.z0, b.x1 + t, y1, b.z1, m.NEON, color)
}

// strips of light up the four corners
local func corner_strips(ctx, b, color){
  local t = 0.35
  box(ctx, b.x0 - t, b.y0, b.z0 - t, b.x0, b.y1, b.z0, m.NEON, color)
  box(ctx, b.x1, b.y0, b.z0 - t, b.x1 + t, b.y1, b.z0, m.NEON, color)
  box(ctx, b.x0 - t, b.y0, b.z1, b.x0, b.y1, b.z1 + t, m.NEON, color)
  box(ctx, b.x1, b.y0, b.z1, b.x1 + t, b.y1, b.z1 + t, m.NEON, color)
}

// a ledge the whole length of a side, with a light along its edge
local func ledge(ctx, b, side, y){
  local depth = ctx.rng:range(3, 6)
  attach(ctx, b, side, 0, depth, 0, 1, y, y + 1, m.DARK, {60, 60, 70}, face_length(b, side))
  attach(ctx, b, side, depth - 0.3, 0.3, 0, 1, y + 1, y + 1.4, m.NEON, neon_color(ctx))
}

// a thin vertical fin standing out from a side
local func fin(ctx, b, side, y){
  local l = face_length(b, side)
  local a = ctx.rng:range(0.1, 0.85)
  local h = ctx.rng:range(6, 16)
  attach(ctx, b, side, 0, ctx.rng:range(3, 5), a, a + 0.6 / l, y, y + h, m.DARK, {70, 66, 80}, h)
}

// an animated screen hanging off a side on two struts, a slot between
// it and the wall
local func billboard(ctx, b, side, y){
  local l = face_length(b, side)
  local w = math.min(ctx.rng:range(12, 22), l * 0.7)
  local h = ctx.rng:range(6, 11)
  local a = ctx.rng:range(0.05, 0.95 - w / l)
  local gap = 1.8
  attach(ctx, b, side, gap, 0.5, a, a + w / l, y, y + h, m.BILLBOARD, neon_color(ctx), ctx.rng:int(3))
  local sa = 0.4 / l
  attach(ctx, b, side, 0, gap, a + sa, a + 2 * sa, y + 1, y + 1.6, m.DARK, {50, 50, 58}, gap)
  attach(ctx, b, side, 0, gap, a + w / l - 2 * sa, a + w / l - sa, y + 1, y + 1.6, m.DARK, {50, 50, 58}, gap)
}

// a platform standing out from a side with a pad on it, hung on struts
local func balcony(ctx, b, side, y, name){
  local l = face_length(b, side)
  local w = 10
  if(l < w + 4){
    return
  }
  local a = ctx.rng:range(0.05, 0.95 - w / l)
  local depth = 7
  local slab = attach(ctx, b, side, 0, depth, a, a + w / l, y - 0.8, y, m.DARK, {62, 62, 72}, w)
  // struts under the outer corners
  attach(ctx, b, side, depth - 0.6, 0.6, a, a + 0.6 / l, y - 7, y - 0.8, m.DARK, {50, 50, 58}, 6)
  attach(ctx, b, side, depth - 0.6, 0.6, a + w / l - 0.6 / l, a + w / l, y - 7, y - 0.8, m.DARK, {50, 50, 58}, 6)
  local n = normals[side]
  local cx = (slab.x0 + slab.x1) / 2
  local cz = (slab.z0 + slab.z1) / 2
  // the pad a little out from the wall
  pad(ctx, slab, cx + n.x * 0.6, cz + n.z * 0.6,
    concat(name, " dock ", string(to_int(y / 3))), "balcony")
  // a light strip along the outer edge
  attach(ctx, b, side, depth - 0.3, 0.3, a, a + w / l, y, y + 0.5, m.NEON, neon_color(ctx))
}

// a halo: four slabs around a tier at a height, a gap between them and
// the wall to fly through, lit on the inside
local func halo(ctx, b, y){
  local gap = 6
  local w = 3
  local c = {58, 58, 68}
  local x0 = b.x0 - gap
  local x1 = b.x1 + gap
  local z0 = b.z0 - gap
  local z1 = b.z1 + gap
  box(ctx, x0 - w, y, z0 - w, x1 + w, y + 0.8, z0, m.DARK, c, x1 - x0)
  box(ctx, x0 - w, y, z1, x1 + w, y + 0.8, z1 + w, m.DARK, c, x1 - x0)
  box(ctx, x0 - w, y, z0, x0, y + 0.8, z1, m.DARK, c, z1 - z0)
  box(ctx, x1, y, z0, x1 + w, y + 0.8, z1, m.DARK, c, z1 - z0)
  local n = neon_color(ctx)
  box(ctx, x0, y + 0.8, z0, x1, y + 1.1, z0 + 0.3, m.NEON, n)
  box(ctx, x0, y + 0.8, z1 - 0.3, x1, y + 1.1, z1, m.NEON, n)
  box(ctx, x0, y + 0.8, z0, x0 + 0.3, y + 1.1, z1, m.NEON, n)
  box(ctx, x1 - 0.3, y + 0.8, z0, x1, y + 1.1, z1, m.NEON, n)
}

// a mast on a roof with a blinking light on top
local func antenna(ctx, b, x, z){
  local h = ctx.rng:range(8, 30)
  box(ctx, x - 0.4, b.y1, z - 0.4, x + 0.4, b.y1 + h, z + 0.4, m.DARK, {50, 50, 58}, h)
  box(ctx, x - 0.6, b.y1 + h, z - 0.6, x + 0.6, b.y1 + h + 1, z + 0.6, m.NEON, {255, 60, 60},
    ctx.rng:range(0.7, 1.6))
}

// ------------------------------------------------------------ buildings

// a tower of tiers standing on y = 0 at cx, cz: returns its tier boxes
// (bottom first). Each tier is decorated; the roof gets a pad or masts.
local func tower(ctx, cx, cz, w, d, height, name, base_y){
  local rng = ctx.rng
  local tiers = {}
  local level = ctx.level
  local n = 1 + rng:int(level.tiers)
  if(height < 60){
    n = math.min(n, 1 + rng:int(2))
  }
  local x0 = snap(cx - w / 2, 2)
  local x1 = snap(cx + w / 2, 2)
  local z0 = snap(cz - d / 2, 2)
  local z1 = snap(cz + d / 2, 2)
  local y = base_y or 0
  local left = height
  local facade = rng:pick(facades)
  for(local t = 0; t < n; t = t + 1){
    local th = left
    if(t < n - 1){
      th = snap(left * rng:range(0.35, 0.65), 3)
    } else {
      th = snap(left, 3)
    }
    if(th < 9){
      th = 9
    }
    local b = box(ctx, x0, y, z0, x1, y + th, z1, m.WALL, facade, rng:range(0.2, 0.7))
    append(tiers, b)
    // lights
    if(rng:chance(0.55)){
      crown(ctx, b, neon_color(ctx))
    }
    if(rng:chance(0.3)){
      corner_strips(ctx, b, neon_color(ctx))
    }
    // things sticking out, above the first floors
    local count = rng:int(1 + to_int(level.decor * 3 + 0.5))
    for(local k = 0; k < count; k = k + 1){
      local side = rng:int(4)
      local fy = snap(rng:range(y + 12, y + th - 6), 3)
      if(fy > y + 6 and fy < y + th - 3){
        local r = rng:next()
        if(r < 0.35){
          ledge(ctx, b, side, fy)
        } else if(r < 0.6){
          fin(ctx, b, side, fy)
        } else if(r < 0.85){
          billboard(ctx, b, side, fy)
        } else if(fy > 20){
          balcony(ctx, b, side, fy, name)
        }
      }
    }
    if(th > 40 and rng:chance(level.halos)){
      halo(ctx, b, snap(rng:range(y + 15, y + th - 10), 3))
    }
    y = y + th
    left = left - th
    // the next tier stands inset on this one
    local ix = snap(rng:range(2, 10), 2)
    local iz = snap(rng:range(2, 10), 2)
    local sx = snap(rng:range(-ix, ix), 2)
    local sz = snap(rng:range(-iz, iz), 2)
    x0 = x0 + ix + sx
    x1 = x1 - ix + sx
    z0 = z0 + iz + sz
    z1 = z1 - iz + sz
    if(x1 - x0 < 10 or z1 - z0 < 10 or left < 9){
      break
    }
  }
  // the roof
  local top = tiers[len(tiers) - 1]
  local rw = top.x1 - top.x0
  local rd = top.z1 - top.z0
  if(rw >= 14 and rd >= 14 and rng:chance(0.7)){
    pad(ctx, top, (top.x0 + top.x1) / 2, (top.z0 + top.z1) / 2, concat(name, " rooftop"), "roof")
    if(rng:chance(0.6)){
      antenna(ctx, top, top.x0 + 2, top.z0 + 2)
    }
  } else {
    local k = 1 + rng:int(2)
    for(local i = 0; i < k; i = i + 1){
      antenna(ctx, top, rng:range(top.x0 + 1, top.x1 - 1), rng:range(top.z0 + 1, top.z1 - 1))
    }
  }
  return tiers
}

// a bridge between two tier boxes a and b (a is lower in x or z) at
// height y: a slab with rails, or a glass tube to fly through
local func bridge(ctx, a, b, y, axis){
  local rng = ctx.rng
  local tube = rng:chance(ctx.level.tubes)
  local w = 7
  if(tube){
    w = 9
  }
  local n = neon_color(ctx)
  local c = {64, 64, 74}
  if(axis == "x"){
    local lo = math.max(a.z0, b.z0)
    local hi = math.min(a.z1, b.z1)
    if(hi - lo < w + 2){
      return false
    }
    local zc = rng:range(lo + w / 2 + 1, hi - w / 2 - 1)
    local x0 = a.x1
    local x1 = b.x0
    box(ctx, x0, y, zc - w / 2, x1, y + 1.2, zc + w / 2, m.DARK, c, x1 - x0)
    if(tube){
      box(ctx, x0, y + 7.5, zc - w / 2, x1, y + 8.5, zc + w / 2, m.DARK, c, x1 - x0)
      box(ctx, x0, y + 1.2, zc - w / 2, x1, y + 7.5, zc - w / 2 + 0.5, m.WALL, {70, 80, 100}, 0.9)
      box(ctx, x0, y + 1.2, zc + w / 2 - 0.5, x1, y + 7.5, zc + w / 2, m.WALL, {70, 80, 100}, 0.9)
      box(ctx, x0, y + 8.5, zc - 0.3, x1, y + 8.8, zc + 0.3, m.NEON, n)
    } else {
      box(ctx, x0, y + 1.2, zc - w / 2, x1, y + 1.7, zc - w / 2 + 0.3, m.NEON, n)
      box(ctx, x0, y + 1.2, zc + w / 2 - 0.3, x1, y + 1.7, zc + w / 2, m.NEON, n)
    }
  } else {
    local lo = math.max(a.x0, b.x0)
    local hi = math.min(a.x1, b.x1)
    if(hi - lo < w + 2){
      return false
    }
    local xc = rng:range(lo + w / 2 + 1, hi - w / 2 - 1)
    local z0 = a.z1
    local z1 = b.z0
    box(ctx, xc - w / 2, y, z0, xc + w / 2, y + 1.2, z1, m.DARK, c, z1 - z0)
    if(tube){
      box(ctx, xc - w / 2, y + 7.5, z0, xc + w / 2, y + 8.5, z1, m.DARK, c, z1 - z0)
      box(ctx, xc - w / 2, y + 1.2, z0, xc - w / 2 + 0.5, y + 7.5, z1, m.WALL, {70, 80, 100}, 0.9)
      box(ctx, xc + w / 2 - 0.5, y + 1.2, z0, xc + w / 2, y + 7.5, z1, m.WALL, {70, 80, 100}, 0.9)
      box(ctx, xc - 0.3, y + 8.5, z0, xc + 0.3, y + 8.8, z1, m.NEON, n)
    } else {
      box(ctx, xc - w / 2, y + 1.2, z0, xc - w / 2 + 0.3, y + 1.7, z1, m.NEON, n)
      box(ctx, xc + w / 2 - 0.3, y + 1.2, z0, xc + w / 2, y + 1.7, z1, m.NEON, n)
    }
  }
  return true
}

// the tier of a tower that spans height y
local func tier_at(tiers, y){
  for(let local t in values(tiers)){
    if(y >= t.y0 + 3 and y + 9 <= t.y1){
      return t
    }
  }
  return null
}

// ------------------------------------------------------------ the city

local func new_chunk(city, cx, cz){
  local chunk = {boxes: {}, cx: cx, cz: cz}
  append(city.chunks, chunk)
  return chunk
}

// generate(seed, level?) -> City {seed, level, n, pitch, block, street,
// half, lane_levels, lane_offsets, boxes, chunks, pads, lanes, grid,
// blocks, names}
func m.generate(seed, level){
  seed = seed or 1
  level = level or levels.default
  local N = level.n
  local city = {
    seed: seed, level: level,
    n: N, block: level.block, street: level.street, pitch: level.block + level.street,
    lane_levels: level.lane_levels, lane_offsets: level.lane_offsets,
    boxes: {}, chunks: {}, pads: {}, lanes: {}, grid: {},
    blocks: {}, names: {}, stamp: 0, wanted_pads: {},
  }
  city.half = N * city.pitch / 2
  local center_rng = vec.random(seed)
  // the ground, one box in a chunk of its own (not in the grid)
  local ground = {city: city, chunk: new_chunk(city, 0, 0), rng: center_rng, level: level}
  local g = city.half + 400
  box(ground, -g, -4, -g, g, 0, g, m.GROUND, {20, 16, 28})
  // the blocks
  for(local i = 0; i < N; i = i + 1){
    for(local j = 0; j < N; j = j + 1){
      local cx = (i - (N - 1) / 2) * city.pitch
      local cz = (j - (N - 1) / 2) * city.pitch
      local rng = vec.random(seed * 7919 + i * 131 + j * 17 + 3)
      local ctx = {city: city, chunk: new_chunk(city, cx, cz), rng: rng, level: level}
      // taller toward the middle, with some noise
      local dx = (i - (N - 1) / 2) / (N / 2)
      local dz = (j - (N - 1) / 2) / (N / 2)
      local centrality = 1 - math.min(1, math.sqrt(dx * dx + dz * dz))
      local nz = vec.noise(i * 0.7 + 0.3, j * 0.7 + 0.3, seed) * 0.5 + 0.5
      local lo = level.height[0]
      local hi = level.height[1]
      local height = lo + (hi - lo) * (0.25 + 0.75 * centrality) * (0.55 + 0.45 * nz)
      height = snap(height, 3)
      local name = building_name(ctx)
      local block = {i: i, j: j, cx: cx, cz: cz, name: name, towers: {}}
      local r = rng:next()
      if(r < 0.6){
        // one tower
        local w = rng:range(city.block * 0.55, city.block * 0.88)
        local d = rng:range(city.block * 0.55, city.block * 0.88)
        append(block.towers, tower(ctx, cx + rng:range(-2, 2), cz + rng:range(-2, 2), w, d, height, name))
      } else if(r < 0.85){
        // twins, a bridge between them
        local along_x = rng:chance(0.5)
        local w = city.block * 0.36
        local d = rng:range(city.block * 0.5, city.block * 0.9)
        local h2 = snap(height * rng:range(0.55, 0.95), 3)
        local t1 = null
        local t2 = null
        if(along_x){
          t1 = tower(ctx, cx - city.block * 0.28, cz, w, d, height, name)
          t2 = tower(ctx, cx + city.block * 0.28, cz, w, d, h2, unique_name(ctx, concat(name, " annex")))
        } else {
          t1 = tower(ctx, cx, cz - city.block * 0.28, d, w, height, name)
          t2 = tower(ctx, cx, cz + city.block * 0.28, d, w, h2, unique_name(ctx, concat(name, " annex")))
        }
        append(block.towers, t1)
        append(block.towers, t2)
        local y = snap(rng:range(15, math.min(height, h2) - 15), 3)
        local a = tier_at(t1, y)
        local b = tier_at(t2, y)
        if(a != null and b != null){
          local axis = "z"
          if(along_x){
            axis = "x"
          }
          bridge(ctx, a, b, y, axis)
        }
      } else {
        // a wide low base with a slim tower on it
        local w = city.block * 0.88
        local base = tower(ctx, cx, cz, w, w, snap(rng:range(24, 45), 3), name)
        local top = base[len(base) - 1]
        local tw = rng:range(16, 26)
        local tx = rng:range(top.x0 + tw / 2 + 2, top.x1 - tw / 2 - 2)
        local tz = rng:range(top.z0 + tw / 2 + 2, top.z1 - tw / 2 - 2)
        local spire = tower(ctx, tx, tz, tw, tw, height, unique_name(ctx, concat(name, " spire")), top.y1)
        append(block.towers, base)
        append(block.towers, spire)
      }
      block.ctx = ctx
      city.blocks[i * N + j] = block
    }
  }
  // bridges between neighbouring blocks, between the lanes' heights
  for(local i = 0; i < N; i = i + 1){
    for(local j = 0; j < N; j = j + 1){
      local block = city.blocks[i * N + j]
      local ctx = block.ctx
      local rng = ctx.rng
      for(let local d in values({{1, 0}, {0, 1}})){
        local ni = i + d[0]
        local nj = j + d[1]
        if(ni < N and nj < N and rng:chance(level.bridges)){
          local other = city.blocks[ni * N + nj]
          local count = 1 + rng:int(1 + to_int(level.bridges * 1.5))
          for(local k = 0; k < count; k = k + 1){
            local ly = rng:int(len(city.lane_levels) - 1)
            local y = city.lane_levels[ly] + 15
            // the towers nearest each other across the street
            local a = null
            local b = null
            local best = 1e9
            for(let local ta in values(block.towers)){
              for(let local tb in values(other.towers)){
                local ya = tier_at(ta, y)
                local yb = tier_at(tb, y)
                if(ya != null and yb != null){
                  local gap = 0
                  if(d[0] == 1){
                    gap = yb.x0 - ya.x1
                  } else {
                    gap = yb.z0 - ya.z1
                  }
                  if(gap > 4 and gap < best){
                    best = gap
                    a = ya
                    b = yb
                  }
                }
              }
            }
            if(a != null){
              local axis = "z"
              if(d[0] == 1){
                axis = "x"
              }
              bridge(ctx, a, b, y, axis)
            }
          }
        }
      }
    }
  }
  place_pads(city)
  // the chunks' extents, for culling
  for(let local chunk in values(city.chunks)){
    local x0 = 1e9
    local y0 = 1e9
    local z0 = 1e9
    local x1 = -1e9
    local y1 = -1e9
    local z1 = -1e9
    for(let local b in values(chunk.boxes)){
      x0 = math.min(x0, b.x0)
      y0 = math.min(y0, b.y0)
      z0 = math.min(z0, b.z0)
      x1 = math.max(x1, b.x1)
      y1 = math.max(y1, b.y1)
      z1 = math.max(z1, b.z1)
    }
    chunk.center = {x: (x0 + x1) / 2, y: (y0 + y1) / 2, z: (z0 + z1) / 2}
    chunk.radius = vec.distance(chunk.center, {x: x0, y: y0, z: z0})
  }
  // the lanes: both ways along every street at every level, one or
  // more side by side in each direction
  for(local k = 0; k <= N; k = k + 1){
    local at = (k - N / 2) * city.pitch
    for(let local y in values(city.lane_levels)){
      for(let local dir in values({1, -1})){
        for(let local offset in values(city.lane_offsets)){
          append(city.lanes, {axis: "x", at: at + dir * offset, y: y, dir: dir})
          append(city.lanes, {axis: "z", at: at - dir * offset, y: y, dir: dir})
        }
      }
    }
  }
  for(let local block in values(city.blocks)){
    block.ctx = null
  }
  return city
}

// ------------------------------------------------------------ queries

// query(city, x0, y0, z0, x1, y1, z1) -> the boxes that may overlap the
// region (those sharing a grid cell with it)
func m.query(city, x0, y0, z0, x1, y1, z1){
  local c = m.CELL
  city.stamp = city.stamp + 1
  local stamp = city.stamp
  local out = {}
  local ix0 = to_int(math.floor((x0 + OFFSET) / c))
  local ix1 = to_int(math.floor((x1 + OFFSET) / c))
  local iy0 = to_int(math.floor(math.max(y0, 0) / c))
  local iy1 = to_int(math.floor(math.max(y1, 0) / c))
  local iz0 = to_int(math.floor((z0 + OFFSET) / c))
  local iz1 = to_int(math.floor((z1 + OFFSET) / c))
  for(local ix = ix0; ix <= ix1; ix = ix + 1){
    for(local iy = iy0; iy <= iy1; iy = iy + 1){
      for(local iz = iz0; iz <= iz1; iz = iz + 1){
        local cell = city.grid[cell_key(ix, iy, iz)]
        if(cell != null){
          for(let local b in values(cell)){
            if(b.mark != stamp){
              b.mark = stamp
              if(b.x1 >= x0 and b.x0 <= x1 and b.y1 >= y0 and b.y0 <= y1 and b.z1 >= z0 and b.z0 <= z1){
                append(out, b)
              }
            }
          }
        }
      }
    }
  }
  return out
}

// the box containing point p, if any (the ground counts)
func m.box_at(city, p){
  if(p.y <= 0){
    return city.boxes[0]
  }
  local c = m.CELL
  local cell = city.grid[cell_key(
    to_int(math.floor((p.x + OFFSET) / c)),
    to_int(math.floor(p.y / c)),
    to_int(math.floor((p.z + OFFSET) / c)),
  )]
  if(cell == null){
    return null
  }
  for(let local b in values(cell)){
    if(p.x >= b.x0 and p.x <= b.x1 and p.y >= b.y0 and p.y <= b.y1 and p.z >= b.z0 and p.z <= b.z1){
      return b
    }
  }
  return null
}

// raycast(city, origin, dir (unit), max) -> {dist, box} of the first box
// along the ray (stepping, so a thin box may be missed), or null
func m.raycast(city, origin, dir, max){
  local step = 1.5
  for(local t = 0; t <= max; t = t + step){
    local p = vec.add_scaled(origin, dir, t)
    local b = m.box_at(city, p)
    if(b != null){
      return {dist: t, box: b}
    }
  }
  return null
}

// the pad nearest a point
func m.nearest_pad(city, p){
  local best = null
  local bd = 1e18
  for(let local pad in values(city.pads)){
    local d = vec.distance(pad, p)
    if(d < bd){
      bd = d
      best = pad
    }
  }
  return best
}

return m
