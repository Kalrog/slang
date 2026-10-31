// game/vec: small 3D vector and quaternion helpers in slang (the hot
// paths avoid raymath's FFI calls), and a seeded random generator for
// levels that look the same every time.
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

// the direction of a yaw (radians, 0 along +z, turning toward +x) and pitch
func m.direction(yaw, pitch){
  local c = math.cos(pitch)
  return {x: math.sin(yaw) * c, y: math.sin(pitch), z: math.cos(yaw) * c}
}

// the yaw of a direction
func m.yaw_of(d){
  return math.atan2(d.x, d.z)
}

// a quaternion {x, y, z, w} turning yaw radians about y
func m.quat_yaw(yaw){
  return {x: 0, y: math.sin(yaw / 2), z: 0, w: math.cos(yaw / 2)}
}

// a quaternion turning angle radians about an axis (unit)
func m.quat_axis(axis, angle){
  local s = math.sin(angle / 2)
  return {x: axis.x * s, y: axis.y * s, z: axis.z * s, w: math.cos(angle / 2)}
}

func m.quat_multiply(a, b){
  return {
    x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
    y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
    z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
    w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
  }
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

// the yaw a quaternion turns about y (its heading)
func m.quat_to_yaw(q){
  local f = m.rotate(q, {x: 0, y: 0, z: 1})
  return math.atan2(f.x, f.z)
}

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

// a Jolt matrix (four columns) scaled, as raylib's Matrix
func m.jolt_matrix(jm, s){
  local c = jm.column
  return {
    m0: c[0].x * s.x,
    m1: c[0].y * s.x,
    m2: c[0].z * s.x,
    m3: 0,
    m4: c[1].x * s.y,
    m5: c[1].y * s.y,
    m6: c[1].z * s.y,
    m7: 0,
    m8: c[2].x * s.z,
    m9: c[2].y * s.z,
    m10: c[2].z * s.z,
    m11: 0,
    m12: c[3].x,
    m13: c[3].y,
    m14: c[3].z,
    m15: 1,
  }
}

// a point of a matrix: m * {x, y, z, 1}
func m.transform(mt, v){
  return {
    x: mt.m0 * v.x + mt.m4 * v.y + mt.m8 * v.z + mt.m12,
    y: mt.m1 * v.x + mt.m5 * v.y + mt.m9 * v.z + mt.m13,
    z: mt.m2 * v.x + mt.m6 * v.y + mt.m10 * v.z + mt.m14,
  }
}

// a direction of a matrix (no translation)
func m.transform_direction(mt, v){
  return {
    x: mt.m0 * v.x + mt.m4 * v.y + mt.m8 * v.z,
    y: mt.m1 * v.x + mt.m5 * v.y + mt.m9 * v.z,
    z: mt.m2 * v.x + mt.m6 * v.y + mt.m10 * v.z,
  }
}

func m.matrix_multiply(a, b){
  // a * b: b applied first (raylib's convention for MatrixMultiply(b, a))
  local r = {}
  local names = {
    "m0", "m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8", "m9", "m10", "m11",
    "m12", "m13", "m14", "m15",
  }
  for(local col = 0; col < 4; col = col + 1){
    for(local row = 0; row < 4; row = row + 1){
      local sum = 0
      for(local k = 0; k < 4; k = k + 1){
        sum = sum + a[names[k * 4 + row]] * b[names[col * 4 + k]]
      }
      r[names[col * 4 + row]] = sum
    }
  }
  return r
}

// ------------------------------------------------------------ random

// A deterministic random generator: {seed: int}; next() in [0, 1)
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
  pick: func(r, list){
    return list[r:int(len(list))]
  },
}

func m.random(seed){
  return {state: (seed or 1) & 2147483647, meta: rng_meta}
}

// smooth value noise in [−1, 1] over x, z: a few octaves of a hashed grid
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

// layered noise: octaves of halving size and amplitude
func m.fbm(x, z, seed, octaves){
  local sum = 0
  local amp = 1
  local total = 0
  local f = 1
  for(local i = 0; i < (octaves or 4); i = i + 1){
    sum = sum + m.noise(x * f, z * f, seed + i * 7) * amp
    total = total + amp
    amp = amp * 0.5
    f = f * 2
  }
  return sum / total
}

return m
