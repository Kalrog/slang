// tool/scenes/body_knocks: knocks by hand, a second apart, each harder
// than the last: 0.15, 0.25, 0.4, 0.6 (it starts to do damage), 0.9, 1.3,
// 2, 4 and 10 m/s (a crash), first from below (a landing: the thud
// leads), then from 10 s on from the side (a rock, a tree: the panel
// clangs). Then, from 20 s, a landing as the game has it: a row of
// knocks a frame apart, of which only the hardest are heard. The truck
// stands; the listener is behind it.
local body = require("sound/layers/body")

local STRENGTHS = {0.15, 0.25, 0.4, 0.6, 0.9, 1.3, 2, 4, 10}

return func(kit, args){
  local at = 0
  local script = {}
  for(local i = 0; i < len(STRENGTHS); i = i + 1){
    append(script, {1 + i, STRENGTHS[i], 1})
  }
  for(local i = 0; i < len(STRENGTHS); i = i + 1){
    append(script, {11 + i, STRENGTHS[i], 0.1})
  }
  // (what the watcher would send of a landing at 18 m/s: see body_drive)
  append(script, {21, 0.31, 0.9})
  append(script, {21.1, 0.73, 0.9})
  return kit.mix(23, func(t, set, send){
    for(let local name in values({
      "mid", "roof", "tail", "front", "knock", "brush", "hook", "work"
    })){
      set(concat("body_", name, "_left"), 0.62)
      set(concat("body_", name, "_right"), 0.62)
    }
    for(at < len(script) and script[at][0] <= t){
      send(body.KNOCK, script[at][1], script[at][2])
      at = at + 1
    }
  }, {only: {"body"}})
}
