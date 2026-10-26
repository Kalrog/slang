# Slang

A scripting language inspired by Lua and metalua. The virtual machine is
written in Go; the parser, compiler and most of the standard library are
written in slang itself and shipped as precompiled bytecode inside the
interpreter binary.

## Building and running

```sh
make build              # builds bin/slang from the committed seed in go/boot
bin/slang run file.slang [args...]
bin/slang run --explain file.slang   # also prints the project file, the units and their extensions
bin/slang test       # runs every *test.slang file in ./test
bin/slang repl
bin/slang compile file.slang [-o out.slb] [--strip]
bin/slang disasm file.slb
```

Requirements: Go 1.26 or newer. Nothing else.

### Self-hosting

`slang/compiler/*.slang` is the compiler, `slang/lib/*.slang` the slang part
of the standard library. Both are compiled by the interpreter itself:

```sh
make seed       # recompiles slang/ into go/boot and rebuilds the binary
make fixpoint   # checks that the seed reproduces itself byte for byte
make test
```

After changing the compiler, run `make seed` twice (the first seed is compiled
by the old compiler, the second by the new one) and then `make fixpoint`.

`SLANG_CPUPROFILE=out.prof bin/slang run x.slang` writes a CPU profile for
`go tool pprof`; `SLANG_CALLPROFILE=1` prints the most called slang functions
at exit.

Files loaded with `require` or `slang run` are cached as bytecode in
`~/.cache/slang` (override with `SLANG_CACHE_DIR`, disable with
`SLANG_NO_CACHE=1`). Only files that compile with the standard grammar and run
no code at compile time are cached, so the cache never changes behaviour.

## Syntax
### Variables
```slang
// are automatically declared when assigned to
a = 1
b = 2
// are global by default
if (true) {
    c = 3
}
print(a, b, c) // 1 2 3
// can be declared as local
if (true) {
    local d = 4
    print(d) // 4
}
print(d) // null
```
### Types
```slang
// integers (64 bit)
a = 1
// doubles
b = 1.0
// strings (UTF-8 byte strings)
c = "hello"
// booleans
d = true
// null
e = null
// tables
f = {a: 1, b: 2, 3, 4}
// functions
g = func() {
    print("hello")
}
```
### Operators
```slang
// arithmetic
+ - * / % ^
// comparison
== != < > <= >=
// logical
and or not
```
`/` always produces a double (`7 / 2 == 3.5`), `%` is never negative for a
positive divisor, `^` is exponentiation. `+` concatenates two strings and
`"ab" * 3` repeats a string. Only `null` and `false` are falsy.

### Control Flow
```slang
// if
if (true) {
    print("true")
} else if (false) {
    print("false")
} else {
    print("else")
}

// for
for(i = 0; i < 10; i = i + 1) {
    print(i)
}
//but also
run = true
for(run){
    print("running")
}
// and
local i = len(list)
for(i >= 0; i = i - 1){
    print(list[i])
}
for([init]; condition; [update]){   // init and update are optional:
    // body                          // for(; i < 10; i = i + 1), for(i < 10)
}
// break leaves the innermost loop
```
### Functions
```slang
// return without a value returns null
func check(x) {
    if (x == null) { return }
    print(x)
}
// normal
func add(a, b) {
    return a + b
}
// anonymous (normal is actually just a shorthand for this)
add = func(a, b) {
    return a + b
}
// expression body
add = func(a, b) => a + b
// varargs
func add(a, b, ...more) {
    sum = a + b
    for(i = 0; i < len(more); i = i + 1) {
        sum = sum + more[i]
    }
    return sum
}
```
### Tables
```slang
// can be used as arrays
a = {1, 2, 3}
print(a[0]) // 1
// can be used as maps
b = {a: 1, b: 2}
print(b["a"]) // 1
// keys can be computed
c = {[concat("a", "b")]: 1}
// can be used as structures
c = {a: 1, b: 2}
print(c.a) // 1
// have a special element called "meta" which can be used to define operators on the table
vector = {}
func vector.add(a, b) {
    return {x: a.x + b.x, y: a.y + b.y}
}
a = {x: 1, y: 2}
a.meta = {__index: vector}
b = {x: 3, y: 4}
a.add(a, b)
// special shorthand for functions whose first argument is the table they are inside of
// think of it as a method
a:add(b)
// this will be very familiar to lua users
```
The metatable understands `__index` (table or function), `__newindex` (table
or function) and `__type` (a string or a function, used by `type()` and by
`'Type{...}` patterns). Assigning `null` to a key removes it. Tables compare
structurally with `==`.

Operators can be overloaded through the metatable as well:
```slang
local Vec = {}
local vec_meta = {
    __index: Vec,
    __type: "Vec",
    __add: func(a, b) => Vec.new(a.x + b.x, a.y + b.y),
    __mul: func(a, b) => Vec.new(a.x * b, a.y * b),
    __unm: func(a) => Vec.new(-a.x, -a.y),
    __eq: func(a, b) => a.x == b.x and a.y == b.y,
    __tostring: func(a) => concat("(", a.x, ", ", a.y, ")"),
}
func Vec.new(x, y) { return {x: x, y: y, meta: vec_meta} }
Vec.meta = {__call: func(self, x, y) => Vec.new(x, y)}   // Vec(1, 2)
print(Vec(1, 2) + Vec(3, 4) * 2)                         // (7, 10)
```
`__add`, `__sub`, `__mul`, `__div`, `__mod` and `__pow` are consulted when the
built-in operation does not apply (the left operand's metatable first, then
the right one's). `__unm` handles unary minus, `__lt` and `__le` the
comparisons (`>` and `>=` are the negations of `<=` and `<`), `__eq` is used
when both operands are tables, `__call` makes a table callable, `__tostring`
is used by `print`, `string`, `concat` and `error`, and `__len` by `len`.
Metamethods run as nested calls, so they cannot yield.

### Pattern Matching
```slang
// matches a value against a pattern
patient = {name: "John", age: 30}
print(let {name: "John"} = patient) // true
// can assign value from the pattern to variables
if (let {name: name, age: 30} = patient) {
    print("the 30 year old patient is called", name)
}
// can be used in for loops
patients = {{name: "John", age: 30}, {name: "Jane", age: 40}}
for(let {name: local name, age: local age} in values(patients)) {
    print(name, "is", age, "years old")
}
// loops stop when they encounter a value that does not match the pattern
// a type can be matched with 'Type{...}, a nullable binding with name?
```
### Passing Functions as arguments
```slang
// if the function is the last argument passed and takes no arguments there is a special syntax for this
run{
    ... //do something
}
// is the same as
run(func(){
  ... //do something
})

// module, allows you to declare global functions in a block and capture them in a table (called a module)
calc = module{
    func add(a,b){
        return a + b
    }
    local func private(){
        print("this function is not visible in the calc module")
    }
}
// run allows you to treat a block of statements as an expression
a = run{
    return a
} + 1
```

### Coroutines
```slang
local thread = require("slang/thread")
local co = thread.create(func(start){
    local v = thread.yield(start * 2) // suspends; resume returns 2*start
    return v + 1                      // the final resume returns this
})
print(thread.resume(co, 10)) // 20
print(thread.resume(co, 5))  // 6
print(thread.state(co))      // dead
```
`yield` works from any slang function called inside the coroutine, including
inside `pcall`, but not from inside a function that was called by a native
function (for example a metamethod). An error inside a coroutine is raised
in the resumer, and the coroutine is dead afterwards.

### Errors
```slang
local r = pcall(func(a, b){ return a / b }, 1, 0)   // {"ok", value} or {"err", e}
if (let {"err", local e} = pcall(error, "boom")) {
    print(e.message, e.location.origin, e.location.line, e.stack)
}
```
Uncaught errors stop the program and print the message, the source position
and a stack trace.

### Metaprogramming
```slang
local ast = +{expr: 1 + 2}      // quote: the AST as a table ('BinOp{...})
local stat = +{stat: local x = -{ast}}  // unquote inside a quote splices a value
-{block: print("runs at compile time")}  // unquote at top level runs while parsing
compile("return 1 + 1")()        // compile source or an AST table to a function
```
An unquote runs once, when the parser first reaches it, and the code it
returns is spliced in its place. It may compute anything, but it may not
change the grammar.

Grammar changes are made by **extension statements**, which are only allowed
at the top level of a file (or of a `compile`d string):
```slang
extension "extensions/switch"     // runs the file at compile time
extension {                       // runs the block at compile time
  local g = require("slang/compiler").grammar()
  g:expression():primary("one", g:keyword("one"):map(func(t){ return {token: t, ast: +{1}} }))
}
x = one                           // the change applies from the next statement on
```
A file is parsed one top-level statement at a time; an extension statement
takes effect for the statements after it, and a statement is always parsed
with a single grammar. Grammar changes are **scoped to the unit** (a file or
a `compile`d string): they end with it, and a file is always compiled with
the root grammar, so a module means the same wherever it is required from.
A string compiled from an unquote is part of its file and sees the file's
extensions. Keywords introduced by extensions are reserved as variable names
but stay usable as field names (`t.switch`, `t:switch()`, `{switch: 1}`).

Global changes are explicit. `extension global "file"` (or `extension global
{ ... }`) in the main file, before its other extension statements, changes
the root grammar for every unit compiled afterwards; changes made at run
time through `require("slang/compiler").grammar()` do the same. The usual
place for them is the **project file**: `slang.project`, next to the main
file or in a directory above it, a slang table literal:
```slang
{
  extensions: {"extensions/custom_operators"},        // ambient: loaded into every unit
  dialects: {
    [".json"]: {compile: "extensions/json"},          // require("config") loads config.json
    [".hx"]: {extensions: {"ext/html_templates"}},    // .hx files are slang plus these extensions
  },
  search_paths: {"src"},                               // relative to the project file
  warnings: {["extensions/custom_operators"]: false},  // or false: grammar warnings off
}
```
A dialect is either a list of extensions the file is compiled with, or a
module exporting `compile(source, origin)` that returns a function (see
`extensions/json.slang`); `require` tries `name.slang` and then every dialect
suffix. `slang run --explain file` prints the project file, the ambient
extensions and dialects, and for every unit compiled under extensions the
extensions in effect and the rules they modified. `examples/project` is a
small project using both.

An extension file runs once per unit that loads it (it is a script, not a
module), with `require("slang/compiler").grammar()` returning the grammar of
that unit; an extension that depends on another loads it with
`require("slang/compiler").load_extension(name)`. Compile-time state that
later units must see (declared names, say) belongs in a module the extension
requires, since modules are loaded once.

An extension gets the grammar it extends with `require("slang/compiler").grammar()`
and builds parsers with the combinators of `require("slang/peg")` (`seq`,
`choice`, `star`, `plus`, `optional`, `map`, `token`, `ref`, ...). The grammar
object offers:

- `g:token(text)` and `g:keyword(word)` (a keyword is reserved); `g:rule(name)`
  refers to any rule of the grammar (`"expr"`, `"statement"`, `"block"`,
  `"chunk"`, `"identifier"`, `"slang_pattern"`, `"table_literal"`, ...).
- `g:statement(name, parser)`: a statement; the parser yields a node or
  `{token, ast}`. `g:extension_statement(name, parser, apply)`: a statement
  that is only recognised at the top level; after it parsed, `apply(result, g)`
  runs with grammar changes allowed, with `g` the grammar of the unit being
  parsed (not necessarily the one the extension was loaded into: a project
  loads an extension once), and returns the statement to emit, or `null`
  (see `extensions/custom_operators.slang`).
- `g:expression()`: the expression registry. `:primary(name, parser,
  {after, before})` adds a primary expression, `:level(name, {after, before})`
  a precedence level (tightest first; core has `indexAndCall`, `power`,
  `unary`, `multiply`, `add`, `compare`, `and`, `or`), and a level takes
  `:prefix(op, func(op, operand))`, `:postfix(op, func(left, op))`,
  `:left(op, func(left, op, right))`, `:right(...)` and `:wrapper(open,
  close, func(open, value, close))`. `:levels()` and `:primaries()` list the
  names. `g:walker()` gives an extension an expression walker of its own
  (`peg.walker`), for DSLs with their own operators.
- `g:define(name, parser)` adds a rule, `g:modify(name, func(old){ ... })`
  replaces one by a parser built from the current one (the rules that make
  metaprogramming work, quote, unquote and the extension statement, are
  protected), `g:rules()` lists every rule with the extensions that changed
  it. Changes are sealed lazily: the first parse after a change rebuilds the
  expression walker and the dispatch tables once. `SLANG_GRAMMAR_WARNINGS=1`
  (or `--explain`) reports rules modified by more than one extension,
  modifications that can never match their second alternative, and rules
  that stop parsing their probe snippet.
- `g:derive()` is a copy that changes independently (the unit grammars are
  derived from the root this way), `g:root()` the root grammar, `g:unit()`
  the grammar of the unit being parsed, `g:extensions()` the extensions
  loaded into the grammar.
- `g:error_at(token, message...)` raises a compile error at a token,
  `g:origin()` is the name of the source being compiled, `g:uniq_id()` an
  identifier no program can write.

See `extensions/` for examples (switch statement, lambda shorthand, custom
infix/prefix/postfix operators, a grammar DSL, the JSON dialect) and
`examples/dungeon/dsl` for larger ones. The plan for the rest of this work
(memoization placement, tooling) is in `PLAN_GRAMMAR.md`.

## Standard library
Globals: `print`, `args`, `readLine`, `open` (files with `read`, `write`,
`readBytes`, `writeBytes`, `close`), `assert`, `error`, `raise`, `pcall`, `compile`,
`require`, `type`, `len`, `append`, `remove`, `keys`, `values`, `entries`,
`concat`, `set_raw`, `get_raw`, `to_int`, `string`, `module`, `run`.

Modules (`require("slang/...")`): `table` (contains, map, filter, fold,
dequeue), `string` (join, substring, split, trim, replace, index_of,
starts_with, ends_with, byte_at, char_at, chr, upper, lower, to_number, ...),
`math`, `os` (exists, read_file, write_file, list_dir, getenv, cwd, exit,
clock, time_ms), `thread` (coroutines), `vm` (upvalue access, bytecode
loading), `parser`, `test` (group/test/setup/teardown/run), `compiler`.

## Repository layout
```
go/        the VM (go/vm), native library functions (go/stdlib), the CLI and the embedded seed
slang/     the compiler (slang/compiler) and library code (slang/lib) written in slang
test/      the test suite (bin/slang test)
bench/     benchmarks (bench/run_all.sh)
extensions/ parser extensions written in slang
examples/  example programs; examples/dungeon is a game on Ebitengine whose content is written in DSLs
tool/      oracle scripts comparing the self-hosted compiler with the legacy Dart one
legacy/    the original Dart implementation (bootstrap reference, not used by the Go toolchain)
```

## Embedding

The VM is a Go library: `vm.New()`, `stdlib.Open`, `stdlib.Boot`, then
`Register`/`Preload` natives and `Call` slang functions. `examples/dungeon/host`
is a complete host program (about 300 lines) that runs a game written in
slang on Ebitengine; `make dungeon` starts it.

## Ideas
- [ ] goroutine-based isolates with channels (see PLAN.md)
- [ ] bitwise operators
- [ ] static typing
- [ ] language server
