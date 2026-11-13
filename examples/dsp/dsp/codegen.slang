// dsp/codegen: a program's signals as kernel source (packages/kernel).
//
// The kernel computes a block of n samples:
//
//   struct State { sr: double = 48000, iota: int64, ui_freq: double = 440, m0: double }
//   func compute(d: State, ring: float[], n: int, in0: float[], out0: float[]){
//     local sr = d.sr                       // controls, once a block,
//     local ui_freq = clamp(d.ui_freq, 20.0, 2000.0)
//     local c0 = ui_freq / sr               // with what is computed from them
//     local m0 = d.m0                       // state into registers
//     for(local i = 0; i < n; i += 1){
//       local s0 = fract(m0 + c0)           // what the samples need
//       out0[i] = sin(s0 * 6.283185307179586)
//       m0 = s0                             // state one sample on
//     }
//     d.m0 = m0                             // and back into the instance
//   }
//
// - Rates: constants are folded (dsp/signal); what depends only on
//   controls is computed before the loop, once a block; only what
//   depends on inputs or state is computed per sample.
// - A value used more than once is a local; one used once is written
//   where it is used, so the kernel compiler gets whole expressions (and
//   fuses a + b * c).
// - `mem` (and `x'`, and every feedback ~) is a state variable: a field
//   of State, kept in a register through the block. All state is updated
//   at the end of the sample, from values computed before any changes.
// - `x @ d` is a ring buffer per delayed signal in the instance's `ring`
//   (32-bit floats), as long as the largest delay of that signal rounded
//   up to a power of two; the interval of d (sliders have their range)
//   gives the largest delay, so a delay must be bounded. Every delay of x
//   reads the same line, written once a sample.
local str = require("slang/string")
local math = require("slang/math")
local signal = require("dsp/signal")

local codegen = {}

// the longest delay line, in samples
codegen.MAX_DELAY = 1 << 22

local ADD = 5
local MUL = 6
local UNARY = 7
local ATOM = 10

local func fail(line, ...parts){
  raise(error.new(error.kinds.compile, concat("", ...parts), {line: line}))
}

// a float literal of the kernel language
local func literal(v){
  if(math.is_nan(v) or math.is_inf(v)){
    fail(null, "a constant is not a finite number")
  }
  local s = string(v * 1.0)
  if(not str.contains(s, ".") and not str.contains(s, "e") and
    not str.contains(s, "E")){
    s = concat(s, ".0")
  }
  if(v < 0){
    return {text: s, prec: UNARY}
  }
  return {text: s, prec: ATOM}
}

local func wrap(e, prec, right){
  if(e.prec < prec or (right and e.prec == prec)){
    return concat("(", e.text, ")")
  }
  return e.text
}

// the state variables two expressions read
local func union(a, b){
  if(a == null){
    return b
  }
  if(b == null){
    return a
  }
  return {...a, ...b}
}

local func infix(a, op, b, prec){
  return {
    text: concat(wrap(a, prec, false), " ", op, " ", wrap(b, prec, true)),
    prec: prec,
    reads: union(a.reads, b.reads),
  }
}

local func call(name, ...args){
  local parts = {}
  local reads = null
  for(let local a in values(args)){
    append(parts, a.text)
    reads = union(reads, a.reads)
  }
  return {
    text: concat(name, "(", str.join(parts, ", "), ")"), prec: ATOM,
    reads: reads
  }
}

local func atom(text){
  return {text: text, prec: ATOM}
}

local CALLS = {
  sin: "sin",
  cos: "cos",
  tan: "tan",
  asin: "asin",
  acos: "acos",
  atan: "atan",
  exp: "exp",
  log: "log",
  sqrt: "sqrt",
  abs: "abs",
  floor: "floor",
  ceil: "ceil",
  rint: "round",
  tanh: "tanh",
  int: "trunc",
  min: "min",
  max: "max",
  pow: "pow",
  atan2: "atan2",
}
local COMPARE = {lt: "<", le: "<=", gt: ">", ge: ">=", eq: "==", ne: "!="}
local BITS = {band: "&", bor: "|", bxor: "~", shl: "<<", shr: ">>"}

// an identifier for a control's label: ui_ and the label's letters
local func field_name(label, taken){
  local out = {}
  for(local i = 0; i < len(label); i = i + 1){
    local b = str.byte_at(label, i)
    local ok = (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
      (b >= '0' and b <= '9') or b == '_'
    if(ok){
      append(out, str.from_bytes({b}))
    } else {
      append(out, "_")
    }
  }
  local base = concat("ui_", str.join(out, ""))
  local name = base
  local k = 2
  for(taken[name]){
    name = concat(base, "_", string(k))
    k = k + 1
  }
  taken[name] = true
  return name
}

// The names of the loop's temporaries and of the state
local regex = require("slang/regex")
local temp_name = regex.compile("\\b[su][0-9]+\\b")
local state_name = regex.compile("\\bm[0-9]+\\b")
local local_def = regex.compile("^local ([su][0-9]+) = ")
local control_name = regex.compile("\\bc[0-9]+\\b")
local control_def = regex.compile("^local (c[0-9]+) = ")
local float_literal = regex.compile("\\b[0-9]+\\.[0-9]+(e[-+]?[0-9]+)?")

// a slot of the pool: a register t0.. below the budget, else an element
// of the scratch array tmp
local func slot_text(slot, registers){
  if(registers != null and slot >= registers){
    return concat("tmp[", string(slot - registers), "]")
  }
  return concat("t", string(slot))
}

// The loop's statements with their temporaries (local s4 = ..., local
// u9 = ...) in a pool of locals t0, t1, ... declared before the loop, each
// reused once the value it held is read for the last time: as many
// registers as values live at once, not one per value.
local func pooled(body, registers){
  local last = {}
  for(local b = 0; b < len(body); b = b + 1){
    for(let local m in values(temp_name:find_all(body[b]))){
      last[m.text] = b
    }
  }
  local slot_of = {}
  local free = {}
  local size = 0
  local out = {}
  for(local b = 0; b < len(body); b = b + 1){
    local line = body[b]
    local def = local_def:find(line)
    local target = null
    if(def != null){
      target = def.groups[1]
      line = str.substring(line, len(def.text))
    }
    // the right side reads the pool as it is
    line = temp_name:replace(line, func(m){
      return slot_text(slot_of[m.text], registers)
    })
    // values read here for the last time give their slots back
    for(let local m in values(temp_name:find_all(body[b]))){
      if(last[m.text] == b and m.text != target and slot_of[m.text] != null){
        append(free, slot_of[m.text])
        delete(slot_of, m.text)
      }
    }
    if(target != null){
      local slot = null
      if(len(free) > 0){
        slot = remove(free, len(free) - 1)
      } else {
        slot = size
        size = size + 1
      }
      slot_of[target] = slot
      line = concat(slot_text(slot, registers), " = ", line)
    }
    append(out, line)
  }
  return {body: out, size: size}
}

// generate(r: {graph, outputs, inputs}, name?: string, options?) -> {source, info}
// options {pool?: bool, registers?: int, spill_controls?: bool,
// spill_state?: bool, spill_constants?: bool, constants?: int}: for
// programs too big for the kernel's registers, temporaries in a reused
// pool (at most registers of them in registers, the rest in the scratch
// array tmp), the values computed once a block, the state and the
// constants (the constants least used, or all) left in the instance.
// The kernel source of a program's signals (as dsp/eval gives them) and
// what slang needs to run it: info {inputs, outputs, ring, controls:
// {{label, field, kind, init, min, max, step}}, state}.
func codegen.generate(r, name, options){
  local g = r.graph
  local resolve = signal.resolve

  // ---- uses, and the delay lines
  local uses = {}
  local lines = {}
  local line_list = {}
  local stack = {}
  for(let local o in values(r.outputs)){
    append(stack, o)
  }
  // (a stack, not recursion: a long chain of diagrams is a deep graph)
  for(len(stack) > 0){
    local n = resolve(remove(stack, len(stack) - 1))
    local c = (uses[n.id] or 0) + 1
    uses[n.id] = c
    if(c > 1){
      continue
    }
    if(n.op == "delay"){
      local x = resolve(n.args[0])
      local d = n.args[1]
      if(d.hi == math.inf){
        fail(
          n.line,
          "a delay must be bounded: the delay of @ can be any number (give it a range, e.g. min(d, 48000) or a slider)",
        )
      }
      if(d.hi >= codegen.MAX_DELAY){
        fail(
          n.line, "a delay of ", string(d.hi), " samples is too long (",
          string(codegen.MAX_DELAY), " at most)"
        )
      }
      local l = lines[x.id]
      if(l == null){
        l = {max: 0, x: x}
        lines[x.id] = l
        append(line_list, l)
      }
      l.max = math.max(l.max, to_int(math.max(d.hi, 0.0)))
    }
    for(let local a in values(n.args)){
      append(stack, a)
    }
  }
  local ring = 0
  for(let local l in values(line_list)){
    local size = 1
    for(size < l.max + 1){
      size = size * 2
    }
    l.size = size
    l.offset = ring
    ring = ring + size
  }

  // ---- the code
  local pro = {}
  local body = {}
  local states = {}
  local updates = {}
  local names = {}
  local counter = 0
  local taken = {}
  local controls = {}
  local control_field = {}
  // the controls as the program writes them (by line, stable)
  local specs = {...g.controls}
  for(local a = 1; a < len(specs); a = a + 1){
    local b = a
    for(b > 0 and specs[b - 1].line > specs[b].line){
      local t = specs[b - 1]
      specs[b - 1] = specs[b]
      specs[b] = t
      b = b - 1
    }
  }
  for(let local spec in values(specs)){
    local field = field_name(spec.label, taken)
    control_field[spec.label] = field
    append(controls, {
      label: spec.label,
      field: field,
      kind: spec.kind,
      init: spec.init,
      min: spec.min,
      max: spec.max,
      step: spec.step,
    })
  }

  local func fresh(prefix){
    local s = concat(prefix, string(counter))
    counter = counter + 1
    return s
  }

  local emit = null

  // an element of a delay line: index is a slot of the line
  local func slot(l, index){
    if(l.offset == 0){
      return concat("ring[", index, "]")
    }
    return concat("ring[", string(l.offset), " + (", index, ")]")
  }

  // a local for an expression: in the prologue (control rate) or the loop
  local func bind(n, e, rate){
    local v = fresh(if(rate < 2){ "c" } else { "s" })
    if(rate < 2){
      append(pro, concat("local ", v, " = ", e.text))
    } else {
      append(body, concat("local ", v, " = ", e.text))
    }
    local named = {text: v, prec: ATOM, local: true}
    names[n.id] = named
    return named
  }

  local func arith(n, ctx){
    local op = n.op
    local a = n.args[0]
    local b = n.args[1]
    local sub = ctx
    if(op == "add"){
      local x = emit(a, sub)
      if(b.op == "const" and b.value < 0){
        return infix(x, "-", literal(-b.value), ADD)
      }
      return infix(x, "+", emit(b, sub), ADD)
    } else if(op == "sub"){
      // x - floor(x)
      if(b.op == "floor" and same(resolve(b.args[0]), resolve(a))){
        return call("fract", emit(a, sub))
      }
      if(a.op == "const" and a.value == 0.0){
        local x = emit(b, sub)
        return {
          text: concat("-", wrap(x, UNARY, true)), prec: UNARY, reads: x.reads
        }
      }
      return infix(emit(a, sub), "-", emit(b, sub), ADD)
    } else if(op == "mul"){
      return infix(emit(a, sub), "*", emit(b, sub), MUL)
    } else if(op == "div"){
      return infix(emit(a, sub), "/", emit(b, sub), MUL)
    } else if(op == "mod"){
      return infix(emit(a, sub), "%", emit(b, sub), MUL)
    } else if(op == "fmod"){
      // C's fmod: the remainder of a truncated division
      local x = emit(a, sub)
      local y = emit(b, sub)
      return infix(
        x, "-", infix(y, "*", call("trunc", infix(x, "/", y, MUL)), MUL), ADD
      )
    } else if(op == "log10"){
      return infix(
        call("log", emit(a, sub)),
        "*",
        literal(1 / math.log(10.0)),
        MUL,
      )
    } else if(op == "select2"){
      // select2(s, a, b): a when s is 0, else b
      local cmp = COMPARE[resolve(a).op]
      if(cmp != null and uses[resolve(a).id] == 1){
        local c = resolve(a)
        return call(
          "select", infix(emit(c.args[0], sub), cmp, emit(c.args[1], sub), 1),
          emit(n.args[2], sub), emit(b, sub)
        )
      }
      local s = emit(a, sub)
      return call(
        "select", infix(s, "==", atom("0.0"), 1), emit(b, sub),
        emit(n.args[2], sub)
      )
    } else if(COMPARE[op] != null){
      return call(
        "select", infix(emit(a, sub), COMPARE[op], emit(b, sub), 1),
        atom("1.0"), atom("0.0")
      )
    } else if(BITS[op] != null){
      return call("float", infix(
        call("int", emit(a, sub)),
        BITS[op],
        call("int", emit(b, sub)),
        1,
      ))
    } else if(CALLS[op] != null){
      if(b == null){
        return call(CALLS[op], emit(a, sub))
      }
      return call(CALLS[op], emit(a, sub), emit(b, sub))
    }
    fail(n.line, "cannot generate ", op)
  }

  // the expression of node n in a context ("c": the prologue, "s": the
  // loop)
  emit = func(n, ctx){
    n = resolve(n)
    local named = names[n.id]
    if(named != null){
      return named
    }
    local op = n.op
    if(op == "const"){
      return literal(n.value)
    } else if(op == "input"){
      local e = atom(concat("in", string(n.index), "[i]"))
      if(uses[n.id] > 1){
        return bind(n, e, 2)
      }
      return e
    } else if(op == "sr"){
      append(pro, "local sr = d.sr")
      names[n.id] = {text: "sr", prec: ATOM, local: true}
      return names[n.id]
    } else if(op == "control"){
      local spec = n.control
      local field = control_field[spec.label]
      local read = concat("d.", field)
      if(spec.kind != "button" and spec.kind != "checkbox"){
        read = concat(
          "clamp(", read, ", ", literal(spec.min).text, ", ",
          literal(spec.max).text, ")"
        )
      }
      append(pro, concat("local ", field, " = ", read))
      names[n.id] = {text: field, prec: ATOM, local: true}
      return names[n.id]
    } else if(op == "mem"){
      local v = fresh("m")
      append(states, v)
      names[n.id] = {text: v, prec: ATOM, reads: {[v]: true}}
      append(updates, {state: v, node: n.args[0]})
      return names[n.id]
    } else if(op == "delay"){
      local x = resolve(n.args[0])
      local l = lines[x.id]
      if(not l.written){
        l.written = true
        local v = emit(x, "s")
        append(body, concat(
          slot(l, concat("iota & ", string(l.size - 1))), " = ", v.text
        ))
      }
      local d = n.args[1]
      local back = null
      if(d.op == "const"){
        back = concat("iota - ", string(to_int(d.value)))
      } else {
        local de = call("int", emit(d, "s"))
        if(d.lo < 0){
          de = call("max", de, atom("0"))
        }
        back = concat("iota - ", de.text)
      }
      local e = atom(slot(l, concat("(", back, ") & ", string(l.size - 1))))
      if(uses[n.id] > 1){
        return bind(n, e, 2)
      }
      return e
    }
    // arithmetic
    if(n.rate < 2){
      local e = arith(n, "c")
      if(ctx == "s" or uses[n.id] > 1){
        return bind(n, e, 1)
      }
      return e
    }
    local e = arith(n, "s")
    if(uses[n.id] > 1){
      return bind(n, e, 2)
    }
    return e
  }

  // ---- the outputs, then the state for the next sample
  local outs = {}
  for(local j = 0; j < len(r.outputs); j = j + 1){
    local e = emit(r.outputs[j], "s")
    append(outs, concat("out", string(j), "[i] = ", e.text))
  }
  // (computing an update may add state, and with it more updates)
  local k = 0
  for(k < len(updates)){
    local u = updates[k]
    u.e = emit(u.node, "s")
    k = k + 1
  }
  // an update that reads state written before it goes through a
  // temporary, so that every update sees the state as the sample found it
  local writes = {}
  local written = {}
  for(let local u in values(updates)){
    local e = u.e
    local clash = false
    for(let local s in keys(e.reads or {})){
      clash = clash or written[s] == true
    }
    written[u.state] = true
    if(clash){
      local t = fresh("u")
      append(body, concat("local ", t, " = ", e.text))
      e = atom(t)
    }
    append(writes, concat(u.state, " = ", e.text))
  }
  for(let local o in values(outs)){
    append(body, o)
  }
  for(let local w in values(writes)){
    append(body, w)
  }
  if(ring > 0){
    append(body, "iota += 1")
  }

  // ---- big programs: fewer registers
  options = options or {}
  local pool = 0
  local scratch = 0
  if(options.pool){
    local r2 = pooled(body, options.registers)
    body = r2.body
    pool = r2.size
    if(options.registers != null and pool > options.registers){
      scratch = pool - options.registers
      pool = options.registers
    }
  }
  if(options.spill_state){
    // the state stays in the instance: d.m3 instead of a register
    for(local b = 0; b < len(body); b = b + 1){
      body[b] = state_name:replace(body[b], func(m){
        return concat("d.", m.text)
      })
    }
  }
  local in_registers = if(options.spill_state){ {} } else { states }
  // the constants in the instance too: fields with them as defaults
  local constant_fields = {}
  if(options.spill_constants){
    // the least used first: options.constants of them (all without)
    local uses_of = {}
    local texts = {}
    for(let local list in values({pro, body})){
      for(let local line in values(list)){
        for(let local m in values(float_literal:find_all(line))){
          if(uses_of[m.text] == null){
            uses_of[m.text] = 0
            append(texts, m.text)
          }
          uses_of[m.text] = uses_of[m.text] + 1
        }
      }
    }
    for(local a = 1; a < len(texts); a = a + 1){
      local b = a
      for(b > 0 and uses_of[texts[b - 1]] > uses_of[texts[b]]){
        local t = texts[b - 1]
        texts[b - 1] = texts[b]
        texts[b] = t
        b = b - 1
      }
    }
    local spilled = {}
    local how_many = options.constants or len(texts)
    for(local i = 0; i < how_many and i < len(texts); i = i + 1){
      spilled[texts[i]] = true
    }
    local by_text = {}
    local func spill(list){
      for(local b = 0; b < len(list); b = b + 1){
        list[b] = float_literal:replace(list[b], func(m){
          if(spilled[m.text] == null){
            return m.text
          }
          local f = by_text[m.text]
          if(f == null){
            f = concat("k", string(len(constant_fields)))
            by_text[m.text] = f
            append(constant_fields, {name: f, value: m.text})
          }
          return concat("d.", f)
        })
      }
    }
    spill(pro)
    spill(body)
  }
  // the values computed once a block in the instance too: d.c3
  local spilled_controls = {}
  if(options.spill_controls){
    local func spill(list){
      for(local b = 0; b < len(list); b = b + 1){
        local line = list[b]
        local def = control_def:find(line)
        local target = ""
        if(def != null){
          append(spilled_controls, def.groups[1])
          target = concat("d.", def.groups[1], " = ")
          line = str.substring(line, len(def.text))
        }
        list[b] = concat(target, control_name:replace(line, func(m){
          return concat("d.", m.text)
        }))
      }
    }
    spill(pro)
    spill(body)
  }

  // ---- the source
  local src = {concat("// generated by dsp from ", name or "a program")}
  local fields = {"  sr: double = 48000,"}
  if(ring > 0){
    append(fields, "  iota: int64,")
  }
  for(let local c in values(controls)){
    append(fields, concat(
      "  ", c.field, ": double = ", literal(c.init).text, ","
    ))
  }
  for(let local s in values(states)){
    append(fields, concat("  ", s, ": double,"))
  }
  for(let local c in values(spilled_controls)){
    append(fields, concat("  ", c, ": double,"))
  }
  for(let local k in values(constant_fields)){
    append(fields, concat("  ", k.name, ": double = ", k.value, ","))
  }
  append(src, "struct State {")
  for(let local f in values(fields)){
    append(src, f)
  }
  append(src, "}")
  append(src, "")
  local params = {"d: State", "ring: float[]", "tmp: double[]", "n: int"}
  for(local i = 0; i < r.inputs; i = i + 1){
    append(params, concat("in", string(i), ": float[]"))
  }
  for(local j = 0; j < len(r.outputs); j = j + 1){
    append(params, concat("out", string(j), ": float[]"))
  }
  append(src, concat("func compute(", str.join(params, ", "), "){"))
  for(let local p in values(pro)){
    append(src, concat("  ", p))
  }
  for(let local s in values(in_registers)){
    append(src, concat("  local ", s, " = d.", s))
  }
  for(local t = 0; t < pool; t = t + 1){
    append(src, concat("  local t", string(t), " = 0.0"))
  }
  if(ring > 0){
    append(src, "  local iota = d.iota")
  }
  append(src, "  for(local i = 0; i < n; i += 1){")
  for(let local b in values(body)){
    append(src, concat("    ", b))
  }
  append(src, "  }")
  for(let local s in values(in_registers)){
    append(src, concat("  d.", s, " = ", s))
  }
  if(ring > 0){
    append(src, "  d.iota = iota")
  }
  append(src, "}")
  append(src, "")

  return {
    source: str.join(src, "\n"),
    info: {
      inputs: r.inputs,
      outputs: len(r.outputs),
      ring: ring,
      scratch: scratch,
      controls: controls,
      state: len(states),
    },
  }
}

return codegen
