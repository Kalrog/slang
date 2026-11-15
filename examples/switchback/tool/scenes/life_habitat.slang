// tool/scenes/life_habitat: standing still somewhere in the valley and
// listening to what lives there (the life layer alone, through the
// mixer): the place is made up (what sound/around would say of it), no
// world is needed.
//
// Arguments: the place (wood by default), the seconds (120), the seed
// of who lives there (7), and "turn" for a camera that turns slowly.
//
//   wood      a broadleaf wood          conifer   a conifer wood
//   edge      a meadow at a wood's edge meadow    an open meadow low down
//   high      a high meadow             rock      bare rock up high
//   snow      a snow field              gale      the broadleaf wood in a gale
//
// Prints every song (when, who, how far, on which side), the songs a
// minute of every kind, and how regular the pauses between songs are.
//
// With "census" as the place nothing is rendered: every place is
// listened to for ten minutes by six seeds, and the songs a minute of
// every kind are printed, place by place.
local math = require("slang/math")
local str = require("slang/string")
local params = require("sound/params")
local life = require("sound/life")

// what sound/around says of each place
local PLACES = {
  wood: func(a){
    a.trees.broadleaf = 0.9
    a.trees.bush = 0.3
    a.cover.grass = 0.6
    a.cover.loose = 0.4
  },
  conifer: func(a){
    a.trees.conifer = 0.9
    a.alpine = 0.2
    a.cover.grass = 0.3
    a.cover.loose = 0.7
  },
  edge: func(a){
    a.trees.broadleaf = 0.25
    a.trees.bush = 0.2
    a.cover.grass = 0.9
    a.cover.loose = 0.1
  },
  meadow: func(a){
    a.trees.broadleaf = 0.04
    a.trees.bush = 0.05
    a.cover.grass = 1
  },
  high: func(a){
    a.alpine = 0.75
    a.cover.grass = 0.7
    a.cover.rock = 0.3
    a.wind.steady = 0.3
    a.wind.strength = 0.35
  },
  rock: func(a){
    a.alpine = 0.9
    a.cover.rock = 1
    a.wind.steady = 0.35
    a.wind.strength = 0.4
  },
  snow: func(a){
    a.alpine = 1
    a.cover.snow = 1
    a.wind.steady = 0.4
    a.wind.strength = 0.45
  },
  gale: func(a){
    a.trees.broadleaf = 0.9
    a.cover.grass = 0.6
    a.wind.steady = 0.9
    a.wind.strength = 0.95
  },
}

// the songs a minute of every kind at every place, without their sound
local func census(kit){
  local kernel = require("kernel")
  local around = require("sound/around")
  local layer = require("sound/layers/life")
  local view = {eye: {x: 0, y: 2.5, z: 0}, forward: {x: 0, y: 0, z: 1}, right: {x: -1, y: 0, z: 0}}
  local seeds = 6
  local minutes = 10
  for(let local place in values({"wood", "conifer", "edge", "meadow", "high", "rock", "snow", "gale"})){
    local counts = {}
    for(local i = 0; i < len(life.CAST); i = i + 1){
      append(counts, 0)
    }
    local total = 0
    local least = 1.0e9
    local most = 0
    for(local seed = 1; seed <= seeds; seed = seed + 1){
      local a = around.new()
      a.height = 2.5
      PLACES[place](a)
      local w = layer.watcher(seed)
      for(local f = 0; f < minutes * 3600; f = f + 1){
        layer.watch(w, {around: a, view: view, dt: 1 / 60}, func(name, value){}, func(kind, x, y, z){})
      }
      local sum = 0
      for(local i = 0; i < len(life.CAST); i = i + 1){
        counts[i] = counts[i] + w.sung[i]
        sum = sum + w.sung[i]
      }
      total = total + sum
      least = math.min(least, sum / minutes)
      most = math.max(most, sum / minutes)
    }
    print(str.format("%-8s %5.1f a minute (%.1f to %.1f):", place, total / seeds / minutes, least, most))
    for(local i = 0; i < len(life.CAST); i = i + 1){
      if(counts[i] > 0){
        print(" ", life.CAST[i].name, " ", str.format("%.1f", counts[i] / seeds / minutes))
      }
    }
    print("\n")
  }
  return {channels: {kernel.float:array(kit.RATE)}, load: 0}
}

return func(kit, args){
  local director = require("sound/director")
  local mixer = require("sound/mixer")
  local around = require("sound/around")
  local layer = require("sound/layers/life")
  local place = args[0] or "wood"
  if(place == "census"){
    return census(kit)
  }
  local seconds = str.to_number(args[1] or "120")
  local seed = to_int(str.to_number(args[2] or "7"))
  local turn = args[3] == "turn"
  if(PLACES[place] == null){
    raise(error.new(error.kinds.argument, concat("life_habitat: no place ", place)))
  }
  local sound = director.offline()
  local costs = mixer.costs()
  local block = mixer.new(sound.shared.values, sound.shared.events, {
    sample_rate: kit.RATE, block: kit.BLOCK, only: {"life"}, costs: costs,
  })
  sound.set("awake", 1)
  local a = around.new()
  a.height = 2.5
  PLACES[place](a)
  local w = layer.watcher(seed)
  local view = {eye: {x: 0, y: 2.5, z: 0}, forward: {x: 0, y: 0, z: 1}, right: {x: -1, y: 0, z: 0}}
  // every song as it is sent: when, who, where
  local base = params.EVENTS.life
  local songs = {}
  local send = func(kind, x, y, z){
    sound.send(kind, x, y, z)
    if(kind >= base and kind < base + len(life.CAST)){
      append(songs, {at: w.time, member: kind - base, voice: to_int(x)})
    }
  }
  local seen = 0
  local r = kit.run(seconds, block, func(t, dt){
    if(turn){
      local angle = t * 0.1
      view.forward.x = math.sin(angle)
      view.forward.z = math.cos(angle)
      view.right.x = -view.forward.z
      view.right.z = view.forward.x
    }
    layer.watch(w, {around: a, view: view, dt: dt}, sound.set, send)
    for(seen < len(songs)){
      local song = songs[seen]
      local g = w.voices[song.voice].singer
      local dx = g.x - view.eye.x
      local dy = g.y - view.eye.y
      local dz = g.z - view.eye.z
      song.far = math.sqrt(dx * dx + dy * dy + dz * dz)
      song.side = (dx * view.right.x + dz * view.right.z) / math.max(song.far, 0.001)
      seen = seen + 1
    }
  })
  r.costs = costs
  // what was sung
  local counts = {}
  for(local i = 0; i < len(life.CAST); i = i + 1){
    append(counts, 0)
  }
  local last = null
  local pauses = {}
  for(let local song in values(songs)){
    counts[song.member] = counts[song.member] + 1
    print(str.format("%7.2f s  %-10s %5.0f m  %s\n", song.at, life.CAST[song.member].name, song.far,
      if(song.side < -0.25){ "left" } else if(song.side > 0.25){ "right" } else { "middle" }))
    if(last != null){
      append(pauses, song.at - last)
    }
    last = song.at
  }
  print("life_habitat: ", place, ", ", string(len(songs)), " songs in ", string(seconds), " s (",
    str.format("%.1f", len(songs) * 60 / seconds), " a minute):")
  for(local i = 0; i < len(life.CAST); i = i + 1){
    if(counts[i] > 0){
      print(" ", life.CAST[i].name, " ", string(counts[i]))
    }
  }
  print("\n")
  if(len(pauses) > 2){
    // the pauses between the starts of songs: an even beat has a spread
    // near 0, songs that come as they like one near 1 and over
    local sum = 0
    local longest = 0
    local shortest = 1.0e9
    for(let local p in values(pauses)){
      sum = sum + p
      longest = math.max(longest, p)
      shortest = math.min(shortest, p)
    }
    local mean = sum / len(pauses)
    local spread = 0
    for(let local p in values(pauses)){
      spread = spread + (p - mean) * (p - mean)
    }
    spread = math.sqrt(spread / len(pauses)) / mean
    print("life_habitat: between songs ", str.format("%.1f", shortest), " to ", str.format("%.1f", longest),
      " s, ", str.format("%.1f", mean), " s on average, spread ", str.format("%.2f", spread), "\n")
  }
  return r
}
