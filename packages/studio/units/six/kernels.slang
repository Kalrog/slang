extension "kernel/syntax"
// studio/units/six/kernels: the sound of the six unit. Every sample is
// computed by kernels, slang only decides per segment what they do.
//
// - control (once a block, every voice): the operators' envelopes and the
//   pitch envelope move by the block's time; each operator's phase
//   increment and the amplitude it ramps to by the block's end follow.
// - render (per voice): six sine operators wired as the voice's algorithm,
//   summed into the output. There is one render kernel per algorithm in
//   render.kernel, which tool/gen_six.slang generates from
//   algorithms.slang: the routing is fixed in each, so an operator's
//   inputs are plain additions.
// - clear, finish: the segment's start and end (a soft limiter into both
//   sides of the track).
//
// Units: phases in cycles (0..1); a modulator's output is a phase offset in
// cycles, MOD at full level; envelope levels 0..99, 8 of them a doubling
// of gain (0.75 dB each).
local algorithms = require("studio/units/six/algorithms")
local render = require("studio/units/six/render")

local kernels = {}

// a modulator at full level moves its target's phase by MOD cycles (an
// index of 4 pi)
kernels.MOD = 2.0

kernel {
  use "studio/units/six/voice"

  // an envelope's next stage, after reaching the target of stage s
  local func next_stage(s: int): int {
    if(s == 2){
      return 3
    }
    return s + 1
  }

  func control(ops: OpState[], voices: Voice[], b: Block){
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

  func clear(out: float[], n: int){
    for(local i = 0; i < n; i += 1){
      out[i] = 0
    }
  }

  // the mix through a soft limiter into frames start .. start + n - 1 of
  // l and r (the voices are mono: both the same)
  func finish(
    out: float[], n: int, gain: float, l: float[], r: float[], start: int
  ){
    for(local i = 0; i < n; i += 1){
      local s = tanh(out[i] * gain)
      l[start + i] = s
      r[start + i] = s
    }
  }
}

// load() -> the kernels: {control, clear, finish, render: {[a]: kernel},
// OpState, Voice, Block (struct types)}
func kernels.load(){
  local m = {
    control: control,
    clear: clear,
    finish: finish,
    OpState: OpState,
    Voice: Voice,
    Block: Block,
    render: {},
  }
  for(local a = 1; a <= algorithms.count; a = a + 1){
    m.render[a] = render[concat("render", string(a))]
  }
  return m
}

return kernels
