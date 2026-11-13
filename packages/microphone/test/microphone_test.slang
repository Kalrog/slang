local t = require("slang/test")
local buffer = require("slang/buffer")
local math = require("slang/math")
local str = require("slang/string")
local microphone = require("microphone")

// The ring of an input through a virtual one (no device needed), and the
// device list where this platform has one. Nothing here records.

local func floats(list){
  local b = buffer.new("float", len(list))
  b:set(list)
  return b
}

t.group("microphone"){
  t.test("what is written is read, in order, in whole frames"){
    if(not microphone.available()){
      return null
    }
    local mic = microphone.virtual({channels: 2, buffer: 64})
    assert(
      mic.name == "virtual" and mic.channels == 2 and mic.sample_rate == 48000,
    )
    assert(
      mic:write(floats({0.1, -0.1, 0.2, -0.2, 0.5})) == 2,
      "the odd sample is no frame",
    )
    assert(mic.waiting == 2)
    local out = buffer.new("float", 2)
    assert(mic:read(out) == 1, "a buffer of one frame takes one")
    assert(math.abs(out[0] - 0.1) < 1e-6 and math.abs(out[1] + 0.1) < 1e-6)
    local rest = mic:read()
    assert(len(rest) == 2 and math.abs(rest[0] - 0.2) < 1e-6)
    assert(mic.waiting == 0 and len(mic:read()) == 0)
    mic:close()
  }
  t.test("level is the peak since the last look"){
    if(not microphone.available()){
      return null
    }
    local mic = microphone.virtual()
    mic:write(floats({0.25, -0.75, 0.5}))
    assert(math.abs(mic.level - 0.75) < 1e-6)
    assert(mic.level == 0.0, "reading level starts it again")
    mic:close()
  }
  t.test("a full ring loses the oldest frames and counts them"){
    if(not microphone.available()){
      return null
    }
    local mic = microphone.virtual({buffer: 64})
    local samples = buffer.new("float", 100)
    for(local i = 0; i < 100; i = i + 1){
      samples[i] = i
    }
    mic:write(samples)
    assert(mic.waiting == 64 and mic.dropped == 36)
    local out = mic:read()
    assert(out[0] == 36.0 and out[63] == 99.0, "the latest frames stay")
    // around the end of the ring
    mic:write(samples:slice(0, 50))
    mic:write(samples:slice(50, 80))
    out = mic:read()
    assert(len(out) == 64 and out[0] == 16.0 and out[63] == 79.0)
    mic:close()
  }
  t.test("a closed input and a wrong buffer raise"){
    if(not microphone.available()){
      return null
    }
    local mic = microphone.virtual()
    local r = try { mic:read(buffer.new("double", 4)) } catch(e) { e }
    assert(str.contains(string(r), "float"), string(r))
    mic:close()
    r = try { mic.waiting } catch(e) { e }
    assert(str.contains(string(r), "closed"), string(r))
  }
  t.test("devices list and permission answer"){
    for(let local d in values(microphone.devices())){
      assert(type(d.name) == "string" and d.channels > 0)
    }
    local p = microphone.permission()
    assert(
      p == "granted" or p == "denied" or p == "restricted" or
        p == "undetermined" or p == "unknown",
      p,
    )
  }
}
