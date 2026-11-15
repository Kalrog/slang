// tool/scenes/body_winch: the winch by hand: at 1 s the hook is set on a
// tree's strap; the drum takes the slack in; from 3 s the line pulls,
// harder and harder (the motor slows, the line creaks on the drum), from
// 7 s all it can (the drum stands, the motor strains); at 9 s the load
// goes; at 10 s the line is unhooked and runs in, 12 m of it, and the
// hook comes home. Then, at 13 s, a hook set on a ground anchor. The
// listener is behind the truck.
local math = require("slang/math")
local body = require("sound/layers/body")

return func(kit, args){
  local sent = 0
  return kit.mix(15, func(t, set, send){
    for(let local name in values({
      "mid", "roof", "tail", "front", "knock", "brush", "hook", "work"
    })){
      set(concat("body_", name, "_left"), 0.62)
      set(concat("body_", name, "_right"), 0.62)
    }
    // (the anchor is farther off than the truck)
    set("body_hook_left", 0.3)
    set("body_hook_right", 0.3)
    if(t >= 1 and sent == 0){
      send(body.HOOK, 0)
      sent = 1
    }
    if(t >= 10 and sent == 1){
      send(body.REEL, 12)
      sent = 2
    }
    if(t >= 13 and sent == 2){
      send(body.HOOK, 1)
      sent = 3
    }
    local run = 0
    local strain = 0
    if(t >= 1 and t < 10){
      strain = math.min(math.max((t - 3) / 4, 0), 1)
      if(t > 9){
        strain = 0
      }
      run = if(strain > 0.97){ 0.15 } else { 1 }
    }
    set("body_winch", run)
    set("body_strain", strain)
    set("body_line", strain * strain * math.min(run + 0.2, 1))
    set("body_line_rate", 5 + 22 * run)
  }, {only: {"body"}})
}
