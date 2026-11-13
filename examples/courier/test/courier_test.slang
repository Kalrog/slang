// The game without a window: the city is the same for a seed and holds
// together (pads have clear air above them, bridges span streets between
// the lanes, the traffic's lanes are clear of the buildings), the car
// flies, drifts, sticks to walls and roofs and crashes as it should on
// Jolt, the board offers jobs of four kinds that pay, near misses chain
// into cash, slots are ridden
// through on a wall, routes join pads through the clear air of the
// streets, and the autopilot flies its jobs through the traffic
// without touching anything. Run
// with `slang test test` in examples/courier (or make courier-test).
local t = require("slang/test")
local math = require("slang/math")
local vec = require("game/vec")
local city = require("game/city")
local car_lib = require("game/car")
local world = require("game/world")
local traffic = require("game/traffic")
local bot = require("game/bot")
local near_miss = require("game/near_miss")
local nav = require("game/nav")
local missions = require("game/missions")
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
  t.test("crossing lanes never share a height: traffic passes over and under"){
    for(local li = 0; li < len(levels.list); li = li + 1){
      local lc = city.generate(5 + li, levels.get(li))
      local xs = {}
      local zs = {}
      for(let local lane in values(lc.lanes)){
        if(lane.axis == "x"){
          xs[lane.y] = true
        } else {
          zs[lane.y] = true
        }
      }
      for(let local yx in keys(xs)){
        for(let local yz in keys(zs)){
          // a car is 1.7 m tall: more than that apart
          assert(math.abs(yx - yz) > 3, concat(string(yx), " and ", string(yz)))
        }
      }
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
  t.test("belly first, the magnet takes a wall at speed: a slam, not a crash; nose first it crashes"){
    local w = world.new({seed: 3, traffic: 0})
    local wall = null
    for(let local b in values(w.city.boxes)){
      if(b.kind == city.WALL and b.y1 - b.y0 > 60 and b.z1 - b.z0 > 30 and wall == null){
        wall = b
      }
    }
    local mid = (wall.y0 + wall.y1) / 2
    local func fly_at(q, cooldown){
      local pos = {x: wall.x1 + 12, y: mid, z: (wall.z0 + wall.z1) / 2}
      car_lib.place(w.car, pos, 0)
      w.car.q = q
      w.car.cooldown = cooldown or 0
      w.car.hull = 1
      w.car.body:set_position_rotation_and_velocity(pos, q, {-40, 0, 10}, {0, 0, 0})
      local seen = {}
      for(local i = 0; i < 40; i = i + 1){
        world.step(w, idle(), dt)
        for(let local e in values(w.events)){
          seen[e.kind] = e
        }
      }
      return seen
    }
    // its underside to the wall: up along the wall's normal (+x)
    local seen = fly_at(vec.quat_look({x: 0, y: 0, z: 1}, {x: 1, y: 0, z: 0}))
    assert(seen.attach != null and seen.attach.slam > car_lib.GRAB_SPEED, seen.attach)
    assert(seen.hit == null and w.car.hull == 1 and w.car.mode == "stick" and w.car.stick.box == wall)
    // just after a jump (the magnet held off) it still lands, belly first
    w.car.left_box = null
    w.car.jumped = true
    seen = fly_at(vec.quat_look({x: 0, y: 0, z: 1}, {x: 1, y: 0, z: 0}), 5)
    assert(seen.hit == null and w.car.mode == "stick")
    // level, nose first into it
    seen = fly_at(vec.quat_yaw(-math.pi / 2))
    assert(seen.hit != null and w.car.hull < 1, seen)
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
  // a pyramid on a roof (game/city: a solid), and the face of it that
  // slopes most toward +x
  local func pyramid(w){
    for(let local b in values(w.city.boxes)){
      if(b.solid != null and b.crown and b.kind == city.ROOF and b.y1 - b.y0 > 8 and
        b.solid.top[0].x == b.solid.top[1].x and b.solid.top[0].x == b.solid.top[2].x){
        local face = null
        for(let local f in values(city.solid_faces(b.solid))){
          if(f.n.y > 0.2 and f.n.y < 0.95 and (face == null or f.n.x > face.n.x)){
            face = f
          }
        }
        return {box: b, face: face}
      }
    }
    return null
  }
  t.test("a sloped roof collides where it slopes, not at its bounds"){
    local w = world.new({seed: 3, level: 3, traffic: 0, flyers: 0})
    local p = pyramid(w)
    assert(p != null)
    local b = p.box
    // over a corner of its bounds: the slope there is near its foot
    local from = {x: b.x0 + 0.8, y: b.y1 + 5, z: b.z0 + 0.8}
    local down = b.y1 - b.y0 + 10
    local hit = w.phys.jw:cast_ray(from, {0, -down, 0})
    assert(hit != null)
    local y = from.y - down * hit.fraction
    assert(y < b.y0 + (b.y1 - b.y0) * 0.3, y - b.y0)
    world.destroy(w)
  }
  t.test("the magnet holds the car on a slope, belly to it"){
    local w = world.new({seed: 3, level: 3, traffic: 0, flyers: 0})
    local p = pyramid(w)
    local f = p.face
    local c = {x: 0, y: 0, z: 0}
    for(let local q in values(f.points)){
      c = vec.add(c, q)
    }
    c = vec.scale(c, 1 / len(f.points))
    local up = f.n
    local forward = vec.normalize(vec.cross({x: 0, y: 1, z: 0}, up))
    local q = vec.quat_look(forward, up)
    local pos = vec.add_scaled(c, up, car_lib.CLEARANCE + 0.6)
    w.car.pos = pos
    w.car.q = q
    w.car.body:set_position_rotation_and_velocity(pos, q, {0, 0, 0}, {0, 0, 0})
    local mag = idle()
    mag.magnet = true
    run(w, mag, 90)
    assert(w.car.mode == "stick" and w.car.stick.box == p.box, w.car.mode)
    assert(vec.dot(w.car.stick.normal, f.n) > 0.999)
    // it stays on the face, the clearance off it
    local d = vec.dot(f.n, w.car.pos) - f.d
    assert(math.abs(d - car_lib.CLEARANCE) < 0.4, d)
    world.destroy(w)
  }
  t.test("a hole goes through its tier: the air down its middle is clear, the walls round it solid"){
    local w = world.new({seed: 3, level: 3, traffic: 0, flyers: 0})
    local found = 0
    for(let local block in values(w.city.blocks)){
      for(let local tw in values(block.towers)){
        for(let local tier in values(tw)){
          local h = tier.hole
          if(h != null){
            found = found + 1
            local u = (h.u0 + h.u1) / 2
            local v = (h.v0 + h.v1) / 2
            local from = null
            local dir = null
            local len = 0
            if(h.axis == "x"){
              from = {x: tier.x0 - 3, y: v, z: u}
              len = tier.x1 - tier.x0 + 6
              dir = {len, 0, 0}
            } else {
              from = {x: u, y: v, z: tier.z0 - 3}
              len = tier.z1 - tier.z0 + 6
              dir = {0, 0, len}
            }
            // (a twin's middle is its pillar: down one of the two)
            if(h.shape == "twin"){
              local off = (h.u1 - h.u0) / 4 + 0.5
              if(h.axis == "x"){ from.z = from.z - off } else { from.x = from.x - off }
            }
            assert(w.phys.jw:cast_ray(from, dir) == null, h.shape)
            // and over it, the wall
            local above = {x: from.x, y: h.v1 + 2, z: from.z}
            assert(w.phys.jw:cast_ray(above, dir) != null, h.shape)
          }
        }
      }
    }
    assert(found > 3, found)
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
  t.test("the magnet is on by itself; its button jumps off the surface"){
    local w = world.new({seed: 3, traffic: 0})
    local pad = w.last_pad
    car_lib.place(w.car, {x: pad.x, y: pad.y + 3, z: pad.z}, 0)
    run(w, idle(), 90)
    assert(w.car.mode == "stick", w.car.mode)
    local jump = idle()
    jump.magnet = true
    run(w, jump, 12)
    assert(w.car.mode == "fly", w.car.mode)
    assert(w.car.vel.y > 4 and w.car.pos.y > pad.y + 2, w.car.vel)
    world.destroy(w)
  }
  t.test("over the tallest building the car is pulled back down"){
    local w = world.new({seed: 3, traffic: 0})
    local top = w.phys.ceiling
    assert(top > 50, top)
    car_lib.place(w.car, {x: 0, y: top + 60, z: 0}, 0)
    local climb = idle()
    climb.throttle = 1
    climb.pitch = -1
    run(w, climb, 60 * 4)
    assert(w.car.pos.y < top + 40, w.car.pos.y - top)
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
  t.test("every car has a design, its class's box, and a body of that size near the player"){
    local w = world.new({seed: 5, level: 2})
    local classes = {}
    for(let local car in values(w.traffic.cars)){
      assert(car.design != null and car.half != null)
      classes[car.class] = true
    }
    // all the classes come up in a city's worth of cars
    for(let local name in values(require("game/designs").CLASS_ORDER)){
      assert(classes[name], name)
    }
    run(w, idle(), 5)
    for(let local slot in values(w.traffic.pool)){
      if(slot.car != null){
        assert(slot.class == slot.car.class)
      }
    }
    world.destroy(w)
  }
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

// steps the world through the missions n times with the same input
local func play(w, input, n){
  local seen = {}
  for(local i = 0; i < n; i = i + 1){
    missions.step(w, input, dt)
    input.magnet = false
    for(let local e in values(w.events)){
      seen[e.kind] = e
    }
  }
  return seen
}

// the offer of a kind put on the board near the car
local func offer(w, kind){
  missions.board(w)
  return missions.new_offer(w, kind, true)
}

// over an offer's pad, still
local func at(w, pad){
  car_lib.place(w.car, {x: pad.x, y: pad.y + 3, z: pad.z}, 0)
}

t.group("jobs"){
  t.test("the board holds offers of every kind, near the car, which run out and are replaced"){
    local w = world.new({seed: 3, traffic: 0})
    local board = missions.board(w)
    assert(len(board.offers) == missions.OFFERS)
    assert(board.offers[0].kind == "delivery" and vec.distance(board.offers[0].pad, w.car.pos) < 400)
    for(let local o in values(board.offers)){
      assert(o.pay > 0 and o.left > 0 and missions.KINDS[o.kind] != null)
    }
    // all of them run out; new ones come up
    local kinds = {}
    local gone = 0
    for(local i = 0; i < 60 * 240; i = i + 15){
      missions.step(w, idle(), dt * 15)
      for(let local e in values(w.events)){
        if(e.kind == "offer_gone"){ gone = gone + 1 }
        if(e.kind == "offer"){ kinds[e.offer.kind] = true }
      }
    }
    assert(gone >= 6 and len(board.offers) == missions.OFFERS, gone)
    for(let local k in values(missions.ORDER)){
      assert(kinds[k], k)
    }
    world.destroy(w)
  }
  t.test("a delivery: landing on its offer takes it; landing at the far pad pays"){
    local w = world.new({seed: 3, traffic: 0})
    local o = offer(w, "delivery")
    at(w, o.pad)
    local seen = play(w, idle(), 10)
    local job = w.job
    assert(seen.accept != null and job.kind == "delivery" and job.to == o.to, seen)
    assert(missions.target(w).pad == o.to)
    // off the board, which goes on while it is under way
    for(let local other in values(w.board.offers)){
      assert(other != o)
    }
    at(w, job.to)
    seen = play(w, idle(), 10)
    assert(seen.job_done != null and w.jobs == 1 and w.credits > job.pay * 0.9, w.credits)
    assert(w.job == null)
    world.destroy(w)
  }
  t.test("arriving fast does not take it"){
    local w = world.new({seed: 3, traffic: 0})
    local o = offer(w, "delivery")
    at(w, o.pad)
    w.car.body.linear_velocity = {30, 0, 0}
    missions.step(w, idle(), dt)
    assert(w.job == null)
    world.destroy(w)
  }
  t.test("enough jobs move on to the next district, earnings kept"){
    local w = world.new({seed: 3, traffic: 0, level: 0})
    assert(w.level.name == "Outskirts")
    local level_up = null
    for(local k = 0; k < w.level.jobs and level_up == null; k = k + 1){
      local o = offer(w, "delivery")
      at(w, o.pad)
      play(w, idle(), 10)
      at(w, w.job.to)
      level_up = play(w, idle(), 10).level_up
    }
    assert(level_up != null and level_up.next == 1 and level_up.level.name == "Midtown")
    local credits = w.credits
    assert(credits > 0 and w.jobs == 3)
    world.destroy(w)
    local next = world.new({seed: 4, traffic: 0, level: 1, credits: credits, jobs: 3})
    assert(next.level.name == "Midtown" and next.credits == credits and next.jobs == 3)
    assert(next.level_jobs == 0 and next.job == null)
    world.destroy(next)
  }
  t.test("a wreck loses the job and sets the car down at the last pad"){
    local w = world.new({seed: 3, traffic: 0})
    local o = offer(w, "delivery")
    at(w, o.pad)
    play(w, idle(), 10)
    assert(w.job != null)
    car_lib.place(w.car, {x: 0, y: 300, z: 0}, 0)
    w.car.hull = 0
    local seen = play(w, idle(), 1)
    assert(w.state == "wrecked" and w.job == null and seen.job_failed.why == "wrecked")
    play(w, idle(), 60 * 4)
    assert(w.state == "play" and w.car.hull == 1)
    assert(vec.distance(w.car.pos, o.pad) < 3, w.car.pos)
    world.destroy(w)
  }
  t.test("a race: the rival waits out the count with the car, then flies to the pad"){
    local w = world.new({seed: 5, traffic: 0, level: 1})
    local o = offer(w, "race")
    at(w, o.pad)
    local seen = play(w, idle(), 10)
    local job = w.job
    assert(job.kind == "race" and job.phase == "count" and len(w.npcs) == 1)
    local held = w.car.pos
    local input = idle()
    input.throttle = 1
    play(w, input, 60 * 2)
    // held through the count (the magnet may settle it onto the pad)
    assert(math.abs(w.car.pos.x - held.x) < 1 and math.abs(w.car.pos.z - held.z) < 1)
    seen = play(w, idle(), 60 * 2)
    assert(seen.race_go != null and job.phase == "race")
    // the rival gets there (the car never left): a race lost
    local lost = null
    for(local k = 0; k < 60 and lost == null; k = k + 1){
      lost = play(w, idle(), 60).job_failed
    }
    assert(lost != null and lost.why == "the rival got there first")
    assert(len(w.npcs) == 0 and w.job == null)
    world.destroy(w)
  }
  t.test("a takedown: rams wear the target down until it falls"){
    local w = world.new({seed: 5, traffic: 0, level: 1})
    local o = offer(w, "takedown")
    // a fly-through: over its pad, not landed
    car_lib.place(w.car, {x: o.pad.x, y: o.pad.y + 12, z: o.pad.z}, 0)
    play(w, idle(), 2)
    local job = w.job
    assert(job.kind == "takedown" and job.target != null and job.hull == 1)
    // into it, hard, from beside it
    local hits = 0
    for(local k = 0; k < 8 and w.job != null; k = k + 1){
      local t = job.target.car
      local from = vec.add(t.pos, {x: 6, y: 0, z: 0})
      car_lib.place(w.car, from, 0)
      w.car.body.linear_velocity = {-30 + t.vel.x, t.vel.y, t.vel.z}
      local seen = play(w, idle(), 30)
      if(seen.target_hit != null){ hits = hits + 1 }
    }
    assert(hits >= 2 and w.job == null and job.target.wrecked and w.jobs == 1, hits)
    world.destroy(w)
  }
  t.test("a tail: too near for too long, and it spots you"){
    local w = world.new({seed: 5, traffic: 0, level: 1})
    local o = offer(w, "tail")
    car_lib.place(w.car, {x: o.pad.x, y: o.pad.y + 12, z: o.pad.z}, 0)
    play(w, idle(), 2)
    local job = w.job
    assert(job.kind == "tail")
    local failed = null
    for(local k = 0; k < 600 and failed == null; k = k + 1){
      // right behind it
      local t = job.target.car
      car_lib.place(w.car, vec.add(t.pos, {x: 0, y: 8, z: 0}), 0)
      failed = play(w, idle(), 1).job_failed
    }
    assert(failed != null and failed.why == "spotted", failed)
    world.destroy(w)
  }
}

t.group("routes"){
  t.test("the middles of the streets are clear in every band, in every district"){
    for(local li = 0; li < len(levels.list); li = li + 1){
      local w = world.new({seed: 5 + li, level: li, traffic: 0})
      local n = bot.nav(w)
      assert(len(n.bands) >= 4)
      for(let local y in values(n.bands)){
        for(local k = 0; k <= n.n; k = k + 1){
          local s = n.lines[k]
          local a = n.lines[0]
          local b = n.lines[n.n]
          assert(nav.clear(n, {x: a, y: y, z: s}, {x: b, y: y, z: s}), concat("x street ", string(k), " at ", string(y)))
          assert(nav.clear(n, {x: s, y: y, z: a}, {x: s, y: y, z: b}), concat("z street ", string(k), " at ", string(y)))
          // and no lane runs down the middle
          assert(not nav.lanes(n, {x: a, y: y, z: s}, {x: b, y: y, z: s}))
        }
      }
      world.destroy(w)
    }
  }
  t.test("join pads, every leg clear of the city"){
    local w = world.new({seed: 9, level: 3, traffic: 0})
    local n = bot.nav(w)
    local pads = w.city.pads
    for(local k = 0; k < 8; k = k + 1){
      local a = pads[(k * 7) % len(pads)]
      local b = pads[(k * 13 + 5) % len(pads)]
      local r = nav.route(n, {x: a.x, y: a.y + 1.5, z: a.z}, {x: b.x, y: b.y + 2.5, z: b.z})
      assert(r != null, concat(a.name, " to ", b.name))
      for(local i = 0; i + 1 < len(r); i = i + 1){
        local skip_a = 0
        local skip_b = 0
        if(i == 0){ skip_a = 3 }
        if(i == len(r) - 2){ skip_b = 3 }
        assert(nav.clear(n, r[i], r[i + 1], skip_a, skip_b), concat("leg ", string(i), " of ", a.name, " to ", b.name))
      }
    }
    world.destroy(w)
  }
}

t.group("autopilot"){
  t.test("flies its jobs through all of the traffic without a scratch"){
    local w = world.new({seed: 7, level: 2})
    local seen = {accept: 0, job_done: 0, hit: 0, scrape: 0}
    for(local i = 0; i < 60 * 75; i = i + 1){
      missions.step(w, missions.autopilot(w, dt, {prefer: {"delivery"}}), dt)
      for(let local e in values(w.events)){
        if(seen[e.kind] != null){
          seen[e.kind] = seen[e.kind] + 1
        }
      }
    }
    assert(seen.accept >= 1 and seen.job_done >= 1, seen.job_done)
    assert(seen.hit == 0, concat(string(seen.hit), " hits"))
    assert(w.pilot.failed == 0)
    world.destroy(w)
  }
  t.test("wins a race and takes a target down"){
    for(let local kind in values({"race", "takedown"})){
      local w = world.new({seed: 11, level: 1})
      missions.board(w)
      missions.new_offer(w, kind, true)
      local done = null
      for(local i = 0; i < 60 * 100 and done == null; i = i + 1){
        missions.step(w, missions.autopilot(w, dt, {prefer: {kind}}), dt)
        for(let local e in values(w.events)){
          if(e.kind == "job_done" or e.kind == "job_failed"){
            done = e
          }
        }
      }
      assert(done != null and done.kind == "job_done" and done.job.kind == kind, kind)
      world.destroy(w)
    }
  }
  t.test("follows a goal on the move, through it, without landing"){
    local w = world.new({seed: 3, level: 1, traffic: 0})
    local p = bot.new()
    local n = bot.nav(w)
    // a goal sliding down the middle of a street, in a band
    local y = n.bands[2]
    local z = n.lines[3]
    local near = 0
    local caught = null
    local frames = 60 * 30
    for(local i = 0; i < frames; i = i + 1){
      local goal = {x: n.lines[1] + i / 60 * 12, y: y, z: z}
      local input = bot.drive(w, w.car, p, goal, dt, {land: false})
      world.step(w, input, dt)
      assert(w.state == "play")
      if(vec.distance(w.car.pos, goal) < 25){
        near = near + 1
        if(caught == null){
          caught = i
        }
      }
    }
    // caught up within 20 s (the route depends on the city's shapes), and
    // near it most of the time after (arriving fast it may overshoot once:
    // the autopilot does not match a moving goal's speed)
    assert(caught != null and caught < 60 * 20, caught)
    assert(near > (frames - caught) * 0.6, near)
    world.destroy(w)
  }
}

// a world of one car and the traffic given, for the near misses alone
local func miss_world(cars){
  return {
    car: {
      pos: {x: -40, y: 0, z: 0}, vel: {x: 50, y: 0, z: 0},
      q: vec.quat_yaw(math.pi / 2), boost: 0, skimming: false,
    },
    traffic: {near: cars},
    events: {},
    credits: 0,
    near_miss: near_miss.new(),
  }
}

// a traffic car parked at the origin in an x lane, driving at 20 m/s
local func parked(id){
  return {id: id, lane: {axis: "x"}, pos: {x: 0, y: 0, z: 0}, vel: {x: 20, y: 0, z: 0}, wrecked: false}
}

// the car flies along x past the origin, side by side with a gap of air
local func fly_past(w, gap){
  // the traffic car's half width and the car's (turned along x)
  w.car.pos = {x: -40, y: 0, z: traffic.HALF_WIDTH + car_lib.HALF.x + gap}
  for(local i = 0; i < 100; i = i + 1){
    w.car.pos.x = w.car.pos.x + 50 * dt
    near_miss.step(w.near_miss, w, dt)
  }
}

local func kinds(w){
  local out = {}
  for(let local e in values(w.events)){
    append(out, e.kind)
  }
  return out
}

t.group("near misses"){
  t.test("the gap is the air between the hulls"){
    local w = miss_world({})
    w.car.pos = {x: 0, y: 0, z: traffic.HALF_WIDTH + car_lib.HALF.x + 1}
    assert(math.abs(near_miss.gap(w.car, parked(1)) - 1) < 0.001)
    w.car.pos = {x: 0, y: traffic.HALF_HEIGHT + car_lib.HALF.y + 2.5, z: 0}
    assert(math.abs(near_miss.gap(w.car, parked(1)) - 2.5) < 0.001)
  }
  t.test("a pass is graded by its closest gap"){
    local tiers = {{0.3, "RAZOR"}, {1.2, "TIGHT"}, {3, "CLOSE"}}
    for(let local c in values(tiers)){
      local w = miss_world({parked(1)})
      fly_past(w, c[0])
      assert(len(w.events) == 1 and w.events[0].kind == "near_miss", kinds(w))
      assert(w.events[0].tier == c[1], w.events[0].tier)
      assert(w.car.boost > 0)
    }
    // farther than the zone: nothing
    local w = miss_world({parked(1)})
    fly_past(w, 5)
    assert(len(w.events) == 0)
  }
  t.test("an oncoming car is worth more than one overtaken"){
    local w = miss_world({parked(1)})
    fly_past(w, 1)
    local overtaken = w.events[0].cash
    local car = parked(1)
    car.vel = {x: -20, y: 0, z: 0}
    // the same speed between the two, the other way
    w = miss_world({car})
    w.car.vel = {x: 10, y: 0, z: 0}
    fly_past(w, 1)
    assert(w.events[0].oncoming and w.events[0].cash > overtaken, w.events[0].cash)
  }
  t.test("misses chain, and the chain banks when its clock runs out"){
    local w = miss_world({parked(1)})
    fly_past(w, 1)
    fly_past(w, 0.3)
    assert(w.near_miss.chain == 2 and w.near_miss.mult == 1.25)
    local cash = w.near_miss.cash
    w.traffic.near = {}
    for(local i = 0; i < 4 * 60; i = i + 1){
      near_miss.step(w.near_miss, w, dt)
    }
    local last = w.events[len(w.events) - 1]
    assert(last.kind == "chain_banked" and last.chain == 2, kinds(w))
    assert(w.credits == to_int(math.floor(cash + 0.5)) and w.near_miss.chain == 0)
  }
  t.test("skimming holds the chain's clock"){
    local w = miss_world({parked(1)})
    fly_past(w, 1)
    w.traffic.near = {}
    w.car.skimming = true
    for(local i = 0; i < 6 * 60; i = i + 1){
      near_miss.step(w.near_miss, w, dt)
    }
    assert(w.near_miss.chain == 1 and w.credits == 0)
  }
  t.test("a crash loses the chain, and a touch is no miss"){
    local w = miss_world({parked(1)})
    fly_past(w, 1)
    near_miss.crash(w.near_miss, w)
    assert(w.events[len(w.events) - 1].kind == "chain_lost")
    assert(w.near_miss.chain == 0 and w.credits == 0)
    w = miss_world({parked(1)})
    w.car.pos = {x: 0, y: 0, z: traffic.HALF_WIDTH + car_lib.HALF.x + 0.2}
    near_miss.step(w.near_miss, w, dt)
    near_miss.touch(w.near_miss, w.traffic.near[0])
    w.car.pos.z = 20
    near_miss.step(w.near_miss, w, dt)
    assert(len(w.events) == 0, kinds(w))
  }
  t.test("in the world: the chain is banked before the district changes"){
    local w = world.new({seed: 3, traffic: 0, level: 0})
    w.level_jobs = w.level.jobs - 1
    local o = offer(w, "delivery")
    at(w, o.pad)
    play(w, idle(), 10)
    w.near_miss.chain = 3
    w.near_miss.cash = 40
    w.near_miss.clock = 100
    at(w, w.job.to)
    local seen = {}
    for(local i = 0; i < 10 and seen.level_up == null; i = i + 1){
      missions.step(w, idle(), dt)
      for(let local e in values(w.events)){
        seen[e.kind] = e
      }
    }
    assert(seen.level_up != null and seen.chain_banked != null, kinds(w))
    assert(seen.chain_banked.cash == 40 and w.near_miss.chain == 0)
    world.destroy(w)
  }
}

// a Midtown with no traffic (it has slots)
local func slot_world(seed){
  local w = world.new({seed: seed, traffic: 0, level: 1})
  return w
}

local func along_slot(s, dir){
  if(s.axis == "x"){
    return {x: dir, y: 0, z: 0}
  }
  return {x: 0, y: 0, z: dir}
}

// the point at along a and across c, height y, in a slot's frame
local func slot_point(s, a, c, y){
  if(s.axis == "x"){
    return {x: a, y: y, z: c}
  }
  return {x: c, y: y, z: a}
}

local func count_events(w, input, frames){
  local seen = {hits: 0, threads: 0}
  for(local i = 0; i < frames; i = i + 1){
    world.step(w, input, dt)
    for(let local e in values(w.events)){
      if(e.kind == "hit"){
        seen.hits = seen.hits + 1
      } else if(e.kind == "near_miss" and e.tier == "THREAD"){
        seen.threads = seen.threads + 1
      }
    }
  }
  return seen
}

t.group("slots"){
  t.test("every district has lines of them: 2 m wide, walls on both sides, clear inside"){
    for(local li = 0; li < len(levels.list); li = li + 1){
      local c = city.generate(5 + li, levels.get(li))
      assert(len(c.slots) > 0, li)
      for(let local s in values(c.slots)){
        local func boxes(c0, c1){
          local p = slot_point(s, s.lo + 1, c0, 2)
          local q = slot_point(s, s.hi - 1, c1, s.top - 1)
          return len(city.query(c, math.min(p.x, q.x), p.y, math.min(p.z, q.z), math.max(p.x, q.x), q.y, math.max(p.z, q.z)))
        }
        assert(boxes(s.at - 0.95, s.at + 0.95) == 0, concat("inside a slot of level ", string(li)))
        assert(boxes(s.at - 1.2, s.at - 1.1) > 0 and boxes(s.at + 1.1, s.at + 1.2) > 0)
        assert(s.hi - s.lo >= 15 and s.top >= 40, s.top)
      }
    }
  }
  t.test("a line starts and ends in a funnel (unless at the city's edge): wide, clear, its walls not magnetic"){
    for(local li = 0; li < len(levels.list); li = li + 1){
      local c = city.generate(5 + li, levels.get(li))
      for(let local f in values(c.funnels)){
        // on a line of slots, beside its first or last
        local next = false
        for(let local s in values(c.slots)){
          if(s.at == f.line and s.axis == f.axis and (math.abs(s.a0 - f.a1) < c.pitch or math.abs(f.a0 - s.a1) < c.pitch)){
            next = true
          }
        }
        assert(next, concat("a funnel off its line in level ", string(li)))
        local half = city.FUNNEL / 2 - 0.1
        local p = slot_point(f, f.a0 + 1, f.at - half, 2)
        local q = slot_point(f, f.a1 - 1, f.at + half, f.top - 1)
        assert(len(city.query(c, math.min(p.x, q.x), p.y, math.min(p.z, q.z), math.max(p.x, q.x), q.y, math.max(p.z, q.z))) == 0)
      }
      assert(len(c.funnels) > 0, li)
    }
    local w = slot_world(6)
    local f = w.city.funnels[0]
    for(let local b in values(city.query(w.city, f.a0, 5, f.a0, f.a1, 6, f.a1))){
      if(b.kind == city.WALL and b.y0 == 0){
        assert(b.slick or not b.slot)
      }
    }
    world.destroy(w)
  }
  t.test("flown level down a funnel's middle, the magnet takes the car into the line"){
    for(let local speed in values({50, 70})){
      local w = slot_world(6)
      local s = w.city.slots[0]
      local entry = null
      for(let local f in values(w.city.funnels)){
        if(f.line == s.at and f.axis == s.axis and (entry == null or f.a0 < entry.a0)){
          entry = f
        }
      }
      local pos = slot_point(s, entry.a0 - 20, entry.at, 40)
      car_lib.place(w.car, pos, vec.yaw_of(along_slot(s, 1)))
      w.car.cooldown = 0
      w.car.body:set_position_rotation_and_velocity(pos, w.car.q, vec.scale(along_slot(s, 1), speed), {0, 0, 0})
      local input = idle()
      input.throttle = 0.6
      local seen = count_events(w, input, 60 * 4)
      assert(seen.hits == 0 and seen.threads >= 1, concat("at ", string(speed)))
      world.destroy(w)
    }
  }
  t.test("level, with no magnet, the car does not fit"){
    local w = slot_world(6)
    local s = w.city.slots[0]
    local pos = slot_point(s, s.a0 - 15, s.at, 40)
    car_lib.place(w.car, pos, vec.yaw_of(along_slot(s, 1)))
    w.car.magnet = false
    w.car.body:set_position_rotation_and_velocity(pos, w.car.q, vec.scale(along_slot(s, 1), 40), {0, 0, 0})
    local input = idle()
    input.throttle = 0.6
    local seen = count_events(w, input, 90)
    assert(seen.hits > 0 and seen.threads == 0)
    world.destroy(w)
  }
  t.test("flying in level beside a lead wall, the magnet takes the car through"){
    for(let local speed in values({30, 70})){
      for(let local dir in values({1, -1})){
        local w = slot_world(6)
        local s = w.city.slots[0]
        // beside A's wall coming one way, B's the other, 2.5 m out
        local start = s.a0 - 15
        local across = s.at + 2.5
        if(dir < 0){
          start = s.a1 + 15
          across = s.at - 2.5
        }
        local pos = slot_point(s, start, across, 40)
        car_lib.place(w.car, pos, vec.yaw_of(along_slot(s, dir)))
        w.car.cooldown = 0
        w.car.body:set_position_rotation_and_velocity(pos, w.car.q, vec.scale(along_slot(s, dir), speed), {0, 0, 0})
        local input = idle()
        input.throttle = 0.6
        local seen = count_events(w, input, 120)
        assert(seen.hits == 0 and seen.threads == 1, concat("speed ", string(speed), " dir ", string(dir)))
        world.destroy(w)
      }
    }
  }
  t.test("hands off on a wall, the car runs a line of slots, across the streets"){
    local w = slot_world(6)
    local s = w.city.slots[0]
    local fwd = along_slot(s, 1)
    local n = slot_point(s, 0, 1, 0)
    local pos = slot_point(s, s.a0 + 2, s.at, 40)
    car_lib.place(w.car, pos, 0)
    w.car.q = vec.quat_look(fwd, n)
    w.car.cooldown = 0
    w.car.body:set_position_rotation_and_velocity(pos, w.car.q, vec.scale(fwd, 20), {0, 0, 0})
    local input = idle()
    input.throttle = 1
    local seen = count_events(w, input, 60 * 5)
    assert(seen.hits == 0 and seen.threads >= 3, seen.threads)
    assert(w.car.speed > 60, w.car.speed)
    // on to the end of the line and out through its funnel, untouched
    local exit = null
    for(let local f in values(w.city.funnels)){
      if(f.line == s.at and f.axis == s.axis and (exit == null or f.a0 > exit.a0)){
        exit = f
      }
    }
    assert(exit != null)
    local out = false
    for(local i = 0; i < 60 * 12 and not out; i = i + 1){
      seen = count_events(w, input, 1)
      assert(seen.hits == 0, i)
      local along = w.car.pos.x
      if(s.axis == "z"){
        along = w.car.pos.z
      }
      out = along > exit.a1 + 10
    }
    assert(out, w.car.pos)
    world.destroy(w)
  }
}

t.group("flyers"){
  local flyers = require("game/flyers")
  t.test("their paths, pulled tight, keep clear of the city; a cruiser's of every lane"){
    local reach = flyers.TIGHTEN
    local each = flyers.TIGHTEN_EACH
    flyers.TIGHTEN = 1e9
    flyers.TIGHTEN_EACH = 1000
    local dashers = 0
    for(local li = 0; li < len(levels.list); li = li + 1){
      local w = world.new({seed: 7 + li, level: li, traffic: 0})
      local n = bot.nav(w)
      flyers.new(w, 25)
      // far off (sliding), on and pulled tight a few times
      car_lib.place(w.car, {x: 0, y: -100, z: 0}, 0)
      for(local i = 0; i < 60 * 8; i = i + 1){
        flyers.step(w, dt)
      }
      for(let local f in values(w.flyers.list)){
        if(f.style == "dash"){
          dashers = dashers + 1
        }
        for(local k = f.k; k + 1 < len(f.path); k = k + 1){
          local a = f.path[k]
          local b = f.path[k + 1]
          local where = concat("level ", string(li), " ", f.style, " ", string(f.id), " leg ", string(k))
          assert(nav.clear(n, a, b), where)
          if(f.style == "cruise"){
            assert(not nav.crosses(n, a, b), concat("a lane: ", where))
          }
        }
      }
      world.destroy(w)
    }
    flyers.TIGHTEN = reach
    flyers.TIGHTEN_EACH = each
    assert(dashers > 10, dashers)
  }
  t.test("near the car they are cars of the world, far off they slide"){
    local w = world.new({seed: 3, level: 1, flyers: 60})
    play(w, idle(), 60 * 5)
    local near = 0
    for(let local f in values(w.flyers.list)){
      local d = vec.distance(f.pos, w.car.pos)
      if(f.npc != null){
        near = near + 1
        assert(d < flyers.FAR + 5, d)
      } else {
        assert(d > flyers.NEAR - 5, d)
      }
    }
    assert(near > 0)
    world.destroy(w)
  }
  t.test("a minute of many of them around the autopilot: nothing hits anything"){
    local w = world.new({seed: 62, level: 1, flyers: 80})
    local hits = 0
    for(local i = 0; i < 60 * 60; i = i + 1){
      missions.step(w, missions.autopilot(w, dt, {prefer: {"delivery"}}), dt)
      for(let local e in values(w.events)){
        if(e.kind == "hit"){ hits = hits + 1 }
      }
      for(let local npc in values(w.npcs)){
        for(let local e in values(npc.car.events)){
          if(e.kind == "hit"){ hits = hits + 1 }
        }
      }
    }
    assert(hits == 0, hits)
    world.destroy(w)
  }
}
