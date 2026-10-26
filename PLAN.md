# Slang port plan: Go VM + self-hosted compiler + goroutine threads

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done.

## Goals

1. Rewrite the VM in Go for speed.
2. Rewrite everything else (parser, AST tools, code generator, optimizer, standard library glue) in slang itself.
3. Threading: keep cooperative coroutines (`thread.create/resume/yield/state`) and implement them inside the VM (Lua style, one value stack per coroutine, no goroutines). Drop the preemptive model (`parallel`, `atomic`, `suspend`, `wake`, `spawn`, and the slang-level semaphore/channel/barrier). A Go-style concurrency model (isolates on goroutines with channels) is a later, separate project; see "Future".
4. Every other language feature keeps working. The existing `test/*_test.slang` suite is the acceptance oracle; `slang_thread_test.slang` is trimmed to its coroutine tests.
5. The Go toolchain replaces Dart completely at the end. Dart survives only as the stage-0 bootstrap compiler until the self-hosted compiler compiles itself.

Out of scope: static typing, language server, a register-based bytecode redesign (possible later, see "Future").

## Current architecture (what is being ported)

- Stack-based bytecode VM, 27 opcodes (`lib/src/vm/slang_vm_bytecode.dart`). Frames hold their own value stack. Native (Dart) functions use a continuation protocol so the VM can single-step.
- Tables are hybrid list + insertion-ordered map with metatables (`__index`, `__newindex`, `__type`), `meta` is a magic key. Structural equality.
- Closures with open/closed upvalues; `_ENV` is upvalue 0 of every chunk and is how `module{}` works (`vm.setUpvalue`).
- Compiler: petitparser PEG grammar, AST classes, constant-folding optimizer, `FunctionAssembler`/`PatternAssembler` codegen, `.slb` encoder.
- Metaprogramming: `+{}` quote to AST tables, `-{}` unquote executed at parse time, extensible parser (`slang/parser`: `add_statement`, `add_primitive_expression*`, `add_expression_group*`, combinators `seq/choice/star/...`, expression groups `prefix/postfix/left/right`).
- Threads: child VMs sharing globals; `resume/yield` cooperative; `parallel` steps threads round-robin; `atomic`, `suspend/wake`, `spawn`; semaphore/channel/barrier written in slang on top of those.
- Stdlib: std, package (`require` with loaders/search paths), vm, table, string, math, test, thread, parser. CLI: run, repl, test, compile.

## Target layout

```
go/                       Go module (module name: slang)
  cmd/slang/              CLI: run, repl, test, compile, disasm
  vm/                     values, tables, closures, protos, bytecode (.slb v2), interpreter, threads/scheduler, errors, native API
  stdlib/                 Go natives: core, io, math, string, vm, thread, peg helpers
  boot/                   embedded seed bytecode (*.slb) generated from slang/ (checked in)
slang/                    everything written in slang
  lib/                    std, package, table, test, string, thread, repl
  compiler/               peg, grammar, ast, optimizer, codegen, compiler, parser_lib (slang/parser compat API)
tool/                     stage-0 helpers (Dart compile-to-.slb) until bootstrap is complete
extensions/, test/        unchanged (plus new tests)
Makefile                  build, seed, reseed, test, bench
```

## Key design decisions

### Values
`Value` is a small struct `{kind, int64 payload, any pointer}`; ints and floats never allocate. Ints are 64-bit wrapping, floats are float64, exactly like Dart. Numeric semantics follow Dart: `int / int` yields a double, `%` is Euclidean (non-negative for a positive divisor), `==` compares int and double numerically, only `null` and `false` are falsy. `+` and `*` on strings behave like Dart (`"a"+"b"`, `"ab"*2`).

### Tables
Array part plus insertion-ordered hash part (so `keys`/`values`/`entries` and printing are deterministic, as in Dart), string keys in a dedicated map for speed. All quirks that programs can observe are kept: `meta` key, assigning `null` removes (and shifts the array part), `append` uses `len(t)` as the key, structural `==`.

### Native function API
`func(th *Thread, args []Value) (Value, error)`. Natives can call back into slang synchronously (`th.Call`), which runs a nested interpreter loop. The Dart continuation protocol disappears. Consequence (same rule as Lua 5.1): a coroutine can only `yield` from slang frames; yielding from inside a function that a native called (a metamethod, a `map` callback) is an error. `pcall` is implemented inside the interpreter rather than as a native, so yielding inside a protected call works.

### Errors
Slang errors are `{message, location: {origin, line, column}, stack}` tables (same shape as today plus `stack`). Runtime errors inside the VM are converted to the same shape, so `pcall` catches everything, and an uncaught error prints message, location and a slang stack trace.

### Bytecode
The existing stack-based instruction set is kept unchanged through the bootstrap. This is deliberate: it lets the self-hosted compiler be checked byte-for-byte against the Dart compiler on every test file before Dart is removed. The `.slb` container gets a v2 header (magic `SLANG`, version byte, 64-bit int constants, UTF-8 strings, little endian). After the bootstrap the ISA can evolve freely (reseeding procedure below).

### Coroutines (no goroutines for now)
Every coroutine is a `Thread` with its own value stack and frame list. `resume` drives the coroutine's interpreter loop from the resumer's native call until the coroutine yields or returns; `yield` suspends it and hands the value back; errors inside the coroutine propagate to the resumer. States: `init`, `running`, `suspended`, `dead`. The main chunk runs on a main thread that cannot yield. The old `thread` module keeps `create`, `resume`, `yield`, `state`, `current`, `id`; everything related to preemption is removed.

### Self-hosted compiler
- `slang/compiler/peg.slang`: a PEG combinator library reproducing the petitparser semantics the grammar and the extensions rely on (contexts, tokens with line/column, `trim`, lazy star, separated lists, `ref`/`resolve`, settable parsers, expression builder with precedence groups and loopback). Hot primitives (literal match at position, character class match, whitespace skipping) are tiny Go natives.
- `grammar.slang` is the slang grammar written with that library, including quote/unquote, keyword registry and the extensibility registry (statements, primitive levels, expression group levels, rebuild).
- AST nodes are plain slang tables (`{type:"BinOp", left, op, right, token}` with `meta.__type`), the same shape extensions already see. No conversion layer.
- `codegen.slang` ports `FunctionAssembler`, `PatternAssembler` and the generator visitor, producing a prototype table that the VM turns into a function (`vm.load_proto`). `.slb` encode/decode stays in Go because it is the VM's own container format.
- `compiler.slang` is the driver (`compile(source|ast, origin)`), owns unquote execution and the REPL mode, and exposes the `slang/parser` compatibility API so all existing extensions work unchanged.

### Bootstrap
1. Stage 0: Dart compiles `slang/**/*.slang` to `.slb` v2 (`legacy/tool/stage0.dart`).
2. The Go VM runs the stage-0 compiler; its output on every test file is diffed against Dart's output (byte identical).
3. The compiler compiles itself (seed'), then seed' compiles itself (seed''); seed' == seed'' is the fixed point. The seed is embedded into the Go binary (`go/boot`).
4. Reseeding after an ISA/format change: build with the current seed, compile the modified compiler sources to a new seed, switch the VM, verify the fixed point. `make reseed` scripts this.

### Strings
UTF-8 byte strings (Go and Lua convention); `len`/`substring` are byte based, with rune helpers added to `slang/string`. Dart used UTF-16 code units. Only non-ASCII text observes the difference.

## Phases

### Phase 1: Go VM core executes Dart-compiled bytecode `[x]`
- [x] `legacy/tool/stage0.dart`: compile `.slang` to `.slb` v2 with source locations.
- [x] `go/vm`: values, tables, closures/upvalues, protos, `.slb` v2 decoder/encoder, disassembler.
- [x] Interpreter loop with all 27 opcodes (+ `pow`), call/return/varargs, metatables (`__index`, `__newindex`, `__type`), `type`, `pcall`/`error` with locations and stack traces.
- [x] Coroutines: `thread.create/resume/yield/state/current/id` (yield works inside `pcall`, not across native calls).
- [x] Native API, core globals, modules `slang/vm`, `slang/os`, `slang/string`, `slang/math`, `slang/thread`.
- [x] slang-side libs compiled by stage 0 and embedded: `std` (module, run), `package` (require), `table`, `test`.
- [x] `go/cmd/slang run file.slb|file.slang` and the oracle (`make oracle`): 17 test files, 67 tests, identical output to Dart. Known difference: the new test "error inside thread propagates to resume" fails on Dart, which never marks a coroutine dead after an uncaught error.

### Phase 2: Remaining runtime pieces `[x]`
- [x] File I/O userdata (`open` + read/write/readBytes/writeBytes/close), `args`, `readLine`, `slang/os` helpers.
- [x] Trim `slang_thread_test.slang` to coroutine tests (plus two new coroutine tests).
- [ ] Remove the preemptive API from the README (Phase 6).

### Phase 3: Self-hosted compiler `[x]`
- [x] `peg.slang` (+ `test/peg_test.slang`, 15 tests) with Go helper natives in `slang/string`.
- [x] `grammar.slang`: full grammar, quote/unquote, keyword registry, extensibility registry; references resolve eagerly at registration like petitparser.
- [x] `ast.slang` (constructors, `to_string`, quote-to-table-literal, token attachment), `optimizer.slang`.
- [x] `codegen.slang`, `compiler.slang` (driver, unquote execution, REPL mode, `slang/parser` API).
- [x] `tool/ast_oracle.sh`: identical ASTs for every file. `tool/bytecode_oracle.sh`: byte-identical bytecode for every test, library and compiler file.
- [x] Full suite (89 tests) passes on Go from source; all extensions work.
- Bugs found in the Dart grammar and fixed there too: computed table keys need the colon (`{[k]: v}`), and word-like tokens (`not`, `and`, `or`, `local`, `let`, keywords) need a word boundary (`notify`, `localVar` were misparsed).

### Phase 4: Bootstrap, CLI, embedding `[x]`
- [x] Fixed point reached: the Dart-compiled seed, the self-compiled seed and the seed compiled by that seed are byte-identical (`make fixpoint`). Seed lives in `go/boot/slang/*.slb`; `make seed` regenerates it with the Go binary.
- [x] CLI complete: `run` (.slang and .slb), `test`, `repl`, `compile` (`-o`, `--origin`, `--strip`), `disasm`; errors print message, location and a slang stack trace.
- [x] Dart is no longer needed for anything (`legacy/tool/stage0.dart` and the oracle scripts remain only for cross-checking until the Dart code is deleted).

### Phase 5: Performance `[x]`
- [x] Benchmarks in `bench/` (`bench/run_all.sh`): dijkstra (from the old Dart speed test), fib, tables, strings, compile.
- [x] GC percent 400 by default (`GOGC` in the environment still wins); `SLANG_CPUPROFILE=file` writes a pprof profile.
- [x] Parser: Pratt-style expression walker with first-byte dispatch (same semantics as the nested combinators, verified by the AST oracle on every file), native whitespace/comment skipping, value-free fast parsing for `flatten`, native line/column lookup. Parsing the 838-line grammar source went from 165 ms to 80 ms.
- [x] Bytecode cache for files loaded through `require` and `slang run` (`~/.cache/slang`, `SLANG_CACHE_DIR`, `SLANG_NO_CACHE=1`); only files compiled with the unextended grammar and without compile-time execution are cached, so it never changes behaviour. Test suite: 0.32 s cold, 0.14 s warm.
- Numbers (M-series laptop): dijkstra x1000 305 ms (Dart: 2157 ms, 7x), full test suite 0.5 s (Dart: 4 s), fib(27) 33 ms, 300k method calls with allocation 370 ms. `bench/compile.slang` parses a frozen 1050-line copy of the grammar source (`bench/data/sample.slang`) in about 100 ms.
- Possible further VM work: table access (string-keyed map lookups dominate), call setup, allocation in `values()`/`keys()` iterators.

### Phase 6: Cleanup and docs `[ ]`
- [ ] Remove Dart sources and pubspec (after confirmation), update README (build, thread API, bootstrapping, string semantics), keep DESIGN.md notes.

## Decisions taken (2026-10-23)

- Threads: coroutines only, inside the VM, no goroutines. Preemptive API dropped.
- Strings: UTF-8 bytes.
- `int / int` always yields a double; the constant folder is fixed to match.
- `^` is implemented as power.
- Debugger: minimal (disassembler, `--trace`); the interactive stepper is not ported.
- Dart code is deleted at the end (git history keeps it); confirm before deleting.

## Compile-time execution model (decided and implemented 2026-10-23)

Problem: an unquote block could run twice when the parser backtracked across it, and a grammar change made by an unquote affected an ill-defined range of text (whatever the backtracking order happened to re-parse).

Rules now in force:
- A compilation unit is parsed one top-level statement at a time by a loop that only moves forward. Grammar changes are made by `extension "file"` / `extension { code }` statements, which exist only at that top level, run at compile time with changes allowed, and take effect from the next statement on. A statement is always parsed with one grammar, at every nesting level: the mutation functions (`add_*`, `keyword`, `reset`) are guarded by counters maintained by the loop (`parse_depth`, `statement_depth`, `extension_depth`), so neither unquotes nor parser callbacks nor nested `compile` calls can change the grammar while any statement is being parsed.
- Ordinary unquotes and parser actions (map callbacks) are pure with respect to the grammar: unquotes are executed once, memoized per parse position, and neither may change the grammar. Extensions that need grammar-changing statements (operator declarations in `extensions/custom_operators.slang`) register them with `p.add_extension_statement(name, parser, apply)`: the statement is recognised only by the top-level loop and `apply(result)` runs between statements with changes allowed.
- The grammar is global and changes in file compilation order (extensions loaded once stay available).
- Files whose compilation ran code at compile time are not bytecode-cached.
- Prior art considered: Racket phases and `#lang`, Honu, Raku's mutable lexically scoped grammar, Common Lisp `load`, Coq notations, camlp4 phrases, Template Haskell declaration groups, Rust proc-macro crate separation, metalua `-{extension}`.
- Possible later refinement: lexical scoping of extension statements inside blocks (Raku style).

## Example game and language additions (2026-10-23)

`examples/dungeon` is a dungeon crawler on Ebitengine: the Go host (`examples/dungeon/host`, the Go module is `examples/dungeon/go.mod` with `replace slang => ../../go`) only wraps the engine; the game, its engine modules and eight DSLs (sprite art baked at compile time, levels checked against declared tiles and entities, entity types, state machines with checked `goto`, dialogues as coroutines, loot tables with validated chances, event rules by pattern, `wait` scripts) are slang. Tests in `examples/dungeon/test`, `make dungeon`, `make dungeon-test`.

Added to the language for it:
- Operator metamethods: `__add __sub __mul __div __mod __pow __unm __eq __lt __le __call __tostring __len` (nested calls, cannot yield).
- Keywords are allowed as field names after `.` and `:` and as table keys, so DSL keywords never make a field unreachable (`g.name` rule in the grammar).
- `p.error_at(token, message)` and `p.origin()` in the parser API, `str.from_bytes(list)`.

## Future (not planned now)

- **Isolates on goroutines.** Discussed design: a thread is a separate VM instance (own globals, module cache, parser state) on its own goroutine; nothing is shared except channels; tables and closures are deep-copied when they cross a channel or `spawn`; prototypes, natives and strings are shared because they are immutable. Open points when this is picked up: fresh environment vs. snapshot of globals at spawn (slang is globals-by-default, so this matters), `freeze` for sharing immutable tables without copying, error delivery through `join`, exit semantics when the main chunk returns. A baton/GIL model was considered and rejected because it gives no multicore and keeps shared-state semantics that a Go-style model does not want.
- Register-based ISA, packrat memoization in peg, bytecode cache for `.slang` files.
