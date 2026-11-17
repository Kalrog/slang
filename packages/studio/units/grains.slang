extension "kernel/syntax"
// studio/units/grains: a granular synthesizer (the one of
// examples/granular): every key held is a voice that scatters short
// grains of a recording, each read at its own place, pitch, direction and
// pan, dozens a second. The recording is a sample, or in live mode the
// last seconds a microphone heard.
//
//   local wav = require("studio/wav")
//   local cloud = s:track("cloud", "grains", {
//     sample: wav.read("take.wav", {mono: true, rate: 48000}),
//     size: 180, density: 30, spray: 120,
//   })
//   cloud:note(60)                      // 60 plays the recording at its pitch
//
//   // what a microphone hears, as it hears it:
//   s:track("air", "grains", {microphone: true, mode: "live"})
//
// Options: `sample` (what studio/wav's read gives, or a buffer of floats;
// mono, at the studio's rate), `microphone` (true, or part of a device's
// name: the unit listens, for live mode and for recording), `seconds`
// (how long a recording may be without a sample given: 30), `view` (a
// shared buffer of two floats per grain, which gets where each grain
// reads, 0..1, and how loud it is: for drawing).
//
// The knobs glide to where they are set (50 ms), so a jump does not click.
// `record` 1 records the microphone into the sample (from its start) until
// it is 0 again; `freeze` stops live mode listening and scan moving. Four
// parameters are the unit's to write, read with unit:effective(name):
// `length` (frames of the recording), `level` (the microphone's peak),
// `grains` (how many sound) and `scan_at` (where scan has moved the
// position, 0..1).
local kernel = require("kernel")
local math = require("slang/math")
local param = require("studio/param")
local events = require("studio/events")

local MAXG = 128 // grains at once
local NK = 14 // the knobs that glide

kernel {
  struct Grain {
    on: int32,
    voice: int32,
    age: int32,
    dur: int32,
    pos: double,
    inc: double,
    amp: float,
    pl: float,
    pr: float,
  }

  struct Key {
    note: double,
    vel: double,
    gate: int32,
    held: int32,
    env: double,
    timer: double,
  }

  struct Cloud {
    seed: int64 = 22222,
    scan: double,
    l1: double,
    l2: double,
    r1: double,
    r2: double,
    primed: int32,
    gain: double,
    bend: double = 1,
  }

  // 0 .. 1
  local func rand(st: Cloud): float {
    st.seed = (st.seed * 6364136223846793005 + 1442695040888963407) &
      9223372036854775807
    return float((st.seed >> 20) & 1048575) / 1048576.0
  }

  // the grain's window at t (0..1): rises to its peak at skew, then falls,
  // smoothly at both ends
  local func window(t: float, skew: float): float {
    local x = 0.0
    if(t < skew){
      x = t / skew
    } else {
      x = (1.0 - t) / (1.0 - skew)
    }
    return x * x * (3.0 - 2.0 * x)
  }

  // src at a fractional position, cubic (Hermite) between four samples;
  // positions wrap around n
  local func at(src: float[], n: int, pos: float): float {
    local i = int(floor(pos))
    local f = pos - floor(pos)
    local y0 = src[(i - 1) % n]
    local y1 = src[i % n]
    local y2 = src[(i + 1) % n]
    local y3 = src[(i + 2) % n]
    local c1 = 0.5 * (y2 - y0)
    local c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
    local c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
    return ((c3 * f + c2) * f + c1) * f + y1
  }

  // frames start .. start + n - 1 of l and r. src holds the sound: the
  // recording (its first `length` frames), or in live mode the ring whose
  // newest frame is just before head. sm: the knobs as the sound uses
  // them. Returns the grains sounding.
  func render(
    l: float[], r: float[], start: int, n: int, src: float[], length: int,
    live: bool, head: int, grains: Grain[], keys: Key[], st: Cloud, p: double[],
    base: int, sm: double[], view: float[], sr: double
  ): int {
    // each knob glides to where it was set (50 ms)
    local glide = 1.0 - exp(-float(n) / (sr * 0.05))
    if(st.primed == 0){
      st.primed = 1
      for(local k = 0; k < len(sm); k += 1){
        sm[k] = p[base + k]
      }
      st.gain = sm[13]
    }
    for(local k = 0; k < len(sm); k += 1){
      sm[k] += (p[base + k] - sm[k]) * glide
    }
    local pos = sm[0]
    local spray = sm[1] * 0.001 * 0.5 * sr
    local dur = int(sm[2] * 0.001 * sr)
    local interval = sr / sm[3]
    local pitch = sm[4]
    local detune = sm[5]
    local reverse = sm[6]
    local skew = sm[7]
    local scan_speed = sm[8]
    local stereo = sm[9]
    local attack_step = 1.0 / (sm[11] * 0.001 * sr)
    local release_step = 1.0 / (sm[12] * 0.001 * sr)
    local gain_to = sm[13]
    local frozen = p[base + 15] >= 0.5
    // the filter (a state variable filter, topology preserving): its
    // cutoff from 40 Hz to 20 kHz
    local hz = 40.0 * pow(2.0, sm[10] * 9.0)
    local g = tan(PI * min(hz, sr * 0.45) / sr)
    local k = 1.4
    local a1 = 1.0 / (1.0 + g * (g + k))
    local a2 = g * a1
    local a3 = g * a2
    // more grains overlapping: each one quieter
    local overlap = sm[3] * sm[2] * 0.001
    local norm = 1.0 / sqrt(max(1.0, overlap))
    if(live){
      st.scan = 0.0
    }
    for(local i = 0; i < n; i += 1){
      if(not live and length > 0 and not frozen){
        st.scan = (st.scan + scan_speed / float(length)) % 1.0
      }
      // the voices: envelopes, and grains when it is time
      for(local v = 0; v < len(keys); v += 1){
        local vo = keys[v]
        if(vo.gate > 0){
          vo.env = min(1.0, vo.env + attack_step)
        } else {
          vo.env = max(0.0, vo.env - release_step)
        }
        if(vo.env <= 0.0){
          continue
        }
        vo.timer -= 1.0
        if(vo.timer > 0.0 or length < 2048){
          continue
        }
        // a little jitter, so that grains do not buzz at the density
        vo.timer += interval * (0.75 + 0.5 * rand(st))
        local slot = -1
        for(local s = 0; s < len(grains) and slot < 0; s += 1){
          if(grains[s].on == 0){
            slot = s
          }
        }
        if(slot < 0){
          continue
        }
        local gr = grains[slot]
        local semis = vo.note - 60.0 + pitch + detune * (rand(st) * 2.0 - 1.0)
        local inc = pow(2.0, semis / 12.0) * st.bend
        if(rand(st) < reverse){
          inc = -inc
        }
        local from = 0.0
        local d = float(dur)
        if(live){
          // position 1 is now, 0 the oldest the ring holds (silence
          // until the microphone has filled it); a grain must never catch
          // up with the head, nor fall off the ring's end. The head moves
          // when the microphone delivers (every 10 ms or so), so a grain
          // starts at least 25 ms behind it.
          local ring = float(len(src))
          local behind = (1.0 - pos) * ring + spray * (rand(st) * 2.0 - 1.0)
          local least = max(0.0, (inc - 1.0) * d) + 0.025 * sr
          local most = ring - abs(inc) * d - 64.0
          behind = clamp(behind, least, max(least, most))
          from = float(head) - behind
        } else {
          from = ((pos + st.scan) % 1.0) * float(length) +
            spray * (rand(st) * 2.0 - 1.0)
          if(inc < 0.0){
            // backwards from the end of its slice
            from += abs(inc) * d
          }
        }
        local side = clamp(0.5 + stereo * (rand(st) - 0.5), 0.0, 1.0)
        gr.on = 1
        gr.voice = v
        gr.age = 0
        gr.dur = max(dur, 16)
        gr.pos = from
        gr.inc = inc
        gr.amp = vo.vel * norm
        gr.pl = cos(side * PI * 0.5)
        gr.pr = sin(side * PI * 0.5)
      }
      // the grains
      local a = 0.0
      local b = 0.0
      for(local s = 0; s < len(grains); s += 1){
        local gr = grains[s]
        if(gr.on == 0){
          continue
        }
        local e = window(float(gr.age) / float(gr.dur), skew) * gr.amp *
          keys[gr.voice].env
        local x = 0.0
        if(live){
          x = at(src, len(src), gr.pos)
        } else {
          x = at(src, length, gr.pos)
        }
        a += x * e * gr.pl
        b += x * e * gr.pr
        gr.pos += gr.inc
        gr.age += 1
        if(gr.age >= gr.dur){
          gr.on = 0
        }
      }
      // the filter
      local v3 = a - st.l2
      local v1 = a1 * st.l1 + a2 * v3
      local v2 = st.l2 + a2 * st.l1 + a3 * v3
      st.l1 = 2.0 * v1 - st.l1
      st.l2 = 2.0 * v2 - st.l2
      a = v2
      v3 = b - st.r2
      v1 = a1 * st.r1 + a2 * v3
      v2 = st.r2 + a2 * st.r1 + a3 * v3
      st.r1 = 2.0 * v1 - st.r1
      st.r2 = 2.0 * v2 - st.r2
      b = v2
      // the gain ramps across the segment, so turning it does not click
      local gain = st.gain + (gain_to - st.gain) * float(i + 1) / float(n)
      l[start + i] = tanh(a * gain)
      r[start + i] = tanh(b * gain)
    }
    st.gain = gain_to
    // what a window draws: where each grain reads, and how loud
    local sounding = 0
    local first = float(head - len(src))
    local show = len(view) >= len(grains) * 2
    for(local s = 0; s < len(grains); s += 1){
      local gr = grains[s]
      if(gr.on == 0){
        if(show){
          view[s * 2 + 1] = 0.0
        }
        continue
      }
      sounding += 1
      if(show){
        local x = 0.0
        if(live){
          x = (gr.pos - first) / float(len(src))
        } else {
          x = (gr.pos % float(length)) / float(length)
        }
        view[s * 2] = clamp(x, 0.0, 1.0)
        view[s * 2 + 1] = gr.amp * keys[gr.voice].env *
          window(float(gr.age) / float(gr.dur), skew)
      }
    }
    return sounding
  }

  // n frames of src into the ring dst (of dst_len frames), from at on
  func capture(dst: float[], dst_len: int, at: int, src: float[], n: int){
    for(local i = 0; i < n; i += 1){
      dst[(at + i) % dst_len] = src[i]
    }
  }
}

local params = param.set({
  {name: "position", min: 0.0, max: 1.0, default: 0.3},
  {name: "spray", min: 0.0, max: 1000.0, default: 80.0, unit: "ms"},
  {name: "size", min: 5.0, max: 1000.0, default: 120.0, unit: "ms", curve: 2.0},
  {
    name: "density", min: 1.0, max: 200.0, default: 24.0, unit: "/s", curve: 2.0
  },
  {
    name: "pitch", min: -24.0, max: 24.0, default: 0.0, unit: "st", step: 1.0,
    bipolar: true
  },
  {name: "detune", min: 0.0, max: 12.0, default: 0.1, unit: "st", curve: 2.0},
  {name: "reverse", min: 0.0, max: 1.0, default: 0.0},
  {name: "skew", min: 0.02, max: 0.98, default: 0.5},
  {name: "scan", min: -2.0, max: 2.0, default: 0.0, unit: "x", bipolar: true},
  {name: "stereo", min: 0.0, max: 1.0, default: 0.5},
  {name: "cutoff", min: 0.0, max: 1.0, default: 0.85},
  {
    name: "attack", min: 1.0, max: 4000.0, default: 50.0, unit: "ms", curve: 3.0
  },
  {
    name: "release", min: 10.0, max: 8000.0, default: 800.0, unit: "ms",
    curve: 3.0
  },
  {name: "gain", min: 0.0, max: 3.0, default: 1.5},
  {name: "mode", labels: {"sample", "live"}, default: "sample"},
  {name: "freeze", kind: "switch", default: 0},
  {name: "record", kind: "switch", default: 0},
  // the unit's own to write
  {name: "length", min: 0.0, max: 1.0e9, default: 0.0, kind: "meter"},
  {name: "level", min: 0.0, max: 4.0, default: 0.0, kind: "meter"},
  {name: "grains", min: 0.0, max: 1024.0, default: 0.0, kind: "meter"},
  {name: "scan_at", min: 0.0, max: 1.0, default: 0.0, kind: "meter"},
})
local P = params.index

local func new(ctx){
  local sr = ctx.sample_rate * 1.0
  local p = ctx.params
  local base = ctx.base
  local options = ctx.options
  local count = options.voices or 8
  local grains = Grain:array(MAXG)
  local keys = Key:array(count)
  local views = {}
  for(local i = 0; i < count; i = i + 1){
    views[i] = keys[i]
  }
  local st = Cloud:new()
  local sm = kernel.double:array(NK)
  local view = options.view or kernel.float:array(1)
  // the recording: the program's, or the unit's own to record into
  local sample = null
  local length = 0
  local func take(s){
    if(type(s) == "table"){
      sample = s.left
      length = math.min(s.frames or len(s.left), len(s.left))
    } else {
      sample = s
      length = len(s)
    }
  }
  if(options.sample != null){
    take(options.sample)
  } else {
    sample = kernel.float:array(to_int(sr * (options.seconds or 30)))
  }
  // the microphone: one given (in this isolate), or opened by name
  local input = options.input
  if(input == null and options.microphone != null and
    options.microphone != false){
    local device = options.microphone
    if(device == true){
      device = null
    }
    input = try { require(
      "microphone",
    ).open({
      device: device,
      sample_rate: ctx.sample_rate,
      buffer: ctx.sample_rate,
    }) } catch { null }
  }
  local live = null
  local live_len = to_int(sr * 6)
  local live_head = 0
  local tmp = null
  if(input != null){
    live = kernel.float:array(live_len)
    tmp = kernel.float:array(4096)
  }
  local recording = false
  local rec_at = 0
  local pedal = false
  local sounding = 0

  // the microphone's frames since the last segment into the live ring,
  // and into the recording while `record` is 1
  local func listen(){
    local want = p[base + P.record] >= 0.5
    if(want and not recording){
      recording = true
      rec_at = 0
      length = 0
    } else if(not want and recording){
      recording = false
    }
    if(input == null){
      return null
    }
    for(true){
      local n = input:read(tmp)
      if(n == 0){
        break
      }
      // frozen: the live ring keeps what it has
      if(p[base + P.freeze] < 0.5){
        capture(live, live_len, live_head % live_len, tmp, n)
        live_head = live_head + n
      }
      if(recording){
        local room = math.min(n, len(sample) - rec_at)
        capture(sample, len(sample), rec_at, tmp, room)
        rec_at = rec_at + room
        length = rec_at
        if(rec_at >= len(sample)){
          // full
          recording = false
        }
      }
      if(n < len(tmp)){
        break
      }
    }
    p[base + P.level] = input.level
  }

  local func let_go(v){
    v.gate = 0
    v.held = 0
  }

  return {
    note_on: func(note, vel){
      // the key's own voice again, a silent one, else the quietest
      local pick = -1
      local quiet = 0
      for(local i = 0; i < count; i = i + 1){
        local v = views[i]
        if(v.gate > 0 and v.note == note){
          pick = i
          break
        }
        if(pick < 0 and v.gate == 0 and v.env <= 0.0){
          pick = i
        }
        if(v.env < views[quiet].env){
          quiet = i
        }
      }
      if(pick < 0){
        pick = quiet
      }
      local v = views[pick]
      v.note = note
      v.vel = vel
      v.gate = 1
      v.held = 0
      v.timer = 0.0
    },
    note_off: func(note){
      for(local i = 0; i < count; i = i + 1){
        local v = views[i]
        if(v.gate > 0 and v.note == note and v.held == 0){
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
        st.bend = math.exp(math.log(2) * value * 2 / 12)
      } else if(which == events.controls.SUSTAIN){
        pedal = value >= 0.5
        if(not pedal){
          for(local i = 0; i < count; i = i + 1){
            if(views[i].held != 0){
              let_go(views[i])
            }
          }
        }
      }
    },
    hush: func(){
      for(local i = 0; i < count; i = i + 1){
        let_go(views[i])
      }
    },
    panic: func(){
      for(local i = 0; i < count; i = i + 1){
        let_go(views[i])
        views[i].env = 0.0
      }
      for(local i = 0; i < MAXG; i = i + 1){
        grains[i].on = 0
      }
    },
    message: func(m){
      if(m.sample != null){
        for(local i = 0; i < MAXG; i = i + 1){
          grains[i].on = 0
        }
        take(m.sample)
        st.scan = 0.0
      }
    },
    voices: func(){
      local held = 0
      for(local i = 0; i < count; i = i + 1){
        if(views[i].gate > 0 or views[i].env > 0.0){
          held = held + 1
        }
      }
      return held
    },
    render: func(l, r, start, n){
      listen()
      if(p[base + P.mode] >= 0.5 and live != null){
        sounding = render(
          l, r, start, n, live, math.min(live_head, live_len), true, live_head,
          grains, keys, st, p, base, sm, view, sr
        )
      } else {
        sounding = render(
          l, r, start, n, sample, length, false, 0, grains, keys, st, p, base,
          sm, view, sr
        )
      }
      p[base + P.length] = length
      p[base + P.grains] = sounding
      p[base + P.scan_at] = st.scan
    },
    close: func(){
      if(input != null and options.input == null){
        input:close()
      }
    },
  }
}

return {
  name: "grains",
  kind: "instrument",
  params: params,
  options: {"voices", "sample", "microphone", "input", "seconds", "view"},
  grains: MAXG,
  new: new,
}
