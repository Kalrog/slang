// game/autopilot: plays a mission from a list of steps, producing the same
// input a player would. Tests use it to prove each mission can be solved
// (and that the obvious shortcut fails); the demo mode shows it.
//
//   local pilot = autopilot.new(w, {
//     {go: "port1"}, {jack: "port1"}, {type: "door1.open()"}, {unjack: true},
//     {go: "dossier"}, {go: "exit"},
//   })
//   w:update(dt, pilot:input(dt))
//
// Steps:
//   {go: target}   walk there: "dossier", "exit", an object's name, or {x, z}
//   {jack: port}   face the port and plug in
//   {type: code}   type code into the deck and run it
//   {unjack: true} put the deck away
//   {wait: s}      stand still
//   {until: f}     stand still until f(world) is true
local math = require("slang/math")
local world = require("game/world")

local autopilot = {}

local Pilot = {}
// the metatable of every pilot (not Pilot.meta: that would be Pilot's own)
local pilot_meta = {__index: Pilot}

// walkable(w, x, z) -> whether the planner may route through a cell (doors
// and lasers are, whatever their state: getting the timing right is the
// steps' business)
local func walkable(w, x, z){
  local g = w:glyph(x, z)
  return g != "#" and g != " " and g != "%"
}

// path(w, from, to) -> list of cells {x, z} from the cell after from to to,
// or null
func autopilot.path(w, from, to){
  local key = func(x, z) => x * 1000 + z
  local came = {[key(from.x, from.z)]: from}
  local queue = {from}
  local head = 0
  local dirs = {{1, 0}, {- 1, 0}, {0, 1}, {0, - 1}}
  for(head < len(queue)){
    local c = queue[head]
    head = head + 1
    if(c.x == to.x and c.z == to.z){
      local out = {}
      for(not(c.x == from.x and c.z == from.z)){
        append(out, c)
        c = came[key(c.x, c.z)]
      }
      // reverse
      local n = len(out)
      for(local i = 0; i < n / 2; i = i + 1){
        local t = out[i]
        out[i] = out[n - 1 - i]
        out[n - 1 - i] = t
      }
      return out
    }
    for(let local d in values(dirs)){
      local nx = c.x + d[0]
      local nz = c.z + d[1]
      if(walkable(w, nx, nz) and came[key(nx, nz)] == null){
        local next = {x: nx, z: nz}
        came[key(nx, nz)] = c
        append(queue, next)
      }
    }
  }
  return null
}

local func target_cell(w, target){
  if(type(target) == "string"){
    if(target == "dossier" or target == "exit"){
      return w.map[target]
    }
    local o = w.objects[target]
    if(o == null){
      error("autopilot: no target ", target)
    }
    return {x: o.x, z: o.z}
  }
  return target
}

// new(w, steps) -> a pilot for a world
func autopilot.new(w, steps){
  return {
    world: w, steps: steps, index: 0, route: null, waited: 0.0, stuck: 0.0,
    done: false, failed: null, meta: pilot_meta
  }
}

local func next_step(self){
  self.index = self.index + 1
  self.route = null
  self.waited = 0.0
  self.stuck = 0.0
  if(self.index >= len(self.steps)){
    self.done = true
  }
}

// steer(p, x, z) -> {turn, forward} that walks the player towards a point
local func steer(p, x, z){
  local want = math.atan2(z - p.z, x - p.x)
  return {turn: world.angle_diff(want, p.yaw), forward: 1}
}

// input(dt) -> the input for this frame
func Pilot.input(self, dt){
  if(self.done or self.failed != null or self.index >= len(self.steps)){
    self.done = self.failed == null
    return {}
  }
  local w = self.world
  local p = w.player
  local step = self.steps[self.index]
  if(step.go != null){
    if(self.route == null){
      local to = target_cell(w, step.go)
      local from = {x: world.cell(p.x), z: world.cell(p.z)}
      self.route = autopilot.path(w, from, to)
      if(self.route == null){
        self.failed = concat("no way to ", string(step.go))
        return {}
      }
      self.last = {x: p.x, z: p.z}
    }
    if(len(self.route) == 0){
      next_step(self)
      return {}
    }
    local c = self.route[0]
    local dx = c.x - p.x
    local dz = c.z - p.z
    if(dx * dx + dz * dz < 0.12 * 0.12){
      remove(self.route, 0)
      return {}
    }
    // not getting anywhere (a closed door)
    local mx = p.x - self.last.x
    local mz = p.z - self.last.z
    if(mx * mx + mz * mz < 0.0001){
      self.stuck = self.stuck + dt
      if(self.stuck > 3){
        self.failed = concat("stuck on the way to ", string(step.go))
      }
    } else {
      self.stuck = 0.0
    }
    self.last = {x: p.x, z: p.z}
    local s = steer(p, c.x, c.z)
    // slow down on the last stretch so a cell's centre is not overshot
    local dist = math.sqrt(dx * dx + dz * dz)
    s.forward = math.min(1, dist / (world.WALK * dt))
    return s
  }
  if(step.jack != null){
    local o = w.objects[step.jack]
    local d = require("game/grid").dirs[o.dir]
    if(w.jacked == step.jack){
      next_step(self)
      return {}
    }
    local want = d.yaw + math.pi
    local turn = world.angle_diff(want, p.yaw)
    self.waited = self.waited + dt
    if(self.waited > 1){
      self.failed = concat("cannot jack into ", step.jack)
    }
    return {turn: turn, use: math.abs(turn) < 0.01}
  }
  if(step.type != null){
    if(not w:type_code(step.type)){
      self.failed = concat("the deck refused: ", step.type)
    }
    next_step(self)
    return {}
  }
  if(step.unjack != null){
    w:unjack()
    next_step(self)
    return {}
  }
  if(step.wait != null){
    self.waited = self.waited + dt
    if(self.waited >= step.wait){
      next_step(self)
    }
    return {}
  }
  if(step["until"] != null){
    if(step["until"](w)){
      next_step(self)
    }
    return {}
  }
  error("autopilot: unknown step")
}

// play(mission, steps, max_seconds) -> {world, pilot} after the steps ran
// out, the mission ended or the time was up (60 frames a second)
func autopilot.play(mission, steps, max_seconds){
  local w = world.new(mission)
  local pilot = autopilot.new(w, steps)
  local dt = 1 / 60
  for(local t = 0; t < (max_seconds or 60); t = t + dt){
    if(w.state != "playing" or pilot.failed != null){
      break
    }
    if(pilot.done){
      // keep the world going a little: a step may have ended on the exit
      w:update(dt, {})
      break
    }
    w:update(dt, pilot:input(dt))
  }
  return {world: w, pilot: pilot}
}

return autopilot
