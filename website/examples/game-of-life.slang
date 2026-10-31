// Game of Life
local width = 20
local height = 10
local cells = {}
for(local y = 0; y < height; y = y + 1){
  local row = {}
  for(local x = 0; x < width; x = x + 1){
    append(row, false)
  }
  append(cells, row)
}
// a glider and a blinker
local glider = {{1, 0}, {2, 1}, {0, 2}, {1, 2}, {2, 2}}
local blinker = {{12, 4}, {13, 4}, {14, 4}}
for(let {local x, local y} in values({...glider, ...blinker})){
  cells[y][x] = true
}

local func alive(x, y){
  local row = cells[(y + height) % height]
  return row[(x + width) % width]
}

local func step(){
  local next = {}
  for(local y = 0; y < height; y = y + 1){
    local row = {}
    for(local x = 0; x < width; x = x + 1){
      local n = 0
      for(local dy = -1; dy <= 1; dy = dy + 1){
        for(local dx = -1; dx <= 1; dx = dx + 1){
          if((dx != 0 or dy != 0) and alive(x + dx, y + dy)){
            n = n + 1
          }
        }
      }
      append(row, n == 3 or (n == 2 and cells[y][x]))
    }
    append(next, row)
  }
  cells = next
}

for(local generation = 0; generation < 4; generation = generation + 1){
  print("generation ", generation, "\n")
  for(local y = 0; y < height; y = y + 1){
    local line = ""
    for(local x = 0; x < width; x = x + 1){
      line = concat(line, cells[y][x] and "#" or ".")
    }
    print(line, "\n")
  }
  step()
}
