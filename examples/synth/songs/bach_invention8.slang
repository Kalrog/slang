// Invention No. 8 in F major, BWV 779, by Johann Sebastian Bach, recorded
// as two synthesizer parts: the upper voice a bright pulse, the lower a
// round sawtooth with a plucked start. The notes: the Mutopia Project's
// edition (no. 61, from the Bach-Gesellschaft, typeset by Allen Garvin),
// placed in the public domain by its typesetter.
//
//   slang run mixdown.slang songs/bach_invention8.slang
return {
  title: "Invention No. 8 in F major",
  composer: "J. S. Bach",
  midi: "bach_invention8.mid",
  voice: "top",
  speed: 1.25,
  mix: {reverb: 0.22, room: 0.75},
  parts: {
    {
      name: "upper", tracks: {1}, pan: -0.35, gain: 0.9,
      patch: {
        range1: "8'", wave1: "WIDE", vol1: 0.8,
        range2: "4'", wave2: "SAW", detune2: 0.51, vol2: 0.3,
        on3: 0, noise_on: 0,
        cutoff: 0.48, emphasis: 0.3, contour: 0.4, kbd_ctrl: 1,
        f_attack: 0.02, f_decay: 0.3, f_sustain: 0.4,
        a_attack: 0.01, a_decay: 0.35, a_sustain: 0.75, decay_sw: 1,
        volume: 0.8,
      },
      automation: {
        cutoff: {{0, 0.44}, {40, 0.55}, {70, 0.5}, {96, 0.42}},
      },
    },
    {
      name: "lower", tracks: {2}, pan: 0.35, gain: 0.85,
      patch: {
        range1: "8'", wave1: "SAW", vol1: 0.8,
        range2: "16'", wave2: "SQR", detune2: 0.5, vol2: 0.45,
        on3: 0, noise_on: 0,
        cutoff: 0.36, emphasis: 0.25, contour: 0.45, kbd_ctrl: 1,
        f_attack: 0.0, f_decay: 0.25, f_sustain: 0.3,
        a_attack: 0.0, a_decay: 0.3, a_sustain: 0.7, decay_sw: 1,
        volume: 0.8,
      },
    },
  },
}
