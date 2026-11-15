// sound/space: the place as the game sees it, for sound/place.dsp: how
// much the ground gives back, the two walls whose echoes are heard most
// and where they stand for the listener, how much the woods and the
// rock around scatter. From sound/around, once a frame.
local math = require("slang/math")

local m = {}

local RATE = 48000
local SOUND = 343     // m/s

m.params = {
  {"space_ground", 0.25, 0.3},
  {"space_ground_delay", 44, 0.1},
  {"space_wall1_delay", 4000, 0},
  {"space_wall1_left", 0, 0.25},
  {"space_wall1_right", 0, 0.25},
  {"space_wall2_delay", 6000, 0},
  {"space_wall2_left", 0, 0.25},
  {"space_wall2_right", 0, 0.25},
  {"space_tail", 0.12, 0.5},
  {"space_size", 0.3, 0.5},
  {"space_damp", 0.5, 0.5},
}

// watcher() -> the walls it follows: an echo keeps its wall while that
// one is heard (a wall that changed places would jump)
func m.watcher(){
  return {first: null, second: null}
}

// how loud a wall's echo is beside the sound itself: only what is
// steep throws sound back (a hillside scatters it up and away), rock
// keeps about half of it, and the way there and back is longer than the
// way straight to the ears
local func heard(wall){
  if(wall.distance > 96){
    return 0
  }
  // (the rise over the twenty meters behind its foot: 1 is 45 degrees)
  local steep = math.min(math.max((wall.rise / 20 - 0.5) / 0.7, 0), 1)
  return steep * 0.55 * math.min(7.5 / (2 * wall.distance), 1)
}

// watch(w, s, set): a frame (s: sound/director's Frame, with around)
func m.watch(w, s, set){
  local a = s.around
  local view = s.view
  local c = a.cover
  // the ground: rock and gravel give back, a meadow less, snow nearly
  // nothing; the way down and up again by how high the ears are over it
  local hard = c.rock * 0.4 + c.loose * 0.32 + c.wet * 0.28 + c.grass * 0.18 + c.snow * 0.06
  set("space_ground", hard)
  local ears = math.max(a.height - a.ground, 0.5)
  local away = 7.5
  local source = 0.5
  local longer = math.sqrt(away * away + (ears + source) * (ears + source)) -
    math.sqrt(away * away + (ears - source) * (ears - source))
  set("space_ground_delay", longer / SOUND * RATE)
  // the two walls heard best; one that is followed already stays (in its
  // slot) while it is heard at all
  local best = null
  local next = null
  for(let local wall in values(a.walls)){
    local h = heard(wall)
    if(h <= 0.02){
      continue
    }
    if(best == null or h > heard(best)){
      next = best
      best = wall
    } else if(next == null or h > heard(next)){
      next = wall
    }
  }
  if(w.first != null and (w.first == next or (w.second == best and best != null))){
    local t = best
    best = next
    next = t
  }
  w.first = best
  w.second = next
  local snow = 1 - 0.7 * c.snow
  local slots = {{best, "space_wall1"}, {next, "space_wall2"}}
  for(let local e in values(slots)){
    local wall = e[0]
    local name = e[1]
    if(wall == null){
      set(concat(name, "_left"), 0)
      set(concat(name, "_right"), 0)
      continue
    }
    local level = heard(wall) * snow
    // where it stands for the listener: more on the side it is on
    local side = wall.x * view.right.x + wall.z * view.right.z
    local angle = (side * 0.85 + 1) * math.pi / 4
    set(concat(name, "_delay"), math.max(wall.distance * 2 / SOUND * RATE, 200))
    set(concat(name, "_left"), level * math.cos(angle))
    set(concat(name, "_right"), level * math.sin(angle))
  }
  // the tail: barely there in the open, woods scatter a little, steep
  // rock on several sides makes a gorge
  local closed = 0
  for(let local wall in values(a.walls)){
    if(wall.distance <= 96){
      closed = closed + math.min(math.max((wall.rise / 20 - 0.5) / 0.7, 0), 1) / 8
    }
  }
  local woods = math.min(a.trees.conifer + a.trees.broadleaf, 1)
  set("space_tail", math.min(0.12 + 0.3 * woods + 0.7 * closed, 1) * snow)
  set("space_size", math.min(0.2 + 0.3 * woods + 0.7 * closed, 1))
  set("space_damp", math.min(0.35 + 0.4 * woods + 0.6 * c.snow, 1))
}

return m
