// tool/scenes/body_crash: crashes by hand, four seconds apart, as the
// layer's watcher sends them for the game's own truck (a rack, the spare,
// the winch's hook): at 1 s a hard knock that is a little of a crash
// (0.3), at 5 s more of one (0.6: as much as a truck takes without
// breaking), at 9 s the one that breaks it (1: the rules' "broken",
// after which the truck stands dead for two and a half seconds). With
// each, what the truck carries is thrown about at once, comes down a
// moment later, and after the big ones once more as all comes to rest.
// For comparison, at 14 s, the hardest knock that is no crash (1 m/s
// from the side). The truck stands; the listener is behind it.
local body = require("sound/layers/body")

// the things the game's own truck carries (their places in body.THINGS)
local CARRIED = {0, 6, 7, 8, 10}

return func(kit, args){
  local script = {}
  local func crash(at, amount){
    append(script, {at, body.CRASH, amount, 0.2})
    for(local k = 0; k < len(CARRIED); k = k + 1){
      append(script, {at, body.RATTLE, CARRIED[k], 1, 0})
      append(script, {at, body.RATTLE, CARRIED[k], 0.75, 0.15 + 0.11 * k})
      if(amount > 0.5){
        append(script, {at, body.RATTLE, CARRIED[k], 0.4, 0.8 + 0.27 * k})
      }
    }
  }
  crash(1, 0.3)
  crash(5, 0.6)
  crash(9, 1)
  append(script, {14, body.KNOCK, 1.0, 0.1, 0})
  local at = 0
  return kit.mix(16, func(t, set, send){
    for(let local name in values({
      "mid",
      "roof",
      "tail",
      "front",
      "knock",
      "brush",
      "hook",
      "work",
      "corner1",
      "corner2",
      "corner3",
      "corner4",
    })){
      set(concat("body_", name, "_left"), 0.62)
      set(concat("body_", name, "_right"), 0.62)
    }
    for(at < len(script) and script[at][0] <= t){
      local e = script[at]
      send(e[1], e[2], e[3], e[4] or 0)
      at = at + 1
    }
  }, {only: {"body"}})
}
