extension "kernel/syntax"
// studio/units/crush: a bitcrusher: the sound held at a lower sample rate
// and rounded to fewer bits.
//
//   drums:insert("crush", {bits: 6, rate: 8})
local param = require("studio/param")

kernel {
  struct Crush { phase: double, hl: double, hr: double }

  func run(
    l: float[], r: float[], start: int, n: int, st: Crush, p: double[],
    base: int
  ){
    local steps = exp2(clamp(p[base], 1.0, 16.0) - 1.0)
    local inc = 1.0 / clamp(p[base + 1], 1.0, 256.0)
    local mix = p[base + 2]
    for(local i = start; i < start + n; i += 1){
      st.phase += inc
      if(st.phase >= 1.0){
        st.phase -= 1.0
        st.hl = floor(l[i] * steps + 0.5) / steps
        st.hr = floor(r[i] * steps + 0.5) / steps
      }
      l[i] = l[i] * (1.0 - mix) + st.hl * mix
      r[i] = r[i] * (1.0 - mix) + st.hr * mix
    }
  }
}

local params = param.set({
  {name: "bits", min: 1.0, max: 16.0, default: 8.0},
  {name: "rate", min: 1.0, max: 256.0, default: 4.0, curve: 3.0},
  {name: "mix", min: 0.0, max: 1.0, default: 1.0},
})

return {
  name: "crush",
  kind: "effect",
  params: params,
  new: func(ctx){
    local st = Crush:new({phase: 1.0})
    local p = ctx.params
    local base = ctx.base
    return {
      render: func(l, r, start, n){
        run(l, r, start, n, st, p, base)
      },
    }
  },
}
