// render/flora_mesh: the shapes of what stands on the land, built from
// numbers: trees (trunk, limbs and foliage as cards cut out of a
// texture), bushes, rocks, logs and stumps, each in up to three levels of
// detail: near (the branches themselves), mid (a few cards) and far (a
// cone or a blob of a few triangles). render/flora draws them.
//
// What a vertex carries, besides its place, normal and texture place:
//   color    r: how far the wind bends the tree there, g: how much the
//            leaf flutters, b: how open the place is to the sky (inside
//            a crown it is dark), a: a number of its branch (so that
//            branches move apart)
//   tangent  x, y, z: its color (for foliage: a tint of the texture's;
//            for rock: the direction across its strata),
//            w: what it is made of (a kind of bark, LEAF, PLAIN, ROCK, ROUND)
// A rock's color bytes are not the wind's: b is how far the vertex is
// from its face's border (of 0.4 at scale 1), which the shader wears the
// edges down by; the rest is filled in when it is baked into the land.
// Foliage cards are seen from both sides (each triangle twice, turned),
// and are lit as the crown they are part of, not as flat cards: their
// normals point out of the crown.
local kernel = require("kernel")
local math = require("slang/math")
local vec = require("game/vec")
local plants = require("game/plants")

local m = {}

// what a vertex is made of (its tangent's w). Bark comes in kinds: the
// scales of a spruce or a fir, a pine's plates, an oak's furrows, a dead
// tree's bare wood, a birch's white skin.
m.BARK = 0
m.PLATES = 0.15
m.FURROWS = 0.3
m.WOOD = 0.45
// (a trunk's cut end)
m.RINGS = 0.5
m.BIRCH = 0.6
m.LEAF = 1
m.PLAIN = 2
m.ROCK = 3
// (a river stone: rock drawn smooth)
m.ROUND = 4

// the tiles of the foliage texture, two by two: a spruce's frond, a
// pine's tufts of needles, a hanging spray of small leaves, a cluster of
// broad ones
m.FROND = 0
m.TUFT = 1
m.SPRAY = 2
m.CLUSTER = 3

local pi = math.pi

// ------------------------------------------------------------ building

local func builder(){
  return {v: {}, n: {}, t: {}, c: {}, g: {}, i: {}, count: 0}
}

local func byte(x){
  if(x <= 0){
    return 0
  }
  if(x >= 1){
    return 255
  }
  return to_int(x * 255)
}

// a vertex: its place, normal, texture place, the four of its color
// (0..1 each), its own color and what it is made of; its number comes back
local func vertex(b, x, y, z, nx, ny, nz, u, v, sway, flutter, open, branch, r, g, bl, made){
  local k = b.count
  append(b.v, x)
  append(b.v, y)
  append(b.v, z)
  append(b.n, nx)
  append(b.n, ny)
  append(b.n, nz)
  append(b.t, u)
  append(b.t, v)
  append(b.c, byte(sway))
  append(b.c, byte(flutter))
  append(b.c, byte(open))
  append(b.c, byte(branch))
  append(b.g, r)
  append(b.g, g)
  append(b.g, bl)
  append(b.g, made)
  b.count = k + 1
  return k
}

local func face(b, i0, i1, i2){
  append(b.i, i0)
  append(b.i, i1)
  append(b.i, i2)
}

// a triangle seen from both sides
local func face2(b, i0, i1, i2){
  append(b.i, i0)
  append(b.i, i1)
  append(b.i, i2)
  append(b.i, i0)
  append(b.i, i2)
  append(b.i, i1)
}

// how far the wind bends a tree at a height: nothing at the ground, most
// at the top, and less of a small tree
local func sway_at(y, height){
  local t = vec.clamp(y / height, 0, 1)
  return t * math.sqrt(t) * math.min(1, height / 14)
}

// the place of a tile's (u, v) in the whole texture
local func tile_u(tile, u){
  return (tile % 2) * 0.5 + u * 0.5
}

local func tile_v(tile, v){
  return math.floor(tile / 2) * 0.5 + v * 0.5
}

// tube(b, path, sides, o): a round limb along a path of {x, y, z, r}
// (r: its radius there), sides around; o: {color, top?: the color at its
// end, made, height: the tree's (for the sway), flutter?, branch?,
// open?, cap?: closed at its end, cap_start?, turns?: how often the bark
// goes around}
local func tube(b, path, sides, o){
  local n = len(path)
  local first = b.count
  local along = 0
  local c0 = o.color
  local c1 = o.top or o.color
  for(local i = 0; i < n; i = i + 1){
    local p = path[i]
    local a = path[math.max(0, i - 1)]
    local c = path[math.min(n - 1, i + 1)]
    local t = vec.normalize({x: c.x - a.x, y: c.y - a.y, z: c.z - a.z})
    local ref = if(math.abs(t.y) < 0.95){ {x: 0, y: 1, z: 0} } else { {x: 1, y: 0, z: 0} }
    local bx = vec.normalize(vec.cross(ref, t))
    local by = vec.cross(t, bx)
    if(i > 0){
      local q = path[i - 1]
      along = along + math.sqrt((p.x - q.x) * (p.x - q.x) + (p.y - q.y) * (p.y - q.y) + (p.z - q.z) * (p.z - q.z))
    }
    local k = i / (n - 1)
    local r = c0[0] + (c1[0] - c0[0]) * k
    local g = c0[1] + (c1[1] - c0[1]) * k
    local bl = c0[2] + (c1[2] - c0[2]) * k
    local sway = sway_at(p.y, o.height)
    for(local s = 0; s <= sides; s = s + 1){
      local angle = s / sides * 2 * pi
      local ca = math.cos(angle)
      local sa = math.sin(angle)
      local nx = bx.x * ca + by.x * sa
      local ny = bx.y * ca + by.y * sa
      local nz = bx.z * ca + by.z * sa
      vertex(b, p.x + nx * p.r, p.y + ny * p.r, p.z + nz * p.r, nx, ny, nz,
        s / sides * (o.turns or 1), along, sway, o.flutter or 0, o.open or 0.8, o.branch or 0,
        r, g, bl, o.made)
    }
  }
  local row = sides + 1
  for(local i = 0; i + 1 < n; i = i + 1){
    for(local s = 0; s < sides; s = s + 1){
      local a = first + i * row + s
      face(b, a, a + 1, a + row)
      face(b, a + 1, a + row + 1, a + row)
    }
  }
  // the ends, flat
  for(let local end in values({0, n - 1})){
    if((end == 0 and o.cap_start) or (end == n - 1 and o.cap)){
      local p = path[end]
      local q = path[if(end == 0){ 1 } else { n - 2 }]
      local t = vec.normalize({x: p.x - q.x, y: p.y - q.y, z: p.z - q.z})
      local cc = o.cap_color or c1
      local center = vertex(b, p.x, p.y, p.z, t.x, t.y, t.z, 0.5, 0.5, sway_at(p.y, o.height), 0,
        o.open or 0.8, 0, cc[0], cc[1], cc[2], m.RINGS)
      local ring = first + end * row
      local rim = b.count
      for(local s = 0; s <= sides; s = s + 1){
        local at = ring + s
        vertex(b, b.v[at * 3], b.v[at * 3 + 1], b.v[at * 3 + 2], t.x, t.y, t.z, 0.5 + 0.5 * math.cos(s / sides * 2 * pi),
          0.5 + 0.5 * math.sin(s / sides * 2 * pi), sway_at(p.y, o.height), 0, o.open or 0.8, 0,
          cc[0] * 0.8, cc[1] * 0.8, cc[2] * 0.8, m.RINGS)
      }
      for(local s = 0; s < sides; s = s + 1){
        if(end == 0){
          face(b, center, rim + s + 1, rim + s)
        } else {
          face(b, center, rim + s, rim + s + 1)
        }
      }
    }
  }
}

// card(b, corners, normals, tile, o): a foliage card of four corners
// (a strip's two ends: left and right at its start, left and right at
// its end) with a normal for each; the tile's u runs from u0 to u1 across
// it and its v from v0 to v1 along it. o: {tint, sway: {start, end},
// flutter: {start, end}, open: {start, end}, branch}
local func card(b, c, n, tile, u0, u1, v0, v1, o){
  local t = o.tint
  local i0 = vertex(b, c[0].x, c[0].y, c[0].z, n[0].x, n[0].y, n[0].z, tile_u(tile, u0), tile_v(tile, v0),
    o.sway[0], o.flutter[0], o.open[0], o.branch, t[0], t[1], t[2], m.LEAF)
  local i1 = vertex(b, c[1].x, c[1].y, c[1].z, n[1].x, n[1].y, n[1].z, tile_u(tile, u1), tile_v(tile, v0),
    o.sway[0], o.flutter[0], o.open[0], o.branch, t[0], t[1], t[2], m.LEAF)
  local i2 = vertex(b, c[2].x, c[2].y, c[2].z, n[2].x, n[2].y, n[2].z, tile_u(tile, u0), tile_v(tile, v1),
    o.sway[1], o.flutter[1], o.open[1], o.branch, t[0], t[1], t[2], m.LEAF)
  local i3 = vertex(b, c[3].x, c[3].y, c[3].z, n[3].x, n[3].y, n[3].z, tile_u(tile, u1), tile_v(tile, v1),
    o.sway[1], o.flutter[1], o.open[1], o.branch, t[0], t[1], t[2], m.LEAF)
  face2(b, i0, i1, i2)
  face2(b, i1, i3, i2)
}

// a normal for foliage at a place: out of the crown around an axis point,
// and up a little
local func crown_normal(p, center, up){
  return vec.normalize({x: p.x - center.x, y: (p.y - center.y) + up, z: p.z - center.z})
}

// tuft(b, at, size, tile, quads, center, o, rng): a ball of foliage: a few
// square cards through one point, turned every way
local func tuft(b, at, size, tile, quads, center, o, rng){
  local n = crown_normal(at, center, o.up or 0.35)
  for(local q = 0; q < quads; q = q + 1){
    local axis = vec.normalize({x: rng:range(-1, 1), y: rng:range(-0.4, 1), z: rng:range(-1, 1)})
    local side = vec.normalize(vec.cross(axis, {x: rng:range(-1, 1), y: rng:range(-1, 1), z: rng:range(-1, 1)}))
    local h = size / 2
    local corners = {}
    local normals = {}
    for(let local s in values({{-1, -1}, {1, -1}, {-1, 1}, {1, 1}})){
      local p = {
        x: at.x + (side.x * s[0] + axis.x * s[1]) * h,
        y: at.y + (side.y * s[0] + axis.y * s[1]) * h,
        z: at.z + (side.z * s[0] + axis.z * s[1]) * h,
      }
      append(corners, p)
      // between the crown's normal and the corner's own way out of the tuft
      append(normals, vec.normalize(vec.add(vec.scale(n, 1.4), vec.normalize(vec.sub(p, at)))))
    }
    card(b, corners, normals, tile, 0, 1, 0, 1, o)
  }
}

// What a kind's foliage looks like as one color: see FAR further down
// (filled in by render/flora before any shape is made).
local FAR = {}

// core(b, height, center, rx, ry, color, seed): the inside of a crown: a
// lumpy ball in the foliage's own color, darker, behind the cards. A
// crown of cards alone has holes the sky shows through, most of all at
// mid distance, where the cards are few, and from above.
local func core(b, height, center, rx, ry, color, seed){
  local shape = plants.ball(1)
  local first = b.count
  for(let local d in values(shape.points)){
    local k = 0.8 + 0.4 * (vec.noise(d.x * 2.3 + seed, d.z * 2.3 + d.y * 1.9, seed) * 0.5 + 0.5)
    local x = center.x + d.x * rx * k
    local y = center.y + d.y * ry * k * (if(d.y < 0){ 0.8 } else { 1 })
    local z = center.z + d.z * rx * k
    local n = vec.normalize({x: d.x, y: d.y + 0.3, z: d.z})
    // (in the shade of the leaves around it)
    local open = 0.3 + 0.4 * vec.clamp(d.y * 0.6 + 0.5, 0, 1)
    vertex(b, x, y, z, n.x, n.y, n.z, 0, 0, sway_at(y, height), 0.3, open, 0.5 + 0.5 * d.x,
      color[0], color[1], color[2], m.PLAIN)
  }
  for(let local f in values(shape.faces)){
    face(b, first + f[0], first + f[1], first + f[2])
  }
}

// the same for a conifer: a cone around the trunk, from low up to top
local func cone_core(b, height, at, low, top, radius, color){
  local sides = 6
  local first = b.count
  local apex = at(top)
  for(local s = 0; s <= sides; s = s + 1){
    local a = s / sides * 2 * pi
    local base = at(low)
    local n = vec.normalize({x: math.sin(a), y: 0.4, z: math.cos(a)})
    vertex(b, base.x + math.sin(a) * radius, low, base.z + math.cos(a) * radius, n.x, n.y, n.z, 0, 0, sway_at(low, height), 0.2,
      0.3, s / sides, color[0], color[1], color[2], m.PLAIN)
    vertex(b, apex.x, top, apex.z, n.x, n.y, n.z, 0, 0, sway_at(top, height), 0.2, 0.6, s / sides,
      color[0], color[1], color[2], m.PLAIN)
  }
  for(local s = 0; s < sides; s = s + 1){
    local a = first + s * 2
    face(b, a, a + 2, a + 1)
  }
}

// a foliage color darker, for a core
local func darker(color, k){
  return {color[0] * k, color[1] * k, color[2] * k}
}

// ------------------------------------------------------------ conifers

// one branch of a conifer: a frond draped over it like a tent, its two
// halves hanging down to the sides, so that it shows from every side
local func frond(b, from, phi, long, o, t, rng, sections, axis){
  local dx = math.sin(phi)
  local dz = math.cos(phi)
  // across the branch, level
  local sx = dz
  local sz = -dx
  local up = math.tan(o.up + (o.up_top - o.up) * t)
  local droop = (o.droop + ((o.droop_top or o.droop) - o.droop) * t) * rng:range(0.8, 1.25)
  local wide = long * o.wide
  local reach = math.cos(o.drop)
  local fall = math.sin(o.drop)
  local branch = rng:next()
  local tint_k = rng:range(0.84, 1.12)
  local r = o.needle[0] * tint_k
  local g = o.needle[1] * tint_k
  local bl = o.needle[2] * tint_k
  local first = b.count
  for(local i = 0; i < sections; i = i + 1){
    local s = i / (sections - 1)
    local out = long * s
    local rise = long * (up * s - droop * s * s + o.curl * s * s * s * s)
    local mx = from.x + dx * out
    local my = from.y + rise
    local mz = from.z + dz * out
    // widest a third of the way out, a point at the end
    local f = 0.24
    if(sections == 2){
      f = if(i == 0){ 0.9 } else { 0.5 }
    } else if(i == 0){
      f = 0.5
    } else if(i < sections - 1){
      f = 1.06 - 0.3 * (i - 1) / math.max(1, sections - 3)
    }
    local w = wide * f
    local v = tile_v(m.FROND, 0.97 - 0.94 * s)
    local open = (0.3 + 0.7 * (s) ^ (0.7)) * (0.66 + 0.34 * t)
    local sway = sway_at(my, o.height)
    local n = crown_normal({x: mx, y: my, z: mz}, axis, 0.55)
    for(local side = -1; side <= 1; side = side + 1){
      local px = mx + sx * w * reach * side
      local py = my - math.abs(side) * w * fall
      local pz = mz + sz * w * reach * side
      // the halves face out to their sides
      local nn = vec.normalize({x: n.x + sx * side * 0.45, y: n.y - math.abs(side) * 0.1, z: n.z + sz * side * 0.45})
      vertex(b, px, py, pz, nn.x, nn.y, nn.z, tile_u(m.FROND, 0.5 + 0.5 * side), v, sway,
        s * (0.6 + 0.4 * math.abs(side)), open * (1 - 0.18 * math.abs(side)), branch, r, g, bl, m.LEAF)
    }
  }
  for(local i = 0; i + 1 < sections; i = i + 1){
    local a = first + i * 3
    face2(b, a, a + 1, a + 3)
    face2(b, a + 1, a + 4, a + 3)
    face2(b, a + 1, a + 2, a + 4)
    face2(b, a + 2, a + 5, a + 4)
  }
}

// What a conifer is made from.
// type Conifer = {height, trunk, crown, layers, first, per, taper, up,
//   up_top, droop, curl, wide, hang, bark, needle, seed}
// [crown]: how long the lowest branches are; [first]: where up the trunk
// they begin (a share of the height); [per]: branches in a whorl

local SPRUCE = {
  name: "spruce", height: 17.5, trunk: 0.27, crown: 3.7, layers: 19, first: 0.12, per: 6, taper: 0.82,
  up: 0.12, up_top: 0.6, droop: 0.5, droop_top: 0.15, curl: 0.22, wide: 0.4, drop: 0.78,
  bark: {0.16, 0.125, 0.095}, needle: {0.56, 0.68, 0.54}, seed: 11,
}
local FIR = {
  name: "fir", height: 15.5, trunk: 0.21, crown: 2.15, layers: 21, first: 0.1, per: 5, taper: 0.6,
  up: 0.05, up_top: 0.8, droop: 0.22, droop_top: 0.05, curl: 0.1, wide: 0.46, drop: 0.55,
  bark: {0.2, 0.19, 0.175}, needle: {0.46, 0.6, 0.62}, seed: 23,
}
local SAPLING = {
  name: "sapling", height: 3.4, trunk: 0.05, crown: 1.05, layers: 9, first: 0.1, per: 5, taper: 0.75,
  up: 0.25, up_top: 0.7, droop: 0.25, droop_top: 0.1, curl: 0.15, wide: 0.44, drop: 0.6,
  bark: {0.15, 0.12, 0.09}, needle: {0.66, 0.8, 0.5}, seed: 37,
}

local func conifer(o, lod){
  local b = builder()
  local rng = vec.random(o.seed)
  local height = o.height
  local sides = if(lod == 0){ 8 } else { 5 }
  local parts = if(lod == 0){ 7 } else { 3 }
  local lean_x = rng:range(-0.14, 0.14)
  local lean_z = rng:range(-0.14, 0.14)
  local path = {}
  for(local i = 0; i <= parts; i = i + 1){
    local t = i / parts
    append(path, {
      x: lean_x * math.sin(t * pi) * height / 17, y: -0.3 + (height * 0.985 + 0.3) * t,
      z: lean_z * math.sin(t * pi) * height / 17,
      r: o.trunk * (if(i == 0){ 1.25 } else { (1 - t) ^ (0.85) }) + 0.015,
    })
  }
  tube(b, path, sides, {color: o.bark, made: m.BARK, height: height, turns: 2, open: 0.6})
  local func axis_at(y){
    local t = vec.clamp(y / height, 0, 1)
    return {x: lean_x * math.sin(t * pi) * height / 17, y: y, z: lean_z * math.sin(t * pi) * height / 17}
  }
  local layers = if(lod == 0){ o.layers } else { math.max(6, to_int(o.layers * 0.7)) }
  local sections = if(lod == 0){ 4 } else { 2 }
  local azimuth = rng:range(0, 2 * pi)
  if(lod > 0){
    // fewer branches, each bigger, so that the crown stays as full
    o = {...o, wide: o.wide * 1.55}
  }
  for(local l = 0; l < layers; l = l + 1){
    local t = (l + 0.6 * rng:next()) / layers
    local y = height * (o.first + (0.97 - o.first) * (t) ^ (0.92))
    local long = (o.crown * (1 - t) ^ (o.taper) + 0.24) * rng:range(0.86, 1.1)
    if(lod > 0){
      long = long * 1.15
    }
    local count = to_int(o.per + (3.2 - o.per) * t + 0.5)
    if(lod > 0){
      count = math.max(3, count - 1)
    }
    azimuth = azimuth + 2.4 + rng:range(-0.3, 0.3)
    local from = axis_at(y)
    for(local k = 0; k < count; k = k + 1){
      local phi = azimuth + k * 2 * pi / count + rng:range(-0.22, 0.22)
      frond(b, from, phi, long * rng:range(0.84, 1.1), o, t, rng, sections,
        {x: from.x, y: y - long * 0.5, z: from.z})
    }
  }
  // the inside of the crown: skirts of foliage around the trunk, each a
  // fan of fronds hanging outward, in the shade of the branches, so that
  // the sky does not show through between the whorls
  local skirts = if(lod == 0){ to_int(layers * 0.75) } else { to_int(layers * 0.5) }
  local fans = if(lod == 0){ 7 } else { 5 }
  for(local l = 0; l < skirts; l = l + 1){
    local t = (l + 0.5) / skirts
    local y = height * (o.first + 0.03 + (0.9 - o.first) * t)
    local reach = (o.crown * (1 - t) ^ (o.taper) + 0.2) * 0.74
    local fall = reach * (0.42 + 0.5 * o.droop)
    local from = axis_at(y)
    local turn = rng:range(0, 2 * pi)
    local shade = rng:range(0.74, 0.9)
    for(local k = 0; k < fans; k = k + 1){
      local a0 = turn + k * 2 * pi / fans
      local a1 = turn + (k + 1.12) * 2 * pi / fans
      local am = (a0 + a1) / 2
      local n = vec.normalize({x: math.sin(am), y: 0.75, z: math.cos(am)})
      local sway = sway_at(y, height)
      local i0 = vertex(b, from.x, y, from.z, n.x * 0.4, 0.9, n.z * 0.4, tile_u(m.FROND, 0.5), tile_v(m.FROND, 0.97), sway, 0,
        0.3 + 0.2 * t, 0.3, o.needle[0] * shade, o.needle[1] * shade, o.needle[2] * shade, m.LEAF)
      local i1 = vertex(b, from.x + math.sin(a0) * reach, y - fall, from.z + math.cos(a0) * reach, n.x, n.y, n.z,
        tile_u(m.FROND, 0.02), tile_v(m.FROND, 0.2), sway, 0.5, 0.5 + 0.3 * t, 0.3,
        o.needle[0] * shade, o.needle[1] * shade, o.needle[2] * shade, m.LEAF)
      local i2 = vertex(b, from.x + math.sin(a1) * reach, y - fall, from.z + math.cos(a1) * reach, n.x, n.y, n.z,
        tile_u(m.FROND, 0.98), tile_v(m.FROND, 0.2), sway, 0.5, 0.5 + 0.3 * t, 0.3,
        o.needle[0] * shade, o.needle[1] * shade, o.needle[2] * shade, m.LEAF)
      face2(b, i0, i2, i1)
    }
  }
  cone_core(b, height, axis_at, height * (o.first + 0.05), height * 0.9, o.crown * 0.42, darker(FAR[o.name], 0.7))
  // the tip: the leader, a narrow frond standing straight up (two cards
  // crossed)
  local top = axis_at(height * 0.92)
  local tall = height * 0.1 + 0.35
  local half = 0.2 + o.crown * 0.07
  local k = 1.05
  for(local q = 0; q < 2; q = q + 1){
    local sx = math.cos(q * pi / 2 + azimuth)
    local sz = math.sin(q * pi / 2 + azimuth)
    local corners = {
      {x: top.x - sx * half, y: top.y, z: top.z - sz * half}, {x: top.x + sx * half, y: top.y, z: top.z + sz * half},
      {x: top.x - sx * half, y: top.y + tall, z: top.z - sz * half}, {x: top.x + sx * half, y: top.y + tall, z: top.z + sz * half},
    }
    local normals = {}
    for(let local c in values(corners)){
      append(normals, crown_normal(c, {x: top.x, y: top.y - 1, z: top.z}, 0.6))
    }
    card(b, corners, normals, m.FROND, 0, 1, 0.97, 0.03, {
      tint: {o.needle[0] * k, o.needle[1] * k, o.needle[2] * k}, branch: 0.5,
      sway: {sway_at(top.y, height), sway_at(top.y + tall, height)}, flutter: {0.2, 0.8}, open: {0.85, 1},
    })
  }
  return b
}

// a conifer far off: two cones on a stick
local func far_conifer(o, color){
  local b = builder()
  local sides = 6
  local base = o.height * o.first
  tube(b, {{x: 0, y: -0.3, z: 0, r: o.trunk * 0.9}, {x: 0, y: base + 1, z: 0, r: o.trunk * 0.7}}, 4,
    {color: o.bark, made: m.BARK, height: o.height, open: 0.6})
  local tiers = {
    {from: base, to: o.height * 0.62, r: o.crown * 0.92},
    {from: o.height * 0.36, to: o.height * 0.99, r: o.crown * 0.56},
  }
  for(let local tier in values(tiers)){
    local first = b.count
    local slope = tier.r / (tier.to - tier.from)
    for(local s = 0; s <= sides; s = s + 1){
      local a = s / sides * 2 * pi
      local nx = math.sin(a)
      local nz = math.cos(a)
      local n = vec.normalize({x: nx, y: slope + 0.25, z: nz})
      // the skirt hangs a little between the branches
      local r = tier.r * (if(s % 2 == 0){ 1 } else { 0.86 })
      vertex(b, nx * r, tier.from, nz * r, n.x, n.y, n.z, 0, 0, sway_at(tier.from, o.height), 0.4, 0.62, s / sides,
        color[0] * 0.8, color[1] * 0.8, color[2] * 0.8, m.PLAIN)
      vertex(b, 0, tier.to, 0, n.x * 0.6, 0.8, n.z * 0.6, 0, 0, sway_at(tier.to, o.height), 0.2, 1, s / sides,
        color[0] * 1.15, color[1] * 1.15, color[2] * 1.15, m.PLAIN)
    }
    for(local s = 0; s < sides; s = s + 1){
      local a = first + s * 2
      face(b, a, a + 2, a + 1)
    }
  }
  return b
}

// ------------------------------------------------------------ broadleaf

// a limb from a point: out by a length at an angle from straight up,
// bending a little; returns its path
local func limb(from, phi, tilt, long, r0, r1, parts, lift, rng){
  local path = {}
  local dx = math.sin(phi) * math.sin(tilt)
  local dz = math.cos(phi) * math.sin(tilt)
  local dy = math.cos(tilt)
  local wx = rng:range(-0.12, 0.12)
  local wz = rng:range(-0.12, 0.12)
  for(local i = 0; i <= parts; i = i + 1){
    local s = i / parts
    append(path, {
      x: from.x + (dx * s + wx * math.sin(s * pi)) * long,
      y: from.y + (dy * s + lift * s * s) * long,
      z: from.z + (dz * s + wz * math.sin(s * pi)) * long,
      r: r0 + (r1 - r0) * s,
    })
  }
  return path
}

local func point_on(path, s){
  local n = len(path) - 1
  local f = vec.clamp(s, 0, 1) * n
  local i = math.min(n - 1, to_int(f))
  local a = path[i]
  local c = path[i + 1]
  local k = f - i
  return {x: a.x + (c.x - a.x) * k, y: a.y + (c.y - a.y) * k, z: a.z + (c.z - a.z) * k}
}

// a pine: a tall bare trunk, red toward the top, limbs at its head with
// tufts of long needles
local func pine(lod){
  local b = builder()
  local rng = vec.random(51)
  local height = 15
  local low = {0.16, 0.12, 0.09}
  local high = {0.38, 0.18, 0.08}
  local needle = {0.66, 0.72, 0.48}
  local parts = if(lod == 0){ 8 } else { 4 }
  local bend_x = rng:range(-0.5, 0.5)
  local bend_z = rng:range(-0.5, 0.5)
  local func axis_at(t){
    return {x: bend_x * math.sin(t * pi * 1.1) * t, y: -0.3 + (height + 0.3) * t, z: bend_z * math.sin(t * pi * 0.9) * t}
  }
  local path = {}
  for(local i = 0; i <= parts; i = i + 1){
    local t = i / parts * 0.97
    local p = axis_at(t)
    p.r = 0.25 * (if(i == 0){ 1.3 } else { 1 - 0.78 * t }) + 0.01
    append(path, p)
  }
  tube(b, path, if(lod == 0){ 8 } else { 5 }, {color: low, top: high, made: m.PLATES, height: height, turns: 2, open: 0.75})
  local center = axis_at(0.8)
  local limbs = if(lod == 0){ 13 } else { 7 }
  local azimuth = rng:range(0, 6)
  for(local k = 0; k < limbs; k = k + 1){
    local t = 0.56 + 0.4 * (k + rng:next() * 0.6) / limbs
    local from = axis_at(t)
    azimuth = azimuth + 2.3 + rng:range(-0.4, 0.4)
    local long = (3.3 - 2.1 * (t - 0.56) / 0.4) * rng:range(0.8, 1.15)
    local path2 = limb(from, azimuth, 1.25 - 0.7 * (t - 0.56) / 0.4, long, 0.075 * (1.2 - t), 0.018, 3, 0.22, rng)
    if(lod == 0){
      tube(b, path2, 5, {color: high, made: m.PLATES, height: height, open: 0.6, branch: rng:next()})
    }
    local tufts = if(lod == 0){ 5 } else { 3 }
    for(local q = 0; q < tufts; q = q + 1){
      local s = 0.35 + 0.65 * (q + 1) / tufts
      local at = point_on(path2, s)
      at.x = at.x + rng:range(-0.3, 0.3)
      at.y = at.y + rng:range(-0.1, 0.35)
      at.z = at.z + rng:range(-0.3, 0.3)
      local k2 = rng:range(0.85, 1.12)
      local open = 0.55 + 0.45 * s
      tuft(b, at, rng:range(1.2, 1.75) * (if(lod == 0){ 1 } else { 1.45 }), m.TUFT, if(lod == 0){ 3 } else { 2 }, center, {
        tint: {needle[0] * k2, needle[1] * k2, needle[2] * k2}, branch: rng:next(),
        sway: {sway_at(at.y, height), sway_at(at.y, height)}, flutter: {0.7, 0.7}, open: {open, open}, up: 0.5,
      }, rng)
    }
  }
  core(b, height, {x: center.x, y: center.y - 0.3, z: center.z}, 1.7, 2.0, darker(FAR.pine, 0.8), 13)
  // tufts all over the head, so that it is a crown from every side
  for(local q = 0; q < (if(lod == 0){ 16 } else { 12 }); q = q + 1){
    local d = vec.normalize({x: rng:range(-1, 1), y: rng:range(-0.5, 1), z: rng:range(-1, 1)})
    local at = {x: center.x + d.x * 2.1, y: center.y - 0.3 + d.y * 2.3, z: center.z + d.z * 2.1}
    local k2 = rng:range(0.85, 1.12)
    local open = 0.6 + 0.4 * vec.clamp(d.y * 0.5 + 0.5, 0, 1)
    tuft(b, at, rng:range(1.5, 1.9) * (if(lod == 0){ 1 } else { 1.35 }), m.TUFT, 2, center, {
      tint: {needle[0] * k2, needle[1] * k2, needle[2] * k2}, branch: rng:next(),
      sway: {sway_at(at.y, height), sway_at(at.y, height)}, flutter: {0.7, 0.7}, open: {open, open}, up: 0.5,
    }, rng)
  }
  // the head
  for(local q = 0; q < (if(lod == 0){ 6 } else { 3 }); q = q + 1){
    local at = axis_at(0.97)
    at.x = at.x + rng:range(-0.6, 0.6)
    at.y = at.y + rng:range(-0.5, 0.5)
    at.z = at.z + rng:range(-0.6, 0.6)
    tuft(b, at, 1.7, m.TUFT, 3, center, {
      tint: needle, branch: rng:next(), sway: {sway_at(at.y, height), sway_at(at.y, height)},
      flutter: {0.8, 0.8}, open: {1, 1}, up: 0.6,
    }, rng)
  }
  return b
}

// a birch: a slender pale trunk, limbs rising steeply, sprays of small
// leaves hanging from them
local func birch(lod){
  local b = builder()
  local rng = vec.random(71)
  local height = 11.5
  local bark = {0.62, 0.6, 0.55}
  local leafy = {0.5, 0.56, 0.72}
  local bend_x = rng:range(-0.45, 0.45)
  local bend_z = rng:range(-0.45, 0.45)
  local func axis_at(t){
    return {x: bend_x * t * t, y: -0.3 + (height * 0.9 + 0.3) * t, z: bend_z * math.sin(t * 2.2)}
  }
  local parts = if(lod == 0){ 7 } else { 3 }
  local path = {}
  for(local i = 0; i <= parts; i = i + 1){
    local t = i / parts
    local p = axis_at(t)
    p.r = 0.15 * (if(i == 0){ 1.35 } else { 1 - 0.86 * t }) + 0.012
    append(path, p)
  }
  tube(b, path, if(lod == 0){ 7 } else { 4 }, {color: bark, made: m.BIRCH, height: height, turns: 1, open: 0.85})
  local center = axis_at(0.68)
  local limbs = if(lod == 0){ 13 } else { 7 }
  local azimuth = rng:range(0, 6)
  local func spray(at, long, wide, open){
    // a card hanging from a point, in an upright plane turned any way
    local a = rng:range(0, 2 * pi)
    local sx = math.sin(a)
    local sz = math.cos(a)
    local out = vec.normalize({x: at.x - center.x, y: 0, z: at.z - center.z})
    local low = {x: at.x + out.x * long * 0.18, y: at.y - long, z: at.z + out.z * long * 0.18}
    local k = rng:range(0.82, 1.12)
    local look = {
      tint: {leafy[0] * k, leafy[1] * k, leafy[2] * (1.5 - k * 0.5)}, branch: rng:next(),
      sway: {sway_at(at.y, height), sway_at(low.y, height)}, flutter: {0.25, 1}, open: {open, open * 0.9}, up: 0.3,
    }
    local w = wide / 2
    local corners = {
      {x: at.x + sx * w, y: at.y + 0.08, z: at.z + sz * w}, {x: at.x - sx * w, y: at.y + 0.08, z: at.z - sz * w},
      {x: low.x + sx * w, y: low.y, z: low.z + sz * w}, {x: low.x - sx * w, y: low.y, z: low.z - sz * w},
    }
    local normals = {}
    for(let local c in values(corners)){
      append(normals, crown_normal(c, center, 0.35))
    }
    card(b, corners, normals, m.SPRAY, 0, 1, 0, 1, look)
  }
  for(local k = 0; k < limbs; k = k + 1){
    local t = 0.3 + 0.62 * (k + rng:next() * 0.5) / limbs
    local from = axis_at(t)
    azimuth = azimuth + 2.4 + rng:range(-0.4, 0.4)
    local long = (3.9 - 2.3 * (t - 0.3) / 0.62) * rng:range(0.8, 1.15)
    local path2 = limb(from, azimuth, 0.7 + 0.3 * rng:next(), long, 0.05 * (1.3 - t), 0.012, 3, -0.12, rng)
    if(lod == 0){
      tube(b, path2, 4, {color: {0.2, 0.17, 0.14}, made: m.BARK, height: height, open: 0.7, branch: rng:next()})
    }
    local sprays = if(lod == 0){ 6 } else { 3 }
    for(local q = 0; q < sprays; q = q + 1){
      local s = 0.25 + 0.75 * (q + rng:next()) / sprays
      local at = point_on(path2, s)
      at.x = at.x + rng:range(-0.45, 0.45)
      at.y = at.y + rng:range(-0.1, 0.4)
      at.z = at.z + rng:range(-0.45, 0.45)
      spray(at, rng:range(1.25, 1.95) * (if(lod == 0){ 1 } else { 1.3 }), rng:range(0.95, 1.35) * (if(lod == 0){ 1 } else { 1.5 }),
        0.55 + 0.45 * s)
    }
  }
  core(b, height, {x: center.x, y: center.y - 0.2, z: center.z}, 1.25, 3.0, darker(FAR.birch, 0.8), 17)
  // sprays all around the crown, so that it is one from every side
  for(local q = 0; q < (if(lod == 0){ 22 } else { 18 }); q = q + 1){
    local d = vec.normalize({x: rng:range(-1, 1), y: rng:range(-0.7, 1), z: rng:range(-1, 1)})
    local at = {x: center.x + d.x * 1.75, y: center.y + 0.5 + d.y * 3.3, z: center.z + d.z * 1.75}
    spray(at, rng:range(1.3, 1.9) * (if(lod == 0){ 1 } else { 1.25 }), rng:range(1.0, 1.4) * (if(lod == 0){ 1 } else { 1.4 }),
      0.6 + 0.4 * vec.clamp(d.y * 0.5 + 0.5, 0, 1))
  }
  // (hanging sprays are seen edge on from above: leaves lying any way
  // over the crown's upper half)
  for(local q = 0; q < (if(lod == 0){ 14 } else { 11 }); q = q + 1){
    local d = vec.normalize({x: rng:range(-1, 1), y: rng:range(0.15, 1), z: rng:range(-1, 1)})
    local at = {x: center.x + d.x * 1.45, y: center.y - 0.2 + d.y * 3.1, z: center.z + d.z * 1.45}
    local k = rng:range(0.82, 1.12)
    local open = 0.75 + 0.25 * d.y
    tuft(b, at, rng:range(1.3, 1.7) * (if(lod == 0){ 1 } else { 1.3 }), m.SPRAY, 2, center, {
      tint: {leafy[0] * k, leafy[1] * k, leafy[2] * (1.5 - k * 0.5)}, branch: rng:next(),
      sway: {sway_at(at.y, height), sway_at(at.y, height)}, flutter: {0.7, 0.7}, open: {open, open}, up: 0.6,
    }, rng)
  }
  // the top
  for(local q = 0; q < (if(lod == 0){ 14 } else { 7 }); q = q + 1){
    local at = axis_at(0.78 + 0.22 * rng:next())
    at.x = at.x + rng:range(-0.7, 0.7)
    at.y = at.y + rng:range(0, 0.9)
    at.z = at.z + rng:range(-0.7, 0.7)
    spray(at, rng:range(1.0, 1.5), rng:range(0.8, 1.1), 1)
  }
  return b
}

// an oak: a thick short trunk, limbs spreading wide, a round dense crown
// of leaf clusters
local func oak(lod){
  local b = builder()
  local rng = vec.random(91)
  local height = 11.5
  local bark = {0.15, 0.125, 0.1}
  local leafy = {0.6, 0.68, 0.48}
  local path = {}
  local parts = if(lod == 0){ 5 } else { 2 }
  for(local i = 0; i <= parts; i = i + 1){
    local t = i / parts
    append(path, {
      x: 0.12 * math.sin(t * 3), y: -0.3 + 4.6 * t, z: 0.1 * math.sin(t * 2.2 + 1),
      r: 0.36 * (if(i == 0){ 1.4 } else { 1 - 0.35 * t }),
    })
  }
  tube(b, path, if(lod == 0){ 8 } else { 5 }, {color: bark, made: m.FURROWS, height: height, turns: 2, open: 0.55})
  local fork = {x: path[parts].x, y: 4.2, z: path[parts].z}
  local center = {x: 0, y: 7.0, z: 0}
  local rx = 4.6
  local ry = 3.9
  local look_at = func(at){
    local d = vec.sub(at, center)
    local k = math.sqrt((d.x / rx) * (d.x / rx) + (d.y / ry) * (d.y / ry) + (d.z / rx) * (d.z / rx))
    local open = vec.clamp(0.25 + 0.75 * k * k, 0, 1) * (0.72 + 0.28 * vec.clamp((d.y + ry) / (2 * ry), 0, 1))
    local q = rng:range(0.84, 1.1)
    return {
      tint: {leafy[0] * q, leafy[1] * q, leafy[2] * q}, branch: rng:next(),
      sway: {sway_at(at.y, height), sway_at(at.y, height)}, flutter: {0.75, 0.75}, open: {open, open}, up: 0.25,
    }
  }
  local limbs = if(lod == 0){ 6 } else { 4 }
  local azimuth = rng:range(0, 6)
  for(local k = 0; k < limbs; k = k + 1){
    azimuth = azimuth + 2 * pi / limbs + rng:range(-0.3, 0.3)
    local tilt = if(k == 0){ 0.15 } else { rng:range(0.7, 1.15) }
    local long = rng:range(3.4, 4.6)
    local path2 = limb(fork, azimuth, tilt, long, 0.2, 0.05, 3, 0.18, rng)
    if(lod == 0){
      tube(b, path2, 5, {color: bark, made: m.FURROWS, height: height, open: 0.5})
      // each forks once
      local path3 = limb(point_on(path2, 0.55), azimuth + rng:range(0.6, 1.2), tilt * 0.8 + 0.2, long * 0.6, 0.09, 0.025, 2, 0.1, rng)
      tube(b, path3, 4, {color: bark, made: m.FURROWS, height: height, open: 0.5})
      for(local q = 0; q < 3; q = q + 1){
        local at = point_on(path3, 0.5 + 0.25 * q)
        tuft(b, at, rng:range(1.5, 1.9), m.CLUSTER, 2, center, look_at(at), rng)
      }
    }
    for(local q = 0; q < (if(lod == 0){ 4 } else { 2 }); q = q + 1){
      local at = point_on(path2, 0.45 + 0.55 * (q + 1) / (if(lod == 0){ 4 } else { 2 }))
      tuft(b, at, rng:range(1.6, 2.0), m.CLUSTER, if(lod == 0){ 3 } else { 2 }, center, look_at(at), rng)
    }
  }
  core(b, height, center, rx * 0.8, ry * 0.8, darker(FAR.oak, 0.8), 19)
  // the crown's skin: clusters all over a ball
  local skin = if(lod == 0){ 96 } else { 40 }
  for(local q = 0; q < skin; q = q + 1){
    local d = vec.normalize({x: rng:range(-1, 1), y: rng:range(-0.55, 1), z: rng:range(-1, 1)})
    local k = rng:range(0.72, 1.0)
    local at = {x: center.x + d.x * rx * k, y: center.y + d.y * ry * k, z: center.z + d.z * rx * k}
    tuft(b, at, rng:range(1.5, 2.0) * (if(lod == 0){ 1 } else { 1.8 }), m.CLUSTER, if(lod == 0){ 3 } else { 2 }, center,
      look_at(at), rng)
  }
  return b
}

// a blob of foliage on a stick: a broadleaf (or a pine's head) far off
local func far_blob(height, trunk, bark, center_y, rx, ry, color, seed, made){
  local b = builder()
  tube(b, {{x: 0, y: -0.3, z: 0, r: trunk}, {x: 0, y: center_y, z: 0, r: trunk * 0.6}}, 4,
    {color: bark, made: made or m.BARK, height: height, open: 0.7})
  local shape = plants.ball(1)
  local first = b.count
  for(let local d in values(shape.points)){
    // a lumpy crown, flatter underneath
    local k = 0.72 + 0.56 * (vec.noise(d.x * 2.3 + seed, d.z * 2.3 + d.y * 1.9, seed) * 0.5 + 0.5)
    local x = d.x * rx * k + 0.18 * rx * vec.noise(d.y * 2 + seed, d.z, seed + 3)
    local y = center_y + d.y * ry * k * (if(d.y < 0){ 0.62 } else { 1 })
    local z = d.z * rx * k + 0.18 * rx * vec.noise(d.x, d.y * 2 + seed, seed + 5)
    local n = vec.normalize({x: d.x, y: d.y + 0.3, z: d.z})
    local open = 0.62 + 0.38 * vec.clamp(d.y * 0.6 + 0.5, 0, 1)
    vertex(b, x, y, z, n.x, n.y, n.z, 0, 0, sway_at(y, height), 0.5, open, 0.5 + 0.5 * d.x,
      color[0], color[1], color[2], m.PLAIN)
  }
  for(let local f in values(shape.faces)){
    face(b, first + f[0], first + f[1], first + f[2])
  }
  return b
}

// a dead tree: a grey trunk broken off, bare stubs of branches
local func snag(lod){
  local b = builder()
  local rng = vec.random(113)
  local height = 9.5
  local grey = {0.2, 0.19, 0.17}
  local path = {}
  local parts = if(lod == 0){ 6 } else { 3 }
  for(local i = 0; i <= parts; i = i + 1){
    local t = i / parts
    append(path, {
      x: 0.25 * t * t, y: -0.3 + (height + 0.3) * t, z: -0.18 * math.sin(t * 2.5),
      r: 0.21 * (if(i == 0){ 1.3 } else { 1 - 0.6 * t }),
    })
  }
  tube(b, path, if(lod == 0){ 7 } else { 4 }, {
    color: grey, made: m.WOOD, height: height, turns: 2, open: 0.9, cap: true, cap_color: {0.26, 0.22, 0.17},
  })
  local stubs = if(lod == 0){ 13 } else { 5 }
  local azimuth = 0
  for(local k = 0; k < stubs; k = k + 1){
    local t = 0.25 + 0.7 * (k + rng:next()) / stubs
    azimuth = azimuth + 2.4 + rng:range(-0.5, 0.5)
    local from = point_on(path, t)
    local path2 = limb(from, azimuth, rng:range(1.3, 1.9), rng:range(0.7, 2.4) * (1.15 - t), 0.05, 0.012, 2, -0.2, rng)
    tube(b, path2, 3, {color: grey, made: m.WOOD, height: height, open: 0.9})
  }
  return b
}

// ------------------------------------------------------------ bushes

// a bush: stems from one root and a dome of leaf clusters (tile: which
// foliage), high and wide in meters
local func bush(lod, o){
  local b = builder()
  local rng = vec.random(o.seed)
  local center = {x: 0, y: o.high * 0.35, z: 0}
  if(lod == 0){
    for(local k = 0; k < o.stems; k = k + 1){
      local path = limb({x: 0, y: -0.1, z: 0}, k * 2 * pi / o.stems + rng:range(-0.3, 0.3), rng:range(0.25, 0.8),
        o.high * rng:range(0.6, 0.95), 0.03, 0.008, 2, -0.1, rng)
      tube(b, path, 3, {color: {0.12, 0.1, 0.08}, made: m.BARK, height: 14, open: 0.5})
    }
  }
  local clusters = if(lod == 0){ o.clusters } else { to_int(o.clusters * 0.4) }
  for(local q = 0; q < clusters; q = q + 1){
    local d = vec.normalize({x: rng:range(-1, 1), y: rng:range(-0.1, 1), z: rng:range(-1, 1)})
    local k = rng:range(0.55, 1.0)
    local at = {x: d.x * o.wide * k, y: center.y + d.y * o.high * 0.62 * k, z: d.z * o.wide * k}
    local open = vec.clamp(0.35 + 0.65 * k, 0, 1) * (0.7 + 0.3 * vec.clamp(at.y / o.high, 0, 1))
    local q2 = rng:range(0.84, 1.12)
    tuft(b, at, o.size * rng:range(0.85, 1.2) * (if(lod == 0){ 1 } else { 1.5 }), o.tile, if(lod == 0){ 2 } else { 2 }, center, {
      tint: {o.tint[0] * q2, o.tint[1] * q2, o.tint[2] * q2}, branch: rng:next(),
      sway: {0.02 * at.y, 0.02 * at.y}, flutter: {0.7, 0.7}, open: {open, open}, up: 0.5,
    }, rng)
  }
  return b
}

local BUSH = {seed: 131, high: 1.6, wide: 1.05, stems: 6, clusters: 26, size: 0.95, tile: m.SPRAY, tint: {0.4, 0.46, 0.7}}
local SHRUB = {seed: 151, high: 0.85, wide: 1.15, stems: 5, clusters: 20, size: 0.85, tile: m.TUFT, tint: {0.56, 0.66, 0.5}}

// ------------------------------------------------------------ rocks, logs

// a rock (a shape of game/plants): detail 0 the whole shape, every face
// flat, as broken stone is; 1 the shape without its chips (a small
// stone); 2 the same with its corners shared and smoothed (a rock far
// off). A river stone is smooth at every detail.
local func rock(index, detail){
  local b = builder()
  local shape = plants.rock_shapes()[index]
  local source = if(detail == 0){ shape } else { shape.coarse }
  local points = source.points
  local faces = source.faces
  local rng = vec.random(300 + index)
  // across the strata: a direction of the rock's own
  local bed = vec.normalize({x: rng:range(-0.6, 0.6), y: 1, z: rng:range(-0.6, 0.6)})
  if(shape.normals != null or detail == 2){
    // shared corners
    local normals = shape.normals
    if(normals == null){
      normals = {}
      for(local i = 0; i < len(points); i = i + 1){
        normals[i] = {x: 0, y: 0, z: 0}
      }
      for(let local f in values(faces)){
        local n = vec.cross(vec.sub(points[f[1]], points[f[0]]), vec.sub(points[f[2]], points[f[0]]))
        for(local k = 0; k < 3; k = k + 1){
          normals[f[k]] = vec.add(normals[f[k]], n)
        }
      }
      for(local i = 0; i < len(points); i = i + 1){
        normals[i] = vec.normalize(normals[i])
      }
    }
    local made = if(shape.normals != null){ m.ROUND } else { m.ROCK }
    for(local i = 0; i < len(points); i = i + 1){
      local q = points[i]
      local n = normals[i]
      // (far from any border: nothing is worn down)
      vertex(b, q.x, q.y, q.z, n.x, n.y, n.z, 0, 0, 0, 0, 1, 0, bed.x, bed.y, bed.z, made)
    }
    for(let local f in values(faces)){
      face(b, f[0], f[1], f[2])
    }
    return b
  }
  // the triangles of one flat face together: a fan around the face's
  // middle, which knows how far it is from the face's border
  local done = {}
  for(local t = 0; t < len(faces); t = t + 1){
    if(done[t]){
      continue
    }
    local f = faces[t]
    local a = points[f[0]]
    local n = vec.normalize(vec.cross(vec.sub(points[f[1]], a), vec.sub(points[f[2]], a)))
    // the face's border: the triangles from here on that lie in its
    // plane are its fan, in order (see plants.rock_shapes)
    local border = {f[0], f[1], f[2]}
    done[t] = true
    for(local u = t + 1; u < len(faces); u = u + 1){
      local g = faces[u]
      if(g[0] != f[0] or g[1] != border[len(border) - 1]){
        break
      }
      local gn = vec.normalize(vec.cross(vec.sub(points[g[1]], points[g[0]]), vec.sub(points[g[2]], points[g[0]])))
      if(vec.dot(gn, n) < 0.9999){
        break
      }
      append(border, g[2])
      done[u] = true
    }
    local count = len(border)
    local middle = {x: 0, y: 0, z: 0}
    for(let local id in values(border)){
      middle = vec.add_scaled(middle, points[id], 1 / count)
    }
    // how far the middle is from the nearest side
    local inner = 1.0e9
    for(local k = 0; k < count; k = k + 1){
      local p0 = points[border[k]]
      local p1 = points[border[(k + 1) % count]]
      local side = vec.normalize(vec.sub(p1, p0))
      local off = vec.sub(middle, p0)
      inner = math.min(inner, vec.length(vec.sub(off, vec.scale(side, vec.dot(off, side)))))
    }
    local first = b.count
    vertex(b, middle.x, middle.y, middle.z, n.x, n.y, n.z, 0, 0, 0, 0, math.min(1, inner / 0.4), 0, bed.x, bed.y, bed.z, m.ROCK)
    for(let local id in values(border)){
      local q = points[id]
      vertex(b, q.x, q.y, q.z, n.x, n.y, n.z, 0, 0, 0, 0, 0, 0, bed.x, bed.y, bed.z, m.ROCK)
    }
    for(local k = 0; k < count; k = k + 1){
      face(b, first, first + 1 + k, first + 1 + (k + 1) % count)
    }
  }
  return b
}

// a fallen trunk, lying along z, with the stubs of its branches
local func log(){
  local b = builder()
  local rng = vec.random(171)
  local kind = plants.KINDS[plants.LOG]
  local long = kind.length
  local bark = {0.1, 0.082, 0.064}
  local path = {}
  for(local i = 0; i <= 4; i = i + 1){
    local t = i / 4
    append(path, {
      x: 0.12 * math.sin(t * 3.4), y: 0.04 * math.sin(t * 5), z: (t - 0.5) * long,
      r: kind.radius * (1.12 - 0.3 * t),
    })
  }
  tube(b, path, 8, {
    color: bark, made: m.FURROWS, height: 1000, turns: 2, open: 0.8, cap: true, cap_start: true,
    cap_color: {0.36, 0.27, 0.16},
  })
  for(local k = 0; k < 4; k = k + 1){
    local from = point_on(path, 0.25 + 0.2 * k)
    local a = rng:range(0, 2 * pi)
    local dir = {x: math.cos(a), y: math.abs(math.sin(a)) + 0.2, z: rng:range(-0.4, 0.4)}
    local l = rng:range(0.3, 0.9)
    tube(b, {
      {x: from.x, y: from.y, z: from.z, r: 0.05},
      {x: from.x + dir.x * l, y: from.y + dir.y * l, z: from.z + dir.z * l, r: 0.02},
    }, 4, {color: bark, made: m.FURROWS, height: 1000, open: 0.8, cap: true})
  }
  return b
}

// a stump: what is left of a felled tree, its roots spreading
local func stump(){
  local b = builder()
  local kind = plants.KINDS[plants.STUMP]
  local bark = {0.11, 0.09, 0.07}
  tube(b, {
    {x: 0, y: -0.25, z: 0, r: kind.radius * 1.6}, {x: 0, y: 0.08, z: 0, r: kind.radius * 1.22},
    {x: 0, y: 0.3, z: 0, r: kind.radius * 1.02}, {x: 0.02, y: kind.height, z: 0, r: kind.radius * 0.94},
  }, 9, {color: bark, made: m.FURROWS, height: 1000, turns: 3, open: 0.8, cap: true, cap_color: {0.4, 0.3, 0.17}})
  return b
}

// ------------------------------------------------------------ the list

// a shape as buffers of numbers, for the kernel that bakes instances of
// it into the meshes that are drawn (render/flora_bake.kernel)
// type Shape = {pos, nrm, uv, col, tan, idx, vertices: int, indices: int,
//   triangles: int}
local func finish(b){
  if(b.count > 60000){
    raise(error.new(error.kinds.argument, concat("flora: a shape of ", string(b.count), " vertices is too many")))
  }
  return {
    pos: kernel.float:array(b.v),
    nrm: kernel.float:array(b.n),
    uv: kernel.float:array(b.t),
    col: kernel.uint8:array(b.c),
    tan: kernel.float:array(b.g),
    idx: kernel.uint16:array(b.i),
    vertices: b.count,
    indices: len(b.i),
    triangles: to_int(len(b.i) / 3),
  }
}

// what a kind's foliage looks like from far off, as one color: set by
// render/flora from the texture's tiles before the shapes are made
// (tints: each kind's tint and tile, for that)
for(let local e in entries({
  spruce: {0.016, 0.045, 0.014},
  fir: {0.014, 0.04, 0.016},
  sapling: {0.02, 0.05, 0.014},
  pine: {0.022, 0.05, 0.014},
  birch: {0.06, 0.1, 0.02},
  oak: {0.03, 0.06, 0.014},
  bush: {0.05, 0.085, 0.02},
  shrub: {0.018, 0.04, 0.016},
})){
  FAR[e[0]] = e[1]
}
m.FAR = FAR
m.TINTS = {
  spruce: {tint: SPRUCE.needle, tile: m.FROND},
  fir: {tint: FIR.needle, tile: m.FROND},
  sapling: {tint: SAPLING.needle, tile: m.FROND},
  pine: {tint: {0.66, 0.72, 0.48}, tile: m.TUFT},
  birch: {tint: {0.5, 0.56, 0.72}, tile: m.SPRAY},
  oak: {tint: {0.6, 0.68, 0.48}, tile: m.CLUSTER},
  bush: {tint: BUSH.tint, tile: m.SPRAY},
  shrub: {tint: SHRUB.tint, tile: m.TUFT},
}

// shapes(kind: int) -> {near: Shape, small?: Shape, mid?: Shape, far?: Shape}
// The shapes of a kind of game/plants: near, mid and far as the levels
// of detail have them (a level the kind is not seen at is left out);
// small is a rock's shape when it is only a stone.
func m.shapes(kind){
  local name = plants.KINDS[kind].name
  if(name == "spruce"){
    return {near: finish(conifer(SPRUCE, 0)), mid: finish(conifer(SPRUCE, 1)), far: finish(far_conifer(SPRUCE, FAR.spruce))}
  }
  if(name == "fir"){
    return {near: finish(conifer(FIR, 0)), mid: finish(conifer(FIR, 1)), far: finish(far_conifer(FIR, FAR.fir))}
  }
  if(name == "sapling"){
    return {near: finish(conifer(SAPLING, 0)), mid: finish(conifer(SAPLING, 1))}
  }
  if(name == "pine"){
    return {
      near: finish(pine(0)), mid: finish(pine(1)),
      far: finish(far_blob(15, 0.2, {0.2, 0.11, 0.065}, 11.6, 2.5, 3.0, FAR.pine, 3)),
    }
  }
  if(name == "birch"){
    return {
      near: finish(birch(0)), mid: finish(birch(1)),
      far: finish(far_blob(11.5, 0.13, {0.6, 0.58, 0.53}, 7.4, 2.5, 3.6, FAR.birch, 5, m.BIRCH)),
    }
  }
  if(name == "oak"){
    return {
      near: finish(oak(0)), mid: finish(oak(1)),
      far: finish(far_blob(11.5, 0.33, {0.1, 0.085, 0.066}, 7.0, 4.7, 4.0, FAR.oak, 7)),
    }
  }
  if(name == "snag"){
    return {near: finish(snag(0)), mid: finish(snag(1))}
  }
  if(name == "bush"){
    return {near: finish(bush(0, BUSH)), mid: finish(far_blob(1.6, 0.03, {0.12, 0.1, 0.08}, 0.68, 1.0, 0.85, FAR.bush, 9))}
  }
  if(name == "shrub"){
    return {near: finish(bush(0, SHRUB)), mid: finish(far_blob(0.85, 0.03, {0.12, 0.1, 0.08}, 0.33, 1.05, 0.46, FAR.shrub, 11))}
  }
  if(name == "log"){
    local shape = finish(log())
    return {near: shape, mid: shape}
  }
  if(name == "stump"){
    local shape = finish(stump())
    return {near: shape, mid: shape}
  }
  // a rock: the same shape near and at mid distance, so that nothing
  // changes where the two meet
  local index = kind - plants.ROCK
  local whole = finish(rock(index, 0))
  return {near: whole, small: finish(rock(index, 1)), mid: whole, far: finish(rock(index, 2))}
}

return m
