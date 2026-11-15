// game/run: a run of the trail, as the rules have it. The clock starts
// when the truck first moves and stops at the summit; the checkpoints
// are taken in order, each with its split; hard knocks add up to damage
// and a wreck costs time, as does being put back on the trail. The best
// time of each valley is kept in a file in the player's home.
//
//   local r = run.new(world)
//   local events = run.step(r, world, input, dt)   // after world.step
//   run.info(r, world)                             // what the HUD shows
//
// No window and no drawing here: main.slang turns the events into
// messages and sounds.
local math = require("slang/math")
local os = require("slang/os")
local json = require("slang/json")
local vec = require("game/vec")
local car_lib = require("game/car")
local world_lib = require("game/world")

local m = {}

m.CHECK_RADIUS = 11       // how near a checkpoint counts as there, m
m.RECOVER_PENALTY = 20    // s on the clock for being put back on the trail
m.WRECK_PENALTY = 45      // and for wrecking the truck
m.RECOVER_HOLD = 0.7      // s the key is held before it happens
m.BROKEN = 2.6            // s a truck that broke stands where it broke (what
// broke it is seen and heard) before it is patched up, or towed
// a knock (the truck's speed changing by this much in one step of the
// physics, m/s) starts to do damage; DAMAGE is how much per m/s over it
m.KNOCK = 0.55
m.DAMAGE = 0.11

// new(world) -> Run
func m.new(world){
  world.car.dead = false
  return {
    phase: "ready",        // ready (the clock waits), driving, finished
    time: 0,
    penalty: 0,
    next: 1,               // the checkpoint to reach
    splits: {},            // {name, time, best?} of those reached
    index: 0,              // the trail's point nearest the truck
    section: null,         // the obstacle it is in
    damage: 0,
    broken: null,          // broken: the seconds until it is patched up
    recoveries: 0,
    wrecks: 0,
    holding_recover: 0,
    upside_down: 0,
    recover_hint: false,
    best: m.load_best(world.land.seed),
    new_best: false,
  }
}

// where the best times are kept
local func best_file(){
  local home = os.getenv("HOME") or "."
  return concat(home, "/.switchback/best.json")
}

local func read_all(){
  local file = best_file()
  if(not os.exists(file)){
    return {}
  }
  return try { json.decode(os.read_file(file)) } catch { {} }
}

// load_best(seed) -> {time: float, splits: {float}}? the best run of a
// valley so far
func m.load_best(seed){
  local all = read_all()
  local best = all[string(seed)]
  if(type(best) != "table" or best.time == null){
    return null
  }
  return best
}

// save_best(seed, time, splits): kept if it is the best
func m.save_best(seed, time, splits){
  local all = read_all()
  local old = all[string(seed)]
  if(type(old) == "table" and old.time != null and old.time <= time){
    return false
  }
  all[string(seed)] = {time: time, splits: splits}
  local home = os.getenv("HOME") or "."
  try {
    os.mkdir_all(concat(home, "/.switchback"))
    os.write_file(best_file(), json.encode(all))
  } catch {
    return false
  }
  return true
}

// the trail's point nearest the truck, near where it was last
local func locate(r, trail, pos){
  local count = len(trail.points)
  local best = r.index
  local least = 1.0e12
  for(local i = math.max(0, r.index - 10); i < math.min(count, r.index + 60); i = i + 1){
    local p = trail.points[i]
    local dx = p.x - pos.x
    local dz = p.z - pos.z
    local d = dx * dx + dz * dz
    if(d < least){
      least = d
      best = i
    }
  }
  // far from where it was (it left the trail and came back elsewhere):
  // look along all of it
  if(least > 60 * 60){
    for(local i = 0; i < count; i = i + 4){
      local p = trail.points[i]
      local dx = p.x - pos.x
      local dz = p.z - pos.z
      local d = dx * dx + dz * dz
      if(d < least){
        least = d
        best = i
      }
    }
  }
  r.index = best
  return math.sqrt(least)
}

// recover(r, world): the truck back on the trail, for a price
func m.recover(r, world){
  local trail = world.trail
  local index = null
  if(trail != null){
    index = math.max(0, r.index - 3)
  }
  world_lib.recover(world, index)
  r.recoveries = r.recoveries + 1
  r.holding_recover = 0
  r.upside_down = 0
  r.recover_hint = false
  if(r.phase == "driving"){
    r.penalty = r.penalty + m.RECOVER_PENALTY
  }
}

// step(r, world, input: {recover?: bool}, dt) -> {Event}
// What happened in this frame: {kind: "start"}, {kind: "checkpoint",
// name, time, delta?} (delta: against the best run's split), {kind:
// "section", name}, {kind: "knock", strength}, {kind: "recover"},
// {kind: "broken"} (the knock that was one too many: the truck stands
// dead where it is for BROKEN seconds), {kind: "wreck"} (then: patched up
// and back on the trail), {kind: "finish", time, new_best}.
func m.step(r, world, input, dt){
  local events = {}
  local car = world.car
  local trail = world.trail
  if(r.phase == "ready" and math.abs(car.speed) > 0.6){
    r.phase = "driving"
    append(events, {kind: "start"})
  }
  if(r.phase == "driving"){
    r.time = r.time + dt
  }
  // knocks: what the world saw of the truck's speed changing at once
  local knock = world.knock or 0
  if(knock > m.KNOCK){
    // (a truck that is broken already takes no more harm)
    local harm = if(r.broken == null){ (knock - m.KNOCK) * m.DAMAGE } else { 0 }
    r.damage = math.min(1, r.damage + harm)
    append(events, {kind: "knock", strength: knock, harm: harm})
  }
  if(r.broken != null){
    // a wreck: it stands where it broke a moment, then it is patched up
    // and put back, for a price
    r.broken = r.broken - dt
    if(r.broken <= 0){
      r.broken = null
      car.dead = false
      r.wrecks = r.wrecks + 1
      r.damage = 0.35
      if(r.phase == "driving"){
        r.penalty = r.penalty + m.WRECK_PENALTY - m.RECOVER_PENALTY
      }
      m.recover(r, world)
      append(events, {kind: "wreck"})
    }
  } else if(r.damage >= 1 and r.phase != "finished"){
    r.broken = m.BROKEN
    car.dead = true
    append(events, {kind: "broken"})
  }
  // on its side or roof, or off the map: offer the way back
  if(car.up.y < 0.3){
    r.upside_down = r.upside_down + dt
  } else {
    r.upside_down = 0
  }
  local edge = world.land.half - 52
  local out = math.abs(car.pos.x) > edge or math.abs(car.pos.z) > edge
  r.recover_hint = (r.upside_down > 1.5 or out) and r.broken == null
  if(out and (math.abs(car.pos.x) > edge + 14 or math.abs(car.pos.z) > edge + 14)){
    m.recover(r, world)
    append(events, {kind: "recover", why: "edge"})
  }
  // (a broken truck is not righted: it is patched up in a moment)
  if(input != null and input.recover and r.broken == null){
    r.holding_recover = r.holding_recover + dt
    if(r.holding_recover >= m.RECOVER_HOLD){
      m.recover(r, world)
      append(events, {kind: "recover"})
    }
  } else {
    r.holding_recover = 0
  }
  if(trail == null){
    return events
  }
  // where on the trail, and in which of its obstacles
  r.off = locate(r, trail, car.pos)
  local along = r.index * 2.0
  local section = null
  if(r.off < 12){
    for(let local s in values(trail.sections)){
      if(along >= s.from - 4 and along <= s.to){
        section = s
      }
    }
  }
  if(section != null and section != r.section){
    append(events, {kind: "section", name: section.name})
  }
  r.section = section
  // the checkpoints, in order
  if(r.phase != "finished" and r.next < len(trail.checkpoints)){
    local c = trail.checkpoints[r.next]
    local dx = c.x - car.pos.x
    local dz = c.z - car.pos.z
    if(dx * dx + dz * dz < m.CHECK_RADIUS * m.CHECK_RADIUS){
      local total = r.time + r.penalty
      local split = {name: c.name, time: total}
      if(r.best != null and r.best.splits != null and r.best.splits[r.next - 1] != null){
        split.best = r.best.splits[r.next - 1]
      }
      append(r.splits, split)
      local event = {kind: "checkpoint", name: c.name, time: total, index: r.next}
      if(split.best != null){
        event.delta = total - split.best
      }
      append(events, event)
      r.next = r.next + 1
      if(r.next >= len(trail.checkpoints)){
        r.phase = "finished"
        local times = {}
        for(let local s in values(r.splits)){
          append(times, s.time)
        }
        r.new_best = m.save_best(world.land.seed, total, times)
        append(events, {kind: "finish", time: total, new_best: r.new_best})
      }
    }
  }
  return events
}

// result(r) -> what the finish screen shows
func m.result(r){
  return {
    time: r.time + r.penalty,
    penalty: r.penalty,
    splits: r.splits,
    best: if(r.best != null){ r.best.time } else { null },
    new_best: r.new_best,
    recoveries: r.recoveries,
    damage: r.damage,
  }
}

// truck(world) -> what the HUD shows of the truck (see render/hud's Info)
func m.truck(world){
  local car = world.car
  local d = car.drive
  local f = car.forward
  local wheels = {}
  local share = car_lib.MASS * 9.81 / 4
  for(local i = 0; i < 4; i = i + 1){
    local w = car.wheels[i]
    append(wheels, {
      contact: w.contact, slip: w.slip_ratio, load: w.load / share, surface: w.surface.name,
    })
  }
  local info = {
    speed: car.speed,
    rpm: d.rpm,
    redline: d.spec.redline,
    limiter: d.spec.limiter,
    idle: d.spec.idle,
    gear: d.gear,
    low: d.low,
    shifting: d.shift != null,
    clutch: d.clutch,
    throttle: car.throttle,
    brake: car.brake,
    hand_brake: car.hand_brake > 0,
    holding: car.holding,
    locks: {front: d.locks.front, rear: d.locks.rear, center: d.locks.center or d.low},
    pitch: math.asin(vec.clamp(f.y, -1, 1)),
    roll: math.asin(vec.clamp(car.left.y, -1, 1)),
    heading: math.atan2(f.x, f.z),
    wheels: wheels,
    surface: car.wheels[2].surface.name,
  }
  return info
}

// info(r, world) -> what the HUD shows of the truck and the run
func m.info(r, world){
  local car = world.car
  local info = m.truck(world)
  for(let local e in entries({
    mode: "trail",
    time: r.time + r.penalty,
    running: r.phase == "driving",
    penalty: r.penalty,
    splits: r.splits,
    damage: r.damage,
    recover: r.recover_hint,
    recover_hold: r.holding_recover / m.RECOVER_HOLD,
    section: r.section,
  })){
    info[e[0]] = e[1]
  }
  local trail = world.trail
  if(trail != null){
    info.progress = r.index / math.max(1, len(trail.points) - 1)
    info.trail = {points: trail.points, position: {x: car.pos.x, z: car.pos.z}, checkpoints: trail.checkpoints, index: r.index}
    if(r.next < len(trail.checkpoints)){
      local c = trail.checkpoints[r.next]
      local dx = c.x - car.pos.x
      local dz = c.z - car.pos.z
      info.checkpoint = {
        name: c.name,
        distance: math.sqrt(dx * dx + dz * dz),
        bearing: math.atan2(dx, dz),
        index: r.next,
        total: len(trail.checkpoints) - 1,
      }
    }
  }
  return info
}

return m
