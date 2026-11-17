extension "kernel/syntax"
// studio/units/compressor: what is louder than the threshold is turned
// down by the ratio (4: four dB over come out as one), smoothly around the
// threshold (knee), after `attack` and for `release` afterwards; makeup
// turns the whole up again. It listens to its own strip, or with
// `sidechain: track` to another track: a pad that ducks on every kick.
//
//   drums:insert("compressor", {threshold: -18, ratio: 4, makeup: 4})
//   pad:insert("compressor", {sidechain: kick, threshold: -30, ratio: 10, release: 250})
//   pad.reduction      // dB it takes off right now
local param = require("studio/param")

kernel {
  struct Comp { env: double }

  local DB = 6.020599913279624 // dB in a doubling

  // sl, sr: what it listens to; meters[at]: the most it took off, in dB
  func run(
    l: float[], r: float[], start: int, n: int, st: Comp, p: double[],
    base: int, rate: double, sl: float[], sr: float[], meters: double[], at: int
  ){
    local thr = p[base]
    local slope = 1.0 - 1.0 / max(p[base + 1], 1.0)
    local att = 1.0 - exp(-1.0 / (max(p[base + 2], 0.05) * 0.001 * rate))
    local rel = 1.0 - exp(-1.0 / (max(p[base + 3], 1.0) * 0.001 * rate))
    local knee = p[base + 4]
    local makeup = p[base + 5]
    local mix = p[base + 6]
    local env = st.env
    local most = 0.0
    for(local i = start; i < start + n; i += 1){
      local x = max(abs(sl[i]), abs(sr[i]))
      local over = DB * log2(max(x, 0.000000001)) - thr
      local want = 0.0
      if(over >= knee * 0.5){
        want = over * slope
      } else if(over > -knee * 0.5){
        local t = over + knee * 0.5
        want = slope * t * t / (2.0 * knee)
      }
      if(want > env){
        env += (want - env) * att
      } else {
        env += (want - env) * rel
      }
      most = max(most, env)
      local g = exp2((makeup - env) / DB)
      l[i] = l[i] * (1.0 - mix) + l[i] * g * mix
      r[i] = r[i] * (1.0 - mix) + r[i] * g * mix
    }
    st.env = env
    meters[at] = most
  }
}

local params = param.set({
  {name: "threshold", min: -60.0, max: 0.0, default: -18.0, unit: "dB"},
  {name: "ratio", min: 1.0, max: 20.0, default: 4.0, curve: 2.0},
  {
    name: "attack", min: 0.05, max: 200.0, default: 10.0, unit: "ms", curve: 3.0
  },
  {
    name: "release", min: 5.0, max: 2000.0, default: 150.0, unit: "ms",
    curve: 3.0
  },
  {name: "knee", min: 0.0, max: 24.0, default: 6.0, unit: "dB"},
  {name: "makeup", min: 0.0, max: 24.0, default: 0.0, unit: "dB"},
  {name: "mix", min: 0.0, max: 1.0, default: 1.0},
})

local patches = {
  {
    name: "Gentle", threshold: -20, ratio: 2, attack: 20, release: 200,
    knee: 12, makeup: 3
  },
  {
    name: "Drums", threshold: -16, ratio: 5, attack: 8, release: 90, knee: 6,
    makeup: 5
  },
  {
    name: "Glue", threshold: -14, ratio: 3, attack: 30, release: 300, knee: 10,
    makeup: 2
  },
  {name: "Duck", threshold: -34, ratio: 12, attack: 2, release: 220, knee: 4},
  {
    name: "Parallel", threshold: -36, ratio: 12, attack: 3, release: 80,
    knee: 6, makeup: 12, mix: 0.4
  },
}

return {
  name: "compressor",
  kind: "effect",
  params: params,
  patches: patches,
  new: func(ctx){
    local st = Comp:new()
    local rate = ctx.sample_rate * 1.0
    local p = ctx.params
    local base = ctx.base
    local meters = ctx.meters
    local at = ctx.meter + 3
    return {
      render: func(l, r, start, n, sl, sr){
        run(l, r, start, n, st, p, base, rate, sl, sr, meters, at)
      },
    }
  },
}
