extension "kernel/syntax"
// studio/units/phaser: the sound through a chain of allpass filters whose
// turning point an LFO sweeps, mixed with itself: notches that travel up
// and down the spectrum. More stages, more notches; feedback sharpens
// them.
//
//   pad:insert("phaser", {rate: 0.2, stages: 6, feedback: 0.6})
local kernel = require("kernel")
local param = require("studio/param")

kernel {
  struct Phaser {
    phase: double,
    fl: double,
    fr: double,
    mix: double,
    primed: int32,
  }

  // z: the allpasses' states, 12 a side
  func run(
    l: float[], r: float[], start: int, n: int, st: Phaser, p: double[],
    base: int, sr: double, z: double[]
  ){
    local inc = p[base] / sr
    local depth = p[base + 1]
    local center = p[base + 2]
    local fb = clamp(p[base + 3], -0.95, 0.95)
    local stages = int(clamp(p[base + 4], 2.0, 12.0))
    local mix_to = p[base + 5]
    if(st.primed == 0){
      st.primed = 1
      st.mix = mix_to
    }
    local dmix = (mix_to - st.mix) / float(n)
    local mix = st.mix
    for(local i = start; i < start + n; i += 1){
      mix += dmix
      st.phase += inc
      if(st.phase >= 1.0){
        st.phase -= 1.0
      }
      // the sweep: up to two octaves either side of the center, the
      // right side a quarter turn behind
      local fl = center * exp2(sin(st.phase * TAU) * depth * 2.0)
      local fr = center * exp2(sin(st.phase * TAU + 1.5708) * depth * 2.0)
      local tl = tan(PI * min(fl, sr * 0.45) / sr)
      local tr = tan(PI * min(fr, sr * 0.45) / sr)
      local al = (tl - 1.0) / (tl + 1.0)
      local ar = (tr - 1.0) / (tr + 1.0)
      local x = l[i] + st.fl * fb
      local y = r[i] + st.fr * fb
      for(local k = 0; k < stages; k += 1){
        local out = al * x + z[k]
        z[k] = x - al * out
        x = out
        out = ar * y + z[12 + k]
        z[12 + k] = y - ar * out
        y = out
      }
      st.fl = x
      st.fr = y
      l[i] = l[i] * (1.0 - mix * 0.5) + x * mix * 0.5
      r[i] = r[i] * (1.0 - mix * 0.5) + y * mix * 0.5
    }
    st.mix = mix_to
  }
}

local params = param.set({
  {name: "rate", min: 0.02, max: 10.0, default: 0.4, unit: "Hz", curve: 3.0},
  {name: "depth", min: 0.0, max: 1.0, default: 0.7},
  {
    name: "center", min: 100.0, max: 6000.0, default: 900.0, unit: "Hz",
    curve: 3.0
  },
  {name: "feedback", min: -0.95, max: 0.95, default: 0.4, bipolar: true},
  {name: "stages", min: 2.0, max: 12.0, default: 6.0, step: 2.0},
  {name: "mix", min: 0.0, max: 1.0, default: 1.0},
})

return {
  name: "phaser",
  kind: "effect",
  params: params,
  new: func(ctx){
    local st = Phaser:new()
    local sr = ctx.sample_rate * 1.0
    local z = kernel.double:array(24)
    local p = ctx.params
    local base = ctx.base
    return {
      render: func(l, r, start, n){
        run(l, r, start, n, st, p, base, sr, z)
      },
    }
  },
}
