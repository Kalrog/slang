// microphone: audio input from the devices that record (CoreAudio on
// macOS). Samples arrive on the system's audio thread and wait in the
// input's ring until read, so a program can read them once a frame and an
// audio isolate once a block.
//
//   local microphone = require("microphone")
//   microphone.devices()                // {{name: "MacBook Pro Microphone",
//                                       //   channels: 1, default: true, ...}}
//   local mic = microphone.open()       // the default device; or
//                                       // open({device: "USB"}) (part of a
//                                       // name, or an index)
//   local samples = kernel.float:array(512)
//   local n = mic:read(samples)         // frames read (here: up to 512)
//   mic.level                           // the loudest sample since the
//                                       // last look, 0..1
//   mic:close()
//
// Samples are floats (-1..1), channels interleaved, at the rate open was
// asked for (48000 by default: the system converts from the device's own).
// The ring keeps the last options.buffer frames; a reader that falls behind
// loses the oldest (counted in mic.dropped), so it hears the latest sound
// rather than a growing delay. microphone.virtual() is an input without a
// device that the program feeds itself: for tests, or a file played as if
// it were heard.
//
// macOS asks the user once whether the program (the terminal or editor
// that runs slang) may use the microphone; until it may, it records
// silence. microphone.permission() says what the settings say.
local buffer = require("slang/buffer")
local str = require("slang/string")

local microphone = {}

// the native module, where the package has one for this platform
local native = try { require("microphone/native") } catch { null }

// available() -> bool: whether this platform can record
func microphone.available(){
  return native != null
}

// A device that can record, as devices lists it.
// type Device = {name: string, uid: string, channels: int,
//   sample_rate: float, default: bool}
// [name]: what the system calls it
// [uid]: the system's id of it, which stays the same across restarts
// [channels]: how many channels it records
// [sample_rate]: the rate it runs at (open converts to the rate asked)
// [default]: whether it is the system's default input

// devices() -> {Device}: the devices that can record, in the order open
// takes an index in
func microphone.devices(){
  if(native == null){
    return {}
  }
  return native.devices()
}

// permission() -> string: "granted", "denied", "restricted" (by a policy),
// "undetermined" (macOS asks when recording starts) or "unknown"
func microphone.permission(){
  if(native == null){
    return "unknown"
  }
  return native.permission()
}

// An open input. Methods are called with `:`; level, waiting, dropped and
// the rest are properties.
// type Input = {read: func(out?: Buffer): any, write: func(samples: Buffer): int,
//   close: func(), level: float, waiting: int, dropped: int, name: string,
//   sample_rate: int, channels: int}
// [read]: with a float buffer, fills it with the frames that wait (as many
//   as fit) and returns how many; without, returns a new float buffer of
//   all that wait
// [write]: puts the frames of a float buffer into the ring, as if they
//   had been recorded; returns how many
// [close]: stops recording (an input that is collected stops too)
// [level]: the loudest sample since the last time level was read, 0..1
// [waiting]: frames ready to read
// [dropped]: frames lost because the ring was full, since open
// [name]: the device's name ("virtual" for a virtual input)
// [sample_rate]: the rate of the samples read
// [channels]: how many channels a frame has
local input_methods = {}
local input_get = {}

func input_methods.read(self, out){
  if(out == null){
    out = buffer.new("float", native.waiting(self.handle) * self.channels)
    local n = native.read(self.handle, out)
    return out:slice(0, n * self.channels)
  }
  return native.read(self.handle, out)
}

func input_methods.write(self, samples){
  return native.write(self.handle, samples)
}

func input_methods.close(self){
  native.close(self.handle)
}

// level(self) -> float
func input_get.level(self){
  return native.level(self.handle)
}

// waiting(self) -> int
func input_get.waiting(self){
  return native.waiting(self.handle)
}

// dropped(self) -> int
func input_get.dropped(self){
  return native.dropped(self.handle)
}

// type microphone.Input
local input_meta = {
  __type: "microphone.Input",
  __index: input_methods,
  __get: input_get,
}

// The options of open and virtual.
// type Options = {device?: any, sample_rate?: int, channels?: int,
//   buffer?: int}
// [device]: an index into devices(), or a part of a device's name
//   (ignoring case); the system's default input when null
// [sample_rate]: of the samples read, 48000 by default
// [channels]: of the samples read, 1 by default (the system mixes or
//   copies the device's channels to these)
// [buffer]: frames the ring holds before the oldest go; two seconds by
//   default

local func settings(options){
  options = options or {}
  local rate = options.sample_rate or 48000
  return {
    rate: rate,
    channels: options.channels or 1,
    frames: options.buffer or rate * 2,
  }
}

local func unsupported(){
  raise(error.new(
    error.kinds.unsupported,
    "microphone: no audio input on this platform",
  ))
}

// open(options?: Options) -> Input
// Starts recording from a device. Raises an error of kind not_found when
// options.device names none, of kind unsupported when this platform cannot
// record (see available).
func microphone.open(options){
  if(native == null){
    unsupported()
  }
  local s = settings(options)
  local which = if(options != null){ options.device } else { null }
  local devices = native.devices()
  local device = null
  if(type(which) == "int"){
    device = devices[which]
  } else if(which != null){
    for(let local d in values(devices)){
      if(device == null and str.contains(str.lower(d.name), str.lower(which))){
        device = d
      }
    }
  } else {
    for(let local d in values(devices)){
      if(d.default){
        device = d
      }
    }
    if(device == null and len(devices) == 0){
      raise(error.new(
        error.kinds.not_found,
        "microphone: there is no device that records",
      ))
    }
  }
  if(which != null and device == null){
    local names = {}
    for(let local d in values(devices)){
      append(names, d.name)
    }
    raise(error.new(
      error.kinds.not_found,
      concat(
        "microphone: no device is called ", string(which), " (there are: ",
        str.join(names, ", "), ")"
      ),
      {name: which},
    ))
  }
  local uid = if(which == null){ "" } else { device.uid }
  return {
    handle: native.open(uid, s.rate, s.channels, s.frames),
    name: if(device != null){ device.name } else { "default" },
    sample_rate: s.rate,
    channels: s.channels,
    @meta: input_meta,
  }
}

// virtual(options?: Options) -> Input
// An input with no device: what write puts in is what read takes out
// (options.device is ignored).
func microphone.virtual(options){
  if(native == null){
    unsupported()
  }
  local s = settings(options)
  return {
    handle: native.virtual(s.rate, s.channels, s.frames),
    name: "virtual",
    sample_rate: s.rate,
    channels: s.channels,
    @meta: input_meta,
  }
}

return microphone
