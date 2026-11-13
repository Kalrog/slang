// game/route: the trail. From the trailhead on the meadow it fords the
// river, passes the lake and climbs to the shoulder of the highest
// mountain. Nobody draws it: it is the cheapest way over the land for a
// track that may not be steep, found on a coarse grid (so it winds up a
// slope in switchbacks and takes a side valley where there is one), then
// smoothed into a line and cut into the land as a level track with banks
// (game/trail.kernel).
//
//   local trail = route.plan(land)     // {points, length, checkpoints, ...}
//   route.carve(land, trail)           // the land's heights get the track
//   route.along(land, x, z)            // how far along the trail a place is
local math = require("slang/math")
local kernel = require("kernel")
local vec = require("game/vec")
local terrain = require("game/terrain")
local trail_kernels = require("game/trail")
local land_kernels = require("game/land")

local m = {}

m.BLOCK = 16         // samples along a side of a square of the coarse grid
m.STEP = 2.0         // meters between the trail's points
m.FINE_STEP = 0.5    // and between the points of the line it is cut along
m.HALF_WIDTH = 2.3   // of the track, m
m.REACH = 20.0       // how far from its line the track's banks reach, m
m.DEEPEST = 7.0      // deeper than this the track is not cut: a ridge gets a pass
m.GRADE = 0.16       // the rise over run the way should not exceed
m.PITCH = 0.22       // and that no step of the way does, where the land allows
m.STEEPEST = 0.24    // the steepest the finished track is anywhere

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
  return d1 * d2 <= 0 and d3 * d4 <= 0 and (d1 != 0 or d2 != 0 or d3 != 0 or d4 != 0)
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
      if(math.abs(a.x - c.x) < 80 and math.abs(a.z - c.z) < 80 and segments_cross(a, b, c, d)){
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
  narrows: {name: "The Narrows", length: 30, pace: 3.0},
  steps: {name: "Rock Steps", length: 32, pace: 2.1},
  rocks: {name: "Rock Garden", length: 34, pace: 1.7},
  logs: {name: "Deadfall", length: 26, pace: 1.6},
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
// trail.kernel's near) and `pace`, the speed to take it at.
local func obstacles(land, points, bends){
  local rng = vec.random(land.seed * 131 + 7)
  local count = len(points)
  local step = m.STEP
  local sections = {}
  local last = null
  local before = null
  local at = 150 + rng:range(0, 70)
  local length = (count - 1) * step
  for(at < length - 190){
    local i0 = to_int(at / step)
    local p = points[i0]
    // where it is: how high over the river, how steep the land lies
    // across it, whether it climbs
    local n = land.n
    local row = to_int(vec.clamp((p.z + land.half) / land.spacing + 0.5, 0, n - 1))
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
    for(local again = 0; again < 4 and (kind == last or kind == before); again = again + 1){
      kind = rng:pick(kinds)
    }
    local spec = m.OBSTACLES[kind]
    local i1 = math.min(count - 2, i0 + to_int(spec.length / step))
    // not in a bend, not in the water
    local fits = true
    for(local i = math.max(0, i0 - 6); i <= math.min(count - 1, i1 + 6); i = i + 1){
      if(bends[i] > 0.3 or terrain.water_at(land, points[i].x, points[i].z) > 0.02){
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
      kind: kind, name: spec.name, from: i0 * step, to: i1 * step, index: i0, last: i1,
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
        q.wall = 3.4 * ramp
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

// plan(land: terrain.Terrain) -> Trail
// The trail of a land, not yet cut into it: `points` every STEP meters
// ({x, y, z, half: half the track's width}), `length`, `start` and `goal`,
// the checkpoints along it ({at: meters along, x, y, z, name}), its
// obstacles (`sections`: {kind, name, from, to}, meters along), its
// `fords` ({x, z, radius, from, to}) and its `summit` ({x, y, z, radius}:
// the level place at the mountain's top where it ends; null if no way
// led to the top). The land itself changes in one way: where the trail
// crosses the river, the river gets a shallow.
func m.plan(land){
  local n = land.n
  local block = m.BLOCK
  local cm = to_int(n / block)
  local cell = block * land.spacing
  local height = kernel.float:array(cm * cm)
  local steep = kernel.float:array(cm * cm)
  local wet = kernel.float:array(cm * cm)
  trail_kernels.coarse(height, steep, wet, cm, block, land.heights, land.water, n, land.spacing)
  // nothing at the land's edge, and not much near it
  local toll = kernel.float:array(cm * cm)
  for(local j = 0; j < cm; j = j + 1){
    for(local i = 0; i < cm; i = i + 1){
      local edge = math.min(math.min(i, j), math.min(cm - 1 - i, cm - 1 - j))
      if(edge < 3){
        toll[j * cm + i] = 1.0e9
      } else if(edge < 12){
        toll[j * cm + i] = (12 - edge) * 14
      }
    }
  }
  // the search's states: sixteen directions a square (see trail.kernel)
  local states = cm * cm * 16
  local cost = kernel.double:array(states)
  local from = kernel.int32:array(states)
  local room = states * 6
  local heap_key = kernel.double:array(room)
  local heap_cell = kernel.int32:array(room)
  local done = kernel.uint8:array(states)
  // the directions round the compass: neighbors and knight's moves in turn
  local dir_x = kernel.int32:array({1, 2, 1, 1, 0, -1, -1, -2, -1, -2, -1, -1, 0, 1, 1, 2})
  local dir_z = kernel.int32:array({0, 1, 1, 2, 1, 2, 1, 1, 0, -1, -1, -2, -1, -2, -1, -1})

  local func square_of(x, z){
    local i = to_int(vec.clamp((x + land.half) / cell, 0, cm - 1))
    local j = to_int(vec.clamp((z + land.half) / cell, 0, cm - 1))
    return j * cm + i
  }
  local func place_of(square){
    local i = square % cm
    local j = to_int((square - i) / cm)
    return {x: (i + 0.5) * cell - land.half, z: (j + 0.5) * cell - land.half}
  }

  // how steep the coarse land is at a square (rise over run)
  local func gradient(i, j){
    local gx = (height[j * cm + i + 1] - height[j * cm + i - 1]) / (2 * cell)
    local gz = (height[(j + 1) * cm + i] - height[(j - 1) * cm + i]) / (2 * cell)
    return math.sqrt(gx * gx + gz * gz)
  }
  // the best square of a rectangle of the land by a score
  local func find(x0, x1, z0, z1, score){
    local best = -1.0e30
    local found = null
    for(local j = 3; j < cm - 3; j = j + 1){
      for(local i = 3; i < cm - 3; i = i + 1){
        local p = place_of(j * cm + i)
        if(p.x >= math.min(x0, x1) and p.x <= math.max(x0, x1) and p.z >= z0 and p.z <= z1){
          local value = score(p, height[j * cm + i], gradient(i, j), wet[j * cm + i])
          if(value > best){
            best = value
            found = p
          }
        }
      }
    }
    return found
  }
  // the trailhead: on the meadow in the south, across the river from the
  // mountain
  local side = if(land.peak.x > 0){ 1 } else { -1 }
  local z0 = -land.half * 0.62
  local start = {x: river_x(land, z0) - side * 46, z: z0}
  // by the lake, on the mountain's side
  local lake = land.river.lake
  local shore = {x: river_x(land, lake.z) + side * 185, z: lake.z + 20}
  // the goal: the summit itself, the highest point of the mountain (the
  // highest sample within reach of its middle); should no way lead there,
  // the highest ground near it that is not a cliff
  local summit = {x: land.peak.x, z: land.peak.z, y: -1.0e9}
  local reach = 320
  local i0 = to_int(vec.clamp(land.peak.x - reach + land.half, 8, n - 9))
  local i1 = to_int(vec.clamp(land.peak.x + reach + land.half, 8, n - 9))
  local j0 = to_int(vec.clamp(land.peak.z - reach + land.half, 8, n - 9))
  local j1 = to_int(vec.clamp(land.peak.z + reach + land.half, 8, n - 9))
  for(local pass = 0; pass < 2; pass = pass + 1){
    // (every second sample first, then all of them around the best)
    local stride = if(pass == 0){ 2 } else { 1 }
    for(local j = j0; j <= j1; j = j + stride){
      for(local i = i0; i <= i1; i = i + stride){
        local h = land.heights[j * n + i]
        if(h > summit.y){
          summit = {x: i * land.spacing - land.half, z: j * land.spacing - land.half, y: h}
        }
      }
    }
    i0 = to_int((summit.x + land.half) / land.spacing) - 3
    i1 = i0 + 6
    j0 = to_int((summit.z + land.half) / land.spacing) - 3
    j1 = j0 + 6
  }
  local shoulder = find(land.peak.x - 300, land.peak.x + 300, land.peak.z - 300, land.peak.z + 300,
    func(p, h, steepness, water){
      if(steepness > 0.8){
        return -1.0e20
      }
      return h - steepness * 40
    }) or {x: land.peak.x, z: land.peak.z}
  local goal = {x: summit.x, z: summit.z}

  // the way: leg by leg, each the cheapest, each leaving a stop the way
  // the one before arrived. A way that crosses itself (a loop to gain
  // height) cannot be built on the land: the squares where it does are
  // closed and the way is looked for again.
  local stops = {start, shore, goal}
  local line = null
  local at_summit = true
  local steep_legs = 0
  for(local attempt = 0; attempt < 10; attempt = attempt + 1){
    line = {}
    steep_legs = 0
    local heading = -1
    for(local leg = 0; leg + 1 < len(stops); leg = leg + 1){
      local a = square_of(stops[leg].x, stops[leg].z)
      local b = square_of(stops[leg + 1].x, stops[leg + 1].z)
      // (pitches steeper than a track can be cost dearly: the way winds
      // instead, wherever it can)
      local at = trail_kernels.ways(cost, from, height, steep, wet, toll, cm, cell, a, heading, b,
        m.GRADE, m.PITCH, dir_x, dir_z, heap_key, heap_cell, room, done)
      if(at == -1 and leg + 2 == len(stops) and at_summit){
        // no way to the very top at all: to the shoulder under it
        at_summit = false
        stops[leg + 1] = shoulder
        b = square_of(shoulder.x, shoulder.z)
        at = trail_kernels.ways(cost, from, height, steep, wet, toll, cm, cell, a, heading, b,
          m.GRADE, 0, dir_x, dir_z, heap_key, heap_cell, room, done)
      }
      if(at != -1){
        heading = at % 16
      }
      local squares = {}
      for(at != -1){
        append(squares, to_int((at - at % 16) / 16))
        at = from[at]
      }
      // (found from the goal back: turn it round; the first square of a
      // later leg is the last of the one before)
      local first = if(leg == 0){ len(squares) - 1 } else { len(squares) - 2 }
      for(local i = first; i >= 0; i = i - 1){
        append(line, place_of(squares[i]))
      }
    }
    local cross = crossing(line)
    if(cross == null){
      break
    }
    for(let local p in values({line[cross], line[cross + 1]})){
      toll[square_of(p.x, p.z)] = 1.0e9
    }
  }

  // (the way ends in the middle of the summit's square: on to the summit)
  if(at_summit){
    local last = line[len(line) - 1]
    if((last.x - summit.x) * (last.x - summit.x) + (last.z - summit.z) * (last.z - summit.z) > 9){
      append(line, {x: summit.x, z: summit.z})
    }
  }
  // a line a truck can follow: corners rounded, points evenly apart
  local points = resampled(rounded(line, 3), m.STEP)
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
      local ford = {x: middle.x, z: middle.z, radius: 22 + wide * 0.7, from: wet_from * m.STEP, to: i * m.STEP}
      land_kernels.shoal(land.heights, land.water, n, land.spacing, -land.half, ford.x, ford.z,
        ford.radius, 0.3, land.seed)
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
  // (in a ford the track is the river's bed)
  local bed = {}
  for(local i = 0; i < count; i = i + 1){
    local p = points[i]
    local y = terrain.height_at(land, p.x, p.z)
    local depth = terrain.water_at(land, p.x, p.z)
    if(depth > 0.02){
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
  // wider where it turns tightly
  local bends = {}
  for(local i = 0; i < count; i = i + 1){
    local p = points[i]
    local a = points[math.max(0, i - 4)]
    local b = points[math.min(count - 1, i + 4)]
    local chord = math.sqrt((b.x - a.x) * (b.x - a.x) + (b.z - a.z) * (b.z - a.z))
    local bend = vec.clamp((1 - vec.clamp(chord / (8 * m.STEP), 0, 1)) * 2.2, 0, 1)
    bends[i] = bend
    p.half = m.HALF_WIDTH + 2.4 * bend
    p.at = i * m.STEP
  }
  // (and at the summit, where it ends in a place to turn round)
  if(at_summit){
    for(local k = 0; k < 6 and k < count; k = k + 1){
      local p = points[count - 1 - k]
      p.half = math.max(p.half, 6.0 - k * 0.7)
    }
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
  // the summit: the track ends on a level place at the mountain's top,
  // a little under its very tip (the evening out pulled its end down
  // toward the climb)
  local top = null
  if(at_summit){
    top = {x: summit.x, z: summit.z, y: summit.y - 0.35, radius: 6.5}
    for(local i = count - 1; i >= 0 and (count - 1 - i) * m.STEP <= top.radius; i = i - 1){
      ys[i] = top.y
    }
  }
  // not too steep anywhere, less so in a hairpin (a truck that turns
  // cannot also climb) and up in the snow
  local func most(i){
    local limit = m.STEEPEST * (1 - 0.55 * bends[i])
    if(ys[i] > 430){
      limit = math.min(limit, m.STEEPEST * 0.72)
    }
    return limit * m.STEP
  }
  for(local i = 1; i < count; i = i + 1){
    local limit = most(i)
    ys[i] = vec.clamp(ys[i], ys[i - 1] - limit, ys[i - 1] + limit)
  }
  for(local i = count - 2; i >= 0; i = i - 1){
    local limit = most(i)
    ys[i] = vec.clamp(ys[i], ys[i + 1] - limit, ys[i + 1] + limit)
  }
  local length = (count - 1) * m.STEP
  if(top != null){
    // (the level the track could climb to: the summit's)
    top.y = ys[count - 1]
  }
  for(local i = 0; i < count; i = i + 1){
    points[i].y = ys[i]
  }
  local sections = obstacles(land, points, bends)
  for(local i = 0; i < count; i = i + 1){
    local p = points[i]
    // (base: the even track; y: with what its obstacles do to it)
    p.base = ys[i]
    p.y = ys[i] + m.offset(sections, i * m.STEP)
    // under the water the land is left as the river made it: the track
    // runs down through the bank to the water's edge and ends there
    local over = ys[i] - land.water[
      to_int(vec.clamp((p.z + land.half) / land.spacing + 0.5, 0, n - 1)) * n +
      to_int(vec.clamp((p.x + land.half) / land.spacing + 0.5, 0, n - 1))
    ]
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
  // the checkpoints: the trailhead, the summit, and camps between them:
  // one where the trail comes to the lake, one half way there, the others
  // evenly up the mountain
  local lakeside = 0
  local nearest = 1.0e12
  for(local i = 0; i < count; i = i + 1){
    local d = (points[i].x - shore.x) * (points[i].x - shore.x) + (points[i].z - shore.z) * (points[i].z - shore.z)
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
  local camps = {
    {"Trailhead", 0},
    {"River Camp", to_int(lakeside / 2)},
    {"Lakeside", lakeside},
    {"Timber Camp", lakeside + to_int((last - lakeside) * 0.25)},
    {"High Bench", lakeside + to_int((last - lakeside) * 0.5)},
    {"The Shoulder", lakeside + to_int((last - lakeside) * 0.75)},
    {"Summit", last},
  }
  local checkpoints = {}
  for(let local camp in values(camps)){
    local p = points[camp[1]]
    append(checkpoints, {at: p.at, index: camp[1], x: p.x, y: p.y, z: p.z, name: camp[0]})
  }
  return {
    points: points,
    length: length,
    start: points[0],
    goal: points[count - 1],
    checkpoints: checkpoints,
    sections: sections,
    fords: fords,
    summit: top,
    steep_legs: steep_legs,
    side: side,
  }
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

// carve(land, trail, options?: {workers?: int})
// The track cut into the land: into its fine heights (made here if the
// land has none yet, see terrain.refine), from which the coarse ones are
// taken back. The land also gets its `trail` maps: for every sample how
// far the track's line is (large when far), how far along the trail the
// nearest point is, half the track's width there, and whether it is a
// mud pit. Each of the trail's points gets the height the track has
// there.
func m.carve(land, trail, options){
  options = options or {}
  local n = land.n
  local count = len(trail.points)
  local flat = kernel.float:array(count * 8)
  for(local i = 0; i < count; i = i + 1){
    local p = trail.points[i]
    flat[i * 8] = p.x
    flat[i * 8 + 1] = p.z
    flat[i * 8 + 2] = p.y
    flat[i * 8 + 3] = p.half
    flat[i * 8 + 7] = p.mud or 0
  }
  local dist = kernel.float:array(n * n, {shared: true})
  dist:fill(1.0e9)
  local half = kernel.float:array(n * n, {shared: true})
  local along = kernel.float:array(n * n, {shared: true})
  local mud = kernel.uint8:array(n * n, {shared: true})
  trail_kernels.near(dist, half, along, mud, n, land.spacing, -land.half, flat, count, m.REACH, m.STEP)
  if(land.fine == null){
    terrain.refine(land, options)
  }
  local fine = land.fine
  local line = fine_line(trail)
  // (a pass where the track would be a trench: see trail.kernel's saddle)
  trail_kernels.saddle(fine.heights, fine.n, fine.spacing, -land.half, line.flat, line.count, 4,
    m.DEEPEST, land.seed)
  terrain.bands("game/trail", "cut", fine.n, options.workers, fine.heights, fine.n, fine.spacing,
    -land.half, dist, along, n, land.spacing, line.flat, line.count, m.FINE_STEP, m.REACH, land.seed)
  if(trail.summit != null){
    // nothing around the summit stands over it
    local top = trail.summit
    trail_kernels.crown(fine.heights, fine.n, fine.spacing, -land.half, top.x, top.z, top.y + 0.06,
      top.radius, 46)
  }
  terrain.settle(land, options)
  land.trail = {dist: dist, along: along, half: half, mud: mud}
  // (in a ford the track's height is the river bed's)
  for(let local p in values(trail.points)){
    if(p.cut < 0.999){
      p.y = terrain.height_at(land, p.x, p.z)
    }
  }
  for(let local c in values(trail.checkpoints)){
    c.y = terrain.height_at(land, c.x, c.z)
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
  trail_kernels.clear(data, size, block, land.trail.dist, land.trail.half, land.n, margin or 2)
  return {data: data, n: size, cell: block * land.spacing}
}

// direction(trail, index) -> the way the trail runs at a point, as a yaw
func m.direction(trail, index){
  local count = len(trail.points)
  local a = trail.points[math.max(0, index - 1)]
  local b = trail.points[math.min(count - 1, index + 1)]
  return math.atan2(b.x - a.x, b.z - a.z)
}

// near(land, x, z) -> {dist, along}? what the trail's maps say of a place:
// how far its line is and how far along it; null away from the trail
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
  return {dist: d, along: land.trail.along[j * n + i]}
}

return m
