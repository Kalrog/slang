// game/structures: buildings made of parts. Each builder returns a list
// of specs (game/world's Spec) for a level or the editor to place; joints
// between some of them go into the options' `joints` (pairs of indices
// into the list, with a joint type). Walls
// of staggered bricks with gaps for doors and windows (glass in the
// windows), towers of rings of bricks, houses with gable roofs and
// furniture inside, bridges, stacks of crates.
local math = require("slang/math")
local vec = require("game/vec")
local materials = require("game/materials")

local m = {}

local BRICK = {x: 1, y: 0.5, z: 0.5}
local PLANK = {x: 2, y: 0.25, z: 0.5}

local next_group = 1

func m.group(){
  local g = next_group
  next_group = next_group + 1
  return g
}

func m.set_next_group(g){
  next_group = math.max(next_group, g)
}

// a point lx, lz in a structure's own frame (its origin and heading) in
// the world
local func place(o, lx, lz){
  local c = math.cos(o.yaw)
  local s = math.sin(o.yaw)
  return {x: o.x + lx * c + lz * s, z: o.z - lx * s + lz * c}
}

local func spec(o, kind, material, lx, y, lz, size, yaw, extra){
  local p = place(o, lx, lz)
  local sp = {
    kind: kind,
    material: material,
    pos: {x: p.x, y: y, z: p.z},
    size: {x: size.x, y: size.y, z: size.z},
    yaw: o.yaw + (yaw or 0),
    variant: o.r:int(4),
    group: o.group,
  }
  if(extra != null){
    for(let local e in entries(extra)){
      sp[e[0]] = e[1]
    }
  }
  return sp
}

// the parts of a brick between a and b (along the wall) that lie outside
// the openings of its row: the brick cut around doors and windows, as
// masons do; the openings are the gaps and the lintel zones over them
local func cut(pieces, from, to){
  local out = {}
  for(let local p in values(pieces)){
    if(to <= p[0] + 0.01 or from >= p[1] - 0.01){
      append(out, p)
    } else {
      if(from > p[0] + 0.2){
        append(out, {p[0], from})
      }
      if(to < p[1] - 0.2){
        append(out, {to, p[1]})
      }
    }
  }
  return out
}

local func row_pieces(a, b, bottom, top, openings){
  local pieces = {{a, b}}
  for(let local o in values(openings)){
    if(top > o.bottom + 0.01 and bottom < o.top - 0.01){
      pieces = cut(pieces, o.from, o.to)
    }
  }
  return pieces
}

// wall(o): o = {x, z, yaw, length, height, material?, brick?, gaps?, r,
// group, base}: a wall of staggered bricks centered on x, z running along
// its own x axis. Gaps are {from, to, bottom, top} along the wall and up
// it: openings with a lintel stone over them; windows (glass: true) get a
// pane.
func m.wall(o, out){
  out = out or {}
  local brick = o.brick or BRICK
  local material = o.material or "stone"
  local rows = to_int(o.height / brick.y + 0.5)
  local n = to_int(o.length / brick.x + 0.5)
  local length = n * brick.x
  // the openings: each gap, and the lintel's place over it (half a brick
  // wider at each side, one row high)
  local openings = {}
  local lintels = {}
  for(let local g in values(o.gaps or {})){
    append(openings, g)
    if(g.top < rows * brick.y - 0.01){
      local l = {
        from: g.from - brick.x / 2,
        to: g.to + brick.x / 2,
        bottom: g.top,
        top: g.top + brick.y,
      }
      append(openings, l)
      append(lintels, l)
    }
  }
  for(local row = 0; row < rows; row = row + 1){
    local y = o.base + brick.y * (row + 0.5)
    local bottom = row * brick.y
    local top = bottom + brick.y
    local offset = 0
    if(row % 2 == 1){
      offset = brick.x / 2
    }
    // the bricks of the row, from a half brick when it is staggered
    local edges = {0}
    local x = offset
    if(offset > 0){
      append(edges, offset)
    }
    for(x < length - 0.01){
      x = math.min(length, x + brick.x)
      append(edges, x)
    }
    for(local i = 1; i < len(edges); i = i + 1){
      local a = edges[i - 1]
      local b = edges[i]
      for(let local piece in values(row_pieces(a, b, bottom, top, openings))){
        local w = piece[1] - piece[0]
        append(out, spec(o, "box", material, (piece[0] + piece[1]) / 2 - length / 2,
          y, 0, {x: w, y: brick.y, z: brick.z}))
      }
    }
  }
  for(let local l in values(lintels)){
    local from = math.max(0, l.from)
    local to = math.min(length, l.to)
    append(out, spec(o, "box", material, (from + to) / 2 - length / 2,
      o.base + l.bottom + brick.y / 2, 0, {x: to - from, y: brick.y, z: brick.z}))
  }
  // panes in the windows
  for(let local g in values(o.gaps or {})){
    if(g.glass){
      local cx = (g.from + g.to) / 2 - length / 2
      append(out, spec(o, "box", "glass", cx, o.base + (g.bottom + g.top) / 2, 0, {
        x: g.to - g.from - 0.04, y: g.top - g.bottom - 0.04, z: 0.08
      }))
    }
  }
  return out
}

// tower(o): {x, z, yaw, radius, height, material?, r, group, base, roof?}:
// rings of bricks (each ring turned half a brick), a wooden top and
// battlements, or a pointed roof of planks
func m.tower(o, out){
  out = out or {}
  local material = o.material or "stone"
  local brick = o.brick or BRICK
  local circumference = 2 * math.pi * o.radius
  local n = math.max(6, to_int(circumference / brick.x + 0.5))
  // a brick's width: the chord at the ring's inner face, less a gap, so
  // the corners of neighbours do not overlap
  local width = 2 * (o.radius - brick.z / 2) * math.sin(math.pi / n) - 0.04
  local rows = to_int(o.height / brick.y + 0.5)
  for(local row = 0; row < rows; row = row + 1){
    local y = o.base + brick.y * (row + 0.5)
    local shift = 0
    if(row % 2 == 1){
      shift = math.pi / n
    }
    for(local i = 0; i < n; i = i + 1){
      local a = i * 2 * math.pi / n + shift
      local lx = math.sin(a) * o.radius
      local lz = math.cos(a) * o.radius
      append(out, spec(o, "box", material, lx, y, lz, {
        x: width, y: brick.y, z: brick.z
      }, a))
    }
  }
  local top = o.base + rows * brick.y
  if(o.roof == "cone"){
    // planks leaning together over a wooden floor
    append(out, spec(o, "cylinder", "wood", 0, top + 0.1, 0, {
      x: o.radius + 0.25, y: 0.2, z: o.radius + 0.25
    }))
    local planks = n
    local lean = 0.95
    local h = o.radius * 1.2
    local disc = len(out) - 1
    o.joints = o.joints or {}
    for(local i = 0; i < planks; i = i + 1){
      local a = i * 2 * math.pi / planks
      local r = o.radius * 0.55
      // the planks taper toward the top: narrow enough not to overlap
      local pw = 2 * r * math.sin(math.pi / planks) - 0.04
      append(out, spec(o, "box", "wood", math.sin(a) * r, top + 0.2 + h * 0.45,
        math.cos(a) * r, {x: pw, y: 0.12, z: h * 1.1}, a, {pitch: -lean}))
      // nailed to the floor: the roof comes off in one piece
      append(o.joints, {type: "fixed", a: disc, b: len(out) - 1})
    }
  } else {
    append(out, spec(o, "cylinder", "wood", 0, top + 0.1, 0, {
      x: o.radius + 0.25, y: 0.2, z: o.radius + 0.25
    }))
    // battlements: every other brick of one more ring
    for(local i = 0; i < n; i = i + 2){
      local a = i * 2 * math.pi / n
      append(out, spec(o, "box", material, math.sin(a) * o.radius, top + 0.2 + brick.y / 2,
        math.cos(a) * o.radius, {x: width, y: brick.y, z: brick.z}, a))
    }
  }
  return out
}

// the furniture of a room w x d (its own frame), on the floor at base
local func furnish(o, w, d, out){
  local r = o.r
  local fw = w / 2 - 0.6
  local fd = d / 2 - 0.6
  local func put(name, lx, lz, yaw){
    local mat = materials.get(name)
    local size = {x: mat.size[0], y: mat.size[1], z: mat.size[2]}
    append(out, spec(o, mat.shape, name, lx, o.base + size.y / 2, lz, size, yaw))
    return size
  }
  // a table with a vase on it and chairs beside it
  local tx = r:range(-fw * 0.4, fw * 0.4)
  local tz = r:range(-fd * 0.4, fd * 0.4)
  local table = put("table", tx, tz, 0)
  append(out, spec(o, "cylinder", "vase", tx, o.base + table.y + 0.35, tz, {
    x: 0.3, y: 0.7, z: 0.3
  }))
  put("chair", tx - table.x / 2 - 0.4, tz, math.pi / 2)
  put("chair", tx + table.x / 2 + 0.4, tz, -math.pi / 2)
  // along the walls: a shelf, a bed, a lamp
  if(w > 5){
    put("shelf", -fw + 0.2, fd - 0.2, 0)
    put("lamp", fw - 0.2, -fd + 0.2, 0)
  }
  if(d > 6 and w > 5){
    put("bed", fw - 0.7, 0, 0)
  }
}

// house(o): {x, z, yaw, width, depth, height, material?, r, group, base,
// furniture?, roof?: "gable" | "flat"}: four walls with a door at the
// front and windows, a roof of planks, and furniture inside
func m.house(o, out){
  out = out or {}
  local material = o.material or "stone"
  local w = o.width
  local d = o.depth
  local h = o.height
  local brick = BRICK
  local wall = func(cx, cz, yaw, length, gaps){
    m.wall({
      x: place(o, cx, cz).x,
      z: place(o, cx, cz).z,
      yaw: o.yaw + yaw,
      length: length,
      height: h,
      material: material,
      brick: brick,
      gaps: gaps,
      r: o.r,
      group: o.group,
      base: o.base,
    }, out)
  }
  local window = func(at){
    return {from: at - 0.5, to: at + 0.5, bottom: 1, top: 2, glass: true}
  }
  // front: a door in the middle, windows beside it
  local door = {from: w / 2 - 0.5, to: w / 2 + 0.5, bottom: 0, top: 2}
  local front = {door}
  if(w >= 6){
    append(front, window(w / 2 - 2))
    append(front, window(w / 2 + 2))
  }
  wall(0, d / 2 - brick.z / 2, 0, w, front)
  local back = {}
  if(w >= 6){
    append(back, window(w / 2 - 2))
    append(back, window(w / 2 + 2))
  } else {
    append(back, window(w / 2))
  }
  wall(0, -d / 2 + brick.z / 2, math.pi, w, back)
  local sides = {window(d / 2)}
  wall(w / 2 - brick.z / 2, 0, math.pi / 2, d - brick.z * 2, sides)
  wall(-w / 2 + brick.z / 2, 0, -math.pi / 2, d - brick.z * 2, sides)
  local top = o.base + to_int(h / brick.y + 0.5) * brick.y
  if(o.roof == "flat"){
    local planks = to_int(w / PLANK.z + 0.5)
    for(local i = 0; i < planks; i = i + 1){
      local lx = -w / 2 + PLANK.z * (i + 0.5)
      append(out, spec(o, "box", "wood", lx, top + 0.125, 0, {
        x: PLANK.z, y: 0.25, z: d + 0.4
      }))
    }
  } else {
    // a gable roof: the gable ends step up to a ridge beam; each side's
    // planks lean from the wall's top to the beam, shallow enough that
    // their friction holds them
    local steps = math.max(2, to_int(w * 0.27 / brick.y))
    for(local end = -1; end <= 1; end = end + 2){
      for(local s = 0; s < steps; s = s + 1){
        local width = math.max(1, w * (1 - (s + 0.5) / steps) - 0.8)
        append(out, spec(o, "box", material, 0, top + brick.y * (s + 0.5),
          end * (d / 2 - brick.z / 2), {x: width, y: brick.y, z: brick.z}))
      }
    }
    local beam_top = top + brick.y * steps + 0.3
    append(out, spec(o, "box", "wood", 0, beam_top - 0.15, 0, {
      x: 0.3, y: 0.3, z: d + 0.3
    }))
    // the underside of a plank runs from the wall's outer edge (and 0.3
    // beyond) up onto the beam, stopping just short of the other side's
    local run = w / 2 - 0.07
    local rise = beam_top - top
    local pitch = math.atan2(rise, run)
    local thickness = 0.12
    local p1x = w / 2 + 0.3 * math.cos(pitch)
    local p1y = top - 0.3 * math.sin(pitch)
    local p2x = 0.07
    local length = math.sqrt((p1x - p2x) * (p1x - p2x) + (beam_top - p1y) * (beam_top - p1y))
    local mx = (p1x + p2x) / 2 + math.sin(pitch) * thickness / 2
    local my = (p1y + beam_top) / 2 + math.cos(pitch) * thickness / 2
    local count = to_int((d + 0.3) / 0.6 + 0.5)
    local plank_d = (d + 0.3) / count
    for(local side = -1; side <= 1; side = side + 2){
      for(local i = 0; i < count; i = i + 1){
        local lz = -(d + 0.3) / 2 + plank_d * (i + 0.5)
        append(out, spec(o, "box", "wood", side * mx, my, lz, {
          x: length, y: thickness, z: plank_d - 0.03
        }, 0, {roll: -side * pitch}))
      }
    }
  }
  if(o.furniture != false){
    furnish(o, w - 1, d - 1, out)
  }
  return out
}

// stack(o): {x, z, yaw, rows, material?, size?, r, group, base}: a
// pyramid of crates
func m.stack(o, out){
  out = out or {}
  local size = o.size or {x: 0.8, y: 0.8, z: 0.8}
  local material = o.material or "wood"
  for(local row = 0; row < o.rows; row = row + 1){
    local count = o.rows - row
    for(local i = 0; i < count; i = i + 1){
      local lx = (i - (count - 1) / 2) * (size.x + 0.05)
      append(out, spec(o, "box", material, lx, o.base + size.y * (row + 0.5) + 0.02 * row, 0, size))
    }
  }
  return out
}

// pillar(o): {x, z, yaw, height, material?, r, group, base, radius?}: a
// column of round stones
func m.pillar(o, out){
  out = out or {}
  local radius = o.radius or 0.4
  local h = 0.5
  local n = to_int(o.height / h + 0.5)
  for(local i = 0; i < n; i = i + 1){
    append(out, spec(o, "cylinder", o.material or "stone", 0, o.base + h * (i + 0.5), 0, {
      x: radius, y: h, z: radius
    }))
  }
  return out
}

// bridge(o): {x, z, yaw, length, height, r, group, base}: planks across
// two pillars, with barrels on top
func m.bridge(o, out){
  out = out or {}
  m.pillar({x: place(o, -o.length / 2, 0).x, z: place(o, -o.length / 2, 0).z,
    yaw: o.yaw, height: o.height, r: o.r, group: o.group, base: o.base, radius: 0.7}, out)
  m.pillar({x: place(o, o.length / 2, 0).x, z: place(o, o.length / 2, 0).z,
    yaw: o.yaw, height: o.height, r: o.r, group: o.group, base: o.base, radius: 0.7}, out)
  local top = o.base + to_int(o.height / 0.5 + 0.5) * 0.5
  local n = 3
  for(local i = 0; i < n; i = i + 1){
    append(out, spec(o, "box", "wood", 0, top + 0.1, (i - 1) * 0.42, {
      x: o.length + 1, y: 0.2, z: 0.4
    }))
  }
  append(out, spec(o, "cylinder", "barrel", 0, top + 0.2 + 0.55, 0, {
    x: 0.45, y: 1.1, z: 0.45
  }))
  return out
}

// the footprint of a structure: its radius on the ground, for levels to
// flatten
func m.footprint(kind, o){
  if(kind == "house"){
    return math.sqrt(o.width * o.width + o.depth * o.depth) / 2 + 1.5
  }
  if(kind == "tower"){
    return o.radius + 1.5
  }
  if(kind == "wall" or kind == "bridge"){
    return o.length / 2 + 1
  }
  return 3
}

m.builders = {
  wall: m.wall,
  tower: m.tower,
  house: m.house,
  stack: m.stack,
  pillar: m.pillar,
  bridge: m.bridge,
}

return m
