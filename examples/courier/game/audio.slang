extension "kernel/syntax"
// game/audio: the game's sound, computed while it plays in the render
// isolate of raylib/stream (game/sound starts it and talks to it). One
// kernel renders everything, in stereo:
//
// - the car: a hover turbine (two detuned saws through a resonant filter
//   that opens with the throttle, a sub, a whine that climbs with the
//   speed), the wind (noise through band-passes that follow the speed,
//   with gusts, different in each ear), the boost (a roar and a rumble
//   with crackle), the magnet (a pulsing hum while it holds);
// - the city at night: a soft pad over four chords, a bass and a plucked
//   arpeggio through a delay (rl M mutes it);
// - one-shots as voices: hits (a thump, a crunch and the inharmonic ring
//   of metal), scrapes, the whoosh of a near miss that passes from one
//   ear to the other, the ping of a chain of them (climbing), the
//   magnet's clunk, chimes made of FM bells, the buzz of a late
//   delivery, the boom of a wreck with debris after it;
// - a small reverb (four combs and two all-passes per ear) that the bells,
//   the music and the hits share.
//
// The controls come through a shared buffer (indexes below), the one-shots
// through a channel as {name, gain, pan}.
local kernel = require("kernel")
local math = require("slang/math")

local audio = {}

// the cells of the shared controls
audio.SPEED = 0 // m/s
audio.THRUST = 1 // 0..1
audio.BOOST = 2 // 0 or 1
audio.MAGNET = 3 // 0 off, 1 seeking, 2 holding
audio.MASTER = 4 // 0..1
audio.MUSIC = 5 // 0..1
audio.DRIVING = 6 // 1 while the car flies (the title is quiet)
audio.CONTROLS = 8

kernel {
  struct Voice {
    kind: int32,
    t: double,
    dur: double,
    gain: double,
    pan: double,
    send: double,
    f: double,
    p1: double,
    p2: double,
    p3: double,
    p4: double,
    lp: double,
    bp: double,
    lp2: double,
    bp2: double,
    x: double,
  }

  local HIT = 1
  local SCRAPE = 2
  local WHOOSH = 3
  local CLUNK = 4
  local RELEASE = 5
  local PICKUP = 6
  local DELIVER = 7
  local LATE = 8
  local WRECK = 9
  local UI = 10
  local LEVEL = 11
  local IGNITE = 12
  local CHAIN = 13

  local SR = 48000.0
  local DT = 1.0 / 48000.0

  // ---- state: the smoothed controls, oscillators, filters, the reverb
  local seed = 1234567
  local speed = 0.0
  local thrust = 0.0
  local boost = 0.0
  local magnet = 0.0
  local driving = 0.0
  local music = 0.0
  local master = 1.0
  local e1 = 0.0
  local e2 = 0.0
  local e3 = 0.0
  local e4 = 0.0
  local elp = 0.0
  local ebp = 0.0
  local wl_lp = 0.0
  local wl_bp = 0.0
  local wr_lp = 0.0
  local wr_bp = 0.0
  local hl_lp = 0.0
  local hr_lp = 0.0
  local gust = 0.0
  local b_lp = 0.0
  local b_bp = 0.0
  local b_ph = 0.0
  local crackle = 0.0
  local m_ph = 0.0
  local m_lp = 0.0
  // the music: time, the pad's phases and filter, the arpeggio
  local mt = 0.0
  local pad_ph: double[8]
  local pad_f: double[8]
  local pad_lp = 0.0
  local pad_rp = 0.0
  local pad_bp = 0.0
  local pad_rb = 0.0
  local bass_ph = 0.0
  local bass_f = 55.0
  local arp_t = 10.0
  local arp_f = 440.0
  local arp_ph = 0.0
  local arp_ph2 = 0.0
  local arp_step = 0
  local delay_l: float[24000]
  local delay_r: float[24000]
  local delay_at = 0
  // the reverb: 8 combs and 4 all-passes in one line of memory
  local rv: float[16384]
  local rv_at: int32[12]
  local rv_damp: double[8]

  local func noise(): float {
    seed = seed * 6364136223846793005 + 1442695040888963407
    return float((seed >> 33) & 2147483647) / 1073741824.0 - 1.0
  }

  local func midi(n: float): float {
    return 440.0 * exp2((n - 69.0) / 12.0)
  }

  // a Chamberlin state-variable filter's coefficient for a cutoff
  local func svf_f(fc: float): float {
    return 2.0 * sin(PI * min(fc, 7000.0) / SR)
  }

  local func saw(p: float): float {
    return 2.0 * p - 1.0
  }

  local func soft(x: float): float {
    return tanh(x)
  }

  // the pan law: the left gain of a pan in -1..1 (the right is of -pan)
  local func left(pan: float): float {
    return cos((pan + 1.0) * PI * 0.25)
  }

  // a comb of the reverb: its delay line starts at `from`, `n` long
  local func comb(k: int, from: int, n: int, x: float): float {
    local at = rv_at[k]
    local y = rv[from + at]
    rv_damp[k] = y * 0.6 + rv_damp[k] * 0.4
    rv[from + at] = float(x + rv_damp[k] * 0.82)
    rv_at[k] = (at + 1) % n
    return y
  }

  local func allpass(k: int, from: int, n: int, x: float): float {
    local at = rv_at[k]
    local b = rv[from + at]
    rv[from + at] = float(x + b * 0.5)
    rv_at[k] = (at + 1) % n
    return b - x
  }

  // an FM bell: carrier f, modulator at 3.5 f, the index fading with it
  local func bell(t: float, f: float, decay: float): float {
    if(t < 0.0){
      return 0.0
    }
    local env = exp(-t * decay)
    local mod = sin(TAU * f * 3.5 * t) * 2.2 * exp(-t * decay * 2.5)
    return sin(TAU * f * t + mod) * env * min(1.0, t * 400.0)
  }

  // one-shot voices: a mono sample, the voice's state moving on
  local func shot_a(v: Voice): float {
    local t = v.t
    local u = t / v.dur
    local s = 0.0
    if(v.kind == HIT){
      // a thump dropping in pitch, a crunch of noise, ringing metal
      local fq = 40.0 + 90.0 * exp(-t * 30.0)
      v.p1 = fract(v.p1 + fq * DT)
      local thump = sin(TAU * v.p1) * exp(-t * 14.0)
      local fn = svf_f(1800.0 * v.f)
      v.lp += fn * v.bp
      v.bp += fn * (noise() - v.lp - 0.8 * v.bp)
      local crunch = v.bp * exp(-t * 28.0) * 1.4
      local ring = sin(TAU * 523.0 * v.f * t) * exp(-t * 9.0) * 0.35 +
        sin(TAU * 1187.0 * v.f * t) * exp(-t * 12.0) * 0.25 +
        sin(TAU * 1873.0 * v.f * t) * exp(-t * 16.0) * 0.18 +
        sin(TAU * 2711.0 * v.f * t) * exp(-t * 22.0) * 0.12
      s = thump * 1.1 + crunch + ring * 0.6
    } else if(v.kind == SCRAPE){
      // grit: band-passed noise, its level jumping
      if(fract(t * 60.0) < fract((t - DT) * 60.0)){
        v.x = 0.4 + 0.6 * abs(noise())
      }
      local fn = svf_f(2600.0 * v.f)
      v.lp += fn * v.bp
      v.bp += fn * (noise() - v.lp - 0.5 * v.bp)
      s = v.bp * v.x * sin(PI * u) * 1.2
    } else if(v.kind == WHOOSH){
      // air rushing by: a band falling as the thing passes, from the side
      // it came from to the other
      local fc = 2400.0 * exp(-u * 2.2) + 250.0
      local fn = svf_f(fc)
      v.lp += fn * v.bp
      v.bp += fn * (noise() - v.lp - 0.35 * v.bp)
      local env = sin(PI * min(1.0, u * 1.25))
      s = v.bp * env * env * 1.1
      v.pan = v.f * (1.0 - 2.0 * smoothstep(0.2, 0.8, u))
    } else if(v.kind == CLUNK){
      // the magnet takes hold: a thud, a click, a ping
      v.p1 = fract(v.p1 + (70.0 + 60.0 * exp(-t * 40.0)) * DT)
      s = sin(TAU * v.p1) * exp(-t * 18.0) + noise() * exp(-t * 200.0) * 0.6 +
        sin(TAU * 2350.0 * t) * exp(-t * 35.0) * 0.25
    } else if(v.kind == RELEASE){
      // the magnet lets go: a rising zip
      v.p1 = fract(v.p1 + (280.0 + 900.0 * u * u) * DT)
      s = (sin(TAU * v.p1) * 0.6 + noise() * 0.15) * (1.0 - u) *
        min(1.0, t * 200.0)
    } else if(v.kind == IGNITE){
      // the boost lights: a whump, the air sucked in
      local fn = svf_f(200.0 + 2400.0 * u)
      v.lp += fn * v.bp
      v.bp += fn * (noise() - v.lp - 0.5 * v.bp)
      v.p1 = fract(v.p1 + (50.0 + 40.0 * u) * DT)
      s = (v.bp * 0.8 * sin(PI * u) + sin(TAU * v.p1) * exp(-t * 6.0) * 0.8)
    }
    v.t += DT
    if(v.t >= v.dur){
      v.kind = 0
    }
    return s * v.gain
  }

  // the chimes, the buzz, the wreck, the click
  local func shot_b(v: Voice): float {
    local t = v.t
    local u = t / v.dur
    local s = 0.0
    if(v.kind == PICKUP){
      s = bell(t, 1318.5, 5.0) * 0.5 + bell(t - 0.09, 1975.5, 5.0) * 0.45
    } else if(v.kind == DELIVER){
      s = bell(t, 1046.5, 3.0) * 0.4 + bell(t - 0.08, 1318.5, 3.0) * 0.38 +
        bell(t - 0.16, 1568.0, 3.0) * 0.36 + bell(t - 0.24, 2093.0, 2.5) * 0.4
      // a shimmer over it
      s += sin(TAU * 4186.0 * t + sin(TAU * 7.0 * t) * 2.0) * exp(-t * 4.0) *
        0.06 * min(1.0, t * 20.0)
    } else if(v.kind == LEVEL){
      local step = 0.11
      s = bell(t, 784.0, 2.5) * 0.35 + bell(t - step, 1046.5, 2.5) * 0.35 +
        bell(t - step * 2.0, 1318.5, 2.5) * 0.35 +
        bell(t - step * 3.0, 1568.0, 2.0) * 0.35 +
        bell(t - step * 4.0, 2093.0, 1.6) * 0.45
    } else if(v.kind == LATE){
      // two falling buzzes
      local f = 440.0
      if(t > 0.22){
        f = 349.2
      }
      v.p1 = fract(v.p1 + f * DT)
      v.p2 = fract(v.p2 + f * 1.006 * DT)
      local raw = saw(v.p1) + saw(v.p2)
      local fn = svf_f(1400.0)
      v.lp += fn * v.bp
      v.bp += fn * (raw - v.lp - 0.6 * v.bp)
      local tt = t
      if(t > 0.22){
        tt = t - 0.22
      }
      s = v.lp * 0.35 * exp(-tt * 5.0) * min(1.0, tt * 300.0)
    } else if(v.kind == WRECK){
      // a boom, the crunch of it, then debris
      v.p1 = fract(v.p1 + (28.0 + 60.0 * exp(-t * 8.0)) * DT)
      local boom = sin(TAU * v.p1) * exp(-t * 2.5) * 1.3
      local fn = svf_f(300.0 + 1500.0 * exp(-t * 6.0))
      v.lp += fn * v.bp
      v.bp += fn * (noise() - v.lp - 0.7 * v.bp)
      local body = v.lp * exp(-t * 3.0) * 1.5
      if(fract(t * 9.0) < fract((t - DT) * 9.0) and abs(noise()) > 0.45){
        v.x = t
        v.f = 0.7 + abs(noise()) * 0.8
      }
      local dt = t - v.x
      local debris = 0.0
      if(v.x > 0.0){
        debris = (sin(TAU * 1300.0 * v.f * dt) * 0.5 +
          sin(TAU * 2900.0 * v.f * dt) * 0.3) * exp(-dt * 30.0) * exp(-t * 1.2)
      }
      s = boom + body + debris * 0.5
    } else if(v.kind == UI){
      s = sin(TAU * 1500.0 * t) * exp(-t * 90.0) * 0.5
    } else if(v.kind == CHAIN){
      // a near miss in a chain: a glassy ping, a step higher each time
      s = bell(t, 1046.5 * v.f, 9.0) * 0.4 + bell(t - 0.035, 2093.0 * v.f, 12.0) * 0.18
    }
    v.t += DT
    if(v.t >= v.dur){
      v.kind = 0
    }
    return s * v.gain
  }

  // the chord of the pad at music time t: four chords, six seconds each
  local func chord_note(c: int, k: int): float {
    // A minor, F, C, G: three notes each (MIDI), and the bass
    if(c == 0){
      return select(
        k == 0, 57.0, select(k == 1, 60.0, select(k == 2, 64.0, 45.0))
      )
    }
    if(c == 1){
      return select(
        k == 0, 57.0, select(k == 1, 60.0, select(k == 2, 65.0, 41.0))
      )
    }
    if(c == 2){
      return select(
        k == 0, 55.0, select(k == 1, 60.0, select(k == 2, 64.0, 48.0))
      )
    }
    return select(
      k == 0, 55.0, select(k == 1, 59.0, select(k == 2, 62.0, 43.0))
    )
  }

  // the car's sounds into out (stereo, replacing what is there)
  func car(out: float[], frames: int, ctl: float[]){
    local t_speed = float(ctl[0])
    local t_thrust = float(ctl[1])
    local t_boost = float(ctl[2])
    local t_magnet = select(ctl[3] > 1.5, 1.0, 0.0)
    local t_driving = float(ctl[6])
    for(local i = 0; i < frames; i += 1){
      speed += (t_speed - speed) * 0.0004
      thrust += (t_thrust - thrust) * 0.0015
      boost += (t_boost - boost) * select(t_boost > boost, 0.0012, 0.00025)
      magnet += (t_magnet - magnet) * 0.001
      driving += (t_driving - driving) * 0.0005
      mt += DT
      local sp = min(speed / 90.0, 1.5)

      // ---- the turbine
      local f0 = 46.0 + 34.0 * thrust + 70.0 * sp + 30.0 * boost
      e1 = fract(e1 + f0 * DT)
      e2 = fract(e2 + f0 * 1.007 * DT)
      e3 = fract(e3 + f0 * 0.5 * DT)
      e4 = fract(e4 + f0 * (6.5 + 0.03 * sin(TAU * 5.0 * mt)) * DT)
      local raw = saw(e1) + saw(e2) * 0.8
      local fn = svf_f(220.0 + 1600.0 * thrust + 900.0 * sp + 1500.0 * boost)
      elp += fn * ebp
      ebp += fn * (raw - elp - 0.45 * ebp)
      local turbine = elp * 0.35 + sin(TAU * e3) * 0.35 +
        sin(TAU * e4) * (0.03 + 0.07 * sp) * (0.4 + thrust)
      turbine *= (0.45 + 0.4 * thrust + 0.2 * sp) * driving
      local tl = turbine * (1.0 + 0.15 * sin(TAU * e2))
      local tr = turbine * (1.0 - 0.15 * sin(TAU * e2))

      // ---- the wind: different noise in each ear, gusts
      gust += ((noise() * 0.5 + 0.5) - gust) * 0.00005
      local wind_level = min(1.0, max(0.0, (speed - 8.0) / 70.0)) ^ 1.4 *
        (0.7 + 0.6 * gust) * driving
      local wf = svf_f(250.0 + speed * 18.0 + 500.0 * gust)
      wl_lp += wf * wl_bp
      wl_bp += wf * (noise() - wl_lp - 0.7 * wl_bp)
      wr_lp += wf * wr_bp
      wr_bp += wf * (noise() - wr_lp - 0.7 * wr_bp)
      local hiss = noise()
      hl_lp += (hiss - hl_lp) * 0.3
      hr_lp += (noise() - hr_lp) * 0.3
      local wl = (wl_bp * 0.9 + (hiss - hl_lp) * 0.12 * sp) * wind_level
      local wr = (wr_bp * 0.9 + (hiss - hr_lp) * 0.12 * sp) * wind_level

      // ---- the boost: a roar, a rumble, crackle
      local bf = svf_f(500.0 + 500.0 * boost + speed * 4.0)
      b_lp += bf * b_bp
      b_bp += bf * (noise() - b_lp - 0.6 * b_bp)
      b_ph = fract(b_ph + (38.0 + 12.0 * sp) * DT)
      if(noise() > 0.9993){
        crackle = 1.0
      }
      crackle *= 0.992
      local roar = (b_bp * 1.1 + b_lp * 0.5 + sin(TAU * b_ph) * 0.5 +
        crackle * noise() * 0.9) * boost * 0.55 * driving

      // ---- the magnet holding: a pulsing hum
      m_ph = fract(m_ph + 82.0 * DT)
      local hum_raw = select(m_ph < 0.5, 1.0, -1.0)
      m_lp += (hum_raw - m_lp) * 0.04
      local hum = m_lp * (0.6 + 0.4 * sin(TAU * 11.0 * mt)) * magnet * 0.12 *
        driving

      out[2 * i] = float(tl * 0.4 + wl * 0.55 + roar * 0.55 + hum)
      out[2 * i + 1] = float(tr * 0.4 + wr * 0.55 + roar * 0.55 + hum)
    }
  }

  // the music added to out, its reverb send into send (replacing it)
  func music_block(out: float[], send: float[], frames: int, ctl: float[]){
    local t_music = float(ctl[5])
    for(local i = 0; i < frames; i += 1){
      music += (t_music - music) * 0.0002
      local ml = 0.0
      local mr = 0.0
      local send_music = 0.0
      if(music > 0.001){
        local c = int(mt / 6.0) % 4
        // the pad: three notes, two detuned saws each, gliding to the chord
        local pad = 0.0
        local pad2 = 0.0
        for(local k = 0; k < 3; k += 1){
          local target = midi(chord_note(c, k))
          pad_f[k] += (target - pad_f[k]) * 0.0004
          if(pad_f[k] < 20.0){
            pad_f[k] = target
          }
          pad_ph[k] = fract(pad_ph[k] + pad_f[k] * DT)
          pad_ph[k + 3] = fract(pad_ph[k + 3] + pad_f[k] * 1.004 * DT)
          pad += saw(pad_ph[k])
          pad2 += saw(pad_ph[k + 3])
        }
        local pf = svf_f(500.0 + 250.0 * sin(TAU * mt / 12.0))
        pad_lp += pf * pad_bp
        pad_bp += pf * (pad - pad_lp - 0.9 * pad_bp)
        pad_rp += pf * pad_rb
        pad_rb += pf * (pad2 - pad_rp - 0.9 * pad_rb)
        // the bass under it
        bass_f += (midi(chord_note(c, 3)) - bass_f) * 0.002
        bass_ph = fract(bass_ph + bass_f * DT)
        local pulse = 0.6 + 0.4 * (1.0 - fract(mt * 2.0))
        local bass = sin(TAU * bass_ph) * 0.22 * pulse
        // the arpeggio: an eighth note at 120 bpm, chord tones up and down
        arp_t += DT
        if(arp_t >= 0.25){
          arp_t = 0.0
          arp_step = (arp_step + 1) % 8
          local k = select(
            arp_step < 3, arp_step, select(arp_step < 6, 5 - arp_step + 0, 1)
          )
          local octave = select(arp_step == 3 or arp_step == 7, 24.0, 12.0)
          arp_f = midi(chord_note(c, k % 3) + octave)
        }
        arp_ph = fract(arp_ph + arp_f * DT)
        arp_ph2 = fract(arp_ph2 + arp_f * 2.0 * DT)
        local arp = (sin(TAU * arp_ph) + sin(TAU * arp_ph2) * 0.3) *
          exp(-arp_t * 9.0) * min(1.0, arp_t * 500.0) * 0.16
        // the arpeggio's echo: a dotted eighth, the other ear
        local d = (delay_at + 24000 - 18000) % 24000
        local el = delay_l[d]
        local er = delay_r[d]
        delay_l[delay_at] = float(arp + er * 0.45)
        delay_r[delay_at] = float(el * 0.45)
        delay_at = (delay_at + 1) % 24000
        ml = (pad_lp * 0.09 + bass + arp * 0.8 + el * 0.5) * music
        mr = (pad_rp * 0.09 + bass + arp * 0.6 + er * 0.5) * music
        send_music = (pad_lp + pad_rp) * 0.04 * music + arp * music * 0.5
      }

      out[2 * i] += float(ml)
      out[2 * i + 1] += float(mr)
      send[i] = float(send_music)
    }
  }

  // the one-shots of the first kind (hits, scrapes, the magnet) added
  func shots_a(out: float[], send: float[], frames: int, voices: Voice[]){
    for(local k = 0; k < len(voices); k += 1){
      local v = voices[k]
      if(v.kind != 0 and v.kind <= 5 or v.kind == 12){
        local gl = left(v.pan)
        for(local i = 0; i < frames and v.kind != 0; i += 1){
          local s = shot_a(v)
          if(v.kind == 3){
            gl = left(v.pan)
          }
          out[2 * i] += float(s * gl)
          out[2 * i + 1] += float(s * sqrt(max(0.0, 1.0 - gl * gl)))
          send[i] += float(s * v.send)
        }
      }
    }
  }

  // the chimes, the buzz, the wreck, the click added
  func shots_b(out: float[], send: float[], frames: int, voices: Voice[]){
    for(local k = 0; k < len(voices); k += 1){
      local v = voices[k]
      if(v.kind >= 6 and v.kind <= 11 or v.kind == CHAIN){
        local gl = left(v.pan)
        local gr = left(-v.pan)
        for(local i = 0; i < frames and v.kind != 0; i += 1){
          local s = shot_b(v)
          out[2 * i] += float(s * gl)
          out[2 * i + 1] += float(s * gr)
          send[i] += float(s * v.send)
        }
      }
    }
  }

  // the reverb of send added, the master level and a soft clip
  func finish(out: float[], send: float[], frames: int, ctl: float[]){
    local t_master = float(ctl[4])
    for(local i = 0; i < frames; i += 1){
      master += (t_master - master) * 0.001
      local rin = send[i] * 0.25
      local rl = comb(0, 0, 1557, rin) + comb(1, 1557, 1617, rin) +
        comb(2, 3174, 1491, rin) + comb(3, 4665, 1422, rin)
      local rr = comb(4, 6087, 1580, rin) + comb(5, 7667, 1640, rin) +
        comb(6, 9307, 1514, rin) + comb(7, 10821, 1445, rin)
      rl = allpass(8, 12266, 556, rl)
      rl = allpass(9, 12822, 441, rl)
      rr = allpass(10, 13263, 579, rr)
      rr = allpass(11, 13842, 464, rr)
      out[2 * i] = float(soft((out[2 * i] + rl * 0.35) * master * 0.8))
      out[2 * i + 1] = float(soft((out[2 * i + 1] + rr * 0.35) * master * 0.8))
    }
  }
}

// how each one-shot is played: its kind, length, gain and reverb send
local shots = {
  hit: {1, 0.9, 0.9, 0.25},
  scrape: {2, 0.3, 0.7, 0.1},
  whoosh: {3, 0.7, 0.8, 0.15},
  clunk: {4, 0.35, 0.8, 0.2},
  release: {5, 0.2, 0.4, 0.2},
  pickup: {6, 1.4, 0.7, 0.6},
  deliver: {7, 2.2, 0.7, 0.6},
  late: {8, 0.75, 0.8, 0.3},
  wreck: {9, 2.8, 1.0, 0.35},
  ui: {10, 0.08, 0.5, 0.1},
  level: {11, 2.6, 0.7, 0.7},
  ignite: {12, 0.5, 0.7, 0.15},
  chain: {13, 0.45, 0.6, 0.35},
}

// new(ctl, events) -> block function for raylib/stream: the one-shots from
// events into voices, then the kernel fills the block (stereo)
func audio.new(ctl, events){
  local voices = Voice:array(16)
  local send = kernel.float:array(8192)
  local seed = 99
  local func rand(){
    seed = (seed * 1103515245 + 12345) % 2147483648
    return seed / 2147483648
  }
  local func start(e){
    local shot = shots[e.name]
    if(shot == null){
      return null
    }
    // a free voice, else the one furthest along
    local best = 0
    local furthest = -1.0
    for(local k = 0; k < len(voices); k = k + 1){
      local v = voices[k]
      if(v.kind == 0){
        best = k
        furthest = 1e9
        break
      }
      local along = v.t / v.dur
      if(along > furthest){
        furthest = along
        best = k
      }
    }
    // a little different every time: f varies pitches; a whoosh's f is
    // the side it comes from
    local f = 0.92 + rand() * 0.16
    if(e.name == "whoosh"){
      f = e.pan or (rand() * 2 - 1)
    } else if(e.f != null){
      f = e.f
    }
    voices[best] = {
      kind: shot[0],
      t: 0.0,
      dur: shot[1],
      gain: shot[2] * (e.gain or 1),
      pan: e.pan or 0.0,
      send: shot[3],
      f: f,
      p1: 0.0,
      p2: 0.0,
      p3: 0.0,
      p4: 0.0,
      lp: 0.0,
      bp: 0.0,
      lp2: 0.0,
      bp2: 0.0,
      x: 0.0,
    }
  }
  return func(out, frames){
    for(true){
      local e = events:try_receive()
      if(e == null){
        break
      }
      start(e)
    }
    car(out, frames, ctl)
    music_block(out, send, frames, ctl)
    shots_a(out, send, frames, voices)
    shots_b(out, send, frames, voices)
    finish(out, send, frames, ctl)
  }
}

return audio
