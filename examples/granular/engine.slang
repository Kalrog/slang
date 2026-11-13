// engine: the granular synthesizer's sound. A kernel plays up to MAXG
// grains at once: short windowed slices of a recording, each read at its
// own place, speed, direction and pan, started by the voices (the keys
// held) DENSITY times a second; the sum goes through a lowpass filter and a
// ping-pong delay. The knobs glide to where they are turned (so a jump
// does not click), and two LFOs move them.
//
// engine.new runs in the render isolate of raylib/stream (or in a test, or
// tool/render.slang). Everything it shares with the window lives in shared
// buffers (engine.shared):
//
//   sample  the recording grains are read from (MAXS frames at most)
//   live    the last LIVE frames of the microphone, a ring (live mode)
//   ctl     the knobs the window turns (engine.knobs) and the cells the
//           engine reports in (engine.cells)
//   keys    one slot of four per voice: note, gate, velocity and a serial
//           the window counts up for each new note
//   view    per grain where it reads (0..1 of the waveform shown) and how
//           loud it is, for drawing
//
// The microphone is read in the render isolate every block (128 frames):
// it writes into sample while ctl[RECORD] is 1, and into live always.
extension "kernel/syntax"
local kernel = require("kernel")
local math = require("slang/math")

local engine = {}

engine.RATE = 48000
engine.MAXS = 48000 * 30 // a recording: 30 seconds at most
engine.LIVE = 48000 * 6 // live mode: the last six seconds
engine.MAXG = 128 // grains at once
engine.NV = 8 // voices
engine.ROOT = 60 // the note that plays a recording at its own pitch

// the knobs: cell, range, start value, how the window labels it
engine.knobs = {
  {name: "position", cell: 0, min: 0.0, max: 1.0, init: 0.3, unit: ""},
  {name: "spray", cell: 1, min: 0.0, max: 1.0, init: 0.08, unit: "s"},
  {
    name: "size", cell: 2, min: 5.0, max: 1000.0, init: 120.0, unit: "ms",
    curve: 2.0
  },
  {
    name: "density", cell: 3, min: 1.0, max: 200.0, init: 24.0, unit: "/s",
    curve: 2.0
  },
  {
    name: "pitch", cell: 4, min: -24.0, max: 24.0, init: 0.0, unit: "st",
    step: 1.0, bipolar: true
  },
  {
    name: "detune", cell: 5, min: 0.0, max: 12.0, init: 0.1, unit: "st",
    curve: 2.0
  },
  {name: "reverse", cell: 6, min: 0.0, max: 1.0, init: 0.0, unit: ""},
  {name: "skew", cell: 7, min: 0.02, max: 0.98, init: 0.5, unit: ""},
  {
    name: "scan", cell: 8, min: -2.0, max: 2.0, init: 0.0, unit: "x",
    bipolar: true
  },
  {name: "stereo", cell: 9, min: 0.0, max: 1.0, init: 0.5, unit: ""},
  {name: "cutoff", cell: 10, min: 0.0, max: 1.0, init: 0.85, unit: ""},
  {name: "delay", cell: 11, min: 0.02, max: 1.5, init: 0.38, unit: "s"},
  {name: "feedback", cell: 12, min: 0.0, max: 0.95, init: 0.45, unit: ""},
  {name: "mix", cell: 13, min: 0.0, max: 1.0, init: 0.3, unit: ""},
  {
    name: "attack", cell: 14, min: 0.001, max: 4.0, init: 0.05, unit: "s",
    curve: 3.0
  },
  {
    name: "release", cell: 15, min: 0.01, max: 8.0, init: 0.8, unit: "s",
    curve: 3.0
  },
  {name: "gain", cell: 16, min: 0.0, max: 3.0, init: 1.5, unit: ""},
}
engine.knob = {}
for(let local k in values(engine.knobs)){
  engine.knob[k.name] = k
}

// a knob's value at slider position t (0..1), through its curve: from_t
// as it is, value_of rounded to its step
func engine.from_t(k, t){
  return k.min + (k.max - k.min) * t ^ (k.curve or 1.0)
}

func engine.value_of(k, t){
  local v = engine.from_t(k, t)
  if(k.step != null){
    v = math.round(v / k.step) * k.step
  }
  return v
}

// where the slider of k is for the value v
func engine.t_of(k, v){
  local t = math.clamp((v - k.min) / (k.max - k.min), 0.0, 1.0)
  return t ^ (1.0 / (k.curve or 1.0))
}

// The LFOs: each moves one knob (dest: its cell, -1 none) up and down
// around where the slider is; depth 1 sweeps the slider's whole range.
// The engine writes where the LFO is now (-1..1) into out.
engine.SHAPES = {"sine", "triangle", "ramp", "square", "random", "drift"}
engine.lfos = {}
for(local o = 0; o < 2; o = o + 1){
  local base = 40 + o * 8
  append(engine.lfos, {
    rate: {
      name: "rate", cell: base, min: 0.02, max: 20.0,
      init: if(o == 0){ 0.25 } else { 0.08 }, unit: "Hz", curve: 3.0
    },
    depth: {
      name: "depth", cell: base + 2, min: -1.0, max: 1.0, init: 0.0, unit: "",
      bipolar: true
    },
    shape: base + 1,
    dest: base + 3,
    out: base + 4,
    init_shape: if(o == 0){ 0 } else { 5 },
    init_dest: if(o == 0){ 0 } else { 2 },
  })
}

// the other cells of ctl. The window writes MODE, RECORD, LENGTH (when it
// loads a sample), RESET, PLAY, FREEZE and the LFOs' settings; the engine
// the rest.
engine.cells = {
  MODE: 20, // 0: the recording, 1: live
  RECORD: 21, // 1 while recording
  LENGTH: 22, // frames of the recording
  RECPOS: 23, // where recording writes
  LEVEL: 24, // the microphone's peak (the window sets it back to 0)
  GRAINS: 25, // grains sounding
  SCANPOS: 26, // where scan has moved position to (0..1)
  PEAKL: 27, // the output's peaks (the window sets them back to 0)
  PEAKR: 28,
  MIC: 29, // 1: recording works, -1: it failed, 0: no microphone asked
  RESET: 30, // the window sets 1: scan starts again at position
  LIVEHEAD: 31, // frames the live ring has taken, in all
  PLAY: 32, // the window sets 1: the recording plays once, as it is
  PLAYPOS: 33, // where that playing is (frames)
  FREEZE: 34, // 1: live mode stops listening, scan stops moving
  LFO: 40, // the LFOs' cells, 8 each (engine.lfos)
  EFF: 60, // 60..76: each knob as the sound uses it (glided, modulated)
  GLIDE: 78, // the window's own: how long a snapshot takes to arrive
  MORPH: 79, // the window's own: from where it was (0) to the snapshot (1)
  SIZE: 80,
}

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

  struct Voice {
    serial: double,
    note: double,
    vel: double,
    gate: int32,
    env: double,
    timer: double,
  }

  local seed = 22222
  local scan = 0.0
  // the filter's state, per side
  local l1 = 0.0
  local l2 = 0.0
  local r1 = 0.0
  local r2 = 0.0
  // the delay: two seconds a side, with a lowpass in the loop
  local dl: float[96000]
  local dr: float[96000]
  local dw = 0
  local tl = 0.0
  local tr = 0.0
  local smooth_time = 0.38
  // the knobs as the sound uses them: glided, then modulated
  local sm: double[17]
  local mods: double[17]
  local primed = 0
  local last_gain = 0.0
  local last_mix = 0.0
  // the LFOs: phase, and the random values random and drift go between
  local lfo_phase: double[2]
  local lfo_from: double[2]
  local lfo_to: double[2]

  // 0 .. 1
  local func rand(): float {
    seed = (seed * 6364136223846793005 + 1442695040888963407) &
      9223372036854775807
    return float((seed >> 20) & 1048575) / 1048576.0
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

  // n frames into out (stereo, interleaved). src holds the sound: the
  // recording (its first len frames), or in live mode the ring whose
  // newest frame is just before head.
  func render(
    out: float[], n: int, src: float[], length: int, live: bool, head: int,
    grains: Grain[], voices: Voice[], keys: double[], ctl: double[],
    view: float[], ranges: double[]
  ){
    local sr = 48000.0
    // each knob glides to where the window put it (50 ms) ...
    local glide = 1.0 - exp(-float(n) / (sr * 0.05))
    if(primed == 0){
      primed = 1
      for(local k = 0; k < 17; k += 1){
        sm[k] = ctl[k]
      }
      last_gain = ctl[16]
      last_mix = ctl[13]
    }
    for(local k = 0; k < 17; k += 1){
      sm[k] += (ctl[k] - sm[k]) * glide
      mods[k] = 0.0
    }
    // ... and the LFOs move it, in the slider's terms
    for(local o = 0; o < 2; o += 1){
      local b = 40 + o * 8
      local ph = lfo_phase[o] + ctl[b] * float(n) / sr
      if(ph >= 1.0){
        ph = ph % 1.0
        lfo_from[o] = lfo_to[o]
        lfo_to[o] = rand() * 2.0 - 1.0
      }
      lfo_phase[o] = ph
      local shape = int(ctl[b + 1])
      local v = 0.0
      if(shape == 0){
        v = sin(2.0 * PI * ph)
      } else if(shape == 1){
        v = 1.0 - 4.0 * abs(ph - 0.5)
      } else if(shape == 2){
        v = 2.0 * ph - 1.0
      } else if(shape == 3){
        if(ph < 0.5){
          v = 1.0
        } else {
          v = -1.0
        }
      } else if(shape == 4){
        v = lfo_to[o]
      } else {
        local e = 0.5 - 0.5 * cos(PI * ph)
        v = lfo_from[o] + (lfo_to[o] - lfo_from[o]) * e
      }
      ctl[b + 4] = v
      local dest = int(ctl[b + 3])
      if(dest >= 0 and dest < 17){
        mods[dest] += v * ctl[b + 2]
      }
    }
    for(local k = 0; k < 17; k += 1){
      local v = sm[k]
      if(mods[k] != 0.0){
        local lo = ranges[k * 3]
        local hi = ranges[k * 3 + 1]
        local cu = ranges[k * 3 + 2]
        local t = pow(clamp((v - lo) / (hi - lo), 0.0, 1.0), 1.0 / cu)
        t = clamp(t + mods[k], 0.0, 1.0)
        v = lo + (hi - lo) * pow(t, cu)
      }
      ctl[60 + k] = v
    }
    local pos = ctl[60]
    local spray = ctl[61] * 0.5 * sr
    local dur = int(ctl[62] * 0.001 * sr)
    local interval = sr / ctl[63]
    local pitch = ctl[64]
    local detune = ctl[65]
    local reverse = ctl[66]
    local skew = ctl[67]
    local scan_speed = ctl[68]
    local stereo = ctl[69]
    local fb = ctl[72]
    local attack_step = 1.0 / (ctl[74] * sr)
    local release_step = 1.0 / (ctl[75] * sr)
    local mix_to = ctl[73]
    local gain_to = ctl[76]
    // the filter (a state variable filter, topology preserving): its
    // cutoff from 40 Hz to 20 kHz
    local hz = 40.0 * pow(2.0, ctl[70] * 9.0)
    local g = tan(PI * min(hz, sr * 0.45) / sr)
    local k = 1.4
    local a1 = 1.0 / (1.0 + g * (g + k))
    local a2 = g * a1
    local a3 = g * a2
    // more grains overlapping: each one quieter
    local overlap = ctl[63] * ctl[62] * 0.001
    local norm = 1.0 / sqrt(max(1.0, overlap))
    if(ctl[30] > 0.0){
      ctl[30] = 0.0
      scan = 0.0
    }
    if(live){
      scan = 0.0
    }
    // a new note in a slot starts its voice again
    for(local v = 0; v < len(voices); v += 1){
      local vo = voices[v]
      local serial = keys[v * 4 + 3]
      if(serial != vo.serial){
        vo.serial = serial
        vo.note = keys[v * 4]
        vo.vel = keys[v * 4 + 2]
        vo.timer = 0.0
      }
      vo.gate = int(keys[v * 4 + 1])
    }
    local sounding = 0
    local peak_l = 0.0
    local peak_r = 0.0
    for(local i = 0; i < n; i += 1){
      if(not live and length > 0 and ctl[34] == 0.0){
        scan = (scan + scan_speed / float(length)) % 1.0
      }
      // the voices: envelopes, and grains when it is time
      for(local v = 0; v < len(voices); v += 1){
        local vo = voices[v]
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
        vo.timer += interval * (0.75 + 0.5 * rand())
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
        local semis = vo.note - 60.0 + pitch + detune * (rand() * 2.0 - 1.0)
        local inc = pow(2.0, semis / 12.0)
        if(rand() < reverse){
          inc = -inc
        }
        local start = 0.0
        local d = float(dur)
        if(live){
          // position 1 is now, 0 the oldest the ring holds (silence
          // until the microphone has filled it); a grain must never catch
          // up with the head, nor fall off the ring's end. The head moves
          // when the microphone delivers (every 10 ms or so), so a grain
          // starts at least 25 ms behind it.
          local ring = float(len(src))
          local behind = (1.0 - pos) * ring + spray * (rand() * 2.0 - 1.0)
          local least = max(0.0, (inc - 1.0) * d) + 1200.0
          local most = ring - abs(inc) * d - 64.0
          behind = clamp(behind, least, max(least, most))
          start = float(head) - behind
        } else {
          start = ((pos + scan) % 1.0) * float(length) +
            spray * (rand() * 2.0 - 1.0)
          if(inc < 0.0){
            // backwards from the end of its slice
            start += abs(inc) * d
          }
        }
        local p = clamp(0.5 + stereo * (rand() - 0.5), 0.0, 1.0)
        gr.on = 1
        gr.voice = v
        gr.age = 0
        gr.dur = max(dur, 16)
        gr.pos = start
        gr.inc = inc
        gr.amp = vo.vel * norm
        gr.pl = cos(p * PI * 0.5)
        gr.pr = sin(p * PI * 0.5)
      }
      // the grains
      local l = 0.0
      local r = 0.0
      for(local s = 0; s < len(grains); s += 1){
        local gr = grains[s]
        if(gr.on == 0){
          continue
        }
        local e = window(float(gr.age) / float(gr.dur), skew) * gr.amp *
          voices[gr.voice].env
        local x = 0.0
        if(live){
          x = at(src, len(src), gr.pos)
        } else {
          x = at(src, length, gr.pos)
        }
        l += x * e * gr.pl
        r += x * e * gr.pr
        gr.pos += gr.inc
        gr.age += 1
        if(gr.age >= gr.dur){
          gr.on = 0
        }
      }
      // the filter
      local v3 = l - l2
      local v1 = a1 * l1 + a2 * v3
      local v2 = l2 + a2 * l1 + a3 * v3
      l1 = 2.0 * v1 - l1
      l2 = 2.0 * v2 - l2
      l = v2
      v3 = r - r2
      v1 = a1 * r1 + a2 * v3
      v2 = r2 + a2 * r1 + a3 * v3
      r1 = 2.0 * v1 - r1
      r2 = 2.0 * v2 - r2
      r = v2
      // the delay: each side feeds the other (ping-pong), darker each
      // time round; its time glides, so turning it bends the echoes
      smooth_time += (ctl[71] - smooth_time) * 0.0002
      local back = smooth_time * sr
      local rd = float(dw) - back
      local il = int(floor(rd))
      local f = rd - floor(rd)
      local nd = len(dl)
      local el = dl[il % nd] * (1.0 - f) + dl[(il + 1) % nd] * f
      local er = dr[il % nd] * (1.0 - f) + dr[(il + 1) % nd] * f
      tl += (er - tl) * 0.35
      tr += (el - tr) * 0.35
      dl[dw % nd] = l * 0.7 + tl * fb
      dr[dw % nd] = r * 0.7 + tr * fb
      dw = (dw + 1) % nd
      // gain and mix ramp across the block, so turning them does not click
      local ramp = float(i + 1) / float(n)
      local mix = last_mix + (mix_to - last_mix) * ramp
      local gain = last_gain + (gain_to - last_gain) * ramp
      l = tanh((l + el * mix) * gain)
      r = tanh((r + er * mix) * gain)
      out[2 * i] = l
      out[2 * i + 1] = r
      peak_l = max(peak_l, abs(l))
      peak_r = max(peak_r, abs(r))
    }
    // what the window draws: where each grain reads, and how loud
    local first = float(head - len(src))
    for(local s = 0; s < len(grains); s += 1){
      local gr = grains[s]
      if(gr.on == 0){
        view[s * 2 + 1] = 0.0
        continue
      }
      sounding += 1
      local x = 0.0
      if(live){
        x = (gr.pos - first) / float(len(src))
      } else {
        x = (gr.pos % float(length)) / float(length)
      }
      view[s * 2] = clamp(x, 0.0, 1.0)
      view[s * 2 + 1] = gr.amp * voices[gr.voice].env *
        window(float(gr.age) / float(gr.dur), skew)
    }
    last_mix = mix_to
    last_gain = gain_to
    ctl[25] = float(sounding)
    ctl[26] = scan
    ctl[27] = max(ctl[27], peak_l)
    ctl[28] = max(ctl[28], peak_r)
  }

  // while ctl[PLAY] is 1: the recording as it is, from ctl[PLAYPOS] on,
  // added to out (both sides); at its end PLAY goes back to 0
  func audition(out: float[], n: int, src: float[], length: int, ctl: double[]){
    if(ctl[32] == 0.0){
      return
    }
    local at = int(ctl[33])
    for(local i = 0; i < n; i += 1){
      if(at >= length){
        ctl[32] = 0.0
        break
      }
      local l = clamp(out[2 * i] + src[at], -1.0, 1.0)
      local r = clamp(out[2 * i + 1] + src[at], -1.0, 1.0)
      out[2 * i] = l
      out[2 * i + 1] = r
      ctl[27] = max(ctl[27], abs(l))
      ctl[28] = max(ctl[28], abs(r))
      at += 1
    }
    ctl[33] = float(at)
  }

  // n frames of src into the ring dst (of dst_len frames), from at on
  func capture(dst: float[], dst_len: int, at: int, src: float[], n: int){
    for(local i = 0; i < n; i += 1){
      dst[(at + i) % dst_len] = src[i]
    }
  }

  // the waveform as columns: the lowest and highest sample of each of
  // cols stretches of count frames from start (wrapping around ring)
  func peaks(
    src: float[], start: int, count: int, ring: int, cols: int, out: float[]
  ){
    for(local c = 0; c < cols; c += 1){
      local a = start + c * count / cols
      local b = start + (c + 1) * count / cols
      local lo = 0.0
      local hi = 0.0
      // a wide column looks at no more than 256 samples of it
      local step = max(1, (b - a) / 256)
      for(local i = a; i < b; i += step){
        local x = src[i % ring]
        lo = min(lo, x)
        hi = max(hi, x)
      }
      out[c * 2] = lo
      out[c * 2 + 1] = hi
    }
  }
}

engine.Grain = Grain
engine.Voice = Voice
engine.capture = capture
engine.peaks = peaks

// shared() -> {sample, live, ctl, keys, view}: the buffers the window and
// the engine share, the knobs at their start values
func engine.shared(){
  local ctl = kernel.double:array(engine.cells.SIZE, {shared: true})
  for(let local k in values(engine.knobs)){
    ctl[k.cell] = k.init
    ctl[engine.cells.EFF + k.cell] = k.init
  }
  for(let local o in values(engine.lfos)){
    ctl[o.rate.cell] = o.rate.init
    ctl[o.depth.cell] = o.depth.init
    ctl[o.shape] = o.init_shape
    ctl[o.dest] = o.init_dest
  }
  return {
    sample: kernel.float:array(engine.MAXS, {shared: true}),
    live: kernel.float:array(engine.LIVE, {shared: true}),
    ctl: ctl,
    keys: kernel.double:array(engine.NV * 4, {shared: true}),
    view: kernel.float:array(engine.MAXG * 2, {shared: true}),
  }
}

// new(shared, options?) -> func(out, frames)
// The block function: frames stereo frames into out (interleaved).
// options.input is where the sound comes from: a microphone.Input, or
// null to open the microphone (options.device names it; options.mic ==
// false opens none). options.report(message) hears whether it opened.
func engine.new(shared, options){
  options = options or {}
  local c = engine.cells
  local ctl = shared.ctl
  local grains = Grain:array(engine.MAXG)
  local voices = Voice:array(engine.NV)
  // the knobs' ranges, for the LFOs: min, max and curve each
  local ranges = kernel.double:array(len(engine.knobs) * 3)
  for(let local k in values(engine.knobs)){
    ranges[k.cell * 3] = k.min
    ranges[k.cell * 3 + 1] = k.max
    ranges[k.cell * 3 + 2] = k.curve or 1.0
  }
  local input = options.input
  if(input == null and options.mic != false){
    local opened = try { {
      input: require(
        "microphone",
      ).open({device: options.device, buffer: 48000}),
    } } catch(e) { {error: e} }
    input = opened.input
    local failed = opened.error
    if(failed != null){
      ctl[c.MIC] = -1.0
    }
    if(options.report != null){
      if(failed != null){
        options.report({error: string(failed)})
      } else {
        options.report({name: input.name})
      }
    }
  }
  if(input != null){
    ctl[c.MIC] = 1.0
  }
  local tmp = kernel.float:array(4096)
  local recording = false
  local live_head = 0
  // the microphone's frames since the last block into the live ring, and
  // into the recording while ctl[RECORD] is 1
  local func listen(){
    if(ctl[c.RECORD] > 0.0 and not recording){
      recording = true
      ctl[c.RECPOS] = 0.0
      ctl[c.LENGTH] = 0.0
    } else if(ctl[c.RECORD] == 0.0 and recording){
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
      if(ctl[c.FREEZE] == 0.0){
        capture(shared.live, engine.LIVE, live_head % engine.LIVE, tmp, n)
        live_head = live_head + n
      }
      if(recording){
        local at = to_int(ctl[c.RECPOS])
        n = math.min(n, engine.MAXS - at)
        capture(shared.sample, engine.MAXS, at, tmp, n)
        ctl[c.RECPOS] = at + n
        ctl[c.LENGTH] = at + n
        if(at + n >= engine.MAXS){
          // full
          ctl[c.RECORD] = 0.0
          recording = false
        }
      }
      if(n < len(tmp)){
        break
      }
    }
    ctl[c.LIVEHEAD] = live_head
    ctl[c.LEVEL] = math.max(ctl[c.LEVEL], input.level)
  }
  return func(out, frames){
    listen()
    if(ctl[c.MODE] > 0.0){
      render(
        out, frames, shared.live, math.min(live_head, engine.LIVE), true,
        live_head, grains, voices, shared.keys, ctl, shared.view, ranges
      )
    } else {
      render(
        out, frames, shared.sample, to_int(ctl[c.LENGTH]), false, 0, grains,
        voices, shared.keys, ctl, shared.view, ranges
      )
    }
    audition(out, frames, shared.sample, to_int(ctl[c.LENGTH]), ctl)
  }
}

return engine
