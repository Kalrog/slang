// The car of programs/inline4.dsp, to drive: its four-cylinder engine, a
// clutch, a six-speed gearbox and 1250 kg of car, all simulated sample by
// sample in the one kernel the program compiles to; heard through
// programs/acoustics.dsp, with its tyres on the road and the wind, from
// beside the road or from the driver's seat (vehicle.slang runs both).
//
//   make car        (or: cd examples/dsp && slang run car.slang)
//
// Keys: W or up is the throttle, S or down the brake, E shifts up and Q
// down, A switches the automatic on and off. The clutch is worked for you
// (driver.slang): a shift lifts off the throttle, presses the clutch,
// changes the gear and lets the clutch out again (blipping the throttle to
// match the revs on a downshift), and pulling away the clutch bites as the
// revs rise. The automatic shifts up near the red line and down when the
// revs fall low. V puts you in the car or beside the road, R changes the
// road (smooth asphalt, coarse chip seal, cobbles). The sliders change the
// engine (spark advance, header and exhaust length, muffler...) and the
// levels of what you hear.
//
// Beside them: the tachometer and the speedometer, the gear, the pedals,
// the pressure in cylinder 1 over its 720-degree cycle (the indicator
// diagram) and the pressure in the exhaust collector.
//
// CAR_FRAMES=n quits after n frames, CAR_SCREENSHOT=file.png saves the
// last one, CAR_THROTTLE=x holds the throttle at x, CAR_AUTO=1 starts in
// the automatic, CAR_INSIDE=1 in the driver's seat (for smoke tests).
local rl = require("raylib")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")
local kernel = require("kernel")
local stream = require("raylib/stream")
local vehicle = require("vehicle")

local W = 1040
local H = 660
local RATE = 48000
// the scope's samples: a ring of rpm, cylinder 1, its phase, the
// collector, the speed
local SCOPE = 8192
local CHANNELS = 5

local C = {
  back: {20, 22, 27},
  panel: {31, 34, 42},
  line: {52, 56, 70},
  text: {214, 218, 228},
  dim: {130, 136, 156},
  accent: {255, 176, 72},
  blue: {96, 196, 255},
  red: {255, 96, 80},
  green: {130, 220, 140},
}

// the controls of both programs, shared with the audio isolate: one cell
// per control
local controls = {}
for(let local c in values(vehicle.controls())){
  append(controls, c.control)
}
local params = kernel.double:array(len(controls), {shared: true})
local slot = {}
for(local i = 0; i < len(controls); i = i + 1){
  params[i] = controls[i].init
  slot[controls[i].label] = i
}
// the scope ring and its write position (cell 0)
local scope = kernel.double:array(SCOPE * CHANNELS, {shared: true})
local scope_at = kernel.int64:array(1, {shared: true})

local player = stream.play(func(params, scope, scope_at, size){
  local vehicle = require("vehicle")
  local car = vehicle.new({sample_rate: 48000, block: 1024})
  local out_rpm = car.engine_out[vehicle.RPM]
  local out_cylinder = car.engine_out[vehicle.CYLINDER]
  local out_phase = car.engine_out[vehicle.PHASE]
  local out_collector = car.engine_out[vehicle.COLLECTOR]
  local out_kmh = car.engine_out[vehicle.KMH]
  return func(out, frames){
    for(local i = 0; i < len(car.controls); i = i + 1){
      local c = car.controls[i]
      c.instance.state[c.control.field] = params[i]
    }
    car:compute(frames)
    local left = car.left
    local right = car.right
    local at = scope_at[0]
    for(local i = 0; i < frames; i = i + 1){
      out[2 * i] = left[i]
      out[2 * i + 1] = right[i]
      local k = (at % size) * 5
      scope[k] = out_rpm[i]
      scope[k + 1] = out_cylinder[i]
      scope[k + 2] = out_phase[i]
      scope[k + 3] = out_collector[i]
      scope[k + 4] = out_kmh[i]
      at = at + 1
    }
    scope_at[0] = at
  }
}, {args: {params, scope, scope_at, SCOPE}, sample_rate: RATE, channels: 2, block: 128})

// the controls the driver works (not sliders; see driver.slang)
local DRIVER = {
  gear: true, clutch: true, brake: true, listener: true, road: true
}
local ROADS = {"smooth asphalt", "coarse chip seal", "cobbles"}

// the scope's last n samples of channel ch, oldest first, into list
local func recent(ch, n, list){
  local at = scope_at[0]
  for(local i = 0; i < n; i = i + 1){
    local k = ((at - n + i) % SCOPE + SCOPE) % SCOPE
    list[i] = scope[k * CHANNELS + ch]
  }
  return list
}

// ------------------------------------------------------------ the driver

local driver = require("driver").new({automatic: os.getenv("CAR_AUTO") != null})
local rpm = 0.0
local kmh = 0.0

local func drive(dt){
  local c = driver:step(dt, rpm, kmh)
  params[slot.throttle] = c.throttle
  params[slot.clutch] = c.clutch
  params[slot.gear] = c.gear
  params[slot.brake] = c.brake
}

// ------------------------------------------------------------ widgets

local drag = null

local func slider(i, x, y, w){
  local c = controls[i]
  local v = params[i]
  local t = (v - c.min) / (c.max - c.min)
  rl.draw.text(c.label, x, y, 10, C.dim)
  local shown = string(math.round(v * 100) / 100)
  rl.draw.text(shown, x + w - rl.text.measure(shown, 10), y, 10, C.text)
  local bar = y + 16
  local is_throttle = c.label == "throttle"
  rl.draw.rectangle(x, bar, w, 6, C.line)
  rl.draw.rectangle(
    x, bar, to_int(w * t), 6, if(is_throttle){ C.accent } else { C.blue }
  )
  rl.draw.rectangle(x + to_int(w * t) - 2, bar - 3, 5, 12, C.text)
  local m = rl.mouse.position
  if(not is_throttle and rl.mouse.pressed(rl.MOUSE_BUTTON_LEFT) and
    m.x >= x - 4 and m.x <= x + w + 4 and m.y >= bar - 6 and m.y <= bar + 12){
    drag = {i: i, x: x, w: w}
  }
}

local func update_drag(){
  if(drag == null){
    return
  }
  if(not rl.mouse.down(rl.MOUSE_BUTTON_LEFT)){
    drag = null
    return
  }
  local c = controls[drag.i]
  local t = math.clamp((rl.mouse.position.x - drag.x) / drag.w, 0.0, 1.0)
  local v = c.min + t * (c.max - c.min)
  if(c.step > 0){
    v = c.min + math.round((v - c.min) / c.step) * c.step
  }
  params[drag.i] = math.clamp(v, c.min, c.max)
}

// a pedal or the clutch as a vertical bar
local func bar(label, v, x, y, color){
  rl.draw.rectangle(x, y, 22, 70, C.panel)
  local h = to_int(70 * math.clamp(v, 0, 1))
  rl.draw.rectangle(x, y + 70 - h, 22, h, color)
  rl.draw.text(
    label, x + 11 - to_int(rl.text.measure(label, 10) / 2), y + 76, 10, C.dim
  )
}

// ------------------------------------------------------------ gauges

// a round gauge from 0 to top over 270 degrees: a labelled tick every
// major (its value over scale), four small ones between, red from red
local func dial(cx, cy, r, value, top, major, scale, red, text, unit){
  rl.draw.circle(cx, cy, r, C.panel)
  local steps = to_int(top / major) * 5
  for(local k = 0; k <= steps; k = k + 1){
    local at = k / steps
    local a = (135 + at * 270) * math.pi / 180
    local big = k % 5 == 0
    local inner = if(big){ r - 16 } else { r - 8 }
    local color = if(at * top >= red){ C.red } else { C.dim }
    rl.draw.line(
      cx + math.cos(a) * inner,
      cy + math.sin(a) * inner,
      cx + math.cos(a) * (r - 3),
      cy + math.sin(a) * (r - 3),
      color,
    )
    if(big){
      local label = string(to_int(at * top / scale))
      local lw = rl.text.measure(label, 10)
      rl.draw.text(
        label, to_int(cx + math.cos(a) * (r - 28) - lw / 2),
        to_int(cy + math.sin(a) * (r - 28)) - 5, 10, C.text
      )
    }
  }
  local a = (135 + math.clamp(value / top, 0, 1.03) * 270) * math.pi / 180
  rl.draw.line_ex(
    {x: cx, y: cy},
    {x: cx + math.cos(a) * (r - 12), y: cy + math.sin(a) * (r - 12)},
    3,
    C.accent,
  )
  rl.draw.circle(cx, cy, 6, C.accent)
  rl.draw.text(
    text, cx - to_int(rl.text.measure(text, 20) / 2), cy + 36, 20, C.text
  )
  rl.draw.text(
    unit, cx - to_int(rl.text.measure(unit, 10) / 2), cy + 60, 10, C.dim
  )
}

local cycle = {}
local phases = {}
local trace = {}

// cylinder 1's pressure over its cycle: one point a sample of the last
// cycles (x: crank angle 0-720, y: bar)
local func indicator(x, y, w, h){
  rl.draw.rectangle(x, y, w, h, C.panel)
  rl.draw.text(
    "CYLINDER 1: pressure over the cycle (bar)", x + 8, y + 6, 10, C.accent
  )
  local top = 60.0
  local names = {"intake", "compression", "power", "exhaust"}
  for(local s = 0; s < 4; s = s + 1){
    local sx = x + to_int(w * s / 4)
    rl.draw.line(sx, y + 20, sx, y + h, C.line)
    rl.draw.text(names[s], sx + 6, y + h - 16, 10, C.dim)
  }
  for(let local b in values({0, 10, 20, 30, 40, 50})){
    local py = y + h - 24 - to_int((h - 50) * b / top)
    rl.draw.line(x, py, x + w, py, C.line)
    rl.draw.text(string(b), x + w - 18, py - 10, 10, C.dim)
  }
  local n = 4096
  recent(1, n, cycle)
  recent(2, n, phases)
  for(local i = 0; i < n; i = i + 1){
    local px = x + to_int(phases[i] * w)
    local py = y + h - 24 -
      to_int((h - 50) * math.clamp((cycle[i] + 1) / top, 0, 1))
    rl.draw.pixel(px, py, C.green)
    rl.draw.pixel(px, py + 1, C.green)
  }
}

// the exhaust collector's pressure, the last 40 ms
local func collector(x, y, w, h){
  rl.draw.rectangle(x, y, w, h, C.panel)
  rl.draw.text("EXHAUST COLLECTOR, last 40 ms", x + 8, y + 6, 10, C.accent)
  local n = 1920
  recent(3, n, trace)
  local mid = y + to_int(h / 2) + 8
  rl.draw.line(x, mid, x + w, mid, C.line)
  local scale = (h - 30) / 2 / 0.6
  local px = x
  local py = mid
  for(local i = 0; i < n; i = i + 4){
    local nx = x + to_int(i / n * w)
    local ny = mid -
      to_int(math.clamp(trace[i] * scale, -(h - 30) / 2, (h - 30) / 2))
    rl.draw.line(px, py, nx, ny, C.blue)
    px = nx
    py = ny
  }
}

local func gear_box(x, y){
  rl.draw.rectangle(x, y, 120, 96, C.panel)
  local g = if(driver.gear == 0){ "N" } else { string(driver.gear) }
  if(driver:shifting()){
    g = "-"
  }
  rl.draw.text(
    g, x + 60 - to_int(rl.text.measure(g, 40) / 2), y + 14, 40, C.accent
  )
  local mode = if(driver.automatic){ "AUTOMATIC" } else { "MANUAL" }
  rl.draw.text(
    mode, x + 60 - to_int(rl.text.measure(mode, 10) / 2), y + 64, 10, C.text
  )
  rl.draw.text("gear", x + 8, y + 6, 10, C.dim)
}

// ------------------------------------------------------------ the loop

rl.window.open(W, H, "dsp: a car")
rl.target_fps = 60
local max_frames = null
if(os.getenv("CAR_FRAMES") != null){
  max_frames = to_int(os.getenv("CAR_FRAMES"))
}
local screenshot = os.getenv("CAR_SCREENSHOT")
local held_throttle = null
if(os.getenv("CAR_THROTTLE") != null){
  held_throttle = str.to_number(os.getenv("CAR_THROTTLE"))
}
if(os.getenv("CAR_INSIDE") != null){
  params[slot.listener] = 1
}
local frame = 0
local stats = {load: 0.0, underruns: 0}
local stats_at = 0.0
local latest = {}
for(not rl.window.should_close){
  frame = frame + 1
  local dt = math.min(rl.frame_time, 0.05)
  // the pedals: pushed down quickly, let up a little faster
  local foot = rl.key.down(rl.KEY_W) or rl.key.down(rl.KEY_UP)
  driver.pedal = math.clamp(
    driver.pedal + if(foot){ 6 * dt } else { -8 * dt }, 0, 1
  )
  if(held_throttle != null){
    driver.pedal = held_throttle
  }
  local stop = rl.key.down(rl.KEY_S) or rl.key.down(rl.KEY_DOWN)
  driver.brake = math.clamp(
    driver.brake + if(stop){ 5 * dt } else { -8 * dt }, 0, 1
  )
  if(rl.key.pressed(rl.KEY_E)){
    driver:shift_to(driver.gear + 1)
  }
  if(rl.key.pressed(rl.KEY_Q)){
    driver:shift_to(driver.gear - 1)
  }
  if(rl.key.pressed(rl.KEY_A)){
    driver.automatic = not driver.automatic
  }
  if(rl.key.pressed(rl.KEY_V)){
    params[slot.listener] = 1 - params[slot.listener]
  }
  if(rl.key.pressed(rl.KEY_R)){
    params[slot.road] = (params[slot.road] + 1) % 3
  }
  rpm = recent(0, 1, latest)[0]
  kmh = recent(4, 1, latest)[0]
  drive(dt)
  update_drag()
  if(rl.time - stats_at > 0.5){
    stats_at = rl.time
    stats = player:stats()
  }
  rl.drawing{
    rl.draw.clear(C.back)
    rl.draw.text("a car", 16, 14, 24, C.accent)
    rl.draw.text(
      "programs/inline4.dsp and acoustics.dsp: engine, drivetrain, tyres, wind and listener, compiled to kernels",
      110, 22, 10, C.dim
    )
    local y = 64
    for(local i = 0; i < len(controls); i = i + 1){
      if(DRIVER[controls[i].label] == null){
        slider(i, 24, y, 290)
        y = y + 34
      }
    }
    rl.draw.text("W / up: throttle    S / down: brake", 24, y + 8, 10, C.dim)
    rl.draw.text(
      "E: shift up    Q: shift down    A: automatic", 24, y + 24, 10, C.dim
    )
    rl.draw.text(
      "V: inside / outside    R: road surface", 24, y + 40, 10, C.dim
    )
    rl.draw.text(concat(
      "audio load ",
      string(math.round(stats.load * 1000) / 10),
      "%, underruns ",
      string(stats.underruns),
    ), 24, y + 64, 10, C.dim)
    dial(
      480, 196, 128, rpm, 8000, 1000, 1000, 6800,
      concat(string(to_int(rpm)), " rpm"), "x1000"
    )
    dial(890, 196, 128, kmh, 240, 20, 1, 1000, string(to_int(kmh)), "km/h")
    gear_box(625, 110)
    bar("clutch", params[slot.clutch], 627, 230, C.blue)
    bar("brake", params[slot.brake], 676, 230, C.red)
    bar("gas", params[slot.throttle], 725, 230, C.accent)
    local where = if(params[slot.listener] > 0.5){ "in the driver's seat" } else { "beside the road" }
    local scene = concat(
      "listening ", where, "    road: ", ROADS[to_int(params[slot.road])]
    )
    rl.draw.text(
      scene, 685 - to_int(rl.text.measure(scene, 10) / 2), 380, 10, C.text
    )
    indicator(340, 420, 440, 220)
    collector(800, 420, 220, 220)
  }
  if(max_frames != null and frame >= max_frames){
    if(screenshot != null){
      rl.window.screenshot(screenshot)
    }
    break
  }
}
local last = player:stats()
player:stop()
rl.window.close()
print(concat(
  "frames ", string(frame), ", load ", string(last.load), ", underruns ",
  string(last.underruns), "\n"
))
