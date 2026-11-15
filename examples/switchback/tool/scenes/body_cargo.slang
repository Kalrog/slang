// tool/scenes/body_cargo: what the truck carries, shaken by hand: every
// thing of sound/layers/body's THINGS in turn, two seconds each: a light
// shake, then a hard one (the things that bounce come down again). The
// truck stands; the listener is behind it.
local body = require("sound/layers/body")

return func(kit, args){
  local at = 0
  local script = {}
  for(local i = 0; i < len(body.THINGS); i = i + 1){
    append(script, {1 + 2 * i, i, 0.3})
    append(script, {2 + 2 * i, i, 1})
  }
  return kit.mix(2 + 2 * len(body.THINGS), func(t, set, send){
    for(let local name in values({
      "mid", "roof", "tail", "front", "knock", "brush", "hook", "work"
    })){
      set(concat("body_", name, "_left"), 0.62)
      set(concat("body_", name, "_right"), 0.62)
    }
    for(at < len(script) and script[at][0] <= t){
      send(body.RATTLE, script[at][1], script[at][2])
      at = at + 1
    }
  }, {only: {"body"}})
}
