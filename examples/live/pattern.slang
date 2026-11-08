// Patterns: what a player plays, as steps in time, and signals, values
// that change with the beat. A pattern comes from a backtick literal
// (`0123`, see mini.slang and notation.slang) or pattern.parse(text);
// its steps take one `dur` each (the player's), a subsequence shares a
// step, a chord stacks, a supersequence changes with every repetition.
//
//   local p = pattern.parse("0<24>")        // 0 2 0 4 over two repetitions
//   p:events(1)                             // {{at: 0, len: 1, value: 0, ...}, {at: 1, value: 4, ...}}
//   p:then(pattern.parse("7")):times(2)     // 0 2 7 0 2 7, then 0 4 7 0 4 7
//   pattern.sine(4, 0.2, 0.8):at(1.0)       // a signal: 0.8 at beat 1 of a 4-beat sine
//
// A player asks events_between(p, dur, b0, b1) for the events that start
// in a span of beats, and value_at(x, beat, dur) for what a parameter is
// at a beat: a number, a pattern's step value, a signal's value, a
// control's position.
local mini = require("mini")
local math = require("slang/math")
local str = require("slang/string")
local tbl = require("slang/table")

local pattern = {}

// ------------------------------------------------------------------ scales

pattern.scales = {
  major: {0, 2, 4, 5, 7, 9, 11},
  minor: {0, 2, 3, 5, 7, 8, 10},
  dorian: {0, 2, 3, 5, 7, 9, 10},
  phrygian: {0, 1, 3, 5, 7, 8, 10},
  lydian: {0, 2, 4, 6, 7, 9, 11},
  mixolydian: {0, 2, 4, 5, 7, 9, 10},
  locrian: {0, 1, 3, 5, 6, 8, 10},
  harmonic_minor: {0, 2, 3, 5, 7, 8, 11},
  melodic_minor: {0, 2, 3, 5, 7, 9, 11},
  pentatonic: {0, 2, 4, 7, 9},
  minor_pentatonic: {0, 3, 5, 7, 10},
  blues: {0, 3, 5, 6, 7, 10},
  whole: {0, 2, 4, 6, 8, 10},
  chromatic: {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11},
}

local letters = {c: 0, d: 2, e: 4, f: 5, g: 7, a: 9, b: 11}

// note_name(s: string | number) -> number: the MIDI note of "c4" (60),
// "eb3", "f#2", "a" (octave 4); a number is returned as it is
func pattern.note_name(s){
  if(type(s) != "string"){
    return s
  }
  local n = letters[str.lower(str.substring(s, 0, 1))]
  if(n == null){
    raise(error.new(error.kinds.argument, concat("not a note name: ", s)))
  }
  local i = 1
  local c = str.substring(s, i, math.min(i + 1, len(s)))
  if(c == "#"){
    n = n + 1
    i = i + 1
  } else if(c == "b"){
    n = n - 1
    i = i + 1
  }
  local octave = 4
  if(i < len(s)){
    octave = str.to_number(str.substring(s, i, len(s)))
  }
  return 12 * (octave + 1) + n
}

// note_of(degree: number, acc: int, scale: {int}, root: number) -> number:
// the MIDI note of a scale degree (any integer, octaves wrap) sharpened
// or flattened by acc, over a root note
func pattern.note_of(degree, acc, scale, root){
  local n = len(scale)
  local d = to_int(math.floor(degree))
  local octave = to_int(math.floor(d / n))
  local index = d - octave * n
  return root + 12 * octave + scale[index] + (acc or 0) + (degree - d)
}

// --------------------------------------------------------------- patterns

local pattern_methods = {}
local pattern_meta = {__index: pattern_methods, __type: "Pattern"}

local func new_pattern(items){
  return {
    items: items,
    loops: null,
    anchor_now: false,
    transforms: {},
    cache: {},
    @meta: pattern_meta,
  }
}

// is(x: any) -> bool: whether x is a pattern
func pattern.is(x){
  return type(x) == "Pattern"
}

// from_tree(items: {step}) -> Pattern: a pattern over the steps mini.parse
// gives (what a backtick literal compiles to)
func pattern.from_tree(items){
  return new_pattern(items)
}

// parse(text: string) -> Pattern: the pattern written in text
func pattern.parse(text){
  return new_pattern(mini.parse(text))
}

// the events of items, which start at `at` and take `unit` per step,
// in repetition rep, appended to out
local func flatten(items, rep, at, unit, out){
  for(local i = 0; i < len(items); i = i + 1){
    local item = items[i]
    local pos = at + i * unit
    local t = item.t
    if(t == "note" or t == "hit"){
      append(out, {
        at: pos,
        len: unit * (item.dur or 1.0),
        value: item.v,
        vel: item.vel or 1.0,
        acc: item.acc or 0,
        flags: item.flags or "",
      })
    } else if(t == "hold"){
      if(len(out) > 0){
        local last = out[len(out) - 1]
        last.len = last.len + unit
      }
    } else if(t == "sub"){
      if(len(item.items) > 0){
        flatten(item.items, rep, pos, unit / len(item.items), out)
      }
    } else if(t == "chord"){
      for(let local sub in values(item.items)){
        flatten({sub}, rep, pos, unit, out)
      }
    } else if(t == "super"){
      local n = len(item.items)
      if(n > 0){
        local k = rep - to_int(math.floor(rep / n)) * n
        flatten({item.items[k]}, to_int(math.floor(rep / n)), pos, unit, out)
      }
    } else if(t == "splice"){
      local v = item.v
      if(type(v) == "int" or type(v) == "double"){
        flatten({
          {
            t: "note", v: v, dur: item.dur, vel: item.vel, acc: item.acc,
            flags: item.flags
          },
        }, rep, pos, unit, out)
      } else if(type(v) == "string"){
        if(len(v) == 1){
          flatten({{t: "hit", v: v}}, rep, pos, unit, out)
        } else {
          flatten({{t: "sub", items: mini.parse(v)}}, rep, pos, unit, out)
        }
      } else if(pattern.is(v)){
        flatten({{t: "sub", items: v.items}}, rep, pos, unit, out)
      } else if(type(v) == "table"){
        append(out, {
          at: pos,
          len: unit,
          value: v,
          vel: 1.0,
          acc: 0,
          flags: "",
        })
      }
    }
  }
}

// steps() -> int: how many steps one repetition has
func pattern_methods.steps(self){
  return len(self.items)
}

// events(rep: int) -> {Event}: the events of repetition rep (0, 1, ...),
// each {at, len} in steps from the repetition's start, with value (a
// degree, a letter or a spliced value), vel, acc and flags
func pattern_methods.events(self, rep){
  local cached = self.cache[rep]
  if(cached != null){
    return cached
  }
  local out = {}
  flatten(self.items, rep, 0.0, 1.0, out)
  for(let local f in values(self.transforms)){
    for(let local e in values(out)){
      e.value = f(e.value, e)
    }
  }
  tbl.sort(out, func(a, b){ return a.at < b.at })
  self.cache[rep] = out
  return out
}

local func derive(self, items){
  local p = new_pattern(items)
  p.loops = self.loops
  p.anchor_now = self.anchor_now
  p.transforms = tbl.slice(self.transforms)
  return p
}

// then(other: Pattern | string) -> Pattern: this pattern followed by other
func pattern_methods.then(self, other){
  if(type(other) == "string"){
    other = pattern.parse(other)
  }
  local items = tbl.slice(self.items)
  for(let local it in values(other.items)){
    append(items, it)
  }
  return derive(self, items)
}

// times(n: int) -> Pattern: the steps repeated n times
func pattern_methods.times(self, n){
  local items = {}
  for(local k = 0; k < n; k = k + 1){
    for(let local it in values(self.items)){
      append(items, it)
    }
  }
  return derive(self, items)
}

// crop(n: int) -> Pattern: the first n steps, repeating the pattern when it
// is shorter (`01`:crop(5) is 01010)
func pattern_methods.crop(self, n){
  local items = {}
  if(len(self.items) > 0){
    for(local k = 0; k < n; k = k + 1){
      append(items, self.items[k % len(self.items)])
    }
  }
  return derive(self, items)
}

// rev() -> Pattern: the steps backwards
func pattern_methods.rev(self){
  return derive(self, tbl.reverse(tbl.slice(self.items)))
}

// loop(n: int) -> Pattern: played n times from when the piece is
// evaluated, then silent
func pattern_methods.loop(self, n){
  local p = derive(self, self.items)
  p.loops = n
  p.anchor_now = true
  return p
}

// now() -> Pattern: starts at its first step on the next beat after the
// piece is evaluated, instead of as if it had played since beat 0
func pattern_methods.now(self){
  local p = derive(self, self.items)
  p.anchor_now = true
  return p
}

// map(f: func(value, event): any) -> Pattern: every event's value through f
func pattern_methods.map(self, f){
  local p = derive(self, self.items)
  append(p.transforms, f)
  return p
}

// add(n: number) / mul(n: number) -> Pattern: numeric values shifted or scaled
func pattern_methods.add(self, n){
  return self:map(func(v){
    if(type(v) == "int" or type(v) == "double"){
      return v + n
    }
    return v
  })
}
func pattern_methods.mul(self, n){
  return self:map(func(v){
    if(type(v) == "int" or type(v) == "double"){
      return v * n
    }
    return v
  })
}

// at(beat: number, dur?: number) -> any: the value of the event sounding at
// beat, with dur beats per step (1 by default); null in a rest
func pattern_methods.at(self, beat, dur){
  dur = dur or 1.0
  local n = len(self.items)
  if(n == 0){
    return null
  }
  local length = n * dur
  local rep = to_int(math.floor(beat / length))
  local off = (beat - rep * length) / dur
  local found = null
  for(let local e in values(self:events(rep))){
    if(e.at <= off and off < e.at + e.len){
      found = e.value
    }
  }
  return found
}

// events_between(p: Pattern, dur: number, b0: number, b1: number,
//   anchor?: number) -> {Event}: the events starting in [b0, b1) in beats,
// with dur beats per step and the pattern's beat 0 at anchor (0 by
// default): {start, len (beats), value, vel, acc, flags, rep}
func pattern.events_between(p, dur, b0, b1, anchor){
  anchor = anchor or 0.0
  local out = {}
  local n = len(p.items)
  if(n == 0 or dur <= 0){
    return out
  }
  local length = n * dur
  local r0 = to_int(math.floor((b0 - anchor) / length))
  local r1 = to_int(math.floor((b1 - anchor) / length))
  for(local rep = r0; rep <= r1; rep = rep + 1){
    if(rep < 0 or (p.loops != null and rep >= p.loops)){
      continue
    }
    for(let local e in values(p:events(rep))){
      local start = anchor + rep * length + e.at * dur
      if(start >= b0 and start < b1){
        append(out, {
          start: start,
          len: e.len * dur,
          value: e.value,
          vel: e.vel,
          acc: e.acc,
          flags: e.flags,
          rep: rep,
        })
      }
    }
  }
  return out
}

// ---------------------------------------------------------------- signals

local signal_methods = {}
local signal_meta = {__index: signal_methods, __type: "Signal"}

// signal(f: func(beat: number): number) -> Signal: a value that changes
// with the beat; a signal is a parameter like a number is
func pattern.signal(f){
  return {f: f, @meta: signal_meta}
}

func pattern.is_signal(x){
  return type(x) == "Signal"
}

// ---- arithmetic: a signal, a slider and a number add up to a signal

// lift(a, b, op) -> Signal: op of the two values at each beat
local func lift(a, b, op){
  return pattern.signal(func(beat){
    return op(pattern.value_at(a, beat), pattern.value_at(b, beat))
  })
}

// arithmetic(meta): + - * / ^ % and negation on the values of a
// metatable, each giving a signal of the result (so `cut + sine(4, -0.2,
// 0.2)` is a slider moved by a sine, `2 * s` a signal doubled); the other
// operand may be a number, a signal or a slider
func pattern.arithmetic(meta){
  meta.__add = func(a, b){ return lift(a, b, func(x, y){ return x + y }) }
  meta.__sub = func(a, b){ return lift(a, b, func(x, y){ return x - y }) }
  meta.__mul = func(a, b){ return lift(a, b, func(x, y){ return x * y }) }
  meta.__div = func(a, b){ return lift(a, b, func(x, y){ return x / y }) }
  meta.__pow = func(a, b){ return lift(a, b, func(x, y){ return x ^ y }) }
  meta.__mod = func(a, b){ return lift(a, b, func(x, y){ return x % y }) }
  meta.__unm = func(a){ return lift(a, 0, func(x, y){ return -x }) }
}
pattern.arithmetic(signal_meta)

// at(beat: number) -> number: the signal's value at beat
func signal_methods.at(self, beat){
  return self.f(beat)
}

// map(f: func(v: number): number) -> Signal
func signal_methods.map(self, f){
  local g = self.f
  return pattern.signal(func(beat){ return f(g(beat)) })
}

// range(lo: number, hi: number) -> Signal: a 0..1 signal stretched to lo..hi
func signal_methods.range(self, lo, hi){
  return self:map(func(v){ return lo + v * (hi - lo) })
}

func signal_methods.add(self, n){
  return self:map(func(v){ return v + n })
}

func signal_methods.mul(self, n){
  return self:map(func(v){ return v * n })
}

// slow(k: number) -> Signal: the signal over k times the beats
func signal_methods.slow(self, k){
  local g = self.f
  return pattern.signal(func(beat){ return g(beat / k) })
}

local func unit(period, lo, hi, phase, shape){
  period = period or 4.0
  lo = lo or 0.0
  hi = hi or 1.0
  phase = phase or 0.0
  return pattern.signal(func(beat){
    local x = beat / period + phase
    x = x - math.floor(x)
    return lo + shape(x) * (hi - lo)
  })
}

// sine(period?: beats, lo?, hi?, phase?) -> Signal: from the middle up, 4
// beats by default, 0..1; saw rises, tri goes up and down, square is
// hi for the first half
func pattern.sine(period, lo, hi, phase){
  return unit(period, lo, hi, phase, func(x){
    return 0.5 + 0.5 * math.sin(x * 2 * math.pi)
  })
}
func pattern.saw(period, lo, hi, phase){
  return unit(period, lo, hi, phase, func(x){ return x })
}
func pattern.tri(period, lo, hi, phase){
  return unit(period, lo, hi, phase, func(x){
    if(x < 0.5){
      return x * 2
    }
    return 2 - x * 2
  })
}
func pattern.square(period, lo, hi, phase){
  return unit(period, lo, hi, phase, func(x){
    if(x < 0.5){
      return 1.0
    }
    return 0.0
  })
}

// a stable pseudo-random number in 0..1 for an integer
local func hash01(k){
  local x = (k * 2654435761 + 1013904223) % 4294967296
  x = (x ~ (x >> 13)) * 1274126177 % 4294967296
  x = x ~ (x >> 16)
  return (x % 1000003) / 1000003.0
}

// rand(period?: beats, lo?, hi?) -> Signal: a new random value in lo..hi
// every period beats (1 by default)
func pattern.rand(period, lo, hi){
  period = period or 1.0
  lo = lo or 0.0
  hi = hi or 1.0
  return pattern.signal(func(beat){
    return lo + hash01(to_int(math.floor(beat / period))) * (hi - lo)
  })
}

// steps(values: {number}, dur?: beats, smooth?: bool) -> Signal: the values
// one after the other, each for dur beats (1 by default), repeating;
// smooth glides from each to the next
func pattern.steps(values, dur, smooth){
  dur = dur or 1.0
  local n = len(values)
  return pattern.signal(func(beat){
    if(n == 0){
      return 0.0
    }
    local x = beat / dur
    local i = to_int(math.floor(x))
    local a = values[((i % n) + n) % n]
    if(not smooth){
      return a
    }
    local b = values[(((i + 1) % n) + n) % n]
    return a + (b - a) * (x - i)
  })
}

// value_at(x: any, beat: number, dur?: number) -> any: what a parameter
// is at a beat: a number or string as it is, a signal's or control's
// value, a pattern's step value (null in a rest)
func pattern.value_at(x, beat, dur){
  local t = type(x)
  if(t == "int" or t == "double" or t == "string" or t == "null" or t == "bool"){
    return x
  }
  if(t == "Pattern"){
    return x:at(beat, dur)
  }
  // a signal, a control, or anything with an at (type says the
  // metatable's __type for them, not "table")
  if(t != "function" and x.at != null){
    return x:at(beat, dur)
  }
  return x
}

return pattern
