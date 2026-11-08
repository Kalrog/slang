// game/bot: an autopilot. It flies the car toward the job's pad: the yaw
// from the heading error, the pitch from the climb it wants (never
// steeper than it can recover from), a bank into turns; its feelers
// make it climb or turn away from what is ahead, it slows to arrive and
// boosts on a clear straight. The tests and the attract mode use it.
local math = require("slang/math")
local vec = require("game/vec")
local car_lib = require("game/car")
local world = require("game/world")

local m = {}

// how far along dir the city is clear, up to length
local func feeler(w, car, dir, length){
  local hit = w.phys.jw:cast_ray(vec.add_scaled(car.pos, dir, 3), vec.scale(dir, length))
  if(hit == null){
    return length
  }
  local what = w.phys.by_id[hit.body.id]
  if(what != null and what.traffic != null){
    return length
  }
  return hit.fraction * length
}

local func flat(v){
  return vec.normalize({x: v.x, y: 0, z: v.z})
}

// input(w, dt) -> the input for this frame
func m.input(w, dt){
  local car = w.car
  local axes = car_lib.axes(car)
  local target = world.target(w)
  local input = {pitch: 0, roll: 0, yaw: 0, throttle: 0, brake: 0, boost: false, magnet: false}
  if(target == null or w.state != "play"){
    return input
  }
  // aimed a little over the pad, so it comes down onto it and not into
  // the side of the roof
  local goal = {x: target.x, y: target.y + 6, z: target.z}
  local to = vec.sub(goal, car.pos)
  local dist = vec.length(to)
  local dir = vec.normalize(to)
  // the feelers: ahead, and to each side and up
  local look = vec.clamp(car.speed * 2.5, 40, 120)
  local f = axes.forward
  local ahead = feeler(w, car, f, look)
  local climb = 0
  local turn = 0
  if(ahead < look){
    local left = feeler(w, car, vec.normalize(vec.add_scaled(f, axes.right, -0.6)), look)
    local right = feeler(w, car, vec.normalize(vec.add_scaled(f, axes.right, 0.6)), look)
    local up = feeler(w, car, vec.normalize(vec.add_scaled(f, {x: 0, y: 1, z: 0}, 0.7)), look)
    local urgency = 1 - ahead / look
    if(up >= left and up >= right){
      climb = urgency
    } else if(left > right){
      turn = -urgency
    } else {
      turn = urgency
    }
  }
  // the heading: how far the goal is to the right of the nose
  local ff = flat(f)
  local df = flat(dir)
  // (cross(ff, df).y > 0 means the goal is toward +x, the car's left)
  local yaw_error = -math.atan2(vec.cross(ff, df).y, vec.dot(ff, df))
  input.yaw = vec.clamp(yaw_error * 1.5 - turn * 2, -1, 1)
  input.roll = vec.clamp(input.yaw * 0.6, -1, 1)
  // the climb: the pitch it wants, within what it can hold
  local want = math.asin(vec.clamp(dir.y, -1, 1))
  want = vec.clamp(want + climb * 1.2, -0.7, 1.0)
  if(car.pos.y < 25){
    want = math.max(want, 0.2)
  }
  // not into the roof it stands on
  local below = feeler(w, car, vec.scale(axes.up, -1), 12)
  if(below < 12 and dist > 30){
    want = math.max(want, 0.15 + (12 - below) * 0.05)
  }
  // pinned against something: back off for a moment
  if(car.speed < 1.5 and dist > 8){
    car.bot_stuck = (car.bot_stuck or 0) + dt
  } else {
    car.bot_stuck = 0
  }
  if(car.bot_stuck > 1 and car.bot_stuck < 2.5){
    input.brake = 1
    input.pitch = -0.5
    return input
  }
  local have = math.asin(vec.clamp(f.y, -1, 1))
  input.pitch = vec.clamp(-(want - have) * 3, -1, 1)
  // the speed: full ahead, slowing to the pad's speed on arrival
  local want_speed = math.min(car_lib.TOP_SPEED, 8 + dist * 0.5)
  if(ahead < 30){
    want_speed = math.min(want_speed, 18)
  }
  if(car.speed < want_speed){
    input.throttle = vec.clamp((want_speed - car.speed) / 8, 0.3, 1)
  } else if(car.speed > want_speed + 3){
    input.brake = 1
  }
  if(dist < 12){
    // the last meters: creep onto the pad
    input.throttle = vec.clamp((6 - car.speed) / 6, 0, 0.5)
    input.brake = 0
    if(car.speed > 8){
      input.brake = 1
    }
  }
  input.boost = dist > 250 and math.abs(yaw_error) < 0.15 and ahead >= look and car.boost > 0.3
  return input
}

return m
