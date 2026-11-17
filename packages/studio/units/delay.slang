extension "kernel/syntax"
// studio/units/delay: a tape delay: its time slides when it is turned (so
// the echoes bend), every repeat is a little darker (tone), and with
// `cross` each side's echo feeds the other (ping-pong).
//
//   lead:insert("delay", {time: 375, feedback: 0.45, mix: 0.3})
//   echo:insert("delay", {time: 500, cross: true, mix: 1})   // on a bus: all wet
local kernel = require("kernel")
local param = require("studio/param")

kernel {
  struct Tape {
    at: int32,
    primed: int32,
    time: double, // samples, gliding to the knob
    tl: double,
    tr: double,
    mix: double,
  }

  func run(
    l: float[], r: float[], start: int, n: int, st: Tape, p: double[],
    base: int, sr: double, dl: float[], dr: float[]
  ){
    local size = len(dl)
    local goal = clamp(p[base] * 0.001 * sr, 1.0, float(size - 4))
    local fb = clamp(p[base + 1], 0.0, 0.98)
    local tone = p[base + 2]
    local tc = 0.02 + tone * tone * 0.9
    local mix_to = p[base + 3]
    local cross = p[base + 4] >= 0.5
    if(st.primed == 0){
      st.primed = 1
      st.time = goal
      st.mix = mix_to
    }
    local dmix = (mix_to - st.mix) / float(n)
    local mix = st.mix
    // the time glides: about a fifth of a second to arrive
    local slide = 1.0 - exp(-1.0 / (sr * 0.05))
    local at = st.at
    for(local i = start; i < start + n; i += 1){
      st.time += (goal - st.time) * slide
      mix += dmix
      local rp = float(at) - st.time
      if(rp < 0.0){
        rp += float(size)
      }
      local i0 = int(rp)
      local f = rp - float(i0)
      local i1 = (i0 + 1) % size
      local el = dl[i0] * (1.0 - f) + dl[i1] * f
      local er = dr[i0] * (1.0 - f) + dr[i1] * f
      st.tl += (el - st.tl) * tc
      st.tr += (er - st.tr) * tc
      local x = l[i]
      local y = r[i]
      if(cross){
        dl[at] = x + st.tr * fb
        dr[at] = y + st.tl * fb
      } else {
        dl[at] = x + st.tl * fb
        dr[at] = y + st.tr * fb
      }
      at = (at + 1) % size
      l[i] = x * (1.0 - mix) + el * mix
      r[i] = y * (1.0 - mix) + er * mix
    }
    st.at = at
    st.mix = mix_to
  }
}

local params = param.set({
  {name: "time", min: 1.0, max: 2000.0, default: 375.0, unit: "ms", curve: 2.0},
  {name: "feedback", min: 0.0, max: 0.98, default: 0.4},
  {name: "tone", min: 0.0, max: 1.0, default: 0.5},
  {name: "mix", min: 0.0, max: 1.0, default: 0.3},
  {name: "cross", kind: "switch", default: 0},
})

return {
  name: "delay",
  kind: "effect",
  params: params,
  new: func(ctx){
    local st = Tape:new()
    local sr = ctx.sample_rate * 1.0
    local size = to_int(sr * 2.1)
    local dl = kernel.float:array(size)
    local dr = kernel.float:array(size)
    local p = ctx.params
    local base = ctx.base
    return {
      render: func(l, r, start, n){
        run(l, r, start, n, st, p, base, sr, dl, dr)
      },
    }
  },
}
