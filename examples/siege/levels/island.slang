// Island: three islets joined by sand bars, each with something to
// wreck: a house with a bridge of barrels, a stone tower, a shed. The
// sand bars are narrow; the water is close everywhere.
local levels = require("game/levels")
local vec = require("game/vec")
local math = require("slang/math")

local b = levels.builder("Island", 47)
local islands = {{x: 0, z: -28, r: 15}, {x: 10, z: 8, r: 16}, {x: -24, z: 22, r: 13}}
b:terrain(func(x, z){
  local n = vec.fbm(x * 0.04, z * 0.04, 9, 3)
  local h = -4
  for(let local isl in values(islands)){
    local d = math.sqrt((x - isl.x) * (x - isl.x) + (z - isl.z) * (z - isl.z))
    local k = vec.clamp(1 - d / isl.r, 0, 1)
    h = math.max(h, -4 + math.sqrt(k) * 9.5 + n * 1.5)
  }
  // sand bars between them
  local func bar(ax, az, bx, bz){
    local dx = bx - ax
    local dz = bz - az
    local l2 = dx * dx + dz * dz
    local t = vec.clamp(((x - ax) * dx + (z - az) * dz) / l2, 0, 1)
    local px = ax + dx * t
    local pz = az + dz * t
    local d = math.sqrt((x - px) * (x - px) + (z - pz) * (z - pz))
    return vec.clamp(1 - d / 5, 0, 1)
  }
  local bars = math.max(bar(0, -28, 10, 8), bar(10, 8, -24, 22))
  return math.max(h, -4 + bars * 5.6)
})
b:water(0.6)
b:spawn(0, -30, 0.3)
b:structure("house", {x: 12, z: 10, yaw: 0.6, width: 7, depth: 8, height: 3})
b:structure("bridge", {x: 4, z: 14, yaw: 1.2, length: 6, height: 2.5})
b:structure("tower", {x: -24, z: 24, yaw: 0, radius: 1.8, height: 6})
b:structure("house", {x: -28, z: 16, yaw: -0.4, width: 5, depth: 5, height: 2.5, roof: "flat"})
b:structure("stack", {x: 16, z: 2, yaw: 0, rows: 4})
b:object({kind: "cylinder", material: "barrel", pos: {x: 7, z: 4}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:object({kind: "cylinder", material: "barrel", pos: {x: -21, z: 18}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:scatter("tree", 10, 8, 14, 5)
b:scatter("pine", -24, 22, 12, 4)
b:scatter("bush", 0, 0, 50, 14)
b:scatter("flowers", 0, 0, 50, 12)
b:scatter("boulder", 0, -28, 12, 3)
b:target(9000)
b:ammo({rock: 8, triple: 3, bomb: 2, chain: 2})
return b:level()
