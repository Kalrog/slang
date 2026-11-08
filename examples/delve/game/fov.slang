// Field of view by symmetric shadowcasting (Albert Ford's algorithm,
// albertford.com/shadowcasting): a floor cell is visible from the origin
// exactly when the origin is visible from it, and walls are revealed
// generously, so a room's boundary shows whole.
//
// Each of the four quadrants is scanned row by row away from the origin;
// a row carries the window of slopes still lit, and a wall after a floor
// splits off the rest of the window into a scan of its own. Slopes are
// fractions kept as numerator/denominator pairs, so nothing rounds.
local fov = {}

// floor division for integers of either sign
local func floor_div(a, b){
  local q = a / b
  local f = to_int(q)
  if(f > q){ f = f - 1 }
  return f
}

// slope to the left edge of a tile: (2 * col - 1) / (2 * depth)
local func slope(depth, col){
  return {2 * col - 1, 2 * depth}
}

// round(depth * s) with ties going up
local func ties_up(depth, s){
  // floor(n + 1/2) with n = depth * s[0] / s[1], s[1] > 0
  local num = 2 * depth * s[0] + s[1]
  local den = 2 * s[1]
  return to_int(floor_div(num, den))
}

// round(depth * s) with ties going down
local func ties_down(depth, s){
  // ceil(n - 1/2)
  local num = 2 * depth * s[0] - s[1]
  local den = 2 * s[1]
  return to_int(-floor_div(-num, den))
}

// col >= depth * start and col <= depth * end, as fractions
local func symmetric(depth, col, start, end){
  return col * start[1] >= depth * start[0] and col * end[1] <= depth * end[0]
}

// Computes what is visible from (ox, oy) up to radius cells away.
// blocking(x, y) says whether a cell stops sight (out of the map counts as
// blocking), reveal(x, y) is called once for every visible cell.
func fov.compute(ox, oy, radius, blocking, reveal){
  reveal(ox, oy)
  for(local q = 0; q < 4; q = q + 1){
    local func transform(depth, col){
      if(q == 0){ return {ox + col, oy - depth} }
      if(q == 1){ return {ox + col, oy + depth} }
      if(q == 2){ return {ox + depth, oy + col} }
      return {ox - depth, oy + col}
    }
    local func scan(depth, start, end){
      if(depth > radius){ return }
      local prev = null      // null, "wall" or "floor"
      local lo = ties_up(depth, start)
      local hi = ties_down(depth, end)
      for(local col = lo; col <= hi; col = col + 1){
        local p = transform(depth, col)
        local wall = blocking(p[0], p[1])
        local kind = wall and "wall" or "floor"
        if(wall or symmetric(depth, col, start, end)){
          if(depth * depth + col * col <= radius * radius + radius){
            reveal(p[0], p[1])
          }
        }
        if(prev == "wall" and not wall){
          start = slope(depth, col)
        }
        if(prev == "floor" and wall){
          scan(depth + 1, start, slope(depth, col))
        }
        prev = kind
      }
      if(prev == "floor"){
        scan(depth + 1, start, end)
      }
    }
    scan(1, {-1, 1}, {1, 1})
  }
}

return fov
