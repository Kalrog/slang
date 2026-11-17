// studio/units/poly: a polyphonic voice for most things: an oscillator
// (saw, square, triangle, sine, noise, a two-operator FM pair or a
// supersaw of seven saws), a resonant lowpass its envelope opens, a
// drive and a pan. It is the voice of examples/live.
//
//   local lead = s:track("lead", "poly", {wave: "supersaw", cutoff: 0.7})
//   lead:note(57, {length: 400, params: {pan: -0.5}})
//
// Sixteen voices (the option `voices` sets how many). A note takes a free
// voice, else the quietest. A parameter set while notes sound reaches
// them; `params` of a note hold for that note alone. The pitch wheel
// bends two semitones and the pedal holds released notes.
local kernel = require("kernel")
local math = require("slang/math")
local param = require("studio/param")
local events = require("studio/events")
local voice = require("studio/units/voice")
local voices_lib = require("studio/voices")

local WAVES = {"saw", "square", "tri", "sine", "noise", "fm", "supersaw"}
// the kernel's number of each
local WAVE_CODE = {0, 1, 2, 3, 4, 5, 19}

local params = param.set({
  {name: "wave", labels: WAVES, default: "saw"},
  {name: "attack", min: 0.5, max: 4000.0, default: 5.0, unit: "ms", curve: 3.0},
  {
    name: "decay", min: 1.0, max: 8000.0, default: 200.0, unit: "ms", curve: 3.0
  },
  {name: "sustain", min: 0.0, max: 1.0, default: 0.6},
  {
    name: "release", min: 2.0, max: 8000.0, default: 200.0, unit: "ms",
    curve: 3.0
  },
  {name: "cutoff", min: 0.0, max: 1.0, default: 0.8},
  {name: "res", min: 0.0, max: 1.0, default: 0.1},
  {name: "env", min: -1.0, max: 1.0, default: 0.0, bipolar: true},
  {name: "gain", min: 0.0, max: 2.0, default: 0.5},
  {name: "pan", min: -1.0, max: 1.0, default: 0.0, bipolar: true},
  {name: "detune", min: 0.0, max: 100.0, default: 0.0, unit: "ct"},
  {name: "pw", min: 0.0, max: 1.0, default: 0.5},
  {name: "glide", min: 0.0, max: 2000.0, default: 0.0, unit: "ms", curve: 3.0},
  {name: "fm", min: 0.0, max: 12.0, default: 2.0},
  {name: "ratio", min: 0.25, max: 16.0, default: 2.0},
  {name: "drive", min: 0.0, max: 1.0, default: 0.0},
})
local P = params.index
local NP = params.count

local patches = {
  {name: "Saw"},
  {
    name: "Pluck", wave: "saw", attack: 1, decay: 180, sustain: 0.0,
    release: 120, cutoff: 0.35, env: 0.5, res: 0.3
  },
  {
    name: "Bass", wave: "square", pw: 0.35, attack: 2, decay: 250, sustain: 0.4,
    release: 80, cutoff: 0.3, env: 0.35, res: 0.25, drive: 0.2
  },
  {
    name: "Pad", wave: "supersaw", detune: 22, pw: 0.7, attack: 600,
    decay: 1500, sustain: 0.8, release: 1800, cutoff: 0.55, gain: 0.35
  },
  {
    name: "Bell", wave: "fm", fm: 3.5, ratio: 3.5, attack: 1, decay: 1400,
    sustain: 0.0, release: 900, cutoff: 1.0
  },
  {
    name: "Organ", wave: "tri", attack: 4, decay: 50, sustain: 1.0, release: 60,
    cutoff: 1.0
  },
  {
    name: "Lead", wave: "saw", detune: 9, attack: 5, decay: 300, sustain: 0.7,
    release: 150, cutoff: 0.6, env: 0.2, res: 0.35, glide: 60
  },
  {
    name: "Wind", wave: "noise", attack: 900, decay: 2000, sustain: 0.6,
    release: 1500, cutoff: 0.5, res: 0.6, gain: 0.3
  },
}

local func new(ctx){
  local sr = ctx.sample_rate * 1.0
  local p = ctx.params
  local base = ctx.base
  local count = ctx.options.voices or 16
  local voices = voice.Voice:array(count)
  local views = {}
  for(local i = 0; i < count; i = i + 1){
    views[i] = voices[i]
  }
  local vp = kernel.double:array(count * NP)
  local over = {} // the next note's own parameters
  local has_over = false
  local bend = 1.0
  local pedal = false
  local sounding = 0
  local seed = 12345
  local render = voice.render

  local func coefs(v, i){
    local pb = i * NP
    v.ac = 1.0 / (math.max(vp[pb + P.attack], 0.5) * 0.001 * sr)
    v.dc = 1.0 - math.exp(-1.0 / (math.max(vp[pb + P.decay], 1.0) * 0.001 * sr))
    v.rc = math.exp(-1.0 / (math.max(vp[pb + P.release], 2.0) * 0.001 * sr))
    local glide = vp[pb + P.glide] * 0.001
    if(glide > 0.0005){
      v.gl = 1.0 - math.exp(-1.0 / (glide * sr))
    } else {
      v.gl = 1.0
    }
  }

  local func note_on(note, vel){
    // a free voice, or the quietest
    local pick = -1
    local quiet = 0
    local quietest = 1.0e9
    local last_freq = null
    local last_t = 1.0e9
    for(local i = 0; i < count; i = i + 1){
      local v = views[i]
      if(v.on == 0){
        if(pick < 0){
          pick = i
        }
      } else {
        if(v.t < last_t){
          last_t = v.t
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
    local v = views[pick]
    local pb = pick * NP
    for(local k = 0; k < NP; k = k + 1){
      vp[pb + k] = p[base + k]
    }
    if(has_over){
      for(let local e in entries(over)){
        vp[pb + e[0]] = e[1]
      }
      over = {}
      has_over = false
    }
    local wave = WAVE_CODE[to_int(vp[pb + P.wave])]
    vp[pb + P.wave] = wave
    seed = (seed * 1103515245 + 12345) % 2147483648
    voices_lib.start(v, pick, wave, note, vel, seed)
    coefs(v, pick)
    if(vp[pb + P.glide] > 0.5 and last_freq != null){
      v.freq = last_freq
    }
  }

  local func note_off(note){
    for(local i = 0; i < count; i = i + 1){
      local v = views[i]
      if(v.on != 0 and v.note == note and v.stage < 2 and v.held == 0){
        if(pedal){
          v.held = 1
        } else {
          v.stage = 2
        }
      }
    }
  }

  local func hush(){
    for(local i = 0; i < count; i = i + 1){
      local v = views[i]
      if(v.on != 0 and v.stage < 2){
        v.stage = 2
        v.held = 0
      }
    }
  }

  return {
    note_on: note_on,
    note_off: note_off,
    next: func(i, value){
      over[i] = value
      has_over = true
    },
    control: func(which, value){
      if(which == events.controls.BEND){
        bend = math.exp(math.log(2) * value * 2 / 12)
      } else if(which == events.controls.SUSTAIN){
        pedal = value >= 0.5
        if(not pedal){
          for(local i = 0; i < count; i = i + 1){
            local v = views[i]
            if(v.on != 0 and v.held != 0){
              v.held = 0
              v.stage = 2
            }
          }
        }
      }
    },
    // a parameter reaches the notes that sound, the wave excepted
    set: func(i, value){
      if(i == P.wave){
        return null
      }
      for(local k = 0; k < count; k = k + 1){
        local v = views[k]
        if(v.on != 0){
          vp[k * NP + i] = value
          if(i == P.attack or i == P.decay or i == P.release or i == P.glide){
            coefs(v, k)
          }
        }
      }
    },
    hush: hush,
    panic: func(){
      for(local i = 0; i < count; i = i + 1){
        views[i].on = 0
      }
    },
    voices: func(){
      return sounding
    },
    render: func(l, r, start, n){
      sounding = render(l, r, start, n, sr, voices, vp, bend)
    },
  }
}

return {
  name: "poly",
  kind: "instrument",
  params: params,
  options: {"voices"},
  patches: patches,
  waves: WAVES,
  new: new,
}
