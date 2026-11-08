// Grids of one value per cell, the directions, and small geometry.
local grid = {}

// the eight directions, cardinals first
grid.DIRS = {
  {1, 0}, {-1, 0}, {0, 1}, {0, -1},
  {1, 1}, {-1, 1}, {1, -1}, {-1, -1},
}
grid.CARDINALS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

// a w by h grid filled with v
func grid.new(w, h, v){
  local cells = {}
  for(local i = 0; i < w * h; i = i + 1){ cells[i] = v }
  return {w: w, h: h, cells: cells, @meta: {__index: grid}}
}

func grid.inside(g, x, y){
  return x >= 0 and y >= 0 and x < g.w and y < g.h
}

func grid.get(g, x, y){
  return g.cells[y * g.w + x]
}

func grid.set(g, x, y, v){
  g.cells[y * g.w + x] = v
}

func grid.fill(g, v){
  for(local i = 0; i < g.w * g.h; i = i + 1){ g.cells[i] = v }
}

func grid.copy(g){
  local c = grid.new(g.w, g.h, null)
  for(local i = 0; i < g.w * g.h; i = i + 1){ c.cells[i] = g.cells[i] }
  return c
}

// Whether a step from (x, y) by (dx, dy) cuts a corner: a diagonal step
// is only allowed when both cells it passes between are passable, so
// nothing moves or strikes around the corner of a wall, and a doorway
// holds one attacker at a time.
func grid.cuts_corner(passable, x, y, dx, dy){
  if(dx == 0 or dy == 0){ return false }
  return not passable(x + dx, y) or not passable(x, y + dy)
}

// Chebyshev distance: moves on an eight-way grid
func grid.distance(x1, y1, x2, y2){
  local dx = x1 - x2
  local dy = y1 - y2
  if(dx < 0){ dx = -dx }
  if(dy < 0){ dy = -dy }
  return dx > dy and dx or dy
}

// the cells of a straight line from (x1, y1) to (x2, y2) (Bresenham), the
// start excluded, the end included
func grid.line(x1, y1, x2, y2){
  local out = {}
  local dx = x2 - x1
  local dy = y2 - y1
  local sx = dx < 0 and -1 or 1
  local sy = dy < 0 and -1 or 1
  if(dx < 0){ dx = -dx }
  if(dy < 0){ dy = -dy }
  local err = dx - dy
  local x = x1
  local y = y1
  for(x != x2 or y != y2){
    local e2 = 2 * err
    if(e2 > -dy){
      err = err - dy
      x = x + sx
    }
    if(e2 < dx){
      err = err + dx
      y = y + sy
    }
    append(out, {x, y})
  }
  return out
}

return grid
