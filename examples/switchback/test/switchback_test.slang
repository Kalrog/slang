// The game without a window: the drivetrain turns the wheels and is
// turned by them, the tires grip by the ground, the truck on Jolt settles
// without bouncing, stays parked on slopes, crosses them without
// creeping downhill, pulls away, brakes with its engine and stops by the
// surface; the land is the same for a seed, the trail climbs to the
// summit without crossing itself and is cut into the land, the bot
// drives it, the truck stands on the ground the game tells of, the winch
// pulls, and a run counts checkpoints, penalties and the finish.
// Run with `slang test test` in examples/switchback (or make
// switchback-test).
local t = require("slang/test")
local math = require("slang/math")
local jolt = require("jolt")
local vec = require("game/vec")
local drivetrain = require("game/drivetrain")
local tires = require("game/tires")
local surfaces = require("game/surfaces")
local car_lib = require("game/car")
local terrain = require("game/terrain")
local route = require("game/route")
local world = require("game/world")
local bot = require("game/bot")
local run = require("game/run")
local winch = require("game/winch")

local DT = 1 / 120

// ------------------------------------------------------------ helpers

// four wheels as the drivetrain is told of them
local func wheels(hold, omega){
  local out = {}
  for(local i = 0; i < 4; i = i + 1){
    append(out, {omega: omega or 0, hold: hold, ground: 0, brake: 0})
  }
  return out
}

// a plane through the origin tilted by roll (sideways) and pitch (uphill),
// in degrees, of one surface, with a truck standing on it
local func scene(o){
  o = o or {}
  local jw = jolt.world({gravity: {0, -9.81, 0}, threads: 1})
  local roll = (o.roll or 0) * math.pi / 180
  local pitch = (o.pitch or 0) * math.pi / 180
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
  local w = {
    jw: jw,
    surface_at: func(x, z){
      return surface
    },
  }
  local car = car_lib.new(w, vec.scale(normal, car_lib.WHEEL_RADIUS + (o.drop or 0.02)), q)
  return {jw: jw, car: car, q: q, time: 0}
}

local func drive(s, seconds, input, each){
  local steps = to_int(seconds / DT + 0.5)
  for(local i = 0; i < steps; i = i + 1){
    local now = input
    if(type(input) == "function"){
      now = input(s)
    }
    s.car:step(now, DT)
    s.jw:step(DT)
    s.car:read()
    s.time = s.time + DT
    if(each != null){
      each(s)
    }
  }
}

local func finish(s){
  s.car:destroy()
  s.jw:destroy()
}

// the truck's place in the plane's own frame: across, off it, along
local func place(s){
  return vec.unrotate(s.q, s.car.pos)
}

// ------------------------------------------------------------ drivetrain

t.group("drivetrain"){
  t.test("idles in neutral and revs with the throttle"){
    local d = drivetrain.new()
    for(local i = 0; i < 240; i = i + 1){
      d:step({throttle: 0, direction: 0}, wheels(drivetrain.GRIP), DT)
    }
    assert(math.abs(d.rpm - d.spec.idle) < 40, d.rpm)
    for(local i = 0; i < 240; i = i + 1){
      d:step({throttle: 1, direction: 0}, wheels(drivetrain.GRIP), DT)
    }
    // against the limiter, not past it
    assert(d.rpm > d.spec.redline - 100 and d.rpm < d.spec.limiter + 150, d.rpm)
  }
  t.test("the clutch slips against wheels that are held and passes torque"){
    local d = drivetrain.new()
    local torques = null
    for(local i = 0; i < 360; i = i + 1){
      torques = d:step({throttle: 1, direction: 1}, wheels(drivetrain.FIXED), DT)
    }
    assert(d.gear == 1 and d.slipping, "slipping in first")
    // the engine neither stalls nor runs away: it holds where the clutch takes what it makes
    assert(d.rpm > 1200 and d.rpm < 2600, d.rpm)
    local total = torques[0] + torques[1] + torques[2] + torques[3]
    assert(total > 3000, total)
  }
  t.test("the engine's speed follows the wheels once the clutch holds"){
    local d = drivetrain.new()
    local ws = wheels(drivetrain.GRIP, 0)
    local omega = 0
    for(local i = 0; i < 600; i = i + 1){
      local torques = d:step({throttle: 0.7, direction: 1}, ws, DT)
      // wheels with the truck's weight behind them: they speed up slowly
      omega = omega + (torques[0] + torques[1] + torques[2] + torques[3]) * DT / 350
      for(local k = 0; k < 4; k = k + 1){
        ws[k].omega = omega
      }
    }
    assert(not d.slipping, "the clutch holds")
    local matched = omega * d:ratio() * drivetrain.RPM
    assert(math.abs(d.rpm - matched) < 60, concat(string(d.rpm), " against ", string(matched)))
  }
  t.test("off the throttle the engine brakes the wheels"){
    local d = drivetrain.new()
    local ws = wheels(drivetrain.GRIP, 6)
    local torques = null
    for(local i = 0; i < 120; i = i + 1){
      torques = d:step({throttle: 0, direction: 1, low: true}, ws, DT)
    }
    assert(not d.slipping and d.torque < -30, d.torque)
    assert(torques[0] < -100 and torques[3] < -100, torques[0])
  }
  t.test("wheels in the air take the torque of open differentials, locks carry it over"){
    // a wheel of each axle off the ground, the truck held by the others
    local func pull(locked){
      local d = drivetrain.new()
      d.locks.front = locked
      d.locks.rear = locked
      local ws = wheels(drivetrain.GRIP, 0)
      ws[0].hold = drivetrain.AIR
      ws[3].hold = drivetrain.AIR
      local sum = 0
      for(local i = 0; i < 360; i = i + 1){
        local torques = d:step({throttle: 0.6, direction: 1}, ws, DT)
        // the wheels in the air spin up; the others stand
        ws[0].omega = ws[0].omega + torques[0] * DT / d.spec.wheel_inertia
        ws[3].omega = ws[3].omega + torques[3] * DT / d.spec.wheel_inertia
        if(i >= 240){
          sum = sum + torques[1] + torques[2]
        }
      }
      return sum / 120
    }
    local open = pull(false)
    local locked = pull(true)
    assert(locked > open * 3 and locked > 1500, concat(string(open), " open, ", string(locked), " locked"))
  }
  t.test("changes up as the truck gains speed and down when it lugs"){
    local d = drivetrain.new()
    local ws = wheels(drivetrain.GRIP, 0)
    local omega = 0
    local top = 0
    for(local i = 0; i < 1800; i = i + 1){
      local torques = d:step({throttle: 1, direction: 1}, ws, DT)
      omega = omega + (torques[0] + torques[1] + torques[2] + torques[3]) * DT / 350
      for(local k = 0; k < 4; k = k + 1){
        ws[k].omega = omega
      }
      top = math.max(top, d.gear)
    }
    assert(top >= 3, top)
    // held back to a crawl: back down the gears
    for(local i = 0; i < 1200; i = i + 1){
      omega = math.max(1.5, omega - 12 * DT)
      for(local k = 0; k < 4; k = k + 1){
        ws[k].omega = omega
      }
      d:step({throttle: 0.2, direction: 1}, ws, DT)
    }
    assert(d.gear == 1, d.gear)
  }
}

t.group("tires"){
  t.test("grip by the ground"){
    local rock = tires.grip(surfaces.rock, 0, 0, 1)
    local mud = tires.grip(surfaces.mud, 0, 0, 1)
    local ice = tires.grip(surfaces.ice, 0, 0, 1)
    assert(rock.across > 0.95 and rock.along > 0.95)
    assert(mud.across < rock.across * 0.5 and ice.across < mud.across)
    // loose ground gives more to a wheel that digs a little
    assert(tires.grip(surfaces.mud, 0.3, 0, 1).along > mud.along)
  }
  t.test("a sliding tire grips against the slide"){
    local spin = tires.grip(surfaces.dirt, 3, 0, 1)
    assert(spin.along > 0.6 and spin.across < spin.along * 0.4)
    local sideways = tires.grip(surfaces.dirt, 0, 2, 1)
    assert(sideways.across > 0.6 and sideways.along < sideways.across * 0.4)
    // both at once: the whole of it is what a sliding tire has
    local both = tires.grip(surfaces.dirt, 2, 2, 1)
    local whole = math.sqrt(both.along * both.along + both.across * both.across)
    assert(whole > 0.6 and whole < 0.9, whole)
  }
}

// ------------------------------------------------------------ the truck

t.group("truck"){
  t.test("comes to rest without bouncing"){
    local s = scene({drop: 0.3})
    local last = 0
    local turns = 0
    local way = 0
    local landed = false
    drive(s, 3, {}, func(s){
      local y = place(s).y
      if(s.car.wheels[0].contact){
        landed = true
      }
      if(landed and math.abs(y - last) > 0.00005){
        local now = if(y > last){ 1 } else { -1 }
        if(way != 0 and now != way){
          turns = turns + 1
        }
        way = now
      }
      last = y
    })
    assert(turns <= 2, turns)
    // riding at its height: the wheels' centers level with its origin
    assert(math.abs(place(s).y - car_lib.WHEEL_RADIUS) < 0.012, place(s).y)
    finish(s)
  }
  t.test("stays parked across a slope and on a hill"){
    for(let local slope in values({{roll: 25, surface: surfaces.grass}, {pitch: 30}, {pitch: -30}})){
      local s = scene(slope)
      drive(s, 2, {})
      local from = place(s)
      drive(s, 5, {})
      local to = place(s)
      local moved = math.sqrt((to.x - from.x) * (to.x - from.x) + (to.z - from.z) * (to.z - from.z))
      assert(moved < 0.004, concat("moved ", string(moved * 1000), " mm"))
      finish(s)
    }
  }
  t.test("slides off a slope its tires cannot hold"){
    local s = scene({roll: 30, surface: surfaces.mud})
    drive(s, 4, {})
    assert(math.abs(place(s).x) > 2, place(s).x)
    finish(s)
  }
  t.test("crosses a slope slowly without drifting downhill"){
    local s = scene({roll: 20, surface: surfaces.grass})
    drive(s, 1.5, {})
    local from = place(s)
    drive(s, 8, func(s){
      return {forward: if(s.car.speed < 1.6){ 0.35 } else { 0 }, low: true}
    })
    local to = place(s)
    assert(to.z - from.z > 8, to.z - from.z)
    assert(math.abs(to.x - from.x) < 0.03, to.x - from.x)
    finish(s)
  }
  t.test("pulls away through the gears with the revs following the road"){
    local s = scene({surface: surfaces.dirt})
    drive(s, 0.5, {})
    local top = 0
    local worst = 0
    drive(s, 8, {forward: 1}, func(s){
      local d = s.car.drive
      top = math.max(top, d.gear)
      // with the clutch closed and no wheel spinning, the engine turns
      // as fast as the road says
      if(not d.slipping and d.shift == null and s.time > 3){
        worst = math.max(worst, math.abs(d:speed_at(d.rpm) - s.car.speed) / math.max(1, s.car.speed))
      }
    })
    assert(s.car.speed * 3.6 > 70, s.car.speed * 3.6)
    assert(top >= 3, top)
    assert(worst < 0.04, worst)
    finish(s)
  }
  t.test("holds back down a hill on the engine alone in low range"){
    local s = scene({pitch: -22, surface: surfaces.dirt})
    drive(s, 1, {low: true})
    drive(s, 0.8, {forward: 0.4, low: true})
    drive(s, 8, {low: true})
    local d = s.car.drive
    assert(s.car.speed > 0.8 and s.car.speed < 2.4, s.car.speed)
    assert(not d.slipping and d.torque < -20 and d.gear == 1, d.torque)
    finish(s)
  }
  t.test("stops by what it stands on"){
    local func stopping(surface){
      local s = scene({surface: surface})
      drive(s, 0.5, {})
      local guard = 0
      for(s.car.speed < 12 and guard < 4000){
        drive(s, DT, {forward: 1})
        guard = guard + 1
      }
      local from = place(s)
      guard = 0
      for(s.car.speed > 0.3 and guard < 6000){
        drive(s, DT, {back: 1})
        guard = guard + 1
      }
      local d = place(s).z - from.z
      finish(s)
      return d
    }
    local rock = stopping(surfaces.rock)
    local gravel = stopping(surfaces.gravel)
    local snow = stopping(surfaces.snow)
    assert(rock < gravel and gravel < snow, concat(string(rock), " ", string(gravel), " ", string(snow)))
    assert(rock > 6 and rock < 11, rock)
  }
}

// ------------------------------------------------------------ the land

t.group("land"){
  local small = terrain.generate(5, {size: 256, workers: 2})
  terrain.finish(small, {workers: 2})
  t.test("is the same for a seed"){
    local again = terrain.generate(5, {size: 256, workers: 2})
    assert(again.heights[1000] == small.heights[1000] and again.heights[40000] == small.heights[40000])
    local other = terrain.generate(6, {size: 256, workers: 2})
    assert(other.heights[1000] != small.heights[1000])
  }
  t.test("has ground and what covers it everywhere"){
    local n = small.n
    for(local i = 0; i < n * n; i = i + 97){
      local h = small.heights[i]
      assert(h > -50 and h < 2000, h)
      local sum = 0
      for(local k = 0; k < 4; k = k + 1){
        sum = sum + small.cover[i * 4 + k] + small.cover2[i * 4 + k]
      }
      assert(sum >= 250 and sum <= 260, sum)
    }
    local surface = terrain.surface_at(small, 3.5, -20.25)
    assert(surface.grip > 0 and surface.name != null)
    local normal = terrain.normal_at(small, 3.5, -20.25)
    assert(math.abs(vec.length(normal) - 1) < 0.001)
  }
}

// one whole world for the trail, the bot and the run (it takes a moment)
local w = world.new({seed: 7})

t.group("trail"){
  local trail = w.trail
  local points = trail.points
  t.test("climbs from the meadow to the mountain"){
    assert(trail.length > 2500 and trail.length < 9000, trail.length)
    assert(trail.goal.y - trail.start.y > 300, trail.goal.y - trail.start.y)
    assert(len(trail.checkpoints) == 7)
    for(local i = 1; i < len(trail.checkpoints); i = i + 1){
      assert(trail.checkpoints[i].at > trail.checkpoints[i - 1].at)
    }
  }
  t.test("is never too steep outside its obstacles"){
    local hard = {}
    for(let local s in values(trail.sections)){
      for(local i = s.index - 2; i <= s.last + 2; i = i + 1){
        hard[i] = true
      }
    }
    // (nor in a ford, where the track is the river's bed)
    for(let local ford in values(trail.fords)){
      for(local i = to_int(ford.from / route.STEP) - 8; i <= to_int(ford.to / route.STEP) + 8; i = i + 1){
        hard[i] = true
      }
    }
    for(local i = 1; i < len(points); i = i + 1){
      if(not hard[i] and not hard[i - 1]){
        local grade = math.abs(points[i].y - points[i - 1].y) / route.STEP
        assert(grade <= route.STEEPEST + 0.001, concat(string(grade), " at ", string(i * 2), " m"))
      }
    }
  }
  t.test("does not cross or crowd itself"){
    for(local i = 0; i < len(points); i = i + 8){
      for(local j = i + 40; j < len(points); j = j + 8){
        local dx = points[i].x - points[j].x
        local dz = points[i].z - points[j].z
        assert(dx * dx + dz * dz > 6 * 6, concat(string(i * 2), " m and ", string(j * 2), " m"))
      }
    }
  }
  t.test("is cut into the land, with its obstacles"){
    local kinds = {}
    for(let local s in values(trail.sections)){
      kinds[s.kind] = true
      assert(s.to > s.from and s.from > 100)
    }
    assert(len(trail.sections) >= 8, len(trail.sections))
    assert(count(kinds) >= 4, count(kinds))
    // on a plain stretch the land is at the track's height, and it is dirt
    local checked = 0
    for(local i = 20; i < 200; i = i + 6){
      local p = points[i]
      if(p.pace == null and terrain.water_at(w.land, p.x, p.z) == 0){
        assert(math.abs(terrain.height_at(w.land, p.x, p.z) - p.y) < 0.12)
        checked = checked + 1
      }
    }
    assert(checked > 10)
    local near = route.near(w.land, points[60].x, points[60].z)
    assert(near != null and near.dist < 1.5 and math.abs(near.along - 120) < 4)
  }
}

t.group("driving the trail"){
  t.test("the bot takes the first stretch and its first obstacle"){
    local driver = bot.new()
    local lean = 1
    local section = w.trail.sections[0]
    for(w.time < 110 and driver.index < section.last + 8){
      world.step(w, driver:drive(w, world.STEP), world.STEP)
      lean = math.min(lean, w.car.up.y)
    }
    assert(driver.index >= section.last + 8, concat("got to ", string(driver.index * 2), " m"))
    assert(lean > 0.75, lean)
    assert(driver.recoveries == 0)
    // on the track: the wheels are on dirt or mud or in the ford
    local name = w.car.wheels[2].surface.name
    assert(name == "dirt" or name == "mud" or name == "riverbed" or name == "gravel" or name == "sand", name)
  }
}

t.group("the world"){
  t.test("the ground the truck drives on is the ground height_at tells of"){
    // the truck standing at a few places of the trail: its wheels'
    // contacts lie on the land's fine triangles
    for(let local index in values({40, 365, 1200})){
      world.recover(w, index)
      for(local i = 0; i < 240; i = i + 1){
        world.step(w, {}, DT)
      }
      for(let local wheel in values(w.car.wheels)){
        assert(wheel.contact)
        local off = wheel.point.y - terrain.height_at(w.land, wheel.point.x, wheel.point.z)
        assert(math.abs(off) < 0.03, concat("a wheel's contact ", string(off), " m off the ground"))
      }
    }
  }
  t.test("what stands near the truck is solid, and only that"){
    world.recover(w, 40)
    local count = 0
    for(let local e in entries(w.solids)){
      count = count + 1
    }
    assert(w.plants.total > 10000)
    assert(count < 400, count)
    // nothing stands on the track, but where stones or trunks were set
    // on it on purpose, and the cairn at its end
    local set = {}
    for(let local s in values(w.trail.sections)){
      if(s.kind == "rocks" or s.kind == "logs"){
        for(local i = s.index - 3; i <= s.last + 3; i = i + 1){
          set[i] = true
        }
      }
    }
    for(local i = 0; i < len(w.trail.points) - 4; i = i + 5){
      if(set[i]){
        continue
      }
      local p = w.trail.points[i]
      for(let local chunk in values(require("game/plants").near(w.plants, p.x, p.z, 1))){
        for(let local solid in values(require("game/plants").solids(w.plants, chunk))){
          local dx = solid.position.x - p.x
          local dz = solid.position.z - p.z
          assert(dx * dx + dz * dz > 2.2 * 2.2, concat("something stands on the track at ", string(i * 2), " m"))
        }
      }
    }
  }
  t.test("the winch pulls the truck toward what it is hooked to"){
    world.recover(w, 300)
    for(local i = 0; i < 120; i = i + 1){
      world.step(w, {}, DT)
    }
    local kind = winch.attach(w)
    assert(kind == "tree" or kind == "ground")
    assert(winch.attach(w) == null)
    local line = w.winch
    local before = vec.length(vec.sub(line.anchor, w.car.pos))
    local most = 0
    for(local i = 0; i < 600; i = i + 1){
      world.step(w, {}, DT)
      if(w.winch != null and w.winch.tension > most){
        most = w.winch.tension
      }
    }
    local after = vec.length(vec.sub(line.anchor, w.car.pos))
    // five seconds at the drum's speed, less the moment it takes to pull
    // taut (more where the ground falls toward the anchor: the truck's
    // brakes are off while it is pulled)
    assert(before - after > 1.5 and before - after < 9, before - after)
    assert(most > 500 and most <= winch.PULL, most)
    winch.release(w)
    assert(w.winch == null and not w.car.winched)
  }
}

t.group("a run"){
  t.test("starts its clock when the truck moves, takes checkpoints in order, ends at the summit"){
    world.recover(w, 4)
    local r = run.new(w)
    r.best = null
    local all = {}
    local func frames(n, input){
      for(local i = 0; i < n; i = i + 1){
        world.step(w, input, 1 / 60)
        for(let local e in values(run.step(r, w, input, 1 / 60))){
          append(all, e)
        }
      }
    }
    frames(30, {})
    assert(r.phase == "ready" and r.time == 0)
    frames(120, {forward: 0.6})
    assert(r.phase == "driving" and r.time > 1)
    // put at each checkpoint in turn (and once at a later one first: not counted)
    local checkpoints = w.trail.checkpoints
    world.recover(w, checkpoints[3].index)
    frames(5, {})
    assert(r.next == 1)
    for(local i = 1; i < len(checkpoints); i = i + 1){
      world.recover(w, checkpoints[i].index)
      r.index = checkpoints[i].index
      frames(5, {})
      assert(r.next == i + 1, r.next)
    }
    assert(r.phase == "finished")
    local kinds = {}
    for(let local e in values(all)){
      kinds[e.kind] = (kinds[e.kind] or 0) + 1
    }
    assert(kinds.start == 1 and kinds.checkpoint == 6 and kinds.finish == 1)
    local result = run.result(r)
    assert(len(result.splits) == 6 and result.time > 1)
    local info = run.info(r, w)
    assert(info.gear != null and len(info.wheels) == 4 and info.trail != null)
  }
  t.test("being put back on the trail costs time"){
    world.recover(w, 30)
    local r = run.new(w)
    r.best = null
    r.phase = "driving"
    r.index = 30
    for(local i = 0; i < 60; i = i + 1){
      world.step(w, {}, 1 / 60)
      run.step(r, w, {recover: true}, 1 / 60)
    }
    assert(r.recoveries == 1 and r.penalty == run.RECOVER_PENALTY, r.penalty)
    // (the last test with the world: it goes)
    world.destroy(w)
  }
}
