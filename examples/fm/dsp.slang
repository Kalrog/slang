// The sound, as kernels (packages/kernel): every sample is computed by
// kernels, slang only decides per block what they do.
//
// - control (once a block, every voice): the operators' envelopes and the
//   pitch envelope move by the block's time; each operator's phase
//   increment and the amplitude it ramps to by the block's end follow.
// - render (per voice): six sine operators wired as the voice's algorithm,
//   summed into the output. There is one render kernel per algorithm,
//   generated from algorithms.slang: the routing is fixed in each, so an
//   operator's inputs are plain additions.
// - clear, finish: the block's start and end (a soft limiter, and the
//   oscilloscope's copy).
//
// Units: phases in cycles (0..1); a modulator's output is a phase offset in
// cycles, MOD at full level; envelope levels 0..99, 8 of them a doubling
// of gain (0.75 dB each).
local str = require("slang/string")
local kernel = require("kernel")
local algorithms = require("algorithms")

local dsp = {}

// a modulator at full level moves its target's phase by MOD cycles (an
// index of 4 pi)
dsp.MOD = 2.0
// a single carrier at full level, before the voice's share of the mix
dsp.CARRIER_GAIN = 0.25

local common = """
// one operator of one voice (six in a row per voice)
struct OpState {
  phase: double, inc: double, amp: double, damp: double,
  base: double,            // the phase increment at the voice's pitch
  fixed: int32,            // 1: a fixed frequency (pitch changes pass by)
  level: double,           // the envelope, 0..99
  stage: int32,            // 0..2 toward l1..l3, 3 held, 4 released, 5 done
  r1: double, r2: double, r3: double, r4: double,   // speeds, levels/s
  l1: double, l2: double, l3: double, l4: double,
  offset: double,          // gain in octaves: level, velocity, key scaling
  ams: double,             // gain in octaves the LFO takes at full depth
  scale: double,           // 1 for a carrier, MOD for a modulator, 0 off
  carrier: int32,
}

struct Voice {
  active: int32, gate: int32, age: double,
  y1: double, y2: double, fb: double,      // feedback: the last outputs
  pitch: double, pstage: int32,            // the pitch envelope, 0..99
  pr1: double, pr2: double, pr3: double, pr4: double,
  pl1: double, pl2: double, pl3: double, pl4: double,
}

// what is the same for every voice in a block
struct Block {
  n: int32, dt: double,
  bend: double,            // semitones
  lfo: double,             // -1..1
  lfo_am: double,          // 0..1
  pmd: double,             // semitones at full LFO
  amd: double,             // 0..1
  delay: double,           // seconds before the LFO fades in
}
"""

local control = """
// an envelope's next stage, after reaching the target of stage s
func next_stage(s: int): int {
  if(s == 2){
    return 3
  }
  return s + 1
}

kernel func control(ops: OpState[], voices: Voice[], b: Block){
  local dt = b.dt
  local n = float(b.n)
  for(local v = 0; v < len(voices); v += 1){
    local vo = voices[v]
    if(vo.active == 0){
      continue
    }
    vo.age += dt
    // the pitch envelope: 50 is the key's pitch, 0 and 99 two octaves off
    local ps = vo.pstage
    if(vo.gate == 0 and ps < 4){
      ps = 4
    }
    if(ps != 3 and ps != 5){
      local target = vo.pl1
      local speed = vo.pr1
      if(ps == 1){
        target = vo.pl2
        speed = vo.pr2
      } else if(ps == 2){
        target = vo.pl3
        speed = vo.pr3
      } else if(ps == 4){
        target = vo.pl4
        speed = vo.pr4
      }
      local p = vo.pitch
      if(p < target){
        p = min(p + speed * dt, target)
      } else {
        p = max(p - speed * dt, target)
      }
      if(p == target){
        ps = next_stage(ps)
      }
      vo.pitch = p
    }
    vo.pstage = ps
    // the LFO, faded in after its delay
    local fade = clamp((vo.age - b.delay) / (b.delay * 0.5 + 0.01), 0, 1)
    local semis = b.bend + (vo.pitch - 50) * 0.48 + b.lfo * b.pmd * fade
    local mul = exp2(semis / 12)
    local am = b.lfo_am * b.amd * fade
    local loud = false
    for(local k = 0; k < 6; k += 1){
      local o = ops[v * 6 + k]
      local st = o.stage
      if(vo.gate == 0 and st < 4){
        st = 4
      }
      if(st != 3 and st != 5){
        local target = o.l1
        local speed = o.r1
        if(st == 1){
          target = o.l2
          speed = o.r2
        } else if(st == 2){
          target = o.l3
          speed = o.r3
        } else if(st == 4){
          target = o.l4
          speed = o.r4
        }
        local lv = o.level
        if(lv < target){
          // an attack skips the inaudible bottom of the range
          if(lv < 40 and target > 40){
            lv = 40
          }
          lv = min(lv + speed * dt, target)
        } else {
          lv = max(lv - speed * dt, target)
        }
        if(lv == target){
          st = next_stage(st)
        }
        o.level = lv
      }
      o.stage = st
      if(o.fixed == 1){
        o.inc = o.base
      } else {
        o.inc = o.base * mul
      }
      local goal = 0.0
      if(o.level > 0.5 and o.scale > 0){
        goal = exp2((o.level - 99) / 8 + o.offset - o.ams * am) * o.scale
      }
      o.damp = (goal - o.amp) / n
      if(o.carrier == 1 and (goal > 0.00002 or o.amp > 0.00002)){
        loud = true
      }
    }
    // a released voice ends when its carriers are silent
    if(vo.gate == 0 and not loud){
      vo.active = 0
      for(local k = 0; k < 6; k += 1){
        local o = ops[v * 6 + k]
        o.amp = 0
        o.damp = 0
        o.level = 0
      }
    }
  }
}

kernel func clear(out: float[], n: int){
  for(local i = 0; i < n; i += 1){
    out[i] = 0
  }
}

// the mix through a soft limiter, and into the oscilloscope's ring (whose
// last cell says where the next sample goes); returns the ring's position
kernel func finish(out: float[], n: int, gain: float, scope: float[], at: int): int {
  local size = len(scope) - 1
  for(local i = 0; i < n; i += 1){
    local s = tanh(out[i] * gain)
    out[i] = s
    scope[at] = s
    at += 1
    if(at >= size){
      at = 0
    }
  }
  return at
}
"""

// the render kernel of algorithm number a: "render<a>"
local func render_source(a, number){
  local alg = algorithms.get(number)
  local lines = {}
  local func add(...parts){
    local s = ""
    for(let local p in values(parts)){
      s = concat(s, string(p))
    }
    append(lines, s)
  }
  add("kernel func render", number, "(out: float[], ops: OpState[], voices: Voice[], v: int, n: int){")
  add("  local b = v * 6")
  for(local k = 1; k <= 6; k = k + 1){
    add("  local o", k, " = ops[b + ", k - 1, "]")
    add("  local p", k, " = o", k, ".phase")
    add("  local i", k, " = o", k, ".inc")
    add("  local a", k, " = o", k, ".amp")
    add("  local d", k, " = o", k, ".damp")
  }
  add("  local vo = voices[v]")
  add("  local y1 = vo.y1")
  add("  local y2 = vo.y2")
  add("  local fb = vo.fb")
  add("  for(local i = 0; i < n; i += 1){")
  for(local k = 6; k >= 1; k = k - 1){
    // the phase offset: the modulators' outputs, and the feedback
    local inputs = {}
    for(let local m in values(alg.mods[k])){
      append(inputs, concat("x", string(m)))
    }
    if(alg.fb_to == k){
      append(inputs, "(y1 + y2) * fb")
    }
    local phase = concat("p", string(k))
    if(len(inputs) > 0){
      phase = concat("p", string(k), " + ", str.join(inputs, " + "))
    }
    add("    p", k, " = fract(p", k, " + i", k, ")")
    add("    local x", k, " = sin((", phase, ") * TAU) * a", k)
    add("    a", k, " += d", k)
    if(alg.fb_from == k){
      add("    y2 = y1")
      add("    y1 = x", k)
    }
  }
  local carriers = {}
  for(let local c in values(alg.carriers)){
    append(carriers, concat("x", string(c)))
  }
  // the carriers share the voice's level: more of them, each softer
  local gain = dsp.CARRIER_GAIN / (len(alg.carriers) ^ 0.5)
  add("    out[i] += (", str.join(carriers, " + "), ") * ", gain)
  add("  }")
  for(local k = 1; k <= 6; k = k + 1){
    add("  o", k, ".phase = p", k)
    add("  o", k, ".amp = a", k)
  }
  add("  vo.y1 = y1")
  add("  vo.y2 = y2")
  add("}")
  return str.join(lines, "\n")
}

// source() -> the kernel source of everything: structs, control, the 32
// render kernels
func dsp.source(){
  local parts = {common, control}
  for(local a = 1; a <= algorithms.count; a = a + 1){
    append(parts, render_source(a, a))
  }
  return str.join(parts, "\n")
}

// load() -> the compiled kernels: {control, clear, finish, render: {[a]:
// kernel}, OpState, Voice, Block (struct types)}
func dsp.load(){
  local m = kernel.compile(dsp.source(), "fm/dsp")
  m.render = {}
  for(local a = 1; a <= algorithms.count; a = a + 1){
    m.render[a] = m[concat("render", string(a))]
  }
  return m
}

return dsp
