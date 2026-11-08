// Dungeon floors: a grid of tiles made of rooms joined by corridors, with
// doors where a corridor meets a room, stairs down somewhere far from
// where the player arrives, and a few loops so that there is more than
// one way around.
local grid = require("game/grid")
local rng = require("game/rng")
local dijkstra = require("game/dijkstra")

local map = {}

map.W = 64
map.H = 30

// tiles
map.WALL = 0
map.FLOOR = 1
map.DOOR = 2        // closed: blocks sight, not movement (opens when walked into)
map.OPEN_DOOR = 3
map.STAIRS = 4
map.ROCK = 5        // solid rock between rooms: never carved, same as WALL to the player

local MIN_ROOMS = 7
local MAX_ROOMS = 11

func map.walkable(m, x, y){
  if(not m.tiles:inside(x, y)){ return false }
  local t = m.tiles:get(x, y)
  return t != map.WALL and t != map.ROCK
}

func map.opaque(m, x, y){
  if(not m.tiles:inside(x, y)){ return true }
  local t = m.tiles:get(x, y)
  return t == map.WALL or t == map.ROCK or t == map.DOOR
}

func map.in_room(m, x, y){
  for(let local r in values(m.rooms)){
    if(x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h){
      return r
    }
  }
  return null
}

local func carve_room(m, r){
  for(local y = r.y; y < r.y + r.h; y = y + 1){
    for(local x = r.x; x < r.x + r.w; x = x + 1){
      m.tiles:set(x, y, map.FLOOR)
    }
  }
}

local func overlaps(a, b, gap){
  return a.x < b.x + b.w + gap and b.x < a.x + a.w + gap and
    a.y < b.y + b.h + gap and b.y < a.y + a.h + gap
}

// carves one cell of corridor; a wall of a room becomes a door
local func carve(m, x, y){
  local t = m.tiles:get(x, y)
  if(t == map.FLOOR){ return }
  // a corridor cell next to a room's floor, on the room's edge, is a door:
  // it is on the room's bounding box (the walls around the room)
  local door = false
  for(let local r in values(m.rooms)){
    local on_edge = (x == r.x - 1 or x == r.x + r.w) and y >= r.y - 1 and y <= r.y + r.h
    on_edge = on_edge or ((y == r.y - 1 or y == r.y + r.h) and x >= r.x - 1 and x <= r.x + r.w)
    if(on_edge){ door = true }
  }
  m.tiles:set(x, y, door and map.DOOR or map.FLOOR)
}

// an L-shaped corridor between two points, the bend chosen at random
local func corridor(m, x1, y1, x2, y2){
  local horizontal_first = rng.chance(0.5)
  local x = x1
  local y = y1
  if(horizontal_first){
    for(x != x2){ x = x + (x2 > x and 1 or -1); carve(m, x, y) }
    for(y != y2){ y = y + (y2 > y and 1 or -1); carve(m, x, y) }
  } else {
    for(y != y2){ y = y + (y2 > y and 1 or -1); carve(m, x, y) }
    for(x != x2){ x = x + (x2 > x and 1 or -1); carve(m, x, y) }
  }
}

local func center(r){
  return {r.x + to_int(r.w / 2), r.y + to_int(r.h / 2)}
}

// doors that ended up next to each other or in the open become floor,
// and a door with floor on more than two sides is not a doorway
local func tidy_doors(m){
  for(local y = 1; y < m.h - 1; y = y + 1){
    for(local x = 1; x < m.w - 1; x = x + 1){
      if(m.tiles:get(x, y) == map.DOOR){
        local open = 0
        for(let local d in values(grid.CARDINALS)){
          local t = m.tiles:get(x + d[0], y + d[1])
          if(t != map.WALL and t != map.ROCK){ open = open + 1 }
        }
        // a doorway sits between two walls: wall above and below, or left and right
        local ns = m.tiles:get(x, y - 1) == map.WALL and m.tiles:get(x, y + 1) == map.WALL
        local ew = m.tiles:get(x - 1, y) == map.WALL and m.tiles:get(x + 1, y) == map.WALL
        if(open != 2 or not (ns or ew)){
          m.tiles:set(x, y, map.FLOOR)
        }
      }
    }
  }
  // no two doors side by side
  for(local y = 1; y < m.h - 1; y = y + 1){
    for(local x = 1; x < m.w - 1; x = x + 1){
      if(m.tiles:get(x, y) == map.DOOR){
        for(let local d in values(grid.CARDINALS)){
          if(m.tiles:get(x + d[0], y + d[1]) == map.DOOR){
            m.tiles:set(x + d[0], y + d[1], map.FLOOR)
          }
        }
      }
    }
  }
}

// A random cell of the floor (not a door, not stairs), or null
func map.random_floor(m){
  for(local tries = 0; tries < 1000; tries = tries + 1){
    local x = rng.int(1, m.w - 2)
    local y = rng.int(1, m.h - 2)
    if(m.tiles:get(x, y) == map.FLOOR){
      return {x, y}
    }
  }
  return null
}

// Generates a floor. depth adds rooms and (later) monsters; the result is
// {w, h, tiles, rooms, start: {x, y}, stairs: {x, y}}
func map.generate(depth){
  for(local attempt = 0; attempt < 50; attempt = attempt + 1){
    local m = {w: map.W, h: map.H, tiles: grid.new(map.W, map.H, map.WALL), rooms: {}, @meta: {__index: map}}
    local n = rng.int(MIN_ROOMS, MAX_ROOMS)
    for(local tries = 0; tries < 300 and len(m.rooms) < n; tries = tries + 1){
      local w = rng.int(4, 12)
      local h = rng.int(3, 7)
      local r = {x: rng.int(1, m.w - w - 2), y: rng.int(1, m.h - h - 2), w: w, h: h}
      local ok = true
      for(let local o in values(m.rooms)){
        if(overlaps(r, o, 2)){ ok = false }
      }
      if(ok){ append(m.rooms, r) }
    }
    if(len(m.rooms) < MIN_ROOMS){ continue }
    for(let local r in values(m.rooms)){ carve_room(m, r) }
    // join the rooms in order of their x, then add a few loops
    local tbl = require("slang/table")
    tbl.sort(m.rooms, func(a, b) => a.x < b.x)
    for(local i = 1; i < len(m.rooms); i = i + 1){
      local a = center(m.rooms[i - 1])
      local b = center(m.rooms[i])
      corridor(m, a[0], a[1], b[0], b[1])
    }
    local loops = rng.int(1, 3)
    for(local i = 0; i < loops; i = i + 1){
      local a = center(rng.pick(m.rooms))
      local b = center(rng.pick(m.rooms))
      corridor(m, a[0], a[1], b[0], b[1])
    }
    tidy_doors(m)
    // start in the first room, stairs in the room farthest from it by moves
    local first = m.rooms[0]
    m.start = center(first)
    local d = dijkstra.from(m.w, m.h, {m.start}, func(x, y) => m:walkable(x, y))
    local best = null
    local best_d = -1
    for(let local r in values(m.rooms)){
      local c = center(r)
      local v = d:get(c[0], c[1])
      if(v < dijkstra.FAR and v > best_d){
        best_d = v
        best = c
      }
    }
    if(best == null or best_d < 20){ continue }
    // every room must be reachable
    local reachable = true
    for(let local r in values(m.rooms)){
      local c = center(r)
      if(d:get(c[0], c[1]) >= dijkstra.FAR){ reachable = false }
    }
    if(not reachable){ continue }
    m.stairs = best
    m.tiles:set(best[0], best[1], map.STAIRS)
    return m
  }
  raise(error.new(error.kinds.internal, "could not generate a floor"))
}

// the floor as text, for tests and the log
func map.to_text(m, overlay){
  local str = require("slang/string")
  local lines = {}
  for(local y = 0; y < m.h; y = y + 1){
    local row = {}
    for(local x = 0; x < m.w; x = x + 1){
      local c = overlay and overlay(x, y)
      if(c == null){
        local t = m.tiles:get(x, y)
        if(t == map.WALL or t == map.ROCK){ c = "#" }
        else if(t == map.FLOOR){ c = "." }
        else if(t == map.DOOR){ c = "+" }
        else if(t == map.OPEN_DOOR){ c = "'" }
        else if(t == map.STAIRS){ c = ">" }
        else { c = "?" }
      }
      append(row, c)
    }
    append(lines, str.join(row, ""))
  }
  return str.join(lines, "\n")
}

return map
