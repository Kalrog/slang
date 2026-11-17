local t = require("slang/test")
local math = require("slang/math")
local os = require("slang/os")
local path = require("slang/path")
local time = require("slang/time")
local isolate = require("slang/isolate")
local buffer = require("slang/buffer")
local studio = require("studio")

// The studio as a stream plays it: the engine in an isolate of its own,
// everything crossing through the shared buffers and the commands. No
// sound card: an audio module made here calls the block function as
// window/audio and raylib/stream do. And MIDI, from messages made here.

// what audio.play is to the studio: setup in a new isolate, its block
// function called block after block until stop
local fake = {}
func fake.play(setup, options){
  local state = buffer.shared("double", 4) // stop, blocks, peak
  local worker = isolate.spawn(func(setup, args, frames, state){
    local buffer = require("slang/buffer")
    local time = require("slang/time")
    local block = setup(...args)
    local out = buffer.new("float", frames * 2)
    for(state[0] == 0.0){
      block(out, frames)
      local peak = state[2]
      for(local i = 0; i < frames * 2; i = i + 1){
        local v = out[i]
        if(v < 0){
          v = -v
        }
        if(v > peak){
          peak = v
        }
      }
      state[2] = peak
      state[1] = state[1] + 1
      time.sleep(0.2)
    }
    return "stopped"
  }, setup, options.args, options.block, state)
  return {
    state: state,
    stop: func(self){
      state[0] = 1.0
      worker:join()
    },
    stats: func(self){
      return {blocks: state[1], peak: state[2]}
    },
  }
}

// waits until f() holds (two seconds at most)
local func wait_for(f, what){
  local from = time.clock()
  for(not f()){
    if(time.clock() - from > 2000){
      assert(false, concat("waited in vain for ", what))
    }
    time.sleep(2)
  }
}

t.group("realtime", func(){
  t.test("a stream's isolate plays what the program tells it", func(){
    if(not isolate.available()){
      return null
    }
    local s = studio.new()
    local keys = s:track("keys", "six", {patch: "TINE PIANO"})
    local smp = buffer.shared("float", 4800)
    for(local i = 0; i < 4800; i = i + 1){
      smp[i] = math.sin(i * 0.05) * 0.5
    }
    local hit = s:track("hit", "sampler", {
      zones: {{sample: smp}},
      mode: "one shot",
    })
    s:start(fake)
    assert(s.playing)
    t.raises(func(){ s:render(10) })
    wait_for(func(){ return s.clock > 1000 }, "the clock")
    assert(s:stats().peak == 0.0, "silent so far")
    keys:note(60, {length: 100})
    wait_for(func(){ return s:stats().peak > 0.01 }, "the note")
    wait_for(func(){ return keys.voices == 0 }, "the note's end")
    // a parameter crosses, and a layout change while it plays
    keys.unit.params.algorithm = 7
    wait_for(func(){
      return keys.unit.params.algorithm == 7.0
    }, "the parameter")
    local bus = s:bus("room")
    bus:insert("room", {mix: 1})
    keys:send(bus, 0.5)
    hit:note(60)
    wait_for(func(){
      return bus.peak.left > 0.0 or hit.voices == 1
    }, "the sample through the stream")
    keys:note(64, {length: 50})
    wait_for(func(){ return bus.peak.left > 0.001 }, "the bus")
    assert(s.dropped == 0)
    s:stop()
    assert(not s.playing)
    // and offline again
    keys:note(60, {length: 50})
    assert(len(s:render(100).left) == 4800)
  })
})

t.group("midi", func(){
  t.test("a controller plays a track, block by block", func(){
    local s = studio.new()
    local keys = s:track("keys", "poly", {release: 5})
    local waiting = {}
    local input = {
      read: func(self){
        local out = waiting
        waiting = {}
        return out
      },
    }
    s:midi(keys, {input: input})
    s:render(10)
    append(waiting, {kind: "note_on", channel: 1, note: 60, velocity: 100})
    append(waiting, {kind: "cc", channel: 1, controller: 64, value: 127})
    s:render(20)
    assert(keys.voices == 1)
    append(waiting, {kind: "note_off", channel: 1, note: 60})
    s:render(200)
    assert(keys.voices == 1, "the pedal holds it")
    append(waiting, {kind: "cc", channel: 1, controller: 64, value: 0})
    s:render(200)
    assert(keys.voices == 0)
    s:midi(null)
    append(waiting, {kind: "note_on", channel: 1, note: 60, velocity: 100})
    s:render(20)
    assert(keys.voices == 0, "no track, no notes")
  })
  t.test("knobs are learned and move parameters along their sliders", func(){
    local file = path.join(
      os.getenv("TMPDIR") or "/tmp",
      "studio_midi_map_test.json",
    )
    if(os.exists(file)){
      os.remove(file)
    }
    local s = studio.new()
    local keys = s:track("keys", "poly")
    local fx = keys:insert("delay")
    local knobs = require("studio/midi").open(s, {path: file, input: false})
    local func cc(n, v){
      return {kind: "cc", channel: 1, controller: n, value: v}
    }
    assert(not knobs:handle(cc(74, 64)), "bound to nothing yet")
    knobs:learn(keys.unit, "attack")
    assert(knobs.learning)
    assert(knobs:handle(cc(74, 127)))
    assert(not knobs.learning and knobs:binding(keys.unit, "attack") == "CC 74")
    assert(keys.unit.params.attack == 4000.0)
    knobs:handle(cc(74, 0))
    assert(keys.unit.params.attack == 0.5)
    knobs:learn(fx, "mix")
    knobs:handle(cc(71, 127))
    assert(fx.params.mix == 1.0)
    knobs:learn(keys, "gain")
    knobs:handle(cc(7, 90))
    assert(
      math.abs(keys.gain - 1.0) < 0.01,
      "a fader at 90 of 127 is about unity",
    )
    // the bindings are there the next time
    local again = require("studio/midi").open(s, {path: file, input: false})
    assert(again:binding(fx, "mix") == "CC 71")
    again:forget(fx, "mix")
    assert(again:binding(fx, "mix") == null)
    t.raises(func(){ knobs:learn(keys.unit, "nothing") })
    os.remove(file)
  })
})
