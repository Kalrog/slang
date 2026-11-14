// tool/drive: the bot drives the trail of a seed from end to end, without
// a window, and reports how it went: the time to each checkpoint, where
// it got stuck, how far it leaned.
//
//   cd examples/switchback && ../../bin/slang run tool/drive.slang [seed] [seconds] [from] [trail]
//
// seconds: how long it may take (2400); from: where along the trail it
// starts, in meters (0); trail: which of the valley's trails (0, the
// Summit Run; the others from where they leave the trail they branch
// off).
local math = require("slang/math")
local str = require("slang/string")
local time = require("slang/time")
local world = require("game/world")
local bot = require("game/bot")
local terrain = require("game/terrain")

local argv = args()
local seed = if(len(argv) > 0){ to_int(str.to_number(argv[0])) } else { 7 }
local limit = if(len(argv) > 1){ str.to_number(argv[1]) } else { 2400 }
local from = if(len(argv) > 2){ str.to_number(argv[2]) } else { 0 }
local which = if(len(argv) > 3){ to_int(str.to_number(argv[3])) } else { 0 }

local func fmt(v, digits){
  return str.format(concat("%.", string(digits or 1), "f"), v)
}

local func vec_clamp(v){
  return math.max(-1, math.min(1, v))
}

local started = time.clock()
local w = world.new({seed: seed})
if(which > 0){
  // (the bot follows the world's trail: this one, from its start)
  w.trail = w.trails[which]
  world.recover(w, 4)
}
print("world of seed ", seed, " in ", to_int(time.clock() - started), " ms; ", w.trail.name, " ", to_int(w.trail.length), " m\n")
local driver = bot.new()
if(from > 0){
  // from a place along the trail
  driver.index = to_int(from / 2)
  world.recover(w, driver.index)
}
local next = 1
local lean = 1
local last_report = 0
local rolls = 0
local sim_started = time.clock()
// the last moments, for when it goes wrong
local recent = {}
local func note(input){
  local car = w.car
  local p = w.trail.points[driver.index]
  local yaw = require("game/route").direction(w.trail, driver.index)
  local lx = math.cos(yaw)
  local lz = -math.sin(yaw)
  local across = {}
  for(let local off in values({-5, -2.5, 0, 2.5, 5})){
    append(across, fmt(terrain.height_at(w.land, p.x + lx * off, p.z + lz * off) - p.y, 1))
  }
  append(recent, concat("    t=", fmt(w.time, 2), " at ", string(driver.index * 2), " m v ", fmt(car.speed), " (wants ", fmt(driver.target_speed),
    ") lean ", fmt(math.acos(vec_clamp(car.up.y)) * 180 / math.pi, 0), " steer ", fmt(input.steer or 0, 2), " thr ", fmt(input.forward or 0, 2), " brk ",
    fmt(input.back or 0, 2), " off ", fmt(driver.off), " on ", car.wheels[0].surface.name, "/", car.wheels[1].surface.name, "/", car.wheels[2].surface.name,
    "/", car.wheels[3].surface.name, " land across the trail: ", str.join(across, " "), "\n"))
  if(len(recent) > 14){
    remove(recent, 0)
  }
}
for(w.time < limit and not driver.done){
  local input = driver:drive(w, world.STEP)
  world.step(w, input, world.STEP)
  local car = w.car
  if(w.steps % 30 == 0){
    note(input)
  }
  lean = math.min(lean, car.up.y)
  if(w.trail.checkpoints != null and next < len(w.trail.checkpoints) and driver.index >= w.trail.checkpoints[next].index - 3){
    local c = w.trail.checkpoints[next]
    print("  ", c.name, " (", to_int(c.at), " m) at ", fmt(w.time), " s; most lean so far ", fmt(math.acos(lean) * 180 / math.pi, 0),
      " deg; backed up ", driver.recoveries, " times\n")
    next = next + 1
  }
  if(car.up.y < 0.2){
    print("  rolled over at ", fmt(w.time), " s, ", to_int(driver.index * 2), " m along (", fmt(car.pos.x, 0), " ", fmt(car.pos.z, 0), "); before that:\n")
    if(rolls < 2){
      for(let local line in values(recent)){
        print(line)
      }
    }
    rolls = rolls + 1
    if(rolls > 12){
      break
    }
    // back on the trail, a little further on than where it left it
    world.recover(w, math.min(len(w.trail.points) - 1, driver.index + 3))
    driver.index = math.min(len(w.trail.points) - 1, driver.index + 3)
  }
  if(w.time - last_report > 30){
    last_report = w.time
    local d = car.drive
    print("    t=", fmt(w.time, 0), " at ", to_int(driver.index * 2), " m, ", fmt(car.speed * 3.6), " km/h (wants ", fmt(driver.target_speed * 3.6),
      "), gear ", d.gear, if(d.low){ "L" } else { "H" }, " rpm ", to_int(d.rpm), ", off the line ", fmt(driver.off), " m, on ", car.wheels[0].surface.name,
      ", height ", fmt(car.pos.y, 0), "\n")
  }
}
local wall = time.clock() - sim_started
print(if(driver.done){ "arrived" } else { "did not arrive" }, ": ", fmt(w.time), " s of driving for ", to_int(driver.index * 2), " m (",
  fmt(driver.index * 2 / math.max(1, w.time) * 3.6), " km/h on average), backed up ", driver.recoveries, " times, rolled over ", rolls, " times; ",
  fmt(wall / 1000), " s to compute, ", fmt(wall / math.max(1, w.steps) * 1000, 0), " us a step\n")
world.destroy(w)
