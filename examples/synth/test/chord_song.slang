// a C major chord, held a beat, as three parts: one line each
return {
  title: "chord",
  notes: {{0, 1, 60}, {0, 1, 64}, {0, 1, 67}},
  bpm: 60,
  parts: {
    {name: "high", voice: 0},
    {name: "middle", voice: 1, pan: 0.5, gain: 0.5},
    {name: "low", voice: "bottom"},
  },
}
