// Writes the songs that come with the tracker (songs/*.json): each is
// made here from a few lines per track, so that what a song is can be read.
//
//   slang run tool/demos.slang          (make tracker-demos)
local str = require("slang/string")
local song = require("song")

// rows(s, p, t, col, text, notes): one character of text a row: `.`
// nothing, `=` OFF, a letter the note it names in `notes` (a capital: at
// full velocity)
local func rows(s, p, t, col, text, notes){
  local row = 0
  for(local i = 0; i < len(text); i = i + 1){
    local c = str.substring(text, i, i + 1)
    if(c == " "){
      continue
    }
    if(c == "="){
      song.put(s, p, t, "note", col, row, song.OFF)
    } else if(c != "."){
      local low = str.lower(c)
      song.put(s, p, t, "note", col, row, notes[low])
      if(c != low){
        song.put(s, p, t, "vel", col, row, 99)
      } else if(notes.soft != null){
        song.put(s, p, t, "vel", col, row, notes.soft)
      }
    }
    row = row + 1
  }
}

// lane(s, p, t, from, to, a, b): the lane's values from row `from` to
// `to`, sliding from a to b
local func lane(s, p, t, from, to, a, b){
  for(local row = from; row <= to; row = row + 1){
    local k = if(to == from){ 0 } else { (row - from) / (to - from) }
    song.put(s, p, t, "fx", 0, row, to_int(a + (b - a) * k + 0.5))
  }
}

local KIT = {k: 36, s: 38, c: 39, h: 42, o: 46, b: 56, soft: 60}

// ---------------------------------------------------------------- dusk
// Four chords in A minor at 100, two bars each: an 808, a bass, an
// electric piano, a pad that ducks under the drums, a bell for the
// second half.
local func dusk(){
  local s = song.new()
  s.name = "dusk"
  s.bpm = 100
  s.swing = 0.3
  s.tracks = {}
  s.patterns = {}
  local drums = song.track("drums", "drums", null, {
    kit: 1, kick_decay: 1.2, gain: 0.5
  })
  drums.columns = 2
  drums.sends.hall = 0.06
  append(drums.inserts, song.unit("compressor", "Drums", {makeup: 2}))
  song.add_track(s, drums)
  local bass = song.track("bass", "mini", "Fat Bass", {volume: 0.55})
  bass.lane = "cutoff"
  bass.gain = 0.8
  song.add_track(s, bass)
  local keys = song.track("keys", "six", "TINE PIANO", {volume: 0.6})
  keys.columns = 4
  keys.pan = -0.15
  keys.sends.hall = 0.2
  append(keys.inserts, song.unit("chorus", null, {mix: 0.35}))
  song.add_track(s, keys)
  local pad = song.track("pad", "poly", "Pad", {gain: 0.2, cutoff: 0.4})
  pad.columns = 4
  pad.lane = "cutoff"
  pad.pan = 0.2
  pad.sends.hall = 0.5
  append(pad.inserts, song.unit("phaser", null, {
    rate: 0.11, feedback: 0.5, mix: 0.6
  }))
  local duck = song.unit("compressor", "Duck", {release: 180})
  duck.sidechain = "drums"
  append(pad.inserts, duck)
  song.add_track(s, pad)
  local bell = song.track("bell", "bell", null, {decay: 1.2, index: 2.0})
  bell.gain = 0.5
  bell.sends.echo = 0.35
  bell.sends.hall = 0.3
  song.add_track(s, bell)
  s.master.inserts = {
    song.unit("eq", null, {low_cut: 30, high_gain: 1.5}),
    song.unit("limiter", null, {ceiling: -1}),
  }
  s.master.gain = 0.7

  local chords = {
    {root: 33, notes: {57, 60, 64, 67}}, // Am7
    {root: 29, notes: {53, 57, 60, 64}}, // Fmaj7
    {root: 36, notes: {55, 59, 60, 64}}, // Cmaj7
    {root: 31, notes: {55, 59, 62, 67}}, // G
  }
  for(local c = 0; c < 4; c = c + 1){
    local ch = chords[c]
    append(s.patterns, song.pattern(s, 32))
    rows(s, c, 0, 0, "K...s.....K.c... K...s.....K.c...", KIT)
    rows(s, c, 0, 1, "h.h.h.h.h.h.h.h. h.h.h.h.h.h.h.o.", KIT)
    local low = {r: ch.root, o: ch.root + 12, f: ch.root + 7}
    rows(s, c, 1, 0, "R.=...r.=.o..=f= R.=...r.=.o..=f=", low)
    lane(s, c, 1, 0, 0, 28, 28)
    lane(s, c, 1, 10, 13, 34, 44)
    lane(s, c, 1, 16, 16, 28, 28)
    lane(s, c, 1, 26, 29, 34, 48)
    for(local k = 0; k < 4; k = k + 1){
      local one = {n: ch.notes[k], soft: 55}
      rows(s, c, 2, k, "n.............=. ..n...........=.", one)
      rows(s, c, 3, k, "n............... ..............=.", {
        n: ch.notes[k] - 12, soft: 60
      })
    }
    // the pad opens over the song
    lane(s, c, 3, 0, 31, 40 + c * 8, 48 + c * 8)
    if(c >= 2){
      local up = {
        a: ch.notes[0] + 12,
        b: ch.notes[1] + 12,
        c: ch.notes[2] + 12,
        d: ch.notes[3] + 12,
        soft: 50,
      }
      rows(s, c, 4, 0, "a.b.c.d.d.c.b.a. a.b.c.d.d.c.b.a.", up)
    }
  }
  s.order = {0, 1, 2, 3}
  return s
}

// ---------------------------------------------------------------- relay
// Four on the floor at 126: an acid line whose filter the lane plays,
// chords of seven saws pumped by the kick, a plucked answer.
local func relay(){
  local s = song.new()
  s.name = "relay"
  s.bpm = 126
  s.swing = 0.0
  s.tracks = {}
  s.patterns = {}
  local drums = song.track("drums", "drums", null, {
    kit: 1, gain: 0.55, kick_decay: 0.9, open_decay: 0.6
  })
  drums.columns = 3
  drums.sends.hall = 0.04
  song.add_track(s, drums)
  local acid = song.track("acid", "mini", "Pluck Bass", {
    emphasis: 0.8, contour: 0.45, glide: 0.25, volume: 0.5
  })
  acid.lane = "cutoff"
  acid.sends.echo = 0.15
  append(acid.inserts, song.unit("drive", null, {
    drive: 0.35, mode: 1, tone: 0.8
  }))
  song.add_track(s, acid)
  local stab = song.track("stab", "poly", null, {
    wave: 6,
    detune: 24,
    pw: 0.8,
    attack: 2,
    decay: 400,
    sustain: 0.5,
    release: 300,
    cutoff: 0.62,
    res: 0.2,
    gain: 0.3,
  })
  stab.columns = 3
  stab.lane = "cutoff"
  stab.sends.hall = 0.35
  stab.sends.echo = 0.2
  local pump = song.unit("compressor", "Duck", {threshold: -30, release: 160})
  pump.sidechain = "drums"
  append(stab.inserts, pump)
  song.add_track(s, stab)
  local pluck = song.track("pluck", "pluck", null, {
    damping: 0.2, brightness: 0.9
  })
  pluck.gain = 0.7
  pluck.pan = 0.3
  pluck.sends.echo = 0.4
  pluck.sends.hall = 0.2
  song.add_track(s, pluck)
  s.buses[0].inserts[0].params.time = 357
  s.master.inserts = {song.unit("limiter", null, {ceiling: -1, gain: 2})}
  s.master.gain = 0.7

  local line = {a: 33, c: 36, d: 38, e: 40, g: 43, h: 45, soft: 70}
  local func bar(p, with_stabs, with_pluck, open){
    rows(s, p, 0, 0, "K...K...K...K... K...K...K...K...", KIT)
    rows(s, p, 0, 1, "....c.......c... ....c.......c..c", KIT)
    rows(s, p, 0, 2, "..o...o...o...o. ..o...o...o...oh", KIT)
    rows(s, p, 1, 0, "A.a.h.a.c.a.H.g. A.a.h.a.d.a.E.c.", line)
    // the filter opens through the bar and falls back
    lane(s, p, 1, 0, 15, open, open + 30)
    lane(s, p, 1, 16, 31, open + 30, open)
    if(with_stabs){
      local chord = {{57, 60, 64}, {55, 59, 62}}
      for(local k = 0; k < 3; k = k + 1){
        rows(s, p, 2, k, "..n..=.....n.=.. ..m..=.....m.=..", {
          n: chord[0][k], m: chord[1][k], soft: 75
        })
      }
      lane(s, p, 2, 0, 31, 55, 75)
    }
    if(with_pluck){
      rows(s, p, 3, 0, "........e.g.a... ......c.e.d.....", {
        a: 81, c: 72, d: 74, e: 76, g: 79, soft: 65
      })
    }
  }
  append(s.patterns, song.pattern(s, 32))
  bar(0, false, false, 18)
  append(s.patterns, song.pattern(s, 32))
  bar(1, true, false, 30)
  append(s.patterns, song.pattern(s, 32))
  bar(2, true, true, 42)
  // a break: the line alone, its filter closing
  append(s.patterns, song.pattern(s, 32))
  rows(s, 3, 1, 0, "A.a.h.a.c.a.H.g. A.a.h.a.d.a.E.c.", line)
  lane(s, 3, 1, 0, 31, 70, 12)
  rows(s, 3, 0, 1, "................ ............c.cc", KIT)
  rows(s, 3, 3, 0, "e.......g....... a...............", {
    a: 81, e: 76, g: 79, soft: 60
  })
  s.order = {0, 1, 2, 2, 3, 2}
  return s
}

for(let local make in values({dusk, relay})){
  local s = make()
  s.undo = {}
  s.redo = {}
  local file = concat("songs/", s.name, ".json")
  song.save(s, file)
  print(file, ": ", len(s.tracks), " tracks, ", len(s.patterns), " patterns\n")
}
