// tool/scenes/tires_survey: what the Summit Run of a seed is made of, a
// line every 50 m: how high it is there, how deep its water, and what the
// ground under the two ruts is (for finding the stretches to listen to:
// the fords, the rock, the snow). Arguments: the seed (25). The WAV it
// leaves is a moment of silence.
local kernel = require("kernel")
local str = require("slang/string")
local world = require("game/world")
local terrain = require("game/terrain")

return func(kit, args){
  local seed = to_int(str.to_number(args[0] or "25"))
  local w = world.new({seed: seed, plants: false})
  local trail = w.trail
  local points = trail.points
  print("seed ", seed, ": ", len(points), " points\n")
  for(let local f in values(trail.fords or {})){
    print("ford from ", f.from, " to ", f.to, "\n")
  }
  local step = 25
  for(local i = 0; i < len(points); i = i + step){
    local counts = {}
    local deepest = 0
    local top = 0
    for(local k = i; k < i + step and k < len(points); k = k + 1){
      local p = points[k]
      // (a rut to each side, taken along x: the track's direction does
      // not matter for a survey)
      for(let local off in values({-0.8, 0.8})){
        local s = terrain.surface_at(w.land, p.x + off, p.z)
        counts[s.name] = (counts[s.name] or 0) + 1
        local d = terrain.water_at(w.land, p.x + off, p.z)
        if(d > deepest){
          deepest = d
        }
      }
      if(p.y > top){
        top = p.y
      }
    }
    local parts = {}
    for(let local e in entries(counts)){
      append(parts, concat(e[0], ":", string(e[1])))
    }
    print(
      str.format("%5d m  y %5.0f  water %.2f  ", i * 2, top, deepest),
      str.join(parts, " "), "\n"
    )
  }
  world.destroy(w)
  return {channels: {kernel.float:array(kit.BLOCK)}, load: 0}
}
