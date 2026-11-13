// game/world: the land, the physics and the truck together, without a
// window. The land (game/terrain) is a Jolt height field; the truck
// (game/car) drives on it and reads the surface under each wheel from
// it. What stands on the land (game/plants) is solid where the truck is:
// the trunks, boulders and logs near it are bodies, made as it comes and
// removed as it goes. The physics runs in fixed steps of its own, however
// long a frame takes.
//
//   local w = world.new({seed: 7})
//   world.step(w, input, frame_time)
//   w.car.pos, w.land
//   world.destroy(w)
local math = require("slang/math")
local jolt = require("jolt")
local terrain = require("game/terrain")
local route = require("game/route")
local car_lib = require("game/car")
local plants = require("game/plants")
local winch = require("game/winch")
local props = require("game/props")
local surfaces = require("game/surfaces")
local vec = require("game/vec")

local m = {}

m.STEP = 1 / 120        // a step of the physics, s
m.MAX_STEPS = 6         // per frame: a slow frame slows the game, not more
// what stands within SOLID_NEAR meters of the truck is solid; it stays so
// until the truck is SOLID_FAR away
m.SOLID_NEAR = 34
m.SOLID_FAR = 46

// where the truck starts: on the meadow by the river, in the south of
// the map, looking up the valley
local func start_of(land){
  local z = -land.half * 0.72
  local x = 0
  // the river's line at that z, and a little to its side
  local best = 1.0e9
  for(let local p in values(land.river.points)){
    local d = math.abs(p.z - z)
    if(d < best){
      best = d
      x = p.x
    }
  }
  x = x + 34
  return {x: x, y: terrain.height_at(land, x, z) + car_lib.WHEEL_RADIUS + 0.25, z: z}
}

// the shapes of the boulders, made once: a hull each, of its size at
// scale 1
local rock_hulls = null

// a solid of game/plants as a body of the world
local func solid_body(w, solid){
  local shape = null
  if(solid.kind == "cylinder"){
    shape = jolt.cylinder(solid.half_height, solid.radius)
  } else {
    if(rock_hulls == null){
      rock_hulls = {}
      for(let local rock in values(plants.rock_shapes())){
        append(rock_hulls, jolt.convex_hull(rock.hull, {max_convex_radius: 0.03}))
      }
    }
    shape = jolt.scaled(rock_hulls[solid.shape], {solid.scale, solid.scale, solid.scale})
  }
  local p = solid.position
  return w.jw:create_body({
    shape: shape,
    position: {p.x, p.y, p.z},
    rotation: solid.rotation,
    friction: car_lib.WORLD_FRICTION,
  })
}

// solids(w): the trunks, boulders and logs near the truck made bodies,
// those it has left behind removed
local func solids(w){
  local p = w.plants
  if(p == null){
    return
  }
  local at = w.car.pos
  local near = m.SOLID_NEAR * m.SOLID_NEAR
  local far = m.SOLID_FAR * m.SOLID_FAR
  local keep = {}
  for(let local chunk in values(plants.near(p, at.x, at.z, m.SOLID_FAR))){
    local list = plants.solids(p, chunk)
    for(local i = 0; i < len(list); i = i + 1){
      local q = list[i].position
      local d = (q.x - at.x) * (q.x - at.x) + (q.z - at.z) * (q.z - at.z)
      if(d < far){
        local key = chunk.index * 1024 + i
        if(w.solids[key] != null){
          keep[key] = true
        } else if(d < near){
          w.solids[key] = solid_body(w, list[i])
          keep[key] = true
        }
      }
    }
  }
  local gone = {}
  for(let local e in entries(w.solids)){
    if(not keep[e[0]]){
      append(gone, e[0])
    }
  }
  for(let local key in values(gone)){
    w.solids[key]:destroy()
    delete(w.solids, key)
  }
  w.solids_at = {x: at.x, z: at.z}
}

// new(options?: {seed?: int, size?: int, land?: Terrain, trail?: bool,
//   plants?: bool, start?: Vec3, yaw?: float,
//   progress?: func(share: float, what: string)}) -> World
// A world of a seed (7 by default): its land with the trail cut into it
// and trees, bushes and rocks set on it (not on the track), the truck at
// the trailhead. size is the land's (see terrain.generate; a land smaller
// than the whole map has no trail); a land made before can be given
// instead; trail false leaves the trail out, plants false what grows;
// progress is called before each part of the making with the share done
// so far.
func m.new(options){
  options = options or {}
  // (what is being made, for whoever shows it)
  local progress = options.progress or func(share, what){}
  progress(0.02, "Raising the mountains")
  local land = options.land or terrain.generate(options.seed or 7, {size: options.size})
  local trail = null
  if(options.trail != false and land.n == terrain.SIZE and land.trail == null){
    progress(0.45, "Cutting the trail")
    trail = route.plan(land)
    route.carve(land, trail)
  }
  if(land.shape == null){
    progress(0.6, "Laying out the ground and the light")
    terrain.finish(land)
  }
  if(land.fine == null){
    // (a land without a trail: smooth all the same)
    terrain.refine(land)
  }
  progress(0.85, "Setting the truck on its wheels")
  local jw = jolt.world({gravity: {0, -9.81, 0}})
  // the ground the truck drives on: the land's fine heights
  local fine = land.fine
  local ground = jw:create_body({
    shape: jolt.height_field(fine.heights, {
      size: fine.n,
      offset: {-land.half, 0, -land.half},
      scale: {fine.spacing, 1, fine.spacing},
      block_size: 4,
      bits_per_sample: 12,
    }),
    friction: car_lib.WORLD_FRICTION,
  })
  local w = {
    land: land,
    jw: jw,
    ground: ground,
    time: 0,
    left_over: 0,
    steps: 0,
  }
  // (y: how high the wheel stands, when it is known: on a boulder or a
  // log it stands on that, not on the ground under it)
  w.surface_at = func(x, z, y){
    if(y != null and y - terrain.height_at(land, x, z) > 0.12){
      return surfaces.rock
    }
    return terrain.surface_at(land, x, z)
  }
  w.trail = trail
  w.solids = {}
  if(options.plants != false){
    progress(0.92, "Planting the woods")
    w.plants = plants.scatter(land, {mask: route.clear(land, 2)})
    if(trail != null){
      // (and what is set on the trail by hand: stones, fallen trunks)
      props.add(w.plants, props.trail(land, trail))
    }
  }
  local start = options.start
  local yaw = options.yaw or 0
  if(start == null and trail != null){
    // on the trail, a little way in, looking along it
    local p = trail.points[4]
    start = {x: p.x, y: terrain.height_at(land, p.x, p.z) + car_lib.WHEEL_RADIUS + 0.25, z: p.z}
    yaw = route.direction(trail, 4)
  }
  if(start == null){
    start = start_of(land)
  }
  w.start = start
  w.start_yaw = yaw
  w.step_time = m.STEP
  w.car = car_lib.new(w, start, yaw)
  solids(w)
  return w
}

// step(w, input: car.Input, dt: float) -> how many steps of the physics
// A frame of dt seconds: as many fixed steps as fit in it (and in what
// was left over from the frame before). Afterwards w.knock is the most
// the truck's velocity changed in one of them (m/s): how hard it was hit,
// and w.winch_done is true if the winch pulled the truck all the way in
// (game/winch; whoever reads it sets it back).
func m.step(w, input, dt){
  w.left_over = w.left_over + dt
  local n = 0
  local knock = 0
  for(w.left_over >= m.STEP and n < m.MAX_STEPS){
    local before = w.car.velocity
    if(w.winch != null and winch.step(w, m.STEP) == "done"){
      w.winch_done = true
    }
    w.car:step(input, m.STEP)
    w.jw:step(m.STEP)
    w.car:read()
    // how much the truck's speed changed at once: a knock
    local after = w.car.velocity
    local dx = after.x - before.x
    local dy = after.y - before.y
    local dz = after.z - before.z
    knock = math.max(knock, math.sqrt(dx * dx + dy * dy + dz * dz))
    w.left_over = w.left_over - m.STEP
    w.time = w.time + m.STEP
    n = n + 1
  }
  if(n == m.MAX_STEPS){
    w.left_over = 0
  }
  w.steps = w.steps + n
  w.knock = knock
  // what is solid around the truck: looked at again every few meters
  local at = w.car.pos
  local was = w.solids_at
  if(was == null or (at.x - was.x) * (at.x - was.x) + (at.z - was.z) * (at.z - was.z) > 16){
    solids(w)
  }
  return n
}

// recover(w, index?): the truck back on its wheels on the trail, at the
// trail's point `index` (by default a little before where it is now),
// standing still and looking along the trail
func m.recover(w, index){
  winch.release(w)
  local trail = w.trail
  if(trail == null){
    w.car:place(w.start, w.start_yaw)
    solids(w)
    return
  }
  if(index == null){
    // the trail's point nearest the truck
    local best = 1.0e12
    index = 0
    local pos = w.car.pos
    for(local i = 0; i < len(trail.points); i = i + 1){
      local p = trail.points[i]
      local d = (p.x - pos.x) * (p.x - pos.x) + (p.z - pos.z) * (p.z - pos.z)
      if(d < best){
        best = d
        index = i
      }
    }
    index = math.max(0, index - 4)
  }
  local p = trail.points[index]
  w.car:place({
    x: p.x, y: terrain.height_at(w.land, p.x, p.z) + car_lib.WHEEL_RADIUS + 0.3, z: p.z
  }, route.direction(trail, index))
  solids(w)
}

func m.destroy(w){
  w.car:destroy()
  w.jw:destroy()
}

return m
