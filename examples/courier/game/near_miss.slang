// game/near_miss: passing traffic close, at speed, graded and chained.
// A pass is followed while the gap between the two hulls (the car's box,
// turned as it is, and the traffic car's box along its lane) is under
// ZONE; when the gap opens again the pass is scored by the smallest gap
// it had: RAZOR, TIGHT or CLOSE, more for a faster pass and more for an
// oncoming car. A pass that touched scores nothing.
//
// Misses chain: each one winds the chain's clock back up and raises the
// multiplier, and skimming a wall holds the clock. Threading a slot (in
// at one end, out at the other: game/city) counts as a miss too. The chain's cash is
// banked when the clock runs out; a crash before that loses all of it.
local math = require("slang/math")
local vec = require("game/vec")
local car_lib = require("game/car")
local traffic_lib = require("game/traffic")

local m = {}

m.ZONE = 4          // m of gap where a pass begins
m.MIN_SPEED = 12    // m/s between the two, below which nothing counts
m.CHAIN_TIME = 3.5  // s from one miss to the next before the chain banks
m.MAX_MULT = 3      // the multiplier: 1 for the first, +0.25 each, to this
m.CASH = 3          // $ per point
m.ONCOMING = 1.5    // points for a car coming the other way
m.THREAD = {name: "THREAD", points: 3, boost: 0.15}
m.TIERS = {
  {gap: 0.6, name: "RAZOR", points: 4, boost: 0.25},
  {gap: 1.6, name: "TIGHT", points: 2, boost: 0.16},
  {gap: m.ZONE, name: "CLOSE", points: 1, boost: 0.1},
}

// new() -> the state: the passes under way (by traffic car id) and the
// chain
func m.new(){
  return {
    passes: {},
    chain: 0,       // misses in the chain
    cash: 0,        // what it would bank now
    clock: 0,       // s left before it banks
    mult: 1,
    misses: 0,      // all of them, for the stats
    best_chain: 0,
    banked: 0,
  }
}

// gap(car, t): the air between the car's hull and a traffic car's
func m.gap(car, t){
  local th = t.half or {x: traffic_lib.HALF_WIDTH, y: traffic_lib.HALF_HEIGHT, z: traffic_lib.HALF_LENGTH}
  local hx = th.x
  local hz = th.z
  if(t.lane.axis == "x"){
    hx = th.z
    hz = th.x
  }
  local hy = th.y
  local d = vec.sub(car.pos, t.pos)
  // from the nearest point of the traffic car's box to the car's center
  local out = {
    x: d.x - vec.clamp(d.x, -hx, hx),
    y: d.y - vec.clamp(d.y, -hy, hy),
    z: d.z - vec.clamp(d.z, -hz, hz),
  }
  local dist = vec.length(out)
  if(dist < 0.0001){
    return 0
  }
  // less how far the car's own box reaches that way
  local n = vec.scale(out, 1 / dist)
  local a = vec.axes(car.q)
  local half = car_lib.HALF
  local reach = math.abs(vec.dot(a.right, n)) * half.x +
    math.abs(vec.dot(a.up, n)) * half.y + math.abs(vec.dot(a.forward, n)) * half.z
  return math.max(0, dist - reach)
}

local func event(w, kind, extra){
  extra.kind = kind
  append(w.events, extra)
}

// the tier of a smallest gap
func m.tier(gap){
  for(let local tier in values(m.TIERS)){
    if(gap < tier.gap){
      return tier
    }
  }
  return null
}

// a miss of a tier into the chain
local func add(s, w, tier, speed, oncoming, pos, gap){
  local points = tier.points * vec.clamp(speed / 30, 0.6, 2)
  if(oncoming){
    points = points * m.ONCOMING
  }
  s.chain = s.chain + 1
  s.misses = s.misses + 1
  s.best_chain = math.max(s.best_chain, s.chain)
  s.mult = math.min(m.MAX_MULT, 1 + 0.25 * (s.chain - 1))
  local cash = points * m.CASH * s.mult
  s.cash = s.cash + cash
  s.clock = m.CHAIN_TIME
  w.car.boost = math.min(1, w.car.boost + tier.boost)
  event(w, "near_miss", {
    tier: tier.name,
    cash: to_int(math.floor(cash + 0.5)),
    chain: s.chain,
    mult: s.mult,
    gap: gap,
    speed: speed,
    oncoming: oncoming,
    pos: pos,
  })
}

// a pass that opened: a miss, if it was one
local func score(s, w, p){
  if(p.touched or p.speed < m.MIN_SPEED){
    return
  }
  local tier = m.tier(p.gap)
  add(s, w, tier, p.speed, p.oncoming, p.car.pos, p.gap)
}

// thread(s, w, speed): a slot threaded, end to end
func m.thread(s, w, speed){
  add(s, w, m.THREAD, speed, false, w.car.pos, 0)
}

// bank(s, w): the chain's cash into the credits, now
func m.bank(s, w){
  if(s.chain > 0){
    local cash = to_int(math.floor(s.cash + 0.5))
    w.credits = w.credits + cash
    s.banked = s.banked + cash
    event(w, "chain_banked", {cash: cash, chain: s.chain})
  }
  s.chain = 0
  s.cash = 0
  s.clock = 0
  s.mult = 1
}

// crash(s, w): the chain is lost
func m.crash(s, w){
  if(s.chain > 0){
    event(w, "chain_lost", {cash: to_int(math.floor(s.cash + 0.5)), chain: s.chain})
  }
  s.chain = 0
  s.cash = 0
  s.clock = 0
  s.mult = 1
  s.passes = {}
}

// touch(s, t): the car touched a traffic car: its pass scores nothing
func m.touch(s, t){
  local p = s.passes[t.id]
  if(p == null){
    s.passes[t.id] = {car: t, gap: 0, speed: 0, oncoming: false, touched: true}
  } else {
    p.touched = true
  }
}

// step(s, w, dt): follow the passes, score those that opened, run the
// chain's clock (held while skimming)
func m.step(s, w, dt){
  local car = w.car
  local reach = m.ZONE + 5.2 + car_lib.HALF.z
  local seen = {}
  for(let local t in values(w.traffic.near)){
    if(not t.wrecked and t.pos != null and vec.distance(t.pos, car.pos) < reach){
      local g = m.gap(car, t)
      if(g < m.ZONE){
        seen[t.id] = true
        local p = s.passes[t.id]
        if(p == null){
          p = {car: t, gap: g, speed: 0, oncoming: false, touched: false}
          s.passes[t.id] = p
        }
        if(g <= p.gap){
          p.gap = g
          p.oncoming = vec.dot(car.vel, t.vel) < 0
        }
        p.speed = math.max(p.speed, vec.length(vec.sub(car.vel, t.vel)))
      }
    }
  }
  local open = {}
  for(let local en in entries(s.passes)){
    if(seen[en[0]]){
      open[en[0]] = en[1]
    } else {
      score(s, w, en[1])
    }
  }
  s.passes = open
  if(s.chain > 0 and not car.skimming){
    s.clock = s.clock - dt
    if(s.clock <= 0){
      m.bank(s, w)
    }
  }
}

return m
