// game/terrain: the land. A valley between mountains, made from a seed:
// a river runs down its middle through a lake, the floor beside it is
// meadow, the sides rise into ridges cut by gullies, with ledges of rock
// where the strata show. The land is a grid of heights a meter apart
// (2048 by 2048 of them), computed by kernels (packages/kernel) in about
// a second; the physics gets it as a Jolt height field, the renderer as
// a texture, and the game asks it how high and how steep the ground is
// at a point and what it is made of.
//
//   local land = terrain.generate(7)
//   terrain.height_at(land, x, z)
//   terrain.surface_at(land, x, z)     // a surface of game/surfaces
//
// x and z are the two horizontal axes (the river flows toward -z), y is
// up; the origin is the middle of the map. The kernels are in
// game/land.kernel.
local kernel = require("kernel")
local math = require("slang/math")
local vec = require("game/vec")
local surfaces = require("game/surfaces")
local isolate = require("slang/isolate")
local os = require("slang/os")
local land = require("game/land")

local m = {}

m.SIZE = 2048       // samples along a side
m.SPACING = 1.0     // meters between them
// what drives on the land and what draws it take its heights finer than
// that: FINE samples for each one along a side (see [refine])
m.FINE = 2

// the river: a line of points down the valley from north to south, each
// {x, z, level: the water's height, half: half its width, m}; it winds,
// falls gently and spreads into a lake in the middle of the map
local func river_points(rng, half){
  local points = {}
  local phase1 = rng:range(0, 6.28)
  local phase2 = rng:range(0, 6.28)
  local phase3 = rng:range(0, 6.28)
  local lake_z = rng:range(-140, 120)
  local reach = half + 420
  local step = 22
  local count = to_int(reach * 2 / step) + 1
  local top = 58
  local bottom = 6
  for(local i = 0; i < count; i = i + 1){
    local z = reach - i * step
    local x = 190 * math.sin(z * 0.0031 + phase1) + 80 * math.sin(z * 0.0083 + phase2) +
      26 * math.sin(z * 0.021 + phase3)
    local k = i / (count - 1)
    local level = top + (bottom - top) * k
    local width = 5.5 + 1.6 * math.sin(z * 0.017 + phase2)
    // the lake: level across its length, wide in its middle
    local in_lake = 1 - vec.clamp(math.abs(z - lake_z) / 150, 0, 1)
    if(in_lake > 0){
      local s = in_lake * in_lake * (3 - 2 * in_lake)
      width = width + 125 * s
    }
    append(points, {x: x, z: z, level: level, half: width})
  }
  // the lake's water is level: every point in it takes the level of its
  // lower end, and the river above it steps down to that over a stretch
  local lake_level = null
  for(let local p in values(points)){
    if(math.abs(p.z - lake_z) < 150 and (lake_level == null or p.level < lake_level)){
      lake_level = p.level
    }
  }
  for(let local p in values(points)){
    local dz = p.z - lake_z
    if(math.abs(dz) < 150){
      p.level = lake_level
    } else if(dz >= 150 and dz < 420){
      // above the lake: the fall that was skipped is spread over rapids
      local k = (dz - 150) / 270
      local natural = p.level
      p.level = lake_level + (natural - lake_level) * k * k
    }
  }
  return {points: points, step: step, lake: {z: lake_z, level: lake_level}}
}

// the rows j0 to j1 of something a module of kernels computes, in an
// isolate of its own (it crosses as code: it uses only what it is given)
local func band(module, name, j0, j1, ...rest){
  require(module)[name](j0, j1, ...rest)
  return j1 - j0
}

// bands(module: string, name: string, n: int, workers?: int, ...rest)
// A kernel (name, of a module of kernels such as "game/land") that takes
// rows j0 to j1 first, run over all n rows: a band on every core. Every
// array given must be shared memory.
func m.bands(module, name, n, workers, ...rest){
  m.rows(module, name, 0, n, workers, ...rest)
}

// rows(module: string, name: string, from: int, to: int, workers?: int,
//   ...rest): the same for the rows from `from` up to `to` only
func m.rows(module, name, from, to, workers, ...rest){
  if(not isolate.available()){
    // (a browser: no threads, all rows here)
    band(module, name, from, to, ...rest)
    return null
  }
  workers = workers or math.max(1, math.min(os.cpu_count() - 1, 12))
  local rows = math.max(1, to_int((to - from + workers - 1) / workers))
  local pool = {}
  for(local j0 = from; j0 < to; j0 = j0 + rows){
    append(pool, isolate.spawn(band, module, name, j0, math.min(to, j0 + rows), ...rest))
  }
  for(let local worker in values(pool)){
    worker:join()
  }
}

local func in_bands(name, n, workers, ...rest){
  m.bands("game/land", name, n, workers, ...rest)
}

// generate(seed: int, options?: {size?: int, workers?: int, far?: bool})
//   -> Terrain
// The land of a seed. size is the samples along a side (2048 by default;
// tests take less and get the middle of the map at the same detail);
// workers the isolates that compute it (one per core but one by default);
// far false leaves out the coarse land beyond the map (`far`: its
// heights, for the eye only).
func m.generate(seed, options){
  options = options or {}
  local n = options.size or m.SIZE
  local spacing = m.SPACING
  local half = n * spacing / 2
  local rng = vec.random(seed * 7919 + 13)
  local river = river_points(rng, m.SIZE * spacing / 2)

  // how far the river is, over a coarse grid that reaches past the map
  local cell = 8.0
  local reach = m.SIZE * spacing / 2 + 64
  local fm = to_int(reach * 2 / cell) + 1
  local count = len(river.points)
  local flat = kernel.float:array(count * 2)
  for(local i = 0; i < count; i = i + 1){
    flat[i * 2] = river.points[i].x
    flat[i * 2 + 1] = river.points[i].z
  }
  local dist = kernel.float:array(fm * fm, {shared: true})
  land.river_field(dist, fm, cell, -reach, flat, count)
  // its water level and half width by z, from the south end north
  local table_step = river.step
  local level = kernel.float:array(count, {shared: true})
  local width = kernel.float:array(count, {shared: true})
  for(local i = 0; i < count; i = i + 1){
    local p = river.points[count - 1 - i]
    level[i] = p.level
    width[i] = p.half
  }
  local table_origin = river.points[count - 1].z

  // the highest mountain: off to one side, in the northern half
  local side = if(rng:chance(0.5)){ 1 } else { -1 }
  local peak = {x: side * rng:range(560, 760), z: rng:range(250, 650)}

  // the heights: a band of rows on every core
  local h = kernel.float:array(n * n, {shared: true})
  local water = kernel.float:array(n * n, {shared: true})
  in_bands("heights", n, options.workers, h, water, n, spacing, -half, seed, dist, fm, cell,
    -reach, level, width, table_origin, table_step, peak.x, peak.z)

  // the land beyond the map, for the eye only: the same heights, coarse,
  // over four times the map's side
  local far = null
  if(n == m.SIZE){
    local fn = 512
    local fs = m.SIZE * spacing * 4 / fn
    local fh = kernel.float:array(fn * fn, {shared: true})
    local fw = kernel.float:array(fn * fn, {shared: true})
    in_bands("heights", fn, options.workers, fh, fw, fn, fs, -fn * fs / 2, seed, dist, fm, cell,
      -reach, level, width, table_origin, table_step, peak.x, peak.z)
    if(options.far != false){
      far = {heights: fh, n: fn, spacing: fs, half: fn * fs / 2}
    }
  }

  return {
    seed: seed,
    far: far,
    n: n,
    spacing: spacing,
    half: half,
    heights: h,
    water: water,
    river: river,
    peak: peak,
    field: {dist: dist, m: fm, cell: cell, origin: -reach},
  }
}

// refine(t, options?: {workers?: int})
// The land's heights again as `fine`: {heights, n, spacing}, FINE samples
// for each one along a side, a smooth surface where the coarse samples
// would make facets. What is cut into the land afterwards (the trail) is
// cut into these; [settle] then takes the coarse heights back from them.
func m.refine(t, options){
  options = options or {}
  local f = m.FINE
  local n = t.n * f
  local heights = kernel.float:array(n * n, {shared: true})
  in_bands("refine", n, options.workers, heights, t.heights, t.n, f)
  t.fine = {heights: heights, n: n, spacing: t.spacing / f, factor: f}
}

// settle(t, options?: {workers?: int}): the coarse heights as the fine
// ones have them now: what reads the land sample by sample (its cover,
// its plants, the grass) sees what was cut into it
func m.settle(t, options){
  options = options or {}
  in_bands("coarsen", t.n, options.workers, t.heights, t.n, t.fine.heights, t.fine.factor)
}

// where the sun stands: over the south west, a third of the way up
m.SUN = vec.normalize({x: -0.52, y: 0.5, z: -0.62})

// finish(t, options?: {workers?: int})
// What follows from the land's final heights (after the trail is cut into
// them): `shape` (four bytes a sample: the normal's x and z, how much sky
// the place sees, how much sun reaches it past the mountains) and what
// covers the ground, as shares of 255 in `cover` (rock, scree, dirt,
// mud) and `cover2` (sand, snow, forest floor, grass). [surface_at] reads
// these.
func m.finish(t, options){
  options = options or {}
  local n = t.n
  local top = 0
  for(local i = 0; i < n * n; i = i + 211){
    if(t.heights[i] > top){
      top = t.heights[i]
    }
  }
  t.top = top + 30
  t.shape = kernel.uint8:array(n * n * 4, {shared: true})
  in_bands("shape", n, options.workers, t.shape, t.heights, n, t.spacing, m.SUN.x, m.SUN.y, m.SUN.z, t.top)
  // the shadows' edges smoothed: six times over, through a second array
  // (a mountain's shadow is soft, and on snow every step of it shows)
  local other = kernel.uint8:array(n * n * 4, {shared: true})
  for(local pass = 0; pass < 3; pass = pass + 1){
    in_bands("soften", n, options.workers, other, t.shape, n)
    in_bands("soften", n, options.workers, t.shape, other, n)
  }
  // the track's maps, or none
  local track = null
  local half = null
  local along = null
  local pits = null
  if(t.trail != null){
    track = t.trail.dist
    half = t.trail.half
    along = t.trail.along
    pits = t.trail.mud
  } else {
    track = kernel.float:array(n * n, {shared: true})
    track:fill(1.0e9)
    half = track
    along = track
    pits = kernel.uint8:array(n * n, {shared: true})
  }
  t.cover = kernel.uint8:array(n * n * 4, {shared: true})
  t.cover2 = kernel.uint8:array(n * n * 4, {shared: true})
  in_bands("cover", n, options.workers, t.cover, t.cover2, t.heights, t.water, track, half, along,
    pits, t.shape, n, t.spacing, -t.half, t.seed)
}

// height_at(t, x, z) -> the height of the ground at a point (the edge's
// beyond the map), as the two triangles of each square of samples have it
// (of the fine samples, once the land has them): the same triangles the
// physics drives on and the picture shows
func m.height_at(t, x, z){
  local g = t.fine or t
  local n = g.n
  local fx = (x + t.half) / g.spacing
  local fz = (z + t.half) / g.spacing
  if(fx < 0){
    fx = 0
  } else if(fx > n - 1.001){
    fx = n - 1.001
  }
  if(fz < 0){
    fz = 0
  } else if(fz > n - 1.001){
    fz = n - 1.001
  }
  local ix = to_int(fx)
  local iz = to_int(fz)
  local tx = fx - ix
  local tz = fz - iz
  local h = g.heights
  local i = iz * n + ix
  local a = h[i]
  local d = h[i + n + 1]
  // (the square is split from its first corner to the one across)
  if(tz >= tx){
    local c = h[i + n]
    return a + (c - a) * tz + (d - c) * tx
  }
  local b = h[i + 1]
  return a + (b - a) * tx + (d - b) * tz
}

// water_at(t, x, z) -> how deep the water stands over the ground at a
// point (0 on dry land)
func m.water_at(t, x, z){
  local n = t.n
  local ix = to_int(vec.clamp((x + t.half) / t.spacing + 0.5, 0, n - 1))
  local iz = to_int(vec.clamp((z + t.half) / t.spacing + 0.5, 0, n - 1))
  local depth = t.water[iz * n + ix] - m.height_at(t, x, z)
  if(depth < 0){
    return 0
  }
  return depth
}

// normal_at(t, x, z) -> the ground's normal at a point
func m.normal_at(t, x, z){
  local e = t.spacing
  local dx = m.height_at(t, x + e, z) - m.height_at(t, x - e, z)
  local dz = m.height_at(t, x, z + e) - m.height_at(t, x, z - e)
  return vec.normalize({x: -dx, y: 2 * e, z: -dz})
}

// the surfaces of the eight shares of the cover, in their order
local COVER = {
  surfaces.rock, surfaces.gravel, surfaces.dirt, surfaces.mud,
  surfaces.sand, surfaces.snow, surfaces.dirt, surfaces.grass,
}

// surface_at(t, x, z) -> Surface: what the ground is made of at a point
// (game/surfaces): what has the largest share there (see [finish]); under
// water, the river's bed
func m.surface_at(t, x, z){
  local n = t.n
  local i = to_int(vec.clamp((x + t.half) / t.spacing + 0.5, 0, n - 1))
  local j = to_int(vec.clamp((z + t.half) / t.spacing + 0.5, 0, n - 1))
  local at = (j * n + i) * 4
  if(t.water[j * n + i] - t.heights[j * n + i] > 0.06){
    return surfaces.riverbed
  }
  if(t.cover == null){
    return surfaces.grass
  }
  local best = 0
  local most = -1
  local first = t.cover
  local second = t.cover2
  for(local k = 0; k < 4; k = k + 1){
    if(first[at + k] > most){
      most = first[at + k]
      best = k
    }
    if(second[at + k] > most){
      most = second[at + k]
      best = k + 4
    }
  }
  return COVER[best]
}

// detail(size?, seed?) -> a square picture of size by size (512) that
// repeats, four bytes a pixel, for the ground's small patterns (see
// game/land.kernel)
func m.detail(size, seed){
  size = size or 512
  local data = kernel.uint8:array(size * size * 4)
  land.detail(data, size, seed or 1)
  return {data: data, size: size}
}

// picture(t, step?) -> {data, size}: the land from above, one pixel per
// step samples (r, g, b, a bytes), north up, with the trail when the
// land has one
func m.picture(t, step){
  step = step or 2
  local size = to_int(t.n / step)
  local data = kernel.uint8:array(size * size * 4)
  land.relief(data, t.heights, t.water, t.n, step, t.spacing)
  if(t.trail != null){
    land.mark(data, t.trail.dist, t.n, step, 2.2, 226, 196, 120)
  }
  return {data: data, size: size}
}

return m
