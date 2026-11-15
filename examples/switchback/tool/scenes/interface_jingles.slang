// tool/scenes/interface_jingles: the jingles as the game brings them
// about: the rules' events (game/explore's and game/run's) handed to the
// interface's watch, one every few seconds, through the mixer and the
// master (at full volume, so that the levels are the bus's): a camp
// found, the same camp come back to, the truck mended, a checkpoint
// ahead of the best time, one without a best time, one behind, the last
// checkpoint with the summit, a marker reached, a breakdown, a wreck, a
// recovery, and a trail's and a section's name (which have no sound).
//
// It prints when each event is sent, and for a jingle its notes ("cue":
// when in the file, the instrument, the note's number and its
// frequency), for measuring their pitches.
local str = require("slang/string")
local layer = require("sound/layers/interface")
local jingles = require("sound/jingles")

// what happens, and when (s)
local PLAN = {
  {
    at: 3.0, events: {{kind: "camp", name: "Larch Camp", new: true}},
    jingle: "camp_found"
  },
  {
    at: 8.5, events: {{kind: "camp", name: "Larch Camp", new: false}},
    jingle: "camp"
  },
  {at: 11.5, events: {{kind: "mended", name: "Larch Camp"}}, jingle: "mended"},
  {
    at: 14.5,
    events: {
      {kind: "checkpoint", name: "The Ford", time: 81.2, delta: -2.1, index: 1},
    },
    jingle: "ahead",
  },
  {
    at: 18.0,
    events: {{kind: "checkpoint", name: "The Ford", time: 81.2, index: 1}},
    jingle: "passed",
  },
  {
    at: 21.5,
    events: {
      {kind: "checkpoint", name: "The Ford", time: 81.2, delta: 3.2, index: 1},
    },
    jingle: "behind",
  },
  {
    at: 25.0,
    events: {
      {kind: "checkpoint", name: "Summit", time: 640.5, delta: -4, index: 6},
      {kind: "finish", time: 640.5, new_best: true},
    },
    jingle: "summit",
  },
  {at: 31.0, events: {{kind: "arrived", name: "Marker 1"}}, jingle: "arrived"},
  {
    at: 35.0,
    events: {
      {kind: "knock", strength: 3, harm: 0.4},
      {kind: "breakdown", camp: "Larch Camp"},
    },
    jingle: "broken",
  },
  {at: 38.5, events: {{kind: "wreck"}}, jingle: "broken"},
  {at: 42.0, events: {{kind: "recover"}}},
  {at: 43.5, events: {{kind: "trail", name: "Lakeside Trail"}}},
  {at: 45.0, events: {{kind: "section", name: "Rock Steps"}}},
}

return func(kit, args){
  local w = layer.watcher()
  local next = 0
  return kit.mix(46.5, func(t, set, send){
    set("master", 1)
    if(next < len(PLAN) and t >= PLAN[next].at){
      local step = PLAN[next]
      next = next + 1
      layer.watch(w, {events: step.events}, set, send)
      print(
        str.format("%6.2f", t),
        " s: ",
        step.events[len(step.events) - 1].kind,
        "\n",
      )
      if(step.jingle != null){
        for(let local note in values(jingles.by_name[step.jingle].notes)){
          print(
            "cue ", step.jingle, " ", str.format("%.3f", t + note.at), " ",
            note.play, " ", note.note, " ",
            str.format("%.3f", jingles.hz(note.note)), "\n"
          )
        }
      }
    }
  }, {only: {"interface"}})
}
