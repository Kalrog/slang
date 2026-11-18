local t = require("slang/test")
local math = require("slang/math")
local os = require("slang/os")
local path = require("slang/path")
local song = require("song")
local player = require("player")

// The tracker without a window or a sound card: the song as data, its
// undo and its file, and the player: rows at their sample, columns,
// lanes, the order, and the songs that come with it.

local here = __PACKAGES.search_paths[0]

local func peak_of(buf, from, to){
  local peak = 0.0
  for(local i = from or 0; i < (to or len(buf)); i = i + 1){
    peak = math.max(peak, math.abs(buf[i]))
  }
  return peak
}

local func onset(buf, from, level){
  for(local i = from; i < len(buf); i = i + 1){
    if(math.abs(buf[i]) > level){
      return i
    }
  }
  return -1
}

// a song of one track with a plain tone, 120 bpm: a row is 6000 samples
local func plain(){
  local s = song.new()
  s.tracks = {}
  s.buses = {}
  s.master.inserts = {}
  s.master.gain = 1.0
  s.patterns = {}
  local tr = song.track("tone", "poly", null, {
    wave: 1, attack: 0.5, release: 2, cutoff: 1, sustain: 1
  })
  song.add_track(s, tr)
  append(s.patterns, song.pattern(s, 8))
  s.order = {0}
  return s
}

t.group("song", func(){
  t.test("names, cells, undo and redo", func(){
    assert(song.note_name(60) == "C-4" and song.note_name(61) == "C#4")
    assert(song.note_name(song.OFF) == "===" and song.note_name(null) == "...")
    assert(song.two(7) == "07" and song.two(null) == "..")
    assert(
      song.drum_name(36) == "BD " and song.drum_name(42) == "HH " and
        song.drum_name(60) == null,
    )
    // every drum the tracker names is one the drums unit plays, and the other way
    local played = require("studio/units/drums").notes
    for(local n = 0; n < 128; n = n + 1){
      assert(
        (song.DRUMS[n] != null) == (played[n] != null),
        concat("note ", string(n)),
      )
    }
    local s = song.new()
    assert(len(s.tracks) == 4 and len(
        s.patterns,
      ) == 1 and s.patterns[0].rows == 32)
    song.begin(s)
    song.put(s, 0, 1, "note", 0, 4, 36)
    song.put(s, 0, 1, "vel", 0, 4, 99)
    song.begin(s)
    song.put(s, 0, 1, "fx", 0, 4, 50)
    assert(song.get(s, 0, 1, "note", 0, 4) == 36 and song.get(
        s, 0, 1, "fx", 0, 4
      ) == 50)
    assert(song.undo(s))
    assert(song.get(s, 0, 1, "fx", 0, 4) == null and song.get(
        s, 0, 1, "note", 0, 4
      ) == 36)
    assert(song.undo(s))
    assert(song.get(s, 0, 1, "note", 0, 4) == null and song.get(
        s, 0, 1, "vel", 0, 4
      ) == null)
    assert(not song.undo(s))
    assert(song.redo(s) and song.get(s, 0, 1, "vel", 0, 4) == 99)
    song.begin(s)
    song.put(s, 0, 1, "note", 0, 4, null)
    assert(song.get(s, 0, 1, "note", 0, 4) == null)
    assert(not song.redo(s), "a new edit forgets what was undone")
  })
  t.test("patterns, tracks and the file", func(){
    local s = song.new()
    song.put(s, 0, 2, "note", 1, 8, 64)
    song.put(s, 0, 2, "note", 1, 12, song.OFF)
    song.put(s, 0, 2, "vel", 1, 8, 0)
    song.put(s, 0, 1, "fx", 0, 3, 0)
    local copy = song.duplicate_pattern(s, 0, 0)
    assert(copy == 1 and s.order[0] == 0 and s.order[1] == 1)
    song.put(s, 1, 2, "note", 1, 8, 67)
    assert(song.get(s, 0, 2, "note", 1, 8) == 64, "a copy is its own")
    local added = song.add_track(s, song.track("bell", "bell"))
    assert(added == 4 and s.patterns[1].data[4] != null)
    song.remove_track(s, 0)
    assert(len(s.tracks) == 4 and song.get(s, 0, 1, "note", 1, 8) == 64)
    local file = path.join(
      os.getenv("TMPDIR") or "/tmp",
      "tracker_song_test.json",
    )
    s.name = "a test"
    s.bpm = 97
    s.tracks[0].sends.hall = 0.25
    s.tracks[1].params.op1_level = 80
    song.save(s, file)
    local back = song.load(file)
    os.remove(file)
    assert(back.name == "a test" and back.bpm == 97 and len(back.tracks) == 4)
    assert(back.tracks[0].unit == "mini" and back.tracks[0].patch == "Fat Bass")
    assert(
      back.tracks[0].sends.hall == 0.25 and
        back.tracks[1].params.op1_level == 80,
    )
    assert(back.tracks[1].columns == 3 and back.tracks[0].lane == "cutoff")
    assert(song.get(back, 0, 1, "note", 1, 8) == 64 and song.get(
        back, 0, 1, "vel", 1, 8
      ) == 0)
    assert(song.get(back, 0, 1, "note", 1, 12) == song.OFF)
    assert(song.get(back, 1, 1, "note", 1, 8) == 67 and song.get(
        back, 0, 0, "fx", 0, 3
      ) == 0)
    assert(len(back.order) == 2 and len(
        back.buses,
      ) == 2 and back.master.inserts[0].unit == "limiter")
  })
})

t.group("player", func(){
  t.test(
    "rows sound at their sample; a note lasts to the next or to OFF",
    func(){
      local s = plain()
      song.put(s, 0, 0, "note", 0, 0, 60)
      song.put(s, 0, 0, "note", 0, 2, song.OFF)
      song.put(s, 0, 0, "note", 0, 4, 72)
      local a = player.render(s, {tail: 500})
      assert(len(a.left) == 8 * 6000 + 24000)
      assert(onset(a.left, 0, 0.01) <= 2)
      assert(peak_of(a.left, 6000, 11990) > 0.1, "it sounds through row 1")
      assert(peak_of(a.left, 12600, 23990) < 0.001, "silent after its OFF")
      assert(
        math.abs(onset(a.left, 20000, 0.01) - 24000) <= 2,
        "row 4 at its sample",
      )
      assert(
        peak_of(a.left, 42000, 47990) > 0.1,
        "the last note sounds to the end",
      )
      assert(peak_of(a.left, 60000) < 0.001, "and ends with the song")
    },
  )
  t.test("columns, velocities, the lane and swing", func(){
    local s = plain()
    s.tracks[0].columns = 2
    s.tracks[0].lane = "pan"
    song.put(s, 0, 0, "note", 0, 0, 60)
    song.put(s, 0, 0, "note", 1, 0, 67)
    song.put(s, 0, 0, "fx", 0, 0, 0)
    song.put(s, 0, 0, "note", 0, 4, 60)
    song.put(s, 0, 0, "vel", 0, 4, 20)
    song.put(s, 0, 0, "note", 1, 4, song.OFF)
    song.put(s, 0, 0, "fx", 0, 4, 99)
    local a = player.render(s, {tail: 100})
    assert(
      peak_of(a.left, 600, 6000) > 0.3 and peak_of(a.right, 600, 6000) < 1.0e-6,
      "panned left by the lane",
    )
    assert(
      peak_of(a.right, 24600, 30000) > 0.01 and
        peak_of(a.left, 24600, 30000) < 1.0e-6,
      "then right",
    )
    assert(
      peak_of(a.right, 24600, 30000) < peak_of(a.left, 600, 6000) * 0.3,
      "one soft note where two were",
    )
    // swing: every second row late, by half a row at the most
    s.swing = 1.0
    local P = player.new(s)
    P:play("pattern", 0, 0)
    P:tick(400)
    assert(P.sent[1].row == 1 and P.sent[2].row == 2)
    assert(
      math.abs(P.sent[1].time - P.sent[0].time - 9000) < 1,
      "row 1 half a row late",
    )
    assert(
      math.abs(P.sent[2].time - P.sent[0].time - 12000) < 1,
      "row 2 on time",
    )
  })
  t.test("the order, the playhead and edits while it plays", func(){
    local s = plain()
    song.put(s, 0, 0, "note", 0, 0, 60)
    local second = song.add_pattern(s, 4, 0)
    song.put(s, second, 0, "note", 0, 0, 72)
    local P = player.new(s)
    assert(player.length(s) == 12 * 0.125)
    P:play("song", 0, 0)
    assert(P:position() == null)
    local seen = {}
    for(local k = 0; k < 80; k = k + 1){
      P:tick()
      P.studio:render(25)
      local pos = P:position()
      if(pos != null){
        seen[concat(string(pos.order), ":", string(pos.row))] = true
      }
    }
    assert(
      seen["0:0"] and seen["0:7"] and seen["1:0"] and seen["1:3"],
      "through both patterns",
    )
    P:stop()
    assert(not P.playing and P:position() == null)
    P.studio:render(100)
    assert(P.tracks[0].voices == 0, "stopping ends the notes")
    // a pattern loops, and a note typed while it plays is heard
    P:play("pattern", 1, 0)
    for(local k = 0; k < 20; k = k + 1){
      P:tick()
      P.studio:render(25)
    }
    assert(P:position().order == 1 and P:position().pattern == second)
    song.put(s, second, 0, "note", 0, 2, 79)
    local heard = false
    for(local k = 0; k < 40; k = k + 1){
      P:tick()
      P.studio:render(25)
      if(P.held[0][0] == 79){
        heard = true
      }
    }
    assert(heard)
  })
  t.test(
    "parameters, patches, inserts and tracks stay in step with the song",
    func(){
      local s = song.new()
      local P = player.new(s)
      local bass = {kind: "track", index: 1}
      P:set_param(bass, -1, "cutoff", 0.9)
      assert(
        s.tracks[1].params.cutoff == 0.9 and
          P.tracks[1].unit.params.cutoff == 0.9,
      )
      P:set_patch(bass, -1, "Lead")
      assert(s.tracks[1].patch == "Lead" and s.tracks[1].params.cutoff == null)
      assert(P.tracks[1].unit.params.cutoff == 0.48)
      local slot = P:add_insert(bass, "chorus")
      assert(slot == 0 and s.tracks[1].inserts[0].unit == "chorus" and len(
          P.tracks[1].inserts,
        ) == 1)
      P:set_param(bass, 0, "mix", 0.9)
      assert(P:unit(bass, 0).handle.params.mix == 0.9)
      local hall = {kind: "bus", index: 1}
      local wet = P:add_insert(hall, "eq")
      assert(P:unit(hall, wet).entry.unit == "eq")
      P:remove_insert(hall, wet)
      assert(len(s.buses[1].inserts) == 1)
      P:set_send(1, "hall", 0.4)
      P:set_strip(bass, "gain", 0.5)
      assert(s.tracks[1].sends.hall == 0.4 and P.tracks[1].gain == 0.5)
      P:set_unit(1, "organ")
      assert(s.tracks[1].unit == "organ" and P.tracks[1].unit.name == "organ")
      assert(len(P.tracks[1].inserts) == 1, "its inserts stay")
      local added = P:add_track("six")
      assert(
        added == 4 and s.tracks[4].name == "six" and
          s.tracks[4].patch == "TINE PIANO",
      )
      assert(P:add_track("six") == 5 and s.tracks[5].name == "six 2")
      P:remove_track(0)
      assert(len(s.tracks) == 5 and len(
          P.studio.tracks,
        ) == 5 and P.tracks[0].unit.name == "organ")
      // and the song still plays
      song.put(s, 0, 0, "note", 0, 0, 60)
      assert(peak_of(player.render(s, {tail: 100}).left) > 0.01)
    },
  )
  t.test("buses come and go, with what was sent to them", func(){
    local s = song.new()
    local P = player.new(s)
    local b = P:add_bus("room")
    assert(
      b == 2 and s.buses[2].name == "room" and
        s.buses[2].inserts[0].params.mix == 1,
    )
    assert(len(P.studio.buses) == 3)
    P:set_send(1, "room", 0.5)
    assert(P:add_bus("room") == 3 and s.buses[3].name == "room 2")
    assert(P:add_bus("chorus") == null, "four are the most")
    P:remove_bus(2)
    assert(len(
      s.buses,
    ) == 3 and s.buses[2].name == "room 2" and s.tracks[1].sends.room == null)
    assert(len(P.studio.buses) == 3 and P.buses.room == null)
    P:set_send(0, "room 2", 0.3)
    song.put(s, 0, 0, "note", 0, 0, 36)
    local a = player.render(s, {tail: 300})
    assert(peak_of(a.left) > 0.01)
    // and through the file
    local back = song.from_table(song.to_table(s))
    assert(len(back.buses) == 3 and back.tracks[0].sends["room 2"] == 0.3)
  })
  t.test("a track of a recording", func(){
    local wav = require("studio/wav")
    local buffer = require("slang/buffer")
    local file = path.join(
      os.getenv("TMPDIR") or "/tmp",
      "tracker_sample_test.wav",
    )
    local tone = buffer.new("float", 24000)
    for(local i = 0; i < 24000; i = i + 1){
      tone[i] = math.sin(i * 0.06) * 0.5
    }
    wav.write(file, {tone}, 48000)
    local s = plain()
    local P = player.new(s)
    P:set_unit(0, "sampler")
    P:set_sample(0, file)
    assert(s.tracks[0].sample == file and P.missing == null)
    song.put(s, 0, 0, "note", 0, 0, 60)
    local a = player.render(s, {tail: 100})
    assert(peak_of(a.left, 0, 6000) > 0.2, "the recording plays")
    // it is in the song's file, and a file that is gone is said
    local saved = path.join(
      os.getenv("TMPDIR") or "/tmp",
      "tracker_sample_song.json",
    )
    song.save(s, saved)
    os.remove(file)
    local back = song.load(saved)
    os.remove(saved)
    assert(back.tracks[0].sample == file)
    local Q = player.new(back)
    assert(Q.missing == file)
  })
  t.test("the songs that come with it play", func(){
    local dir = path.join(here, "songs")
    local n = 0
    for(let local name in values(os.list_dir(dir))){
      if(not require("slang/string").ends_with(name, ".json")){
        continue
      }
      n = n + 1
      local s = song.load(path.join(dir, name))
      // its first pattern only: the whole of it is the render tool's
      s.order = {s.order[0]}
      local a = player.render(s, {tail: 200})
      local peak = math.max(peak_of(a.left), peak_of(a.right))
      assert(peak > 0.05, concat(name, ": silent"))
      assert(peak <= 1.0, concat(name, ": over 1"))
    }
    assert(n >= 1, "no songs")
  })
})

// the state the grid's functions work on, as main.slang makes it
local func app(s){
  return {
    song: s,
    order_pos: 0,
    cursor: {t: 0, f: 0, row: 0},
    anchor: null,
    octave: 4,
    step: 1,
    clip: null,
    typing: null,
  }
}

t.group("grid", func(){
  local grid = require("grid")
  t.test("fields, and the cursor through them", func(){
    local s = song.new()
    local A = app(s)
    // drums: one column and the lane; keys: three columns
    assert(len(grid.fields_of(s.tracks[0])) == 3 and len(
        grid.fields_of(s.tracks[2]),
      ) == 7)
    assert(grid.width_of(s.tracks[2]) == 21)
    grid.move(A, 3, 0, false)
    assert(A.cursor.t == 1 and A.cursor.f == 0, "past the lane: the next track")
    grid.move(A, -1, 0, false)
    assert(A.cursor.t == 0 and grid.field(A).kind == "fx")
    grid.move(A, 0, -1, false)
    assert(A.cursor.row == 31, "round the top")
    grid.move(A, 0, 1, true)
    assert(
      A.cursor.row == 31 and A.anchor != null,
      "a selection stops at the ends",
    )
    grid.track(A, -1)
    assert(A.cursor.t == 3 and A.cursor.f == 0 and A.anchor == null)
    A.cursor = {t: 9, f: 9, row: 99}
    grid.clamp(A)
    assert(A.cursor.t == 3 and A.cursor.f == 2 and A.cursor.row == 31)
  })
  t.test("notes, digits, clearing and undo", func(){
    local s = song.new()
    local A = app(s)
    A.step = 2
    assert(grid.note(A, 36) and A.cursor.row == 2)
    assert(grid.note(A, song.OFF) and A.cursor.row == 4)
    assert(song.get(s, 0, 0, "note", 0, 0) == 36 and song.get(
        s, 0, 0, "note", 0, 2
      ) == song.OFF)
    grid.move(A, 1, -4, false)
    assert(not grid.note(A, 40), "no notes into a velocity")
    grid.digit(A, 4)
    grid.digit(A, 5)
    assert(song.get(s, 0, 0, "vel", 0, 0) == 45)
    grid.digit(A, 7)
    assert(song.get(s, 0, 0, "vel", 0, 0) == 57, "the digits move through")
    grid.move(A, 0, 1, false)
    grid.move(A, 0, -1, false)
    grid.digit(A, 9)
    assert(
      song.get(s, 0, 0, "vel", 0, 0) == 9,
      "a new value after the cursor moved",
    )
    grid.move(A, -1, 0, false)
    grid.clear(A)
    assert(song.get(s, 0, 0, "note", 0, 0) == null and song.get(
        s, 0, 0, "vel", 0, 0
      ) == null)
    song.undo(s)
    assert(song.get(s, 0, 0, "note", 0, 0) == 36 and song.get(
        s, 0, 0, "vel", 0, 0
      ) == 9)
  })
  t.test("copy and paste, transpose, fill between, select all", func(){
    local s = song.new()
    local A = app(s)
    A.cursor.t = 1
    grid.note(A, 36)
    grid.note(A, 43)
    song.put(s, 0, 1, "fx", 0, 0, 10)
    song.put(s, 0, 1, "fx", 0, 4, 50)
    // the lane, rows 0 to 4: filled between its ends
    A.cursor = {t: 1, f: 2, row: 0}
    grid.move(A, 0, 4, true)
    assert(grid.interpolate(A))
    assert(song.get(s, 0, 1, "fx", 0, 1) == 20 and song.get(
        s, 0, 1, "fx", 0, 3
      ) == 40)
    // the whole track, copied to row 8
    A.cursor = {t: 1, f: 0, row: 0}
    A.anchor = null
    grid.move(A, 2, 4, true)
    local r = grid.range(A)
    assert(r.r0 == 0 and r.r1 == 4 and r.f1 - r.f0 == 2)
    grid.copy(A)
    A.cursor = {t: 1, f: 0, row: 8}
    A.anchor = null
    assert(grid.paste(A))
    assert(song.get(s, 0, 1, "note", 0, 8) == 36 and song.get(
        s, 0, 1, "note", 0, 9
      ) == 43)
    assert(song.get(s, 0, 1, "fx", 0, 10) == 30 and song.get(
        s, 0, 1, "fx", 0, 12
      ) == 50)
    // pasted into another track: its notes fit, its lane where there is one
    A.cursor = {t: 3, f: 0, row: 30}
    grid.paste(A)
    assert(song.get(s, 0, 3, "note", 0, 30) == 36 and song.get(
        s, 0, 3, "note", 0, 31
      ) == 43)
    // transposed, the selection only
    A.cursor = {t: 1, f: 0, row: 8}
    grid.move(A, 0, 1, true)
    grid.transpose(A, 12)
    assert(song.get(s, 0, 1, "note", 0, 8) == 48 and song.get(
        s, 0, 1, "note", 0, 0
      ) == 36)
    grid.select_all(A)
    r = grid.range(A)
    assert(
      r.r0 == 0 and r.r1 == 31 and r.fields[r.f0].t == 1 and
        r.fields[r.f1].t == 1,
    )
    grid.select_all(A)
    r = grid.range(A)
    assert(
      r.fields[r.f0].t == 0 and r.fields[r.f1].t == 3,
      "again: the whole pattern",
    )
    grid.clear(A)
    assert(song.get(s, 0, 1, "note", 0, 8) == null and song.get(
        s, 0, 3, "note", 0, 30
      ) == null)
  })
})
