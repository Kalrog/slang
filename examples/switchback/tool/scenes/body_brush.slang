// tool/scenes/body_brush: a bush taking the truck's side, by hand: three
// passes of two seconds each, at a crawl, at a trot and fast, twigs
// snapping as it goes in and through; then a low shrub with little wood.
// The listener is behind the truck.
local math = require("slang/math")
local body = require("sound/layers/body")

return func(kit, args){
  local snapped = -1
  return kit.mix(13, func(t, set, send){
    for(let local name in values({
      "mid", "roof", "tail", "front", "knock", "brush", "hook", "work"
    })){
      set(concat("body_", name, "_left"), 0.62)
      set(concat("body_", name, "_right"), 0.62)
    }
    local pass = to_int((t - 1) / 3)
    local k = t - 1 - pass * 3
    local leaves = 0
    local speed = 0
    local twigs = 0
    if(t >= 1 and pass < 4 and k < 2){
      leaves = math.sin(k / 2 * math.pi)
      speed = ({0.15, 0.5, 1, 0.5})[pass]
      twigs = if(pass == 3){ 0.3 } else { 0.6 }
      // a twig as it goes in, another halfway
      local index = pass * 2 + (if(k > 1){ 1 } else { 0 })
      if(index > snapped){
        snapped = index
        send(body.SNAP, speed * twigs)
      }
    }
    set("body_leaves", leaves)
    set("body_brush_speed", speed)
    set("body_twigs", twigs * leaves)
  }, {only: {"body"}})
}
