// Citadel: the big one. A walled town with two towers, a hall, houses
// and a store of barrels, on a plateau over a lake. Plenty of ammo; the
// target asks for most of it to come down.
local levels = require("game/levels")
local vec = require("game/vec")
local math = require("slang/math")

local b = levels.builder("Citadel", 59)
b:terrain(func(x, z){
  local n = vec.fbm(x * 0.02, z * 0.02, 13, 4)
  local plateau = vec.clamp(1 - (math.sqrt(x * x + (z - 10) * (z - 10)) - 22) / 10, 0, 1)
  plateau = plateau * plateau * (3 - 2 * plateau)
  local lake = vec.clamp(1 - math.sqrt((x + 36) * (x + 36) + (z + 30) * (z + 30)) / 22, 0, 1)
  return 2 + n * 4 + plateau * 6 - lake * 8
})
b:water(0.5)
b:flatten(0, 10, 24, 8)
b:spawn(0, -34, 0)
b:structure("tower", {x: -12, z: 0, yaw: 0, radius: 2.2, height: 8, roof: "cone", base: 8})
b:structure("tower", {x: 12, z: 0, yaw: 0, radius: 2.2, height: 8, roof: "cone", base: 8})
b:structure("wall", {x: -6.5, z: 0, yaw: 0, length: 7, height: 4, base: 8})
b:structure("wall", {x: 6.5, z: 0, yaw: 0, length: 7, height: 4, base: 8})
b:structure("house", {x: 0, z: 12, yaw: 0, width: 10, depth: 9, height: 4, base: 8})
b:structure("house", {x: -11, z: 14, yaw: 1.3, width: 5, depth: 6, height: 2.5, base: 8})
b:structure("house", {x: 12, z: 15, yaw: -1.1, width: 6, depth: 6, height: 3, roof: "flat", base: 8})
b:structure("stack", {x: -4, z: 4, yaw: 0.2, rows: 3, base: 8})
b:structure("bridge", {x: 0, z: 24, yaw: 0, length: 8, height: 3, base: 8})
for(local i = 0; i < 5; i = i + 1){
  b:object({kind: "cylinder", material: "barrel", pos: {x: 3 + (i % 3) * 1.1, z: 4 + to_int(i / 3) * 1.1}, size: {x: 0.45, y: 1.1, z: 0.45}})
}
b:object({kind: "cylinder", material: "barrel", pos: {x: -12, z: 8}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:object({kind: "cylinder", material: "barrel", pos: {x: 13, z: 9}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:scatter("tree", 0, 10, 60, 14)
b:scatter("pine", 30, -20, 25, 10)
b:scatter("bush", 0, 0, 58, 22)
b:scatter("flowers", 0, 0, 58, 20)
b:scatter("boulder", 30, 30, 25, 6)
b:target(16000)
b:ammo({rock: 10, triple: 4, bomb: 3, chain: 3})
return b:level()
