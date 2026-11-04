# Partial evaluation and the first Futamura projection

`mix.slang` is a partial evaluator for a subset of slang: given a program
and the values of some of its inputs, it produces the residual program, in
which everything that depended only on those inputs has already happened.
`main.slang` runs it on a few programs and ends with the first Futamura
projection: an interpreter specialized to a program is that program,
compiled.

```
bin/slang run examples/futamura/main.slang
```

```slang
local mix = require("mix")
local program = +{block:
  func power(x, n){
    local r = 1
    for(local i = 0; i < n; i = i + 1){ r = r * x }
    return r
  }
}
local spec = mix.specialize(program, "power", {n: 3})
print(spec:source())
//   local func power(x){
//     return 1 * x * x * x
//   }
spec:load()(2)      // 8
```

A program is a quoted block of function declarations (`+{block: ...}`,
so it is an AST, which is what `mix` walks). `mix.specialize(program,
entry, args, options?)` fixes the parameters named in `args` and returns
the residual program: `spec:source()` prints it, `spec:load()` compiles it
and returns the entry function (its remaining parameters are the dynamic
ones), `spec.functions` are the residual functions. `mix.load(program)`
loads the program as it is, to compare.

## What it does

The specializer walks the AST with an environment that holds, for every
variable, either its value (static) or only its name (dynamic). Values
flow from the static arguments:

- Expressions over static values are evaluated; the rest are rebuilt as
  residual code. The pure builtins (`len`, `count`, `type`, `concat`,
  `string`, ...) and the functions in `options.pure` run on static
  arguments; other calls of unknown functions stay.
- A static condition picks its branch. A dynamic one keeps both, and
  every variable the branches disagree on becomes dynamic afterwards
  (each branch assigns its value).
- A loop whose condition stays static is unrolled (`options.unroll`
  iterations at most, 256 by default). Otherwise the variables it changes
  are made dynamic before it and it is emitted as a loop, with the
  rest of its body still specialized.
- A call of a program function with some static arguments specializes
  that function to them. Specializations are memoized on the static
  values, so recursion over static data ends when the data does (`fact(n)`
  with `n = 10` is `return 3628800`; the glob matcher below gets one
  function per pattern position). A specialized function that is not
  recursive is inlined at the call site, as statements or as one
  expression; the others become `local func` declarations next to the
  entry.
- A call of `error` or `raise` never returns, so nothing after it is
  specialized (otherwise dead code after an error would turn dynamic and
  drag whole functions into the residual).
- The residual code is tidied without changing what it evaluates when:
  a local that is read once, as the first thing the next statement
  evaluates, is written into that statement (`local r = 1 * x` followed
  by `r = r * x` and `return r` is `return 1 * x * x`). Nothing is
  simplified algebraically: `1 * x` is not `x` for every value.
- Arity raising: a residual function whose calls all pass a table
  literal for a parameter, and whose body only reads fields of it, takes
  the fields as parameters: `f({n: a})` with `env.n` in the body becomes
  `f(a)` with `n` in the body (`{...env, op: x}` becomes the fields of
  `env` plus `op`, iterated to a fixpoint). It is what makes the Lisp
  example below produce functions of the Lisp variables. `options.raise
  = false` leaves it out.
- Residual functions are named after the function they specialize plus
  the identifier-like strings among the static arguments
  (`lookup(program, "main")` gives `lookup_main`), or after a
  `hint(name)` statement in the body with a static name, which does
  nothing at run time: the Lisp interpreter's `apply_def` hints the name
  of the Lisp function it applies.
- Table literals of static fields are static values, as are the static
  arguments; static tables are read-only (writing to one is an error:
  build it at run time, or wrap it in `dynamic(...)`). A function literal
  makes the static locals it mentions dynamic, since it captures them.

The subset: literals, tables (spread included), variables, indexing,
operators, `if`, `for`, `break`, `continue`, `return`, `local`,
assignment, closures, calls and method calls. Not supported: `let`
patterns, `for ... in`, `try`, `throw`, `defer`, labels, rest parameters. The program's free
names are either builtins, or values given in `options.statics` (modules,
say: `{statics: {str: str}}`), which the residual refers to by the same
name and `spec:load()` binds.

### Binding times

Which values are static is decided while specializing, from the inputs,
and sometimes the program has to say so. The glob matcher in `main.slang`
is the classic case: `matches(p, t)` calls `match(p, 0, t, 0)`, and with
the pattern static the position `j` in the text starts static too, is
counted up under a dynamic condition, and never stops: `mix` gives up
after `options.limit` (1000) specializations of one function. `match(p,
0, t, dynamic(0))` makes `j` dynamic from the start, and the pattern
`"a*b?"` becomes four functions, one per state. `dynamic(x)` is `x` at
run time (`mix.dynamic`, also a global once `mix` is loaded).

## The Futamura projections

The first projection: `mix(interpreter, program)` is a compiled program.
`main.slang` has an interpreter for a small language of assignments,
`while`, `if` and `print` over a table of variables, and specializes
`run(program, input)` to a program with the input left dynamic. The
interpreter's dispatch on the program disappears, its loops over the
program unroll, and what remains is the program itself, written in slang
over the `vars` table:

```slang
local func run(input){
  local vars = {n: input}
  vars.result = 1
  for(vars.n > 0){
    vars.result = vars.result * vars.n
    vars.n = vars.n - 1
  }
  return vars.result
}
```

`main.slang` times the interpreted and the compiled collatz program
against each other at the end.

## A Lisp, its self-interpreter, and mix(int, sint)

`lisp.slang` is a small first-order Lisp: a reader and printer for
s-expressions, and an interpreter `int` written as a quoted program for
`mix`. A program is a list of `(define (name param ...) body)` forms;
there are `quote`, `if`, `let`, the list primitives, arithmetic, and
calls. `sint.lisp` is the same interpreter written in the Lisp itself (11
definitions: `lookup`, `bind`, `variable`, `ev`, `ev-let`, `ev-args`,
`apply`, `call`, ...), loaded by `require("sint")` through a dialect in
`slang.project`.

```
bin/slang run examples/futamura/self.slang
```

`mix(int, p)` compiles a Lisp program to slang. The interpreter keeps
its environment as a table of the variables by name, built as a literal,
and with the program static a variable is `env.n`, a call's environment
is `{n: env.n - 1}`, and arity raising then makes the residual function
a function of the variables. A `hint` in `apply_def` names it after the
Lisp function:

```slang
(define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
;; mix(int, fib):
local fib
fib = func(n){
  return if(n < 2){ n } else { fib(n - 1) + fib(n - 2) }
}
```

`mix(int, sint)` is the interesting one: the interpreter specialized to
the self-interpreter is a Lisp interpreter written in slang, generated.
It comes out as eleven functions that read like `sint.lisp` translated
by hand, `ev(program, e, env)`, `apply(program, op, args)`,
`bind(names, values, env)` and so on, except that the two bindings of
the `let` in `ev` become two helper functions. Jones's optimality test
for a specializer asks whether this generated interpreter is as good as
the hand-written one, that is, whether `mix` removes a whole layer of
interpretation and not just part of it. `self.slang` times fib(18) four
ways: compiled by `mix(int, fib)`, run by `int`, run by `mix(int, sint)`,
and run by `int` running `sint` running fib. The generated interpreter
runs at the speed of the hand-written one, and about seventy times
faster than the doubly interpreted program.

Two things made that possible, both standard binding-time improvements:
the interpreter is written so that what depends only on the program is
visibly separate from what depends on the input (the environment's names
are keys, its values are the fields; recursion instead of loops; the
argument list is built by a function that returns a literal), and `mix`
rebuilds the environments as parameters afterwards (arity raising).

## The grammar compiled: pegc

The parser combinators of `slang/peg` are an interpreter of the grammar,
and the grammar is static. `slang/compiler/pegc.slang` does for them
what `mix` cannot (they are closures, not an AST): a generator written
by hand from what `mix` would do. It walks the sealed grammar's parser
graph and emits slang: every node reachable from the rules becomes
straight-line code inlined into its parent, nodes that are shared
(several parents, rules, memoized nodes, dispatch candidates) become
functions, each in the mode its parent needs (the value path, the fast
path that only finds the end position, or the tree path that also
builds the lossless tree), and the expression walker's Pratt loop is
generated with one function per operator entry. Actions, predicates,
regexes, custom parsers and the walker's callbacks are called through a
table of statics. The context contract of `slang/peg` is kept, so the
generated parser records the same failures and builds the same ASTs and
trees.

It started here as the experiment `pegc.slang` (which now just loads the
compiler's) and is what the compiler uses: a grammar flagged for it (the
root, a project's, a dialect's) installs the generated parsers as the
targets of its rule references when a parse first asks for the tree or
once a process has parsed more than 128 KB; the root grammar's module
ships with the compiler, others are compiled once and cached as
bytecode (see the README's Metaprogramming section; `SLANG_PEGC=0`
turns it off).

On the language server, driven in-process over the 22 files of
`examples/siege` (206 KB): opening a file (tree parse, symbols, lint)
169 to 111 ms, a keystroke (the same analysis again) 84 to 53 ms,
formatting 296 to 215 ms, hover 8.5 to 4 ms; requests that read the
index (definition, references, completion) were already under a
millisecond and stay there.

```
bin/slang run examples/futamura/peg_bench.slang
```

parses the compiler's own sources (309 KB) with the combinators and with
the generated parser, checks that the ASTs and the lossless trees are
identical, and times them (the best of five runs, on a quiet machine):

| | combinators | generated |
|---|---|---|
| parse | 258 ms | 111 ms |
| parse with the lossless tree (the language server's) | 874 ms | 326 ms |

`compiler.tree` of a 107 KB file, which is what the language server
runs on every change, goes from 307 ms to 131 ms, and its very first
call, generation and loading of the cached module included, is faster
than the interpreted parse was.

Where the time went, step by step: a straight translation 1.5×; values
in locals instead of ctx.value, failures inlined, tokens generated
directly 1.9×; the natives bound as locals 2.0×; small non-recursive
rules inlined 2.3×; the failure bookkeeping (only the farthest failure,
its position cached per function) 2.6×. The tree path is not inlined
across shared nodes and splits big nodes into functions, since a
function has 255 registers; its functions live in a nested scope of
their own for the same reason, and go into a table when a grammar grows
past what one frame holds.

The second projection, `mix(mix, interpreter)`, would be a compiler, and
the third, `mix(mix, mix)`, a compiler generator. Both need `mix` to be
written in the subset it handles and to specialize well under
self-application, which this one is not (it uses `for ... in`, patterns,
metatables and closures over mutable state, and makes its binding-time
decisions online). That is the hard part of the literature: Jones, Gomard
and Sestoft, *Partial Evaluation and Automatic Program Generation*
(chapter 5 has a self-applicable specializer for a small first-order
language). This example stops at the first projection and at
specialization as a tool.
