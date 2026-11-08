extension "kernel/syntax"
// The sound of the modular: every module of the rack, rendered by one
// kernel (packages/kernel). The patch is data in shared buffers that the
// rack (rack.slang) writes and the kernel reads at every sample: the kind
// of each module slot, where each input is patched from, the knobs, the
// sequencers' steps and the song chain. Patching never compiles anything:
// a cable is an index written into a buffer.
//
// Signals: every module has NO outputs, each a cell of `sig`; an input
// holds the index of the cell it reads, or -1. Modules run in the order
// the rack gives (sources before what they feed; a cable backwards reads
// the previous sample, so feedback patches work). Units: audio -1..1,
// pitch in octaves from C4 (1 V/oct), gates 0 or 1, envelopes 0..1.
//
// engine.new runs in the render isolate of raylib/stream and returns the
// block function; engine.offline makes one for rendering a song to a file.
local kernel = require("kernel")
local buffer = require("slang/buffer")
local os = require("slang/os")

local engine = {}

// the sizes the rack and the kernel agree on
engine.MAX = 32        // module slots
engine.NI = 8          // inputs per module
engine.NO = 6          // outputs per module
engine.NP = 12         // parameters per module
engine.SEQW = 512      // ints of sequencer data per module
engine.MEM = 65536     // floats of delay memory per module
engine.STATUS = 4      // doubles of status per module
engine.SONG = 33       // the song chain: its length, then up to 32 patterns
engine.SCOPE = 1024    // samples kept for the output's trace
engine.SCOPE_W = 96     // columns of a SCOPE module's capture (least and most each)
engine.FMW = 180       // doubles of FM patch data per module (see engine.fm)

// the kinds, by the number in the rack's `kinds` buffer
engine.kinds = {
  EMPTY: 0, OUT: 1, VCO: 2, LFO: 3, ADSR: 4, VCF: 5, VCA: 6, MIX: 7, NOISE: 8,
  DELAY: 9, REVERB: 10, SEQ: 11, TRIGS: 12, DRUMS: 13, CLOCK: 14, KBD: 15,
  QUANT: 16, MATH: 17, SCOPE: 18, SH: 19, CRUSH: 20, FM: 21, TR808: 22,
}

// the cells of an FM module's patch in `fmdata` (FMW per module): the six
// operators' fields in the order of fm/patch.slang's OP_FIELDS (OPW each),
// the voice's in VOICE_FIELDS' order from VOICE, then what the rack
// derives from the algorithm: a version that changes with every edit (the
// kernel re-applies the patch to a sounding note), each operator's up to
// three modulators (operator indices, -1 for none), the feedback's source
// and target, and which operators are carriers
engine.fm = {OPW: 22, VOICE: 132, VERSION: 151, ROUTE: 152, FB_FROM: 170, FB_TO: 171, CARRIER: 172}

// the cells of `live`: what the player does, written by the window (or a
// MIDI controller in the render isolate)
engine.live = {PITCH: 0, GATE: 1, VEL: 2, WHEEL: 3, RUN: 4, PATTERN: 5, COUNT: 8}

// ------------------------------------------------------------ the kernel

kernel {
  // the state of one module; which fields a kind uses is said at its code
  struct Mod {
    phase: double, phase2: double,
    y1: double, y2: double, y3: double, y4: double,
    z1: double, z2: double, z3: double,
    env: double, held: double,
    a: double, b: double, c: double, d: double,
    stage: int32, gate: int32, clk: int32, rst: int32,
    step: int32, fresh: int32, counter: int32, period: int32, since: int32,
    w: int32, p1: int32, p2: int32, p3: int32, p4: int32, q1: int32, q2: int32,
    rnd: int64,
  }

  // one operator of an FM module (six per slot): a sine with an envelope of
  // four rates and levels (0..99, 8 a doubling of gain), wired by the
  // algorithm (m0..m2: its modulators, fbin/fbout: the feedback loop).
  // Phases are in cycles; a modulator moves its target's phase by its
  // output, which at full level is MOD cycles.
  struct FmOp {
    phase: double, inc: double, amp: double, damp: double,
    ratio: double,                     // to the pitch, or a phase increment when fixed
    level: double,                     // the envelope, 0..99
    r1: double, r2: double, r3: double, r4: double,   // speeds, levels/s
    l1: double, l2: double, l3: double, l4: double,
    offset: double,                    // gain in octaves: level, velocity, key scaling
    ams: double,                       // octaves the LFO takes at full depth
    scale: double,                     // 1 a carrier, MOD a modulator, 0 off
    fixed: int32, stage: int32, carrier: int32,
    m0: int32, m1: int32, m2: int32, fbin: int32, fbout: int32,
  }

  local MAX = 32
  local NI = 8
  local NO = 6
  local NP = 12
  local SEQW = 512
  local MEM = 65536
  local CONTROL = 16
  local C4 = 261.6255653005986

  local OUT = 1
  local VCO = 2
  local LFO = 3
  local ADSR = 4
  local VCF = 5
  local VCA = 6
  local MIX = 7
  local NOISE = 8
  local DELAY = 9
  local REVERB = 10
  local SEQ = 11
  local TRIGS = 12
  local DRUMS = 13
  local CLOCK = 14
  local KBD = 15
  local QUANT = 16
  local MATH = 17
  local SCOPE = 18
  local SH = 19
  local CRUSH = 20
  local FM = 21
  local TR808 = 22
  local SCOPE_W = 96

  // the FM patch data (engine.fm) and its units
  local FMW = 180
  local OPW = 22
  local F_ON = 0
  local F_MODE = 1
  local F_COARSE = 2
  local F_FINE = 3
  local F_DETUNE = 4
  local F_LEVEL = 5
  local F_VEL = 6
  local F_RS = 7
  local F_AMS = 8
  local F_R1 = 9
  local F_L1 = 13
  local F_BREAK = 17
  local F_LDEPTH = 18
  local F_RDEPTH = 19
  local F_LCURVE = 20
  local F_RCURVE = 21
  local V_ALGORITHM = 132
  local V_FEEDBACK = 133
  local V_OSC_SYNC = 134
  local V_TRANSPOSE = 135
  local V_WAVE = 136
  local V_SPEED = 137
  local V_DELAY = 138
  local V_PMD = 139
  local V_AMD = 140
  local V_LFO_SYNC = 141
  local V_PMS = 142
  local V_PR1 = 143
  local V_PL1 = 147
  local V_VERSION = 151
  local V_ROUTE = 152
  local V_FB_FROM = 170
  local V_FB_TO = 171
  local V_CARRIER = 172
  local MOD = 2.0                    // cycles a modulator at level 99 moves its target
  local FEEDBACK_MAX = 0.3           // cycles feedback 7 moves
  local FM_GAIN = 0.5                // a single carrier at full level

  // the 808's state in its delay memory (which it has no other use for):
  // the hats' six phases, their envelope and its decay, the high pass's two
  // states, the cowbell's two phases, envelope and band pass, the clap's
  // band pass, the accent of each voice's last hit, and from D_K the
  // coefficients the control step computes
  local D_HAT = 0
  local D_HENV = 6
  local D_HDEC = 7
  local D_HP = 8
  local D_CB = 10
  local D_CBENV = 12
  local D_CBF = 13
  local D_CPF = 15
  local D_ACC = 17
  local D_K = 32

  local L_PITCH = 0
  local L_GATE = 1
  local L_VEL = 2
  local L_WHEEL = 3
  local L_RUN = 4
  local L_PATTERN = 5

  // the signals (state: slang sees them through `meters` at block end)
  local sig: double[192]
  local ctl = 0            // samples until the next control step
  local cur_pattern = 0    // the pattern the sequencers play
  local transport = 0      // 1 for the sample in which the clock started
  local scope_at = 0
  local fmx: double[8]     // an FM voice's operator outputs, this sample

  local func inp(inputs: int32[], at: int): float {
    local s = inputs[at]
    if(s < 0){
      return 0.0
    }
    return sig[s]
  }

  local func patched(inputs: int32[], at: int): bool {
    return inputs[at] >= 0
  }

  // white noise from the module's LCG, -1..1
  local func white(md: Mod): float {
    md.rnd = (md.rnd * 1103515245 + 12345) & 0x7fffffff
    return md.rnd / 1073741823.5 - 1.0
  }

  // PolyBLEP: the correction that takes the alias out of a jump at phase 0
  local func blep(t: float, dt: float): float {
    if(t < dt){
      local x = t / dt
      return x + x - x * x - 1.0
    }
    if(t > 1.0 - dt){
      local x = (t - 1.0) / dt
      return x * x + x + x + 1.0
    }
    return 0.0
  }

  // a one-pole coefficient for a time constant of t seconds
  local func coef(t: float, sr: float): float {
    return 1.0 - exp(-1.0 / (max(t, 0.0001) * sr))
  }

  local func scale_mask(i: int): int {
    if(i == 1){ return 2741 }     // major
    if(i == 2){ return 1453 }     // minor
    if(i == 3){ return 661 }      // pentatonic major
    if(i == 4){ return 1193 }     // pentatonic minor
    if(i == 5){ return 1709 }     // dorian
    if(i == 6){ return 1257 }     // blues
    if(i == 7){ return 1365 }     // whole tone
    return 4095                   // chromatic
  }

  // ---- the FM voice (after examples/fm: the same envelopes, scaling and
  // units, one voice per module, pitch and gate from the rack)

  // envelope speed in levels per second: rate 99 crosses the range in
  // 1.5 ms, rate 0 in about a minute and a half
  local func fm_speed(rate: float): float {
    return 66000.0 * exp2(-(99.0 - rate) / 6.2)
  }

  // the semitones the LFO moves at full depth, by PITCH SENS
  local func fm_pms(i: int): float {
    if(i <= 0){ return 0.0 }
    if(i == 1){ return 0.06 }
    if(i == 2){ return 0.12 }
    if(i == 3){ return 0.2 }
    if(i == 4){ return 0.35 }
    if(i == 5){ return 0.65 }
    if(i == 6){ return 1.3 }
    return 4.0
  }

  // the octaves of gain full amplitude modulation takes, by AMS
  local func fm_ams(i: int): float {
    if(i <= 0){ return 0.0 }
    if(i == 1){ return 0.5 }
    if(i == 2){ return 1.2 }
    return 3.0
  }

  // an envelope's next stage after reaching stage s's target (3 holds)
  local func fm_next(s: int): int {
    if(s == 2){
      return 3
    }
    return s + 1
  }

  // the patch of module m into its operators: ratios, envelope speeds, the
  // gain offsets of velocity and keyboard scaling for the key the note was
  // played at, the routing; with trigger the envelopes and phases start
  // again. key: a MIDI note number, vel 0..1.
  local func fm_apply(
    m: int, md: Mod, fmops: FmOp[], fmdata: double[], key: float, vel: float, trigger: bool, sr: float
  ){
    local base = m * FMW
    local fb_from = int(fmdata[base + V_FB_FROM])
    local fb_to = int(fmdata[base + V_FB_TO])
    local osc_sync = fmdata[base + V_OSC_SYNC] > 0.5
    local src_scale = 0.0
    local carriers = 0
    for(local k = 0; k < 6; k += 1){
      local o = fmops[m * 6 + k]
      local f = base + k * OPW
      local coarse = fmdata[f + F_COARSE]
      local fine = fmdata[f + F_FINE]
      local detune = exp2(fmdata[f + F_DETUNE] * 1.5 / 1200.0)
      if(fmdata[f + F_MODE] > 0.5){
        // 1, 10, 100 or 1000 Hz times 10^(fine / 100)
        o.ratio = exp2((float(int(coarse) % 4) + fine / 100.0) * 3.321928094887362) * detune / sr
        o.fixed = 1
      } else {
        local r = coarse
        if(coarse < 0.5){
          r = 0.5
        }
        o.ratio = r * (1.0 + fine / 100.0) * detune
        o.fixed = 0
      }
      // rate scaling: higher keys, faster envelopes
      local faster = fmdata[f + F_RS] * max(0.0, key - 36.0) / 12.0 * 0.8
      o.r1 = fm_speed(min(99.0, fmdata[f + F_R1] + faster))
      o.r2 = fm_speed(min(99.0, fmdata[f + F_R1 + 1] + faster))
      o.r3 = fm_speed(min(99.0, fmdata[f + F_R1 + 2] + faster))
      o.r4 = fm_speed(min(99.0, fmdata[f + F_R1 + 3] + faster))
      o.l1 = fmdata[f + F_L1]
      o.l2 = fmdata[f + F_L1 + 1]
      o.l3 = fmdata[f + F_L1 + 2]
      o.l4 = fmdata[f + F_L1 + 3]
      // gain in octaves: the output level, velocity, key level scaling
      local level = fmdata[f + F_LEVEL]
      local offset = (level - 99.0) / 8.0 + (fmdata[f + F_VEL] / 7.0) * (vel - 1.0) * 2.5
      local d = (key - fmdata[f + F_BREAK]) / 12.0
      local depth = fmdata[f + F_RDEPTH]
      local curve = int(fmdata[f + F_RCURVE])
      if(d < 0.0){
        d = -d
        depth = fmdata[f + F_LDEPTH]
        curve = int(fmdata[f + F_LCURVE])
      }
      local shape = d
      if(curve == 1 or curve == 2){
        shape = (exp2(d) - 1.0) * 0.5
      }
      local kls = depth / 99.0 * shape
      if(curve < 2){
        kls = -kls
      }
      o.offset = offset + clamp(kls, -8.0, 2.0)
      o.ams = fm_ams(int(fmdata[f + F_AMS]))
      local carrier = fmdata[base + V_CARRIER + k] > 0.5
      local scale = MOD
      if(carrier){
        scale = 1.0
        carriers += 1
      }
      if(fmdata[f + F_ON] < 0.5 or level < 0.5){
        scale = 0.0
      }
      o.scale = scale
      o.carrier = select(carrier, 1, 0)
      o.m0 = int(fmdata[base + V_ROUTE + k * 3])
      o.m1 = int(fmdata[base + V_ROUTE + k * 3 + 1])
      o.m2 = int(fmdata[base + V_ROUTE + k * 3 + 2])
      o.fbin = select(fb_to == k, 1, 0)
      o.fbout = select(fb_from == k, 1, 0)
      if(fb_from == k){
        src_scale = scale
      }
      if(trigger){
        o.stage = 0
        if(osc_sync){
          o.phase = 0
        }
      }
    }
    // feedback: the average of the source's last two outputs, which carry
    // its scale
    local feedback = fmdata[base + V_FEEDBACK]
    md.b = 0
    if(feedback > 0.5 and src_scale > 0.0){
      md.b = FEEDBACK_MAX * exp2(feedback - 7.0) * 0.5 / src_scale
    }
    // the carriers share the voice's level: more of them, each softer
    md.c = FM_GAIN / sqrt(float(max(carriers, 1)))
    if(trigger){
      md.stage = 0
      // the pitch envelope starts where its release ends
      md.env = fmdata[base + V_PL1 + 3]
      md.z2 = 0
      md.p1 = 1
      if(osc_sync){
        md.y1 = 0
        md.y2 = 0
      }
      if(fmdata[base + V_LFO_SYNC] > 0.5){
        md.phase2 = 0
      }
    }
  }

  // an envelope (level 0..99 in stage) moved by dt seconds toward its
  // stage's target; returns the level, the stage comes back in md.q2
  local func fm_env(
    md: Mod, level: float, stage: int, gate: bool, dt: float,
    r1: float, r2: float, r3: float, r4: float, l1: float, l2: float, l3: float, l4: float
  ): float {
    local st = stage
    if(not gate and st < 4){
      st = 4
    }
    if(st != 3 and st != 5){
      local target = l1
      local speed = r1
      if(st == 1){
        target = l2
        speed = r2
      } else if(st == 2){
        target = l3
        speed = r3
      } else if(st == 4){
        target = l4
        speed = r4
      }
      if(level < target){
        // an attack skips the inaudible bottom of the range
        if(level < 40.0 and target > 40.0){
          level = 40.0
        }
        level = min(level + speed * dt, target)
      } else {
        level = max(level - speed * dt, target)
      }
      if(level == target){
        st = fm_next(st)
      }
    }
    md.q2 = st
    return level
  }

  // the control step of an FM module: a new note (the gate rising) or an
  // edited patch applied, the LFO and the pitch envelope moved, every
  // operator's envelope moved and its phase increment and target amplitude
  // set; md.p1 says whether the voice sounds at all
  local func fm_control(
    m: int, md: Mod, params: double[], inputs: int32[], fmops: FmOp[], fmdata: double[], sr: float
  ){
    local base = m * FMW
    local pb = m * NP
    local ib = m * NI
    local dt = float(CONTROL) / sr
    local cv = inp(inputs, ib)
    local gate = inp(inputs, ib + 1) > 0.5
    local trigger = gate and md.gate == 0
    local version = int(fmdata[base + V_VERSION])
    if(trigger or (version != md.p4 and md.p1 == 1)){
      if(trigger){
        md.counter = int(round(60.0 + cv * 12.0))
        md.held = 1.0
        if(patched(inputs, ib + 2)){
          md.held = clamp(inp(inputs, ib + 2), 0.0, 1.0)
        }
      }
      fm_apply(m, md, fmops, fmdata, float(md.counter), md.held, trigger, sr)
    }
    md.p4 = version
    md.gate = select(gate, 1, 0)
    if(md.p1 == 0){
      return
    }
    // the LFO: triangle, saws down and up, square, sine, sample and hold
    local speed = fmdata[base + V_SPEED]
    local before = md.phase2
    md.phase2 = fract(md.phase2 + (0.05 + speed * speed * 0.005) * dt)
    local x = md.phase2
    local w = int(fmdata[base + V_WAVE])
    local lfo = 0.0
    if(w == 0){
      lfo = select(x < 0.5, 4.0 * x - 1.0, 3.0 - 4.0 * x)
    } else if(w == 1){
      lfo = 1.0 - 2.0 * x
    } else if(w == 2){
      lfo = 2.0 * x - 1.0
    } else if(w == 3){
      lfo = select(x < 0.5, 1.0, -1.0)
    } else if(w == 4){
      lfo = sin(x * TAU)
    } else {
      if(md.phase2 < before){
        md.z1 = white(md)
      }
      lfo = md.z1
    }
    md.z2 += dt
    local dl = fmdata[base + V_DELAY] / 99.0
    local delay = dl * dl * 5.0
    local fade = clamp((md.z2 - delay) / (delay * 0.5 + 0.01), 0.0, 1.0)
    // the pitch envelope: 50 is the key's pitch, 0 and 99 two octaves off
    md.env = fm_env(md, md.env, md.stage, gate, dt,
      fm_speed(fmdata[base + V_PR1]), fm_speed(fmdata[base + V_PR1 + 1]),
      fm_speed(fmdata[base + V_PR1 + 2]), fm_speed(fmdata[base + V_PR1 + 3]),
      fmdata[base + V_PL1], fmdata[base + V_PL1 + 1], fmdata[base + V_PL1 + 2], fmdata[base + V_PL1 + 3])
    md.stage = md.q2
    // vibrato: the patch's depth plus the MOD knob and input, as a wheel
    local wheel = params[pb + 2] + inp(inputs, ib + 3)
    local pmd = min(1.0, fmdata[base + V_PMD] / 99.0 + wheel) * fm_pms(int(fmdata[base + V_PMS]))
    local semis = fmdata[base + V_TRANSPOSE] + (md.env - 50.0) * 0.48 + lfo * pmd * fade
    // the phase increment of ratio 1: the pitch input, in octaves from C4
    md.a = C4 * exp2(cv + semis / 12.0) / sr
    local am = (lfo + 1.0) * 0.5 * fmdata[base + V_AMD] / 99.0 * fade
    local loud = false
    for(local k = 0; k < 6; k += 1){
      local o = fmops[m * 6 + k]
      o.level = fm_env(md, o.level, o.stage, gate, dt, o.r1, o.r2, o.r3, o.r4, o.l1, o.l2, o.l3, o.l4)
      o.stage = md.q2
      if(o.fixed == 1){
        o.inc = o.ratio
      } else {
        o.inc = min(o.ratio * md.a, 0.45)
      }
      local goal = 0.0
      if(o.level > 0.5 and o.scale > 0.0){
        goal = exp2((o.level - 99.0) / 8.0 + o.offset - o.ams * am) * o.scale
      }
      o.damp = (goal - o.amp) / float(CONTROL)
      if(o.carrier == 1 and (goal > 0.00002 or o.amp > 0.00002)){
        loud = true
      }
    }
    // a released voice ends when its carriers are silent
    if(not gate and not loud){
      md.p1 = 0
      for(local k = 0; k < 6; k += 1){
        local o = fmops[m * 6 + k]
        o.amp = 0
        o.damp = 0
        o.level = 0
        o.stage = 5
      }
    }
  }

  // a module's state back to nothing (flags[m] asks for it: a module just
  // added, or a kind changed)
  local func clear(md: Mod, m: int, sr: float){
    md.phase = 0
    md.phase2 = 0
    md.y1 = 0
    md.y2 = 0
    md.y3 = 0
    md.y4 = 0
    md.z1 = 0
    md.z2 = 0
    md.z3 = 0
    md.env = 0
    md.held = 0
    md.a = 0
    md.b = 0
    md.c = 0
    md.d = 0
    md.stage = 0
    md.gate = 0
    md.clk = 0
    md.rst = 0
    md.step = 0
    md.fresh = 1
    md.counter = 0
    md.period = int(sr * 0.125)
    md.since = 0
    md.w = 0
    md.p1 = 0
    md.p2 = 0
    md.p3 = 0
    md.p4 = 0
    md.q1 = 0
    md.q2 = 0
    md.rnd = 12345 + m * 7919
  }

  local func fm_clear(m: int, fmops: FmOp[]){
    for(local k = 0; k < 6; k += 1){
      local o = fmops[m * 6 + k]
      o.phase = 0
      o.amp = 0
      o.damp = 0
      o.level = 0
      o.stage = 5
    }
  }

  // the control step of module m: what changes every CONTROL samples (the
  // knobs read, exponentials taken) into md.a .. md.d
  local func control(
    m: int, kind: int, md: Mod, params: double[], inputs: int32[], sr: float,
    fmops: FmOp[], fmdata: double[], mem: float[]
  ){
    local pb = m * NP
    local ib = m * NI
    local dt = 1.0 / sr
    if(kind == TR808){
      // the coefficients of every voice into its memory (D_K..): see the
      // 808 at the sample
      local k = m * MEM + D_K
      mem[k] = (40.0 + params[pb] * 40.0) * dt                                   // kick at rest
      mem[k + 1] = exp(-1.0 / (sr * (0.08 + params[pb + 1] * params[pb + 1] * 1.5)))
      local f1 = 150.0 + params[pb + 3] * 150.0                                  // the snare's resonators
      mem[k + 2] = f1 * dt
      mem[k + 3] = f1 * 1.83 * dt
      mem[k + 4] = exp(-1.0 / (sr * (0.04 + params[pb + 5] * 0.25)))
      mem[k + 5] = exp(-1.0 / (sr * (0.03 + params[pb + 5] * 0.35)))
      mem[k + 6] = exp(-1.0 / (sr * (0.04 + params[pb + 6] * 0.4)))             // the clap's tail
      mem[k + 7] = exp(-1.0 / (sr * (0.015 + params[pb + 8] * 0.2)))            // closed hat
      mem[k + 8] = exp(-1.0 / (sr * (0.1 + params[pb + 9] * 1.5)))              // open hat
      mem[k + 9] = 1.0 - exp(-TAU * 2800.0 * exp2(params[pb + 7] * 1.6) * dt)   // the hats' high pass
      mem[k + 10] = 1.0 - exp(-TAU * 900.0 * dt)                                // the snare's noise high pass
      mem[k + 11] = 2.0 * sin(PI * 1100.0 * dt)                                 // the clap's band pass
      mem[k + 12] = 2.0 * sin(PI * 2200.0 * dt)                                 // the cowbell's
      mem[k + 13] = exp(-1.0 / (sr * 0.18))
      mem[k + 14] = exp(-1.0 / (sr * 0.025))                                    // the kick's pitch sweep
      mem[k + 15] = exp(-1.0 / (sr * 0.0035))                                   // a clap burst
      // the hats' six square waves, the 808's frequencies, tuned by TONE
      local tune = exp2((params[pb + 7] - 0.5) * 0.8) * dt
      mem[k + 16] = 205.3 * tune
      mem[k + 17] = 304.4 * tune
      mem[k + 18] = 369.6 * tune
      mem[k + 19] = 522.7 * tune
      mem[k + 20] = 540.0 * tune
      mem[k + 21] = 800.0 * tune
      mem[k + 22] = 587.0 * dt                                                  // the cowbell's two
      mem[k + 23] = 845.0 * dt
    } else if(kind == VCO){
      // a: the phase increment at the pitch; b: the pulse width
      local semis = (params[pb] - 2.0) * 12.0 + (params[pb + 1] - 12.0) + (params[pb + 2] * 2.0 - 1.0)
      md.a = min(C4 * exp2(semis / 12.0 + inp(inputs, ib)) * dt, 0.45)
      md.b = clamp(params[pb + 3] * 0.9 + 0.05 + inp(inputs, ib + 2) * 0.45, 0.02, 0.98)
    } else if(kind == LFO){
      md.a = min(0.05 * exp2(params[pb] * 9.2 + inp(inputs, ib)) * dt, 0.45)
    } else if(kind == ADSR){
      // a attack (aiming past 1), b decay, c sustain level, d release
      local p = params[pb]
      md.a = coef(0.001 * exp2(p * 12.0) * 3.1, sr)
      p = params[pb + 1]
      md.b = coef(0.005 * exp2(p * 10.6), sr)
      md.c = params[pb + 2]
      p = params[pb + 3]
      md.d = coef(0.005 * exp2(p * 10.6), sr)
    } else if(kind == VCF){
      // a: the ladder's coefficient for two passes a sample, b: feedback,
      // c: drive
      local oct = 4.32 + params[pb] * 9.6 + (params[pb + 2] * 2.0 - 1.0) * 6.0 * inp(inputs, ib + 1)
      local fc = clamp(exp2(oct) * dt, 0.0004, 0.4)
      md.a = 1.0 - exp(-TAU * fc * 0.5)
      md.b = clamp(params[pb + 1] + inp(inputs, ib + 2), 0.0, 1.0) * 4.2
      md.c = 1.0 + params[pb + 3] * 5.0
    } else if(kind == DELAY){
      // a: the delay in samples (slides, as tape would), b: feedback,
      // c: mix, d: the tone of the feedback
      local target = clamp(0.01 * exp2(params[pb] * 7.2 + inp(inputs, ib + 1)) * sr, 2.0, MEM - 2.0)
      md.a += (target - md.a) * 0.03
      md.b = params[pb + 1] * 0.95
      md.c = params[pb + 2]
      md.d = 1.0 - exp(-TAU * 200.0 * exp2(params[pb + 3] * 6.3) * dt)
    } else if(kind == REVERB){
      if(md.p1 == 0){
        local k = sr / 44100.0
        md.p1 = int(1116.0 * k)
        md.p2 = int(1188.0 * k)
        md.p3 = int(1277.0 * k)
        md.p4 = int(1356.0 * k)
        md.q1 = int(556.0 * k)
        md.q2 = int(441.0 * k)
      }
      md.a = 0.7 + params[pb] * 0.28       // the combs' feedback
      md.b = params[pb + 1] * 0.4          // damping
      md.c = params[pb + 2]                // mix
    } else if(kind == DRUMS){
      md.a = exp(-1.0 / (sr * (0.04 + params[pb + 1] * 0.6)))      // kick decay
      md.b = exp(-1.0 / (sr * (0.03 + params[pb + 3] * 0.4)))      // snare decay
      md.c = exp(-1.0 / (sr * (0.01 + params[pb + 4] * 0.3)))      // hat decay
      md.d = 35.0 + params[pb] * 60.0                               // kick Hz
    } else if(kind == CLOCK){
      local bpm = 40.0 + params[pb] * 200.0
      md.a = bpm / (60.0 * sr) * 4.0       // sixteenths per sample
    } else if(kind == KBD){
      local t = params[pb] * params[pb] * 2.0
      md.a = 1.0
      if(t > 0.002){
        md.a = coef(t * 0.3, sr)
      }
    } else if(kind == SCOPE){
      // p1: the window in samples (2 ms .. 200 ms)
      md.p1 = int(sr * 0.002 * exp2(params[pb] * 6.6))
    } else if(kind == CRUSH){
      // a: how far the sample clock moves a sample (1 / the divider), b: the
      // steps each side of zero (2^bits levels, none at zero); the CVs add
      // crushing
      local div = exp2(params[pb + 1] * 7.0 + max(inp(inputs, ib + 2), 0.0) * 3.0)
      md.a = 1.0 / clamp(div, 1.0, 256.0)
      local bits = clamp(1.0 + params[pb] * 15.0 - max(inp(inputs, ib + 1), 0.0) * 8.0, 1.0, 16.0)
      md.b = exp2(bits - 1.0)
    } else if(kind == SH){
      local t = params[pb] * params[pb] * 2.0
      md.a = 1.0
      if(t > 0.002){
        md.a = coef(t * 0.3, sr)
      }
    } else if(kind == QUANT){
      local mask = scale_mask(int(params[pb]))
      local root = int(params[pb + 1])
      local semis = int(round(inp(inputs, ib) * 12.0)) - root
      local q = semis
      for(local d = 0; d < 7; d += 1){
        if(((mask >> ((semis - d) % 12)) & 1) == 1){
          q = semis - d
          break
        }
        if(((mask >> ((semis + d) % 12)) & 1) == 1){
          q = semis + d
          break
        }
      }
      md.held = (q + root) / 12.0
    } else if(kind == FM){
      fm_control(m, md, params, inputs, fmops, fmdata, sr)
    }
  }

  // render(out, frames, ...): `frames` stereo frames into out (interleaved).
  // order lists the modules to run, -1 after the last; flags[m] 1 asks for
  // module m's state to be cleared; meters gets every signal and status
  // STATUS cells per module (the clock's place, a sequencer's step, the
  // output's scope position) at the end.
  func render(
    out: float[], frames: int, sr: double, order: int32[], kinds: int32[],
    inputs: int32[], params: double[], mods: Mod[], mem: float[],
    seqdata: int32[], song: int32[], live: double[], flags: int32[],
    meters: double[], status: double[], scope: float[], scopes: float[],
    fmops: FmOp[], fmdata: double[]
  ){
    local dt = 1.0 / sr
    local pulse = int(sr * 0.005)
    local scope_n = len(scope)
    for(local i = 0; i < frames; i += 1){
      // ---- the control step
      if(ctl == 0){
        cur_pattern = int(live[L_PATTERN])
        for(local k = 0; k < MAX; k += 1){
          local m = order[k]
          if(m < 0){
            break
          }
          local md = mods[m]
          if(flags[m] != 0){
            clear(md, m, sr)
            fm_clear(m, fmops)
            // the 808's voices live in its memory
            for(local c = 0; c < 64; c += 1){
              mem[m * MEM + c] = 0
            }
            flags[m] = 0
          }
          control(m, kinds[m], md, params, inputs, sr, fmops, fmdata, mem)
        }
      }
      ctl = (ctl + 1) % CONTROL
      // ---- the sample
      local left = 0.0
      local right = 0.0
      for(local k = 0; k < MAX; k += 1){
        local m = order[k]
        if(m < 0){
          break
        }
        local kind = kinds[m]
        local md = mods[m]
        local pb = m * NP
        local ib = m * NI
        local ob = m * NO
        if(kind == VCO){
          // in: V/oct, FM, PWM, sync; out: saw, pulse, triangle, sine
          local inc = md.a
          if(patched(inputs, ib + 1)){
            inc = clamp(inc * (1.0 + inp(inputs, ib + 1) * params[pb + 4] * 2.0), 0.0, 0.45)
          }
          local sync = inp(inputs, ib + 3) > 0.5
          if(sync and md.gate == 0){
            md.phase = 0
          }
          md.gate = select(sync, 1, 0)
          md.phase = fract(md.phase + inc)
          local p = md.phase
          local w = md.b
          local q = p - w
          if(q < 0.0){
            q += 1.0
          }
          sig[ob] = 2.0 * p - 1.0 - blep(p, inc)
          sig[ob + 1] = select(p < w, 1.0, -1.0) + blep(p, inc) - blep(q, inc)
          sig[ob + 2] = 1.0 - 4.0 * abs(p - 0.5)
          sig[ob + 3] = sin(p * TAU)
        } else if(kind == LFO){
          // in: rate, reset; out: sine, triangle, square, saw
          local rst = inp(inputs, ib + 1) > 0.5
          if(rst and md.rst == 0){
            md.phase = 0
          }
          md.rst = select(rst, 1, 0)
          md.phase = fract(md.phase + md.a)
          local p = md.phase
          sig[ob] = sin(p * TAU)
          sig[ob + 1] = 1.0 - 4.0 * abs(p - 0.5)
          sig[ob + 2] = select(p < 0.5, 1.0, -1.0)
          sig[ob + 3] = 1.0 - 2.0 * p
        } else if(kind == ADSR){
          // in: gate, retrigger; out: envelope, inverted
          local g = inp(inputs, ib) > 0.5
          local trig = inp(inputs, ib + 1) > 0.5
          if((g and md.gate == 0) or (trig and md.clk == 0 and g)){
            md.stage = 1
          }
          if(not g and md.gate == 1){
            md.stage = 4
          }
          md.gate = select(g, 1, 0)
          md.clk = select(trig, 1, 0)
          if(md.stage == 1){
            md.env += (1.3 - md.env) * md.a
            if(md.env >= 1.0){
              md.env = 1.0
              md.stage = 2
            }
          } else if(md.stage == 2){
            md.env += (md.c - md.env) * md.b
          } else if(md.stage == 4){
            md.env -= md.env * md.d
            if(md.env < 0.0001){
              md.env = 0
              md.stage = 0
            }
          }
          sig[ob] = md.env
          sig[ob + 1] = 1.0 - md.env
        } else if(kind == VCF){
          // in: audio, cutoff CV, resonance CV; out: low, band, high
          local x = inp(inputs, ib) * md.c
          local g = md.a
          local fb = md.b
          for(local pass = 0; pass < 2; pass += 1){
            local u = tanh(x - fb * md.y4)
            md.y1 += g * (u - md.y1)
            md.y2 += g * (md.y1 - md.y2)
            md.y3 += g * (md.y2 - md.y3)
            md.y4 += g * (md.y3 - md.y4)
          }
          local makeup = 1.0 + fb * 0.3
          sig[ob] = md.y4 * makeup
          sig[ob + 1] = (md.y2 - md.y4) * 2.0 * makeup
          sig[ob + 2] = tanh(x) - md.y4
        } else if(kind == VCA){
          // in: audio, CV; out: audio
          local cv = 1.0
          if(patched(inputs, ib + 1)){
            cv = inp(inputs, ib + 1) * params[pb + 1]
          }
          sig[ob] = inp(inputs, ib) * params[pb] * 2.0 * cv
        } else if(kind == MIX){
          // in: four channels; out: mono, left, right (1 and 3 lean left,
          // 2 and 4 right, by SPREAD)
          local a1 = inp(inputs, ib) * params[pb]
          local a2 = inp(inputs, ib + 1) * params[pb + 1]
          local a3 = inp(inputs, ib + 2) * params[pb + 2]
          local a4 = inp(inputs, ib + 3) * params[pb + 3]
          local s = 1.0 - params[pb + 4]
          sig[ob] = a1 + a2 + a3 + a4
          sig[ob + 1] = a1 + a3 + (a2 + a4) * s
          sig[ob + 2] = a2 + a4 + (a1 + a3) * s
        } else if(kind == NOISE){
          // in: sample trigger; out: white, pink, sample & hold
          local w = white(md) * params[pb]
          md.y1 = 0.99765 * md.y1 + w * 0.0990460
          md.y2 = 0.96300 * md.y2 + w * 0.2965164
          md.y3 = 0.57000 * md.y3 + w * 1.0526913
          local trig = inp(inputs, ib) > 0.5
          if(trig and md.clk == 0){
            md.held = w
          }
          md.clk = select(trig, 1, 0)
          sig[ob] = w
          sig[ob + 1] = (md.y1 + md.y2 + md.y3 + w * 0.1848) * 0.11
          sig[ob + 2] = md.held
        } else if(kind == DELAY){
          // in: audio, time CV; out: mix, wet
          local base = m * MEM
          local rp = md.w - md.a
          if(rp < 0.0){
            rp += MEM
          }
          local i0 = int(rp)
          local fr = rp - i0
          local i1 = (i0 + 1) % MEM
          local wet = mem[base + i0] * (1.0 - fr) + mem[base + i1] * fr
          md.y1 += (wet - md.y1) * md.d
          local x = inp(inputs, ib)
          mem[base + md.w] = x + md.y1 * md.b
          md.w = (md.w + 1) % MEM
          sig[ob] = x * (1.0 - md.c) + wet * md.c
          sig[ob + 1] = wet
        } else if(kind == REVERB){
          // in: audio; out: mix, wet (four combs into two allpasses)
          local base = m * MEM
          local x = inp(inputs, ib) * 0.5
          local n = md.counter
          local d = md.b
          local fb = md.a
          local acc = 0.0
          local at = base + n % md.p1
          local y = mem[at]
          md.y1 = y * (1.0 - d) + md.y1 * d
          mem[at] = x + md.y1 * fb
          acc += y
          at = base + 2048 + n % md.p2
          y = mem[at]
          md.y2 = y * (1.0 - d) + md.y2 * d
          mem[at] = x + md.y2 * fb
          acc += y
          at = base + 4096 + n % md.p3
          y = mem[at]
          md.y3 = y * (1.0 - d) + md.y3 * d
          mem[at] = x + md.y3 * fb
          acc += y
          at = base + 6144 + n % md.p4
          y = mem[at]
          md.y4 = y * (1.0 - d) + md.y4 * d
          mem[at] = x + md.y4 * fb
          acc += y
          acc *= 0.25
          at = base + 8192 + n % md.q1
          y = mem[at]
          mem[at] = acc + y * 0.5
          acc = y - acc
          at = base + 9216 + n % md.q2
          y = mem[at]
          mem[at] = acc + y * 0.5
          acc = y - acc
          md.counter = n + 1
          local c = md.c
          sig[ob] = inp(inputs, ib) * (1.0 - c) + acc * c
          sig[ob + 1] = acc
        } else if(kind == SEQ or kind == TRIGS){
          // in: clock, reset; SEQ out: pitch, gate, trigger, ramp; TRIGS
          // out: four triggers
          local steps = int(clamp(params[pb] + 1.0, 1.0, 16.0))
          local clk = inp(inputs, ib) > 0.5
          local rst = inp(inputs, ib + 1) > 0.5 or transport == 1
          if(rst and md.rst == 0){
            md.step = 0
            md.fresh = 1
          }
          if(clk and md.clk == 0){
            if(md.fresh == 1){
              md.fresh = 0
            } else {
              md.step += 1
            }
            if(md.step >= steps){
              md.step = 0
            }
            // the step's length: the time since the last clock (kept from
            // before when this is the first, or a reset's own edge)
            if(md.since > 2){
              md.period = md.since
            }
            md.since = 0
            md.p1 = 1
          }
          md.clk = select(clk, 1, 0)
          md.rst = select(rst, 1, 0)
          md.since += 1
          local st = md.step
          local sb = m * SEQW + cur_pattern * 64
          status[m * 4] = st
          status[m * 4 + 1] = cur_pattern
          if(kind == SEQ){
            local g = seqdata[sb + 16 + st]
            if(md.p1 == 1){
              md.p1 = 0
              if(g > 0){
                local semis = seqdata[sb + st] + (params[pb + 3] - 12.0)
                md.held = semis / 12.0 + (params[pb + 1] - 2.0)
              }
            }
            local gate = 0.0
            if(g == 2){
              gate = 1.0
            } else if(g == 1 and md.since < md.period * (0.1 + params[pb + 2] * 0.9)){
              gate = 1.0
            }
            sig[ob] = md.held
            sig[ob + 1] = gate
            sig[ob + 2] = select(g > 0 and md.since < pulse, 1.0, 0.0)
            sig[ob + 3] = float(st) / steps
          } else {
            local on = md.since < pulse
            sig[ob] = select(on and seqdata[sb + st] == 1, 1.0, 0.0)
            sig[ob + 1] = select(on and seqdata[sb + 16 + st] == 1, 1.0, 0.0)
            sig[ob + 2] = select(on and seqdata[sb + 32 + st] == 1, 1.0, 0.0)
            sig[ob + 3] = select(on and seqdata[sb + 48 + st] == 1, 1.0, 0.0)
          }
        } else if(kind == DRUMS){
          // in: kick, snare, hat triggers; out: kick, snare, hat, mix
          local t1 = inp(inputs, ib) > 0.5
          local t2 = inp(inputs, ib + 1) > 0.5
          local t3 = inp(inputs, ib + 2) > 0.5
          if(t1 and md.p1 == 0){
            md.env = 1.0
            md.held = 1.0
            md.phase = 0
          }
          if(t2 and md.p2 == 0){
            md.y1 = 1.0
            md.y2 = 1.0
          }
          if(t3 and md.p3 == 0){
            md.y3 = 1.0
          }
          md.p1 = select(t1, 1, 0)
          md.p2 = select(t2, 1, 0)
          md.p3 = select(t3, 1, 0)
          // the kick: a sine whose pitch falls fast
          md.held *= 0.9985
          md.phase = fract(md.phase + md.d * (1.0 + 8.0 * md.held) * dt)
          local kick = sin(md.phase * TAU) * md.env
          md.env *= md.a
          // the snare: noise and a tone, each with a decay
          local w = white(md)
          md.phase2 = fract(md.phase2 + 185.0 * dt)
          local tone = params[pb + 2]
          local snare = w * md.y1 * (0.5 + tone * 0.5) + sin(md.phase2 * TAU) * md.y2 * (1.0 - tone * 0.7)
          md.y1 *= md.b
          md.y2 *= 0.9975
          // the hat: noise with its bottom taken off
          md.z1 += (w - md.z1) * 0.3
          local hat = (w - md.z1) * md.y3
          md.y3 *= md.c
          local lv = params[pb + 5] * 1.6
          sig[ob] = kick * lv
          sig[ob + 1] = snare * lv * 0.8
          sig[ob + 2] = hat * lv * 0.6
          sig[ob + 3] = (kick + snare * 0.8 + hat * 0.6) * lv
        } else if(kind == TR808){
          // in: kick, snare, clap, closed hat, open hat, cowbell triggers,
          // accent; out: each voice and the mix. After the 808: the kick a
          // sine whose pitch sweeps down and whose body is driven (TONE);
          // the snare two resonators and noise through a high pass, each
          // decaying (SNAP is the noise's share); the clap noise through a
          // band pass, three bursts and a tail; the hats six square waves
          // through a high pass with one envelope, so a closed hat chokes
          // an open one; the cowbell two squares through a band pass. A
          // hit's loudness follows ACC (unpatched: full) by the ACC knob.
          local base = m * MEM
          local k = base + D_K
          local acc = 1.0
          if(patched(inputs, ib + 6)){
            acc = clamp(inp(inputs, ib + 6), 0.0, 1.0)
          }
          local accent = 1.0 - params[pb + 10] * (1.0 - acc)
          local t0 = inp(inputs, ib) > 0.5
          local t1 = inp(inputs, ib + 1) > 0.5
          local t2 = inp(inputs, ib + 2) > 0.5
          local t3 = inp(inputs, ib + 3) > 0.5
          local t4 = inp(inputs, ib + 4) > 0.5
          local t5 = inp(inputs, ib + 5) > 0.5
          if(t0 and md.p1 == 0){
            md.env = 1.0
            md.y1 = 1.0
            md.phase = 0
            mem[base + D_ACC] = accent
          }
          if(t1 and md.p2 == 0){
            md.y2 = 1.0
            md.y3 = 1.0
            md.phase2 = 0
            md.z1 = 0
            mem[base + D_ACC + 1] = accent
          }
          if(t2 and md.p3 == 0){
            md.y4 = 1.0
            md.counter = 0
            mem[base + D_ACC + 2] = accent
          }
          if(t3 and md.p4 == 0){
            mem[base + D_HENV] = 1.0
            mem[base + D_HDEC] = mem[k + 7]
            mem[base + D_ACC + 3] = accent
          }
          if(t4 and md.q1 == 0){
            mem[base + D_HENV] = 1.0
            mem[base + D_HDEC] = mem[k + 8]
            mem[base + D_ACC + 3] = accent
          }
          if(t5 and md.q2 == 0){
            mem[base + D_CBENV] = 1.0
            mem[base + D_ACC + 4] = accent
          }
          md.p1 = select(t0, 1, 0)
          md.p2 = select(t1, 1, 0)
          md.p3 = select(t2, 1, 0)
          md.p4 = select(t3, 1, 0)
          md.q1 = select(t4, 1, 0)
          md.q2 = select(t5, 1, 0)
          // the kick
          local tone = params[pb + 2]
          md.phase = fract(md.phase + mem[k] * (1.0 + md.y1 * (1.5 + tone * 3.0)))
          md.y1 *= mem[k + 14]
          local kick = tanh(sin(md.phase * TAU) * md.env * (1.0 + tone * 4.0)) / (1.0 + tone * 1.5)
          md.env *= mem[k + 1]
          kick *= mem[base + D_ACC]
          // the snare
          md.phase2 = fract(md.phase2 + mem[k + 2])
          md.z1 = fract(md.z1 + mem[k + 3])
          local w = white(md)
          md.z2 += (w - md.z2) * mem[k + 10]
          local snap = params[pb + 4]
          local snare = (sin(md.phase2 * TAU) * 0.7 + sin(md.z1 * TAU) * 0.4) * md.y2 * (1.0 - snap * 0.5)
          snare += (w - md.z2) * md.y3 * snap * 1.4
          md.y2 *= mem[k + 4]
          md.y3 *= mem[k + 5]
          snare *= mem[base + D_ACC + 1]
          // the clap: three bursts 9 ms apart, then the tail
          local burst = int(sr * 0.009)
          if(md.counter < burst * 3 and md.counter % burst == 0){
            md.y4 = 1.0
          }
          if(md.counter < 1000000){
            md.counter += 1
          }
          local w2 = white(md)
          local f = mem[k + 11]
          local lp = mem[base + D_CPF]
          local bp = mem[base + D_CPF + 1]
          lp += f * bp
          bp += f * (w2 - lp - 0.8 * bp)
          mem[base + D_CPF] = lp
          mem[base + D_CPF + 1] = bp
          local clap = bp * md.y4 * 2.5 * mem[base + D_ACC + 2]
          md.y4 *= select(md.counter < burst * 3, mem[k + 15], mem[k + 6])
          // the hats
          local metal = 0.0
          for(local i = 0; i < 6; i += 1){
            local p = fract(mem[base + D_HAT + i] + mem[k + 16 + i])
            mem[base + D_HAT + i] = p
            metal += select(p < 0.5, 1.0, -1.0)
          }
          local hk = mem[k + 9]
          local s1 = mem[base + D_HP]
          s1 += (metal - s1) * hk
          local h1 = metal - s1
          local s2 = mem[base + D_HP + 1]
          s2 += (h1 - s2) * hk
          mem[base + D_HP] = s1
          mem[base + D_HP + 1] = s2
          local henv = mem[base + D_HENV]
          local hat = tanh((h1 - s2) * 0.7) * 1.3 * henv * mem[base + D_ACC + 3]
          mem[base + D_HENV] = henv * mem[base + D_HDEC]
          // the cowbell
          local c1 = fract(mem[base + D_CB] + mem[k + 22])
          local c2 = fract(mem[base + D_CB + 1] + mem[k + 23])
          mem[base + D_CB] = c1
          mem[base + D_CB + 1] = c2
          local cb = (select(c1 < 0.5, 1.0, -1.0) + select(c2 < 0.5, 1.0, -1.0)) * 0.5
          f = mem[k + 12]
          lp = mem[base + D_CBF]
          bp = mem[base + D_CBF + 1]
          lp += f * bp
          bp += f * (cb - lp - 0.6 * bp)
          mem[base + D_CBF] = lp
          mem[base + D_CBF + 1] = bp
          local cbenv = mem[base + D_CBENV]
          local cowbell = bp * cbenv * 1.5 * mem[base + D_ACC + 4]
          mem[base + D_CBENV] = cbenv * mem[k + 13]
          local lv = params[pb + 11] * 1.6
          sig[ob] = kick * lv
          sig[ob + 1] = snare * lv
          sig[ob + 2] = clap * lv
          sig[ob + 3] = hat * lv
          sig[ob + 4] = cowbell * lv
          sig[ob + 5] = (kick + snare * 0.8 + clap * 0.7 + hat * 0.5 + cowbell * 0.5) * lv
        } else if(kind == CLOCK){
          // in: run; out: sixteenths, eighths, beats, bars. Keeps the song's
          // place and picks the pattern in song mode.
          local run = live[L_RUN] > 0.5 or inp(inputs, ib) > 0.5
          if(run and md.gate == 0){
            md.counter = 0
            md.phase = 0
            transport = 1
          }
          md.gate = select(run, 1, 0)
          local c = md.counter
          if(run){
            local sw = params[pb + 1] * 0.33
            local inc = md.a / (1.0 + sw)
            if(c % 2 == 1){
              inc = md.a / (1.0 - sw)
            }
            md.phase += inc
            if(md.phase >= 1.0){
              md.phase -= 1.0
              md.counter = c + 1
              c = md.counter
            }
          }
          local ph = md.phase
          sig[ob] = select(run and ph < 0.5, 1.0, 0.0)
          sig[ob + 1] = select(run and c % 2 == 0, 1.0, 0.0)
          sig[ob + 2] = select(run and c % 4 == 0, 1.0, 0.0)
          sig[ob + 3] = select(run and c % 16 == 0, 1.0, 0.0)
          local bar = c / 16
          if(params[pb + 3] > 0.5 and song[0] > 0){
            local per = 1 << int(params[pb + 2])
            cur_pattern = song[1 + (bar / per) % song[0]]
          }
          status[m * 4] = c % 16
          status[m * 4 + 1] = (c / 4) % 4
          status[m * 4 + 2] = bar
          status[m * 4 + 3] = cur_pattern
        } else if(kind == KBD){
          // out: pitch (with glide), gate, velocity, mod wheel
          md.y1 += (live[L_PITCH] - md.y1) * md.a
          sig[ob] = md.y1
          sig[ob + 1] = live[L_GATE]
          sig[ob + 2] = live[L_VEL]
          sig[ob + 3] = live[L_WHEEL]
        } else if(kind == QUANT){
          // in: pitch; out: the nearest note of the scale (control rate)
          sig[ob] = md.held
        } else if(kind == MATH){
          // in: a, b; out: a*ka + b*kb + offset, a*b, max, min
          local a = inp(inputs, ib)
          local b = inp(inputs, ib + 1)
          sig[ob] = a * (params[pb] * 4.0 - 2.0) + b * (params[pb + 1] * 4.0 - 2.0) + (params[pb + 2] * 4.0 - 2.0)
          sig[ob + 1] = a * b
          sig[ob + 2] = max(a, b)
          sig[ob + 3] = min(a, b)
        } else if(kind == CRUSH){
          // in: signal, bits CV, rate CV; out: the signal held at the lower
          // sample rate and rounded to the bits, mixed with the signal
          local x = inp(inputs, ib)
          md.phase += md.a
          if(md.phase >= 1.0){
            md.phase -= 1.0
            md.held = (floor(x * md.b) + 0.5) / md.b
          }
          local mix = params[pb + 2]
          sig[ob] = x * (1.0 - mix) + md.held * mix
        } else if(kind == SH){
          // in: signal, trigger; out: the signal as it was at the trigger's
          // rising edge, as it is while the trigger is high, and the held
          // value slewed
          local x = inp(inputs, ib)
          local trig = inp(inputs, ib + 1) > 0.5
          if(trig and md.clk == 0){
            md.held = x
          }
          md.clk = select(trig, 1, 0)
          if(trig){
            md.z1 = x
          }
          md.z2 += (md.held - md.z2) * md.a
          sig[ob] = md.held
          sig[ob + 1] = md.z1
          sig[ob + 2] = md.z2
        } else if(kind == SCOPE){
          // in: signal, trigger; out: the signal. From a rising edge of the
          // trigger (the signal itself when nothing is patched) through
          // the level, a window of the signal is captured (into its delay
          // memory) as the least and the most of each column, and shown
          // whole in scopes when complete; after two windows without an
          // edge it captures anyway (auto trigger). stage 1 captures,
          // counter the sample, step the column, held the trigger before.
          local x = inp(inputs, ib)
          local t = x
          if(patched(inputs, ib + 1)){
            t = inp(inputs, ib + 1)
          }
          local win = max(md.p1, SCOPE_W)
          local sb = m * MEM
          if(md.stage == 0){
            md.since += 1
            local lv = params[pb + 1] * 2.0 - 1.0
            if((t >= lv and md.held < lv) or md.since > 2 * win){
              md.stage = 1
              md.counter = 0
              md.step = 0
              md.y1 = x
              md.y2 = x
            }
          }
          md.held = t
          if(md.stage == 1){
            local col = md.counter * SCOPE_W / win
            if(col != md.step){
              mem[sb + md.step * 2] = md.y1
              mem[sb + md.step * 2 + 1] = md.y2
              md.step = col
              md.y1 = x
              md.y2 = x
            }
            md.y1 = min(md.y1, x)
            md.y2 = max(md.y2, x)
            md.counter += 1
            if(md.counter >= win){
              mem[sb + md.step * 2] = md.y1
              mem[sb + md.step * 2 + 1] = md.y2
              // the window complete: onto the screen at once
              local ob2 = m * SCOPE_W * 2
              for(local c = 0; c < SCOPE_W * 2; c += 1){
                scopes[ob2 + c] = mem[sb + c]
              }
              md.stage = 0
              md.since = 0
            }
          }
          sig[ob] = x
        } else if(kind == FM){
          // in: V/oct, gate, velocity, mod; out: the voice, the first
          // carrier's envelope. Operators run 6 down to 1 (a modulator has
          // a higher number than what it modulates), each reading its
          // modulators' outputs of this sample from fmx and the feedback
          // loop the voice's last two outputs.
          local sum = 0.0
          local eg = 0.0
          if(md.p1 == 1){
            local fb = (md.y1 + md.y2) * md.b
            for(local k = 5; k >= 0; k -= 1){
              local o = fmops[m * 6 + k]
              local x = 0.0
              if(o.m0 >= 0){
                x += fmx[o.m0]
              }
              if(o.m1 >= 0){
                x += fmx[o.m1]
              }
              if(o.m2 >= 0){
                x += fmx[o.m2]
              }
              if(o.fbin == 1){
                x += fb
              }
              o.phase = fract(o.phase + o.inc)
              local y = sin((o.phase + x) * TAU) * o.amp
              o.amp += o.damp
              if(o.fbout == 1){
                md.y2 = md.y1
                md.y1 = y
              }
              fmx[k] = y
              if(o.carrier == 1){
                sum += y
                eg = o.level / 99.0
              }
            }
          }
          sig[ob] = sum * md.c * params[pb + 1] * 2.0
          sig[ob + 1] = eg
        } else if(kind == OUT){
          // in: left, right (left alone plays on both); the stream's output
          local l = inp(inputs, ib)
          local r = l
          if(patched(inputs, ib + 1)){
            r = inp(inputs, ib + 1)
          }
          local g = params[pb] * params[pb] * 2.0
          l = tanh(l * g)
          r = tanh(r * g)
          left += l
          right += r
          sig[ob] = (l + r) * 0.5
          scope[scope_at] = sig[ob]
          scope_at = (scope_at + 1) % scope_n
          status[m * 4] = scope_at
        }
      }
      transport = 0
      out[i * 2] = left
      out[i * 2 + 1] = right
    }
    for(local s = 0; s < MAX * NO; s += 1){
      meters[s] = sig[s]
    }
  }
}

engine.Mod = Mod
engine.FmOp = FmOp
engine.render = render

// ------------------------------------------------------------ in slang

// the shared buffers the rack and the engine agree on (rack.slang makes
// them with buffer.shared, the tests with buffer.new)
func engine.arrays(make){
  return {
    kinds: make("int32", engine.MAX),
    inputs: make("int32", engine.MAX * engine.NI),
    params: make("double", engine.MAX * engine.NP),
    seqdata: make("int32", engine.MAX * engine.SEQW),
    song: make("int32", engine.SONG),
    order: make("int32", engine.MAX),
    flags: make("int32", engine.MAX),
    live: make("double", engine.live.COUNT),
    meters: make("double", engine.MAX * engine.NO),
    status: make("double", engine.MAX * engine.STATUS),
    scope: make("float", engine.SCOPE),
    scopes: make("float", engine.MAX * engine.SCOPE_W * 2),
    fmdata: make("double", engine.MAX * engine.FMW),
  }
}

// a MIDI controller's notes into live (last note priority), its mod wheel
// and velocity; null when there is no MIDI here
local func open_midi(){
  return try {
    require("midi").open(os.getenv("MIDI_INPUT"))
  } catch { null }
}

// new(a: the arrays, sample_rate: int, options?: {midi?: bool}) -> block
// function (out: float[frames * 2], frames). With options.midi a MIDI
// controller plays the KBD module (MIDI_INPUT=name picks the source).
func engine.new(a, sample_rate, options){
  local sr = sample_rate * 1.0
  local mods = Mod:array(engine.MAX)
  local fmops = FmOp:array(engine.MAX * 6)
  local mem = kernel.float:array(engine.MAX * engine.MEM)
  for(local m = 0; m < engine.MAX; m = m + 1){
    a.flags[m] = 1
  }
  local midi = null
  if(options != null and options.midi){
    midi = open_midi()
  }
  local held = {}
  local live = a.live
  local L = engine.live

  local func take_midi(){
    if(midi == null){
      return
    }
    for(let local msg in values(midi:read())){
      if(msg.kind == "note_on"){
        local rest = {}
        for(let local h in values(held)){
          if(h != msg.note){
            append(rest, h)
          }
        }
        held = rest
        append(held, msg.note)
        live[L.PITCH] = (msg.note - 60) / 12
        live[L.VEL] = msg.velocity / 127
        live[L.GATE] = 1
      } else if(msg.kind == "note_off"){
        local rest = {}
        for(let local h in values(held)){
          if(h != msg.note){
            append(rest, h)
          }
        }
        held = rest
        if(len(held) > 0){
          live[L.PITCH] = (held[len(held) - 1] - 60) / 12
        } else {
          live[L.GATE] = 0
        }
      } else if(msg.kind == "cc" and msg.controller == 1){
        live[L.WHEEL] = msg.value / 127
      }
    }
  }

  return func(out, frames){
    take_midi()
    render(out, frames, sr, a.order, a.kinds, a.inputs, a.params, mods, mem,
      a.seqdata, a.song, live, a.flags, a.meters, a.status, a.scope, a.scopes,
      fmops, a.fmdata)
  }
}

// offline(a, sample_rate, own?) -> block function: an engine of its own
// over the rack's patch (its kinds, cables, knobs, sequences and song),
// with the transport running and no player, for rendering a song to a
// file. Its live, flags, meters, status and scope are its own: those of
// `own` (engine.arrays(buffer.new)) when given, to be read after.
func engine.offline(a, sample_rate, own){
  own = own or engine.arrays(buffer.new)
  own.kinds = a.kinds
  own.inputs = a.inputs
  own.params = a.params
  own.seqdata = a.seqdata
  own.song = a.song
  own.order = a.order
  own.fmdata = a.fmdata
  own.live[engine.live.RUN] = 1
  own.live[engine.live.PATTERN] = a.live[engine.live.PATTERN]
  return engine.new(own, sample_rate)
}

// render(block, frames, sample_rate) -> {left, right}: `frames` of sound
// from a block function, in blocks of 128
func engine.render(block, frames, sample_rate){
  local left = buffer.new("float", frames)
  local right = buffer.new("float", frames)
  local out = buffer.new("float", 256)
  local at = 0
  for(at < frames){
    local n = 128
    if(frames - at < n){
      n = frames - at
    }
    block(out, n)
    for(local i = 0; i < n; i = i + 1){
      left[at + i] = out[i * 2]
      right[at + i] = out[i * 2 + 1]
    }
    at = at + n
  }
  return {left: left, right: right}
}

return engine
