// The sound: a kernel that renders every voice of every player, with a
// delay and a reverb, in the render isolate of raylib/stream; the piece's
// side (session.slang) sends it timed instructions through a ring of
// events in a shared buffer, and reads back the clock and the meters.
//
// A player is a set of parameters (engine.params) a voice starts from; an
// instruction is a note (a voice with the player's parameters, some
// overridden for this note; gate is its length in seconds, under 0 held
// until a note off), a set (a parameter of the player and of its sounding
// voices), a note off (for held notes), an
// fx setting (engine.fx) or a hush. Every instruction has a time in
// samples of the engine's clock (ctl[PLAYED]), and the block function
// renders up to each one before it applies it.
extension "kernel/syntax"
local kernel = require("kernel")
local buffer = require("slang/buffer")
local math = require("slang/math")

local engine = {}

engine.MAXV = 32 // voices
engine.MAXP = 8 // players
engine.MAXE = 2048 // events the ring holds

// the parameters of a voice, in the order they travel with a note
engine.params = {
  wave: 0,
  attack: 1,
  decay: 2,
  sustain: 3,
  release: 4,
  cutoff: 5,
  res: 6,
  env: 7,
  gain: 8,
  pan: 9,
  detune: 10,
  pw: 11,
  delay: 12,
  room: 13,
  glide: 14,
  fm: 15,
  ratio: 16,
  drive: 17,
  vel: 18,
  gate: 19,
}
engine.NP = 20
engine.param_names = {}
for(let local e in entries(engine.params)){
  engine.param_names[e[1]] = e[0]
}
// what a player's parameters are until the piece sets them
engine.defaults = {
  wave: 0,
  attack: 0.005,
  decay: 0.2,
  sustain: 0.6,
  release: 0.2,
  cutoff: 0.8,
  res: 0.1,
  env: 0.0,
  gain: 0.5,
  pan: 0.0,
  detune: 0.0,
  pw: 0.5,
  delay: 0.0,
  room: 0.0,
  glide: 0.0,
  fm: 2.0,
  ratio: 2.0,
  drive: 0.0,
  vel: 1.0,
  gate: 0.25,
}
engine.waves = {
  saw: 0,
  square: 1,
  tri: 2,
  sine: 3,
  noise: 4,
  fm: 5,
  kick: 6,
  snare: 7,
  hat: 8,
  open: 9,
  clap: 10,
  tom: 11,
  rim: 12,
  // the 808: a kick sweeping down and driven, a snare of two resonators
  // and noise, hats of six square waves (the closed one chokes the open),
  // a clap of three bursts, a cowbell of two squares
  kick808: 13,
  snare808: 14,
  hat808: 15,
  open808: 16,
  clap808: 17,
  cowbell: 18,
  // seven saws spread around the pitch (detune: the outer ones' cents,
  // 18 when 0; pw: how loud the six beside the middle one are)
  supersaw: 19,
}
// the effects' parameters: delay time in seconds, its feedback and tone,
// the reverb's size and damping, the master gain
engine.fx = {time: 0, feedback: 1, tone: 2, size: 3, damp: 4, master: 5}
engine.NF = 6
engine.fx_defaults = {
  time: 0.375, feedback: 0.4, tone: 0.5, size: 0.7, damp: 0.4, master: 0.8
}

// an event: time (samples), kind, player, note or parameter, then the
// parameters of a note (NONE for the player's value) or a set's value
engine.kinds = {NOTE: 0, SET: 1, OFF: 2, FX: 3, HUSH: 4}
engine.ES = 4 + engine.NP
engine.NONE = -1.0e9
// the cells of ctl: the ring's counters, the engine's clock, voices in use
engine.ctl = {WRITE: 0, READ: 1, PLAYED: 2, VOICES: 3, SIZE: 8}
// meters: one per player (its loudest voice's envelope), then the output's
// left and right peak
engine.METERS = engine.MAXP + 2

kernel {
  struct Voice {
    on: int32,
    player: int32,
    stage: int32,
    ctr: int32,
    rnd: int64,
    note: double,
    freq: double,
    target: double,
    gate: double,
    env: double,
    amp: double,
    penv: double,
    t: double,
    phase: double,
    phase2: double,
    ic1: double,
    ic2: double,
    lp: double,
    g: double,
    k: double,
    pl: double,
    pr: double,
    ac: double,
    dc: double,
    rc: double,
    gl: double,
    pk: double,
    d1: double,
    d2: double,
    p3: double,
    p4: double,
    p5: double,
    p6: double,
    p7: double,
  }
  local NP = 20
  local WAVE = 0
  local SUSTAIN = 3
  local CUTOFF = 5
  local RES = 6
  local ENV = 7
  local GAIN = 8
  local PAN = 9
  local DETUNE = 10
  local PW = 11
  local DELAY = 12
  local ROOM = 13
  local FM = 15
  local RATIO = 16
  local DRIVE = 17
  local VEL = 18
  local FX_TIME = 0
  local FX_FEEDBACK = 1
  local FX_TONE = 2
  local FX_SIZE = 3
  local FX_DAMP = 4
  local FX_MASTER = 5

  // the delay line and the reverb's combs and allpasses
  local dl: float[262144]
  local dpos = 0
  local dtime = 0.0
  local dlp = 0.0
  local c0: float[4096]
  local c1: float[4096]
  local c2: float[4096]
  local c3: float[4096]
  local cp = 0
  local f0 = 0.0
  local f1 = 0.0
  local f2 = 0.0
  local f3 = 0.0
  local a0: float[2048]
  local a1: float[2048]
  local ap = 0
  local peak_l = 0.0
  local peak_r = 0.0

  local func white(v: Voice): float {
    v.rnd = (v.rnd * 6364136223846793005 + 1442695040888963407) &
      9223372036854775807
    return float((v.rnd >> 20) & 1048575) / 524288.0 - 1.0
  }

  // the polyblep correction at a discontinuity
  local func blep(t: float, dt: float): float {
    local y = 0.0
    if(t < dt){
      local x = t / dt
      y = x + x - x * x - 1.0
    } else if(t > 1.0 - dt){
      local x = (t - 1.0) / dt
      y = x * x + x + x + 1.0
    }
    return y
  }

  local func comb(
    buf: float[], n: int, x: float, fb: float, damp: float, f: float
  ): float {
    local y = buf[cp % n]
    f = y * (1.0 - damp) + f * damp
    buf[cp % n] = x + f * fb
    return y
  }

  // renders frames start .. start + n of out (interleaved stereo)
  func render(
    out: float[], start: int, n: int, sr: double, voices: Voice[], vp: double[],
    fx: double[], meters: double[]
  ){
    local nv = len(voices)
    local np = len(meters) - 2
    local mdecay = exp(-float(n) / (sr * 0.08))
    for(local p = 0; p < np; p += 1){
      meters[p] = meters[p] * mdecay
    }
    local dmax = len(dl) - 4
    local dtarget = clamp(fx[FX_TIME] * sr, 1.0, float(dmax))
    local tone = fx[FX_TONE]
    local tcoef = 0.02 + tone * tone * 0.9
    local fb = clamp(fx[FX_FEEDBACK], 0.0, 0.95)
    local scale = sr / 44100.0
    local n0 = int(1116 * scale)
    local n1 = int(1188 * scale)
    local n2 = int(1277 * scale)
    local n3 = int(1356 * scale)
    local m0 = int(556 * scale)
    local m1 = int(441 * scale)
    local rfb = 0.72 + clamp(fx[FX_SIZE], 0.0, 1.0) * 0.26
    local damp = clamp(fx[FX_DAMP], 0.0, 1.0) * 0.8
    local master = fx[FX_MASTER]
    local inv = 1.0 / sr
    local pdecay = exp(-1.0 / (sr * 0.1))
    for(local i = 0; i < n; i += 1){
      local l = 0.0
      local r = 0.0
      local dsend = 0.0
      local rsend = 0.0
      for(local vi = 0; vi < nv; vi += 1){
        local v = voices[vi]
        if(v.on == 0){
          continue
        }
        local pb = vi * NP
        local wave = int(vp[pb + WAVE])
        // the envelope
        if(wave < 6){
          if(v.stage == 0){
            v.env += v.ac
            if(v.env >= 1.0){
              v.env = 1.0
              v.stage = 1
            }
          } else if(v.stage == 1){
            v.env += (vp[pb + SUSTAIN] - v.env) * v.dc
          } else {
            v.env *= v.rc
            if(v.env < 0.0005){
              v.on = 0
              continue
            }
          }
          if(v.gate >= 0.0 and v.stage < 2){
            v.gate -= 1.0
            if(v.gate <= 0.0){
              v.stage = 2
            }
          }
        } else {
          v.amp *= v.dc
          v.penv *= v.pk
          if(v.amp < 0.001){
            v.on = 0
            continue
          }
          v.env = v.amp
        }
        v.t += inv
        v.freq += (v.target - v.freq) * v.gl
        local dt = v.freq * inv
        local y = 0.0
        if(wave == 0){
          v.phase += dt
          v.phase -= floor(v.phase)
          y = 2.0 * v.phase - 1.0 - blep(v.phase, dt)
          local det = vp[pb + DETUNE]
          if(det != 0.0){
            local dt2 = dt * exp2(det / 1200.0)
            v.phase2 += dt2
            v.phase2 -= floor(v.phase2)
            y = (y + 2.0 * v.phase2 - 1.0 - blep(v.phase2, dt2)) * 0.6
          }
        } else if(wave == 1){
          v.phase += dt
          v.phase -= floor(v.phase)
          local pw = clamp(vp[pb + PW], 0.05, 0.95)
          y = select(v.phase < pw, 1.0, -1.0)
          y += blep(v.phase, dt)
          local t2 = v.phase + 1.0 - pw
          t2 -= floor(t2)
          y -= blep(t2, dt)
          local det = vp[pb + DETUNE]
          if(det != 0.0){
            local dt2 = dt * exp2(det / 1200.0)
            v.phase2 += dt2
            v.phase2 -= floor(v.phase2)
            local y2 = select(v.phase2 < pw, 1.0, -1.0) + blep(v.phase2, dt2)
            t2 = v.phase2 + 1.0 - pw
            t2 -= floor(t2)
            y2 -= blep(t2, dt2)
            y = (y + y2) * 0.6
          }
        } else if(wave == 2){
          v.phase += dt
          v.phase -= floor(v.phase)
          y = 1.0 - 4.0 * abs(v.phase - 0.5)
        } else if(wave == 3){
          v.phase += dt
          v.phase -= floor(v.phase)
          y = sin(v.phase * TAU)
        } else if(wave == 4){
          y = white(v)
        } else if(wave == 5){
          v.phase += dt
          v.phase -= floor(v.phase)
          v.phase2 += dt * vp[pb + RATIO]
          v.phase2 -= floor(v.phase2)
          y = sin(v.phase * TAU + vp[pb + FM] * v.env * sin(v.phase2 * TAU))
        } else if(wave == 6){
          // kick: a sine dropping from eight times its pitch, with a click
          v.phase += dt * (1.0 + 7.0 * v.penv)
          v.phase -= floor(v.phase)
          y = sin(v.phase * TAU) + white(v) * v.penv * 0.3
        } else if(wave == 7){
          // snare: a short tone and a noise tail
          v.phase += dt
          v.phase -= floor(v.phase)
          local nz = white(v)
          v.lp += (nz - v.lp) * 0.2
          y = sin(v.phase * TAU) * v.penv * 0.8 + (nz - v.lp) * 0.7
        } else if(wave == 8 or wave == 9){
          // hats: noise above a one-pole
          local nz = white(v)
          v.lp += (nz - v.lp) * 0.35
          y = (nz - v.lp) * 0.8
        } else if(wave == 10){
          // clap: three bursts, then a tail
          local nz = white(v)
          v.lp += (nz - v.lp) * 0.15
          local e = 1.0
          if(v.t < 0.03){
            e = 1.0 - fract(v.t * 100.0)
            v.amp = 1.0
          }
          y = (nz - v.lp) * e * 0.9
        } else if(wave == 11){
          // tom: a sine dropping a little
          v.phase += dt * (1.0 + 1.5 * v.penv)
          v.phase -= floor(v.phase)
          y = sin(v.phase * TAU)
        } else if(wave == 12){
          // rim: a tick
          v.phase += dt
          v.phase -= floor(v.phase)
          y = sin(v.phase * TAU) * v.penv + white(v) * v.penv * 0.5
        } else if(wave == 13){
          // 808 kick: a sine whose pitch sweeps down from the hit, driven
          // hard while it is loud (the click and the punch)
          v.phase += dt * (1.0 + 3.5 * v.penv)
          v.phase -= floor(v.phase)
          y = tanh(sin(v.phase * TAU) * (1.0 + 3.0 * v.amp)) * 0.8
        } else if(wave == 14){
          // 808 snare: two resonators (the second 1.83 times the first)
          // decaying with the pitch envelope, and noise through a high pass
          v.phase += dt
          v.phase -= floor(v.phase)
          v.phase2 += dt * 1.83
          v.phase2 -= floor(v.phase2)
          local nz = white(v)
          v.d1 += (nz - v.d1) * (1.0 - exp(-TAU * 900.0 * inv))
          y = (sin(v.phase * TAU) * 0.7 + sin(v.phase2 * TAU) * 0.4) * v.penv * 0.8
          y += (nz - v.d1) * 0.9
        } else if(wave == 15 or wave == 16){
          // 808 hats: six square waves at the 808's frequencies (scaled by
          // the note, 830 Hz being as it was) through a high pass; the
          // closed and the open differ in their decay, and a closed hat
          // chokes an open one (note_on)
          local s = v.t * v.freq / 830.0
          local metal = select(fract(s * 205.3) < 0.5, 1.0, -1.0)
          metal += select(fract(s * 304.4) < 0.5, 1.0, -1.0)
          metal += select(fract(s * 369.6) < 0.5, 1.0, -1.0)
          metal += select(fract(s * 522.7) < 0.5, 1.0, -1.0)
          metal += select(fract(s * 540.0) < 0.5, 1.0, -1.0)
          metal += select(fract(s * 800.0) < 0.5, 1.0, -1.0)
          // the six summed (-6..6) through two one-poles at 5 kHz: what
          // is left are the edges, the metallic hiss; soft-clipped
          local hk = 1.0 - exp(-TAU * 5000.0 * inv)
          v.d1 += (metal - v.d1) * hk
          local h1 = metal - v.d1
          v.d2 += (h1 - v.d2) * hk
          y = tanh((h1 - v.d2) * 0.7) * 1.3
        } else if(wave == 17){
          // 808 clap: noise through a band pass, three bursts 9 ms apart,
          // then the tail
          local nz = white(v)
          local f = 2.0 * sin(PI * 1100.0 * inv)
          v.d1 += f * v.d2
          v.d2 += f * (nz - v.d1 - 0.8 * v.d2)
          local e = 1.0
          if(v.t < 0.027){
            e = exp(-fract(v.t * 111.1) * 2.6)
            v.amp = 1.0
          }
          y = v.d2 * e * 2.5
        } else if(wave == 19){
          // supersaw: seven saws, the middle one at the pitch, six spread
          // around it as the JP-8000 spread them, the outer ones DETUNE
          // cents off, mixed in at PW; band-limited each
          local det = vp[pb + DETUNE]
          if(det == 0.0){
            det = 18.0
          }
          local side = clamp(vp[pb + PW], 0.0, 1.0)
          v.phase += dt
          v.phase -= floor(v.phase)
          y = 2.0 * v.phase - 1.0 - blep(v.phase, dt)
          local d2 = dt * exp2(det * -1.0239 / 1200.0)
          v.phase2 += d2
          v.phase2 -= floor(v.phase2)
          local s = 2.0 * v.phase2 - 1.0 - blep(v.phase2, d2)
          local d3 = dt * exp2(det * -0.5852 / 1200.0)
          v.p3 += d3
          v.p3 -= floor(v.p3)
          s += 2.0 * v.p3 - 1.0 - blep(v.p3, d3)
          local d4 = dt * exp2(det * -0.1817 / 1200.0)
          v.p4 += d4
          v.p4 -= floor(v.p4)
          s += 2.0 * v.p4 - 1.0 - blep(v.p4, d4)
          local d5 = dt * exp2(det * 0.1853 / 1200.0)
          v.p5 += d5
          v.p5 -= floor(v.p5)
          s += 2.0 * v.p5 - 1.0 - blep(v.p5, d5)
          local d6 = dt * exp2(det * 0.5785 / 1200.0)
          v.p6 += d6
          v.p6 -= floor(v.p6)
          s += 2.0 * v.p6 - 1.0 - blep(v.p6, d6)
          local d7 = dt * exp2(det / 1200.0)
          v.p7 += d7
          v.p7 -= floor(v.p7)
          s += 2.0 * v.p7 - 1.0 - blep(v.p7, d7)
          y = (y + s * side) / (1.0 + 6.0 * side) * 2.2
        } else {
          // 808 cowbell: two square waves (587 and 845 Hz at its note)
          // through a band pass
          v.phase += dt
          v.phase -= floor(v.phase)
          v.phase2 += dt * 1.4395
          v.phase2 -= floor(v.phase2)
          local cb = (select(v.phase < 0.5, 1.0, -1.0) + select(v.phase2 < 0.5, 1.0, -1.0)) * 0.5
          local f = 2.0 * sin(PI * 2200.0 * inv)
          v.d1 += f * v.d2
          v.d2 += f * (cb - v.d1 - 0.6 * v.d2)
          y = v.d2 * 1.5
        }
        // the filter, its coefficients every eight samples
        if((v.ctr & 7) == 0){
          local cut = vp[pb + CUTOFF] + vp[pb + ENV] * v.env
          local fc = clamp(
            20.0 * exp2(clamp(cut, 0.0, 1.0) * 10.0), 20.0, sr * 0.45
          )
          v.g = tan(PI * fc * inv)
          v.k = 2.0 - 1.96 * clamp(vp[pb + RES], 0.0, 1.0)
          local pan = clamp(vp[pb + PAN], -1.0, 1.0)
          v.pl = cos((pan + 1.0) * PI * 0.25)
          v.pr = sin((pan + 1.0) * PI * 0.25)
        }
        v.ctr += 1
        if(vp[pb + CUTOFF] + vp[pb + ENV] * v.env < 1.0){
          local g = v.g
          local a1 = 1.0 / (1.0 + g * (g + v.k))
          local a2 = g * a1
          local a3 = g * a2
          local v3 = y - v.ic2
          local v1 = a1 * v.ic1 + a2 * v3
          local v2 = v.ic2 + a2 * v.ic1 + a3 * v3
          v.ic1 = 2.0 * v1 - v.ic1
          v.ic2 = 2.0 * v2 - v.ic2
          y = v2
        }
        local drive = vp[pb + DRIVE]
        if(drive > 0.0){
          y = tanh(y * (1.0 + drive * 8.0)) / (1.0 + drive * 0.3)
        }
        local a = v.env * vp[pb + VEL] * vp[pb + GAIN]
        y *= a
        l += y * v.pl
        r += y * v.pr
        dsend += y * vp[pb + DELAY]
        rsend += y * vp[pb + ROOM]
        local pm = v.env * vp[pb + VEL]
        if(pm > meters[v.player]){
          meters[v.player] = pm
        }
      }
      // the delay: a tape, its time slides
      dtime += (dtarget - dtime) * 0.0005
      local rp = float(dpos) - dtime
      if(rp < 0.0){
        rp += float(dmax)
      }
      local ri = int(rp)
      local frac = rp - float(ri)
      local d = dl[ri % dmax] * (1.0 - frac) + dl[(ri + 1) % dmax] * frac
      dlp += (d - dlp) * tcoef
      dl[dpos] = dsend + dlp * fb
      dpos = (dpos + 1) % dmax
      l += d * 0.8
      r += d * 0.8
      // the reverb: four combs into two allpasses
      local rin = rsend * 0.5
      local rv = comb(c0, n0, rin, rfb, damp, f0)
      f0 = rv * (1.0 - damp) + f0 * damp
      local rv1 = comb(c1, n1, rin, rfb, damp, f1)
      f1 = rv1 * (1.0 - damp) + f1 * damp
      local rv2 = comb(c2, n2, rin, rfb, damp, f2)
      f2 = rv2 * (1.0 - damp) + f2 * damp
      local rv3 = comb(c3, n3, rin, rfb, damp, f3)
      f3 = rv3 * (1.0 - damp) + f3 * damp
      cp += 1
      local s = (rv + rv1 + rv2 + rv3) * 0.25
      local b0 = a0[ap % m0]
      local o0 = -s + b0
      a0[ap % m0] = s + b0 * 0.5
      local b1 = a1[ap % m1]
      local o1 = -o0 + b1
      a1[ap % m1] = o0 + b1 * 0.5
      ap += 1
      l += o1 * 0.6
      r += o0 * 0.6
      l = tanh(l * master)
      r = tanh(r * master)
      peak_l = max(peak_l * pdecay, abs(l))
      peak_r = max(peak_r * pdecay, abs(r))
      out[(start + i) * 2] = l
      out[(start + i) * 2 + 1] = r
    }
    meters[np] = peak_l
    meters[np + 1] = peak_r
  }
}

engine.Voice = Voice

// arrays(make: func(type, n)) -> {ev, ctl, meters}: the buffers the piece
// and the engine share (buffer.shared for a stream, buffer.new offline)
func engine.arrays(make){
  return {
    ev: make("double", engine.MAXE * engine.ES),
    ctl: make("double", engine.ctl.SIZE),
    meters: make("double", engine.METERS),
  }
}

// send(a, time, kind, player, note, params?: {double}): an instruction into
// the ring, dropped when the ring is full
func engine.send(a, time, kind, player, note, params){
  local w = to_int(a.ctl[engine.ctl.WRITE])
  local r = to_int(a.ctl[engine.ctl.READ])
  if(w - r >= engine.MAXE){
    return false
  }
  local base = (w % engine.MAXE) * engine.ES
  local ev = a.ev
  ev[base] = time
  ev[base + 1] = kind
  ev[base + 2] = player
  ev[base + 3] = note
  for(local k = 0; k < engine.NP; k = k + 1){
    local v = engine.NONE
    if(params != null and params[k] != null){
      v = params[k]
    }
    ev[base + 4 + k] = v
  }
  a.ctl[engine.ctl.WRITE] = w + 1
  return true
}

local func freq_of(note){
  return 440.0 * math.exp(math.log(2) * (note - 69) / 12)
}

// new(a: the arrays, sample_rate: int) -> block function (out: float[frames
// * 2], frames): the engine
func engine.new(a, sample_rate){
  local sr = sample_rate * 1.0
  local NP = engine.NP
  local P = engine.params
  local voices = Voice:array(engine.MAXV)
  local vp = kernel.double:array(engine.MAXV * NP)
  local pp = kernel.double:array(engine.MAXP * NP)
  local fx = kernel.double:array(engine.NF)
  for(local p = 0; p < engine.MAXP; p = p + 1){
    for(let local e in entries(engine.params)){
      pp[p * NP + e[1]] = engine.defaults[e[0]]
    }
  }
  for(let local e in entries(engine.fx)){
    fx[e[1]] = engine.fx_defaults[e[0]]
  }
  local played = 0
  local pending = {}
  local seed = 12345
  local ctl = a.ctl
  local ev = a.ev

  local func coefs(v, i){
    local pb = i * NP
    v.ac = 1.0 / (math.max(vp[pb + P.attack], 0.0005) * sr)
    local wave = to_int(vp[pb + P.wave])
    if(wave >= engine.waves.kick){
      v.dc = math.exp(-1.0 / (math.max(vp[pb + P.decay], 0.005) * sr))
    } else {
      v.dc = 1.0 - math.exp(-1.0 / (math.max(vp[pb + P.decay], 0.001) * sr))
    }
    v.rc = math.exp(-1.0 / (math.max(vp[pb + P.release], 0.002) * sr))
    local glide = vp[pb + P.glide]
    if(glide > 0.0005){
      v.gl = 1.0 - math.exp(-1.0 / (glide * sr))
    } else {
      v.gl = 1.0
    }
  }

  local func note_on(e){
    local player = to_int(e[2])
    local note = e[3]
    // a free voice, or the quietest
    local pick = -1
    local quiet = -1
    local quietest = 1.0e9
    local last_freq = null
    for(local i = 0; i < engine.MAXV; i = i + 1){
      local v = voices[i]
      if(v.on == 0){
        if(pick < 0){
          pick = i
        }
      } else {
        if(v.player == player){
          last_freq = v.freq
        }
        if(v.env < quietest){
          quietest = v.env
          quiet = i
        }
      }
    }
    if(pick < 0){
      pick = quiet
    }
    local v = voices[pick]
    local pb = pick * NP
    for(local k = 0; k < NP; k = k + 1){
      local x = e[4 + k]
      if(x == engine.NONE){
        vp[pb + k] = pp[player * NP + k]
      } else {
        vp[pb + k] = x
      }
    }
    v.on = 1
    v.player = player
    v.stage = 0
    v.ctr = 0
    seed = seed * 1103515245 + 12345
    v.rnd = seed % 2147483647
    v.note = note
    v.target = freq_of(note)
    v.freq = v.target
    coefs(v, pick)
    local wave = to_int(vp[pb + P.wave])
    if(wave == engine.waves.hat808){
      // a closed hat chokes the open hats of its player, in 8 ms
      for(local i = 0; i < engine.MAXV; i = i + 1){
        local o = voices[i]
        if(i != pick and o.on != 0 and o.player == player and
          to_int(vp[i * NP + P.wave]) == engine.waves.open808){
          o.dc = math.exp(-1.0 / (0.008 * sr))
        }
      }
    }
    if(vp[pb + P.glide] > 0.0005 and last_freq != null){
      v.freq = last_freq
    }
    local dur = vp[pb + P.gate]
    if(dur < 0){
      v.gate = -1.0
    } else {
      v.gate = dur * sr
    }
    v.env = 0.0
    v.amp = 1.0
    v.penv = 1.0
    v.t = 0.0
    v.phase = 0.0
    v.phase2 = 0.0
    v.ic1 = 0.0
    v.ic2 = 0.0
    v.lp = 0.0
    v.d1 = 0.0
    v.d2 = 0.0
    // the supersaw's saws start apart, so a chord does not click together
    v.p3 = 0.17 + pick * 0.013
    v.p4 = 0.41 + pick * 0.021
    v.p5 = 0.63 + pick * 0.007
    v.p6 = 0.29 + pick * 0.017
    v.p7 = 0.86 + pick * 0.011
    if(wave == engine.waves.supersaw){
      v.phase2 = 0.52 + pick * 0.009
    }
    // the pitch envelope: the 808 snare's tone rings longer than a sweep
    local sweep = 0.03
    if(wave == engine.waves.snare808){
      sweep = 0.12
    }
    v.pk = math.exp(-1.0 / (sweep * sr))
    v.g = 0.5
    v.k = 1.0
    v.pl = 0.7
    v.pr = 0.7
  }

  local func set_param(player, k, value){
    pp[player * NP + k] = value
    for(local i = 0; i < engine.MAXV; i = i + 1){
      local v = voices[i]
      if(v.on != 0 and v.player == player){
        vp[i * NP + k] = value
        if(k == P.attack or k == P.decay or k == P.release or k == P.glide){
          coefs(v, i)
        }
      }
    }
  }

  local func apply(e){
    local kind = to_int(e[1])
    if(kind == engine.kinds.NOTE){
      note_on(e)
    } else if(kind == engine.kinds.SET){
      set_param(to_int(e[2]), to_int(e[3]), e[4])
    } else if(kind == engine.kinds.OFF){
      local player = to_int(e[2])
      for(local i = 0; i < engine.MAXV; i = i + 1){
        local v = voices[i]
        if(v.on != 0 and v.player == player and v.note == e[3] and v.gate < 0.0){
          v.gate = 0.0
        }
      }
    } else if(kind == engine.kinds.FX){
      fx[to_int(e[3])] = e[4]
    } else if(kind == engine.kinds.HUSH){
      local player = to_int(e[2])
      for(local i = 0; i < engine.MAXV; i = i + 1){
        local v = voices[i]
        if(v.on != 0 and (player < 0 or v.player == player)){
          if(v.stage < 2){
            v.stage = 2
          }
          v.gate = 0.0
        }
      }
    }
  }

  // the ring's new events into pending, sorted by time
  local func take(){
    local w = to_int(ctl[engine.ctl.WRITE])
    local r = to_int(ctl[engine.ctl.READ])
    if(w == r){
      return
    }
    for(r < w){
      local base = (r % engine.MAXE) * engine.ES
      local e = {}
      for(local k = 0; k < engine.ES; k = k + 1){
        append(e, ev[base + k])
      }
      append(pending, e)
      r = r + 1
    }
    ctl[engine.ctl.READ] = r
    require("slang/table").sort(pending, func(x, y){ return x[0] < y[0] })
  }

  return func(out, frames){
    take()
    local pos = 0
    local stop = played + frames
    local i = 0
    for(i < len(pending)){
      local e = pending[i]
      if(e[0] >= stop){
        break
      }
      local at = to_int(e[0]) - played
      if(at > pos){
        render(out, pos, at - pos, sr, voices, vp, fx, a.meters)
        pos = at
      }
      apply(e)
      i = i + 1
    }
    if(i > 0){
      pending = require("slang/table").slice(pending, i)
    }
    if(frames > pos){
      render(out, pos, frames - pos, sr, voices, vp, fx, a.meters)
    }
    played = stop
    ctl[engine.ctl.PLAYED] = played
    local active = 0
    for(local k = 0; k < engine.MAXV; k = k + 1){
      if(voices[k].on != 0){
        active = active + 1
      }
    }
    ctl[engine.ctl.VOICES] = active
  }
}

// render(block, frames) -> {left, right}: frames of sound from a block
// function, in blocks of 128
func engine.render(block, frames){
  local left = buffer.new("float", frames)
  local right = buffer.new("float", frames)
  local out = buffer.new("float", 256)
  local at = 0
  for(at < frames){
    local n = 128
    if(frames - at < n){
      n = frames - at
    }
    block(out, n)
    for(local i = 0; i < n; i = i + 1){
      left[at + i] = out[i * 2]
      right[at + i] = out[i * 2 + 1]
    }
    at = at + n
  }
  return {left: left, right: right}
}

return engine
