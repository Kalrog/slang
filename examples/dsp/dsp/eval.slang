// dsp/eval: block diagrams to signals.
//
// A program's definitions (dsp/grammar) are evaluated lazily, by name, to
// values:
//
// - a box: a diagram with ins inputs and outs outputs, and a function from
//   ins input signals to outs output signals (dsp/signal nodes)
// - an abstraction: a definition with parameters, or a lambda, waiting for
//   its arguments
// - a native: a builtin that takes arguments other than diagrams (sliders
//   take a label and numbers)
// - a string: a label
//
// The composition operators check the numbers of inputs and outputs as
// the language defines them, and say what does not fit:
//
//   a : b    outs(a) == ins(b)
//   a , b    any
//   a <: b   ins(b) a multiple of outs(a): a's outputs copied round
//   a :> b   outs(a) a multiple of ins(b): every ins(b)-th output summed
//   a ~ b    ins(b) <= outs(a) and outs(b) <= ins(a): b's outputs one
//            sample late into a's first inputs
//
// Errors are raised with {line}, the line in the program's text.
local signal = require("dsp/signal")

local eval = {}

local func fail(line, ...parts){
  raise(error.new(error.kinds.compile, concat("", ...parts), {line: line}))
}

local func plural(n, word){
  if(n == 1){
    return concat("1 ", word)
  }
  return concat(string(n), " ", word, "s")
}

local func box(ins, outs, f){
  return {t: "box", ins: ins, outs: outs, f: f}
}

local func describe(v){
  if(v.t == "box"){
    return concat(
      "a diagram with ",
      plural(v.ins, "input"),
      " and ",
      plural(v.outs, "output"),
    )
  } else if(v.t == "str"){
    return concat("the string \"", v.value, "\"")
  }
  return "a function (it needs arguments)"
}

local as_box = null

local func need_box(v, line, what){
  if(v.t == "abs"){
    v = as_box(v, line)
  }
  if(v.t != "box"){
    fail(line, what, " must be a diagram, not ", describe(v))
  }
  return v
}

local func slice(list, from, to){
  local out = {}
  for(local i = from; i < to; i = i + 1){
    append(out, list[i])
  }
  return out
}

// ------------------------------------------------------------ composition

local func seq(a, b, line){
  if(a.outs != b.ins){
    fail(
      line,
      "a : b needs as many outputs of a as inputs of b; a has ",
      plural(a.outs, "output"),
      ", b ",
      plural(b.ins, "input"),
    )
  }
  return box(a.ins, b.outs, func(xs){
    return b.f(a.f(xs))
  })
}

local func par(a, b){
  return box(a.ins + b.ins, a.outs + b.outs, func(xs){
    local out = {...a.f(slice(xs, 0, a.ins))}
    for(let local y in values(b.f(slice(xs, a.ins, a.ins + b.ins)))){
      append(out, y)
    }
    return out
  })
}

local func split(g, a, b, line){
  if(a.outs == 0 or b.ins % a.outs != 0){
    fail(
      line,
      "a <: b needs a multiple of a's outputs as b's inputs; a has ",
      plural(a.outs, "output"),
      ", b ",
      plural(b.ins, "input"),
    )
  }
  return box(a.ins, b.outs, func(xs){
    local ys = a.f(xs)
    local spread = {}
    for(local i = 0; i < b.ins; i = i + 1){
      append(spread, ys[i % a.outs])
    }
    return b.f(spread)
  })
}

local func merge(g, a, b, line){
  if(b.ins == 0 or a.outs % b.ins != 0){
    fail(
      line,
      "a :> b needs a multiple of b's inputs as a's outputs; a has ",
      plural(a.outs, "output"),
      ", b ",
      plural(b.ins, "input"),
    )
  }
  return box(a.ins, b.outs, func(xs){
    local ys = a.f(xs)
    local sums = slice(ys, 0, b.ins)
    for(local i = b.ins; i < a.outs; i = i + 1){
      local k = i % b.ins
      sums[k] = g:op("add", {sums[k], ys[i]}, line)
    }
    return b.f(sums)
  })
}

// a ~ b: the outputs of a are the signals of a feedback group; b computes
// from them what a's first inputs get one sample later
local func rec(g, a, b, line){
  if(b.ins > a.outs or b.outs > a.ins){
    fail(
      line,
      "a ~ b needs at most as many inputs of b as outputs of a, and at most as many outputs of b as inputs of a; a has ",
      plural(a.ins, "input"),
      " and ",
      plural(a.outs, "output"),
      ", b ",
      plural(b.ins, "input"),
      " and ",
      plural(b.outs, "output"),
    )
  }
  return box(a.ins - b.outs, a.outs, func(xs){
    local group = g:group(a.outs)
    local now = {}
    for(local j = 0; j < a.outs; j = j + 1){
      append(now, g:proj(group, j))
    }
    local back = b.f(slice(now, 0, b.ins))
    local into = {}
    for(let local y in values(back)){
      append(into, g:mem(y, line))
    }
    for(let local x in values(xs)){
      append(into, x)
    }
    // a loop that computes what another one does is that one
    return g:close(group, a.f(into))
  })
}

// ------------------------------------------------------------ primitives

local func wire(){
  return box(1, 1, func(xs){ return xs })
}

local func op_box(g, op, n, line){
  return box(n, 1, func(xs){
    return {(g:op(op, xs, line))}
  })
}

// operator symbols: their signal operations
local SYMBOLS = {
  ["+"]: "add",
  ["-"]: "sub",
  ["*"]: "mul",
  ["/"]: "div",
  ["%"]: "mod",
  ["^"]: "pow",
  ["<"]: "lt",
  ["<="]: "le",
  [">"]: "gt",
  [">="]: "ge",
  ["=="]: "eq",
  ["!="]: "ne",
  ["&"]: "band",
  ["|"]: "bor",
  ["xor"]: "bxor",
  ["<<"]: "shl",
  [">>"]: "shr",
}

local func symbol_box(g, s, line){
  if(s == "@"){
    return box(2, 1, func(xs){
      return {(g:delay(xs[0], xs[1], line))}
    })
  }
  if(s == "<:" or s == ":>"){
    fail(line, s, " composes two diagrams; it is not a box")
  }
  return op_box(g, SYMBOLS[s], 2, line)
}

// the constant a value stands for (a box with no inputs and one constant
// output)
local func constant(v, line, what){
  if(v.t == "box" and v.ins == 0 and v.outs == 1){
    local s = v.f({})[0]
    if(s.op == "const"){
      return s.value
    }
  }
  fail(line, what, " must be a constant number, not ", describe(v))
}

local func label(v, line, what){
  if(v.t != "str"){
    fail(line, what, " must be a string, not ", describe(v))
  }
  return v.value
}

// the builtins: the root environment
local func builtins(g){
  local env = {}
  local func define(name, value){
    env[name] = {value: value}
  }
  define("mem", box(1, 1, func(xs){ return {(g:mem(xs[0]))} }))
  define("SR", box(0, 1, func(xs){ return {(g:sr())} }))
  define("float", wire())
  for(let local f in values({
    "sin", "cos", "tan", "asin", "acos", "atan", "exp", "log", "log10", "sqrt",
    "abs", "floor", "ceil", "rint", "tanh", "int"
  })){
    define(f, op_box(g, f, 1))
  }
  for(let local f in values({"min", "max", "pow", "atan2", "fmod"})){
    define(f, op_box(g, f, 2))
  }
  define("select2", op_box(g, "select2", 3))
  // select3(s, a, b, c): a, b or c as s is 0, 1 or 2
  define("select3", box(4, 1, func(xs){
    local s = xs[0]
    local ab = g:op("select2", {
      (g:op("lt", {s, (g:const(0.5))})), xs[2], xs[1]
    })
    local lt = g:op("lt", {s, (g:const(1.5))})
    return {(g:op("select2", {lt, xs[3], ab}))}
  }))
  // take(i, (a, b, c)): the i-th output of a tuple of constants or
  // signals (from 1)
  define("take", {
    t: "native", n: 2, f: func(args, line){
      local i = to_int(constant(args[0], line, "the index of take"))
      local t = need_box(args[1], line, "what take takes from")
      if(t.ins != 0 or i < 1 or i > t.outs){
        fail(
          line,
          "take(i, list): i from 1 to ",
          string(t.outs),
          " in a list without inputs",
        )
      }
      return box(0, 1, func(xs){ return {t.f({})[i - 1]} })
    }
  })
  // attach(a, b): a; b is computed too (for its effects: nothing here)
  define("attach", box(2, 1, func(xs){ return {xs[0]} }))
  // hslider(label, init, min, max, step) and its kin
  for(let local kind in values({"hslider", "vslider", "nentry"})){
    define(kind, {
      t: "native", n: 5, f: func(args, line){
        local spec = {
          kind: kind,
          label: label(args[0], line, concat("the label of ", kind)),
          init: constant(args[1], line, concat("the start value of ", kind)),
          min: constant(args[2], line, concat("the minimum of ", kind)),
          max: constant(args[3], line, concat("the maximum of ", kind)),
          step: constant(args[4], line, concat("the step of ", kind)),
          line: line,
        }
        if(spec.min > spec.max){
          fail(
            line, kind, " \"", spec.label,
            "\": the minimum is above the maximum"
          )
        }
        return box(0, 1, func(xs){ return {(g:control(spec))} })
      }
    })
  }
  for(let local kind in values({"button", "checkbox"})){
    define(kind, {
      t: "native", n: 1, f: func(args, line){
        local spec = {
          kind: kind,
          label: label(args[0], line, concat("the label of ", kind)),
          init: 0.0,
          min: 0.0,
          max: 1.0,
          step: 1.0,
          line: line,
        }
        return box(0, 1, func(xs){ return {(g:control(spec))} })
      }
    })
  }
  return {defs: env, parent: null}
}

// ------------------------------------------------------------ evaluation

local evaluate = null

// the file an error is in: the first definition it passes through says
// (null: the program's own text)
local func locate(err, origin){
  if(type(err) == "table" and not err.located){
    err.located = true
    err.origin = origin
  }
  return err
}

local func lookup(env, name, line){
  local e = env
  for(e != null){
    local d = e.defs[name]
    if(d != null){
      if(d.value == null){
        if(d.busy){
          fail(
            line, name,
            " is defined in terms of itself: a loop in a diagram goes through ~"
          )
        }
        d.busy = true
        try {
          d.value = evaluate(d.tree, d.env)
        } catch(local err) {
          d.busy = false
          raise(locate(err, d.origin))
        }
        d.busy = false
      }
      return d.value
    }
    e = e.parent
  }
  fail(line, "unknown name ", name)
}

// an environment of definitions, evaluated when first used
local func define_all(defs, parent){
  local env = {defs: {}, parent: parent}
  local lines = {}
  for(let local d in values(defs)){
    if(d.k != "def"){
      continue
    }
    if(lines[d.name] != null){
      fail(
        d.line, d.name, " is defined twice (first at line ",
        string(lines[d.name]), ")"
      )
    }
    lines[d.name] = d.line
    local scope = env
    if(d.with != null and d.params == null){
      scope = define_all(d.with, env)
    }
    if(d.params != null){
      // (its with sees the parameters: it is defined when it is applied)
      env.defs[d.name] = {
        value: {
          t: "abs",
          params: d.params,
          body: d.body,
          with: d.with,
          env: env,
          line: d.line,
          origin: d.origin,
        },
      }
    } else {
      env.defs[d.name] = {tree: d.body, env: scope, origin: d.origin}
    }
  }
  return env
}

local func apply(g, f, args, line){
  if(f.t == "abs"){
    local n = len(f.params)
    local env = {defs: {}, parent: f.env}
    local k = len(args)
    if(k > n){
      k = n
    }
    for(local i = 0; i < k; i = i + 1){
      env.defs[f.params[i]] = {value: args[i]}
    }
    if(k < n){
      // fewer arguments: a function of the rest
      return {
        t: "abs",
        params: slice(f.params, k, n),
        body: f.body,
        with: f.with,
        env: env,
        line: f.line,
        origin: f.origin,
      }
    }
    if(f.with != null){
      env = define_all(f.with, env)
    }
    local v = null
    try {
      v = evaluate(f.body, env)
    } catch(local err) {
      raise(locate(err, f.origin))
    }
    if(len(args) > n){
      return apply(g, v, slice(args, n, len(args)), line)
    }
    return v
  } else if(f.t == "native"){
    if(len(args) != f.n){
      fail(
        line, "expected ", plural(f.n, "argument"), ", got ", string(len(args))
      )
    }
    return f.f(args, line)
  } else if(f.t == "box"){
    // partial application: the arguments feed the last inputs,
    // f(a) is (_, ..., a) : f
    local feed = null
    local outs = 0
    for(let local a in values(args)){
      need_box(a, line, "an argument of a diagram")
      outs = outs + a.outs
      if(feed == null){
        feed = a
      } else {
        feed = par(feed, a)
      }
    }
    if(outs > f.ins){
      fail(
        line, "too many arguments: ", describe(f), " gets ",
        plural(outs, "signal")
      )
    }
    for(local i = 0; i < f.ins - outs; i = i + 1){
      feed = par(wire(), feed)
    }
    return seq(feed, f, line)
  }
  fail(line, describe(f), " takes no arguments")
}

// a function used as a diagram: f(x, y) is a box with two inputs, x and y
// standing for the signals it gets
as_box = func(f, line){
  local n = len(f.params)
  local current = {}
  local args = {}
  for(local i = 0; i < n; i = i + 1){
    local k = i
    append(args, box(0, 1, func(xs){ return {current[k]} }))
  }
  local body = need_box(apply(null, f, args, line), line, "a function's body")
  return box(n + body.ins, body.outs, func(xs){
    local saved = current
    current = slice(xs, 0, n)
    local out = body.f(slice(xs, n, len(xs)))
    current = saved
    return out
  })
}

local func compose(g, tree, env){
  local line = tree.line
  local a = need_box(
    evaluate(tree.a, env),
    line,
    concat("the left side of ", tree.op),
  )
  local b = need_box(
    evaluate(tree.b, env),
    line,
    concat("the right side of ", tree.op),
  )
  local op = tree.op
  if(op == ":"){
    return seq(a, b, line)
  } else if(op == ","){
    return par(a, b)
  } else if(op == "<:"){
    return split(g, a, b, line)
  } else if(op == ":>"){
    return merge(g, a, b, line)
  }
  return rec(g, a, b, line)
}

local func iterate(g, tree, env){
  local line = tree.line
  local count = constant(
    evaluate(tree.count, env),
    line,
    concat("the count of ", tree.op),
  )
  local n = to_int(count)
  if(n != count or n < 0){
    fail(line, "the count of ", tree.op, " must be a whole number >= 0")
  }
  local result = null
  for(local i = 0; i < n; i = i + 1){
    local scope = {defs: {}, parent: env}
    scope.defs[tree.var] = {value: box(0, 1, func(xs){ return {(g:const(i))} })}
    local v = need_box(
      evaluate(tree.body, scope),
      line,
      concat("the body of ", tree.op),
    )
    if(result == null){
      result = v
    } else if(tree.op == "par"){
      result = par(result, v)
    } else if(tree.op == "seq"){
      result = seq(result, v, line)
    } else {
      local o = "add"
      if(tree.op == "prod"){
        o = "mul"
      }
      result = seq(par(result, v), op_box(g, o, 2, line), line)
    }
  }
  if(result == null){
    if(tree.op == "sum"){
      return box(0, 1, func(xs){ return {(g:const(0))} })
    } else if(tree.op == "prod"){
      return box(0, 1, func(xs){ return {(g:const(1))} })
    }
    return box(0, 0, func(xs){ return {} })
  }
  return result
}

// make(g) -> func(tree, env): the evaluator over graph g
local func evaluator(g){
  local inner = null
  // the column of the innermost expression an error is on
  local func at(tree, env){
    if(tree.column == null){
      return inner(tree, env)
    }
    try {
      return inner(tree, env)
    } catch(local err) {
      if(type(err) == "table" and err.column == null and
        err.line == tree.line and not err.located){
        err.column = tree.column
      }
      raise(err)
    }
  }
  inner = func(tree, env){
    local k = tree.k
    local line = tree.line
    if(k == "num"){
      local v = tree.value
      return box(0, 1, func(xs){ return {(g:const(v))} })
    } else if(k == "wire"){
      return wire()
    } else if(k == "cut"){
      return box(1, 0, func(xs){ return {} })
    } else if(k == "str"){
      return {t: "str", value: tree.value}
    } else if(k == "name"){
      return lookup(env, tree.name, line)
    } else if(k == "op"){
      return symbol_box(g, tree.op, line)
    } else if(k == "bin"){
      // a + b is a, b : +
      local a = need_box(
        evaluate(tree.a, env),
        line,
        concat("the left side of ", tree.op),
      )
      local b = need_box(
        evaluate(tree.b, env),
        line,
        concat("the right side of ", tree.op),
      )
      return seq(par(a, b), symbol_box(g, tree.op, line), line)
    } else if(k == "comp"){
      return compose(g, tree, env)
    } else if(k == "mem"){
      local e = need_box(evaluate(tree.e, env), line, "what ' delays")
      return seq(e, box(1, 1, func(xs){ return {(g:mem(xs[0], line))} }), line)
    } else if(k == "app"){
      local f = evaluate(tree.f, env)
      local args = {}
      for(let local a in values(tree.args)){
        append(args, evaluate(a, env))
      }
      return apply(g, f, args, line)
    } else if(k == "iter"){
      return iterate(g, tree, env)
    } else if(k == "lambda"){
      return {
        t: "abs", params: tree.params, body: tree.body, env: env, line: line
      }
    }
    fail(line, "cannot evaluate ", k)
  }
  return at
}

// program(items, g, load) -> Box
// The `process` of a program's definitions (items as dsp/grammar parses
// them), a box over graph g. load(module, line) gives the definitions of
// an imported module (its items, with their own imports done).
func eval.program(items, g, load){
  local root = builtins(g)
  // imported definitions sit between the builtins and the program's own
  local all = {}
  local seen = {}
  local func gather(list){
    for(let local item in values(list)){
      if(item.k == "import"){
        if(not seen[item.module]){
          seen[item.module] = true
          gather(load(item.module, item.line))
        }
      } else {
        append(all, item)
      }
    }
  }
  local own = {}
  for(let local item in values(items)){
    if(item.k == "import"){
      gather({item})
    } else {
      append(own, item)
    }
  }
  local imported = define_all(all, root)
  local env = define_all(own, imported)
  evaluate = evaluator(g)
  if(env.defs.process == null){
    fail(
      1,
      "no process: a program defines what it computes as `process = ...;`",
    )
  }
  return need_box(lookup(env, "process", 1), 1, "process")
}

// signals(items, load?) -> {graph, outputs: {Node}, inputs: int}
// The output signals of a program's process, applied to its inputs.
func eval.signals(items, load){
  local g = signal.graph()
  local p = eval.program(items, g, load or func(m, line){
      fail(line, "import: no module loader")
    })
  local xs = {}
  for(local i = 0; i < p.ins; i = i + 1){
    append(xs, g:input(i))
  }
  return {graph: g, outputs: p.f(xs), inputs: p.ins}
}

return eval
