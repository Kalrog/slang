// tool/scenes/body_bush: the truck driven through a bush in the real
// game: it is put down nine meters from a big bush on even ground (the
// first one found with nothing solid in the way), looking at it, and
// driven straight on at half throttle for eight seconds.
// Arguments: seed (25), then the layers to hear (the body alone when
// none are given).
local math = require("slang/math")
local str = require("slang/string")

return func(kit, args){
  local world = require("game/world")
  local plants = require("game/plants")
  local terrain = require("game/terrain")
  local only = {}
  for(local i = 1; i < len(args); i = i + 1){
    append(only, args[i])
  }
  if(len(only) == 0){
    only = {"body"}
  }
  // a bush to drive at: {x, z, yaw} of where the truck starts
  local func find(w){
    local p = w.plants
    for(let local chunk in values(p.chunks)){
      local d = chunk.data
      for(local r = chunk.starts[7]; r < chunk.starts[8]; r = r + 1){
        local at = r * plants.STRIDE
        local bx = d[at + plants.X]
        local bz = d[at + plants.Z]
        // (a big one, on dry land, well inside the map: at its edge the
        // truck is towed back)
        local inside = math.max(math.abs(bx), math.abs(bz)) < w.land.half - 150
        if(inside and d[at + plants.SCALE] > 1.1 and
          terrain.water_at(w.land, bx, bz) < 0.05){
          local here = terrain.height_at(w.land, bx, bz)
          for(local turn = 0; turn < 8; turn = turn + 1){
            local yaw = turn * math.pi / 4
            // (the truck looks along +z turned by yaw: from behind the
            // bush to beyond it)
            local fx = math.sin(yaw)
            local fz = math.cos(yaw)
            local even = true
            for(local step = -9; step <= 8; step = step + 3){
              local h = terrain.height_at(
                w.land, bx + fx * step, bz + fz * step
              )
              even = even and math.abs(h - here) < 0.07 * math.abs(step) + 0.15
            }
            local clear = true
            for(let local c in values(plants.near(p, bx, bz, 14))){
              for(let local solid in values(plants.solids(p, c))){
                local sx = solid.position.x - bx
                local sz = solid.position.z - bz
                local along = sx * fx + sz * fz
                local across = math.abs(sx * fz - sz * fx)
                clear = clear and
                  not(along > -12 and along < 12 and across < 3.5)
              }
            }
            if(even and clear){
              return {x: bx - fx * 9, z: bz - fz * 9, yaw: yaw}
            }
          }
        }
      }
    }
    return null
  }
  return kit.drive({
    seed: to_int(str.to_number(args[0] or "25")),
    seconds: 10,
    only: only,
    before: func(w){
      local spot = find(w)
      if(spot == null){
        print("body_bush: no bush on even ground found\n")
        return
      }
      world.place(w, {x: spot.x, z: spot.z}, spot.yaw)
    },
    input: func(t, w, input){
      return {forward: if(t > 2.2 and t < 9){ 0.5 } else { 0 }, steer: 0}
    },
  })
}
