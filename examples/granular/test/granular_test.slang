local t = require("slang/test")
local os = require("slang/os")
local math = require("slang/math")
local str = require("slang/string")
local kernel = require("kernel")
local microphone = require("microphone")
local engine = require("engine")
local sample = require("sample")
local snapshots = require("snapshots")

// The synthesizer without a window or an audio device: WAV files, the
// demo sample, and the engine (voices, grains, pitch, recording and live
// mode, fed by a virtual microphone).

local c = engine.cells

local func peak(buf, from, to){
  local p = 0.0
  for(local i = from; i < to; i = i + 1){
    p = math.max(p, math.abs(buf[i]))
  }
  return p
}

// seconds of the engine's output (stereo, interleaved)
local func run(block, seconds){
  local frames = to_int(seconds * engine.RATE / 128) * 128
  local out = kernel.float:array(frames * 2)
  for(local at = 0; at < frames; at = at + 128){
    block(out:slice(at * 2, (at + 128) * 2), 128)
  }
  return out
}

local func key(shared, slot, note, gate){
  shared.keys[slot * 4] = note
  shared.keys[slot * 4 + 1] = if(gate){ 1.0 } else { 0.0 }
  shared.keys[slot * 4 + 2] = 1.0
  if(gate){
    shared.keys[slot * 4 + 3] = shared.keys[slot * 4 + 3] + 1
  }
}

// a sine of hz into the first n frames of the sample
local func sine(shared, hz, n){
  for(local i = 0; i < n; i = i + 1){
    shared.sample[i] = math.sin(i * hz * 2 * math.pi / engine.RATE) * 0.5
  }
  shared.ctl[c.LENGTH] = n
}

local tmp = os.temp_dir()

t.group("samples"){
  t.test("the demo sample is about four seconds of sound"){
    local buf = kernel.float:array(engine.RATE * 5)
    local n = sample.demo(buf)
    assert(n > engine.RATE * 4 and n < engine.RATE * 5, string(n))
    assert(peak(buf, 0, n) > 0.2 and peak(buf, 0, n) < 1.0)
  }
  t.test("a take saved is the same take loaded"){
    local buf = kernel.float:array(1000)
    for(local i = 0; i < 1000; i = i + 1){
      buf[i] = math.sin(i * 0.05) * 0.8
    }
    local file = concat(tmp, "/granular_take.wav")
    sample.save(file, buf, 1000)
    local back = kernel.float:array(2000)
    local n = sample.load(file, back)
    assert(n >= 999 and n <= 1000, string(n))
    for(local i = 0; i < n; i = i + 1){
      assert(math.abs(back[i] - buf[i]) < 0.0002, string(i))
    }
    os.remove(file)
  }
  t.test("a stereo float file at 24 kHz loads as mono at 48 kHz"){
    // 480 frames: left 0.5, right -0.1 (mixed: 0.2)
    local frames = 480
    local data = kernel.float:array(frames * 2)
    for(local i = 0; i < frames; i = i + 1){
      data[i * 2] = 0.5
      data[i * 2 + 1] = -0.1
    }
    local func u32(n){
      return str.from_bytes({
        n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255
      })
    }
    local func u16(n){
      return str.from_bytes({n & 255, (n >> 8) & 255})
    }
    local body = data:to_string()
    local file = concat(tmp, "/granular_float.wav")
    os.write_file(file, concat(
      "RIFF", u32(36 + len(body)), "WAVE", "fmt ", u32(16), u16(3), u16(2),
      u32(24000), u32(24000 * 8), u16(8), u16(32), "data", u32(len(body)), body
    ))
    local back = kernel.float:array(2000)
    local n = sample.load(file, back)
    assert(n >= 955 and n <= 960, string(n))
    assert(math.abs(back[100] - 0.2) < 1e-6, string(back[100]))
    os.remove(file)
  }
  t.test("what is no WAV file raises"){
    local file = concat(tmp, "/granular_bad.wav")
    os.write_file(file, "hello, this is text")
    local r = try { sample.load(
      file,
      kernel.float:array(10),
    ) } catch(e) { string(e) }
    assert(str.contains(r, "not a WAV file"), r)
    os.remove(file)
  }
}

t.group("engine"){
  t.test("silent until a key, sounding while held, silent after release"){
    local shared = engine.shared()
    shared.ctl[c.LENGTH] = sample.demo(shared.sample)
    local block = engine.new(shared, {mic: false})
    local quiet = run(block, 0.2)
    assert(peak(quiet, 0, len(quiet)) == 0.0, "no key, no sound")
    key(shared, 0, 60, true)
    local out = run(block, 0.5)
    assert(peak(out, 0, len(out)) > 0.05, "a key plays grains")
    assert(shared.ctl[c.GRAINS] > 0)
    key(shared, 0, 60, false)
    // release 0.8 s; the delay's echoes (feedback 0.45) die later
    shared.ctl[engine.knob.mix.cell] = 0.0
    run(block, 1.2)
    out = run(block, 0.2)
    assert(peak(out, 0, len(out)) < 0.001, string(peak(out, 0, len(out))))
    assert(shared.ctl[c.GRAINS] == 0.0)
  }
  t.test("a key an octave up plays the recording an octave up"){
    local shared = engine.shared()
    sine(shared, 500.0, engine.RATE)
    for(let local k in values({"spray", "detune", "reverse", "stereo", "mix"})){
      shared.ctl[engine.knob[k].cell] = 0.0
    }
    shared.ctl[engine.knob.cutoff.cell] = 1.0
    shared.ctl[engine.knob.size.cell] = 200.0
    shared.ctl[engine.knob.density.cell] = 10.0
    local block = engine.new(shared, {mic: false})
    local func crossings(note){
      key(shared, 0, note, true)
      run(block, 0.3)
      local out = run(block, 0.5)
      key(shared, 0, note, false)
      run(block, 1.0)
      local n = 0
      for(local i = 1; i < len(out) / 2; i = i + 1){
        if((out[i * 2] >= 0.0) != (out[(i - 1) * 2] >= 0.0)){
          n = n + 1
        }
      }
      // two a period, over half a second
      return n
    }
    local root = crossings(60)
    assert(math.abs(root - 500) < 40, string(root))
    local up = crossings(72)
    assert(math.abs(up - 1000) < 80, string(up))
  }
  t.test("P plays the recording as it is, once"){
    local shared = engine.shared()
    sine(shared, 300.0, 4800)
    // no echoes (the delay line is the kernel's, kept from other tests;
    // the mix glides down)
    shared.ctl[engine.knob.mix.cell] = 0.0
    local block = engine.new(shared, {mic: false})
    run(block, 0.5)
    shared.ctl[c.PLAY] = 1.0
    local out = run(block, 0.2)
    for(local i = 0; i < 4800; i = i + 37){
      assert(math.abs(out[i * 2] - shared.sample[i]) < 0.001, string(i))
      assert(math.abs(out[i * 2 + 1] - shared.sample[i]) < 0.001, string(i))
    }
    assert(peak(out, 4800 * 2, len(out)) < 0.001, "then silence")
    assert(shared.ctl[c.PLAY] == 0.0 and shared.ctl[c.PLAYPOS] == 4800.0)
  }
  t.test("a knob glides to where it is set, an LFO moves it"){
    local shared = engine.shared()
    shared.ctl[c.LENGTH] = sample.demo(shared.sample)
    local block = engine.new(shared, {mic: false})
    local size = engine.knob.size.cell
    run(block, 0.3)
    shared.ctl[size] = 600.0
    run(block, 0.01)
    local eff = shared.ctl[c.EFF + size]
    assert(eff > 130.0 and eff < 400.0, string(eff))
    run(block, 0.5)
    assert(math.abs(shared.ctl[c.EFF + size] - 600.0) < 1.0)
    // LFO 1 on position, half the slider either way
    local o = engine.lfos[0]
    shared.ctl[o.dest] = engine.knob.position.cell
    shared.ctl[o.rate.cell] = 5.0
    shared.ctl[o.depth.cell] = 0.5
    local lo = 1.0
    local hi = 0.0
    for(local b = 0; b < 100; b = b + 1){
      run(block, 0.003)
      local p = shared.ctl[c.EFF + engine.knob.position.cell]
      lo = math.min(lo, p)
      hi = math.max(hi, p)
    }
    assert(
      lo == 0.0 and hi > 0.75 and hi < 0.81,
      concat(string(lo), " ", string(hi)),
    )
    shared.ctl[o.depth.cell] = 0.0
  }
  t.test("freeze keeps the live ring as it was"){
    if(not microphone.available()){
      return null
    }
    local mic = microphone.virtual()
    local shared = engine.shared()
    local block = engine.new(shared, {input: mic})
    mic:write(kernel.float:array(1000))
    run(block, 0.003)
    shared.ctl[c.FREEZE] = 1.0
    mic:write(kernel.float:array(1000))
    run(block, 0.003)
    assert(shared.ctl[c.LIVEHEAD] == 1000.0 and mic.waiting == 0)
    shared.ctl[c.FREEZE] = 0.0
    mic:close()
  }
  t.test("recording takes what the microphone hears, live mode plays it"){
    if(not microphone.available()){
      return null
    }
    local mic = microphone.virtual()
    local shared = engine.shared()
    local block = engine.new(shared, {input: mic})
    assert(shared.ctl[c.MIC] == 1.0)
    local heard = kernel.float:array(4800)
    for(local i = 0; i < len(heard); i = i + 1){
      heard[i] = math.sin(i * 0.1) * 0.25
    }
    // what comes while not recording goes to the live ring only
    mic:write(heard)
    run(block, 0.01)
    assert(shared.ctl[c.LENGTH] == 0.0 and shared.ctl[c.LIVEHEAD] == 4800.0)
    shared.ctl[c.RECORD] = 1.0
    mic:write(heard)
    run(block, 0.01)
    mic:write(heard)
    run(block, 0.01)
    shared.ctl[c.RECORD] = 0.0
    mic:write(heard)
    run(block, 0.01)
    assert(shared.ctl[c.LENGTH] == 9600.0, string(shared.ctl[c.LENGTH]))
    assert(shared.sample[4800 + 7] == heard[7] and shared.sample[9600] == 0.0)
    assert(shared.ctl[c.LEVEL] > 0.24, "the input's level is reported")
    assert(shared.ctl[c.LIVEHEAD] == 19200.0)
    // live: grains of the last seconds, and where they read is on screen
    shared.ctl[c.MODE] = 1.0
    shared.ctl[engine.knob.position.cell] = 0.95
    key(shared, 0, 60, true)
    local out = null
    // as a device delivers: a few blocks' worth at a time
    for(local b = 0; b < 100; b = b + 1){
      mic:write(heard:slice(0, 384))
      out = run(block, 0.008)
    }
    assert(peak(out, 0, len(out)) > 0.05)
    local seen = 0
    for(local s = 0; s < engine.MAXG; s = s + 1){
      if(shared.view[s * 2 + 1] > 0.0){
        seen = seen + 1
        assert(
          shared.view[s * 2] > 0.5 and shared.view[s * 2] < 0.997,
          string(shared.view[s * 2]),
        )
      }
    }
    assert(seen > 0)
    mic:close()
  }
  t.test("a full recording stops by itself"){
    if(not microphone.available()){
      return null
    }
    local mic = microphone.virtual({buffer: engine.MAXS})
    local shared = engine.shared()
    local block = engine.new(shared, {input: mic})
    shared.ctl[c.RECORD] = 1.0
    local chunk = kernel.float:array(engine.RATE)
    for(local s = 0; s < engine.MAXS / engine.RATE + 1; s = s + 1){
      mic:write(chunk)
      run(block, 0.003)
    }
    assert(shared.ctl[c.RECORD] == 0.0 and shared.ctl[c.LENGTH] == engine.MAXS)
    mic:close()
  }
}

t.group("snapshots"){
  t.test("recall morphs along the sliders, a knob turned stays"){
    local shared = engine.shared()
    local ctl = shared.ctl
    local snaps = snapshots.new(ctl)
    local size = engine.knob.size
    local shape = engine.lfos[0].shape
    ctl[size.cell] = 5.0
    snaps:store(1)
    ctl[size.cell] = 1000.0
    ctl[shape] = 3.0
    ctl[engine.knob.cutoff.cell] = 0.2
    snaps:store(2)
    assert(not snaps:recall(3), "an empty slot")
    ctl[c.GLIDE] = 1.0
    snaps:recall(1)
    snaps:step(0.25)
    snaps:step(0.25)
    // halfway along the slider (size has a curve), the choice switched
    assert(math.abs(engine.t_of(size, ctl[size.cell]) - 0.5) < 0.001)
    assert(ctl[shape] == 0.0 and snaps.gliding)
    ctl[engine.knob.cutoff.cell] = 0.9
    snaps:touch(engine.knob.cutoff.cell)
    snaps:step(1.0)
    assert(ctl[size.cell] == 5.0 and not snaps.gliding)
    assert(ctl[engine.knob.cutoff.cell] == 0.9, "the turned knob stays")
    snaps:morph(0.0)
    assert(ctl[size.cell] == 1000.0 and ctl[shape] == 3.0)
    // the slot keeps what was stored
    snaps:recall(1)
    snaps:morph(1.0)
    assert(ctl[engine.knob.cutoff.cell] == engine.knob.cutoff.init)
  }
  t.test("snapshots saved are snapshots loaded"){
    local a = snapshots.new(engine.shared().ctl)
    a.ctl[engine.knob.density.cell] = 77.5
    a:store(4)
    local file = concat(tmp, "/granular_snaps.json")
    a:save(file)
    local b = snapshots.new(engine.shared().ctl)
    assert(b:load(file) and b:has(4) and not b:has(1))
    b.ctl[c.GLIDE] = 0.0
    b:recall(4)
    assert(b.ctl[engine.knob.density.cell] == 77.5)
    os.remove(file)
  }
}
