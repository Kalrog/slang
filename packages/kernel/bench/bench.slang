// Kernels against the same loops in plain slang: ns per sample, blocks of
// 128 as an audio stream renders them.
//
//   make kernel-bench     (or: cd packages/kernel && slang run bench/bench.slang)
local buffer = require("slang/buffer")
local time = require("slang/time")
local math = require("slang/math")
local dsp = require("bench/dsp")

local N = 128
local BLOCKS = 4000
local out = buffer.new("float", N)

// ---- the loops in slang

local func saw(out, n, phase, inc){
  for(local i = 0; i < n; i = i + 1){
    phase = phase + inc
    if(phase >= 1.0){
      phase = phase - 1.0
    }
    out[i] = phase * 2 - 1
  }
  return phase
}

local sin = math.sin
local TAU = 6.283185307179586
local func chain(out, phase, inc, level, n){
  for(local i = 0; i < n; i = i + 1){
    local m = 0.0
    for(local k = 5; k >= 0; k = k - 1){
      local p = phase[k] + inc[k]
      if(p >= 1.0){
        p = p - 1.0
      }
      phase[k] = p
      m = sin((p + m) * TAU) * level[k]
    }
    out[i] = m
  }
}

local tanh = math.tanh
local func ladder(io, n, g, k, st){
  local y1 = st[0]
  local y2 = st[1]
  local y3 = st[2]
  local y4 = st[3]
  for(local i = 0; i < n; i = i + 1){
    local u = tanh(io[i] - k * y4)
    y1 = y1 + g * (u - y1)
    y2 = y2 + g * (y1 - y2)
    y3 = y3 + g * (y2 - y3)
    y4 = y4 + g * (y3 - y4)
    io[i] = y4
  }
  st[0] = y1
  st[1] = y2
  st[2] = y3
  st[3] = y4
}

// ---- running

local func ns(f){
  local t0 = time.clock()
  for(local b = 0; b < BLOCKS; b = b + 1){
    f()
  }
  return (time.clock() - t0) * 1000000 / (N * BLOCKS)
}

local func row(name, plain, kern){
  local a = ns(plain)
  local b = ns(kern)
  print(name, ": slang ", math.round(a * 10) / 10, " ns, kernel ", math.round(b * 10) / 10,
    " ns per sample (", math.round(a / b * 10) / 10, "x)\n")
}

local phase = 0.0
local kphase = 0.0
row("sawtooth", func(){ phase = saw(out, N, phase, 0.001) }, func(){ kphase = dsp.saw(out, N, kphase, 0.001) })

local ph = buffer.new("double", 6)
local inc = buffer.new("double", 6)
local level = buffer.new("double", 6)
local ops = buffer.new(dsp.Op, 6)
for(local i = 0; i < 6; i = i + 1){
  inc[i] = 0.01 * (i + 1)
  level[i] = 0.5
  ops[i].inc = inc[i]
  ops[i].level = 0.5
}
row("fm chain, 6 operators", func(){ chain(out, ph, inc, level, N) }, func(){ dsp.chain(out, ops, N) })

local st = buffer.new("double", 4)
local kst = buffer.new("double", 4)
local noise = buffer.new("float", N)
for(local i = 0; i < N; i = i + 1){
  noise[i] = math.random() * 2 - 1
}
row("ladder filter", func(){ ladder(noise, N, 0.2, 3.5, st) }, func(){ dsp.ladder(noise, N, 0.2, 3.5, kst) })
