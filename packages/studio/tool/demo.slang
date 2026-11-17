// Renders a short piece that uses most of the package (five instruments,
// six effects, a bus, a sidechain, an LFO, a curve) to a WAV file, and
// says how much of a core it took.
//
//   slang run tool/demo.slang [out.wav]        (make studio-demo)
local math = require("slang/math")
local time = require("slang/time")
local studio = require("studio")
local sequence = require("studio/sequence")
local wav = require("studio/wav")

local out = args()[0] or "demo.wav"

local s = studio.new()

// ---- the strips
local hall = s:bus("hall")
hall:insert("hall", {decay: 2800, size: 0.6, damp: 0.5, mix: 1})
hall.gain = 0.7

local drums = s:track("drums", "drums", {
  kit: "808", kick_decay: 1.2, gain: 0.5
})
drums:insert("compressor", {patch: "Drums", makeup: 2})
drums:send(hall, 0.06)

local bass = s:track("bass", "mini", {patch: "Fat Bass", volume: 0.55})
bass.gain = 0.8
s:lfo({rate: 0.2, shape: "sine"}):to(bass.unit, "cutoff", 0.06)

local keys = s:track("keys", "six", {patch: "TINE PIANO", volume: 0.6})
keys:insert("chorus", {mix: 0.35})
keys:send(hall, 0.2)
keys.pan = -0.15

local pad = s:track("pad", "poly", {patch: "Pad", gain: 0.2, cutoff: 0.35})
pad:insert("phaser", {rate: 0.11, feedback: 0.5, mix: 0.6})
// the pad makes room for the drums
pad:insert("compressor", {sidechain: drums, patch: "Duck", release: 180})
pad:send(hall, 0.5)
pad.pan = 0.2

local bell = s:track("bell", "bell", {decay: 1.2, index: 2.0})
bell:insert("delay", {
  time: 450, feedback: 0.4, cross: true, mix: 0.3, tone: 0.4
})
bell:send(hall, 0.3)
bell.gain = 0.5

s.master:insert("eq", {low_cut: 30, high_gain: 1.5})
s.master:insert("limiter", {ceiling: -1})
s.master.gain = 0.7

// ---- the piece: eight bars in A minor, two bars a chord
local song = sequence.new(s, {bpm: 100, swing: 0.15})
local chords = {
  {root: 33, notes: {57, 60, 64, 67}}, // Am7
  {root: 29, notes: {53, 57, 60, 64}}, // Fmaj7
  {root: 36, notes: {55, 59, 60, 64}}, // Cmaj7
  {root: 31, notes: {55, 59, 62, 67}}, // G
}
for(local c = 0; c < 4; c = c + 1){
  local chord = chords[c]
  local at = c * 8
  for(let local n in values(chord.notes)){
    song:note(keys, at, n, {length: 3.5, velocity: 0.55})
    song:note(keys, at + 4.5, n, {length: 3, velocity: 0.45})
    song:note(pad, at, n - 12, {length: 8, velocity: 0.6})
  }
  for(local bar = 0; bar < 2; bar = bar + 1){
    local b = at + bar * 4
    song:notes(bass, {
      {b, 0.5, chord.root},
      {b + 1.5, 0.4, chord.root},
      {b + 2.5, 0.75, chord.root + 12},
      {b + 3.5, 0.4, chord.root + 7},
    })
    song:notes(drums, {
      {b, 1, 36, 1.0}, {b + 2.5, 1, 36, 0.8}, {b + 1, 1, 38, 0.8},
      {b + 3, 1, 39, 0.8}
    })
    for(local h = 0; h < 8; h = h + 1){
      song:note(drums, b + h * 0.5, 42, {
        velocity: if(h % 2 == 0){ 0.5 } else { 0.3 },
      })
    }
    if(bar == 1){
      song:note(drums, b + 3.5, 46, {velocity: 0.5})
    }
    // the bell comes in for the second half: the chord up and down
    if(c >= 2){
      for(local k = 0; k < 8; k = k + 1){
        local step = if(k < 4){ k } else { 7 - k }
        song:note(bell, b + k * 0.5, chord.notes[step] + 12, {
          length: 0.4, velocity: 0.5
        })
      }
    }
  }
}
// the pad opens over the piece
song:curve(pad.unit, "cutoff", {{0, 0.35}, {24, 0.7}, {32, 0.5}})
song.length = 32

local from = time.clock()
local sound = song:render({tail: 4000})
local took = time.clock() - from
local seconds = len(sound.left) / s.sample_rate
local peak = 0.0
for(local i = 0; i < len(sound.left); i = i + 1){
  peak = math.max(peak, math.abs(sound.left[i]), math.abs(sound.right[i]))
}
wav.write(out, {sound.left, sound.right}, s.sample_rate)
print(
  out,
  ": ",
  math.round(seconds * 10) / 10,
  " s, rendered in ",
  math.round(took) / 1000,
  " s (",
  math.round(took / seconds / 10 * 10) / 10,
  "% of real time), peak ",
  math.round(20 * math.log10(math.max(peak, 1.0e-9)) * 10) / 10,
  " dBFS\n",
)
