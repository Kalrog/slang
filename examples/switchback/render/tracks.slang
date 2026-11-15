// render/tracks: what the wheels leave on the ground. A map of how hard
// the ground has been pressed, and which way the wheel went that pressed
// it, a sixteenth of a meter to the texel, lies around the truck and goes
// with it (the map wraps: a place's texel is its position modulo the
// map's side, and what comes into reach on one side as the truck moves is
// wiped as it leaves on the other). Each wheel on the ground presses its
// way into the map as a plain band with soft edges, harder on soft ground
// and when it spins; the ground's shader darkens and dents what is
// pressed (render/terrain), and the grass lies down there, along the way
// the wheel went and a little outward at the band's edges (render/grass).
//
//   tracks.init()
//   tracks.update(world)        // once a frame, after the physics
//   tracks.texture(), tracks.info()
local rl = require("raylib")
local math = require("slang/math")
local kernel = require("kernel")
local terrain_lib = require("game/terrain")
local press = require("render/tracks_map")

local m = {}

m.SIZE = 2048 // texels along a side of the map
m.TEXEL = 0.0625 // meters to a texel: the map reaches 64 m each way
m.BLOCK = 32 // texels: the map is wiped in strips this wide (2 m)
m.TILE = 64 // texels: what changed is kept track of in squares this
// wide (4 m), and goes to the graphics card as the rectangle around them
m.MOST = 4 // squares along a side of the largest such rectangle
// half the width of a wheel's band, m (the tire is 0.29 m wide: a little
// more, for the grass its shoulders push over), and how far the blades at
// the band's edges are turned outward (1: by 45 degrees)
m.HALF = 0.19
m.SPREAD = 0.9

// how hard a tire presses each kind of ground, 0 to 1 (rock and wood
// take no mark; under water nothing stays)
local PRESS = {
  mud: 1.0,
  snow: 0.95,
  sand: 0.85,
  grass: 0.6,
  dirt: 0.45,
  gravel: 0.4,
  ice: 0.15,
}

local state = {}

// init(): an empty map
func m.init(){
  local n = m.SIZE
  state.map = kernel.uint8:array(n * n * 4)
  press.blank(state.map, n, 0, 0, n, n)
  state.texture = rl.texture.load_from_image({
    data: state.map,
    width: n,
    height: n,
    mipmaps: 1,
    format: rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
  })
  state.texture.filter = rl.TEXTURE_FILTER_BILINEAR
  state.texture.wrap = rl.TEXTURE_WRAP_REPEAT
  // a strip of untouched ground, for wiping
  state.strip = kernel.uint8:array(n * m.BLOCK * 4)
  press.blank(state.strip, n, 0, 0, n, m.BLOCK)
  state.center = null
  state.last = {}
  // the squares changed since the last upload (by their index), and the
  // texels of a rectangle of them packed for the upload
  state.dirty = {}
  state.tile = kernel.uint8:array(m.TILE * m.MOST * m.TILE * m.MOST * 4)
  state.at = {x: 0, z: 0}
}

// texture() -> the map, for the shaders, read at (x, z) * info()[0],
// repeating: its red is how hard the ground is pressed there, its green
// and blue (each times 2, less 1) the way the wheel went, x and z
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
  press.blank(state.map, n, c0, 0, m.BLOCK, n)
  state.texture:update_rec(
    {x: c0, y: 0, width: m.BLOCK, height: n},
    state.strip,
  )
}

local func wipe_row(block){
  local n = m.SIZE
  local r0 = wrap(block * m.BLOCK)
  press.blank(state.map, n, 0, r0, n, m.BLOCK)
  state.texture:update_rec(
    {x: 0, y: r0, width: n, height: m.BLOCK},
    state.strip,
  )
}

local func wipe_all(){
  press.blank(state.map, m.SIZE, 0, 0, m.SIZE, m.SIZE)
  state.texture:update(state.map)
  state.dirty = {}
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

// a wheel's way from one place to the next pressed into the map (see
// render/tracks_map's press), going the way (wx, wz)
local func band(x0, z0, x1, z1, strength, wx, wz){
  local n = m.SIZE
  local k = 1 / m.TEXEL
  local radius = m.HALF * k
  press.press(state.map, n, x0 * k, z0 * k, x1 * k, z1 * k, radius, strength, wx, wz, m.SPREAD)
  // the squares it touched
  local reach = radius + 2
  local tiles = to_int(n / m.TILE)
  local tx0 = to_int(math.floor((math.min(x0, x1) * k - reach) / m.TILE))
  local tx1 = to_int(math.floor((math.max(x0, x1) * k + reach) / m.TILE))
  local tz0 = to_int(math.floor((math.min(z0, z1) * k - reach) / m.TILE))
  local tz1 = to_int(math.floor((math.max(z0, z1) * k + reach) / m.TILE))
  for(local tz = tz0; tz <= tz1; tz = tz + 1){
    for(local tx = tx0; tx <= tx1; tx = tx + 1){
      local row = tz % tiles
      local column = tx % tiles
      if(row < 0){
        row = row + tiles
      }
      if(column < 0){
        column = column + tiles
      }
      state.dirty[row * tiles + column] = true
    }
  }
}

// update(world): the wheels' ways since the last frame pressed into the
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
    local hard = PRESS[w.surface.name] or 0
    if(hard > 0 and terrain_lib.water_at(world.land, p.x, p.z) > 0.03){
      hard = 0
    }
    if(hard <= 0){
      state.last[i] = null
      continue
    }
    // harder when it spins or slides, lighter when it hardly carries
    local slip = math.min(1, math.abs(w.slip_ratio) + math.abs(w.side_slip))
    local strength = math.min(1, hard * (0.75 + 0.5 * slip)) *
      math.min(1, w.load / 2500)
    if(last == null){
      // set down here: from the next frame on there is a way to press
      state.last[i] = {x: p.x, z: p.z}
      continue
    }
    local dx = p.x - last.x
    local dz = p.z - last.z
    local d = math.sqrt(dx * dx + dz * dz)
    if(d > 3){
      // (set down elsewhere: no way between)
      last.x = p.x
      last.z = p.z
    } else if(d >= 0.03){
      band(last.x, last.z, p.x, p.z, strength, dx / d, dz / d)
      last.x = p.x
      last.z = p.z
    }
  }
  // what changed, to the graphics card: the rectangle around the squares
  // the wheels pressed, in one piece (every piece sent makes the card
  // wait); square by square only when they lie on both sides of the
  // map's seam, or too far apart
  local n = m.SIZE
  local size = m.TILE
  local tiles = to_int(n / size)
  local tile = state.tile
  local x0 = tiles
  local x1 = -1
  local z0 = tiles
  local z1 = -1
  for(let local index in keys(state.dirty)){
    local tx = index % tiles
    local tz = to_int((index - tx) / tiles)
    x0 = math.min(x0, tx)
    x1 = math.max(x1, tx)
    z0 = math.min(z0, tz)
    z1 = math.max(z1, tz)
  }
  if(x1 >= x0 and x1 - x0 < m.MOST and z1 - z0 < m.MOST){
    local wide = (x1 - x0 + 1) * size
    local high = (z1 - z0 + 1) * size
    press.pack(tile, state.map, n, x0 * size, z0 * size, wide, high)
    state.texture:update_rec({x: x0 * size, y: z0 * size, width: wide, height: high}, tile)
  } else {
    for(let local index in keys(state.dirty)){
      local tx = index % tiles
      local tz = to_int((index - tx) / tiles)
      press.pack(tile, state.map, n, tx * size, tz * size, size, size)
      state.texture:update_rec({x: tx * size, y: tz * size, width: size, height: size}, tile)
    }
  }
  state.dirty = {}
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
