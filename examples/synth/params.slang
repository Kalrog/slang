// The synth's controls: what the panel draws and the engine reads. Each
// control is a cell of a shared buffer of doubles (main.slang writes it when
// a knob turns, engine.slang reads it at every block); its index is its
// place in the list.
//
// kinds: "knob" (0..1, shown 0..10, or -5..5 when bipolar), "steps" (a
// rotary switch: the index of one of its labels), "switch" (0 or 1).
// x and y are the control's center on the panel; section names where its
// heading goes.
local params = {}

params.sections = {
  {name: "CONTROLLERS", from: 45, to: 225},
  {name: "OSCILLATOR BANK", from: 230, to: 605},
  {name: "MIXER", from: 610, to: 790},
  {name: "MODIFIERS", from: 795, to: 1080},
  {name: "OUTPUT", from: 1085, to: 1155},
}

// the rows of knobs and the panel's extent (main.slang draws from these)
local ROW1 = 112
local ROW2 = 207
local ROW3 = 302
params.rows = {ROW1, ROW2, ROW3}
params.top = 20
params.bottom = 388

local ranges = {"LO", "32'", "16'", "8'", "4'", "2'"}
local waves = {"TRI", "SHRK", "SAW", "SQR", "WIDE", "NARR"}
local waves3 = {"TRI", "REV", "SAW", "SQR", "WIDE", "NARR"}

params.list = {
  // controllers
  {id: "tune", label: "TUNE", kind: "knob", bipolar: true, default: 0.5, x: 95, y: ROW1},
  {id: "glide", label: "GLIDE", kind: "knob", default: 0.0, x: 95, y: ROW2},
  {id: "mod_mix", label: "MOD MIX", kind: "knob", default: 0.0, x: 175, y: ROW2, left: "OSC 3", right: "NOISE"},
  {id: "osc_mod", label: "OSC MOD", kind: "switch", default: 0, x: 175, y: ROW1},
  {id: "filter_mod", label: "FILTER MOD", kind: "switch", default: 0, x: 135, y: ROW3},
  // oscillator bank
  {id: "range1", label: "RANGE", kind: "steps", labels: ranges, default: 3, x: 290, y: ROW1},
  {id: "wave1", label: "WAVEFORM", kind: "steps", labels: waves, default: 2, x: 500, y: ROW1},
  {id: "range2", label: "RANGE", kind: "steps", labels: ranges, default: 3, x: 290, y: ROW2},
  {id: "detune2", label: "FREQUENCY", kind: "knob", bipolar: true, default: 0.52, x: 395, y: ROW2},
  {id: "wave2", label: "WAVEFORM", kind: "steps", labels: waves, default: 2, x: 500, y: ROW2},
  {id: "range3", label: "RANGE", kind: "steps", labels: ranges, default: 2, x: 290, y: ROW3},
  {id: "detune3", label: "FREQUENCY", kind: "knob", bipolar: true, default: 0.47, x: 395, y: ROW3},
  {id: "wave3", label: "WAVEFORM", kind: "steps", labels: waves3, default: 3, x: 500, y: ROW3},
  {id: "osc3_ctrl", label: "OSC 3 CTRL", kind: "switch", default: 1, x: 570, y: ROW3},
  // mixer
  {id: "vol1", label: "OSC 1", kind: "knob", small: true, default: 0.8, x: 660, y: 104},
  {id: "on1", label: "", kind: "switch", default: 1, x: 735, y: 104},
  {id: "vol2", label: "OSC 2", kind: "knob", small: true, default: 0.7, x: 660, y: 172},
  {id: "on2", label: "", kind: "switch", default: 1, x: 735, y: 172},
  {id: "vol3", label: "OSC 3", kind: "knob", small: true, default: 0.5, x: 660, y: 240},
  {id: "on3", label: "", kind: "switch", default: 0, x: 735, y: 240},
  {id: "noise", label: "NOISE", kind: "knob", small: true, default: 0.3, x: 660, y: 308},
  {id: "noise_on", label: "", kind: "switch", default: 0, x: 735, y: 308},
  // modifiers: the filter and the loudness contour
  {id: "cutoff", label: "CUTOFF", kind: "knob", default: 0.45, x: 845, y: ROW1},
  {id: "emphasis", label: "EMPHASIS", kind: "knob", default: 0.35, x: 915, y: ROW1},
  {id: "contour", label: "CONTOUR", kind: "knob", default: 0.5, x: 985, y: ROW1},
  {id: "f_attack", label: "ATTACK", kind: "knob", default: 0.05, x: 845, y: ROW2},
  {id: "f_decay", label: "DECAY", kind: "knob", default: 0.4, x: 915, y: ROW2},
  {id: "f_sustain", label: "SUSTAIN", kind: "knob", default: 0.3, x: 985, y: ROW2},
  {id: "a_attack", label: "ATTACK", kind: "knob", default: 0.02, x: 845, y: ROW3},
  {id: "a_decay", label: "DECAY", kind: "knob", default: 0.4, x: 915, y: ROW3},
  {id: "a_sustain", label: "SUSTAIN", kind: "knob", default: 0.8, x: 985, y: ROW3},
  {id: "kbd_ctrl", label: "KBD CTRL", kind: "switch", default: 1, x: 1045, y: ROW1},
  {id: "decay_sw", label: "DECAY", kind: "switch", default: 1, x: 1045, y: ROW3},
  // output
  {id: "volume", label: "VOLUME", kind: "knob", default: 0.6, x: 1120, y: ROW1},
  // the wheels left of the keyboard (drawn there, not on the panel)
  {id: "bend", label: "PITCH", kind: "wheel", bipolar: true, default: 0.5},
  {id: "mod", label: "MOD", kind: "wheel", default: 0.0},
}

params.index = {}
for(local i = 0; i < len(params.list); i = i + 1){
  params.index[params.list[i].id] = i
}
params.count = len(params.list)

return params
