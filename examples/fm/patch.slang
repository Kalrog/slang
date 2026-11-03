// What a patch is: the parameters of six operators and of the voice, their
// ranges (the editor's and the patch files' units, as on the classic
// six-operator synthesizers: mostly 0 to 99), and how a patch file writes
// them compactly.
//
// A patch:
//   {name, algorithm (1..32), feedback (0..7), osc_sync, transpose,
//    lfo: {wave, speed, delay, pmd, amd, sync}, pms (0..7),
//    pitch_eg: {rates: {r1..r4}, levels: {l1..l4}} (50 is no change),
//    ops: {op1, ..., op6}}
// an operator:
//   {on, mode ("ratio" | "fixed"), coarse, fine, detune (-7..7), level,
//    vel (velocity sensitivity 0..7), rs (rate scaling 0..7), ams (0..3),
//    rates: {r1..r4}, levels: {l1..l4},
//    kls: {break (a note), ldepth, rdepth, lcurve, rcurve}}
// An envelope runs from where it is to l1 at rate r1, to l2 at r2, to l3 at
// r3 and stays there while the key is held; released, it goes to l4 at r4.
local math = require("slang/math")

local patch = {}

patch.WAVES = {"TRI", "SAW DN", "SAW UP", "SQUARE", "SINE", "S/HOLD"}
patch.CURVES = {"-LIN", "-EXP", "+EXP", "+LIN"}
patch.NOTE_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

// the editable fields: {id, label, min, max, kind?} (kind "bool", "enum"
// with labels, "note"); an operator's envelope fields are r1..r4, l1..l4
patch.OP_FIELDS = {
  {id: "on", label: "ON", min: 0, max: 1, kind: "bool"},
  {id: "mode", label: "MODE", min: 0, max: 1, kind: "enum", labels: {"RATIO", "FIXED"}},
  {id: "coarse", label: "COARSE", min: 0, max: 31},
  {id: "fine", label: "FINE", min: 0, max: 99},
  {id: "detune", label: "DET", min: -7, max: 7},
  {id: "level", label: "LEVEL", min: 0, max: 99},
  {id: "vel", label: "VEL", min: 0, max: 7},
  {id: "rs", label: "R.SC", min: 0, max: 7},
  {id: "ams", label: "AMS", min: 0, max: 3},
  {id: "r1", label: "R1", min: 0, max: 99},
  {id: "r2", label: "R2", min: 0, max: 99},
  {id: "r3", label: "R3", min: 0, max: 99},
  {id: "r4", label: "R4", min: 0, max: 99},
  {id: "l1", label: "L1", min: 0, max: 99},
  {id: "l2", label: "L2", min: 0, max: 99},
  {id: "l3", label: "L3", min: 0, max: 99},
  {id: "l4", label: "L4", min: 0, max: 99},
  {id: "break", label: "BREAK", min: 21, max: 108, kind: "note"},
  {id: "ldepth", label: "L.DEP", min: 0, max: 99},
  {id: "rdepth", label: "R.DEP", min: 0, max: 99},
  {id: "lcurve", label: "L.CRV", min: 0, max: 3, kind: "enum", labels: patch.CURVES},
  {id: "rcurve", label: "R.CRV", min: 0, max: 3, kind: "enum", labels: patch.CURVES},
}

patch.VOICE_FIELDS = {
  {id: "algorithm", label: "ALGORITHM", min: 1, max: 32},
  {id: "feedback", label: "FEEDBACK", min: 0, max: 7},
  {id: "osc_sync", label: "OSC SYNC", min: 0, max: 1, kind: "bool"},
  {id: "transpose", label: "TRANSPOSE", min: -24, max: 24},
  {id: "wave", label: "LFO WAVE", min: 0, max: 5, kind: "enum", labels: patch.WAVES},
  {id: "speed", label: "LFO SPEED", min: 0, max: 99},
  {id: "delay", label: "LFO DELAY", min: 0, max: 99},
  {id: "pmd", label: "PITCH DEPTH", min: 0, max: 99},
  {id: "amd", label: "AMP DEPTH", min: 0, max: 99},
  {id: "lfo_sync", label: "LFO SYNC", min: 0, max: 1, kind: "bool"},
  {id: "pms", label: "PITCH SENS", min: 0, max: 7},
  {id: "pr1", label: "P.R1", min: 0, max: 99},
  {id: "pr2", label: "P.R2", min: 0, max: 99},
  {id: "pr3", label: "P.R3", min: 0, max: 99},
  {id: "pr4", label: "P.R4", min: 0, max: 99},
  {id: "pl1", label: "P.L1", min: 0, max: 99},
  {id: "pl2", label: "P.L2", min: 0, max: 99},
  {id: "pl3", label: "P.L3", min: 0, max: 99},
  {id: "pl4", label: "P.L4", min: 0, max: 99},
}

// ------------------------------------------------------------ writing patches

// the defaults of an operator: a sine at the key's pitch, silent, with an
// organ envelope
local func op_defaults(){
  return {
    on: 1, mode: 0, coarse: 1, fine: 0, detune: 0, level: 0, vel: 0, rs: 0,
    ams: 0, r1: 99, r2: 99, r3: 99, r4: 70, l1: 99, l2: 99, l3: 99, l4: 0,
    ["break"]: 60, ldepth: 0, rdepth: 0, lcurve: 0, rcurve: 0,
  }
}

local func voice_defaults(){
  return {
    name: "INIT VOICE", algorithm: 1, feedback: 0, osc_sync: 1, transpose: 0,
    wave: 0, speed: 35, delay: 0, pmd: 0, amd: 0, lfo_sync: 1, pms: 3,
    pr1: 99, pr2: 99, pr3: 99, pr4: 99, pl1: 50, pl2: 50, pl3: 50, pl4: 50,
  }
}

local func index_of(list, v){
  for(local i = 0; i < len(list); i = i + 1){
    if(list[i] == v){
      return i
    }
  }
  error(concat("patch: ", string(v), " is not one of ", string(list)))
}

// ratio -> coarse, fine: coarse 0 is 0.5, fine adds hundredths of coarse
local func ratio_fields(r){
  local coarse = math.floor(r)
  local base = coarse
  if(coarse < 1){
    coarse = 0
    base = 0.5
  }
  local fine = math.round((r / base - 1) * 100)
  if(fine > 99){
    error(concat("patch: ratio ", string(r), " cannot be written (fine ", string(fine), ")"))
  }
  return {coarse: to_int(coarse), fine: to_int(fine)}
}

// op(t) -> an operator: the defaults, with t's fields, where t may write
//   ratio: 2.76 (for coarse and fine), fixed: 440 (Hz, for mode, coarse and
//   fine), eg: {{r1, r2, r3, r4}, {l1, l2, l3, l4}}, curves by name
func patch.op(t){
  local o = op_defaults()
  for(let local e in entries(t)){
    local k = e[0]
    local v = e[1]
    if(k == "ratio"){
      local f = ratio_fields(v)
      o.mode = 0
      o.coarse = f.coarse
      o.fine = f.fine
    } else if(k == "fixed"){
      local decade = to_int(math.floor(math.log10(v)))
      o.mode = 1
      o.coarse = decade
      o.fine = to_int(math.round(math.log10(v / (10 ^ decade)) * 100))
    } else if(k == "eg"){
      o.r1 = v[0][0]
      o.r2 = v[0][1]
      o.r3 = v[0][2]
      o.r4 = v[0][3]
      o.l1 = v[1][0]
      o.l2 = v[1][1]
      o.l3 = v[1][2]
      o.l4 = v[1][3]
    } else if(k == "lcurve" or k == "rcurve"){
      o[k] = index_of(patch.CURVES, v)
    } else {
      if(o[k] == null){
        error(concat("patch: an operator has no field ", k))
      }
      o[k] = v
    }
  }
  return o
}

// voice(t) -> a patch: the defaults with t's fields; t.ops lists operators
// 1 to 6 (missing ones are silent), t.lfo {wave, speed, delay, pmd, amd,
// sync} and t.pitch_eg {{rates}, {levels}} are written as tables
func patch.voice(t){
  local p = voice_defaults()
  for(let local e in entries(t)){
    local k = e[0]
    local v = e[1]
    if(k == "ops"){
      // set below
    } else if(k == "lfo"){
      for(let local f in entries(v)){
        if(f[0] == "wave"){
          p.wave = index_of(patch.WAVES, f[1])
        } else if(f[0] == "sync"){
          p.lfo_sync = f[1]
        } else {
          p[f[0]] = f[1]
        }
      }
    } else if(k == "pitch_eg"){
      p.pr1 = v[0][0]
      p.pr2 = v[0][1]
      p.pr3 = v[0][2]
      p.pr4 = v[0][3]
      p.pl1 = v[1][0]
      p.pl2 = v[1][1]
      p.pl3 = v[1][2]
      p.pl4 = v[1][3]
    } else {
      if(p[k] == null){
        error(concat("patch: a voice has no field ", k))
      }
      p[k] = v
    }
  }
  p.ops = {}
  for(local i = 0; i < 6; i = i + 1){
    local o = (t.ops or {})[i]
    if(o == null){
      o = patch.op({})
    }
    append(p.ops, o)
  }
  patch.check(p)
  return p
}

// check(p): every field in its range (raises naming the patch and field)
func patch.check(p){
  local func in_range(where, f, v){
    if(type(v) != "int" or v < f.min or v > f.max){
      error(concat("patch ", p.name, ": ", where, f.id, " is ", string(v), ", not ", string(f.min), "..", string(f.max)))
    }
  }
  for(let local f in values(patch.VOICE_FIELDS)){
    in_range("", f, p[f.id])
  }
  for(local i = 0; i < 6; i = i + 1){
    for(let local f in values(patch.OP_FIELDS)){
      in_range(concat("op ", string(i + 1), " "), f, p.ops[i][f.id])
    }
  }
}

// copy(p) -> a deep copy (for the editor's undo of edits: choosing a patch
// again restores it)
func patch.copy(p){
  local out = {}
  for(let local e in entries(p)){
    out[e[0]] = e[1]
  }
  out.ops = {}
  for(let local o in values(p.ops)){
    local c = {}
    for(let local e in entries(o)){
      c[e[0]] = e[1]
    }
    append(out.ops, c)
  }
  return out
}

// ------------------------------------------------------------ the numbers

// ratio(op) -> the frequency ratio of a ratio-mode operator
func patch.ratio(o){
  local base = o.coarse * 1.0
  if(o.coarse == 0){
    base = 0.5
  }
  return base * (1 + o.fine / 100)
}

// fixed_hz(op) -> the frequency of a fixed-mode operator: 1, 10, 100 or
// 1000 Hz times 10^(fine / 100)
func patch.fixed_hz(o){
  return (10 ^ (o.coarse % 4)) * (10 ^ (o.fine / 100))
}

// frequency(op) -> how the editor shows it: "1.00", "3.50", "440 Hz"
func patch.frequency_text(o){
  if(o.mode == 1){
    local hz = patch.fixed_hz(o)
    if(hz >= 100){
      return concat(string(to_int(math.round(hz))), "Hz")
    }
    return concat(string(math.round(hz * 10) / 10), "Hz")
  }
  local r = math.round(patch.ratio(o) * 100) / 100
  local s = string(r)
  // two decimals
  local dot = require("slang/string").index_of(s, ".")
  if(dot < 0){
    return concat(s, ".00")
  }
  if(len(s) - dot == 2){
    return concat(s, "0")
  }
  return s
}

// field_text(field, v) -> how a value shows: "ON", "SINE", "C4", "+3", "42"
func patch.field_text(f, v){
  if(f.kind == "bool"){
    if(v == 1){
      return "ON"
    }
    return "OFF"
  }
  if(f.kind == "enum"){
    return f.labels[v]
  }
  if(f.kind == "note"){
    return patch.note_name(v)
  }
  if(f.id == "detune" and v > 0){
    return concat("+", string(v))
  }
  return string(v)
}

func patch.note_name(n){
  return concat(patch.NOTE_NAMES[n % 12], string(to_int(n / 12) - 1))
}

// speed(rate) -> envelope speed in level units (0..99) per second: rate 99
// crosses the whole range in 1.5 ms, rate 0 in about a minute and a half
func patch.speed(rate){
  return 66000.0 * (2 ^ (-(99 - rate) / 6.2))
}

// lfo_hz(speed) -> 0.05 Hz at 0, about 6 Hz at 35, 49 Hz at 99
func patch.lfo_hz(speed){
  return 0.05 + speed * speed * 0.005
}

// lfo_delay(delay) -> seconds before the LFO fades in
func patch.lfo_delay(delay){
  local d = delay / 99
  return d * d * 5
}

// the pitch an LFO at full depth moves, in semitones, by PITCH SENS
patch.PMS = {0, 0.06, 0.12, 0.2, 0.35, 0.65, 1.3, 4.0}
// the attenuation full amplitude modulation gives, in octaves of gain
// (6 dB each), by AMS
patch.AMS = {0, 0.5, 1.2, 3.0}

return patch
