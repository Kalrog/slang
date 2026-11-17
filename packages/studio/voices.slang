// studio/voices: what the units that play studio/units/voice share: how a
// voice starts.
local math = require("slang/math")

local voices = {}

// freq(note: number) -> Hz (69 is 440)
func voices.freq(note){
  return 440.0 * math.exp(math.log(2) * (note - 69) / 12)
}

// start(v: Voice, pick: int, wave: int, note: number, vel: number,
//   seed: int)
// Voice v (slot pick of its unit) from its beginning: wave is the
// kernel's number of what it plays.
func voices.start(v, pick, wave, note, vel, seed){
  v.on = 1
  v.stage = 0
  v.ctr = 0
  v.held = 0
  v.rnd = seed
  v.note = note
  v.vel = vel
  v.target = voices.freq(note)
  v.freq = v.target
  v.env = 0.0
  v.amp = 1.0
  v.penv = 1.0
  v.t = 0.0
  v.phase = 0.0
  v.phase2 = 0.0
  v.ic1 = 0.0
  v.ic2 = 0.0
  v.lp = 0.0
  v.d1 = 0.0
  v.d2 = 0.0
  // the supersaw's saws start apart, so a chord does not click together
  v.p3 = 0.17 + pick * 0.013
  v.p4 = 0.41 + pick * 0.021
  v.p5 = 0.63 + pick * 0.007
  v.p6 = 0.29 + pick * 0.017
  v.p7 = 0.86 + pick * 0.011
  if(wave == 19){
    v.phase2 = 0.52 + pick * 0.009
  }
  v.g = 0.5
  v.k = 1.0
  v.pl = 0.7
  v.pr = 0.7
}

return voices
