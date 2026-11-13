// game/bot: a driver that follows the trail. It steers at a point of
// the trail ahead of the truck (farther ahead the faster it goes), slows
// for the bends, the fords and the drops that it sees coming, takes low
// range for the climbs, locks the differentials when a wheel spins, and
// backs up and tries again when it is stuck. The tests drive with it,
// and so does the title screen.
//
//   local driver = bot.new()
//   local input = driver:drive(world, dt)     // for world.step
//   driver.index, driver.done, driver.recoveries
local math = require("slang/math")
local vec = require("game/vec")
local terrain = require("game/terrain")
local route = require("game/route")
local car_lib = require("game/car")

local m = {}

local Bot = {}
local meta = {__index: Bot, __type: "Bot"}

// new(options?: {pace?: float}) -> Bot
// pace: how fast it likes to go, as a factor (1 by default)
func m.new(options){
  options = options or {}
  return {
    pace: options.pace or 1,
    index: 0,          // the trail's point nearest the truck
    done: false,       // it has reached the trail's end
    low: true,
    locked: 0,         // s the differentials stay locked
    stuck: 0,          // s without getting anywhere
    backing: 0,        // s it still backs up
    recoveries: 0,     // how often it had to back up
    target_speed: 0,
    @meta: meta,
  }
}

// the point of the trail nearest the truck, near where it was last (the
// trail comes close to itself in the switchbacks: no jumping across)
local func locate(b, trail, pos){
  local count = len(trail.points)
  local best = b.index
  local least = 1.0e12
  for(local i = math.max(0, b.index - 6); i < math.min(count, b.index + 40); i = i + 1){
    local p = trail.points[i]
    local dx = p.x - pos.x
    local dz = p.z - pos.z
    local d = dx * dx + dz * dz
    if(d < least){
      least = d
      best = i
    }
  }
  b.index = best
  return math.sqrt(least)
}

// drive(b, world, dt) -> car.Input
// What the driver does in the next moment.
func Bot.drive(b, world, dt){
  local car = world.car
  local trail = world.trail
  local points = trail.points
  local count = len(points)
  local off = locate(b, trail, car.pos)
  b.off = off
  if(b.index >= count - 4){
    b.done = true
    return {back: if(car.speed > 0.3){ 1 } else { 0 }, low: true}
  }
  local speed = car.speed
  local step = route.STEP

  // what is coming: the tightest bend, the steepest drop and climb, water
  local bend = 0
  local drop = 0
  local climb = 0
  local wet = false
  local slow = 100
  local ahead = to_int((14 + math.abs(speed) * 2.2) / step)
  for(local i = b.index; i < math.min(count - 3, b.index + ahead); i = i + 2){
    local a = points[i]
    local c = points[i + 2]
    local d = points[math.min(count - 1, i + 4)]
    local h1 = math.atan2(c.x - a.x, c.z - a.z)
    local h2 = math.atan2(d.x - c.x, d.z - c.z)
    local turn = h2 - h1
    if(turn > math.pi){
      turn = turn - 2 * math.pi
    } else if(turn < -math.pi){
      turn = turn + 2 * math.pi
    }
    bend = math.max(bend, math.abs(turn) / (2 * step))
    local grade = (c.y - a.y) / (2 * step)
    drop = math.min(drop, grade)
    climb = math.max(climb, grade)
    if(i < b.index + 8 and terrain.water_at(world.land, c.x, c.z) > 0.1){
      wet = true
    }
    // an obstacle of the trail: at its pace
    if(i < b.index + 9 and c.pace != null){
      slow = math.min(slow, c.pace)
    }
  }
  local target = math.sqrt(1.7 / math.max(bend, 0.004))
  target = vec.clamp(target, 2.2, 6.8) * b.pace
  if(drop < -0.12){
    target = math.min(target, 3.8)
  }
  if(wet){
    target = math.min(target, 2.8)
  }
  target = math.min(target, slow * b.pace)
  b.target_speed = target

  // steering: at a point of the trail ahead, by the arc that leads there
  local look = to_int(vec.clamp(4.5 + math.abs(speed) * 0.85, 5, 13) / step)
  local goal = points[math.min(count - 1, b.index + look)]
  local to = vec.unrotate(car.q, {x: goal.x - car.pos.x, y: 0, z: goal.z - car.pos.z})
  local d2 = to.x * to.x + to.z * to.z
  local curve = 2 * to.x / math.max(d2, 1)
  local angle = math.atan(car_lib.HALF_WHEELBASE * 2 * curve)
  local steer = -angle / 0.5
  // and back toward the line when it has strayed to a side of it
  local here = points[b.index]
  local yaw = route.direction(trail, b.index)
  local left = (car.pos.x - here.x) * math.cos(yaw) - (car.pos.z - here.z) * math.sin(yaw)
  steer = vec.clamp(steer + vec.clamp(left * 0.22, -0.35, 0.35), -1, 1)
  // no faster than the arc it steers allows, and slowly when off the line
  target = math.min(target, math.max(2.2, math.sqrt(1.7 / math.max(math.abs(curve), 0.004))))
  if(math.abs(left) > 1.1){
    target = math.min(target, 3.0)
  }
  b.target_speed = target

  // low range for the climbs and the slow going; changed at a crawl only
  local want_low = climb > 0.13 or target < 4.2 or drop < -0.14
  if(want_low != b.low and math.abs(speed) < 4.5){
    b.low = want_low
  }

  // stuck: full throttle and going nowhere. First the locks, then back
  // up a little and come again
  local input = {steer: steer, low: b.low}
  if(b.backing > 0){
    b.backing = b.backing - dt
    input.back = 0.7
    input.steer = -steer * 0.6
    input.lock_front = true
    input.lock_rear = true
    return input
  }
  local error = target - speed
  local throttle = vec.clamp(0.22 + error * 0.45 + math.max(climb, 0) * 2.2, 0, 1)
  local brake = 0
  if(error < -0.9){
    throttle = 0
    brake = vec.clamp(-error * 0.35, 0, 1)
  }
  if(throttle > 0.4 and math.abs(speed) < 0.35){
    b.stuck = b.stuck + dt
  } else {
    b.stuck = math.max(0, b.stuck - dt * 2)
  }
  if(b.stuck > 1.5){
    b.locked = 8
  }
  if(b.stuck > 4.5){
    b.stuck = 0
    b.backing = 1.6
    b.recoveries = b.recoveries + 1
  }
  // a spinning wheel: lock up for a while, and ease off: wheels that
  // spin do not hold the truck on the track
  local spin = 0
  for(local i = 0; i < 4; i = i + 1){
    spin = math.max(spin, math.abs(car.wheels[i].slip_ratio))
  }
  if(spin > 0.6 and math.abs(speed) < 4){
    b.locked = math.max(b.locked, 4)
  }
  if(spin > 0.35){
    throttle = throttle * vec.clamp(1.25 - spin * 1.5, 0.3, 1)
  }
  if(b.locked > 0){
    b.locked = b.locked - dt
    // (not through a tight bend: locked axles push straight on)
    if(bend < 0.09){
      input.lock_front = true
    }
    input.lock_rear = true
  }
  input.forward = throttle
  input.back = brake
  return input
}

return m
