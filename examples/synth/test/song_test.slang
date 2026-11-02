local t = require("slang/test")
local buffer = require("slang/buffer")
local isolate = require("slang/isolate")
local params = require("params")
local engine = require("engine")
local midi = require("midi")
local song = require("song")

// MIDI files, song files, and the engine playing a song (no window, no
// audio device).

t.group("songs"){
  t.test("a MIDI file: notes paired, the tempo map read"){
    local m = midi.read("songs/grieg_mountain_king.mid")
    assert(m.ppq == 384 and len(m.tracks) == 3)
    assert(to_int(60 / m.tempos[0][1] + 0.5) == 138, "138 a minute at first")
    local first = m.tracks[1].notes[2]
    // the theme starts on B, a sixteenth long
    assert(first.note == 35 and first.length == 96, concat("", first.note, " ", first.length))
    assert(midi.seconds(m, 384 * 138) > 59.9 and midi.seconds(m, 384 * 138) < 60.1)
  }
  t.test("a song file: one line, folded into its range, curves in seconds"){
    local s = song.load("songs/grieg_mountain_king.slang")
    local held = 0
    for(let local e in values(s.events)){
      assert(e.note >= 47 and e.note <= 83, concat("folded: ", e.note))
      if(e.on){
        held = held + 1
      } else {
        held = held - 1
      }
      assert(held <= 1, "one note at a time")
    }
    assert(len(s.curves) > 0 and s.length > 140)
    // a rotary switch by its label
    local wave = null
    for(let local c in values(s.curves)){
      if(c.index == params.index.wave1){
        wave = c
      }
    }
    assert(wave.step and wave.points[1][1] == 2.0, "SAW is position 2")
  }
  t.test("the engine plays a song: notes sound, keys and controls move"){
    local p = buffer.new("double", params.count)
    for(local i = 0; i < params.count; i = i + 1){
      p[i] = params.list[i].default
    }
    local events = isolate.channel()
    local status = {state: buffer.new("double", 4), keys: buffer.new("uint8", 128)}
    local block = engine.new(p, events, null, 48000, status)
    events:send({song: song.load("songs/bach_prelude.slang")})
    local out = buffer.new("float", 128)
    local loud = 0.0
    local keys_seen = 0
    for(local b = 0; b < 375; b = b + 1){
      block(out, 128)
      for(local i = 0; i < 128; i = i + 1){
        loud = loud + out[i] * out[i]
      }
      for(local n = 0; n < 128; n = n + 1){
        keys_seen = keys_seen + status.keys[n]
      }
    }
    assert(status.state[0] == 1 and status.state[1] > 0.99, "playing, a second in")
    assert(loud > 1.0, "it sounds")
    assert(keys_seen > 0, "the song holds keys")
    assert(p[params.index.a_sustain] == 0.85, "the song's patch is set")
    events:send({stop_song: true})
    block(out, 128)
    assert(status.state[0] == 0, "stopped")
  }
  t.test("parts: a chord as three lines, each part its own settings"){
    local info = song.parts("test/chord_song.slang")
    assert(len(info.parts) == 3 and info.parts[1].name == "middle")
    assert(info.parts[1].pan == 0.5 and info.parts[1].gain == 0.5 and info.parts[0].gain == 1.0)
    local expect = {67, 64, 60}
    for(local k = 0; k < 3; k = k + 1){
      local s = song.load("test/chord_song.slang", k)
      assert(len(s.events) == 2, concat("part ", k, ": two events"))
      assert(s.events[0].note == expect[k] and s.events[0].on and s.events[1].t == 1.0)
    }
    // by name
    assert(song.load("test/chord_song.slang", "low").events[0].note == 60)
  }
}
