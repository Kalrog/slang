// tool/scenes/life_drive: what lives in the valley as the game has it:
// the bot drives the Summit Run for a while, stops, and the truck stands
// with its engine idling while the camera behind it listens. Who lives
// where comes from the real land (the game's trees and meadows), and the
// truck's noise frightens what is near.
//
// Arguments: the valley's seed (25), where on the trail to start, m (0),
// the seconds in all (120), the second at which the truck stops (30;
// more than the seconds: it drives on), then any of: other layers to
// hear with it ("engine tires"), "heavy" for a heavy foot, "seed=" with
// a number for who lives there (7), and last "who" to have the singers
// about listed with the place.
//
// Prints the place every twenty seconds (what sound/around says of it,
// and how many singers are about), every song (when, who, how far, on
// which side, how loud the truck was), and the songs of every kind.
//
// With "survey" as the second argument nothing is driven and nothing
// worth hearing rendered: the truck is set down every 150 m along the
// trail, and what is around and who lives within earshot is printed,
// place by place: the valley's life as a table.
local math = require("slang/math")
local str = require("slang/string")
local params = require("sound/params")
local life = require("sound/life")

// the valley's life along the Summit Run, as a table
local func survey(kit, seed, who){
  local layer = require("sound/layers/life")
  local world_lib = require("game/world")
  local w = null
  local at = 0
  local frames = 0
  local done = false
  return kit.drive({
    seed: seed, seconds: 30, only: {"life"},
    input: func(t, world, input){
      return {}
    },
    each: func(t, world, sound){
      if(w == null){
        w = layer.watcher(who)
        sound.by_name.life.state = w
      }
      frames = frames + 1
      if(frames % 24 != 0 or done){
        return
      }
      // what is here
      local a = sound.around
      local view = kit.behind(world.car, 7.6, 2.5)
      local kinds = {}
      for(local i = 0; i < len(life.CAST); i = i + 1){
        append(kinds, 0)
      }
      for(let local g in values(w.singers)){
        local dx = g.x - view.eye.x
        local dy = g.y - view.eye.y
        local dz = g.z - view.eye.z
        if(dx * dx + dy * dy + dz * dz <= g.bird.hear * g.bird.hear){
          kinds[g.member] = kinds[g.member] + 1
        }
      }
      // (the steepest rock near: how high it stands)
      local cliff = 0
      for(let local wall in values(a.walls)){
        if(wall.distance <= 96){
          cliff = math.max(cliff, wall.rise)
        }
      }
      print(str.format(
        "%5d m (%.0f %.0f), %3.0f m up: broadleaf %.2f conifer %.2f bush %.2f, grass %.2f rock %.2f snow %.2f, alpine %.2f, wind %.2f, cliff %.0f m, insects %.2f; in earshot:",
        at, world.car.pos.x, world.car.pos.z, a.ground, a.trees.broadleaf, a.trees.conifer, a.trees.bush, a.cover.grass, a.cover.rock, a.cover.snow,
        a.alpine, a.wind.steady, cliff, sound.shared.values[params.layout().slot.life_crickets]
      ))
      for(local i = 0; i < len(life.CAST); i = i + 1){
        if(kinds[i] > 0){
          print(" ", string(kinds[i]), " ", life.CAST[i].name)
        }
      }
      print("\n")
      // and on to the next place
      at = at + 150
      if(to_int(at / 2) >= len(world.trail.points)){
        done = true
      } else {
        world_lib.recover(world, to_int(at / 2))
      }
    },
  })
}

return func(kit, args){
  local layer = require("sound/layers/life")
  local seed = to_int(str.to_number(args[0] or "25"))
  if(args[1] == "survey"){
    return survey(kit, seed, 7)
  }
  local from = str.to_number(args[1] or "0")
  local seconds = str.to_number(args[2] or "120")
  local stop = str.to_number(args[3] or "30")
  local only = {"life"}
  local heavy = false
  local who = 7
  for(local i = 4; i < len(args); i = i + 1){
    if(args[i] == "heavy"){
      heavy = true
    } else if(args[i] == "who"){
      // (the singers about are listed with the place)
    } else if(str.starts_with(args[i], "seed=")){
      who = to_int(str.to_number(str.sub(args[i], 5)))
    } else {
      append(only, args[i])
    }
  }
  local base = params.EVENTS.life
  local songs = {}
  local w = null
  local seen = 0
  local told = -100
  local r = kit.drive({
    seed: seed, from: from, seconds: seconds, heavy: heavy, only: only,
    input: func(t, world, input){
      if(t < stop){
        return input
      }
      // brake to a stand; the truck holds itself there
      if(world.car.speed > 0.8){
        return {back: 1}
      }
      return {}
    },
    each: func(t, world, sound){
      if(w == null){
        // who lives here is the same every time: the layer's state with
        // a seed of ours, and the songs it sends written down
        w = layer.watcher(who)
        sound.by_name.life.state = w
        local send = sound.send
        sound.send = func(kind, x, y, z){
          send(kind, x, y, z)
          if(kind >= base and kind < base + len(life.CAST)){
            append(songs, {at: t, member: kind - base, voice: to_int(x)})
          }
        }
      }
      local view = kit.behind(world.car, 7.6, 2.5)
      for(seen < len(songs)){
        local song = songs[seen]
        song.at = w.time
        local g = w.voices[song.voice].singer
        local dx = g.x - view.eye.x
        local dy = g.y - view.eye.y
        local dz = g.z - view.eye.z
        song.far = math.sqrt(dx * dx + dy * dy + dz * dz)
        song.side = (dx * view.right.x + dz * view.right.z) / math.max(song.far, 0.001)
        song.noise = w.noise
        print(str.format("%7.2f s  %-10s %5.0f m  %-6s truck %.2f\n", song.at, life.CAST[song.member].name, song.far,
          if(song.side < -0.25){ "left" } else if(song.side > 0.25){ "right" } else { "middle" }, song.noise))
        seen = seen + 1
      }
      if(t - told >= 20){
        told = t
        local a = sound.around
        print(str.format(
          "%7.2f s  at %.0f %.0f, %.0f km/h: broadleaf %.2f conifer %.2f bush %.2f, grass %.2f rock %.2f snow %.2f, alpine %.2f, wind %.2f, water %.0f m; %d singers, awake %.2f\n",
          t, world.car.pos.x, world.car.pos.z, world.car.speed * 3.6, a.trees.broadleaf, a.trees.conifer, a.trees.bush,
          a.cover.grass, a.cover.rock, a.cover.snow, a.alpine, a.wind.strength, a.water.distance, len(w.singers),
          w.activity * w.calm
        ))
        if(args[len(args) - 1] == "who"){
          for(let local g in values(w.singers)){
            local dx = g.x - view.eye.x
            local dz = g.z - view.eye.z
            print(str.format("             %-10s %4.0f m, sings in %5.1f s, %d left, hushed %4.1f s\n", g.bird.name,
              math.sqrt(dx * dx + dz * dz), g.next - w.time, g.left, math.max(g.hush - w.time, 0)))
          }
        }
      }
    },
  })
  local counts = {}
  for(local i = 0; i < len(life.CAST); i = i + 1){
    append(counts, 0)
  }
  for(let local song in values(songs)){
    counts[song.member] = counts[song.member] + 1
  }
  print("life_drive: ", string(len(songs)), " songs in ", string(seconds), " s:")
  for(local i = 0; i < len(life.CAST); i = i + 1){
    if(counts[i] > 0){
      print(" ", life.CAST[i].name, " ", string(counts[i]))
    }
  }
  print("\n")
  return r
}
