// game/navigate: the way to a place over the trails. The trails are a
// graph: a node every few points of each, joined along it and where one
// trail leaves another or meets it. The way from the truck to a place
// goes to the trails, along them by the shortest way, and off them again
// to the place; when the place is near, or the trails would be a detour,
// it is the straight line.
//
//   local net = navigate.new(world.trails)
//   local way = navigate.route(net, from, to)    // {points, length}
//   local guide = navigate.guide(way, pos)       // where to head for now
local math = require("slang/math")
local route = require("game/route")

local m = {}

m.EVERY = 4         // a node every this many of a trail's points
m.AHEAD = 32        // how far ahead along the way the guide is, m

local func distance(a, b){
  local dx = a.x - b.x
  local dz = a.z - b.z
  return math.sqrt(dx * dx + dz * dz)
}

// new(trails: {route.Trail}) -> Net
func m.new(trails){
  local net = {nodes: {}, links: {}, first: {}}
  local nodes = net.nodes
  local links = net.links
  local func link(a, b, cost){
    append(links[a], {to: b, cost: cost})
    append(links[b], {to: a, cost: cost})
  }
  // the node of a trail's point (the one at or before it)
  for(let local trail in values(trails)){
    local count = len(trail.points)
    net.first[trail] = len(nodes)
    local last = null
    for(local i = 0; i < count; i = i + m.EVERY){
      local index = i
      local p = trail.points[index]
      local id = len(nodes)
      append(nodes, {x: p.x, z: p.z, trail: trail, index: index})
      append(links, {})
      if(last != null){
        link(last, id, (index - nodes[last].index) * route.STEP)
      }
      last = id
    }
    if((count - 1) % m.EVERY != 0){
      local p = trail.points[count - 1]
      local id = len(nodes)
      append(nodes, {x: p.x, z: p.z, trail: trail, index: count - 1})
      append(links, {})
      link(last, id, (count - 1 - nodes[last].index) * route.STEP)
    }
  }
  local func node_of(trail, index){
    local first = net.first[trail]
    local id = first + math.min(to_int((index + m.EVERY / 2) / m.EVERY), to_int((len(trail.points) - 1) / m.EVERY))
    return id
  }
  // where trails meet
  for(let local trail in values(trails)){
    local first = net.first[trail]
    if(trail.from != null and net.first[trail.from.trail] != null){
      local other = node_of(trail.from.trail, trail.from.index)
      link(first, other, distance(nodes[first], nodes[other]))
    }
    if(trail.to != null and net.first[trail.to.trail] != null){
      local last = first
      for(local id = first; id < len(nodes) and nodes[id].trail == trail; id = id + 1){
        last = id
      }
      local other = node_of(trail.to.trail, trail.to.index)
      link(last, other, distance(nodes[last], nodes[other]))
    }
  }
  return net
}

// nearest(net, place) -> the node nearest a place, and how far it is
func m.nearest(net, place){
  local best = 0
  local least = 1.0e18
  for(local i = 0; i < len(net.nodes); i = i + 1){
    local n = net.nodes[i]
    local d = (n.x - place.x) * (n.x - place.x) + (n.z - place.z) * (n.z - place.z)
    if(d < least){
      least = d
      best = i
    }
  }
  return {node: best, distance: math.sqrt(least)}
}

// route(net, from: {x, z}, to: {x, z}) -> Way
// type Way = {points: {{x, z}}, length: float, direct: bool}
// The way from one place to another: to the trails, along them, and off
// them to the place; or straight there.
func m.route(net, from, to){
  local straight = distance(from, to)
  local direct = {points: {{x: from.x, z: from.z}, {x: to.x, z: to.z}}, length: straight, direct: true}
  if(len(net.nodes) == 0 or straight < 150){
    return direct
  }
  local a = m.nearest(net, from)
  local b = m.nearest(net, to)
  if(a.distance + b.distance >= straight){
    return direct
  }
  // Dijkstra's, with a heap of {cost, node}
  local count = len(net.nodes)
  local cost = {}
  local back = {}
  local heap = {}
  local func push(c, node){
    append(heap, {c, node})
    local i = len(heap) - 1
    for(i > 0){
      local p = to_int((i - 1) / 2)
      if(heap[p][0] <= heap[i][0]){
        break
      }
      local t = heap[p]
      heap[p] = heap[i]
      heap[i] = t
      i = p
    }
  }
  local func pop(){
    local top = heap[0]
    local last = heap[len(heap) - 1]
    remove(heap, len(heap) - 1)
    if(len(heap) > 0){
      heap[0] = last
      local i = 0
      for(true){
        local l = 2 * i + 1
        local r = l + 1
        local s = i
        if(l < len(heap) and heap[l][0] < heap[s][0]){
          s = l
        }
        if(r < len(heap) and heap[r][0] < heap[s][0]){
          s = r
        }
        if(s == i){
          break
        }
        local t = heap[s]
        heap[s] = heap[i]
        heap[i] = t
        i = s
      }
    }
    return top
  }
  cost[a.node] = 0
  push(0, a.node)
  for(len(heap) > 0){
    local top = pop()
    local c = top[0]
    local node = top[1]
    if(node == b.node){
      break
    }
    if(c <= cost[node]){
      for(let local l in values(net.links[node])){
        local nc = c + l.cost
        if(cost[l.to] == null or nc < cost[l.to]){
          cost[l.to] = nc
          back[l.to] = node
          push(nc, l.to)
        }
      }
    }
  }
  if(cost[b.node] == null){
    return direct
  }
  local along = {}
  local at = b.node
  for(at != null){
    append(along, at)
    at = back[at]
  }
  local points = {{x: from.x, z: from.z}}
  for(local i = len(along) - 1; i >= 0; i = i - 1){
    local n = net.nodes[along[i]]
    append(points, {x: n.x, z: n.z})
  }
  append(points, {x: to.x, z: to.z})
  local length = 0
  for(local i = 1; i < len(points); i = i + 1){
    length = length + distance(points[i - 1], points[i])
  }
  return {points: points, length: length, direct: false}
}

// guide(way, pos, hint?) -> {x, z, left, off, index}
// Where to head for now on a way: the point of the way AHEAD meters on
// from the one nearest the truck; `left`: how far it still is along the
// way; `off`: how far the truck is from the way; `index`: the nearest
// point (give it back as hint next time: the search starts there).
func m.guide(way, pos, hint){
  local points = way.points
  local count = len(points)
  // the nearest piece of the way
  local best = 0
  local least = 1.0e18
  local bt = 0
  local from = 0
  local to = count - 1
  if(hint != null){
    from = math.max(0, hint - 30)
    to = math.min(count - 1, hint + 60)
  }
  for(local i = from; i < to; i = i + 1){
    local a = points[i]
    local b = points[i + 1]
    local ex = b.x - a.x
    local ez = b.z - a.z
    local ee = ex * ex + ez * ez
    local t = 0
    if(ee > 0.0001){
      t = math.max(0, math.min(1, ((pos.x - a.x) * ex + (pos.z - a.z) * ez) / ee))
    }
    local qx = a.x + ex * t - pos.x
    local qz = a.z + ez * t - pos.z
    local d = qx * qx + qz * qz
    if(d < least){
      least = d
      best = i
      bt = t
    }
  }
  if(hint != null and least > 80 * 80){
    return m.guide(way, pos, null)
  }
  local a = points[best]
  local b = points[math.min(count - 1, best + 1)]
  local here = {x: a.x + (b.x - a.x) * bt, z: a.z + (b.z - a.z) * bt}
  // on along the way
  local go = m.AHEAD
  local at = here
  local i = best + 1
  local guide = null
  for(i < count){
    local d = distance(at, points[i])
    if(d >= go){
      local t = go / d
      guide = {x: at.x + (points[i].x - at.x) * t, z: at.z + (points[i].z - at.z) * t}
      break
    }
    go = go - d
    at = points[i]
    i = i + 1
  }
  if(guide == null){
    guide = {x: points[count - 1].x, z: points[count - 1].z}
  }
  local left = distance(here, b)
  for(local k = best + 1; k + 1 < count; k = k + 1){
    left = left + distance(points[k], points[k + 1])
  }
  local off = math.sqrt(least)
  return {x: guide.x, z: guide.z, left: left + off, off: off, index: best}
}

return m
