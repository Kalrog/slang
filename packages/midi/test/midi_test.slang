local t = require("slang/test")
local os = require("slang/os")
local midi = require("midi")
local map_mod = require("midi/map")

// Decoding, the byte parser of the native module, and MIDI learn's map;
// none of them needs a device.

t.group("midi"){
  t.test("messages decode by kind, channel and values"){
    local m = midi.decode(0x90 | (60 << 8) | (100 << 16))
    assert(m.kind == "note_on" and m.channel == 1 and m.note == 60 and m.velocity == 100)
    m = midi.decode(0x93 | (60 << 8))
    assert(m.kind == "note_off" and m.channel == 4, "velocity 0 is an off")
    m = midi.decode(0xB0 | (74 << 8) | (127 << 16))
    assert(m.kind == "cc" and m.controller == 74 and m.value == 127)
    // pitch bend: 14 bits around 8192
    assert(midi.decode(0xE0 | (0 << 8) | (64 << 16)).value == 0.0)
    assert(midi.decode(0xE0).value == -1.0)
    m = midi.decode(0xC5 | (12 << 8))
    assert(m.kind == "program" and m.channel == 6 and m.program == 12)
  }
  t.test("bytes become messages: running status, sysex and clock skipped"){
    if(not midi.available()){
      return null
    }
    local native = require("midi/native")
    local str = require("slang/string")
    // a note on, two more by running status (one with a clock byte in
    // the middle), a sysex, a cc
    local bytes = str.from_bytes({0x90, 60, 100, 62, 0xF8, 90, 64, 0, 0xF0, 1, 2, 3, 0xF7, 0xB1, 7, 99})
    local words = native.parse(bytes)
    assert(len(words) == 4, string(len(words)))
    assert(midi.decode(words[1]).note == 62 and midi.decode(words[1]).velocity == 90)
    assert(midi.decode(words[2]).kind == "note_off")
    local cc = midi.decode(words[3])
    assert(cc.kind == "cc" and cc.channel == 2 and cc.value == 99)
  }
  t.test("inputs list and open where there is MIDI"){
    if(not midi.available()){
      return null
    }
    assert(type(midi.inputs()) == "table")
    local input = midi.open()
    assert(len(input:read()) >= 0)
    input:close()
    local r = pcall(func(){ midi.open("no such controller anywhere") })
    assert(r[0] == "err")
  }
  t.test("MIDI learn: arm, bind on the next controller, rebind, save"){
    local path = "test/_map.json"
    if(os.exists(path)){
      os.remove(path)
    }
    local map = map_mod.load(path)
    local cc = func(ch, n){ return {kind: "cc", channel: ch, controller: n, value: 10} }
    assert(map:target(cc(1, 21)) == null, "nothing bound yet")
    map:arm("cutoff")
    assert(map:target(cc(1, 21)) == "cutoff" and map.armed == null)
    assert(map:binding("cutoff") == "CC 21")
    // the target moves to another controller
    map:arm("cutoff")
    map:target(cc(2, 22))
    assert(map:binding("cutoff") == "CC 22/2" and map:target(cc(1, 21)) == null)
    // saved: a new map reads the same
    assert(map_mod.load(path):binding("cutoff") == "CC 22/2")
    map:clear("cutoff")
    assert(map_mod.load(path):binding("cutoff") == null)
    os.remove(path)
  }
}
