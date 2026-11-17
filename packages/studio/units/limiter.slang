extension "kernel/syntax"
// studio/units/limiter: nothing comes out louder than the ceiling. It
// looks five milliseconds ahead (and is that late), so it has turned down
// before a peak arrives instead of clipping it; `gain` drives the sound
// into it, for loudness.
//
//   s.master:insert("limiter")
local kernel = require("kernel")
local param = require("studio/param")

kernel {
  struct Limiter {
    at: int32,
    hold: int32,
    target: double = 1,
    gain: double = 1,
  }

  local DB = 6.020599913279624

  // dl, dr: the lookahead (their length is how far)
  func run(
    l: float[], r: float[], start: int, n: int, st: Limiter, p: double[],
    base: int, rate: double, dl: float[], dr: float[], meters: double[],
    at_meter: int
  ){
    local ahead = len(dl)
    local pre = exp2(p[base] / DB)
    local top = exp2(p[base + 1] / DB)
    local rel = 1.0 - exp(-1.0 / (max(p[base + 2], 1.0) * 0.001 * rate))
    // down within the lookahead: four time constants of it
    local att = 1.0 - exp(-4.0 / float(ahead))
    local at = st.at
    local least = 1.0
    for(local i = start; i < start + n; i += 1){
      local x = l[i] * pre
      local y = r[i] * pre
      local peak = max(abs(x), abs(y))
      local need = 1.0
      if(peak > top){
        need = top / peak
      }
      if(need <= st.target){
        st.target = need
        st.hold = ahead
      } else if(st.hold > 0){
        st.hold -= 1
      } else {
        st.target += (1.0 - st.target) * rel
      }
      if(st.target < st.gain){
        st.gain += (st.target - st.gain) * att
      } else {
        st.gain = st.target
      }
      least = min(least, st.gain)
      local a = dl[at]
      local b = dr[at]
      dl[at] = x
      dr[at] = y
      at = (at + 1) % ahead
      l[i] = clamp(a * st.gain, -top, top)
      r[i] = clamp(b * st.gain, -top, top)
    }
    st.at = at
    meters[at_meter] = -DB * log2(least)
  }
}

local params = param.set({
  {name: "gain", min: 0.0, max: 24.0, default: 0.0, unit: "dB"},
  {name: "ceiling", min: -12.0, max: 0.0, default: -0.3, unit: "dB"},
  {
    name: "release", min: 5.0, max: 1000.0, default: 80.0, unit: "ms",
    curve: 3.0
  },
})

return {
  name: "limiter",
  kind: "effect",
  params: params,
  new: func(ctx){
    local st = Limiter:new()
    local rate = ctx.sample_rate * 1.0
    local ahead = to_int(rate * 0.005)
    local dl = kernel.float:array(ahead)
    local dr = kernel.float:array(ahead)
    local p = ctx.params
    local base = ctx.base
    local meters = ctx.meters
    local at = ctx.meter + 3
    return {
      render: func(l, r, start, n){
        run(l, r, start, n, st, p, base, rate, dl, dr, meters, at)
      },
    }
  },
}
