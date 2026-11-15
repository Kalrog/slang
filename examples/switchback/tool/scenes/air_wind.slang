// tool/scenes/air_wind: the valley's wind from calm to a gale, thirty
// seconds in each of four places: a meadow, a conifer wood, a broadleaf
// wood, a bare ridge (its strength doubles every six seconds, with the
// game's gusts on it: the bands should swell and fall, never stand).
// Arguments: one place's name, for that place alone; then a strength
// (0 to 1), for a wind that stays about it instead of rising.
local math = require("slang/math")

local PLACES = {"meadow", "conifer", "broadleaf", "ridge"}

return func(kit, args){
  local world = require("tool/scenes/air_kit")
  local places = PLACES
  if(args[0] != null){
    places = {args[0]}
  }
  local steady = null
  if(args[1] != null){
    steady = require("slang/string").to_number(args[1])
  }
  return world.hear(kit, 30 * len(places), {"air"}, func(t, frame){
    local a = frame.around
    local place = places[math.min(to_int(t / 30), len(places) - 1)]
    a.trees.conifer = 0
    a.trees.broadleaf = 0
    a.trees.bush = 0
    a.cover.grass = 0
    a.alpine = 0
    a.shelter = 0
    if(place == "meadow"){
      a.cover.grass = 1
      a.trees.broadleaf = 0.08
    } else if(place == "conifer"){
      a.trees.conifer = 1
      a.cover.grass = 0.3
      a.shelter = 0.45
    } else if(place == "broadleaf"){
      a.trees.broadleaf = 0.9
      a.trees.bush = 0.4
      a.cover.grass = 0.4
      a.shelter = 0.45
    } else {
      a.alpine = 1
    }
    local local_t = t - 30 * to_int(t / 30)
    world.blow(a, t, steady or 0.03 * math.exp(local_t / 30 * math.log(20)))
  })
}
