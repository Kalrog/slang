# The language

The [tour](../tour/) teaches slang by example. This page is the reference
behind it: the same ground in the same order, with the details the tour
leaves out.

## Variables and scope

```slang
local count = 1            // a local of the block it is declared in
{
  local count = 2          // an inner block may declare the name again
  print(count, "\n")       // 2
}
print(count, "\n")         // 1

Total = count + 1          // assigned without local: a global
global verbose = false     // a global declared on purpose
```

- Locals are lexical. A function sees the locals around it, and a block's
  locals end with the block. An inner scope may shadow a name; declaring a
  name twice in one scope is an error.
- A name assigned without `local` is a global. Globals start with an
  uppercase letter by convention: the language server and `slang highlight
  --check` warn about a lowercase one, which is usually a typo or a
  forgotten `local`. `global name = ...` (or `global func name(){ ... }`)
  declares a global whatever its name, and is an error where a local of
  that name is visible.
- Reading a name nothing has assigned gives `null`.

## Values

| type | literals | notes |
|---|---|---|
| `int` | `42`, `0xff`, `0b1010`, `0o17`, `1_000_000`, `'a'` | 64 bit; a character literal is the int of its character |
| `double` | `2.5`, `1e9` | |
| `string` | `"text"`, `"""several lines"""` | bytes, usually UTF-8; escapes `\n`, `\t`, `\xHH`, `\u{H...}` |
| `bool` | `true`, `false` | |
| `null` | `null` | a value like any other |
| `table` | `{1, 2}`, `{x: 1}` | the one data structure |
| `function` | `func(x) => x * 2` | closures |

`type(value)` gives the name in the first column, or the `__type` of a
table's metatable. Only `null` and `false` are falsy: `0` and `""` are
true. `len` of a string counts bytes; `slang/utf8` counts characters.

## Operators

| | |
|---|---|
| arithmetic | `+` `-` `*` `/` `%` `^` (power), unary `-` |
| comparison | `==` `!=` `<` `<=` `>` `>=` |
| logical | `and` `or` `not` |
| bitwise, on ints | `&` `\|` `~` (xor) `<<` `>>`, unary `~` (not) |

- `/` always gives a double (`7 / 2` is `3.5`); `to_int` truncates. `%` is
  never negative for a positive divisor.
- `+` also joins two strings, and `"ab" * 3` repeats one. `concat(a, b,
  ...)` joins values of any type into a string.
- Bitwise operators bind tighter than comparison and looser than
  arithmetic: `(a & mask) == 0` needs no parentheses, and `a + 1 << 2` is
  `(a + 1) << 2`. `>>` is arithmetic. Shifts by 64 or more give 0 (or -1
  for a negative value shifted right).
- `==` compares tables by their contents; `same(a, b)` tells whether they
  are one table. Strings do not order with `<`: use `str.compare` from
  `slang/string`.

## Control flow

```slang
local n = 7
if(n > 5){
  print("big\n")
} else if(n > 2){
  print("medium\n")
} else {
  print("small\n")
}

// if is an expression too
local size = if(n > 5){ "big" } else { "small" }

for(local i = 0; i < 3; i = i + 1){ print(i, " ") }   // init; condition; update
for(n > 0){ n = n - 1 }                               // condition only
for(let local v in values({1, 2, 3})){ print(v, " ") }   // an iterator

:rows: for(local r = 0; r < 3; r = r + 1){
  for(local c = 0; c < 3; c = c + 1){
    if(c > r){ continue rows }       // a label reaches an outer loop
    print(r, ",", c, " ")
  }
}
```

There is one loop, `for`. The init and update of the C form are optional
(`for(; i < 10; i = i + 1)`), and `for(true){ ... }` loops until a `break`.
`break` and `continue` apply to the innermost loop, or to the loop a label
names. `defer statement` runs the statement when the block it is in ends,
however it ends.

An iterator is a function that returns the next element each time it is
called, and the global `stop` when it is done (`null` is an element like
any other). `keys(t)`, `values(t)` and `entries(t)` make iterators over a
table; `entries` gives `{key, value}` pairs:

```slang
local func countdown(n){
  return func(){
    if(n == 0){ return stop }
    n = n - 1
    return n + 1
  }
}
for(let local n in countdown(3)){ print(n, " ") }        // 3 2 1
for(let {local k, local v} in entries({a: 1})){ print(k, "=", v, "\n") }
```

## Functions

```slang
func add(a, b){ return a + b }           // a global function
local func add2(a, b){ return a + b }    // a local one
local double = func(x) => x * 2          // a function value with an expression body

local func sum(...numbers){              // the rest parameter collects a list
  local total = 0
  for(let local n in values(numbers)){ total = total + n }
  return total
}
local list = {1, 2, 3}
sum(...list)                             // a list spread into the arguments
sum(0, ...list, 4)                       // anywhere, any number of times
local all = {0, ...list, last: true}     // in table literals too
```

- `return` without a value returns `null`. A missing argument is `null`.
- A rest parameter keeps every argument: `f(1, null, 3)` gives `{1, null,
  3}`, and `g(...numbers)` passes them on as they came.
- A call's `(` must be on the line where the function expression ends.

A block after a call is a function passed as its last argument, so
functions that take one read like statements:

```slang
local func twice(f){ f() f() }
twice{ print("hi ") }                    // twice(func(){ print("hi ") })

local calc = module{                     // module: the block's global functions, as a table
  func add(a, b){ return a + b }
  local func helper(){ }                 // not part of the module
}
local answer = run{ return 41 } + 1      // run: a block as an expression
```

## Tables

```slang
local list = {"apple", "pear"}           // a list, indexed from 0
append(list, "plum")
local point = {x: 1, y: 2}               // a record
point.z = 3
point["x"] = 10
local key = "dynamic"
local map = {[key]: true}                // a computed key
local mixed = {1, 2, name: "both"}       // list elements and named keys together
```

- A table's list is its elements 0, 1, 2, ... up to the first absent
  index. `len(t)` is its length, `count(t)` the number of all entries,
  named keys included.
- `null` is a value: `t.x = null` stores it and the key stays
  (`has(t, "x")` is true), and `{1, null, 3}` has length 3. Reading an
  absent key gives `null` as well; `has` tells the two apart.
- `delete(t, k)` takes a key out and nothing else. `remove(list, i)` takes
  an element out of a list and moves the later ones down.
- `keys`, `values` and `entries` iterate over the table as it is: a key
  added during the loop is visited, a deleted one is not. Iterate over a
  copy, `values({...t})`, to change the table freely.
- `slang/table` has `sort`, `map`, `filter`, `fold`, `slice`, `index_of`
  and more.

## Metatables

`t.@meta` is a table's metatable, the table that says how `t` behaves.
`__index` gives it defaults, which makes classes, and `a:f(x)` calls
`a.f(a, x)`:

```slang
local Vec = {}
local vec_meta = {
  __index: Vec,
  __type: "Vec",
  __add: func(a, b) => Vec.new(a.x + b.x, a.y + b.y),
  __eq: func(a, b) => a.x == b.x and a.y == b.y,
  __tostring: func(v) => concat("(", v.x, ", ", v.y, ")"),
  __get: {length: func(v) => (v.x * v.x + v.y * v.y) ^ 0.5},
}
func Vec.new(x, y){ return {x: x, y: y, @meta: vec_meta} }
func Vec.scale(v, k){ return Vec.new(v.x * k, v.y * k) }

local v = Vec.new(3, 4)
print(v + v:scale(2), " ", v.length, " ", type(v), "\n")   // (9, 12) 5.0 Vec
```

| metamethod | used for |
|---|---|
| `__index`, `__newindex` | reading and writing keys the table does not hold: a table or a function |
| `__get`, `__set` | properties: tables of getters and setters by key |
| `__add` `__sub` `__mul` `__div` `__mod` `__pow` `__unm` | arithmetic |
| `__band` `__bor` `__bxor` `__shl` `__shr` `__bnot` | bitwise operators |
| `__eq`, `__lt`, `__le` | comparison (`>` and `>=` are the negations of `<=` and `<`) |
| `__call` | calling the table |
| `__len`, `__tostring` | `len`, and `print`, `string`, `concat` |
| `__type` | the name `type()` gives and `'Type{...}` patterns check |
| `__match` | matching, see below |

Properties read and write like fields but run functions. They are looked
up for keys the object does not hold itself, before `__index`, and are
inherited along the `__index` chain; a key with a getter and no setter is
read-only. A key that holds `null` hides its metatable's `__index`, as any
key of its own does. An operator's metamethod is looked up on the left
operand first, then on the right one. Metamethods run as nested calls, so
they cannot yield.

## Pattern matching

`let pattern = value` matches a value against a pattern and binds the
names in it. As an expression it is a test; as a statement it raises when
the value does not match.

```slang
local patient = {name: "Ada", age: 36, tags: {"vip"}}

if(let {name: local name, age: 36} = patient){    // a test that binds name
  print(name, " is 36\n")
}
let {tags: {local first}} = patient               // a statement: binds or raises
let {map: local map, filter: local filter} = require("slang/table")

local limit = 36
print(let {age: ^limit} = patient, "\n")          // ^expr compares with a value
```

| pattern | matches |
|---|---|
| `local name` | anything but `null`, and binds it |
| `local name?` | anything, `null` included |
| `name` | the same, assigning an existing variable |
| `42`, `"text"`, `true` | that value |
| `^expr` | the value of the expression |
| `{a: P, b: Q}`, `{P, Q}` | a table whose fields or elements match |
| `'Type{...}` | a value whose `type()` is `Type`, then the table pattern |
| `'m`, `'m{...}`, `'m as P` | what the matcher `m` accepts, see below |

In a loop, `for(let pattern in iterator)` binds each element. An element
that does not match raises, as the statement does; `for(let? ...)` skips
it instead.

A matcher is a value whose metatable has `__match(self, value)`: `null`
means no match, anything else is what the rest of the pattern sees. Every
parser of `slang/peg` is one, and a library function can return one:

```slang
local func between(lo, hi){
  return {@meta: {__match: func(self, v){
    if(type(v) == "int" and v >= lo and v <= hi){ return v }
    return null
  }}}
}
print(let 'between(1, 10) = 5, "\n")              // true
```

## Errors

```slang
local os = require("slang/os")

local func load(path){
  if(path == ""){ raise(error.new(error.kinds.argument, "an empty path")) }
  return os.read_file(path)
}

try {
  print(load("/etc/missing"))
} catch({kind: ^error.kinds.not_found, path: local p}) {
  print("no file ", p, "\n")
} catch(local e) {
  print(e.kind, ": ", e.message, "\n")
  raise(e)                           // passes it on, keeping where it was raised
}

local config = try { load("config.json") } catch { "{}" }    // try is an expression
try { load("") } catch(local e) { raise(error.wrap(e, "loading the config")) }
```

- `raise(value)` raises any value. Errors are tables `{kind, message,
  cause?, location, stack, ...}`, made with `error.new(kind, message,
  fields?)`.
- `kind` is what a program catches on, from `error.kinds` (`not_found`,
  `argument`, `type`, `format`, `timeout`, ...). Reading a kind that is
  not listed raises, so a typo does not go unnoticed.
- `catch` clauses take patterns. The first one that matches handles the
  error; an error no clause matches goes on up.
- `error.wrap(e, message)` adds context and keeps the kind and the cause.
  `error.is(e, kind)` looks through causes, and `error.message(e)` joins
  the messages along them.
- An error nothing catches stops the program and prints `error (kind):
  message`, the source position and a stack trace.

## Modules

`require("name")` loads a module once and returns what its file returns.
The standard library is under `slang/` (`require("slang/json")`); other
names are files, looked up relative to the project. A project's
`slang.project` adds search paths, packages and other file types:
[Projects and packages](projects.md).

## Coroutines

```slang
local thread = require("slang/thread")
local co = thread.create(func(start){
  local v = thread.yield(start * 2)    // suspends; resume returns start * 2
  return v + 1                         // the last resume returns this
})
print(thread.resume(co, 10), "\n")     // 20
print(thread.resume(co, 5), "\n")      // 6
print(thread.state(co), "\n")          // dead
```

`yield` works from any slang function called inside the coroutine, inside
a `try` too, but not from a function that a native function called (a
metamethod, say). An error inside a coroutine is raised in the resumer,
and the coroutine is dead afterwards. `slang/async` builds futures,
streams and `await` on coroutines: [Async and the web](async.md).

## Isolates

Coroutines take turns on one thread. An isolate is a VM of its own on an
OS thread of its own, so isolates run in parallel. They share nothing and
talk through channels, which copy what is sent:

```slang
local isolate = require("slang/isolate")
local jobs = isolate.channel()
local results = isolate.channel()
local worker = isolate.spawn(func(jobs, results){
  local iso = require("slang/isolate")    // a VM of its own: it requires what it needs
  for(let local job in iso.each(jobs)){
    results:send(job.w * job.h)
  }
  return "done"
}, jobs, results)
jobs:send({w: 2, h: 3})          // copied into the worker's heap
jobs:close()
print(results:receive(), "\n")   // 6
print(worker:join(), "\n")       // done (or the worker's error, raised here)
```

- A function that crosses may use globals, not locals of the code around
  it. Tables cross with their cycles and metatables, functions as
  bytecode.
- Channels and isolate handles cross by reference, and so does
  `buffer.shared(type, n)`: memory every isolate reads and writes, with
  `b:lock(f)` for more than single elements.
- Channels can be bounded (`channel({capacity: 8})`), polled (`try_send`,
  `try_receive`) and awaited from the event loop (`async.receive(ch)`).
  `worker:kill()` stops an isolate at its next safe point.

`examples/isolates` renders a Mandelbrot set with one isolate per CPU.
