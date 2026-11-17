extension "kernel/syntax"
// studio/units/sampler: recordings played from the keys. A zone is a
// recording with the note it was made at and the keys and velocities it
// answers to; a note plays the zone it falls in, faster or slower by how
// far it is from the zone's own note. One zone over all keys is a simple
// sampler; a zone per drum is a kit; a few zones up the keyboard is a
// multisampled piano.
//
//   local wav = require("studio/wav")
//   local piano = s:track("piano", "sampler", {zones: {
//     {sample: wav.read("c2.wav"), root: 36, high: 47},
//     {sample: wav.read("c4.wav"), root: 60, low: 48, high: 71},
//     {sample: wav.read("c6.wav"), root: 84, low: 72},
//   }, release: 400})
//   piano:note(64, {length: 900})
//   piano.unit:message({zones: {...}})       // other recordings, while it plays
//
// A zone: {sample, root?, low?, high?, low_velocity?, high_velocity?,
// loop_start?, loop_end?, gain?, pan?, tune?}. sample is what
// studio/wav's read gives ({left, right?, frames, rate}; left alone plays
// on both sides) or a buffer of floats at 48 kHz; made shared (as read
// makes them) when the studio plays through a stream. root is the note
// that plays it as recorded (60), low..high the notes (0..127) and
// low_velocity..high_velocity (0..1) it answers to, loop_start..loop_end
// frames that repeat while the key is held (in mode "loop"), tune in
// semitones.
//
// mode "gate" plays while the key is held and then releases, "one shot"
// plays the recording to its end whatever the key does (drums), "loop"
// repeats the zone's loop while the key is held.
local math = require("slang/math")
local param = require("studio/param")
local events = require("studio/events")

kernel {
  struct Sample {
    on: int32,
    stage: int32, // 0 attack, 1 decay and sustain, 2 release
    held: int32,
    looping: int32,
    stereo: int32,
    zone: int32,
    note: double,
    pos: double, // frames into the recording
    inc: double,
    length: double,
    loop_start: double,
    loop_end: double,
    env: double,
    gain: double,
    gl: double,
    gr: double,
    ic1: double,
    ic2: double,
    jc1: double,
    jc2: double,
    age: double,
  }

  // src at a fractional position, cubic (Hermite) between four samples
  local func at(src: float[], n: int, pos: float): float {
    local i = int(floor(pos))
    local f = pos - floor(pos)
    local y0 = src[clamp(i - 1, 0, n - 1)]
    local y1 = src[clamp(i, 0, n - 1)]
    local y2 = src[clamp(i + 1, 0, n - 1)]
    local y3 = src[clamp(i + 2, 0, n - 1)]
    local c1 = 0.5 * (y2 - y0)
    local c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
    local c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
    return ((c3 * f + c2) * f + c1) * f + y1
  }

  // one voice's frames added to l and r; a, b: its recording's sides
  func play(
    l: float[], r: float[], start: int, n: int, v: Sample, a: float[],
    b: float[], p: double[], base: int, sr: double, bend: double
  ){
    local attack = 1.0 / (max(p[base], 0.1) * 0.001 * sr)
    local decay = 1.0 - exp(-1.0 / (max(p[base + 1], 1.0) * 0.001 * sr))
    local sustain = p[base + 2]
    local release = exp(-1.0 / (max(p[base + 3], 1.0) * 0.001 * sr))
    local cut0 = p[base + 8]
    local res = 2.0 - 1.96 * clamp(p[base + 9], 0.0, 1.0)
    local amount = p[base + 10]
    local frames = int(v.length)
    local inc = v.inc * bend
    local g = 0.0
    local stereo = v.stereo != 0
    for(local i = start; i < start + n; i += 1){
      if(v.stage == 0){
        v.env += attack
        if(v.env >= 1.0){
          v.env = 1.0
          v.stage = 1
        }
      } else if(v.stage == 1){
        v.env += (sustain - v.env) * decay
      } else {
        v.env *= release
        if(v.env < 0.0005){
          v.on = 0
          break
        }
      }
      if(v.pos >= v.length - 1.0 or v.pos < 0.0){
        v.on = 0
        break
      }
      local x = at(a, frames, v.pos)
      local y = x
      if(stereo){
        y = at(b, frames, v.pos)
      }
      v.pos += inc
      if(v.looping != 0 and v.stage < 2 and v.pos >= v.loop_end){
        v.pos -= v.loop_end - v.loop_start
      }
      local cut = cut0 + amount * v.env
      if(cut < 1.0){
        // the filter's coefficient, every sixteen samples
        if((i & 15) == 0 or g == 0.0){
          g = tan(
            PI *
              clamp(20.0 * exp2(clamp(cut, 0.0, 1.0) * 10.0), 20.0, sr * 0.45) /
              sr,
          )
        }
        local a1 = 1.0 / (1.0 + g * (g + res))
        local a2 = g * a1
        local a3 = g * a2
        local v3 = x - v.ic2
        local v1 = a1 * v.ic1 + a2 * v3
        local v2 = v.ic2 + a2 * v.ic1 + a3 * v3
        v.ic1 = 2.0 * v1 - v.ic1
        v.ic2 = 2.0 * v2 - v.ic2
        x = v2
        v3 = y - v.jc2
        v1 = a1 * v.jc1 + a2 * v3
        v2 = v.jc2 + a2 * v.jc1 + a3 * v3
        v.jc1 = 2.0 * v1 - v.jc1
        v.jc2 = 2.0 * v2 - v.jc2
        y = v2
      }
      local e = v.env * v.gain
      l[i] += x * e * v.gl
      r[i] += y * e * v.gr
    }
    v.age += float(n)
  }

  func clear(l: float[], r: float[], start: int, n: int){
    for(local i = start; i < start + n; i += 1){
      l[i] = 0.0
      r[i] = 0.0
    }
  }
}

local params = param.set({
  {name: "attack", min: 0.1, max: 4000.0, default: 1.0, unit: "ms", curve: 3.0},
  {
    name: "decay", min: 1.0, max: 8000.0, default: 300.0, unit: "ms", curve: 3.0
  },
  {name: "sustain", min: 0.0, max: 1.0, default: 1.0},
  {
    name: "release", min: 1.0, max: 8000.0, default: 120.0, unit: "ms",
    curve: 3.0
  },
  {name: "gain", min: 0.0, max: 4.0, default: 1.0, curve: 2.0},
  {name: "pan", min: -1.0, max: 1.0, default: 0.0, bipolar: true},
  {
    name: "tune", min: -24.0, max: 24.0, default: 0.0, unit: "st", step: 1.0,
    bipolar: true
  },
  {
    name: "fine", min: -100.0, max: 100.0, default: 0.0, unit: "ct",
    bipolar: true
  },
  {name: "cutoff", min: 0.0, max: 1.0, default: 1.0},
  {name: "res", min: 0.0, max: 1.0, default: 0.1},
  {name: "env", min: -1.0, max: 1.0, default: 0.0, bipolar: true},
  {name: "velocity", min: 0.0, max: 1.0, default: 0.8},
  {name: "start", min: 0.0, max: 1.0, default: 0.0},
  {name: "mode", labels: {"gate", "one shot", "loop"}, default: "gate"},
})
local P = params.index

// zones as the unit keeps them: every field there, the recording as its
// buffers
local func read_zones(list, rate){
  local zones = {}
  for(local i = 0; i < len(list or {}); i = i + 1){
    local z = list[i]
    local sample = z.sample
    if(sample == null){
      raise(error.new(
        error.kinds.argument,
        "studio: a sampler's zone needs a sample",
      ))
    }
    local left = sample
    local right = null
    local frames = null
    local own_rate = 48000
    if(type(sample) == "table"){
      left = sample.left
      right = sample.right
      frames = sample.frames
      own_rate = sample.rate or 48000
    }
    frames = math.min(frames or len(left), len(left))
    zones[i] = {
      left: left,
      right: right,
      frames: frames,
      // frames of the recording per frame of the engine, at its own note
      speed: own_rate / rate,
      root: z.root or 60,
      low: z.low or 0,
      high: z.high or 127,
      low_velocity: z.low_velocity or 0.0,
      high_velocity: z.high_velocity or 1.0,
      loop_start: z.loop_start or 0,
      loop_end: math.min(z.loop_end or frames, frames),
      gain: z.gain or 1.0,
      pan: z.pan or 0.0,
      tune: z.tune or 0.0,
    }
  }
  return zones
}

local func new(ctx){
  local sr = ctx.sample_rate * 1.0
  local p = ctx.params
  local base = ctx.base
  local count = ctx.options.voices or 16
  local voices = Sample:array(count)
  local views = {}
  for(local i = 0; i < count; i = i + 1){
    views[i] = voices[i]
  }
  local zones = read_zones(ctx.options.zones, sr)
  local bend = 1.0
  local pedal = false
  local sounding = 0

  local func note_on(note, vel){
    for(local z = 0; z < len(zones); z = z + 1){
      local zone = zones[z]
      if(note < zone.low or note > zone.high or vel < zone.low_velocity or
        vel > zone.high_velocity or zone.frames < 2){
        continue
      }
      // a free voice, else the one that has sounded longest
      local pick = -1
      local oldest = 0
      for(local i = 0; i < count; i = i + 1){
        local v = views[i]
        if(v.on == 0){
          pick = i
          break
        }
        if(v.age > views[oldest].age){
          oldest = i
        }
      }
      if(pick < 0){
        pick = oldest
      }
      local v = views[pick]
      local mode = to_int(p[base + P.mode])
      local semis = note - zone.root + zone.tune + p[base + P.tune] +
        p[base + P.fine] / 100
      local sense = p[base + P.velocity]
      local pan = math.clamp(zone.pan + p[base + P.pan], -1.0, 1.0)
      v.on = 1
      v.stage = 0
      v.held = if(mode == 1){ 2 } else { 0 }
      v.looping = if(mode == 2 and zone.loop_end > zone.loop_start + 1){ 1 } else { 0 }
      v.stereo = if(zone.right != null){ 1 } else { 0 }
      v.zone = z
      v.note = note
      v.pos = p[base + P.start] * (zone.frames - 2)
      v.inc = zone.speed * math.exp(math.log(2) * semis / 12)
      v.length = zone.frames
      v.loop_start = zone.loop_start
      v.loop_end = zone.loop_end
      v.env = 0.0
      v.gain = zone.gain * p[base + P.gain] * (1.0 - sense + sense * vel)
      v.gl = math.min(1.0, 1.0 - pan)
      v.gr = math.min(1.0, 1.0 + pan)
      v.ic1 = 0.0
      v.ic2 = 0.0
      v.jc1 = 0.0
      v.jc2 = 0.0
      v.age = 0.0
    }
  }

  local func let_go(v){
    if(v.stage < 2){
      v.stage = 2
    }
    v.held = 0
  }

  return {
    note_on: note_on,
    note_off: func(note){
      for(local i = 0; i < count; i = i + 1){
        local v = views[i]
        // (held 2: a one shot, which no key ends)
        if(v.on != 0 and v.note == note and v.stage < 2 and v.held == 0){
          if(pedal){
            v.held = 1
          } else {
            let_go(v)
          }
        }
      }
    },
    control: func(which, value){
      if(which == events.controls.BEND){
        bend = math.exp(math.log(2) * value * 2 / 12)
      } else if(which == events.controls.SUSTAIN){
        pedal = value >= 0.5
        if(not pedal){
          for(local i = 0; i < count; i = i + 1){
            if(views[i].on != 0 and views[i].held == 1){
              let_go(views[i])
            }
          }
        }
      }
    },
    hush: func(){
      for(local i = 0; i < count; i = i + 1){
        if(views[i].on != 0){
          let_go(views[i])
        }
      }
    },
    panic: func(){
      for(local i = 0; i < count; i = i + 1){
        views[i].on = 0
      }
    },
    message: func(m){
      if(m.zones != null){
        for(local i = 0; i < count; i = i + 1){
          views[i].on = 0
        }
        zones = read_zones(m.zones, sr)
      }
    },
    voices: func(){
      return sounding
    },
    render: func(l, r, start, n){
      clear(l, r, start, n)
      sounding = 0
      for(local i = 0; i < count; i = i + 1){
        local v = views[i]
        if(v.on != 0){
          local zone = zones[v.zone]
          play(
            l, r, start, n, v, zone.left, zone.right or zone.left, p, base, sr,
            bend
          )
          if(v.on != 0){
            sounding = sounding + 1
          }
        }
      }
    },
  }
}

return {
  name: "sampler",
  kind: "instrument",
  params: params,
  options: {"voices", "zones"},
  new: new,
}
