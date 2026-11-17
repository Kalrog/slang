// A sine stream computed in slang, and a computed sound played over it at
// rising pitches. Plays for about three seconds.
//   cd packages/window && ../../bin/slang run examples/tones.slang
local audio = require("window/audio")
local buffer = require("slang/buffer")
local math = require("slang/math")
local time = require("slang/time")

print("driver: ", audio.driver, ", device: ", audio.device_name, "\n")

// a stream: a quiet A3 drone
local player = audio.play(func(freq){
  local math = require("slang/math")
  local phase = 0.0
  return func(out, frames){
    for(local i = 0; i < frames; i = i + 1){
      out[i] = math.sin(phase * 2 * math.pi) * 0.1
      phase = (phase + freq / 48000.0) % 1.0
    }
  }
}, {args: {220.0}})

// a sound: a short plucked note made of samples
local n = 9600
local samples = buffer.new("float", n)
for(local i = 0; i < n; i = i + 1){
  local t = i / 48000.0
  samples[i] = math.sin(2 * math.pi * 660 * t) * math.exp(-t * 18) * 0.4
}
local pluck = audio.sound(samples)
print("pluck: ", pluck.duration, " ms\n")

for(let local pitch in values({1.0, 1.25, 1.5, 2.0, 1.5, 1.25, 1.0})){
  pluck:play({pitch: pitch})
  time.sleep(400)
}
local stats = player:stats()
print(
  "stream load ", stats.load, ", underruns ", stats.underruns, ", blocks ",
  stats.blocks, "\n"
)
player:stop()
