// game/grid: maps as ASCII art. parse(rows) checks a map and finds its
// objects; dsl/map runs it while a mission file compiles, so a broken map
// is a compile error on its row.
//
//   #  wall          .  floor         %  window (blocks walking, not sight)
//   S  start         $  dossier       E  exit
//   D  door          L  laser         P  hack port
//   ^ > v <  camera, looking north, east, south or west
//
// x grows to the right, z downwards; cell (x, z) is centred on (x, z).
// Objects are named in reading order: door1, door2, cam1, laser1, port1...
// A door or laser stands between two walls (west and east, or north and
// south), a camera has a wall behind it, a port a wall beside it.
local str = require("slang/string")

local grid = {}

// the four directions: facing vectors and yaw (forward = cos yaw, sin yaw)
grid.dirs = {
  north: {dx: 0, dz: -1, yaw: -1.5707963267948966},
  east: {dx: 1, dz: 0, yaw: 0.0},
  south: {dx: 0, dz: 1, yaw: 1.5707963267948966},
  west: {dx: -1, dz: 0, yaw: 3.141592653589793},
}
grid.dir_order = {"north", "east", "south", "west"}

local camera_glyphs = {
  ["^"]: "north", [">"]: "east", ["v"]: "south", ["<"]: "west"
}
local kinds = {D: "door", L: "laser", P: "port"}
local prefixes = {door: "door", laser: "laser", port: "port", camera: "cam"}

// solid(ch) -> whether a glyph is wall for the map's shape (walls, windows
// and the outside)
func grid.wall_glyph(ch){
  return ch == "#" or ch == " " or ch == null
}

// parse(rows, fail) -> map. rows is a list of strings; fail(row, message)
// is called for a broken map (and must not return). The map is plain data:
//   {w, h, rows, start: {x, z, yaw}, dossier: {x, z}, exit: {x, z},
//    objects: {{kind, name, x, z, dir, axis}}}
func grid.parse(rows, fail){
  local h = len(rows)
  if(h == 0){
    fail(0, "a map needs at least one row")
  }
  local w = 0
  for(let local row in values(rows)){
    if(len(row) > w){
      w = len(row)
    }
  }
  // short rows are padded with outside
  local padded = {}
  for(let local row in values(rows)){
    append(padded, concat(row, " " * (w - len(row))))
  }
  local func at(x, z){
    if(x < 0 or z < 0 or x >= w or z >= h){
      return null
    }
    return str.char_at(padded[z], x)
  }
  local func wall_at(x, z){
    return grid.wall_glyph(at(x, z))
  }
  local m = {w: w, h: h, rows: padded, objects: {}}
  local counts = {}
  local singles = {S: "start", ["$"]: "dossier", E: "exit"}
  for(local z = 0; z < h; z = z + 1){
    for(local x = 0; x < w; x = x + 1){
      local ch = at(x, z)
      local where = concat("row ", z + 1, " column ", x + 1)
      if(singles[ch] != null){
        local key = singles[ch]
        if(m[key] != null){
          fail(z, concat(where, ": a second ", key, " (\"", ch, "\")"))
        }
        m[key] = {x: x, z: z}
      } else if(kinds[ch] != null or camera_glyphs[ch] != null){
        local kind = kinds[ch] or "camera"
        local o = {kind: kind, x: x, z: z}
        if(kind == "door" or kind == "laser"){
          if(wall_at(x - 1, z) and wall_at(x + 1, z)){
            o.axis = "x"
          } else if(wall_at(x, z - 1) and wall_at(x, z + 1)){
            o.axis = "z"
          } else {
            fail(z, concat(
              where, ": a ", kind,
              " needs walls on two opposite sides (west and east, or north and south)"
            ))
          }
        } else if(kind == "camera"){
          o.dir = camera_glyphs[ch]
          local d = grid.dirs[o.dir]
          if(not wall_at(x - d.dx, z - d.dz)){
            fail(z, concat(
              where,
              ": a camera looking ",
              o.dir,
              " needs a wall behind it",
            ))
          }
        } else {
          // a port hangs on a wall and faces away from it
          for(let local name in values(grid.dir_order)){
            local d = grid.dirs[name]
            if(o.dir == null and wall_at(x - d.dx, z - d.dz)){
              o.dir = name
            }
          }
          if(o.dir == null){
            fail(z, concat(where, ": a port needs a wall beside it"))
          }
        }
        local n = (counts[kind] or 0) + 1
        counts[kind] = n
        o.name = concat(prefixes[kind], n)
        append(m.objects, o)
      } else if(ch != "#" and ch != "." and ch != "%" and ch != " "){
        fail(z, concat(where, ": \"", ch, "\" is not a map glyph"))
      }
    }
  }
  for(let local key in values({"start", "dossier", "exit"})){
    if(m[key] == null){
      fail(0, concat("the map has no ", key))
    }
  }
  // the start looks down the longest open line
  local best = -1
  for(let local name in values(grid.dir_order)){
    local d = grid.dirs[name]
    local run = 0
    for(not wall_at(
      m.start.x + d.dx * (run + 1),
      m.start.z + d.dz * (run + 1),
    ) and
      at(m.start.x + d.dx * (run + 1), m.start.z + d.dz * (run + 1)) != "%"){
      run = run + 1
    }
    if(run > best){
      best = run
      m.start.yaw = d.yaw
    }
  }
  return m
}

// parse_text(text) -> map, raising an error for a broken map (for tests and
// maps made at run time)
func grid.parse_text(text){
  local rows = {}
  for(let local line in values(str.split(text, "\n"))){
    if(str.trim(line) != ""){
      append(rows, line)
    }
  }
  return grid.parse(rows, func(row, message){
    error("map: ", message)
  })
}

return grid
