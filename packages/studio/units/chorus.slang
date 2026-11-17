extension "kernel/syntax"
// studio/units/chorus: copies of the sound whose delay an LFO moves, so
// their pitch wavers against it: two a side, the sides' LFOs a quarter
// turn apart (wide). With a short delay and feedback it is a flanger.
//
//   keys:insert("chorus")
//   gtr:insert("chorus", {patch: "Flanger"})
local kernel = require("kernel")
local param = require("studio/param")

kernel {
  struct Chorus {
    at: int32,
    primed: int32,
    phase: double,
    mix: double,
    fl: double,
    fr: double,
  }

  local func tap(mem: float[], size: int, at: int, back: float): float {
    local rp = float(at) - back
    local i0 = int(floor(rp))
    local f = rp - floor(rp)
    return mem[i0 % size] * (1.0 - f) + mem[(i0 + 1) % size] * f
  }

  func run(
    l: float[], r: float[], start: int, n: int, st: Chorus, p: double[],
    base: int, sr: double, ml: float[], mr: float[]
  ){
    local size = len(ml)
    local inc = p[base] / sr
    local depth = p[base + 1] * 0.001 * sr
    local delay = p[base + 2] * 0.001 * sr
    local fb = clamp(p[base + 3], -0.95, 0.95)
    local mix_to = p[base + 4]
    if(st.primed == 0){
      st.primed = 1
      st.mix = mix_to
    }
    local dmix = (mix_to - st.mix) / float(n)
    local mix = st.mix
    local at = st.at
    for(local i = start; i < start + n; i += 1){
      mix += dmix
      st.phase += inc
      if(st.phase >= 1.0){
        st.phase -= 1.0
      }
      local a = st.phase * TAU
      ml[at] = l[i] + st.fl * fb
      mr[at] = r[i] + st.fr * fb
      // (a tap never reads closer than a sample behind the write)
      local w1 = tap(ml, size, at, 1.0 + delay + depth * (1.0 + sin(a)))
      local w2 = tap(
        ml, size, at, 1.0 + delay * 1.31 + depth * (1.0 + sin(a + 2.1))
      )
      local w3 = tap(
        mr, size, at, 1.0 + delay + depth * (1.0 + sin(a + 1.5708))
      )
      local w4 = tap(
        mr, size, at, 1.0 + delay * 1.31 + depth * (1.0 + sin(a + 3.67))
      )
      st.fl = w1
      st.fr = w3
      at = (at + 1) % size
      l[i] = l[i] * (1.0 - mix * 0.5) + (w1 + w2) * 0.5 * mix
      r[i] = r[i] * (1.0 - mix * 0.5) + (w3 + w4) * 0.5 * mix
    }
    st.at = at
    st.mix = mix_to
  }
}

local params = param.set({
  {name: "rate", min: 0.02, max: 10.0, default: 0.6, unit: "Hz", curve: 3.0},
  {name: "depth", min: 0.0, max: 10.0, default: 2.5, unit: "ms", curve: 2.0},
  {name: "delay", min: 0.1, max: 40.0, default: 12.0, unit: "ms", curve: 2.0},
  {name: "feedback", min: -0.95, max: 0.95, default: 0.0, bipolar: true},
  {name: "mix", min: 0.0, max: 1.0, default: 0.5},
})

local patches = {
  {name: "Chorus"},
  {name: "Wide", rate: 0.25, depth: 5.0, delay: 18.0, mix: 0.7},
  {
    name: "Flanger", rate: 0.18, depth: 2.2, delay: 0.6, feedback: 0.7, mix: 0.8
  },
  {name: "Jet", rate: 0.07, depth: 3.5, delay: 0.3, feedback: -0.85, mix: 1.0},
  {name: "Vibrato", rate: 5.5, depth: 0.8, delay: 4.0, mix: 1.0},
}

return {
  name: "chorus",
  kind: "effect",
  params: params,
  patches: patches,
  new: func(ctx){
    local st = Chorus:new()
    local sr = ctx.sample_rate * 1.0
    // the longest tap: delay * 1.31 + twice the depth, and room
    local size = to_int(sr * 0.08) + 16
    local ml = kernel.float:array(size)
    local mr = kernel.float:array(size)
    local p = ctx.params
    local base = ctx.base
    return {
      render: func(l, r, start, n){
        run(l, r, start, n, st, p, base, sr, ml, mr)
      },
    }
  },
}
