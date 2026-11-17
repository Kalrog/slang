extension "kernel/syntax"
// studio/units/drive: distortion: the sound pushed into a curve. "tanh" is
// a tube's soft knee, "soft" a gentler one that is flat beyond, "fold"
// turns back what goes over the top (bright, metallic), "hard" clips.
// Tone darkens what comes out; level makes up for what drive adds.
//
//   bass:insert("drive", {drive: 0.5, mode: "fold", tone: 0.7})
local param = require("studio/param")

kernel {
  use "studio/lib"

  struct Drive { ll: double, lr: double, gain: double, primed: int32 }

  local func shape(x: float, mode: int): float {
    if(mode == 0){
      return tanh(x)
    }
    if(mode == 1){
      return soft(x)
    }
    if(mode == 2){
      // a triangle of period 4 through the origin
      local t = (x + 1.0) * 0.25
      t -= floor(t)
      return 1.0 - 4.0 * abs(t - 0.5)
    }
    return clamp(x, -1.0, 1.0)
  }

  func run(
    l: float[], r: float[], start: int, n: int, st: Drive, p: double[],
    base: int, sr: double
  ){
    local goal = 1.0 + p[base] * p[base] * 40.0
    if(st.primed == 0){
      st.primed = 1
      st.gain = goal
    }
    local dg = (goal - st.gain) / float(n)
    local gain = st.gain
    local mode = int(p[base + 1])
    local tone = p[base + 2]
    local c = 1.0 - exp(-TAU * min(300.0 * exp2(tone * 6.2), sr * 0.45) / sr)
    local mix = p[base + 3]
    local level = p[base + 4]
    for(local i = start; i < start + n; i += 1){
      gain += dg
      // louder in, quieter out: about as loud as it was
      local trim = level / sqrt(gain)
      local a = shape(l[i] * gain, mode)
      local b = shape(r[i] * gain, mode)
      st.ll += (a - st.ll) * c
      st.lr += (b - st.lr) * c
      l[i] = l[i] * (1.0 - mix) + st.ll * trim * mix
      r[i] = r[i] * (1.0 - mix) + st.lr * trim * mix
    }
    st.gain = goal
  }
}

local params = param.set({
  {name: "drive", min: 0.0, max: 1.0, default: 0.3},
  {name: "mode", labels: {"tanh", "soft", "fold", "hard"}, default: "tanh"},
  {name: "tone", min: 0.0, max: 1.0, default: 1.0},
  {name: "mix", min: 0.0, max: 1.0, default: 1.0},
  {name: "level", min: 0.0, max: 2.0, default: 1.0},
})

return {
  name: "drive",
  kind: "effect",
  params: params,
  new: func(ctx){
    local st = Drive:new()
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
