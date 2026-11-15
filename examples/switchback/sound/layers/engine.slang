// sound/layers/engine: the truck's engine (sound/engine) in the game: what
// the drivetrain does becomes the engine's speed, fuel and boost; the
// tailpipe, the engine bay and the intake (behind the grille, or up the
// snorkel) are placed for the listener; and the engine is started and
// dies as the game says (watcher.running): the starter turns it, it
// catches and flares, a breakdown lets it run down.
local math = require("slang/math")
local drivetrain = require("game/drivetrain")
local listener = require("sound/listener")

local m = {}

m.params = {
  // the crank, the fuel as a share of the most at this speed, the boost
  {"rpm", 0, 0.03},
  {"fuel", 0, 0.04},
  {"boost", 0, 0.06},
  {"starter", 0, 0},
  // how worn the engine is (the truck's damage), and the intake's last
  // pipe, m
  {"damage", 0, 0.3},
  {"snorkel", 0.4, 0},
  // the gains of the tailpipe, the engine bay and the intake's mouth
  {"exhaust_left", 0, 0.03},
  {"exhaust_right", 0, 0.03},
  {"bay_left", 0, 0.03},
  {"bay_right", 0, 0.03},
  {"intake_left", 0, 0.03},
  {"intake_right", 0, 0.03},
}

// where they are on the truck (its frame: x left, y up, z forward)
local TAILPIPE = {x: -0.5, y: 0.15, z: -2.26}
local BAY = {x: 0, y: 0.45, z: 1.5}
local GRILLE = {x: 0.25, y: 0.45, z: 2.1}
local SNORKEL = {x: -0.86, y: 1.6, z: 0.75}

// how the starting goes, s: the starter alone, then with the first
// fuel, then the engine running up
local CRANK = 0.5
local FIRE = 0.3
local CATCH = 0.7
// and how long a dying engine takes to stand
local DIE = 0.9

// ------------------------------------------------------------ the game's side

// watcher() -> the layer's state in the main isolate
// [running]: whether the engine should run; set by the director
func m.watcher(){
  return {running: false, phase: "off", t: 0, rpm: 0}
}

// watch(w, s, set, send): a frame (s: sound/director's Frame)
func m.watch(w, s, set, send){
  local d = s.car.drive
  local spec = d.spec
  // the engine as the drivetrain has it
  local rpm = d.rpm
  local full = drivetrain.full_torque(spec, rpm)
  local drag = drivetrain.drag_torque(spec, rpm)
  local fuel = math.min(math.max((d.torque + drag) / (full + drag), 0), 1)
  local boost = d.boost
  local starter = 0
  // the starting and the dying
  w.t = w.t + s.dt
  if(w.running and (w.phase == "off" or w.phase == "dying")){
    w.phase = "starting"
    w.t = 0
  } else if(not w.running and (w.phase == "running" or w.phase == "starting")){
    w.phase = "dying"
    w.t = 0
  }
  if(w.phase == "off"){
    rpm = 0
    fuel = 0
    boost = 0
  } else if(w.phase == "starting"){
    boost = 0
    if(w.t < CRANK + FIRE){
      // the starter turns it, slowing at each compression
      starter = 1
      rpm = 215 + 35 * math.sin(w.t * 2 * math.pi * 7.2)
      fuel = if(w.t < CRANK){ 0 } else { 0.55 }
      if(w.t >= CRANK){
        rpm = rpm + (w.t - CRANK) / FIRE * 160
      }
    } else if(w.t < CRANK + FIRE + CATCH){
      // it catches: up past the idle and back to it
      local k = (w.t - CRANK - FIRE) / CATCH
      local flare = spec.idle + 330 * math.sin(k * math.pi) * (1 - k * 0.5)
      rpm = 400 + (flare - 400) * math.min(k * 2.5, 1)
      rpm = rpm + (d.rpm - spec.idle) * k
      fuel = 0.5 - 0.38 * k
    } else {
      w.phase = "running"
    }
  } else if(w.phase == "dying"){
    local k = w.t / DIE
    if(k >= 1){
      w.phase = "off"
      rpm = 0
    } else {
      // it runs down, shaking at the end
      rpm = w.rpm * (1 - k) * (1 - k) * (1 + 0.08 * math.sin(w.t * 40) * k)
    }
    fuel = 0
    boost = 0
  }
  if(w.phase == "running" or w.phase == "starting"){
    w.rpm = rpm
  }
  set("rpm", rpm)
  set("fuel", fuel)
  set("boost", boost)
  set("starter", starter)
  set("damage", s.damage or 0)
  local raised = s.setup != null and s.setup.snorkel == "snorkel"
  set("snorkel", if(raised){ 1.5 } else { 0.4 })
  // where it is heard from
  local e = listener.place(s.view, listener.at(s.car, TAILPIPE))
  set("exhaust_left", e.left)
  set("exhaust_right", e.right)
  local b = listener.place(s.view, listener.at(s.car, BAY))
  set("bay_left", b.left)
  set("bay_right", b.right)
  local i = listener.place(
    s.view,
    listener.at(s.car, if(raised){ SNORKEL } else { GRILLE }),
  )
  set("intake_left", i.left)
  set("intake_right", i.right)
}

// ------------------------------------------------------------ the mixer's side

// the stems' levels in the mix
local EXHAUST = 0.9
local INTAKE = 0.72
local MECHANICS = 0.8
local TURBO = 0.72

// voice(ctx) -> {block}: see sound/mixer
func m.voice(ctx){
  local engine = require("sound/engine")
  // (SWITCHBACK_CYLINDERS: 5 or 6, to hear the truck with another engine)
  local count = to_int(require("slang/string").to_number(
    require("slang/os").getenv("SWITCHBACK_CYLINDERS") or "4",
  ))
  local e = engine.new({
    sample_rate: ctx.rate, block: ctx.size, cylinders: count
  })
  local now = ctx.now
  local slot = ctx.slot
  local rpm = slot.rpm
  local fuel = slot.fuel
  local boost = slot.boost
  local starter = slot.starter
  local damage = slot.damage
  local snorkel = slot.snorkel
  local places = {
    {
      stem: engine.EXHAUST,
      left: slot.exhaust_left,
      right: slot.exhaust_right,
      level: EXHAUST,
    },
    {
      stem: engine.INTAKE,
      left: slot.intake_left,
      right: slot.intake_right,
      level: INTAKE,
    },
    {
      stem: engine.MECHANICS,
      left: slot.bay_left,
      right: slot.bay_right,
      level: MECHANICS,
    },
    {
      stem: engine.TURBO, left: slot.bay_left, right: slot.bay_right,
      level: TURBO
    },
  }
  for(let local p in values(places)){
    p.was = {left: 0, right: 0}
    p.to = {left: 0, right: 0}
  }
  return {
    block: func(n){
      e:set("rpm", now[rpm])
      e:set("fuel", now[fuel])
      e:set("boost", now[boost])
      e:set("starter", now[starter])
      e:set("damage", now[damage])
      e:set("snorkel", now[snorkel])
      e:compute(n)
      for(local i = 0; i < 4; i = i + 1){
        local p = places[i]
        p.to.left = now[p.left] * p.level
        p.to.right = now[p.right] * p.level
        ctx.place(ctx.truck, e.out[p.stem], p.was, p.to, n)
      }
    },
  }
}

return m
