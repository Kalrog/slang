// game/plants: what stands on the land: trees, bushes, rocks and fallen
// logs, set down from the land's seed. Woods grow in patches with
// clearings on the valley's sides (broadleaf low down and by the river,
// conifers above, thinning toward a tree line near 300 m), trees stand
// alone and in groups on the meadow, bushes at the woods' edges and along
// the water, boulders lie alone and in fields with small stones around
// them. Nothing green stands on snow or above the tree line (rocks do). Nothing here draws: render/flora does, and the physics takes the
// solids (trunks, boulders, logs) of the squares near the truck.
//
//   local p = plants.scatter(land)
//   local chunk = plants.chunk_at(p, x, z)        // the 64 m square there
//   plants.record(p, chunk, 0)                    // {kind, x, y, z, yaw, ...}
//   plants.solids(p, chunk)                       // what a truck can hit
//
// Everything is in squares of 64 m (chunks), each with its records in one
// buffer of numbers, ten a record (x, y, z, yaw, pitch, roll, scale, kind,
// tint, extra), in the order of their kinds: chunk.starts[k] is where
// kind k begins and chunk.starts[k + 1] where it ends. The kernels that
// do the setting are in game/plants_sow.kernel.
local kernel = require("kernel")
local math = require("slang/math")
local table = require("slang/table")
local vec = require("game/vec")
local terrain = require("game/terrain")
local sow = require("game/plants_sow")

local m = {}

m.CHUNK = 64        // the side of a square, m
m.STRIDE = 10       // numbers in a record
// the places of a record's numbers
m.X = 0
m.Y = 1
m.Z = 2
m.YAW = 3
m.PITCH = 4
m.ROLL = 5
m.SCALE = 6
m.KIND = 7
m.TINT = 8
m.EXTRA = 9

// The kinds, by their number in a record. A tree's trunk is trunk meters
// thick (its radius at the ground) at scale 1 and the tree height meters
// tall; a rock's scale is its size in meters; a log lies along its z.
// type Kind = {name: string, group: string, trunk?: float, height?: float,
//   radius?: float, length?: float, solid?: bool}
// [group]: "tree", "bush", "rock" or "log"
// [solid]: whether a truck hits it (see [solids])
m.KINDS = {
  {name: "spruce", group: "tree", trunk: 0.27, height: 17.5, solid: true},
  {name: "fir", group: "tree", trunk: 0.21, height: 15.5, solid: true},
  {name: "pine", group: "tree", trunk: 0.25, height: 15, solid: true},
  {name: "birch", group: "tree", trunk: 0.15, height: 11.5, solid: true},
  {name: "oak", group: "tree", trunk: 0.36, height: 11.5, solid: true},
  {name: "snag", group: "tree", trunk: 0.21, height: 9.5, solid: true},
  {name: "sapling", group: "tree", trunk: 0.05, height: 3.4},
  {name: "bush", group: "bush", height: 1.5},
  {name: "shrub", group: "bush", height: 0.9},
  {name: "rock1", group: "rock", solid: true},
  {name: "rock2", group: "rock", solid: true},
  {name: "rock3", group: "rock", solid: true},
  {name: "rock4", group: "rock", solid: true},
  {name: "rock5", group: "rock", solid: true},
  {name: "log", group: "log", radius: 0.23, length: 5.4, solid: true},
  {name: "stump", group: "log", radius: 0.3, height: 0.6, solid: true},
}
m.ROCK = 9          // the first rock's kind
m.ROCKS = 5         // how many shapes of rock
m.LOG = 14
m.STUMP = 15
// a rock smaller than this stops no wheel: it is not a solid
m.SOLID_ROCK = 0.45

m.by_name = {}
for(local i = 0; i < len(m.KINDS); i = i + 1){
  m.KINDS[i].index = i
  m.by_name[m.KINDS[i].name] = m.KINDS[i]
}

// ------------------------------------------------------------ rocks

// the corners and faces of a ball of triangles: an icosahedron, each
// face split in four `splits` times, its corners pushed out onto the
// unit sphere
local func ball(splits){
  local t = (1 + math.sqrt(5)) / 2
  local points = {}
  for(let local p in values({
    {-1, t, 0}, {1, t, 0}, {-1, -t, 0}, {1, -t, 0}, {0, -1, t}, {0, 1, t},
    {0, -1, -t}, {0, 1, -t}, {t, 0, -1}, {t, 0, 1}, {-t, 0, -1}, {-t, 0, 1},
  })){
    append(points, vec.normalize({x: p[0], y: p[1], z: p[2]}))
  }
  local faces = {
    {0, 11, 5}, {0, 5, 1}, {0, 1, 7}, {0, 7, 10}, {0, 10, 11}, {1, 5, 9}, {5, 11, 4},
    {11, 10, 2}, {10, 7, 6}, {7, 1, 8}, {3, 9, 4}, {3, 4, 2}, {3, 2, 6}, {3, 6, 8},
    {3, 8, 9}, {4, 9, 5}, {2, 4, 11}, {6, 2, 10}, {8, 6, 7}, {9, 8, 1},
  }
  for(local s = 0; s < splits; s = s + 1){
    local middles = {}
    local func middle(a, b){
      local key = if(a < b){ a * 100000 + b } else { b * 100000 + a }
      local i = middles[key]
      if(i == null){
        i = len(points)
        append(points, vec.normalize(vec.add(points[a], points[b])))
        middles[key] = i
      }
      return i
    }
    local next = {}
    for(let local f in values(faces)){
      local ab = middle(f[0], f[1])
      local bc = middle(f[1], f[2])
      local ca = middle(f[2], f[0])
      append(next, {f[0], ab, ca})
      append(next, {f[1], bc, ab})
      append(next, {f[2], ca, bc})
      append(next, {ab, bc, ca})
    }
    faces = next
  }
  return {points: points, faces: faces}
}

m.ball = ball

// A rock is a convex solid: a block of stone cut by planes, a few big
// ones (its faces), smaller ones, and chips off its corners and edges.
// Being convex, what is drawn and what the physics takes (the hull of
// its corners) are the same shape.

// a solid as its faces, each a list of corners in order (counter
// clockwise seen from outside)

// the normal of a face (not of unit length: its length is twice its area)
local func face_normal(face){
  local n = {x: 0, y: 0, z: 0}
  local count = len(face)
  for(local i = 0; i < count; i = i + 1){
    local a = face[i]
    local b = face[(i + 1) % count]
    n.x = n.x + (a.y - b.y) * (a.z + b.z)
    n.y = n.y + (a.z - b.z) * (a.x + b.x)
    n.z = n.z + (a.x - b.x) * (a.y + b.y)
  }
  return n
}

// a block from -a to a, low to high, -c to c
local func block(a, low, high, c){
  local func p(x, y, z){
    return {x: x, y: y, z: z}
  }
  local faces = {
    {p(a, low, -c), p(a, high, -c), p(a, high, c), p(a, low, c)},
    {p(-a, low, c), p(-a, high, c), p(-a, high, -c), p(-a, low, -c)},
    {p(-a, high, -c), p(-a, high, c), p(a, high, c), p(a, high, -c)},
    {p(-a, low, c), p(-a, low, -c), p(a, low, -c), p(a, low, c)},
    {p(a, low, c), p(a, high, c), p(-a, high, c), p(-a, low, c)},
    {p(-a, low, -c), p(-a, high, -c), p(a, high, -c), p(a, low, -c)},
  }
  // (each seen counter clockwise from outside)
  local middle = {x: 0, y: (low + high) / 2, z: 0}
  for(local i = 0; i < len(faces); i = i + 1){
    local face = faces[i]
    if(vec.dot(face_normal(face), vec.sub(face[0], middle)) < 0){
      local turned = {}
      for(local k = len(face) - 1; k >= 0; k = k - 1){
        append(turned, face[k])
      }
      faces[i] = turned
    }
  }
  return faces
}

// cut(faces, n, d) -> faces: what is left of a solid on the inner side
// of a plane (where n . p <= d), closed by a new face in the plane
local func cut(faces, n, d){
  local eps = 1.0e-7
  local out = {}
  local rim = {}
  local any = false
  for(let local face in values(faces)){
    local kept = {}
    local count = len(face)
    local outside = false
    for(local i = 0; i < count; i = i + 1){
      if(vec.dot(n, face[i]) - d > eps){
        outside = true
      }
    }
    if(not outside){
      append(out, face)
      continue
    }
    any = true
    for(local i = 0; i < count; i = i + 1){
      local a = face[i]
      local b = face[(i + 1) % count]
      local da = vec.dot(n, a) - d
      local db = vec.dot(n, b) - d
      if(da <= eps){
        append(kept, a)
        if(da >= -eps){
          append(rim, a)
        }
      }
      if((da > eps and db < -eps) or (da < -eps and db > eps)){
        local q = vec.lerp(a, b, da / (da - db))
        append(kept, q)
        append(rim, q)
      }
    }
    if(len(kept) >= 3){
      append(out, kept)
    }
  }
  if(not any){
    return faces
  }
  // the new face: the rim's corners (each met twice, once from either
  // face beside it) in order around the plane's normal
  local corners = {}
  for(let local q in values(rim)){
    local known = false
    for(let local c in values(corners)){
      if(math.abs(c.x - q.x) + math.abs(c.y - q.y) + math.abs(c.z - q.z) < 1.0e-6){
        known = true
        break
      }
    }
    if(not known){
      append(corners, q)
    }
  }
  if(len(corners) >= 3){
    local middle = {x: 0, y: 0, z: 0}
    for(let local q in values(corners)){
      middle = vec.add_scaled(middle, q, 1 / len(corners))
    }
    local u = vec.normalize(vec.sub(corners[0], middle))
    local v = vec.cross(n, u)
    local order = {}
    for(let local q in values(corners)){
      local e = vec.sub(q, middle)
      append(order, {q: q, angle: math.atan2(vec.dot(e, v), vec.dot(e, u))})
    }
    table.sort(order, func(x, y){
      return x.angle < y.angle
    })
    local cap = {}
    for(let local o in values(order)){
      append(cap, o.q)
    }
    append(out, cap)
  }
  return out
}

// how far a block reaches in a direction
local func block_reach(a, low, high, c, n){
  return a * math.abs(n.x) + c * math.abs(n.z) + (if(n.y > 0){ high * n.y } else { low * n.y })
}

// the corners of a solid, each once, and its faces as triangles of them
local func mesh_of(faces){
  local points = {}
  local func index_of(q){
    for(local i = 0; i < len(points); i = i + 1){
      local c = points[i]
      if(math.abs(c.x - q.x) + math.abs(c.y - q.y) + math.abs(c.z - q.z) < 1.0e-5){
        return i
      }
    }
    append(points, {x: q.x, y: q.y, z: q.z})
    return len(points) - 1
  }
  local triangles = {}
  for(let local face in values(faces)){
    local ids = {}
    for(let local q in values(face)){
      local id = index_of(q)
      if(len(ids) == 0 or (ids[len(ids) - 1] != id and ids[0] != id)){
        append(ids, id)
      }
    }
    for(local i = 1; i + 1 < len(ids); i = i + 1){
      append(triangles, {ids[0], ids[i], ids[i + 1]})
    }
  }
  return {points: points, faces: triangles}
}

// What the five rocks are cut from: a block (a wide, low to high, c
// deep), `big` planes that take a lot off, `mid` ones that take a
// little, `chips` off corners and edges; round: a river stone instead (a
// pebble's shape, smooth).
local ROCKS = {
  {a: 0.52, low: -0.26, high: 0.44, c: 0.45, big: 6, mid: 7, chips: 13, seed: 4011},
  {a: 0.5, low: -0.25, high: 0.52, c: 0.4, big: 7, mid: 6, chips: 12, seed: 4172, lean: 0.5},
  {a: 0.56, low: -0.22, high: 0.33, c: 0.47, big: 5, mid: 8, chips: 13, seed: 4283},
  {a: 0.58, low: -0.13, high: 0.15, c: 0.43, big: 4, mid: 7, chips: 12, seed: 4394, slab: true},
  {a: 0.5, low: -0.2, high: 0.3, c: 0.4, round: true, seed: 4525},
}

local func build_rock(o){
  local rng = vec.random(o.seed)
  local faces = block(o.a, o.low, o.high, o.c)
  local coarse = null
  local normals = null
  if(o.round){
    // planes touching a pebble all around
    local b = (o.high - o.low) / 2 + 0.06
    local lift = (o.high + o.low) / 2 + 0.06
    for(let local d in values(ball(1).points)){
      local reach = math.sqrt((o.a * d.x) * (o.a * d.x) + (b * d.y) * (b * d.y) + (o.c * d.z) * (o.c * d.z))
      local uneven = 1 + 0.07 * vec.noise(d.x * 2.3 + o.seed, d.z * 2.3 + d.y * 1.7, o.seed)
      faces = cut(faces, d, reach * uneven + lift * d.y)
    }
    local solid = mesh_of(faces)
    normals = {}
    for(let local q in values(solid.points)){
      append(normals, vec.normalize({
        x: q.x / (o.a * o.a), y: (q.y - lift) / (b * b), z: q.z / (o.c * o.c),
      }))
    }
    return {points: solid.points, faces: solid.faces, hull: solid.points, coarse: solid, normals: normals}
  }
  // first the block's own shape goes: its four upright edges and its top
  for(let local side in values({{1, 1}, {1, -1}, {-1, 1}, {-1, -1}})){
    local n = vec.normalize({
      x: side[0] * rng:range(0.45, 1), y: rng:range(-0.15, if(o.slab){ 0.15 } else { 0.7 }), z: side[1] * rng:range(0.45, 1),
    })
    faces = cut(faces, n, block_reach(o.a, o.low, o.high, o.c, n) * rng:range(0.68, 0.84))
  }
  // (two faces leaning against each other, through a point under the
  // middle of the block's top)
  local tilt = if(o.slab){ 0.1 } else { 0.72 }
  local tx = rng:range(0.4, 1) * tilt * (if(rng:next() < 0.5){ -1 } else { 1 })
  local tz = rng:range(0.4, 1) * tilt * (if(rng:next() < 0.5){ -1 } else { 1 })
  local under = {x: rng:range(-0.1, 0.1), y: o.high - rng:range(0.005, 0.03), z: rng:range(-0.1, 0.1)}
  local top = vec.normalize({x: tx, y: 1, z: tz})
  faces = cut(faces, top, vec.dot(top, under))
  top = vec.normalize({x: -tx * rng:range(0.5, 1.2), y: 1, z: -tz * rng:range(0.5, 1.2)})
  faces = cut(faces, top, vec.dot(top, under))
  // the big faces: not underneath, and a slab keeps its top and bottom
  for(local k = 0; k < o.big + o.mid; k = k + 1){
    local big = k < o.big
    local n = vec.normalize({
      x: rng:range(-1, 1), y: rng:range(-0.25, if(o.slab){ 0.35 } else { 1 }), z: rng:range(-1, 1),
    })
    if(o.lean != null and k == 0){
      // one face leaning over the whole rock: a wedge
      n = vec.normalize({x: o.lean, y: 0.8, z: 0.15})
    }
    local reach = block_reach(o.a, o.low, o.high, o.c, n)
    local share = if(big){ rng:range(0.6, 0.76) } else { rng:range(0.78, 0.9) }
    faces = cut(faces, n, reach * share)
  }
  coarse = mesh_of(faces)
  // chips: a corner knocked off, or an edge beside it
  for(local k = 0; k < o.chips; k = k + 1){
    local solid = mesh_of(faces)
    local corner = solid.points[rng:int(len(solid.points))]
    local middle = {x: 0, y: (o.low + o.high) / 2, z: 0}
    local n = vec.normalize(vec.sub(corner, middle))
    if(k % 2 == 1){
      // along an edge: between two of the faces that meet at the corner
      local beside = {}
      for(let local face in values(faces)){
        for(let local q in values(face)){
          if(math.abs(q.x - corner.x) + math.abs(q.y - corner.y) + math.abs(q.z - corner.z) < 1.0e-5){
            append(beside, vec.normalize(face_normal(face)))
            break
          }
        }
      }
      if(len(beside) >= 2){
        local first = rng:int(len(beside))
        local second = (first + 1 + rng:int(len(beside) - 1)) % len(beside)
        n = vec.normalize(vec.add(beside[first], beside[second]))
      }
    }
    n = vec.normalize({x: n.x + rng:range(-0.2, 0.2), y: n.y + rng:range(-0.2, 0.2), z: n.z + rng:range(-0.2, 0.2)})
    faces = cut(faces, n, vec.dot(n, corner) - rng:range(0.012, 0.045))
  }
  local solid = mesh_of(faces)
  return {points: solid.points, faces: solid.faces, hull: solid.points, coarse: coarse}
}

local rock_cache = null

// rock_shapes() -> {Rock}: the shapes a rock can have, each about one
// meter across (a record's scale is the rock's size): what render/flora
// draws and what the physics takes as hulls. The first four are broken
// stone (a boulder, a wedge, a low boulder, a slab), the fifth a river
// stone, rounded. Each is convex, flat underneath, and stands from low
// (about -0.25) to high (0.15 to 0.5) around its record's place.
// type Rock = {points: {Vec3}, faces: {{int}}, hull: {Vec3},
//   coarse: {points, faces}, normals?: {Vec3}, low: float, high: float}
// [points], [faces]: its surface as triangles (corners counter clockwise
//   seen from outside); the triangles of one flat face lie in one plane
// [hull]: the corners of the surface: their convex hull is the surface
// [coarse]: the same without the chips, for a stone or a rock far off
// [normals]: a river stone's, one for each point (it is drawn smooth)
// [low], [high]: its lowest and highest point (y)
func m.rock_shapes(){
  if(rock_cache != null){
    return rock_cache
  }
  local shapes = {}
  for(let local o in values(ROCKS)){
    local rock = build_rock(o)
    rock.low = 1.0e9
    rock.high = -1.0e9
    for(let local q in values(rock.points)){
      rock.low = math.min(rock.low, q.y)
      rock.high = math.max(rock.high, q.y)
    }
    append(shapes, rock)
  }
  rock_cache = shapes
  return shapes
}

// ------------------------------------------------------------ scattering

// rotation(yaw, pitch, roll) -> Quat: how a record's three angles turn
// its shape: the roll (about z) first, then the pitch (about x), then
// the yaw (about y)
func m.rotation(yaw, pitch, roll){
  return vec.quat_multiply(
    vec.quat_yaw(yaw),
    vec.quat_multiply(vec.quat_axis({x: 1, y: 0, z: 0}, pitch), vec.quat_axis({x: 0, y: 0, z: 1}, roll)),
  )
}

// What [scatter] takes.
// type Options = {density?: float, trees?: float, bushes?: float,
//   rocks?: float, logs?: float, mask?: any, cap?: int}
// [density]: more (over 1) or less of everything
// [trees], [bushes], [rocks], [logs]: the same for one group
// [mask]: where nothing may stand (a trail, a camp): a function
//   (x, z) -> bool that is true there, or a grid over the whole land
//   {data: buffer of uint8, n: cells a side, cell: meters a cell} whose
//   bytes are not 0 there (row by row from the land's -x, -z corner, as
//   the land's heights are)
// [cap]: the most records in one chunk (800 by default)

// scatter(land: terrain.Terrain, options?: Options) -> Plants
// Everything that stands on a land, the same for the same land.
// type Plants = {land: terrain.Terrain, size: float, side: int,
//   origin: float, chunks: {Chunk}, counts: {[string]: int},
//   groups: {[string]: int}, total: int}
// [size]: a chunk's side in meters, [side]: chunks along a side of the land
// [chunks]: row by row from the land's -x, -z corner (index cz * side + cx)
// [counts]: how many of each kind, by its name
// [groups]: how many trees, bushes, rocks and logs (tree, bush, rock, log)
// type Chunk = {index: int, cx: int, cz: int, x0: float, z0: float,
//   count: int, data?: buffer, starts: {int}, low: float, high: float}
// [data]: count records (null when there are none)
// [starts]: where each kind's records begin (one more entry than kinds)
// [low], [high]: the lowest and highest ground something stands on
func m.scatter(land, options){
  options = options or {}
  local n = land.n
  local spacing = land.spacing
  local origin = -land.half
  local size = m.CHUNK
  local side = to_int(math.ceil(n * spacing / size))
  local density = options.density or 1
  local seed = (land.seed or 1) * 31 + 5

  // the river's level by z, from the south end north, for "how far over
  // the river"
  local level = null
  local level_origin = 0
  local level_step = 1
  if(land.river != null){
    local points = land.river.points
    local count = len(points)
    level = kernel.float:array(count)
    for(local i = 0; i < count; i = i + 1){
      level[i] = points[count - 1 - i].level
    }
    level_origin = points[count - 1].z
    level_step = land.river.step
  } else {
    level = kernel.float:array(2)
  }

  // the mask as a grid for the kernels, or as a function asked afterwards
  local mask = kernel.uint8:array(1)
  local mask_n = 0
  local mask_cell = 1
  local mask_func = null
  if(type(options.mask) == "function"){
    mask_func = options.mask
  } else if(options.mask != null){
    mask = options.mask.data
    mask_n = options.mask.n
    mask_cell = options.mask.cell
  }

  // where snow lies (the land's cover, once terrain.finish has made it):
  // nothing green stands there
  local snow = land.cover2 or kernel.uint8:array(4)
  local snow_n = if(land.cover2 != null){ n } else { 0 }

  local kinds = len(m.KINDS)
  local cap = options.cap or 800
  local temp = kernel.float:array(cap * m.STRIDE)
  local sorted = kernel.float:array(cap * m.STRIDE)
  local starts = kernel.int32:array(kinds + 1)
  local bounds = kernel.float:array(2)
  local chunks = {}
  local counts = {}
  local groups = {tree: 0, bush: 0, rock: 0, log: 0}
  for(let local k in values(m.KINDS)){
    counts[k.name] = 0
  }
  local total = 0
  local h = land.heights
  local water = land.water
  for(local cz = 0; cz < side; cz = cz + 1){
    for(local cx = 0; cx < side; cx = cx + 1){
      local x0 = origin + cx * size
      local z0 = origin + cz * size
      local count = sow.trees(temp, 0, cap, h, water, n, spacing, origin, level, level_origin, level_step,
        x0, z0, size, size / 12, seed, density * (options.trees or 1), mask, mask_n, mask_cell, snow, snow_n)
      count = sow.bushes(temp, count, cap, h, water, n, spacing, origin, level, level_origin, level_step,
        x0, z0, size, size / 9, seed, density * (options.bushes or 1), mask, mask_n, mask_cell, snow, snow_n)
      count = sow.rocks(temp, count, cap, h, water, n, spacing, origin, level, level_origin, level_step,
        x0, z0, size, size / 5, seed, density * (options.rocks or 1), mask, mask_n, mask_cell, m.ROCKS)
      count = sow.logs(temp, count, cap, h, water, n, spacing, origin, level, level_origin, level_step,
        x0, z0, size, size / 3, seed, density * (options.logs or 1), mask, mask_n, mask_cell, m.LOG, snow, snow_n)
      if(mask_func != null){
        for(local i = 0; i < count; i = i + 1){
          if(mask_func(temp[i * m.STRIDE], temp[i * m.STRIDE + 2])){
            temp[i * m.STRIDE + m.KIND] = -1
          }
        }
      }
      local kept = sow.arrange(temp, count, sorted, starts, kinds, bounds)
      local chunk = {
        index: cz * side + cx, cx: cx, cz: cz, x0: x0, z0: z0, count: kept, data: null,
        starts: {}, low: bounds[0], high: bounds[1],
      }
      for(local k = 0; k <= kinds; k = k + 1){
        chunk.starts[k] = starts[k]
      }
      if(kept > 0){
        chunk.data = kernel.float:array(kept * m.STRIDE)
        chunk.data:set(sorted:slice(0, kept * m.STRIDE))
        for(local k = 0; k < kinds; k = k + 1){
          local c = starts[k + 1] - starts[k]
          if(c > 0){
            local kind = m.KINDS[k]
            counts[kind.name] = counts[kind.name] + c
            groups[kind.group] = groups[kind.group] + c
          }
        }
        total = total + kept
      }
      append(chunks, chunk)
    }
  }
  return {
    land: land,
    size: size,
    side: side,
    origin: origin,
    chunks: chunks,
    counts: counts,
    groups: groups,
    total: total,
  }
}

// place(land, records: {{kind: string | int, x: float, z: float,
//   y?: float, yaw?: float, pitch?: float, roll?: float, scale?: float,
//   tint?: float, extra?: float}}) -> Plants
// Plants set down by hand (for a tool, a test, a camp): each record's
// kind by name or number, standing on the ground unless it says its y.
func m.place(land, records){
  local origin = -land.half
  local size = m.CHUNK
  local side = to_int(math.ceil(land.n * land.spacing / size))
  local kinds = len(m.KINDS)
  local lists = {}
  for(local i = 0; i < side * side; i = i + 1){
    lists[i] = {}
  }
  for(let local r in values(records)){
    local cx = to_int(vec.clamp(math.floor((r.x - origin) / size), 0, side - 1))
    local cz = to_int(vec.clamp(math.floor((r.z - origin) / size), 0, side - 1))
    append(lists[cz * side + cx], r)
  }
  local starts = kernel.int32:array(kinds + 1)
  local bounds = kernel.float:array(2)
  local chunks = {}
  local counts = {}
  local groups = {tree: 0, bush: 0, rock: 0, log: 0}
  for(let local k in values(m.KINDS)){
    counts[k.name] = 0
  }
  local total = 0
  for(local i = 0; i < side * side; i = i + 1){
    local list = lists[i]
    local cx = i % side
    local cz = to_int(i / side)
    local chunk = {
      index: i, cx: cx, cz: cz, x0: origin + cx * size, z0: origin + cz * size, count: 0, data: null,
      starts: {}, low: 0, high: 0,
    }
    local n = len(list)
    if(n > 0){
      local temp = kernel.float:array(n * m.STRIDE)
      for(local j = 0; j < n; j = j + 1){
        local r = list[j]
        local kind = r.kind
        if(type(kind) == "string"){
          kind = m.by_name[kind].index
        }
        local at = j * m.STRIDE
        temp[at] = r.x
        temp[at + 1] = r.y or terrain.height_at(land, r.x, r.z)
        temp[at + 2] = r.z
        temp[at + 3] = r.yaw or 0
        temp[at + 4] = r.pitch or 0
        temp[at + 5] = r.roll or 0
        temp[at + 6] = r.scale or 1
        temp[at + 7] = kind
        temp[at + 8] = r.tint or 0.5
        temp[at + 9] = r.extra or 0
        counts[m.KINDS[kind].name] = counts[m.KINDS[kind].name] + 1
        groups[m.KINDS[kind].group] = groups[m.KINDS[kind].group] + 1
      }
      chunk.data = kernel.float:array(n * m.STRIDE)
      chunk.count = sow.arrange(temp, n, chunk.data, starts, kinds, bounds)
      chunk.low = bounds[0]
      chunk.high = bounds[1]
      total = total + n
    }
    for(local k = 0; k <= kinds; k = k + 1){
      chunk.starts[k] = if(n > 0){ starts[k] } else { 0 }
    }
    append(chunks, chunk)
  }
  return {
    land: land, size: size, side: side, origin: origin, chunks: chunks, counts: counts, groups: groups,
    total: total,
  }
}

// chunk_at(p, x, z) -> Chunk?: the square a point is in (null off the land)
func m.chunk_at(p, x, z){
  local cx = to_int(math.floor((x - p.origin) / p.size))
  local cz = to_int(math.floor((z - p.origin) / p.size))
  if(cx < 0 or cz < 0 or cx >= p.side or cz >= p.side){
    return null
  }
  return p.chunks[cz * p.side + cx]
}

// near(p, x, z, radius) -> {Chunk}: the squares within radius of a point
func m.near(p, x, z, radius){
  local out = {}
  local cx0 = math.max(0, to_int(math.floor((x - radius - p.origin) / p.size)))
  local cx1 = math.min(p.side - 1, to_int(math.floor((x + radius - p.origin) / p.size)))
  local cz0 = math.max(0, to_int(math.floor((z - radius - p.origin) / p.size)))
  local cz1 = math.min(p.side - 1, to_int(math.floor((z + radius - p.origin) / p.size)))
  for(local cz = cz0; cz <= cz1; cz = cz + 1){
    for(local cx = cx0; cx <= cx1; cx = cx + 1){
      append(out, p.chunks[cz * p.side + cx])
    }
  }
  return out
}

// record(p, chunk, i) -> {kind: Kind, x, y, z, yaw, pitch, roll, scale,
//   tint, extra}: the i-th record of a chunk as a table
func m.record(p, chunk, i){
  local d = chunk.data
  local at = i * m.STRIDE
  return {
    kind: m.KINDS[to_int(d[at + m.KIND])],
    x: d[at], y: d[at + 1], z: d[at + 2],
    yaw: d[at + 3], pitch: d[at + 4], roll: d[at + 5],
    scale: d[at + 6], tint: d[at + 8], extra: d[at + 9],
  }
}

// What a truck can hit, in the world:
// type Solid = {kind: string, position: Vec3, rotation: Quat,
//   radius?: float, half_height?: float, shape?: int, scale?: float}
// [kind]: "cylinder" (a trunk, a log, a stump: standing along its own y,
//   turned by rotation, radius thick and twice half_height long, position
//   its middle) or "hull" (a boulder: the convex hull of
//   rock_shapes()[shape].hull, scaled by scale, turned by rotation, its
//   middle at position)

// solids(p, chunk) -> {Solid}: the solids of a chunk (made when first
// asked for, then kept): the trunks of its trees but the saplings', its
// boulders (not the small stones), its logs and stumps
func m.solids(p, chunk){
  if(chunk.solids != null){
    return chunk.solids
  }
  local out = {}
  local d = chunk.data
  local quarter = vec.quat_axis({x: 1, y: 0, z: 0}, math.pi / 2)
  for(local i = 0; i < chunk.count; i = i + 1){
    local at = i * m.STRIDE
    local k = to_int(d[at + m.KIND])
    local kind = m.KINDS[k]
    if(not kind.solid){
      continue
    }
    local scale = d[at + m.SCALE]
    local q = m.rotation(d[at + m.YAW], d[at + m.PITCH], d[at + m.ROLL])
    local base = {x: d[at], y: d[at + 1], z: d[at + 2]}
    if(kind.group == "tree"){
      // the trunk from under the ground to over the truck's roof
      local up = vec.rotate(q, {x: 0, y: 1.5, z: 0})
      append(out, {
        kind: "cylinder", position: vec.add(base, up), rotation: q,
        radius: kind.trunk * scale * 0.9, half_height: 1.9,
      })
    } else if(kind.group == "rock"){
      if(d[at + m.EXTRA] < 0.5 and scale >= m.SOLID_ROCK){
        append(out, {kind: "hull", shape: k - m.ROCK, position: base, rotation: q, scale: scale})
      }
    } else if(k == m.LOG){
      append(out, {
        kind: "cylinder", position: base, rotation: vec.quat_multiply(q, quarter),
        radius: kind.radius * scale, half_height: kind.length * scale / 2,
      })
    } else {
      local half = kind.height * scale / 2
      append(out, {
        kind: "cylinder", position: {x: base.x, y: base.y + half, z: base.z}, rotation: q,
        radius: kind.radius * scale, half_height: half,
      })
    }
  }
  chunk.solids = out
  return out
}

return m
