// The rules of Inkblast, with no window and no network: the arena, moving,
// charges and their blasts, the ink they spill, knockouts and the round.
// The server runs them; clients only draw what the server tells them.
//
// Every blast paints the floor it reaches in the colour of whoever set
// the charge, over any colour that was there. When the round ends, the
// player with the most floor wins. A player caught in a blast is knocked
// out for a few seconds and comes back at their corner; knockouts are
// counted but score nothing, they only keep someone from painting.
local math = require("slang/math")
local str = require("slang/string")

local rules = {}

rules.W = 15
rules.H = 11
// the simulation steps at a fixed rate
rules.TICK = 1000 / 30
rules.ROUND = 90 * 1000
rules.INTERMISSION = 6000
rules.MAX_PLAYERS = 4

// what a cell holds
rules.FLOOR = 0
rules.PILLAR = 1
rules.CRATE = 2
// pickups lie on the floor: a pot splashes ink around whoever takes it,
// a lens makes the next charges reach further
rules.POT = 3
rules.LENS = 4

local SPEED = 5          // cells per second
local FUSE = 2200
local BLAST = 450        // how long a blast burns
local REACH = 2
local LENS_REACH = 4
local LENS_CHARGES = 2   // charges a lens lasts
local CAPACITY = 2       // charges a player may have set at once
local OUT = 3000         // knocked out this long
local SAFE = 1500        // and then safe from blasts this long
local CRATES = 0.62      // the part of the free cells that start as crates
local DROPS = 0.3        // the part of the crates that leave a pickup

rules.SPAWNS = {{1, 1}, {13, 9}, {13, 1}, {1, 9}}
// directions: 0 none, 1 up, 2 right, 3 down, 4 left
rules.DX = {0, 0, 1, 0, -1}
rules.DY = {0, -1, 0, 1, 0}
local OPPOSITE = {0, 3, 4, 1, 2}

local func index(x, y){
  return y * rules.W + x
}
rules.index = index

// a small generator with a seed, so that an arena can be made again
local func generator(seed){
  local state = seed & 0x7FFF_FFFF
  return func(){
    state = (state * 1103515245 + 12345) & 0x7FFF_FFFF
    return state / 0x8000_0000
  }
}

local func near_spawn(x, y){
  for(let local s in values(rules.SPAWNS)){
    if(math.abs(s[0] - x) + math.abs(s[1] - y) <= 1){
      return true
    }
  }
  return false
}

// new_world(seed: int) -> World: an arena with walls around, pillars in a
// lattice and crates everywhere else but the corners
func rules.new_world(seed){
  local random = generator(seed)
  local cells = {}
  local paint = {}
  for(local y = 0; y < rules.H; y = y + 1){
    for(local x = 0; x < rules.W; x = x + 1){
      local c = rules.FLOOR
      if(x == 0 or y == 0 or x == rules.W - 1 or y == rules.H - 1 or (x % 2 == 0 and y % 2 == 0)){
        c = rules.PILLAR
      } else if(not near_spawn(x, y) and random() < CRATES){
        c = rules.CRATE
      }
      append(cells, c)
      append(paint, 0)
    }
  }
  return {
    cells: cells, paint: paint, players: {}, charges: {}, blasts: {},
    now: 0, tick: 0, left: rules.ROUND, phase: "playing", winner: -1,
    random: random, events: {},
  }
}

// ------------------------------------------------------------ players

// add_player(world, slot: int, name: string) -> Player
func rules.add_player(w, slot, name){
  local s = rules.SPAWNS[slot]
  local p = {
    slot: slot, name: name, x: s[0], y: s[1], tx: s[0], ty: s[1], progress: 0,
    moving: false, dir: 3, input: 0, alive: true, back_at: 0, safe_until: w.now + SAFE,
    out: 0, lens: 0, kos: 0, score: 0,
  }
  w.players[slot] = p
  return p
}

func rules.remove_player(w, slot){
  w.players[slot] = null
}

// where a player is drawn, in cells (fractions while moving)
func rules.position(p){
  if(not p.moving){
    return {p.x, p.y}
  }
  return {p.x + (p.tx - p.x) * p.progress, p.y + (p.ty - p.y) * p.progress}
}

// the cell a player counts as standing on: the one they are closer to
func rules.cell_of(p){
  if(p.moving and p.progress >= 0.5){
    return {p.tx, p.ty}
  }
  return {p.x, p.y}
}

local func charge_at(w, x, y){
  for(let local c in values(w.charges)){
    if(c.x == x and c.y == y){
      return c
    }
  }
  return null
}
rules.charge_at = charge_at

// whether a player may walk into the cell
func rules.passable(w, x, y){
  if(x < 0 or y < 0 or x >= rules.W or y >= rules.H){
    return false
  }
  local c = w.cells[index(x, y)]
  if(c == rules.PILLAR or c == rules.CRATE){
    return false
  }
  return charge_at(w, x, y) == null
}

local func splash(w, cx, cy, owner){
  for(local y = cy - 1; y <= cy + 1; y = y + 1){
    for(local x = cx - 1; x <= cx + 1; x = x + 1){
      if(x > 0 and y > 0 and x < rules.W - 1 and y < rules.H - 1){
        local c = w.cells[index(x, y)]
        if(c != rules.PILLAR and c != rules.CRATE){
          w.paint[index(x, y)] = owner + 1
        }
      }
    }
  }
}

local func arrive(w, p){
  local i = index(p.x, p.y)
  local c = w.cells[i]
  if(c == rules.POT){
    w.cells[i] = rules.FLOOR
    splash(w, p.x, p.y, p.slot)
    append(w.events, {"pickup", p.slot, "pot"})
  } else if(c == rules.LENS){
    w.cells[i] = rules.FLOOR
    p.lens = p.lens + LENS_CHARGES
    append(w.events, {"pickup", p.slot, "lens"})
  }
}

local func move(w, p, dt){
  local d = p.input
  if(p.moving){
    // turning back is allowed at any time
    if(d != 0 and d == OPPOSITE[p.dir]){
      local x = p.x
      local y = p.y
      p.x = p.tx
      p.y = p.ty
      p.tx = x
      p.ty = y
      p.progress = 1 - p.progress
      p.dir = d
    }
    p.progress = p.progress + SPEED * dt / 1000
    if(p.progress < 1 - 1e-9){
      return
    }
    p.x = p.tx
    p.y = p.ty
    p.moving = false
    p.progress = 0
    arrive(w, p)
  }
  if(d != 0){
    p.dir = d
    local nx = p.x + rules.DX[d]
    local ny = p.y + rules.DY[d]
    if(rules.passable(w, nx, ny)){
      p.tx = nx
      p.ty = ny
      p.moving = true
      p.progress = 0
    }
  }
}

// drop(world, slot): sets a charge where the player stands, if they may
func rules.drop(w, slot){
  local p = w.players[slot]
  if(p == null or not p.alive or p.out >= CAPACITY or w.phase != "playing"){
    return false
  }
  local at = rules.cell_of(p)
  if(charge_at(w, at[0], at[1]) != null){
    return false
  }
  local reach = REACH
  if(p.lens > 0){
    p.lens = p.lens - 1
    reach = LENS_REACH
  }
  append(w.charges, {x: at[0], y: at[1], owner: slot, at: w.now + FUSE, reach: reach})
  p.out = p.out + 1
  append(w.events, {"drop", slot})
  return true
}

// ------------------------------------------------------------ blasts

// the cells a charge's blast reaches: its own and along the four
// directions up to its reach, stopping at a pillar and at the first crate
// (which it reaches); with what it reaches, in order
func rules.blast_cells(w, x, y, reach){
  local cells = {index(x, y)}
  for(local d = 1; d <= 4; d = d + 1){
    for(local r = 1; r <= reach; r = r + 1){
      local cx = x + rules.DX[d] * r
      local cy = y + rules.DY[d] * r
      local c = w.cells[index(cx, cy)]
      if(c == rules.PILLAR){
        break
      }
      append(cells, index(cx, cy))
      if(c == rules.CRATE){
        break
      }
    }
  }
  return cells
}

local func explode(w, charge){
  local owner = w.players[charge.owner]
  if(owner != null){
    owner.out = owner.out - 1
  }
  local cells = rules.blast_cells(w, charge.x, charge.y, charge.reach)
  local chained = {}
  for(let local i in values(cells)){
    local c = w.cells[i]
    if(c == rules.CRATE){
      w.cells[i] = rules.FLOOR
      if(w.random() < DROPS){
        w.cells[i] = if(w.random() < 0.6){ rules.POT } else { rules.LENS }
      }
    } else if(c == rules.POT or c == rules.LENS){
      // a blast burns what lies in its way (but not what a crate it
      // breaks leaves, just above)
      w.cells[i] = rules.FLOOR
    }
    if(w.cells[i] == rules.FLOOR or w.cells[i] == rules.POT or w.cells[i] == rules.LENS){
      w.paint[i] = charge.owner + 1
    }
    local x = i % rules.W
    local y = to_int((i - x) / rules.W)
    local other = charge_at(w, x, y)
    if(other != null and other != charge){
      append(chained, other)
    }
  }
  append(w.blasts, {cells: cells, owner: charge.owner, until: w.now + BLAST})
  append(w.events, {"boom", charge.owner, charge.x, charge.y})
  return chained
}

local func knock_out(w, p, by){
  p.alive = false
  p.moving = false
  p.progress = 0
  p.back_at = w.now + OUT
  if(by != p.slot and w.players[by] != null){
    w.players[by].kos = w.players[by].kos + 1
  }
  append(w.events, {"ko", p.slot, by})
}

local func detonate(w){
  // every charge whose time came, and the ones their blasts reach
  local due = {}
  for(let local c in values(w.charges)){
    if(c.at <= w.now){
      append(due, c)
    }
  }
  for(len(due) > 0){
    local c = remove(due, len(due) - 1)
    local i = 0
    local found = false
    for(; i < len(w.charges); i = i + 1){
      if(w.charges[i] == c){
        found = true
        break
      }
    }
    if(found){
      remove(w.charges, i)
      for(let local other in values(explode(w, c))){
        append(due, other)
      }
    }
  }
}

local func burn(w){
  local live = {}
  for(let local b in values(w.blasts)){
    if(b.until > w.now){
      append(live, b)
    }
  }
  w.blasts = live
  for(let local p in values(w.players)){
    if(p.alive and p.safe_until <= w.now){
      local at = rules.cell_of(p)
      local i = index(at[0], at[1])
      for(let local b in values(w.blasts)){
        local hit = false
        for(let local c in values(b.cells)){
          if(c == i){
            hit = true
            break
          }
        }
        if(hit){
          knock_out(w, p, b.owner)
          break
        }
      }
    }
  }
}

local func score(w){
  for(let local p in values(w.players)){
    p.score = 0
  }
  for(let local owner in values(w.paint)){
    if(owner > 0){
      local p = w.players[owner - 1]
      if(p != null){
        p.score = p.score + 1
      }
    }
  }
}

// step(world): one tick, with each player's input (a direction) as set
func rules.step(w){
  local dt = rules.TICK
  w.now = w.now + dt
  w.tick = w.tick + 1
  if(w.phase == "over"){
    return
  }
  for(let local p in values(w.players)){
    if(p.alive){
      move(w, p, dt)
    } else if(p.back_at <= w.now){
      local s = rules.SPAWNS[p.slot]
      p.x = s[0]
      p.y = s[1]
      p.tx = s[0]
      p.ty = s[1]
      p.alive = true
      p.safe_until = w.now + SAFE
    }
  }
  detonate(w)
  burn(w)
  score(w)
  w.left = w.left - dt
  if(w.left <= 0){
    w.left = 0
    w.phase = "over"
    // what still burns is put out: the floor is counted
    w.charges = {}
    w.blasts = {}
    for(let local p in values(w.players)){
      p.out = 0
    }
    local best = -1
    for(let local p in values(w.players)){
      if(best < 0 or p.score > w.players[best].score){
        best = p.slot
      }
    }
    w.winner = best
    append(w.events, {"over", best})
  }
}

// take_events(world) -> {{string, ...}}: what happened since the last call
func rules.take_events(w){
  local e = w.events
  w.events = {}
  return e
}

// ------------------------------------------------------------ snapshots

// snapshot(world) -> table: what clients need to draw the world (the
// fields of the "state" message)
func rules.snapshot(w){
  local players = {}
  for(let local p in values(w.players)){
    local at = rules.position(p)
    local flags = 0
    if(p.alive){
      flags = flags | 1
    }
    if(p.alive and p.safe_until > w.now){
      flags = flags | 2
    }
    append(players, {p.slot, at[0], at[1], p.dir, flags, p.kos, p.score, p.lens})
  }
  local charges = {}
  for(let local c in values(w.charges)){
    append(charges, {c.x, c.y, c.owner, to_int(math.max(0, c.at - w.now))})
  }
  local blasts = {}
  for(let local b in values(w.blasts)){
    append(blasts, {b.owner, str.from_bytes(b.cells)})
  }
  return {
    tick: w.tick, left: to_int(w.left), phase: w.phase, winner: w.winner,
    cells: str.from_bytes(w.cells), paint: str.from_bytes(w.paint),
    players: players, charges: charges, blasts: blasts,
  }
}

return rules
