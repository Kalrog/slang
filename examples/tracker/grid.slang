// The pattern as a grid: a row per line, per track its note columns (a
// note and a velocity each) and its lane. The cursor, the selection and
// what the keys do to the cells. (view.slang draws it.)
//
// The app's state `A` (main.slang makes it) holds the song, the player,
// the pattern shown (A.order_pos), the cursor {t, f, row} (track, field of
// the track, row), the selection's other corner (A.anchor), the octave
// and the step the cursor moves after a note.
local math = require("slang/math")
local song = require("song")

local grid = {}

// ------------------------------------------------------------ fields

// fields_of(track) -> the fields of a track from left to right: {kind,
// col, x, w}: kind "note", "vel" or "fx"; x and w in characters
func grid.fields_of(track){
  local out = {}
  local x = 0
  for(local c = 0; c < track.columns; c = c + 1){
    append(out, {kind: "note", col: c, x: x, w: 3})
    append(out, {kind: "vel", col: c, x: x + 3, w: 2})
    x = x + 6
  }
  append(out, {kind: "fx", col: 0, x: x, w: 2})
  return out
}

// width_of(track) -> its width in characters, with the gap after it
func grid.width_of(track){
  return track.columns * 6 + 3
}

// every field of the song in a row: {t, kind, col}, for the selection
local func all_fields(s){
  local out = {}
  for(local t = 0; t < len(s.tracks); t = t + 1){
    local fs = grid.fields_of(s.tracks[t])
    for(local f = 0; f < len(fs); f = f + 1){
      append(out, {t: t, f: f, kind: fs[f].kind, col: fs[f].col})
    }
  }
  return out
}

local func index_of(fields, t, f){
  for(local i = 0; i < len(fields); i = i + 1){
    if(fields[i].t == t and fields[i].f == f){
      return i
    }
  }
  return 0
}

// pattern(A) -> the index of the pattern shown
func grid.pattern(A){
  return A.song.order[A.order_pos]
}

// field(A) -> the field the cursor is in
func grid.field(A){
  return grid.fields_of(A.song.tracks[A.cursor.t])[A.cursor.f]
}

// the cursor kept inside the song as it is now
func grid.clamp(A){
  local s = A.song
  A.order_pos = math.clamp(A.order_pos, 0, len(s.order) - 1)
  local c = A.cursor
  c.t = math.clamp(c.t, 0, len(s.tracks) - 1)
  c.f = math.clamp(c.f, 0, len(grid.fields_of(s.tracks[c.t])) - 1)
  c.row = math.clamp(c.row, 0, s.patterns[grid.pattern(A)].rows - 1)
}

// range(A) -> {f0, f1, r0, r1, fields}: the selection (or the cursor's
// cell alone) as indices into every field of the song, and rows
func grid.range(A){
  local fields = all_fields(A.song)
  local at = index_of(fields, A.cursor.t, A.cursor.f)
  local r = {f0: at, f1: at, r0: A.cursor.row, r1: A.cursor.row, fields: fields}
  if(A.anchor != null){
    local other = index_of(fields, A.anchor.t, A.anchor.f)
    r.f0 = math.min(at, other)
    r.f1 = math.max(at, other)
    r.r0 = math.min(A.cursor.row, A.anchor.row)
    r.r1 = math.max(A.cursor.row, A.anchor.row)
  }
  return r
}

// ------------------------------------------------------------ moving

// move(A, dx, dy, select): the cursor by fields and rows; with select the
// selection grows from where it was
func grid.move(A, dx, dy, select){
  local s = A.song
  local c = A.cursor
  A.typing = null
  if(select){
    if(A.anchor == null){
      A.anchor = {t: c.t, f: c.f, row: c.row}
    }
  } else {
    A.anchor = null
  }
  local rows = s.patterns[grid.pattern(A)].rows
  if(dy != 0){
    c.row = c.row + dy
    if(select){
      c.row = math.clamp(c.row, 0, rows - 1)
    } else {
      // round the pattern's ends
      c.row = ((c.row % rows) + rows) % rows
    }
  }
  for(dx > 0){
    c.f = c.f + 1
    if(c.f >= len(grid.fields_of(s.tracks[c.t]))){
      if(c.t + 1 < len(s.tracks)){
        c.t = c.t + 1
        c.f = 0
      } else {
        c.f = c.f - 1
      }
    }
    dx = dx - 1
  }
  for(dx < 0){
    c.f = c.f - 1
    if(c.f < 0){
      if(c.t > 0){
        c.t = c.t - 1
        c.f = len(grid.fields_of(s.tracks[c.t])) - 1
      } else {
        c.f = 0
      }
    }
    dx = dx + 1
  }
}

// track(A, d): the cursor to the first field of the track d further on
func grid.track(A, d){
  local n = len(A.song.tracks)
  A.cursor.t = ((A.cursor.t + d) % n + n) % n
  A.cursor.f = 0
  A.anchor = null
  A.typing = null
}

// select_all(A): the cursor's track, all rows; again, the whole pattern
func grid.select_all(A){
  local s = A.song
  local rows = s.patterns[grid.pattern(A)].rows
  local last = len(grid.fields_of(s.tracks[A.cursor.t])) - 1
  local whole = A.anchor != null and A.anchor.t == A.cursor.t and
    A.anchor.f == 0 and A.anchor.row == 0 and A.cursor.f == last and
    A.cursor.row == rows - 1
  if(whole){
    A.anchor = {t: 0, f: 0, row: 0}
    A.cursor.t = len(s.tracks) - 1
    A.cursor.f = len(grid.fields_of(s.tracks[A.cursor.t])) - 1
  } else {
    A.anchor = {t: A.cursor.t, f: 0, row: 0}
    A.cursor.f = last
  }
  A.cursor.row = rows - 1
}

// ------------------------------------------------------------ editing

// note(A, n): a note (or song.OFF) at the cursor, which then moves on by
// the step. False when the cursor is in no note field.
func grid.note(A, n){
  local f = grid.field(A)
  if(f.kind != "note"){
    return false
  }
  local p = grid.pattern(A)
  song.begin(A.song)
  song.put(A.song, p, A.cursor.t, "note", f.col, A.cursor.row, n)
  if(n == song.OFF){
    song.put(A.song, p, A.cursor.t, "vel", f.col, A.cursor.row, null)
  }
  A.anchor = null
  grid.move(A, 0, A.step, false)
  return true
}

// digit(A, d): a digit typed into a velocity or a lane: the value's
// digits move left and d comes in at the right ("4" then "5" is 45)
func grid.digit(A, d){
  local f = grid.field(A)
  if(f.kind == "note"){
    return false
  }
  local p = grid.pattern(A)
  local c = A.cursor
  // a new value starts when the cursor has moved since the last digit
  local fresh = A.typing == null or A.typing.t != c.t or A.typing.f != c.f or
    A.typing.row != c.row
  local old = 0
  if(not fresh){
    old = song.get(A.song, p, c.t, f.kind, f.col, c.row) or 0
  }
  if(fresh){
    song.begin(A.song)
  }
  song.put(A.song, p, c.t, f.kind, f.col, c.row, (old % 10) * 10 + d)
  A.typing = {t: c.t, f: c.f, row: c.row}
  return true
}

// clear(A): the selection (or the cursor's cell) emptied; a note takes
// its velocity with it
func grid.clear(A){
  local r = grid.range(A)
  local p = grid.pattern(A)
  song.begin(A.song)
  for(local i = r.f0; i <= r.f1; i = i + 1){
    local f = r.fields[i]
    for(local row = r.r0; row <= r.r1; row = row + 1){
      song.put(A.song, p, f.t, f.kind, f.col, row, null)
      if(f.kind == "note"){
        song.put(A.song, p, f.t, "vel", f.col, row, null)
      }
    }
  }
}

// copy(A) -> the selection as the clipboard keeps it
func grid.copy(A){
  local r = grid.range(A)
  local p = grid.pattern(A)
  local clip = {rows: r.r1 - r.r0 + 1, fields: {}}
  for(local i = r.f0; i <= r.f1; i = i + 1){
    local f = r.fields[i]
    local cells = {}
    for(local row = r.r0; row <= r.r1; row = row + 1){
      local v = song.get(A.song, p, f.t, f.kind, f.col, row)
      if(v != null){
        cells[row - r.r0] = v
      }
    }
    append(clip.fields, {kind: f.kind, cells: cells})
  }
  A.clip = clip
  return clip
}

// paste(A): the clipboard at the cursor: its fields onto the fields from
// the cursor's on, where their kinds agree
func grid.paste(A){
  local clip = A.clip
  if(clip == null){
    return false
  }
  local fields = all_fields(A.song)
  local at = index_of(fields, A.cursor.t, A.cursor.f)
  local p = grid.pattern(A)
  local rows = A.song.patterns[p].rows
  song.begin(A.song)
  for(local i = 0; i < len(clip.fields); i = i + 1){
    local f = fields[at + i]
    if(f == null or f.kind != clip.fields[i].kind){
      continue
    }
    for(local k = 0; k < clip.rows; k = k + 1){
      local row = A.cursor.row + k
      if(row < rows){
        song.put(A.song, p, f.t, f.kind, f.col, row, clip.fields[i].cells[k])
      }
    }
  }
  A.anchor = null
  return true
}

// transpose(A, d): the notes of the selection d semitones up
func grid.transpose(A, d){
  local r = grid.range(A)
  local p = grid.pattern(A)
  song.begin(A.song)
  for(local i = r.f0; i <= r.f1; i = i + 1){
    local f = r.fields[i]
    if(f.kind != "note"){
      continue
    }
    for(local row = r.r0; row <= r.r1; row = row + 1){
      local n = song.get(A.song, p, f.t, "note", f.col, row)
      if(n != null and n >= 0){
        song.put(A.song, p, f.t, "note", f.col, row, math.clamp(n + d, 0, 127))
      }
    }
  }
}

// interpolate(A): in the velocities and lanes of the selection, the rows
// between the first and the last filled in, sliding from one to the other
func grid.interpolate(A){
  local r = grid.range(A)
  local p = grid.pattern(A)
  if(r.r1 <= r.r0){
    return false
  }
  song.begin(A.song)
  for(local i = r.f0; i <= r.f1; i = i + 1){
    local f = r.fields[i]
    if(f.kind == "note"){
      continue
    }
    local a = song.get(A.song, p, f.t, f.kind, f.col, r.r0)
    local b = song.get(A.song, p, f.t, f.kind, f.col, r.r1)
    if(a == null or b == null){
      continue
    }
    for(local row = r.r0 + 1; row < r.r1; row = row + 1){
      local k = (row - r.r0) / (r.r1 - r.r0)
      song.put(
        A.song, p, f.t, f.kind, f.col, row, to_int(a + (b - a) * k + 0.5)
      )
    }
  }
  return true
}

return grid
