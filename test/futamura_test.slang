// the partial evaluator of examples/futamura
local t = require("slang/test")
local str = require("slang/string")
local mix = require("examples/futamura/mix")

local arith = +{block:
  func power(x, n){
    local r = 1
    for(local i = 0; i < n; i = i + 1){ r = r * x }
    return r
  }
  func fact(n){
    if(n == 0){ return 1 }
    return n * fact(n - 1)
  }
  func adder(k, list){
    local total = 0
    local add = func(x){ total = total + x * k }
    for(local i = 0; i < len(list); i = i + 1){
      if(list[i] == null){ break }
      add(list[i])
    }
    return total
  }
}

t.group("mix"){
  t.test("a static loop bound unrolls the loop"){
    local spec = mix.specialize(arith, "power", {n: 3})
    local src = spec:source()
    assert(not str.contains(src, "for("), src)
    assert(spec:load()(2) == 8, "power(2)")
  }
  t.test("a dynamic loop bound keeps the loop with the base folded"){
    local spec = mix.specialize(arith, "power", {x: 2})
    local src = spec:source()
    assert(str.contains(src, "r * 2"), src)
    assert(spec:load()(10) == 1024, "2^10")
  }
  t.test("static recursion is computed, dynamic recursion stays"){
    assert(str.contains(mix.specialize(arith, "fact", {n: 5}):source(), "return 120"), "fact(5)")
    local spec = mix.specialize(arith, "fact", {})
    assert(str.contains(spec:source(), "fact(n - 1)"), spec:source())
    assert(spec:load()(5) == 120, "fact(5) dynamic")
  }
  t.test("closures capture, loops with breaks stay loops"){
    local spec = mix.specialize(arith, "adder", {k: 3})
    assert(str.contains(spec:source(), "local k = 3"), spec:source())
    assert(spec:load()({1, 2, 3}) == 18, "adder")
  }
  t.test("writes to static tables are errors, dynamic() lifts them"){
    local p = +{block:
      func g(){ local t = {a: 1} t.b = 2 return t }
      func h(){ local t = dynamic({a: 1}) t.b = 2 return t }
    }
    let {"err", local e} = pcall(mix.specialize, p, "g", {})
    assert(str.contains(e.message, "read-only"), e.message)
    assert(mix.specialize(p, "h", {}):load()().b == 2, "dynamic table")
  }
  t.test("runaway specialization is reported"){
    local p = +{block:
      func count(i, x){ if(x > i){ return count(i + 1, x) } return i }
    }
    let {"err", local e} = pcall(mix.specialize, p, "count", {i: 0}, {limit: 10})
    assert(str.contains(e.message, "specialized more than 10"), e.message)
  }
}

t.group("first Futamura projection"){
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
        if(eval(stmt[1], vars)){ exec(stmt[2], vars) } else { exec(stmt[3], vars) }
      }
    }
    func eval(e, vars){
      if(type(e) == "int"){ return e }
      if(type(e) == "string"){ return vars[e] }
      local a = eval(e[1], vars)
      local b = eval(e[2], vars)
      if(e[0] == "+"){ return a + b }
      if(e[0] == "-"){ return a - b }
      if(e[0] == "*"){ return a * b }
      if(e[0] == "%"){ return a % b }
      if(e[0] == "/"){ return a / b }
      if(e[0] == ">"){ return a > b }
      return a == b
    }
  }
  local collatz = {"seq",
    {"set", "result", 0},
    {"while", {">", "n", 1},
      {"seq",
        {"if", {"==", {"%", "n", 2}, 0}, {"set", "n", {"/", "n", 2}}, {"set", "n", {"+", {"*", "n", 3}, 1}}},
        {"set", "result", {"+", "result", 1}}}},
  }
  t.test("the interpreter specialized to a program is the program"){
    local spec = mix.specialize(interpreter, "run", {program: collatz})
    local src = spec:source()
    assert(not str.contains(src, "exec") and not str.contains(src, "eval"), src)
    assert(str.contains(src, "vars.n % 2 == 0"), src)
    assert(spec:load()(27) == 111, "collatz(27)")
    assert(mix.load(interpreter).run(collatz, 27) == 111, "interpreted collatz(27)")
  }
}

t.group("Lisp: mix(int, p) and mix(int, sint)"){
  local lisp = require("examples/futamura/lisp")
  local os = require("slang/os")
  local sint = lisp.read(os.read_file("examples/futamura/sint.lisp"))
  local fib = lisp.read("(define (main n) (fib n)) (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))")
  local options = {limit: 5000}
  t.test("a Lisp program compiles to a function of its variables"){
    local spec = mix.specialize(lisp.interpreter, "run", {program: fib}, options)
    local src = spec:source()
    assert(str.contains(src, "fib(n - 1) + fib(n - 2)"), src)
    assert(spec:load()(10) == 55, "fib(10)")
    assert(str.contains(mix.specialize(lisp.interpreter, "run", {program: fib, a: 10}, options):source(), "return 55"), "fib(10) static")
  }
  t.test("the interpreter specialized to the self-interpreter interprets"){
    local spec = mix.specialize(lisp.interpreter, "run", {program: sint}, options)
    local src = spec:source()
    assert(str.contains(src, "ev = func(program, e, env)"), src)
    assert(spec:load()(fib, 10) == 55, "generated interpreter")
    assert(mix.load(lisp.interpreter).run(sint, fib, 10) == 55, "doubly interpreted")
  }
}

t.group("pegc: the grammar compiled to slang"){
  t.test("the generated parser builds the same AST as the combinators"){
    local compiler = require("slang/compiler")
    local peg = require("slang/peg")
    local ast = require("slang/ast")
    local pegc = require("examples/futamura/pegc")
    local g = compiler.grammar()
    g:parse_source("local x = 1", "warm")
    local parsers = pegc.compile(g):load()
    local source = "local func f(a, b){ if(a < b){ return {a, b, k: a * 2} } return f(b, a):m(\"s\") }"
    local ctx = peg.context(source)
    local q1 = g.sealed.statement:parse_on(ctx, 0)
    local a = ctx.value
    ctx = peg.context(source)
    local q2 = parsers.rules.statement(ctx, 0)
    assert(q1 == q2 and q1 == len(source), concat("positions ", q1, " ", q2))
    assert(ast.to_source(a) == ast.to_source(ctx.value), ast.to_source(ctx.value))
    ctx = peg.context("local = 1")
    assert(parsers.rules.statement(ctx, 0) < 0 and ctx.far_pos == 6, concat("failure at ", ctx.far_pos, ": ", ctx.far_msg))
  }
}
