// studio/units/drums: two drum machines on the notes of General MIDI: a
// plain kit (a sine kick with a click, noise snare and hats, a clap of
// three bursts, toms, a rim tick) and an 808 (a driven sweeping kick, a
// snare of two resonators and noise, hats of six square waves, the clap,
// the cowbell).
//
//   local drums = s:track("drums", "drums", {kit: "808", kick_decay: 1.6})
//   drums:note(36)                     // kick
//   drums:note(42, {velocity: 0.5})    // closed hat, which chokes an open one
//
//   35 heavy kick   36 kick     37 rim      38 snare   39 clap   40 deep snare
//   41 43 45 47 48 50 toms, low to high     42 44 closed hat     46 open hat
//   56 cowbell
//
// A hit rings out by itself: note offs mean nothing. Every drum has its
// level (`kick`), its tuning in semitones (`kick_tune`) and its decay as
// a factor (`kick_decay`: 2 rings twice as long).
local kernel = require("kernel")
local math = require("slang/math")
local param = require("studio/param")
local voice = require("studio/units/voice")
local voices_lib = require("studio/voices")

local DRUMS = {"kick", "snare", "hat", "open", "clap", "tom", "rim", "cowbell"}

// what each drum plays in each kit: the kernel's wave, its note, its
// decay in seconds, how open its filter is, where it sits (-1..1)
local KITS = {
  {
    kick: {wave: 6, note: 36, decay: 0.35, cutoff: 0.8, pan: 0.0},
    snare: {wave: 7, note: 54, decay: 0.18, cutoff: 0.8, pan: 0.0},
    hat: {wave: 8, note: 80, decay: 0.04, cutoff: 0.8, pan: 0.5},
    open: {wave: 9, note: 80, decay: 0.3, cutoff: 0.8, pan: 0.5},
    clap: {wave: 10, note: 60, decay: 0.2, cutoff: 0.8, pan: -0.3},
    tom: {wave: 11, note: 50, decay: 0.3, cutoff: 0.8, pan: 0.0},
    rim: {wave: 12, note: 84, decay: 0.03, cutoff: 0.8, pan: -0.4},
    cowbell: {wave: 18, note: 74, decay: 0.25, cutoff: 1.0, pan: 0.6},
  },
  {
    kick: {wave: 13, note: 33, decay: 0.5, cutoff: 0.8, pan: 0.0},
    snare: {wave: 14, note: 55, decay: 0.22, cutoff: 1.0, pan: 0.0},
    hat: {wave: 15, note: 80, decay: 0.06, cutoff: 1.0, pan: 0.5},
    open: {wave: 16, note: 80, decay: 0.5, cutoff: 1.0, pan: 0.5},
    clap: {wave: 17, note: 60, decay: 0.25, cutoff: 1.0, pan: -0.3},
    tom: {wave: 11, note: 50, decay: 0.35, cutoff: 0.8, pan: 0.0},
    rim: {wave: 12, note: 84, decay: 0.03, cutoff: 0.8, pan: -0.4},
    cowbell: {wave: 18, note: 74, decay: 0.25, cutoff: 1.0, pan: 0.6},
  },
}

// a MIDI note's drum: {drum, semitones from the drum's own note, a
// factor on its decay, on its loudness}
local NOTES = {
  [35]: {"kick", -5, 1.5, 1.2},
  [36]: {"kick", 0, 1, 1},
  [37]: {"rim", 0, 1, 1},
  [38]: {"snare", 0, 1, 1},
  [39]: {"clap", 0, 1, 1},
  [40]: {"snare", -4, 1.6, 1.1},
  [41]: {"tom", -10, 1.4, 1},
  [42]: {"hat", 0, 1, 1},
  [43]: {"tom", -7, 1.3, 1},
  [44]: {"hat", 0, 0.7, 0.8},
  [45]: {"tom", -3, 1.15, 1},
  [46]: {"open", 0, 1, 1},
  [47]: {"tom", 0, 1, 1},
  [48]: {"tom", 3, 0.9, 1},
  [49]: {"open", 2, 1.6, 1},
  [50]: {"tom", 7, 0.8, 1},
  [51]: {"hat", -2, 1.5, 0.9},
  [56]: {"cowbell", 0, 1, 1},
}

local defs = {
  {name: "kit", labels: {"plain", "808"}, default: "plain"},
  {name: "gain", min: 0.0, max: 2.0, default: 0.6},
  {name: "drive", min: 0.0, max: 1.0, default: 0.0},
  {name: "width", min: 0.0, max: 1.0, default: 0.5},
}
for(let local d in values(DRUMS)){
  append(defs, {name: d, min: 0.0, max: 2.0, default: 1.0})
  append(defs, {
    name: concat(d, "_tune"), min: -24.0, max: 24.0, default: 0.0, unit: "st",
    bipolar: true
  })
  append(defs, {
    name: concat(d, "_decay"), min: 0.25, max: 4.0, default: 1.0, curve: 2.0
  })
}
local params = param.set(defs)
local P = params.index
local NP = 16

local func new(ctx){
  local sr = ctx.sample_rate * 1.0
  local p = ctx.params
  local base = ctx.base
  local count = ctx.options.voices or 12
  local voices = voice.Voice:array(count)
  local views = {}
  for(local i = 0; i < count; i = i + 1){
    views[i] = voices[i]
  }
  local vp = kernel.double:array(count * NP)
  local sounding = 0
  local seed = 54321
  local render = voice.render

  local func note_on(note, vel){
    local hit = NOTES[to_int(math.round(note))]
    if(hit == null){
      return null
    }
    local name = hit[0]
    local kit = KITS[to_int(p[base + P.kit])]
    local d = kit[name]
    local level = p[base + P[name]]
    if(level <= 0.0){
      return null
    }
    // a free voice, or the quietest
    local pick = -1
    local quiet = 0
    local quietest = 1.0e9
    for(local i = 0; i < count; i = i + 1){
      local v = views[i]
      if(v.on == 0){
        if(pick < 0){
          pick = i
        }
      } else if(v.env < quietest){
        quietest = v.env
        quiet = i
      }
    }
    if(pick < 0){
      pick = quiet
    }
    local v = views[pick]
    local pb = pick * NP
    local decay = d.decay * hit[2] * p[base + P[concat(name, "_decay")]]
    vp[pb] = d.wave
    vp[pb + 3] = 0.0
    vp[pb + 5] = d.cutoff
    vp[pb + 6] = 0.1
    vp[pb + 7] = 0.0
    vp[pb + 8] = p[base + P.gain] * level * hit[3]
    vp[pb + 9] = d.pan * p[base + P.width]
    vp[pb + 10] = 0.0
    vp[pb + 11] = 0.5
    vp[pb + 15] = p[base + P.drive]
    seed = (seed * 1103515245 + 12345) % 2147483648
    voices_lib.start(
      v, pick, d.wave, d.note + hit[1] + p[base + P[concat(name, "_tune")]],
      vel, seed
    )
    v.ac = 1.0
    v.dc = math.exp(-1.0 / (math.max(decay, 0.005) * sr))
    v.rc = 0.0
    v.gl = 1.0
    // the pitch envelope: the 808 snare's tone rings longer than a sweep
    v.pk = math.exp(-1.0 / (if(d.wave == 14){ 0.12 } else { 0.03 } * sr))
    if(name == "hat"){
      // a closed hat chokes the open ones, in 8 ms
      for(local i = 0; i < count; i = i + 1){
        local o = views[i]
        local w = to_int(vp[i * NP])
        if(i != pick and o.on != 0 and (w == 9 or w == 16)){
          o.dc = math.exp(-1.0 / (0.008 * sr))
        }
      }
    }
  }

  return {
    note_on: note_on,
    note_off: func(note){},
    panic: func(){
      for(local i = 0; i < count; i = i + 1){
        views[i].on = 0
      }
    },
    voices: func(){
      return sounding
    },
    render: func(l, r, start, n){
      sounding = render(l, r, start, n, sr, voices, vp, 1.0)
    },
  }
}

return {
  name: "drums",
  kind: "instrument",
  params: params,
  options: {"voices"},
  drums: DRUMS,
  notes: NOTES,
  new: new,
}
