// A song: tracks (an instrument each, with its effects), buses, the
// master, patterns of rows, and the order the patterns play in. Plain
// data, as it is saved; the functions here read and change it, with an
// undo for what is typed into patterns.
//
//   local song = require("song")
//   local s = song.new()                         // four tracks, one pattern
//   song.put(s, 0, 2, "note", 0, 4, 60)          // pattern 0, track 2,
//                                                // column 0, row 4: C-4
//   song.undo(s)
//   song.save(s, "songs/mine.json"); s = song.load("songs/mine.json")
//
// A pattern holds, per track: notes in up to four columns (a note number,
// or song.OFF where the column's note ends), a velocity beside each note
// (0 to 99; none is 80) and one lane of values (0 to 99) for the
// parameter the track's `lane` names: 0 is the bottom of that parameter's
// slider, 99 its top.
local json = require("slang/json")
local os = require("slang/os")

local song = {}

song.OFF = -1 // in a note column: the note before ends here
song.COLUMNS = 4 // note columns a track has at most
song.TRACKS = 16 // tracks at most
song.VELOCITY = 80 // a note without a velocity

local NAMES = {
  "C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"
}

// note_name(n: int?) -> "C-4", "===" for OFF, "..." for none
func song.note_name(n){
  if(n == null){
    return "..."
  }
  if(n == song.OFF){
    return "==="
  }
  return concat(NAMES[n % 12], string(to_int(n / 12) - 1))
}

// what the notes of a drums track play (the drums unit's notes, which
// are General MIDI's), as a pattern shows them: the bass drum (a heavy
// one), the rim, the snare (a deep one), the clap, the closed hat (a
// short and a long one), the open hat (a long one), six toms, the cowbell
song.DRUMS = {
  [35]: "BD+",
  [36]: "BD ",
  [37]: "RIM",
  [38]: "SD ",
  [39]: "CLP",
  [40]: "SD-",
  [41]: "TM1",
  [42]: "HH ",
  [43]: "TM2",
  [44]: "HH-",
  [45]: "TM3",
  [46]: "OH ",
  [47]: "TM4",
  [48]: "TM5",
  [49]: "OH+",
  [50]: "TM6",
  [51]: "HH+",
  [56]: "COW",
}
song.DRUM_BASE = 35 // the lowest of them

// drum_name(n: int) -> the drum of a note, or null when it plays none
func song.drum_name(n){
  return song.DRUMS[n]
}

// two(v: int?) -> a value 0..99 as two digits, ".." for none
func song.two(v){
  if(v == null){
    return ".."
  }
  if(v < 10){
    return concat("0", string(v))
  }
  return string(v)
}

// ------------------------------------------------------------ making one

// unit(name, patch?, params?) -> an instrument's or effect's entry
func song.unit(name, patch, params){
  return {unit: name, patch: patch, params: params or {}}
}

// track(name, unit, patch?, params?) -> a track's entry
func song.track(name, unit, patch, params){
  return {
    name: name,
    unit: unit,
    patch: patch,
    params: params or {},
    columns: 1,
    lane: null,
    gain: 1.0,
    pan: 0.0,
    mute: false,
    sends: {},
    inserts: {},
  }
}

local func track_data(){
  local d = {notes: {}, vels: {}, fx: {}}
  for(local c = 0; c < song.COLUMNS; c = c + 1){
    d.notes[c] = {}
    d.vels[c] = {}
  }
  return d
}

// pattern(s, rows) -> an empty pattern for the song's tracks
func song.pattern(s, rows){
  local p = {rows: rows, data: {}}
  for(local t = 0; t < len(s.tracks); t = t + 1){
    p.data[t] = track_data()
  }
  return p
}

// new() -> a song to start from: drums, a bass, keys and a lead, an echo
// and a hall to send to, a limiter on the master, one empty pattern
func song.new(){
  local s = {
    name: "untitled",
    bpm: 120,
    lpb: 4,
    swing: 0.0,
    tracks: {},
    buses: {
      {
        name: "echo", gain: 1.0, pan: 0.0, mute: false, inserts: {
          song.unit("delay", null, {
            time: 375, feedback: 0.45, cross: 1, mix: 1
          }),
        }
      },
      {
        name: "hall", gain: 1.0, pan: 0.0, mute: false, inserts: {
          song.unit("hall", null, {decay: 2400, mix: 1}),
        }
      },
    },
    master: {
      name: "master", gain: 0.8, pan: 0.0, mute: false, inserts: {
        song.unit("limiter", null, {ceiling: -1}),
      }
    },
    patterns: {},
    order: {0},
    undo: {},
    redo: {},
  }
  append(s.tracks, song.track("drums", "drums", null, {kit: 1}))
  append(s.tracks, song.track("bass", "mini", "Fat Bass"))
  append(s.tracks, song.track("keys", "six", "TINE PIANO"))
  append(s.tracks, song.track("lead", "poly", "Lead"))
  s.tracks[2].columns = 3
  s.tracks[1].lane = "cutoff"
  s.tracks[3].lane = "cutoff"
  append(s.patterns, song.pattern(s, 32))
  return s
}

// ------------------------------------------------------------ patterns

// get(s, p, t, kind, col, row) -> what is there: kind "note", "vel" or
// "fx" (col is the note column, ignored for "fx")
func song.get(s, p, t, kind, col, row){
  local d = s.patterns[p].data[t]
  if(kind == "note"){
    return d.notes[col][row]
  }
  if(kind == "vel"){
    return d.vels[col][row]
  }
  return d.fx[row]
}

local func store(s, p, t, kind, col, row, value){
  local d = s.patterns[p].data[t]
  local where = d.fx
  if(kind == "note"){
    where = d.notes[col]
  } else if(kind == "vel"){
    where = d.vels[col]
  }
  if(value == null){
    delete(where, row)
  } else {
    where[row] = value
  }
}

// put(s, p, t, kind, col, row, value): a note, velocity or lane value
// written (null: removed), remembered for undo. What is put between
// begin() and the next begin() is undone together.
func song.put(s, p, t, kind, col, row, value){
  local before = song.get(s, p, t, kind, col, row)
  if(before == value){
    return null
  }
  if(len(s.undo) == 0 or s.undo[len(s.undo) - 1].closed){
    append(s.undo, {closed: false, edits: {}})
  }
  append(s.undo[len(s.undo) - 1].edits, {
    p: p,
    t: t,
    kind: kind,
    col: col,
    row: row,
    before: before,
    after: value,
  })
  s.redo = {}
  store(s, p, t, kind, col, row, value)
  s.dirty = true
}

// begin(s): what is put from here on is one step of undo
func song.begin(s){
  if(len(s.undo) > 0){
    s.undo[len(s.undo) - 1].closed = true
  }
  if(len(s.undo) > 200){
    remove(s.undo, 0)
  }
}

// undo(s) -> bool: the last step taken back (false: there is none)
func song.undo(s){
  if(len(s.undo) == 0){
    return false
  }
  local step = s.undo[len(s.undo) - 1]
  remove(s.undo, len(s.undo) - 1)
  for(local i = len(step.edits) - 1; i >= 0; i = i - 1){
    local e = step.edits[i]
    if(s.patterns[e.p] != null and s.patterns[e.p].data[e.t] != null){
      store(s, e.p, e.t, e.kind, e.col, e.row, e.before)
    }
  }
  step.closed = true
  append(s.redo, step)
  s.dirty = true
  return true
}

// redo(s) -> bool: the step last undone, done again
func song.redo(s){
  if(len(s.redo) == 0){
    return false
  }
  local step = s.redo[len(s.redo) - 1]
  remove(s.redo, len(s.redo) - 1)
  for(let local e in values(step.edits)){
    if(s.patterns[e.p] != null and s.patterns[e.p].data[e.t] != null){
      store(s, e.p, e.t, e.kind, e.col, e.row, e.after)
    }
  }
  append(s.undo, step)
  s.dirty = true
  return true
}

// add_pattern(s, rows, after?) -> its index: an empty pattern, put into
// the order after position `after` when given
func song.add_pattern(s, rows, after){
  append(s.patterns, song.pattern(s, rows))
  local index = len(s.patterns) - 1
  if(after != null){
    local k = len(s.order)
    for(k > after + 1){
      s.order[k] = s.order[k - 1]
      k = k - 1
    }
    s.order[after + 1] = index
  }
  s.dirty = true
  return index
}

local func copy_rows(t){
  local out = {}
  for(let local e in entries(t)){
    out[e[0]] = e[1]
  }
  return out
}

// duplicate_pattern(s, p, after?) -> the index of a copy of pattern p
func song.duplicate_pattern(s, p, after){
  local index = song.add_pattern(s, s.patterns[p].rows, after)
  local from = s.patterns[p]
  local to = s.patterns[index]
  for(local t = 0; t < len(s.tracks); t = t + 1){
    for(local c = 0; c < song.COLUMNS; c = c + 1){
      to.data[t].notes[c] = copy_rows(from.data[t].notes[c])
      to.data[t].vels[c] = copy_rows(from.data[t].vels[c])
    }
    to.data[t].fx = copy_rows(from.data[t].fx)
  }
  return index
}

// set_rows(s, p, rows): the pattern's length (what lies beyond stays, and
// is back when it grows again)
func song.set_rows(s, p, rows){
  s.patterns[p].rows = rows
  s.dirty = true
}

// ------------------------------------------------------------ tracks

// add_track(s, track) -> its index, or null when the song is full
func song.add_track(s, track){
  if(len(s.tracks) >= song.TRACKS){
    return null
  }
  append(s.tracks, track)
  for(let local p in values(s.patterns)){
    append(p.data, track_data())
  }
  s.undo = {}
  s.redo = {}
  s.dirty = true
  return len(s.tracks) - 1
}

// remove_track(s, t): the track and what every pattern holds for it
func song.remove_track(s, t){
  remove(s.tracks, t)
  for(let local p in values(s.patterns)){
    remove(p.data, t)
  }
  s.undo = {}
  s.redo = {}
  s.dirty = true
}

// ------------------------------------------------------------ files

local func unit_table(u){
  return {
    unit: u.unit, patch: u.patch, params: u.params, sidechain: u.sidechain
  }
}

local func strip_table(st){
  local out = {
    name: st.name, gain: st.gain, pan: st.pan, mute: st.mute, inserts: {}
  }
  for(let local u in values(st.inserts)){
    append(out.inserts, unit_table(u))
  }
  return out
}

// to_table(s) -> the song as JSON takes it
func song.to_table(s){
  local out = {
    name: s.name,
    bpm: s.bpm,
    lpb: s.lpb,
    swing: s.swing,
    tracks: {},
    buses: {},
    master: strip_table(s.master),
    patterns: {},
    order: s.order,
  }
  for(let local t in values(s.tracks)){
    local e = strip_table(t)
    e.unit = t.unit
    e.patch = t.patch
    e.params = t.params
    e.columns = t.columns
    e.lane = t.lane
    e.sends = t.sends
    e.sample = t.sample
    append(out.tracks, e)
  }
  for(let local b in values(s.buses)){
    append(out.buses, strip_table(b))
  }
  for(let local p in values(s.patterns)){
    local pe = {rows: p.rows, tracks: {}}
    for(local t = 0; t < len(s.tracks); t = t + 1){
      local d = p.data[t]
      local te = {notes: {}, fx: {}}
      for(local c = 0; c < song.COLUMNS; c = c + 1){
        for(local row = 0; row < 256; row = row + 1){
          local n = d.notes[c][row]
          local v = d.vels[c][row]
          if(n != null or v != null){
            // (a list may not end in null: no velocity is -1)
            append(te.notes, {
              row,
              c,
              if(n == null){ -2 } else { n },
              if(v == null){ -1 } else { v },
            })
          }
        }
      }
      for(local row = 0; row < 256; row = row + 1){
        if(d.fx[row] != null){
          append(te.fx, {row, d.fx[row]})
        }
      }
      append(pe.tracks, te)
    }
    append(out.patterns, pe)
  }
  return out
}

local func read_unit(u){
  local e = song.unit(u.unit, u.patch, u.params or {})
  e.sidechain = u.sidechain
  return e
}

local func read_strip(st, into){
  into.name = st.name
  into.gain = st.gain or 1.0
  into.pan = st.pan or 0.0
  into.mute = st.mute == true
  into.inserts = {}
  for(let local u in values(st.inserts or {})){
    append(into.inserts, read_unit(u))
  }
  return into
}

// from_table(t) -> the song a table of to_table's shape describes
func song.from_table(t){
  local s = {
    name: t.name or "untitled",
    bpm: t.bpm or 120,
    lpb: t.lpb or 4,
    swing: t.swing or 0.0,
    tracks: {},
    buses: {},
    master: read_strip(t.master or {name: "master"}, {}),
    patterns: {},
    order: {},
    undo: {},
    redo: {},
  }
  for(let local e in values(t.tracks or {})){
    local tr = song.track(e.name, e.unit, e.patch, e.params or {})
    read_strip(e, tr)
    tr.columns = e.columns or 1
    tr.lane = e.lane
    tr.sends = e.sends or {}
    tr.sample = e.sample
    append(s.tracks, tr)
  }
  for(let local b in values(t.buses or {})){
    append(s.buses, read_strip(b, {}))
  }
  for(let local pe in values(t.patterns or {})){
    local p = song.pattern(s, pe.rows or 32)
    for(local k = 0; k < len(s.tracks); k = k + 1){
      local te = (pe.tracks or {})[k]
      if(te == null){
        continue
      }
      for(let local n in values(te.notes or {})){
        if(n[2] != -2){
          p.data[k].notes[n[1]][n[0]] = n[2]
        }
        if(n[3] != null and n[3] >= 0){
          p.data[k].vels[n[1]][n[0]] = n[3]
        }
      }
      for(let local f in values(te.fx or {})){
        p.data[k].fx[f[0]] = f[1]
      }
    }
    append(s.patterns, p)
  }
  if(len(s.patterns) == 0){
    append(s.patterns, song.pattern(s, 32))
  }
  for(let local o in values(t.order or {0})){
    if(s.patterns[o] != null){
      append(s.order, o)
    }
  }
  if(len(s.order) == 0){
    s.order = {0}
  }
  return s
}

// save(s, path)
func song.save(s, path){
  os.write_file(path, json.encode(song.to_table(s), {indent: " "}))
  s.dirty = false
}

// load(path) -> the song
func song.load(path){
  local s = song.from_table(json.decode(os.read_file(path), path))
  s.dirty = false
  return s
}

return song
