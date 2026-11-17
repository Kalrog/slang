// studio/units/rack/patch: the rack of the rack unit: the patch as data. Modules in slots, cables between their
// jacks, the knobs, the sequencers' steps and the song chain, kept in
// slang tables and written into the shared buffers the engine's kernel
// reads at every sample (engine.slang). The catalog says what each kind
// of module has: its knobs, jacks and the size of its panel.
//
//   local rack = require("studio/units/rack/patch")
//   local r = rack.new(buffer.shared)         // or buffer.new, offline
//   local clock = r:add("CLOCK")
//   local seq = r:add("SEQ")
//   r:connect(clock, 0, seq, 0)               // clock's out 0 to seq's in 0
//   r:set_param(seq, 0, 8)                    // 8 steps
//   r:save("patches/mine.json"); r:load("patches/mine.json")
local json = require("slang/json")
local os = require("slang/os")
local str = require("slang/string")
local engine = require("studio/units/rack/engine")
// the FM module's patch model, bank and algorithms: the six unit's
local patch = require("studio/units/six/patch")
local bank = require("studio/units/six/patches")
local algorithms = require("studio/units/six/algorithms")

local rack = {}
local K = engine.kinds
rack.bank = bank

local fm_names = {}
for(let local p in values(bank)){
  append(fm_names, p.name)
}

// ------------------------------------------------------------ the catalog

// a knob (0..1) or a stepper (0..n-1, shown by its labels or an offset)
local func knob(id, label, default, show){
  return {id: id, label: label, kind: "knob", default: default, show: show}
}

local func steps(id, label, n, default, labels, offset){
  return {
    id: id, label: label, kind: "steps", n: n, default: default, labels: labels,
    offset: offset
  }
}

local func pct(v){
  return concat("", to_int(v * 100 + 0.5), "%")
}

local func hz(v){
  if(v >= 1000){
    return concat("", to_int(v / 100 + 0.5) / 10, " KHZ")
  }
  if(v >= 100){
    return concat("", to_int(v + 0.5), " HZ")
  }
  return concat("", to_int(v * 10 + 0.5) / 10, " HZ")
}

local func ms(seconds){
  if(seconds >= 1){
    return concat("", to_int(seconds * 100 + 0.5) / 100, " S")
  }
  return concat("", to_int(seconds * 1000 + 0.5), " MS")
}

local func signed(v){
  local s = to_int(v * 100 + 0.5) - 100
  if(s >= 0){
    return concat("+", s)
  }
  return string(s)
}

local scale_names = {
  "CHROM", "MAJOR", "MINOR", "PENT+", "PENT-", "DORIAN", "BLUES", "WHOLE"
}
local note_names = {
  "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"
}
rack.note_names = note_names

// the kinds, in the order of the add menu: {name, kind, color, tip,
// params, inputs, outputs, grid (height of a drawn area under the title)}
local catalog = {
  {
    name: "OUT", kind: K.OUT, color: "red",
    tip: "THE SPEAKERS: LEFT ALONE PLAYS ON BOTH",
    params: {knob("volume", "VOL", 0.7, pct)}, inputs: {"L", "R"},
    outputs: {"MON"}
  },
  {
    name: "VCO",
    kind: K.VCO,
    color: "orange",
    tip: "OSCILLATOR: SAW, PULSE, TRIANGLE, SINE",
    params: {
      steps("oct", "OCT", 5, 2, null, -2),
      steps("coarse", "SEMI", 25, 12, null, -12),
      knob("fine", "FINE", 0.5, func(v){ return concat(signed(v), " CT") }),
      knob("pw", "PW", 0.5, pct),
      knob("fm", "FM", 0.0, pct),
    },
    inputs: {"V/O", "FM", "PWM", "SYN"},
    outputs: {"SAW", "PLS", "TRI", "SIN"},
  },
  {
    name: "VCF",
    kind: K.VCF,
    color: "green",
    tip: "LADDER FILTER: LOW, BAND, HIGH",
    params: {
      knob("cutoff", "CUT", 0.6, func(v){ return hz(2 ^ (4.32 + v * 9.6)) }),
      knob("res", "RES", 0.2, pct),
      knob("cv", "CV", 0.5, signed),
      knob("drive", "DRV", 0.0, pct),
    },
    inputs: {"IN", "CV", "RES"},
    outputs: {"LP", "BP", "HP"},
  },
  {
    name: "VCA",
    kind: K.VCA,
    color: "green",
    tip: "AMPLIFIER: IN TIMES CV (OR GAIN ALONE)",
    params: {
      knob("gain", "GAIN", 0.5, func(v){ return pct(v * 2) }),
      knob("cv", "CV", 1.0, pct),
    },
    inputs: {"IN", "CV"},
    outputs: {"OUT"},
  },
  {
    name: "ADSR",
    kind: K.ADSR,
    color: "blue",
    tip: "ENVELOPE: ATTACK, DECAY, SUSTAIN, RELEASE",
    params: {
      knob("a", "A", 0.2, func(v){ return ms(0.001 * 2 ^ (v * 12)) }),
      knob("d", "D", 0.4, func(v){ return ms(0.005 * 2 ^ (v * 10.6)) }),
      knob("s", "S", 0.6, pct),
      knob("r", "R", 0.4, func(v){ return ms(0.005 * 2 ^ (v * 10.6)) }),
    },
    inputs: {"GAT", "TRG"},
    outputs: {"ENV", "INV"},
  },
  {
    name: "LFO",
    kind: K.LFO,
    color: "blue",
    tip: "SLOW OSCILLATOR: SINE, TRIANGLE, SQUARE, SAW",
    params: {
      knob("rate", "RATE", 0.4, func(v){ return hz(0.05 * 2 ^ (v * 9.2)) }),
    },
    inputs: {"CV", "RST"},
    outputs: {"SIN", "TRI", "SQR", "SAW"},
  },
  {
    name: "MIX",
    kind: K.MIX,
    color: "grey",
    tip: "FOUR CHANNELS; 1 AND 3 LEAN LEFT, 2 AND 4 RIGHT",
    params: {
      knob("l1", "1", 0.8, pct),
      knob("l2", "2", 0.8, pct),
      knob("l3", "3", 0.8, pct),
      knob("l4", "4", 0.8, pct),
      knob("spread", "SPRD", 0.5, pct),
    },
    inputs: {"1", "2", "3", "4"},
    outputs: {"MON", "L", "R"},
  },
  {
    name: "NOISE", kind: K.NOISE, color: "orange",
    tip: "WHITE, PINK, AND A SAMPLE HELD ON TRG",
    params: {knob("level", "LVL", 1.0, pct)}, inputs: {"TRG"},
    outputs: {"WHT", "PNK", "S&H"}
  },
  {
    name: "S&H",
    kind: K.SH,
    color: "grey",
    tip: "HOLDS IN AT A TRIGGER; TRACKS WHILE IT IS HIGH; SLEWS THE HELD VALUE",
    params: {knob("slew", "SLEW", 0.0, func(v){ return ms(v * v * 2) })},
    inputs: {"IN", "TRG"},
    outputs: {"S&H", "T&H", "SLW"},
  },
  {
    name: "DELAY",
    kind: K.DELAY,
    color: "purple",
    tip: "TAPE-STYLE DELAY: TIME SLIDES",
    params: {
      knob("time", "TIME", 0.5, func(v){ return ms(0.01 * 2 ^ (v * 7.2)) }),
      knob("fb", "FB", 0.4, pct),
      knob("mix", "MIX", 0.3, pct),
      knob("tone", "TONE", 0.6, func(v){ return hz(200 * 2 ^ (v * 6.3)) }),
    },
    inputs: {"IN", "CV"},
    outputs: {"MIX", "WET"},
  },
  {
    name: "CRUSH",
    kind: K.CRUSH,
    color: "purple",
    tip: "A BITCRUSHER: FEWER BITS, A LOWER SAMPLE RATE",
    params: {
      knob("bits", "BITS", 0.5, func(v){
        return concat("", to_int((1 + v * 15) * 10 + 0.5) / 10, " BIT")
      }),
      knob("rate", "RATE", 0.3, func(v){
        return concat("/", to_int(2 ^ (v * 7) * 10 + 0.5) / 10)
      }),
      knob("mix", "MIX", 1.0, pct),
    },
    inputs: {"IN", "BIT", "RTE"},
    outputs: {"OUT"},
  },
  {
    name: "REVERB",
    kind: K.REVERB,
    color: "purple",
    tip: "A SMALL HALL",
    params: {
      knob("size", "SIZE", 0.6, pct),
      knob("damp", "DAMP", 0.4, pct),
      knob("mix", "MIX", 0.25, pct),
    },
    inputs: {"IN"},
    outputs: {"MIX", "WET"},
  },
  {
    name: "SEQ",
    kind: K.SEQ,
    color: "yellow",
    tip: "16 STEPS, 8 PATTERNS: CLICK A STEP, DRAG ITS NOTE, RIGHT CLICK TIES",
    params: {
      steps("steps", "STEP", 16, 15, null, 1),
      steps("oct", "OCT", 5, 2, null, -2),
      knob("gate", "GATE", 0.5, pct),
      steps("transpose", "TRNS", 25, 12, null, -12),
    },
    inputs: {"CLK", "RST"},
    outputs: {"CV", "GAT", "TRG", "RMP"},
    grid: 52,
  },
  {
    name: "TRIGS",
    kind: K.TRIGS,
    color: "yellow",
    tip: "FOUR ROWS OF 16 TRIGGERS, 8 PATTERNS",
    params: {steps("steps", "STEP", 16, 15, null, 1)},
    inputs: {"CLK", "RST"},
    outputs: {"1", "2", "3", "4"},
    grid: 28,
  },
  {
    name: "FM",
    kind: K.FM,
    color: "orange",
    tip: "SIX-OPERATOR FM VOICE, 32 PRESETS: CLICK ITS FACE (OR E) TO EDIT",
    params: {
      steps("patch", "PATCH", len(bank), 0, fm_names, null),
      knob("level", "LVL", 0.7, pct),
      knob("mod", "MOD", 0.0, pct),
    },
    inputs: {"V/O", "GAT", "VEL", "MOD"},
    outputs: {"OUT", "EG"},
    grid: 50,
  },
  {
    name: "808",
    kind: K.TR808,
    color: "orange",
    tip: "808-STYLE DRUMS: KICK, SNARE, CLAP, HATS, COWBELL; HITS FOLLOW ACC",
    params: {
      knob("tune", "TUNE", 0.4, func(v){ return hz(40 + v * 40) }),
      knob("kdecay", "KDEC", 0.5, func(v){ return ms(0.08 + v * v * 1.5) }),
      knob("tone", "TONE", 0.3, pct),
      knob("stune", "STUN", 0.4, func(v){ return hz(150 + v * 150) }),
      knob("snap", "SNAP", 0.6, pct),
      knob("sdecay", "SDEC", 0.4, func(v){ return ms(0.04 + v * 0.25) }),
      knob("cdecay", "CLAP", 0.4, func(v){ return ms(0.04 + v * 0.4) }),
      knob("htone", "HTON", 0.5, pct),
      knob("chdecay", "CHAT", 0.3, func(v){ return ms(0.015 + v * 0.2) }),
      knob("ohdecay", "OHAT", 0.4, func(v){ return ms(0.1 + v * 1.5) }),
      knob("accent", "ACC", 0.5, pct),
      knob("level", "LVL", 0.6, pct),
    },
    inputs: {"BD", "SD", "CP", "CH", "OH", "CB", "ACC"},
    outputs: {"BD", "SD", "CP", "HH", "CB", "MIX"},
  },
  {
    name: "DRUMS",
    kind: K.DRUMS,
    color: "orange",
    tip: "KICK, SNARE AND HAT FROM TRIGGERS",
    params: {
      knob("tune", "TUNE", 0.3, pct),
      knob("kdecay", "KDEC", 0.4, pct),
      knob("tone", "TONE", 0.5, pct),
      knob("sdecay", "SDEC", 0.4, pct),
      knob("hdecay", "HDEC", 0.2, pct),
      knob("level", "LVL", 0.6, pct),
    },
    inputs: {"KCK", "SNR", "HAT"},
    outputs: {"KCK", "SNR", "HAT", "MIX"},
  },
  {
    name: "CLOCK",
    kind: K.CLOCK,
    color: "yellow",
    tip: "THE TRANSPORT (SPACE); SONG MODE FOLLOWS THE CHAIN",
    params: {
      knob("bpm", "BPM", 0.4, func(v){
        return concat("", to_int(40 + v * 200 + 0.5), " BPM")
      }),
      knob("swing", "SWNG", 0.0, pct),
      steps("bars", "BARS", 4, 0, {"1", "2", "4", "8"}, null),
      steps("song", "SONG", 2, 0, {"OFF", "ON"}, null),
    },
    inputs: {"RUN"},
    outputs: {"16", "8", "4", "BAR"},
    grid: 22,
  },
  {
    name: "KBD", kind: K.KBD, color: "grey",
    tip: "THE COMPUTER KEYBOARD OR A MIDI CONTROLLER",
    params: {knob("glide", "GLID", 0.0, pct)}, inputs: {},
    outputs: {"CV", "GAT", "VEL", "WHL"}
  },
  {
    name: "QUANT",
    kind: K.QUANT,
    color: "grey",
    tip: "SNAPS A PITCH TO A SCALE",
    params: {
      steps("scale", "SCL", 8, 1, scale_names, null),
      steps("root", "ROOT", 12, 0, note_names, null),
    },
    inputs: {"IN"},
    outputs: {"OUT"},
  },
  {
    name: "SCOPE",
    kind: K.SCOPE,
    color: "green",
    tip: "AN OSCILLOSCOPE: TRIGGERS ON IN RISING THROUGH TRIG, OR ON TRG",
    params: {
      knob("time", "TIME", 0.5, func(v){ return ms(0.002 * 2 ^ (v * 6.6)) }),
      knob("trig", "TRIG", 0.5, func(v){
        return concat("", to_int((v * 2 - 1) * 100 + 0.5) / 100)
      }),
      knob("gain", "GAIN", 0.5, func(v){
        return concat("X", to_int(0.25 * 2 ^ (v * 4) * 100 + 0.5) / 100)
      }),
    },
    inputs: {"IN", "TRG"},
    outputs: {"OUT"},
  },
  {
    name: "MATH",
    kind: K.MATH,
    color: "grey",
    tip: "A*KA + B*KB + OFFSET; A*B; MAX; MIN",
    params: {
      knob("ka", "KA", 0.75, func(v){
        return concat("", to_int((v * 4 - 2) * 100 + 0.5) / 100)
      }),
      knob("kb", "KB", 0.75, func(v){
        return concat("", to_int((v * 4 - 2) * 100 + 0.5) / 100)
      }),
      knob("offset", "OFFS", 0.5, func(v){
        return concat("", to_int((v * 4 - 2) * 100 + 0.5) / 100)
      }),
    },
    inputs: {"A", "B"},
    outputs: {"SUM", "A*B", "MAX", "MIN"},
  },
}
rack.catalog = catalog

local by_name = {}
local by_kind = {}
for(let local c in values(catalog)){
  by_name[c.name] = c
  by_kind[c.kind] = c
}

// spec(name or kind) -> the catalog entry
func rack.spec(what){
  if(type(what) == "string"){
    return by_name[what]
  }
  return by_kind[what]
}

// shown(spec, i, v) -> how knob i's value v reads on the status line
func rack.shown(spec, i, v){
  local p = spec.params[i]
  if(p.kind == "steps"){
    if(p.labels != null){
      return p.labels[to_int(v)]
    }
    local n = to_int(v) + p.offset
    if(n > 0){
      return concat("+", n)
    }
    return string(n)
  }
  return p.show(v)
}

// ------------------------------------------------------------ the rack

local Rack = {}
local rack_meta = {__index: Rack}

// new(make: (type, n) -> Buffer) -> Rack: buffer.shared for a rack the
// engine plays in its isolate, buffer.new for one rendered here
func rack.new(make){
  local r = {
    a: engine.arrays(make),
    modules: {}, // by slot: {kind, spec, params: {values}, seq?: {ints}}
    cables: {}, // {from: {m, o}, to: {m, i}}
    song: {}, // pattern indices, 0..7
    name: "untitled",
    path: null,
    @meta: rack_meta,
  }
  for(local m = 0; m < engine.MAX; m = m + 1){
    r.modules[m] = null
  }
  r.a.order[0] = -1
  return r
}

// slots(): the slots in use, in order
func Rack.slots(self){
  local out = {}
  for(local m = 0; m < engine.MAX; m = m + 1){
    if(self.modules[m] != null){
      append(out, m)
    }
  }
  return out
}

// add(name) -> slot or null when the rack is full
func Rack.add(self, name){
  local spec = by_name[name]
  for(local m = 0; m < engine.MAX; m = m + 1){
    if(self.modules[m] == null){
      local mod = {kind: spec.kind, spec: spec, params: {}}
      for(let local p in values(spec.params)){
        append(mod.params, p.default)
      }
      if(spec.kind == K.SEQ or spec.kind == K.TRIGS){
        mod.seq = {}
        for(local i = 0; i < engine.SEQW; i = i + 1){
          append(mod.seq, 0)
        }
      }
      if(spec.kind == K.FM){
        mod.fm = patch.copy(bank[0])
        mod.fm_edited = false
      }
      self.modules[m] = mod
      self:write_module(m)
      self.a.flags[m] = 1
      self:write_cables()
      return m
    }
  }
  return null
}

// remove(m): the module and its cables
func Rack.remove(self, m){
  if(self.modules[m] == null){
    return
  }
  self.modules[m] = null
  local keep = {}
  for(let local c in values(self.cables)){
    if(c.from.m != m and c.to.m != m){
      append(keep, c)
    }
  }
  self.cables = keep
  self.a.kinds[m] = 0
  self:write_cables()
}

// clear(): an empty rack
func Rack.clear(self){
  for(local m = 0; m < engine.MAX; m = m + 1){
    self.modules[m] = null
    self.a.kinds[m] = 0
  }
  self.cables = {}
  self.song = {}
  self:write_cables()
  self:write_song()
}

// write_module(m): its kind, knobs and sequence into the buffers
func Rack.write_module(self, m){
  local mod = self.modules[m]
  local a = self.a
  if(mod == null){
    a.kinds[m] = 0
    return
  }
  for(local i = 0; i < engine.NP; i = i + 1){
    a.params[m * engine.NP + i] = mod.params[i] or 0
  }
  if(mod.seq != null){
    for(local i = 0; i < engine.SEQW; i = i + 1){
      a.seqdata[m * engine.SEQW + i] = mod.seq[i]
    }
  }
  if(mod.fm != null){
    self:write_fm(m)
  }
  a.kinds[m] = mod.kind
}

// set_param(m, i, v): knob i of module m (clamped to its range); an FM
// module's PATCH stepper loads that preset of the bank
func Rack.set_param(self, m, i, v){
  local mod = self.modules[m]
  local p = mod.spec.params[i]
  if(p.kind == "steps"){
    if(v < 0){
      v = 0
    } else if(v > p.n - 1){
      v = p.n - 1
    }
  } else if(v < 0){
    v = 0.0
  } else if(v > 1){
    v = 1.0
  }
  if(mod.kind == K.FM and i == 0){
    self:fm_select(m, to_int(v))
    return
  }
  mod.params[i] = v
  self.a.params[m * engine.NP + i] = v
}

// ---- the FM module's patch: fm/patch.slang's shape ({name, algorithm,
// feedback, ..., ops: {six operators}}), a copy of a preset of the bank
// that fm_set edits field by field; the kernel reads it from fmdata
// (engine.fm) and hears every edit at once

// fm_field(op, id) -> the field's spec: op null for a voice field
func rack.fm_field(op, id){
  local list = patch.VOICE_FIELDS
  if(op != null){
    list = patch.OP_FIELDS
  }
  for(let local f in values(list)){
    if(f.id == id){
      return f
    }
  }
  raise(error.new(error.kinds.argument, concat("fm: no field ", id)))
}

// write_fm(m): the patch and what the kernel needs of its algorithm into
// fmdata, with a new version
func Rack.write_fm(self, m){
  local mod = self.modules[m]
  local p = mod.fm
  local d = self.a.fmdata
  local F = engine.fm
  local base = m * engine.FMW
  for(local k = 0; k < 6; k = k + 1){
    for(local i = 0; i < len(patch.OP_FIELDS); i = i + 1){
      d[base + k * F.OPW + i] = p.ops[k][patch.OP_FIELDS[i].id]
    }
  }
  for(local i = 0; i < len(patch.VOICE_FIELDS); i = i + 1){
    d[base + F.VOICE + i] = p[patch.VOICE_FIELDS[i].id]
  }
  local alg = algorithms.get(p.algorithm)
  for(local k = 0; k < 6; k = k + 1){
    local mods = alg.mods[k + 1]
    for(local j = 0; j < 3; j = j + 1){
      local from = -1
      if(j < len(mods)){
        from = mods[j] - 1
      }
      d[base + F.ROUTE + k * 3 + j] = from
    }
    d[base + F.CARRIER + k] = 0
    if(algorithms.is_carrier(alg, k + 1)){
      d[base + F.CARRIER + k] = 1
    }
  }
  d[base + F.FB_FROM] = alg.fb_from - 1
  d[base + F.FB_TO] = alg.fb_to - 1
  mod.fm_version = (mod.fm_version or 0) + 1
  d[base + F.VERSION] = mod.fm_version
}

// fm_select(m, i): preset i of the bank into module m (its edits undone)
func Rack.fm_select(self, m, i){
  local mod = self.modules[m]
  mod.fm = patch.copy(bank[i])
  mod.fm_edited = false
  mod.params[0] = i
  self.a.params[m * engine.NP] = i
  self:write_fm(m)
}

// fm_get(m, op, id) -> the value of a field (op 0..5, or null for the
// voice's fields)
func Rack.fm_get(self, m, op, id){
  local p = self.modules[m].fm
  if(op == null){
    return p[id]
  }
  return p.ops[op][id]
}

// fm_preset_value(m, op, id) -> the field as the preset has it
func Rack.fm_preset_value(self, m, op, id){
  local p = bank[to_int(self.modules[m].params[0])]
  if(op == null){
    return p[id]
  }
  return p.ops[op][id]
}

// fm_set(m, op, id, v) -> the value set: rounded and clamped to the
// field's range
func Rack.fm_set(self, m, op, id, v){
  local mod = self.modules[m]
  local f = rack.fm_field(op, id)
  v = to_int(v + 0.5)
  if(v < f.min){
    v = f.min
  } else if(v > f.max){
    v = f.max
  }
  if(op == null){
    mod.fm[id] = v
  } else {
    mod.fm.ops[op][id] = v
  }
  mod.fm_edited = true
  self:write_fm(m)
  return v
}

// cable_to(m, i) -> the cable into input i of module m, or null
func Rack.cable_to(self, m, i){
  for(let local c in values(self.cables)){
    if(c.to.m == m and c.to.i == i){
      return c
    }
  }
  return null
}

// connect(from_m, o, to_m, i): output o of from_m into input i of to_m
// (replacing what was patched there)
func Rack.connect(self, from_m, o, to_m, i){
  self:disconnect(to_m, i)
  append(self.cables, {from: {m: from_m, o: o}, to: {m: to_m, i: i}})
  self:write_cables()
}

// disconnect(m, i): nothing into input i of module m
func Rack.disconnect(self, m, i){
  local keep = {}
  for(let local c in values(self.cables)){
    if(not(c.to.m == m and c.to.i == i)){
      append(keep, c)
    }
  }
  self.cables = keep
  self:write_cables()
}

// order(): the slots in use, sources before what they feed (Kahn's
// algorithm, slot order among equals; a cycle's modules go last in slot
// order and read the previous sample across the loop)
func Rack.order(self){
  local slots = self:slots()
  local indeg = {}
  local outs = {}
  for(let local m in values(slots)){
    indeg[m] = 0
    outs[m] = {}
  }
  for(let local c in values(self.cables)){
    if(c.from.m != c.to.m){
      indeg[c.to.m] = indeg[c.to.m] + 1
      append(outs[c.from.m], c.to.m)
    }
  }
  local out = {}
  local done = {}
  for(len(out) < len(slots)){
    local next = null
    for(let local m in values(slots)){
      if(done[m] == null and indeg[m] == 0){
        next = m
        break
      }
    }
    if(next == null){
      // a cycle: take the lowest slot left
      for(let local m in values(slots)){
        if(done[m] == null){
          next = m
          break
        }
      }
    }
    done[next] = true
    append(out, next)
    for(let local t in values(outs[next])){
      indeg[t] = indeg[t] - 1
    }
  }
  return out
}

// write_cables(): the inputs and the order into the buffers
func Rack.write_cables(self){
  local a = self.a
  for(local i = 0; i < engine.MAX * engine.NI; i = i + 1){
    a.inputs[i] = -1
  }
  for(let local c in values(self.cables)){
    a.inputs[c.to.m * engine.NI + c.to.i] = c.from.m * engine.NO + c.from.o
  }
  local order = self:order()
  // the terminator first, so the kernel never reads a stale tail
  a.order[len(order)] = -1
  for(local k = 0; k < len(order); k = k + 1){
    a.order[k] = order[k]
  }
}

// write_song(): the chain into the buffer
func Rack.write_song(self){
  local n = len(self.song)
  if(n > engine.SONG - 1){
    n = engine.SONG - 1
  }
  for(local i = 0; i < n; i = i + 1){
    self.a.song[1 + i] = self.song[i]
  }
  self.a.song[0] = n
}

// ---- sequences (SEQ: 8 patterns of 16 notes then 16 gates, 64 ints a
// pattern; TRIGS: 8 patterns of 4 rows of 16)

func Rack.seq_note(self, m, pattern, step){
  return self.modules[m].seq[pattern * 64 + step]
}

func Rack.seq_gate(self, m, pattern, step){
  return self.modules[m].seq[pattern * 64 + 16 + step]
}

// set_step(m, pattern, step, note, gate): a SEQ step (note in semitones
// from C4, -24..24; gate 0 off, 1 on, 2 tied)
func Rack.set_step(self, m, pattern, step, note, gate){
  local mod = self.modules[m]
  if(note < -24){
    note = -24
  } else if(note > 24){
    note = 24
  }
  mod.seq[pattern * 64 + step] = note
  mod.seq[pattern * 64 + 16 + step] = gate
  local base = m * engine.SEQW + pattern * 64
  self.a.seqdata[base + step] = note
  self.a.seqdata[base + 16 + step] = gate
}

func Rack.trig(self, m, pattern, row, step){
  return self.modules[m].seq[pattern * 64 + row * 16 + step]
}

func Rack.set_trig(self, m, pattern, row, step, on){
  local at = pattern * 64 + row * 16 + step
  self.modules[m].seq[at] = on
  self.a.seqdata[m * engine.SEQW + at] = on
}

// copy_pattern(m, from, to): a sequencer's pattern onto another
func Rack.copy_pattern(self, m, from, to){
  local mod = self.modules[m]
  for(local i = 0; i < 64; i = i + 1){
    mod.seq[to * 64 + i] = mod.seq[from * 64 + i]
    self.a.seqdata[m * engine.SEQW + to * 64 + i] = mod.seq[to * 64 + i]
  }
}

// ---- files

// to_table() -> the patch as plain data (what save writes)
func Rack.to_table(self){
  local mods = {}
  for(let local m in values(self:slots())){
    local mod = self.modules[m]
    local params = {}
    for(local i = 0; i < len(mod.spec.params); i = i + 1){
      params[mod.spec.params[i].id] = mod.params[i]
    }
    local t = {slot: m, kind: mod.spec.name, params: params}
    if(mod.seq != null){
      // the 512 ints as one line
      local parts = {}
      for(let local v in values(mod.seq)){
        append(parts, string(v))
      }
      t.seq = str.join(parts, ",")
    }
    if(mod.fm != null and mod.fm_edited){
      t.fm = patch.copy(mod.fm)
    }
    append(mods, t)
  }
  local cables = {}
  for(let local c in values(self.cables)){
    append(cables, {c.from.m, c.from.o, c.to.m, c.to.i})
  }
  return {name: self.name, modules: mods, cables: cables, song: self.song}
}

// from_table(t): the rack as t describes it (replacing what was there)
func Rack.from_table(self, t){
  self:clear()
  self.name = t.name or "untitled"
  for(let local mt in values(t.modules)){
    local spec = by_name[mt.kind]
    if(spec == null){
      continue
    }
    local mod = {kind: spec.kind, spec: spec, params: {}}
    for(let local p in values(spec.params)){
      local v = p.default
      if(mt.params != null and mt.params[p.id] != null){
        v = mt.params[p.id]
      }
      append(mod.params, v)
    }
    if(spec.kind == K.SEQ or spec.kind == K.TRIGS){
      mod.seq = {}
      local given = {}
      if(type(mt.seq) == "string"){
        given = str.split(mt.seq, ",")
      } else if(mt.seq != null){
        given = mt.seq
      }
      for(local i = 0; i < engine.SEQW; i = i + 1){
        local v = 0
        if(i < len(given)){
          v = to_int(str.to_number(string(given[i])))
        }
        append(mod.seq, v)
      }
    }
    if(spec.kind == K.FM){
      // the preset, with the file's edits over it
      mod.fm = patch.copy(bank[to_int(mod.params[0])])
      mod.fm_edited = false
      if(mt.fm != null){
        mod.fm_edited = true
        mod.fm.name = mt.fm.name or mod.fm.name
        for(let local f in values(patch.VOICE_FIELDS)){
          if(mt.fm[f.id] != null){
            mod.fm[f.id] = to_int(mt.fm[f.id])
          }
        }
        for(local k = 0; k < 6; k = k + 1){
          local o = (mt.fm.ops or {})[k]
          if(o == null){
            continue
          }
          for(let local f in values(patch.OP_FIELDS)){
            if(o[f.id] != null){
              mod.fm.ops[k][f.id] = to_int(o[f.id])
            }
          }
        }
      }
    }
    self.modules[mt.slot] = mod
    self:write_module(mt.slot)
    self.a.flags[mt.slot] = 1
  }
  for(let local c in values(t.cables or {})){
    if(self.modules[c[0]] != null and self.modules[c[2]] != null){
      append(self.cables, {from: {m: c[0], o: c[1]}, to: {m: c[2], i: c[3]}})
    }
  }
  self.song = {}
  for(let local p in values(t.song or {})){
    append(self.song, to_int(p))
  }
  self:write_cables()
  self:write_song()
}

// save(path?): the patch as JSON (to its own path by default)
func Rack.save(self, path){
  path = path or self.path
  os.write_file(path, json.encode(self:to_table(), {indent: "  "}))
  self.path = path
}

// load(path): a patch from JSON; its name from the file's
func Rack.load(self, path){
  self:from_table(json.decode(os.read_file(path)))
  self.path = path
  local base = path
  local slash = str.last_index_of(base, "/")
  if(slash != null and slash >= 0){
    base = str.substring(base, slash + 1)
  }
  self.name = str.upper(str.trim_suffix(base, ".json"))
}

return rack
