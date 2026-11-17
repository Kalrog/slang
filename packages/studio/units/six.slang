// studio/units/six: a polyphonic six-operator FM synthesizer in the
// spirit of the classic digital keyboards of the 1980s (the one of
// examples/fm): 32 algorithms, an envelope of four rates and four levels
// on every operator, feedback, an LFO, a pitch envelope, velocity and
// keyboard scaling, sixteen voices and a bank of 32 patches.
//
//   local keys = s:track("keys", "six", {patch: "TINE PIANO"})
//   keys:note(60, {velocity: 0.7, length: 800})
//   keys.unit.params.op2_level = 82        // an operator's field
//   keys.unit.params.algorithm = 5         // the voice's
//
// Parameters are in the units of those synthesizers, mostly 0 to 99: an
// operator's are op1_ .. op6_ and on, mode, coarse, fine, detune, level,
// vel, rs, ams, r1..r4, l1..l4, break, ldepth, rdepth, lcurve, rcurve;
// the voice's are algorithm, feedback, osc_sync, transpose, lfo_wave,
// lfo_speed, lfo_delay, pmd, amd, lfo_sync, pms, pr1..pr4, pl1..pl4, and
// volume. studio/units/six/patch says what each means. An edit is heard at
// once, on held notes too. The pitch wheel bends two semitones, the mod
// wheel adds vibrato, the pedal sustains.
local kernel = require("kernel")
local math = require("slang/math")
local param = require("studio/param")
local events = require("studio/events")
local patch = require("studio/units/six/patch")
local algorithms = require("studio/units/six/algorithms")
local kernels = require("studio/units/six/kernels")
local bank = require("studio/units/six/patches")

// feedback 7 moves the phase by up to this many cycles
local FEEDBACK_MAX = 0.3

// the voice's fields as the unit names them
local VOICE_NAMES = {wave: "lfo_wave", speed: "lfo_speed", delay: "lfo_delay"}

local func field_param(name, f, default){
  local d = {name: name, min: f.min, max: f.max, step: 1, default: default}
  if(f.kind == "bool"){
    d.kind = "switch"
  } else if(f.kind == "enum"){
    d.labels = f.labels
  } else if(f.kind == "note"){
    d.kind = "note"
  }
  return d
}

local init = patch.voice({})
local defs = {}
for(local k = 0; k < 6; k = k + 1){
  for(let local f in values(patch.OP_FIELDS)){
    append(defs, field_param(
      concat("op", string(k + 1), "_", f.id), f, init.ops[k][f.id]
    ))
  }
}
local OPW = len(patch.OP_FIELDS)
local VOICE = OPW * 6
for(let local f in values(patch.VOICE_FIELDS)){
  append(defs, field_param(VOICE_NAMES[f.id] or f.id, f, init[f.id]))
}
append(defs, {name: "volume", min: 0.0, max: 1.0, default: 0.7})
local params = param.set(defs)
local VOLUME = params.index.volume

// a patch of the bank as a unit's patch: every parameter by its name
local func flat(p){
  local out = {name: p.name}
  for(local k = 0; k < 6; k = k + 1){
    for(let local f in values(patch.OP_FIELDS)){
      out[concat("op", string(k + 1), "_", f.id)] = p.ops[k][f.id]
    }
  }
  for(let local f in values(patch.VOICE_FIELDS)){
    out[VOICE_NAMES[f.id] or f.id] = p[f.id]
  }
  return out
}
local patches = {}
for(let local p in values(bank)){
  append(patches, flat(p))
}

local func new(ctx){
  local k = kernels.load()
  local sr = ctx.sample_rate * 1.0
  local cells = ctx.params
  local base = ctx.base
  local VOICES = ctx.options.voices or 16
  local ops = k.OpState:array(VOICES * 6)
  local voices = k.Voice:array(VOICES)
  local blocks = k.Block:array(1)
  local mono = kernel.float:array(ctx.block)
  // views of the elements, made once: writing through them allocates
  // nothing
  local op_at = {}
  for(local i = 0; i < VOICES * 6; i = i + 1){
    op_at[i] = ops[i]
  }
  local voice_at = {}
  local info = {}
  for(local v = 0; v < VOICES; v = v + 1){
    voice_at[v] = voices[v]
    // what slang keeps of a voice
    info[v] = {
      active: false, note: -1, vel: 100, gate: false, pedal: false, order: 0,
      alg: 1
    }
  }
  local blk = blocks[0]
  // the patch as patch.voice shapes it, read from the cells when they
  // change
  local p = patch.voice({})
  local dirty = true
  local counter = 0
  local sustain = false
  local bend = 0.0
  local wheel = 0.0
  local lfo_phase = 0.0
  local lfo_hold = 0.0
  local sounding = 0

  local func read_patch(){
    for(local i = 0; i < 6; i = i + 1){
      local o = p.ops[i]
      local at = base + i * OPW
      for(local f = 0; f < OPW; f = f + 1){
        o[patch.OP_FIELDS[f].id] = to_int(math.round(cells[at + f]))
      }
    }
    for(local f = 0; f < len(patch.VOICE_FIELDS); f = f + 1){
      p[patch.VOICE_FIELDS[f].id] = to_int(math.round(cells[base + VOICE + f]))
    }
    dirty = false
  }

  // apply(v, trigger): the patch's parameters into voice v (and, with
  // trigger, its envelopes and phases start again)
  local func apply(v, trigger){
    local vi = info[v]
    local vo = voice_at[v]
    local alg = algorithms.get(p.algorithm)
    vi.alg = p.algorithm
    local key = vi.note + p.transpose
    local hz = 440.0 * (2 ^ ((key - 69) / 12))
    local scales = {}
    for(local i = 0; i < 6; i = i + 1){
      local o = p.ops[i]
      local s = op_at[v * 6 + i]
      local carrier = algorithms.is_carrier(alg, i + 1)
      local detune = 2 ^ (o.detune * 1.5 / 1200)
      if(o.mode == 1){
        s.base = patch.fixed_hz(o) * detune / sr
        s.fixed = 1
      } else {
        s.base = hz * patch.ratio(o) * detune / sr
        s.fixed = 0
      }
      // rate scaling: higher keys, faster envelopes
      local faster = o.rs * math.max(0, key - 36) / 12 * 0.8
      s.r1 = patch.speed(math.min(99, o.r1 + faster))
      s.r2 = patch.speed(math.min(99, o.r2 + faster))
      s.r3 = patch.speed(math.min(99, o.r3 + faster))
      s.r4 = patch.speed(math.min(99, o.r4 + faster))
      s.l1 = o.l1
      s.l2 = o.l2
      s.l3 = o.l3
      s.l4 = o.l4
      // gain in octaves: the output level, velocity, key level scaling
      local offset = (o.level - 99) / 8
      offset = offset + (o.vel / 7) * ((vi.vel - 127) / 127) * 2.5
      local d = (key - o["break"]) / 12
      local depth = o.rdepth
      local curve = o.rcurve
      if(d < 0){
        d = -d
        depth = o.ldepth
        curve = o.lcurve
      }
      local shape = d
      if(curve == 1 or curve == 2){
        shape = ((2 ^ d) - 1) * 0.5
      }
      local kls = depth / 99 * shape
      if(curve < 2){
        kls = -kls
      }
      s.offset = offset + math.clamp(kls, -8, 2)
      s.ams = patch.AMS[o.ams]
      local scale = kernels.MOD
      if(carrier){
        scale = 1.0
        s.carrier = 1
      } else {
        s.carrier = 0
      }
      if(o.on == 0 or o.level == 0){
        scale = 0.0
      }
      s.scale = scale
      scales[i] = scale
      if(trigger){
        s.stage = 0
        if(p.osc_sync == 1){
          s.phase = 0
        }
      }
    }
    // feedback: the average of the source's last two outputs, which carry
    // its scale
    local fb = 0.0
    local src = scales[alg.fb_from - 1]
    if(p.feedback > 0 and src > 0){
      fb = FEEDBACK_MAX * (2 ^ (p.feedback - 7)) * 0.5 / src
    }
    vo.fb = fb
    vo.pr1 = patch.speed(p.pr1)
    vo.pr2 = patch.speed(p.pr2)
    vo.pr3 = patch.speed(p.pr3)
    vo.pr4 = patch.speed(p.pr4)
    vo.pl1 = p.pl1
    vo.pl2 = p.pl2
    vo.pl3 = p.pl3
    vo.pl4 = p.pl4
    if(trigger){
      vo.pstage = 0
      // the pitch envelope starts where its release ends
      vo.pitch = p.pl4
      vo.age = 0
      vo.gate = 1
      vo.active = 1
      if(p.osc_sync == 1){
        vo.y1 = 0
        vo.y2 = 0
      }
    }
  }

  // the patch from the cells, into the voices that sound
  local func refresh(){
    read_patch()
    for(local v = 0; v < VOICES; v = v + 1){
      if(info[v].active){
        apply(v, false)
      }
    }
  }

  local func allocate(note){
    for(local v = 0; v < VOICES; v = v + 1){
      if(info[v].active and info[v].note == note){
        return v
      }
    }
    for(local v = 0; v < VOICES; v = v + 1){
      if(not info[v].active){
        return v
      }
    }
    // the released voice that was played first, else the oldest of all
    local best = -1
    for(local v = 0; v < VOICES; v = v + 1){
      if(not info[v].gate and (best < 0 or info[v].order < info[best].order)){
        best = v
      }
    }
    if(best >= 0){
      return best
    }
    best = 0
    for(local v = 1; v < VOICES; v = v + 1){
      if(info[v].order < info[best].order){
        best = v
      }
    }
    return best
  }

  local func release(v){
    info[v].gate = false
    info[v].pedal = false
    voice_at[v].gate = 0
  }

  local func note_on(note, vel){
    if(dirty){
      refresh()
    }
    local v = allocate(note)
    local vi = info[v]
    vi.active = true
    vi.note = note
    vi.vel = math.max(1, vel * 127)
    vi.gate = true
    vi.pedal = false
    counter = counter + 1
    vi.order = counter
    if(p.lfo_sync == 1){
      lfo_phase = 0.0
    }
    apply(v, true)
  }

  local func note_off(note){
    for(local v = 0; v < VOICES; v = v + 1){
      local vi = info[v]
      if(vi.active and vi.gate and vi.note == note){
        if(sustain){
          vi.pedal = true
        } else {
          release(v)
        }
      }
    }
  }

  local func panic(){
    for(local v = 0; v < VOICES; v = v + 1){
      info[v].active = false
      info[v].gate = false
      voice_at[v].active = 0
      voice_at[v].gate = 0
      for(local i = 0; i < 6; i = i + 1){
        local s = op_at[v * 6 + i]
        s.amp = 0
        s.damp = 0
        s.level = 0
      }
    }
  }

  local func set_sustain(on){
    sustain = on
    if(not sustain){
      for(local v = 0; v < VOICES; v = v + 1){
        if(info[v].pedal){
          release(v)
        }
      }
    }
  }

  // the LFO's value (-1..1) after dt seconds
  local func lfo(dt){
    local before = lfo_phase
    lfo_phase = lfo_phase + patch.lfo_hz(p.speed) * dt
    if(lfo_phase >= 1.0){
      lfo_phase = lfo_phase - math.floor(lfo_phase)
    }
    local x = lfo_phase
    local w = p.wave
    if(w == 0){
      if(x < 0.5){
        return 4 * x - 1
      }
      return 3 - 4 * x
    } else if(w == 1){
      return 1 - 2 * x
    } else if(w == 2){
      return 2 * x - 1
    } else if(w == 3){
      if(x < 0.5){
        return 1.0
      }
      return -1.0
    } else if(w == 4){
      return math.sin(x * 2 * math.pi)
    }
    // sample and hold: a new value each cycle
    if(lfo_phase < before){
      lfo_hold = math.random() * 2 - 1
    }
    return lfo_hold
  }

  return {
    note_on: note_on,
    note_off: note_off,
    control: func(which, value){
      if(which == events.controls.BEND){
        bend = value
      } else if(which == events.controls.MOD){
        wheel = value
      } else if(which == events.controls.SUSTAIN){
        set_sustain(value >= 0.5)
      }
    },
    set: func(i, value){
      if(i != VOLUME){
        dirty = true
      }
    },
    hush: func(){
      sustain = false
      for(local v = 0; v < VOICES; v = v + 1){
        if(info[v].active and info[v].gate){
          release(v)
        }
      }
    },
    panic: panic,
    voices: func(){
      return sounding
    },
    render: func(l, r, start, frames){
      if(dirty){
        refresh()
      }
      local dt = frames / sr
      local x = lfo(dt)
      blk.n = frames
      blk.dt = dt
      blk.bend = bend * 2
      blk.lfo = x
      blk.lfo_am = (x + 1) * 0.5
      blk.pmd = math.min(1, p.pmd / 99 + wheel) * patch.PMS[p.pms]
      blk.amd = p.amd / 99
      blk.delay = patch.lfo_delay(p.delay)
      k.control(ops, voices, blocks)
      k.clear(mono, frames)
      sounding = 0
      for(local v = 0; v < VOICES; v = v + 1){
        local vi = info[v]
        if(vi.active){
          if(voice_at[v].active == 0){
            // control ended it: its carriers fell silent
            vi.active = false
            vi.gate = false
          } else {
            k.render[vi.alg](mono, ops, voices, v, frames)
            sounding = sounding + 1
          }
        }
      }
      local vol = cells[base + VOLUME]
      k.finish(mono, frames, vol * vol * 2, l, r, start)
    },
  }
}

return {
  name: "six",
  kind: "instrument",
  params: params,
  options: {"voices"},
  patches: patches,
  new: new,
}
