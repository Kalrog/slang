// sound/listener: where things are for the ears. The listener is the
// camera (scene.View: its eye and which way it looks); a source at a
// point gets two gains, for the left and the right loudspeaker: louder
// the nearer it is, and more on the side it is on.
local math = require("slang/math")

local m = {}

// the distance at which a source is heard at its own level, m
m.REFERENCE = 7.0

// place(view, point, reference?) -> {left, right, distance}
// The gains of a source at point for the listener view. reference: the
// distance at which they add up to 1 (REFERENCE by default); nearer than
// a third of it a source grows no louder.
func m.place(view, point, reference){
  reference = reference or m.REFERENCE
  local eye = view.eye
  local dx = point.x - eye.x
  local dy = point.y - eye.y
  local dz = point.z - eye.z
  local d = math.sqrt(dx * dx + dy * dy + dz * dz)
  local gain = reference / math.max(d, reference / 3)
  local side = 0
  local ahead = 1
  if(d > 0.001){
    local r = view.right
    local f = view.forward
    side = (dx * r.x + dy * r.y + dz * r.z) / d
    ahead = (dx * f.x + dy * f.y + dz * f.z) / d
  }
  // behind the head a source is a little duller and quieter: here only
  // quieter
  if(ahead < 0){
    gain = gain * (1 + 0.3 * ahead)
  }
  // (never all on one side: a head is not that wide)
  local angle = (side * 0.8 + 1) * math.pi / 4
  return {left: gain * math.cos(angle), right: gain * math.sin(angle), distance: d}
}

// at(car, offset) -> Vec3: a point of the truck (its frame: x to its left,
// y up, z forward) in the world
func m.at(car, offset){
  local l = car.left
  local u = car.up
  local f = car.forward
  local p = car.pos
  return {
    x: p.x + l.x * offset.x + u.x * offset.y + f.x * offset.z,
    y: p.y + l.y * offset.x + u.y * offset.y + f.y * offset.z,
    z: p.z + l.z * offset.x + u.z * offset.y + f.z * offset.z,
  }
}

return m
