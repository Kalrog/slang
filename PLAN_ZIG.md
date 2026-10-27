# Slang port plan: Zig VM + `slang.h` extension API

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done.

## Why

Native extensions (modules that wrap a system library or need native speed) cannot be loaded at runtime in a reasonable way from Go: `plugin` does not work on Windows and needs an identical toolchain and dependency set, and cgo + dlopen forbids C from holding Go pointers and adds overhead on every callback. Today the only way to add natives is to build a custom Go host binary (`examples/dungeon/host`). The goal of this port is a VM where `require "foo"` can load `foo.so`/`foo.dylib`/`foo.dll`, written in C, Zig or anything with a C ABI.

## Goals

1. Rewrite the VM, the native standard library and the CLI in Zig. The Go VM is the reference until the Zig VM reaches parity, then it is deleted (after confirmation).
2. A public C API, `slang.h`, modelled on Lua's `lua.h`: a value stack per thread, index-based access, no exposed `Value` layout. It serves both native extensions and embedding the VM in a host program.
3. `require` loads native extensions from shared libraries.
4. Everything written in slang is unchanged: compiler, grammar, extensions, `slang/lib`. The seed bytecode (now `boot/slang/*.slb`) boots the Zig VM as is; no stage 0 is needed.
5. The `test/*_test.slang` suite is the acceptance oracle, plus differential runs against the Go binary.

Out of scope: the dungeon example (it stays on the Go VM until it is ported later, ideally as a native extension wrapping raylib or SDL instead of a custom host), changes to the language, ISA or `.slb` format, isolates/threads (see "Future" in PLAN.md).

## Target layout

```
zig/
  build.zig, build.zig.zon     pinned Zig version (minimum_zig_version), options: -Dgc-stress, -Dtrace
  include/slang.h              the public C API (the only header extensions need)
  src/
    vm/                        value, object/gc, string, table, proto, slb, disasm, interp, thread, error, meta
    api.zig                    implementation of slang.h on top of vm/
    stdlib/                    core, string, vm, thread (internal API); os, math, file (written against slang.h)
    loader.zig                 native extension loading (std.DynLib)
    main.zig                   CLI: run, repl, test, compile, disasm
boot/slang/*.slb               the seed, moved out of go/ and embedded by both VMs during the transition
extensions/native/             example native extensions (one in C, one in Zig) used by the tests
```

## Key design decisions

### Values
A 16-byte tagged union (`tag` + 8-byte payload: bool, i64, f64 bits or object pointer). The Go `Value` is 32 bytes (kind, int64 and a 16-byte interface), so this halves stack and table traffic. NaN-boxing to 8 bytes is a later optimisation; it stays possible because `slang.h` never exposes the layout. Numeric semantics are unchanged (64-bit wrapping ints, `int / int` is a double, Euclidean `%`, Dart-compatible number printing).

### Heap objects and GC
All heap objects (string, table, closure, upvalue, proto, userdata, thread) start with a common header (`next`, `kind`, `marked`) and are linked into one list. The collector is stop-the-world, non-moving mark and sweep with a gray stack; a collection runs when allocated bytes exceed a threshold (live heap times a growth factor, the equivalent of the current `GOGC=400`). Non-moving means natives may hold object pointers for the duration of a call.

Roots: globals, `__PACKAGES`, the registry (see API), every live thread (stack up to `top`, frame closures, open upvalues, the yielded value), the current error value, and the protos of loaded chunks. The Lua-style API makes native code safe by construction: everything a native touches lives on the thread's stack, which is a root.

`-Dgc-stress=true` collects on every allocation. The suite and the compiler fixed point must pass under it; running the compiler is the main stress test because it allocates heavily.

Userdata may have a finalizer (a C function pointer given at creation), run during sweep. This is needed for extensions that own C resources. A slang-level `__gc` metamethod and weak tables are not planned.

### Strings
Immutable heap objects holding UTF-8 bytes, length and a cached hash. Short strings (up to 40 bytes) are interned, so equality and string-keyed table lookup on them are pointer comparisons; long strings compare by content. Semantics are unchanged (byte-based `len`/`substring`).

### Tables
The same observable behaviour as the Go table: an array part for keys `0..n-1`, an insertion-ordered hash part (dense entry array plus an open-addressing index, tombstones for removed entries, compaction when they pile up), float keys with integral values normalised to ints, the `meta` key, assigning `null` removes (and shifts the array part), `append` uses `len(t)` as the key. Table and function keys hash by identity, as in Go, while `==` on tables stays structural.

### Errors
Inside the VM, a slang error is a Zig error (`error.SlangError`) with the error value (the `{message, location, stack}` table) stored on the thread. Stack overflow and internal faults become normal slang errors, so `panic`/`recover` has no counterpart. `pcall` stays special-cased in the interpreter so yields inside it keep working. Natives cannot yield (same rule as now).

### The C API (`slang.h`)
Shaped after Lua; the differences are deliberate.

- `slang_State *` is a thread. Natives have the type `int (*slang_CFunction)(slang_State *S)` and see their arguments at stack indices `1..n` (negative indices count from the top). A native returns `1` (result on top of the stack), `0` (null) or `SLANG_ERROR`. Slang functions return one value, so there is no multi-result count.
- **No longjmp.** `slang_error(S, ...)` sets the error value and returns `SLANG_ERROR`; a native does `return slang_error(S, "bad thing");`. `slang_call` returns a status, and on failure the native either handles the error or returns `SLANG_ERROR` to propagate it. This keeps Zig and C frames free of non-local jumps.
- Functions: push/to/is for null, bool, int, double, string (with length), table, function, userdata; `slang_type`, `slang_typename`; table access `get/set`, `get_field/set_field`, `get_index/set_index`, `raw_get/raw_set`, `len`, `append`, `next` style iteration; `get_global/set_global`; `slang_call`, `slang_pcall`; metatable get/set; `check_*`/`opt_*` argument helpers that produce the same messages as today (`Expected int for x got string`).
- **Registry and references.** `slang_ref(S)` pops a value and returns an integer handle that keeps it alive; `slang_get_ref`/`slang_unref` use and release it. This is how an extension stores a callback or a table beyond one call.
- **Userdata.** `slang_new_userdata(S, size, type_name, finalizer)` returns memory owned by the GC; `slang_check_userdata(S, idx, type_name)` returns it or raises a type error.
- **Closures with state.** `slang_push_cclosure(S, fn, n_upvalues)` with `slang_upvalue_index(i)`, so extensions can carry state without globals.
- **Module registration.** `slang_new_module(S, const slang_Reg funcs[])` builds a table of natives.
- **Embedding.** `slang_new()`, `slang_close()`, `slang_do_file()`, `slang_do_string()`, `slang_open_libs()`, so a host program (for example a later game host) uses the same header.
- **Versioning.** `SLANG_API_VERSION` in the header; the `SLANG_EXTENSION(name)` macro defines `slang_open_<name>` and exports the version the extension was built against, which the loader checks before calling it.

### Native extension loading
A fourth loader in `slang/package` (after preloaded, embedded and search path) looks for `<path>/<name>.<so|dylib|dll>` in `__PACKAGES.nativeSearchPaths`, opens it with `std.DynLib`, checks the API version and calls `slang_open_<name>` (with `/` and `-` mapped to `_`). The value it returns becomes the module, cached like any other.

Symbol resolution: extensions call `slang_*` functions that live in the `slang` executable, as with Lua. On Linux the executable is linked with `--export-dynamic`, on macOS extensions are built with `-undefined dynamic_lookup`. Windows needs an import library (or a `slang.dll` that the executable links against); that is deferred until the other two platforms work.

### Internal natives vs. the public API
`core`, `slang/string` (including the hot parser helpers `skip_space`, `class_run`, `line_col`), `slang/vm` and `slang/thread` use the internal Zig API for speed and because they reach VM internals. `slang/os`, `slang/math` and the file userdata are written against `slang.h`; they are the first test that the API is complete and comfortable.

### Zig version
Pin the latest stable release at the start in `build.zig.zon` and only upgrade deliberately, because Zig still breaks APIs between releases. Zig is not installed on the development machine yet.

## Phases

### Phase 0: Skeleton `[x]`
- [x] Zig 0.17.0 through anyzig (pinned in `build.zig.zon`); `zig/build.zig` with the CLI and test steps; `make zig`, `make zig-test`, `make zig-fixpoint`.
- [x] The seed stays in `go/boot/slang` while go/ exists (Go's embed cannot leave its module); the Zig build copies it into a generated `seed` module.

### Phase 1: Values, objects, `.slb` `[x]`
- [x] Value (16-byte tagged union), object header, strings (interned up to 40 bytes), tables, protos, closures, upvalues, userdata.
- [x] `.slb` v2 decoder/encoder and disassembler (output identical to Go).
- [x] Unit tests for tables and number formatting (`zig build test`).

### Phase 2: Interpreter `[x]`
- [x] All opcodes, calls, varargs, upvalues, `_ENV`, metatables and operator metamethods (`SLANG_TRACE=1` prints every instruction).
- [x] Errors with locations and stack traces, `pcall`, coroutines.
- [x] All natives (core, `slang/string`, `slang/vm`, `slang/thread`, `slang/os`, `slang/math`, files).
- [x] Boots the seed; the full test suite and the dungeon DSL tests give output identical to the Go binary.
- [x] `make zig-fixpoint`: the seed compiled by the Zig VM is byte-identical.
- Lesson: never write `slot = .{ .tag = f(slot) }`; Zig's result location sets the tag before evaluating `f(slot)`. Read into a local first.

### Phase 3: Garbage collector `[x]`
- [x] Mark and sweep at interpreter safe points, exact byte accounting through a counting allocator, threshold = 2x live (min 8 MB), `-Dgc-stress=true` collects every 64 KB.
- [x] Suite and fixed point pass under stress; peak memory on the benchmarks is one half to one third of Go's.

### Phase 4: `slang.h` and native extensions `[x]`
- [x] `zig/include/slang.h` implemented in `zig/src/capi.zig` (75 functions: stack, push/read, argument checks with `slang_failed`, errors without longjmp, tables with and without metamethods, `slang_next` iteration, globals, `slang_call`, userdata with finalizers, references, C closures with upvalues, modules, embedding with `slang_new/slang_dostring/slang_dofile`, version check).
- [x] Native loader: `vm.load_native` (`zig/src/loader.zig`) and a fourth loader in `slang/lib/package.slang` (reseeded; the Go VM still passes because `vm.load_native` is absent there). Search paths in `__PACKAGES.nativeSearchPaths`, files `<name>.<ext>` or `lib<name>.<ext>`, symbols `slang_ext_version_<name>` and `slang_open_<name>`.
- [x] Example extensions: `extensions/native/hello.c` (C, exercises every API area) and `extensions/native/vec.zig` (Zig through translate-c, userdata with operator metamethods), built as shared libraries by `zig build`; tests in `zig/test/native_test.slang` (`make zig-test`), passing in Debug, ReleaseSafe, ReleaseFast and under GC stress.
- [x] First real extension: `extensions/native/raylib.c` wraps raylib (system library, `-Draylib=false` to skip); `examples/breakout` is a breakout game on it (`make breakout`; `BREAKOUT_FRAMES`/`BREAKOUT_AUTOPLAY` for an unattended run). `SLANG_NATIVE_PATH` adds directories to `__PACKAGES.nativeSearchPaths`.
- Decided against rewriting `slang/os` and `slang/math` through the API: the C example covers more of the API than those modules would, and the internal natives stay faster.
- Lessons: optimised builds dead-strip unreferenced `export fn`s even with `rdynamic`; `link_gc_sections = false` keeps them (extensions then resolved `slang_*` to null and jumped to address 0). `@cImport` is gone in 0.17; Zig extensions import the header through `b.addTranslateC`. Negative stack indices must be resolved before popping (`slang_setmetatable`).

### Phase 5: CLI parity `[x]`
- [x] `run` (with `--explain`), `repl`, `test`, `compile` (`-o`, `--origin`, `--strip`), `disasm`, `SLANG_TRACE`.
- [x] Bytecode cache: implemented in slang (`compiler.load_file`), so it works unchanged; both VMs produce identical bytecode, sharing the cache is harmless.
- Found: `File.writer` is positional in 0.17, so a redirected stdout/stderr was rewritten from offset 0 at every flush; the VM uses the streaming writers/readers now.

### Phase 6: Performance `[x]`
- [x] `make zig` builds ReleaseFast (`make zig-safe` the checked build; `make zig-test` runs the suite on both, `-Dgc-stress=true` as before).
- [x] Tables up to 8 hash entries have no index: a linear scan over interned keys (pointer comparison) beats hashing, and a record costs two allocations instead of four. `concat` renders scalars into stack buffers and allocates the result once (`print` writes pieces straight to stdout); results longer than the intern limit are never interned.
- [x] The interpreter keeps the stack top and base pointer in locals, written back around calls out (natives, metamethods, collector, errors, trace), and dispatches with a labelled switch: every opcode fetches the next instruction and `continue :sw`s to its case.
- The `SLANG_TRACE` check sat in every opcode; measured at about 3% on fib when removed outright, and the loop is now instantiated twice from a comptime `trace` parameter (fib 21 -> 18.7 ms, parse 44 -> 42.5 ms: more than the removal alone, from the tighter cases).
- Tried and dropped: writing the frame pc back only at call-out sites (no measurable change; the per-instruction store stays).
- Numbers (min of 3, ms; Go VM for comparison):

  | benchmark | Go | Zig ReleaseSafe before | Zig ReleaseFast after |
  |---|---|---|---|
  | fib(27) | 32 | 31 | 19 |
  | dijkstra x1000 | 302 | 310 | 215 |
  | tables | 350 | 521 | 167 |
  | strings | 31 | 88 | 23 |
  | parse sample.slang | 72 | 70 | 42 |

- Not done: NaN-boxing (16-byte values stay). Every benchmark is 1.4 to 2x ahead of the Go VM; the next step would be a register-based bytecode, which is a compiler change.

### Phase 7: Switch-over `[x]`
- [x] 2026-10-27: the Zig VM is the implementation. `make build` installs `bin/slang` and `lib/` from `zig/`; `make test`, `seed`, `fixpoint`, `bench`, `breakout`, `dungeon-test` use it. The seed moved to `boot/slang` (the Zig build copies it into its generated module; `make go-build` copies it into `go/boot/slang`, since Go's embed cannot leave the module). `require` of a native module also looks in `lib/` next to the binary's `bin/` directory.
- [x] Decided to keep `go/` (reference VM, `make go-build/go-test/go-fixpoint`) and `legacy/` (Dart) for history rather than deleting them; the project is not public. The dungeon window host still runs on the Go VM until it is ported to `slang.h`.

## Open points
- Windows support for native extensions (import library vs. `slang.dll`); Linux needs a test run (`-rdynamic` export, `.so` loading).
- Whether userdata should get a slang-level `__gc`.
- Iteration API shape (`slang_next` like Lua vs. an index-based cursor that matches insertion order).
