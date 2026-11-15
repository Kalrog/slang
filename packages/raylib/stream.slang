// raylib/stream: an audio stream computed in slang, in isolates of its own,
// so that the program's frames, its collector and raylib's audio thread do
// not wait for each other.
//
//   local stream = require("raylib/stream")
//   local player = stream.play(func(freq){
//     local math = require("slang/math")        // a new isolate: it
//     local phase = 0.0                          // requires what it needs
//     return func(out, frames){
//       for(local i = 0; i < frames; i = i + 1){
//         out[i] = math.sin(phase * 2 * math.pi) * 0.2
//         phase = (phase + freq / 48000.0) % 1.0
//       }
//     }
//   }, {args: {440.0}})
//   ...
//   player:stats().load        // the share of real time spent computing
//   player:stop()
//
// Two isolates do the work. The render isolate calls the setup function
// once and the block function it returns again and again, writing blocks of
// samples into a ring a little ahead of the audio device (options.latency
// frames at most). raylib calls its stream callback on its own audio thread,
// which macOS runs on a slow core, and which must never wait: that callback
// runs in the second, the pump isolate, and only copies from the ring. Nothing
// in the main program runs on the audio thread, and the stream needs no
// raylib window.
//
// A block function cannot reach the main program's variables: what it
// needs comes through options.args, copied as isolate.spawn copies its
// arguments. Channels (for events such as notes) and shared buffers (for
// parameters a user turns, read by the block function at every block) cross
// by reference; see slang/isolate and slang/buffer.
local isolate = require("slang/isolate")
local buffer = require("slang/buffer")
local time = require("slang/time")

local stream = {}

// the cells of the shared state buffer (int64): ring positions in frames
// and counters
local WRITE = 0
local READ = 1
local UNDERRUNS = 2
local CALLBACKS = 3
local PLAYING = 4
local STATE_SIZE = 5

// the cells of the shared timing buffer (double)
local RENDERED = 0
local RENDER_SECONDS = 1
local PEAK = 2
local TIMING_SIZE = 3

// The render isolate: blocks into the ring until the stream is stopped
// (the pump closes `wake`).
local func render_loop(setup, args, cfg, ring, state, timing, wake){
  local buffer = require("slang/buffer")
  local time = require("slang/time")
  local block = setup(...args)
  local frames = cfg.block
  local ch = cfg.channels
  local ring_frames = cfg.ring
  local out = buffer.new("float", frames * ch)
  for(true){
    state:lock()
    local filled = state[0] - state[1]
    state:unlock()
    if(filled + frames > cfg.latency){
      // full: wait until the pump takes some (null once it stopped)
      if(wake:receive() == null){
        return null
      }
      continue
    }
    local t0 = time.clock()
    block(out, frames)
    // (seconds, as the load is a share of the audio time)
    local dt = (time.clock() - t0) / 1000
    state:lock()
    local w = state[0]
    state:unlock()
    ring:set(out, (w % ring_frames) * ch)
    state:lock()
    state[0] = w + frames
    state:unlock()
    timing[0] = timing[0] + frames
    timing[1] = timing[1] + dt
    local share = dt * cfg.sample_rate / frames
    if(share > timing[2]){
      timing[2] = share
    }
  }
}

// The pump isolate: opens the audio device and plays a stream whose
// callback copies from the ring, until a message comes on ctl.
local func pump_loop(cfg, ring, state, wake, ctl){
  local rl = require("raylib")
  local buffer = require("slang/buffer")
  local time = require("slang/time")
  local ch = cfg.channels
  local ring_frames = cfg.ring
  rl.audio.open()
  if(not rl.audio.ready){
    wake:close()
    raise(error.new(error.kinds.not_found, "raylib/stream: no audio device"))
  }
  local s = rl.audio_stream.load(cfg.sample_rate, 32, ch)
  // raylib's audio thread calls this; it runs in this isolate, whose own
  // thread waits on ctl meanwhile
  s.callback = func(data, frames){
    local out = buffer.wrap(data, frames * ch, "float")
    state:lock()
    local r = state[1]
    local avail = state[0] - r
    state:unlock()
    local n = frames
    if(avail < n){
      n = avail
    }
    local done = 0
    for(done < n){
      local at = (r + done) % ring_frames
      local run = n - done
      if(at + run > ring_frames){
        run = ring_frames - at
      }
      out:set(ring:slice(at * ch, (at + run) * ch), done * ch)
      done = done + run
    }
    if(n < frames){
      out:slice(n * ch):fill(0.0)
      state[2] = state[2] + 1
    }
    state:lock()
    state[1] = r + n
    state[3] = state[3] + 1
    state:unlock()
    wake:try_send(true)
  }
  // start once the render isolate has filled the ring (or a second passed)
  local t0 = time.clock()
  for(state[0] < cfg.latency - cfg.block and time.clock() - t0 < 1000){
    time.sleep(2)
  }
  s:play()
  state[4] = 1
  ctl:receive()
  s:stop()
  s:unload()
  rl.audio.close()
  wake:close()
  return null
}

// A playing stream, as play returns it. Methods are called with `:`.
// type Player = {stats: func(): Stats, stop: func(), playing: bool}
// [stats]: how the stream is doing since the last call to stats (it
//   starts the next measuring window: load and peak are since then);
//   raises the render isolate's error when the block function failed
// [stop]: stops the stream, closes the audio device and ends both
//   isolates; raises the render isolate's error when it failed
// [playing]: whether the device plays (after the first blocks)
//
// type Stats = {load: float, peak: float, underruns: int,
//   callbacks: int, playing: bool}
// [load]: the time spent in the block function over the audio time it
//   rendered (1.0: as long as the audio lasts, the most it can take)
// [peak]: the same for the slowest block
// [underruns]: callbacks the ring could not fill (heard as clicks); all of
//   them since the start
// [callbacks]: raylib's calls of the stream callback since the start
// [playing]: whether the device plays (after the first blocks)
local player_methods = {}

func player_methods.stats(player){
  local self = player.inner
  if(not self.pump.running and not self.stopped){
    // raises when there is no audio device
    self.pump:join()
  }
  if(not self.render.running){
    // raises the block function's error
    self.render:join()
  }
  local rendered = self.timing[0]
  local seconds = self.timing[1]
  local frames = rendered - self.last_rendered
  local load = 0.0
  if(frames > 0){
    load = (seconds - self.last_seconds) * self.sample_rate / frames
  }
  self.last_rendered = rendered
  self.last_seconds = seconds
  local peak = self.timing[2]
  self.timing[2] = 0.0
  return {
    load: load,
    peak: peak,
    underruns: self.state[2],
    callbacks: self.state[3],
    playing: self.state[4] == 1,
  }
}

func player_methods.stop(player){
  local self = player.inner
  if(self.stopped){
    return null
  }
  self.stopped = true
  self.ctl:send("stop")
  self.pump:join()
  self.render:join()
}

local player_get = {}

// playing(self) -> bool
// Whether the device plays (after the first blocks).
func player_get.playing(p){
  return p.inner.state[4] == 1
}

local player_meta = {
  __type: "raylib.Player",
  __index: player_methods,
  __get: player_get,
}

// ------------------------------------------------------------ one thread
//
// Where there are no isolates (a browser), setup runs in the program's own
// VM and the stream's callback computes the blocks as raylib asks for them.
// In a browser raylib's audio (miniaudio on Web Audio) calls it on the
// page's one thread, between the program's frames, so the program and the
// sound take turns; the device's own buffer is the latency.

local here_methods = {}

func here_methods.stats(player){
  local self = player.inner
  if(self.failed != null){
    raise(self.failed)
  }
  local frames = self.rendered - self.last_rendered
  local load = 0.0
  if(frames > 0){
    load = (self.seconds - self.last_seconds) * self.sample_rate / frames
  }
  self.last_rendered = self.rendered
  self.last_seconds = self.seconds
  local peak = self.peak
  self.peak = 0.0
  return {
    load: load,
    peak: peak,
    underruns: 0,
    callbacks: self.callbacks,
    playing: self.playing,
  }
}

func here_methods.stop(player){
  local self = player.inner
  if(self.stopped){
    return null
  }
  self.stopped = true
  self.stream:stop()
  self.stream:unload()
  require("raylib").audio.close()
  if(self.failed != null){
    raise(self.failed)
  }
}

local here_get = {}

func here_get.playing(p){
  return p.inner.playing
}

local here_meta = {
  __type: "raylib.Player",
  __index: here_methods,
  __get: here_get,
}

local func play_here(setup, args, cfg){
  local rl = require("raylib")
  local block = setup(...args)
  local ch = cfg.channels
  local frames = cfg.block
  rl.audio.open()
  if(not rl.audio.ready){
    raise(error.new(error.kinds.not_found, "raylib/stream: no audio device"))
  }
  local s = rl.audio_stream.load(cfg.sample_rate, 32, ch)
  local inner = {
    stream: s,
    sample_rate: cfg.sample_rate,
    rendered: 0,
    seconds: 0.0,
    peak: 0.0,
    callbacks: 0,
    last_rendered: 0,
    last_seconds: 0.0,
    playing: false,
    stopped: false,
    failed: null,
  }
  // one block computed ahead: what the last call did not take of it
  local out = buffer.new("float", frames * ch)
  local left = 0
  s.callback = func(data, asked){
    local dst = buffer.wrap(data, asked * ch, "float")
    inner.callbacks = inner.callbacks + 1
    if(inner.failed != null){
      dst:fill(0.0)
      return null
    }
    local done = 0
    try {
      for(done < asked){
        if(left == 0){
          local t0 = time.clock()
          block(out, frames)
          local dt = (time.clock() - t0) / 1000
          inner.rendered = inner.rendered + frames
          inner.seconds = inner.seconds + dt
          local share = dt * cfg.sample_rate / frames
          if(share > inner.peak){
            inner.peak = share
          }
          left = frames
        }
        local n = asked - done
        if(n > left){
          n = left
        }
        local from = (frames - left) * ch
        dst:set(out:slice(from, from + n * ch), done * ch)
        done = done + n
        left = left - n
      }
    } catch(local e) {
      // heard as silence; stats and stop raise it
      inner.failed = e
      dst:slice(done * ch):fill(0.0)
    }
  }
  s:play()
  inner.playing = true
  return {@meta: here_meta, inner: inner}
}

// play(setup: function, options?: Options) -> Player
// Starts a stream: setup(...options.args) runs in a new isolate and returns
// the block function, block(out: Buffer, frames: int), which fills out
// (float samples, frames * channels of them, channels interleaved) and is
// called for every block. Like isolate.spawn's function, setup must not
// use locals of the code around it. The stream plays once the first blocks
// are there. Where there are no isolates (a browser) setup runs in this VM
// and the blocks are computed in raylib's audio callback (see "one
// thread" above).
//
// type Options = {sample_rate?: int, channels?: int, block?: int,
//   latency?: int, args?: {any}}
// [sample_rate]: 48000 by default
// [channels]: 1 (mono) by default
// [block]: frames per call of the block function, 128 by default
// [latency]: how far ahead of the device the ring may get, in frames;
//   1024 by default (21 ms at 48000). Smaller reacts sooner to events and
//   underruns sooner when a block takes long.
// [args]: the arguments of setup
func stream.play(setup, options){
  options = options or {}
  local block = options.block or 128
  local latency = options.latency or 1024
  if(latency < block * 2){
    latency = block * 2
  }
  local ring = 1
  for(ring < latency * 2){
    ring = ring * 2
  }
  if(ring % block != 0){
    raise(error.new(error.kinds.argument, concat(
      "raylib/stream: block must divide the ring (",
      ring,
      " frames): use a power of two",
    )))
  }
  local cfg = {
    sample_rate: options.sample_rate or 48000,
    channels: options.channels or 1,
    block: block,
    latency: latency,
    ring: ring,
  }
  if(not isolate.available()){
    return play_here(setup, options.args or {}, cfg)
  }
  local samples = buffer.shared("float", ring * cfg.channels)
  local state = buffer.shared("int64", STATE_SIZE)
  local timing = buffer.shared("double", TIMING_SIZE)
  local wake = isolate.channel({capacity: 1})
  local ctl = isolate.channel()
  local render = isolate.spawn(
    render_loop, setup, options.args or {}, cfg, samples, state, timing, wake
  )
  local pump = isolate.spawn(pump_loop, cfg, samples, state, wake, ctl)
  return {
    @meta: player_meta, inner: {
      render: render,
      pump: pump,
      ctl: ctl,
      state: state,
      timing: timing,
      sample_rate: cfg.sample_rate,
      last_rendered: 0,
      last_seconds: 0.0,
      stopped: false,
    }
  }
}

return stream
