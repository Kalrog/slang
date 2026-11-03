// Bots: players the server moves itself, so a match needs no four people.
// A bot sees the world as the rules have it and wants three things, in
// this order: out of any blast that is coming, a charge set where it
// breaks crates or catches someone (when it can get away from it), and
// then the nearest pickup, crate or floor that is not its colour.
local rules = require("game/rules")
local math = require("slang/math")

local bots = {}

local W = rules.W

// cell -> ms until a blast reaches it (0 for one burning now); cells that
// no blast reaches are not in it
local func danger(w){
  local d = {}
  for(let local b in values(w.blasts)){
    for(let local i in values(b.cells)){
      d[i] = 0
    }
  }
  // a charge goes off at its time or with the first blast that reaches
  // it, whichever is sooner: settled by passes until nothing changes
  local times = {}
  local reach = {}
  for(let local c in values(w.charges)){
    times[c] = math.max(0, c.at - w.now)
    reach[c] = rules.blast_cells(w, c.x, c.y, c.reach)
  }
  local changed = true
  for(changed){
    changed = false
    for(let local c in values(w.charges)){
      for(let local i in values(reach[c])){
        for(let local o in values(w.charges)){
          if(o != c and rules.index(o.x, o.y) == i and times[c] < times[o]){
            times[o] = times[c]
            changed = true
          }
        }
      }
    }
  }
  for(let local c in values(w.charges)){
    for(let local i in values(reach[c])){
      if(d[i] == null or times[c] < d[i]){
        d[i] = times[c]
      }
    }
  }
  return d
}

// the first step of the shortest walk from (x, y) to a cell that wanted(i)
// accepts, avoiding cells that burn on the way: {dir, steps, cell} or null
local func search(w, x, y, wanted, d, max_steps){
  local start = rules.index(x, y)
  local first = {}
  local steps = {}
  first[start] = 0
  steps[start] = 0
  local queue = {start}
  local at = 0
  for(at < len(queue)){
    local i = queue[at]
    at = at + 1
    if(wanted(i)){
      return {dir: first[i], steps: steps[i], cell: i}
    }
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
          append(queue, n)
        }
      }
    }
  }
  return null
}

// whether a charge at (x, y) would hit something worth it
local func worth(w, me, x, y, reach){
  local n = 0
  for(let local i in values(rules.blast_cells(w, x, y, reach))){
    local c = w.cells[i]
    if(c == rules.CRATE){
      n = n + 2
    } else if(w.paint[i] != me.slot + 1){
      n = n + 1
    }
    for(let local p in values(w.players)){
      if(p != me and p.alive){
        local at = rules.cell_of(p)
        if(rules.index(at[0], at[1]) == i){
          n = n + 4
        }
      }
    }
  }
  return n
}

// think(world, slot) -> {dir: int, drop: bool}: what the bot does now
func bots.think(w, slot){
  local me = w.players[slot]
  if(me == null or not me.alive){
    return {dir: 0, drop: false}
  }
  // between cells, the plan is made for the cell it is walking into: what
  // it returns is the way it goes from there once it arrives
  local x = me.x
  local y = me.y
  if(me.moving){
    x = me.tx
    y = me.ty
  }
  local d = danger(w)
  local here = rules.index(x, y)
  local safe = func(i){ return d[i] == null }
  if(d[here] != null){
    local away = search(w, x, y, safe, d, 8)
    return {dir: if(away != null){ away.dir } else { 0 }, drop: false}
  }
  // a charge here: only when there is a way out of its blast
  local reach = if(me.lens > 0){ 4 } else { 2 }
  // (walking into the cell, it stops there first)
  if(me.out < 2 and rules.charge_at(w, x, y) == null and worth(w, me, x, y, reach) >= 3){
    local mine = {}
    for(let local i in values(rules.blast_cells(w, x, y, reach))){
      mine[i] = true
    }
    local escape = search(w, x, y, func(i){ return d[i] == null and not mine[i] }, d, 6)
    if(escape != null and (me.moving or w.random() < 0.7)){
      return {dir: 0, drop: not me.moving}
    }
  }
  // somewhere to go: a pickup, a cell next to a crate, foreign floor
  local goal = search(w, x, y, func(i){
    if(i == here or d[i] != null){
      return false
    }
    local c = w.cells[i]
    if(c == rules.POT or c == rules.LENS){
      return true
    }
    if(w.paint[i] != me.slot + 1 and w.random() < 0.15){
      return true
    }
    for(local dir = 1; dir <= 4; dir = dir + 1){
      if(w.cells[i + rules.DX[dir] + rules.DY[dir] * W] == rules.CRATE){
        return true
      }
    }
    return false
  }, d, 30)
  if(goal != null){
    return {dir: goal.dir, drop: false}
  }
  // nothing to do: a step that does not lead into a blast, or none
  local dir = math.random_int(1, 4)
  local n = rules.index(x + rules.DX[dir], y + rules.DY[dir])
  if(d[n] != null){
    dir = 0
  }
  return {dir: dir, drop: false}
}

return bots
