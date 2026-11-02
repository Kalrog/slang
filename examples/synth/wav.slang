// WAV files: 16-bit PCM from buffers of float samples (-1 to 1).
//
//   local wav = require("wav")
//   wav.write("out.wav", {left, right}, 48000)       // stereo
//   wav.write("stem.wav", {samples}, 48000, 0.9)     // mono, scaled
local buffer = require("slang/buffer")
local os = require("slang/os")
local str = require("slang/string")

local wav = {}

local func u32(n){
  return str.from_bytes({n & 255, (n >> 8) & 255, (n >> 16) & 255, (n >> 24) & 255})
}

local func u16(n){
  return str.from_bytes({n & 255, (n >> 8) & 255})
}

// write(path: string, channels: {Buffer}, rate: int, scale?: float)
// The channels' samples (all as long as the first), interleaved, times
// scale (1 by default), clipped to -1..1.
func wav.write(path, channels, rate, scale){
  scale = scale or 1.0
  local n = len(channels)
  local frames = len(channels[0])
  local pcm = buffer.new("int16", frames * n)
  for(local c = 0; c < n; c = c + 1){
    local src = channels[c]
    local k = c
    for(local i = 0; i < frames; i = i + 1){
      local v = src[i] * scale
      if(v > 1.0){
        v = 1.0
      } else if(v < -1.0){
        v = -1.0
      }
      pcm[k] = to_int(v * 32767)
      k = k + n
    }
  }
  local data = pcm:to_string()
  local header = concat(
    "RIFF", u32(36 + len(data)), "WAVE",
    "fmt ", u32(16), u16(1), u16(n), u32(rate), u32(rate * n * 2), u16(n * 2), u16(16),
    "data", u32(len(data))
  )
  os.write_file(path, concat(header, data))
}

return wav
