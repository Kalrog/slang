// a level of Siege, in its builder (levels/meadow.slang)
local b = levels.builder("Meadow", 11)
b:terrain(func(x, z){
  return 4.5 + vec.fbm(x * 0.022, z * 0.022, 3, 3) * 5
})
b:water(1.4)
b:spawn(0, -26, 0)
b:structure("house", {x: 0, z: 8, width: 7, depth: 8, height: 3})
b:structure("stack", {x: -12, z: 6, yaw: 0.4, rows: 4})
b:scatter("tree", 0, 0, 55, 18)
b:target(4000)
b:ammo({rock: 6, triple: 2, bomb: 1, chain: 1})
return b:level()
