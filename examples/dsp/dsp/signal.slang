// dsp/signal: the signals a block diagram computes, as a graph of nodes.
//
// A diagram applied to its input signals gives its output signals
// (dsp/eval); dsp/codegen turns them into a kernel. Nodes are hash-consed:
// building the same operation on the same operands twice gives the same
// node, so a value the diagram computes in two places is computed once.
// Building a node also simplifies it:
//
// - constants fold (`2 * 3` is 6, `x * 1` is x, `x * 0` is 0, `x - 2` is
//   `x + -2`, and constants gather: `(x * 2) * 3` is `x * 6`)
// - every node knows its rate: 0 constant, 1 control (changes only
//   between blocks: sliders and what is computed from them), 2 sample
// - every node knows an interval its values lie in (sliders have their
//   range): a delay `x @ d` needs one for d, to size its line
//
// Node: {id, op, args: {Node}, value?, control?, index?, group?, j?,
//   rate, lo, hi, line?}. Ops: "const", "input", "control", "sr", the
// arithmetic of OPS, "mem" (one sample late), "delay" (x, d) and "proj"
// (the j-th output of a feedback group, see group()).
local math = require("slang/math")
local str = require("slang/string")

local signal = {}

local inf = math.inf

// operator -> {n: operands, fold?: func, commutative?: bool}
local func floor_mod(a, b){
  return a - b * math.floor(a / b)
}

local func bool(x){
  if(x){
    return 1.0
  }
  return 0.0
}

local OPS = {
  add: {n: 2, commutative: true, fold: func(a, b){ return a + b }},
  sub: {n: 2, fold: func(a, b){ return a - b }},
  mul: {n: 2, commutative: true, fold: func(a, b){ return a * b }},
  div: {n: 2, fold: func(a, b){ return a / b }},
  mod: {n: 2, fold: floor_mod},
  fmod: {n: 2, fold: func(a, b){ return a - b * math.trunc(a / b) }},
  pow: {n: 2, fold: func(a, b){ return a ^ b }},
  min: {n: 2, commutative: true, fold: func(a, b){ return math.min(a, b) }},
  max: {n: 2, commutative: true, fold: func(a, b){ return math.max(a, b) }},
  atan2: {n: 2, fold: func(a, b){ return math.atan2(a, b) }},
  lt: {n: 2, fold: func(a, b){ return bool(a < b) }},
  le: {n: 2, fold: func(a, b){ return bool(a <= b) }},
  gt: {n: 2, fold: func(a, b){ return bool(a > b) }},
  ge: {n: 2, fold: func(a, b){ return bool(a >= b) }},
  eq: {n: 2, commutative: true, fold: func(a, b){ return bool(a == b) }},
  ne: {n: 2, commutative: true, fold: func(a, b){ return bool(a != b) }},
  band: {
    n: 2, commutative: true, fold: func(a, b){
      return (to_int(a) & to_int(b)) * 1.0
    }
  },
  bor: {
    n: 2, commutative: true, fold: func(a, b){
      return (to_int(a) | to_int(b)) * 1.0
    }
  },
  bxor: {
    n: 2, commutative: true, fold: func(a, b){
      return (to_int(a) ~ to_int(b)) * 1.0
    }
  },
  shl: {n: 2, fold: func(a, b){ return (to_int(a) << to_int(b)) * 1.0 }},
  shr: {n: 2, fold: func(a, b){ return (to_int(a) >> to_int(b)) * 1.0 }},
  sin: {n: 1, fold: math.sin},
  cos: {n: 1, fold: math.cos},
  tan: {n: 1, fold: math.tan},
  asin: {n: 1, fold: math.asin},
  acos: {n: 1, fold: math.acos},
  atan: {n: 1, fold: math.atan},
  exp: {n: 1, fold: math.exp},
  log: {n: 1, fold: func(x){ return math.log(x) }},
  log10: {n: 1, fold: math.log10},
  sqrt: {n: 1, fold: math.sqrt},
  abs: {n: 1, fold: func(x){ return math.abs(x) * 1.0 }},
  floor: {n: 1, fold: math.floor},
  ceil: {n: 1, fold: math.ceil},
  rint: {n: 1, fold: math.round},
  tanh: {n: 1, fold: math.tanh},
  int: {n: 1, fold: math.trunc},
  select2: {n: 3},
}
signal.OPS = OPS

// ------------------------------------------------------------ intervals

local func lo_of(...xs){
  local r = inf
  for(let local x in values(xs)){
    if(math.is_nan(x)){
      return -inf
    }
    r = math.min(r, x)
  }
  return r
}

local func hi_of(...xs){
  local r = -inf
  for(let local x in values(xs)){
    if(math.is_nan(x)){
      return inf
    }
    r = math.max(r, x)
  }
  return r
}

// the interval of op over its operands' intervals: {lo, hi}
local func interval(op, a, b, c){
  if(op == "add"){
    return {lo_of(a.lo + b.lo), hi_of(a.hi + b.hi)}
  } else if(op == "sub"){
    return {lo_of(a.lo - b.hi), hi_of(a.hi - b.lo)}
  } else if(op == "mul"){
    local p = {a.lo * b.lo, a.lo * b.hi, a.hi * b.lo, a.hi * b.hi}
    return {lo_of(...p), hi_of(...p)}
  } else if(op == "div"){
    if(b.lo > 0 or b.hi < 0){
      local p = {a.lo / b.lo, a.lo / b.hi, a.hi / b.lo, a.hi / b.hi}
      return {lo_of(...p), hi_of(...p)}
    }
  } else if(op == "min"){
    return {math.min(a.lo, b.lo), math.min(a.hi, b.hi)}
  } else if(op == "max"){
    return {math.max(a.lo, b.lo), math.max(a.hi, b.hi)}
  } else if(op == "mod"){
    if(b.lo > 0 and b.hi < inf){
      return {0.0, b.hi}
    }
  } else if(op == "int" or op == "floor" or op == "ceil" or op == "rint"){
    local f = OPS[op].fold
    return {lo_of(f(a.lo)), hi_of(f(a.hi))}
  } else if(op == "abs"){
    if(a.lo >= 0){
      return {a.lo, a.hi}
    }
    return {0.0, hi_of(-a.lo, a.hi)}
  } else if(op == "sqrt"){
    return {math.sqrt(math.max(a.lo, 0.0)), math.sqrt(math.max(a.hi, 0.0))}
  } else if(op == "sin" or op == "cos" or op == "tanh"){
    return {-1.0, 1.0}
  } else if(op == "lt" or op == "le" or op == "gt" or op == "ge" or
    op == "eq" or op == "ne"){
    return {0.0, 1.0}
  } else if(op == "select2"){
    return {math.min(b.lo, c.lo), math.max(b.hi, c.hi)}
  } else if(op == "exp"){
    return {math.exp(a.lo), math.exp(a.hi)}
  }
  return {-inf, inf}
}

// ------------------------------------------------------------ the graph

local graph_methods = {}
local graph_meta = {__index: graph_methods}

// graph() -> Graph: an empty graph, for one program
func signal.graph(){
  return {
    nodes: {},
    count: 0,
    groups: 0,
    controls: {},
    controls_by_label: {},
    closed: {},
    @meta: graph_meta,
  }
}

func graph_methods.intern(self, key, make){
  local n = self.nodes[key]
  if(n == null){
    n = make()
    n.id = self.count
    self.count = self.count + 1
    self.nodes[key] = n
  }
  return n
}

// const(value: float) -> Node
func graph_methods.const(self, v){
  v = v * 1.0
  if(v == 0.0){
    // -0.0 and 0.0 are one constant
    v = 0.0
  }
  return self:intern(concat("k", string(v)), func(){
    return {op: "const", args: {}, value: v, rate: 0, lo: v, hi: v}
  })
}

// input(i: int) -> Node: the i-th input of the program
func graph_methods.input(self, i){
  return self:intern(concat("in", string(i)), func(){
    return {op: "input", args: {}, index: i, rate: 2, lo: -inf, hi: inf}
  })
}

// SR: the sample rate, a control the instance sets
signal.SR_MIN = 8000.0
signal.SR_MAX = 96000.0

func graph_methods.sr(self){
  return self:intern("sr", func(){
    return {op: "sr", args: {}, rate: 1, lo: signal.SR_MIN, hi: signal.SR_MAX}
  })
}

// control(spec) -> Node: a user interface element,
// spec {kind: "hslider" | "vslider" | "nentry" | "button" | "checkbox",
// label, init, min, max, step, line}. Controls of one label are one.
func graph_methods.control(self, spec){
  local known = self.controls_by_label[spec.label]
  if(known != null){
    local same = known.kind == spec.kind and known.init == spec.init and
      known.min == spec.min and known.max == spec.max
    if(not same){
      raise(
        error.new(
          error.kinds.compile,
          concat("two different controls are labelled \"", spec.label, "\""),
          {
            line: spec.line,
          },
        ),
      )
    }
    return known.node
  }
  local n = self:intern(concat("ui", spec.label), func(){
    return {
      op: "control", args: {}, control: spec, rate: 1, lo: spec.min,
      hi: spec.max
    }
  })
  spec.node = n
  self.controls_by_label[spec.label] = spec
  append(self.controls, spec)
  return n
}

local func is_const(n, v){
  return n.op == "const" and (v == null or n.value == v)
}

local func key_of(op, args){
  local k = op
  for(let local a in values(args)){
    k = concat(k, ",", string(a.id))
  }
  return k
}

// op(name: string, args: {Node}, line?: int) -> Node: an arithmetic node,
// folded and simplified
func graph_methods.op(self, op, args, line){
  local spec = OPS[op]
  local a = args[0]
  local b = args[1]
  // all constants: the value (when it is a number)
  local constant = spec.fold != null
  for(let local x in values(args)){
    constant = constant and x.op == "const"
  }
  if(constant){
    local v = 0.0
    if(spec.n == 1){
      v = spec.fold(a.value)
    } else {
      v = spec.fold(a.value, b.value)
    }
    if(not math.is_nan(v) and not math.is_inf(v)){
      return self:const(v)
    }
  }
  // the constant second, and operands in a fixed order, so that a + b and
  // b + a are one node
  if(spec.commutative and (is_const(a) or (not is_const(b) and b.id < a.id))){
    local t = a
    a = b
    b = t
  }
  if(op == "sub" and is_const(b)){
    return self:op("add", {a, (self:const(-b.value))}, line)
  }
  if(op == "add"){
    if(is_const(b, 0.0)){
      return a
    }
    // x + (0 - y) = x - y
    if(b.op == "sub" and is_const(b.args[0], 0.0)){
      return self:op("sub", {a, b.args[1]}, line)
    }
    if(a.op == "sub" and is_const(a.args[0], 0.0)){
      return self:op("sub", {b, a.args[1]}, line)
    }
    // (x + c1) + c2 = x + (c1 + c2)
    if(is_const(b) and a.op == "add" and is_const(a.args[1])){
      return self:op(
        "add", {a.args[0], (self:const(a.args[1].value + b.value))}, line
      )
    }
  } else if(op == "mul"){
    if(is_const(b, 1.0)){
      return a
    }
    if(is_const(b, -1.0)){
      return self:op("sub", {(self:const(0)), a}, line)
    }
    if(is_const(b, 0.0)){
      return b
    }
    if(is_const(b) and a.op == "mul" and is_const(a.args[1])){
      return self:op(
        "mul", {a.args[0], (self:const(a.args[1].value * b.value))}, line
      )
    }
  } else if(op == "div"){
    if(is_const(b, 1.0)){
      return a
    }
    // x / c = x * (1 / c): a multiplication is cheaper
    if(is_const(b) and b.value != 0.0){
      return self:op("mul", {a, (self:const(1.0 / b.value))}, line)
    }
  } else if(op == "select2"){
    if(is_const(a)){
      if(a.value == 0.0){
        return b
      }
      return args[2]
    }
    if(same(b, args[2])){
      return b
    }
  } else if(op == "int" and
    (a.op == "int" or a.op == "floor" or a.op == "ceil" or a.op == "rint")){
    return a
  }
  local list = {a}
  if(spec.n >= 2){
    append(list, b)
  }
  if(spec.n == 3){
    append(list, args[2])
  }
  return self:intern(key_of(op, list), func(){
    local rate = 0
    for(let local x in values(list)){
      rate = math.max(rate, x.rate)
    }
    local iv = interval(op, a, b, args[2])
    return {op: op, args: list, rate: rate, lo: iv[0], hi: iv[1], line: line}
  })
}

// mem(x: Node) -> Node: x one sample late (0 at the first sample)
func graph_methods.mem(self, x, line){
  if(is_const(x, 0.0)){
    return x
  }
  return self:intern(key_of("mem", {x}), func(){
    return {
      op: "mem",
      args: {x},
      rate: 2,
      lo: math.min(x.lo, 0.0),
      hi: math.max(x.hi, 0.0),
      line: line,
    }
  })
}

// delay(x: Node, d: Node) -> Node: x d samples late (d is truncated)
func graph_methods.delay(self, x, d, line){
  if(is_const(x, 0.0)){
    return x
  }
  if(is_const(d)){
    local k = math.trunc(d.value)
    if(k <= 0){
      return x
    }
    if(k == 1){
      return self:mem(x, line)
    }
    d = self:const(k)
  }
  return self:intern(key_of("delay", {x, d}), func(){
    return {
      op: "delay",
      args: {x, d},
      rate: 2,
      lo: math.min(x.lo, 0.0),
      hi: math.max(x.hi, 0.0),
      line: line,
    }
  })
}

// group(n: int) -> Group: a feedback loop of n signals. Its projections
// (proj) stand for the signals until they are defined (group.defs, set
// once the loop's diagram is applied).
func graph_methods.group(self, n){
  self.groups = self.groups + 1
  return {id: self.groups, n: n, defs: null}
}

func graph_methods.proj(self, group, j){
  return self:intern(concat("p", string(group.id), ",", string(j)), func(){
    return {
      op: "proj", args: {}, group: group, j: j, rate: 2, lo: -inf, hi: inf
    }
  })
}

// close(group, defs) -> {Node}: the group's signals, defined as defs.
// Two loops that compute the same from the same signals are one: the
// first one's projections are returned for the second (a smoothed slider
// used in four places is smoothed once).
func graph_methods.close(self, group, defs){
  group.defs = defs
  // the structure of the defs: own projections by number, nodes that do
  // not depend on the group by id
  local memo = {}
  local func key(n){
    local k = memo[n.id]
    if(k != null){
      return k
    }
    if(n.op == "proj" and same(n.group, group)){
      k = concat("#", string(n.j))
    } else if(len(n.args) == 0){
      k = concat("@", string(n.id))
    } else {
      local parts = {n.op}
      local inner = false
      for(let local a in values(n.args)){
        local ak = key(a)
        append(parts, ak)
        inner = inner or str.byte_at(ak, 0) != '@'
      }
      if(inner){
        k = concat("(", str.join(parts, " "), ")")
      } else {
        k = concat("@", string(n.id))
      }
    }
    memo[n.id] = k
    return k
  }
  local parts = {}
  for(let local d in values(defs)){
    append(parts, key(d))
  }
  local whole = str.join(parts, ";")
  local same = self.closed[whole]
  if(same != null){
    return same
  }
  local out = {}
  for(local j = 0; j < group.n; j = j + 1){
    append(out, self:proj(group, j))
  }
  self.closed[whole] = out
  return out
}

// resolve(n: Node) -> Node: n, or the signal a projection stands for
func signal.resolve(n){
  for(n.op == "proj"){
    n = n.group.defs[n.j]
  }
  return n
}

return signal
