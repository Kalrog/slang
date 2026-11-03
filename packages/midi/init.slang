// midi: MIDI input from the controllers and programs the system knows
// (CoreMIDI on macOS). Messages arrive on the system's MIDI thread and wait
// in the input until read, so a program can read them once a frame and an
// audio isolate once a block.
//
//   local midi = require("midi")
//   midi.inputs()                       // {"Arturia KeyStep 37", ...}
//   local input = midi.open()           // every source; or an index, or
//                                       // a part of a name: open("KeyStep")
//   for(let local m in values(input:read())){
//     if(m.kind == "note_on"){ play(m.note, m.velocity) }
//   }
//   input:close()
//
// A message is {kind, channel (1..16), ...}:
//   note_on {note, velocity}       note_off {note, velocity} (a note on
//                                  with velocity 0 is a note off)
//   cc {controller, value}         bend {value: -1..1}
//   program {program}              pressure {value} (channel)
//   aftertouch {note, value}       (polyphonic)
// values 0..127 except bend. midi/file reads Standard MIDI Files, midi/map
// binds controllers to a program's controls (MIDI learn).
local buffer = require("slang/buffer")
local str = require("slang/string")

local midi = {}

// the native module, where the package has one for this platform
local loaded = pcall(func(){ return require("midi/native") })
local native = null
if(loaded[0] == "ok"){
  native = loaded[1]
}

// available() -> bool: whether this platform has MIDI input
func midi.available(){
  return native != null
}

// inputs() -> {string}: the sources' names, in the order open takes them
func midi.inputs(){
  if(native == null){
    return {}
  }
  return native.sources()
}

// decode(word: int) -> Message: one message as the native module packs it
// (status | data1 << 8 | data2 << 16)
func midi.decode(w){
  local status = w & 255
  local d1 = (w >> 8) & 127
  local d2 = (w >> 16) & 127
  local kind = status >> 4
  local ch = (status & 15) + 1
  if(kind == 9 and d2 > 0){
    return {kind: "note_on", channel: ch, note: d1, velocity: d2}
  }
  if(kind == 8 or kind == 9){
    return {kind: "note_off", channel: ch, note: d1, velocity: d2}
  }
  if(kind == 11){
    return {kind: "cc", channel: ch, controller: d1, value: d2}
  }
  if(kind == 14){
    local v = (d1 | (d2 << 7)) - 8192
    return {kind: "bend", channel: ch, value: v / 8192}
  }
  if(kind == 12){
    return {kind: "program", channel: ch, program: d1}
  }
  if(kind == 13){
    return {kind: "pressure", channel: ch, value: d1}
  }
  if(kind == 10){
    return {kind: "aftertouch", channel: ch, note: d1, value: d2}
  }
  return {kind: "system", status: status, data1: d1, data2: d2}
}

// An open input. Methods are called with `:`.
// type Input = {read: func(): {Message}, close: func(), name: string}
// [read]: the messages since the last read, oldest first
// [close]: disconnects it
// [name]: what it listens to (a source's name, or "all")
local input_methods = {}
local input_meta = {__type: "midi.Input", __index: input_methods}

func input_methods.read(self){
  local out = {}
  for(true){
    local n = native.read(self.handle, self.words)
    for(local i = 0; i < n; i = i + 1){
      append(out, midi.decode(self.words[i]))
    }
    if(n < len(self.words)){
      return out
    }
  }
}

func input_methods.close(self){
  native.close(self.handle)
}

// open(which?: int | string) -> Input
// Every source (which null), the source of an index, or the first whose
// name contains which (ignoring case). Raises when there is none, or when
// this platform has no MIDI input (see available).
func midi.open(which){
  if(native == null){
    error("midi: no MIDI input on this platform")
  }
  local index = -1
  local name = "all"
  if(type(which) == "int"){
    index = which
    name = midi.inputs()[which] or "?"
  } else if(which != null){
    local names = midi.inputs()
    for(local i = len(names) - 1; i >= 0; i = i - 1){
      if(str.contains(str.lower(names[i]), str.lower(which))){
        index = i
        name = names[i]
      }
    }
    if(index < 0){
      error(concat("midi: no input is called ", which, " (there are: ", str.join(names, ", "), ")"))
    }
  }
  return {handle: native.open(index), words: buffer.new("uint32", 256), name: name, meta: input_meta}
}

return midi
