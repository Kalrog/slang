// Premade sounds for the synth: each patch names the controls it sets, as a
// song's patch does (knobs 0 to 1, switches 0 or 1, rotary switches an
// index or one of their labels); every control it leaves out is at its
// default. Up and down on the computer keyboard, or the arrows on the strip
// under the panel, step through them.
//
// A few numbers to go by (engine.slang): CUTOFF puts the filter at 20 Hz
// times 2^(10 x cutoff), CONTOUR adds up to six octaves, EMPHASIS whistles
// from about 0.9; contour times are 10 s x knob^3 (0.4 is 0.64 s);
// FREQUENCY detunes by 7 semitones x (2 x knob - 1)^3, so 0.6 is 6 cents
// and 1.0 a fifth up; osc 3 at RANGE LO with OSC 3 CTRL off is an LFO of
// 4 to 6 Hz for the mod wheel to send.
local params = require("params")

local patches = {}

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

patches.list = {
  {name: "Init", patch: {}},
  {name: "Fat Bass", patch: {
    range1: "16'", wave1: "SAW", vol1: 0.8,
    range2: "16'", wave2: "SQR", detune2: 0.6, vol2: 0.7,
    range3: "32'", wave3: "SAW", detune3: 0.42, vol3: 0.5, on3: 1,
    cutoff: 0.3, emphasis: 0.25, contour: 0.5,
    f_attack: 0.0, f_decay: 0.3, f_sustain: 0.15,
    a_attack: 0.0, a_decay: 0.35, a_sustain: 0.9, decay_sw: 0,
    volume: 0.7,
  }},
  {name: "Pluck Bass", patch: {
    range1: "16'", wave1: "WIDE",
    range2: "16'", wave2: "SAW", detune2: 0.58, vol2: 0.6,
    cutoff: 0.22, emphasis: 0.55, contour: 0.65,
    f_attack: 0.0, f_decay: 0.22, f_sustain: 0.0,
    a_attack: 0.0, a_decay: 0.45, a_sustain: 0.0,
    volume: 0.7,
  }},
  {name: "Lead", patch: with(lfo, {
    glide: 0.25, osc_mod: 1, mod: 0.06, detune3: 0.7,
    wave1: "SAW", wave2: "SAW", detune2: 0.62, vol2: 0.75,
    cutoff: 0.48, emphasis: 0.45, contour: 0.45,
    f_attack: 0.1, f_decay: 0.45, f_sustain: 0.5,
    a_attack: 0.05, a_decay: 0.4, a_sustain: 0.95,
  })},
  {name: "Brass", patch: {
    wave1: "SAW", wave2: "SAW", detune2: 0.6, vol2: 0.8,
    cutoff: 0.34, emphasis: 0.15, contour: 0.55,
    f_attack: 0.3, f_decay: 0.45, f_sustain: 0.55,
    a_attack: 0.15, a_decay: 0.4, a_sustain: 0.9,
    volume: 0.7,
  }},
  {name: "Flute", patch: with(lfo, {
    osc_mod: 1, mod: 0.05, detune3: 0.75,
    wave1: "TRI", vol1: 0.9,
    range2: "4'", wave2: "TRI", detune2: 0.5, vol2: 0.2,
    noise: 0.15, noise_on: 1,
    cutoff: 0.56, emphasis: 0.05, contour: 0.15,
    f_attack: 0.05, f_decay: 0.3, f_sustain: 0.8,
    a_attack: 0.22, a_decay: 0.3, a_sustain: 0.9,
    volume: 0.75,
  })},
  {name: "Fifths", patch: {
    wave1: "SAW", wave2: "SAW", detune2: 1.0, vol2: 0.6,
    cutoff: 0.42, emphasis: 0.3, contour: 0.4,
    f_attack: 0.05, f_decay: 0.35, f_sustain: 0.4,
  }},
  {name: "Slow Pad", patch: {
    wave1: "SAW", wave2: "SAW", detune2: 0.62, vol2: 0.7,
    range3: "8'", wave3: "SAW", detune3: 0.38, vol3: 0.6, on3: 1,
    cutoff: 0.4, emphasis: 0.1, contour: 0.3,
    f_attack: 0.6, f_decay: 0.6, f_sustain: 0.7,
    a_attack: 0.55, a_decay: 0.6, a_sustain: 1.0,
    volume: 0.6,
  }},
  {name: "Filter Sweep", patch: {
    wave1: "SQR", wave2: "SAW", detune2: 0.58,
    cutoff: 0.15, emphasis: 0.75, contour: 0.85,
    f_attack: 0.45, f_decay: 0.55, f_sustain: 0.2,
    a_attack: 0.02, a_sustain: 1.0,
  }},
  {name: "Wobble", patch: with(lfo, {
    filter_mod: 1, mod: 0.6, detune3: 0.3,
    range1: "16'", wave1: "SAW", range2: "32'", wave2: "SQR", detune2: 0.55,
    cutoff: 0.3, emphasis: 0.6, contour: 0.2,
    a_attack: 0.0, a_sustain: 1.0, decay_sw: 0,
  })},
  {name: "Zap", patch: {
    range1: "4'", wave1: "SAW", on2: 0,
    cutoff: 0.25, emphasis: 0.8, contour: 1.0,
    f_attack: 0.0, f_decay: 0.2, f_sustain: 0.0,
    a_attack: 0.0, a_decay: 0.3, a_sustain: 0.0,
  }},
  {name: "Wind", patch: {
    on1: 0, on2: 0, noise: 0.9, noise_on: 1,
    cutoff: 0.6, emphasis: 0.9, contour: 0.2, kbd_ctrl: 1,
    f_attack: 0.4, f_decay: 0.6, f_sustain: 0.6,
    a_attack: 0.5, a_decay: 0.6, a_sustain: 1.0,
    volume: 0.8,
  }},
}

// values(k: int) -> {number}: every control's value under patch k, in
// params.list's order
func patches.values(k){
  local def = patches.list[k]
  for(let local id in keys(def.patch)){
    if(params.index[id] == null){
      error(concat("patch ", def.name, ": there is no control called ", id))
    }
  }
  local out = {}
  for(let local c in values(params.list)){
    local v = c.default
    if(def.patch[c.id] != null){
      v = params.value(c, def.patch[c.id])
      if(v == null){
        error(concat("patch ", def.name, ": ", c.id, " has no position called ", def.patch[c.id]))
      }
    }
    append(out, v)
  }
  return out
}

return patches
