// game/terrain: the ground, a height map of n x n samples spacing meters
// apart, centered on the origin. It becomes a raylib mesh with vertex
// colors (sand by the water, grass, rock where it is steep, snow up high)
// and a Jolt height field; below the water level there is water. The
// generators here are what levels and the editor sculpt with.
local rl = require("raylib")
local buffer = require("slang/buffer")
local math = require("slang/math")
local jolt = require("jolt")
local vec = require("game/vec")

local m = {}

// new(n: int, spacing: float, water: float) -> Terrain
// A flat terrain of n x n samples (n a multiple of 2) at height 0.
func m.new(n, spacing, water){
  local heights = {}
  for(local i = 0; i < n * n; i = i + 1){
    append(heights, 0)
  }
  return {
    n: n,
    spacing: spacing,
    water: water or -1,
    heights: heights,
    half: (n - 1) * spacing / 2,
    model: null,
    shape: null,
    version: 0,
  }
}

// the world x (or z) of a sample index
func m.world(t, i){
  return i * t.spacing - t.half
}

func m.get(t, ix, iz){
  return t.heights[iz * t.n + ix]
}

func m.set(t, ix, iz, h){
  t.heights[iz * t.n + ix] = h
}

// height_at(t, x, z) -> float: the height of the ground at a world point
// (bilinear between the samples; the edge's height beyond it)
func m.height_at(t, x, z){
  local n = t.n
  local fx = vec.clamp((x + t.half) / t.spacing, 0, n - 1.001)
  local fz = vec.clamp((z + t.half) / t.spacing, 0, n - 1.001)
  local ix = to_int(fx)
  local iz = to_int(fz)
  local tx = fx - ix
  local tz = fz - iz
  local h = t.heights
  local a = h[iz * n + ix]
  local b = h[iz * n + ix + 1]
  local c = h[(iz + 1) * n + ix]
  local d = h[(iz + 1) * n + ix + 1]
  // the two triangles Jolt and the mesh use: (a, c, b) and (b, c, d)
  if(tx + tz <= 1){
    return a + (b - a) * tx + (c - a) * tz
  }
  return d + (c - d) * (1 - tx) + (b - d) * (1 - tz)
}

// normal_at(t, x, z) -> Vec3 of the ground at a world point
func m.normal_at(t, x, z){
  local e = t.spacing * 0.5
  local dx = m.height_at(t, x + e, z) - m.height_at(t, x - e, z)
  local dz = m.height_at(t, x, z + e) - m.height_at(t, x, z - e)
  return vec.normalize({x: -dx, y: 2 * e, z: -dz})
}

// inside(t, x, z) -> whether a point is over the terrain
func m.inside(t, x, z){
  return x > -t.half and x < t.half and z > -t.half and z < t.half
}

// ------------------------------------------------------------ sculpting

// fill(t, f: func(x, z) -> height): every sample from a function of the
// world position
func m.fill(t, f){
  for(local iz = 0; iz < t.n; iz = iz + 1){
    for(local ix = 0; ix < t.n; ix = ix + 1){
      t.heights[iz * t.n + ix] = f(m.world(t, ix), m.world(t, iz))
    }
  }
  t.version = t.version + 1
}

// the samples within radius of a world point, with a weight of 1 up to
// flat * radius from the center, falling smoothly to 0 at the edge:
// f(ix, iz, weight)
local func brush(t, cx, cz, radius, flat, f){
  local n = t.n
  local s = t.spacing
  local x0 = math.max(0, to_int((cx - radius + t.half) / s))
  local x1 = math.min(n - 1, to_int((cx + radius + t.half) / s) + 1)
  local z0 = math.max(0, to_int((cz - radius + t.half) / s))
  local z1 = math.min(n - 1, to_int((cz + radius + t.half) / s) + 1)
  for(local iz = z0; iz <= z1; iz = iz + 1){
    local dz = m.world(t, iz) - cz
    for(local ix = x0; ix <= x1; ix = ix + 1){
      local dx = m.world(t, ix) - cx
      local d = math.sqrt(dx * dx + dz * dz) / radius
      if(d < 1){
        local k = vec.clamp((d - flat) / (1 - flat), 0, 1)
        local w = 1 - k * k * (3 - 2 * k)
        f(ix, iz, w)
      }
    }
  }
  t.version = t.version + 1
}

// raise(t, cx, cz, radius, amount): a smooth hill (or a dip, when amount
// is negative)
func m.raise(t, cx, cz, radius, amount){
  brush(t, cx, cz, radius, 0, func(ix, iz, w){
    local i = iz * t.n + ix
    t.heights[i] = t.heights[i] + amount * w
  })
}

// flatten(t, cx, cz, radius, height?, strength?): the ground within
// radius pulled to a height (the center's height when left out): flat
// over most of it, blending into the land around at the rim
// [protect]: a function of a world point that is true where the ground
// must stay as it is (under another building)
func m.flatten(t, cx, cz, radius, height, strength, protect){
  if(height == null){
    height = m.height_at(t, cx, cz)
  }
  strength = strength or 1
  brush(t, cx, cz, radius, 0.72, func(ix, iz, w){
    if(protect != null and protect(m.world(t, ix), m.world(t, iz))){
      return
    }
    local i = iz * t.n + ix
    t.heights[i] = t.heights[i] + (height - t.heights[i]) * w * strength
  })
}

// smooth(t, cx, cz, radius, strength): the samples toward their
// neighbours' average
func m.smooth(t, cx, cz, radius, strength){
  local n = t.n
  local old = {...t.heights}
  brush(t, cx, cz, radius, 0.3, func(ix, iz, w){
    local sum = 0
    local count = 0
    for(local dz = -1; dz <= 1; dz = dz + 1){
      for(local dx = -1; dx <= 1; dx = dx + 1){
        local jx = ix + dx
        local jz = iz + dz
        if(jx >= 0 and jx < n and jz >= 0 and jz < n){
          sum = sum + old[jz * n + jx]
          count = count + 1
        }
      }
    }
    local i = iz * n + ix
    t.heights[i] = t.heights[i] + (sum / count - t.heights[i]) * w * strength
  })
}

// ------------------------------------------------------------ the mesh

local func raylib_buffer(type, n, bytes_each){
  return buffer.wrap(rl.mem_alloc(n * bytes_each), n, type)
}

// the color of the ground at a sample: by height over the water and by
// slope, with a little noise so it is not flat
local func ground_color(t, ix, iz, h, slope){
  local over = h - t.water
  local x = m.world(t, ix)
  local z = m.world(t, iz)
  local v = vec.noise(x * 0.35, z * 0.35, 11) * 0.5 + 0.5
  local r = 0
  local g = 0
  local b = 0
  if(over < 0.35){
    // sand
    local k = vec.clamp((over + 0.6) / 0.95, 0, 1)
    r = vec.mix(206, 214, v)
    g = vec.mix(186, 196, v)
    b = vec.mix(130, 142, v)
    // wetter and darker right at the water
    r = r * (0.75 + 0.25 * k)
    g = g * (0.75 + 0.25 * k)
    b = b * (0.75 + 0.25 * k)
  } else if(over < 0.9){
    local k = (over - 0.35) / 0.55
    r = vec.mix(206, vec.mix(96, 118, v), k)
    g = vec.mix(186, vec.mix(168, 184, v), k)
    b = vec.mix(130, vec.mix(70, 80, v), k)
  } else {
    r = vec.mix(96, 118, v)
    g = vec.mix(168, 184, v)
    b = vec.mix(70, 80, v)
    // darker, bluer grass up high; snow over 22
    local high = vec.clamp((h - 12) / 10, 0, 1)
    r = vec.mix(r, 92, high)
    g = vec.mix(g, 140, high)
    b = vec.mix(b, 84, high)
    local snow = vec.clamp((h - 22) / 4, 0, 1)
    r = vec.mix(r, 236, snow)
    g = vec.mix(g, 240, snow)
    b = vec.mix(b, 246, snow)
  }
  // rock on steep ground
  local rock = vec.clamp((slope - 0.45) / 0.3, 0, 1)
  r = vec.mix(r, vec.mix(120, 140, v), rock)
  g = vec.mix(g, vec.mix(114, 132, v), rock)
  b = vec.mix(b, vec.mix(108, 124, v), rock)
  return {to_int(r), to_int(g), to_int(b)}
}

// build(t): makes (or remakes) t.model, the raylib model of the ground
func m.build(t){
  if(t.model != null){
    rl.unload_model(t.model)
    t.model = null
  }
  local n = t.n
  local vertex_count = n * n
  local triangle_count = (n - 1) * (n - 1) * 2
  local vertices = raylib_buffer("float", vertex_count * 3, 4)
  local normals = raylib_buffer("float", vertex_count * 3, 4)
  local colors = raylib_buffer("unsigned char", vertex_count * 4, 1)
  local indices = raylib_buffer("unsigned short", triangle_count * 3, 2)
  local h = t.heights
  local s = t.spacing
  for(local iz = 0; iz < n; iz = iz + 1){
    for(local ix = 0; ix < n; ix = ix + 1){
      local i = iz * n + ix
      local y = h[i]
      vertices[i * 3] = m.world(t, ix)
      vertices[i * 3 + 1] = y
      vertices[i * 3 + 2] = m.world(t, iz)
      local xa = ix
      local xb = ix
      if(ix > 0){
        xa = ix - 1
      }
      if(ix < n - 1){
        xb = ix + 1
      }
      local za = iz
      local zb = iz
      if(iz > 0){
        za = iz - 1
      }
      if(iz < n - 1){
        zb = iz + 1
      }
      local dx = (h[iz * n + xb] - h[iz * n + xa]) / ((xb - xa) * s)
      local dz = (h[zb * n + ix] - h[za * n + ix]) / ((zb - za) * s)
      local nv = vec.normalize({x: -dx, y: 1, z: -dz})
      normals[i * 3] = nv.x
      normals[i * 3 + 1] = nv.y
      normals[i * 3 + 2] = nv.z
      local slope = 1 - nv.y
      local c = ground_color(t, ix, iz, y, math.sqrt(dx * dx + dz * dz) / 3)
      colors[i * 4] = c[0]
      colors[i * 4 + 1] = c[1]
      colors[i * 4 + 2] = c[2]
      colors[i * 4 + 3] = 255
    }
  }
  local k = 0
  for(local iz = 0; iz < n - 1; iz = iz + 1){
    for(local ix = 0; ix < n - 1; ix = ix + 1){
      local a = iz * n + ix
      local b = a + 1
      local c = a + n
      local d = c + 1
      indices:set({a, c, b, b, c, d}, k)
      k = k + 6
    }
  }
  local mesh = {
    vertex_count: vertex_count,
    triangle_count: triangle_count,
    vertices: vertices,
    normals: normals,
    colors: colors,
    indices: indices,
  }
  rl.upload_mesh(mesh, false)
  t.model = rl.load_model_from_mesh(mesh)
  t.built = t.version
  return t.model
}

// shape(t) -> the Jolt height field shape of the terrain (made again
// after the terrain changed)
func m.shape(t){
  local n = t.n
  local samples = buffer.new("float", n * n)
  for(local i = 0; i < n * n; i = i + 1){
    samples[i] = t.heights[i]
  }
  local settings = jolt.height_field_shape_settings_create(
    samples, {-t.half, 0, -t.half}, {t.spacing, 1, t.spacing}, n, null
  )
  t.shape = jolt.height_field_shape_settings_create_shape(settings)
  return t.shape
}

func m.unload(t){
  if(t.model != null){
    rl.unload_model(t.model)
    t.model = null
  }
}

// ------------------------------------------------------------ saving

// the samples rounded to centimeters, for a level file
func m.export(t){
  local hs = {}
  for(let local h in values(t.heights)){
    append(hs, math.round(h * 100) / 100)
  }
  return {n: t.n, spacing: t.spacing, water: t.water, heights: hs}
}

func m.import(data){
  local t = m.new(data.n, data.spacing, data.water)
  for(local i = 0; i < t.n * t.n; i = i + 1){
    t.heights[i] = data.heights[i] or 0
  }
  return t
}

return m
