// Renders a song to a WAV file without a window or a sound card, and says
// how long that took.
//
//   slang run tool/render.slang songs/dusk.json out.wav
local time = require("slang/time")
local math = require("slang/math")
local song = require("song")
local player = require("player")
local wav = require("studio/wav")

local a = args()
if(len(a) < 2){
  print("usage: slang run tool/render.slang song.json out.wav\n")
  return null
}
local s = song.load(a[0])
local from = time.clock()
local sound = player.render(s)
local took = (time.clock() - from) / 1000
local seconds = len(sound.left) / sound.sample_rate
local peak = 0.0
for(local i = 0; i < len(sound.left); i = i + 1){
  peak = math.max(peak, math.abs(sound.left[i]), math.abs(sound.right[i]))
}
wav.write(a[1], {sound.left, sound.right}, sound.sample_rate)
print(
  s.name, ": ", math.round(seconds * 10) / 10, " s rendered in ",
  math.round(took * 100) / 100, " s (", math.round(took / seconds * 1000) / 10,
  "% of real time), peak ",
  math.round(20 * math.log10(math.max(peak, 1.0e-9)) * 10) / 10, " dBFS, to ",
  a[1], "\n"
)
