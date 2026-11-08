// An autoplayer: explores on a Dijkstra map whose goals are the edge of
// the known floor, picks up what it sees, fights what stands next to it,
// drinks when hurt, and takes the stairs once a floor is explored. It is
// how the game plays itself in tests (and with DELVE_AUTOPLAY=1), and a
// demonstration of the maps the monsters use.
local grid = require("game/grid")
local dijkstra = require("game/dijkstra")
local kinds = require("game/kinds")

local bot = {}

func bot.new(w){
  return {w: w, stood: {}, depth: 0, @meta: {__index: bot}}
}

local func pack_index(w, use){
  for(local i = 0; i < len(w.player.pack); i = i + 1){
    if(kinds.items[w.player.pack[i].kind].use == use){ return i }
  }
  return -1
}

// the step toward the nearest of the goals, or null
local func toward(w, goals){
  if(len(goals) == 0){ return null }
  local m = w.map
  local d = dijkstra.from(m.w, m.h, goals, func(x, y) => m:walkable(x, y) and w.seen:get(x, y))
  local p = w.player
  local s = dijkstra.downhill(d, p.x, p.y, func(x, y, dx, dy) => not grid.cuts_corner(func(cx, cy) => m:walkable(cx, cy), x, y, dx, dy))
  if(s == null){ return null }
  return {kind: "move", dx: s[0] - p.x, dy: s[1] - p.y}
}

// the next action
func bot.decide(b){
  local w = b.w
  local p = w.player
  if(b.depth != w.depth){
    b.depth = w.depth
    b.stood = {}
  }
  b.stood[p.y * w.map.w + p.x] = true
  // hurt: drink
  if(p.hp <= p.max_hp * 0.4 and pack_index(w, "heal") >= 0){
    return {kind: "use", index: pack_index(w, "heal")}
  }
  // something next to us: hit the weakest; crowded, back into a narrower spot first
  local walkable = func(x, y) => w.map:walkable(x, y)
  local target = null
  local crowd = 0
  for(let local mo in values(w.monsters)){
    if(grid.distance(mo.x, mo.y, p.x, p.y) <= 1 and
       not grid.cuts_corner(walkable, p.x, p.y, mo.x - p.x, mo.y - p.y)){
      crowd = crowd + 1
      if(target == null or mo.hp < target.hp){ target = mo }
    }
  }
  if(crowd >= 2){
    local retreat = b:narrower()
    if(retreat != null){ return retreat }
  }
  if(target != null){
    return {kind: "move", dx: target.x - p.x, dy: target.y - p.y}
  }
  // a wand and a monster in line: zap
  local wand = pack_index(w, "zap")
  if(wand >= 0){
    for(let local mo in values(w.monsters)){
      if(w.visible:get(mo.x, mo.y) and mo.hp >= 6){
        local dx = mo.x - p.x
        local dy = mo.y - p.y
        local ax = dx < 0 and -dx or dx
        local ay = dy < 0 and -dy or dy
        if((dx == 0 or dy == 0 or ax == ay) and (ax > ay and ax or ay) <= 7){
          return {kind: "use", index: wand, dir: {dx == 0 and 0 or (dx > 0 and 1 or -1), dy == 0 and 0 or (dy > 0 and 1 or -1)}}
        }
      }
    }
  }
  // an awake monster in sight: go for it before it comes for us (or
  // keeps shooting)
  local goals = {}
  for(let local mo in values(w.monsters)){
    if(mo.awake and w.visible:get(mo.x, mo.y) and grid.distance(mo.x, mo.y, p.x, p.y) <= 8){
      append(goals, {mo.x, mo.y})
    }
  }
  local step = toward(w, goals)
  if(step != null){ return step }
  // something here: take it (unless the pack is full of it)
  local here = w:items_at(p.x, p.y)
  if(len(here) > 0 and not b:refuses(here[0])){
    return {kind: "pickup"}
  }
  // something seen: go and get it
  goals = {}
  for(let local it in values(w.items)){
    if(w.seen:get(it.x, it.y) and not b:refuses(it)){ append(goals, {it.x, it.y}) }
  }
  step = toward(w, goals)
  if(step != null){ return step }
  // the edge of the known floor
  goals = {}
  for(local y = 0; y < w.map.h; y = y + 1){
    for(local x = 0; x < w.map.w; x = x + 1){
      if(w.seen:get(x, y) and w.map:walkable(x, y) and not b.stood[y * w.map.w + x]){
        for(let local d in values(grid.DIRS)){
          if(w.map.tiles:inside(x + d[0], y + d[1]) and not w.seen:get(x + d[0], y + d[1])){
            append(goals, {x, y})
            break
          }
        }
      }
    }
  }
  step = toward(w, goals)
  if(step != null){ return step }
  // explored: the stairs
  local s = w.map.stairs
  if(s != null){
    if(p.x == s[0] and p.y == s[1]){ return {kind: "descend"} }
    if(w.seen:get(s[0], s[1])){
      step = toward(w, {s})
      if(step != null){ return step }
    }
  }
  // nowhere to go: a teleport scroll, or wait
  if(pack_index(w, "teleport") >= 0){
    return {kind: "use", index: pack_index(w, "teleport")}
  }
  return {kind: "wait"}
}

// the number of cells something could attack (x, y) from
local func exposure(w, x, y){
  local walkable = func(cx, cy) => w.map:walkable(cx, cy)
  local n = 0
  for(let local d in values(grid.DIRS)){
    if(w.map:walkable(x + d[0], y + d[1]) and not grid.cuts_corner(walkable, x, y, d[0], d[1])){
      n = n + 1
    }
  }
  return n
}

// a step to a free neighbouring cell with fewer sides to attack from, or null
func bot.narrower(b){
  local w = b.w
  local p = w.player
  local walkable = func(x, y) => w.map:walkable(x, y)
  local best = exposure(w, p.x, p.y)
  local step = null
  for(let local d in values(grid.DIRS)){
    local x = p.x + d[0]
    local y = p.y + d[1]
    if(w.map:walkable(x, y) and w:monster_at(x, y) == null and
       not grid.cuts_corner(walkable, p.x, p.y, d[0], d[1])){
      local e = exposure(w, x, y)
      if(e < best){
        best = e
        step = {kind: "move", dx: d[0], dy: d[1]}
      }
    }
  }
  return step
}

// items the bot leaves: things it cannot carry or use
func bot.refuses(b, it){
  local w = b.w
  local k = kinds.items[it.kind]
  if(k.weapon != null){
    return k.weapon[0] + k.weapon[1] <= w.player.weapon.weapon[0] + w.player.weapon.weapon[1]
  }
  if(k.armor != null){
    return k.armor <= (w.player.armor and w.player.armor.armor or 0)
  }
  if(k.use != null){ return len(w.player.pack) >= 10 }
  return false
}

// plays one action; returns whether the game goes on
func bot.step(b){
  local w = b.w
  if(w.state != "playing"){ return false }
  local a = b:decide()
  local passed = w:act(a)
  if(not passed){
    // a move that failed (a wall remembered wrong?): wait instead
    w:act({kind: "wait"})
  }
  return w.state == "playing"
}

return bot
