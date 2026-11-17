extension "kernel/syntax"
// studio/units/filter: a four-pole ladder filter with drive, after the
// modular's VCF: low pass (24 dB an octave), band pass or high pass, the
// resonance whistling by itself near the top.
//
//   bass:insert("filter", {cutoff: 0.4, res: 0.6})
//   s:lfo({rate: 0.3}):to(filter, "cutoff", 0.3)
local param = require("studio/param")

kernel {
  struct Ladder {
    a1: double,
    a2: double,
    a3: double,
    a4: double,
    b1: double,
    b2: double,
    b3: double,
    b4: double,
    g: double,
    primed: int32,
  }

  // cutoff 0..1 is 20 Hz to 20 kHz; the ladder runs twice a sample
  func run(
    l: float[], r: float[], start: int, n: int, st: Ladder, p: double[],
    base: int, sr: double
  ){
    local fc = clamp(20.0 * exp2(p[base] * 10.0) / sr, 0.0004, 0.4)
    local goal = 1.0 - exp(-TAU * fc * 0.5)
    if(st.primed == 0){
      st.primed = 1
      st.g = goal
    }
    local dg = (goal - st.g) / float(n)
    local g = st.g
    local fb = clamp(p[base + 1], 0.0, 1.0) * 4.2
    local drive = 1.0 + p[base + 2] * 5.0
    local mode = int(p[base + 3])
    local makeup = 1.0 + fb * 0.3
    for(local i = start; i < start + n; i += 1){
      g += dg
      local x = l[i] * drive
      local y = r[i] * drive
      for(local pass = 0; pass < 2; pass += 1){
        local u = tanh(x - fb * st.a4)
        st.a1 += g * (u - st.a1)
        st.a2 += g * (st.a1 - st.a2)
        st.a3 += g * (st.a2 - st.a3)
        st.a4 += g * (st.a3 - st.a4)
        u = tanh(y - fb * st.b4)
        st.b1 += g * (u - st.b1)
        st.b2 += g * (st.b1 - st.b2)
        st.b3 += g * (st.b2 - st.b3)
        st.b4 += g * (st.b3 - st.b4)
      }
      if(mode == 0){
        l[i] = st.a4 * makeup
        r[i] = st.b4 * makeup
      } else if(mode == 1){
        l[i] = (st.a2 - st.a4) * 2.0 * makeup
        r[i] = (st.b2 - st.b4) * 2.0 * makeup
      } else {
        l[i] = tanh(x) - st.a4
        r[i] = tanh(y) - st.b4
      }
    }
    st.g = goal
  }
}

local params = param.set({
  {name: "cutoff", min: 0.0, max: 1.0, default: 0.6},
  {name: "res", min: 0.0, max: 1.0, default: 0.2},
  {name: "drive", min: 0.0, max: 1.0, default: 0.0},
  {name: "mode", labels: {"low", "band", "high"}, default: "low"},
})

return {
  name: "filter",
  kind: "effect",
  params: params,
  new: func(ctx){
    local st = Ladder:new()
    local sr = ctx.sample_rate * 1.0
    local p = ctx.params
    local base = ctx.base
    return {
      render: func(l, r, start, n){
        run(l, r, start, n, st, p, base, sr)
      },
    }
  },
}
