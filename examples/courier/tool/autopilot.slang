// tool/autopilot: the autopilot through its jobs in each district, with
// all of the traffic, and what came of it: jobs done and failed by kind
// (and deliveries late), hits (and how hard: rams in a takedown count),
// wrecks, routes planned and not found, the hull left, the average
// speed, and what held it back for how long.
//     slang run tool/autopilot.slang [seconds per district] [seed] [level]
// AUTOPILOT_LOG=1 prints each hit; AGGRESSION=0..1 flies it as a rival in
// a hurry; JOB=kind takes only jobs of that kind; FLYERS=n sets how many
// cars fly free; DECEL=, CORNER= try other settings.
local world = require("game/world")
local bot = require("game/bot")
local missions = require("game/missions")
local levels = require("game/levels")
local time = require("slang/time")
local math = require("slang/math")
local str = require("slang/string")
local os = require("slang/os")

local a = args()
local seconds = 90
local seed = 11
local only = null
if(len(a) > 0){ seconds = str.to_number(a[0]) }
if(len(a) > 1){ seed = to_int(str.to_number(a[1])) }
if(len(a) > 2){ only = to_int(str.to_number(a[2])) }

local dt = 1 / 60
if(os.getenv("DECEL") != null){ bot.DECEL = str.to_number(os.getenv("DECEL")) }
if(os.getenv("CORNER") != null){ bot.CORNER = str.to_number(os.getenv("CORNER")) }
local aggression = str.to_number(os.getenv("AGGRESSION") or "0")
local only_kind = os.getenv("JOB")
local prefer = null
if(only_kind != null){
  prefer = {only_kind}
}
for(local li = 0; li < len(levels.list); li = li + 1){
  if(only != null and li != only){
    continue
  }
  local wo = {seed: seed + li, level: li}
  if(os.getenv("FLYERS") != null){
    wo.flyers = to_int(str.to_number(os.getenv("FLYERS")))
  }
  local w = world.new(wo)
  w.pilot = bot.new({aggression: aggression})
  missions.board(w)
  if(only_kind != null){
    missions.new_offer(w, only_kind, true)
  }
  local done = {}
  local failed = {}
  local stats = {hits: 0, hard: 0, worst: 0, wrecks: 0, traffic: 0, cars: 0, speed: 0, late: 0}
  local started = time.clock()
  local frames = to_int(seconds * 60)
  for(local i = 0; i < frames; i = i + 1){
    missions.step(w, missions.autopilot(w, dt, {prefer: prefer}), dt)
    stats.speed = stats.speed + w.car.speed
    for(let local e in values(w.events)){
      if(e.kind == "hit"){
        stats.hits = stats.hits + 1
        stats.worst = math.max(stats.worst, e.impact)
        if(e.impact > 12){ stats.hard = stats.hard + 1 }
        if(e.traffic){ stats.traffic = stats.traffic + 1 }
        if(e.car != null){ stats.cars = stats.cars + 1 }
        if(os.getenv("AUTOPILOT_LOG") != null){
          print("  hit at ", to_int(i / 60), "s ", to_int(e.impact), " m/s ", if(e.traffic){ "traffic" } else if(e.car != null){ "car" } else { "city" },
            " at ", to_int(e.pos.x), ",", to_int(e.pos.y), ",", to_int(e.pos.z), "\n")
        }
      } else if(e.kind == "wreck"){
        stats.wrecks = stats.wrecks + 1
      } else if(e.kind == "job_done"){
        done[e.job.kind] = (done[e.job.kind] or 0) + 1
        if(e.job.late){ stats.late = stats.late + 1 }
      } else if(e.kind == "job_failed"){
        failed[e.job.kind] = (failed[e.job.kind] or 0) + 1
        if(os.getenv("AUTOPILOT_LOG") != null){
          print("  ", e.job.kind, " failed at ", to_int(i / 60), "s: ", e.why, "\n")
        }
      }
    }
  }
  local p = w.pilot or {plans: 0, failed: 0}
  local jobs = ""
  for(let local k in values(missions.ORDER)){
    if(done[k] != null or failed[k] != null){
      jobs = concat(jobs, k, " ", string(done[k] or 0), "/", string((done[k] or 0) + (failed[k] or 0)), ", ")
    }
  }
  print(levels.get(li).name, ": ", jobs, stats.late, " late, ",
    stats.hits, " hits (", stats.traffic, " traffic, ", stats.cars, " cars, ", stats.hard, " hard, worst ", to_int(stats.worst), " m/s), ",
    stats.wrecks, " wrecks, hull ", to_int(w.car.hull * 100), "%, ", p.plans, " plans (", p.failed, " failed), ",
    to_int(frames * 1000 / math.max(1, time.clock() - started)), " steps/s, avg ", to_int(stats.speed / frames), " m/s, ",
    w.near_miss.misses, " near misses\n")
  local tt = ""
  for(let local e in entries(p.time or {})){ tt = concat(tt, e[0], " ", to_int(e[1]), "s  ") }
  print("   ", tt, "\n")
  world.destroy(w)
}
