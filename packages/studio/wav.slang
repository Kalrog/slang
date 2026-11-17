extension "kernel/syntax"
// studio/wav: WAV files in and out.
//
//   local wav = require("studio/wav")
//   local sound = s:render(4000)
//   wav.write("out.wav", {sound.left, sound.right}, 48000)
//
//   local take = wav.read("kick.wav")          // {left, frames, rate, ...}
//   s:track("kit", "sampler", {zones: {{sample: take, root: 36}}})
//
// read takes 16- and 24-bit PCM and 32-bit float files of any channel
// count and rate; write makes 16-bit PCM.
local kernel = require("kernel")
local buffer = require("slang/buffer")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")

local wav = {}

kernel {
  // floats to 16-bit, clipped, interleaved: channel c of ch
  func to_pcm(
    src: float[], dst: int16[], n: int, c: int, ch: int, scale: float
  ){
    for(local i = 0; i < n; i += 1){
      dst[i * ch + c] = int(clamp(src[i] * scale, -1.0, 1.0) * 32767.0)
    }
  }

  func from_int16(src: int16[], dst: double[], n: int){
    for(local i = 0; i < n; i += 1){
      dst[i] = float(src[i]) / 32768.0
    }
  }

  func from_int24(src: uint8[], dst: double[], n: int){
    for(local i = 0; i < n; i += 1){
      local v = src[3 * i] | (src[3 * i + 1] << 8) | (src[3 * i + 2] << 16)
      if(v >= 8388608){
        v -= 16777216
      }
      dst[i] = float(v) / 8388608.0
    }
  }

  func from_float(src: float[], dst: double[], n: int){
    for(local i = 0; i < n; i += 1){
      dst[i] = src[i]
    }
  }

  // channel `which` of ch interleaved channels (-1: all of them mixed),
  // resampled by step (source frames per frame), into dst; returns the
  // frames written
  func channel(
    src: double[], frames: int, ch: int, which: int, step: float, dst: float[]
  ): int {
    local n = min(int(float(frames - 1) / step) + 1, len(dst))
    for(local i = 0; i < n; i += 1){
      local p = float(i) * step
      local j = min(int(p), frames - 1)
      local k = min(j + 1, frames - 1)
      local f = p - float(j)
      local a = 0.0
      local b = 0.0
      if(which < 0){
        for(local c = 0; c < ch; c += 1){
          a += src[j * ch + c]
          b += src[k * ch + c]
        }
        a /= float(ch)
        b /= float(ch)
      } else {
        a = src[j * ch + which]
        b = src[k * ch + which]
      }
      dst[i] = a + (b - a) * f
    }
    return max(n, 0)
  }
}

local func u32(n){
  return str.from_bytes({
    n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255
  })
}

local func u16(n){
  return str.from_bytes({n & 255, (n >> 8) & 255})
}

// write(path: string, channels: {Buffer}, rate: int, options?: WriteOptions)
// The channels' samples (floats -1..1, all as long as the first) as a
// 16-bit PCM file, clipped.
// type WriteOptions = {frames?: int, scale?: number}
// [frames]: how many of the samples; all of them when absent
// [scale]: a gain on the way out; 1 when absent
func wav.write(path, channels, rate, options){
  options = options or {}
  local n = len(channels)
  if(n < 1){
    raise(error.new(error.kinds.argument, "studio/wav: write needs a channel"))
  }
  local frames = options.frames or len(channels[0])
  local pcm = kernel.int16:array(math.max(frames * n, 1))
  for(local c = 0; c < n; c = c + 1){
    to_pcm(channels[c], pcm, frames, c, n, options.scale or 1.0)
  }
  local data = pcm:slice(0, frames * n):to_string()
  local header = concat(
    "RIFF", u32(36 + len(data)), "WAVE", "fmt ", u32(16), u16(1), u16(n),
    u32(rate), u32(rate * n * 2), u16(n * 2), u16(16), "data", u32(len(data))
  )
  os.write_file(path, concat(header, data))
}

local func le(bytes, at, n){
  local v = 0
  for(local i = n - 1; i >= 0; i = i - 1){
    v = (v << 8) | bytes[at + i]
  }
  return v
}

// read(path: string, options?: ReadOptions) -> Sound
// A WAV file's samples. Raises for what is no WAV file or one of a format
// it does not read.
// type ReadOptions = {rate?: int, mono?: bool, shared?: bool}
// [rate]: the samples resampled to this rate (linear); the file's own
//   when absent
// [mono]: every channel mixed into one
// [shared]: false for buffers of this isolate alone; shared by default,
//   so that an engine in the audio stream's isolate can play them
//
// type Sound = {left: Buffer, right?: Buffer, frames: int, rate: int,
//   channels: int}
// [left]: the first (or only, or mixed) channel, floats -1..1
// [right]: the second channel of a file with two or more, unless mono
// [rate]: samples a second of left and right
// [channels]: how many the file has
func wav.read(path, options){
  options = options or {}
  local bytes = buffer.from_string(os.read_file(path))
  local fail = func(why){
    raise(error.new(
      error.kinds.argument,
      concat("studio/wav: ", path, ": ", why),
    ))
  }
  if(len(bytes) < 12 or bytes:slice(0, 4):to_string() != "RIFF" or
    bytes:slice(8, 12):to_string() != "WAVE"){
    fail("not a WAV file")
  }
  local format = null
  local at = 12
  for(at + 8 <= len(bytes)){
    local id = bytes:slice(at, at + 4):to_string()
    local size = le(bytes, at + 4, 4)
    local body = at + 8
    if(id == "fmt "){
      format = {
        code: le(bytes, body, 2),
        channels: le(bytes, body + 2, 2),
        rate: le(bytes, body + 4, 4),
        bits: le(bytes, body + 14, 2),
      }
      if(format.code == 65534 and size >= 26){
        // WAVE_FORMAT_EXTENSIBLE: the sub format's code
        format.code = le(bytes, body + 24, 2)
      }
    } else if(id == "data"){
      if(format == null){
        fail("data before its format")
      }
      local stop = math.min(body + size, len(bytes))
      local raw = bytes:slice(body, stop):copy()
      local width = to_int(format.bits / 8)
      local count = to_int((stop - body) / width)
      local numbers = kernel.double:array(math.max(count, 1))
      if(format.code == 1 and format.bits == 16){
        from_int16(raw:cast(kernel.int16.type), numbers, count)
      } else if(format.code == 1 and format.bits == 24){
        from_int24(raw, numbers, count)
      } else if(format.code == 3 and format.bits == 32){
        from_float(raw:cast(kernel.float.type), numbers, count)
      } else {
        fail(concat(
          "a format it does not read (code ", string(format.code), ", ",
          string(format.bits), " bits)"
        ))
      }
      local ch = format.channels
      local frames = to_int(count / ch)
      local rate = options.rate or format.rate
      local step = format.rate / rate
      local out_frames = math.max(to_int((frames - 1) / step) + 1, 1)
      local make = {shared: options.shared != false}
      local sound = {frames: 0, rate: rate, channels: ch}
      local stereo = ch >= 2 and not options.mono
      sound.left = kernel.float:array(out_frames, make)
      sound.frames = channel(
        numbers, frames, ch, if(stereo or ch == 1){ 0 } else { -1 }, step,
        sound.left
      )
      if(stereo){
        sound.right = kernel.float:array(out_frames, make)
        channel(numbers, frames, ch, 1, step, sound.right)
      }
      return sound
    }
    at = body + size + (size & 1)
  }
  fail("no data")
}

return wav
