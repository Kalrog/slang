// window/audio: streams, sounds from samples and WAV files, voices. Needs
// an audio device; everything plays at volume 0 (run with
// `slang test test` in packages/window)
local t = require("slang/test")
local audio = require("window/audio")
local buffer = require("slang/buffer")
local os = require("slang/os")
local time = require("slang/time")

// a 16-bit mono WAV file of n frames of silence
local func wav_bytes(n, rate){
  local b = buffer.new("uint8_t", 44 + n * 2)
  local func put(at, s){
    for(local i = 0; i < len(s); i = i + 1){
      b[at + i] = require("slang/string").byte_at(s, i)
    }
  }
  local func u32(at, v){
    for(local i = 0; i < 4; i = i + 1){
      b[at + i] = (v >> (8 * i)) & 255
    }
  }
  local func u16(at, v){
    b[at] = v & 255
    b[at + 1] = (v >> 8) & 255
  }
  put(0, "RIFF")
  u32(4, 36 + n * 2)
  put(8, "WAVEfmt ")
  u32(16, 16)
  u16(20, 1)
  u16(22, 1)
  u32(24, rate)
  u32(28, rate * 2)
  u16(32, 2)
  u16(34, 16)
  put(36, "data")
  u32(40, n * 2)
  return b:to_string()
}

t.group("window/audio: sounds"){
  t.test("a sound from float samples"){
    local s = audio.sound(buffer.new("float", 4800), {sample_rate: 48000})
    assert(type(s) == "window.Sound")
    assert(s.frames == 4800 and s.channels == 1 and s.duration == 100.0)
  }
  t.test("a sound from a WAV file"){
    local path = "test/.audio_test.wav"
    os.write_file(path, wav_bytes(2205, 22050))
    local s = audio.sound(path)
    os.remove(path)
    assert(s.sample_rate == 22050 and s.channels == 1 and s.frames == 2205, s)
    local v = s:play({volume: 0})
    assert(type(v) == "window.Voice" and v.playing)
    v:stop()
    assert(not v.playing)
  }
  t.test("a voice plays out and ends"){
    local s = audio.sound(buffer.new("float", 480))
    local v = s:play({volume: 0, pitch: 2})
    assert(v.pitch == 2 and v.volume == 0)
    local t0 = time.clock()
    for(v.playing and time.clock() - t0 < 2000){
      time.sleep(5)
    }
    assert(not v.playing)
  }
  t.test("a missing file raises"){
    t.raises(func(){
      audio.sound("no/such/file.wav")
    })
  }
}

t.group("window/audio: streams"){
  t.test("a stream computes blocks and stops"){
    local p = audio.play(func(){
      return func(out, frames){
        out:fill(0.0)
      }
    })
    p.volume = 0
    time.sleep(200)
    local s = p:stats()
    assert(s.blocks > 10 and s.playing, s)
    assert(s.load >= 0 and s.load < 1)
    p:stop()
    assert(not p.playing)
    p:stop()
  }
  t.test("a block function's error is raised by stop"){
    local p = audio.play(func(){
      return func(out, frames){
        raise("broken block")
      }
    })
    time.sleep(100)
    t.raises(func(){
      p:stop()
    })
  }
  t.test("the driver has a name"){
    assert(len(audio.driver) > 0)
  }
}

t.group("window/audio: microphones"){
  t.test("a virtual microphone reads what was written, a frame at a time"){
    local mic = audio.virtual_microphone({sample_rate: 48000, channels: 1})
    local samples = buffer.new("float", 1000)
    for(local i = 0; i < 1000; i = i + 1){
      samples[i] = (i % 10) / 20.0
    }
    mic:write(samples)
    assert(mic.waiting == 1000, string(mic.waiting))
    local out = buffer.new("float", 960)
    assert(mic:read(out) == 960 and out[9] == samples[9])
    assert(mic.level > 0.44 and mic.level == 0.0)
    local rest = mic:read()
    assert(len(rest) == 40 and rest[0] == samples[960])
    assert(mic:read(out) == 0)
    mic:close()
    mic:close()
    t.raises(func(){ mic:read(out) })
  }
  t.test("a virtual microphone drops the oldest beyond its buffer"){
    local mic = audio.virtual_microphone({buffer: 100})
    local samples = buffer.new("float", 150)
    for(local i = 0; i < 150; i = i + 1){
      samples[i] = i / 1000.0
    }
    mic:write(samples)
    local out = mic:read()
    assert(len(out) == 100 and mic.dropped == 50 and out[0] == samples[50])
    mic:close()
  }
  t.test("the default microphone records, where there is one"){
    if(len(audio.microphones()) == 0){
      t.skip("no microphone")
    }
    local mic = audio.microphone({sample_rate: 48000})
    assert(type(mic.name) == "string")
    time.sleep(150)
    local out = buffer.new("float", 48000)
    // (silence where the program may not use the microphone)
    assert(mic:read(out) > 0)
    mic:close()
    t.raises(func(){ audio.microphone({device: "no such microphone anywhere"}) })
  }
}
