# Partial evaluation and the first Futamura projection

A *partial evaluator* takes a program and the values of some of its
inputs, and gives back the *residual program*: the same program with
everything done that depended only on those inputs. What is known when
specializing is called **static**, what is only known when the residual
program runs **dynamic**.

`mix.slang`, next to this notebook, is a partial evaluator for a subset of
slang. This notebook runs it on a few programs, small ones first, and ends
where the idea gets its name: an interpreter specialized to a program is
that program, compiled.

Run the cells from the top (**Run all**); each one builds on those before.

```slang
local mix = require("mix")
local nb = require("notebook")
local str = require("slang/string")
local time = require("slang/time")

// shows a residual program as the code it is
local func show(spec){
  nb.display(nb.code(spec:source()))
}

// how long f takes, in milliseconds
local func timed(f){
  local started = time.clock()
  f()
  return time.clock() - started
}
```

## Specializing a function

A program for `mix` is a quoted block of function declarations. The quote,
`+{block: ...}`, makes it a syntax tree instead of running it, and the
tree is what `mix` walks.

```slang
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
}
```

`mix.specialize(program, entry, args)` fixes the parameters named in
`args`. With `n = 4`, the loop of `power` depends on nothing dynamic: its
condition can be decided each time round, so the loop is unrolled, and
only the multiplications by `x` are left.

```slang
local spec = mix.specialize(arith, "power", {n: 4})
show(spec)
```

Nothing is simplified algebraically (`1 * x` stays: it is not `x` for
every value `x` may have). `spec:load()` compiles the residual program
and gives its entry function, which takes the parameters that stayed
dynamic:

```slang
spec:load()(3)
```

The other way round, with the base known and the exponent not, the loop
has to stay, since how often it runs is dynamic. The base is a constant
in it:

```slang
show(mix.specialize(arith, "power", {x: 2}))
```

A dot product of vectors of a known length is a sum written out:

```slang
show(mix.specialize(arith, "dot", {n: 3}))
```

Recursion is treated like loops. A call of a program function with static
arguments specializes that function to them, and when the recursion runs
on static data it ends when the data does: `fact(10)` is computed while
specializing.

```slang
show(mix.specialize(arith, "fact", {n: 10}))
```

With `n` dynamic there is nothing to compute, and the function comes back
as it was:

```slang
show(mix.specialize(arith, "fact", {}))
```

A static condition picks its branch; a dynamic one keeps both. Here the
loop is static and the comparison is not, so the loop unrolls into four
tests, early returns included:

```slang
show(mix.specialize(arith, "first_over", {limit: 10}))
```

## Known data, unknown functions

The program may call functions that are not part of it. `mix` has to be
told two things about them: `statics` are values the residual program
refers to by name (and `load` binds), and `pure` lists functions that may
be run at specialization time when their arguments are static.

```slang
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

local func double(x) => 2 * x

local lists = +{block:
  func map(l, f){
    if(head(l) == null){
      return {}
    }
    return cons(f(head(l)), map(rest(l), f))
  }
  func fold(l, i, f){
    if(head(l) == null){
      return i
    }
    return f(head(l), fold(rest(l), i, f))
  }
}

local helpers = {
  pure: {cons, head, rest, double},
  statics: {cons: cons, head: head, rest: rest},
}
```

With the list static and the function dynamic, walking the list happens
now and calling `f` happens later:

```slang
show(mix.specialize(lists, "map", {l: {1, 2, 3}}, helpers))
```

When the function is static too, and pure, nothing is left to do later:

```slang
show(mix.specialize(lists, "map", {l: {1, 2, 3}, f: double}, helpers))
```

And a fold over a known list is its calls, nested:

```slang
show(mix.specialize(lists, "fold", {l: {1, 2, 3}}, helpers))
```

## A matcher becomes a state machine

`match(p, i, t, j)` says whether the pattern `p` from position `i` matches
the text `t` from position `j`: `*` is any run of characters, `?` any one.
It is an interpreter of patterns. Specialized to a pattern, every position
in the pattern becomes a function of its own, and the matcher is a state
machine for that one pattern.

There is a catch, and it is the central difficulty of partial evaluation.
Which values are static is decided from the inputs, and here that goes
wrong: `matches` starts at `j = 0`, a constant, so `j` looks static. But
it is counted up under conditions that depend on the text, and
specializing `match` to `j = 1, 2, 3, ...` never ends. `mix` gives up
after a thousand specializations of one function:

```slang
local func glob(start){
  // the program, with the matcher started at j = -{start}
  return +{block:
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
    func matches(pattern, text){ return match(pattern, 0, text, -{start}) }
  }
}
local text_functions = {statics: {str: str}, pure: {str.byte_at}}

local problem = "none"
try {
  mix.specialize(glob(+{expr: 0}), "matches", {pattern: "a*b?"}, text_functions)
} catch(local e) {
  problem = e.message
}
problem
```

The program has to say that `j` belongs to the text. `dynamic(x)` is `x`
when the program runs, and tells `mix` to treat it as unknown. This is a
*binding-time improvement*: a change to the program that does not change
what it computes, only what can be known about it early.

```slang
local machine = mix.specialize(
  glob(+{expr: dynamic(0)}), "matches", {pattern: "a*b?"}, text_functions,
)
show(machine)
```

Four functions, one per position of `a*b?` (the characters are compared
as their codes: 97 is `a`, 98 is `b`). It still matches:

```slang
local matches = machine:load()
local rows = {}
for(let local text in values({"axxbc", "abc", "ab", "xbc"})){
  append(rows, {text: text, matches: matches(text)})
}
nb.table(rows, {columns: {"text", "matches"}})
```

## The first Futamura projection

Now an interpreter of a real, if small, language: assignments, `while`,
`if` and `print` over a table of variables. A program is a table,
`{"seq", s1, s2, ...}`, `{"set", name, e}`, `{"while", c, body}`,
`{"if", c, then, else}`; an expression is a number, a variable's name or
`{op, a, b}`.

```slang
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
      raise(error.new(error.kinds.argument, concat("unknown statement ", kind)))
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
    raise(error.new(error.kinds.argument, concat("unknown operator ", op)))
  }
}
```

Two programs in that language: the factorial of `n`, and the number of
steps `n` takes to reach 1 in the Collatz sequence.

```slang
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
```

`mix.load` loads a program as it is. Interpreted, the two give:

```slang
local interp = mix.load(interpreter)
{factorial: interp.run(factorial, 5), collatz: interp.run(collatz, 27)}
```

An interpreter is a program with two inputs, the program it runs and that
program's input. Fix the first and leave the second dynamic:
**mix(interpreter, program)**. The interpreter's dispatch on the kind of
each statement is static and disappears, its loop over a sequence
unrolls, and `eval` of an expression becomes the expression. What is
left is the factorial program itself, written in slang over the table of
variables:

```slang
local factorial_compiled = mix.specialize(interpreter, "run", {program: factorial})
show(factorial_compiled)
```

That is the first Futamura projection: specializing an interpreter to a
program compiles the program into the language the interpreter is
written in. Nobody wrote a compiler; there is only an interpreter and
`mix`. The same for the other program:

```slang
local collatz_compiled = mix.specialize(interpreter, "run", {program: collatz})
show(collatz_compiled)
```

Both compute what the interpreter computes:

```slang
local run_factorial = factorial_compiled:load()
local run_collatz = collatz_compiled:load()
{factorial: run_factorial(5), collatz: run_collatz(27)}
```

And faster, since a layer of interpretation is gone:

```slang
local rounds = 20000
local interpreted_ms = timed(func(){
  for(local i = 0; i < rounds; i = i + 1){ interp.run(collatz, 27) }
})
local compiled_ms = timed(func(){
  for(local i = 0; i < rounds; i = i + 1){ run_collatz(27) }
})
nb.display(nb.plot(
  {{x: {0}, y: {interpreted_ms}, label: "interpreted", kind: "bar"},
   {x: {0}, y: {compiled_ms}, label: "compiled", kind: "bar"}},
  {title: concat("collatz(27), ", string(rounds), " times: milliseconds"), width: 420, height: 240},
))
concat(str.format("%.1f", interpreted_ms / compiled_ms), " times faster")
```

## A Lisp, its self-interpreter, and mix(int, sint)

How good is the compiler that `mix` makes of an interpreter? There is a
classic test for that, and it needs a language with an interpreter
written in itself.

`lisp.slang` is a small first-order Lisp: a reader and printer for
s-expressions, and an interpreter, `int`, written as a quoted program for
`mix`. A Lisp program is a list of `(define (name param ...) body)` forms
and runs by calling `main`.

```slang
local lisp = require("lisp")
local int = mix.load(lisp.interpreter)
local options = {limit: 5000}

local fib = lisp.read("""
  (define (main n) (fib n))
  (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
""")
local append_lists = lisp.read("""
  (define (main xs ys) (app xs ys))
  (define (app xs ys) (if (null? xs) ys (cons (car xs) (app (cdr xs) ys))))
""")
local func list_of(text){
  return lisp.read(text)[0]
}

print("fib(20) = ", int.run(fib, 20), "\n")
print("(app '(1 2) '(3)) = ", lisp.show(int.run(append_lists, list_of("(1 2)"), list_of("(3)"))), "\n")
```

### mix(int, p): Lisp compiled to slang

The first projection again. `int` keeps its environment as a table of
the Lisp variables by name, so with the program static a variable is a
field read and a call builds a table of the arguments. `mix` then turns
those tables into parameters (arity raising): the residual function is a
function of the Lisp variables, named after the Lisp function.

```slang
local fib_compiled = mix.specialize(lisp.interpreter, "run", {program: fib}, options)
show(fib_compiled)
```

Lists are pairs, `{car, cdr}`, and the empty list is `null`:

```slang
show(mix.specialize(lisp.interpreter, "run", {program: append_lists}, options))
```

With the program's input static as well there is nothing left to run:

```slang
show(mix.specialize(lisp.interpreter, "run", {program: fib, a: 10}, options))
```

### The interpreter in its own language

`sint.lisp` is the same interpreter written in the Lisp itself. It loads
with `require`, through a dialect that the example's `slang.project`
declares for `.lisp` files.

```slang
local os = require("slang/os")
local sint = require("sint")
print(len(lisp.to_list(sint)), " definitions\n")
nb.code(os.read_file("sint.lisp"), "lisp")
```

Running a program with it means two layers of interpretation: `int` runs
`sint`, which runs the program.

```slang
int.run(sint, fib, 15)
```

### mix(int, sint)

Now specialize the interpreter to the self-interpreter. The result is a
Lisp interpreter written in slang, which nobody wrote: `ev`, `apply`,
`bind` and the rest read like `sint.lisp` translated by hand.

```slang
local generated = mix.specialize(lisp.interpreter, "run", {program: sint}, options)
print(len(generated.functions), " functions\n")
show(generated)
```

It runs Lisp programs like the hand-written one:

```slang
local sint_slang = generated:load()
print("fib(15) = ", sint_slang(fib, 15), "\n")
print("(app '(1 2) '(3)) = ", lisp.show(sint_slang(append_lists, list_of("(1 2)"), list_of("(3)"))), "\n")
```

### The optimality test

Jones's test for a specializer: is the interpreter it generates from the
self-interpreter as good as the one written by hand? If so, `mix` removes
a whole layer of interpretation, not just part of one. Here is fib(18)
four ways.

```slang
local run_fib = fib_compiled:load()
local n = 18
local ways = {
  {how: "compiled by mix(int, fib)", ms: timed(func(){ run_fib(n) })},
  {how: "int, the interpreter written by hand", ms: timed(func(){ int.run(fib, n) })},
  {how: "mix(int, sint), the generated interpreter", ms: timed(func(){ sint_slang(fib, n) })},
  {how: "int running sint running fib", ms: timed(func(){ int.run(sint, fib, n) })},
}
for(let local way in values(ways)){
  way.ms = str.format("%.1f", way.ms)
}
nb.table(ways, {columns: {"how", "ms"}})
```

The generated interpreter runs at the speed of the hand-written one, and
far faster than the doubly interpreted program it was made from.

Two things made that possible, both binding-time improvements. The
interpreter is written so that what depends only on the program is
visibly apart from what depends on its input: the environment's names
are the keys of a table and its values the fields, it recurses instead
of looping, and the argument list is built by a function that returns a
table literal. And `mix` rebuilds those environments as parameters
afterwards.

## Further

**The second and third projections.** `mix(mix, interpreter)` would be a
compiler, and `mix(mix, mix)` a compiler generator. Both need `mix` to be
written in the subset it handles and to specialize well when applied to
itself. This one is not: it uses `for ... in`, patterns, metatables and
closures over mutable state, and decides binding times while it runs.
That is the hard part of the literature (Jones, Gomard and Sestoft,
*Partial Evaluation and Automatic Program Generation*; chapter 5 has a
self-applicable specializer for a small first-order language).

**A grammar, compiled.** The parser combinators of `slang/peg` are an
interpreter of the grammar, and the grammar is static. `mix` cannot
specialize them (they are closures, not a syntax tree), so
`slang/compiler/pegc.slang` does by hand what `mix` would do, and slang's
own parser is its output. `peg_bench.slang` measures it.

The README next to this notebook has the details: what `mix` does case by
case, the subset of slang it takes, and the numbers for the compiled
grammar.

```slang
```
