// Meadow: the first level. A gentle valley by a lake, a cottage and a
// wood shed in the open; the catapult starts close by.
local levels = require("game/levels")
local vec = require("game/vec")

local b = levels.builder("Meadow", 11)
b:terrain(func(x, z){
  local n = vec.fbm(x * 0.022, z * 0.022, 3, 3)
  local h = 4.5 + n * 5
  // a lake toward the far corner
  local dx = x - 34
  local dz = z - 36
  local lake = 1 - vec.clamp((dx * dx + dz * dz) / 900, 0, 1)
  return h - lake * 6
})
b:water(1.4)
b:spawn(0, -26, 0)
b:structure("house", {x: 0, z: 8, yaw: 0.1, width: 7, depth: 8, height: 3})
b:structure("stack", {x: -12, z: 6, yaw: 0.4, rows: 4})
b:structure("wall", {x: 11, z: 10, yaw: -0.3, length: 6, height: 2.5, material: "wood", brick: {x: 2, y: 0.25, z: 0.3}})
b:object({kind: "cylinder", material: "barrel", pos: {x: 7, z: 6}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:object({kind: "cylinder", material: "barrel", pos: {x: -8, z: 9}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:scatter("tree", 0, 0, 55, 18)
b:scatter("pine", -30, 30, 25, 8)
b:scatter("bush", 0, 0, 50, 20)
b:scatter("flowers", 0, 0, 45, 24)
b:scatter("boulder", 20, -20, 30, 5)
b:target(4000)
b:ammo({rock: 6, triple: 2, bomb: 1, chain: 1})
return b:level()
