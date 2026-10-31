// Hilltop: a fort on a hill: a ring wall with a tower, a house inside and
// barrels by the gate. The catapult starts in the valley and has to
// climb the ramp to see over the wall, or lob shots from below.
local levels = require("game/levels")
local vec = require("game/vec")
local math = require("slang/math")

local b = levels.builder("Hilltop", 31)
b:terrain(func(x, z){
  local n = vec.fbm(x * 0.025, z * 0.025, 7, 3)
  local d = math.sqrt(x * x + (z - 14) * (z - 14))
  local hill = vec.clamp(1 - d / 34, 0, 1)
  hill = hill * hill * (3 - 2 * hill)
  return 3 + n * 3 + hill * 11
})
b:water(0.8)
// the hill's top is flat, with a ramp down the near side
b:flatten(0, 14, 15, 14)
for(local i = 0; i < 12; i = i + 1){
  local z = 2 - i * 2.4
  b:flatten(-3, z, 5, 14 - i * 1.0)
}
b:spawn(-3, -30, 0)
b:structure("tower", {x: 6, z: 20, yaw: 0, radius: 2, height: 7, roof: "cone", base: 14})
b:structure("wall", {x: 0, z: 6, yaw: 0, length: 8, height: 3, base: 14})
b:structure("wall", {x: -8, z: 12, yaw: math.pi / 2, length: 10, height: 3, base: 14})
b:structure("wall", {x: 9, z: 10, yaw: math.pi / 2, length: 6, height: 3, base: 14})
b:structure("house", {x: -2, z: 16, yaw: 0.2, width: 6, depth: 7, height: 3, base: 14})
b:structure("stack", {x: 5, z: 12, yaw: 0.3, rows: 3, base: 14})
b:object({kind: "cylinder", material: "barrel", pos: {x: 4.6, z: 7.5}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:object({kind: "cylinder", material: "barrel", pos: {x: 5.5, z: 7.8}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:object({kind: "cylinder", material: "barrel", pos: {x: -3, z: 20.5}, size: {x: 0.45, y: 1.1, z: 0.45}})
b:scatter("pine", 0, 0, 58, 16)
b:scatter("tree", 20, -20, 30, 8)
b:scatter("bush", 0, 0, 55, 18)
b:scatter("boulder", -25, 0, 25, 6)
b:scatter("flowers", 0, -10, 40, 14)
b:target(8000)
b:ammo({rock: 7, triple: 2, bomb: 2, chain: 2})
return b:level()
