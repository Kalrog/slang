# Slang

A scripting language inspired by Lua and metalua. The virtual machine is
written in Go; the parser, compiler and most of the standard library are
written in slang itself and shipped as precompiled bytecode inside the
interpreter binary.

## Building and running

```sh
make build              # builds bin/slang from the committed seed in go/boot
bin/slang run file.slang [args...]
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
`go tool pprof`.

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
for([init(optional)]; [condition]; [update(optional)]){
    // body
}
// break leaves the innermost loop
```
### Functions
```slang
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
  local p = require("slang/parser")
  p.add_primitive_expression("one", p.keyword("one"):map(func(t){ return {token: t, ast: +{1}} }))
}
x = one                           // the change applies from the next statement on
```
A file is parsed one top-level statement at a time; an extension statement
takes effect for the statements after it, and a statement is always parsed
with a single grammar. The grammar is global: an extension loaded by one file
stays available to files compiled later.

Extensions can define their own extension statements (statements that change
the grammar, such as operator declarations): `p.add_extension_statement(name,
parser, apply)` registers a top-level-only statement; after it parsed,
`apply(result)` runs with grammar changes allowed and returns the statement to
emit, or `null`. See `extensions/custom_operators.slang`.

The parser API (`require("slang/parser")`) offers `add_statement`,
`add_primitive_expression`, `add_expression_group_before/after/at` and the
combinators `seq`, `choice`, `star`, `plus`, `optional`, `map`, `token`,
`keyword`, ... See `extensions/` for examples (switch statement, lambda
shorthand, custom infix/prefix/postfix operators, a grammar DSL).

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
tool/      oracle scripts comparing the self-hosted compiler with the legacy Dart one
legacy/    the original Dart implementation (bootstrap reference, not used by the Go toolchain)
```

## Ideas
- [ ] goroutine-based isolates with channels (see PLAN.md)
- [ ] bitwise operators
- [ ] static typing
- [ ] language server
