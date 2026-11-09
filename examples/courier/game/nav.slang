// game/nav: routes through the city, for the autopilot (game/bot) and
// whatever else flies by itself. The city is built so that some air is
// always clear: down the middle of a street there are no lanes (they run
// to either side of it), the towers and what hangs off them stay back
// from it, and between one level of lanes and the next there is a band
// (BAND over the level: over the crossing lanes, which run 6 m higher,
// and under the bridges, which hang 15 m higher) where nothing crosses a
// street at all. The middle of a crossing is clear at every height. So a
// route runs along the middles of the streets in a band, changes bands
// climbing along a street (where no bridge is in the way) or in the
// middle of a crossing, and only its ends leave that network: up
// or down from where it starts and out to a street, and in to the pad.
// Every leg is checked against the city's boxes; the search is A* over
// the crossings and bands, a turn costing as much as some distance.
// Then the route is pulled tight: wherever a straight line skips some of
// its points clear of the city and the lanes (out of the street middles
// the bands are still clear of every lane, so there only the buildings
// matter), it takes it, across the corners of crossings and over the
// lower blocks.
local math = require("slang/math")
local vec = require("game/vec")
local city = require("game/city")

local m = {}

m.R = 2.5      // the half width of the air a leg keeps clear
m.BAND = 11    // a band's height over a level of lanes
m.LOW = 12     // the lowest band, under the first lanes
m.LANE_GAP = 3.2 // how far from a lane's line (up and across) is in it
m.LANE_COST = 400 // what crossing lanes in a leg costs (it is avoided)
m.TURN = 60    // what a turn costs, in meters (the car slows for it)
m.DENSE = 15   // m between the points a route is pulled tight through
m.SHORT_R = 4  // the half width of the air a shortcut keeps clear (the
               // car cuts inside its corners a little)
m.LANE_ACROSS = 3.4 // how near a lane's line a leg may not come, across
m.LANE_UP = 3.2     // ... and up or down

// new(c, top) -> Nav: the streets and bands of a city; top, the highest
// a route may fly
func m.new(c, top){
  local N = c.n
  local lines = {}
  for(local k = 0; k <= N; k = k + 1){
    append(lines, (k - N / 2) * c.pitch)
  }
  local bands = {m.LOW}
  for(let local level in values(c.lane_levels)){
    if(level + m.BAND <= top){
      append(bands, level + m.BAND)
    }
  }
  return {city: c, n: N, lines: lines, bands: bands, cache: {}}
}

// ------------------------------------------------------------ legs

// whether the box from a to b, grown by r, holds none of the city
local func box_clear(c, a, b, r){
  local found = city.query(c,
    math.min(a.x, b.x) - r, math.min(a.y, b.y) - r, math.min(a.z, b.z) - r,
    math.max(a.x, b.x) + r, math.max(a.y, b.y) + r, math.max(a.z, b.z) + r)
  return len(found) == 0
}

// clear(nav, a, b, skip_a?, skip_b?): whether a leg from a to b is clear
// of the city, leaving out skip meters at either end (where the car
// stands on something). A leg along an axis is one box; any other is
// sampled every 2 m.
func m.clear(nav, a, b, skip_a, skip_b){
  local d = vec.sub(b, a)
  local length = vec.length(d)
  skip_a = skip_a or 0
  skip_b = skip_b or 0
  if(length <= skip_a + skip_b + 0.01){
    return true
  }
  local u = vec.scale(d, 1 / length)
  local p = vec.add_scaled(a, u, skip_a)
  local q = vec.add_scaled(b, u, -skip_b)
  local moving = 0
  if(math.abs(d.x) > 0.01){ moving = moving + 1 }
  if(math.abs(d.y) > 0.01){ moving = moving + 1 }
  if(math.abs(d.z) > 0.01){ moving = moving + 1 }
  if(moving <= 1){
    return box_clear(nav.city, p, q, m.R)
  }
  local span = length - skip_a - skip_b
  local steps = to_int(math.floor(span / 2)) + 1
  for(local i = 0; i <= steps; i = i + 1){
    local s = vec.add_scaled(p, u, span * i / math.max(1, steps))
    if(not box_clear(nav.city, s, s, m.R)){
      return false
    }
  }
  return true
}

// lanes(nav, a, b): whether a leg along an axis (or any leg, roughly: its
// box) passes through a level of lanes where a lane runs
func m.lanes(nav, a, b){
  local g = m.LANE_GAP
  local x0 = math.min(a.x, b.x) - g
  local x1 = math.max(a.x, b.x) + g
  local y0 = math.min(a.y, b.y) - g
  local y1 = math.max(a.y, b.y) + g
  local z0 = math.min(a.z, b.z) - g
  local z1 = math.max(a.z, b.z) + g
  for(let local lane in values(nav.city.lanes)){
    if(lane.y >= y0 and lane.y <= y1){
      if(lane.axis == "x" and lane.at >= z0 and lane.at <= z1){
        return true
      }
      if(lane.axis == "z" and lane.at >= x0 and lane.at <= x1){
        return true
      }
    }
  }
  return false
}

// crosses(nav, a, b, across?, up?): whether a leg (any direction) comes
// nearer the line of a lane than across (LANE_ACROSS) and up (LANE_UP): a lane runs the length of the city, so what counts is the
// leg seen down the lane, against the lane's point
func m.crosses(nav, a, b, across, up){
  across = across or m.LANE_ACROSS
  up = up or m.LANE_UP
  local y0 = math.min(a.y, b.y) - up
  local y1 = math.max(a.y, b.y) + up
  for(let local lane in values(nav.city.lanes)){
    if(lane.y >= y0 and lane.y <= y1){
      // the leg in (across, up), scaled so the keep-out is a unit circle
      local pa = a.z
      local pb = b.z
      if(lane.axis == "z"){
        pa = a.x
        pb = b.x
      }
      local ux = (pa - lane.at) / across
      local uy = (a.y - lane.y) / up
      local vx = (pb - pa) / across
      local vy = (b.y - a.y) / up
      local vv = vx * vx + vy * vy
      local t = 0
      if(vv > 0.000001){
        t = vec.clamp(-(ux * vx + uy * vy) / vv, 0, 1)
      }
      local dx = ux + vx * t
      local dy = uy + vy * t
      if(dx * dx + dy * dy < 1){
        return true
      }
    }
  }
  return false
}

// a leg sampled every 2 m against the city, r around it
local func sampled_clear(nav, a, b, r){
  local length = vec.distance(a, b)
  local steps = to_int(math.floor(length / 2)) + 1
  for(local i = 0; i <= steps; i = i + 1){
    local s = vec.lerp(a, b, i / steps)
    if(not box_clear(nav.city, s, s, r)){
      return false
    }
  }
  return true
}

// without points that lie on the line between their neighbours
local func simplified(pts){
  local out = {}
  for(let local p in values(pts)){
    local n = len(out)
    if(n > 0 and vec.distance(out[n - 1], p) < 0.5){
      continue
    }
    if(n >= 2){
      local a = vec.normalize(vec.sub(out[n - 1], out[n - 2]))
      local b = vec.normalize(vec.sub(p, out[n - 1]))
      if(vec.dot(a, b) > 0.9995){
        out[n - 1] = p
        continue
      }
    }
    append(out, p)
  }
  return out
}

// smooth(nav, pts, o?: {lane_across, lane_up, short_r, lanes: false (cut
// through the lanes' levels too)}) -> the route pulled tight. Points go along its legs
// every DENSE m first, so a shortcut can leave or join a leg anywhere on
// it, not only at its corners; then from each point the route goes
// straight on to the furthest point after it that it can reach in a
// straight line clear of the city (with room to spare) and of the lanes,
// cutting the corners of the crossings and across the blocks it can fly
// over. The first leg (off what the car stands on) and the last (down
// onto the pad) stay as they are.
func m.smooth(nav, pts, o){
  o = o or {}
  local across = o.lane_across or m.LANE_ACROSS
  local up = o.lane_up or m.LANE_UP
  local r = o.short_r or m.SHORT_R
  local n = len(pts)
  if(n <= 3){
    return pts
  }
  // the points between the first leg and the last, every DENSE m
  local dense = {pts[1]}
  for(local k = 1; k < n - 2; k = k + 1){
    local a = pts[k]
    local b = pts[k + 1]
    local count = to_int(math.floor(vec.distance(a, b) / m.DENSE)) + 1
    for(local c = 1; c <= count; c = c + 1){
      append(dense, vec.lerp(a, b, c / count))
    }
  }
  local out = {pts[0], pts[1]}
  local i = 0
  local last = len(dense) - 1
  for(i < last){
    // on while the line stays clear (it stops at the first that is not:
    // a little short of the furthest, much cheaper to find)
    local j = i + 1
    for(j + 1 <= last){
      local q = dense[j + 1]
      if(vec.distance(dense[i], q) > 600 or (o.lanes != false and m.crosses(nav, dense[i], q, across, up)) or
          not sampled_clear(nav, dense[i], q, r)){
        break
      }
      j = j + 1
    }
    append(out, dense[j])
    i = j
  }
  append(out, pts[n - 1])
  return simplified(out)
}

// ------------------------------------------------------------ the network

local func node_id(nav, i, j, b){
  return (i * (nav.n + 1) + j) * len(nav.bands) + b
}

local func node_pos(nav, i, j, b){
  return {x: nav.lines[i], y: nav.bands[b], z: nav.lines[j]}
}

// a leg between two crossings (or bands of one), checked once
local func edge_clear(nav, a, b, pa, pb){
  local key = a * 100000 + b
  if(a > b){
    key = b * 100000 + a
  }
  local known = nav.cache[key]
  if(known == null){
    known = m.clear(nav, pa, pb)
    // a climb along a street passes the lanes of the crossing streets near
    // its ends, at their heights: those it may not come near
    if(known and pa.y != pb.y and (pa.x != pb.x or pa.z != pb.z)){
      known = not m.crosses(nav, pa, pb)
    }
    nav.cache[key] = known
  }
  return known
}

// the index of the street line at or below v (so v is between it and
// the next), within the city
local func line_below(nav, v){
  local k = to_int(math.floor((v - nav.lines[0]) / (nav.lines[1] - nav.lines[0])))
  return to_int(vec.clamp(k, 0, nav.n - 1))
}

// the bands nearest a height, nearest first
local func near_bands(nav, y, count){
  local out = {}
  local taken = {}
  for(local k = 0; k < math.min(count, len(nav.bands)); k = k + 1){
    local best = -1
    for(local b = 0; b < len(nav.bands); b = b + 1){
      if(not taken[b] and (best < 0 or math.abs(nav.bands[b] - y) < math.abs(nav.bands[best] - y))){
        best = b
      }
    }
    taken[best] = true
    append(out, best)
  }
  return out
}

local func path_length(pts){
  local total = 0
  for(local k = 0; k + 1 < len(pts); k = k + 1){
    total = total + vec.distance(pts[k], pts[k + 1])
  }
  return total
}

// the ways from a point onto the network: up or down, out to a street
// beside it, up or down to a band there, then along the street to the
// crossings at either end. Each: {pts (p first), street,
// band, s (on the street), cost to s, ends: {{node, pos}}}
local func accesses(nav, p, skip, lane_cost){
  local out = {}
  local i0 = line_below(nav, p.x)
  local j0 = line_below(nav, p.z)
  local streets = {
    {axis: "x", k: j0}, {axis: "x", k: j0 + 1}, {axis: "z", k: i0}, {axis: "z", k: i0 + 1},
  }
  for(let local st in values(streets)){
    for(let local b in values(near_bands(nav, p.y, 3))){
      local yb = nav.bands[b]
      local s = null
      local ends = null
      if(st.axis == "x"){
        s = {x: p.x, y: yb, z: nav.lines[st.k]}
        ends = {{node: node_id(nav, i0, st.k, b), pos: node_pos(nav, i0, st.k, b)},
          {node: node_id(nav, i0 + 1, st.k, b), pos: node_pos(nav, i0 + 1, st.k, b)}}
      } else {
        s = {x: nav.lines[st.k], y: yb, z: p.z}
        ends = {{node: node_id(nav, st.k, j0, b), pos: node_pos(nav, st.k, j0, b)},
          {node: node_id(nav, st.k, j0 + 1, b), pos: node_pos(nav, st.k, j0 + 1, b)}}
      }
      // up or down to a height h, out to the street at it, then up or
      // down the middle of the street to the band: h is the band itself,
      // where p is, or a little over it (over a roof's edge)
      local best = null
      local best_cost = 1e18
      for(let local h in values({yb, p.y, p.y + 6})){
        local over = {x: p.x, y: h, z: p.z}
        local beside = {x: s.x, y: h, z: s.z}
        if(m.clear(nav, p, over, skip, 0) and m.clear(nav, over, beside) and m.clear(nav, beside, s)){
          local cost = vec.distance(p, over) + vec.distance(over, beside) + vec.distance(beside, s)
          if(m.lanes(nav, p, over) or m.lanes(nav, over, beside) or m.lanes(nav, beside, s)){
            cost = cost + lane_cost
          }
          if(cost < best_cost){
            best_cost = cost
            best = {p, over, beside, s}
          }
        }
      }
      if(best != null){
        local usable = {}
        for(let local e in values(ends)){
          if(m.clear(nav, s, e.pos)){
            append(usable, e)
          }
        }
        append(out, {pts: best, street: st, band: b, s: s, cost: best_cost, ends: usable})
      }
    }
  }
  return out
}

local func reversed(pts){
  local out = {}
  for(local k = len(pts) - 1; k >= 0; k = k - 1){
    append(out, pts[k])
  }
  return out
}

// route(nav, from, to, o?: {skip_from, skip_to, smooth (true), lane_cost,
// lane_across, lane_up, short_r (the margins: smaller to run closer to
// the traffic and the buildings)}) -> a list of points from from to to,
// pulled tight (smooth), or null. skip: the meters at that end not checked (the car
// standing on a roof, the pad under the goal).
func m.route(nav, from, to, o){
  o = o or {}
  local skip_from = o.skip_from or 3
  local skip_to = o.skip_to or 3
  local lane_cost = o.lane_cost or m.LANE_COST
  local best = null
  local best_cost = 1e18
  // straight there, if it is near and clear
  local direct = vec.distance(from, to)
  if(direct < 160 and m.clear(nav, from, to, skip_from, skip_to)){
    best = {from, to}
    best_cost = direct
    if(m.lanes(nav, from, to)){
      best_cost = best_cost + lane_cost
    }
  }
  local starts = accesses(nav, from, skip_from, lane_cost)
  local goals = accesses(nav, to, skip_to, lane_cost)
  // along one street from the start's access to the goal's
  for(let local sa in values(starts)){
    for(let local ga in values(goals)){
      if(sa.street.axis == ga.street.axis and sa.street.k == ga.street.k and sa.band == ga.band){
        local cost = sa.cost + vec.distance(sa.s, ga.s) + ga.cost
        if(cost < best_cost and m.clear(nav, sa.s, ga.s)){
          best_cost = cost
          local pts = {}
          for(let local p in values(sa.pts)){ append(pts, p) }
          for(let local p in values(reversed(ga.pts))){ append(pts, p) }
          best = pts
        }
      }
    }
  }
  // the goal's ways in, by the crossing they start at
  local into = {}
  for(let local ga in values(goals)){
    for(let local e in values(ga.ends)){
      local list = into[e.node]
      if(list == null){
        list = {}
        into[e.node] = list
      }
      append(list, {access: ga, cost: vec.distance(e.pos, ga.s) + ga.cost})
    }
  }
  // A* over the crossings and bands, and the way it came into each
  // (a turn costs TURN more: the car slows for it)
  local nb = len(nav.bands)
  local dist = {}
  local prev = {}
  local open = {}
  local closed = {}
  local func h(pos){
    return math.abs(pos.x - to.x) + math.abs(pos.z - to.z) + math.abs(pos.y - to.y)
  }
  // states: a node and the heading it came in on (0 none, 1 +x, 2 -x,
  // 3 +z, 4 -z, 5 up, 6 down)
  local func push(node, heading, pos, cost, from_state, first){
    local state = node * 7 + heading
    if(dist[state] == null or cost < dist[state]){
      dist[state] = cost
      prev[state] = {state: from_state, first: first}
      append(open, {state: state, node: node, heading: heading, pos: pos, f: cost + h(pos)})
    }
  }
  local func heading_of(a, b){
    if(b.x > a.x + 0.1){ return 1 }
    if(b.x < a.x - 0.1){ return 2 }
    if(b.z > a.z + 0.1){ return 3 }
    if(b.z < a.z - 0.1){ return 4 }
    if(b.y > a.y){ return 5 }
    return 6
  }
  for(let local sa in values(starts)){
    for(let local e in values(sa.ends)){
      push(e.node, heading_of(sa.s, e.pos), e.pos, sa.cost + vec.distance(sa.s, e.pos), null, sa)
    }
  }
  local finish = null
  for(len(open) > 0){
    // the open state with the least f
    local bi = 0
    for(local k = 1; k < len(open); k = k + 1){
      if(open[k].f < open[bi].f){
        bi = k
      }
    }
    local cur = open[bi]
    open[bi] = open[len(open) - 1]
    remove(open, len(open) - 1)
    if(closed[cur.state] or cur.f >= best_cost){
      continue
    }
    closed[cur.state] = true
    local d = dist[cur.state]
    local ways = into[cur.node]
    if(ways != null){
      for(let local wv in values(ways)){
        if(d + wv.cost < best_cost){
          best_cost = d + wv.cost
          finish = {state: cur.state, access: wv.access}
          best = null
        }
      }
    }
    // the neighbours: along the two streets (level, or climbing or
    // coming down a band or two on the way), and straight up and down
    local b = cur.node % nb
    local ij = to_int((cur.node - b) / nb)
    local j = ij % (nav.n + 1)
    local i = to_int((ij - j) / (nav.n + 1))
    local func step_to(ni, nj, nbd, extra){
      if(ni < 0 or nj < 0 or ni > nav.n or nj > nav.n or nbd < 0 or nbd >= nb){
        return
      }
      local node = node_id(nav, ni, nj, nbd)
      local pos = node_pos(nav, ni, nj, nbd)
      local heading = heading_of(cur.pos, pos)
      if(closed[node * 7 + heading]){
        return
      }
      if(edge_clear(nav, cur.node, node, cur.pos, pos)){
        local cost = d + vec.distance(cur.pos, pos) * extra
        if(cur.heading != 0 and heading != cur.heading){
          cost = cost + m.TURN
        }
        push(node, heading, pos, cost, cur.state, null)
      }
    }
    for(let local dir in values({{1, 0}, {-1, 0}, {0, 1}, {0, -1}})){
      step_to(i + dir[0], j + dir[1], b, 1)
      step_to(i + dir[0], j + dir[1], b + 1, 1.05)
      step_to(i + dir[0], j + dir[1], b - 1, 1.05)
      step_to(i + dir[0], j + dir[1], b + 2, 1.1)
      step_to(i + dir[0], j + dir[1], b - 2, 1.1)
    }
    step_to(i, j, b + 1, 1.4)
    step_to(i, j, b - 1, 1.4)
  }
  if(finish != null){
    // back from the last crossing to the first, then the start's way on
    local nodes = {}
    local state = finish.state
    local first = null
    for(state != null){
      append(nodes, to_int((state - state % 7) / 7))
      local pr = prev[state]
      first = pr.first
      state = pr.state
    }
    local pts = {}
    for(let local p in values(first.pts)){ append(pts, p) }
    for(local k = len(nodes) - 1; k >= 0; k = k - 1){
      local n = nodes[k]
      local bb = n % nb
      local nij = to_int((n - bb) / nb)
      local nj = nij % (nav.n + 1)
      local ni = to_int((nij - nj) / (nav.n + 1))
      append(pts, node_pos(nav, ni, nj, bb))
    }
    for(let local p in values(reversed(finish.access.pts))){ append(pts, p) }
    best = pts
  }
  if(best == null){
    return null
  }
  if(o.smooth == false){
    return simplified(best)
  }
  return m.smooth(nav, simplified(best), o)
}

return m
