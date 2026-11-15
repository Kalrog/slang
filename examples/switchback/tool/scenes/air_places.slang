// tool/scenes/air_places: a moderate day's wind (the game's: steady with
// gusts) while the place changes, as on a drive up the valley: a meadow,
// into a conifer wood, a broadleaf wood, and out onto a bare ridge, where
// it blows harder; fifteen seconds each, five seconds from one to the
// next. The layers should hand over to each other without a seam.
local math = require("slang/math")

// what each place is: {conifer, broadleaf, bush, grass, alpine, shelter}
local PLACES = {
  {0, 0.08, 0.1, 1, 0, 0.05},
  {1, 0.05, 0.1, 0.3, 0.1, 0.45},
  {0.1, 0.9, 0.4, 0.4, 0, 0.45},
  {0, 0, 0, 0.1, 1, 0},
}

return func(kit, args){
  local world = require("tool/scenes/air_kit")
  return world.hear(kit, 80, {"air"}, func(t, frame){
    local a = frame.around
    local at = math.min(t / 20, 3)
    local k = math.min(to_int(at), 2)
    // (fifteen seconds in a place, five on the way to the next)
    local mix = math.min(math.max((at - k - 0.75) / 0.25, 0), 1)
    local p = PLACES[k]
    local q = PLACES[k + 1]
    local func between(i){
      return p[i] + (q[i] - p[i]) * mix
    }
    a.trees.conifer = between(0)
    a.trees.broadleaf = between(1)
    a.trees.bush = between(2)
    a.cover.grass = between(3)
    a.alpine = between(4)
    a.shelter = between(5)
    // the wind as sound/around has it: harder up high, less in shelter
    local where = (0.55 + 0.75 * a.alpine) * (1 - 0.6 * a.shelter)
    world.blow(a, t, 0.32 * where)
  })
}
