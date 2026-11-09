extension "kernel/syntax"
// tool/levels: renders each sound of game/audio alone and prints its peak,
// its RMS and the time it takes per second of sound (for balancing them):
//     slang run tool/levels.slang
local audio = require("game/audio")
local kernel = require("kernel")
local isolate = require("slang/isolate")
local time = require("slang/time")
local math = require("slang/math")
kernel {
  // stats[0]: the peak so far, stats[1]: the sum of squares
  func measure(x: float[], stats: double[]){
    for(local i = 0; i < len(x); i += 1){
      stats[0] = max(stats[0], abs(x[i]))
      stats[1] += x[i] * x[i]
    }
  }
}

local func run(label, setup, seconds, shot){
  local ctl = kernel.float:array(audio.CONTROLS)
  local events = isolate.channel()
  ctl[audio.MASTER] = 1.0
  setup(ctl)
  local block = audio.new(ctl, events)
  local out = kernel.float:array(256)
  if(shot != null){ events:send({name: shot}) }
  local blocks = to_int(48000 * seconds / 128)
  local stats = kernel.double:array(2)
  local n = 0
  local t0 = time.clock()
  for(local b = 0; b < blocks; b = b + 1){
    block(out, 128)
    if(b > blocks / 3 or shot != null){
      measure(out, stats)
      n = n + 256
    }
  }
  print(
    label, ": peak ", math.floor(stats[0] * 1000) / 1000, "  rms ",
    math.floor(math.sqrt(stats[1] / math.max(1, n)) * 1000) / 1000, "  ",
    math.floor((time.clock() - t0) / seconds), " ms/s\n"
  )
}
local func driving(speed, thrust, boost, magnet){
  return func(c){
    c[audio.DRIVING] = 1.0
    c[audio.SPEED] = speed
    c[audio.THRUST] = thrust
    c[audio.BOOST] = boost
    c[audio.MAGNET] = magnet
  }
}
run("idle hover", driving(0, 0, 0, 0), 3)
run("cruise 40", driving(40, 0.5, 0, 0), 3)
run("full 90", driving(90, 1, 0, 0), 3)
run("boost 120", driving(120, 1, 1, 0), 3)
run("magnet hold", driving(0, 0, 0, 2), 3)
run("music", func(c){ c[audio.MUSIC] = 1.0 }, 6)
for(let local s in values({
  "hit", "scrape", "whoosh", "clunk", "release", "pickup", "deliver", "late",
  "wreck", "ui", "level", "ignite"
})){
  run(s, func(c){}, 3, s)
}
