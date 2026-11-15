// sound/layers/life: what lives in the valley and is heard (sound/life:
// the cast and its songs) in the game: birds in the woods, a cuckoo far
// off, a buzzard over the valley, a raven at the cliffs, marmots on the
// high meadows, a bumblebee now and then, and the meadows' crickets and
// grasshoppers as a quiet bed.
//
// The game's side owns the singers. The land is cut into squares, and a
// square has a singer or not, always the same one for a valley and a
// session: a bird sits in a tree that stands there (the game's own
// trees, where the world is known), a marmot on the grass of a high
// meadow. Every singer keeps its own time: it sings a bout of songs with
// pauses between them, rests, and starts again; when the truck roars
// close by or crashes it falls silent for a while, and in a gale nobody
// sings. A
// song is one event to the mixer; from then on the game only says, every
// frame, how loud the singer is on the left and the right and how much
// the air between has dulled it.
//
// The mixer's side has a handful of voices. A voice composes the song it
// is told to sing (sound/life.compose: the same song the game's side
// composed to know its length) and hands its syllables, one at a time
// and each on its sample, to a whistle or a rough voice
// (sound/life/whistle.dsp, rough.dsp). The insects are one program
// (sound/life/insects.dsp) whose crickets and grasshoppers the voice
// turns up and down.
local math = require("slang/math")
local kernel = require("kernel")
local listener = require("sound/listener")
local params = require("sound/params")
local life = require("sound/life")

local m = {}

// how many songs can sound at once
local VOICES = 6

// a song's level on the world's bus when its singer is as far away as
// its kind reaches (half of that or nearer: twice this, and no more:
// nothing in the valley is piercing). Quiet: a call is a detail in the
// wind and the water, heard once the truck stands
local LEVEL = 0.007
// the insects' level
local BED = 0.0045

// from the game's word to a song's first sound, s (the voice's gains
// arrive meanwhile), and how long after its last sound the game keeps a
// voice (the mixer hears the word a little late)
local LEAD = 0.12
local KEEP = 0.25

m.params = {
  // how much of the meadow's crickets and grasshoppers is awake, 0 to 1
  {"life_crickets", 0, 0.5},
  {"life_hoppers", 0, 0.5},
}
// each voice's gains and what the air leaves of it (a lowpass, Hz)
local VOICE_NAMES = {}
for(local k = 0; k < VOICES; k = k + 1){
  local names = {
    left: concat("life_", string(k), "_left"),
    right: concat("life_", string(k), "_right"),
    far: concat("life_", string(k), "_far"),
  }
  append(VOICE_NAMES, names)
  append(m.params, {names.left, 0, 0.04})
  append(m.params, {names.right, 0, 0.04})
  append(m.params, {names.far, 16000, 0.1})
}
// the gains of the insects' three places
local BED_NAMES = {}
for(local k = 0; k < 3; k = k + 1){
  local names = {
    left: concat("life_bed_", string(k), "_left"),
    right: concat("life_bed_", string(k), "_right"),
  }
  append(BED_NAMES, names)
  append(m.params, {names.left, 0, 0.1})
  append(m.params, {names.right, 0, 0.1})
}

// The events. SING + a member's place in the cast: a song; a: the voice
// that sings it, b: the bird, c: its song type + 64 * this time's
// variation. SEED: a: where the insects' chance starts. CUT: a: the
// voice whose song breaks off.
local SING = params.EVENTS.life
local SEED = SING + 90
local CUT = SING + 91

// ------------------------------------------------------------ the game's side

// the land's squares, m; a square this near has its singer, and loses it
// this far away
local CELL = 32
local NEAR = 100
local FAR = 124
// a knock this hard (game/world's knock: the speed lost at once, m/s) is
// a crash to whoever lives near
local CRASH = 2.5
// how many of a full wood's squares have a singer, and of a high
// meadow's a marmot
local POPULATION = 0.3
local MARMOTS = 0.1

// the cast's members that live in trees (the first of the cast), and
// those with ways of their own
local RESIDENTS = 5
local WOODPECKER = life.index.woodpecker
local CUCKOO = life.index.cuckoo
local BUZZARD = life.index.buzzard
local RAVEN = life.index.raven
local MARMOT = life.index.marmot
local BEE = life.index.bee

// the game's modules, and its plants by what they are to a bird: loaded
// when a world is first seen (the mixer's side has no use for them)
local plants = null
local terrain = null
local surfaces = null
local CONIFER = {}
local BROADLEAF = {}
local BUSH = {}
local PERCHES = {}
local TRUNKS = {}

local func know_the_world(){
  plants = require("game/plants")
  terrain = require("game/terrain")
  surfaces = require("game/surfaces")
  for(local k = 0; k < len(plants.KINDS); k = k + 1){
    local kind = plants.KINDS[k]
    if(kind.name == "spruce" or kind.name == "fir" or kind.name == "pine"){
      append(CONIFER, k)
    } else if(kind.name == "birch" or kind.name == "oak" or kind.name == "sapling"){
      append(BROADLEAF, k)
    } else if(kind.group == "bush"){
      append(BUSH, k)
    }
    if(kind.group == "tree"){
      append(PERCHES, k)
      if(kind.solid){
        append(TRUNKS, k)
      }
    }
  }
}

local func smoothstep(a, b, v){
  local t = (v - a) / (b - a)
  if(t <= 0){
    return 0
  }
  if(t >= 1){
    return 1
  }
  return t * t * (3 - 2 * t)
}

// a draw from 0 up to 1 from a singer's (or the watcher's) own row of
// chance: nobody's song depends on what the others do
local func draw(g){
  g.rng = life.next(g.rng)
  return life.unit(g.rng)
}

// a wait of at least range[0] seconds and on average range[1] more, now
// and then much more
local func wait(g, range){
  return range[0] - range[1] * math.log(1 - draw(g))
}

// how many songs a bout has
local func bout(g){
  local b = g.bird.bout
  return b[0] + to_int(draw(g) * (b[1] - b[0] + 1))
}

// watcher(seed?: int) -> the layer's state in the main isolate. seed:
// who lives where and what they do (another every session by default)
// [sung]: how many songs each member of the cast has sung so far (by its
//   place in the cast): for tools and tests
func m.watcher(seed){
  seed = seed or to_int(math.random() * 2000000000) + 1
  local w = {
    seed: seed,
    rng: life.hash(seed, 1, 2),
    time: 0,
    told: false,
    cells: {},
    singers: {},
    voices: {},
    scan: 0,
    at: {x: 1.0e9, z: 1.0e9},
    noise: 0,
    calm: 1,
    activity: 1,
    visits: {},
    spot: {x: 0, y: 0, z: 0},
    scratch: life.song(),
    sung: {},
  }
  for(local k = 0; k < VOICES; k = k + 1){
    append(w.voices, {singer: null, until: 0, cut: false})
  }
  for(local i = 0; i < len(life.CAST); i = i + 1){
    append(w.sung, 0)
  }
  // the visitors: when each first looks in, s
  append(w.visits, {member: CUCKOO, guest: null, next: 20 + 100 * draw(w)})
  append(w.visits, {member: BUZZARD, guest: null, next: 30 + 150 * draw(w)})
  append(w.visits, {member: RAVEN, guest: null, next: 15 + 60 * draw(w)})
  append(w.visits, {member: BEE, guest: null, next: 15 + 40 * draw(w)})
  return w
}

// how many plants of some kinds stand in a square of the game's plants
local func counted(chunk, kinds){
  local n = 0
  if(chunk.count > 0){
    for(let local k in values(kinds)){
      n = n + chunk.starts[k + 1] - chunk.starts[k]
    }
  }
  return n
}

// the plant of some kinds nearest a point of a square, no further than
// reach: the seat's place becomes a share of the way up it; false when
// there is none
local func perch(seat, chunk, x, z, kinds, reach, up){
  if(chunk.count == 0){
    return false
  }
  local d = chunk.data
  local best = -1
  local best_kind = 0
  local least = reach * reach
  for(let local k in values(kinds)){
    for(local i = chunk.starts[k]; i < chunk.starts[k + 1]; i = i + 1){
      local at = i * plants.STRIDE
      local dx = d[at + plants.X] - x
      local dz = d[at + plants.Z] - z
      if(dx * dx + dz * dz < least){
        least = dx * dx + dz * dz
        best = at
        best_kind = k
      }
    }
  }
  if(best < 0){
    return false
  }
  seat.x = d[best + plants.X]
  seat.z = d[best + plants.Z]
  seat.y = d[best + plants.Y] + (plants.KINDS[best_kind].height or 1) * d[best + plants.SCALE] * up
  return true
}

// a singer as it starts out: in the middle of a bout, or resting
local func begin(w, g){
  local bird = g.bird
  g.kind = to_int(draw(g) * bird.types)
  g.hush = 0
  g.wary = 0
  g.alarms = 0
  g.voice = null
  g.gone = false
  if(g.member == MARMOT){
    // (a marmot whistles when something is the matter: see act)
    g.kind = 0
    g.left = 1
    g.next = w.time + 5 + wait(g, bird.rest) * draw(g)
  } else if(draw(g) < 0.45){
    g.left = 1 + to_int(draw(g) * bird.bout[1])
    g.next = w.time + 0.3 + draw(g) * (bird.pause[0] + bird.pause[1]) * 1.5
  } else {
    g.left = bout(g)
    g.next = w.time + 2 + wait(g, bird.rest) * draw(g)
  }
}

// who lives in the square (ix, iz) of the land: a singer, or false.
// Always the same for the same square: its chance comes from where it is
local func settle(w, s, ix, iz){
  local a = s.around
  local g = {rng: life.hash(ix + 100000, iz + 100000, w.seed)}
  local x = (ix + draw(g)) * CELL
  local z = (iz + draw(g)) * CELL
  local lot = draw(g)
  local which = draw(g)
  // what grows there: the game's plants where the world is known, else
  // what is around the listener
  local broadleaf = a.trees.broadleaf
  local conifer = a.trees.conifer
  local bush = a.trees.bush
  local grass = draw(g) < a.cover.grass
  local chunk = null
  local world = s.world
  if(world != null and world.plants != null){
    chunk = plants.chunk_at(world.plants, x, z)
    if(chunk == null){
      return false
    }
    broadleaf = math.min(counted(chunk, BROADLEAF) / 40, 1)
    conifer = math.min(counted(chunk, CONIFER) / 40, 1)
    bush = math.min(counted(chunk, BUSH) / 20, 1)
    grass = terrain.surface_at(world.land, x, z) == surfaces.grass
  }
  local cover = math.min(broadleaf + conifer * 0.45 + bush * 0.25, 1)
  local member = null
  // (a thin stand has more singers than its share of a wood's: where
  // trees are few every one of them has its bird)
  if(lot < POPULATION * math.sqrt(cover)){
    // a bird of the trees: which, by what each likes of what grows here
    local total = 0
    for(local i = 0; i < RESIDENTS; i = i + 1){
      local home = life.CAST[i].home
      total = total + home.broadleaf * broadleaf + home.conifer * conifer + home.bush * bush
    }
    local target = which * total
    for(local i = 0; i < RESIDENTS; i = i + 1){
      local home = life.CAST[i].home
      target = target - (home.broadleaf * broadleaf + home.conifer * conifer + home.bush * bush)
      if(target <= 0){
        member = i
        break
      }
    }
  } else if(grass and cover < 0.15 and lot > 1 - MARMOTS * smoothstep(0.3, 0.5, a.alpine)){
    member = MARMOT
  }
  if(member == null){
    return false
  }
  g.x = x
  g.z = z
  if(chunk == null){
    g.y = if(member == MARMOT){ a.ground + 0.3 } else { a.height + 6 }
  } else if(member == MARMOT){
    g.y = terrain.height_at(world.land, x, z) + 0.3
  } else if(member == WOODPECKER){
    // (it drums on a trunk)
    if(not perch(g, chunk, x, z, TRUNKS, 26, 0.5)){
      return false
    }
  } else if(not perch(g, chunk, x, z, PERCHES, 26, 0.8) and not perch(g, chunk, x, z, BUSH, 26, 0.8)){
    return false
  }
  g.member = member
  g.bird = life.CAST[member]
  g.who = life.hash(ix + 100000, iz + 100000, w.seed + 1)
  begin(w, g)
  return g
}

// the squares around the listener: those that came near get their
// singers, those left behind are forgotten
local func survey(w, s){
  local eye = s.view.eye
  w.scan = w.time + 0.5
  w.at.x = eye.x
  w.at.z = eye.z
  local x0 = to_int(math.floor((eye.x - NEAR) / CELL))
  local x1 = to_int(math.floor((eye.x + NEAR) / CELL))
  local z0 = to_int(math.floor((eye.z - NEAR) / CELL))
  local z1 = to_int(math.floor((eye.z + NEAR) / CELL))
  for(local iz = z0; iz <= z1; iz = iz + 1){
    for(local ix = x0; ix <= x1; ix = ix + 1){
      local dx = (ix + 0.5) * CELL - eye.x
      local dz = (iz + 0.5) * CELL - eye.z
      if(dx * dx + dz * dz <= NEAR * NEAR){
        local key = (ix + 100000) * 1000000 + iz + 100000
        if(w.cells[key] == null){
          local g = settle(w, s, ix, iz)
          w.cells[key] = g
          if(g != false){
            append(w.singers, g)
          }
        }
      }
    }
  }
  local left = {}
  for(let local e in entries(w.cells)){
    local key = e[0]
    local dx = (to_int(key / 1000000) - 100000 + 0.5) * CELL - eye.x
    local dz = (key % 1000000 - 100000 + 0.5) * CELL - eye.z
    if(dx * dx + dz * dz > FAR * FAR){
      append(left, key)
      if(e[1] != false){
        e[1].gone = true
      }
    }
  }
  for(let local key in values(left)){
    delete(w.cells, key)
  }
}

// a voice's gains for where its singer is now
local func hear(w, s, k, set){
  local v = w.voices[k]
  local names = VOICE_NAMES[k]
  if(v.cut){
    set(names.left, 0)
    set(names.right, 0)
    return
  }
  local g = v.singer
  local bird = g.bird
  local p = listener.place(s.view, g, bird.reach)
  local level = LEVEL * bird.level
  // (nearer than half its reach a singer grows no louder)
  local half = bird.reach / 2
  if(p.distance < half){
    level = level * math.max(p.distance, bird.reach / 3) / half
  }
  set(names.left, p.left * level)
  set(names.right, p.right * level)
  // (twice as dull every twenty meters or so of wood between)
  set(names.far, 16000 / (1 + p.distance * bird.air / 22))
}

// a singer's song breaks off (it was frightened)
local func cut(w, g, send){
  local v = w.voices[g.voice]
  if(not v.cut){
    v.cut = true
    v.until = math.min(v.until, w.time + 0.3)
    send(CUT, g.voice)
  }
}

// how loud the truck is (0: standing with its engine idling; 1: all it
// has), and who it frightens: the singers near it fall silent for a
// while, the nearer the louder it is; the meadow's insects too. A crash
// (a hard knock, the knock that breaks the truck) frightens further
local func disturb(w, s, dt, send){
  local car = s.car
  local n = 0
  if(car != null){
    local rpm = if(car.drive != null){ car.drive.rpm or 0 } else { 0 }
    local speed = math.abs(car.speed or 0)
    n = math.max(math.min(math.max((rpm - 900) / 2200, 0), 1), math.min(speed / 8, 1))
  }
  w.noise = n
  local reach = 0
  if(n > 0.12){
    reach = 12 + 45 * n
    w.calm = math.max(w.calm - dt * (0.5 + 2 * n), 0)
  } else {
    w.calm = math.min(w.calm + dt / 10, 1)
  }
  local events = s.events or {}
  for(local i = 0; i < len(events); i = i + 1){
    local e = events[i]
    if(e.kind == "broken" or (e.kind == "knock" and (e.strength or 0) >= CRASH)){
      reach = 80
      w.calm = 0
    }
  }
  if(reach == 0){
    return
  }
  local p = if(car != null){ car.pos } else { s.view.eye }
  local list = w.singers
  for(local i = 0; i < len(list); i = i + 1){
    local g = list[i]
    // (a marmot does the opposite: see act; the visitors are far off)
    if(g.member < RESIDENTS){
      local dx = g.x - p.x
      local dz = g.z - p.z
      if(dx * dx + dz * dz < reach * reach){
        if(g.hush < w.time + 4){
          // quiet for a while; then it starts over with a new bout, or
          // has had enough for now and rests first
          g.hush = w.time + 6 + 10 * draw(g)
          g.left = bout(g)
          if(draw(g) < 0.5){
            g.next = g.hush + 1 + 25 * draw(g)
          } else {
            g.next = g.hush + 20 + wait(g, g.bird.rest) / 2
          }
        }
        if(g.voice != null){
          cut(w, g, send)
        }
      }
    }
  }
}

// a singer's turn: when its time has come it sings, if it is heard at
// all and a voice is free, and decides when it sings next
local func act(w, s, g, set, send){
  local bird = g.bird
  if(g.member == MARMOT and w.noise > 0.2 and w.time >= g.wary){
    // the truck comes near: an alarm, a row of whistles; again if it
    // does not go away, and after the third the marmot is in its burrow
    local p = s.car.pos
    local dx = g.x - p.x
    local dz = g.z - p.z
    if(dx * dx + dz * dz < 90 * 90){
      g.kind = 1
      g.left = 1
      g.next = math.min(g.next, w.time + 0.2 + 1.2 * draw(g))
      g.alarms = g.alarms + 1
      if(g.alarms >= 3){
        g.alarms = 0
        g.wary = w.time + 150 + 100 * draw(g)
      } else {
        g.wary = w.time + 12 + 20 * draw(g)
      }
    }
  }
  if(g.voice != null or w.time < g.next){
    return
  }
  // frightened: once that is over
  if(w.time < g.hush){
    g.next = g.hush + 1 + 14 * draw(g)
    return
  }
  // the wind keeps some of them quiet, a gale all
  if(draw(g) >= w.activity){
    g.next = w.time + 3 + wait(g, bird.pause)
    return
  }
  local eye = s.view.eye
  local dx = g.x - eye.x
  local dy = g.y - eye.y
  local dz = g.z - eye.z
  local slot = -1
  if(dx * dx + dy * dy + dz * dz <= bird.hear * bird.hear){
    for(local k = 0; k < VOICES; k = k + 1){
      if(w.voices[k].singer == null){
        slot = k
        break
      }
    }
    if(slot < 0){
      // every voice is taken: in a moment
      g.next = w.time + 0.5 + 1.5 * draw(g)
      return
    }
  }
  // the song (composed here for its length; one out of earshot is sung
  // to nobody)
  local variation = to_int(draw(g) * 1000000)
  life.compose(w.scratch, g.member, g.who, g.kind, variation)
  local length = LEAD + w.scratch.length
  if(slot >= 0){
    send(SING + g.member, slot, g.who, g.kind + 64 * variation)
    local v = w.voices[slot]
    v.singer = g
    v.until = w.time + length + KEEP
    v.cut = false
    g.voice = slot
    w.sung[g.member] = w.sung[g.member] + 1
    hear(w, s, slot, set)
  }
  // when it sings next: counted from when this song was due, not from
  // the frame that noticed (so the pace does not hang on the frame rate)
  local from = if(w.time - g.next < 0.25){ g.next } else { w.time }
  g.left = g.left - 1
  if(g.left > 0){
    g.next = from + length + wait(g, bird.pause)
  } else if(g.visitor){
    // a visitor goes its way after its bout
    g.gone = true
    g.next = 1.0e18
  } else {
    g.left = bout(g)
    g.next = from + length + wait(g, bird.rest)
    if(bird.stay){
      g.kind = to_int(draw(g) * bird.types)
    }
  }
  if(g.member == MARMOT){
    g.kind = 0
    g.left = 1
  } else if(not bird.stay and bird.types > 1){
    // another of its songs every time, never the same twice running
    g.kind = (g.kind + 1 + to_int(draw(g) * (bird.types - 1))) % bird.types
  }
}

// how welcome a visitor is where the listener stands, 0 to 1
local func welcome(w, s, member){
  local a = s.around
  local trees = a.trees.broadleaf + a.trees.conifer
  if(member == CUCKOO){
    // in the woods of the valley's floor
    return math.min(4 * (a.trees.broadleaf + 0.4 * a.trees.conifer), 1) *
      (1 - smoothstep(0.25, 0.45, a.alpine)) * w.activity
  }
  if(member == BUZZARD){
    // over meadows and woods, not over the summits
    return math.min(2.5 * (a.cover.grass + trees), 1) * (1 - smoothstep(0.7, 0.95, a.alpine)) *
      w.activity
  }
  if(member == RAVEN){
    // up high, and where rock stands steep; not over bare rock and snow
    local cliff = 0
    for(let local wall in values(a.walls)){
      if(wall.distance <= 96 and wall.rise > 24){
        cliff = 0.7
      }
    }
    return math.max(smoothstep(0.25, 0.55, a.alpine), cliff) *
      math.min(4 * (a.cover.grass + trees + a.trees.bush), 1) * w.activity
  }
  // the bumblebee: over a meadow low down, out of the woods' shade, when
  // the truck stands
  local slow = if(s.car != null and math.abs(s.car.speed or 0) > 1.5){ 0 } else { 1 }
  return smoothstep(0.3, 0.6, a.cover.grass) * (1 - smoothstep(0.3, 0.5, a.alpine)) *
    (1 - math.min(trees * 1.5, 1)) * w.activity * w.calm * slow
}

// a visitor arrives: where, and how it moves
local func arrive(w, s, member){
  local a = s.around
  local eye = s.view.eye
  local bird = life.CAST[member]
  local g = {
    member: member, bird: bird, visitor: true,
    rng: life.hash(w.seed, member, to_int(w.time * 10)),
    // (the valley has a pair of cuckoos, of buzzards, of ravens; every
    // bee is another)
    who: life.hash(w.seed, member, if(member == BEE){ to_int(w.time) } else { to_int(draw(w) * 2) }),
    x: eye.x, y: eye.y, z: eye.z, vx: 0, vz: 0, turn: 0,
  }
  begin(w, g)
  local angle = draw(g) * 2 * math.pi
  local sin = math.sin(angle)
  local cos = math.cos(angle)
  g.left = bout(g)
  g.next = w.time + 1 + 3 * draw(g)
  if(member == CUCKOO){
    local far = 260 + 260 * draw(g)
    g.x = eye.x + sin * far
    g.z = eye.z + cos * far
    g.y = eye.y + 12
  } else if(member == BUZZARD){
    // circling
    local far = 120 + 140 * draw(g)
    g.cx = eye.x + sin * far
    g.cz = eye.z + cos * far
    g.y = eye.y + 90 + 80 * draw(g)
    g.radius = 50 + 30 * draw(g)
    g.angle = draw(g) * 2 * math.pi
    g.turn = (0.12 + 0.08 * draw(g)) * (if(draw(g) < 0.5){ 1 } else { -1 })
    g.x = g.cx + math.sin(g.angle) * g.radius
    g.z = g.cz + math.cos(g.angle) * g.radius
  } else if(member == RAVEN){
    // on the steepest rock around, or flying by
    local cliff = null
    for(let local wall in values(a.walls)){
      if(wall.distance <= 96 and wall.rise > 24 and (cliff == null or wall.rise > cliff.rise)){
        cliff = wall
      }
    }
    if(cliff != null){
      // (up the rock, and never close: a raven keeps its distance)
      local far = math.max(cliff.distance + 8, 60)
      g.x = eye.x + cliff.x * far
      g.z = eye.z + cliff.z * far
      g.y = eye.y + math.min(cliff.rise, 45) * 0.8
    } else {
      local far = 70 + 110 * draw(g)
      local speed = 7 + 3 * draw(g)
      local way = angle + math.pi / 2 + draw(g) - 0.5
      g.x = eye.x + sin * far
      g.z = eye.z + cos * far
      g.y = eye.y + 35 + 45 * draw(g)
      g.vx = math.sin(way) * speed
      g.vz = math.cos(way) * speed
    }
  } else {
    // the bee: past the listener's ear, from one side to the other;
    // nearest in the middle of its hum
    local near = 1.2 + 1.8 * draw(g)
    local speed = (3.5 + 1.5 * draw(g)) * (if(draw(g) < 0.5){ 1 } else { -1 })
    g.vx = cos * speed
    g.vz = -sin * speed
    g.x = eye.x + sin * near - g.vx * 2.7
    g.z = eye.z + cos * near - g.vz * 2.7
    g.y = eye.y - 0.4 + 0.9 * draw(g)
    g.next = w.time
  }
  return g
}

// the visitors come and go
local func visit(w, s, dt){
  for(let local v in values(w.visits)){
    local g = v.guest
    if(g == null){
      if(w.time >= v.next){
        if(draw(w) < welcome(w, s, v.member)){
          v.guest = arrive(w, s, v.member)
          append(w.singers, v.guest)
        } else {
          // not here, not now: it looks in again later
          v.next = w.time + 10 + 20 * draw(w)
        }
      }
    } else if(g.gone and g.voice == null){
      v.guest = null
      v.next = w.time + wait(w, g.bird.rest)
    } else if(g.turn != 0){
      g.angle = g.angle + g.turn * dt
      g.x = g.cx + math.sin(g.angle) * g.radius
      g.z = g.cz + math.cos(g.angle) * g.radius
    } else {
      g.x = g.x + g.vx * dt
      g.z = g.z + g.vz * dt
    }
  }
}

// the meadow's insects: how much of them is awake (they like grass, low
// down, in the open, without wind, and nothing rumbling past), and
// where their three places are for the listener: around it, and staying
// put as the camera turns
local func bed(w, s, set){
  local a = s.around
  local shade = math.min((a.trees.broadleaf + a.trees.conifer) * 1.5, 1)
  local meadow = a.cover.grass * (1 - smoothstep(0.2, 0.45, a.alpine)) * (1 - shade)
  set("life_crickets", smoothstep(0.15, 0.6, meadow) * w.activity * w.calm)
  set("life_hoppers", smoothstep(0.3, 0.75, meadow) * w.activity * w.calm)
  local eye = s.view.eye
  local spot = w.spot
  for(local k = 0; k < 3; k = k + 1){
    local angle = 0.7 + k * 2 * math.pi / 3
    spot.x = eye.x + math.sin(angle) * listener.REFERENCE
    spot.y = eye.y
    spot.z = eye.z + math.cos(angle) * listener.REFERENCE
    local p = listener.place(s.view, spot)
    set(BED_NAMES[k].left, p.left * BED)
    set(BED_NAMES[k].right, p.right * BED)
  }
}

// watch(w, s, set, send): a frame (s: sound/director's Frame)
func m.watch(w, s, set, send){
  local dt = s.dt or 1 / 60
  w.time = w.time + dt
  local a = s.around
  if(a == null or s.view == null){
    return
  }
  if(not w.told){
    w.told = true
    send(SEED, w.seed)
  }
  if(s.world != null and plants == null){
    know_the_world()
  }
  // (gusts come and go in seconds: it is the day's wind that counts)
  w.activity = 1 - smoothstep(0.42, 0.72, 0.7 * a.wind.steady + 0.3 * a.wind.strength)
  disturb(w, s, dt, send)
  // who lives around here: looked at twice a second, and at once after
  // a jump (the truck was towed)
  local eye = s.view.eye
  local dx = eye.x - w.at.x
  local dz = eye.z - w.at.z
  if(w.time >= w.scan or dx * dx + dz * dz > CELL * CELL){
    survey(w, s)
  }
  visit(w, s, dt)
  // everybody's turn; who is gone and has sung to its end is forgotten
  local list = w.singers
  local kept = 0
  for(local i = 0; i < len(list); i = i + 1){
    local g = list[i]
    if(not g.gone){
      act(w, s, g, set, send)
    }
    if(not g.gone or g.voice != null){
      list[kept] = g
      kept = kept + 1
    }
  }
  for(len(list) > kept){
    remove(list, len(list) - 1)
  }
  // the voices: free again once their songs are over, else placed for
  // the listener
  for(local k = 0; k < VOICES; k = k + 1){
    local v = w.voices[k]
    if(v.singer != null){
      if(w.time >= v.until){
        v.singer.voice = null
        v.singer = null
        v.cut = false
      } else {
        hear(w, s, k, set)
      }
    }
  }
  bed(w, s, set)
}

// ------------------------------------------------------------ the mixer's side

// how long a voice goes on after its song's last syllable, s (what rings
// on dies away)
local TAIL = 0.1

// voice(ctx) -> {block, on}: see sound/mixer
func m.voice(ctx){
  local whistle = require("sound/life/whistle")
  local rough = require("sound/life/rough")
  local insects = require("sound/life/insects")
  local rate = ctx.rate
  local now = ctx.now
  local slot = ctx.slot
  local world = ctx.world
  local none = {}
  // the frames computed so far: the voices' clock
  local clock = 0
  local lead = to_int(LEAD * rate)
  local tail = to_int(TAIL * rate)

  // each control's field in a program's state, by its label
  local func fields(program){
    local f = {}
    for(let local c in values(program.controls)){
      f[c.label] = c.field
    }
    return f
  }
  local whistle_fields = fields(whistle)
  local rough_fields = fields(rough)

  // the voices: each can whistle and croak, one song at a time
  local voices = {}
  for(local k = 0; k < VOICES; k = k + 1){
    local out = kernel.float:array(ctx.size)
    local names = VOICE_NAMES[k]
    append(voices, {
      song: life.song(rate),
      live: false,
      // the next syllable, the clock at the song's start and at its end
      next: 0, start: 0, stop: 0,
      // (the programs start a syllable when their `hit` changes)
      hits: 0,
      whistle: whistle:new({sample_rate: rate}),
      rough: rough:new({sample_rate: rate}),
      inst: null, state: null, fields: null,
      out: out, outs: {out},
      left: slot[names.left], right: slot[names.right], far: slot[names.far],
      was: {left: 0, right: 0}, to: {left: 0, right: 0},
    })
  }

  // the insects: three crickets that sing for a while and pause for a
  // while, two grasshoppers that rasp a verse now and then
  local bed = insects:new({sample_rate: rate})
  local bed_state = bed.state
  local bed_fields = fields(insects)
  local bed_outs = {kernel.float:array(ctx.size), kernel.float:array(ctx.size), kernel.float:array(ctx.size)}
  local bed_places = {}
  for(local k = 0; k < 3; k = k + 1){
    append(bed_places, {
      left: slot[BED_NAMES[k].left], right: slot[BED_NAMES[k].right],
      was: {left: 0, right: 0}, to: {left: 0, right: 0},
    })
  }
  local crickets = {}
  for(let local label in values({"one", "two", "three"})){
    local pace = insects.by_label[concat("pace_", label)]
    append(crickets, {
      field: bed_fields[label], on: false, until: 0, level: 0, loud: 1,
      // (its chirps a second: what they are on average, now, and what
      // they are drifting to)
      pace_field: pace.field, pace: pace.init, pace_now: pace.init, pace_to: pace.init, turn: 0,
    })
  }
  local hoppers = {}
  for(let local label in values({"rasp_one", "rasp_two"})){
    append(hoppers, {field: bed_fields[label], singing: false, from: 0, length: 0, next: 0, loud: 1})
  }
  local crickets_awake = slot.life_crickets
  local hoppers_awake = slot.life_hoppers
  local bed_live = false
  // the insects' chance (the game sends where it starts)
  local seed = 20261114
  local func chance(){
    seed = seed * 48271 % 2147483647
    return (seed - 1) / 2147483646
  }

  // a song's next syllable, when its time has come in this block of n
  // frames: one in a breath with the one before starts with the first
  // block after its time (the one before is held meanwhile), any other
  // on its sample
  local func syllable(v, n){
    local d = v.song.data
    local at = v.next * life.STRIDE
    local due = d[at] - (clock - v.start)
    local joined = d[at + life.JOINED] > 0
    if(joined){
      if(due > 0){
        return
      }
      due = 0
    } else if(due >= n){
      return
    } else if(due < 0){
      due = 0
    }
    local st = v.state
    local f = v.fields
    st[f.delay] = due
    st[f.dur] = d[at + life.DUR]
    st[f.from] = d[at + life.FROM]
    st[f.to] = d[at + life.TO]
    st[f.arch] = d[at + life.ARCH]
    st[f.loud] = d[at + life.LOUD]
    st[f.fade] = d[at + life.FADE]
    st[f.attack] = d[at + life.ATTACK]
    st[f.release] = d[at + life.RELEASE]
    v.hits = v.hits + 1
    st[f.hit] = v.hits
    v.next = v.next + 1
  }

  // the insects' block: who is awake, how loud, and their sound
  local func insects_block(n){
    // (a parameter glides toward nothing and never gets there)
    local awake = now[crickets_awake]
    if(awake < 0.001){
      awake = 0
    }
    local rasping = now[hoppers_awake]
    if(rasping < 0.001){
      rasping = 0
    }
    // no meadow, and nothing of one still sounding: nothing to do
    if(awake == 0 and rasping == 0 and not bed_live){
      return
    }
    local sounding = false
    // (a cricket fades in and out over a third of a second)
    local step = n / (0.3 * rate)
    for(local i = 0; i < 3; i = i + 1){
      local c = crickets[i]
      if(clock >= c.until){
        // it sings for a while or pauses for a while: even in the best
        // of meadows not all of them all the time
        c.on = chance() < 0.55 * awake
        c.loud = 0.6 + 0.4 * chance()
        if(c.on){
          c.until = clock + rate * (8 + 30 * chance())
        } else if(awake > 0.05){
          c.until = clock + rate * (4 + 16 * chance())
        } else {
          // (no meadow here: it looks again soon, in case one comes)
          c.until = clock + rate * (1 + 2 * chance())
        }
      }
      // its pace is never quite even: every few seconds it drifts to
      // another, a few percent off
      if(clock >= c.turn){
        c.pace_to = c.pace * (0.965 + 0.07 * chance())
        c.turn = clock + rate * (3 + 5 * chance())
      }
      c.pace_now = c.pace_now + (c.pace_to - c.pace_now) * 0.002
      bed_state[c.pace_field] = c.pace_now
      local target = 0
      if(c.on){
        target = c.loud * awake * 2.5
        if(target > c.loud){
          target = c.loud
        }
      }
      if(c.level < target){
        c.level = c.level + step
        if(c.level > target){
          c.level = target
        }
      } else if(c.level > target){
        c.level = c.level - step
        if(c.level < target){
          c.level = target
        }
      }
      bed_state[c.field] = c.level
      if(c.level > 0){
        sounding = true
      }
    }
    for(local i = 0; i < 2; i = i + 1){
      local h = hoppers[i]
      local level = 0
      if(h.singing){
        local t = (clock - h.from) / rate
        if(t >= h.length){
          h.singing = false
          h.next = clock + rate * (6 - 14 * math.log(1 - chance()))
        } else {
          // a verse swells and breaks off
          level = 0.3 + 1.4 * t / h.length
          if(level > 1){
            level = 1
          }
          if(t < 0.03){
            level = level * t / 0.03
          }
          if(h.length - t < 0.05){
            level = level * (h.length - t) / 0.05
          }
          level = level * h.loud
          if(rasping < 0.4){
            level = level * rasping * 2.5
          }
        }
      } else if(clock >= h.next){
        if(chance() < rasping){
          h.singing = true
          h.from = clock
          h.length = 1.2 + 1.6 * chance()
          h.loud = 0.5 + 0.5 * chance()
        } else {
          h.next = clock + rate * (2 + 6 * chance())
        }
      }
      bed_state[h.field] = level
      if(level > 0){
        sounding = true
      }
    }
    // (one block more than they sound: what is left in the filters)
    if(sounding or bed_live){
      bed:compute(n, none, bed_outs)
      for(local k = 0; k < 3; k = k + 1){
        local p = bed_places[k]
        p.to.left = now[p.left]
        p.to.right = now[p.right]
        if(not bed_live){
          p.was.left = p.to.left
          p.was.right = p.to.right
        }
        ctx.place(world, bed_outs[k], p.was, p.to, n)
      }
    }
    bed_live = sounding
  }

  local cast = len(life.CAST)
  local switch = slot.layer_life
  return {
    block: func(n){
      for(local k = 0; k < VOICES; k = k + 1){
        local v = voices[k]
        if(v.live){
          if(v.next < v.song.count){
            syllable(v, n)
          }
          v.state[v.fields.cutoff] = now[v.far]
          v.inst:compute(n, none, v.outs)
          v.to.left = now[v.left]
          v.to.right = now[v.right]
          ctx.place(world, v.out, v.was, v.to, n)
          if(clock + n >= v.stop){
            v.live = false
          }
        }
      }
      insects_block(n)
      clock = clock + n
    },
    on: func(kind, a, b, c){
      if(kind < SING or kind > CUT){
        return
      }
      if(kind == SEED){
        seed = to_int(a) % 2147483646 + 1
        return
      }
      local k = to_int(a)
      if(k < 0 or k >= VOICES){
        return
      }
      local v = voices[k]
      if(kind == CUT){
        // no more syllables; the game takes its gains away meanwhile
        if(v.live){
          v.next = v.song.count
          if(v.stop > clock + tail){
            v.stop = clock + tail
          }
        }
        return
      }
      local member = kind - SING
      // (a layer that is switched off computes nothing: a song begun now
      // would start whenever it is switched on again)
      if(member >= cast or (switch != null and now[switch] < 0.5)){
        return
      }
      local code = to_int(c)
      local song = v.song
      life.compose(song, member, to_int(b), code % 64, to_int(code / 64))
      local st = null
      local f = null
      if(song.voice == life.ROUGH){
        v.inst = v.rough
        st = v.rough.state
        f = rough_fields
        st[f.strike] = song.strike
        st[f.jitter] = song.jitter
        st[f.waver] = song.waver
        st[f.hiss] = song.hiss
        st[f.low] = song.low
        st[f.low_q] = song.low_q
        st[f.low_gain] = song.low_gain
        st[f.high] = song.high
        st[f.high_q] = song.high_q
        st[f.high_gain] = song.high_gain
      } else {
        v.inst = v.whistle
        st = v.whistle.state
        f = whistle_fields
        st[f.second] = song.second
        st[f.third] = song.third
      }
      v.state = st
      v.fields = f
      // (whatever syllable the program still holds is over)
      st[f.loud] = 0
      st[f.fade] = 0
      v.next = 0
      v.start = clock + lead
      v.stop = v.start + to_int(song.length * rate) + tail
      if(not v.live){
        v.was.left = now[v.left]
        v.was.right = now[v.right]
      }
      v.live = true
    },
  }
}

return m
