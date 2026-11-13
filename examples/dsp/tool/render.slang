// Renders a little tune on every instrument, through the echo and the
// reverb, into WAV files (no window, no audio device):
//
//   slang run tool/render.slang [out_dir]       (default: .)
//
// Writes <instrument>.wav and prints how long the rendering took per
// second of sound.
local kernel = require("kernel")
local time = require("slang/time")
local path = require("slang/path")
local engine = require("engine")
local instruments = require("instruments")
local wav = require("wav")

local RATE = 48000
local BLOCK = 128
local dir = args()[0] or "."

// the tune: MIDI notes, one a half second (null: a rest)
local tune = {57, 60, 64, 69, 67, 64, 62, null, 60, 64, 67, 72}

local func hz(note){
  return 440.0 * 2.0 ^ ((note - 69) / 12.0)
}

local layout = engine.layout()
for(local k = 0; k < len(instruments.list); k = k + 1){
  local params = engine.params(layout)
  params[engine.PROGRAM] = k
  local block = engine.new(params, RATE)
  local seconds = len(tune) * 0.5 + 2
  local frames = to_int(seconds * RATE / BLOCK) * BLOCK
  local left = kernel.float:array(frames)
  local right = kernel.float:array(frames)
  local out = kernel.float:array(BLOCK * 2)
  local spent = 0.0
  for(local at = 0; at < frames; at = at + BLOCK){
    local step = to_int(at / (RATE * 0.5))
    if(step < len(tune) and tune[step] != null){
      params[engine.FREQ] = hz(tune[step])
      params[engine.NOTE] = step
      // held for 0.4 of each 0.5 second
      params[engine.GATE] = if(at - step * RATE * 0.5 < RATE * 0.4){ 1.0 } else { 0.0 }
    } else {
      params[engine.GATE] = 0.0
    }
    local t0 = time.clock()
    block(out, BLOCK)
    spent = spent + (time.clock() - t0)
    for(local i = 0; i < BLOCK; i = i + 1){
      left[at + i] = out[2 * i]
      right[at + i] = out[2 * i + 1]
    }
  }
  local file = path.join(dir, concat(instruments.names[k], ".wav"))
  wav.write(file, {left, right}, RATE)
  print(concat(
    file,
    ": ",
    string(to_int(spent / seconds * 1000) / 1000.0),
    " ms per second of sound\n",
  ))
}
