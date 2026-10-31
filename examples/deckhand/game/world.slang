// game/world: one mission in play. Pure simulation: no drawing, no input
// devices, so tests step it with made-up input.
//
//   local w = world.new(mission)
//   w:update(dt, {forward: 1, strafe: 0, turn: 0, look: 0, use: false})
//   w.state      // "playing", "caught" or "complete"
//
// A mission is {name, title, briefing, map (from dsl/map), objects: {name:
// settings}}; game/missions has them and describes the settings.
local math = require("slang/math")
local grid = require("game/grid")
local deck = require("game/deck")

local world = {}

world.WALL_HEIGHT = 1.5
world.EYE = 0.8
world.PLAYER_RADIUS = 0.22
world.WALK = 2.8
world.REACH = 1.1
// a door leaf: thickness, and how open it must be to walk or see through
world.DOOR_THICK = 0.16
world.DOOR_PASS = 0.9
world.DOOR_SEE = 0.5
// how fast doors move (fraction per second)
world.DOOR_SPEED = 2.5
// seconds a camera needs to recognise you, and how fast that fades
world.SPOT_TIME = 0.45
world.SPOT_FADE = 0.6

local World = {}
// the metatable of every world (not World.meta: that would be World's own)
local world_meta = {__index: World}

// ------------------------------------------------------------ helpers

local func clamp(v, lo, hi){
  if(v < lo){
    return lo
  }
  if(v > hi){
    return hi
  }
  return v
}

// angle_diff(a, b) -> a - b, wrapped into -pi..pi
func world.angle_diff(a, b){
  local d = a - b
  for(d > math.pi){
    d = d - 2 * math.pi
  }
  for(d < -math.pi){
    d = d + 2 * math.pi
  }
  return d
}

local func round1(v){
  return math.round(v * 10) / 10
}

// ------------------------------------------------------------ objects

// settings every kind starts from; a mission's objects table overrides them
//   door:   limit (longest open, s; null for none), rest (s before it opens
//           again after a limited opening), open (starts open)
//   camera: range, fov and sweep (degrees), period (s per sweep), limit, rest
//   laser:  limit, rest
//   port:   network (list of object names)
local defaults = {
  door: {limit: null, rest: 0, open: false},
  camera: {range: 6.0, fov: 50, sweep: 70, period: 6.0, limit: null, rest: 0},
  laser: {limit: null, rest: 0},
  port: {network: {}},
}

local help = {
  door: "open(s), close(), is_open()",
  camera: "off(s), on(), is_on()",
  laser: "off(s), on(), is_on()",
}

local func make_object(spec, settings){
  local o = {
    kind: spec.kind, name: spec.name, x: spec.x, z: spec.z, dir: spec.dir,
    axis: spec.axis
  }
  for(let local e in entries(defaults[spec.kind])){
    o[e[0]] = e[1]
  }
  for(let local e in entries(settings or {})){
    o[e[0]] = e[1]
  }
  if(o.kind == "door"){
    o.target = if(o.open){ 1.0 } else { 0.0 }
    o.amount = o.target
    o.close_at = null
  } else if(o.kind == "camera" or o.kind == "laser"){
    o.on = true
    o.on_at = null
    if(o.kind == "camera"){
      local d = grid.dirs[o.dir]
      o.base_yaw = d.yaw
      o.yaw = d.yaw
      // the lens sits near the wall it hangs on
      o.px = o.x - d.dx * 0.38
      o.pz = o.z - d.dz * 0.38
      o.seeing = false
    }
  }
  o.ready_at = 0.0
  return o
}

// ------------------------------------------------------------ the world

// new(mission) -> a world at the start of the mission
func world.new(mission){
  local m = mission.map
  local w = {
    mission: mission, map: m, time: 0.0, state: "playing", reason: null,
    player: {
      x: m.start.x * 1.0, z: m.start.z * 1.0, yaw: m.start.yaw, pitch: 0.0
    }, objects: {}, names: {}, has_dossier: false, spotted: 0.0, jacked: null,
    deck: deck.new(), notes: {}, events: {}, handles: {}, meta: world_meta
  }
  for(let local spec in values(m.objects)){
    local settings = null
    if(mission.objects != null){
      settings = mission.objects[spec.name]
    }
    local o = make_object(spec, settings)
    w.objects[o.name] = o
    append(w.names, o.name)
  }
  if(mission.objects != null){
    for(let local name in keys(mission.objects)){
      if(w.objects[name] == null){
        error("mission ", mission.name, ": the map has no ", name)
      }
    }
  }
  for(let local name in values(w.names)){
    local o = w.objects[name]
    if(o.kind == "port"){
      for(let local n in values(o.network)){
        if(w.objects[n] == null or w.objects[n].kind == "port"){
          error(
            "mission ", mission.name, ": ", name, " reaches ", n,
            ", which is not an object"
          )
        }
      }
    }
  }
  w.deck:out(concat("deck ready. mission: ", mission.title), "sys")
  return w
}

// glyph(x, z) -> the map character of a cell ("#" outside the map)
func World.glyph(self, x, z){
  local m = self.map
  if(x < 0 or z < 0 or x >= m.w or z >= m.h){
    return "#"
  }
  return require("slang/string").char_at(m.rows[z], x)
}

// cell(v) -> the cell a coordinate falls in (an int: str.char_at takes no
// doubles)
local func cell(v){
  return to_int(math.floor(v + 0.5))
}
world.cell = cell

// object_at(x, z, kind) -> the object of that kind in a cell, or null
func World.object_at(self, x, z, kind){
  for(let local name in values(self.names)){
    local o = self.objects[name]
    if(o.x == x and o.z == z and (kind == null or o.kind == kind)){
      return o
    }
  }
  return null
}

// note(text): a message for the screen (and the event list, for tests)
func World.note(self, text){
  append(self.notes, {text: text, until: self.time + 3.0})
  append(self.events, text)
}

// ------------------------------------------------------------ collision

// boxes(cx, cz) -> the solid boxes {x0, z0, x1, z1} in and around a cell
func World.boxes(self, cx, cz){
  local out = {}
  for(local z = cz - 1; z <= cz + 1; z = z + 1){
    for(local x = cx - 1; x <= cx + 1; x = x + 1){
      local g = self:glyph(x, z)
      if(g == "#" or g == " " or g == "%"){
        append(out, {x - 0.5, z - 0.5, x + 0.5, z + 0.5})
      } else if(g == "D"){
        local d = self:object_at(x, z, "door")
        if(d.amount < world.DOOR_PASS){
          local t = world.DOOR_THICK / 2
          if(d.axis == "x"){
            append(out, {x - 0.5, z - t, x + 0.5, z + t})
          } else {
            append(out, {x - t, z - 0.5, x + t, z + 0.5})
          }
        }
      }
    }
  }
  return out
}

local func overlaps(px, pz, r, b){
  local cx = clamp(px, b[0], b[2])
  local cz = clamp(pz, b[1], b[3])
  local dx = px - cx
  local dz = pz - cz
  return dx * dx + dz * dz < r * r
}

// free(px, pz) -> whether the player fits at a position
func World.free(self, px, pz){
  for(let local b in values(self:boxes(cell(px), cell(pz)))){
    if(overlaps(px, pz, world.PLAYER_RADIUS, b)){
      return false
    }
  }
  return true
}

// move(dx, dz): moves the player, sliding along what it hits. Steps are
// short so a fast frame never tunnels through a door leaf.
func World.move(self, dx, dz){
  local p = self.player
  local dist = math.sqrt(dx * dx + dz * dz)
  local steps = math.max(1, math.ceil(dist / 0.05))
  for(local i = 0; i < steps; i = i + 1){
    local nx = p.x + dx / steps
    if(self:free(nx, p.z)){
      p.x = nx
    }
    local nz = p.z + dz / steps
    if(self:free(p.x, nz)){
      p.z = nz
    }
  }
}

// ------------------------------------------------------------ sight

// sight_blocked(x, z) -> whether a cell stops a line of sight
func World.sight_blocked(self, x, z){
  local g = self:glyph(x, z)
  if(g == "#" or g == " "){
    return true
  }
  if(g == "D"){
    return self:object_at(x, z, "door").amount < world.DOOR_SEE
  }
  return false
}

// ray(x, z, yaw, max) -> how far a ray gets before something blocks it
func World.ray(self, x, z, yaw, max){
  local dx = math.cos(yaw)
  local dz = math.sin(yaw)
  local step = 0.1
  for(local d = step; d < max; d = d + step){
    if(self:sight_blocked(cell(x + dx * d), cell(z + dz * d))){
      return d
    }
  }
  return max
}

// sees(cam, x, z) -> whether a camera sees a point
func World.sees(self, cam, x, z){
  if(not cam.on){
    return false
  }
  local dx = x - cam.px
  local dz = z - cam.pz
  local dist = math.sqrt(dx * dx + dz * dz)
  if(dist > cam.range or dist < 0.001){
    return dist < 0.001
  }
  local angle = math.atan2(dz, dx)
  local half = cam.fov * math.pi / 360
  if(math.abs(world.angle_diff(angle, cam.yaw)) > half){
    return false
  }
  return self:ray(cam.px, cam.pz, angle, dist) >= dist
}

// cone(cam, n) -> n + 1 points {x, z} along the edge of what a camera sees
func World.cone(self, cam, n){
  local half = cam.fov * math.pi / 360
  local out = {}
  for(local i = 0; i <= n; i = i + 1){
    local a = cam.yaw - half + 2 * half * i / n
    local d = self:ray(cam.px, cam.pz, a, cam.range)
    append(out, {x: cam.px + math.cos(a) * d, z: cam.pz + math.sin(a) * d})
  }
  return out
}

// ------------------------------------------------------------ the deck's objects

// limited(o, seconds, verb) -> how long an action lasts, or null when the
// object is resting (and the deck was told)
func World.limited(self, o, seconds, verb){
  if(seconds != null and type(seconds) != "int" and type(seconds) != "double"){
    error(o.name, ".", verb, "(seconds) needs a number")
  }
  // the same slack the deck gives wait(): a script that waited exactly as
  // long as the object needs finds it ready
  if(self.time + 0.000001 < o.ready_at){
    self.deck:out(
      concat(
        o.name, " is resetting: ", round1(o.ready_at - self.time), "s left"
      ),
      "err",
    )
    return null
  }
  if(o.limit != null){
    if(seconds == null or seconds > o.limit){
      self.deck:out(
        concat(o.name, ": ", verb, " for at most ", o.limit, "s"),
        "sys",
      )
      seconds = o.limit
    }
  }
  return seconds or -1
}

local func do_open(self, o, seconds){
  local s = self:limited(o, seconds, "open")
  if(s == null){
    return false
  }
  o.target = 1.0
  o.close_at = if(s >= 0){ self.time + s } else { null }
  if(s >= 0 and o.limit != null){
    o.ready_at = self.time + s + o.rest
  }
  append(self.events, concat(o.name, " open"))
  return true
}

local func do_close(self, o){
  o.target = 0.0
  o.close_at = null
  append(self.events, concat(o.name, " close"))
  return true
}

local func do_off(self, o, seconds){
  local s = self:limited(o, seconds, "off")
  if(s == null){
    return false
  }
  o.on = false
  o.on_at = if(s >= 0){ self.time + s } else { null }
  if(s >= 0 and o.limit != null){
    o.ready_at = self.time + s + o.rest
  }
  append(self.events, concat(o.name, " off"))
  return true
}

local func do_on(self, o){
  o.on = true
  o.on_at = null
  append(self.events, concat(o.name, " on"))
  return true
}

// status(o) -> how the deck shows an object
func World.status(self, o){
  if(o.kind == "door"){
    return if(o.target > 0.5){ "open" } else { "closed" }
  }
  if(o.kind == "camera" or o.kind == "laser"){
    return if(o.on){ "on" } else { "off" }
  }
  return ""
}

// handle(o) -> what deck scripts see of an object. Methods work called
// with a dot or with a colon (door1.open(3), door1:open(3)).
func World.handle(self, o){
  local h = self.handles[o.name]
  if(h != null){
    return h
  }
  local w = self
  h = {
    name: o.name, kind: o.kind, help: help[o.kind], meta: {
      __tostring: func(_) => concat(
        o.name, " (", o.kind, ", ", w:status(o), ")"
      ),
    }
  }
  local func method(f){
    return func(...args){
      if(len(args) > 0 and args[0] == h){
        remove(args, 0)
      }
      return f(...args)
    }
  }
  if(o.kind == "door"){
    h.open = method(func(s) => do_open(w, o, s))
    h.close = method(func() => do_close(w, o))
    h.is_open = method(func() => o.target > 0.5)
  } else {
    h.off = method(func(s) => do_off(w, o, s))
    h.on = method(func() => do_on(w, o))
    h.is_on = method(func() => o.on)
  }
  self.handles[o.name] = h
  return h
}

// network(port) -> {names, objects} of what a port reaches
func World.network(self, port){
  local objects = {}
  for(let local name in values(port.network)){
    objects[name] = self:handle(self.objects[name])
  }
  return {names: port.network, objects: objects}
}

// ------------------------------------------------------------ the player's hands

// port_in_reach() -> the port the player looks at, close enough, or null
func World.port_in_reach(self){
  local p = self.player
  local best = null
  local best_d = world.REACH
  for(let local name in values(self.names)){
    local o = self.objects[name]
    if(o.kind == "port"){
      local d = grid.dirs[o.dir]
      // the screen is on the wall behind the cell's centre
      local sx = o.x - d.dx * 0.45
      local sz = o.z - d.dz * 0.45
      local dx = sx - p.x
      local dz = sz - p.z
      local dist = math.sqrt(dx * dx + dz * dz)
      local facing = math.abs(world.angle_diff(math.atan2(dz, dx), p.yaw)) < 1.0
      if(dist < best_d and facing){
        best = o
        best_d = dist
      }
    }
  }
  return best
}

// jack(port): plugs the deck into a port
func World.jack(self, port){
  self.jacked = port.name
  local names = port.network
  if(len(names) == 0){
    self.deck:out(
      concat("jacked into ", port.name, ": nothing on this network"),
      "sys",
    )
  } else {
    self.deck:out(
      concat(
        "jacked into ", port.name, ": ",
        require("slang/string").join(names, ", ")
      ),
      "sys",
    )
  }
}

// unjack(): the deck is put away (its scripts keep running)
func World.unjack(self){
  self.jacked = null
}

// type_code(code) -> whether a script started, run from the jacked port
func World.type_code(self, code){
  if(self.jacked == null){
    return false
  }
  return self.deck:run(code, self:network(self.objects[self.jacked]))
}

// ------------------------------------------------------------ time

local func update_objects(self, dt){
  for(let local name in values(self.names)){
    local o = self.objects[name]
    if(o.kind == "door"){
      if(o.close_at != null and self.time >= o.close_at){
        o.target = 0.0
        o.close_at = null
        append(self.events, concat(o.name, " close"))
      }
      // a closing door waits for the player to get out of its way
      local p = self.player
      local in_door = math.abs(p.x - o.x) < 0.5 + world.PLAYER_RADIUS and
        math.abs(p.z - o.z) < 0.5 + world.PLAYER_RADIUS
      local blocked = o.target < o.amount and in_door and
        o.amount >= world.DOOR_PASS
      if(not blocked){
        if(o.amount < o.target){
          o.amount = math.min(o.target, o.amount + world.DOOR_SPEED * dt)
        } else if(o.amount > o.target){
          o.amount = math.max(o.target, o.amount - world.DOOR_SPEED * dt)
        }
      }
    } else if(o.kind == "camera" or o.kind == "laser"){
      if(o.on_at != null and self.time >= o.on_at){
        o.on = true
        o.on_at = null
        append(self.events, concat(o.name, " on"))
      }
      if(o.kind == "camera" and o.on){
        o.yaw = o.base_yaw +
          math.sin(self.time * 2 * math.pi / o.period) * o.sweep * math.pi / 360
      }
    }
  }
}

local func update_player(self, dt, input){
  local p = self.player
  p.yaw = p.yaw + (input.turn or 0)
  p.pitch = clamp(p.pitch + (input.look or 0), -1.3, 1.3)
  local f = input.forward or 0
  local s = input.strafe or 0
  local n = math.sqrt(f * f + s * s)
  if(n > 1){
    f = f / n
    s = s / n
  }
  local cy = math.cos(p.yaw)
  local sy = math.sin(p.yaw)
  // strafing right is +90 degrees from forward (z grows southwards)
  local dx = (cy * f - sy * s) * world.WALK * dt
  local dz = (sy * f + cy * s) * world.WALK * dt
  if(dx != 0 or dz != 0){
    self:move(dx, dz)
  }
}

local func caught(self, reason){
  if(self.state == "playing"){
    self.state = "caught"
    self.reason = reason
    append(self.events, concat("caught: ", reason))
  }
}

local func check_hazards(self, dt){
  local p = self.player
  local seen_by = null
  for(let local name in values(self.names)){
    local o = self.objects[name]
    if(o.kind == "camera"){
      o.seeing = self:sees(o, p.x, p.z)
      if(o.seeing){
        seen_by = o
      }
    } else if(o.kind == "laser" and o.on){
      // the beam runs across the cell's middle, along its axis
      local r = world.PLAYER_RADIUS
      local hit = if(o.axis == "x"){ math.abs(p.z - o.z) < r and
        math.abs(p.x - o.x) < 0.5 + r } else { math.abs(p.x - o.x) < r and
        math.abs(p.z - o.z) < 0.5 + r }
      if(hit){
        caught(self, concat("you tripped ", o.name))
        return
      }
    }
  }
  if(seen_by != null){
    self.spotted = self.spotted + dt / world.SPOT_TIME
    if(self.spotted >= 1){
      caught(self, concat(seen_by.name, " saw you"))
    }
  } else {
    self.spotted = math.max(0, self.spotted - dt * world.SPOT_FADE)
  }
}

local func check_goals(self){
  local p = self.player
  local d = self.map.dossier
  if(not self.has_dossier){
    local dx = p.x - d.x
    local dz = p.z - d.z
    if(dx * dx + dz * dz < 0.45 * 0.45){
      self.has_dossier = true
      self:note("you have the dossier: get to the exit")
    }
  }
  local e = self.map.exit
  if(cell(p.x) == e.x and cell(p.z) == e.z){
    if(self.has_dossier){
      self.state = "complete"
      append(self.events, "complete")
    } else if(not self.exit_hint){
      self.exit_hint = true
      self:note("not without the dossier")
    }
  } else {
    self.exit_hint = false
  }
}

// update(dt, input): one frame. input: {forward, strafe (-1..1), turn,
// look (radians), use (pressed this frame)}. The player stands still while
// jacked in.
func World.update(self, dt, input){
  input = input or {}
  if(self.state != "playing"){
    return
  }
  self.time = self.time + dt
  update_objects(self, dt)
  self.deck:update(self.time)
  if(self.jacked == null){
    update_player(self, dt, input)
    if(input.use){
      local port = self:port_in_reach()
      if(port != null){
        self:jack(port)
      }
    }
  }
  check_hazards(self, dt)
  if(self.state == "playing"){
    check_goals(self)
  }
  local i = 0
  for(i < len(self.notes)){
    if(self.notes[i].until < self.time){
      remove(self.notes, i)
    } else {
      i = i + 1
    }
  }
}

return world
