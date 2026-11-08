// Renders a patch's song to a WAV without a window or an audio device,
// as F3 does in the program: the clock runs from the start through the
// song chain (or 8 bars of the chosen pattern), then two seconds of tail.
//
//   slang run tool/render.slang patches/first_song.json out.wav [pattern]
local buffer = require("slang/buffer")
local time = require("slang/time")
local rack = require("rack")
local engine = require("engine")
local wav = require("wav")

local a = args()
if(len(a) < 2){
  print("usage: slang run tool/render.slang patch.json out.wav [pattern 1-8]\n")
  return
}
local r = rack.new(func(t, n){ return buffer.new(t, n) })
r:load(a[0])
if(len(a) > 2){
  r.a.live[engine.live.PATTERN] = to_int(a[2]) - 1
}
local seconds = 8.0
for(let local m in values(r:slots())){
  local mod = r.modules[m]
  if(mod.kind == engine.kinds.CLOCK){
    local bpm = 40 + mod.params[0] * 200
    local bars = 8
    if(mod.params[3] > 0.5 and len(r.song) > 0){
      bars = len(r.song) * (1 << to_int(mod.params[2]))
    }
    seconds = bars * 16 * 60 / bpm / 4 + 2
    break
  }
}
local rate = 48000
local frames = to_int(seconds * rate)
local t0 = time.clock()
local s = engine.render(engine.offline(r.a, rate), frames, rate)
local took = (time.clock() - t0) / 1000
wav.write(a[1], {s.left, s.right}, rate, 0.9)
print(concat(r.name, ": ", to_int(seconds), " s rendered in ", to_int(took * 100) / 100, " s (", to_int(took / seconds * 100), "% of real time) to ", a[1], "\n"))
