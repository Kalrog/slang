local t = require("slang/test")
local math = require("slang/math")
local os = require("slang/os")
local path = require("slang/path")
local buffer = require("slang/buffer")
local studio = require("studio")
local wav = require("studio/wav")

// WAV files and the sampler.

local here = __PACKAGES.search_paths[0]
local tmp = path.join(os.getenv("TMPDIR") or "/tmp", "studio_wav_test.wav")

local func peak_of(buf, from, to){
  local peak = 0.0
  for(local i = from or 0; i < (to or len(buf)); i = i + 1){
    peak = math.max(peak, math.abs(buf[i]))
  }
  return peak
}

local func crossings(buf, from, to){
  local n = 0
  for(local i = from + 1; i < to; i = i + 1){
    if(buf[i - 1] < 0 and buf[i] >= 0){
      n = n + 1
    }
  }
  return n
}

// a second of a sine at hz
local func sine(hz, rate, seconds){
  local n = to_int(rate * (seconds or 1))
  local b = buffer.shared("float", n)
  for(local i = 0; i < n; i = i + 1){
    b[i] = math.sin(2 * math.pi * hz * i / rate) * 0.5
  }
  return b
}

t.group("wav", func(){
  t.test("what is written reads back", func(){
    local l = sine(440, 48000, 0.1)
    local r = sine(880, 48000, 0.1)
    wav.write(tmp, {l, r}, 48000)
    local back = wav.read(tmp)
    assert(back.frames == 4800 and back.rate == 48000 and back.channels == 2)
    local worst = 0.0
    for(local i = 0; i < 4800; i = i + 1){
      worst = math.max(
        worst,
        math.abs(back.left[i] - l[i]),
        math.abs(back.right[i] - r[i]),
      )
    }
    assert(worst < 1.0 / 16000, concat("16 bits: ", string(worst)))
    local mono = wav.read(tmp, {mono: true, rate: 24000})
    assert(mono.right == null and mono.frames == 2400 and mono.rate == 24000)
    os.remove(tmp)
    t.raises(func(){ wav.read(path.join(here, "slang.project")) })
  })
})

t.group("sampler", func(){
  t.test("a zone plays at its note's speed", func(){
    local s = studio.new()
    local smp = s:track("smp", "sampler", {
      zones: {{sample: sine(440, 48000), root: 69}},
    })
    smp:note(69)
    local a = s:render(500)
    assert(
      math.abs(crossings(a.left, 2400, 21600) - 176) <= 1,
      "440 Hz as recorded",
    )
    smp:off(69)
    s:render(1500)
    assert(smp.voices == 0)
    smp:note(81)
    local b = s:render(400)
    assert(
      math.abs(crossings(b.left, 2400, 16800) - 264) <= 2,
      "an octave up: 880 Hz",
    )
    s:render(300)
    assert(
      smp.voices == 0,
      "twice as fast, the recording is over in half a second",
    )
  })
  t.test(
    "zones by key and velocity, a recording's own rate, one shots and loops",
    func(){
      local s = studio.new()
      local smp = s:track("smp", "sampler", {
        zones: {
          {sample: sine(220, 48000), root: 57, high: 59},
          {
            sample: {left: sine(440, 24000), frames: 24000, rate: 24000},
            root: 69, low: 60, low_velocity: 0.5
          },
        },
        mode: "one shot",
      })
      smp:note(57, {length: 10})
      local a = s:render(300)
      assert(math.abs(crossings(a.left, 2400, 12000) - 44) <= 1, "the low zone")
      assert(smp.voices == 1, "a one shot plays on after its key")
      smp:panic()
      smp:note(69, {velocity: 0.3})
      assert(peak_of(s:render(50).left) == 0.0, "too soft for the zone")
      smp:note(69, {velocity: 0.9})
      local b = s:render(300)
      assert(
        math.abs(crossings(b.left, 2400, 12000) - 88) <= 1,
        "24 kHz recording, still 440 Hz",
      )
      smp:panic()
      // a loop outlasts its recording
      local l = studio.new()
      local loop = l:track("loop", "sampler", {
        zones: {
          {
            sample: sine(480, 48000, 0.1), root: 60, loop_start: 1000,
            loop_end: 3000
          },
        },
        mode: "loop",
      })
      loop:note(60)
      l:render(1000)
      assert(loop.voices == 1)
      assert(peak_of(l:render(100).left) > 0.3)
      loop:off(60)
      l:render(1500)
      assert(loop.voices == 0)
      loop.unit:message({zones: {{sample: sine(100, 48000), root: 60}}})
      loop:note(60)
      assert(
        math.abs(crossings(l:render(500).left, 0, 24000) - 50) <= 1,
        "the new zone",
      )
    },
  )
})

t.group("grains", func(){
  t.test("grains of a sample while a key is held", func(){
    local s = studio.new()
    local take = sine(220, 48000)
    local cloud = s:track("cloud", "grains", {
      sample: take, attack: 2, release: 20, detune: 0
    })
    cloud:note(60)
    local a = s:render(500)
    assert(peak_of(a.left, 4800) > 0.05, "no grains")
    assert(peak_of(a.left) <= 1.0)
    assert(cloud.unit:effective("grains") > 2)
    assert(cloud.unit:effective("length") == 48000)
    assert(cloud.voices == 1)
    cloud:off(60)
    s:render(600)
    assert(cloud.voices == 0)
    assert(peak_of(s:render(50).left) == 0.0, "silent after its key")
    // an octave up: grains read twice as fast
    cloud.unit:patch({
      size: 400, density: 4, spray: 0, detune: 0, attack: 1, stereo: 0,
      cutoff: 1, scan: 0
    })
    s:render(300)
    cloud:note(72)
    local b = s:render(300)
    local up = crossings(b.left, 4800, 9600)
    assert(math.abs(up - 44) <= 3, concat("440 Hz in a grain: ", string(up)))
  })
  t.test("records a microphone and plays it live", func(){
    if(not try { require("microphone").virtual != null } catch { false }){
      return null
    }
    local mic = require("microphone").virtual()
    local s = studio.new()
    local cloud = s:track("cloud", "grains", {
      input: mic, attack: 2, seconds: 2
    })
    cloud.unit.params.record = 1
    local chunk = buffer.new("float", 480)
    for(local k = 0; k < 100; k = k + 1){
      for(local i = 0; i < 480; i = i + 1){
        chunk[i] = math.sin(2 * math.pi * 330 * (k * 480 + i) / 48000) * 0.5
      }
      mic:write(chunk)
      s:render(10)
    }
    cloud.unit.params.record = 0
    s:render(10)
    assert(
      cloud.unit:effective("length") == 48000,
      concat("recorded ", string(cloud.unit:effective("length"))),
    )
    cloud:note(60)
    assert(peak_of(s:render(400).left, 4800) > 0.05, "the recording plays")
    cloud.unit.params.mode = "live"
    for(local k = 0; k < 40; k = k + 1){
      mic:write(chunk)
      s:render(10)
    }
    assert(cloud.unit:effective("grains") > 0, "live grains")
  })
})

t.group("programs", func(){
  t.test("the dsp instruments sound, and end after their keys", func(){
    for(let local name in values({"organ", "pluck", "bell", "wind"})){
      local s = studio.new()
      local tr = s:track(name, name)
      tr:note(57, {length: 150})
      tr:note(64, {length: 150})
      local a = s:render(150)
      assert(peak_of(a.left, 2400) > 0.01, concat(name, ": silent"))
      assert(peak_of(a.left) < 2.0, concat(name, ": too loud"))
      assert(
        tr.voices == 2,
        concat(name, ": two notes, ", string(tr.voices), " voices"),
      )
      tr:hush()
      s:render(4000)
      // (a string rings as long as it rings)
      assert(tr.voices == 0 or name == "pluck", concat(name, ": rings on"))
    }
  })
  t.test("controls are parameters; the pitch is the note's", func(){
    local s = studio.new()
    local organ = s:track("organ", "organ", {
      bar_4: 0, bar_2_2_3: 0, bar_2: 0, tremolo_depth: 0
    })
    assert(organ.unit.info.index.bar_8 == 0)
    assert(organ.unit.params.bar_4 == 0.0)
    organ:note(69)
    s:render(100)
    assert(
      math.abs(crossings(s:render(500).left, 0, 24000) - 220) <= 1,
      "440 Hz",
    )
    local loud = peak_of(s:render(100).left)
    organ.unit.params.bar_8 = 0.4
    s:render(50)
    assert(
      math.abs(peak_of(s:render(100).left) - loud * 0.5) < loud * 0.05,
      "the drawbar halves it",
    )
    organ.bend = 1
    s:render(50)
    local bent = crossings(s:render(500).left, 0, 24000)
    assert(
      math.abs(bent - 247) <= 1,
      concat("two semitones up: ", string(bent)),
    )
  })
})

t.group("rack", func(){
  t.test("the racks that come with it play", func(){
    local names = require("studio/units/rack/patches").names
    assert(len(names) == 8)
    for(let local name in values({"first_song", "acid", "generative"})){
      local s = studio.new()
      local tr = s:track(name, "rack", {rack: name})
      local a = s:render(1500)
      assert(peak_of(a.left) > 0.02, concat(name, ": silent"))
      assert(peak_of(a.left) <= 1.0, concat(name, ": over 1"))
      tr.unit.params.run = 0
      s:render(3000)
      assert(
        peak_of(s:render(500).left) < 0.02 or name == "generative",
        concat(name, ": plays on, stopped"),
      )
    }
  })
  t.test(
    "notes reach the keyboard module; two racks do not share a clock",
    func(){
      local s = studio.new()
      local tr = s:track("keys", "rack", {rack: "play"})
      assert(peak_of(s:render(200).left) < 0.001, "silent until a key")
      tr:note(57)
      assert(peak_of(s:render(300).left) > 0.02, "the key sounds")
      tr:off(57)
      s:render(3000)
      assert(peak_of(s:render(300).left) < 0.01, "and ends")
      // a rack patched from the program
      local patch = require("studio/units/rack/patch")
      local r = patch.new(buffer.shared)
      local vco = r:add("VCO")
      local out = r:add("OUT")
      r:connect(vco, 0, out, 0)
      local own = s:track("own", "rack", {rack: r.a})
      local a = s:render(500)
      local hz = crossings(a.left, 0, 24000) * 2
      assert(math.abs(hz - 262) < 6, concat("a VCO at C4: ", string(hz)))
      // two of the same song, the second started half a second later: each
      // keeps its own place
      local two = studio.new()
      local first = two:track("a", "rack", {rack: "first_song"})
      local x = two:render(500)
      first.mute = true
      two:render(10)
      local second = two:track("b", "rack", {rack: "first_song"})
      local y = two:render(500)
      local worst = 0.0
      for(local i = 0; i < 24000; i = i + 1){
        worst = math.max(worst, math.abs(x.left[i] - y.left[i]))
      }
      assert(worst < 1.0e-6, concat(
        "the second starts as the first did: ",
        string(worst),
      ))
    },
  )
})

t.group("units of a program's own", func(){
  t.test("a dsp program as an effect, by its module's name", func(){
    local s = studio.new()
    local tr = s:track("src", "poly", {
      wave: "sine", attack: 0.5, sustain: 1, cutoff: 1
    })
    tr:note(69)
    local dry = peak_of(s:render(100).left, 2400)
    local fx = tr:insert("test/programs/tilt_unit")
    assert(fx.name == "test/programs/tilt_unit" and fx.info.index.amount == 0)
    local half = peak_of(s:render(100).left, 2400)
    assert(math.abs(half - dry * 0.5) < dry * 0.02)
    fx.params.amount = 2
    local twice = peak_of(s:render(100).left, 2400)
    assert(math.abs(twice - dry * 2) < dry * 0.05)
    t.raises(func(){ tr:insert("test/programs/none") })
    t.raises(func(){ s:track("x", "test/programs/tilt_unit") })
  })
})
