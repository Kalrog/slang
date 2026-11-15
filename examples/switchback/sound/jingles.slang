// sound/jingles: the interface's jingles as notes: what is played when a
// camp is found, the truck mended, a checkpoint passed, the summit
// reached, a marker arrived at, the truck broken. Two instruments play
// them (sound/layers/interface): a plucked string (sound/interface/pluck)
// and a bar under a soft mallet (sound/interface/bell), out of doors: a
// valley that answers once, faintly (sound/interface/stage).
//
//   local jingles = require("sound/jingles")
//   jingles.by_name.camp_found.notes     // {{at, play, note, level, ...}}
//   jingles.hz(jingles.note("F#5"))      // 739.99
//
// All are in D major, so that whichever follow each other belong
// together, and they share a pace (a step of 0.15 s; the valley's echo
// comes three steps late). The camp's figure is the game's own: the open
// fifth and second of D rising from the A below (A D E A), then two
// bells further up. A camp already known gets its first two notes; a
// truck mended, the triad up to the D. A checkpoint is two bells, of
// which the first is always the A: the second says how the run goes: up
// to D ahead of the best time, the A again without one, down to G sharp
// behind it. The summit is the cadence: G, A, and D strummed.
local math = require("slang/math")
local str = require("slang/string")

local m = {}

// the pace: a step, s, and how late the valley's echo is, s
m.STEP = 0.15
m.ECHO = 0.45

local SEMITONES = {C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11}

// note(name: string) -> int: a note's number as MIDI counts them
// ("A4": 69, "C4": 60); "F#5" is F sharp, "Bb3" B flat
func m.note(name){
  local n = SEMITONES[str.substring(name, 0, 1)]
  if(n == null){
    raise(error.new(error.kinds.argument, concat("jingles: no note ", name)))
  }
  local at = 1
  if(str.substring(name, 1, 2) == "#"){
    n = n + 1
    at = 2
  } else if(str.substring(name, 1, 2) == "b"){
    n = n - 1
    at = 2
  }
  return n + 12 * (to_int(str.to_number(str.substring(name, at))) + 1)
}

// hz(note: int) -> float: its frequency in equal temperament, A4 = 440 Hz
func m.hz(note){
  return 440 * math.exp((note - 69) / 12 * math.log(2))
}

// A note of a jingle.
// type Note = {at: float, play: string, note: int, level: float,
//   ring?: float, hold?: float, bright?: float}
// [at]: when, in seconds from the jingle's start
// [play]: "string" or "bell"
// [note]: as MIDI counts them
// [level]: how hard, 0 to 1
// [ring]: how long it rings, s (to 60 dB down; by its pitch when left out)
// [hold]: after so many seconds the string is stopped (a hand laid on
//   it); left out, it rings out
// [bright]: 0 dull to 1 bright (0.5 when left out)
local func played(play, at, name, level, more){
  local note = {at: at, play: play, note: m.note(name), level: level}
  for(let local e in entries(more or {})){
    note[e[0]] = e[1]
  }
  return note
}

local func pluck(at, name, level, more){
  return played("string", at, name, level, more)
}

local func bell(at, name, level, more){
  return played("bell", at, name, level, more)
}

// The jingles, in the order the layer counts them.
// type Jingle = {name: string, notes: {Note}}
m.list = {
  // a camp found: the game's own figure. Rising and open: A D E A on the
  // string (the last over the D below), then two bells: F sharp, A.
  {
    name: "camp_found",
    notes: {
      pluck(0.00, "A3", 0.72),
      pluck(0.15, "D4", 0.80),
      pluck(0.30, "E4", 0.88),
      pluck(0.60, "A4", 1.00, {bright: 0.65}),
      pluck(0.60, "D3", 0.70),
      bell(1.05, "F#5", 0.85, {ring: 1.6}),
      bell(1.35, "A5", 0.75, {ring: 1.9}),
    },
  },
  // a camp come back to: how its figure begins, softly
  {
    name: "camp",
    notes: {
      pluck(0.00, "A3", 0.58, {bright: 0.35}),
      pluck(0.18, "D4", 0.64, {bright: 0.35}),
    },
  },
  // the truck mended: done: up the triad to the D, a bell on it
  {
    name: "mended",
    notes: {
      pluck(0.00, "F#4", 0.66),
      pluck(0.11, "A4", 0.72),
      pluck(0.22, "D5", 0.78),
      bell(0.22, "D5", 0.62, {ring: 1.2}),
    },
  },
  // a checkpoint, ahead of the best time: up a fourth, home
  {
    name: "ahead",
    notes: {
      bell(0.00, "A4", 0.78, {ring: 0.8, bright: 0.6}),
      pluck(0.00, "A3", 0.55),
      bell(0.17, "D5", 0.92, {ring: 1.4, bright: 0.7}),
      pluck(0.17, "D4", 0.65),
    },
  },
  // a checkpoint without a best time to compare: the same note again
  {
    name: "passed",
    notes: {
      bell(0.00, "A4", 0.78, {ring: 0.8}),
      pluck(0.00, "A3", 0.55),
      bell(0.17, "A4", 0.80, {ring: 1.2}),
    },
  },
  // a checkpoint, behind: down a semitone, out of the key, and duller
  {
    name: "behind",
    notes: {
      bell(0.00, "A4", 0.74, {ring: 0.8, bright: 0.35}),
      pluck(0.00, "A3", 0.52, {bright: 0.3}),
      bell(0.19, "G#4", 0.74, {ring: 1.1, bright: 0.25}),
      pluck(0.19, "G#3", 0.52, {bright: 0.3}),
    },
  },
  // the summit: the fullest. G, then A (each stopped as the next comes),
  // then D strummed from the bass up and left to ring; the bell goes B,
  // C sharp, D over them and on up the triad.
  {
    name: "summit",
    notes: {
      pluck(0.00, "G3", 0.80, {hold: 0.47}),
      pluck(0.03, "B3", 0.68, {hold: 0.44}),
      pluck(0.06, "D4", 0.74, {hold: 0.41}),
      bell(0.00, "B4", 0.72, {ring: 0.9}),
      pluck(0.45, "A3", 0.82, {hold: 0.47}),
      pluck(0.48, "C#4", 0.70, {hold: 0.44}),
      pluck(0.51, "E4", 0.76, {hold: 0.41}),
      bell(0.45, "C#5", 0.76, {ring: 0.9}),
      pluck(0.900, "D3", 0.74, {ring: 2.0}),
      pluck(0.928, "A3", 0.62, {ring: 1.9}),
      pluck(0.956, "D4", 0.66, {ring: 1.8}),
      pluck(0.984, "F#4", 0.68, {ring: 1.6, bright: 0.6}),
      pluck(1.012, "A4", 0.72, {ring: 1.5, bright: 0.65}),
      bell(0.90, "D5", 0.90, {ring: 1.9, bright: 0.6}),
      bell(1.35, "F#5", 0.52, {ring: 1.3}),
      bell(1.50, "A5", 0.54, {ring: 1.4}),
      bell(1.65, "D6", 0.60, {ring: 1.7}),
    },
  },
  // a marker reached: one warm bell, the D and the D below in it
  {
    name: "arrived",
    notes: {
      bell(0.00, "D5", 0.96, {ring: 1.7, bright: 0.4}),
      bell(0.00, "D4", 0.50, {ring: 1.3, bright: 0.3}),
    },
  },
  // the truck broken down or wrecked: three steps down to the D, dull
  {
    name: "broken",
    notes: {
      pluck(0.00, "F#4", 0.89, {bright: 0.1, ring: 0.8}),
      pluck(0.24, "E4", 0.81, {bright: 0.1, ring: 0.8}),
      pluck(0.48, "D4", 0.89, {bright: 0.1, ring: 1.1}),
    },
  },
}

// the jingles by name, and each one's place in the list
m.by_name = {}
m.index = {}
for(local i = 0; i < len(m.list); i = i + 1){
  local jingle = m.list[i]
  m.by_name[jingle.name] = jingle
  m.index[jingle.name] = i
  // (in the order they are played)
  for(local k = 1; k < len(jingle.notes); k = k + 1){
    local note = jingle.notes[k]
    local at = k
    for(at > 0 and jingle.notes[at - 1].at > note.at){
      jingle.notes[at] = jingle.notes[at - 1]
      at = at - 1
    }
    jingle.notes[at] = note
  }
}

return m
