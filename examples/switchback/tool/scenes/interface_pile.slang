// tool/scenes/interface_pile: the interface's sounds piled up, to see
// that nothing clips, clicks or goes on forever when much happens at
// once: the bar moved on every frame for a second (no player is that
// fast); every sound in one frame; every jingle in one frame (they wait
// for each other, and those that would wait too long are left out); a
// camp found, the truck mended a moment later and a marker reached right
// after; the summit with the menus rattling over it and the truck put
// back on its wheels twice. Through the mixer and the master at full
// volume.
local str = require("slang/string")
local layer = require("sound/layers/interface")
local jingles = require("sound/jingles")

local func menu(what){
  return {kind: "menu", what: what}
}

local func all(list){
  local events = {}
  for(let local entry in values(list)){
    append(events, menu(entry.name))
  }
  return events
}

// what happens, and when (s)
local PLAN = {
  {at: 5, what: "every sound at once", events: all(layer.sounds)},
  {at: 7, what: "every jingle at once", events: all(jingles.list)},
  {
    at: 17, what: "a camp found",
    events: {{kind: "camp", name: "Larch Camp", new: true}}
  },
  {at: 17.2, what: "mended", events: {{kind: "mended", name: "Larch Camp"}}},
  {at: 17.6, what: "arrived", events: {{kind: "arrived", name: "Marker 1"}}},
  {
    at: 25,
    what: "the summit, the menus over it",
    events: {{kind: "finish", time: 600}},
  },
  {at: 25.7, what: "recovered", events: {{kind: "recover"}}},
  {at: 26.4, what: "recovered", events: {{kind: "recover"}}},
}

return func(kit, args){
  local w = layer.watcher()
  local next = 0
  local frame = 0
  return kit.mix(34, func(t, set, send){
    set("master", 1)
    local events = {}
    frame = frame + 1
    if(t >= 3 and t < 4){
      append(events, menu("move"))
    } else if(t >= 25.2 and t < 27.2 and frame % 6 == 0){
      append(events, menu(if(frame % 12 == 0){ "select" } else { "move" }))
    }
    if(next < len(PLAN) and t >= PLAN[next].at){
      print(str.format("%6.2f", t), " s: ", PLAN[next].what, "\n")
      for(let local e in values(PLAN[next].events)){
        append(events, e)
      }
      next = next + 1
    }
    if(len(events) > 0){
      layer.watch(w, {events: events}, set, send)
    }
  }, {only: {"interface"}})
}
