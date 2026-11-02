// Records a song part by part and mixes the parts, the way synthesizer
// records of Bach were made one line at a time: every part of the song file
// is played by the synth's engine into a recording of its own (a stem), and
// the stems are panned, summed, given a hall and written as a stereo WAV.
//
//   slang run mixdown.slang songs/brandenburg2.slang            // into mixdown/
//   slang run mixdown.slang songs/bach_invention8.slang out
//
// It writes <song>-<part>.wav for every part and <song>-mix.wav. Nothing
// plays: it computes as fast as it can, with the parts recorded at the
// same time, each in an isolate of its own (as are the mix's time slices
// and the reverb's two channels).
local buffer = require("slang/buffer")
local isolate = require("slang/isolate")
local math = require("slang/math")
local os = require("slang/os")
local path = require("slang/path")
local time = require("slang/time")
local song = require("song")
local wav = require("wav")

local RATE = 48000
local BLOCK = 128
// after the last note: the release and the hall
local TAIL = 3.5

// ------------------------------------------------------------ the work of the isolates

// one part, recorded: the engine plays it into out, which then becomes a
// WAV; returns how long the part took
local func record_part(file, k, rate, block_size, out, stem_path){
  local buffer = require("slang/buffer")
  local isolate = require("slang/isolate")
  local time = require("slang/time")
  local params = require("params")
  local engine = require("engine")
  local song = require("song")
  local t0 = time.clock()
  local controls = buffer.new("double", params.count)
  for(local i = 0; i < params.count; i = i + 1){
    controls[i] = params.list[i].default
  }
  local events = isolate.channel()
  local play = engine.new(controls, events, null, rate, null)
  events:send({song: song.load(file, k)})
  local tmp = buffer.new("float", block_size)
  local frames = len(out)
  for(local at = 0; at + block_size <= frames; at = at + block_size){
    play(tmp, block_size)
    out:set(tmp, at)
  }
  require("wav").write(stem_path, {out}, rate)
  return time.clock() - t0
}

// frames from..to-1 of every stem, panned and scaled, summed into left
// and right
local func mix_slice(stems, gains, from, to, left, right){
  for(local k = 0; k < len(stems); k = k + 1){
    local s = stems[k]
    local gl = gains[k][0]
    local gr = gains[k][1]
    for(local i = from; i < to; i = i + 1){
      local v = s[i]
      left[i] = left[i] + v * gl
      right[i] = right[i] + v * gr
    }
  }
}

// a hall for one channel (Freeverb's design: eight damped combs in
// parallel, four allpasses after them), of the mono sum of left and right;
// spread offsets the delays so that the two channels differ. Each filter
// runs over the whole recording in turn, its state in locals: the combs
// add into out, the allpasses then work on out in place.
local func reverb(left, right, out, rate, room, damp, spread){
  local buffer = require("slang/buffer")
  local scale = rate / 44100.0
  local frames = len(out)
  local x = buffer.new("float", frames)
  for(local i = 0; i < frames; i = i + 1){
    x[i] = (left[i] + right[i]) * 0.015
  }
  local feedback = 0.7 + 0.28 * room
  local d1 = damp
  local d2 = 1.0 - damp
  for(let local size in values({
    1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617
  })){
    local n = to_int((size + spread) * scale)
    local b = buffer.new("float", n)
    local at = 0
    local store = 0.0
    for(local i = 0; i < frames; i = i + 1){
      local v = b[at]
      store = v * d2 + store * d1
      b[at] = x[i] + store * feedback
      at = at + 1
      if(at >= n){
        at = 0
      }
      out[i] = out[i] + v
    }
  }
  for(let local size in values({556, 441, 341, 225})){
    local n = to_int((size + spread) * scale)
    local b = buffer.new("float", n)
    local at = 0
    for(local i = 0; i < frames; i = i + 1){
      local y = out[i]
      local v = b[at]
      b[at] = y + v * 0.5
      out[i] = v - y
      at = at + 1
      if(at >= n){
        at = 0
      }
    }
  }
  return null
}

// ------------------------------------------------------------ the song

local a = args()
if(len(a) < 1){
  print("usage: slang run mixdown.slang <song.slang> [out-dir]\n")
  os.exit(1)
}
local file = a[0]
local out_dir = a[1] or "mixdown"
os.mkdir_all(out_dir)
local name = path.base(file)
local str = require("slang/string")
if(str.ends_with(name, ".slang")){
  name = str.substring(name, 0, len(name) - 6)
}
local t0 = time.clock()
local info = song.parts(file)
local parts = info.parts

// as long as the longest part, and the tail
local length = 0.0
for(local k = 0; k < len(parts); k = k + 1){
  local s = song.load(file, k)
  if(s.length > length){
    length = s.length
  }
}
local frames = to_int((length + TAIL) * RATE / BLOCK + 1) * BLOCK
print(concat(info.title, ": ", len(parts), " parts, ", to_int(length), " s\n"))

// every part at once, each in an isolate
local stems = {}
local workers = {}
for(local k = 0; k < len(parts); k = k + 1){
  local stem = buffer.shared("float", frames)
  append(stems, stem)
  local stem_path = path.join(out_dir, concat(name, "-", parts[k].name, ".wav"))
  append(workers, isolate.spawn(
    record_part, file, k, RATE, BLOCK, stem, stem_path
  ))
}
for(local k = 0; k < len(parts); k = k + 1){
  local took = workers[k]:join()
  print(concat(
    "  ", parts[k].name, ": recorded in ", math.round(took * 10) / 10, " s\n"
  ))
}

// panned (constant power) and summed, in time slices
local gains = {}
for(let local p in values(parts)){
  local angle = (p.pan + 1.0) * math.pi / 4.0
  append(gains, {math.cos(angle) * p.gain, math.sin(angle) * p.gain})
}
local left = buffer.shared("float", frames)
local right = buffer.shared("float", frames)
local slices = isolate.cpu_count()
local size = to_int(frames / slices) + 1
local mixers = {}
for(local s = 0; s < slices; s = s + 1){
  local from = s * size
  local to = math.min(frames, from + size)
  if(from < to){
    append(mixers, isolate.spawn(
      mix_slice, stems, gains, from, to, left, right
    ))
  }
}
for(let local m in values(mixers)){
  m:join()
}

// the hall: both channels at once
local mix = info.mix
local wet = mix.reverb or 0.2
local hall_l = buffer.shared("float", frames)
local hall_r = buffer.shared("float", frames)
local room = mix.room or 0.8
local damp = mix.damp or 0.35
local halls = {
  isolate.spawn(reverb, left, right, hall_l, RATE, room, damp, 0),
  isolate.spawn(reverb, left, right, hall_r, RATE, room, damp, 23),
}
for(let local h in values(halls)){
  h:join()
}

// dry and wet together, then as loud as it can be (-1 dB at the peak)
local peak = 0.0
for(local i = 0; i < frames; i = i + 1){
  local l = left[i] + hall_l[i] * wet
  local r = right[i] + hall_r[i] * wet
  left[i] = l
  right[i] = r
  if(l > peak){
    peak = l
  } else if(-l > peak){
    peak = -l
  }
  if(r > peak){
    peak = r
  } else if(-r > peak){
    peak = -r
  }
}
local mix_path = path.join(out_dir, concat(name, "-mix.wav"))
wav.write(mix_path, {left, right}, RATE, 0.89 / peak)
print(concat(
  "mix: ", mix_path, " (", to_int(frames / RATE), " s), all in ",
  math.round((time.clock() - t0) * 10) / 10, " s\n"
))
