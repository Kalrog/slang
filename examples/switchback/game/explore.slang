// game/explore: driving where one likes, as the rules of exploring have
// it. There is no clock. The valley's camps are found by driving to them
// (a camp found stays found), and at a camp the truck is mended. Hard
// knocks add up to damage, and a truck that breaks down is towed to the
// nearest camp found so far: the place it broke down at must be found
// again. Markers set on the map are kept, and the way to the one chosen
// is shown along the trails (game/navigate). What was found and marked
// is kept in a file in the player's home, by valley.
//
//   local e = explore.new(world)
//   explore.start(e, world)                          // the truck at its camp
//   local events = explore.step(e, world, input, dt) // after world.step
//   explore.info(e, world)                           // what the HUD shows
//   explore.mark(e, world, x, z), explore.unmark(e, world, index),
//   explore.aim(e, world, index)
local math = require("slang/math")
local os = require("slang/os")
local json = require("slang/json")
local vec = require("game/vec")
local terrain = require("game/terrain")
local route = require("game/route")
local world_lib = require("game/world")
local run = require("game/run")
local navigate = require("game/navigate")

local m = {}

m.CAMP_RADIUS = 16       // how near a camp counts as there, m
m.MEND = 0.3             // how much damage a camp mends a second
m.ARRIVE = 14            // how near a marker counts as reached, m
m.MARKERS = 9            // the most markers there may be
m.REROUTE = 60           // this far off the way, it is looked for again, m

// what is kept, by valley
local func save_file(){
  return concat(os.getenv("HOME") or ".", "/.switchback/explore.json")
}

local func read_all(){
  local file = save_file()
  if(not os.exists(file)){
    return {}
  }
  return try { json.decode(os.read_file(file)) } catch { {} }
}

// saved(seed) -> {found: {string}, markers: {{x, z, name}}, camp?: string}?
// what was found and marked in a valley
func m.saved(seed){
  local kept = read_all()[string(seed)]
  if(type(kept) != "table"){
    return null
  }
  return kept
}

// save(e, world): what was found and marked kept
func m.save(e, world){
  if(not e.keep){
    return
  }
  local all = read_all()
  local found = {}
  for(let local camp in values(world.camps)){
    if(e.found[camp.name]){
      append(found, camp.name)
    }
  }
  local markers = {}
  for(let local marker in values(e.markers)){
    append(markers, {x: marker.x, z: marker.z, name: marker.name})
  }
  all[string(world.land.seed)] = {found: found, markers: markers, camp: e.camp, target: e.target}
  try {
    os.mkdir_all(concat(os.getenv("HOME") or ".", "/.switchback"))
    os.write_file(save_file(), json.encode(all))
  } catch {
    null
  }
}

// the camp of a name
local func camp_named(world, name){
  for(let local camp in values(world.camps)){
    if(camp.name == name){
      return camp
    }
  }
  return null
}

// new(world, options?: {keep?: bool}) -> Explore: what was kept of the
// valley, or a start at its trailhead. keep false: nothing is read from
// the file nor written to it.
func m.new(world, options){
  options = options or {}
  local e = {
    keep: options.keep != false,
    found: {},
    markers: {},
    target: null,
    way: null,
    guide: null,
    hint: null,
    reroute: 0,
    damage: 0,
    breakdowns: 0,
    camp: "Trailhead",
    at_camp: null,
    place: null,
    trail: null,
    section: null,
    holding_recover: 0,
    upside_down: 0,
    recover_hint: false,
    mending: false,
    net: navigate.new(world.trails),
  }
  local kept = if(e.keep){ m.saved(world.land.seed) } else { null }
  if(kept != null){
    for(let local name in values(kept.found or {})){
      e.found[name] = true
    }
    for(let local marker in values(kept.markers or {})){
      if(len(e.markers) < m.MARKERS and type(marker.x) != "null" and type(marker.z) != "null"){
        append(e.markers, {x: marker.x, z: marker.z, name: marker.name or concat("Marker ", string(len(e.markers) + 1))})
      }
    }
    if(type(kept.camp) == "string" and camp_named(world, kept.camp) != null){
      e.camp = kept.camp
    }
    if(type(kept.target) == "int" and kept.target >= 0 and kept.target < len(e.markers)){
      e.target = kept.target
    }
  }
  if(camp_named(world, "Trailhead") != null){
    e.found.Trailhead = true
  }
  return e
}

// the way to the target marker looked for again from where the truck is
local func reroute(e, world){
  e.way = null
  e.guide = null
  e.hint = null
  if(e.target == null){
    return
  }
  local marker = e.markers[e.target]
  e.way = navigate.route(e.net, {x: world.car.pos.x, z: world.car.pos.z}, marker)
  e.reroute = 0
}

// start(e, world): the truck at the camp it was last at, mended
func m.start(e, world){
  local camp = camp_named(world, e.camp) or world.camps[0]
  if(camp != null){
    world_lib.place(world, camp, camp.yaw)
    e.at_camp = camp.name
  }
  e.damage = 0
  e.section = null
  e.trail = null
  world.car.dirt = 0
  world.car.dust = 0
  reroute(e, world)
}

// mark(e, world, x, z) -> its index, or null when there are as many as
// there may be: a marker set
func m.mark(e, world, x, z){
  if(len(e.markers) >= m.MARKERS){
    return null
  }
  // (named by the first number not taken)
  local number = 1
  local taken = true
  for(taken){
    taken = false
    for(let local marker in values(e.markers)){
      if(marker.name == concat("Marker ", string(number))){
        taken = true
      }
    }
    if(taken){
      number = number + 1
    }
  }
  append(e.markers, {x: x, z: z, name: concat("Marker ", string(number))})
  m.save(e, world)
  return len(e.markers) - 1
}

// unmark(e, world, index): a marker taken away
func m.unmark(e, world, index){
  if(index == null or index < 0 or index >= len(e.markers)){
    return
  }
  remove(e.markers, index)
  if(e.target == index){
    e.target = null
    reroute(e, world)
  } else if(e.target != null and e.target > index){
    e.target = e.target - 1
  }
  m.save(e, world)
}

// aim(e, world, index?): the way shown to a marker (null: to none)
func m.aim(e, world, index){
  if(index != null and (index < 0 or index >= len(e.markers))){
    index = null
  }
  e.target = index
  reroute(e, world)
  m.save(e, world)
}

// the nearest camp found so far to a place
local func nearest_found(e, world, pos){
  local best = null
  local least = 1.0e18
  for(let local camp in values(world.camps)){
    if(e.found[camp.name]){
      local d = (camp.x - pos.x) * (camp.x - pos.x) + (camp.z - pos.z) * (camp.z - pos.z)
      if(d < least){
        least = d
        best = camp
      }
    }
  }
  return best or world.camps[0]
}

// towed to the nearest camp found
local func tow(e, world){
  local camp = nearest_found(e, world, world.car.pos)
  if(camp == null){
    world_lib.recover(world, 4)
    return "the trailhead"
  }
  world_lib.place(world, camp, camp.yaw)
  e.camp = camp.name
  e.at_camp = camp.name
  e.holding_recover = 0
  e.upside_down = 0
  reroute(e, world)
  m.save(e, world)
  return camp.name
}

// the truck back on its wheels where it is (in deep water: on the nearest
// track)
local func right(e, world){
  local car = world.car
  local pos = car.pos
  local heading = math.atan2(car.forward.x, car.forward.z)
  if(terrain.water_at(world.land, pos.x, pos.z) > 0.7){
    local near = navigate.nearest(e.net, pos)
    if(near != null and len(e.net.nodes) > 0){
      local node = e.net.nodes[near.node]
      world_lib.recover(world, node.index, node.trail)
    } else {
      tow(e, world)
    }
  } else {
    world_lib.place(world, pos, heading)
  }
  e.holding_recover = 0
  e.upside_down = 0
  e.recover_hint = false
}

// step(e, world, input: {recover?: bool}, dt) -> {Event}
// What happened in this frame: {kind: "camp", name, new: bool} (the truck
// came to a camp; new: found just now), {kind: "mended", name},
// {kind: "knock", strength, harm}, {kind: "breakdown", camp} (towed
// there), {kind: "recover"}, {kind: "trail", name} (on a trail other
// than before), {kind: "section", name}, {kind: "arrived", name} (at the
// marker the way led to).
func m.step(e, world, input, dt){
  local events = {}
  local car = world.car
  local pos = car.pos
  // knocks, as in a run: but a truck that breaks down is towed
  local knock = world.knock or 0
  if(knock > run.KNOCK){
    local harm = (knock - run.KNOCK) * run.DAMAGE
    e.damage = math.min(1, e.damage + harm)
    append(events, {kind: "knock", strength: knock, harm: harm})
  }
  if(e.damage >= 1){
    e.breakdowns = e.breakdowns + 1
    e.damage = 0
    append(events, {kind: "breakdown", camp: tow(e, world)})
    return events
  }
  // the camps: found by coming to them, and the truck mended there
  local here = null
  for(let local camp in values(world.camps)){
    local dx = camp.x - pos.x
    local dz = camp.z - pos.z
    if(dx * dx + dz * dz < m.CAMP_RADIUS * m.CAMP_RADIUS){
      here = camp
    }
  }
  if(here != null and here.name != e.at_camp){
    local new = not e.found[here.name]
    e.found[here.name] = true
    e.camp = here.name
    append(events, {kind: "camp", name: here.name, new: new})
    m.save(e, world)
  }
  e.at_camp = if(here != null){ here.name } else { null }
  e.mending = false
  if(here != null and e.damage > 0 and math.abs(car.speed) < 3){
    e.mending = true
    e.damage = math.max(0, e.damage - m.MEND * dt)
    if(e.damage == 0){
      append(events, {kind: "mended", name: here.name})
    }
  }
  // on its side or roof, or off the map
  if(car.up.y < 0.3){
    e.upside_down = e.upside_down + dt
  } else {
    e.upside_down = 0
  }
  local edge = world.land.half - 52
  local out = math.abs(pos.x) > edge or math.abs(pos.z) > edge
  e.recover_hint = e.upside_down > 1.5 or out
  if(math.abs(pos.x) > edge + 14 or math.abs(pos.z) > edge + 14){
    tow(e, world)
    append(events, {kind: "recover", why: "edge"})
  }
  if(input != null and input.recover){
    e.holding_recover = e.holding_recover + dt
    if(e.holding_recover >= run.RECOVER_HOLD){
      if(out){
        tow(e, world)
      } else {
        right(e, world)
      }
      append(events, {kind: "recover"})
    }
  } else {
    e.holding_recover = 0
  }
  // which trail it is on, and in which of its obstacles
  local near = route.near(world.land, pos.x, pos.z)
  local trail = null
  local section = null
  if(near != null and near.dist < near.half + 4){
    trail = world.trails[near.trail]
    if(trail != null){
      for(let local s in values(trail.sections)){
        if(near.along >= s.from - 4 and near.along <= s.to){
          section = s
        }
      }
    }
  }
  if(trail != null and trail != e.trail){
    append(events, {kind: "trail", name: trail.name})
  }
  if(trail != null or (near == null or near.dist > 30)){
    // (it keeps the trail's name a while after leaving the track)
    e.trail = trail
  }
  if(section != null and section != e.section){
    append(events, {kind: "section", name: section.name})
  }
  e.section = section
  // the way to the marker
  if(e.target != null and e.way != null){
    e.guide = navigate.guide(e.way, pos, e.hint)
    e.hint = e.guide.index
    e.reroute = e.reroute + dt
    if(e.guide.off > m.REROUTE and e.reroute > 3){
      reroute(e, world)
      e.guide = navigate.guide(e.way, pos, null)
      e.hint = e.guide.index
    }
    local marker = e.markers[e.target]
    local dx = marker.x - pos.x
    local dz = marker.z - pos.z
    if(dx * dx + dz * dz < m.ARRIVE * m.ARRIVE){
      append(events, {kind: "arrived", name: marker.name})
      e.target = null
      e.way = null
      e.guide = null
      m.save(e, world)
    }
  }
  return events
}

// found(e, world) -> how many of the valley's camps are found
func m.found(e, world){
  local n = 0
  for(let local camp in values(world.camps)){
    if(e.found[camp.name]){
      n = n + 1
    }
  }
  return n
}

// map(e, world) -> what the map and the HUD's small map show: the
// trails, the camps (found or not), the markers, the one aimed at, the
// way to it
func m.map(e, world){
  // (the same table every time: what draws it keeps what it worked out)
  if(e.trails == null){
    e.trails = {}
    for(let local t in values(world.trails)){
      append(e.trails, {name: t.name, kind: t.kind, points: t.points})
    }
  }
  local trails = e.trails
  local camps = {}
  for(let local camp in values(world.camps)){
    append(camps, {name: camp.name, x: camp.x, z: camp.z, found: e.found[camp.name] == true})
  }
  local route_points = null
  if(e.way != null){
    route_points = e.way.points
  }
  // (no names of places: a camp's is learned by finding it)
  return {
    trails: trails, camps: camps, markers: e.markers, target: e.target, route: route_points,
    position: {x: world.car.pos.x, z: world.car.pos.z},
  }
}

// info(e, world) -> what the HUD shows of the truck and of exploring
func m.info(e, world){
  local car = world.car
  local info = run.truck(world)
  info.mode = "explore"
  info.damage = e.damage
  info.recover = e.recover_hint
  info.recover_hold = e.holding_recover / run.RECOVER_HOLD
  info.recover_text = "hold to right the truck"
  info.section = e.section
  info.place = if(e.trail != null){ e.trail.name } else { "Off the trails" }
  info.camps_found = m.found(e, world)
  info.camps_total = len(world.camps)
  if(e.mending){
    info.repair = 1 - e.damage
  }
  info.network = m.map(e, world)
  info.trail = {position: {x: car.pos.x, z: car.pos.z}}
  if(e.target != null){
    local marker = e.markers[e.target]
    local toward = e.guide or marker
    local dx = toward.x - car.pos.x
    local dz = toward.z - car.pos.z
    local left = null
    if(e.guide != null){
      left = e.guide.left
    } else {
      left = math.sqrt((marker.x - car.pos.x) * (marker.x - car.pos.x) + (marker.z - car.pos.z) * (marker.z - car.pos.z))
    }
    info.checkpoint = {name: marker.name, distance: left, bearing: math.atan2(dx, dz)}
  }
  return info
}

return m
