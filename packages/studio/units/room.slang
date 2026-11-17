extension "kernel/syntax"
// studio/units/room: a small reverb of four combs into two allpasses a
// side, the one the live and modular examples use, here in stereo (the
// right side's lines are a little longer). Cheap, and good for a room;
// "hall" is the one for long tails.
//
//   local rev = s:bus("room")
//   rev:insert("room", {size: 0.6, mix: 1})
//   snare:send(rev, 0.25)
local kernel = require("kernel")
local param = require("studio/param")

kernel {
  struct Room {
    at: int32,
    f0: double,
    f1: double,
    f2: double,
    f3: double,
    g0: double,
    g1: double,
    g2: double,
    g3: double,
  }

  local LINE = 4096

  // one comb of mem (LINE floats from at0), n samples long: returns what
  // comes out, takes x and the damped feedback
  local func comb(
    mem: float[], at0: int, n: int, at: int, x: float, fb: float
  ): float {
    local y = mem[at0 + at % n]
    mem[at0 + at % n] = x + fb
    return y
  }

  local func allpass(mem: float[], at0: int, n: int, at: int, x: float): float {
    local b = mem[at0 + at % n]
    mem[at0 + at % n] = x + b * 0.5
    return b - x
  }

  func run(
    l: float[], r: float[], start: int, n: int, st: Room, p: double[],
    base: int, sr: double, mem: float[]
  ){
    local scale = sr / 44100.0
    local n0 = int(1116.0 * scale)
    local n1 = int(1188.0 * scale)
    local n2 = int(1277.0 * scale)
    local n3 = int(1356.0 * scale)
    local m0 = int(556.0 * scale)
    local m1 = int(441.0 * scale)
    local wide = int(23.0 * scale)
    local fb = 0.7 + clamp(p[base], 0.0, 1.0) * 0.28
    local damp = clamp(p[base + 1], 0.0, 1.0) * 0.4
    local mix = p[base + 2]
    local at = st.at
    for(local i = start; i < start + n; i += 1){
      // the input scaled down, as Freeverb does: the combs add up
      local x = l[i] * 0.04
      local y = r[i] * 0.04
      local a = comb(mem, 0, n0, at, x, st.f0 * fb)
      st.f0 = a * (1.0 - damp) + st.f0 * damp
      local b = comb(mem, LINE, n1, at, x, st.f1 * fb)
      st.f1 = b * (1.0 - damp) + st.f1 * damp
      local c = comb(mem, LINE * 2, n2, at, x, st.f2 * fb)
      st.f2 = c * (1.0 - damp) + st.f2 * damp
      local d = comb(mem, LINE * 3, n3, at, x, st.f3 * fb)
      st.f3 = d * (1.0 - damp) + st.f3 * damp
      local wl = allpass(mem, LINE * 8, m0, at, a + b + c + d)
      wl = allpass(mem, LINE * 9, m1, at, wl)
      a = comb(mem, LINE * 4, n0 + wide, at, y, st.g0 * fb)
      st.g0 = a * (1.0 - damp) + st.g0 * damp
      b = comb(mem, LINE * 5, n1 + wide, at, y, st.g1 * fb)
      st.g1 = b * (1.0 - damp) + st.g1 * damp
      c = comb(mem, LINE * 6, n2 + wide, at, y, st.g2 * fb)
      st.g2 = c * (1.0 - damp) + st.g2 * damp
      d = comb(mem, LINE * 7, n3 + wide, at, y, st.g3 * fb)
      st.g3 = d * (1.0 - damp) + st.g3 * damp
      local wr = allpass(mem, LINE * 10, m0 + wide, at, a + b + c + d)
      wr = allpass(mem, LINE * 11, m1 + wide, at, wr)
      l[i] = l[i] * (1.0 - mix) + wl * mix
      r[i] = r[i] * (1.0 - mix) + wr * mix
      at += 1
    }
    // (the counter wraps where every line's length divides nothing: far)
    st.at = at % 1073741824
  }
}

local params = param.set({
  {name: "size", min: 0.0, max: 1.0, default: 0.5},
  {name: "damp", min: 0.0, max: 1.0, default: 0.5},
  {name: "mix", min: 0.0, max: 1.0, default: 0.25},
})

return {
  name: "room",
  kind: "effect",
  params: params,
  new: func(ctx){
    local st = Room:new()
    local sr = ctx.sample_rate * 1.0
    local mem = kernel.float:array(4096 * 12)
    local p = ctx.params
    local base = ctx.base
    return {
      render: func(l, r, start, n){
        run(l, r, start, n, st, p, base, sr, mem)
      },
    }
  },
}
