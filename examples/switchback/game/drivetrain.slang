// game/drivetrain: the engine, the clutch, the gearbox and the
// differentials of the truck. Nothing here knows about Jolt: every step
// the car tells it how fast each wheel turns and what holds it (the
// ground, a brake, nothing), and gets back the torque the drivetrain puts
// on each wheel.
//
//   local d = drivetrain.new()
//   local torques = d:step({throttle: 0.6, direction: 1}, wheels, 1 / 120)
//   d.rpm, d.gear, d.clutch
//
// The engine's speed is a state of its own, not a number made up from
// the road speed: the engine turns the wheels through the clutch and the
// gears, and the wheels turn (or hold back) the engine the same way. One
// small linear system is solved per step for the speeds of the engine
// and the four wheels after it, with everything stiff in it taken
// implicitly: the clutch while it grips, the locks and limited slips of
// the three differentials, and the weight of the truck behind every
// wheel that has grip. So a wheel in the air spins up and takes the
// torque of its axle with it (an open differential), a locked axle
// carries it over to the wheel that holds, the engine lugs on a climb
// and brakes on a descent, and a spinning wheel is heard in the revs.
local math = require("slang/math")

local m = {}

local RPM = 30 / math.pi      // rad/s to revolutions per minute

// The truck's drivetrain: a turbo diesel, five gears and a transfer case.
// type Spec = {idle: float, redline: float, limiter: float,
//   inertia: float, torque: {{float}}, drag: {float}, gears: {float},
//   reverse: float, final: float, low: float, clutch_capacity: float,
//   clutch_stiffness: float, wheel_inertia: float, wheel_radius: float,
//   mass: float}
m.SPEC = {
  idle: 750,
  redline: 4500,
  limiter: 4650,
  // the engine with its flywheel, kg m^2
  inertia: 0.38,
  // torque at full throttle, N m, by rpm
  torque: {
    {400, 140}, {750, 255}, {1000, 305}, {1500, 375}, {2000, 400}, {2600, 400},
    {3100, 388}, {3600, 360}, {4100, 315}, {4500, 268}, {4800, 220},
  },
  // what the engine takes to turn with the throttle shut: base, per rpm
  drag: {28, 0.021},
  gears: {4.17, 2.34, 1.52, 1.14, 0.87},
  reverse: -3.72,
  final: 4.10,
  low: 2.72,
  clutch_capacity: 640,
  // N m per rad/s of slip while the clutch grips: stiff enough to count
  // as locked
  clutch_stiffness: 220,
  wheel_inertia: 3.6,
  wheel_radius: 0.42,
  mass: 1950,
  // what a locked differential takes to let its two sides differ, and
  // what the limited slip in the middle takes, N m per rad/s
  lock_stiffness: 900,
  center_slip: 240,
  axle_slip: 6,
}

// how a wheel is held this step, as the car found it after the last one
m.AIR = 0     // nothing holds it
m.GRIP = 1    // the tire holds the ground: the truck's weight is behind it
m.SLIP = 2    // the tire slides: the ground drags with a known torque
m.FIXED = 3   // a brake holds it still

local func smoothstep(t){
  if(t <= 0){
    return 0
  }
  if(t >= 1){
    return 1
  }
  return t * t * (3 - 2 * t)
}

local func clamp(v, lo, hi){
  if(v < lo){
    return lo
  }
  if(v > hi){
    return hi
  }
  return v
}

// the value of a curve of {x, y} points at x (the ends' beyond them)
local func curve(points, x){
  local n = len(points)
  if(x <= points[0][0]){
    return points[0][1]
  }
  for(local i = 1; i < n; i = i + 1){
    local b = points[i]
    if(x <= b[0]){
      local a = points[i - 1]
      return a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0])
    }
  }
  return points[n - 1][1]
}

// full_torque(spec, rpm) -> the engine's torque at full throttle, N m
func m.full_torque(spec, rpm){
  return curve(spec.torque, rpm)
}

// drag_torque(spec, rpm) -> what turning the engine takes, N m
func m.drag_torque(spec, rpm){
  return spec.drag[0] + spec.drag[1] * math.max(0, rpm)
}

// A drivetrain's state.
// type Drivetrain
// [rpm]: the engine's speed
// [gear]: -1 reverse, 0 neutral, 1.. forward
// [low]: whether the transfer case is in low range
// [clutch]: how far the clutch is closed, 0 to 1
// [slipping]: whether the clutch slips (it is open, or closing, or the
//   engine is held near idle)
// [locks]: {center, front, rear}: which differentials are locked
// [torque]: what the engine makes now, N m (negative: it brakes)
// [load]: the same over what it could make at this speed, 0 to 1
local Drivetrain = {}
local meta = {__index: Drivetrain, __type: "Drivetrain"}

// new(spec?: Spec) -> Drivetrain, idling in neutral
func m.new(spec){
  spec = spec or m.SPEC
  return {
    spec: spec,
    omega: spec.idle / RPM,
    rpm: spec.idle,
    gear: 0,
    low: false,
    locks: {center: false, front: false, rear: false},
    clutch: 0,
    slipping: true,
    launched: false,   // the clutch has closed since the truck last stood
    torque: 0,
    load: 0,
    boost: 0,          // the throttle as the engine feels it (the turbo lags)
    high_revs: 0,      // how long the engine has been at its redline, s
    road_load: 0,      // the torque at the wheels that holds the present speed, N m
    wheel_side: 0,     // the speed of the gearbox's output, as a wheel's, rad/s
    road_speed: 0,     // how fast the truck goes, m/s
    rematch: null,     // after a change: the engine's speed is brought to the gear's
    overrun: false,    // the wheels turned the engine too fast: the clutch is open
    shift: null,       // {to, time, total} while a gear change is under way
    since_shift: 10,
    clutch_torque: 0,
    wheel_torques: {0, 0, 0, 0},
    @meta: meta,
  }
}

// ratio(d, gear?) -> engine turns per wheel turn in a gear (the current
// one by default): negative in reverse, 0 in neutral
func Drivetrain.ratio(d, gear){
  local s = d.spec
  if(gear == null){
    gear = d.gear
  }
  if(gear == 0){
    return 0
  }
  local r = if(gear < 0){ s.reverse } else { s.gears[gear - 1] }
  if(d.low){
    r = r * s.low
  }
  return r * s.final
}

// speed_at(d, rpm, gear?) -> the road speed, m/s, an engine speed gives
// in a gear with the clutch closed
func Drivetrain.speed_at(d, rpm, gear){
  local r = d:ratio(gear)
  if(r == 0){
    return 0
  }
  return rpm / RPM / r * d.spec.wheel_radius
}

// the n by n system a x = b solved in place (Gaussian elimination with
// pivoting); a is a flat list by rows, the result is left in b
local func solve(a, b, n){
  for(local col = 0; col < n; col = col + 1){
    local pivot = col
    local best = math.abs(a[col * n + col])
    for(local row = col + 1; row < n; row = row + 1){
      local v = math.abs(a[row * n + col])
      if(v > best){
        best = v
        pivot = row
      }
    }
    if(pivot != col){
      for(local k = col; k < n; k = k + 1){
        local t = a[col * n + k]
        a[col * n + k] = a[pivot * n + k]
        a[pivot * n + k] = t
      }
      local t = b[col]
      b[col] = b[pivot]
      b[pivot] = t
    }
    local diag = a[col * n + col]
    for(local row = col + 1; row < n; row = row + 1){
      local f = a[row * n + col] / diag
      if(f != 0){
        for(local k = col; k < n; k = k + 1){
          a[row * n + k] = a[row * n + k] - f * a[col * n + k]
        }
        b[row] = b[row] - f * b[col]
      }
    }
  }
  for(local row = n - 1; row >= 0; row = row - 1){
    local sum = b[row]
    for(local k = row + 1; k < n; k = k + 1){
      sum = sum - a[row * n + k] * b[k]
    }
    b[row] = sum / a[row * n + row]
  }
}

// the differentials as rows over the unknowns (engine, FL, FR, RL, RR):
// what each lets differ
local FRONT = {0, 1, -1, 0, 0}
local REAR = {0, 0, 0, 1, -1}
local CENTER = {0, 0.5, 0.5, -0.5, -0.5}
// each wheel's share of the torque that comes down the gearbox
local SHARE = {0.25, 0.25, 0.25, 0.25}

// engine_torque(d, throttle, rpm?) -> N m at the flywheel for a throttle
// 0..1 at an engine speed (the present one by default): the governor
// holds the idle, the limiter cuts the fuel
func Drivetrain.engine_torque(d, throttle, rpm){
  local s = d.spec
  if(rpm == null){
    rpm = d.omega * RPM
  }
  local full = m.full_torque(s, rpm)
  local drag = m.drag_torque(s, rpm)
  // the idle governor: fuel enough to turn itself, more as the revs sag
  local idle = (m.drag_torque(s, s.idle) / (m.full_torque(s, s.idle) + m.drag_torque(s, s.idle))) +
    (s.idle - rpm) * 0.0035
  idle = clamp(idle, 0, 0.6)
  // the pedal's first half asks for more than half of the torque
  throttle = throttle * (1.6 - 0.6 * throttle)
  if(throttle < idle){
    throttle = idle
  }
  if(rpm > s.limiter){
    throttle = 0
  } else if(rpm > s.redline){
    throttle = throttle * (s.limiter - rpm) / (s.limiter - s.redline)
  }
  return throttle * (full + drag) - drag
}

// how far the clutch closes by itself: open at idle, closing as the revs
// rise (higher with more throttle, as a driver slips it for a hard
// start), and once it has closed it stays closed down to just over idle,
// through the gears
local func engagement(d, rpm, throttle){
  if(d.launched){
    return smoothstep((rpm - 790) / 170)
  }
  local from = 860 + 240 * throttle
  local span = 480 + 720 * throttle
  return smoothstep((rpm - from) / span)
}

// the gear the box wants: up when the engine runs out of breath, down
// when it lugs, later and sooner with more throttle
local func choose_gear(d, throttle, spinning){
  local s = d.spec
  local rpm = d.omega * RPM
  local gear = d.gear
  local count = len(s.gears)
  if(gear < 1 or d.since_shift < 0.7){
    return gear
  }
  local t = clamp(throttle, 0, 1)
  local up_at = 1900 + 2350 * t * t
  local down_at = 1050 + 550 * t
  if(t < 0.05){
    // off the throttle the gear is held: the engine brakes
    up_at = s.redline - 80
  }
  if(gear < count and rpm > up_at){
    // only if the next gear does not drop the engine into its hole, and
    // pulls what the road asks for now (or the box would hunt on a hill)
    local after = rpm * s.gears[gear] / s.gears[gear - 1]
    if(spinning){
      // wheels that spin say nothing about the next gear: the road does
      after = math.abs(d.road_speed) / s.wheel_radius * math.abs(d:ratio(gear + 1)) * RPM
    }
    local pull = d:engine_torque(throttle, after) * math.abs(d:ratio(gear + 1))
    local enough = pull > d.road_load * 1.2 or rpm > s.redline - 200
    if(after > down_at + 250 and enough){
      return gear + 1
    }
  }
  if(gear > 1){
    local after = rpm * s.gears[gear - 2] / s.gears[gear - 1]
    if(rpm < down_at and after < s.redline - 200){
      return gear - 1
    }
    // a kick down: full throttle with the engine well under its torque
    if(t > 0.92 and rpm < 2300 and after < s.redline - 500 and d.since_shift > 2.5){
      return gear - 1
    }
  }
  return gear
}

// What the car knows of a wheel before a step.
// type WheelState = {omega: float, hold: int, ground?: float,
//   brake?: float}
// [omega]: how fast it turns, rad/s (forward positive)
// [hold]: AIR, GRIP, SLIP or FIXED
// [ground]: for SLIP, the torque the sliding ground puts on it, N m
// [brake]: the brake's torque on it, N m (for AIR and SLIP)

// step(input: {throttle: float, direction: int, low?: bool,
//   road_load?: float, speed?: float}, wheels: {WheelState}, dt: float)
//   -> {float}
// One step: the gearbox follows the driver (direction 1 forward, -1
// reverse, 0 neutral), the engine and the wheels turn each other, and the
// torque the drivetrain puts on each wheel comes back, N m, in the order
// of the wheels (front left, front right, rear left, rear right).
// [road_load]: the torque at the wheels that would hold the present speed
//   (the hill, the mud, the air), N m: the box changes up only into a
//   gear that pulls it
// [speed]: how fast the truck goes, m/s (the wheels' speed when left
//   out, which is wrong while they spin)
func Drivetrain.step(d, input, wheels, dt){
  local s = d.spec
  local throttle = clamp(input.throttle or 0, 0, 1)
  // the turbo: the engine answers the pedal a moment late
  local rate = if(throttle > d.boost){ 9 } else { 14 }
  d.boost = d.boost + (throttle - d.boost) * (1 - math.exp(-dt * rate))
  d.since_shift = d.since_shift + dt

  // ---- what the road asks of the wheels: what they got, less what went
  // into speeding the truck up
  local wheel_side = 0
  local gripping = 0
  for(local i = 0; i < 4; i = i + 1){
    wheel_side = wheel_side + wheels[i].omega * SHARE[i]
    if(wheels[i].hold == m.GRIP){
      gripping = gripping + 1
    }
  }
  d.wheel_side = wheel_side
  d.road_speed = input.speed or wheel_side * s.wheel_radius
  if(input.road_load != null){
    d.road_load = d.road_load + (input.road_load - d.road_load) * (1 - math.exp(-dt * 4))
  }

  // ---- the gearbox
  local direction = input.direction or 0
  local shifting = d.shift != null
  if(shifting){
    d.shift.time = d.shift.time + dt
    if(d.shift.time >= d.shift.total){
      d.rematch = {time: 0, up: d.shift.to > d.gear}
      d.gear = d.shift.to
      d.shift = null
      d.since_shift = 0
      shifting = false
    }
  }
  if(not shifting){
    local want = d.gear
    if(direction == 0){
      want = 0
    } else if(direction < 0){
      want = -1
    } else if(d.gear < 1){
      want = 1
    } else {
      local spinning = false
      for(local i = 0; i < 4; i = i + 1){
        if(wheels[i].hold == m.SLIP or wheels[i].hold == m.AIR){
          spinning = true
        }
      }
      want = choose_gear(d, throttle, spinning)
    }
    if(want != d.gear){
      if(d.gear == 0 or want == 0 or (d.gear > 0) != (want > 0)){
        // into or out of gear from rest: at once
        d.gear = want
        d.since_shift = 0
        d.launched = false
      } else {
        d.shift = {to: want, time: 0, total: 0.3, from: d.gear}
        shifting = true
      }
    }
  }
  if(input.low != null and input.low != d.low and not shifting){
    d.low = input.low
    d.launched = false
    d.since_shift = 0
  }

  // ---- the engine's torque at its speed now
  local rpm = d.omega * RPM
  if(rpm > s.redline - 150){
    d.high_revs = d.high_revs + dt
  } else {
    d.high_revs = 0
  }
  local pedal = d.boost
  if(shifting){
    // the throttle lifts for the change, with a blip to meet a lower gear
    pedal = 0
    local to = d:ratio(d.shift.to)
    local target = 0
    for(local i = 0; i < 4; i = i + 1){
      target = target + wheels[i].omega * SHARE[i]
    }
    target = target * to
    if(d.omega < target - 15){
      pedal = 0.55
    }
  }
  // what the engine would turn at with the clutch closed
  local ratio = d:ratio()
  local matched = wheel_side * ratio * RPM
  if(d.rematch != null){
    // after a change the engine comes to the new gear's speed before
    // the throttle is back: off it going up, a blip going down
    local r = d.rematch
    r.time = r.time + dt
    if(r.time > 0.7 or not d.slipping and r.time > 0.1){
      d.rematch = null
    } else if(r.up and rpm > matched + 120){
      pedal = 0
    } else if(not r.up and rpm < matched - 120){
      pedal = math.max(pedal, 0.6)
    }
  }
  local te = d:engine_torque(pedal)
  d.torque = te
  d.load = clamp(te / math.max(1, m.full_torque(s, rpm)), -1, 1)

  // ---- the clutch
  local closed = 0
  if(d.overrun){
    d.overrun = matched > s.redline
  } else if(rpm > s.limiter + 250 and matched > s.limiter){
    // the wheels drive the engine past what it survives: let it go
    d.overrun = true
  }
  if(ratio != 0 and not shifting and not d.overrun){
    // by the engine's speed, or the road's when the truck rolls faster
    // than the engine idles (downhill off the throttle: the wheels turn
    // the engine, and it brakes them)
    closed = engagement(d, math.max(rpm, math.min(matched, s.redline)), throttle)
    // closing again after a change takes a moment
    closed = closed * smoothstep(d.since_shift / 0.3 + 0.1)
  }
  local capacity = s.clutch_capacity * closed
  local stiffness = s.clutch_stiffness * closed

  // ---- the system: I/dt x' + (clutch, locks) x' = I/dt x + torques
  local n = 5
  local inertia = {s.inertia, 0, 0, 0, 0}
  local x = {d.omega, 0, 0, 0, 0}
  local known = {te, 0, 0, 0, 0}
  for(local i = 0; i < 4; i = i + 1){
    local w = wheels[i]
    x[i + 1] = w.omega
    if(w.hold == m.GRIP){
      // the truck's weight behind the wheels that hold the ground
      inertia[i + 1] = s.wheel_inertia + s.mass * s.wheel_radius * s.wheel_radius / gripping
    } else if(w.hold == m.FIXED){
      inertia[i + 1] = 1.0e7
    } else {
      inertia[i + 1] = s.wheel_inertia
      local t = 0
      if(w.hold == m.SLIP){
        t = w.ground or 0
      }
      local brake = w.brake or 0
      if(brake > 0){
        // a brake stops a wheel; it does not turn it the other way
        local most = math.abs(w.omega) * s.wheel_inertia / dt + math.abs(t)
        if(brake >= most){
          inertia[i + 1] = 1.0e7
          t = 0
        } else if(w.omega > 0){
          t = t - brake
        } else {
          t = t + brake
        }
      }
      known[i + 1] = t
    }
  }
  // the differentials: locked, or slipping a little
  local couplings = {
    {FRONT, if(d.locks.front){ s.lock_stiffness } else { s.axle_slip }},
    {REAR, if(d.locks.rear){ s.lock_stiffness } else { s.axle_slip }},
    {CENTER, if(d.locks.center or d.low){ s.lock_stiffness * 2 } else { s.center_slip }},
  }
  // the clutch's row: the engine against the gearbox's input
  local c = {1, -ratio * SHARE[0], -ratio * SHARE[1], -ratio * SHARE[2], -ratio * SHARE[3]}

  local a = {}
  local b = {}
  local func build(with_clutch, clutch_torque){
    for(local i = 0; i < n * n; i = i + 1){
      a[i] = 0
    }
    for(local i = 0; i < n; i = i + 1){
      a[i * n + i] = inertia[i] / dt
      b[i] = inertia[i] / dt * x[i] + known[i]
    }
    for(local j = 0; j < 3; j = j + 1){
      local row = couplings[j][0]
      local k = couplings[j][1]
      for(local i = 1; i < n; i = i + 1){
        if(row[i] != 0){
          for(local q = 1; q < n; q = q + 1){
            if(row[q] != 0){
              a[i * n + q] = a[i * n + q] + k * row[i] * row[q]
            }
          }
        }
      }
    }
    if(with_clutch){
      for(local i = 0; i < n; i = i + 1){
        for(local q = 0; q < n; q = q + 1){
          a[i * n + q] = a[i * n + q] + stiffness * c[i] * c[q]
        }
      }
    } else {
      for(local i = 0; i < n; i = i + 1){
        b[i] = b[i] - clutch_torque * c[i]
      }
    }
  }

  local clutch_torque = 0
  local slipping = true
  if(stiffness > 0){
    build(true, 0)
    solve(a, b, n)
    local slip = 0
    for(local i = 0; i < n; i = i + 1){
      slip = slip + c[i] * b[i]
    }
    clutch_torque = stiffness * slip
    slipping = false
    if(math.abs(clutch_torque) > capacity){
      // it cannot hold that much: it slips at what it can
      clutch_torque = if(clutch_torque > 0){ capacity } else { -capacity }
      slipping = true
      build(false, clutch_torque)
      solve(a, b, n)
    }
  } else {
    build(false, 0)
    solve(a, b, n)
  }

  // ---- the result: the engine's new speed, the torque on each wheel
  d.omega = math.max(b[0], 0)
  d.rpm = d.omega * RPM
  d.clutch = closed
  d.slipping = slipping
  if(not slipping and closed > 0.5){
    d.launched = true
  } else if(closed < 0.02 and not shifting and d.since_shift > 0.4){
    // back at idle with the clutch open: the next start is a start
    d.launched = false
  }
  d.clutch_torque = clutch_torque
  local torques = d.wheel_torques
  for(local i = 0; i < 4; i = i + 1){
    local t = -clutch_torque * c[i + 1]
    for(local j = 0; j < 3; j = j + 1){
      local row = couplings[j][0]
      if(row[i + 1] != 0){
        local diff = 0
        for(local q = 1; q < n; q = q + 1){
          diff = diff + row[q] * b[q]
        }
        t = t - couplings[j][1] * row[i + 1] * diff
      }
    }
    torques[i] = t
  }
  return torques
}

m.RPM = RPM

return m
