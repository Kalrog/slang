// The same voice three ways, in ns per sample (blocks of 128):
//
//   slang run tool/bench.slang
//
// a sine at a slider's frequency through a resonant lowpass (RBJ biquad)
// at a slider's cutoff: as a dsp block, as a kernel written by hand, and
// as plain slang. The dsp block should cost what the hand-written kernel
// does: the generated code is the loop one would write.
extension "kernel/syntax"
local kernel = require("kernel")
local math = require("slang/math")
local time = require("slang/time")

dsp voice {
  import "std";
  freq = hslider("freq", 220, 20, 2000, 0.01);
  cutoff = hslider("cutoff", 1200, 50, 8000, 1);
  process = osc(freq) : lowpass2(cutoff, 2);
}

kernel {
  struct Voice {
    phase: double,
    x1: double,
    x2: double,
    y1: double,
    y2: double,
  }

  func render(
    out: float[], v: Voice, n: int, freq: float, cutoff: float, sr: float
  ){
    local inc = freq / sr
    local w = 6.283185307179586 * cutoff / sr
    local alpha = sin(w) / 4
    local a0 = 1 + alpha
    local b0 = (1 - cos(w)) / 2 / a0
    local a1 = -2 * cos(w) / a0
    local a2 = (1 - alpha) / a0
    local phase = v.phase
    local x1 = v.x1
    local x2 = v.x2
    local y1 = v.y1
    local y2 = v.y2
    for(local i = 0; i < n; i += 1){
      phase = fract(phase + inc)
      local x = sin(phase * 6.283185307179586)
      local y = b0 * x + 2 * b0 * x1 + b0 * x2 - a1 * y1 - a2 * y2
      x2 = x1
      x1 = x
      y2 = y1
      y1 = y
      out[i] = y
    }
    v.phase = phase
    v.x1 = x1
    v.x2 = x2
    v.y1 = y1
    v.y2 = y2
  }
}

local N = 128
local BLOCKS = 4000

local func measure(name, f){
  f()
  local t0 = time.clock()
  for(local b = 0; b < BLOCKS; b = b + 1){
    f()
  }
  local ns = (time.clock() - t0) * 1000000 / (BLOCKS * N)
  print(concat(name, string(math.round(ns * 10) / 10), " ns/sample\n"))
  return ns
}

local out = kernel.float:array(N)

local inst = voice:new()
local a = measure("dsp block            ", func(){ inst:compute(N, {}, {out}) })
local direct = {inst.state, inst.ring, inst.tmp, N, out}
local b = measure("dsp block (direct)   ", func(){ voice.compute(...direct) })

local v = Voice:new()
local c = measure("kernel by hand       ", func(){
  render(out, v, N, 220, 1200, 48000)
})

local s = {phase: 0.0, x1: 0.0, x2: 0.0, y1: 0.0, y2: 0.0}
local d = measure("plain slang          ", func(){
  local w = 2 * math.pi * 1200 / 48000
  local alpha = math.sin(w) / 4
  local a0 = 1 + alpha
  local b0 = (1 - math.cos(w)) / 2 / a0
  local a1 = -2 * math.cos(w) / a0
  local a2 = (1 - alpha) / a0
  local inc = 220 / 48000
  local phase = s.phase
  local x1 = s.x1
  local x2 = s.x2
  local y1 = s.y1
  local y2 = s.y2
  for(local i = 0; i < N; i = i + 1){
    phase = phase + inc
    phase = phase - math.floor(phase)
    local x = math.sin(phase * 2 * math.pi)
    local y = b0 * x + 2 * b0 * x1 + b0 * x2 - a1 * y1 - a2 * y2
    x2 = x1
    x1 = x
    y2 = y1
    y1 = y
    out[i] = y
  }
  s.phase = phase
  s.x1 = x1
  s.x2 = x2
  s.y1 = y1
  s.y2 = y2
})
print(concat(
  "plain slang / dsp block: ",
  string(math.round(d / a * 10) / 10),
  "x\n",
))
print("\nthe dsp block's kernel:\n\n")
print(voice.source)
