local t = require("slang/test")
local math = require("slang/math")
local os = require("slang/os")
local path = require("slang/path")
local studio = require("studio")
local sequence = require("studio/sequence")
local snapshot = require("studio/snapshot")

// Sequences (notes, curves, loops, MIDI files) and snapshots.

local here = __PACKAGES.search_paths[0]

local func peak_of(buf, from, to){
  local peak = 0.0
  for(local i = from or 0; i < (to or len(buf)); i = i + 1){
    peak = math.max(peak, math.abs(buf[i]))
  }
  return peak
}

// the first sample louder than `level` from `from` on, or -1
local func onset(buf, from, level){
  for(local i = from; i < len(buf); i = i + 1){
    if(math.abs(buf[i]) > level){
      return i
    }
  }
  return -1
}

t.group("sequence", func(){
  t.test("notes sound at their beats, to the sample", func(){
    local s = studio.new()
    local tr = s:track("lead", "poly", {
      wave: "square", attack: 0.5, release: 2, cutoff: 1
    })
    local song = sequence.new(s, {bpm: 120})
    song:notes(tr, {{0, 0.25, 60}, {1, 0.25, 64}, {2.5, 0.25, 67}})
    assert(song.length == 2.75)
    local a = song:render({tail: 200})
    assert(len(a.left) == to_int(2.75 * 24000) + 9600)
    // 120 bpm: a beat is 24000 samples
    assert(onset(a.left, 0, 0.01) <= 2)
    assert(peak_of(a.left, 12000, 23990) < 1.0e-4, "silence between the notes")
    assert(
      math.abs(onset(a.left, 12000, 0.01) - 24000) <= 2,
      "the second at beat 1",
    )
    assert(
      math.abs(onset(a.left, 40000, 0.01) - 60000) <= 2,
      "the third at beat 2.5",
    )
    assert(tr.voices == 0)
  })
  t.test("loops, the tempo, swing and curves", func(){
    local s = studio.new()
    local tr = s:track("lead", "poly", {
      wave: "square", attack: 0.5, release: 2, cutoff: 1
    })
    local song = sequence.new(s, {bpm: 240, length: 1})
    song:note(tr, 0, 60, {length: 0.1})
    song:note(tr, 0.25, 72, {length: 0.1})
    song.swing = 1
    local a = song:render({loops: 3, tail: 100})
    // 240 bpm: a beat is 12000 samples; three passes
    for(local k = 0; k < 3; k = k + 1){
      assert(
        math.abs(onset(
          a.left, k * 12000 - 1 + (if(k == 0){ 1 } else { 0 }), 0.01
        ) - k * 12000) <= 2,
        concat("pass ", string(k)),
      )
      // the second sixteenth, late by an eighth of a beat
      assert(
        math.abs(onset(a.left, k * 12000 + 2400, 0.01) - (k * 12000 + 4500)) <=
          2,
        concat("swung, pass ", string(k)),
      )
    }
    local c = studio.new()
    local pad = c:track("pad", "poly")
    local cs = sequence.new(c, {bpm: 60, length: 2})
    cs:curve(pad.unit, "cutoff", {{0, 0.2}, {2, 0.8}})
    cs:curve(pad, "gain", {{0, 1}, {1, 0.5}}, {step: true})
    cs:start()
    cs.lookahead = 0
    c:render(1100)
    cs:tick()
    c:render(1)
    assert(
      math.abs(pad.unit.params.cutoff - 0.53) < 0.02,
      concat("past half way: ", string(pad.unit.params.cutoff)),
    )
    assert(pad.gain == 0.5, "the gain stepped at beat 1")
    assert(math.abs(cs.beat - 1.1) < 0.01)
    cs.bpm = 120
    c:render(200)
    assert(math.abs(cs.beat - 1.5) < 0.01, "twice as fast from where it was")
    t.raises(func(){ cs:curve(pad.unit, "nothing", {{0, 1}}) })
  })
  t.test("a MIDI file's tracks onto strips", func(){
    local file = path.join(
      here,
      "../../examples/synth/songs/bach_invention8.mid",
    )
    if(not os.exists(file)){
      return null
    }
    local s = studio.new()
    local keys = s:track("keys", "six", {patch: "CLAVI"})
    local song = sequence.new(s)
    local info = song:midi(file, func(i, track){ return keys })
    assert(len(info.tracks) >= 1 and info.length > 16)
    assert(len(song.events) > 100)
    song.length = 4
    local a = song:render({tail: 300})
    assert(peak_of(a.left) > 0.02 and peak_of(a.left) <= 1.0)
  })
})

t.group("snapshot", func(){
  t.test("take, apply, morph along the sliders, save and load", func(){
    local s = studio.new()
    local tr = s:track("lead", "poly", {attack: 1, cutoff: 0.2, wave: "saw"})
    local a = snapshot.take({tr.unit})
    tr.unit:patch({attack: 1000, cutoff: 0.8, wave: "sine"})
    local b = snapshot.take({tr.unit})
    snapshot.apply(a)
    assert(tr.unit.params.cutoff == 0.2 and tr.unit.params.wave == 0.0)
    snapshot.morph(a, b, 0.5)
    assert(math.abs(tr.unit.params.cutoff - 0.5) < 1.0e-9)
    // attack has a curve of 3: half the slider is far less than half the time
    local half = tr.unit.params.attack
    assert(
      half > 100 and half < 200,
      concat("attack at the slider's middle: ", string(half)),
    )
    assert(tr.unit.params.wave == 3.0, "an enumeration changes at the middle")
    snapshot.glide(s, a, b, 100)
    s:render(50)
    assert(
      math.abs(tr.unit.params.cutoff - 0.5) < 0.1,
      "half way through the glide",
    )
    s:render(60)
    assert(math.abs(tr.unit.params.cutoff - 0.8) < 1.0e-9)
    local file = path.join(
      os.getenv("TMPDIR") or "/tmp",
      "studio_snapshot_test.json",
    )
    snapshot.save(a, file)
    local back = snapshot.load(file, {tr.unit})
    os.remove(file)
    snapshot.apply(back)
    assert(tr.unit.params.cutoff == 0.2 and tr.unit.params.attack == 1.0)
  })
})
