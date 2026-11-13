// tool/lab: the truck's physics on a test bench, without a window. Each
// scene is a plane (tilted sideways or uphill, of one surface), a truck
// on it and a script for the driver; what the truck does is printed.
//
//   cd examples/switchback && ../../bin/slang run tool/lab.slang [scene...]
//
// Scenes: settle, side, hill, traverse, launch, crawl, brake, descent,
// air, mud. Without a name every scene runs.
local math = require("slang/math")
local str = require("slang/string")
local time = require("slang/time")
local jolt = require("jolt")
local vec = require("game/vec")
local car_lib = require("game/car")
local drivetrain = require("game/drivetrain")
local surfaces = require("game/surfaces")

local os = require("slang/os")
// LAB_HZ: the physics steps a second (120 by default)
local DT = 1 / str.to_number(os.getenv("LAB_HZ") or "120")

local func fmt(v, digits){
  return str.format(concat("%.", string(digits or 2), "f"), v)
}

// a plane through the origin tilted by roll (sideways) and pitch
// (uphill along z), in degrees, with a truck standing on it
local func scene(o){
  o = o or {}
  local jw = jolt.world({gravity: {0, -9.81, 0}, threads: 1})
  local roll = (o.roll or 0) * math.pi / 180
  local pitch = (o.pitch or 0) * math.pi / 180
  // pitch about x lifts +z; roll about z lifts +x
  local q = vec.quat_multiply(
    vec.quat_axis({x: 1, y: 0, z: 0}, -pitch), vec.quat_axis({x: 0, y: 0, z: 1}, roll)
  )
  local normal = vec.rotate(q, {x: 0, y: 1, z: 0})
  jw:create_body({
    shape: jolt.box({400, 1, 400}),
    position: {-normal.x, -normal.y, -normal.z},
    rotation: q,
    friction: car_lib.WORLD_FRICTION,
  })
  local surface = o.surface or surfaces.rock
  local world = {
    jw: jw,
    step_time: DT,
    surface_at: func(x, z){
      return surface
    },
  }
  local lift = car_lib.WHEEL_RADIUS + (o.drop or 0.02)
  local car = car_lib.new(world, vec.scale(normal, lift), q)
  return {jw: jw, world: world, car: car, q: q, normal: normal, time: 0}
}

local func run(s, seconds, input, each){
  local steps = to_int(seconds / DT + 0.5)
  for(local i = 0; i < steps; i = i + 1){
    local inp = input
    if(type(input) == "function"){
      inp = input(s.time)
    }
    s.car:step(inp, DT)
    s.jw:step(DT)
    s.car:read()
    s.time = s.time + DT
    if(each != null){
      each(s, i)
    }
  }
}

local func finish(s){
  s.car:destroy()
  s.jw:destroy()
}

// the truck's place in the plane's own frame: across (x), off it (y),
// along (z)
local func local_pos(s){
  return vec.unrotate(s.q, s.car.pos)
}

local func line(...parts){
  local out = {}
  for(let local p in values(parts)){
    append(out, string(p))
  }
  print(concat(...out), "\n")
}

local func wheel_line(s){
  local c = s.car
  local parts = {}
  for(local i = 0; i < 4; i = i + 1){
    local w = c.wheels[i]
    append(parts, concat(fmt(w.length, 3), "m ", fmt(w.load / 1000, 1), "kN"))
  }
  return concat(parts[0], " | ", parts[1], " | ", parts[2], " | ", parts[3])
}

local scenes = {}

// dropped from 30 cm: how the suspension takes it and comes to rest
func scenes.settle(){
  line("== settle: dropped from 0.3 m onto level rock")
  local s = scene({drop: 0.3})
  local last = 0
  local turns = 0
  local direction = 0
  local lowest = 10
  local highest = -10
  local landed = false
  run(s, 4, {}, func(s, i){
    local y = local_pos(s).y
    if(s.car.wheels[0].contact){
      landed = true
    }
    if(landed){
      local d = y - last
      if(math.abs(d) > 0.00002){
        local now = if(d > 0){ 1 } else { -1 }
        if(direction != 0 and now != direction){
          turns = turns + 1
        }
        direction = now
      }
      lowest = math.min(lowest, y)
      if(s.time > 1.5){
        highest = math.max(highest, y)
      }
    }
    last = y
    if(i % 30 == 0 and s.time < 2.6){
      line("  t=", fmt(s.time), " y=", fmt(y, 4), "  ", wheel_line(s))
    }
  })
  local y = local_pos(s).y
  line("  rest height of the origin over the plane: ", fmt(y, 4), " (wheel radius ", car_lib.WHEEL_RADIUS, ")")
  line("  lowest ", fmt(lowest, 4), ", direction changes after landing: ", turns, ", after 1.5 s within ", fmt(highest - y, 5))
  finish(s)
}

// parked across a slope: does it stay
func scenes.side(){
  for(let local angle in values({15, 25, 30})){
    for(let local surface in values({surfaces.rock, surfaces.grass, surfaces.mud})){
      local s = scene({roll: angle, surface: surface})
      run(s, 2, {})
      local from = local_pos(s)
      run(s, 10, {})
      local to = local_pos(s)
      line("== side slope ", angle, " deg on ", surface.name, ": moved ", fmt((to.x - from.x) * 1000, 2), " mm across, ",
        fmt((to.z - from.z) * 1000, 2), " mm along in 10 s (needs grip ", fmt(math.tan(angle * math.pi / 180)), ", has ", surface.grip, ")")
      finish(s)
    }
  }
}

// parked on a hill, nose up and nose down
func scenes.hill(){
  for(let local angle in values({20, 30, -30})){
    local s = scene({pitch: angle, surface: surfaces.rock})
    run(s, 2, {})
    local from = local_pos(s)
    run(s, 10, {})
    local to = local_pos(s)
    line("== hill ", angle, " deg on rock: moved ", fmt((to.z - from.z) * 1000, 2), " mm along, ",
      fmt((to.x - from.x) * 1000, 2), " mm across in 10 s; rpm ", fmt(s.car.drive.rpm, 0))
    finish(s)
  }
}

// a slow drive across a slope: how far it drifts downhill
func scenes.traverse(){
  for(let local case in values({{20, surfaces.rock}, {20, surfaces.grass}, {25, surfaces.dirt}})){
    local s = scene({roll: case[0], surface: case[1]})
    run(s, 1.5, {})
    local from = local_pos(s)
    run(s, 12, func(t){
      // gently: hold about walking pace
      local go = if(s.car.speed < 1.6){ 0.35 } else { 0.0 }
      return {forward: go, low: true}
    })
    local to = local_pos(s)
    line("== traverse ", case[0], " deg on ", case[1].name, ": went ", fmt(to.z - from.z, 1), " m, drifted ",
      fmt((to.x - from.x) * 100, 1), " cm downhill; speed ", fmt(s.car.speed), " m/s, gear ", s.car.drive.gear,
      ", rpm ", fmt(s.car.drive.rpm, 0))
    finish(s)
  }
}

// full throttle from rest on the level: the engine, the gears, the road
func scenes.launch(){
  line("== launch: full throttle from rest on level dirt")
  local s = scene({surface: surfaces.dirt})
  run(s, 1, {})
  local t100 = null
  run(s, 14, {forward: 1}, func(s, i){
    local c = s.car
    if(t100 == null and c.speed * 3.6 >= 100){
      t100 = s.time - 1
    }
    if(i % 60 == 0){
      local d = c.drive
      local road = d:speed_at(d.rpm)
      line("  t=", fmt(s.time - 1, 1), " v=", fmt(c.speed * 3.6, 1), " km/h gear ", d.gear, " rpm ", fmt(d.rpm, 0),
        " clutch ", fmt(d.clutch), if(d.slipping){ " slip" } else { " lock" }, " engine ", fmt(d.torque, 0), " Nm; rpm speed ",
        fmt(road * 3.6, 1), " km/h; wheels ", fmt(c.wheels[0].omega * car_lib.WHEEL_RADIUS * 3.6, 1), " ",
        fmt(c.wheels[2].omega * car_lib.WHEEL_RADIUS * 3.6, 1))
    }
  })
  line("  0-100 km/h: ", if(t100 == null){ "not reached" } else { concat(fmt(t100, 1), " s") })
  // lift off: the engine brakes
  local v0 = s.car.speed
  run(s, 3, {})
  line("  3 s off the throttle: ", fmt(v0 * 3.6, 1), " -> ", fmt(s.car.speed * 3.6, 1), " km/h, gear ", s.car.drive.gear,
    ", rpm ", fmt(s.car.drive.rpm, 0), ", engine ", fmt(s.car.drive.torque, 0), " Nm")
  finish(s)
}

// low range, a little throttle: walking pace, held
func scenes.crawl(){
  line("== crawl: low range up a 25 deg hill on rock, 30% throttle then none")
  local s = scene({pitch: 25, surface: surfaces.rock})
  run(s, 1.5, {low: true})
  local from = local_pos(s)
  run(s, 6, {forward: 0.3, low: true}, func(s, i){
    if(i % 120 == 0){
      local d = s.car.drive
      line("  t=", fmt(s.time - 1.5, 1), " v=", fmt(s.car.speed, 2), " m/s gear ", d.gear, " rpm ", fmt(d.rpm, 0), " clutch ", fmt(d.clutch),
        if(d.slipping){ " slip" } else { " lock" }, " engine ", fmt(d.torque, 0), " Nm")
    }
  })
  local mid = local_pos(s)
  line("  climbed ", fmt(mid.z - from.z, 2), " m in 6 s")
  run(s, 4, {low: true}, func(s, i){
    if(i % 120 == 0){
      line("  released t=", fmt(s.time - 7.5, 1), " v=", fmt(s.car.speed, 3), " m/s holding ", s.car.holding)
    }
  })
  local to = local_pos(s)
  line("  after releasing: rolled ", fmt((to.z - mid.z) * 100, 1), " cm in 4 s")
  finish(s)
}

// braking from 60 km/h on different ground
func scenes.brake(){
  for(let local surface in values({surfaces.rock, surfaces.gravel, surfaces.mud, surfaces.ice})){
    local s = scene({surface: surface})
    run(s, 1, {})
    local guard = 0
    for(s.car.speed < 60 / 3.6 and guard < 6000){
      run(s, DT, {forward: 1})
      guard = guard + 1
    }
    local from = local_pos(s)
    local v0 = s.car.speed
    local t0 = s.time
    guard = 0
    for(s.car.speed > 0.2 and guard < 6000){
      run(s, DT, {back: 1})
      guard = guard + 1
    }
    local to = local_pos(s)
    local dist = to.z - from.z
    line("== brake on ", surface.name, ": from ", fmt(v0 * 3.6, 0), " km/h in ", fmt(dist, 1), " m, ", fmt(s.time - t0, 1),
      " s (", fmt(v0 * v0 / (2 * math.max(0.01, dist)) / 9.81, 2), " g; grip ", surface.grip, "), drifted ", fmt((to.x - from.x) * 100, 0), " cm")
    finish(s)
  }
}

// low range down a steep hill with no pedal: the engine holds it back
func scenes.descent(){
  line("== descent: 22 deg downhill on dirt, low range, a push and then no pedals")
  local s = scene({pitch: -22, surface: surfaces.dirt})
  run(s, 1, {low: true})
  run(s, 0.8, {forward: 0.4, low: true})
  run(s, 10, {low: true}, func(s, i){
    if(i % 120 == 0){
      local d = s.car.drive
      line("  t=", fmt(s.time - 1.8, 1), " v=", fmt(s.car.speed, 2), " m/s gear ", d.gear, " rpm ", fmt(d.rpm, 0), " engine ", fmt(d.torque, 0),
        " Nm clutch ", fmt(d.clutch), if(d.slipping){ " slip" } else { " lock" })
    }
  })
  finish(s)
}

// one wheel off the ground: open differentials let it spin, locked ones
// drive on
func scenes.air(){
  for(let local locked in values({false, true})){
    local s = scene({surface: surfaces.rock})
    // a block under the frame's rear left lifts that wheel... simpler: ice
    // under the rear and front left wheels is not the same thing, so the
    // plane is made of ice and the right side stands on rock
    local ice = surfaces.ice
    s.world.surface_at = func(x, z){
      if(x > 0){
        return ice
      }
      return surfaces.rock
    }
    run(s, 1, {low: true})
    local from = local_pos(s)
    run(s, 4, {forward: 0.6, low: true, lock_front: locked, lock_rear: locked})
    local to = local_pos(s)
    local c = s.car
    line("== split grip (left wheels on ice), 60% throttle, low range, locks ", locked, ": went ", fmt(to.z - from.z, 1), " m in 4 s, v=",
      fmt(c.speed, 1), " m/s rpm ", fmt(c.drive.rpm, 0), " wheels ", fmt(c.wheels[0].omega * 0.42, 1), " ", fmt(c.wheels[1].omega * 0.42, 1), " ",
      fmt(c.wheels[2].omega * 0.42, 1), " ", fmt(c.wheels[3].omega * 0.42, 1), " m/s")
    finish(s)
  }
}

// mud: slow going, and it stops soon when the throttle lifts
func scenes.mud(){
  line("== mud: full throttle on level mud, high range")
  local s = scene({surface: surfaces.mud})
  run(s, 1, {})
  run(s, 6, {forward: 1}, func(s, i){
    if(i % 120 == 0){
      local c = s.car
      line("  t=", fmt(s.time - 1, 1), " v=", fmt(c.speed * 3.6, 1), " km/h gear ", c.drive.gear, " rpm ", fmt(c.drive.rpm, 0), " wheels ",
        fmt(c.wheels[0].omega * 0.42 * 3.6, 1), " ", fmt(c.wheels[2].omega * 0.42 * 3.6, 1), " km/h")
    }
  })
  local from = local_pos(s)
  run(s, 5, {})
  local to = local_pos(s)
  line("  coasted ", fmt(to.z - from.z, 1), " m to ", fmt(s.car.speed, 2), " m/s")
  finish(s)
}

local names = args()
local order = {"settle", "side", "hill", "traverse", "launch", "crawl", "brake", "descent", "air", "mud"}
local chosen = {}
for(local i = 0; i < len(names); i = i + 1){
  if(scenes[names[i]] != null){
    append(chosen, names[i])
  }
}
if(len(chosen) == 0){
  chosen = order
}
local started = time.clock()
for(let local name in values(chosen)){
  scenes[name]()
}
line("lab: ", fmt((time.clock() - started) / 1000, 1), " s")
