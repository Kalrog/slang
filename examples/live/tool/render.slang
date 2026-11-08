// Renders a piece to a WAV without a window or an audio device.
//
//   slang run tool/render.slang pieces/first.slang out.wav [seconds]
local os = require("slang/os")
local time = require("slang/time")
local str = require("slang/string")
local offline = require("offline")
local wav = require("wav")

local a = args()
if(len(a) < 2){
  print("usage: slang run tool/render.slang piece.slang out.wav [seconds]\n")
  return
}
local seconds = 16.0
if(len(a) > 2){
  seconds = str.to_number(a[2])
}
local t0 = time.clock()
local r = offline.run(os.read_file(a[0]), seconds, a[0])
local took = (time.clock() - t0) / 1000
wav.write(a[1], {r.left, r.right}, offline.RATE, 0.95)
print(concat(
  a[0], ": ", seconds, " s rendered in ", to_int(took * 100) / 100, " s (",
  to_int(took / seconds * 100), "% of real time) to ", a[1], "\n"
))
