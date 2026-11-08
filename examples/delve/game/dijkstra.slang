// Dijkstra maps (Brian Walker, "The Incredible Power of Dijkstra Maps"):
// a grid holding, for every passable cell, the number of moves to the
// nearest goal. A monster chasing the player rolls downhill on the map
// from the player; a map multiplied by a negative number and rescanned is
// a map for fleeing that leads around corners instead of into them.
local grid = require("game/grid")

local dijkstra = {}

dijkstra.FAR = 1000000

// Fills g (a grid) from its goals: cells that already hold a value below
// FAR are goals, every other passable cell gets the moves to the nearest
// one, walls stay FAR. passable(x, y) says where moves are allowed.
// Eight-way moves, each costing one. A breadth-first scan with the goal
// cells as the frontier, so it costs one visit per cell.
func dijkstra.scan(g, passable){
  local w = g.w
  local h = g.h
  local cells = g.cells
  // the goals, ordered by value: a bucket queue, values are small integers
  local frontier = {}
  for(local i = 0; i < w * h; i = i + 1){
    if(cells[i] < dijkstra.FAR){
      append(frontier, i)
    }
  }
  // Dial's algorithm: process cells in order of value, which the
  // frontier is not in when the goals differ, so sort the initial goals
  local tbl = require("slang/table")
  tbl.sort(frontier, func(a, b) => cells[a] < cells[b])
  local head = 0
  for(head < len(frontier)){
    local i = frontier[head]
    head = head + 1
    local v = cells[i]
    local x = i % w
    local y = to_int(i / w)
    for(let local d in values(grid.DIRS)){
      local nx = x + d[0]
      local ny = y + d[1]
      if(nx >= 0 and ny >= 0 and nx < w and ny < h){
        local j = ny * w + nx
        if(cells[j] > v + 1 and passable(nx, ny) and not grid.cuts_corner(passable, x, y, d[0], d[1])){
          cells[j] = v + 1
          append(frontier, j)
        }
      }
    }
  }
  return g
}

// a new map with the goals given as {{x, y}, ...}
func dijkstra.from(w, h, goals, passable){
  local g = grid.new(w, h, dijkstra.FAR)
  for(let local p in values(goals)){
    g:set(p[0], p[1], 0)
  }
  return dijkstra.scan(g, passable)
}

// a map for fleeing from the goals of map g: every value times -1.2,
// rescanned, so that its low points are far from the goals and reachable
func dijkstra.flee(g, passable){
  local f = grid.new(g.w, g.h, dijkstra.FAR)
  for(local i = 0; i < g.w * g.h; i = i + 1){
    local v = g.cells[i]
    if(v < dijkstra.FAR){
      f.cells[i] = to_int(-1.2 * v)
    }
  }
  // scan needs non-negative integers: shift so the minimum is 0
  local min = 0
  for(local i = 0; i < g.w * g.h; i = i + 1){
    if(f.cells[i] < min){ min = f.cells[i] }
  }
  for(local i = 0; i < g.w * g.h; i = i + 1){
    if(f.cells[i] < dijkstra.FAR){ f.cells[i] = f.cells[i] - min }
  }
  return dijkstra.scan(f, passable)
}

// The neighbour of (x, y) with the lowest value below the cell's own, as
// {x, y}, or null when none is lower (the cell is a goal, or walled in).
// can_step(x, y, dx, dy) says whether a step from (x, y) by (dx, dy) is
// allowed right now (nothing stands there, no corner is cut); ties are
// broken by the order of grid.DIRS, cardinals first.
func dijkstra.downhill(g, x, y, can_step){
  local best = g:get(x, y)
  local step = null
  for(let local d in values(grid.DIRS)){
    local nx = x + d[0]
    local ny = y + d[1]
    if(g:inside(nx, ny)){
      local v = g:get(nx, ny)
      if(v < best and can_step(x, y, d[0], d[1])){
        best = v
        step = {nx, ny}
      }
    }
  }
  return step
}

return dijkstra
