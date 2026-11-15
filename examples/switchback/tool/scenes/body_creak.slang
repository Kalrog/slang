// tool/scenes/body_creak: the frame's creak by hand: the axles twisting
// slowly (single slips), faster (a groan), and back; then four short
// creaks as they come at a crawl over rocks. The truck stands; the
// listener is behind it.
local math = require("slang/math")

return func(kit, args){
  return kit.mix(12, func(t, set, send){
    for(let local name in values({
      "mid", "roof", "tail", "front", "knock", "brush", "hook", "work"
    })){
      set(concat("body_", name, "_left"), 0.62)
      set(concat("body_", name, "_right"), 0.62)
    }
    local level = 0
    local rate = 0
    if(t > 1 and t < 6){
      // the twist's speed up to 0.2 m/s and back
      local speed = 0.2 * math.sin((t - 1) / 5 * math.pi)
      level = math.min(speed / 0.016, 1)
      rate = 6 + 400 * speed
    } else if(t > 7){
      // a third of a second every second, at 0.05 m/s
      local k = t - math.floor(t)
      if(k < 0.35){
        level = math.sin(k / 0.35 * math.pi)
        rate = 26
      }
    }
    set("body_creak", level)
    set("body_creak_rate", rate)
  }, {only: {"body"}})
}
