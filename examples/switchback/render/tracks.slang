// render/tracks: what the wheels leave on the ground. A map of how hard
// the ground has been pressed, an eighth of a meter to the texel, lies
// around the truck and goes with it (the map wraps: a place's texel is
// its position modulo the map's side, and what comes into reach on one
// side as the truck moves is wiped as it leaves on the other). Each wheel
// on the ground presses its path into the map, harder on soft ground and
// when it spins; the ground's shader darkens and dents what is pressed
// (render/terrain) and the grass lies down there (render/grass).
//
//   tracks.init()
//   tracks.update(world)        // once a frame, after the physics
//   tracks.texture(), tracks.info()
local rl = require("raylib")
local math = require("slang/math")
local kernel = require("kernel")
local terrain_lib = require("game/terrain")

local m = {}

m.SIZE = 2048       // texels along a side of the map
m.TEXEL = 0.125     // meters to a texel: the map reaches 128 m each way
m.BLOCK = 16        // texels: the map is wiped in strips this wide (2 m)

// how hard a tire presses each kind of ground, 0 to 1 (rock and wood
// take no mark; under water nothing stays)
local PRESS = {
  mud: 1.0, snow: 0.95, sand: 0.85, grass: 0.6, dirt: 0.45, gravel: 0.4, ice: 0.15,
}

local state = {}

// init(): an empty map
func m.init(){
  local n = m.SIZE
  state.map = kernel.uint8:array(n * n)
  state.texture = rl.texture.load_from_image({
    data: state.map, width: n, height: n, mipmaps: 1,
    format: rl.PIXELFORMAT_UNCOMPRESSED_GRAYSCALE,
  })
  state.texture.filter = rl.TEXTURE_FILTER_BILINEAR
  state.texture.wrap = rl.TEXTURE_WRAP_REPEAT
  state.zeros = kernel.uint8:array(n * m.BLOCK)
  state.center = null
  state.last = {}
  // the rows changed since the last upload: first and last, in the map's
  // lower and upper half
  state.low = {n, -1}
  state.high = {n, -1}
  state.at = {x: 0, z: 0}
}

// texture() -> the map, for the shaders: its red is how hard the ground
// is pressed at (x, z) * info()[0], repeating
func m.texture(){
  return state.texture
}

// info() -> {1 / the map's side in meters, the x and z of its middle, 1}:
// what the shaders need to read it (it holds what is within 0.45 of its
// side of its middle)
func m.info(){
  return {1 / (m.SIZE * m.TEXEL), state.at.x, state.at.z, 1}
}

// a texel index along one axis, wrapped
local func wrap(i){
  local n = m.SIZE
  i = i % n
  if(i < 0){
    i = i + n
  }
  return i
}

// the map wiped where the truck's moving brings new ground into reach
local func wipe_column(block){
  local n = m.SIZE
  local c0 = wrap(block * m.BLOCK)
  for(local r = 0; r < n; r = r + 1){
    state.map:slice(r * n + c0, r * n + c0 + m.BLOCK):fill(0)
  }
  state.texture:update_rec({x: c0, y: 0, width: m.BLOCK, height: n}, state.zeros)
}

local func wipe_row(block){
  local n = m.SIZE
  local r0 = wrap(block * m.BLOCK)
  state.map:slice(r0 * n, (r0 + m.BLOCK) * n):fill(0)
  state.texture:update_rec({x: 0, y: r0, width: n, height: m.BLOCK}, state.zeros)
}

local func wipe_all(){
  state.map:fill(0)
  state.texture:update(state.map)
  state.low = {m.SIZE, -1}
  state.high = {m.SIZE, -1}
}

// the map's middle moved to the truck: block by block, each step wiping
// the strip that now stands for ground on the other side
local func follow(x, z){
  local side = m.BLOCK * m.TEXEL
  local blocks = to_int(m.SIZE / m.BLOCK)
  local bx = to_int(math.floor(x / side))
  local bz = to_int(math.floor(z / side))
  local c = state.center
  if(c == null){
    state.center = {x: bx, z: bz}
    return
  }
  if(math.abs(bx - c.x) >= blocks / 2 or math.abs(bz - c.z) >= blocks / 2){
    // set down far away: nothing of the old map is near
    wipe_all()
    state.center = {x: bx, z: bz}
    state.last = {}
    return
  }
  for(c.x < bx){
    c.x = c.x + 1
    wipe_column(c.x + to_int(blocks / 2) - 1)
  }
  for(c.x > bx){
    c.x = c.x - 1
    wipe_column(c.x - to_int(blocks / 2))
  }
  for(c.z < bz){
    c.z = c.z + 1
    wipe_row(c.z + to_int(blocks / 2) - 1)
  }
  for(c.z > bz){
    c.z = c.z - 1
    wipe_row(c.z - to_int(blocks / 2))
  }
}

// a tire's print at a place: the texels under it pressed, evenly across
// the tread and less at its edges; what was pressed harder before stays
local func stamp(x, z, strength){
  local n = m.SIZE
  local fx = x / m.TEXEL
  local fz = z / m.TEXEL
  local ix = to_int(math.floor(fx))
  local iz = to_int(math.floor(fz))
  local map = state.map
  for(local dj = -1; dj <= 1; dj = dj + 1){
    local row = wrap(iz + dj)
    for(local di = -1; di <= 1; di = di + 1){
      local ex = ix + di + 0.5 - fx
      local ez = iz + dj + 0.5 - fz
      local w = (1.9 - math.sqrt(ex * ex + ez * ez)) / 0.8
      if(w > 0){
        if(w > 1){
          w = 1
        }
        local at = row * n + wrap(ix + di)
        local value = to_int(strength * w * 255)
        if(value > map[at]){
          map[at] = value
        }
      }
    }
    // (rows changed, kept apart by which half of the map they are in:
    // the map wraps, and the truck may stand on the seam)
    if(row < n / 2){
      if(row < state.low[0]){
        state.low[0] = row
      }
      if(row > state.low[1]){
        state.low[1] = row
      }
    } else {
      if(row < state.high[0]){
        state.high[0] = row
      }
      if(row > state.high[1]){
        state.high[1] = row
      }
    }
  }
}

// update(world): the wheels' paths since the last frame pressed into the
// map, and the map kept around the truck
func m.update(world){
  if(state.map == null){
    return
  }
  local car = world.car
  follow(car.pos.x, car.pos.z)
  state.at = {x: car.pos.x, z: car.pos.z}
  for(local i = 0; i < 4; i = i + 1){
    local w = car.wheels[i]
    local last = state.last[i]
    if(not w.contact){
      state.last[i] = null
      continue
    }
    local p = w.point
    local press = PRESS[w.surface.name] or 0
    if(press > 0 and terrain_lib.water_at(world.land, p.x, p.z) > 0.03){
      press = 0
    }
    if(press <= 0){
      state.last[i] = null
      continue
    }
    // harder when it spins or slides, lighter when it hardly carries
    local slip = math.min(1, math.abs(w.slip_ratio) + math.abs(w.side_slip))
    local strength = math.min(1, press * (0.75 + 0.5 * slip)) * math.min(1, w.load / 2500)
    if(last == null){
      stamp(p.x, p.z, strength)
      state.last[i] = {x: p.x, z: p.z}
    } else {
      local dx = p.x - last.x
      local dz = p.z - last.z
      local d = math.sqrt(dx * dx + dz * dz)
      if(d > 3){
        // (set down elsewhere: no line between)
        state.last[i] = {x: p.x, z: p.z}
      } else if(d >= 0.07){
        local steps = to_int(d / 0.1) + 1
        for(local k = 1; k <= steps; k = k + 1){
          stamp(last.x + dx * k / steps, last.z + dz * k / steps, strength)
        }
        last.x = p.x
        last.z = p.z
      }
    }
  }
  // what changed, to the graphics card: the rows from the first changed
  // to the last, in each half of the map
  local n = m.SIZE
  for(let local span in values({state.low, state.high})){
    if(span[1] >= span[0]){
      state.texture:update_rec(
        {x: 0, y: span[0], width: n, height: span[1] - span[0] + 1},
        state.map:slice(span[0] * n, (span[1] + 1) * n),
      )
      span[0] = n
      span[1] = -1
    }
  }
}

// clear(): no tracks (a new run)
func m.clear(){
  if(state.map != null){
    wipe_all()
    state.last = {}
  }
}

func m.unload(){
  if(state.texture != null){
    state.texture:unload()
    state.texture = null
    state.map = null
  }
}

return m
