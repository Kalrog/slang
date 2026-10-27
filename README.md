# Slang

A scripting language inspired by Lua and metalua. The virtual machine is
written in Zig and exposes a Lua-style C API for native extensions; the
parser, compiler and most of the standard library are written in slang
itself and shipped as precompiled bytecode inside the interpreter binary.

## Building and running

```sh
make build              # bin/slang (ReleaseFast) and lib/ (the native extensions)
bin/slang run file.slang [args...]
bin/slang run --explain file.slang   # also prints the project file, the units and their extensions
bin/slang test       # runs every *test.slang file in ./test
bin/slang repl
bin/slang compile file.slang [-o out.slb] [--strip]
bin/slang disasm file.slb
```

`make install` copies the binary and the extensions to `/usr/local/bin/slang`
and `/usr/local/lib/slang/` (`make install PREFIX=~/.local` for a user
install; `make uninstall` removes them).

Requirements: Zig 0.17 (`brew install anyzig` picks the version pinned in
`zig/build.zig.zon`). raylib for the breakout example (`brew install raylib`,
or `-Draylib=false`). Nothing else.

`make test` runs the slang suite, the native extension tests and the Zig
unit tests; `make test-safe` runs the suites on the checked build and under
GC stress (`zig/zig-out-safe`, `zig/zig-out-stress`); `make bench` runs
`bench/`.

### Self-hosting

`slang/compiler/*.slang` is the compiler, `slang/lib/*.slang` the slang part
of the standard library. Both are compiled by the interpreter itself into the
seed bytecode in `boot/slang`, which the binary embeds:

```sh
make seed       # recompiles slang/ into boot/slang and rebuilds the binary
make fixpoint   # checks that the seed reproduces itself byte for byte
make test
```

After changing the compiler, run `make seed` twice (the first seed is compiled
by the old compiler, the second by the new one) and then `make fixpoint`.

`SLANG_TRACE=1` prints every instruction to stderr; `SLANG_GRAMMAR_WARNINGS=1`
reports grammar conflicts (see Metaprogramming). On macOS,
`sample <pid>` on a longer-running copy of a benchmark is a usable profiler.

Files loaded with `require` or `slang run` are cached as bytecode in
`~/.cache/slang` (override with `SLANG_CACHE_DIR`, disable with
`SLANG_NO_CACHE=1`). Only files that compile with the standard grammar and run
no code at compile time are cached, so the cache never changes behaviour.

### Native extensions

`zig/include/slang.h` is a Lua-style stack API for extensions written in C
(or Zig, or anything with a C ABI): `extensions/native/hello.c` exercises
every part of it, `extensions/native/vec.zig` defines a userdata type with
operator metamethods, `extensions/native/raylib.c` wraps raylib for
`examples/breakout`, `extensions/native/uv.c` wraps libuv (`brew install
libuv`, or `-Dlibuv=false`). `zig build` compiles them into `lib/`, and
`require("raylib")` loads `raylib.dylib` (or `.so`) from `lib/` next to the
binary, the current directory, or the directories in `SLANG_NATIVE_PATH`.
Natives signal errors by returning `SLANG_ERROR`, never by longjmp.

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
// arithmetic: + - * / % ^ (power), unary -
// comparison: == != < <= > >=, logical: and or not
// bitwise on integers: & | ~ (xor) << >> (arithmetic), unary ~ (not); they bind
// tighter than comparison and looser than arithmetic: (a & mask) == 0 needs no
// parentheses, a + 1 << 2 is (a + 1) << 2. Shifts by 64 or more give 0 (or -1
// for a negative value shifted right); a float with an integral value converts.
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
### Spread
```slang
local func sum(...numbers){ ... }        // the rest parameter collects a list
local args = {1, 2, 3}
sum(...args)                             // a list spread into the arguments
sum(0, ...args, 4)                       // anywhere in the argument list, any number of times
obj:method(...args)
local all = {0, ...args, last: true}     // in table literals too: the spread table's
                                         // entries (array part and keys) are copied in
local copy = {...args}
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
  that stop parsing their probe snippet. Sealing also places memoization: a
  rule (or the parser it was modified from) that leads several alternatives
  of one choice is memoized per position for the duration of a top-level
  statement, so `choice(seq(old, tail), old)` parses `old` once; `--explain`
  lists the placements, `SLANG_NO_MEMO=1` turns them off. A wrapper of a
  rule built at seal time (`expr`, `statement`) runs at seal time, so create
  the tokens it uses before calling `modify`.
- `g:derive()` is a copy that changes independently (the unit grammars are
  derived from the root this way), `g:root()` the root grammar, `g:unit()`
  the grammar of the unit being parsed, `g:extensions()` the extensions
  loaded into the grammar.
- Token categories: `g:token(source, name, category)` and `peg.token(child,
  category)` tag tokens for highlighting. Core uses `keyword`, `identifier`,
  `number`, `string`, `comment`, `operator`, `punctuation`; an extension may
  use any standard LSP token type (`namespace`, `type`, `class`, `enum`,
  `interface`, `struct`, `typeParameter`, `parameter`, `property`,
  `enumMember`, `event`, `function`, `method`, `macro`, `modifier`,
  `regexp`, `decorator`) with modifiers after dots
  (`enumMember.declaration`); `extensions/enum.slang` shows it.
  `g:tag(g:rule("identifier"), "function.declaration")` recolours what a
  rule produced without changing its value.
- `g:error_at(token, message...)` raises a compile error at a token,
  `g:origin()` is the name of the source being compiled, `g:uniq_id()` an
  identifier no program can write.

See `extensions/` for examples (switch statement, lambda shorthand, custom
infix/prefix/postfix operators, a grammar DSL, the JSON dialect) and
`examples/dungeon/dsl` for larger ones. The plan for the rest of this work
(memoization placement, tooling) is in `PLAN_GRAMMAR.md`.

## Async, libuv and HTTP

`require("uv")` is the libuv binding in callback style (timers, TCP,
`uv.run()`); `slang/async` builds Futures, Streams and `await` on coroutines
on top of it; `extensions/async` adds the syntax; `slang/http` is an HTTP/1.1
server and client. `examples/webserver` puts them together:

```slang
extension "extensions/async"
local http = require("slang/http")
local a = require("slang/async")
a.main(func(){
  local s = http.serve("127.0.0.1", 8080, async func(req){
    await a.sleep(100)                       // does not block other requests
    return concat("hello from ", req.path)   // or {status, headers, body}
  })
  await s.done
})
```

`async func` bodies run as coroutines; `await` takes a Future (or raises its
error); `await for(let local x in stream)` loops over a Stream. Callbacks
stay available everywhere (`f:then(...)`, `stream:listen(...)`, the `uv`
module itself). `PLAN_UV.md` has the design.

## Editor support

`lsp/` is a language server written in slang (over the `uv` extension) that
highlights files with the parser itself, so extensions and dialects are
coloured as they are parsed, and reports parse errors; `slang highlight
file` prints the same tokens as JSON. `editors/vscode` is the VS Code
extension: a generated TextMate grammar for the core language plus the
server's semantic tokens in trusted workspaces (`make vscode` builds the
`.vsix`). `PLAN_LSP.md` has the design.

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
zig/       the VM (zig/src/vm), native library functions (zig/src/stdlib), the CLI, slang.h
boot/      the seed bytecode (slang/ compiled by itself), embedded by the binary
slang/     the compiler (slang/compiler) and library code (slang/lib) written in slang
test/      the test suite (bin/slang test)
bench/     benchmarks (make bench)
extensions/ parser extensions written in slang; extensions/native are native ones
examples/  example programs: examples/breakout on raylib, examples/project (slang.project),
           examples/dungeon, a game whose content is written in DSLs (its window host is the legacy Go one)
lsp/       the language server (highlighting and diagnostics from the real parser); editors/vscode is its VS Code client
go/        the Go VM: the reference implementation during the Zig port, kept for comparison
           (make go-build, go-test, go-fixpoint); it cannot load native extensions
legacy/    the original Dart implementation and the oracle scripts in tool/, kept for history
```

## Embedding

`slang.h` also embeds: `slang_new`, `slang_dostring`, `slang_dofile`,
registering natives and calling slang functions through the same stack API
the extensions use. `examples/dungeon/host` is a host program for the Go VM
(Ebitengine); its port to the C API is still to do, so `make dungeon` uses
the Go VM.

## Ideas
- [ ] goroutine-based isolates with channels (see PLAN.md)
- [ ] bitwise operators
- [ ] static typing
- [ ] language server
