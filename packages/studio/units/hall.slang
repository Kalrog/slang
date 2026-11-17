extension "kernel/syntax"
// studio/units/hall: a reverb for long tails: a feedback delay network of
// eight lines that mix into each other at every turn, so the echoes grow
// dense instead of ringing at the lines' own lengths as combs do. The
// sound first passes a predelay and four diffusers (which smear a click
// into a burst); in the loop each line is damped (highs die first) and two
// of them are read at a slowly moving place, which keeps a long tail from
// sounding metallic.
//
//   local hall = s:bus("hall")
//   hall:insert("hall", {decay: 3500, size: 0.7, mix: 1})
//   pad:send(hall, 0.4)
//
// decay is the time the tail takes to fall by 60 dB.
local kernel = require("kernel")
local math = require("slang/math")
local param = require("studio/param")

kernel {
  struct Hall {
    at: int32,
    primed: int32,
    lfo: double,
    mix: double,
    dc_l: double,
    dc_r: double,
  }

  local LINES = 8
  local LINE = 16384 // floats per line
  local PRE = 16384 // the predelay's
  local DIFF = 2048 // each diffuser's

  local func diffuse(mem: float[], at0: int, n: int, at: int, x: float): float {
    local i = at0 + at % n
    local b = mem[i]
    local y = b - x * 0.6
    mem[i] = x + y * 0.6
    return y
  }

  // lens: each line's length in samples; gains: its feedback gain; lp:
  // its damping filter's state; mem: the lines, then the predelay (two
  // sides), then four diffusers
  func run(
    l: float[], r: float[], start: int, n: int, st: Hall, p: double[],
    base: int, sr: double, lens: int32[], gains: double[], lp: double[],
    mem: float[], tmp: double[]
  ){
    local damp = clamp(p[base + 2], 0.0, 1.0)
    // the damping filter: from 16 kHz (0) down to 1 kHz (1)
    local dc = 1.0 - exp(-TAU * 16000.0 * exp2(-4.0 * damp) / sr)
    local pre = int(clamp(p[base + 3] * 0.001 * sr, 0.0, float(PRE - 2)))
    local depth = p[base + 4] * 0.0007 * sr
    local mix_to = p[base + 5]
    if(st.primed == 0){
      st.primed = 1
      st.mix = mix_to
    }
    local dmix = (mix_to - st.mix) / float(n)
    local mix = st.mix
    local at = st.at
    local pre0 = LINES * LINE
    local dif0 = pre0 + PRE * 2
    local scale = sr / 48000.0
    local d0 = int(142.0 * scale)
    local d1 = int(107.0 * scale)
    local d2 = int(379.0 * scale)
    local d3 = int(277.0 * scale)
    local lfo_inc = 0.31 / sr
    for(local i = start; i < start + n; i += 1){
      mix += dmix
      // the predelay
      local pa = pre0 + at % PRE
      mem[pa] = l[i]
      mem[pa + PRE] = r[i]
      local pr = pre0 + (at - pre) % PRE
      local x = mem[pr]
      local y = mem[pr + PRE]
      // the diffusers: two a side
      x = diffuse(mem, dif0, d0, at, x)
      x = diffuse(mem, dif0 + DIFF, d2, at, x)
      y = diffuse(mem, dif0 + DIFF * 2, d1, at, y)
      y = diffuse(mem, dif0 + DIFF * 3, d3, at, y)
      // what the lines give back, damped; two of them read where the LFO
      // has them
      st.lfo += lfo_inc
      if(st.lfo >= 1.0){
        st.lfo -= 1.0
      }
      local wob = sin(st.lfo * TAU) * depth
      local sum = 0.0
      for(local k = 0; k < LINES; k += 1){
        local len_k = lens[k]
        local out = 0.0
        if(k < 2 and depth > 0.0){
          local back = float(len_k) + select(k == 0, wob, -wob)
          local rp = float(at) - back
          local i0 = int(floor(rp))
          local f = rp - floor(rp)
          out = mem[k * LINE + i0 % LINE] * (1.0 - f) +
            mem[k * LINE + (i0 + 1) % LINE] * f
        } else {
          out = mem[k * LINE + (at - len_k) % LINE]
        }
        lp[k] += (out - lp[k]) * dc
        tmp[k] = lp[k]
        sum += lp[k]
      }
      // each line gets its own back less a quarter of the sum (a
      // Householder reflection: every line feeds every other, and nothing
      // is lost or gained), and the input, alternating sides
      sum *= 2.0 / float(LINES)
      local wl = 0.0
      local wr = 0.0
      for(local k = 0; k < LINES; k += 1){
        local v = tmp[k]
        if((k & 1) == 0){
          wl += select((k & 2) == 0, v, -v)
          mem[k * LINE + at % LINE] = (v - sum) * gains[k] + x
        } else {
          wr += select((k & 2) == 0, v, -v)
          mem[k * LINE + at % LINE] = (v - sum) * gains[k] + y
        }
      }
      at += 1
      // nothing below 20 Hz comes out
      st.dc_l += (wl - st.dc_l) * 0.0026
      st.dc_r += (wr - st.dc_r) * 0.0026
      wl = (wl - st.dc_l) * 0.35
      wr = (wr - st.dc_r) * 0.35
      l[i] = l[i] * (1.0 - mix) + wl * mix
      r[i] = r[i] * (1.0 - mix) + wr * mix
    }
    st.at = at % 1073741824
    st.mix = mix_to
  }
}

local params = param.set({
  {name: "size", min: 0.0, max: 1.0, default: 0.5},
  {
    name: "decay", min: 200.0, max: 20000.0, default: 2200.0, unit: "ms",
    curve: 3.0
  },
  {name: "damp", min: 0.0, max: 1.0, default: 0.45},
  {name: "predelay", min: 0.0, max: 250.0, default: 12.0, unit: "ms"},
  {name: "mod", min: 0.0, max: 1.0, default: 0.3},
  {name: "mix", min: 0.0, max: 1.0, default: 0.25},
})
local P = params.index

// the lines' lengths in milliseconds at size 0.5: mutually prime as
// samples, spread so that no two beat together
local LENGTHS = {29.7, 37.1, 41.1, 43.7, 53.3, 61.9, 67.3, 73.7}

return {
  name: "hall",
  kind: "effect",
  params: params,
  new: func(ctx){
    local st = Hall:new()
    local sr = ctx.sample_rate * 1.0
    local p = ctx.params
    local base = ctx.base
    local lens = kernel.int32:array(8)
    local gains = kernel.double:array(8)
    local lp = kernel.double:array(8)
    local tmp = kernel.double:array(8)
    local mem = kernel.float:array(8 * 16384 + 2 * 16384 + 4 * 2048)
    local dirty = true
    // the lengths by size (half to twice as long), each line's gain by
    // the decay: a line n samples long loses 60 dB in `decay`
    local func derive(){
      local stretch = math.exp(math.log(2) * (p[base + P.size] * 2 - 1))
      local t60 = p[base + P.decay] * 0.001
      for(local k = 0; k < 8; k = k + 1){
        local n = to_int(LENGTHS[k] * 0.001 * sr * stretch)
        // an odd length: the lines stay out of step
        n = math.min(n | 1, 16000)
        lens[k] = n
        gains[k] = math.exp(math.log(10) * (-3.0 * n / (t60 * sr)))
      }
      dirty = false
    }
    return {
      set: func(i, value){
        if(i == P.size or i == P.decay){
          dirty = true
        }
      },
      render: func(l, r, start, n){
        if(dirty){
          derive()
        }
        run(l, r, start, n, st, p, base, sr, lens, gains, lp, mem, tmp)
      },
    }
  },
}
