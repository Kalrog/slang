// sample: what the grains are cut from. WAV files in and out (16- and
// 24-bit PCM and 32-bit float, any channel count mixed to mono, any rate
// made 48 kHz), and a demo sample made here for when nothing has been
// recorded yet.
//
//   local sample = require("sample")
//   local n = sample.load("take.wav", buf)     // frames now in buf
//   sample.save("take.wav", buf, n)
//   local n = sample.demo(buf)
extension "kernel/syntax"
local kernel = require("kernel")
local buffer = require("slang/buffer")
local os = require("slang/os")
local str = require("slang/string")
local math = require("slang/math")

local sample = {}

sample.RATE = 48000

kernel {
  // floats to 16-bit, clipped
  func to_pcm(src: float[], dst: int16[], n: int){
    for(local i = 0; i < n; i += 1){
      dst[i] = int(clamp(src[i], -1.0, 1.0) * 32767.0)
    }
  }

  // frames of ch interleaved channels (scaled ints or floats, as doubles)
  // mixed to mono and resampled by step (source frames per frame), into
  // dst; returns the frames written
  func mix_down(
    src: double[], frames: int, ch: int, step: float, dst: float[]
  ): int {
    local n = min(int(float(frames - 1) / step), len(dst))
    for(local i = 0; i < n; i += 1){
      local p = float(i) * step
      local j = int(p)
      local f = p - float(j)
      local a = 0.0
      local b = 0.0
      for(local c = 0; c < ch; c += 1){
        a += src[j * ch + c]
        b += src[(j + 1) * ch + c]
      }
      dst[i] = (a + (b - a) * f) / float(ch)
    }
    return max(n, 0)
  }

  func from_int16(src: int16[], dst: double[], n: int){
    for(local i = 0; i < n; i += 1){
      dst[i] = float(src[i]) / 32768.0
    }
  }

  func from_float(src: float[], dst: double[], n: int){
    for(local i = 0; i < n; i += 1){
      dst[i] = src[i]
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

  local ks: float[1024]
  local seed = 777
  // the notes, up and down
  local notes: float[8]
  local func fill_notes(){
    notes[0] = 45.0
    notes[1] = 52.0
    notes[2] = 57.0
    notes[3] = 60.0
    notes[4] = 64.0
    notes[5] = 71.0
    notes[6] = 67.0
    notes[7] = 64.0
  }

  local func noise(): float {
    seed = (seed * 6364136223846793005 + 1442695040888963407) &
      9223372036854775807
    return float((seed >> 20) & 1048575) / 524288.0 - 1.0
  }

  // the demo: plucked strings (Karplus-Strong) up an A minor ninth chord
  // and down again, over a breathy pad, about four seconds
  func demo(out: float[], n: int): int {
    local sr = 48000.0
    fill_notes()
    local step = int(sr * 0.42)
    local period = 1
    local w = 0
    local last = 0.0
    local lp = 0.0
    local frames = min(n, int(sr * 4.2))
    for(local i = 0; i < frames; i += 1){
      if(i % step == 0 and i / step < 8){
        // a new pluck: the line filled with noise of the note's period
        local hz = 440.0 * pow(2.0, (notes[i / step] - 69.0) / 12.0)
        period = int(sr / hz)
        for(local k = 0; k < period; k += 1){
          ks[k] = noise() * 0.6
        }
        w = 0
      }
      local a = ks[w % period]
      local b = ks[(w + 1) % period]
      ks[w % period] = (a + b) * 0.4985
      w = (w + 1) % period
      local t = float(i) / sr
      // the pad: three sines, slowly beating, and filtered breath
      lp += (noise() - lp) * 0.05
      local swell = sin(PI * t / 4.2)
      local pad = (sin(TAU * 110.0 * t) + sin(TAU * 164.81 * t * 1.002) * 0.7 +
        sin(TAU * 220.0 * t * 0.998) * 0.5) * 0.08 + lp * 0.5
      out[i] = a * 0.8 + pad * swell * swell
      last = out[i]
    }
    return frames
  }
}

// demo(dst) -> int: the demo sample into dst; returns its frames
func sample.demo(dst){
  return demo(dst, len(dst))
}

local func u32(n){
  return str.from_bytes({
    n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255
  })
}

local func u16(n){
  return str.from_bytes({n & 255, (n >> 8) & 255})
}

// save(path, src, frames): the first frames of src as a mono 16-bit WAV
// file at 48 kHz
func sample.save(path, src, frames){
  local pcm = kernel.int16:array(math.max(frames, 0))
  to_pcm(src, pcm, frames)
  local data = pcm:to_string()
  local rate = sample.RATE
  local header = concat(
    "RIFF", u32(36 + len(data)), "WAVE", "fmt ", u32(16), u16(1), u16(1),
    u32(rate), u32(rate * 2), u16(2), u16(16), "data", u32(len(data))
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

// load(path, dst) -> int: a WAV file into dst (mono, 48 kHz, as much as
// fits); returns the frames. Raises for what is no WAV file or one of a
// format it does not read.
func sample.load(path, dst){
  local bytes = buffer.from_string(os.read_file(path))
  local fail = func(why){
    raise(error.new(error.kinds.argument, concat("sample: ", path, ": ", why)))
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
      local end = math.min(body + size, len(bytes))
      local raw = bytes:slice(body, end):copy()
      local width = format.bits / 8
      local count = to_int((end - body) / width)
      local values = kernel.double:array(count)
      if(format.code == 1 and format.bits == 16){
        from_int16(raw:cast(kernel.int16.type), values, count)
      } else if(format.code == 1 and format.bits == 24){
        from_int24(raw, values, count)
      } else if(format.code == 3 and format.bits == 32){
        from_float(raw:cast(kernel.float.type), values, count)
      } else {
        fail(concat(
          "a format it does not read (code ", string(format.code), ", ",
          string(format.bits), " bits)"
        ))
      }
      local frames = to_int(count / format.channels)
      return mix_down(
        values, frames, format.channels, format.rate / sample.RATE, dst
      )
    }
    at = body + size + (size & 1)
  }
  fail("no data")
}

return sample
