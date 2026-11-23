// window/audio: sound through SDL3's audio: streams computed in slang,
// sounds (WAV files or samples) SDL mixes, and microphones. No window is
// needed.
//
//   local audio = require("window/audio")
//   local player = audio.play(func(freq){
//     local math = require("slang/math")        // a new isolate: it
//     local phase = 0.0                          // requires what it needs
//     return func(out, frames){
//       for(local i = 0; i < frames; i = i + 1){
//         out[i] = math.sin(phase * 2 * math.pi) * 0.2
//         phase = (phase + freq / 48000.0) % 1.0
//       }
//     }
//   }, {args: {440.0}})
//   local hit = audio.sound("hit.wav")
//   hit:play({volume: 0.5})
//   ...
//   player:stop()
//
// A stream's blocks are computed in an isolate of their own, which pushes
// them into an SDL audio stream until SDL holds options.latency frames.
// SDL keeps that buffer and its audio thread only copies from it, so no
// slang runs on the audio thread, and the program's frames and its
// collector never hold up the sound. The API is raylib/stream's: block
// functions written for it play here unchanged.
//
// A block function cannot reach the main program's variables: what it
// needs comes through options.args, copied as isolate.spawn copies its
// arguments. Channels (for events such as notes) and shared buffers (for
// parameters, read at every block) cross by reference; see slang/isolate
// and slang/buffer.
local ffi = require("slang/ffi")
local isolate = require("slang/isolate")
local buffer = require("slang/buffer")
local math = require("slang/math")
local str = require("slang/string")
local sdl = require("window/sdl")
local C = sdl.C
local lib = sdl.lib
local K = sdl.K

local audio = {}

local func fail(what){
  raise(concat("window/audio: ", what, ": ", lib.SDL_GetError()))
}

local func check(ok, what){
  if(not ok){
    fail(what)
  }
}

local initialized = false
local func init(){
  if(not initialized){
    check(lib.SDL_InitSubSystem(K.SDL_INIT_AUDIO), "SDL_InitSubSystem")
    initialized = true
  }
}

// ------------------------------------------------------------ streams

// the cells of the shared state buffer (int64)
local UNDERRUNS = 0
local BLOCKS = 1
local PLAYING = 2
local STATE_SIZE = 3

// the cells of the shared timing buffer (double)
local RENDERED = 0
local RENDER_MS = 1
local PEAK = 2
local TIMING_SIZE = 3

// The render isolate: computes blocks and puts them into the SDL stream at
// address until SDL holds cfg.latency frames, until a message comes on ctl.
local func render_loop(setup, args, cfg, address, state, timing, ctl){
  local ffi = require("slang/ffi")
  local buffer = require("slang/buffer")
  local time = require("slang/time")
  local sdl = require("window/sdl")
  local lib = sdl.lib
  local stream = ffi.cast(address, "SDL_AudioStream", sdl.C)
  local block = setup(...args)
  local frames = cfg.block
  local out = buffer.new("float", frames * cfg.channels)
  local bytes = out.size
  local latency = cfg.latency * cfg.channels * 4
  local started = false
  // how long to sleep when SDL holds enough: a quarter block
  local nap = frames * 1000.0 / cfg.sample_rate / 4
  for(ctl:try_receive() == null){
    local queued = lib.SDL_GetAudioStreamQueued(stream)
    if(queued + bytes > latency){
      if(not started){
        lib.SDL_ResumeAudioStreamDevice(stream)
        started = true
        state[2] = 1
      }
      time.sleep(nap)
    } else {
      if(started and queued == 0){
        state[0] = state[0] + 1
      }
      local t0 = time.clock()
      block(out, frames)
      local ms = time.clock() - t0
      lib.SDL_PutAudioStreamData(stream, out, bytes)
      state[1] = state[1] + 1
      timing[0] = timing[0] + frames
      timing[1] = timing[1] + ms
      local share = ms / 1000 * cfg.sample_rate / frames
      if(share > timing[2]){
        timing[2] = share
      }
    }
  }
  return null
}

local player_methods = {}
local player_get = {}
local player_set = {}

// A playing stream, as [play] returns it.
// type Player
local player_meta = {
  __type: "window.Player",
  __index: player_methods,
  __get: player_get,
  __set: player_set,
}

// stats() -> Stats
// How the stream is doing since the last call to stats (it starts the next
// measuring window: load and peak are since then); raises the render
// isolate's error when the block function failed.
// type Stats = {load: number, peak: number, underruns: int, blocks: int,
//   playing: bool}
// [load]: time spent in the block function over the audio time it
//   rendered (1.0: as long as the audio lasts, the most it can take)
// [peak]: the same for the slowest block
// [underruns]: times SDL ran dry (heard as clicks), since the start
// [blocks]: blocks computed since the start
// [playing]: whether the device plays (after the first blocks)
func player_methods.stats(self){
  if(not self.render.running and not self.stopped){
    // raises the block function's error
    self.render:join()
  }
  local rendered = self.timing[RENDERED]
  local ms = self.timing[RENDER_MS]
  local frames = rendered - self.last_rendered
  local load = 0.0
  if(frames > 0){
    load = (ms - self.last_ms) / 1000 * self.sample_rate / frames
  }
  self.last_rendered = rendered
  self.last_ms = ms
  local peak = self.timing[PEAK]
  self.timing[PEAK] = 0.0
  return {
    load: load,
    peak: peak,
    underruns: self.state[UNDERRUNS],
    blocks: self.state[BLOCKS],
    playing: self.state[PLAYING] == 1,
  }
}

// stop()
// Stops the stream and ends its isolate; raises the block function's
// error when it failed. Stopping twice does nothing.
func player_methods.stop(self){
  if(self.stopped){
    return null
  }
  self.stopped = true
  self.ctl:send("stop")
  local failed = null
  try {
    self.render:join()
  } catch(local e) {
    failed = e
  }
  lib.SDL_DestroyAudioStream(self.stream)
  self.state[PLAYING] = 0
  if(failed != null){
    raise(failed)
  }
}

// playing(self) -> bool
// Whether the device plays the stream (after its first blocks, until stop).
func player_get.playing(self){
  return self.state[PLAYING] == 1
}

// volume(self) -> number
// The stream's gain (1 by default); settable.
func player_get.volume(self){
  return self.gain
}
func player_set.volume(self, v){
  check(lib.SDL_SetAudioStreamGain(self.stream, v), "volume")
  self.gain = v
}

// play(setup: function, options?: PlayOptions) -> Player
// Starts a stream: setup(...options.args) runs in a new isolate and returns
// the block function, block(out: Buffer, frames: int), which fills out
// (float samples, frames * channels of them, channels interleaved) and is
// called for every block. Like isolate.spawn's function, setup must not
// use locals of the code around it. The stream plays once the first blocks
// are there.
// type PlayOptions = {sample_rate?: int, channels?: int, block?: int,
//   latency?: int, args?: {any}}
// [sample_rate]: 48000 by default (SDL converts to the device's rate)
// [channels]: 1 (mono) by default
// [block]: frames per call of the block function, 128 by default
// [latency]: how many frames SDL is given ahead of the device; 1024 by
//   default (21 ms at 48000), and never less than two of the device's own
//   buffers and a block. Smaller reacts sooner to events and runs dry
//   sooner when a block takes long.
// [args]: the arguments of setup
func audio.play(setup, options){
  options = options or {}
  if(not isolate.available()){
    raise(error.new(
      error.kinds.unsupported,
      "window/audio: streams need isolates",
    ))
  }
  init()
  local cfg = {
    sample_rate: options.sample_rate or 48000,
    channels: options.channels or 1,
    block: options.block or 128,
    latency: options.latency or 1024,
  }
  if(cfg.latency < cfg.block * 2){
    cfg.latency = cfg.block * 2
  }
  local stream = lib.SDL_OpenAudioDeviceStream(
    K.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
    {
      format: K.SDL_AUDIO_F32,
      channels: cfg.channels,
      freq: cfg.sample_rate,
    },
    null,
    null,
  )
  if(stream == null){
    fail("SDL_OpenAudioDeviceStream")
  }
  // SDL's device takes a buffer of its own at a time: hold at least two of
  // them (in this stream's frames) and a block, or the stream runs dry
  // between the device's pulls
  local spec = ffi.new("SDL_AudioSpec", 1, C)
  local device_frames = ffi.new("int", 1, C)
  if(lib.SDL_GetAudioDeviceFormat(
    lib.SDL_GetAudioStreamDevice(stream), spec, device_frames
  )){
    local pull = math.ceil(device_frames[0] * cfg.sample_rate / spec.freq) | 0
    if(cfg.latency < pull * 2 + cfg.block){
      cfg.latency = pull * 2 + cfg.block
    }
  }
  local state = buffer.shared("int64", STATE_SIZE)
  local timing = buffer.shared("double", TIMING_SIZE)
  local ctl = isolate.channel()
  local render = isolate.spawn(
    render_loop, setup, options.args or {}, cfg, ffi.address(stream), state,
    timing, ctl
  )
  local p = {
    stream: stream,
    render: render,
    ctl: ctl,
    state: state,
    timing: timing,
    sample_rate: cfg.sample_rate,
    last_rendered: 0,
    last_ms: 0.0,
    gain: 1.0,
    stopped: false,
  }
  p.@meta = player_meta
  return p
}

// ------------------------------------------------------------ sounds

// the device sounds play on, opened on first use, and its format
local device = 0
local device_spec = null
local func the_device(){
  if(device == 0){
    init()
    device = lib.SDL_OpenAudioDevice(K.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, null)
    if(device == 0){
      fail("SDL_OpenAudioDevice")
    }
    local spec = ffi.new("SDL_AudioSpec", 1, C)
    local frames = ffi.new("int", 1, C)
    check(
      lib.SDL_GetAudioDeviceFormat(device, spec, frames),
      "SDL_GetAudioDeviceFormat",
    )
    device_spec = ffi.value(spec)
  }
  return device
}

// voices still playing, kept from the collector until they end
local voices = {}

// ends the voices that have played out
local func prune(){
  local still = {}
  for(let local v in values(voices)){
    if(v.stream != null){
      if(lib.SDL_GetAudioStreamQueued(v.stream) == 0){
        lib.SDL_DestroyAudioStream(v.stream)
        v.stream = null
      } else {
        append(still, v)
      }
    }
  }
  voices = still
}

local voice_methods = {}
local voice_get = {}
local voice_set = {}

// One playing of a sound, as [Sound.play] returns it.
// type Voice
local voice_meta = {
  __type: "window.Voice",
  __index: voice_methods,
  __get: voice_get,
  __set: voice_set,
}

// stop()
// Stops the voice now.
func voice_methods.stop(self){
  if(self.stream != null){
    lib.SDL_DestroyAudioStream(self.stream)
    self.stream = null
  }
}

// playing(self) -> bool
// Whether the voice is still playing.
func voice_get.playing(self){
  prune()
  return self.stream != null
}

// volume(self) -> number
// The voice's gain (1: as recorded); settable while it plays.
func voice_get.volume(self){
  return self.gain
}
func voice_set.volume(self, v){
  self.gain = v
  if(self.stream != null){
    lib.SDL_SetAudioStreamGain(self.stream, v)
  }
}

// pitch(self) -> number
// The playback speed (1: as recorded; 2: an octave up and twice as fast);
// settable while it plays.
func voice_get.pitch(self){
  return self.ratio
}
func voice_set.pitch(self, v){
  self.ratio = v
  if(self.stream != null){
    lib.SDL_SetAudioStreamFrequencyRatio(self.stream, v)
  }
}

// A sound in memory: a WAV file's or computed samples. Play it as often as
// needed, overlapping: SDL mixes the voices.
// type Sound
// [sample_rate]: its frames per second
// [channels]: 1 (mono) or 2 (stereo)
// [frames]: its length in frames
// [duration]: its length in milliseconds
local sound_methods = {}
local sound_meta = {__type: "window.Sound", __index: sound_methods}

// play(options?: {volume?: number, pitch?: number, loop?: int}) -> Voice
// Plays the sound from the start.
// [volume]: gain, 1 by default
// [pitch]: playback speed, 1 by default
// [loop]: how many times to play it in a row (1 by default)
func sound_methods.play(self, options){
  options = options or {}
  prune()
  local dev = the_device()
  local stream = lib.SDL_CreateAudioStream(self.spec, device_spec)
  if(stream == null){
    fail("SDL_CreateAudioStream")
  }
  local v = {
    stream: stream,
    gain: options.volume or 1.0,
    ratio: options.pitch or 1.0,
  }
  v.@meta = voice_meta
  if(v.gain != 1.0){
    lib.SDL_SetAudioStreamGain(stream, v.gain)
  }
  if(v.ratio != 1.0){
    lib.SDL_SetAudioStreamFrequencyRatio(stream, v.ratio)
  }
  for(local i = 0; i < (options.loop or 1); i = i + 1){
    check(lib.SDL_PutAudioStreamData(stream, self.data, self.bytes), "play")
  }
  check(lib.SDL_FlushAudioStream(stream), "play")
  check(lib.SDL_BindAudioStream(dev, stream), "play")
  append(voices, v)
  return v
}

local func make_sound(spec, data, bytes, keep){
  local sample_bytes = 4
  if(spec.format == K.SDL_AUDIO_U8){
    sample_bytes = 1
  } else if(spec.format == K.SDL_AUDIO_S16){
    sample_bytes = 2
  }
  local frames = (bytes / (sample_bytes * spec.channels)) | 0
  local s = {
    spec: spec,
    data: data,
    bytes: bytes,
    keep: keep,
    sample_rate: spec.freq,
    channels: spec.channels,
    frames: frames,
    duration: frames * 1000.0 / spec.freq,
  }
  s.@meta = sound_meta
  return s
}

// sound(source: string | buffer, options?: SoundOptions) -> Sound
// A sound from a WAV file (a path), or from float samples (a slang/buffer
// of "float", channels interleaved, between -1 and 1).
//   local hit = audio.sound("hit.wav")
//   local beep = audio.sound(samples, {sample_rate: 48000})
// type SoundOptions = {sample_rate?: int, channels?: int}
// [sample_rate], [channels]: of the samples (48000 and 1 by default)
func audio.sound(source, options){
  options = options or {}
  init()
  if(type(source) == "string"){
    local spec = ffi.new("SDL_AudioSpec", 1, C)
    local data = ffi.new("Uint8 *", 1, C)
    local size = ffi.new("Uint32", 1, C)
    check(
      lib.SDL_LoadWAV(source, spec, data, size),
      concat("cannot load ", source),
    )
    local p = ffi.gc(data[0], lib.SDL_free)
    return make_sound(ffi.value(spec), p, size[0], p)
  }
  if(not buffer.is(source)){
    raise(
      "window/audio: a sound is a WAV file's path or a buffer of float samples",
    )
  }
  local samples = source:copy()
  return make_sound({
    format: K.SDL_AUDIO_F32,
    channels: options.channels or 1,
    freq: options.sample_rate or 48000,
  }, samples:pointer(), samples.size, samples)
}

// stop_all()
// Stops every sound playing (streams from [play] go on).
func audio.stop_all(){
  for(let local v in values(voices)){
    voice_methods.stop(v)
  }
  voices = {}
}

// ------------------------------------------------------------ microphones

// microphones() -> {MicrophoneInfo}
// The devices that record, in SDL's order (an index into this list, or a
// part of a name, picks one for [microphone]).
// type MicrophoneInfo = {name: string, id: int}
func audio.microphones(){
  init()
  local count = ffi.new("int", 1, C)
  local ids = lib.SDL_GetAudioRecordingDevices(count)
  local out = {}
  if(ids == null){
    return out
  }
  for(local i = 0; i < count[0]; i = i + 1){
    append(out, {name: lib.SDL_GetAudioDeviceName(ids[i]) or "", id: ids[i]})
  }
  lib.SDL_free(ids)
  return out
}

local mic_methods = {}
local mic_get = {}

// A microphone, as [microphone] or [virtual_microphone] opens it: what it
// recorded waits (up to options.buffer frames, the oldest dropped first)
// until [Microphone.read] takes it.
// type Microphone
// [name]: the device's name ("virtual" for a virtual one)
// [sample_rate]: frames per second of what read gives
// [channels]: samples per frame, interleaved
// [dropped]: frames lost because nobody read them in time
local mic_meta = {
  __type: "window.Microphone",
  __index: mic_methods,
  __get: mic_get,
}

local func open_mic(stream, name, options){
  local channels = options.channels or 1
  local m = {
    stream: stream,
    name: name,
    sample_rate: options.sample_rate or 48000,
    channels: channels,
    // the most bytes kept waiting (two seconds by default)
    limit: (options.buffer or (options.sample_rate or 48000) * 2) * channels * 4,
    scratch: null,
    peak: 0.0,
    dropped: 0,
    closed: false,
  }
  m.@meta = mic_meta
  return m
}

// microphone(options?: MicrophoneOptions) -> Microphone
// Starts recording from a device, the system's default unless
// options.device names another. SDL converts to the rate and channels
// asked for. Raises when there is no such device or it cannot record
// (macOS asks the user once whether the program may use the microphone,
// and records silence until it may).
//   local mic = audio.microphone({sample_rate: 48000})
//   local samples = buffer.new("float", 960)
//   local frames = mic:read(samples)         // each tick
// type MicrophoneOptions = {device?: int | string, sample_rate?: int,
//   channels?: int, buffer?: int}
// [device]: an index into [microphones], or a part of a device's name
//   (any case)
// [sample_rate]: 48000 by default
// [channels]: 1 by default
// [buffer]: the most frames kept until read (two seconds by default)
func audio.microphone(options){
  options = options or {}
  init()
  local id = K.SDL_AUDIO_DEVICE_DEFAULT_RECORDING
  local name = null
  if(options.device != null){
    local all = audio.microphones()
    local found = null
    if(type(options.device) == "int"){
      found = all[options.device]
    } else {
      local want = str.lower(string(options.device))
      for(let local d in values(all)){
        if(found == null and str.contains(str.lower(d.name), want)){
          found = d
        }
      }
    }
    if(found == null){
      raise(error.new(error.kinds.not_found, concat(
        "window/audio: no microphone ", string(options.device),
      )))
    }
    id = found.id
    name = found.name
  }
  local stream = lib.SDL_OpenAudioDeviceStream(id, {
    format: K.SDL_AUDIO_F32,
    channels: options.channels or 1,
    freq: options.sample_rate or 48000,
  }, null, null)
  if(stream == null){
    fail("cannot open the microphone")
  }
  if(name == null){
    name = lib.SDL_GetAudioDeviceName(lib.SDL_GetAudioStreamDevice(stream)) or ""
  }
  check(lib.SDL_ResumeAudioStreamDevice(stream), "cannot start the microphone")
  return open_mic(stream, name, options)
}

// virtual_microphone(options?: MicrophoneOptions) -> Microphone
// A microphone without a device: what [Microphone.write] puts in, read
// takes out (tests, bots, a file played in). options.device is ignored.
func audio.virtual_microphone(options){
  options = options or {}
  init()
  local spec = {
    format: K.SDL_AUDIO_F32,
    channels: options.channels or 1,
    freq: options.sample_rate or 48000,
  }
  local stream = lib.SDL_CreateAudioStream(spec, spec)
  if(stream == null){
    fail("SDL_CreateAudioStream")
  }
  local m = open_mic(stream, "virtual", options)
  m.virtual = true
  return m
}

// read(out?: Buffer) -> int | Buffer
// Takes what waits: into out (a buffer of floats; as many whole frames as
// fit) and returns the frames read, or, without out, returns all of it as
// a new buffer.
func mic_methods.read(self, out){
  if(self.closed){
    raise("window/audio: the microphone is closed")
  }
  local frame_bytes = self.channels * 4
  local available = lib.SDL_GetAudioStreamAvailable(self.stream)
  // too much waiting: the oldest goes
  if(available > self.limit){
    local extra = available - self.limit
    extra = extra - extra % frame_bytes
    if(self.scratch == null or self.scratch.size < extra){
      self.scratch = buffer.new("float", (extra / 4) | 0)
    }
    lib.SDL_GetAudioStreamData(self.stream, self.scratch, extra)
    self.dropped = self.dropped + ((extra / frame_bytes) | 0)
    available = available - extra
  }
  local result = null
  if(out == null){
    out = buffer.new("float", (available / 4) | 0)
    result = out
  }
  local bytes = out.size
  if(bytes > available){
    bytes = available
  }
  bytes = bytes - bytes % frame_bytes
  local got = 0
  if(bytes > 0){
    got = lib.SDL_GetAudioStreamData(self.stream, out, bytes)
    if(got < 0){
      fail("cannot read the microphone")
    }
  }
  local samples = (got / 4) | 0
  local peak = self.peak
  for(local i = 0; i < samples; i = i + 1){
    local v = out[i]
    if(v < 0){
      v = -v
    }
    if(v > peak){
      peak = v
    }
  }
  self.peak = peak
  if(result != null){
    return result
  }
  return (samples / self.channels) | 0
}

// write(samples: Buffer)
// A virtual microphone's input: float samples, channels interleaved.
func mic_methods.write(self, samples){
  if(not self.virtual){
    raise("window/audio: only a virtual microphone takes write")
  }
  check(lib.SDL_PutAudioStreamData(self.stream, samples, samples.size), "write")
}

// close()
// Stops recording. Closing twice does nothing.
func mic_methods.close(self){
  if(not self.closed){
    self.closed = true
    lib.SDL_DestroyAudioStream(self.stream)
  }
}

// level(self) -> number
// The loudest sample read since level was last looked at, 0 to 1.
func mic_get.level(self){
  local p = self.peak
  self.peak = 0.0
  return p
}

// waiting(self) -> int
// Frames recorded and not read yet.
func mic_get.waiting(self){
  if(self.closed){
    return 0
  }
  return (lib.SDL_GetAudioStreamAvailable(self.stream) / (self.channels * 4)) | 0
}

// ------------------------------------------------------------ the device

local module_get = {}
local module_set = {}

// volume(self) -> number
// The gain of every sound on the device (1 by default); settable.
func module_get.volume(self){
  return lib.SDL_GetAudioDeviceGain(the_device())
}
func module_set.volume(self, v){
  check(lib.SDL_SetAudioDeviceGain(the_device(), v), "volume")
}

// driver(self) -> string
// SDL's audio driver ("coreaudio", "pipewire", "wasapi", ...).
func module_get.driver(self){
  init()
  return lib.SDL_GetCurrentAudioDriver() or ""
}

// device_name(self) -> string
// The name of the device sounds play on.
func module_get.device_name(self){
  return lib.SDL_GetAudioDeviceName(the_device()) or ""
}

audio.@meta = {__type: "window.audio", __get: module_get, __set: module_set}

return audio
