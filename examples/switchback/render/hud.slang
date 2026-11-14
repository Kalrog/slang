// render/hud: the instruments over the picture while driving. Bottom
// right, what the truck does: the engine's revs on a dial with the speed
// in its middle, the gear and the range, the pedals, lamps for low range,
// the differential locks and the brakes that hold it. Bottom left, how it
// stands: every wheel (gripping, spinning, in the air) with the axles
// that are locked, the ground under it, and how far it leans forward and
// sideways. Top left the clock and the splits (or, exploring, the name
// of the trail and the camps found), top middle the way to the next
// checkpoint (or the marker followed) on a compass, top right the trails
// on a small map that turns with the truck. Titles of the trail's hard stretches and
// messages come and go under the compass.
//
//   hud.init()
//   hud.draw(info)                  // inside rl.drawing{ }, after the scene
//   hud.message("River Camp  +0:03.2", "good")
//   hud.message("Rock Steps", "title")
//
// Everything is drawn anew each frame with a couple of hundred calls of
// raylib's shapes and text (about a third of a millisecond), the shapes
// first and all the words after them.
local rl = require("raylib")
local math = require("slang/math")
local str = require("slang/string")
local buffer = require("slang/buffer")
local ui = require("render/ui")

local m = {}

local colors = ui.colors

// What the HUD shows, filled by the game each frame. Every field may be
// missing.
// type Info = {speed?: float, rpm?: float, redline?: float,
//   limiter?: float, idle?: float, gear?: int, low?: bool,
//   shifting?: bool, clutch?: float, throttle?: float, brake?: float,
//   hand_brake?: bool, holding?: bool, locks?: {front?: bool,
//   rear?: bool, center?: bool}, pitch?: float, roll?: float,
//   heading?: float, wheels?: {Wheel}, surface?: string, time?: float,
//   running?: bool, penalty?: float, checkpoint?: Checkpoint,
//   splits?: {Split}, progress?: float, trail?: Trail, section?: {name:
//   string}, damage?: float, recover?: bool, recover_hold?: float,
//   recover_text?: string, fps?: float, debug?: bool, mode?: string,
//   place?: string, camps_found?: int, camps_total?: int, repair?: float,
//   network?: Network}
// [mode]: "explore" shows where the truck is and the camps found top left
//   instead of the clock, and the small map has [network] (when given)
//   instead of [trail]; "trail" (or nothing) is the run to the summit
// [place]: the name of the trail or place the truck is on (exploring)
// [repair]: while the truck is repaired at a camp, how far that is, 0 to 1
// [recover_text]: what the hint to recover says (when [recover])
// [speed]: m/s, backward negative
// [gear]: -1 reverse, 0 neutral, 1 and up forward
// [pitch], [roll]: radians, nose up and right side down positive
// [heading]: radians, 0 toward +z (north), growing toward +x (which is
//   the west: +x is on the left of a truck that faces +z)
// [progress]: how far along the trail, 0 to 1
// [recover]: the hint how to get back on the trail is shown
// [recover_hold]: how far the key has been held of what it takes, 0 to 1
// [debug]: [fps] is shown
// type Wheel = {contact?: bool, slip?: float, load?: float}
// type Checkpoint = {name: string, distance?: float, bearing?: float,
//   index?: int, total?: int}
// [bearing]: the way to it, an angle like [heading]
// [index]: which of the trail's checkpoints it is
// type Split = {name: string, time: float, best?: float}
// type Network = {position: {x: float, z: float}, trails: {{points:
//   {{x: float, z: float}}, kind?: string}}, route?: {{x: float,
//   z: float}}, camps?: {{x: float, z: float, found?: bool}},
//   markers?: {{x: float, z: float}}, target?: int}
// [position]: the truck's
// [route]: the way along the trails to the marker followed
// [target]: which of the markers is followed
// type Trail = {points: {{x: float, z: float}}, position: {x: float,
//   z: float}, index?: int, checkpoints?: {{x: float, z: float,
//   index?: int, name?: string}}, next?: int}
// [index]: the trail's point nearest the truck ([progress] says where when
//   it is left out)
// [checkpoints]: where they are, and which of the trail's points each is
// [next]: which of the checkpoints is the next one (the [index] of the
//   Info's checkpoint when it is left out)

local state = {
  messages: {},
  section: null,       // {name, age, life}: the title card being shown
  section_name: null,  // the stretch the truck was in the frame before
  rpm: 750,
  points: null,        // a buffer of points for the map's lines
}

local MAP_POINTS = 256
// the dial: where its scale starts and how far round it goes, degrees
// (0 is to the right, growing clockwise), and the revs at its end
local DIAL_FROM = 140
local DIAL_SWEEP = 260
local DIAL_REVS = 5000

// init(): the fonts and what the drawing needs
func m.init(){
  ui.init()
  if(state.points == null){
    state.points = buffer.new("Vector2", MAP_POINTS, rl.decls)
  }
}

// unload(): the fonts given back (when the window closes)
func m.unload(){
  state.messages = {}
  state.section = null
  state.section_name = null
  ui.unload()
}

// the title of a stretch of the trail, large under the compass (the one
// that is showing stays when it is the same)
local func show_title(name, seconds){
  local card = state.section
  if(card != null and card.name == name and card.age < card.life - 0.6){
    return
  }
  state.section = {name: name, age: 0, life: seconds or 3.6}
}

// message(text: string, kind?: string, seconds?: float)
// A line that shows under the compass for a while (3.5 s when seconds is
// left out). kind colors it: "info" (the default), "good" (time gained,
// something done), "warn" (time lost, a penalty), "bad" (damage, a wreck).
// A message of the kind "title" is the name of a stretch of the trail and
// shows large, with a line to either side.
func m.message(text, kind, seconds){
  if(kind == "title"){
    show_title(text, seconds)
    return
  }
  append(state.messages, {text: text, kind: kind or "info", age: 0, life: seconds or 3.5})
  if(len(state.messages) > 4){
    remove(state.messages, 0)
  }
}

// clear(): no messages, no title card (for a new run)
func m.clear(){
  state.messages = {}
  state.section = null
  state.section_name = null
}

local func point_on(cx, cy, r, degrees){
  local a = degrees * math.pi / 180
  return {cx + math.cos(a) * r, cy + math.sin(a) * r}
}

// What stays where it is while the window keeps its size (the marks of
// the dial and of the leans), by name: lists of {from, to, thick, color}
// for lines and {text, x, y} for their numbers.
local fixed = {w: 0, h: 0, marks: {}}

local func fixed_marks(name){
  if(fixed.w != ui.w or fixed.h != ui.h){
    fixed.w = ui.w
    fixed.h = ui.h
    fixed.marks = {}
  }
  return fixed.marks[name]
}

local func draw_marks(list){
  for(let local mark in values(list)){
    if(mark.text != null){
      ui.text(mark.x, mark.y, mark.text, 10, colors.dim)
    } else {
      rl.draw.line_ex(mark.from, mark.to, mark.thick, mark.color)
    }
  }
}

// a turn by degrees about a center, worked out once for the shapes that
// turn together
local func turn_by(cx, cy, degrees){
  local a = degrees * math.pi / 180
  return {cx: cx, cy: cy, c: math.cos(a), s: math.sin(a), degrees: degrees}
}

// a rectangle of w by h whose middle is (ox, oy) from the turn's center
local func turned_rect(turn, ox, oy, w, h, color){
  rl.draw.rectangle_pro(
    {turn.cx + ox * turn.c - oy * turn.s, turn.cy + ox * turn.s + oy * turn.c, w, h},
    {w / 2, h / 2}, turn.degrees, color
  )
}

local func turned_point(turn, ox, oy){
  return {turn.cx + ox * turn.c - oy * turn.s, turn.cy + ox * turn.s + oy * turn.c}
}

// ------------------------------------------------------------ the drive

local func draw_drive(info){
  local s = ui.s
  local r = 92 * s
  local cx = ui.w - 28 * s - r
  local cy = ui.h - 36 * s - r
  local center = {cx, cy}
  // the lamps and the pedals on a plate beside the dial
  local bx = cx - r - 30 * s
  local pw = 62 * s
  local ph = 19 * s
  local px = bx - 26 * s - 2 * pw - 6 * s
  local py = ui.h - 36 * s - 2 * ph - 6 * s
  ui.panel(px - 12 * s, py - 30 * s, bx + 16 * s - px + 12 * s, 2 * ph + 6 * s + 42 * s)
  ui.disc(cx, cy, r + 10 * s, colors.ink)

  local redline = info.redline or 4500
  local rpm = info.rpm or 0
  // (the needle a little slower than the number, as a needle is)
  state.rpm = state.rpm + (rpm - state.rpm) * 0.45
  local share = math.max(0, math.min(1, state.rpm / DIAL_REVS))
  local at = DIAL_FROM + DIAL_SWEEP * share
  local red_from = DIAL_FROM + DIAL_SWEEP * redline / DIAL_REVS
  local to = DIAL_FROM + DIAL_SWEEP
  // the scale, the red end of it, the revs
  rl.draw.ring(center, r - 6 * s, r, DIAL_FROM, to, 48, {242, 234, 216, 36})
  rl.draw.ring(center, r + 2 * s, r + 4 * s, red_from, to, 12, colors.red)
  local hot = (state.rpm - (redline - 500)) / 500
  local color = ui.mix(colors.paper, colors.red, hot)
  if(share > 0.004){
    rl.draw.ring(center, r - 6 * s, r, DIAL_FROM, at, 48, color)
  }
  local marks = fixed_marks("dial")
  if(marks == null){
    marks = {}
    for(local k = 0; k <= 10; k = k + 1){
      local a = DIAL_FROM + DIAL_SWEEP * k * 500 / DIAL_REVS
      if(k % 2 == 0){
        append(marks, {
          from: point_on(cx, cy, r - 14 * s, a), to: point_on(cx, cy, r - 8 * s, a),
          thick: 1.5 * s, color: colors.dim,
        })
        local p = point_on(cx, cy, r - 25 * s, a)
        local text = string(to_int(k / 2))
        append(marks, {text: text, x: p[0] - ui.measure(text, 10) / 2, y: p[1] - 5.5 * s})
      } else {
        append(marks, {
          from: point_on(cx, cy, r - 11 * s, a), to: point_on(cx, cy, r - 8 * s, a),
          thick: 1 * s, color: colors.faint,
        })
      }
    }
    fixed.marks.dial = marks
  }
  draw_marks(marks)
  rl.draw.circle_v(point_on(cx, cy, r - 3 * s, at), 4.5 * s, color)

  // the speed
  local kmh = math.abs(info.speed or 0) * 3.6
  ui.figures(cx, cy - 40 * s, string(to_int(kmh + 0.5)), 52, colors.paper, 0)
  ui.label(cx, cy + 16 * s, "km/h", 10, colors.dim, 0)

  // the gear and the range, in the dial's open bottom
  local gear = info.gear or 0
  local name = "N"
  if(gear < 0){
    name = "R"
  } else if(gear > 0){
    name = string(gear)
  }
  local gear_color = colors.amber
  if(info.shifting){
    gear_color = colors.faint
  }
  local gw = ui.measure(name, 30)
  local range = if(info.low){ "L" } else { "H" }
  local rw = ui.measure(range, 14)
  local gx = cx - (gw + 3 * s + rw) / 2
  ui.text(gx, cy + 40 * s, name, 30, gear_color)
  ui.text(gx + gw + 3 * s, cy + 54 * s, range, 14, if(info.low){ colors.amber } else { colors.dim })

  // the pedals: two thin columns left of the dial
  local bh = 2 * ph + 6 * s
  local by = py
  local throttle = math.max(0, math.min(1, info.throttle or 0))
  local brake = math.max(0, math.min(1, info.brake or 0))
  rl.draw.rectangle_rec({bx, by, 4 * s, bh}, {242, 234, 216, 40})
  rl.draw.rectangle_rec({bx - 10 * s, by, 4 * s, bh}, {242, 234, 216, 40})
  if(throttle > 0.01){
    rl.draw.rectangle_rec({bx, by + bh * (1 - throttle), 4 * s, bh * throttle}, colors.paper)
  }
  if(brake > 0.01){
    rl.draw.rectangle_rec({bx - 10 * s, by + bh * (1 - brake), 4 * s, bh * brake}, colors.red)
  }

  // the lamps: low range, the locks, the brakes that hold
  local locks = info.locks or {}
  ui.label(px, py - 20 * s, "drivetrain", 8, colors.dim)
  ui.pill(px, py, pw, ph, "low", info.low == true)
  local held = info.hand_brake == true or info.holding == true
  ui.pill(px + pw + 6 * s, py, pw, ph, if(info.hand_brake){ "brake" } else { "hold" }, held,
    if(info.hand_brake){ colors.red } else { colors.paper })
  ui.pill(px, py + ph + 6 * s, pw, ph, "f lock", locks.front == true)
  ui.pill(px + pw + 6 * s, py + ph + 6 * s, pw, ph, "r lock", locks.rear == true)
}

// ------------------------------------------------------------ how it stands

// the color of a lean: paper, amber when it is a lot, red when it is
// too much
local func lean_color(radians){
  local d = math.abs(radians) * 180 / math.pi
  if(d > 30){
    return colors.red
  }
  if(d > 20){
    return colors.amber
  }
  return colors.paper
}

local func draw_wheels(info, x, y){
  local s = ui.s
  local w = 78 * s
  local h = 106 * s
  local cx = x + w / 2
  local locks = info.locks or {}
  local wheels = info.wheels or {}
  local ww = 13 * s
  local wh = 27 * s
  local half = 27 * s
  local fy = y + 22 * s
  local ry = y + h - 22 * s
  // the frame: the shaft down the middle, the two axles
  local shaft = if(info.low == true or locks.center == true){ colors.amber } else { colors.faint }
  rl.draw.line_ex({cx, fy}, {cx, ry}, 2 * s, shaft)
  rl.draw.line_ex({cx - half, fy}, {cx + half, fy}, if(locks.front){ 4 * s } else { 1.5 * s },
    if(locks.front){ colors.amber } else { colors.faint })
  rl.draw.line_ex({cx - half, ry}, {cx + half, ry}, if(locks.rear){ 4 * s } else { 1.5 * s },
    if(locks.rear){ colors.amber } else { colors.faint })
  // the wheels: front left, front right, rear left, rear right (the left
  // of the truck is the left of the picture: it is seen from above)
  for(local i = 0; i < 4; i = i + 1){
    local wheel = wheels[i] or {contact: true, slip: 0, load: 1}
    local wx = if(i % 2 == 0){ cx - half - ww / 2 } else { cx + half - ww / 2 }
    local wy = if(i < 2){ fy - wh / 2 } else { ry - wh / 2 }
    local rec = {wx, wy, ww, wh}
    if(wheel.contact == false){
      rl.draw.rectangle_rounded_lines_ex(rec, 0.5, 4, 1.5 * s, colors.red)
    } else if(math.abs(wheel.slip or 0) > 0.3){
      rl.draw.rectangle_rounded(rec, 0.5, 4, colors.amber)
    } else {
      local load = math.max(0.15, math.min(1.3, wheel.load or 1))
      rl.draw.rectangle_rounded(rec, 0.5, 4, {242, 234, 216, to_int(70 + 140 * load / 1.3)})
    }
  }
}

// one of the two gauges of the lean: the truck's outline turning over a
// level line, the angle in figures under it
local func draw_lean(cx, cy, radians, side_view, name){
  local s = ui.s
  local r = 40 * s
  local color = lean_color(radians)
  local degrees = radians * 180 / math.pi
  // the level, and marks at 15 and 30 degrees either way
  local marks = fixed_marks(name)
  if(marks == null){
    marks = {
      {from: {cx - r, cy}, to: {cx - r + 8 * s, cy}, thick: 1.5 * s, color: colors.dim},
      {from: {cx + r - 8 * s, cy}, to: {cx + r, cy}, thick: 1.5 * s, color: colors.dim},
    }
    for(let local at in values({-30, -15, 15, 30, 150, 165, 195, 210})){
      append(marks, {
        from: point_on(cx, cy, r - 4 * s, at), to: point_on(cx, cy, r, at), thick: 1 * s, color: colors.faint,
      })
    }
    fixed.marks[name] = marks
  }
  draw_marks(marks)
  local gy = cy - 3 * s
  if(side_view){
    // from its right side, the nose to the right: nose up turns it
    // against the clock
    local turn = turn_by(cx, gy, -degrees)
    turned_rect(turn, 0, 2 * s, 46 * s, 9 * s, color)
    turned_rect(turn, -6 * s, -7 * s, 28 * s, 10 * s, color)
    local rear = turned_point(turn, -14 * s, 9 * s)
    local front = turned_point(turn, 14 * s, 9 * s)
    rl.draw.circle_v(rear, 6.5 * s, colors.ink_solid)
    rl.draw.circle_v(front, 6.5 * s, colors.ink_solid)
    rl.draw.circle_v(rear, 5 * s, color)
    rl.draw.circle_v(front, 5 * s, color)
  } else {
    // from behind: its right side down turns it with the clock
    local turn = turn_by(cx, gy, degrees)
    turned_rect(turn, 0, -3 * s, 30 * s, 17 * s, color)
    turned_rect(turn, 0, -13 * s, 22 * s, 6 * s, color)
    turned_rect(turn, -14 * s, 8 * s, 7 * s, 13 * s, color)
    turned_rect(turn, 14 * s, 8 * s, 7 * s, 13 * s, color)
  }
  local figure = concat(string(to_int(math.abs(degrees) + 0.5)), "\u{b0}")
  ui.text_center(cx + 2 * s, cy + 23 * s, figure, 13, color)
  ui.label(cx, cy - r - 2 * s, name, 8, colors.dim, 0)
}

local func draw_stance(info){
  local s = ui.s
  local x = 28 * s
  local h = 124 * s
  local y = ui.h - 36 * s - h
  local w = 304 * s
  ui.panel(x - 8 * s, y - 8 * s, w, h + 16 * s)
  draw_wheels(info, x, y + 12 * s)
  // a thin line between the wheels and the leans
  rl.draw.rectangle_rec({x + 88 * s, y + 6 * s, 1 * s, h - 12 * s}, colors.edge)
  local cy = y + h / 2 + 8 * s
  draw_lean(x + 142 * s, cy, info.pitch or 0, true, "pitch")
  draw_lean(x + 240 * s, cy, info.roll or 0, false, "roll")
  // the ground under it, over the wheels; the damage when there is some
  if(info.surface != null){
    ui.label(x + 39 * s, y - 1 * s, info.surface, 8, colors.amber, 0)
  }
  local damage = info.damage or 0
  if(damage > 0.005){
    local dy = y - 34 * s
    ui.panel(x - 8 * s, dy, 150 * s, 20 * s)
    ui.label(x + 2 * s, dy + 5.5 * s, "damage", 8, if(damage > 0.6){ colors.red } else { colors.dim })
    ui.bar(x + 56 * s, dy + 8.5 * s, 76 * s, 3 * s, damage, if(damage > 0.6){ colors.red } else { colors.amber })
  }
}

// ------------------------------------------------------------ the clock

local func draw_clock(info){
  local s = ui.s
  local x = 28 * s
  local y = 24 * s
  local splits = info.splits or {}
  local shown = math.min(2, len(splits))
  local h = (66 + shown * 19) * s
  ui.panel(x - 8 * s, y - 8 * s, 248 * s, h + 12 * s)
  local time = info.time or 0
  ui.figures(x + 4 * s, y - 2 * s, ui.clock(time), 32, if(info.running == false){ colors.dim } else { colors.paper })
  local penalty = info.penalty or 0
  if(penalty > 0.05){
    ui.figures(x + 228 * s, y + 3 * s, concat("+", ui.clock(penalty, false)), 13, colors.red, 1)
    ui.label(x + 228 * s, y + 20 * s, "penalty", 8, colors.red, 1)
  }
  // how far along the trail, with the checkpoints as marks
  local by = y + 44 * s
  local bw = 226 * s
  local progress = math.max(0, math.min(1, info.progress or 0))
  ui.bar(x + 4 * s, by, bw, 3 * s, progress, colors.amber)
  local trail = info.trail
  if(trail != null and trail.checkpoints != null and trail.points != null){
    local last = math.max(1, len(trail.points) - 1)
    for(let local c in values(trail.checkpoints)){
      if(c.index != null){
        local tx = x + 4 * s + bw * math.min(1, c.index / last)
        rl.draw.rectangle_rec({tx - 0.75 * s, by - 3 * s, 1.5 * s, 9 * s},
          if(c.index / last <= progress){ colors.amber } else { colors.dim })
      }
    }
  } else if(info.checkpoint != null and (info.checkpoint.total or 0) > 0){
    local total = info.checkpoint.total
    for(local k = 0; k <= total; k = k + 1){
      local tx = x + 4 * s + bw * k / total
      rl.draw.rectangle_rec({tx - 0.75 * s, by - 3 * s, 1.5 * s, 9 * s}, colors.dim)
    }
  }
  // the last splits: name, time, and the difference to the best run
  for(local k = 0; k < shown; k = k + 1){
    local split = splits[len(splits) - shown + k]
    local sy = y + (58 + k * 19) * s
    ui.label(x + 4 * s, sy + 2 * s, split.name, 9, colors.dim)
    ui.figures(x + 166 * s, sy, ui.clock(split.time), 12, colors.paper, 1)
    if(split.best != null){
      local d = split.time - split.best
      ui.figures(x + 230 * s, sy, ui.delta(d), 12, if(d <= 0){ colors.green } else { colors.red }, 1)
    }
  }
}

// ------------------------------------------------------------ the way

// an angle brought into -pi..pi
local func wrapped(a){
  a = a % (2 * math.pi)
  if(a > math.pi){
    a = a - 2 * math.pi
  }
  return a
}

// the four winds by the angle of [Info.heading], which grows to the left
local compass_names = {[0]: "N", [90]: "W", [180]: "S", [270]: "E"}

local func draw_way(info){
  local s = ui.s
  local cx = ui.w / 2
  local y = 24 * s
  local half = 150 * s
  local span = 55            // degrees shown to either side
  local heading = (info.heading or 0) * 180 / math.pi
  ui.panel(cx - half - 14 * s, y - 8 * s, 2 * half + 28 * s, 62 * s)
  rl.draw.line_ex({cx - half, y + 20 * s}, {cx + half, y + 20 * s}, 1 * s, colors.faint)
  // a mark every 15 degrees, a letter at the four winds
  local first = to_int(math.floor((heading - span) / 15) + 1) * 15
  for(local d = first; d <= heading + span; d = d + 15){
    // (a greater angle lies further left)
    local tx = cx - (d - heading) / span * half
    local name = compass_names[((d % 360) + 360) % 360]
    if(name != null){
      ui.text_center(tx, y - 3 * s, name, 13, colors.paper)
      rl.draw.line_ex({tx, y + 14 * s}, {tx, y + 20 * s}, 1.5 * s, colors.paper)
    } else {
      rl.draw.line_ex({tx, y + 16 * s}, {tx, y + 20 * s}, 1 * s, colors.dim)
    }
  }
  // where the truck points
  rl.draw.triangle({cx, y + 22 * s}, {cx - 4 * s, y + 28 * s}, {cx + 4 * s, y + 28 * s}, colors.paper)
  local checkpoint = info.checkpoint
  if(checkpoint == null){
    return
  }
  // where the checkpoint lies: on the scale, or at its end with an arrow
  if(checkpoint.bearing != null){
    local off = -wrapped(checkpoint.bearing - (info.heading or 0)) * 180 / math.pi
    local tx = cx + math.max(-1, math.min(1, off / span)) * half
    if(off < -span){
      rl.draw.triangle({tx - 7 * s, y + 9 * s}, {tx, y + 15 * s}, {tx, y + 3 * s}, colors.amber)
    } else if(off > span){
      rl.draw.triangle({tx + 7 * s, y + 9 * s}, {tx, y + 3 * s}, {tx, y + 15 * s}, colors.amber)
    } else {
      rl.draw.triangle({tx, y + 19 * s}, {tx + 5 * s, y + 10 * s}, {tx - 5 * s, y + 10 * s}, colors.amber)
    }
  }
  local name = str.upper(checkpoint.name or "")
  local distance = ""
  if(checkpoint.distance != null){
    if(checkpoint.distance >= 1000){
      distance = concat(str.format("%.1f", checkpoint.distance / 1000), " km")
    } else {
      distance = concat(string(to_int(checkpoint.distance / 10 + 0.5) * 10), " m")
    }
  }
  local nw = ui.measure(name, 11, 0.14)
  local dw = ui.measure(distance, 13)
  local gap = if(distance == ""){ 0 } else { 10 * s }
  local x = cx - (nw + gap + dw) / 2
  ui.text(x, y + 33 * s, name, 11, colors.amber, 0.14)
  ui.text(x + nw + gap, y + 31.5 * s, distance, 13, colors.paper)
}

// ------------------------------------------------------------ the map

// the trail around the truck, the truck's nose up: what is behind it
// dim, what is ahead bright, the next checkpoint a ring
local func draw_map(info){
  local trail = info.trail
  if(trail == null or trail.points == null or trail.position == null){
    return
  }
  local s = ui.s
  local r = 76 * s
  local cx = ui.w - 28 * s - r
  local cy = 24 * s + r
  ui.disc(cx, cy, r, colors.ink)
  local points = trail.points
  local count = len(points)
  if(count < 2){
    return
  }
  local index = trail.index
  if(index == null){
    index = to_int((info.progress or 0) * (count - 1))
  }
  local heading = info.heading or 0
  local ch = math.cos(heading)
  local sh = math.sin(heading)
  local px = trail.position.x
  local pz = trail.position.z
  local scale = r / 125          // the map shows 125 m around the truck
  local reach = (r - 5 * s) * (r - 5 * s)
  local buf = state.points
  // runs of points inside the circle, every fourth point of the trail,
  // from a way behind the truck to a longer way ahead
  local func run(from, to, color, thick){
    local n = 0
    for(local i = from; i <= to; i = i + 4){
      local p = points[i]
      local dx = p.x - px
      local dz = p.z - pz
      // ahead is up; the truck's left (cos, -sin) is the picture's left
      local mx = -(dx * ch - dz * sh) * scale
      local my = -(dx * sh + dz * ch) * scale
      if(mx * mx + my * my < reach and n < MAP_POINTS){
        buf[n].x = cx + mx
        buf[n].y = cy + my
        n = n + 1
      } else {
        if(n > 1){
          rl.draw.spline_linear(buf:slice(0, n), thick, color)
        }
        n = 0
      }
    }
    if(n > 1){
      rl.draw.spline_linear(buf:slice(0, n), thick, color)
    }
  }
  local from = math.max(0, index - 76)
  local to = math.min(count - 1, index + 152)
  if(index - from >= 4){
    run(from + (index - from) % 4, index, colors.faint, 2 * s)
  }
  if(to - index >= 4){
    run(index, to, colors.paper, 2.5 * s)
  }
  // the next checkpoint: where it is, or at the rim the way it lies
  local checkpoints = trail.checkpoints
  local next = trail.next
  if(next == null and info.checkpoint != null){
    next = info.checkpoint.index
  }
  if(checkpoints != null and next != null and checkpoints[next] != null){
    local c = checkpoints[next]
    local dx = c.x - px
    local dz = c.z - pz
    local mx = -(dx * ch - dz * sh) * scale
    local my = -(dx * sh + dz * ch) * scale
    local d = math.sqrt(mx * mx + my * my)
    local edge = r - 7 * s
    if(d > edge){
      mx = mx / d * edge
      my = my / d * edge
      rl.draw.circle_v({cx + mx, cy + my}, 3.5 * s, colors.amber)
    } else {
      rl.draw.ring({cx + mx, cy + my}, 4 * s, 6 * s, 0, 360, 20, colors.amber)
    }
  }
  // north, on the rim
  local nx = cx + sh * (r - 9 * s)
  local ny = cy - ch * (r - 9 * s)
  ui.text_center(nx, ny - 5.5 * s, "N", 10, colors.dim)
  // the truck
  rl.draw.triangle({cx, cy - 8 * s}, {cx - 5.5 * s, cy + 6 * s}, {cx + 5.5 * s, cy + 6 * s}, colors.amber)
}

// ------------------------------------------------------------ exploring

// where the truck is while exploring, top left: the trail's (or the
// place's) name, the camps found of all there are, and the repairs while
// they are made at a camp
local func draw_place(info){
  local s = ui.s
  local x = 28 * s
  local y = 24 * s
  local repairing = info.repair != null
  local h = if(repairing){ 92 } else { 66 }
  ui.panel(x - 8 * s, y - 8 * s, 248 * s, h * s + 4 * s)
  ui.label(x + 4 * s, y + 1 * s, "exploring", 8, colors.amber)
  local name = info.place
  if(name == null){
    ui.text(x + 4 * s, y + 13 * s, "Off the trail", 19, colors.dim)
  } else {
    // (a long name smaller, so that it fits)
    local size = 19
    for(ui.measure(name, size) > 222 * s and size > 12){
      size = size - 1
    }
    ui.text(x + 4 * s, y + 13 * s, name, size, colors.paper)
  }
  local cy = y + 51 * s
  ui.tent(x + 11 * s, cy + 6 * s, 6.5 * s, (info.camps_found or 0) > 0)
  ui.label(x + 24 * s, cy, concat("camps  ", string(info.camps_found or 0), " / ", string(info.camps_total or 0)), 9, colors.dim)
  if(repairing){
    local by = y + 74 * s
    ui.label(x + 4 * s, by - 3 * s, "repairing", 8, colors.green)
    ui.bar(x + 82 * s, by, 140 * s, 3 * s, math.max(0, math.min(1, info.repair)), colors.green)
  }
}

// the trails cut in pieces with their boxes, for the small map: {list,
// of} (worked out again when the game gives other trails)
local network_pieces = null

local func pieces_of(trails){
  if(network_pieces != null and network_pieces.of == trails and network_pieces.count == len(trails)){
    return network_pieces.list
  }
  local list = {}
  for(let local trail in values(trails)){
    local points = trail.points
    local count = len(points)
    local cut = {}
    for(local from = 0; from < count - 1; from = from + 48){
      local to = math.min(count - 1, from + 48)
      local x0 = 1.0e9
      local x1 = -1.0e9
      local z0 = 1.0e9
      local z1 = -1.0e9
      for(local i = from; i <= to; i = i + 1){
        local p = points[i]
        x0 = math.min(x0, p.x)
        x1 = math.max(x1, p.x)
        z0 = math.min(z0, p.z)
        z1 = math.max(z1, p.z)
      }
      append(cut, {from: from, to: to, x0: x0, x1: x1, z0: z0, z1: z1})
    }
    append(list, cut)
  }
  network_pieces = {list: list, of: trails, count: len(trails)}
  return list
}

// the small map while exploring: every trail near the truck, the way to
// the marker followed over them, the camps, and the marker itself (at the
// rim when it is further)
local func draw_network(info){
  local network = info.network
  local s = ui.s
  local r = 76 * s
  local cx = ui.w - 28 * s - r
  local cy = 24 * s + r
  ui.disc(cx, cy, r, colors.ink)
  local position = network.position or (info.trail or {}).position
  if(position == null){
    return
  }
  local heading = info.heading or 0
  local ch = math.cos(heading)
  local sh = math.sin(heading)
  local px = position.x
  local pz = position.z
  local scale = r / 150          // 150 m around the truck
  local inner = r - 4 * s
  local reach = inner * inner
  local buf = state.points
  // a point of the land on the map (ahead is up; the truck's left is the
  // picture's left)
  local func at(x, z){
    local dx = x - px
    local dz = z - pz
    return {-(dx * ch - dz * sh) * scale, -(dx * sh + dz * ch) * scale}
  }
  // a line through points from..to, every `step`, in runs inside the disc
  local func run(points, from, to, step, thick, color){
    local n = 0
    local i = from
    local last = false
    for(not last){
      if(i >= to){
        i = to
        last = true
      }
      local p = points[i]
      local q = at(p.x, p.z)
      if(q[0] * q[0] + q[1] * q[1] < reach and n < MAP_POINTS){
        buf[n].x = cx + q[0]
        buf[n].y = cy + q[1]
        n = n + 1
      } else {
        if(n > 1){
          rl.draw.spline_linear(buf:slice(0, n), thick, color)
        }
        n = 0
      }
      i = i + step
    }
    if(n > 1){
      rl.draw.spline_linear(buf:slice(0, n), thick, color)
    }
  }
  local trails = network.trails or {}
  local list = pieces_of(trails)
  local near = 170
  for(local t = 0; t < len(trails); t = t + 1){
    local points = trails[t].points
    local color = if(trails[t].kind == "main"){ {236, 204, 150, 220} } else { {242, 234, 216, 190} }
    for(let local piece in values(list[t])){
      if(piece.x1 > px - near and piece.x0 < px + near and piece.z1 > pz - near and piece.z0 < pz + near){
        run(points, piece.from, piece.to, 2, 2 * s, color)
      }
    }
  }
  local route = network.route
  if(route != null and len(route) > 1){
    run(route, 0, len(route) - 1, 2, 3 * s, colors.amber)
  }
  // the camps in reach
  for(let local c in values(network.camps or {})){
    local q = at(c.x, c.z)
    if(q[0] * q[0] + q[1] * q[1] < (inner - 8 * s) * (inner - 8 * s)){
      ui.tent(cx + q[0], cy + q[1] + 3 * s, 4.5 * s, c.found == true)
    }
  }
  // the markers: the one followed a pin, at the rim when it is further
  local markers = network.markers or {}
  for(local i = 0; i < len(markers); i = i + 1){
    local p = markers[i]
    local q = at(p.x, p.z)
    local d = math.sqrt(q[0] * q[0] + q[1] * q[1])
    local followed = network.target == i
    local edge = r - 8 * s
    if(d > edge){
      if(followed){
        rl.draw.circle_v({cx + q[0] / d * edge, cy + q[1] / d * edge}, 4 * s, colors.amber)
      }
    } else if(followed){
      ui.pin(cx + q[0], cy + q[1], 4.5 * s, null, colors.amber)
    } else {
      rl.draw.circle_v({cx + q[0], cy + q[1]}, 3 * s, colors.ink_solid)
      rl.draw.circle_v({cx + q[0], cy + q[1]}, 2 * s, colors.paper)
    }
  }
  // north, on the rim
  local nx = cx + sh * (r - 9 * s)
  local ny = cy - ch * (r - 9 * s)
  ui.text_center(nx, ny - 5.5 * s, "N", 10, colors.dim)
  rl.draw.triangle({cx, cy - 8 * s}, {cx - 5.5 * s, cy + 6 * s}, {cx + 5.5 * s, cy + 6 * s}, colors.amber)
}

// ------------------------------------------------------------ words

local message_colors = {
  info: colors.paper, good: colors.green, warn: colors.amber, bad: colors.red,
  checkpoint: colors.amber,
}

local func draw_words(info, dt){
  local s = ui.s
  local cx = ui.w / 2
  local y = 104 * s
  // the title of a hard stretch, as the truck drives into it
  local name = null
  if(info.section != null){
    name = info.section.name
  }
  if(name != state.section_name){
    state.section_name = name
    if(name != null){
      show_title(name)
    }
  }
  local card = state.section
  if(card != null){
    card.age = card.age + dt
    local life = card.life
    if(card.age > life){
      state.section = null
    } else {
      local a = math.min(1, card.age / 0.35) * math.min(1, (life - card.age) / 0.6)
      local text = str.upper(card.name)
      local w = ui.measure(text, 24, 0.2)
      local color = ui.with_alpha(colors.paper, a)
      // (the lines open outward as it comes)
      local open = (36 + 28 * math.min(1, card.age / 0.5)) * s
      ui.band(cx, y - 8 * s, w + 2 * open + 120 * s, 44 * s, 130 * a)
      ui.text(cx - w / 2 + 2 * s, y + 2 * s, text, 24, ui.with_alpha(colors.shadow, a), 0.2)
      ui.text(cx - w / 2, y, text, 24, color, 0.2)
      rl.draw.line_ex({cx - w / 2 - open, y + 13 * s}, {cx - w / 2 - 14 * s, y + 13 * s}, 1.5 * s, ui.with_alpha(colors.amber, a))
      rl.draw.line_ex({cx + w / 2 + 14 * s, y + 13 * s}, {cx + w / 2 + open, y + 13 * s}, 1.5 * s, ui.with_alpha(colors.amber, a))
      y = y + 40 * s
    }
  }
  // the messages, the newest lowest
  local keep = {}
  for(let local message in values(state.messages)){
    message.age = message.age + dt
    if(message.age < message.life){
      append(keep, message)
    }
  }
  state.messages = keep
  for(let local message in values(keep)){
    local a = math.min(1, message.age / 0.2) * math.min(1, (message.life - message.age) / 0.5)
    local w = ui.measure(message.text, 16)
    local color = message_colors[message.kind] or colors.paper
    rl.draw.rectangle_rounded({cx - w / 2 - 14 * s, y - 3 * s, w + 28 * s, 26 * s}, 0.5, 6, ui.with_alpha(colors.ink, a))
    ui.text(cx - w / 2, y + 1.5 * s, message.text, 16, ui.with_alpha(color, a))
    y = y + 31 * s
  }
  // how to get back on the trail, when that is what is needed
  local hold = math.max(0, math.min(1, info.recover_hold or 0))
  if(info.recover or hold > 0.02){
    local text = info.recover_text or "hold to recover onto the trail"
    local w = ui.measure(text, 14)
    local kw = 22 * s
    local x = cx - (kw + 8 * s + w) / 2
    local hy = ui.h - 190 * s
    local bx = x - 12 * s
    local bw = kw + w + 32 * s
    rl.draw.rectangle_rounded({bx, hy - 6 * s, bw, 34 * s}, 0.5, 6, colors.ink)
    ui.key_cap(x, hy, "R", 13)
    ui.text(x + kw + 8 * s, hy + 3.5 * s, text, 14, colors.paper)
    // (the key held: a line that fills under the words)
    if(hold > 0.02){
      rl.draw.rectangle_rec({bx + 14 * s, hy + 24 * s, (bw - 28 * s) * hold, 2 * s}, colors.amber)
    }
  }
  if(info.debug and info.fps != null){
    ui.text_center(cx, ui.h - 18 * s, concat(string(to_int(info.fps)), " fps"), 10, colors.dim)
  }
}

// draw(info: Info): the instruments, over the finished picture (inside
// rl.drawing{ }, after the scene is presented)
func m.draw(info){
  info = info or {}
  local dt = rl.frame_time
  ui.begin()
  // (the shapes first and all the words after them: see ui.hold)
  ui.hold()
  draw_drive(info)
  draw_stance(info)
  if(info.mode == "explore"){
    draw_place(info)
  } else {
    draw_clock(info)
  }
  draw_way(info)
  if(info.network != null){
    draw_network(info)
  } else {
    draw_map(info)
  }
  draw_words(info, dt)
  ui.release()
}

return m
