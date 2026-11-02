// The Prelude of the Cello Suite No. 1 in G major, BWV 1007, by Johann
// Sebastian Bach, an octave up. The notes: the Mutopia Project's edition
// (no. 517, from Schirmer, 1916, typeset by Andreas Scherer), placed in
// the public domain by its typesetter.
//
// The sound follows the piece: a soft start, the filter opening through
// the first sequences, more resonance over the long pedal point, the
// brightest sound and a little glide for the climb to the climax, and a
// calmer close.
return {
  title: "Prelude, Cello Suite No. 1",
  composer: "J. S. Bach",
  midi: "bach_prelude.mid",
  voice: "top",
  transpose: 12,
  patch: {
    range1: "8'", wave1: "SAW", vol1: 0.8, on1: 1,
    range2: "8'", wave2: "SAW", detune2: 0.505, vol2: 0.55, on2: 1,
    range3: "16'", wave3: "TRI", detune3: 0.5, vol3: 0.35, on3: 1,
    noise_on: 0, osc3_ctrl: 1,
    cutoff: 0.36, emphasis: 0.25, contour: 0.3, kbd_ctrl: 1,
    f_attack: 0.08, f_decay: 0.35, f_sustain: 0.5,
    a_attack: 0.04, a_decay: 0.3, a_sustain: 0.85, decay_sw: 1,
    glide: 0.0, volume: 0.74, mod: 0.0,
  },
  // in beats (quarter notes); 4 to a bar, 168 in all
  automation: {
    cutoff: {{0, 0.34}, {16, 0.38}, {56, 0.5}, {84, 0.52}, {112, 0.6}, {140, 0.7}, {152, 0.62}, {164, 0.4}, {168, 0.36}},
    emphasis: {{0, 0.25}, {56, 0.3}, {84, 0.45}, {112, 0.5}, {144, 0.58}, {156, 0.4}, {168, 0.3}},
    contour: {{0, 0.3}, {56, 0.4}, {112, 0.5}, {150, 0.55}, {164, 0.3}},
    detune2: {{0, 0.505}, {84, 0.52}, {150, 0.53}, {164, 0.505}},
    glide: {{0, 0.0}, {120, 0.0}, {132, 0.12}, {152, 0.12}, {156, 0.0}},
    vol3: {{0, 0.35}, {84, 0.5}, {150, 0.55}, {168, 0.4}},
    volume: {{0, 0.72}, {140, 0.78}, {164, 0.72}, {170, 0.6}},
  },
}
