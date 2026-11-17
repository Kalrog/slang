extension "kernel/syntax"
// studio/program: units made of dsp programs (packages/dsp: block
// diagrams compiled to kernels). A unit module of a few lines:
//
//   // my/units/whistle.slang, with whistle.dsp next to it
//   local program = require("studio/program")
//   return program.instrument(require("my/units/whistle_dsp"), {name: "whistle"})
//
//   s:track("lead", "my/units/whistle", {q: 40})
//
// instrument(): the program is one voice with the controls "freq" (Hz)
// and "gate" (1 while the key is held), and one or two outputs. The unit
// runs several copies of it, one per note; a "velocity" control gets the
// note's (else the voice is scaled by it). A voice is done when its key
// is up and it has fallen silent.
//
// effect(): a program with as many outputs as inputs, one (run once per
// side) or two.
//
// Every other control of the program is a parameter of the unit, named by
// its label in lower case with `_` for what is no letter or digit ("env
// amount" is env_amount).
local kernel = require("kernel")
local math = require("slang/math")
local str = require("slang/string")
local param = require("studio/param")
local events = require("studio/events")

local program = {}

kernel {
  func clear(l: float[], r: float[], start: int, n: int){
    for(local i = start; i < start + n; i += 1){
      l[i] = 0.0
      r[i] = 0.0
    }
  }

  // a and b (n frames from their start) times g added to l and r from
  // `start`; returns their peak
  func add(
    l: float[], r: float[], start: int, n: int, a: float[], b: float[], g: float
  ): float {
    local peak = 0.0
    for(local i = 0; i < n; i += 1){
      local x = a[i]
      local y = b[i]
      peak = max(peak, max(abs(x), abs(y)))
      l[start + i] += x * g
      r[start + i] += y * g
    }
    return peak
  }

  func take(a: float[], b: float[], l: float[], r: float[], start: int, n: int){
    for(local i = 0; i < n; i += 1){
      a[i] = l[start + i]
      b[i] = r[start + i]
    }
  }

  func put(l: float[], r: float[], start: int, n: int, a: float[], b: float[]){
    for(local i = 0; i < n; i += 1){
      l[start + i] = a[i]
      r[start + i] = b[i]
    }
  }
}

// a control's label as a parameter's name
local func name_of(label){
  local out = ""
  local gap = false
  for(local i = 0; i < len(label); i = i + 1){
    local c = str.byte_at(label, i)
    if(c >= 65 and c <= 90){
      c = c + 32
    }
    if((c >= 97 and c <= 122) or (c >= 48 and c <= 57)){
      if(gap and len(out) > 0){
        out = concat(out, "_")
      }
      gap = false
      out = concat(out, str.from_bytes({c}))
    } else {
      gap = true
    }
  }
  if(len(out) == 0 or (str.byte_at(out, 0) >= 48 and str.byte_at(out, 0) <= 57)){
    out = concat("n", out)
  }
  return out
}

// the program's controls but those named in `skip`, as parameters:
// {params: ParamSet, fields: {[i]: the control's field}}
local func controls_of(prog, skip){
  local defs = {}
  local fields = {}
  for(let local c in values(prog.controls)){
    if(skip[c.label] == null){
      local d = {
        name: name_of(c.label), min: c.min, max: c.max, default: c.init,
        label: c.label
      }
      if(c.kind == "button" or c.kind == "checkbox"){
        d = {
          name: name_of(c.label), kind: "switch", default: c.init,
          label: c.label
        }
      }
      fields[len(defs)] = c.field
      append(defs, d)
    }
  }
  return {params: param.set(defs), fields: fields}
}

// instrument(prog: Dsp, options?: InstrumentOptions) -> Unit
// type InstrumentOptions = {name?: string, voices?: int, gain?: number,
//   patches?: {table}}
// [name]: the unit's name; the program's when absent
// [voices]: copies of the program, eight when absent (the track's option
//   `voices` overrides it)
// [gain]: a factor on every voice
// [patches]: the unit's patches
func program.instrument(prog, options){
  options = options or {}
  if(prog.inputs != 0 or prog.outputs < 1 or prog.outputs > 2){
    raise(error.new(error.kinds.argument, concat(
      "studio/program: an instrument has no inputs and one or two outputs (",
      prog.name or "?", " has ", string(prog.inputs), " and ",
      string(prog.outputs), ")"
    )))
  }
  if(prog.by_label.freq == null or prog.by_label.gate == null){
    raise(error.new(error.kinds.argument, concat(
      "studio/program: ", prog.name or "?",
      " needs the controls \"freq\" and \"gate\""
    )))
  }
  local c = controls_of(prog, {freq: true, gate: true, velocity: true})
  local freq_field = prog.by_label.freq.field
  local gate_field = prog.by_label.gate.field
  local vel_field = null
  if(prog.by_label.velocity != null){
    vel_field = prog.by_label.velocity.field
  }
  local level = options.gain or 1.0

  local func new(ctx){
    local p = ctx.params
    local base = ctx.base
    local count = ctx.options.voices or options.voices or 8
    local voices = {}
    for(local i = 0; i < count; i = i + 1){
      voices[i] = {
        inst: prog:new({sample_rate: ctx.sample_rate}),
        on: false,
        gate: false,
        held: false,
        note: 0.0,
        vel: 1.0,
        age: 0,
        quiet: 0,
      }
      for(local k = 0; k < c.params.count; k = k + 1){
        voices[i].inst.state[c.fields[k]] = p[base + k]
      }
    }
    local a = kernel.float:array(ctx.block)
    local b = a
    local outs = {a}
    if(prog.outputs == 2){
      b = kernel.float:array(ctx.block)
      outs = {a, b}
    }
    local none = {}
    local bend = 1.0
    local pedal = false
    local clock = 0
    local sounding = 0
    // a voice whose key is up is done after this many silent frames
    local tail = to_int(ctx.sample_rate * 0.03)

    local func hz(note){
      return 440.0 * math.exp(math.log(2) * (note - 69) / 12) * bend
    }

    local func let_go(v){
      v.gate = false
      v.held = false
      v.inst.state[gate_field] = 0
    }

    return {
      note_on: func(note, vel){
        // the note's own voice again, a free one, else the oldest
        local pick = null
        local oldest = voices[0]
        for(local i = 0; i < count; i = i + 1){
          local v = voices[i]
          if(v.on and v.gate and v.note == note){
            pick = v
            break
          }
          if(pick == null and not v.on){
            pick = v
          }
          if(v.age < oldest.age){
            oldest = v
          }
        }
        if(pick == null){
          pick = oldest
        }
        clock = clock + 1
        pick.on = true
        pick.gate = true
        pick.held = false
        pick.note = note
        pick.vel = vel
        pick.age = clock
        pick.quiet = 0
        local st = pick.inst.state
        // the gate falls and rises, so a voice taken over starts again
        st[gate_field] = 0
        pick.restart = true
        st[freq_field] = hz(note)
        if(vel_field != null){
          st[vel_field] = vel
        }
      },
      note_off: func(note){
        for(local i = 0; i < count; i = i + 1){
          local v = voices[i]
          if(v.on and v.gate and v.note == note and not v.held){
            if(pedal){
              v.held = true
            } else {
              let_go(v)
            }
          }
        }
      },
      control: func(which, value){
        if(which == events.controls.BEND){
          bend = math.exp(math.log(2) * value * 2 / 12)
          for(local i = 0; i < count; i = i + 1){
            if(voices[i].on){
              voices[i].inst.state[freq_field] = hz(voices[i].note)
            }
          }
        } else if(which == events.controls.SUSTAIN){
          pedal = value >= 0.5
          if(not pedal){
            for(local i = 0; i < count; i = i + 1){
              if(voices[i].held){
                let_go(voices[i])
              }
            }
          }
        }
      },
      set: func(i, value){
        for(local k = 0; k < count; k = k + 1){
          voices[k].inst.state[c.fields[i]] = value
        }
      },
      hush: func(){
        for(local i = 0; i < count; i = i + 1){
          if(voices[i].gate){
            let_go(voices[i])
          }
        }
      },
      panic: func(){
        for(local i = 0; i < count; i = i + 1){
          local v = voices[i]
          if(v.on){
            v.inst:reset()
            for(local k = 0; k < c.params.count; k = k + 1){
              v.inst.state[c.fields[k]] = p[base + k]
            }
          }
          v.on = false
          v.gate = false
          v.held = false
        }
      },
      voices: func(){
        return sounding
      },
      render: func(l, r, start, n){
        clear(l, r, start, n)
        sounding = 0
        for(local i = 0; i < count; i = i + 1){
          local v = voices[i]
          if(not v.on){
            continue
          }
          if(v.restart){
            // one sample with the gate down, then up: the program sees
            // the edge
            v.restart = false
            if(n > 1){
              v.inst:compute(1, none, outs)
            }
            v.inst.state[gate_field] = 1
          }
          v.inst:compute(n, none, outs)
          local g = level
          if(vel_field == null){
            g = level * v.vel
          }
          local peak = add(l, r, start, n, a, b, g)
          if(not v.gate){
            if(peak < 0.0001){
              v.quiet = v.quiet + n
              if(v.quiet >= tail){
                v.on = false
              }
            } else {
              v.quiet = 0
            }
          }
          if(v.on){
            sounding = sounding + 1
          }
        }
      },
    }
  }

  return {
    name: options.name or prog.name,
    kind: "instrument",
    params: c.params,
    options: {"voices"},
    patches: options.patches,
    program: prog,
    new: new,
  }
}

// effect(prog: Dsp, options?: {name?: string, patches?: {table}}) -> Unit
func program.effect(prog, options){
  options = options or {}
  if(prog.inputs != prog.outputs or prog.inputs < 1 or prog.inputs > 2){
    raise(error.new(error.kinds.argument, concat(
      "studio/program: an effect has one input and output, or two of each (",
      prog.name or "?", " has ", string(prog.inputs), " and ",
      string(prog.outputs), ")"
    )))
  }
  local c = controls_of(prog, {})

  local func new(ctx){
    local p = ctx.params
    local base = ctx.base
    // (in a table literal `prog:new()` would be a field named prog)
    local first = prog:new({sample_rate: ctx.sample_rate})
    local copies = {first}
    if(prog.inputs == 1){
      copies[1] = prog:new({sample_rate: ctx.sample_rate})
    }
    for(let local inst in values(copies)){
      for(local k = 0; k < c.params.count; k = k + 1){
        inst.state[c.fields[k]] = p[base + k]
      }
    }
    local a = kernel.float:array(ctx.block)
    local b = kernel.float:array(ctx.block)
    local x = kernel.float:array(ctx.block)
    local y = kernel.float:array(ctx.block)
    local ins = {a, b}
    local outs = {x, y}
    local in_a = {a}
    local in_b = {b}
    local out_x = {x}
    local out_y = {y}
    return {
      set: func(i, value){
        for(let local inst in values(copies)){
          inst.state[c.fields[i]] = value
        }
      },
      render: func(l, r, start, n){
        take(a, b, l, r, start, n)
        if(prog.inputs == 2){
          copies[0]:compute(n, ins, outs)
        } else {
          copies[0]:compute(n, in_a, out_x)
          copies[1]:compute(n, in_b, out_y)
        }
        put(l, r, start, n, x, y)
      },
    }
  }

  return {
    name: options.name or prog.name,
    kind: "effect",
    params: c.params,
    patches: options.patches,
    program: prog,
    new: new,
  }
}

return program
