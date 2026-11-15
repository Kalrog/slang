// sound/layers/camp: what a camp sounds like to someone who comes to it:
// the fire in its ring of stones (sound/camp.dsp: embers and a low flame,
// crackling), heard from thirty meters or so, and the pennant on its
// pole flapping in the wind (sound/camp/pennant.dsp), heard from
// fifteen. Each is where it stands for the listener: the fire beside the
// tent, the pennant up its pole across the track (render/markers builds
// them; where they stand is worked out here the same way).
//
// What moves by itself is made in the voice, a block at a time: the
// flame's flutter, the embers' glow, and when the pennant flaps: the
// more wind, the more often and the harder.
local math = require("slang/math")
local kernel = require("kernel")
local listener = require("sound/listener")

local m = {}

m.params = {
  // the fire: its gain on each side, and how near it is (1 beside it, 0
  // at the edge of earshot)
  {"camp_fire_left", 0, 0.15},
  {"camp_fire_right", 0, 0.15},
  {"camp_fire_near", 0, 0.3},
  // the pennant: its gain on each side
  {"camp_flag_left", 0, 0.15},
  {"camp_flag_right", 0, 0.15},
  // the wind at the camp, gusts and all (0 to 1)
  {"camp_wind", 0, 0.25},
}

// ------------------------------------------------------------ the game's side

// how far the fire and the pennant are heard, m
m.FIRE = 32.0
m.PENNANT = 16.0

// half the width of a camp's clearing, m (game/route.CAMP_HALF)
local CLEARING = 4.6

local func smoothstep(a, b, v){
  local t = math.min(math.max((v - a) / (b - a), 0), 1)
  return t * t * (3 - 2 * t)
}

// watcher() -> the layer's state in the main isolate: the camp whose
// fire and pennant were found last, and where they are
func m.watcher(){
  return {camp: null, fire: {x: 0, y: 0, z: 0}, pennant: {x: 0, y: 0, z: 0}}
}

// found(w, camp, land): where the camp's fire and its pennant are, into
// w.fire and w.pennant. render/markers sets a camp up beside the point
// of its trail a little ahead of where the truck stands at it: the tent
// and the fire to the left of the track, the pole to the right. (A camp
// without a trail, in a test: about its own place the same way.)
local func found(w, camp, land){
  local px = camp.x
  local pz = camp.z
  local yaw = camp.yaw or 0
  local half = CLEARING
  if(camp.trail != null){
    local points = camp.trail.points
    local count = len(points)
    local index = math.min(count - 1, camp.at + 5)
    if(camp.at == 0){
      index = math.min(count - 1, 10)
    } else if(camp.at == count - 1){
      index = math.max(0, count - 2)
    }
    local p = points[index]
    local before = points[math.max(0, index - 1)]
    local after = points[math.min(count - 1, index + 1)]
    px = p.x
    pz = p.z
    yaw = math.atan2(after.x - before.x, after.z - before.z)
    half = math.max(p.half or CLEARING, CLEARING)
  }
  // (to the left of the way the trail runs, and along it)
  local lx = math.cos(yaw)
  local lz = -math.sin(yaw)
  local fx = math.sin(yaw)
  local fz = math.cos(yaw)
  local func spot(into, left, ahead, up){
    into.x = px + lx * left + fx * ahead
    into.z = pz + lz * left + fz * ahead
    into.y = (camp.y or 0) + up
    if(land != null){
      into.y = require("game/terrain").height_at(land, into.x, into.z) + up
    }
  }
  spot(w.fire, half - 2.7, -3.0, 0.2)
  // (the pennant flies from its pole's top, away from the track)
  spot(w.pennant, -(half - 0.6) - 0.7, -1.0, 4.3)
}

// watch(w, s, set, send): a frame (s: sound/director's Frame)
func m.watch(w, s, set, send){
  local a = s.around
  if(a == null or s.view == null){
    return
  }
  local near = a.camp
  local camp = null
  if(near != null and s.world != null and s.world.camps != null){
    camp = s.world.camps[near.index]
  }
  if(camp == null){
    set("camp_fire_left", 0)
    set("camp_fire_right", 0)
    set("camp_flag_left", 0)
    set("camp_flag_right", 0)
    return
  }
  if(not same(camp, w.camp)){
    w.camp = camp
    found(w, camp, s.world.land)
  }
  // the fire: quieter with distance as everything is, and gone at FIRE
  local fire = listener.place(s.view, w.fire)
  local heard = 1 - smoothstep(m.FIRE / 2, m.FIRE, fire.distance)
  set("camp_fire_left", fire.left * heard)
  set("camp_fire_right", fire.right * heard)
  set("camp_fire_near", math.min(
    math.max(1 - (fire.distance - 2) / (m.FIRE - 6), 0),
    1,
  ))
  // the pennant
  local flag = listener.place(s.view, w.pennant)
  heard = 1 - smoothstep(m.PENNANT / 2, m.PENNANT, flag.distance)
  set("camp_flag_left", flag.left * heard)
  set("camp_flag_right", flag.right * heard)
  set("camp_wind", a.wind.strength)
}

// ------------------------------------------------------------ the mixer's side

// The camp's levels in the mix. At 1 the fire from five meters is at
// -45 dB re full scale on the world's bus, its loudest cracks some
// 20 dB over that (it is its cracks that are heard, not its level), and
// the pennant in a moderate wind is about as loud; the user turned the
// truck down by ear, and the camp with it.
local FIRE = 0.6
local PENNANT = 0.5
// under this nothing is heard
local QUIET = 0.0005

// voice(ctx) -> {block}: see sound/mixer
func m.voice(ctx){
  local rate = ctx.rate
  local size = ctx.size
  local now = ctx.now
  local slot = ctx.slot
  local func made(program){
    local inst = program:new({sample_rate: rate})
    local p = {
      inst: inst, state: inst.state, ins: {}, outs: {kernel.float:array(size)},
      field: {}
    }
    for(let local c in values(program.controls)){
      p.field[c.label] = c.field
    }
    return p
  }
  local fire = made(require("sound/camp"))
  local pennant = made(require("sound/camp/pennant"))
  local fire_near = fire.field.near
  local fire_wind = fire.field.wind
  local fire_flutter = fire.field.flutter
  local fire_glow = fire.field.glow
  local pennant_flap = pennant.field.flap
  local pennant_hard = pennant.field.hard
  local pennant_wind = pennant.field.wind
  local s_fire_left = slot.camp_fire_left
  local s_fire_right = slot.camp_fire_right
  local s_fire_near = slot.camp_fire_near
  local s_flag_left = slot.camp_flag_left
  local s_flag_right = slot.camp_flag_right
  local s_wind = slot.camp_wind
  // numbers at random, from -1 to 1
  local seed = 18480229
  local func random(){
    seed = (seed * 69069 + 12345) & 0xffffffff
    return seed / 2147483648.0 - 1
  }
  // the flame's flutter (quick: a few times a second) and the embers'
  // glow (slow): noises that forget themselves, about 0
  local flutter = 0.0
  local glow = 0.0
  // the pennant: where it is between two flaps (0 to 1), how its timing
  // wanders, and how many flaps there were
  local between = 0.0
  local wander = 0.0
  local flaps = 0
  local was_fire = {left: 0, right: 0}
  local to_fire = {left: 0, right: 0}
  local was_flag = {left: 0, right: 0}
  local to_flag = {left: 0, right: 0}
  return {
    block: func(n){
      local dt = n / rate
      local wind = now[s_wind]
      to_fire.left = now[s_fire_left] * FIRE
      to_fire.right = now[s_fire_right] * FIRE
      if(to_fire.left + to_fire.right + was_fire.left + was_fire.right >= QUIET){
        local keep = math.exp(-dt / 0.04)
        flutter = flutter * keep + random() * math.sqrt((1 - keep * keep) * 3)
        keep = math.exp(-dt / 1.2)
        glow = glow * keep + random() * math.sqrt((1 - keep * keep) * 3)
        local state = fire.state
        state[fire_near] = now[s_fire_near]
        state[fire_wind] = wind
        state[fire_flutter] = math.max(1 + 0.6 * flutter, 0.1)
        state[fire_glow] = math.max(1 + 0.35 * glow, 0.3)
        fire.inst:compute(n, fire.ins, fire.outs)
        ctx.place(ctx.world, fire.outs[0], was_fire, to_fire, n)
      }
      to_flag.left = now[s_flag_left] * PENNANT
      to_flag.right = now[s_flag_right] * PENNANT
      if(to_flag.left + to_flag.right + was_flag.left + was_flag.right >= QUIET){
        // the flaps: two a second in a breath of wind, nine in a gale,
        // a third sooner or later each time; in still air it hangs
        local keep = math.exp(-dt / 0.5)
        wander = wander * keep + random() * math.sqrt((1 - keep * keep) * 3)
        between = between +
          dt * (2.2 + 7 * wind) * math.max(1 + 0.3 * wander, 0.3)
        local state = pennant.state
        if(between >= 1){
          between = between - 1
          flaps = flaps + 1
          local stirring = math.min(math.max((wind - 0.03) / 0.09, 0), 1)
          state[pennant_flap] = flaps
          state[pennant_hard] = (0.4 + 0.6 * math.abs(random())) * stirring *
            math.min(0.3 + wind, 1)
        }
        state[pennant_wind] = wind
        pennant.inst:compute(n, pennant.ins, pennant.outs)
        ctx.place(ctx.world, pennant.outs[0], was_flag, to_flag, n)
      }
    },
  }
}

return m
