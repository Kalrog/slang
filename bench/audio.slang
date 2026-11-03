// Audio synthesis in plain slang: ns per sample of the shapes a synth is
// made of (PLAN_PERF.md part 3). The floor is bench/saw.c (the sawtooth in
// C); a sample at 48 kHz has a budget of 20833 ns.
local time = require("slang/time")
local math = require("slang/math")
local buffer = require("slang/buffer")

local n = 1000000
local rate = 48000.0
local out = buffer.new("float", n)

local func row(name, f){
  local t0 = time.clock()
  f()
  local t1 = time.clock()
  print(name, ": ", to_int((t1 - t0) * 1000000 / n), " ns per sample\n")
}

// the sawtooth: a phase accumulator, locals only
row("sawtooth, locals", func(){
  local phase = 0.0
  local inc = 440.0 / rate
  for(local i = 0; i < n; i = i + 1){
    out[i] = phase * 2.0 - 1.0
    phase = phase + inc
    if(phase >= 1.0){
      phase = phase - 1.0
    }
  }
})

// the sine: a call to math.sin per sample
row("sine, math.sin", func(){
  local phase = 0.0
  local inc = 440.0 / rate * 2.0 * math.pi
  for(local i = 0; i < n; i = i + 1){
    out[i] = math.sin(phase)
    phase = phase + inc
  }
})

// a one-pole lowpass over the sawtooth, state in locals
row("saw + one-pole, locals", func(){
  local phase = 0.0
  local inc = 440.0 / rate
  local z = 0.0
  local cutoff = 0.1
  for(local i = 0; i < n; i = i + 1){
    local x = phase * 2.0 - 1.0
    z = z + cutoff * (x - z)
    out[i] = z
    phase = phase + inc
    if(phase >= 1.0){
      phase = phase - 1.0
    }
  }
})

// the same with the state in a table (how a node object keeps it)
row("saw + one-pole, table state", func(){
  local st = {phase: 0.0, inc: 440.0 / rate, z: 0.0, cutoff: 0.1}
  for(local i = 0; i < n; i = i + 1){
    local x = st.phase * 2.0 - 1.0
    st.z = st.z + st.cutoff * (x - st.z)
    out[i] = st.z
    st.phase = st.phase + st.inc
    if(st.phase >= 1.0){
      st.phase = st.phase - 1.0
    }
  }
})

// a closure per sample (a generator function)
local func make_saw(freq){
  local phase = 0.0
  local inc = freq / rate
  return func(){
    local x = phase * 2.0 - 1.0
    phase = phase + inc
    if(phase >= 1.0){
      phase = phase - 1.0
    }
    return x
  }
}
row("closure per sample", func(){
  local saw = make_saw(440.0)
  for(local i = 0; i < n; i = i + 1){
    out[i] = saw()
  }
})

// a method per sample (a node object)
local osc = {}
func osc.new(freq){
  local o = {phase: 0.0, inc: freq / rate}
  o.@meta = {__index: osc}
  return o
}
func osc.next(self){
  local x = self.phase * 2.0 - 1.0
  self.phase = self.phase + self.inc
  if(self.phase >= 1.0){
    self.phase = self.phase - 1.0
  }
  return x
}
row("method per sample", func(){
  local o = osc.new(440.0)
  for(local i = 0; i < n; i = i + 1){
    out[i] = o:next()
  }
})

// 8 voices mixed, each a method call
row("8 voices, method per sample", func(){
  local voices = {}
  for(local v = 0; v < 8; v = v + 1){
    append(voices, osc.new(110.0 * (v + 1)))
  }
  for(local i = 0; i < n; i = i + 1){
    local s = 0.0
    for(local v = 0; v < 8; v = v + 1){
      s = s + voices[v]:next()
    }
    out[i] = s * 0.125
  }
})
