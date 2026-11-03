// The voices of the synth: sixteen of them, each six operators, played from
// a channel of events and rendered in blocks by the kernels of dsp.slang.
// It runs in the render isolate of raylib/stream: engine.new returns the
// block function.
//
// Per block, slang only does what happens at block rate: the events (notes,
// the sustain pedal, a new or edited patch), the LFO, and which voice uses
// which algorithm. The kernels do the rest: control moves every envelope,
// render computes each sounding voice, finish limits the mix.
//
// A note picks its voice: the one already playing that note, else a free
// one, else the one released longest ago, else the oldest. Patch changes
// reach the voices that sound (an edit is heard at once, on the held note).
local buffer = require("slang/buffer")
local math = require("slang/math")
local patch = require("patch")
local algorithms = require("algorithms")
local dsp = require("dsp")

local engine = {}

engine.VOICES = 16
// the controls the panel writes into a shared buffer
engine.BEND = 0          // -1..1, two semitones
engine.WHEEL = 1         // 0..1, the mod wheel: more vibrato
engine.VOLUME = 2        // 0..1
engine.CONTROLS = 3

// feedback 7 moves the phase by up to this many cycles
local FEEDBACK_MAX = 0.3

// new(controls: Buffer, events: Channel, scope: Buffer?, rate: int,
//   status: Buffer?, options?: {midi: bool, keys: Buffer}) -> block function
// events brings {on: note, vel: 1..127}, {off: note}, {sustain: bool},
// {patch: p} (patch.voice's shape) and {panic: true}. status, when given,
// gets the number of sounding voices in its cell 0. With options.midi a
// MIDI controller plays too (its notes, velocities and sustain pedal, read
// every block; MIDI_INPUT=name picks the source), and options.keys (a
// uint8 buffer of 128) says which notes it holds.
func engine.new(controls, events, scope, rate, status, options){
  local k = dsp.load()
  local sr = rate * 1.0
  local VOICES = engine.VOICES
  local ops = buffer.new(k.OpState, VOICES * 6)
  local voices = buffer.new(k.Voice, VOICES)
  local blocks = buffer.new(k.Block, 1)
  // views of the elements, made once: writing through them allocates
  // nothing
  local op_at = {}
  for(local i = 0; i < VOICES * 6; i = i + 1){
    append(op_at, ops[i])
  }
  local voice_at = {}
  local info = {}
  for(local v = 0; v < VOICES; v = v + 1){
    append(voice_at, voices[v])
    // what slang keeps of a voice
    append(info, {active: false, note: -1, vel: 100, gate: false, pedal: false, order: 0, alg: 1})
  }
  local blk = blocks[0]
  local p = patch.voice({})
  local counter = 0
  local sustain = false
  local lfo_phase = 0.0
  local lfo_hold = 0.0
  local scope_at = 0
  if(scope == null){
    // a ring of one sample, so that finish has somewhere to write
    scope = buffer.new("float", 2)
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
      local scale = dsp.MOD
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
      append(scales, scale)
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
    local v = allocate(note)
    local vi = info[v]
    vi.active = true
    vi.note = note
    vi.vel = vel
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

  // the controller, when asked for and there is MIDI here
  local midi_in = null
  local midi_keys = null
  if(options != null and options.midi){
    local r = pcall(func(){
      return require("midi").open(require("slang/os").getenv("MIDI_INPUT"))
    })
    if(r[0] == "ok"){
      midi_in = r[1]
    }
    midi_keys = options.keys
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

  local func take_midi(){
    if(midi_in == null){
      return null
    }
    for(let local m in values(midi_in:read())){
      if(m.kind == "note_on"){
        note_on(m.note, m.velocity)
        if(midi_keys != null){
          midi_keys[m.note] = 1
        }
      } else if(m.kind == "note_off"){
        note_off(m.note)
        if(midi_keys != null){
          midi_keys[m.note] = 0
        }
      } else if(m.kind == "cc" and m.controller == 64){
        set_sustain(m.value >= 64)
      }
    }
  }

  local func take_events(){
    for(true){
      local e = events:try_receive()
      if(e == null){
        return null
      }
      if(e.on != null){
        note_on(e.on, e.vel or 100)
      } else if(e.off != null){
        note_off(e.off)
      } else if(e.sustain != null){
        set_sustain(e.sustain)
      } else if(e.patch != null){
        p = e.patch
        for(local v = 0; v < VOICES; v = v + 1){
          if(info[v].active){
            apply(v, false)
          }
        }
      } else if(e.panic){
        panic()
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

  return func(out, frames){
    take_events()
    take_midi()
    local dt = frames / sr
    local x = lfo(dt)
    blk.n = frames
    blk.dt = dt
    blk.bend = controls[engine.BEND] * 2
    blk.lfo = x
    blk.lfo_am = (x + 1) * 0.5
    blk.pmd = math.min(1, p.pmd / 99 + controls[engine.WHEEL]) * patch.PMS[p.pms]
    blk.amd = p.amd / 99
    blk.delay = patch.lfo_delay(p.delay)
    k.control(ops, voices, blocks)
    k.clear(out, frames)
    local sounding = 0
    for(local v = 0; v < VOICES; v = v + 1){
      local vi = info[v]
      if(vi.active){
        if(voice_at[v].active == 0){
          // control ended it: its carriers fell silent
          vi.active = false
          vi.gate = false
        } else {
          k.render[vi.alg](out, ops, voices, v, frames)
          sounding = sounding + 1
        }
      }
    }
    local vol = controls[engine.VOLUME]
    scope_at = k.finish(out, frames, vol * vol * 2, scope, scope_at)
    scope[len(scope) - 1] = scope_at
    if(status != null){
      status[0] = sounding
    }
  }
}

return engine
