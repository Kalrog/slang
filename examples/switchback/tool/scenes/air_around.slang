// tool/scenes/air_around: a drive of the game with the air, the water and
// the camps alone, and what sound/around says along it, a line a second
// (the place, the nearest water and camp, what grows, the wind; and what
// the water's layer makes of the river's line itself): for seeing what
// the layers are told where.
// Arguments: seed (25), from (m along the trail, 0), seconds (30), then
// any of: "stand" (the truck stands where it is put, its engine
// running), "lake" (it is put at the lake's shore, and stands), "heavy"
// (a heavy foot), "quiet" (no lines), and layers to hear instead of the
// three ("engine", "all" for every layer).
local str = require("slang/string")
local math = require("slang/math")

return func(kit, args){
  local only = null
  local heavy = false
  local stand = false
  local lake = false
  local quiet = false
  for(local i = 3; i < len(args); i = i + 1){
    if(args[i] == "heavy"){
      heavy = true
    } else if(args[i] == "stand"){
      stand = true
    } else if(args[i] == "lake"){
      stand = true
      lake = true
    } else if(args[i] == "quiet"){
      quiet = true
    } else {
      only = only or {}
      append(only, args[i])
    }
  }
  only = only or {"air", "water", "camp"}
  if(only[0] == "all"){
    only = null
  }
  local last = -1
  return kit.drive({
    seed: to_int(str.to_number(args[0] or "25")),
    from: str.to_number(args[1] or "0"),
    seconds: str.to_number(args[2] or "30"),
    heavy: heavy,
    only: only,
    before: func(world){
      // (the lake's western shore, where it is widest)
      local river = world.land.river
      if(lake and river != null and river.lake != null){
        local best = river.points[0]
        for(let local p in values(river.points)){
          if(math.abs(p.z - river.lake.z) < math.abs(best.z - river.lake.z)){
            best = p
          }
        }
        require("game/world").place(
          world, {x: best.x - best.half - 4, z: best.z}, math.pi / 2
        )
      }
    },
    input: func(t, world, input){
      if(stand){
        return {}
      }
      return input
    },
    each: func(t, world, sound){
      if(quiet or t - last < 1){
        return
      }
      last = t
      local a = sound.around
      local c = a.camp
      print(
        str.format("%5.1f", t),
        " at ",
        str.format(
          "%6.0f %4.0f %6.0f", world.car.pos.x, world.car.pos.y, world.car.pos.z
        ),
        " ",
        str.format("%4.1f", world.car.speed),
        " m/s | water ",
        str.format("%5.1f", a.water.distance),
        " m (",
        str.format("%5.2f %5.2f", a.water.x, a.water.z),
        ") flow ",
        str.format("%.2f", a.water.flow),
        " lake ",
        string(a.water.lake),
        " | conifer ",
        str.format("%.2f", a.trees.conifer),
        " broadleaf ",
        str.format("%.2f", a.trees.broadleaf),
        " bush ",
        str.format("%.2f", a.trees.bush),
        " grass ",
        str.format("%.2f", a.cover.grass),
        " alpine ",
        str.format("%.2f", a.alpine),
        " shelter ",
        str.format("%.2f", a.shelter),
        " wind ",
        str.format("%.2f", a.wind.strength),
        " | camp ",
        if(c != null){ concat(
          str.format("%.0f", c.distance), " m #", string(c.index)
        ) } else { "none" },
        " | the water's bank ",
        str.format("%.1f", sound.by_name.water.state.near.distance),
        " m, lake ",
        str.format("%.2f", sound.by_name.water.state.near.still),
        "\n",
      )
    },
  })
}
