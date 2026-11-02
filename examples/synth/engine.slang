// The sound of the synth: a monophonic subtractive voice after the classic
// three-oscillator design. It runs in the render isolate of raylib/stream:
// engine.new returns the block function, which reads the controls from a
// shared buffer at every block, takes notes from a channel and writes
// samples.
//
//   oscillators 1-3 (band-limited saw and pulses, triangle, sharktooth)
//   + noise -> mixer -> 4-pole ladder filter (contour, emphasis, keyboard
//   tracking) -> loudness contour -> output
//
// The mod wheel sends osc 3 (or noise, by MOD MIX) to the oscillators'
// pitch (OSC MOD) and the filter (FILTER MOD); with OSC 3 CTRL off, osc 3
// ignores the keyboard and with RANGE LO it is an LFO. The DECAY switch
// lets a released key fade with the decay time, as on the original.
//
// Everything per sample is plain slang arithmetic on locals; pitch, the
// filter's coefficient and its contour change every 16 samples.
local math = require("slang/math")
local params = require("params")

local engine = {}

local P = params.index
local LN2_12 = 0.6931471805599453 / 12.0
local TWO_PI = 6.283185307179586
local CONTROL = 16

// the octave of each RANGE position, from 8' (0); LO is six down, which
// with OSC 3 CTRL off makes osc 3 an LFO of 4 to 6 Hz
local range_octaves = {-6, -2, -1, 0, 1, 2}
// the width of WIDE and NARROW pulses
local pulse_widths = {0.5, 0.5, 0.5, 0.5, 0.3, 0.12}

// PolyBLEP: the correction that takes the alias out of a jump at phase 0
local func blep(t, dt){
  if(t < dt){
    local x = t / dt
    return x + x - x * x - 1.0
  }
  if(t > 1.0 - dt){
    local x = (t - 1.0) / dt
    return x * x + x + x + 1.0
  }
  return 0.0
}

// one oscillator's sample at phase p (0..1) advancing dt per sample; wave
// is the WAVEFORM position, rev (osc 3) turns SHARK into a reverse saw
local func shape(wave, p, dt, rev){
  if(wave == 2){
    return 2.0 * p - 1.0 - blep(p, dt)
  }
  if(wave >= 3){
    local w = pulse_widths[wave]
    local q = p - w
    if(q < 0.0){
      q = q + 1.0
    }
    local v = -1.0
    if(p < w){
      v = 1.0
    }
    return v + blep(p, dt) - blep(q, dt)
  }
  local x = 2.0 * p - 1.0
  if(x < 0.0){
    x = -x
  }
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

// a soft clip, tanh-like up to 3 and flat beyond
local func soft(x){
  if(x > 3.0){
    return 1.0
  }
  if(x < -3.0){
    return -1.0
  }
  local x2 = x * x
  return x * (27.0 + x2) / (27.0 + 9.0 * x2)
}

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

// new(p: Buffer, events: Channel, scope: Buffer?, sample_rate: int,
//   status?: {state: Buffer, keys: Buffer}) -> block function
// p holds the controls (params.list order), events brings {on: note} and
// {off: note} ({panic: true} lets go of everything), {song: s} (a song as
// song.slang's load makes it: it plays from its start) and {stop_song:
// true}; scope, when given, gets the samples (its last cell: where the
// next one goes). status, when given, hears about the song: state[0] 1
// while one plays, state[1] where it is and state[2] how long it is (in
// seconds), keys[note] 1 while the song holds the note.
func engine.new(p, events, scope, sample_rate, status){
  local sr = sample_rate * 1.0
  local held = {}
  local gate = false
  local note = 60.0
  local pitch = 60.0
  local p1 = 0.0
  local p2 = 0.0
  local p3 = 0.0
  local o3 = 0.0
  local noise_v = 0.0
  local seed = 12345
  local amp = 0.0
  local amp_stage = 0
  local fenv = 0.0
  local fenv_stage = 0
  local y1 = 0.0
  local y2 = 0.0
  local y3 = 0.0
  local y4 = 0.0
  local scope_n = 0
  local scope_at = 0
  if(scope != null){
    scope_n = len(scope) - 1
  }

  local func release(n){
    local rest = {}
    for(let local h in values(held)){
      if(h != n){
        append(rest, h)
      }
    }
    held = rest
  }

  local func note_on(n){
    release(n)
    append(held, n)
    note = n * 1.0
    // single trigger: a key pressed while others are held only changes
    // the pitch
    if(not gate){
      gate = true
      amp_stage = 1
      fenv_stage = 1
    }
  }

  local func note_off(n){
    release(n)
    if(len(held) > 0){
      note = held[len(held) - 1] * 1.0
    } else if(gate){
      gate = false
      amp_stage = 0
      fenv_stage = 0
    }
  }

  local func all_off(){
    held = {}
    gate = false
    amp_stage = 0
    fenv_stage = 0
  }

  // the song playing (song.slang's load): its events and curves, where it
  // is (in samples) and the next event
  local playing = null
  local song_at = 0
  local next_event = 0
  local song_keys = null
  local song_state = null
  if(status != null){
    song_keys = status.keys
    song_state = status.state
  }

  local func song_key(n, down){
    if(song_keys != null and n >= 0 and n < 128){
      if(down){
        song_keys[n] = 1
      } else {
        song_keys[n] = 0
      }
    }
  }

  local func stop_song(){
    if(playing != null){
      for(let local e in values(playing.events)){
        song_key(e.note, false)
      }
      all_off()
      playing = null
    }
    if(song_state != null){
      song_state[0] = 0
    }
  }

  local func start_song(s){
    stop_song()
    all_off()
    // events and curve points in samples
    for(let local e in values(s.events)){
      e.at = to_int(e.t * sr)
    }
    for(let local c in values(s.curves)){
      c.cursor = 0
    }
    for(let local pv in values(s.patch)){
      p[pv[0]] = pv[1]
    }
    playing = s
    song_at = 0
    next_event = 0
    if(song_state != null){
      song_state[0] = 1
      song_state[2] = s.length
    }
  }

  // the controls the song moves, at the song's time: written into the
  // shared controls, so the panel shows them turning
  local func apply_curves(){
    local t = song_at / sr
    for(let local c in values(playing.curves)){
      local pts = c.points
      local k = c.cursor
      for(k + 1 < len(pts) and pts[k + 1][0] <= t){
        k = k + 1
      }
      c.cursor = k
      local v = pts[k][1]
      if(t > pts[k][0] and k + 1 < len(pts) and not c.step){
        local a = pts[k]
        local b = pts[k + 1]
        v = a[1] + (b[1] - a[1]) * (t - a[0]) / (b[0] - a[0])
      } else if(t < pts[0][0]){
        v = pts[0][1]
      }
      p[c.index] = v
    }
  }

  // the song's events up to the song's time
  local func song_events(){
    local evs = playing.events
    for(next_event < len(evs) and evs[next_event].at <= song_at){
      local e = evs[next_event]
      if(e.on){
        note_on(e.note)
      } else {
        note_off(e.note)
      }
      song_key(e.note, e.on)
      next_event = next_event + 1
    }
  }

  local func take_events(){
    for(true){
      local e = events:try_receive()
      if(e == null){
        return null
      }
      if(e.on != null){
        note_on(e.on)
      } else if(e.off != null){
        note_off(e.off)
      } else if(e.panic){
        all_off()
      } else if(e.song != null){
        start_song(e.song)
      } else if(e.stop_song){
        stop_song()
      }
    }
  }

  return func(out, frames){
    take_events()
    if(playing != null){
      apply_curves()
    }
    // the controls, once a block
    local tune = (p[P.tune] - 0.5) * 4.0 + (p[P.bend] - 0.5) * 4.0
    local glide_t = p[P.glide] * p[P.glide] * 3.0
    local glide_c = 1.0
    if(glide_t > 0.002){
      glide_c = coef(glide_t, sr / CONTROL)
    }
    local oct1 = range_octaves[to_int(p[P.range1])]
    local oct2 = range_octaves[to_int(p[P.range2])]
    local oct3 = range_octaves[to_int(p[P.range3])]
    local d2 = (p[P.detune2] - 0.5) * 2.0
    local d3 = (p[P.detune3] - 0.5) * 2.0
    local semis2 = oct2 * 12.0 + 7.0 * d2 * d2 * d2
    local semis3 = oct3 * 12.0 + 7.0 * d3 * d3 * d3
    local semis1 = oct1 * 12.0
    local wave1 = to_int(p[P.wave1])
    local wave2 = to_int(p[P.wave2])
    local wave3 = to_int(p[P.wave3])
    local track3 = p[P.osc3_ctrl] > 0.5
    local g1 = p[P.vol1] * p[P.on1]
    local g2 = p[P.vol2] * p[P.on2]
    local g3 = p[P.vol3] * p[P.on3]
    local gn = p[P.noise] * p[P.noise_on] * 0.7
    local mod_mix = p[P.mod_mix]
    local wheel = p[P.mod]
    local osc_mod = p[P.osc_mod] * wheel * 2.0
    local filter_mod = p[P.filter_mod] * wheel * 2.0
    local cutoff_oct = p[P.cutoff] * 10.0
    local contour = p[P.contour] * 6.0
    local kbd = p[P.kbd_ctrl]
    local k = p[P.emphasis] * 4.3
    // an attack aims past full (1.3) so it gets there in its time
    local fa = coef(contour_time(p[P.f_attack]) * 3.1, sr / CONTROL)
    local fd = coef(contour_time(p[P.f_decay]), sr / CONTROL)
    local fs = p[P.f_sustain]
    local aa = coef(contour_time(p[P.a_attack]) * 3.1, sr)
    local ad = coef(contour_time(p[P.a_decay]), sr)
    local a_sus = p[P.a_sustain]
    local fr = coef(0.008, sr / CONTROL)
    local ar = coef(0.008, sr)
    if(p[P.decay_sw] > 0.5){
      fr = fd
      ar = ad
    }
    local volume = p[P.volume] * p[P.volume] * 0.9
    local makeup = 1.0 + k * 0.35

    local i = 0
    for(i < frames){
      // ---- every CONTROL samples: the song's notes, pitch, modulation,
      // filter
      if(playing != null){
        song_events()
        song_at = song_at + CONTROL
      }
      pitch = pitch + (note - pitch) * glide_c
      local m = o3 + (noise_v - o3) * mod_mix
      local base = pitch - 69.0 + tune
      local vib = m * osc_mod
      local dt1 = 440.0 * math.exp((base + semis1 + vib) * LN2_12) / sr
      local dt2 = 440.0 * math.exp((base + semis2 + vib) * LN2_12) / sr
      local n3 = base
      if(not track3){
        n3 = -9.0
      }
      local dt3 = 440.0 * math.exp((n3 + semis3) * LN2_12) / sr
      if(fenv_stage == 1){
        fenv = fenv + (1.3 - fenv) * fa
        if(fenv >= 1.0){
          fenv = 1.0
          fenv_stage = 2
        }
      } else if(fenv_stage == 2){
        fenv = fenv + (fs - fenv) * fd
      } else {
        fenv = fenv - fenv * fr
      }
      local oct = cutoff_oct + contour * fenv + m * filter_mod +
        kbd * (pitch - 60.0) / 12.0
      local fc = 20.0 * math.exp(oct * 0.6931471805599453)
      if(fc > sr * 0.45){
        fc = sr * 0.45
      }
      // the filter runs at twice the rate
      local g = 1.0 - math.exp(-TWO_PI * fc / (2.0 * sr))
      local stop = i + CONTROL
      if(stop > frames){
        stop = frames
      }
      // ---- every sample
      for(i < stop){
        p1 = p1 + dt1
        if(p1 >= 1.0){
          p1 = p1 - 1.0
        }
        p2 = p2 + dt2
        if(p2 >= 1.0){
          p2 = p2 - 1.0
        }
        p3 = p3 + dt3
        if(p3 >= 1.0){
          p3 = p3 - 1.0
        }
        o3 = shape(wave3, p3, dt3, true)
        seed = (seed * 1103515245 + 12345) & 0x7fffffff
        noise_v = seed / 1073741823.5 - 1.0
        local x = g1 * shape(wave1, p1, dt1, false) +
          g2 * shape(wave2, p2, dt2, false) + g3 * o3 + gn * noise_v
        // the ladder: four one-poles, the emphasis feeding back the last
        local u = soft(x - k * y4)
        y1 = y1 + g * (u - y1)
        y2 = y2 + g * (y1 - y2)
        y3 = y3 + g * (y2 - y3)
        y4 = y4 + g * (y3 - y4)
        u = soft(x - k * y4)
        y1 = y1 + g * (u - y1)
        y2 = y2 + g * (y1 - y2)
        y3 = y3 + g * (y2 - y3)
        y4 = y4 + g * (y3 - y4)
        if(amp_stage == 1){
          amp = amp + (1.3 - amp) * aa
          if(amp >= 1.0){
            amp = 1.0
            amp_stage = 2
          }
        } else if(amp_stage == 2){
          amp = amp + (a_sus - amp) * ad
        } else {
          amp = amp - amp * ar
        }
        local s = soft(y4 * makeup * amp * volume * 1.5) * 0.66
        out[i] = s
        if(scope_n > 0){
          scope[scope_at] = s
          scope_at = scope_at + 1
          if(scope_at >= scope_n){
            scope_at = 0
          }
        }
        i = i + 1
      }
    }
    if(scope_n > 0){
      scope[scope_n] = scope_at
    }
    if(playing != null){
      if(song_state != null){
        song_state[1] = song_at / sr
      }
      // the end: the last event and two seconds for the sound to fade
      if(next_event >= len(playing.events) and song_at / sr > playing.length + 2.0){
        stop_song()
      }
    }
  }
}

return engine
