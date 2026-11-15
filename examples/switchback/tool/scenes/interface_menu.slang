// tool/scenes/interface_menu: a player in the menus, at the pace of one:
// down the title's entries to the garage, some parts and paints changed,
// back, the volume set a few steps, into the game; a pause, the map from
// it, markers set, one followed, one taken away, the map's other side,
// the map closed. The menus' events as main.slang reports them
// ({kind: "menu", what}), handed to the interface's watch; through the
// mixer and the master (at full volume, so that the levels are the
// bus's).
local str = require("slang/string")
local layer = require("sound/layers/interface")

// what the player does, and how long after the last thing (s)
local SESSION = {
  // the title: down to the garage
  {0.50, "move"},
  {0.32, "move"},
  {0.55, "select"},
  // the garage: bumper, roof load, paint
  {0.70, "move"},
  {0.28, "move"},
  {0.30, "move"},
  {0.60, "part"},
  {0.45, "part"},
  {0.50, "move"},
  {0.40, "part"},
  {0.22, "part"},
  {0.20, "part"},
  {0.70, "move"},
  {0.25, "move"},
  {0.25, "move"},
  {0.24, "move"},
  {0.55, "paint"},
  {0.50, "paint"},
  {0.42, "paint"},
  {0.90, "back"},
  // the title again: the volume down three steps and up one, then off
  // to explore
  {0.60, "move"},
  {0.30, "move"},
  {0.50, "step"},
  {0.30, "step"},
  {0.28, "step"},
  {0.70, "step"},
  {0.80, "move"},
  {0.26, "move"},
  {0.24, "move"},
  {0.25, "move"},
  {0.22, "move"},
  {0.60, "select"},
  // later: a pause, the map from its menu
  {2.50, "pause"},
  {0.70, "move"},
  {0.50, "select"},
  {0.05, "open"},
  // markers: two set, the second followed, the first taken away, the
  // other view, closed
  {1.40, "pin"},
  {1.10, "pin"},
  {0.90, "follow"},
  {1.30, "unpin"},
  {1.00, "view"},
  {0.90, "view"},
  {0.80, "close"},
  // a marker too many, and following stopped
  {1.50, "open"},
  {0.90, "deny"},
  {1.00, "unfollow"},
  {0.80, "close"},
}

return func(kit, args){
  local w = layer.watcher()
  local next = 0
  // (the first thing after the master has come up)
  local due = 3.0
  local total = due + 1.5
  for(let local step in values(SESSION)){
    total = total + step[0]
  }
  return kit.mix(total, func(t, set, send){
    set("master", 1)
    if(next < len(SESSION) and t >= due + SESSION[next][0]){
      local step = SESSION[next]
      next = next + 1
      due = due + step[0]
      layer.watch(w, {events: {{kind: "menu", what: step[1]}}}, set, send)
      print(str.format("%6.2f", t), " s: ", step[1], "\n")
    }
  }, {only: {"interface"}})
}
