// game/textures: every texture the game uses, made at start by slang,
// pixel by pixel, from noise: there are no image files. Most are gray
// patterns that a material's color tints when they are drawn.
local rl = require("raylib")
local buffer = require("slang/buffer")
local math = require("slang/math")
local vec = require("game/vec")

local m = {}

local SIZE = 128

// noise(size, scale, seed) -> a function (x, y) -> [-1, 1] over the pixel
// grid, from an image of Perlin noise raylib makes (fast, in C)
local func noise(size, scale, seed){
  local image = rl.gen_image_perlin_noise(size, size, seed * 97, seed * 31, scale)
  local px = buffer.wrap(image.data, size * size * 4, "unsigned char")
  local values = {}
  for(local i = 0; i < size * size; i = i + 1){
    append(values, px[i * 4] / 127.5 - 1)
  }
  rl.unload_image(image)
  return values
}

// an image of size x size pixels from f(x, y, i) -> {r, g, b, a?} with x
// and y in [0, 1) and i the pixel's index, made a texture with mipmaps
// that repeats mirrored (so the noise needs no seams)
local func make(size, f){
  local image = rl.gen_image_color(size, size, rl.WHITE)
  local px = buffer.wrap(image.data, size * size * 4, "unsigned char")
  local k = 0
  local i = 0
  for(local y = 0; y < size; y = y + 1){
    for(local x = 0; x < size; x = x + 1){
      local c = f(x / size, y / size, i)
      px[k] = vec.clamp(to_int(c[0]), 0, 255)
      px[k + 1] = vec.clamp(to_int(c[1]), 0, 255)
      px[k + 2] = vec.clamp(to_int(c[2]), 0, 255)
      px[k + 3] = vec.clamp(to_int(c[3] or 255), 0, 255)
      k = k + 4
      i = i + 1
    }
  }
  local texture = rl.load_texture_from_image(image)
  rl.unload_image(image)
  rl.gen_texture_mipmaps(texture)
  rl.set_texture_filter(texture, rl.TEXTURE_FILTER_TRILINEAR)
  rl.set_texture_wrap(texture, rl.TEXTURE_WRAP_MIRROR_REPEAT)
  return texture
}

local func gray(v, a){
  return {v, v, v, a}
}

// bricks: rows of stones with lighter mortar, every stone its own shade
local func bricks(size){
  local grain = noise(size, 6, 1)
  local rows = 4
  local cols = 2
  return func(x, y, i){
    local ry = y * rows
    local row = math.floor(ry)
    local shift = 0
    if(to_int(row) % 2 == 1){
      shift = 0.5
    }
    local rx = x * cols + shift
    local col = math.floor(rx)
    local fx = rx - col
    local fy = ry - row
    local mortar = 0.07
    local edge = math.min(math.min(fx, 1 - fx) * cols, math.min(fy, 1 - fy) * rows)
    local stone = vec.clamp((edge - mortar * 0.5) / mortar, 0, 1)
    local shade = 0.86 + vec.noise(col * 13.7 + shift * 50, row * 7.1, 5) * 0.12
    local v = (shade + grain[i] * 0.1) * 190
    return gray(vec.mix(205 + grain[i] * 15, v, stone))
  }
}

// planks: boards with grain along y and a dark seam between them
local func planks(size){
  local grain = noise(size, 3, 2)
  local fine = noise(size, 12, 3)
  local boards = 3
  return func(x, y, i){
    local bx = x * boards
    local board = math.floor(bx)
    local fx = bx - board
    local seam = vec.clamp(math.min(fx, 1 - fx) * boards / 0.05, 0, 1)
    local g = math.sin((y * 12 + grain[i] * 2.5 + board * 2) * math.pi)
    local v = (0.8 + g * 0.08 + fine[i] * 0.08 + vec.noise(board * 9.3, 2, 9) * 0.08) * 200
    return gray(vec.mix(80, v, seam))
  }
}

// grass: soft blotches for the ground (tinted by the terrain's colors)
local func grass(size){
  local n = noise(size, 4, 4)
  local fine = noise(size, 14, 5)
  return func(x, y, i){
    return gray(195 + n[i] * 35 + fine[i] * 25)
  }
}

// plain speckled stone, for towers and furniture
local func rough(size){
  local n = noise(size, 7, 6)
  return func(x, y, i){
    return gray(205 + n[i] * 35)
  }
}

// metal with horizontal bands (a barrel's hoops)
local func barrel(size){
  local n = noise(size, 8, 7)
  return func(x, y, i){
    local band = 0
    local fy = (y * 3) % 1
    if(fy < 0.12){
      band = 1 - vec.clamp(math.abs(fy - 0.06) / 0.06, 0, 1) * 0.3
    }
    return gray(vec.mix(200 + n[i] * 25, 70, band))
  }
}

// ripples, for the water: layered waves
local func water(size){
  local n = noise(size, 3, 8)
  return func(x, y, i){
    local w = math.sin((x * 6 + n[i]) * math.pi * 2) * 0.5 +
      math.sin((y * 4 + x * 2 + n[i] * 0.5) * math.pi * 2) * 0.5
    local v = 200 + w * 28 + n[i] * 20
    return {v, v + 8, v + 16, 255}
  }
}

// a soft round blob: shadows under things, smoke
local func blob(size){
  return func(x, y, i){
    local dx = x - 0.5
    local dy = y - 0.5
    local d = math.sqrt(dx * dx + dy * dy) * 2
    local a = 1 - vec.clamp(d, 0, 1)
    return {255, 255, 255, a * a * 255}
  }
}

// leaves: dark and light patches
local func leaves(size){
  local n = noise(size, 6, 9)
  local fine = noise(size, 16, 10)
  return func(x, y, i){
    return gray(200 + n[i] * 50 + fine[i] * 30)
  }
}

// clouds: fluffy noise with soft edges, for the sky
local func cloud(size){
  local n = noise(size, 3, 11)
  return func(x, y, i){
    local dx = x - 0.5
    local dy = (y - 0.5) * 1.8
    local d = math.sqrt(dx * dx + dy * dy) * 2
    local a = vec.clamp((1 - d) * 1.6 - 0.2 + (n[i] * 0.5 + 0.5) * 0.7, 0, 1)
    return {255, 255, 255, a * a * 255}
  }
}

// a single bright dot that fades: sparks, flowers, the sun
local func spark(size){
  return func(x, y, i){
    local dx = x - 0.5
    local dy = y - 0.5
    local d = math.sqrt(dx * dx + dy * dy) * 2
    local a = 1 - vec.clamp(d, 0, 1)
    return {255, 255, 255, a * a * a * 255}
  }
}

// white, for things drawn with no texture
local func white(size){
  return func(x, y, i){
    return {255, 255, 255, 255}
  }
}

local makers = {
  bricks: bricks,
  planks: planks,
  grass: grass,
  rough: rough,
  barrel: barrel,
  water: water,
  blob: blob,
  leaves: leaves,
  cloud: cloud,
  spark: spark,
  white: white,
}

local sizes = {cloud: 256, blob: 64, spark: 32, white: 4}

local textures = {}

// get(name) -> Texture2D, made the first time
func m.get(name){
  local t = textures[name]
  if(t == null){
    local maker = makers[name]
    if(maker == null){
      error("no texture called ", name)
    }
    local size = sizes[name] or SIZE
    t = make(size, maker(size))
    textures[name] = t
  }
  return t
}

// all(): every texture made now (at start, not on the first frame it is
// needed)
func m.all(){
  for(let local e in entries(makers)){
    m.get(e[0])
  }
}

func m.unload(){
  for(let local e in entries(textures)){
    rl.unload_texture(e[1])
  }
  textures = {}
}

return m
