// Partial evaluation in slang: mix.slang specializes a program to the
// values it already knows. The last part is the first Futamura
// projection: an interpreter specialized to a program is that program,
// compiled.
local mix = require("mix")
local str = require("slang/string")
local time = require("slang/time")

local func say(...parts){ print(...parts, "\n") }

local func show(title, spec){
  say("\n== ", title)
  say(spec:source())
}

local func cons(head, rest){
  return {head, ...rest}
}

local func head(list){
  return list[0]
}

local func rest(list){
  local copy = {...list}
  remove(copy, 0)
  return copy
}

// ------------------------------------------------------- loops and recursion
local arith = +{block:
  func power(x, n){
    local r = 1
    for(local i = 0; i < n; i = i + 1){ r = r * x }
    return r
  }
  func dot(a, b, n){
    local s = 0
    for(local i = 0; i < n; i = i + 1){ s = s + a[i] * b[i] }
    return s
  }
  func fact(n){
    if(n == 0){ return 1 }
    return n * fact(n - 1)
  }
  func first_over(limit, list){
    for(local i = 0; i < 4; i = i + 1){
      if(list[i] > limit){ return i }
    }
    return -1
  }

  func map(l, f){
    if(head(l) == null){
      return {}
    }
    return cons(f(head(l)), map(rest(l), f))
  }

  func filter(l, f){
    if(head(l) == null){
      return {}
    }

    return f(head(l)) and
      cons(head(l), filter(rest(l), f) or filter(rest(l), f))
  }

  func fold(l, i, f){
    if(head(l) == null){
      return i
    }
    return f(head(l), fold(rest(l), i, f))
  }
}

local spec = mix.specialize(arith, "power", {n: 4})
show("power(x, n) with n = 4: the loop is unrolled", spec)
say("power(3) = ", spec:load()(3))

spec = mix.specialize(arith, "power", {x: 2})
show("power(x, n) with x = 2: the loop stays, the base is a constant", spec)
say("power(10) = ", spec:load()(10))

show("dot(a, b, n) with n = 3", mix.specialize(arith, "dot", {n: 3}))

show(
  "fact(n) with n = 10: the recursion is computed away",
  mix.specialize(arith, "fact", {n: 10}),
)
show(
  "fact(n) with n unknown: the recursion stays",
  mix.specialize(arith, "fact", {}),
)

show(
  "first_over(limit, list) with limit = 10: early returns unroll too",
  mix.specialize(arith, "first_over", {limit: 10}),
)
local func double(x) => 2 * x

show("map over known table", mix.specialize(
  arith,
  "map",
  {
    l: {1, 2, 3},
  },
  {
    pure: {cons, head, rest, double},
    statics: {cons: cons, head: head, rest: rest},
  },
))
show(
  "map of known table and function",
  mix.specialize(arith, "map", {l: {1, 2, 3}, f: double}, {
    pure: {cons, head, rest, double},
    statics: {cons: cons, head: head, rest: rest},
  }),
)
show(
  "filter over known table",
  mix.specialize(arith, "filter", {l: {1, 2, 3}}, {
    pure: {cons, head, rest},
    statics: {cons: cons, head: head, rest: rest},
  }),
)

show("fold over known table", mix.specialize(arith, "fold", {l: {1, 2, 3}}, {
  pure: {cons, head, rest},
  statics: {cons: cons, head: head, rest: rest},
}))

// --------------------------------------------------------- a glob matcher
// match(p, i, t, j): does pattern p from i match text t from j? `*` is
// any run, `?` any character. With the pattern static, every position in
// it becomes a function of its own: the matcher is a state machine.
local glob = +{block:
  func match(pattern, i, text, j){
    if(i == len(pattern)){ return j == len(text) }
    local c = str.byte_at(pattern, i)
    if(c == '*'){
      if(match(pattern, i + 1, text, j)){ return true }
      if(j < len(text)){ return match(pattern, i, text, j + 1) }
      return false
    }
    if(j == len(text)){ return false }
    if(c == '?' or c == str.byte_at(text, j)){
      return match(pattern, i + 1, text, j + 1)
    }
    return false
  }
  // j starts dynamic: it depends on the text, so counting it up at
  // specialization time would never end (try it without dynamic)
  func matches(pattern, text){ return match(pattern, 0, text, dynamic(0)) }
}
spec = mix.specialize(glob, "matches", {pattern: "a*b?"}, {
  statics: {str: str}, pure: {str.byte_at}
})
show("matches(p, t) with p = \"a*b?\": a state machine", spec)
local m = spec:load()
say(
  "axxbc: ", m("axxbc"), "  ab: ", m("ab"), "  abc: ", m("abc"), "  xbc: ",
  m("xbc")
)

// ---------------------------------------------- the first Futamura projection
// An interpreter for a small language. A program is a table:
//   {"seq", s1, s2, ...}  {"set", name, e}  {"while", c, body}
//   {"if", c, then, else}  {"print", e}
// and an expression a number, a variable name or {op, a, b}.
local interpreter = +{block:
  func run(program, input){
    local vars = {n: input}
    exec(program, vars)
    return vars.result
  }
  func exec(stmt, vars){
    local kind = stmt[0]
    if(kind == "seq"){
      for(local i = 1; i < len(stmt); i = i + 1){ exec(stmt[i], vars) }
    } else if(kind == "set"){
      vars[stmt[1]] = eval(stmt[2], vars)
    } else if(kind == "while"){
      for(eval(stmt[1], vars)){ exec(stmt[2], vars) }
    } else if(kind == "if"){
      if(eval(stmt[1], vars)){
        exec(stmt[2], vars)
      } else {
        exec(stmt[3], vars)
      }
    } else if(kind == "print"){
      print(eval(stmt[1], vars))
    } else {
      error("unknown statement ", kind)
    }
  }
  func eval(e, vars){
    if(type(e) == "int"){ return e }
    if(type(e) == "string"){ return vars[e] }
    local op = e[0]
    local a = eval(e[1], vars)
    local b = eval(e[2], vars)
    if(op == "+"){ return a + b }
    if(op == "-"){ return a - b }
    if(op == "*"){ return a * b }
    if(op == "/"){ return a / b }
    if(op == "%"){ return a % b }
    if(op == ">"){ return a > b }
    if(op == "=="){ return a == b }
    error("unknown operator ", op)
  }
}

local factorial = {
  "seq",
  {"set", "result", 1},
  {
    "while", {">", "n", 0}, {
      "seq",
      {"set", "result", {"*", "result", "n"}},
      {"set", "n", {"-", "n", 1}},
    }
  },
}
local collatz = {
  "seq",
  {"set", "result", 0},
  {
    "while", {">", "n", 1}, {
      "seq",
      {
        "if",
        {"==", {"%", "n", 2}, 0},
        {"set", "n", {"/", "n", 2}},
        {"set", "n", {"+", {"*", "n", 3}, 1}},
      },
      {"set", "result", {"+", "result", 1}},
    }
  },
}

local interp = mix.load(interpreter)
say(
  "\ninterpreted: factorial(5) = ",
  interp.run(factorial, 5),
  "  collatz(27) = ",
  interp.run(collatz, 27),
)

spec = mix.specialize(interpreter, "run", {program: factorial})
show("the interpreter specialized to the factorial program", spec)
local compiled_factorial = spec:load()
say("compiled: factorial(5) = ", compiled_factorial(5))

spec = mix.specialize(interpreter, "run", {program: collatz})
show("the interpreter specialized to the collatz program", spec)
local compiled_collatz = spec:load()
say("compiled: collatz(27) = ", compiled_collatz(27))

// the same work, interpreted and compiled
local rounds = 20000
local t0 = time.clock()
for(local i = 0; i < rounds; i = i + 1){ interp.run(collatz, 27) }
local interpreted_ms = time.clock() - t0
t0 = time.clock()
for(local i = 0; i < rounds; i = i + 1){ compiled_collatz(27) }
local compiled_ms = time.clock() - t0
say(
  "\ncollatz(27) ", rounds, " times: interpreted ", to_int(interpreted_ms),
  " ms, compiled ", to_int(compiled_ms), " ms"
)
