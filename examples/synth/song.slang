// Songs for the synth: a song file (slang, returning a table) names its
// notes (a MIDI file, or notes written in it), the sound to start with and
// how the controls move while it plays. load turns it into what the engine
// plays: events and control curves in seconds.
//
//   // songs/example.slang
//   return {
//     title: "Example",
//     composer: "Someone",
//     midi: "example.mid",          // next to the song file
//     tracks: {1},                  // which tracks (all by default)
//     voice: "top",                 // "top": the highest note sounding;
//                                   // "bottom": the lowest; a number k:
//                                   // the k-th from the top (0 is
//                                   // "top"); "all" (default): every
//                                   // note, the synth keeps the last one
//     legato: false,                // top voice: glide into a new note
//                                   // without restarting the contours
//     transpose: 12,                // semitones
//     fold: {48, 84},               // notes outside move by octaves into
//                                   // this range
//     speed: 1.0,                   // 1.25: a quarter faster
//     patch: {cutoff: 0.4, wave1: "SQR", on3: 1},
//     automation: {                 // per control: {beat, value} points;
//       cutoff: {{0, 0.3}, {32, 0.7}},  // knobs move in straight lines
//       wave2: {{0, "SAW"}, {64, "SQR"}},  // switches step
//     },
//   }
//
// A song of several instruments has parts: each part is a table of the
// fields above (tracks, voice, transpose, patch, automation, ...) that
// override the song's own, plus name, gain (1 by default) and pan (-1 left
// to 1 right, 0 by default); mixdown.slang records every part and mixes
// them, the synth on screen plays the part named by live (the first by
// default). mix: {reverb: 0.2, room: 0.8} sets the mix's reverb.
//
//   parts: {
//     {name: "melody", tracks: {1}, voice: "top", pan: -0.3, patch: {...}},
//     {name: "bass", tracks: {2}, voice: "bottom", pan: 0.3, gain: 0.8},
//   },
//
// Without a MIDI file, notes: {{beat, length, note}, ...} and bpm (120 by
// default) give the notes. Beats are quarter notes from the start, read
// by the MIDI file's tempo map; values are those of the controls (knobs 0
// to 1, switches 0 or 1, rotary switches an index or one of their labels).
local compiler = require("slang/compiler")
local path = require("slang/path")
local tbl = require("slang/table")
local midi = require("midi")
local params = require("params")

local song = {}

// a control's value from a song file: a number, or a rotary switch's label
local func value_of(file, c, v){
  if(type(v) == "string"){
    if(c.labels != null){
      for(local i = 0; i < len(c.labels); i = i + 1){
        if(c.labels[i] == v){
          return i * 1.0
        }
      }
    }
    error(concat(file, ": ", c.id, " has no position called ", v))
  }
  return v * 1.0
}

local func control(file, id){
  local i = params.index[id]
  if(i == null){
    error(concat(file, ": there is no control called ", id))
  }
  return i
}

// the notes to play: {tick, length, note} from the MIDI file's tracks
local func midi_notes(def, m){
  local out = {}
  for(local t = 0; t < len(m.tracks); t = t + 1){
    if(def.tracks == null or tbl.contains(def.tracks, t)){
      for(let local n in values(m.tracks[t].notes)){
        append(out, {tick: n.tick, length: n.length, note: n.note})
      }
    }
  }
  return out
}

// the on and off events of notes as the synth gets them: {t, note, on}
// sorted by time, offs before ons at one time; with a voice other than
// "all" a single line: the note of that rank among those sounding (struck
// again when it is played again)
local func events_of(def, notes, seconds){
  local transpose = def.transpose or 0
  // a note as the synth plays it: folded into the range by octaves
  local func fold(n){
    if(def.fold != null){
      for(n > def.fold[1]){
        n = n - 12
      }
      for(n < def.fold[0]){
        n = n + 12
      }
    }
    return n
  }
  local changes = {}
  for(let local n in values(notes)){
    append(changes, {tick: n.tick, note: n.note + transpose, on: true})
    append(changes, {tick: n.tick + n.length, note: n.note + transpose, on: false})
  }
  tbl.sort(changes, func(a, b){
    if(a.tick != b.tick){
      return a.tick < b.tick
    }
    return not a.on and b.on
  })
  local out = {}
  local voice = def.voice or "all"
  if(voice == "all"){
    for(let local c in values(changes)){
      append(out, {t: seconds(c.tick), note: fold(c.note), on: c.on})
    }
    return out
  }
  local sounding = {}
  local current = null
  local i = 0
  for(i < len(changes)){
    local tick = changes[i].tick
    local struck = {}
    for(i < len(changes) and changes[i].tick == tick){
      local c = changes[i]
      local held = sounding[c.note] or 0
      if(c.on){
        sounding[c.note] = held + 1
        struck[c.note] = true
      } else if(held > 0){
        sounding[c.note] = held - 1
      }
      i = i + 1
    }
    // the notes sounding, highest first, and the one this voice plays
    local playing = {}
    for(let local e in entries(sounding)){
      if(e[1] > 0){
        append(playing, e[0])
      }
    }
    tbl.sort(playing, func(a, b){ return a > b })
    local top = null
    if(voice == "top"){
      top = playing[0]
    } else if(voice == "bottom"){
      top = playing[len(playing) - 1]
    } else {
      top = playing[voice]
    }
    if(top != current or (top != null and struck[top])){
      local t = seconds(tick)
      if(def.legato and top != null){
        append(out, {t: t, note: fold(top), on: true})
        if(current != null){
          append(out, {t: t, note: fold(current), on: false})
        }
      } else {
        if(current != null){
          append(out, {t: t, note: fold(current), on: false})
        }
        if(top != null){
          append(out, {t: t, note: fold(top), on: true})
        }
      }
      current = top
    }
  }
  return out
}

// the song file's definition for one part: the part's fields over the
// song's
local func part_def(file, def, part){
  if(def.parts == null){
    return def
  }
  local k = part
  if(k == null){
    k = 0
    if(def.live != null){
      k = def.live
    }
  }
  if(type(k) == "string"){
    local found = null
    for(local i = 0; i < len(def.parts); i = i + 1){
      if(def.parts[i].name == k){
        found = i
      }
    }
    if(found == null){
      error(concat(file, ": there is no part called ", k))
    }
    k = found
  }
  local out = {}
  for(let local e in entries(def)){
    out[e[0]] = e[1]
  }
  for(let local e in entries(def.parts[k])){
    out[e[0]] = e[1]
  }
  out.parts = null
  return out
}

// parts(file: string) -> {title, composer, mix, parts: {{name, gain, pan}}}
// The parts of a song file (one, named after the song, when it has none).
func song.parts(file){
  local def = compiler.load_file(file)()
  local parts = {}
  if(def.parts == null){
    append(parts, {name: "synth", gain: 1.0, pan: 0.0})
  } else {
    for(let local p in values(def.parts)){
      append(parts, {name: p.name or concat("part", len(parts)), gain: p.gain or 1.0, pan: p.pan or 0.0})
    }
  }
  return {
    title: def.title or path.base(file),
    composer: def.composer or "",
    mix: def.mix or {},
    parts: parts,
  }
}

// load(file: string, part?: int | string) -> {title, composer, length,
//   events, patch, curves}
// One part of a song (by index or name; the live one by default).
// [events]: {{t, note, on}} in seconds
// [patch]: {{index, value}}: the controls at the start (defaults where the
//   song file says nothing)
// [curves]: {{index, step, points: {{t, value}}}}: step for switches
func song.load(file, part){
  local def = part_def(file, compiler.load_file(file)(), part)
  local dir = path.dir(file)
  local speed = def.speed or 1.0
  local m = null
  local notes = null
  if(def.midi != null){
    m = midi.read(path.join(dir, def.midi))
    notes = midi_notes(def, m)
  } else {
    // notes in beats: a tempo map of one tempo, a tick a beat
    m = {ppq: 1, tempos: {{0, 60.0 / (def.bpm or 120)}}}
    notes = {}
    for(let local n in values(def.notes or {})){
      append(notes, {tick: n[0], length: n[1], note: n[2]})
    }
  }
  local func seconds(tick){
    return midi.seconds(m, tick) / speed
  }
  local events = events_of(def, notes, seconds)
  local patch = {}
  for(local i = 0; i < params.count; i = i + 1){
    local c = params.list[i]
    local v = c.default
    if(def.patch != null and def.patch[c.id] != null){
      v = value_of(file, c, def.patch[c.id])
    }
    append(patch, {i, v})
  }
  local curves = {}
  for(let local e in entries(def.automation or {})){
    local i = control(file, e[0])
    local c = params.list[i]
    local points = {}
    for(let local p in values(e[1])){
      append(points, {seconds(p[0] * m.ppq), value_of(file, c, p[1])})
    }
    tbl.sort(points, func(a, b){ return a[0] < b[0] })
    append(curves, {index: i, step: c.kind != "knob" and c.kind != "wheel", points: points})
  }
  local length = 0.0
  if(len(events) > 0){
    length = events[len(events) - 1].t
  }
  return {
    file: file,
    title: def.title or path.base(file),
    composer: def.composer or "",
    length: length,
    events: events,
    patch: patch,
    curves: curves,
  }
}

return song
