// tool/map: the land of a seed from above, written as a picture.
//
//   cd examples/switchback && ../../bin/slang run tool/map.slang [seed] [file.png]
local rl = require("raylib")
local str = require("slang/string")
local time = require("slang/time")
local math = require("slang/math")
local terrain = require("game/terrain")
local route = require("game/route")

local argv = args()
local seed = if(len(argv) > 0){ to_int(str.to_number(argv[0])) } else { 7 }
local file = if(len(argv) > 1){ argv[1] } else { "map.png" }

local started = time.clock()
local land = terrain.generate(seed)
local made = time.clock()
local trail = route.plan(land)
local planned = time.clock()
route.carve(land, trail)
local carved = time.clock()
terrain.finish(land)
local finished = time.clock()
local picture = terrain.picture(land, 2)
rl.image.export({
  data: picture.data, width: picture.size, height: picture.size, mipmaps: 1,
  format: rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
}, file)
local lowest = 1.0e9
local highest = -1.0e9
for(local i = 0; i < land.n * land.n; i = i + 97){
  local h = land.heights[i]
  if(h < lowest){ lowest = h }
  if(h > highest){ highest = h }
}
local steepest = 0
local climb = 0
for(local i = 1; i < len(trail.points); i = i + 1){
  local dy = trail.points[i].y - trail.points[i - 1].y
  steepest = math.max(steepest, math.abs(dy) / route.STEP)
  if(dy > 0){
    climb = climb + dy
  }
}
print("trail: ", to_int(trail.length), " m, from ", to_int(trail.start.y), " m up to ", to_int(trail.goal.y), " m (", to_int(climb),
  " m of climbing, steepest ", to_int(steepest * 100), "%); planned in ", to_int(planned - made), " ms, carved in ", to_int(carved - planned),
  " ms, shape and cover in ", to_int(finished - carved), " ms\n")
for(let local section in values(trail.sections)){
  print("  ", section.name, " from ", to_int(section.from), " to ", to_int(section.to), " m\n")
}
for(let local c in values(trail.checkpoints)){
  print("  ", c.name, " at ", to_int(c.at), " m: ", to_int(c.x), " ", to_int(c.y), " ", to_int(c.z), "\n")
}
print("seed ", seed, ": generated in ", to_int(made - started), " ms, heights ", to_int(lowest), " to ", to_int(highest),
  " m, lake at z ", to_int(land.river.lake.z), " level ", to_int(land.river.lake.level), ", peak at ", to_int(land.peak.x), " ", to_int(land.peak.z),
  "; picture ", file, "\n")
