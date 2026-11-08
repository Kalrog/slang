// The game without a window: the city is the same for a seed and holds
// together (pads have clear air above them, bridges span streets between
// the lanes, the traffic's lanes are clear of the buildings), the car
// flies, drifts, sticks to walls and roofs and crashes as it should on
// Jolt, the jobs pay, and the autopilot gets through a delivery. Run
// with `slang test test` in examples/courier (or make courier-test).
local t = require("slang/test")
local math = require("slang/math")
local vec = require("game/vec")
local city = require("game/city")
local car_lib = require("game/car")
local world = require("game/world")
local traffic = require("game/traffic")
local bot = require("game/bot")
local levels = require("game/levels")

local dt = 1 / 60

local func idle(){
  return {pitch: 0, roll: 0, yaw: 0, throttle: 0, brake: 0, boost: false, magnet: false}
}

// steps the world n times with the same input (the magnet press once)
local func run(w, input, n){
  for(local i = 0; i < n; i = i + 1){
    world.step(w, input, dt)
    input.magnet = false
  }
}

t.group("city"){
  local c = city.generate(3)
  t.test("is the same for a seed and different for another"){
    local again = city.generate(3)
    assert(len(c.boxes) == len(again.boxes))
    assert(c.boxes[100].x0 == again.boxes[100].x0 and c.pads[3].name == again.pads[3].name)
    local other = city.generate(4)
    assert(other.pads[3].name != c.pads[3].name or len(other.boxes) != len(c.boxes))
  }
  t.test("has blocks, bridges, pads and lanes"){
    assert(len(c.chunks) == c.n * c.n + 1, len(c.chunks))
    assert(len(c.pads) > 20, len(c.pads))
    assert(len(c.lanes) == (c.n + 1) * len(c.lane_levels) * 4 * len(c.lane_offsets))
    local kinds = {}
    for(let local b in values(c.boxes)){
      kinds[b.kind] = (kinds[b.kind] or 0) + 1
    }
    assert(kinds[city.WALL] > 100 and kinds[city.NEON] > 100 and kinds[city.DARK] > 100)
    assert(kinds[city.BILLBOARD] > 10 and kinds[city.PAD] == len(c.pads))
  }
  t.test("every pad has clear air above it"){
    for(let local p in values(c.pads)){
      local above = city.query(c, p.x - 3, p.y + 0.5, p.z - 3, p.x + 3, p.y + 12, p.z + 3)
      assert(len(above) == 0, concat(p.name, " has ", string(len(above)), " boxes over it"))
    }
  }
  t.test("the lanes are clear of the buildings, in every district"){
    for(local li = 0; li < len(levels.list); li = li + 1){
      local lc = city.generate(5 + li, levels.get(li))
      local blocked = 0
      for(let local lane in values(lc.lanes)){
        for(local s = -lc.half; s <= lc.half; s = s + 10){
        local p = null
        if(lane.axis == "x"){
          p = {x: s, y: lane.y, z: lane.at}
        } else {
          p = {x: lane.at, y: lane.y, z: s}
        }
        for(let local side in values({-1.3, 0, 1.3})){
          local q = {x: p.x, y: p.y, z: p.z}
          if(lane.axis == "x"){
            q.z = q.z + side
          } else {
            q.x = q.x + side
          }
            if(city.box_at(lc, q) != null){
              blocked = blocked + 1
            }
          }
        }
      }
      assert(blocked == 0, concat(levels.get(li).name, ": ", string(blocked), " lane points inside boxes"))
    }
  }
  t.test("the districts grow denser and faster"){
    for(local li = 1; li < len(levels.list); li = li + 1){
      local a = levels.get(li - 1)
      local b = levels.get(li)
      assert(b.cars > a.cars and b.speed[1] > a.speed[1] and b.street < a.street + 20)
      assert(len(b.lane_levels) >= len(a.lane_levels))
    }
    local beyond = levels.get(len(levels.list) + 1)
    assert(beyond.speed[1] > levels.get(len(levels.list) - 1).speed[1])
    assert(len(levels.get(3).lane_offsets) == 3)
  }
  t.test("the grid finds the box at a point and along a ray"){
    local p = c.pads[0]
    assert(city.box_at(c, {x: p.x, y: p.y - 0.1, z: p.z}).kind == city.PAD)
    assert(city.box_at(c, {x: p.x, y: p.y + 5, z: p.z}) == null)
    local wall = null
    for(let local b in values(c.boxes)){
      if(b.kind == city.WALL and b.y1 - b.y0 > 60 and wall == null){
        wall = b
      }
    }
    local mid = (wall.y0 + wall.y1) / 2
    local hit = city.raycast(c, {x: wall.x1 + 3, y: mid, z: (wall.z0 + wall.z1) / 2}, {x: -1, y: 0, z: 0}, 60)
    assert(hit != null and hit.box == wall and math.abs(hit.dist - 3) < 2, hit)
    assert(city.raycast(c, {x: 0, y: 500, z: 0}, {x: 0, y: 1, z: 0}, 40) == null)
  }
}

t.group("car"){
  t.test("thrust reaches a top speed, the brake stops it"){
    local w = world.new({seed: 3, traffic: 0})
    car_lib.place(w.car, {x: 0, y: 250, z: 0}, 0)
    local full = idle()
    full.throttle = 1
    run(w, full, 60 * 8)
    assert(w.car.speed > 45 and w.car.speed < car_lib.TOP_SPEED + 1, w.car.speed)
    assert(w.car.pos.z > 200, w.car.pos)
    local brake = idle()
    brake.brake = 1
    run(w, brake, 60 * 4)
    assert(w.car.speed < 3, w.car.speed)
    world.destroy(w)
  }
  t.test("boost goes faster and drains the meter; the meter refills"){
    local w = world.new({seed: 3, traffic: 0})
    car_lib.place(w.car, {x: 0, y: 250, z: -300}, 0)
    local boost = idle()
    boost.throttle = 1
    boost.boost = true
    run(w, boost, 60 * 3)
    assert(w.car.speed > 55, w.car.speed)
    assert(w.car.boost < 0.3, w.car.boost)
    local coast = idle()
    run(w, coast, 60 * 10)
    assert(w.car.boost > 0.6, w.car.boost)
    world.destroy(w)
  }
  t.test("rolls, turns with the bank, and levels itself"){
    local w = world.new({seed: 3, traffic: 0})
    car_lib.place(w.car, {x: 0, y: 250, z: 0}, 0)
    local roll = idle()
    roll.roll = 1
    roll.throttle = 0.5
    run(w, roll, 20)
    local axes = car_lib.axes(w.car)
    // rolling right lifts the +x side (the car's left)
    assert(axes.right.y > 0.3, axes.right)
    // banked right, it turns right (toward -x) while it levels out
    local cruise = idle()
    cruise.throttle = 0.5
    run(w, cruise, 60)
    local heading = vec.yaw_of(car_lib.axes(w.car).forward)
    assert(heading < -0.05, heading)
    run(w, idle(), 60 * 3)
    axes = car_lib.axes(w.car)
    assert(math.abs(axes.right.y) < 0.1 and axes.up.y > 0.95, axes)
    world.destroy(w)
  }
  t.test("the magnet locks onto a roof and the car drives on it"){
    local w = world.new({seed: 3, traffic: 0})
    local pad = w.last_pad
    car_lib.place(w.car, {x: pad.x, y: pad.y + 4, z: pad.z}, 0)
    local mag = idle()
    mag.magnet = true
    run(w, mag, 90)
    assert(w.car.mode == "stick", w.car.mode)
    assert(w.car.pos.y - pad.y < 2 and w.car.pos.y - pad.y > 0.3, w.car.pos.y - pad.y)
    assert(car_lib.axes(w.car).up.y > 0.98)
    mag.throttle = 1
    local from = w.car.pos
    run(w, mag, 30)
    assert(vec.distance(from, w.car.pos) > 3)
    assert(math.abs(w.car.pos.y - from.y) < 0.5, w.car.pos.y - from.y)
    world.destroy(w)
  }
  t.test("the magnet locks onto a wall, the car rides it and leaves at its edge"){
    local w = world.new({seed: 3, traffic: 0})
    local wall = null
    for(let local b in values(w.city.boxes)){
      if(b.kind == city.WALL and b.y1 - b.y0 > 60 and b.z1 - b.z0 > 30 and wall == null){
        wall = b
      }
    }
    local mid = (wall.y0 + wall.y1) / 2
    car_lib.place(w.car, {x: wall.x1 + 4, y: mid, z: wall.z0 + 5}, 0)
    local mag = idle()
    mag.magnet = true
    run(w, mag, 90)
    assert(w.car.mode == "stick" and w.car.stick.box == wall, w.car.mode)
    local up = car_lib.axes(w.car).up
    assert(up.x > 0.98, up)
    assert(math.abs(w.car.pos.x - wall.x1 - car_lib.CLEARANCE) < 0.4, w.car.pos.x - wall.x1)
    // along the wall (+z), off its far edge
    mag.throttle = 1
    local edge = false
    for(local i = 0; i < 60 * 8 and not edge; i = i + 1){
      world.step(w, mag, dt)
      for(let local e in values(w.events)){
        if(e.kind == "detach" and e.why == "edge"){
          edge = true
        }
      }
    }
    assert(edge, w.car.pos)
    assert(w.car.mode == "fly")
    world.destroy(w)
  }
  t.test("a crash costs hull and is reported"){
    local w = world.new({seed: 3, traffic: 0})
    local wall = null
    for(let local b in values(w.city.boxes)){
      if(b.kind == city.WALL and b.y1 - b.y0 > 60 and wall == null){
        wall = b
      }
    }
    local mid = (wall.y0 + wall.y1) / 2
    car_lib.place(w.car, {x: wall.x1 + 60, y: mid, z: (wall.z0 + wall.z1) / 2}, -math.pi / 2)
    local full = idle()
    full.throttle = 1
    local hits = 0
    for(local i = 0; i < 60 * 4; i = i + 1){
      world.step(w, full, dt)
      for(let local e in values(w.events)){
        if(e.kind == "hit"){
          hits = hits + 1
          assert(e.impact > 10, e.impact)
        }
      }
    }
    assert(hits > 0)
    assert(w.car.hull < 0.9, w.car.hull)
    assert(w.car.pos.x > wall.x1, w.car.pos)
    world.destroy(w)
  }
  t.test("the city limits push it back"){
    local w = world.new({seed: 3, traffic: 0})
    car_lib.place(w.car, {x: w.city.half + 100, y: 250, z: 0}, math.pi / 2)
    local full = idle()
    full.throttle = 1
    run(w, full, 60 * 10)
    assert(w.car.pos.x < w.city.half + w.city.street + 120, w.car.pos)
    world.destroy(w)
  }
}

t.group("traffic"){
  t.test("a car's position follows its lane and wraps at the edge"){
    local w = world.new({seed: 3, traffic: 300})
    local t = w.traffic
    local car = t.cars[0]
    local lane = car.lane
    local p0 = traffic.position(car, 0)
    local p1 = traffic.position(car, 10)
    local moved = vec.sub(p1, p0)
    assert(math.abs(vec.dot(moved, lane.direction) - math.abs(lane.speed) * 10) < 0.01 or
      vec.length(moved) > t.limit, moved)
    for(local k = 0; k < 50; k = k + 1){
      local p = traffic.position(car, k * 37)
      assert(math.abs(p.x) <= t.limit and math.abs(p.z) <= t.limit, p)
      assert(city.box_at(w.city, p) == null, p)
    }
    world.destroy(w)
  }
  t.test("the cars near the player get bodies, the rest are a formula"){
    local w = world.new({seed: 3, traffic: 3000})
    local t = w.traffic
    // over a lane crossing, where the traffic is
    local lane = t.lanes[0]
    car_lib.place(w.car, {x: 0, y: lane.y + 8, z: lane.at}, 0)
    run(w, idle(), 5)
    assert(len(t.near) > 0, len(t.near))
    local with_body = 0
    for(let local car in values(t.near)){
      assert(vec.distance(car.pos, w.car.pos) < traffic.NEAR * 1.8, car.pos)
      assert(vec.distance(car.body.position, car.pos) < 2, car.body.position)
      with_body = with_body + 1
    }
    assert(with_body == len(t.near))
    // every car within the radius is in the near set
    local counted = 0
    for(let local car in values(t.cars)){
      local p = traffic.position(car, w.time)
      if(vec.distance(p, w.car.pos) < traffic.NEAR * 0.7){
        counted = counted + 1
        assert(car.mark == w.time, p)
      }
    }
    assert(counted > 0)
    // a car hit by the player becomes a wreck: thrown off its lane,
    // hidden from the conveyor, back on it later
    local victim = t.near[0]
    local before = traffic.position(victim, w.time)
    assert(traffic.wreck(t, victim, {x: 0, y: 1, z: 0}, 20, {x: 0, y: 0, z: 0}))
    assert(victim.wrecked and len(t.wrecks) == 1)
    run(w, idle(), 60)
    assert(len(t.wrecks) == 1)
    local thrown = t.wrecks[0].pos
    assert(vec.distance(thrown, traffic.position(victim, w.time)) > 3, thrown)
    for(let local car in values(t.near)){
      assert(car != victim)
    }
    // taken away after its time (or sooner, if it fell to the ground),
    // it is a car on its lane again
    run(w, idle(), 60 * traffic.WRECK_TIME + 5)
    assert(len(t.wrecks) == 0 and not victim.wrecked)
    // flown far away, the bodies are given back
    car_lib.place(w.car, {x: 0, y: 380, z: 0}, 0)
    run(w, idle(), 5)
    for(let local slot in values(t.pool)){
      assert(slot.car == null or slot.car.mark == w.time)
    }
    world.destroy(w)
  }
}

t.group("jobs"){
  t.test("a job leads from a pad to a farther pad, with a clock"){
    local w = world.new({seed: 3, traffic: 0})
    local job = w.job
    assert(job.phase == "pickup" and job.from != job.to)
    assert(vec.distance(job.from, job.to) >= 200)
    assert(job.limit > 20 and job.pay > 40)
    assert(world.target(w) == job.from)
    world.destroy(w)
  }
  t.test("arriving slowly picks up and delivers, and pays"){
    local w = world.new({seed: 3, traffic: 0})
    local job = w.job
    car_lib.place(w.car, {x: job.from.x, y: job.from.y + 3, z: job.from.z}, 0)
    run(w, idle(), 10)
    assert(job.phase == "deliver")
    assert(world.target(w) == job.to)
    car_lib.place(w.car, {x: job.to.x, y: job.to.y + 3, z: job.to.z}, 0)
    run(w, idle(), 10)
    assert(w.deliveries == 1 and w.credits > job.pay, w.credits)
    assert(w.job != job and w.job.phase == "pickup")
    world.destroy(w)
  }
  t.test("arriving fast does not count"){
    local w = world.new({seed: 3, traffic: 0})
    local job = w.job
    car_lib.place(w.car, {x: job.from.x, y: job.from.y + 3, z: job.from.z}, 0)
    w.car.body.linear_velocity = {30, 0, 0}
    world.step(w, idle(), dt)
    assert(job.phase == "pickup")
    world.destroy(w)
  }
  t.test("enough deliveries move on to the next district, earnings kept"){
    local w = world.new({seed: 3, traffic: 0, level: 0})
    assert(w.level.name == "Outskirts")
    local level_up = null
    for(local k = 0; k < w.level.deliveries and level_up == null; k = k + 1){
      local job = w.job
      car_lib.place(w.car, {x: job.from.x, y: job.from.y + 3, z: job.from.z}, 0)
      run(w, idle(), 10)
      car_lib.place(w.car, {x: job.to.x, y: job.to.y + 3, z: job.to.z}, 0)
      for(local i = 0; i < 10 and level_up == null; i = i + 1){
        world.step(w, idle(), dt)
        for(let local e in values(w.events)){
          if(e.kind == "level_up"){
            level_up = e
          }
        }
      }
    }
    assert(level_up != null and level_up.next == 1 and level_up.level.name == "Midtown")
    local credits = w.credits
    assert(credits > 0 and w.deliveries == 3)
    world.destroy(w)
    local next = world.new({seed: 4, traffic: 0, level: 1, credits: credits, deliveries: 3})
    assert(next.level.name == "Midtown" and next.credits == credits and next.deliveries == 3)
    assert(next.level_deliveries == 0 and next.job != null)
    world.destroy(next)
  }
  t.test("a wreck loses the job and sets the car down at the last pad"){
    local w = world.new({seed: 3, traffic: 0})
    local pad = w.last_pad
    car_lib.place(w.car, {x: 0, y: 300, z: 0}, 0)
    w.car.hull = 0
    world.step(w, idle(), dt)
    assert(w.state == "wrecked" and w.job == null)
    run(w, idle(), 60 * 4)
    assert(w.state == "play" and w.job != null and w.car.hull == 1)
    assert(vec.distance(w.car.pos, pad) < 3, w.car.pos)
    world.destroy(w)
  }
}

t.group("autopilot"){
  t.test("picks up a package within two minutes"){
    local w = world.new({seed: 7, traffic: 60})
    local picked = false
    for(local i = 0; i < 60 * 120 and not picked; i = i + 1){
      world.step(w, bot.input(w, dt), dt)
      for(let local e in values(w.events)){
        if(e.kind == "pickup"){
          picked = true
        }
      }
    }
    assert(picked, w.car.pos)
    world.destroy(w)
  }
}
