// render/truck_mesh: a kit for building the truck's meshes from code:
// quads, beveled boxes, cylinders, tubes along a line, shapes turned
// around an axle, and prisms (a side view pushed across the truck with
// softened edges, which is what a boxy body is).
//
//   local b = kit.new()
//   b:paint(kit.PAINT)                 // the material of what follows
//   b:box(0, 0.5, 0, 1.8, 0.4, 4.4, 0.03)
//   local mesh = b:mesh()              // a raylib mesh, uploaded
//
// A vertex carries a position, a normal, a color (for the materials that
// have their own), its material and one number for it (texcoord), and a
// place on its part (texcoord2: around and across a tire). The winding of
// every face is set from its normal, so a part can be built mirrored by
// negating x without a thought.
local rl = require("raylib")
local math = require("slang/math")

local m = {}

// ---- materials: what render/truck's shader makes of a vertex
m.PAINT = 0       // the body's lacquer (the setup's color)
m.ROOF = 1        // the roof's lacquer
m.MATTE = 2       // plastic, rubber, canvas: its own color, dull
m.METAL = 3       // steel and aluminium: its own color, a soft shine
m.GLASS = 4       // windows: dark, mirroring the sky
m.LIGHT = 5       // a lamp's lens: its own color, lit by its group (param)
m.TIRE = 6        // a tire: black, its tread from texcoord2
m.CHROME = 7      // mirrors, polished metal

// ---- the lamps' groups (the param of LIGHT)
m.HEAD = 0
m.TAIL = 1        // the red lamps: dim with the lights on, bright on the brake
m.REVERSE = 3
m.BLINK = 4
m.BAR = 5

local Builder = {}
local meta = {__index: Builder, __type: "MeshBuilder"}

// new() -> MeshBuilder
func m.new(){
  return {
    p: {}, n: {}, c: {}, t: {}, t2: {}, i: {},
    count: 0,
    material: m.MATTE, param: 0,
    r: 128, g: 128, b: 128,
    // where what is built goes: turned by a quaternion, then moved
    q: null, ox: 0, oy: 0, oz: 0, stack: {},
    @meta: meta,
  }
}

// paint(material, param?): what the next faces are made of
func Builder.paint(b, material, param){
  b.material = material
  b.param = param or 0
}

// color(r, g, b): the next faces' own color, 0..255 as the screen has it
func Builder.color(b, r, g, bl){
  b.r = to_int(r)
  b.g = to_int(g)
  b.b = to_int(bl)
}

// push(x, y, z, q?): what follows is built around the origin and put at
// a point, turned by a quaternion (inside what was pushed before); pop()
// ends it
func Builder.push(b, x, y, z, q){
  append(b.stack, {q: b.q, x: b.ox, y: b.oy, z: b.oz})
  local cq = b.q
  if(cq != null){
    local tx = 2 * (cq.y * z - cq.z * y)
    local ty = 2 * (cq.z * x - cq.x * z)
    local tz = 2 * (cq.x * y - cq.y * x)
    local rx = x + cq.w * tx + (cq.y * tz - cq.z * ty)
    local ry = y + cq.w * ty + (cq.z * tx - cq.x * tz)
    local rz = z + cq.w * tz + (cq.x * ty - cq.y * tx)
    x = rx
    y = ry
    z = rz
  }
  b.ox = b.ox + x
  b.oy = b.oy + y
  b.oz = b.oz + z
  if(q != null){
    if(cq == null){
      b.q = q
    } else {
      b.q = {
        x: cq.w * q.x + cq.x * q.w + cq.y * q.z - cq.z * q.y,
        y: cq.w * q.y - cq.x * q.z + cq.y * q.w + cq.z * q.x,
        z: cq.w * q.z + cq.x * q.y - cq.y * q.x + cq.z * q.w,
        w: cq.w * q.w - cq.x * q.x - cq.y * q.y - cq.z * q.z,
      }
    }
  }
}

func Builder.pop(b){
  local at = len(b.stack) - 1
  local s = b.stack[at]
  remove(b.stack, at)
  b.q = s.q
  b.ox = s.x
  b.oy = s.y
  b.oz = s.z
}

// one vertex: its position and normal through the placement
local func emit(b, x, y, z, nx, ny, nz, u, v){
  local q = b.q
  if(q != null){
    local tx = 2 * (q.y * z - q.z * y)
    local ty = 2 * (q.z * x - q.x * z)
    local tz = 2 * (q.x * y - q.y * x)
    local rx = x + q.w * tx + (q.y * tz - q.z * ty)
    local ry = y + q.w * ty + (q.z * tx - q.x * tz)
    local rz = z + q.w * tz + (q.x * ty - q.y * tx)
    x = rx
    y = ry
    z = rz
    tx = 2 * (q.y * nz - q.z * ny)
    ty = 2 * (q.z * nx - q.x * nz)
    tz = 2 * (q.x * ny - q.y * nx)
    rx = nx + q.w * tx + (q.y * tz - q.z * ty)
    ry = ny + q.w * ty + (q.z * tx - q.x * tz)
    rz = nz + q.w * tz + (q.x * ty - q.y * tx)
    nx = rx
    ny = ry
    nz = rz
  }
  local p = b.p
  append(p, x + b.ox)
  append(p, y + b.oy)
  append(p, z + b.oz)
  local n = b.n
  append(n, nx)
  append(n, ny)
  append(n, nz)
  local c = b.c
  append(c, b.r)
  append(c, b.g)
  append(c, b.b)
  append(c, 255)
  local t = b.t
  append(t, b.material)
  append(t, b.param)
  local t2 = b.t2
  append(t2, u or 0)
  append(t2, v or 0)
  local at = b.count
  b.count = at + 1
  return at
}

// quad(a, b, c, d, n?): a flat face through four points in order around
// it ({x, y, z} each); n is the way it faces (worked out from a, b, c
// when left out: counter clockwise seen from outside)
func Builder.quad(b, pa, pb, pc, pd, n){
  local ux = pb.x - pa.x
  local uy = pb.y - pa.y
  local uz = pb.z - pa.z
  local vx = pd.x - pa.x
  local vy = pd.y - pa.y
  local vz = pd.z - pa.z
  local cx = uy * vz - uz * vy
  local cy = uz * vx - ux * vz
  local cz = ux * vy - uy * vx
  local flip = false
  if(n == null){
    local l = math.sqrt(cx * cx + cy * cy + cz * cz)
    if(l < 1.0e-12){
      l = 1
    }
    n = {x: cx / l, y: cy / l, z: cz / l}
  } else {
    flip = cx * n.x + cy * n.y + cz * n.z < 0
  }
  local i0 = emit(b, pa.x, pa.y, pa.z, n.x, n.y, n.z)
  local i1 = emit(b, pb.x, pb.y, pb.z, n.x, n.y, n.z)
  local i2 = emit(b, pc.x, pc.y, pc.z, n.x, n.y, n.z)
  local i3 = emit(b, pd.x, pd.y, pd.z, n.x, n.y, n.z)
  local i = b.i
  if(flip){
    append(i, i0)
    append(i, i2)
    append(i, i1)
    append(i, i0)
    append(i, i3)
    append(i, i2)
  } else {
    append(i, i0)
    append(i, i1)
    append(i, i2)
    append(i, i0)
    append(i, i2)
    append(i, i3)
  }
}

// bent(a, b, c, d, na, nb, nc, nd): a face whose corners face their own
// ways: the light runs over it as over a curve (an edge made soft)
func Builder.bent(b, pa, pb, pc, pd, na, nb, nc, nd){
  local ux = pb.x - pa.x
  local uy = pb.y - pa.y
  local uz = pb.z - pa.z
  local vx = pd.x - pa.x
  local vy = pd.y - pa.y
  local vz = pd.z - pa.z
  local cx = uy * vz - uz * vy
  local cy = uz * vx - ux * vz
  local cz = ux * vy - uy * vx
  local sx = na.x + nb.x + nc.x + nd.x
  local sy = na.y + nb.y + nc.y + nd.y
  local sz = na.z + nb.z + nc.z + nd.z
  local flip = cx * sx + cy * sy + cz * sz < 0
  local i0 = emit(b, pa.x, pa.y, pa.z, na.x, na.y, na.z)
  local i1 = emit(b, pb.x, pb.y, pb.z, nb.x, nb.y, nb.z)
  local i2 = emit(b, pc.x, pc.y, pc.z, nc.x, nc.y, nc.z)
  local i3 = emit(b, pd.x, pd.y, pd.z, nd.x, nd.y, nd.z)
  local i = b.i
  if(flip){
    append(i, i0)
    append(i, i2)
    append(i, i1)
    append(i, i0)
    append(i, i3)
    append(i, i2)
  } else {
    append(i, i0)
    append(i, i1)
    append(i, i2)
    append(i, i0)
    append(i, i2)
    append(i, i3)
  }
}

// tri(a, b, c, n?): a flat triangle
func Builder.tri(b, pa, pb, pc, n){
  local ux = pb.x - pa.x
  local uy = pb.y - pa.y
  local uz = pb.z - pa.z
  local vx = pc.x - pa.x
  local vy = pc.y - pa.y
  local vz = pc.z - pa.z
  local cx = uy * vz - uz * vy
  local cy = uz * vx - ux * vz
  local cz = ux * vy - uy * vx
  local flip = false
  if(n == null){
    local l = math.sqrt(cx * cx + cy * cy + cz * cz)
    if(l < 1.0e-12){
      l = 1
    }
    n = {x: cx / l, y: cy / l, z: cz / l}
  } else {
    flip = cx * n.x + cy * n.y + cz * n.z < 0
  }
  local i0 = emit(b, pa.x, pa.y, pa.z, n.x, n.y, n.z)
  local i1 = emit(b, pb.x, pb.y, pb.z, n.x, n.y, n.z)
  local i2 = emit(b, pc.x, pc.y, pc.z, n.x, n.y, n.z)
  local i = b.i
  append(i, i0)
  if(flip){
    append(i, i2)
    append(i, i1)
  } else {
    append(i, i1)
    append(i, i2)
  }
}

local func v3(x, y, z){
  return {x: x, y: y, z: z}
}

// box(cx, cy, cz, sx, sy, sz, bevel?): a box around a center, sx by sy by
// sz, its edges cut by bevel and lit as if rounded
func Builder.box(b, cx, cy, cz, sx, sy, sz, bevel){
  local hx = sx / 2
  local hy = sy / 2
  local hz = sz / 2
  local e = bevel or 0
  if(e > hx * 0.98){ e = hx * 0.98 }
  if(e > hy * 0.98){ e = hy * 0.98 }
  if(e > hz * 0.98){ e = hz * 0.98 }
  // the faces: each one's axis, and the two across it
  local axes = {
    {1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
  }
  local half = {hx, hy, hz}
  for(local f = 0; f < 6; f = f + 1){
    local a = axes[f]
    // which axis this face is on, and the other two
    local k = if(a[0] != 0){ 0 } else if(a[1] != 0){ 1 } else { 2 }
    local s = a[k]
    local k1 = (k + 1) % 3
    local k2 = (k + 2) % 3
    local h0 = half[k]
    local h1 = half[k1] - e
    local h2 = half[k2] - e
    local pts = {}
    for(let local corner in values({{-1, -1}, {1, -1}, {1, 1}, {-1, 1}})){
      local p = {0, 0, 0}
      p[k] = s * h0
      p[k1] = corner[0] * h1
      p[k2] = corner[1] * h2
      append(pts, v3(cx + p[0], cy + p[1], cz + p[2]))
    }
    b:quad(pts[0], pts[1], pts[2], pts[3], v3(a[0], a[1], a[2]))
  }
  if(e <= 0){
    return
  }
  // the edges: a strip between two faces, its two sides facing as they do
  for(local k = 0; k < 3; k = k + 1){
    local k1 = (k + 1) % 3
    local k2 = (k + 2) % 3
    for(let local s1 in values({-1, 1})){
      for(let local s2 in values({-1, 1})){
        local a0 = {0, 0, 0}
        local a1 = {0, 0, 0}
        local b0 = {0, 0, 0}
        local b1 = {0, 0, 0}
        // along k; on the face k1 at its rim, and on the face k2 at its rim
        a0[k] = -(half[k] - e)
        a1[k] = half[k] - e
        a0[k1] = s1 * half[k1]
        a1[k1] = s1 * half[k1]
        a0[k2] = s2 * (half[k2] - e)
        a1[k2] = s2 * (half[k2] - e)
        b0[k] = -(half[k] - e)
        b1[k] = half[k] - e
        b0[k1] = s1 * (half[k1] - e)
        b1[k1] = s1 * (half[k1] - e)
        b0[k2] = s2 * half[k2]
        b1[k2] = s2 * half[k2]
        local n1 = {0, 0, 0}
        n1[k1] = s1
        local n2 = {0, 0, 0}
        n2[k2] = s2
        local na = v3(n1[0], n1[1], n1[2])
        local nb = v3(n2[0], n2[1], n2[2])
        b:bent(
          v3(cx + a0[0], cy + a0[1], cz + a0[2]), v3(cx + a1[0], cy + a1[1], cz + a1[2]),
          v3(cx + b1[0], cy + b1[1], cz + b1[2]), v3(cx + b0[0], cy + b0[1], cz + b0[2]),
          na, na, nb, nb
        )
      }
    }
  }
  // the corners
  local r = 0.57735
  for(let local s0 in values({-1, 1})){
    for(let local s1 in values({-1, 1})){
      for(let local s2 in values({-1, 1})){
        b:tri(
          v3(cx + s0 * hx, cy + s1 * (hy - e), cz + s2 * (hz - e)),
          v3(cx + s0 * (hx - e), cy + s1 * hy, cz + s2 * (hz - e)),
          v3(cx + s0 * (hx - e), cy + s1 * (hy - e), cz + s2 * hz),
          v3(s0 * r, s1 * r, s2 * r)
        )
      }
    }
  }
}

// two unit vectors across a direction
local func across(dx, dy, dz){
  local ax = 0
  local ay = 1
  local az = 0
  if(math.abs(dy) > 0.9){
    ax = 1
    ay = 0
  }
  // u = a x d, v = d x u
  local ux = ay * dz - az * dy
  local uy = az * dx - ax * dz
  local uz = ax * dy - ay * dx
  local l = math.sqrt(ux * ux + uy * uy + uz * uz)
  ux = ux / l
  uy = uy / l
  uz = uz / l
  return {
    ux: ux, uy: uy, uz: uz,
    vx: dy * uz - dz * uy, vy: dz * ux - dx * uz, vz: dx * uy - dy * ux,
  }
}

// rod(a, b, radius, sides?, radius_b?, cap_a?, cap_b?): a round bar from a
// to b (a cone when the radii differ), with flat ends where asked
func Builder.rod(b, pa, pb, radius, sides, radius_b, cap_a, cap_b){
  sides = sides or 8
  local rb = radius_b or radius
  local dx = pb.x - pa.x
  local dy = pb.y - pa.y
  local dz = pb.z - pa.z
  local l = math.sqrt(dx * dx + dy * dy + dz * dz)
  if(l < 1.0e-9){
    return
  }
  dx = dx / l
  dy = dy / l
  dz = dz / l
  local f = across(dx, dy, dz)
  local ring_a = {}
  local ring_b = {}
  local normals = {}
  // (a cone's side leans)
  local lean = (radius - rb) / l
  for(local k = 0; k <= sides; k = k + 1){
    local a = k / sides * 2 * math.pi
    local c = math.cos(a)
    local s = math.sin(a)
    local ox = f.ux * c + f.vx * s
    local oy = f.uy * c + f.vy * s
    local oz = f.uz * c + f.vz * s
    append(ring_a, v3(pa.x + ox * radius, pa.y + oy * radius, pa.z + oz * radius))
    append(ring_b, v3(pb.x + ox * rb, pb.y + oy * rb, pb.z + oz * rb))
    local nx = ox + dx * lean
    local ny = oy + dy * lean
    local nz = oz + dz * lean
    local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
    append(normals, v3(nx / nl, ny / nl, nz / nl))
  }
  for(local k = 0; k < sides; k = k + 1){
    b:bent(ring_a[k], ring_a[k + 1], ring_b[k + 1], ring_b[k], normals[k], normals[k + 1], normals[k + 1], normals[k])
  }
  if(cap_a){
    local n = v3(-dx, -dy, -dz)
    for(local k = 1; k + 1 < sides; k = k + 1){
      b:tri(ring_a[0], ring_a[k], ring_a[k + 1], n)
    }
  }
  if(cap_b){
    local n = v3(dx, dy, dz)
    for(local k = 1; k + 1 < sides; k = k + 1){
      b:tri(ring_b[0], ring_b[k], ring_b[k + 1], n)
    }
  }
}

// tube(points, radius, sides?): a round bar bent through points (each
// {x, y, z}); closed ends
func Builder.tube(b, points, radius, sides){
  sides = sides or 6
  local count = len(points)
  local rings = {}
  local normals = {}
  local f = null
  for(local i = 0; i < count; i = i + 1){
    // the bar's direction at a point: between its two neighbors
    local from = points[math.max(0, i - 1)]
    local to = points[math.min(count - 1, i + 1)]
    local dx = to.x - from.x
    local dy = to.y - from.y
    local dz = to.z - from.z
    local l = math.sqrt(dx * dx + dy * dy + dz * dz)
    dx = dx / l
    dy = dy / l
    dz = dz / l
    if(f == null){
      f = across(dx, dy, dz)
    } else {
      // carry the frame along: u stays across the new direction
      local d = f.ux * dx + f.uy * dy + f.uz * dz
      local ux = f.ux - dx * d
      local uy = f.uy - dy * d
      local uz = f.uz - dz * d
      local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
      ux = ux / ul
      uy = uy / ul
      uz = uz / ul
      f = {
        ux: ux, uy: uy, uz: uz,
        vx: dy * uz - dz * uy, vy: dz * ux - dx * uz, vz: dx * uy - dy * ux,
      }
    }
    local ring = {}
    local ns = {}
    for(local k = 0; k <= sides; k = k + 1){
      local a = k / sides * 2 * math.pi
      local c = math.cos(a)
      local s = math.sin(a)
      local ox = f.ux * c + f.vx * s
      local oy = f.uy * c + f.vy * s
      local oz = f.uz * c + f.vz * s
      append(ring, v3(points[i].x + ox * radius, points[i].y + oy * radius, points[i].z + oz * radius))
      append(ns, v3(ox, oy, oz))
    }
    append(rings, ring)
    append(normals, ns)
  }
  for(local i = 0; i + 1 < count; i = i + 1){
    local ra = rings[i]
    local rb = rings[i + 1]
    local na = normals[i]
    local nb = normals[i + 1]
    for(local k = 0; k < sides; k = k + 1){
      b:bent(ra[k], ra[k + 1], rb[k + 1], rb[k], na[k], na[k + 1], nb[k + 1], nb[k])
    }
  }
  for(let local end in values({0, count - 1})){
    local ring = rings[end]
    local other = points[if(end == 0){ 1 } else { count - 2 }]
    local n = v3(points[end].x - other.x, points[end].y - other.y, points[end].z - other.z)
    local l = math.sqrt(n.x * n.x + n.y * n.y + n.z * n.z)
    n = v3(n.x / l, n.y / l, n.z / l)
    for(local k = 1; k + 1 < sides; k = k + 1){
      b:tri(ring[0], ring[k], ring[k + 1], n)
    }
  }
}

// disc(center, normal, radius, sides?, inner?): a round flat face (a ring
// with a hole of radius inner)
func Builder.disc(b, center, normal, radius, sides, inner){
  sides = sides or 16
  local f = across(normal.x, normal.y, normal.z)
  local outer = {}
  local hole = {}
  for(local k = 0; k <= sides; k = k + 1){
    local a = k / sides * 2 * math.pi
    local c = math.cos(a)
    local s = math.sin(a)
    local ox = f.ux * c + f.vx * s
    local oy = f.uy * c + f.vy * s
    local oz = f.uz * c + f.vz * s
    append(outer, v3(center.x + ox * radius, center.y + oy * radius, center.z + oz * radius))
    if(inner != null){
      append(hole, v3(center.x + ox * inner, center.y + oy * inner, center.z + oz * inner))
    }
  }
  for(local k = 0; k < sides; k = k + 1){
    if(inner != null){
      b:quad(hole[k], outer[k], outer[k + 1], hole[k + 1], normal)
    } else {
      b:tri(center, outer[k], outer[k + 1], normal)
    }
  }
}

// turned(profile, segments, uv?): a shape turned around the x axis: the
// profile is a list of {a, r} (along the axle, away from it), or {a, r,
// hard: true} where the surface creases. The surface faces to the left
// of the way the profile runs in (a, r): away from the axle where it
// runs toward +x, toward -x where it climbs. With uv the vertices get
// their place around (0..1) and along the profile (a point's v).
func Builder.turned(b, profile, segments, uv){
  local count = len(profile)
  // each stretch of the profile has its own normal; a point between two
  // stretches takes their mean unless it is hard
  local seg_n = {}
  for(local i = 0; i + 1 < count; i = i + 1){
    local da = profile[i + 1].a - profile[i].a
    local dr = profile[i + 1].r - profile[i].r
    local l = math.sqrt(da * da + dr * dr)
    if(l < 1.0e-9){
      l = 1
    }
    // to the left of the direction of travel in (a, r)
    append(seg_n, {a: -dr / l, r: da / l})
  }
  for(local i = 0; i + 1 < count; i = i + 1){
    local p0 = profile[i]
    local p1 = profile[i + 1]
    local n0 = seg_n[i]
    local n1 = seg_n[i]
    if(i > 0 and not p0.hard){
      local o = seg_n[i - 1]
      local l = math.sqrt((o.a + n0.a) * (o.a + n0.a) + (o.r + n0.r) * (o.r + n0.r))
      if(l > 1.0e-6){
        n0 = {a: (o.a + n0.a) / l, r: (o.r + n0.r) / l}
      }
    }
    if(i + 2 < count and not p1.hard){
      local o = seg_n[i + 1]
      local l = math.sqrt((o.a + n1.a) * (o.a + n1.a) + (o.r + n1.r) * (o.r + n1.r))
      if(l > 1.0e-6){
        n1 = {a: (o.a + n1.a) / l, r: (o.r + n1.r) / l}
      }
    }
    local i_prev0 = -1
    local i_prev1 = -1
    for(local k = 0; k <= segments; k = k + 1){
      local ang = k / segments * 2 * math.pi
      local c = math.cos(ang)
      local s = math.sin(ang)
      local u = k / segments
      local j0 = emit(b, p0.a, p0.r * c, p0.r * s, n0.a, n0.r * c, n0.r * s, u, if(uv){ p0.v or 0 } else { 0 })
      local j1 = emit(b, p1.a, p1.r * c, p1.r * s, n1.a, n1.r * c, n1.r * s, u, if(uv){ p1.v or 0 } else { 0 })
      if(k > 0){
        local idx = b.i
        append(idx, i_prev0)
        append(idx, j0)
        append(idx, j1)
        append(idx, i_prev0)
        append(idx, j1)
        append(idx, i_prev1)
      }
      i_prev0 = j0
      i_prev1 = j1
    }
  }
}

// ear clipping: the triangles of a simple polygon given as {u, v} points
// (counter clockwise), as index triples
local func triangulate(points){
  local n = len(points)
  local order = {}
  for(local i = 0; i < n; i = i + 1){
    append(order, i)
  }
  local out = {}
  local guard = 0
  for(len(order) > 3 and guard < 10000){
    guard = guard + 1
    local count = len(order)
    local clipped = false
    for(local k = 0; k < count; k = k + 1){
      local ia = order[(k + count - 1) % count]
      local ib = order[k]
      local ic = order[(k + 1) % count]
      local a = points[ia]
      local bp = points[ib]
      local c = points[ic]
      local cross = (bp.u - a.u) * (c.v - a.v) - (bp.v - a.v) * (c.u - a.u)
      if(cross > 1.0e-12){
        // an ear if no other point is inside it
        local inside = false
        for(local j = 0; j < count; j = j + 1){
          local ip = order[j]
          if(ip != ia and ip != ib and ip != ic){
            local p = points[ip]
            local d1 = (bp.u - a.u) * (p.v - a.v) - (bp.v - a.v) * (p.u - a.u)
            local d2 = (c.u - bp.u) * (p.v - bp.v) - (c.v - bp.v) * (p.u - bp.u)
            local d3 = (a.u - c.u) * (p.v - c.v) - (a.v - c.v) * (p.u - c.u)
            if(d1 >= -1.0e-9 and d2 >= -1.0e-9 and d3 >= -1.0e-9){
              inside = true
              break
            }
          }
        }
        if(not inside){
          append(out, {ia, ib, ic})
          remove(order, k)
          clipped = true
          break
        }
      }
    }
    if(not clipped){
      // a degenerate corner: drop it
      remove(order, 0)
    }
  }
  if(len(order) == 3){
    append(out, {order[0], order[1], order[2]})
  }
  return out
}

// prism(outline, width, options?): a side view pushed across the truck.
// outline: the side view's points in order, each {z, y} with the
// material of the stretch that starts at it ({z, y, material, param?,
// color?}); width(y) is the half width at a height; options.bevel softens
// the edge between the sides and the rest, options.side is the sides'
// material ({material, param, color}), options.lean how the sides face
// up (the slope of width over y, for the normal).
func Builder.prism(b, outline, width, options){
  options = options or {}
  local e = options.bevel or 0.03
  local count = len(outline)
  // counter clockwise in (z, y), so that normals point out
  local area = 0
  for(local i = 0; i < count; i = i + 1){
    local p = outline[i]
    local q = outline[(i + 1) % count]
    area = area + p.z * q.y - q.z * p.y
  }
  local pts = outline
  if(area < 0){
    // turned over: every stretch keeps its material (it starts at what
    // was its end)
    pts = {}
    for(local i = 0; i < count; i = i + 1){
      local p = outline[count - 1 - i]
      local owner = outline[(count - 2 - i + count) % count]
      append(pts, {z: p.z, y: p.y, material: owner.material, param: owner.param, color: owner.color})
    }
  }
  // each stretch's normal, and each point's (for the inset)
  local seg = {}
  for(local i = 0; i < count; i = i + 1){
    local p = pts[i]
    local q = pts[(i + 1) % count]
    local dz = q.z - p.z
    local dy = q.y - p.y
    local l = math.sqrt(dz * dz + dy * dy)
    append(seg, {z: dy / l, y: -dz / l})
  }
  local inset = {}
  for(local i = 0; i < count; i = i + 1){
    local a = seg[(i + count - 1) % count]
    local c = seg[i]
    local d = 1 + a.z * c.z + a.y * c.y
    if(d < 0.25){
      d = 0.25
    }
    local p = pts[i]
    append(inset, {z: p.z - e * (a.z + c.z) / d, y: p.y - e * (a.y + c.y) / d})
  }
  local lean = options.lean or 0
  local ll = math.sqrt(1 + lean * lean)
  for(let local side in values({1, -1})){
    local side_n = v3(side / ll, -lean / ll, 0)
    // the skin and the soft edge, stretch by stretch
    for(local i = 0; i < count; i = i + 1){
      local j = (i + 1) % count
      local p = pts[i]
      local q = pts[j]
      if(p.material != null){
        b:paint(p.material, p.param)
        if(p.color != null){
          b:color(p.color[0], p.color[1], p.color[2])
        }
        local n = v3(0, seg[i].y, seg[i].z)
        local wp = width(p.y) - e
        local wq = width(q.y) - e
        if(side == 1){
          // the skin, once, from side to side
          b:quad(v3(-wp, p.y, p.z), v3(wp, p.y, p.z), v3(wq, q.y, q.z), v3(-wq, q.y, q.z), n)
        }
        b:bent(
          v3(side * wp, p.y, p.z), v3(side * wq, q.y, q.z),
          v3(side * width(inset[j].y), inset[j].y, inset[j].z), v3(side * width(inset[i].y), inset[i].y, inset[i].z),
          n, n, side_n, side_n
        )
      }
    }
    // the side itself
    local sm = options.side
    if(sm != null){
      b:paint(sm.material, sm.param)
      if(sm.color != null){
        b:color(sm.color[0], sm.color[1], sm.color[2])
      }
      local flat = {}
      for(local i = 0; i < count; i = i + 1){
        append(flat, {u: inset[i].z, v: inset[i].y})
      }
      for(let local t in values(triangulate(flat))){
        local pa = inset[t[0]]
        local pb = inset[t[1]]
        local pc = inset[t[2]]
        b:tri(
          v3(side * width(pa.y), pa.y, pa.z), v3(side * width(pb.y), pb.y, pb.z),
          v3(side * width(pc.y), pc.y, pc.z), side_n
        )
      }
    }
  }
}

// mesh() -> Mesh: what was built, uploaded (unload it when done)
func Builder.mesh(b){
  return rl.mesh({
    vertices: b.p, normals: b.n, colors: b.c, texcoords: b.t, texcoords2: b.t2, indices: b.i,
  })
}

m.v3 = v3

return m
