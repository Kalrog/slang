// The built-in bank: 32 patches, made for this synth. Each lists its
// operators 1 to 6 (see patch.slang for the fields; a missing operator is
// silent). eg is {{r1, r2, r3, r4}, {l1, l2, l3, l4}}.
//
// How loud a modulator makes its target bright: its level sets how far it
// moves the target's phase, 2 cycles at 99, halved every 8 below (91: 1
// cycle, 83: a half, 75: a quarter). Around 70 to 85 is the useful range;
// envelopes on modulators are what make a sound change as it plays.
local patch = require("patch")
local op = patch.op
local voice = patch.voice

// envelopes used often
local ORGAN = {{99, 99, 99, 80}, {99, 99, 99, 0}}
local PIANO = {{99, 30, 22, 60}, {99, 82, 0, 0}}
local PLUCK = {{99, 45, 30, 65}, {99, 60, 0, 0}}
local PAD = {{45, 30, 30, 40}, {99, 95, 92, 0}}
// a fast decay to nothing: the attack's bite
local BITE = {{99, 70, 40, 70}, {99, 0, 0, 0}}

local vibrato = {wave: "SINE", speed: 36, delay: 40, pmd: 6}

return {
  voice({
    name: "TINE PIANO", algorithm: 5, feedback: 6,
    lfo: vibrato, pms: 2,
    ops: {
      op({ratio: 1, level: 99, vel: 2, eg: {{96, 25, 25, 67}, {99, 75, 0, 0}}, rs: 2}),
      op({ratio: 1, level: 76, vel: 6, eg: {{95, 50, 35, 78}, {99, 70, 0, 0}}, rs: 3}),
      op({ratio: 1, level: 86, detune: 3, vel: 2, eg: {{96, 25, 25, 67}, {99, 75, 0, 0}}, rs: 2}),
      op({ratio: 14, level: 62, vel: 7, eg: BITE, rs: 4, rdepth: 30, rcurve: "-LIN"}),
      op({ratio: 1, level: 80, detune: -3, eg: {{96, 25, 25, 67}, {99, 75, 0, 0}}, rs: 2}),
      op({ratio: 1, level: 58, vel: 5, eg: {{95, 50, 35, 78}, {99, 70, 0, 0}}}),
    },
  }),
  voice({
    name: "BELL PIANO", algorithm: 5, feedback: 4,
    ops: {
      op({ratio: 1, level: 99, vel: 3, eg: PIANO, rs: 2}),
      op({ratio: 1, level: 80, vel: 5, eg: {{99, 40, 30, 70}, {99, 75, 0, 0}}, rs: 2}),
      op({ratio: 3, level: 82, vel: 4, eg: {{99, 35, 28, 60}, {99, 70, 0, 0}}, rs: 3}),
      op({ratio: 3.5, level: 72, vel: 6, eg: {{99, 50, 30, 70}, {99, 60, 0, 0}}}),
      op({ratio: 1, level: 84, detune: 4, eg: PIANO, rs: 2}),
      op({ratio: 7, level: 55, vel: 7, eg: BITE}),
    },
  }),
  voice({
    name: "BRIGHT PIANO", algorithm: 3, feedback: 5,
    ops: {
      op({ratio: 1, level: 99, vel: 3, eg: PIANO, rs: 3, rdepth: 20, rcurve: "-EXP"}),
      op({ratio: 1, level: 80, vel: 5, eg: {{99, 40, 25, 60}, {99, 70, 0, 0}}, rs: 3}),
      op({ratio: 7, level: 62, vel: 7, eg: BITE, rs: 3}),
      op({ratio: 1, level: 92, detune: 2, vel: 3, eg: PIANO, rs: 3}),
      op({ratio: 1, level: 76, vel: 5, eg: {{99, 45, 25, 60}, {99, 65, 0, 0}}, rs: 3}),
      op({ratio: 3, level: 58, vel: 6, eg: BITE}),
    },
  }),
  voice({
    name: "CLAVI", algorithm: 5, feedback: 7,
    ops: {
      op({ratio: 1, level: 99, vel: 3, eg: {{99, 45, 30, 78}, {99, 80, 0, 0}}}),
      op({ratio: 1, level: 86, vel: 6, eg: {{99, 50, 35, 78}, {99, 72, 0, 0}}}),
      op({ratio: 2, level: 88, vel: 3, eg: {{99, 50, 35, 78}, {99, 75, 0, 0}}}),
      op({ratio: 5, level: 72, vel: 6, eg: {{99, 60, 40, 78}, {99, 55, 0, 0}}}),
      op({ratio: 1, level: 82, detune: 2, eg: {{99, 45, 30, 78}, {99, 80, 0, 0}}}),
      op({ratio: 1, level: 72, vel: 5, eg: {{99, 55, 35, 78}, {99, 60, 0, 0}}}),
    },
  }),
  voice({
    name: "HARPSICHORD", algorithm: 5, feedback: 5,
    ops: {
      op({ratio: 1, level: 99, eg: {{99, 33, 25, 72}, {99, 82, 0, 0}}, rs: 3}),
      op({ratio: 3, level: 82, eg: {{99, 45, 30, 72}, {99, 70, 0, 0}}, rs: 3}),
      op({ratio: 2, level: 88, eg: {{99, 33, 25, 72}, {99, 82, 0, 0}}, rs: 3}),
      op({ratio: 5, level: 74, eg: {{99, 50, 30, 72}, {99, 60, 0, 0}}}),
      op({ratio: 4, level: 78, detune: 2, eg: {{99, 33, 25, 72}, {99, 82, 0, 0}}, rs: 3}),
      op({ratio: 1, level: 70, eg: {{99, 55, 30, 72}, {99, 60, 0, 0}}}),
    },
  }),
  voice({
    name: "PIPE ORGAN", algorithm: 32, feedback: 0,
    lfo: {wave: "SINE", speed: 30, pmd: 4}, pms: 2,
    ops: {
      op({ratio: 0.5, level: 99, eg: {{80, 99, 99, 60}, {99, 99, 99, 0}}}),
      op({ratio: 1, level: 96, eg: {{80, 99, 99, 60}, {99, 99, 99, 0}}}),
      op({ratio: 2, level: 92, eg: {{80, 99, 99, 60}, {99, 99, 99, 0}}}),
      op({ratio: 3, level: 84, eg: {{80, 99, 99, 60}, {99, 99, 99, 0}}}),
      op({ratio: 4, level: 86, eg: {{80, 99, 99, 60}, {99, 99, 99, 0}}}),
      op({ratio: 8, level: 76, eg: {{80, 99, 99, 60}, {99, 99, 99, 0}}}),
    },
  }),
  voice({
    name: "DRAWBARS", algorithm: 32, feedback: 2,
    lfo: {wave: "TRI", speed: 45, pmd: 8}, pms: 2,
    ops: {
      op({ratio: 0.5, level: 99, eg: ORGAN}),
      op({ratio: 1.5, level: 90, eg: ORGAN}),
      op({ratio: 1, level: 99, eg: ORGAN}),
      op({ratio: 2, level: 90, eg: ORGAN}),
      op({ratio: 3, level: 86, eg: ORGAN}),
      op({ratio: 4, level: 84, eg: ORGAN}),
    },
  }),
  voice({
    name: "ROCK ORGAN", algorithm: 32, feedback: 6,
    lfo: {wave: "TRI", speed: 52, pmd: 10}, pms: 2,
    ops: {
      op({ratio: 0.5, level: 99, eg: ORGAN}),
      op({ratio: 1, level: 99, eg: ORGAN}),
      op({ratio: 2, level: 92, eg: ORGAN}),
      op({ratio: 3, level: 88, eg: ORGAN}),
      op({ratio: 4, level: 82, eg: {{99, 60, 40, 80}, {99, 70, 0, 0}}}),
      op({ratio: 1, level: 86, eg: ORGAN}),
    },
  }),
  voice({
    name: "BRASS", algorithm: 22, feedback: 7,
    lfo: vibrato, pms: 3,
    pitch_eg: {{75, 99, 99, 99}, {50, 50, 50, 47}},
    ops: {
      op({ratio: 1, level: 99, vel: 2, eg: {{72, 40, 35, 55}, {99, 95, 92, 0}}}),
      op({ratio: 1, level: 84, vel: 4, eg: {{55, 40, 30, 55}, {99, 88, 80, 0}}}),
      op({ratio: 1, level: 92, detune: -3, eg: {{70, 40, 35, 55}, {99, 95, 92, 0}}}),
      op({ratio: 1, level: 92, detune: 3, eg: {{70, 40, 35, 55}, {99, 95, 92, 0}}}),
      op({ratio: 1, level: 88, eg: {{70, 40, 35, 55}, {99, 95, 92, 0}}}),
      op({ratio: 1, level: 78, vel: 4, eg: {{52, 40, 30, 55}, {99, 85, 78, 0}}}),
    },
  }),
  voice({
    name: "SYNTH BRASS", algorithm: 5, feedback: 5,
    lfo: {wave: "SINE", speed: 32, delay: 30, pmd: 5}, pms: 3,
    ops: {
      op({ratio: 1, level: 99, eg: {{80, 40, 35, 55}, {99, 95, 92, 0}}}),
      op({ratio: 1, level: 86, vel: 3, eg: {{60, 35, 30, 55}, {99, 74, 62, 0}}}),
      op({ratio: 1, level: 96, detune: -5, eg: {{80, 40, 35, 55}, {99, 95, 92, 0}}}),
      op({ratio: 1, level: 86, vel: 3, eg: {{60, 35, 30, 55}, {99, 74, 62, 0}}}),
      op({ratio: 1, level: 96, detune: 5, eg: {{80, 40, 35, 55}, {99, 95, 92, 0}}}),
      op({ratio: 1, level: 84, vel: 3, eg: {{60, 35, 30, 55}, {99, 74, 62, 0}}}),
    },
  }),
  voice({
    name: "STRINGS", algorithm: 5, feedback: 3,
    lfo: {wave: "SINE", speed: 38, delay: 45, pmd: 9}, pms: 3,
    ops: {
      op({ratio: 1, level: 96, eg: {{48, 30, 30, 45}, {99, 95, 95, 0}}}),
      op({ratio: 1, level: 72, eg: {{45, 30, 30, 45}, {99, 92, 90, 0}}}),
      op({ratio: 1, level: 96, detune: -4, eg: {{48, 30, 30, 45}, {99, 95, 95, 0}}}),
      op({ratio: 1, level: 72, eg: {{45, 30, 30, 45}, {99, 92, 90, 0}}}),
      op({ratio: 2, level: 86, detune: 4, eg: {{46, 30, 30, 45}, {99, 95, 95, 0}}}),
      op({ratio: 1, level: 70, eg: {{45, 30, 30, 45}, {99, 92, 90, 0}}}),
    },
  }),
  voice({
    name: "SLOW STRINGS", algorithm: 5, feedback: 4,
    lfo: {wave: "SINE", speed: 34, delay: 55, pmd: 10}, pms: 3,
    ops: {
      op({ratio: 1, level: 96, eg: {{30, 25, 25, 38}, {99, 95, 95, 0}}}),
      op({ratio: 1, level: 70, eg: {{28, 25, 25, 38}, {99, 92, 90, 0}}}),
      op({ratio: 1, level: 96, detune: -5, eg: {{30, 25, 25, 38}, {99, 95, 95, 0}}}),
      op({ratio: 1, level: 70, eg: {{28, 25, 25, 38}, {99, 92, 90, 0}}}),
      op({ratio: 0.5, level: 88, detune: 5, eg: {{30, 25, 25, 38}, {99, 95, 95, 0}}}),
      op({ratio: 1, level: 68, eg: {{28, 25, 25, 38}, {99, 92, 90, 0}}}),
    },
  }),
  voice({
    name: "VOICES", algorithm: 5, feedback: 0,
    lfo: {wave: "SINE", speed: 32, delay: 50, pmd: 10}, pms: 3,
    ops: {
      op({ratio: 1, level: 98, eg: {{40, 30, 30, 40}, {99, 95, 95, 0}}}),
      op({ratio: 1, level: 60, eg: {{40, 30, 30, 40}, {99, 95, 95, 0}}}),
      op({ratio: 3, level: 82, detune: 2, eg: {{38, 30, 30, 40}, {99, 92, 90, 0}}}),
      op({ratio: 1, level: 56, eg: {{40, 30, 30, 40}, {99, 95, 95, 0}}}),
      op({ratio: 5, level: 76, detune: -2, eg: {{36, 30, 30, 40}, {99, 90, 88, 0}}}),
      op({ratio: 1, level: 50, eg: {{40, 30, 30, 40}, {99, 95, 95, 0}}}),
    },
  }),
  voice({
    name: "FLUTE", algorithm: 5, feedback: 7,
    lfo: {wave: "SINE", speed: 36, delay: 45, pmd: 7}, pms: 3,
    ops: {
      op({ratio: 1, level: 99, vel: 2, eg: {{60, 40, 35, 60}, {99, 95, 92, 0}}}),
      op({ratio: 1, level: 56, vel: 3, eg: {{70, 40, 35, 60}, {99, 85, 80, 0}}}),
      op({ratio: 2, level: 72, eg: {{60, 40, 35, 60}, {99, 92, 88, 0}}}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 62, eg: {{99, 60, 50, 60}, {99, 50, 40, 0}}}),
      op({ratio: 7.43, level: 99, eg: {{99, 60, 50, 60}, {99, 90, 85, 0}}}),
    },
  }),
  voice({
    name: "CLARINET", algorithm: 5, feedback: 0,
    lfo: {wave: "SINE", speed: 34, delay: 50, pmd: 5}, pms: 3,
    ops: {
      op({ratio: 1, level: 99, vel: 2, eg: {{65, 40, 35, 60}, {99, 95, 92, 0}}}),
      op({ratio: 2, level: 80, vel: 4, eg: {{60, 40, 35, 60}, {99, 88, 82, 0}}}),
      op({ratio: 3, level: 74, eg: {{65, 40, 35, 60}, {99, 92, 88, 0}}}),
      op({ratio: 2, level: 66, eg: {{60, 40, 35, 60}, {99, 85, 80, 0}}}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 0}),
    },
  }),
  voice({
    name: "OBOE", algorithm: 5, feedback: 2,
    lfo: {wave: "SINE", speed: 38, delay: 40, pmd: 6}, pms: 3,
    ops: {
      op({ratio: 1, level: 99, vel: 2, eg: {{70, 40, 35, 60}, {99, 95, 92, 0}}}),
      op({ratio: 1, level: 84, vel: 4, eg: {{65, 40, 35, 60}, {99, 90, 86, 0}}}),
      op({ratio: 4, level: 84, eg: {{70, 40, 35, 60}, {99, 92, 90, 0}}}),
      op({ratio: 1, level: 72, eg: {{65, 40, 35, 60}, {99, 88, 85, 0}}}),
      op({ratio: 3, level: 78, eg: {{70, 40, 35, 60}, {99, 92, 90, 0}}}),
      op({ratio: 1, level: 60, eg: {{65, 40, 35, 60}, {99, 88, 85, 0}}}),
    },
  }),
  voice({
    name: "MARIMBA", algorithm: 5, feedback: 0,
    ops: {
      op({ratio: 1, level: 99, vel: 3, eg: {{99, 42, 40, 60}, {99, 0, 0, 0}}, rs: 3}),
      op({ratio: 4, level: 66, vel: 6, eg: {{99, 75, 50, 70}, {99, 0, 0, 0}}}),
      op({ratio: 4, level: 78, vel: 4, eg: {{99, 62, 50, 70}, {99, 0, 0, 0}}, rs: 4}),
      op({ratio: 1, level: 40, eg: {{99, 70, 50, 70}, {99, 0, 0, 0}}}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 0}),
    },
  }),
  voice({
    name: "VIBES", algorithm: 5, feedback: 0,
    lfo: {wave: "TRI", speed: 26, amd: 40, sync: 0},
    ops: {
      op({ratio: 1, level: 99, vel: 3, ams: 2, eg: {{99, 30, 28, 45}, {99, 75, 0, 0}}, rs: 2}),
      op({ratio: 1, level: 52, vel: 6, eg: {{99, 60, 40, 60}, {99, 30, 0, 0}}}),
      op({ratio: 4, level: 78, vel: 4, ams: 2, eg: {{99, 45, 35, 50}, {99, 50, 0, 0}}, rs: 3}),
      op({ratio: 1, level: 48, eg: {{99, 60, 40, 60}, {99, 0, 0, 0}}}),
      op({ratio: 10, level: 60, vel: 7, eg: BITE}),
      op({ratio: 1, level: 0}),
    },
  }),
  voice({
    name: "XYLOPHONE", algorithm: 5, feedback: 0,
    ops: {
      op({ratio: 1, level: 99, vel: 3, eg: {{99, 55, 50, 70}, {99, 0, 0, 0}}, rs: 4}),
      op({ratio: 3, level: 64, vel: 6, eg: {{99, 80, 50, 70}, {99, 0, 0, 0}}}),
      op({ratio: 3, level: 82, vel: 4, eg: {{99, 65, 50, 70}, {99, 0, 0, 0}}, rs: 4}),
      op({ratio: 2.5, level: 60, eg: {{99, 80, 50, 70}, {99, 0, 0, 0}}}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 0}),
    },
  }),
  voice({
    name: "TUBULAR BELLS", algorithm: 5, feedback: 2,
    ops: {
      op({ratio: 1, level: 99, vel: 2, eg: {{99, 28, 24, 38}, {99, 70, 0, 0}}}),
      op({ratio: 3.5, level: 76, vel: 5, eg: {{99, 30, 25, 40}, {99, 65, 0, 0}}}),
      op({ratio: 2, level: 88, detune: 4, eg: {{99, 30, 24, 38}, {99, 70, 0, 0}}}),
      op({ratio: 2.76, level: 72, vel: 5, eg: {{99, 32, 25, 40}, {99, 60, 0, 0}}}),
      op({ratio: 4.2, level: 80, detune: -3, eg: {{99, 40, 30, 40}, {99, 60, 0, 0}}}),
      op({ratio: 1.41, level: 70, eg: {{99, 50, 30, 40}, {99, 40, 0, 0}}}),
    },
  }),
  voice({
    name: "GLOCKENSPIEL", algorithm: 5, feedback: 0,
    ops: {
      op({ratio: 4, level: 99, vel: 3, eg: {{99, 38, 30, 45}, {99, 40, 0, 0}}, rs: 3}),
      op({ratio: 3.5, level: 60, vel: 6, eg: {{99, 60, 40, 50}, {99, 20, 0, 0}}}),
      op({ratio: 11, level: 80, vel: 4, eg: {{99, 50, 40, 50}, {99, 20, 0, 0}}}),
      op({ratio: 1, level: 50, eg: BITE}),
      op({ratio: 8, level: 74, eg: {{99, 45, 35, 50}, {99, 30, 0, 0}}}),
      op({ratio: 1, level: 0}),
    },
  }),
  voice({
    name: "STEEL DRUM", algorithm: 5, feedback: 0,
    pitch_eg: {{99, 60, 99, 99}, {50, 50, 50, 52}},
    ops: {
      op({ratio: 1, level: 99, vel: 3, eg: {{99, 40, 32, 55}, {99, 50, 0, 0}}}),
      op({ratio: 1.68, level: 74, vel: 6, eg: {{99, 55, 40, 55}, {99, 40, 0, 0}}}),
      op({ratio: 2, level: 84, eg: {{99, 45, 35, 55}, {99, 40, 0, 0}}}),
      op({ratio: 3.38, level: 62, vel: 6, eg: BITE}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 0}),
    },
  }),
  voice({
    name: "SOLID BASS", algorithm: 5, feedback: 5,
    ops: {
      op({ratio: 0.5, level: 99, vel: 2, eg: {{99, 40, 22, 72}, {99, 90, 0, 0}}}),
      op({ratio: 0.5, level: 84, vel: 5, eg: {{99, 55, 40, 72}, {99, 65, 50, 0}}}),
      op({ratio: 0.5, level: 84, detune: 3, eg: {{99, 40, 22, 72}, {99, 90, 0, 0}}}),
      op({ratio: 1.5, level: 70, vel: 6, eg: BITE}),
      op({ratio: 1, level: 72, eg: {{99, 50, 30, 72}, {99, 60, 0, 0}}}),
      op({ratio: 3, level: 72, vel: 7, eg: BITE}),
    },
  }),
  voice({
    name: "SLAP BASS", algorithm: 5, feedback: 6,
    ops: {
      op({ratio: 0.5, level: 99, vel: 3, eg: {{99, 50, 25, 75}, {99, 82, 0, 0}}}),
      op({ratio: 0.5, level: 90, vel: 6, eg: {{99, 75, 40, 75}, {99, 55, 0, 0}}}),
      op({ratio: 1, level: 86, vel: 3, eg: {{99, 50, 25, 75}, {99, 75, 0, 0}}}),
      op({ratio: 3, level: 80, vel: 7, eg: {{99, 80, 50, 75}, {99, 0, 0, 0}}}),
      op({ratio: 0.5, level: 78, detune: -2, eg: {{99, 50, 25, 75}, {99, 82, 0, 0}}}),
      op({ratio: 7, level: 62, vel: 7, eg: BITE}),
    },
  }),
  voice({
    name: "SYNTH BASS", algorithm: 31, feedback: 6,
    ops: {
      op({ratio: 0.5, level: 82, detune: 3, eg: {{99, 40, 30, 70}, {99, 90, 85, 0}}}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 0}),
      op({ratio: 0.5, level: 99, eg: {{99, 40, 30, 70}, {99, 90, 85, 0}}}),
      op({ratio: 0.5, level: 88, vel: 5, eg: {{99, 48, 35, 70}, {99, 70, 58, 0}}}),
    },
  }),
  voice({
    name: "HARP", algorithm: 5, feedback: 0,
    ops: {
      op({ratio: 1, level: 99, vel: 3, eg: {{99, 30, 25, 45}, {99, 70, 0, 0}}, rs: 3}),
      op({ratio: 2, level: 70, vel: 6, eg: {{99, 60, 35, 50}, {99, 40, 0, 0}}}),
      op({ratio: 2, level: 82, vel: 3, eg: {{99, 35, 25, 45}, {99, 60, 0, 0}}, rs: 3}),
      op({ratio: 1, level: 60, eg: {{99, 60, 35, 50}, {99, 30, 0, 0}}}),
      op({ratio: 1, level: 80, detune: 3, eg: {{99, 30, 25, 45}, {99, 70, 0, 0}}}),
      op({ratio: 4, level: 54, vel: 7, eg: BITE}),
    },
  }),
  voice({
    name: "KOTO", algorithm: 5, feedback: 4,
    lfo: {wave: "SINE", speed: 40, delay: 60, pmd: 12}, pms: 3,
    pitch_eg: {{99, 80, 99, 99}, {50, 50, 50, 51}},
    ops: {
      op({ratio: 1, level: 99, vel: 3, eg: {{99, 36, 28, 50}, {99, 65, 0, 0}}, rs: 3}),
      op({ratio: 3, level: 80, vel: 6, eg: {{99, 60, 35, 50}, {99, 40, 0, 0}}}),
      op({ratio: 1, level: 86, detune: 2, eg: {{99, 36, 28, 50}, {99, 65, 0, 0}}}),
      op({ratio: 5, level: 70, vel: 6, eg: BITE}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 0}),
    },
  }),
  voice({
    name: "SITAR", algorithm: 5, feedback: 7,
    lfo: {wave: "SINE", speed: 40, delay: 50, pmd: 8}, pms: 3,
    ops: {
      op({ratio: 1, level: 99, eg: {{99, 26, 22, 45}, {99, 80, 0, 0}}}),
      op({ratio: 1, level: 86, eg: {{99, 30, 22, 45}, {99, 75, 0, 0}}}),
      op({ratio: 2, level: 84, detune: 4, eg: {{99, 26, 22, 45}, {99, 75, 0, 0}}}),
      op({ratio: 5, level: 76, eg: {{99, 28, 22, 45}, {99, 70, 0, 0}}}),
      op({ratio: 3, level: 78, detune: -4, eg: {{99, 26, 22, 45}, {99, 70, 0, 0}}}),
      op({ratio: 1, level: 80, eg: {{99, 35, 22, 45}, {99, 70, 0, 0}}}),
    },
  }),
  voice({
    name: "TIMPANI", algorithm: 5, feedback: 0,
    pitch_eg: {{99, 55, 99, 99}, {50, 50, 50, 55}},
    ops: {
      op({ratio: 0.5, level: 99, vel: 3, eg: {{99, 35, 30, 45}, {99, 60, 0, 0}}}),
      op({ratio: 0.71, level: 74, vel: 5, eg: {{99, 55, 35, 50}, {99, 30, 0, 0}}}),
      op({ratio: 1, level: 80, eg: {{99, 45, 35, 45}, {99, 40, 0, 0}}}),
      op({ratio: 1.6, level: 70, vel: 6, eg: BITE}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 0}),
    },
  }),
  voice({
    name: "GLASS PAD", algorithm: 5, feedback: 3,
    lfo: {wave: "SINE", speed: 22, pmd: 5, amd: 20, sync: 0}, pms: 2,
    ops: {
      op({ratio: 1, level: 96, eg: PAD}),
      op({ratio: 1, level: 70, eg: {{40, 28, 28, 40}, {99, 88, 84, 0}}}),
      op({ratio: 1, level: 94, detune: 5, eg: PAD}),
      op({ratio: 2, level: 66, eg: {{40, 28, 28, 40}, {99, 88, 84, 0}}}),
      op({ratio: 3, level: 82, detune: -3, ams: 2, eg: {{60, 30, 28, 40}, {99, 80, 70, 0}}}),
      op({ratio: 3.5, level: 72, eg: {{60, 35, 28, 40}, {99, 70, 60, 0}}}),
    },
  }),
  voice({
    name: "SAW LEAD", algorithm: 32, feedback: 7,
    lfo: {wave: "SINE", speed: 40, delay: 35, pmd: 0}, pms: 4,
    ops: {
      op({ratio: 1, level: 84, detune: 5, eg: {{99, 50, 40, 65}, {99, 92, 90, 0}}}),
      op({ratio: 0.5, level: 80, eg: {{99, 50, 40, 65}, {99, 92, 90, 0}}}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 0}),
      op({ratio: 1, level: 99, eg: {{99, 50, 40, 65}, {99, 92, 90, 0}}}),
    },
  }),
  voice({
    name: "SPACE CHIMES", algorithm: 5, feedback: 0,
    lfo: {wave: "S/HOLD", speed: 50, pmd: 0, amd: 0},
    ops: {
      op({ratio: 1, level: 96, eg: {{60, 20, 20, 25}, {99, 70, 0, 0}}}),
      op({ratio: 1.41, level: 78, eg: {{60, 22, 20, 25}, {99, 70, 0, 0}}}),
      op({ratio: 2.76, level: 88, detune: 6, eg: {{70, 22, 20, 25}, {99, 65, 0, 0}}}),
      op({ratio: 3.5, level: 74, eg: {{70, 25, 20, 25}, {99, 60, 0, 0}}}),
      op({ratio: 5.4, level: 82, detune: -6, eg: {{80, 28, 20, 25}, {99, 55, 0, 0}}}),
      op({ratio: 7.1, level: 70, eg: {{80, 30, 20, 25}, {99, 50, 0, 0}}}),
    },
  }),
}
