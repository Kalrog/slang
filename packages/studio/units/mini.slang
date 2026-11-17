extension "kernel/syntax"
// studio/units/mini: a monophonic analog-style synthesizer after the
// classic three-oscillator keyboards (the one of examples/synth): three
// oscillators and noise into a mixer, a four-pole ladder filter with its
// own contour, a loudness contour, glide, and a mod wheel that sends
// oscillator 3 or noise to the pitch and the filter.
//
//   local bass = s:track("bass", "mini", {patch: "Fat Bass"})
//   bass:note(36, {length: 200})
//   bass.unit.params.cutoff = 0.4
//
// One voice, played as the original is: a key pressed while another is
// held changes the pitch without starting the contours again, and letting
// it go returns to the key still held. Knobs are 0 to 1 as on the panel
// (a contour time is 10 s x knob^3; CUTOFF is 20 Hz x 2^(10 x knob);
// FREQUENCY detunes by 7 semitones x (2 x knob - 1)^3); rotary switches
// take their labels (range1: "16'", wave2: "SAW").
local math = require("slang/math")
local param = require("studio/param")
local events = require("studio/events")

kernel {
  use "studio/lib"

  // the voice: what the slang version keeps in locals
  struct Voice {
    note: double = 60,
    pitch: double = 60,
    amp_stage: int32,
    fenv_stage: int32,
    p1: double,
    p2: double,
    p3: double,
    o3: double,
    noise: double,
    seed: int64 = 12345,
    amp: double,
    fenv: double,
    y1: double,
    y2: double,
    y3: double,
    y4: double,
  }

  // the controls of a block, as slang works them out from the knobs
  struct Controls {
    sr: double,
    tune: double,
    glide_c: double,
    semis1: double,
    semis2: double,
    semis3: double,
    wave1: int32,
    wave2: int32,
    wave3: int32,
    track3: int32,
    g1: double,
    g2: double,
    g3: double,
    gn: double,
    mod_mix: double,
    osc_mod: double,
    filter_mod: double,
    cutoff_oct: double,
    contour: double,
    kbd: double,
    k: double,
    fa: double,
    fd: double,
    fs: double,
    aa: double,
    ad: double,
    a_sus: double,
    fr: double,
    ar: double,
    volume: double,
    makeup: double,
  }

  local CONTROL = 16
  local LN2 = 0.6931471805599453
  local LN2_12 = 0.6931471805599453 / 12.0
  local TWO_PI = 6.283185307179586

  // the width of WIDE and NARROW pulses (and of the square)
  local func width(wave: int): float {
    if(wave == 5){
      return 0.12
    }
    if(wave == 4){
      return 0.3
    }
    return 0.5
  }

  // one oscillator's sample, as shape() in slang below
  local func shape(wave: int, p: float, dt: float, rev: bool): float {
    if(wave == 2){
      return 2.0 * p - 1.0 - blep(p, dt)
    }
    if(wave >= 3){
      local w = width(wave)
      local q = p - w
      if(q < 0.0){
        q += 1.0
      }
      local v = -1.0
      if(p < w){
        v = 1.0
      }
      return v + blep(p, dt) - blep(q, dt)
    }
    local x = abs(2.0 * p - 1.0)
    local tri = 2.0 * x - 1.0
    if(wave == 0){
      return tri
    }
    local saw = 2.0 * p - 1.0 - blep(p, dt)
    if(rev){
      return -saw
    }
    return 0.5 * (tri + saw)
  }

  // frames from .. to - 1 of l and r (the voice is mono: both the same),
  // a control step every CONTROL samples from `from`
  func render(
    l: float[], r: float[], from: int, to: int, v: Voice, c: Controls
  ){
    local sr = c.sr
    local note = v.note
    local pitch = v.pitch
    local amp_stage = v.amp_stage
    local fenv_stage = v.fenv_stage
    local p1 = v.p1
    local p2 = v.p2
    local p3 = v.p3
    local o3 = v.o3
    local noise = v.noise
    local seed = v.seed
    local amp = v.amp
    local fenv = v.fenv
    local y1 = v.y1
    local y2 = v.y2
    local y3 = v.y3
    local y4 = v.y4
    local g1 = c.g1
    local g2 = c.g2
    local g3 = c.g3
    local gn = c.gn
    local k = c.k
    local aa = c.aa
    local ad = c.ad
    local a_sus = c.a_sus
    local ar = c.ar
    local makeup = c.makeup
    local volume = c.volume
    local i = from
    for(i < to){
      // ---- every CONTROL samples: pitch, modulation, the filter
      pitch += (note - pitch) * c.glide_c
      local m = o3 + (noise - o3) * c.mod_mix
      local base = pitch - 69.0 + c.tune
      local vib = m * c.osc_mod
      local dt1 = 440.0 * exp((base + c.semis1 + vib) * LN2_12) / sr
      local dt2 = 440.0 * exp((base + c.semis2 + vib) * LN2_12) / sr
      local n3 = base
      if(c.track3 == 0){
        n3 = -9.0
      }
      local dt3 = 440.0 * exp((n3 + c.semis3) * LN2_12) / sr
      if(fenv_stage == 1){
        fenv += (1.3 - fenv) * c.fa
        if(fenv >= 1.0){
          fenv = 1.0
          fenv_stage = 2
        }
      } else if(fenv_stage == 2){
        fenv += (c.fs - fenv) * c.fd
      } else {
        fenv -= fenv * c.fr
      }
      local oct = c.cutoff_oct + c.contour * fenv + m * c.filter_mod +
        c.kbd * (pitch - 60.0) / 12.0
      local fc = min(20.0 * exp(oct * LN2), sr * 0.45)
      // the filter runs at twice the rate
      local g = 1.0 - exp(-TWO_PI * fc / (2.0 * sr))
      local stop = min(i + CONTROL, to)
      // ---- every sample
      for(i < stop){
        p1 += dt1
        if(p1 >= 1.0){
          p1 -= 1.0
        }
        p2 += dt2
        if(p2 >= 1.0){
          p2 -= 1.0
        }
        p3 += dt3
        if(p3 >= 1.0){
          p3 -= 1.0
        }
        o3 = shape(c.wave3, p3, dt3, true)
        seed = (seed * 1103515245 + 12345) & 0x7fffffff
        noise = seed / 1073741823.5 - 1.0
        local x = g1 * shape(c.wave1, p1, dt1, false) +
          g2 * shape(c.wave2, p2, dt2, false) + g3 * o3 + gn * noise
        // the ladder: four one-poles, the emphasis feeding back the last
        local u = soft(x - k * y4)
        y1 += g * (u - y1)
        y2 += g * (y1 - y2)
        y3 += g * (y2 - y3)
        y4 += g * (y3 - y4)
        u = soft(x - k * y4)
        y1 += g * (u - y1)
        y2 += g * (y1 - y2)
        y3 += g * (y2 - y3)
        y4 += g * (y3 - y4)
        if(amp_stage == 1){
          amp += (1.3 - amp) * aa
          if(amp >= 1.0){
            amp = 1.0
            amp_stage = 2
          }
        } else if(amp_stage == 2){
          amp += (a_sus - amp) * ad
        } else {
          amp -= amp * ar
        }
        local s = soft(y4 * makeup * amp * volume * 1.5) * 0.66
        l[i] = s
        r[i] = s
        i += 1
      }
    }
    v.pitch = pitch
    v.amp_stage = amp_stage
    v.fenv_stage = fenv_stage
    v.p1 = p1
    v.p2 = p2
    v.p3 = p3
    v.o3 = o3
    v.noise = noise
    v.seed = seed
    v.amp = amp
    v.fenv = fenv
    v.y1 = y1
    v.y2 = y2
    v.y3 = y3
    v.y4 = y4
  }
}

local ranges = {"LO", "32'", "16'", "8'", "4'", "2'"}
local waves = {"TRI", "SHRK", "SAW", "SQR", "WIDE", "NARR"}
local waves3 = {"TRI", "REV", "SAW", "SQR", "WIDE", "NARR"}

local func knob(name, default, bipolar){
  return {name: name, min: 0.0, max: 1.0, default: default, bipolar: bipolar}
}

local params = param.set({
  // controllers
  knob("tune", 0.5, true),
  knob("glide", 0.0),
  knob("mod_mix", 0.0),
  {name: "osc_mod", kind: "switch", default: 0},
  {name: "filter_mod", kind: "switch", default: 0},
  // oscillator bank
  {name: "range1", labels: ranges, default: "8'"},
  {name: "wave1", labels: waves, default: "SAW"},
  {name: "range2", labels: ranges, default: "8'"},
  knob("detune2", 0.52, true),
  {name: "wave2", labels: waves, default: "SAW"},
  {name: "range3", labels: ranges, default: "16'"},
  knob("detune3", 0.47, true),
  {name: "wave3", labels: waves3, default: "SQR"},
  {name: "osc3_ctrl", kind: "switch", default: 1},
  // mixer
  knob("vol1", 0.8),
  {name: "on1", kind: "switch", default: 1},
  knob("vol2", 0.7),
  {name: "on2", kind: "switch", default: 1},
  knob("vol3", 0.5),
  {name: "on3", kind: "switch", default: 0},
  knob("noise", 0.3),
  {name: "noise_on", kind: "switch", default: 0},
  // modifiers: the filter and the loudness contour
  knob("cutoff", 0.45),
  knob("emphasis", 0.35),
  knob("contour", 0.5),
  knob("f_attack", 0.05),
  knob("f_decay", 0.4),
  knob("f_sustain", 0.3),
  knob("a_attack", 0.02),
  knob("a_decay", 0.4),
  knob("a_sustain", 0.8),
  {name: "kbd_ctrl", kind: "switch", default: 1},
  {name: "decay_sw", kind: "switch", default: 1},
  // output
  knob("volume", 0.6),
  // where the wheels rest: a patch may hold the mod wheel up
  knob("bend", 0.5, true),
  knob("mod", 0.0),
})
local P = params.index

// osc 3 as a slow LFO, sent to the pitch (vibrato) or the filter (wah) by
// the mod wheel
local lfo = {range3: "LO", wave3: "TRI", osc3_ctrl: 0, on3: 0, mod_mix: 0.0}

local func with(base, own){
  local p = {}
  for(let local e in entries(base)){
    p[e[0]] = e[1]
  }
  for(let local e in entries(own)){
    p[e[0]] = e[1]
  }
  return p
}

local bank = {
  {name: "Init", patch: {}},
  {
    name: "Fat Bass", patch: {
      range1: "16'",
      wave1: "SAW",
      vol1: 0.8,
      range2: "16'",
      wave2: "SQR",
      detune2: 0.6,
      vol2: 0.7,
      range3: "32'",
      wave3: "SAW",
      detune3: 0.42,
      vol3: 0.5,
      on3: 1,
      cutoff: 0.3,
      emphasis: 0.25,
      contour: 0.5,
      f_attack: 0.0,
      f_decay: 0.3,
      f_sustain: 0.15,
      a_attack: 0.0,
      a_decay: 0.35,
      a_sustain: 0.9,
      decay_sw: 0,
      volume: 0.7,
    }
  },
  {
    name: "Pluck Bass", patch: {
      range1: "16'",
      wave1: "WIDE",
      range2: "16'",
      wave2: "SAW",
      detune2: 0.58,
      vol2: 0.6,
      cutoff: 0.22,
      emphasis: 0.55,
      contour: 0.65,
      f_attack: 0.0,
      f_decay: 0.22,
      f_sustain: 0.0,
      a_attack: 0.0,
      a_decay: 0.45,
      a_sustain: 0.0,
      volume: 0.7,
    }
  },
  {
    name: "Lead", patch: with(lfo, {
      glide: 0.25,
      osc_mod: 1,
      mod: 0.06,
      detune3: 0.7,
      wave1: "SAW",
      wave2: "SAW",
      detune2: 0.62,
      vol2: 0.75,
      cutoff: 0.48,
      emphasis: 0.45,
      contour: 0.45,
      f_attack: 0.1,
      f_decay: 0.45,
      f_sustain: 0.5,
      a_attack: 0.05,
      a_decay: 0.4,
      a_sustain: 0.95,
    })
  },
  {
    name: "Brass", patch: {
      wave1: "SAW",
      wave2: "SAW",
      detune2: 0.6,
      vol2: 0.8,
      cutoff: 0.34,
      emphasis: 0.15,
      contour: 0.55,
      f_attack: 0.3,
      f_decay: 0.45,
      f_sustain: 0.55,
      a_attack: 0.15,
      a_decay: 0.4,
      a_sustain: 0.9,
      volume: 0.7,
    }
  },
  {
    name: "Flute", patch: with(lfo, {
      osc_mod: 1,
      mod: 0.05,
      detune3: 0.75,
      wave1: "TRI",
      vol1: 0.9,
      range2: "4'",
      wave2: "TRI",
      detune2: 0.5,
      vol2: 0.2,
      noise: 0.15,
      noise_on: 1,
      cutoff: 0.56,
      emphasis: 0.05,
      contour: 0.15,
      f_attack: 0.05,
      f_decay: 0.3,
      f_sustain: 0.8,
      a_attack: 0.22,
      a_decay: 0.3,
      a_sustain: 0.9,
      volume: 0.75,
    })
  },
  {
    name: "Fifths", patch: {
      wave1: "SAW",
      wave2: "SAW",
      detune2: 1.0,
      vol2: 0.6,
      cutoff: 0.42,
      emphasis: 0.3,
      contour: 0.4,
      f_attack: 0.05,
      f_decay: 0.35,
      f_sustain: 0.4,
    }
  },
  {
    name: "Slow Pad", patch: {
      wave1: "SAW",
      wave2: "SAW",
      detune2: 0.62,
      vol2: 0.7,
      range3: "8'",
      wave3: "SAW",
      detune3: 0.38,
      vol3: 0.6,
      on3: 1,
      cutoff: 0.4,
      emphasis: 0.1,
      contour: 0.3,
      f_attack: 0.6,
      f_decay: 0.6,
      f_sustain: 0.7,
      a_attack: 0.55,
      a_decay: 0.6,
      a_sustain: 1.0,
      volume: 0.6,
    }
  },
  {
    name: "Filter Sweep", patch: {
      wave1: "SQR",
      wave2: "SAW",
      detune2: 0.58,
      cutoff: 0.15,
      emphasis: 0.75,
      contour: 0.85,
      f_attack: 0.45,
      f_decay: 0.55,
      f_sustain: 0.2,
      a_attack: 0.02,
      a_sustain: 1.0,
    }
  },
  {
    name: "Wobble", patch: with(lfo, {
      filter_mod: 1,
      mod: 0.6,
      detune3: 0.3,
      range1: "16'",
      wave1: "SAW",
      range2: "32'",
      wave2: "SQR",
      detune2: 0.55,
      cutoff: 0.3,
      emphasis: 0.6,
      contour: 0.2,
      a_attack: 0.0,
      a_sustain: 1.0,
      decay_sw: 0,
    })
  },
  {
    name: "Zap", patch: {
      range1: "4'",
      wave1: "SAW",
      on2: 0,
      cutoff: 0.25,
      emphasis: 0.8,
      contour: 1.0,
      f_attack: 0.0,
      f_decay: 0.2,
      f_sustain: 0.0,
      a_attack: 0.0,
      a_decay: 0.3,
      a_sustain: 0.0,
    }
  },
  {
    name: "Wind", patch: {
      on1: 0,
      on2: 0,
      noise: 0.9,
      noise_on: 1,
      cutoff: 0.6,
      emphasis: 0.9,
      contour: 0.2,
      kbd_ctrl: 1,
      f_attack: 0.4,
      f_decay: 0.6,
      f_sustain: 0.6,
      a_attack: 0.5,
      a_decay: 0.6,
      a_sustain: 1.0,
      volume: 0.8,
    }
  },
}

local patches = {}
for(let local b in values(bank)){
  local flat = {name: b.name}
  for(let local e in entries(b.patch)){
    flat[e[0]] = e[1]
  }
  append(patches, flat)
}

local CONTROL = 16
// the octave of each RANGE position, from 8' (0); LO is six down, which
// with OSC 3 CTRL off makes osc 3 an LFO of 4 to 6 Hz
local range_octaves = {-6, -2, -1, 0, 1, 2}

// the per-step coefficient of an exponential segment that gets within 1%
// (-40 dB) of its target in `seconds`, at `rate` steps per second
local func coef(seconds, rate){
  if(seconds <= 0.0){
    return 1.0
  }
  return 1.0 - math.exp(-4.6 / (seconds * rate))
}

// a knob's 0..1 as a contour time: 1 ms to 10 s, most of the travel short
local func contour_time(x){
  return 0.001 + x * x * x * 10.0
}

local func new(ctx){
  local sr = ctx.sample_rate * 1.0
  local p = ctx.params
  local base = ctx.base
  local v = Voice:new()
  local c = Controls:new({sr: sr})
  local held = {}
  local gate = false
  local wheel_bend = 0.0
  local wheel_mod = 0.0

  local func release(n){
    local rest = {}
    for(local i = 0; i < len(held); i = i + 1){
      if(held[i] != n){
        append(rest, held[i])
      }
    }
    held = rest
  }

  local func all_off(){
    held = {}
    gate = false
    v.amp_stage = 0
    v.fenv_stage = 0
  }

  // the controls, once a segment
  local func controls(){
    local b = base
    c.tune = (p[b + P.tune] - 0.5) * 4.0 + (p[b + P.bend] - 0.5) * 4.0 +
      wheel_bend * 2.0
    local glide_t = p[b + P.glide] * p[b + P.glide] * 3.0
    c.glide_c = 1.0
    if(glide_t > 0.002){
      c.glide_c = coef(glide_t, sr / CONTROL)
    }
    local d2 = (p[b + P.detune2] - 0.5) * 2.0
    local d3 = (p[b + P.detune3] - 0.5) * 2.0
    c.semis1 = range_octaves[to_int(p[b + P.range1])] * 12.0
    c.semis2 = range_octaves[to_int(p[b + P.range2])] * 12.0 +
      7.0 * d2 * d2 * d2
    c.semis3 = range_octaves[to_int(p[b + P.range3])] * 12.0 +
      7.0 * d3 * d3 * d3
    c.wave1 = to_int(p[b + P.wave1])
    c.wave2 = to_int(p[b + P.wave2])
    c.wave3 = to_int(p[b + P.wave3])
    c.track3 = if(p[b + P.osc3_ctrl] > 0.5){ 1 } else { 0 }
    c.g1 = p[b + P.vol1] * p[b + P.on1]
    c.g2 = p[b + P.vol2] * p[b + P.on2]
    c.g3 = p[b + P.vol3] * p[b + P.on3]
    c.gn = p[b + P.noise] * p[b + P.noise_on] * 0.7
    c.mod_mix = p[b + P.mod_mix]
    local wheel = math.min(1.0, p[b + P.mod] + wheel_mod)
    c.osc_mod = p[b + P.osc_mod] * wheel * 2.0
    c.filter_mod = p[b + P.filter_mod] * wheel * 2.0
    c.cutoff_oct = p[b + P.cutoff] * 10.0
    c.contour = p[b + P.contour] * 6.0
    c.kbd = p[b + P.kbd_ctrl]
    local k = p[b + P.emphasis] * 4.3
    c.k = k
    // an attack aims past full (1.3) so it gets there in its time
    c.fa = coef(contour_time(p[b + P.f_attack]) * 3.1, sr / CONTROL)
    c.fd = coef(contour_time(p[b + P.f_decay]), sr / CONTROL)
    c.fs = p[b + P.f_sustain]
    c.aa = coef(contour_time(p[b + P.a_attack]) * 3.1, sr)
    c.ad = coef(contour_time(p[b + P.a_decay]), sr)
    c.a_sus = p[b + P.a_sustain]
    c.fr = coef(0.008, sr / CONTROL)
    c.ar = coef(0.008, sr)
    if(p[b + P.decay_sw] > 0.5){
      c.fr = c.fd
      c.ar = c.ad
    }
    c.volume = p[b + P.volume] * p[b + P.volume] * 0.9
    c.makeup = 1.0 + k * 0.35
  }

  return {
    note_on: func(n, vel){
      release(n)
      append(held, n)
      v.note = n * 1.0
      // single trigger: a key pressed while others are held only changes
      // the pitch
      if(not gate){
        gate = true
        v.amp_stage = 1
        v.fenv_stage = 1
      }
    },
    note_off: func(n){
      release(n)
      if(len(held) > 0){
        v.note = held[len(held) - 1] * 1.0
      } else if(gate){
        gate = false
        v.amp_stage = 0
        v.fenv_stage = 0
      }
    },
    control: func(which, value){
      if(which == events.controls.BEND){
        wheel_bend = value
      } else if(which == events.controls.MOD){
        wheel_mod = value
      }
    },
    hush: all_off,
    panic: func(){
      all_off()
      v.amp = 0.0
      v.fenv = 0.0
    },
    voices: func(){
      if(gate or v.amp > 0.0005){
        return 1
      }
      return 0
    },
    render: func(l, r, start, n){
      controls()
      render(l, r, start, start + n, v, c)
    },
  }
}

return {
  name: "mini",
  kind: "instrument",
  params: params,
  patches: patches,
  new: new,
}
