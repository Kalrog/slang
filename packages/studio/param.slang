// studio/param: what a unit's parameters are, and how a slider, a patch,
// an LFO or a MIDI knob moves one.
//
//   local param = require("studio/param")
//   local set = param.set({
//     {name: "cutoff", min: 0, max: 1, default: 0.8},
//     {name: "attack", min: 1, max: 4000, default: 5, unit: "ms", curve: 3},
//     {name: "wave", labels: {"saw", "square", "sine"}, default: "saw"},
//     {name: "sync", kind: "switch", default: 0},
//   })
//   set.index.attack                       // 1: its cell, counted from the unit's first
//   param.from_t(set.list[1], 0.5)         // the value at the slider's middle
//   param.t_of(set.list[1], 500)           // where the slider is at 500 ms
//   param.value(set.list[2], "square")     // 1.0
//   param.text(set.list[1], 500)           // "500 ms"
//
// A parameter is one number (a double). Everything that moves parameters
// does so in the slider's terms, t from 0 to 1, so that half a turn of a
// knob, half an LFO's depth and half a morph mean the same for a time in
// milliseconds as for a level.
local math = require("slang/math")

local param = {}

// One parameter of a unit.
// type Param = {name: string, min: number, max: number, default: number,
//   curve?: number, step?: number, unit?: string, labels?: {string},
//   kind?: string, label?: string, bipolar?: bool}
// [name]: how patches, events and properties name it
// [min], [max]: its range; a value outside is clamped
// [default]: where it starts
// [curve]: the slider's exponent: value = min + (max - min) * t ^ curve;
//   above 1 gives the low end more of the slider's travel (times,
//   frequencies); 1 when absent
// [step]: values are multiples of it (1 for whole numbers)
// [unit]: "ms", "Hz", "st", "dB", "%" or nothing, for showing it
// [labels]: an enumeration: the value is an index into it (min 0, max
//   len - 1, step 1), and patches may write the label
// [kind]: "switch" for 0 or 1; "note" for a MIDI note
// [label]: what a panel prints, when it is not the name
// [bipolar]: a panel draws it from its middle

// set(defs: {Param}) -> ParamSet
// The parameters of a unit, checked and completed (ranges of enumerations
// and switches, defaults as numbers).
// type ParamSet = {list: {Param}, index: {[string]: int}, count: int}
// [list]: the parameters in cell order
// [index]: each one's cell by its name
func param.set(defs){
  local set = {list: {}, index: {}, count: 0}
  for(local i = 0; i < len(defs); i = i + 1){
    local d = defs[i]
    local p = {}
    for(let local e in entries(d)){
      p[e[0]] = e[1]
    }
    if(type(p.name) != "string"){
      raise(error.new(
        error.kinds.argument,
        "studio/param: a parameter needs a name",
      ))
    }
    if(set.index[p.name] != null){
      raise(error.new(
        error.kinds.argument,
        concat("studio/param: two parameters named ", p.name),
      ))
    }
    if(p.labels != null){
      p.min = 0.0
      p.max = (len(p.labels) - 1) * 1.0
      p.step = 1.0
    } else if(p.kind == "switch"){
      p.min = 0.0
      p.max = 1.0
      p.step = 1.0
    }
    if(p.min == null or p.max == null){
      raise(error.new(
        error.kinds.argument,
        concat("studio/param: ", p.name, " needs min and max"),
      ))
    }
    p.min = p.min * 1.0
    p.max = p.max * 1.0
    p.cell = i
    if(p.default == null){
      p.default = p.min
    }
    p.default = param.value(p, p.default)
    set.list[i] = p
    set.index[p.name] = i
  }
  set.count = len(defs)
  return set
}

// value(p: Param, v: number | string | bool) -> number
// v as the parameter holds it: a label's index, a switch's 0 or 1, the
// number clamped to the range and rounded to the step. Raises for a label
// the parameter does not have.
func param.value(p, v){
  if(type(v) == "string"){
    if(p.labels != null){
      for(local i = 0; i < len(p.labels); i = i + 1){
        if(p.labels[i] == v){
          return i * 1.0
        }
      }
    }
    raise(error.new(
      error.kinds.argument,
      concat("studio: ", p.name, " has no setting \"", v, "\""),
    ))
  }
  if(type(v) == "bool"){
    if(v){
      return 1.0
    }
    return 0.0
  }
  if(type(v) != "int" and type(v) != "double"){
    raise(error.new(error.kinds.argument, concat(
      "studio: ", p.name, " takes a number, not ", type(v)
    )))
  }
  local x = v * 1.0
  if(p.step != null){
    x = math.round(x / p.step) * p.step
  }
  if(x < p.min){
    x = p.min
  } else if(x > p.max){
    x = p.max
  }
  return x
}

// from_t(p: Param, t: number) -> number
// The value at slider position t (0..1), through the curve; not rounded
// to the step (an LFO moves an enumeration smoothly up to its next index).
func param.from_t(p, t){
  if(t < 0.0){
    t = 0.0
  } else if(t > 1.0){
    t = 1.0
  }
  if(p.curve != null){
    t = t ^ p.curve
  }
  return p.min + (p.max - p.min) * t
}

// t_of(p: Param, v: number) -> number
// Where the slider is (0..1) for the value v.
func param.t_of(p, v){
  if(p.max == p.min){
    return 0.0
  }
  local t = (v - p.min) / (p.max - p.min)
  if(t < 0.0){
    t = 0.0
  } else if(t > 1.0){
    t = 1.0
  }
  if(p.curve != null){
    t = t ^ (1.0 / p.curve)
  }
  return t
}

// text(p: Param, v: number) -> string
// The value as a panel shows it: a label, "on", "C4", "120 ms", "0.35".
func param.text(p, v){
  if(p.labels != null){
    return p.labels[to_int(math.round(v))] or string(v)
  }
  if(p.kind == "switch"){
    if(v >= 0.5){
      return "on"
    }
    return "off"
  }
  if(p.kind == "note"){
    local n = to_int(math.round(v))
    local names = {
      "C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"
    }
    return concat(names[n % 12], string(to_int(math.floor(n / 12)) - 1))
  }
  local s = ""
  if(p.step != null and p.step >= 1.0){
    s = string(to_int(math.round(v)))
  } else {
    local a = math.abs(v)
    local digits = 100.0
    if(a >= 100.0){
      digits = 1.0
    } else if(a >= 10.0){
      digits = 10.0
    }
    local r = math.round(v * digits) / digits
    if(r == math.floor(r)){
      s = string(to_int(r))
    } else {
      s = string(r)
    }
  }
  if(p.unit != null and p.unit != ""){
    return concat(s, " ", p.unit)
  }
  return s
}

return param
