# slang 1.0

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done, `[-]` dropped.
Decided 2026-10-29.

Goal: a language people can pick up for real work: one that ships as
single binaries, shares code through built-in package management, handles
errors well, talks TLS, has the everyday tools (formatter, docs,
debugger), and makes a compatibility promise. PLAN_WEB.md is done up to
its "later" items; this plan builds on it.

The order matters: language changes come before the standard library is
reworked for them, and both come before the 1.0 freeze. The binary
builder is independent and comes early, because it is useful at once and
its machinery (static archives of the extensions) is what packages with
native code will need.

## Decisions to make first

These shape later phases; each gets a short design note in this file
before work starts.

- **What slang is for.** Open since 2026-10-29, and above all the others.
  slang began as a toy and a language workbench (metalua's idea: the
  grammar is a library), and this plan pulls it toward a general-purpose
  language with packages, binaries and compatibility promises. That is a
  maintenance commitment: users, bug reports, a stable 1.x. The
  alternative is a curiosity for people in the know, where extensibility
  is the point and stability is not promised. The leaning right now is
  the second. If that holds, much of this plan changes weight: the
  compatibility promises and editions (phase 10) relax or go, packages
  and binaries stay because they make experiments shareable, and the
  semantic extension layer below becomes the interesting work rather
  than a risk. Settle this before phase 10, and ideally before phase 4.
- **How deep extensions go.** Grammar extensions cannot add types,
  because types need a pass over the program after it is parsed. One
  answer is to keep types out of extensions (phase 7 as written: core
  annotations, used by docs and the language server). The other is to
  make the semantic layer extensible too, which other languages have
  done:
  - Racket: Typed Racket is a library that checks the expanded program at
    compile time, with Deep, Shallow and Optional modes (strict to
    loose typing as choices, like the gradual-versus-strict extensions
    imagined for slang).
  - Lean 4: syntax, elaboration and editor information are all
    extensible, and extensions store their own data in compiled `.olean`
    files ("environment extensions"), which is how later modules and the
    editor see facts from compiled dependencies.
  - Pluggable type systems (Bracha, 2004) and Java's Checker Framework:
    optional checkers chosen per program, which never change what the
    program does at run time.
  - mypy plugins, Kotlin compiler plugins, Dart's analyzer plugins and
    builders: libraries shipping checker or editor support for the
    semantics their APIs imply.

  What slang would need for it, and what to watch:
  - A core semantic API that extensions build on: scopes and name
    resolution, stable node identities, facts attached to nodes,
    diagnostics. The language server needs it anyway (go to definition,
    rename, find references), so it is useful with one type system or
    none. A first piece exists since 2026-10-30: `slang/symbols` records
    the names codegen resolves (definitions, uses, fields) and the
    language server follows values through them (PLAN_DOC.md); facts on
    nodes and extension hooks are not there yet.
  - Per-extension data in `.slb` files: a map from extension name (and
    version) to bytes, written at compile time and read by the compiler
    and the language server for compiled dependencies.
  - Extensions in the language server: diagnostics, hover and completion
    hooks, possibly shipped as separate packages next to a library (as
    Dart pairs packages with builders). They run on every keystroke, so
    they must be incremental or cancellable, and they run package code
    in the editor, as grammar extensions already do.
  - Composition: grammar extensions compose fairly well, semantic passes
    less so (two type systems can disagree about one node). Lean uses
    priorities and attributes; Racket mostly one language per module.
  - Code generation hooks: `defer` showed the edge of rewriting at the
    AST level. Function-scoped defer works as a rewrite (at the cost of a
    closure and a pcall per call); block-scoped defer, zero-cost defer,
    and a compile-time "defer outside a function" error need an extension
    to add a node type with its own code generation, or a pass after
    parsing.
  - Check-only versus transforming: extensions that only check are safe
    to combine and to turn off (Bracha's rule); ones that change the
    generated code (Kotlin's Compose) are more powerful and more fragile.
  - The ecosystem: if the core owns the annotation syntax and a shared
    representation of types, and extensions differ in how strictly they
    check, typed libraries stay usable from each other. Truly different
    systems (units, ownership, nullness) then layer on as extra checkers.
  - The risk: slang as a language workbench (Racket, JetBrains MPS) is
    great for experimenting and hard for one coherent ecosystem. That
    risk mostly disappears if slang is the curiosity of the first point.
- **C interop, how far.** The long-term goal is to be at least as good as
  Python, whose C interop is a large part of its success. Python has
  several layers: the C API (`Python.h`; slang has its counterpart in
  `slang.h`), compiled binding tools (Cython; pybind11 and nanobind for
  C++; PyO3 for Rust), runtime FFIs (ctypes; cffi, whose ABI mode needs
  no compiler), prebuilt per-platform binaries in packages (wheels, the
  reason `pip install numpy` compiles nothing), and the buffer protocol
  (memory shared with C without copying). slang's equivalents, smallest
  and most useful first:
  - binding helpers in Zig: `comptime` turns a plain Zig function into
    its slang wrapper (slang's pybind11; `extensions/native/vec.zig`
    shows the starting point);
  - a mutable byte buffer or typed-array type with a C API to borrow its
    memory, so large data is not copied between slang and C;
  - prebuilt per-platform binaries in packages (phase 4), which also
    keeps slang's tools from compiling C;
  - the runtime FFI: C declarations parsed from text (a subset of C, a
    good fit for slang's peg library, perhaps a `c{ ... }` extension),
    calls through libffi, staged as scalars and opaque pointers, then
    structs and arrays, then callbacks;
  - later, a binding generator that reads real headers offline with
    clang or `zig translate-c`.

  The hard parts of the FFI are memory layout, ownership and lifetimes
  (who frees what, keeping slang values alive while C holds them),
  constants from `#define`, callbacks on other threads (the VM is
  single-threaded), and that a wrong declaration crashes the process.
  Python's lesson to keep: its C API exposes interpreter internals, which
  made CPython hard to change (HPy is the attempt to fix it); slang's
  handle-and-stack API avoids that as long as it stays so.

- **Conditional expressions.** Decided and built: the if-expression.
  `match` is still open.
- **The method call colon.** `{obj:method()}` in a table literal is the
  field `obj: method()`. Options: another method operator (`obj->m()`,
  `obj::m()`), a whitespace rule (`{k: v}` needs the space, `obj:m()` must
  not have one), or keeping `:` and warning about the ambiguous form.
  The warning comes in phase 1 whatever is decided; the decision is due
  before the freeze.
- **Labels.** Decided and built: `:outer: for(...)`, with `break outer`
  and `continue outer`.
- **Errors.** Decided 2026-10-29: try/catch, with `raise` as the mechanism,
  because errors as values pay off mostly with type annotations, and the
  standard library fixes how errors are reported more firmly than any
  grammar extension can. Built in phase 1. Errors as values, Swift-style
  `throws` marking, or failure metadata in the library (so a typing
  extension could present errors as values) can come later; phase 2
  was rewritten for this decision (2026-10-30).
- **Type annotations.** Their syntax (reserved in the core grammar, ignored
  at run time) and where the types live for documentation and the
  language server.

## Phase 1: language fixes

- [x] `continue`, and labeled `break` and `continue` (2026-10-29): a loop
      is labeled `:name: for(...)`, and `break name` / `continue name`
      reach it from nested loops. Leaving loops this way runs the defers
      and ends the trys in between and closes the upvalues of the blocks
      left (each iteration's closures keep their values). Fixed with it: a
      break out of a for-in skipped the pop of the iterator, leaving one
      stack slot behind per break.
- [x] `defer` in the core (2026-10-29), block-scoped like Zig's and
      Swift's: the rest of the block becomes a protected region; the
      cleanup is emitted inline at its end, at every return and break
      that leaves it (compiled with the names visible at the defer), and
      in a handler that runs it and raises again. Last in, first out; no
      cost on the normal path. (An earlier Go-style `extensions/defer`
      showed the limits of AST rewriting and was removed.)
- [x] try/catch (2026-10-29): `try { } catch(pattern) { } ...` with the
      existing patterns; the first matching clause runs, none raises the
      value again, `catch { }` takes everything. Handler records in the VM
      (try_begin, try_end, throw): return and break leave a try cleanly,
      errors from any depth and from natives are caught, coroutines and
      await work inside.
- [x] Conditional expression: `if(c){ a } else if(d){ b } else { c }` as
      an expression (2026-10-29); else is required, the braces hold one
      expression.
- [ ] `match` (switch) as an expression and a statement, on the existing
      pattern machinery, with exhaustiveness left to the type checker.
      (`extensions/switch` gives a switch statement as an extension; the
      core form is still open.)
- [x] Same-line continuations (2026-10-29): a call's `(` and a block
      argument's `{` must be on the line where the expression they continue
      ends, so `f(x)` followed by `{ ... }` on the next line is a call and a
      block (Kotlin's rule); method chains and operators still continue
      across lines. No existing code changed meaning (all 153 expandable
      files expand identically).
- [ ] A compile warning for `{name:call(...)}` in table literals, until the
      method syntax is settled.
- [x] Errors keep their data (2026-10-29): `raise` of a table passes that
      table through pcall and catch, with location and stack added when it
      has none (a re-raise keeps the first); other values still become
      error tables.
- [ ] String comparison with `<`, `<=`, `>`, `>=` (byte-wise, like
      `str.compare`).
- [ ] Smaller papercuts met on the way (list kept here), such as the
      `x and null or y` idiom, which the conditional expression replaces.

## Phase 2: error handling

Rewritten 2026-10-30 after the decision above. The first version of this
phase planned errors as values (an `Error` type, `try expr` returning it
from the enclosing function, `raise` as a panic); that was not chosen.
Errors are raised and caught: `try`/`catch` with patterns, `defer`, and
raised tables that keep their data (all built in phase 1). What is left
is making the errors the library raises consistent.

- [~] Raised errors carry data: a raised table keeps its fields through
      `pcall` and `catch`, with location and stack added (done); the
      shape the library uses is not settled yet.
- [ ] Conventions written down: the fields of a library error (`message`
      always, `kind` for what a program can catch on, the original error
      as `cause`), when to raise and when to return null, how to wrap.
- [ ] The standard library brought to them module by module (os, file,
      json, sqlite, http, web, crypto, ...), so `catch({kind: "not_found"})`
      style handling works everywhere.
- [ ] The examples reviewed with it, as the test of whether it reads well.
- Errors as values, Swift-style `throws` marking, or failure metadata a
  typing extension could present as values remain possible later, on top
  of this (see "Errors" in the decisions).

## Phase 3: single binaries (`slang build`)

`slang build` turns a project into one executable that runs without slang
installed. It compiles slang (to bytecode) and links; it never compiles
C. Native code arrives as static archives (`.a`) built by whoever owns
it: slang's own extensions come prebuilt with slang, a package's come
from its author or from the user.

- [ ] The runtime as a static archive (`libslang.a`, with `main`), shipped
      with slang.
- [ ] The extensions as static archives too (`lib/*.a` next to the
      `.dylib`s): uv, sqlite, crypto, llhttp, zlib, webview. Their
      third-party libraries are linked from static archives where the
      system has them; the build documents what it needs.
- [ ] Statically linked extensions found without a generated table: the
      runtime looks up `slang_ext_<name>` in its own executable before it
      searches for shared libraries; the link exports those symbols and
      keeps whole archives (`-force_load` / `--whole-archive`).
- [ ] The program's bytecode embedded at link time as a data section
      (`-sectcreate` on macOS, an `ld -r -b binary` object on Linux): the
      bundle holds every module the program requires, found by following
      `require` from the entry point; a `require` of a computed name is
      reported, and `slang.project` can list extra modules.
- [ ] `slang build [entry] -o name`, with `build: {...}` in `slang.project`
      for the extensions to link, extra modules, static files to embed,
      and the linker to use (the system `cc`, or `zig cc` for other
      targets when the archives for that target exist).
- [ ] Embedded files: `slang/assets` reads files bundled into the binary,
      so a web app's static folder ships inside it; `app:static` takes an
      embedded folder.
- [ ] Examples: the web server and the desktop app as single binaries; the
      desktop app as a `.app` bundle.

## Phase 4: packages

Built into the `slang` command, Go and Dart style, decentralized at
first: a package is a git repository with semver tags, no registry
needed.

- [x] The manifest is `slang.project`: `name`, `version`, `dependencies:
      {name: {git: url, version: "^1.2"}}`, next to `extensions` and
      dialects. (2026-10-30) Also `{path: "../dir"}` for working on two
      packages at once (not allowed in a package fetched with git). A
      package's name is the one in its own slang.project; a dependency must
      use it, so a name means one package everywhere in a program.
- [x] `slang get`, `slang update`, `slang deps`: resolution by minimal
      version selection (Go's: reproducible, no solver), a lockfile
      (`slang.lock`) with exact versions and content hashes, a cache in
      `~/.slang/pkg/<name>@<version>`, offline use from the cache.
      (2026-10-30, `slang/pkg`) Versions are git tags `vX.Y.Z`; "^1.2" is
      a minimum within major 1 (within 0.2 below 1.0). The lock's versions
      raise the minimums, so `get` keeps them; `update [name...]` takes
      the newest within the major. git runs through the new `os.exec`, a
      mirror per repository under the cache's `.mirrors`; a file in the
      cache that differs from the lock's hash is an error. The lock is a
      slang table literal like slang.project.
- [x] `require("name/module")` resolves through the dependency named
      `name`; two versions of one package never mix in a program.
      (`require("name")` is its init.slang; a project with a name requires
      itself the same way.)
- [x] Each package compiles under its own `slang.project`: its grammar
      extensions apply to it only and never leak into its users (a
      package may export extensions for its users to declare). A
      package's grammar is plain slang (snapshotted before the program's
      ambient layer) plus its own extensions and dialects; the compiler
      picks the project of a file by the package directory holding it.
- [x] No install scripts. Compiling a package runs its grammar
      extensions (like Rust's procedural macros); that is stated plainly,
      and the lockfile hashes pin exactly what runs.
- [ ] Later: `slang get name@version` adding a dependency to
      slang.project, a `slang.lock` check in CI (`slang get --check`),
      private repositories beyond what git's own credentials give, and the
      language server's project index reaching into packages.
- [ ] Native code in packages: a package declares its extension's static
      archives per platform (prebuilt by its author, or built by the user
      with the package's own build instructions); `slang build` links
      them; slang itself compiles no C.
- [ ] Later: a registry and package index (pub.dev style) over the same
      git repositories, with documentation from `slang doc`.

## Phase 5: TLS

- [x] TLS over OpenSSL's libssl on libuv TCP (memory BIOs): client first
      (`http.fetch("https://...")`, `ws.connect` with wss), certificate
      verification against the system trust store on by default, SNI.
      (2026-10-30) The `tls` extension is the engine only (no I/O);
      `slang/tls` wraps a uv.tcp handle in a connection with the same
      methods, so async, http and ws use it unchanged. Host names and IP
      addresses are verified; `ca` trusts a server's own certificate,
      `verify: false` turns checking off; ALPN; `tls.self_signed` for
      development and tests. The client also sends `User-Agent: slang`.
- [x] Server side as well (a certificate and key in `http.serve`
      options), for when there is no proxy in front: `tls: {cert, key}`
      (or `cert_file`, `key_file`) in the options of `http.serve` and
      `app:listen`; `req.secure`.
      Client certificates: a server context with `verify` and `ca` asks
      for one.
- [ ] Later: session resumption; the macOS Keychain as a trust store (now
      OpenSSL's own bundle, or the first system bundle found).
- [ ] TLS in single binaries (OpenSSL linked statically).

## Phase 6: tools

- [x] `slang fmt`: an opinionated 80-column formatter built on parser
      layers (a lossless tree, a format layer), extension syntax included
      (2026-10-30; the repository is formatted with it). See PLAN_FORMAT.md.
- [x] The language server's formatting and format on save in VS Code
      (2026-10-30, PLAN_FORMAT.md phase 6).
- [x] `slang doc`: API documentation from the comment conventions the
      libraries already follow, as HTML and in the language server's
      hover. (2026-10-30) With go to definition and find references in the
      language server, on one analysis (`slang/symbols`, names resolved by
      codegen). See PLAN_DOC.md.
- [ ] A debugger: breakpoints, stepping, locals and coroutines through
      the Debug Adapter Protocol (VS Code), on hooks in the VM.
- [x] A profiler: `slang run --profile out.folded` (or `SLANG_PROFILE=out.folded`
      for any command). A timer thread counts milliseconds; the interpreter's
      hooked loop (the one tracing uses, so normal runs pay nothing) samples
      the stack where ticks are pending, natives before their frame is popped.
      Folded stacks for speedscope and flame graph tools, plus a self/total
      summary on stderr. Functions carry their names in the bytecode (.slb
      version 3; version 2 is still read): `seq_list/func (slang/peg:410)`.
      First finding: parsing spends its time in the combinators themselves
      (seq, trim's trivia, rule references, failure recording, tokens), not in
      the grammar's callbacks; see the native PEG executor below.
- [x] Parser speedups in core slang, found with the profiler (2026-10-30,
      about 30% off parsing): keywords and punctuation as one fused parser
      with native calls, token line and column computed on first read, no
      failure recorded for missing trivia.
- [ ] Parsers without the formatter's cost: the format marks wrap shared
      parsers (rule references) in layer wrappers that every normal parse
      runs through (about 2%); only parses that build a tree need them.
- [ ] A native PEG executor, as an optional extension. `slang/peg` stays as
      it is (the API, the parser objects, first sets, memo placement,
      layers and the lossless tree all in slang); at seal time the
      extension compiles the parser graph into a program for a small PEG
      machine in Zig (as LPeg does): string, pattern, seq, choice, star,
      optional, pick, token, trim and the first-byte dispatch natively,
      calling back into slang for map functions, where predicates, custom
      parsers and the walker's callbacks. Normal parses only at first;
      parses that build a tree keep the slang path.
      Slang tries to load it by default and works the same without it, so a
      port of slang to another language (a new VM) never has to build the
      native parser; with it, parsing is faster. Checked like the speedups
      above: the AST, highlighting and formatting of every repository file
      the same with and without it, and the whole test suite in both modes.
      What it can gain: the profile of a parse is now seq 13.5%, literal
      tokens 10%, rule references 6%, choice 5%, the walker 5%; the
      grammar's callbacks (AST building) are a few percent.
- [ ] A playground: the VM built for WebAssembly, a page that compiles and
      runs slang in the browser.

## Phase 7: types

Annotations in the core grammar, ignored at run time: `func f(x: int,
items: list<string>) -> string`, `local n: int`, table shapes. A
semantic pass after the AST is built, which grammar extensions cannot
provide today, so it belongs with the language server and the doc
format.

- [ ] The annotation syntax, reserved and parsed (no meaning yet).
- [ ] Types in `slang doc` and in the language server's hover and
      completion. (Hover, definitions, references and `slang doc` exist
      without types since 2026-10-30, with a type section per `__type`;
      completion does not exist yet.)
- [ ] Types for the standard library.
- [ ] Later (after 1.0 if needed): `slang check`, a gradual checker; then
      exhaustiveness for `match`.

## Phase 8: the standard library

- [ ] Unicode text: code point iteration, lengths, case mapping,
      normalization where cheap (`slang/string` stays byte-based).
- [ ] `slang/path`, command-line arguments (`slang/cli`), `slang/log`
      (levels, structured fields).
- [ ] Time zones in `slang/time` (the system's zone database).
- [ ] The libraries reviewed for consistent naming and errors (with
      phase 2).

## Phase 9: platforms and concurrency

- [ ] Linux: the extensions, the tests, the single binaries.
- [ ] Windows: the same; the window extension on WebView2, and on
      WebKitGTK for Linux.
- [ ] Isolates (Dart style): separate VMs on separate threads that share
      nothing and exchange messages, for real parallelism without making
      the VM thread-safe.

## Phase 10: 1.0

- [ ] The decisions above made and implemented; deprecated APIs removed.
- [ ] Written compatibility promises: the language within 1.x, the
      bytecode format (a version in every `.slb`), the C API
      (`SLANG_API_VERSION`, append-only like the uv C API).
- [ ] Editions for later syntax changes: a project states its edition in
      `slang.project`, so a change in the grammar does not break existing
      code.
- [ ] Documentation: a tour, a language reference, the library
      reference from `slang doc`, a guide for native extensions.
- [ ] Releases: versioned downloads for macOS and Linux (Windows when
      phase 9 gets there), with the static archives for `slang build`.

## After 1.0

- An FFI: calling C functions from slang without writing C (declared
  signatures, libffi or generated stubs). Large, and best designed once
  the error conventions (phase 2) and types exist.
- The type checker beyond hover and docs, if phase 7 stops short of it.
- HTTP/2, Postgres, brotli (the "later" items of PLAN_WEB.md).
- A package registry, if git-based packages prove too little.
