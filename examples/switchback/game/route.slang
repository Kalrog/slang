// game/route: the trails. The first, the Summit Run, leads from the
// trailhead on the meadow over the river, past the lake and up to the
// summit of the highest mountain. Others branch off it to what else there
// is to see (a lookout on a ridge, the lake's far shore, the headwaters),
// and some of those go on to meet the others again, so that the trails
// split and meet and make loops. Nobody draws them: each is the cheapest
// way over the land for a track that may not be steep, found on a coarse
// grid (so it winds up a slope in switchbacks and takes a side valley
// where there is one), then smoothed into a line, pushed apart where it
// passes itself too near (the legs of a switchback need room for the
// bank between them), and cut into the land as a level track with banks
// (game/trail.kernel).
//
//   local net = route.network(land)    // {trails, main, camps}
//   route.carve(land, net.trails)      // the land's heights get the tracks
//   route.plan(land)                   // the Summit Run alone
//   route.near(land, x, z)             // which track is how near a place
local math = require("slang/math")
local kernel = require("kernel")
local vec = require("game/vec")
local terrain = require("game/terrain")

// (between kernels: whoever shows the making of the land may draw a frame,
// see terrain.tick)
local func tick(){
  if(terrain.tick != null){
    terrain.tick()
  }
}
local trail_kernels = require("game/trail")
local land_kernels = require("game/land")

local m = {}

m.BLOCK = 8 // samples along a side of a square of the coarse grid
m.STEP = 2.0 // meters between the trail's points
m.FINE_STEP = 0.5 // and between the points of the line it is cut along
m.HALF_WIDTH = 2.3 // of the track, m
m.REACH = 20.0 // how far from its line the track's banks reach, m
m.DEEPEST = 7.0 // deeper than this the track is not cut: a ridge gets a pass
m.ROOM_GAP = 6 // points of a trail's line this far apart along it and more
// are pushed apart where they lie too near each other (see roomy), and
m.ROOM_STILL = 10 // this many points at each end of it stay where they are
m.ROOM_PASSES = 4 // and this many times over, at most
m.ROOM_WIDER = 1.5 // (a track is wider than usual in a tight turn: room for
// that, m)
m.APART = 10.0 // two places of a track this far apart along it, m, and
// both near a place beside it, are two stretches of it there (the legs
// of a switchback): the land between is shaped by both
m.GRADE = 0.16 // the rise over run the way should not exceed
m.PITCH = 0.22 // and that no step of the way does, where the land allows
m.STEEPEST = 0.24 // the steepest the finished track is, but on a steep climb
m.CLIMB = 0.42 // the steepest it is on a climb up the mountain (the
// Summit Run's): it is not dug into the mountain

// the river's x at a z
local func river_x(land, z){
  local best = 1.0e9
  local x = 0
  for(let local p in values(land.river.points)){
    local d = math.abs(p.z - z)
    if(d < best){
      best = d
      x = p.x
    }
  }
  return x
}

// corners cut off a line of points, n times (the ends stay)
local func rounded(points, times){
  for(local t = 0; t < times; t = t + 1){
    local out = {points[0]}
    for(local i = 0; i + 1 < len(points); i = i + 1){
      local a = points[i]
      local b = points[i + 1]
      append(out, {x: a.x * 0.75 + b.x * 0.25, z: a.z * 0.75 + b.z * 0.25})
      append(out, {x: a.x * 0.25 + b.x * 0.75, z: a.z * 0.25 + b.z * 0.75})
    }
    append(out, points[len(points) - 1])
    points = out
  }
  return points
}

// a line of points again as points `step` apart along it
local func resampled(points, step){
  local out = {points[0]}
  local carry = 0
  for(local i = 0; i + 1 < len(points); i = i + 1){
    local a = points[i]
    local b = points[i + 1]
    local dx = b.x - a.x
    local dz = b.z - a.z
    local l = math.sqrt(dx * dx + dz * dz)
    local at = step - carry
    for(at <= l){
      append(out, {x: a.x + dx * at / l, z: a.z + dz * at / l})
      at = at + step
    }
    carry = l - (at - step)
  }
  return out
}

// whether the segments a-b and c-d cross or touch
local func segments_cross(a, b, c, d){
  local func side(p, q, r){
    return (q.x - p.x) * (r.z - p.z) - (q.z - p.z) * (r.x - p.x)
  }
  local d1 = side(c, d, a)
  local d2 = side(c, d, b)
  local d3 = side(a, b, c)
  local d4 = side(a, b, d)
  return d1 * d2 <= 0 and d3 * d4 <= 0 and
    (d1 != 0 or d2 != 0 or d3 != 0 or d4 != 0)
}

// where a line of points crosses itself: the index of the first point of
// the later of two segments that cross (or meet again), or null
local func crossing(line){
  local count = len(line)
  for(local j = 2; j + 1 < count; j = j + 1){
    local c = line[j]
    local d = line[j + 1]
    for(local i = 0; i + 1 < j; i = i + 1){
      local a = line[i]
      local b = line[i + 1]
      // (only what is near enough to cross: steps are short)
      if(math.abs(a.x - c.x) < 80 and math.abs(a.z - c.z) < 80 and
        segments_cross(a, b, c, d)){
        return j
      }
    }
  }
  return null
}

// What the trail has in store, by kind: its name, how long it is (m), and
// how fast a careful driver takes it (m/s).
m.OBSTACLES = {
  mud: {name: "Mud Hole", length: 26, pace: 3.0},
  humps: {name: "The Moguls", length: 38, pace: 2.3},
  washout: {name: "Washouts", length: 30, pace: 2.6},
  camber: {name: "Off-Camber", length: 44, pace: 3.0},
  narrows: {name: "The Narrows", length: 100, pace: 3.0},
  steps: {name: "Rock Steps", length: 32, pace: 2.1},
  rocks: {name: "Rock Garden", length: 34, pace: 1.7},
  logs: {name: "Deadfall", length: 26, pace: 1.6},
  // (not placed: where the Summit Run climbs steeper than a track's usual)
  climb: {name: "Steep Climb", length: 0, pace: 2.2},
}

// an obstacle rises and falls over five meters at its ends: how much of
// it there is at s meters along the trail
local func ramp_of(section, s){
  local ramp = vec.clamp(math.min(s - section.from, section.to - s) / 5, 0, 1)
  return ramp * ramp * (3 - 2 * ramp)
}

// obstacles(land, points, bends) -> {Section}: stretches of the trail
// made hard on purpose, a few hundred meters apart, each of a kind that
// suits where it is: mud holes and washouts on the valley's floor, humps
// that lift a wheel off the ground, a track tilted with the hillside,
// rock standing close on both sides, ledges up in the rock, stones strewn
// over the track, trunks fallen across it (game/props sets the stones
// and the trunks down). The points
// of a stretch get what the trail's kernels build it from (see
// trail.kernel's near) and `pace`, the speed to take it at. None is in
// the stretches `keep` ({from, to}, meters along: camps, junctions).
local func obstacles(land, points, bends, seed, keep){
  local rng = vec.random(seed)
  local count = len(points)
  local step = m.STEP
  local sections = {}
  local last = null
  local before = null
  local length = (count - 1) * step
  // (a long trail starts and ends with a quiet stretch, a short one has
  // its first obstacle sooner)
  local first = if(length > 2500){ 150 } else { 50 }
  local ends = if(length > 2500){ 190 } else { 60 }
  local at = first + rng:range(0, 70)
  for(at < length - ends){
    local i0 = to_int(at / step)
    local p = points[i0]
    // where it is: how high over the river, how steep the land lies
    // across it, whether it climbs
    local n = land.n
    local row = to_int(
      vec.clamp((p.z + land.half) / land.spacing + 0.5, 0, n - 1),
    )
    local over = p.y - land.water[row * n]
    local yaw = math.atan2(points[i0 + 1].x - p.x, points[i0 + 1].z - p.z)
    local lx = math.cos(yaw)
    local lz = -math.sin(yaw)
    local left = terrain.height_at(land, p.x + lx * 6, p.z + lz * 6)
    local right = terrain.height_at(land, p.x - lx * 6, p.z - lz * 6)
    local cross = (left - right) / 12
    local climb = (points[math.min(count - 1, i0 + 16)].y - p.y) / (16 * step)
    local kinds = {}
    if(over < 14){
      kinds = {"mud", "humps", "washout", "mud", "logs"}
    } else if(p.y > 330){
      kinds = {"steps", "narrows", "humps", "rocks", "rocks"}
    } else if(math.abs(cross) > 0.33){
      kinds = {"camber", "narrows", "washout", "rocks"}
      if(climb > 0.06){
        append(kinds, "steps")
      }
    } else if(math.abs(cross) < 0.09 and math.abs(climb) < 0.035){
      // level ground: water stands on it
      kinds = {"mud", "humps", "logs", "mud", "washout"}
    } else {
      kinds = {"humps", "washout", "camber", "narrows", "logs", "rocks"}
    }
    // (not what came just before, if it can be helped)
    local kind = rng:pick(kinds)
    for(local again = 0; again < 4 and (kind == last or kind == before); again = again +
      1){
      kind = rng:pick(kinds)
    }
    // (narrows are cut out of rock that is there: not where the land
    // beside the track is no higher than the track)
    if(kind == "narrows" and math.max(left, right) - p.y < 2){
      kind = "rocks"
    }
    local spec = m.OBSTACLES[kind]
    local i1 = math.min(count - 2, i0 + to_int(spec.length / step))
    // not in a bend, not in the water
    local fits = true
    for(local i = math.max(0, i0 - 6); i <= math.min(count - 1, i1 + 6); i = i +
      1){
      if(bends[i] > 0.3 or
        terrain.water_at(land, points[i].x, points[i].z) > 0.02){
        fits = false
      }
    }
    for(let local r in values(keep)){
      if(i1 * step + 12 > r.from and i0 * step - 12 < r.to){
        fits = false
      }
    }
    if(not fits){
      at = at + 24
      continue
    }
    before = last
    last = kind
    local section = {
      kind: kind,
      name: spec.name,
      from: i0 * step,
      to: i1 * step,
      index: i0,
      last: i1,
      way: 1,
    }
    if(kind == "camber"){
      section.way = if(cross >= 0){ 1 } else { -1 }
    } else if(kind == "steps"){
      section.way = if(climb >= 0){ 1 } else { -1 }
    }
    for(local i = i0; i <= i1; i = i + 1){
      local q = points[i]
      local ramp = ramp_of(section, i * step)
      q.pace = spec.pace
      if(kind == "mud"){
        q.mud = 1
      } else if(kind == "humps"){
        q.wave = 0.19 * ramp
      } else if(kind == "camber"){
        q.tilt = section.way * 0.17 * ramp
      } else if(kind == "narrows"){
        // (narrower, and the land beside it cut as rock: trail.kernel's cut)
        q.wall = ramp
        q.half = math.min(q.half, 2.3 - 0.55 * ramp)
      }
    }
    append(sections, section)
    at = i1 * step + rng:range(170, 300)
  }
  return sections
}

// offset(sections, s) -> how much higher (or lower) than the even track an
// obstacle makes it at s meters along the trail: a mud hole lies lower,
// washouts are three ditches across the track, rock steps are ledges
// facing the way up (level, then a step). The other obstacles are built
// across the track, not along it (see trail.kernel's cut).
func m.offset(sections, s){
  for(let local section in values(sections)){
    if(s >= section.from and s <= section.to){
      local ramp = ramp_of(section, s)
      local in = s - section.from
      if(section.kind == "mud"){
        return -0.3 * ramp
      }
      if(section.kind == "washout"){
        local sum = 0
        for(let local ditch in values({6, 15, 24})){
          local d = (in - ditch) / 1.2
          sum = sum - 0.36 * math.exp(-d * d)
        }
        return sum
      }
      if(section.kind == "steps"){
        local tread = 3.2
        local f = in / tread - math.floor(in / tread)
        // (the step itself over a third of a meter, not a knife's edge)
        local riser = vec.clamp((f - 0.9) / 0.1, 0, 1)
        return section.way * 0.21 * (0.5 - f + riser) * ramp
      }
      return 0
    }
  }
  return 0
}

m.CAMP_HALF = 4.6 // half the width of the clearing at a camp, m
m.JOIN_GAP = 70 // the least distance between two junctions, m
m.JOIN_ANGLE = 55 // the least angle a trail leaves another at, degrees
m.CROSS = 0.07 // the most a trail is tilted across where another
// leaves it (the rise across per meter)
m.JOIN_CLEAR = 50 // no obstacle this near a junction, m (on both trails)

// ------------------------------------------------------------ finding ways

// the land in squares for finding ways over it, and the search's scratch
local func grid(land){
  local n = land.n
  local block = m.BLOCK
  local cm = to_int(n / block)
  local g = {land: land, cm: cm, cell: block * land.spacing}
  g.height = kernel.float:array(cm * cm)
  g.steep = kernel.float:array(cm * cm)
  g.wet = kernel.float:array(cm * cm)
  trail_kernels.coarse(
    g.height, g.steep, g.wet, cm, block, land.heights, land.water, n,
    land.spacing
  )
  // nothing at the land's edge, and not much near it
  g.base = kernel.float:array(cm * cm)
  for(local j = 0; j < cm; j = j + 1){
    for(local i = 0; i < cm; i = i + 1){
      local edge = math.min(math.min(i, j), math.min(cm - 1 - i, cm - 1 - j))
      if(edge < 3){
        g.base[j * cm + i] = 1.0e9
      } else if(edge < 12){
        g.base[j * cm + i] = (12 - edge) * 14
      }
    }
  }
  g.toll = kernel.float:array(cm * cm)
  g.toll:set(g.base)
  g.targets = kernel.uint8:array(cm * cm)
  // the search's states: sixteen directions a square (see trail.kernel)
  local states = cm * cm * 16
  g.cost = kernel.double:array(states)
  g.from = kernel.int32:array(states)
  g.room = states * 6
  g.heap_key = kernel.double:array(g.room)
  g.heap_cell = kernel.int32:array(g.room)
  g.done = kernel.uint8:array(states)
  // the directions round the compass: neighbors and knight's moves in turn
  g.dir_x = kernel.int32:array({
    1, 2, 1, 1, 0, -1, -1, -2, -1, -2, -1, -1, 0, 1, 1, 2
  })
  g.dir_z = kernel.int32:array({
    0, 1, 1, 2, 1, 2, 1, 1, 0, -1, -1, -2, -1, -2, -1, -1
  })
  return g
}

local func square_of(g, x, z){
  local land = g.land
  local i = to_int(vec.clamp((x + land.half) / g.cell, 0, g.cm - 1))
  local j = to_int(vec.clamp((z + land.half) / g.cell, 0, g.cm - 1))
  return j * g.cm + i
}

local func place_of(g, square){
  local i = square % g.cm
  local j = to_int((square - i) / g.cm)
  return {
    x: (i + 0.5) * g.cell - g.land.half,
    z: (j + 0.5) * g.cell - g.land.half,
  }
}

// how steep the coarse land is at a square (rise over run)
local func gradient(g, i, j){
  local cm = g.cm
  local h = g.height
  local gx = (h[j * cm + i + 1] - h[j * cm + i - 1]) / (2 * g.cell)
  local gz = (h[(j + 1) * cm + i] - h[(j - 1) * cm + i]) / (2 * g.cell)
  return math.sqrt(gx * gx + gz * gz)
}

// the best square of a rectangle of the land by a score
local func find(g, x0, x1, z0, z1, score){
  local cm = g.cm
  local best = -1.0e30
  local found = null
  for(local j = 3; j < cm - 3; j = j + 1){
    for(local i = 3; i < cm - 3; i = i + 1){
      local p = place_of(g, j * cm + i)
      if(p.x >= math.min(x0, x1) and p.x <= math.max(x0, x1) and p.z >= z0 and
        p.z <= z1){
        local value = score(
          p, g.height[j * cm + i], gradient(g, i, j), g.wet[j * cm + i]
        )
        if(value > best){
          best = value
          found = p
        }
      }
    }
  }
  return found
}

// way(g, a, heading, b, most) -> {squares, heading}? the cheapest way from
// the square a to the square b (-1: to any of g.targets), its squares
// from a on, and the direction it arrives in (see trail.kernel's ways)
local func way(g, a, heading, b, most){
  tick()
  local at = trail_kernels.ways(
    g.cost, g.from, g.height, g.steep, g.wet, g.toll, g.cm, g.cell, a, heading,
    b, m.GRADE, most, g.dir_x, g.dir_z, g.heap_key, g.heap_cell, g.room, g.done,
    g.targets
  )
  if(at == -1){
    return null
  }
  local arrives = at % 16
  local back = {}
  for(at != -1){
    append(back, to_int((at - at % 16) / 16))
    at = g.from[at]
  }
  local squares = {}
  for(local i = len(back) - 1; i >= 0; i = i - 1){
    append(squares, back[i])
  }
  return {squares: squares, heading: arrives}
}

// ------------------------------------------------------------ the Summit Run

// the Summit Run's way over the coarse grid: from the trailhead on the
// meadow in the south, across the river from the mountain, by the lake on
// the mountain's side, and up the highest mountain as high as a track
// can go on it as it is: no step of the way up steeper than a climb may
// be (CLIMB: it is not dug into the mountain), and from all the places it can
// reach so, the highest near the mountain's middle. Its natural top, a
// horn, it may not reach. -> {line, summit, shore, side}
local func summit_way(land, g){
  local cm = g.cm
  local side = if(land.peak.x > 0){ 1 } else { -1 }
  local z0 = -land.half * 0.62
  local start = {x: river_x(land, z0) - side * 46, z: z0}
  local lake = land.river.lake
  local shore = {x: river_x(land, lake.z) + side * 185, z: lake.z + 20}
  local line = null
  local top = null
  for(local attempt = 0; attempt < 10; attempt = attempt + 1){
    line = {}
    // to the lake: the cheapest way, winding where steep pitches would cost
    local first = way(
      g, square_of(g, start.x, start.z), -1, square_of(g, shore.x, shore.z),
      m.PITCH
    )
    for(let local q in values(first.squares)){
      append(line, place_of(g, q))
    }
    // up the mountain: every place the way can reach without a step too
    // steep for a track (no goal: the search goes everywhere it can)
    g.targets:fill(0)
    local from_shore = square_of(g, shore.x, shore.z)
    tick()
    trail_kernels.ways(
      g.cost, g.from, g.height, g.steep, g.wet, g.toll, cm, g.cell, from_shore,
      first.heading, -1, m.GRADE, -m.CLIMB, g.dir_x, g.dir_z, g.heap_key,
      g.heap_cell, g.room, g.done, g.targets
    )
    // the highest of them near the mountain's middle (further out if none
    // near it can be reached)
    local best = null
    for(let local reach in values({1000, 1600})){
      local height = -1.0e9
      for(local j = 3; j < cm - 3; j = j + 1){
        for(local i = 3; i < cm - 3; i = i + 1){
          local q = j * cm + i
          local p = place_of(g, q)
          local dx = p.x - land.peak.x
          local dz = p.z - land.peak.z
          if(dx * dx + dz * dz < reach * reach and g.height[q] > height){
            // (reached, by the way it got there most cheaply)
            local state = -1
            local least = 1.0e8
            for(local d = 0; d < 16; d = d + 1){
              if(g.cost[q * 16 + d] < least){
                least = g.cost[q * 16 + d]
                state = q * 16 + d
              }
            }
            if(state != -1){
              height = g.height[q]
              best = state
            }
          }
        }
      }
      if(best != null){
        break
      }
    }
    local back = {}
    local at = best
    for(at != null and at != -1){
      append(back, to_int((at - at % 16) / 16))
      at = g.from[at]
    }
    // (found from the end back; its first square is the lake's, which the
    // way there ended in)
    for(local i = len(back) - 2; i >= 0; i = i - 1){
      append(line, place_of(g, back[i]))
    }
    top = line[len(line) - 1]
    local cross = crossing(line)
    if(cross == null){
      break
    }
    for(let local p in values({line[cross], line[cross + 1]})){
      g.toll[square_of(g, p.x, p.z)] = 1.0e9
      g.base[square_of(g, p.x, p.z)] = 1.0e9
    }
  }
  return {
    line: line,
    summit: {x: top.x, z: top.z, y: terrain.height_at(land, top.x, top.z)},
    shore: shore,
    side: side,
  }
}

// the Summit Run's camps by its points: the trailhead, the summit, and
// camps between them: one where the trail comes to the lake, one half way
// there, the others evenly up the mountain
local func summit_camps(points, shore){
  local count = len(points)
  local lakeside = 0
  local nearest = 1.0e12
  for(local i = 0; i < count; i = i + 1){
    local d = (points[i].x - shore.x) * (points[i].x - shore.x) +
      (points[i].z - shore.z) * (points[i].z - shore.z)
    if(d < nearest){
      nearest = d
      lakeside = i
    }
  }
  // (should the lake be nearly at one end, the camps are spread evenly)
  if(lakeside < count * 0.12 or lakeside > count * 0.6){
    lakeside = to_int(count / 3)
  }
  local last = count - 1
  return {
    {name: "Trailhead", index: 0},
    {name: "River Camp", index: to_int(lakeside / 2)},
    {name: "Lakeside", index: lakeside},
    {name: "Timber Camp", index: lakeside + to_int((last - lakeside) * 0.25)},
    {name: "High Bench", index: lakeside + to_int((last - lakeside) * 0.5)},
    {name: "The Shoulder", index: lakeside + to_int((last - lakeside) * 0.75)},
    {name: "Summit", index: last},
  }
}

// ------------------------------------------------------------ a trail built

// a line of points (STEP apart) with room between its stretches: where it
// passes itself nearer than a bank between the two needs (the legs of a
// switchback one above the other, the arms of a hairpin), they are pushed
// apart (see trail.kernel's spread). The ends stay where they are (a
// trail begins and ends where it meets something).
local func roomy(land, points){
  local most = 400000
  local pairs = null
  // (pushed apart on a slope the two lie further above each other than
  // before, and need more room again: a few times over)
  for(local pass = 0; pass < m.ROOM_PASSES; pass = pass + 1){
    local count = len(points)
    if(count < 2 * m.ROOM_STILL + 20){
      return points
    }
    local x = kernel.float:array(count)
    local z = kernel.float:array(count)
    local y = kernel.float:array(count)
    // how high the track will lie, about: the land along the line, evened
    // out
    local heights = {}
    for(local i = 0; i < count; i = i + 1){
      x[i] = points[i].x
      z[i] = points[i].z
      heights[i] = terrain.height_at(land, points[i].x, points[i].z)
    }
    for(local i = 0; i < count; i = i + 1){
      local sum = 0
      local weight = 0
      for(local k = -7; k <= 7; k = k + 1){
        local j = i + k
        if(j >= 0 and j < count){
          local w = 8 - math.abs(k)
          sum = sum + heights[j] * w
          weight = weight + w
        }
      }
      y[i] = sum / weight
    }
    pairs = pairs or kernel.int32:array(most * 2)
    tick()
    local took = trail_kernels.spread(
      x, z, y, count, 2 * m.HALF_WIDTH + m.ROOM_WIDER, m.ROOM_GAP, m.ROOM_STILL,
      80, pairs, most, kernel.float:array(count), kernel.float:array(count),
      kernel.float:array(count), kernel.float:array(count),
      kernel.float:array(count)
    )
    if(took == 0){
      return points
    }
    local moved = {}
    for(local i = 0; i < count; i = i + 1){
      append(moved, {x: x[i], z: z[i]})
    }
    points = resampled(moved, m.STEP)
  }
  return points
}

// build(land, line, spec) -> Trail
// A trail along a way found over the coarse grid (`line`, its places):
// the line made one a truck can follow, the river given a shallow where
// it is crossed, the track's height along it (evened out, not too steep,
// in a ford the river's bed), its width, its camps, its steep climbs.
// Its obstacles come later (see [dress]): once it is known where the
// other trails meet it.
// spec: {seed, summit?: {x, y, z} (it ends up there, on the mountain),
// camps?: func(points) -> {{name, index}}, start_join?, end_join?: Join
// (where it meets another trail, at its first or its last point),
// climb?: bool (it may climb up to CLIMB steeply, where the land does:
// those stretches are its steep climbs)}.
// type Join = {y: float, dir: {x, z}, slope: float, half: float,
//   flat?: bool}: the other trail where they meet: its height, the way it
//   runs (a unit vector), how much it climbs that way, half its width;
//   flat: a level place (a camp's clearing), not to be tilted.
//
// Where two trails meet, the ground they share is one plane: it climbs
// along the other trail as that one does, and along this one as this one
// starts out; to do both it tilts across the other trail (no more than
// CROSS). This trail follows the plane until it is off the other's
// track, tilted with it, and then comes to its own height; the other is
// tilted the same where they meet (see [network]). Neither is then cut
// into the other.
local func build(land, line, spec){
  local n = land.n
  local points = roomy(land, resampled(rounded(line, 3), m.STEP))
  local count = len(points)
  // where it crosses the river, the river gets a shallow: a ford is a
  // place where the water runs wide and thin over gravel, not a dam
  local fords = {}
  local wet_from = null
  for(local i = 0; i < count; i = i + 1){
    local wet = terrain.water_at(land, points[i].x, points[i].z) > 0.02
    if(wet and wet_from == null){
      wet_from = i
    }
    if(wet_from != null and (not wet or i == count - 1)){
      local middle = points[to_int((wet_from + i - 1) / 2)]
      local wide = (i - wet_from) * m.STEP
      local ford = {
        x: middle.x, z: middle.z, radius: 22 + wide * 0.7,
        from: wet_from * m.STEP, to: i * m.STEP
      }
      land_kernels.shoal(
        land.heights, land.water, n, land.spacing, -land.half, ford.x, ford.z,
        ford.radius, 0.3, land.seed
      )
      append(fords, ford)
      wet_from = null
    }
  }
  // (fine heights made before this would not have the shallows)
  land.fine = null
  // the track's height: the land's along the line (the river's bed at a
  // ford, not deeper than a wheel wades), evened out so that it neither
  // jolts nor climbs too steeply
  local ys = {}
  local bed = {}
  for(local i = 0; i < count; i = i + 1){
    local p = points[i]
    local y = terrain.height_at(land, p.x, p.z)
    if(terrain.water_at(land, p.x, p.z) > 0.02){
      bed[i] = y
    }
    ys[i] = y
  }
  for(local pass = 0; pass < 3; pass = pass + 1){
    local smooth = {}
    for(local i = 0; i < count; i = i + 1){
      local sum = 0
      local weight = 0
      for(local k = -7; k <= 7; k = k + 1){
        local j = i + k
        if(j >= 0 and j < count){
          local w = 8 - math.abs(k)
          sum = sum + ys[j] * w
          weight = weight + w
        }
      }
      smooth[i] = sum / weight
    }
    ys = smooth
  }
  // where it meets another trail: the plane they share there, and how
  // many of its points lie in it ({at, toward, x, z, y, g, inside, cross,
  // radius}: g the plane's rise per meter in x and z)
  local func zone_of(join, from_end){
    local toward = if(from_end){ -1 } else { 1 }
    local at = if(from_end){ count - 1 } else { 0 }
    local j = points[at]
    local ahead = points[at + toward * math.min(3, count - 1)]
    local db = vec.normalize({x: ahead.x - j.x, y: 0, z: ahead.z - j.z})
    local dp = join.dir
    // (the other trail's left: across it)
    local lx = dp.z
    local lz = -dp.x
    local along = dp.x * db.x + dp.z * db.z
    local across = lx * db.x + lz * db.z
    local cross = 0
    if(not join.flat and math.abs(across) > 0.3){
      // the slope this one starts out with: the land's (evened out) a
      // way along, as far as the tilt across the other allows
      local k = math.min(count - 1, 8)
      local natural = (ys[at + toward * k] - join.y) / (k * m.STEP)
      local base = join.slope * along
      local reach = m.CROSS * math.abs(across)
      cross = (vec.clamp(natural, base - reach, base + reach) - base) / across
    }
    local slope = if(join.flat){ 0 } else { join.slope }
    local z = {
      at: at,
      toward: toward,
      x: j.x,
      z: j.z,
      y: join.y,
      cross: cross,
      g: {x: slope * dp.x + cross * lx, z: slope * dp.z + cross * lz},
      radius: 0,
      inside: 0,
      half: join.half,
    }
    // (in it while its track is not yet a meter and a half clear of the
    // other's: by how far it is from the other's line; a level place, by
    // how far from its middle)
    local clear = join.half + m.HALF_WIDTH + 1.5
    for(local k = 0; k < count; k = k + 1){
      local p = points[at + toward * k]
      local ox = p.x - j.x
      local oz = p.z - j.z
      local off = if(join.flat){ math.sqrt(ox * ox + oz * oz) } else { math.abs(
        ox * lx + oz * lz,
      ) }
      if(off > clear or k * m.STEP > 30){
        break
      }
      z.inside = k + 1
      z.radius = math.sqrt(ox * ox + oz * oz)
    }
    return z
  }
  local func plane(z, p){
    return z.y + z.g.x * (p.x - z.x) + z.g.z * (p.z - z.z)
  }
  // (on the plane in it; from there to its own height over a stretch)
  local func hold(z){
    for(local k = 0; k < z.inside; k = k + 1){
      local i = z.at + z.toward * k
      ys[i] = plane(z, points[i])
    }
  }
  local func ease(z){
    for(local k = z.inside; k <= z.inside + 14 and k < count; k = k + 1){
      local i = z.at + z.toward * k
      local t = (k - z.inside) / 14
      local on = plane(z, points[i])
      ys[i] = on + (ys[i] - on) * t * t * (3 - 2 * t)
    }
  }
  local zones = {}
  local zone_list = {}
  if(spec.start_join != null){
    zones.start = zone_of(spec.start_join, false)
    append(zone_list, zones.start)
  }
  if(spec.end_join != null){
    zones.finish = zone_of(spec.end_join, true)
    append(zone_list, zones.finish)
  }
  for(let local z in values(zone_list)){
    hold(z)
    ease(z)
  }
  // wider where it turns tightly
  local bends = {}
  for(local i = 0; i < count; i = i + 1){
    local p = points[i]
    local a = points[math.max(0, i - 4)]
    local b = points[math.min(count - 1, i + 4)]
    local chord = math.sqrt(
      (b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z),
    )
    local bend = vec.clamp(
      (1 - vec.clamp(chord / (8 * m.STEP), 0, 1)) * 2.2, 0, 1
    )
    bends[i] = bend
    p.half = m.HALF_WIDTH + 2.4 * bend
    p.at = i * m.STEP
  }
  // (and at the summit, where it ends in a place to turn round)
  if(spec.summit != null){
    for(local k = 0; k < 6 and k < count; k = k + 1){
      local p = points[count - 1 - k]
      p.half = math.max(p.half, 6.0 - k * 0.7)
    }
  }
  // the camps: a clearing beside the track at each, and none of the
  // obstacles near them or near where it meets other trails
  local camps = {}
  if(spec.camps != null){
    camps = spec.camps(points)
  }
  local keep = {}
  for(let local camp in values(camps)){
    local c = camp.index
    for(local k = -9; k <= 9; k = k + 1){
      local i = c + k
      if(i >= 0 and i < count){
        // (a trail's end is all clearing: a place to turn round)
        local far = if(c == count - 1 or c == 0){ math.max(
          0, math.abs(k) - 3
        ) } else { math.abs(k) }
        points[i].half = math.max(
          points[i].half,
          m.CAMP_HALF + 0.9 - far * 0.32,
        )
      }
    }
    append(keep, {from: c * m.STEP - 30, to: c * m.STEP + 30})
  }
  // down to the river's bed where it is forded, through the banks on both
  // sides as ramps (the evening out lifted it over the water)
  local ramp = 0.13 * m.STEP
  for(local i = 0; i < count; i = i + 1){
    if(bed[i] != null){
      ys[i] = bed[i]
      for(local k = 1; k <= 30; k = k + 1){
        for(let local j in values({i - k, i + k})){
          if(j >= 0 and j < count and bed[j] == null){
            ys[j] = math.min(ys[j], bed[i] + k * ramp)
          }
        }
      }
    }
  }
  // the summit: the track ends on a level place, as high on the
  // mountain as it goes
  local top = null
  if(spec.summit != null){
    top = {
      x: spec.summit.x, z: spec.summit.z, y: spec.summit.y - 0.35, radius: 6.5
    }
    for(local i = count - 1; i >= 0 and (count - 1 - i) * m.STEP <= top.radius; i = i -
      1){
      ys[i] = top.y
    }
  }
  // not too steep anywhere, less so in a hairpin (a truck that turns
  // cannot also climb) and up in the snow; the heights it must have at
  // its ends stay
  local steepest = if(spec.climb){ m.CLIMB } else { m.STEEPEST }
  // (leaving where it meets another trail it climbs gently at first, more
  // steeply over twenty meters: no kink where it leaves the plane)
  local gentle = {}
  for(let local z in values(zone_list)){
    for(local k = z.inside; k < z.inside + 10 and k < count; k = k + 1){
      gentle[z.at + z.toward * k] = 0.35 + 0.65 * (k - z.inside) / 10
    }
  }
  local func most(i){
    local limit = steepest * (1 - 0.55 * bends[i]) * (gentle[i] or 1)
    if(ys[i] > 430){
      limit = math.min(limit, steepest * 0.72)
    }
    return limit * m.STEP
  }
  local fixed_end = zones.finish != null
  local fixed_start = zones.start != null
  local func forward(){
    for(local i = 1; i < count; i = i + 1){
      if(not(fixed_end and i == count - 1)){
        local limit = most(i)
        ys[i] = vec.clamp(ys[i], ys[i - 1] - limit, ys[i - 1] + limit)
      }
    }
  }
  local func backward(){
    for(local i = count - 2; i >= 0; i = i - 1){
      if(not(fixed_start and i == 0)){
        local limit = most(i)
        ys[i] = vec.clamp(ys[i], ys[i + 1] - limit, ys[i + 1] + limit)
      }
    }
  }
  // (the last pass from the end that is held, so that no step next to
  // it is too steep)
  if(fixed_start and not fixed_end){
    backward()
    forward()
  } else {
    forward()
    backward()
  }
  // (and on the plane where it meets another: the stretch after that
  // steeper, if it must be)
  if(fixed_start){
    hold(zones.start)
    forward()
  }
  if(fixed_end){
    hold(zones.finish)
    backward()
  }
  // tilted with the plane across the track where it lies in it, and less
  // and less for a few meters after
  for(let local z in values(zone_list)){
    for(local k = 0; k < z.inside + 4 and k < count; k = k + 1){
      local i = z.at + z.toward * k
      local a = points[math.max(0, i - 1)]
      local b = points[math.min(count - 1, i + 1)]
      local d = vec.normalize({x: b.x - a.x, y: 0, z: b.z - a.z})
      // (this trail's left: across it)
      local tilt = z.g.x * d.z - z.g.z * d.x
      local t = vec.clamp((k - z.inside + 1) / 4, 0, 1)
      points[i].tilt = tilt * (1 - t * t * (3 - 2 * t))
    }
  }
  if(top != null){
    // (the level the track could climb to: the summit's)
    top.y = ys[count - 1]
  }
  for(local i = 0; i < count; i = i + 1){
    points[i].y = ys[i]
  }
  // the steep climbs: where it is steeper than a track's usual (and a
  // little before and after); climbs less than eighty meters apart are one
  local climbs = {}
  if(spec.climb){
    local from = null
    local last = null
    for(local i = 1; i < count; i = i + 1){
      if(math.abs(ys[i] - ys[i - 1]) > (m.STEEPEST + 0.005) * m.STEP){
        if(from == null or i - last > 40){
          if(from != null){
            append(climbs, {from: from, last: last})
          }
          from = i - 1
        }
        last = i
      }
    }
    if(from != null){
      append(climbs, {from: from, last: last})
    }
    for(let local c in values(climbs)){
      append(keep, {from: c.from * m.STEP - 20, to: c.last * m.STEP + 20})
    }
  }
  local sections = {}
  for(let local c in values(climbs)){
    local i0 = math.max(0, c.from - 2)
    local i1 = math.min(count - 1, c.last + 2)
    local climb = m.OBSTACLES.climb
    append(sections, {
      kind: "climb",
      name: climb.name,
      from: i0 * m.STEP,
      to: i1 * m.STEP,
      index: i0,
      last: i1,
      way: if(ys[i1] >= ys[i0]){ 1 } else { -1 },
    })
    for(local i = i0; i <= i1; i = i + 1){
      points[i].pace = climb.pace
    }
  }
  for(local i = 0; i < count; i = i + 1){
    local p = points[i]
    // (base: the even track; y: with what its obstacles do to it, once it
    // has them: see [dress])
    p.base = ys[i]
    p.y = ys[i]
    // under the water the land is left as the river made it: the track
    // runs down through the bank to the water's edge and ends there
    local over = ys[i] -
      land.water[to_int(
        vec.clamp((p.z + land.half) / land.spacing + 0.5, 0, n - 1),
      ) * n +
        to_int(vec.clamp((p.x + land.half) / land.spacing + 0.5, 0, n - 1))]
    local dry = vec.clamp((over + 0.1) / 0.3, 0, 1)
    p.cut = dry * dry * (3 - 2 * dry)
  }
  // (and not all at once)
  for(local pass = 0; pass < 2; pass = pass + 1){
    local cuts = {}
    for(local i = 0; i < count; i = i + 1){
      local a = points[math.max(0, i - 1)].cut
      local b = points[math.min(count - 1, i + 1)].cut
      cuts[i] = math.min(points[i].cut, (a + 2 * points[i].cut + b) / 4)
    }
    for(local i = 0; i < count; i = i + 1){
      points[i].cut = cuts[i]
    }
  }
  local placed = {}
  for(let local camp in values(camps)){
    local p = points[camp.index]
    append(placed, {
      at: p.at, index: camp.index, x: p.x, y: p.y, z: p.z, name: camp.name
    })
  }
  return {
    points: points,
    length: (count - 1) * m.STEP,
    start: points[0],
    goal: points[count - 1],
    sections: sections,
    fords: fords,
    summit: top,
    camps: placed,
    zones: zones,
    // (for [dress]: where the trail turns, what is to stay clear)
    bends: bends,
    keep: keep,
    seed: spec.seed,
  }
}

// dress(land, trail): the obstacles set on a trail (see [obstacles]),
// none in what is to stay clear of them (trail.keep: its camps, its steep
// climbs, where other trails meet it), and its track's height with them
local func dress(land, trail){
  local all = trail.sections
  for(let local section in values(obstacles(
    land, trail.points, trail.bends, trail.seed, trail.keep
  ))){
    append(all, section)
  }
  // (in their order along the trail)
  for(local i = 1; i < len(all); i = i + 1){
    local section = all[i]
    local k = i - 1
    for(k >= 0 and all[k].from > section.from){
      all[k + 1] = all[k]
      k = k - 1
    }
    all[k + 1] = section
  }
  for(local i = 0; i < len(trail.points); i = i + 1){
    local p = trail.points[i]
    p.y = p.base + m.offset(trail.sections, i * m.STEP)
  }
}

// ------------------------------------------------------------ the network

// whether another trail may meet a trail at its point i: not in its first
// or last stretch, not where it climbs, not on a steep climb, not in a
// ford, not near where another trail meets it already, not near the
// summit (its obstacles are set later, clear of where trails meet)
local func joinable(trail, i, junctions){
  local p = trail.points[i]
  local s = i * m.STEP
  if(s < 40 or s > trail.length - 40 or
    (trail.summit != null and s > trail.length - 150)){
    return false
  }
  // (nearly level there: a trail that leaves it climbs or drops by itself)
  local count = len(trail.points)
  local a = trail.points[math.max(0, i - 5)]
  local b = trail.points[math.min(count - 1, i + 5)]
  if(math.abs(b.y - a.y) > 0.05 * 20){
    return false
  }
  for(let local section in values(trail.sections)){
    if(s > section.from - 15 and s < section.to + 15){
      return false
    }
  }
  for(let local ford in values(trail.fords)){
    if(s > ford.from - 30 and s < ford.to + 30){
      return false
    }
  }
  for(let local j in values(junctions)){
    if((j.x - p.x) * (j.x - p.x) + (j.z - p.z) * (j.z - p.z) <
      m.JOIN_GAP * m.JOIN_GAP){
      return false
    }
  }
  return true
}

// the grid's targets (the squares where a way may meet the trails) and
// tolls (closed: where it may not cross them) for a search. `own`: a
// trail the way leaves from its end (it may not come back to it, nor to
// the trail it branched from near where it did)
local func mark(g, trails, junctions, own){
  local cm = g.cm
  g.targets:fill(0)
  g.toll:set(g.base)
  local closed = {}
  local leave = null
  if(own != null){
    leave = own.from
  }
  for(let local trail in values(trails)){
    local count = len(trail.points)
    for(local i = 0; i < count; i = i + 2){
      local p = trail.points[i]
      local s = i * m.STEP
      local open = joinable(trail, i, junctions)
      if(trail == own){
        // (the end it leaves from is neither: the way starts there)
        if(s > trail.length - 60){
          continue
        }
        open = false
      }
      if(leave != null and
        (p.x - leave.x) * (p.x - leave.x) + (p.z - leave.z) * (p.z - leave.z) <
          500 * 500){
        open = false
      }
      local c = square_of(g, p.x, p.z)
      local ci = c % cm
      local cj = to_int((c - ci) / cm)
      // (a square to each side as well: a knight's move does not jump it)
      for(local dj = -1; dj <= 1; dj = dj + 1){
        for(local di = -1; di <= 1; di = di + 1){
          local q = (cj + dj) * cm + ci + di
          if(open){
            if(closed[q] == null){
              g.targets[q] = 1
            }
          } else {
            closed[q] = true
            g.targets[q] = 0
            g.toll[q] = 1.0e9
          }
        }
      }
    }
  }
}

// the point of the trails nearest a place where a trail may meet them:
// {trail, index, x, z}
local func meeting(trails, junctions, own, place){
  local best = null
  local least = 1.0e18
  for(let local trail in values(trails)){
    if(trail != own){
      for(local i = 0; i < len(trail.points); i = i + 1){
        local p = trail.points[i]
        local d = (p.x - place.x) * (p.x - place.x) +
          (p.z - place.z) * (p.z - place.z)
        if(d < least and joinable(trail, i, junctions)){
          least = d
          best = {trail: trail, index: i, x: p.x, z: p.z}
        }
      }
    }
  }
  return best
}

// a way that meets a trail (its first place on that trail) made to leave
// it at JOIN_ANGLE at least: where it would set out too nearly along the
// trail, it goes to a place sixteen meters out at a little more than that
// angle first, on the side it goes to, and what lay within twenty-four
// meters of where they meet is left out. (Two tracks that part at a
// narrow angle run side by side for a long way, one's banks in the
// other's track.)
local func angled(line, meet){
  if(len(line) < 2){
    return line
  }
  local points = meet.trail.points
  local k = meet.index
  local a = points[math.max(0, k - 2)]
  local b = points[math.min(len(points) - 1, k + 2)]
  local dp = vec.normalize({x: b.x - a.x, y: 0, z: b.z - a.z})
  local j = line[0]
  // (where the way goes: its first place a little away from the meeting)
  local next = line[len(line) - 1]
  for(local i = 1; i < len(line); i = i + 1){
    local q = line[i]
    if((q.x - j.x) * (q.x - j.x) + (q.z - j.z) * (q.z - j.z) > 12 * 12){
      next = q
      break
    }
  }
  local d = vec.normalize({x: next.x - j.x, y: 0, z: next.z - j.z})
  local sine = dp.x * d.z - dp.z * d.x
  if(math.abs(sine) >= math.sin(m.JOIN_ANGLE * math.pi / 180)){
    return line
  }
  local side = if(sine >= 0){ 1 } else { -1 }
  local ahead = if(dp.x * d.x + dp.z * d.z >= 0){ 1 } else { -1 }
  local angle = (m.JOIN_ANGLE + 5) * math.pi / 180
  // (square to the trail, on the side whose sine is positive)
  local qx = -dp.z
  local qz = dp.x
  local out = {
    x: j.x + 16 * (ahead * math.cos(angle) * dp.x + side * math.sin(angle) * qx),
    z: j.z + 16 * (ahead * math.cos(angle) * dp.z + side * math.sin(angle) * qz),
  }
  local result = {j, out}
  for(local i = 1; i < len(line); i = i + 1){
    local q = line[i]
    if(i == len(line) - 1 or
      (q.x - j.x) * (q.x - j.x) + (q.z - j.z) * (q.z - j.z) > 24 * 24){
      append(result, q)
    }
  }
  return result
}

// the way from a place to the nearest of the trails where it may meet
// them, as a line from where it meets them to the place: {line, meet}?
local func reach(g, trails, junctions, own, place){
  local extra = {}
  for(local attempt = 0; attempt < 4; attempt = attempt + 1){
    mark(g, trails, junctions, own)
    for(let local q in values(extra)){
      g.toll[q] = 1.0e9
    }
    local a = square_of(g, place.x, place.z)
    local found = way(g, a, -1, -1, m.PITCH) or way(g, a, -1, -1, 0)
    if(found == null){
      return null
    }
    local squares = found.squares
    local meet = meeting(
      trails, junctions, own, place_of(g, squares[len(squares) - 1])
    )
    if(meet == null){
      return null
    }
    local line = {{x: meet.x, z: meet.z}}
    for(local i = len(squares) - 2; i >= 0; i = i - 1){
      append(line, place_of(g, squares[i]))
    }
    local last = line[len(line) - 1]
    if((last.x - place.x) * (last.x - place.x) +
      (last.z - place.z) * (last.z - place.z) > 4){
      append(line, {x: place.x, z: place.z})
    }
    line = angled(line, meet)
    local cross = crossing(line)
    if(cross == null){
      return {line: line, meet: meet}
    }
    append(extra, square_of(g, line[cross].x, line[cross].z))
    append(extra, square_of(g, line[cross + 1].x, line[cross + 1].z))
  }
  return null
}

// join_at(trail, k) -> Join: a trail where another meets it at its
// point k (see [build])
local func join_at(trail, k){
  local points = trail.points
  local a = points[math.max(0, k - 3)]
  local b = points[math.min(len(points) - 1, k + 3)]
  local dx = b.x - a.x
  local dz = b.z - a.z
  local l = math.max(0.01, math.sqrt(dx * dx + dz * dz))
  return {
    y: points[k].base,
    dir: {x: dx / l, z: dz / l},
    slope: (b.base - a.base) / l,
    half: points[k].half,
  }
}

// tilt_at(trail, k, zone): a trail tilted across where another meets it
// at its point k, as the plane they share there has it (see [build]'s
// zones), and less and less for eight meters on either side
local func tilt_at(trail, k, zone){
  if(zone == null or zone.cross == 0){
    return
  }
  local points = trail.points
  for(local i = math.max(0, k - 16); i <= math.min(len(points) - 1, k + 16); i = i +
    1){
    local t = vec.clamp((math.abs(i - k) * m.STEP - zone.radius) / 8, 0, 1)
    local f = 1 - t * t * (3 - 2 * t)
    if(f > 0){
      points[i].tilt = (points[i].tilt or 0) + zone.cross * f
    }
  }
}

// whether a place is at least `far` meters from every trail and from the
// places in `others`
local func apart(trails, others, place, far, between){
  for(let local trail in values(trails)){
    for(local i = 0; i < len(trail.points); i = i + 6){
      local q = trail.points[i]
      if((q.x - place.x) * (q.x - place.x) + (q.z - place.z) * (q.z - place.z) <
        far * far){
        return false
      }
    }
  }
  for(let local o in values(others)){
    if((o.x - place.x) * (o.x - place.x) + (o.z - place.z) * (o.z - place.z) <
      between * between){
      return false
    }
  }
  return true
}

// What else there is to see in a valley, to lead trails to: the lake's
// far shore, the headwaters up the river, and lookouts on ground that
// stands out over what is around it (not up in the snow). {{x, z, name}}
local func destinations(land, g, way_found, trails){
  local cm = g.cm
  local out = {}
  local func usable(i, j){
    local edge = math.min(math.min(i, j), math.min(cm - 1 - i, cm - 1 - j))
    return edge >= 14 and g.wet[j * cm + i] < 0.01 and
      g.steep[j * cm + i] < 0.42
  }
  // the best square by a score that is apart from what there is
  local func best(score, far){
    local found = null
    local top = -1.0e30
    for(local j = 14; j < cm - 14; j = j + 1){
      for(local i = 14; i < cm - 14; i = i + 1){
        if(usable(i, j)){
          local p = place_of(g, j * cm + i)
          local value = score(p, i, j)
          if(value != null and value > top and apart(trails, out, p, far, 520)){
            top = value
            found = p
          }
        }
      }
    }
    return found
  }
  local side = way_found.side
  local lake = land.river.lake
  local rx = river_x(land, lake.z)
  // the lake's far shore: flat ground at the water, across from the
  // Summit Run's side
  local shore = best(func(p, i, j){
    if(math.abs(p.z - lake.z) > 170 or (p.x - rx) * side > 0){
      return null
    }
    local by_water = false
    for(local dj = -1; dj <= 1; dj = dj + 1){
      for(local di = -1; di <= 1; di = di + 1){
        if(g.wet[(j + dj) * cm + i + di] > 0.3){
          by_water = true
        }
      }
    }
    if(not by_water){
      return null
    }
    return -g.steep[j * cm + i] * 60 - math.abs(p.z - lake.z) * 0.05
  }, 180)
  if(shore != null){
    shore.name = "Far Shore"
    shore.far = 160
    append(out, shore)
  }
  // the headwaters: up the river in the north, beside it
  local head = best(func(p, i, j){
    if(p.z < land.half * 0.5 or p.z > land.half * 0.82){
      return null
    }
    local off = math.abs(p.x - river_x(land, p.z))
    if(off < 30 or off > 140){
      return null
    }
    return -g.steep[j * cm + i] * 60 + p.z * 0.04
  }, 300)
  if(head != null){
    head.name = "Headwaters"
    head.far = 250
    append(out, head)
  }
  // the lookouts: what stands out most over the land around it
  local names = {
    "Eagle Point", "Bear Ridge", "Cedar Bench", "Hawk Lookout", "Granite Knob",
    "Wolf Ridge", "Juniper Bench", "Raven Crag"
  }
  // (a name to begin with by the valley: neighboring seeds differ)
  local first = (land.seed * 5 + 3) % len(names)
  for(local k = 0; k < 4; k = k + 1){
    local look = best(func(p, i, j){
      local h = g.height[j * cm + i]
      // (up over the valley's floor, not in the snow)
      if(h > 400 or h < lake.level + 45){
        return null
      }
      local sum = 0
      local count = 0
      for(local dj = -5; dj <= 5; dj = dj + 2){
        for(local di = -5; di <= 5; di = di + 2){
          sum = sum + g.height[(j + dj) * cm + i + di]
          count = count + 1
        }
      }
      local over = h - sum / count
      if(over < 4){
        return null
      }
      return over + h * 0.03 - g.steep[j * cm + i] * 25
    }, 360)
    if(look == null){
      break
    }
    look.name = names[(first + k) % len(names)]
    look.lookout = true
    look.far = 250
    append(out, look)
  }
  return out
}

// network(land, options?: {branches?: bool}) -> Network
// The trails of a land, not yet cut into it: the Summit Run first, then
// a trail to each of the valley's other sights from where it is nearest
// the trails there are, and a few that go on from a sight to meet the
// trails again elsewhere. branches false: the Summit Run alone.
// type Network = {trails: {Trail}, main: Trail, camps: {Camp}}
// type Trail = {name, kind: "main" | "branch" | "loop", id: int, points:
//   {{x, y, z, half, at, base, cut}}, length, sections, fords, summit?,
//   camps: {{name, index, at, x, y, z}}, checkpoints? (the Summit Run's:
//   its camps), from?: {trail, index, x, z} (where it leaves another
//   trail), to?: (where it meets one at its end)}
// type Camp = {name, x, y, z, yaw, trail: Trail, index: int}: where the
//   truck stands at a camp, looking the way it can drive on
// The land itself changes in one way: where a trail crosses the river,
// the river gets a shallow.
func m.network(land, options){
  options = options or {}
  local g = grid(land)
  local found = summit_way(land, g)
  local main = build(land, found.line, {
    seed: land.seed * 131 + 7,
    summit: found.summit,
    climb: true,
    camps: func(points){ return summit_camps(points, found.shore) },
  })
  main.name = "Summit Run"
  main.kind = "main"
  main.id = 0
  main.side = found.side
  main.steep_legs = 0
  main.checkpoints = main.camps
  local trails = {main}
  if(options.branches != false){
    local junctions = {}
    local branches = {}
    for(let local place in values(destinations(land, g, found, trails))){
      // (a trail made since may have come near it already: then it is
      // not worth one of its own)
      if(not apart(trails, {}, place, place.far, 0)){
        continue
      }
      local got = reach(g, trails, junctions, null, place)
      if(got != null){
        local meet = got.meet
        local trail = build(land, got.line, {
          seed: land.seed * 131 + 7 + len(trails) * 977,
          start_join: join_at(meet.trail, meet.index),
          camps: func(points){
            return {{name: place.name, index: len(points) - 1}}
          },
        })
        tilt_at(meet.trail, meet.index, trail.zones.start)
        trail.name = concat(place.name, " Trail")
        trail.kind = "branch"
        trail.id = len(trails)
        trail.from = meet
        trail.place = place.name
        append(junctions, {x: meet.x, z: meet.z})
        append(trails, trail)
        append(branches, trail)
      }
    }
    // from the end of a branch on to the trails elsewhere: a loop, when
    // it is not too long a way
    local loops = 0
    for(let local branch in values(branches)){
      if(loops >= 2){
        break
      }
      local end = branch.points[len(branch.points) - 1]
      local got = reach(g, trails, junctions, branch, end)
      if(got != null){
        local length = 0
        for(local i = 1; i < len(got.line); i = i + 1){
          length = length + vec.length({
              x: got.line[i].x - got.line[i - 1].x,
              y: 0,
              z: got.line[i].z - got.line[i - 1].z,
            })
        }
        if(length > 250 and length < 3200){
          local meet = got.meet
          // (it ends in the branch's clearing: level, not to be tilted)
          local finish = join_at(branch, len(branch.points) - 1)
          finish.flat = true
          local trail = build(land, got.line, {
            seed: land.seed * 131 + 7 + len(trails) * 977,
            start_join: join_at(meet.trail, meet.index),
            end_join: finish,
          })
          tilt_at(meet.trail, meet.index, trail.zones.start)
          trail.name = concat(branch.place, " Traverse")
          trail.kind = "loop"
          trail.id = len(trails)
          trail.from = meet
          trail.to = {
            trail: branch, index: len(branch.points) - 1, x: end.x, z: end.z
          }
          append(junctions, {x: meet.x, z: meet.z})
          append(trails, trail)
          loops = loops + 1
        }
      }
    }
  }
  // the obstacles, now that it is known where the trails meet: none near
  // that, on either trail
  for(let local trail in values(trails)){
    if(trail.from != null){
      local s = trail.from.index * m.STEP
      append(trail.from.trail.keep, {
        from: s - m.JOIN_CLEAR,
        to: s + m.JOIN_CLEAR,
      })
      append(trail.keep, {from: 0, to: m.JOIN_CLEAR})
    }
    if(trail.to != null){
      local s = trail.to.index * m.STEP
      append(trail.to.trail.keep, {
        from: s - m.JOIN_CLEAR,
        to: s + m.JOIN_CLEAR,
      })
      append(trail.keep, {from: trail.length - m.JOIN_CLEAR, to: trail.length})
    }
  }
  for(let local trail in values(trails)){
    dress(land, trail)
  }
  // the camps, where the truck stands at each: on the track, looking along
  // it (at a trail's end, back the way it came)
  local camps = {}
  for(let local trail in values(trails)){
    for(let local c in values(trail.camps)){
      local index = c.index
      local yaw = m.direction(trail, index)
      if(index == 0){
        index = math.min(4, len(trail.points) - 1)
      } else if(index == len(trail.points) - 1){
        index = math.max(0, index - 8)
        yaw = yaw + math.pi
      }
      local p = trail.points[index]
      append(camps, {
        name: c.name, x: p.x, y: p.y, z: p.z, yaw: yaw, trail: trail,
        index: index, at: c.index
      })
    }
  }
  return {trails: trails, main: main, camps: camps}
}

// plan(land: terrain.Terrain) -> Trail: the Summit Run alone (see
// [network]): `points` every STEP meters ({x, y, z, half: half the
// track's width}), `length`, `start` and `goal`, the checkpoints along it
// ({at: meters along, x, y, z, name}), its obstacles (`sections`: {kind,
// name, from, to}, meters along), its `fords` ({x, z, radius, from, to})
// and its `summit` ({x, y, z, radius}: the level place high on the
// mountain where it ends).
func m.plan(land){
  return m.network(land, {branches: false}).main
}

// the trail's line again for cutting: a point every FINE_STEP meters on a
// smooth curve through the trail's points, with the track's height, width
// and obstacles at each (eight numbers a point: see trail.kernel's cut)
local func fine_line(trail){
  local points = trail.points
  local count = len(points)
  local per = to_int(m.STEP / m.FINE_STEP + 0.5)
  local total = (count - 1) * per + 1
  local flat = kernel.float:array(total * 8, {shared: true})
  for(local k = 0; k < total; k = k + 1){
    local i = math.min(count - 2, to_int(k / per))
    local t = (k - i * per) / per
    local p0 = points[math.max(0, i - 1)]
    local p1 = points[i]
    local p2 = points[i + 1]
    local p3 = points[math.min(count - 1, i + 2)]
    // (a curve through the points: each piece from p1 to p2)
    local t2 = t * t
    local t3 = t2 * t
    local w0 = (-t3 + 2 * t2 - t) / 2
    local w1 = (3 * t3 - 5 * t2 + 2) / 2
    local w2 = (-3 * t3 + 4 * t2 + t) / 2
    local w3 = (t3 - t2) / 2
    local at = k * 8
    flat[at] = w0 * p0.x + w1 * p1.x + w2 * p2.x + w3 * p3.x
    flat[at + 1] = w0 * p0.z + w1 * p1.z + w2 * p2.z + w3 * p3.z
    flat[at + 2] = w0 * p0.base + w1 * p1.base + w2 * p2.base + w3 * p3.base +
      m.offset(trail.sections, k * m.FINE_STEP)
    flat[at + 3] = p1.half + (p2.half - p1.half) * t
    flat[at + 4] = (p1.tilt or 0) + ((p2.tilt or 0) - (p1.tilt or 0)) * t
    flat[at + 5] = (p1.wave or 0) + ((p2.wave or 0) - (p1.wave or 0)) * t
    flat[at + 6] = (p1.wall or 0) + ((p2.wall or 0) - (p1.wall or 0)) * t
    flat[at + 7] = p1.cut + (p2.cut - p1.cut) * t
  }
  return {flat: flat, count: total}
}

// carve(land, trails: Trail | {Trail}, options?: {workers?: int})
// The tracks cut into the land, one trail after the other: into its fine
// heights (made here if the land has none yet, see terrain.refine), from
// which the coarse ones are taken back. A trail cut later leaves the
// tracks cut before it as they are and runs its banks into them, so that
// where two trails meet the one goes over into the other. The land also
// gets its `trail` maps: for every sample how far the nearest track's
// line is (large when far), which trail's it is (`which`: its id), how
// far along that trail the nearest point is, half the track's width
// there, and whether it is a mud pit. Each of the trails' points gets
// the height the track has there.
func m.carve(land, trails, options){
  options = options or {}
  if(trails.points != null){
    trails = {trails}
  }
  local n = land.n
  local dist = kernel.float:array(n * n, {shared: true})
  dist:fill(1.0e9)
  local half = kernel.float:array(n * n, {shared: true})
  local along = kernel.float:array(n * n, {shared: true})
  local mud = kernel.uint8:array(n * n, {shared: true})
  local which = kernel.uint8:array(n * n, {shared: true})
  // (one trail's maps, taken into all of theirs when it is cut)
  local own = {
    dist: kernel.float:array(n * n, {shared: true}),
    half: kernel.float:array(n * n, {shared: true}),
    along: kernel.float:array(n * n, {shared: true}),
    mud: kernel.uint8:array(n * n, {shared: true}),
    // (and where it passes itself: the other stretch of it, see
    // trail.kernel's beside)
    dist2: kernel.float:array(n * n, {shared: true}),
    along2: kernel.float:array(n * n, {shared: true}),
  }
  if(land.fine == null){
    terrain.refine(land, options)
  }
  local fine = land.fine
  for(let local trail in values(trails)){
    local count = len(trail.points)
    local flat = kernel.float:array(count * 8)
    local low = 1.0e9
    local high = -1.0e9
    for(local i = 0; i < count; i = i + 1){
      local p = trail.points[i]
      flat[i * 8] = p.x
      flat[i * 8 + 1] = p.z
      flat[i * 8 + 2] = p.y
      flat[i * 8 + 3] = p.half
      flat[i * 8 + 7] = p.mud or 0
      low = math.min(low, p.z)
      high = math.max(high, p.z)
    }
    own.dist:fill(1.0e9)
    tick()
    trail_kernels.near(
      own.dist, own.half, own.along, own.mud, n, land.spacing, -land.half, flat,
      count, m.REACH, m.STEP
    )
    own.dist2:fill(1.0e9)
    tick()
    trail_kernels.beside(
      own.dist2, own.along2, n, land.spacing, -land.half, flat, count, m.REACH,
      m.STEP, own.along, m.APART
    )
    local line = fine_line(trail)
    // (a pass where the track would be a trench: see trail.kernel's saddle)
    tick()
    trail_kernels.saddle(
      fine.heights, fine.n, fine.spacing, -land.half, line.flat, line.count, 4,
      m.DEEPEST, land.seed, dist, half, n, land.spacing
    )
    // (only the rows the track and its banks are in)
    local margin = m.REACH + 4
    local from = to_int(vec.clamp(
      (low - margin + land.half) / fine.spacing, 0, fine.n
    ))
    local to = to_int(vec.clamp(
      (high + margin + land.half) / fine.spacing + 1, 0, fine.n
    ))
    terrain.rows(
      "game/trail", "cut", from, to, options.workers, fine.heights, fine.n,
      fine.spacing, -land.half, own.dist, own.along, n, land.spacing, line.flat,
      line.count, m.FINE_STEP, m.REACH, land.seed, dist, half, own.dist2,
      own.along2
    )
    tick()
    trail_kernels.merge(
      dist, half, along, mud, which, own.dist, own.half, own.along, own.mud,
      n * n, trail.id or 0
    )
  }
  // where trails meet, the ground they share as one piece: the plane
  // both follow there, a little past where they part (see trail.kernel's
  // pad)
  for(let local trail in values(trails)){
    for(let? local z in values({trail.zones.start, trail.zones.finish})){
      local radius = vec.clamp(z.radius + 1, z.half + 3.5, 12)
      tick()
      trail_kernels.pad(
        fine.heights, fine.n, fine.spacing, -land.half, z.x, z.z, z.y, z.g.x,
        z.g.z, radius, radius + 14, dist, half, n, land.spacing
      )
    }
  }
  terrain.settle(land, options)
  land.trail = {dist: dist, along: along, half: half, mud: mud, which: which}
  for(let local trail in values(trails)){
    // (in a ford the track's height is the river bed's)
    for(let local p in values(trail.points)){
      if(p.cut < 0.999){
        p.y = terrain.height_at(land, p.x, p.z)
      }
    }
    for(let local c in values(trail.camps or {})){
      c.y = terrain.height_at(land, c.x, c.z)
    }
  }
}

// clear(land, margin?: float) -> {data, n, cell}: a coarse map of where
// nothing may stand (1): the track and margin meters (2) beside it; what
// game/plants takes as its mask. null for a land without a trail.
func m.clear(land, margin){
  if(land.trail == null){
    return null
  }
  local block = 2
  local size = to_int(land.n / block)
  local data = kernel.uint8:array(size * size, {shared: true})
  tick()
  trail_kernels.clear(
    data, size, block, land.trail.dist, land.trail.half, land.n, margin or 2
  )
  return {data: data, n: size, cell: block * land.spacing}
}

// direction(trail, index) -> the way the trail runs at a point, as a yaw
func m.direction(trail, index){
  local count = len(trail.points)
  local a = trail.points[math.max(0, index - 1)]
  local b = trail.points[math.min(count - 1, index + 1)]
  return math.atan2(b.x - a.x, b.z - a.z)
}

// near(land, x, z) -> {dist, along, trail}? what the trails' maps say of
// a place: how far the nearest track's line is, how far along its trail,
// and which trail that is (its id); null away from the tracks
func m.near(land, x, z){
  if(land.trail == null){
    return null
  }
  local n = land.n
  local i = to_int(vec.clamp((x + land.half) / land.spacing + 0.5, 0, n - 1))
  local j = to_int(vec.clamp((z + land.half) / land.spacing + 0.5, 0, n - 1))
  local d = land.trail.dist[j * n + i]
  if(d > m.REACH){
    return null
  }
  return {
    dist: d,
    along: land.trail.along[j * n + i],
    trail: land.trail.which[j * n + i],
    half: land.trail.half[j * n + i],
  }
}

return m
