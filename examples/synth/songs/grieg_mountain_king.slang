// "In the Hall of the Mountain King" from the Peer Gynt Suite No. 1,
// Op. 46, by Edvard Grieg: the melody of the piano version, its highest
// line kept within the keyboard by octaves. The notes: the Mutopia
// Project's edition (no. 1888, from The University Society, 1918,
// typeset by Coyau), placed in the public domain by its typesetter.
//
// A dark, plucked march at first that opens up as the theme climbs and
// repeats: the filter wider and more resonant, the third oscillator and a
// little noise joining in, a sawtooth for the faster part (Più vivo, beat
// 196), the whole thing brightest at the end.
return {
  title: "In the Hall of the Mountain King",
  composer: "Edvard Grieg",
  midi: "grieg_mountain_king.mid",
  tracks: {1},
  voice: "top",
  transpose: 12,
  fold: {47, 83},
  patch: {
    range1: "8'", wave1: "SQR", vol1: 0.75, on1: 1,
    range2: "8'", wave2: "SAW", detune2: 0.53, vol2: 0.6, on2: 1,
    range3: "16'", wave3: "SAW", detune3: 0.5, vol3: 0.0, on3: 1,
    noise: 0.0, noise_on: 1, osc3_ctrl: 1,
    cutoff: 0.26, emphasis: 0.5, contour: 0.55, kbd_ctrl: 1,
    f_attack: 0.0, f_decay: 0.2, f_sustain: 0.12,
    a_attack: 0.0, a_decay: 0.25, a_sustain: 0.55, decay_sw: 0,
    glide: 0.0, volume: 0.7, mod: 0.0,
  },
  // in beats (quarter notes): 196 at 138 a minute, then 154
  automation: {
    cutoff: {{0, 0.26}, {64, 0.3}, {96, 0.36}, {160, 0.5}, {196, 0.58}, {288, 0.72}, {336, 0.8}, {352, 0.6}},
    emphasis: {{0, 0.5}, {96, 0.55}, {196, 0.65}, {320, 0.72}, {352, 0.5}},
    contour: {{0, 0.5}, {96, 0.6}, {196, 0.7}, {352, 0.75}},
    f_decay: {{0, 0.18}, {196, 0.24}, {300, 0.3}},
    vol3: {{0, 0.0}, {96, 0.0}, {160, 0.45}, {352, 0.55}},
    noise: {{0, 0.0}, {160, 0.0}, {196, 0.25}, {352, 0.35}},
    wave1: {{0, "SQR"}, {196, "SAW"}},
    detune2: {{0, 0.53}, {196, 0.545}},
    volume: {{0, 0.7}, {196, 0.76}, {340, 0.8}},
  },
}
