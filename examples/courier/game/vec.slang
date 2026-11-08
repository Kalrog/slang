// game/vec: 3D vectors, quaternions and raylib matrices in slang (the hot
// paths of the car and the traffic stay out of the FFI), a seeded random
// generator so a city seed makes the same city, and value noise.
local math = require("slang/math")

local m = {}

func m.v3(x, y, z){
  return {x: x, y: y, z: z}
}

func m.add(a, b){
  return {x: a.x + b.x, y: a.y + b.y, z: a.z + b.z}
}

func m.sub(a, b){
  return {x: a.x - b.x, y: a.y - b.y, z: a.z - b.z}
}

func m.scale(a, s){
  return {x: a.x * s, y: a.y * s, z: a.z * s}
}

// a + b * s
func m.add_scaled(a, b, s){
  return {x: a.x + b.x * s, y: a.y + b.y * s, z: a.z + b.z * s}
}

func m.dot(a, b){
  return a.x * b.x + a.y * b.y + a.z * b.z
}

func m.cross(a, b){
  return {
    x: a.y * b.z - a.z * b.y,
    y: a.z * b.x - a.x * b.z,
    z: a.x * b.y - a.y * b.x,
  }
}

func m.length(a){
  return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
}

func m.distance(a, b){
  local dx = a.x - b.x
  local dy = a.y - b.y
  local dz = a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
}

func m.normalize(a){
  local l = m.length(a)
  if(l < 0.000001){
    return {x: 0, y: 0, z: 0}
  }
  return {x: a.x / l, y: a.y / l, z: a.z / l}
}

func m.lerp(a, b, t){
  return {
    x: a.x + (b.x - a.x) * t,
    y: a.y + (b.y - a.y) * t,
    z: a.z + (b.z - a.z) * t,
  }
}

func m.mix(a, b, t){
  return a + (b - a) * t
}

func m.clamp(v, lo, hi){
  if(v < lo){
    return lo
  }
  if(v > hi){
    return hi
  }
  return v
}

// a value eased toward a target: the fraction left after dt at rate k
func m.approach(value, target, k, dt){
  return target + (value - target) * math.exp(-k * dt)
}

// the part of a perpendicular to n (unit)
func m.reject(a, n){
  return m.add_scaled(a, n, -m.dot(a, n))
}

// ------------------------------------------------------------ quaternions

local quat_id = {x: 0, y: 0, z: 0, w: 1}

func m.quat_identity(){
  return {x: 0, y: 0, z: 0, w: 1}
}

// a quaternion turning angle radians about an axis (unit)
func m.quat_axis(axis, angle){
  local s = math.sin(angle / 2)
  return {x: axis.x * s, y: axis.y * s, z: axis.z * s, w: math.cos(angle / 2)}
}

func m.quat_yaw(yaw){
  return {x: 0, y: math.sin(yaw / 2), z: 0, w: math.cos(yaw / 2)}
}

func m.quat_multiply(a, b){
  return {
    x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
  }
}

func m.quat_normalize(q){
  local l = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
  if(l < 0.000001){
    return {x: 0, y: 0, z: 0, w: 1}
  }
  return {x: q.x / l, y: q.y / l, z: q.z / l, w: q.w / l}
}

func m.quat_conjugate(q){
  return {x: -q.x, y: -q.y, z: -q.z, w: q.w}
}

// a vector turned by a quaternion
func m.rotate(q, v){
  local tx = 2 * (q.y * v.z - q.z * v.y)
  local ty = 2 * (q.z * v.x - q.x * v.z)
  local tz = 2 * (q.x * v.y - q.y * v.x)
  return {
    x: v.x + q.w * tx + (q.y * tz - q.z * ty),
    y: v.y + q.w * ty + (q.z * tx - q.x * tz),
    z: v.z + q.w * tz + (q.x * ty - q.y * tx),
  }
}

// a vector turned back by a quaternion (into its frame)
func m.unrotate(q, v){
  return m.rotate(m.quat_conjugate(q), v)
}

// the quaternion after turning by body rates (rad/s about the body's own
// x, y, z) for dt
func m.quat_integrate(q, rates, dt){
  local hx = rates.x * dt / 2
  local hy = rates.y * dt / 2
  local hz = rates.z * dt / 2
  local d = {x: hx, y: hy, z: hz, w: 1}
  return m.quat_normalize(m.quat_multiply(q, d))
}

// the quaternion whose z axis is forward and y axis up (both unit, up
// made perpendicular to forward)
func m.quat_look(forward, up){
  local f = m.normalize(forward)
  local r = m.normalize(m.cross(up, f))
  if(m.length(r) < 0.0001){
    r = {x: 1, y: 0, z: 0}
  }
  local u = m.cross(f, r)
  // from the rotation matrix with columns r, u, f
  local m00 = r.x
  local m01 = u.x
  local m02 = f.x
  local m10 = r.y
  local m11 = u.y
  local m12 = f.y
  local m20 = r.z
  local m21 = u.z
  local m22 = f.z
  local trace = m00 + m11 + m22
  local q = null
  if(trace > 0){
    local s = math.sqrt(trace + 1) * 2
    q = {w: 0.25 * s, x: (m21 - m12) / s, y: (m02 - m20) / s, z: (m10 - m01) / s}
  } else if(m00 > m11 and m00 > m22){
    local s = math.sqrt(1 + m00 - m11 - m22) * 2
    q = {w: (m21 - m12) / s, x: 0.25 * s, y: (m01 + m10) / s, z: (m02 + m20) / s}
  } else if(m11 > m22){
    local s = math.sqrt(1 + m11 - m00 - m22) * 2
    q = {w: (m02 - m20) / s, x: (m01 + m10) / s, y: 0.25 * s, z: (m12 + m21) / s}
  } else {
    local s = math.sqrt(1 + m22 - m00 - m11) * 2
    q = {w: (m10 - m01) / s, x: (m02 + m20) / s, y: (m12 + m21) / s, z: 0.25 * s}
  }
  return m.quat_normalize(q)
}

// spherical interpolation (the short way round)
func m.quat_slerp(a, b, t){
  local d = a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
  if(d < 0){
    b = {x: -b.x, y: -b.y, z: -b.z, w: -b.w}
    d = -d
  }
  if(d > 0.9995){
    return m.quat_normalize({
      x: a.x + (b.x - a.x) * t,
      y: a.y + (b.y - a.y) * t,
      z: a.z + (b.z - a.z) * t,
      w: a.w + (b.w - a.w) * t,
    })
  }
  local theta0 = math.acos(d)
  local theta = theta0 * t
  local s0 = math.cos(theta) - d * math.sin(theta) / math.sin(theta0)
  local s1 = math.sin(theta) / math.sin(theta0)
  return {
    x: a.x * s0 + b.x * s1,
    y: a.y * s0 + b.y * s1,
    z: a.z * s0 + b.z * s1,
    w: a.w * s0 + b.w * s1,
  }
}

// the body axes of an orientation: x, up (y), forward (z). In raylib's
// right-handed frame, looking along +z with y up, x points to the left;
// the name "right" is kept for the axis, not the side
func m.axes(q){
  return {
    right: m.rotate(q, {x: 1, y: 0, z: 0}),
    up: m.rotate(q, {x: 0, y: 1, z: 0}),
    forward: m.rotate(q, {x: 0, y: 0, z: 1}),
  }
}

// the yaw (about y) of a direction: 0 along +z, turning toward +x
func m.yaw_of(d){
  return math.atan2(d.x, d.z)
}

// ------------------------------------------------------------ matrices

// raylib's Matrix (sixteen fields, column major) for a position, a
// quaternion and a scale: what a model's transform takes
func m.matrix(p, q, s){
  local xx = q.x * q.x
  local yy = q.y * q.y
  local zz = q.z * q.z
  local xy = q.x * q.y
  local xz = q.x * q.z
  local yz = q.y * q.z
  local wx = q.w * q.x
  local wy = q.w * q.y
  local wz = q.w * q.z
  return {
    m0: (1 - 2 * (yy + zz)) * s.x,
    m1: 2 * (xy + wz) * s.x,
    m2: 2 * (xz - wy) * s.x,
    m3: 0,
    m4: 2 * (xy - wz) * s.y,
    m5: (1 - 2 * (xx + zz)) * s.y,
    m6: 2 * (yz + wx) * s.y,
    m7: 0,
    m8: 2 * (xz + wy) * s.z,
    m9: 2 * (yz - wx) * s.z,
    m10: (1 - 2 * (xx + yy)) * s.z,
    m11: 0,
    m12: p.x,
    m13: p.y,
    m14: p.z,
    m15: 1,
  }
}

m.identity_matrix = m.matrix({x: 0, y: 0, z: 0}, quat_id, {x: 1, y: 1, z: 1})

// ------------------------------------------------------------ random

// A deterministic random generator: next() in [0, 1)
local rng_meta = {}
rng_meta.__index = {
  next: func(r){
    r.state = (r.state * 1103515245 + 12345) & 2147483647
    return (r.state >> 8) / 8388608
  },
  // a float in [lo, hi)
  range: func(r, lo, hi){
    return lo + r:next() * (hi - lo)
  },
  // an int in [0, n)
  int: func(r, n){
    return to_int(r:next() * n) % n
  },
  // true with probability p
  chance: func(r, p){
    return r:next() < p
  },
  pick: func(r, list){
    return list[r:int(len(list))]
  },
}

func m.random(seed){
  return {state: (seed or 1) & 2147483647, @meta: rng_meta}
}

// value noise in [-1, 1] over x, z from a hashed grid
local func hash2(x, z, seed){
  local n = (x * 374761393 + z * 668265263 + seed * 1442695041) & 2147483647
  n = ((n ~ (n >> 13)) * 1274126177) & 2147483647
  return ((n ~ (n >> 16)) & 65535) / 32768 - 1
}

local func smooth(t){
  return t * t * (3 - 2 * t)
}

func m.noise(x, z, seed){
  local x0 = math.floor(x)
  local z0 = math.floor(z)
  local tx = smooth(x - x0)
  local tz = smooth(z - z0)
  local ix = to_int(x0)
  local iz = to_int(z0)
  local a = hash2(ix, iz, seed)
  local b = hash2(ix + 1, iz, seed)
  local c = hash2(ix, iz + 1, seed)
  local d = hash2(ix + 1, iz + 1, seed)
  return m.mix(m.mix(a, b, tx), m.mix(c, d, tx), tz)
}

return m
