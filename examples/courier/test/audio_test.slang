extension "kernel/syntax"
// The sound without a device: game/audio renders the car, the music and
// every one-shot as numbers that stay finite and under the clipping.
local t = require("slang/test")
local kernel = require("kernel")
local isolate = require("slang/isolate")
local audio = require("game/audio")

kernel {
  // stats[0]: the peak, stats[1]: 1 when a sample is not a number
  func measure(x: float[], stats: double[]){
    for(local i = 0; i < len(x); i += 1){
      if(x[i] != x[i]){
        stats[1] = 1.0
      }
      stats[0] = max(stats[0], abs(x[i]))
    }
  }
}

// the peak of `seconds` of sound, set up by setup, after a one-shot
local func peak_of(setup, shot, seconds){
  local ctl = kernel.float:array(audio.CONTROLS)
  ctl[audio.MASTER] = 1.0
  setup(ctl)
  local events = isolate.channel()
  local block = audio.new(ctl, events)
  if(shot != null){
    events:send({name: shot, gain: 1.0, pan: 0.5})
  }
  local out = kernel.float:array(256)
  local stats = kernel.double:array(2)
  for(local b = 0; b < to_int(48000 * seconds / 128); b = b + 1){
    block(out, 128)
    measure(out, stats)
  }
  assert(stats[1] == 0.0, concat(shot or "the loops", ": not a number"))
  return stats[0]
}

t.group("audio"){
  t.test("the car and the music: heard, under the clipping"){
    local p = peak_of(func(c){
      c[audio.DRIVING] = 1.0
      c[audio.SPEED] = 120
      c[audio.THRUST] = 1.0
      c[audio.BOOST] = 1.0
      c[audio.MAGNET] = 2.0
      c[audio.MUSIC] = 1.0
    }, null, 1.0)
    assert(p > 0.05 and p < 0.98, concat("peak ", p))
  }
  t.test("every one-shot sounds and stays finite"){
    for(let local s in values({
      "hit", "scrape", "whoosh", "clunk", "release", "pickup", "deliver",
      "late", "wreck", "ui", "level", "ignite"
    })){
      local p = peak_of(func(c){}, s, 0.4)
      assert(p > 0.01 and p < 0.98, concat(s, ": peak ", p))
    }
  }
}
