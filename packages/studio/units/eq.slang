extension "kernel/syntax"
// studio/units/eq: an equalizer of five bands: a low cut, a low shelf, two
// bells and a high shelf, then a gain. A band at 0 dB (and the low cut at
// its lowest) leaves the sound alone.
//
//   vox:insert("eq", {low_cut: 90, mid_freq: 350, mid_gain: -4, high_gain: 3})
local kernel = require("kernel")
local math = require("slang/math")
local param = require("studio/param")

kernel {
  // five biquads in a row a side (transposed direct form II). c: b0, b1,
  // b2, a1, a2 per band; z: two states per band and side
  func run(
    l: float[], r: float[], start: int, n: int, c: double[], z: double[],
    g0: float, g1: float
  ){
    local dg = (g1 - g0) / float(n)
    local g = g0
    for(local i = start; i < start + n; i += 1){
      g += dg
      local x = l[i]
      local y = r[i]
      for(local b = 0; b < 5; b += 1){
        local k = b * 5
        local s = b * 4
        local out = c[k] * x + z[s]
        z[s] = c[k + 1] * x - c[k + 3] * out + z[s + 1]
        z[s + 1] = c[k + 2] * x - c[k + 4] * out
        x = out
        out = c[k] * y + z[s + 2]
        z[s + 2] = c[k + 1] * y - c[k + 3] * out + z[s + 3]
        z[s + 3] = c[k + 2] * y - c[k + 4] * out
        y = out
      }
      l[i] = x * g
      r[i] = y * g
    }
  }
}

local params = param.set({
  {
    name: "low_cut", min: 10.0, max: 1000.0, default: 10.0, unit: "Hz",
    curve: 3.0
  },
  {
    name: "low_freq", min: 30.0, max: 1000.0, default: 120.0, unit: "Hz",
    curve: 3.0
  },
  {
    name: "low_gain", min: -18.0, max: 18.0, default: 0.0, unit: "dB",
    bipolar: true
  },
  {
    name: "mid_freq", min: 80.0, max: 8000.0, default: 500.0, unit: "Hz",
    curve: 3.0
  },
  {
    name: "mid_gain", min: -18.0, max: 18.0, default: 0.0, unit: "dB",
    bipolar: true
  },
  {name: "mid_q", min: 0.3, max: 12.0, default: 1.0, curve: 2.0},
  {
    name: "presence_freq", min: 400.0, max: 16000.0, default: 3000.0,
    unit: "Hz", curve: 3.0
  },
  {
    name: "presence_gain", min: -18.0, max: 18.0, default: 0.0, unit: "dB",
    bipolar: true
  },
  {name: "presence_q", min: 0.3, max: 12.0, default: 1.0, curve: 2.0},
  {
    name: "high_freq", min: 1000.0, max: 18000.0, default: 8000.0, unit: "Hz",
    curve: 3.0
  },
  {
    name: "high_gain", min: -18.0, max: 18.0, default: 0.0, unit: "dB",
    bipolar: true
  },
  {
    name: "gain", min: -24.0, max: 24.0, default: 0.0, unit: "dB", bipolar: true
  },
})
local P = params.index

// a band's five coefficients into c from k on: b0, b1, b2, a1, a2 over a0
local func put(c, k, b0, b1, b2, a0, a1, a2){
  c[k] = b0 / a0
  c[k + 1] = b1 / a0
  c[k + 2] = b2 / a0
  c[k + 3] = a1 / a0
  c[k + 4] = a2 / a0
}

local func through(c, k){
  put(c, k, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
}

// the bands, after the Audio EQ Cookbook
local func high_pass(c, k, f, sr){
  local w = 2 * math.pi * f / sr
  local cs = math.cos(w)
  local alpha = math.sin(w) / (2 * 0.7071)
  put(
    c, k, (1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + alpha, -2 * cs, 1 - alpha
  )
}

local func shelf(c, k, f, db, sr, high){
  local a = math.exp(math.log(10) * db / 40)
  local w = 2 * math.pi * f / sr
  local cs = math.cos(w)
  local beta = 2 * math.sqrt(a) * math.sin(w) / 2 * math.sqrt(2)
  if(high){
    put(
      c,
      k,
      a * ((a + 1) + (a - 1) * cs + beta),
      -2 * a * ((a - 1) + (a + 1) * cs),
      a * ((a + 1) + (a - 1) * cs - beta),
      (a + 1) - (a - 1) * cs + beta,
      2 * ((a - 1) - (a + 1) * cs),
      (a + 1) - (a - 1) * cs - beta,
    )
  } else {
    put(
      c,
      k,
      a * ((a + 1) - (a - 1) * cs + beta),
      2 * a * ((a - 1) - (a + 1) * cs),
      a * ((a + 1) - (a - 1) * cs - beta),
      (a + 1) + (a - 1) * cs + beta,
      -2 * ((a - 1) + (a + 1) * cs),
      (a + 1) + (a - 1) * cs - beta,
    )
  }
}

local func bell(c, k, f, db, q, sr){
  local a = math.exp(math.log(10) * db / 40)
  local w = 2 * math.pi * f / sr
  local cs = math.cos(w)
  local alpha = math.sin(w) / (2 * q)
  put(
    c, k, 1 + alpha * a, -2 * cs, 1 - alpha * a, 1 + alpha / a, -2 * cs,
    1 - alpha / a
  )
}

return {
  name: "eq",
  kind: "effect",
  params: params,
  new: func(ctx){
    local sr = ctx.sample_rate * 1.0
    local p = ctx.params
    local base = ctx.base
    local c = kernel.double:array(25)
    local z = kernel.double:array(20)
    local dirty = true
    local gain = null
    local func derive(){
      local top = sr * 0.45
      if(p[base + P.low_cut] > 10.5){
        high_pass(c, 0, p[base + P.low_cut], sr)
      } else {
        through(c, 0)
      }
      if(p[base + P.low_gain] != 0.0){
        shelf(c, 5, p[base + P.low_freq], p[base + P.low_gain], sr, false)
      } else {
        through(c, 5)
      }
      if(p[base + P.mid_gain] != 0.0){
        bell(
          c, 10, p[base + P.mid_freq], p[base + P.mid_gain], p[base + P.mid_q],
          sr
        )
      } else {
        through(c, 10)
      }
      if(p[base + P.presence_gain] != 0.0){
        bell(
          c,
          15,
          math.min(p[base + P.presence_freq], top),
          p[base + P.presence_gain],
          p[base + P.presence_q],
          sr,
        )
      } else {
        through(c, 15)
      }
      if(p[base + P.high_gain] != 0.0){
        shelf(
          c, 20, math.min(p[base + P.high_freq], top), p[base + P.high_gain],
          sr, true
        )
      } else {
        through(c, 20)
      }
      dirty = false
    }
    return {
      set: func(i, value){
        dirty = true
      },
      render: func(l, r, start, n){
        if(dirty){
          derive()
        }
        local g = math.exp(math.log(10) * p[base + P.gain] / 20)
        if(gain == null){
          gain = g
        }
        run(l, r, start, n, c, z, gain, g)
        gain = g
      },
    }
  },
}
