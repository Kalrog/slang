// Harbor: a town on a spit of land in the sea; a watchtower, two houses
// and a bridge of barrels, with water on three sides. Drive carefully.
local levels = require("game/levels")
local vec = require("game/vec")
local math = require("slang/math")

local b = levels.builder("Harbor", 23)
b:terrain(func(x, z){
  local n = vec.fbm(x * 0.03, z * 0.03, 5, 3)
  // a ridge of land along z, the sea at both sides
  local spit = 1 - vec.clamp((math.abs(x) - 14 - n * 6) / 12, 0, 1)
  return -3 + spit * 9 + n * 2
})
b:water(1.2)
b:spawn(0, -38, 0)
b:structure("tower", {x: 4, z: 2, yaw: 0, radius: 1.8, height: 6, roof: "cone"})
b:structure("house", {x: -6, z: 10, yaw: 0.5, width: 6, depth: 7, height: 3})
b:structure("house", {x: 6, z: 20, yaw: -0.3, width: 5, depth: 5, height: 2.5, roof: "flat"})
b:structure("bridge", {x: -4, z: 28, yaw: 0.2, length: 7, height: 3})
b:object({kind: "cylinder", material: "barrel", pos: {x: 1, z: 6}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:object({kind: "cylinder", material: "barrel", pos: {x: 2, z: 6.5}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:scatter("tree", 0, 0, 50, 10)
b:scatter("bush", 0, 0, 50, 16)
b:scatter("flowers", 0, 10, 40, 16)
b:scatter("boulder", 0, 40, 20, 4)
b:target(6000)
b:ammo({rock: 6, triple: 2, bomb: 2, chain: 2})
return b:level()
