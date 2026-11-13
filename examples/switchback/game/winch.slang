// game/winch: the winch on the truck's front bumper. Its line is hooked
// to what stands ahead (the nearest tree in front of the truck, or, where
// there is none, a ground anchor set a way up the track) and pulled in:
// the line is a stiff spring from the fairlead to the anchor that gets
// shorter as the drum turns, and pulls no harder than the winch can. A
// truck that sits in a mud hole or cannot climb a ledge pulls itself out
// by it, slowly.
//
//   winch.attach(world) -> "tree" | "ground" | null
//   winch.step(world, dt)       // every step of the physics
//   winch.release(world)
//   world.winch                 // the line while it is out: see [Line]
local math = require("slang/math")
local vec = require("game/vec")
local terrain = require("game/terrain")
local plants = require("game/plants")

local m = {}

// where the line leaves the truck, in the truck's frame (the roller
// fairlead of the winch bumper: render/truck draws it there)
m.FAIRLEAD = {x: 0, y: 0.335, z: 2.345}
m.REACH = 26        // how far the line goes, m
m.NEAREST = 4       // nothing nearer than this is worth hooking to, m
m.PULL = 42000      // the most the winch pulls, N
m.SPEED = 0.55      // how fast the drum takes the line in, m/s
m.STIFFNESS = 90000 // of the line, N/m
m.DONE = 3.2        // the line this short: unhooked, m

// The line while it is out.
// type Line = {anchor: Vec3, kind: string, length: float, tension: float,
//   from: Vec3, trunk?: {x: float, z: float, radius: float}}
// [anchor]: where it is hooked
// [kind]: "tree" or "ground"
// [trunk]: of a tree: where it stands and how thick the strap round it is
// [length]: how much of it is out, m
// [tension]: how hard it pulls now, N
// [from]: where it leaves the truck (the fairlead, in the world)

// the fairlead in the world
local func fairlead(car){
  local f = m.FAIRLEAD
  return vec.add(car.pos, vec.rotate(car.q, {x: f.x, y: f.y, z: f.z}))
}

// attach(world) -> "tree" | "ground" | null
// Hooks the line to the nearest tree within reach ahead of the truck (in
// a cone of about fifty degrees to each side), or to a ground anchor
// eighteen meters ahead where no tree stands. null when the line is out
// already.
func m.attach(world){
  if(world.winch != null){
    return null
  }
  local car = world.car
  local from = fairlead(car)
  local f = car.forward
  local best = null
  local trunk = null
  local least = 1.0e9
  if(world.plants != null){
    for(let local chunk in values(plants.near(world.plants, from.x, from.z, m.REACH))){
      for(let local solid in values(plants.solids(world.plants, chunk))){
        // a standing trunk: a cylinder that is taller than it is thick
        if(solid.kind == "cylinder" and solid.half_height > 1.5){
          local dx = solid.position.x - from.x
          local dz = solid.position.z - from.z
          local d = math.sqrt(dx * dx + dz * dz)
          if(d > m.NEAREST and d < m.REACH and d < least){
            local ahead = (dx * f.x + dz * f.z) / d
            if(ahead > 0.64){
              least = d
              // (a strap goes round the trunk a little above the ground;
              // the line is hooked to where its ends meet, on this side)
              local ground = terrain.height_at(world.land, solid.position.x, solid.position.z)
              local girth = solid.radius * 1.12 + 0.01
              best = {
                x: solid.position.x - dx / d * (girth + 0.26), y: ground + 0.75,
                z: solid.position.z - dz / d * (girth + 0.26),
              }
              trunk = {x: solid.position.x, z: solid.position.z, radius: girth}
            }
          }
        }
      }
    }
  }
  local kind = "tree"
  if(best == null){
    kind = "ground"
    local flat = vec.normalize({x: f.x, y: 0, z: f.z})
    local x = from.x + flat.x * 18
    local z = from.z + flat.z * 18
    best = {x: x, y: terrain.height_at(world.land, x, z) + 0.2, z: z}
  }
  world.winch = {
    anchor: best, kind: kind, length: vec.length(vec.sub(best, from)), tension: 0, from: from,
    trunk: trunk,
  }
  return kind
}

// release(world): the line unhooked and wound in
func m.release(world){
  world.winch = null
  world.car.winched = false
}

// step(world, dt): the drum takes the line in and the line pulls the
// truck, for one step of the physics. Returns "done" when the truck has
// reached the anchor and the line was unhooked.
func m.step(world, dt){
  local line = world.winch
  if(line == null){
    return null
  }
  local car = world.car
  local from = fairlead(car)
  line.from = from
  local to = vec.sub(line.anchor, from)
  local d = vec.length(to)
  if(d < m.DONE){
    m.release(world)
    return "done"
  }
  local way = vec.scale(to, 1 / d)
  // the line stretched: it pulls; slack, it does not push
  local stretch = d - line.length
  // (how fast the fairlead moves toward the anchor damps the spring)
  local closing = vec.dot(car.velocity, way)
  local tension = m.STIFFNESS * stretch - 9000 * closing
  if(tension < 0){
    tension = 0
  }
  if(tension > m.PULL){
    tension = m.PULL
  }
  // the drum turns while it is not held by its most pull
  if(tension < m.PULL * 0.98){
    line.length = math.max(m.DONE * 0.8, line.length - m.SPEED * dt)
  }
  // (never more slack than a hand's width: the drum keeps the line taut)
  if(line.length > d + 0.1){
    line.length = d + 0.1
  }
  line.tension = tension
  // (the truck's own brakes let go while it is pulled)
  car.winched = tension > 400
  if(tension > 0){
    car.body:add_force2(
      {way.x * tension, way.y * tension, way.z * tension}, {from.x, from.y, from.z}
    )
  }
  return null
}

return m
