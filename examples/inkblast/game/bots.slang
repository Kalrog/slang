// Bots: players the server moves itself, so a match needs no four people.
// A bot wants three things, in this order: out of any blast that is
// coming, a charge set where it breaks crates, paints or catches someone
// (when it can get away from it), and a goal to walk to: a pickup, a spot
// to set a charge, or foreign floor.
//
// A bot keeps a mind between ticks ([mind]): the goal it walks to (it
// sticks with one until it is reached or no good, so it does not dither
// between two), the spots where it found no way out, and when it may set
// its next charge. Its level makes it human: a bot sees a charge only some
// time after it was set, waits between its charges, and goes for players
// more or less.
local rules = require("game/rules")
local math = require("slang/math")

local bots = {}

local W = rules.W

// how a bot of each level plays
// [reaction]: ms before it notices a charge someone else set
// [cooldown]: ms between its charges
// [hunt]: how much a player in reach is worth, against a crate's 2
// [paint]: the least a charge must be worth on open floor
local LEVELS = {
  easy: {reaction: 650, cooldown: 2600, hunt: 0, paint: 7},
  normal: {reaction: 380, cooldown: 1500, hunt: 2, paint: 5},
  hard: {reaction: 0, cooldown: 0, hunt: 5, paint: 3},
}
bots.LEVELS = LEVELS

// mind(level?: string) -> table: what a bot remembers between ticks
func bots.mind(level){
  local l = LEVELS[level or "normal"]
  if(l == null){
    error(concat("inkblast: no bot level ", string(level), " (easy, normal or hard)"))
  }
  return {level: l, goal: null, kind: null, since: 0, tried: {}, next_drop: 0}
}

// cell -> ms until a blast reaches it (0 for one burning now), for the
// blasts and the charges this bot has noticed; cells that none reaches are
// not in it
local func danger(w, me, level){
  local d = {}
  for(let local b in values(w.blasts)){
    for(let local i in values(b.cells)){
      d[i] = 0
    }
  }
  local seen = {}
  for(let local c in values(w.charges)){
    if(c.owner == me.slot or w.now - c.set >= level.reaction){
      append(seen, c)
    }
  }
  // a charge goes off at its time or with the first blast that reaches
  // it, whichever is sooner: settled by passes until nothing changes
  local times = {}
  local reach = {}
  for(let local c in values(seen)){
    times[c] = math.max(0, c.at - w.now)
    reach[c] = rules.blast_cells(w, c.x, c.y, c.reach)
  }
  local changed = true
  for(changed){
    changed = false
    for(let local c in values(seen)){
      for(let local i in values(reach[c])){
        for(let local o in values(seen)){
          if(o != c and rules.index(o.x, o.y) == i and times[c] < times[o]){
            times[o] = times[c]
            changed = true
          }
        }
      }
    }
  }
  for(let local c in values(seen)){
    for(let local i in values(reach[c])){
      if(d[i] == null or times[c] < d[i]){
        d[i] = times[c]
      }
    }
  }
  return d
}

// every cell reachable from (x, y) within max_steps, avoiding cells that
// burn on the way: {order, first, steps}, with first[i] the direction of
// the first step towards i and steps[i] how many it takes
local func reachable(w, x, y, d, max_steps){
  local start = rules.index(x, y)
  local first = {}
  local steps = {}
  first[start] = 0
  steps[start] = 0
  local order = {start}
  local at = 0
  for(at < len(order)){
    local i = order[at]
    at = at + 1
    if(steps[i] >= max_steps){
      continue
    }
    local cx = i % W
    local cy = to_int((i - cx) / W)
    for(local dir = 1; dir <= 4; dir = dir + 1){
      local nx = cx + rules.DX[dir]
      local ny = cy + rules.DY[dir]
      local n = rules.index(nx, ny)
      if(first[n] == null and rules.passable(w, nx, ny)){
        // (a cell is reached after about 200 ms a step)
        local arrive = (steps[i] + 1) * 200
        local burns = d[n]
        if(burns == null or burns > arrive + 600 or burns < arrive - 450){
          first[n] = if(i == start){ dir } else { first[i] }
          steps[n] = steps[i] + 1
          append(order, n)
        }
      }
    }
  }
  return {order: order, first: first, steps: steps}
}

// what a charge at cell i would be worth: crates, foreign floor, players
local func worth(w, me, i, reach, level){
  local x = i % W
  local y = to_int((i - x) / W)
  local n = 0
  local crates = 0
  for(let local b in values(rules.blast_cells(w, x, y, reach))){
    local c = w.cells[b]
    if(c == rules.CRATE){
      n = n + 2
      crates = crates + 1
    } else if(w.paint[b] != me.slot + 1){
      n = n + 1
    }
    for(let local p in values(w.players)){
      if(p != me and p.alive){
        local at = rules.cell_of(p)
        if(rules.index(at[0], at[1]) == b){
          n = n + level.hunt
        }
      }
    }
  }
  // breaking crates is worth it at once; open floor only when there is a
  // lot of it to paint
  if(crates == 0 and n < level.paint){
    return 0
  }
  return n
}

// whether there is a way out of a charge's blast set at cell i
local func can_escape(w, i, reach, d){
  local x = i % W
  local y = to_int((i - x) / W)
  local mine = {}
  for(let local b in values(rules.blast_cells(w, x, y, reach))){
    mine[b] = true
  }
  local r = reachable(w, x, y, d, 6)
  for(let local c in values(r.order)){
    if(d[c] == null and not mine[c]){
      return true
    }
  }
  return false
}

// a new goal: the best of the reachable cells, nearer ones preferred
local func choose(w, me, mind, r, d, reach){
  local best = null
  local best_score = 0
  for(let local i in values(r.order)){
    if(d[i] == null and (mind.tried[i] == null or mind.tried[i] < w.now)){
      local c = w.cells[i]
      local score = 0
      local kind = null
      if(c == rules.POT or c == rules.LENS){
        score = 12
        kind = "pickup"
      } else {
        local value = worth(w, me, i, reach, mind.level)
        if(value > 0){
          score = value
          kind = "spot"
        } else if(w.paint[i] != me.slot + 1){
          score = 1
          kind = "floor"
        }
      }
      // a step costs a little; ties go to chance, once per choice
      score = score - r.steps[i] * 0.35 + w.random() * 0.5
      if(kind != null and (best == null or score > best_score)){
        best = {cell: i, kind: kind}
        best_score = score
      }
    }
  }
  return best
}

// think(world, slot, mind) -> {dir: int, drop: bool}: what the bot does now
func bots.think(w, slot, mind){
  local me = w.players[slot]
  if(me == null or not me.alive){
    if(mind != null){
      mind.goal = null
    }
    return {dir: 0, drop: false}
  }
  mind = mind or bots.mind()
  // between cells, the plan is made for the cell it is walking into: what
  // it returns is the way it goes from there once it arrives
  local x = me.x
  local y = me.y
  if(me.moving){
    x = me.tx
    y = me.ty
  }
  local here = rules.index(x, y)
  local d = danger(w, me, mind.level)
  local r = reachable(w, x, y, d, 30)
  local reach = if(me.lens > 0){ 4 } else { 2 }

  // out of the way of a blast: the nearest safe cell (turning back too)
  if(d[here] != null){
    mind.goal = null
    for(let local i in values(r.order)){
      if(d[i] == null){
        return {dir: r.first[i], drop: false}
      }
    }
    return {dir: 0, drop: false}
  }

  // the goal it has, while it is still good
  local goal = mind.goal
  if(goal != null){
    local stale = w.now - mind.since > 6000 or r.first[goal] == null or d[goal] != null
    local c = w.cells[goal]
    if(mind.kind == "pickup" and c != rules.POT and c != rules.LENS){
      stale = true
    } else if(mind.kind == "floor" and w.paint[goal] == me.slot + 1){
      stale = true
    }
    if(stale){
      goal = null
    }
  }
  if(goal == null){
    local g = choose(w, me, mind, r, d, reach)
    if(g == null){
      mind.goal = null
      return {dir: 0, drop: false}
    }
    goal = g.cell
    mind.goal = goal
    mind.kind = g.kind
    mind.since = w.now
  }

  if(goal == here){
    // there: it stops, and sets its charge if it can get away from it
    if(me.moving){
      return {dir: 0, drop: false}
    }
    mind.goal = null
    if(mind.kind == "spot"){
      if(w.now >= mind.next_drop and me.out < 2 and rules.charge_at(w, x, y) == null and can_escape(w, here, reach, d)){
        mind.next_drop = w.now + mind.level.cooldown
        return {dir: 0, drop: true}
      }
      // (not now: it does not come back here for a while)
      mind.tried[here] = w.now + 3000
    }
    return {dir: 0, drop: false}
  }
  local dir = r.first[goal]
  // no turning back on the way, unless fleeing (above)
  if(me.moving and dir == rules.OPPOSITE[me.dir]){
    return {dir: 0, drop: false}
  }
  return {dir: dir, drop: false}
}

return bots
