# Grammar plan: an extensible parser built from a small kernel

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done.

Decisions from the design discussion on 2026-10-26. The VM side is in
`PLAN_ZIG.md`; this plan only concerns `slang/compiler/*` and the tooling
built on it.

## Why

Extensions today can add statements, primitive expressions and operator
groups, but cannot modify what exists; the grammar is one global object that
changes in file compilation order; the expression walker is hand-built; and
every registration rebuilds the whole walker. The goal is a parser where
slang's own syntax is an ordinary extension on top of a small fixed kernel, so
that modification, scoping, dialects and tooling all follow from one set of
rules instead of special cases.

## Goals

1. **Kernel/core split.** Only the kernel is hard-coded; slang's syntax (core)
   is written against the public extension API and could be replaced.
2. **Modification, not only addition.** Named, late-bound rules that
   extensions can wrap or replace, with provenance.
3. **Lexical scoping by default.** A file's grammar changes end with the file.
   Global changes are explicit and live in the project file.
4. **Dialects.** A file suffix selects a grammar (or a custom compile
   function), so `require` can load `.hxslang` templates or `.json` data.
5. **One optimisation step.** Derived tables (dispatch, analyses, memo
   placement) are rebuilt lazily once per change set, never per registration.
6. **Tooling without arbitrary code.** Token categories and an exportable
   grammar give syntax highlighting without executing project code; semantic
   tokens come from the compiler in a restricted VM.

Behaviour of every existing program must be preserved: the AST oracle and the
bytecode fixed point are the acceptance tests for the refactoring phases.

## Non-goals (this round)

- An extensible AST or codegen. Everything lowers to the core AST; a custom
  `compile` for a dialect returns a value or a function, nothing new for the
  VM.
- A separate lexer. The parser stays scannerless so dialects can define their
  own tokens.
- Automatic prefix factoring across semantic actions (memoization covers the
  cost without changing meaning).
- Incremental parsing for editors.

## Architecture

### The kernel

Fixed, not modifiable by any extension (the *protected set*):

- **Phrase loop** (`compiler.slang`): a unit is a forward-only sequence of
  top-level statements, each parsed under one sealed grammar; grammar changes
  happen only between phrases. The depth counters (`parse_depth`,
  `statement_depth`, `extension_depth`) stay as the guard. On entering a unit
  the loop derives a child grammar; on leaving it the parent is restored.
- **`extension` statement** and the **extension-statement registry** (the
  escape hatch always parses).
- **Quote and unquote** (`+{}`, `-{}`), memoized per position as today.
- **Token primitive and trivia hook**: `tok(text, category)` and the
  `trivia` rule every token skips through. Trivia is replaceable (comments are
  an extension of it); the hook is not. The **keyword registry** (reserving a
  word changes the identifier parser everywhere).
- **Rule registry** (below) and the **expression walker implementation**
  (the class; no configuration of it is kernel).
- **Core AST constructors** (`ast.slang`) and codegen.

### Core: slang's syntax as extension zero

`slang/compiler/core.slang` (the current `grammar.slang`, restructured)
registers literals, operators, `if`/`for`/`func`, patterns, table literals,
blocks and the statement set through the public API only, in one module. It is
loaded first into every grammar. Rule: core may not use anything an external
extension could not; the seed must still compile itself this way.

### Rule registry

```slang
g.define(name, parser, {protected: false, probe: "if (x) { }"})
g.rule(name)                      // a late-bound reference, resolved at parse time
g.modify(name, func(old){ ... })  // the single mutation primitive
g.rules()                         // names with provenance: {core, "ext/a", "ext/b"}
```

- References resolve through the *current* grammar at parse time, so a
  modification is seen by every user of the rule.
- `modify` refuses protected names; everything else is allowed. Replacing is
  just not calling `old`. The registry records the chain of modifiers per
  rule; `--explain` prints it, and modifying a rule that another extension
  already modified is reported.
- An optional `probe` snippet per rule is parsed after a modification; if it
  no longer parses, a warning names the extension (catches accidental
  clobbering without forbidding intentional replacement).
- Lint: `modify` detects the shape `choice(old, seq(old, ...))`, which never
  reaches its second alternative under ordered choice, and points at the
  factored form `seq(old, tail:optional())`.

### Registries with dispatch

Statements, final statements, extension statements, expression primitives and
operator groups are *registries*: ordered entries with names, and the sealed
grammar builds a first-byte dispatch table for each from the entries' derived
first sets (`info_of`, as the expression builder does today). Extensions add,
remove or replace entries by name and get dispatch without knowing about it.
The statement registry gains this; today it is a flat `choice`.

### Expression walker

Pratt walker, kept, with instances and a two-level API.

```slang
local w = g.expression()          // the default walker
local w2 = g.walker()             // a fresh one for a DSL
local w3 = w:derive()             // slang expressions plus/minus something

// engine level: binding powers, full control
w:infix("|>", {lbp: 25, rbp: 26}, func(w, left, tok){ ... })
w:prefix("-", {rbp: 90}, func(w, tok){ ... })

// extension level: named levels, partially ordered; numbers are assigned at seal
w:level("pipe", {below: "comparison", above: "additive"})
w:left("|>", "pipe", func(left, right, tok){ ... })     // lbp = p, rbp = p + 1
w:right("**", "power", ...)                             // rbp = p
w:postfix("?", "call", ...)
w:primary(parser)                                       // a nud that is a parser
w:parse(min_bp)                                         // callable from any nud/led
```

- The walker is a parser (`g.rule("expr")` is `w:parse(0)`), and a nud/led may
  be a parser or a function receiving the walker, so combinators and the
  walker nest both ways.
- Callbacks parse their own operands with `w:parse(rbp)` (ternaries, calls,
  indexing and DSL operand syntax are ordinary entries).
- Levels replace raw precedence numbers in the extension API; two extensions
  that place a level "between comparison and additive" coexist. Numbers exist
  only at the engine level.

### Sealing (the optimisation step)

Any mutation marks the grammar dirty; the first parse after that seals it.
Nothing to call, no slow path. `g.seal()` exists for tooling. A sealed
grammar holds:

1. analyses: first sets, nullability, left-recursion check (an error, not a
   hang) for every rule;
2. dispatch tables for every registry and for choices over many alternatives;
3. the resolved tree: `ref`s resolved to direct parsers, trivial wrappers
   folded (the registry is the source of truth, the sealed tree a compiled
   artifact);
4. memoization placement: a rule is memoized only where it can be parsed twice
   at one position (a prefix of several alternatives of one choice, or the
   `old` in a wrapped rule). Memo lifetime is one top-level statement. No
   full packrat.

### Scoping and layering

Grammar is a value with cheap derivation (copy-on-write registries). For a
file the grammar is built as: base kernel → core → ambient extensions (project
file) → the dialect of the file's suffix → the file's own `extension`
statements. Each layer derives from the previous; an extension is always
compiled with the grammar built so far (no self-dependence). File-local
changes end with the file.

### Project file and dialects

`slang.project` next to (or above) the main file, parsed with the base grammar
only, evaluated once before any unit:

```slang
{
  extensions: {"ext/custom_operators", "ext/switch"},   // ambient, in order
  dialects: {
    ".hxslang": {extensions: {"ext/html_templates"}},
    ".json":    {compile: "ext/json"},                   // module exporting compile(source, origin)
  },
  search_paths: {"src", "vendor"},
}
```

- Paths resolve relative to the project file; `slang run --explain` prints the
  project file and the ambient extensions used for each unit.
- A dialect is `{extensions}` (compile slang under that grammar) or
  `{compile}` (any loader; `require` returns its result). `require` searches
  `<name><suffix>` for every registered suffix in order.
- In-code global loading (`extension global "..."`) is allowed only at the top
  level of the main unit and is the exception, not the default.
- Bytecode cache key = file content + project file + contents of every
  ambient/dialect extension. Files under a stable modified grammar become
  cacheable; files with other compile-time execution stay excluded.

### Tooling

- **Token categories**: `tok(text, category)`; defaults derived from the rule
  (identifier, number, string, operator, comment, keyword). Core and
  extensions alike get highlighting by writing the grammar.
- **Syntax export** (`slang syntax-export`): serialises each dialect's sealed
  grammar minus actions to `.slang/syntax/<dialect>.json`, checked in. A
  highlighter runs a small PEG interpreter over it with no VM: no code
  execution. Parser callbacks that make parse decisions degrade to "accept";
  an extension may register a hand-written highlight grammar as a fallback.
- **Semantic tokens**: codegen records the class of every resolved name
  (local, parameter, upvalue, global) by token position. Extension semantics
  need no extra work: their lowering attaches the user's tokens to the core
  AST nodes, and resolution follows. Requires compiling, so it runs in a
  capability-restricted VM (no `slang/os`, no native extensions) after
  workspace trust. `slang highlight file` prints both tiers as JSON; an LSP
  server speaking semantic tokens comes after.

## Phases

### Phase 1: Rule registry with late binding `[x]`
- [x] `define/rule/modify/rules`, provenance, protected set, probes, the
      `choice(old, seq(old, ...))` lint (warnings behind `SLANG_GRAMMAR_WARNINGS`).
- [x] Grammar derivation (`derive`), dirty flag, lazy sealing; `seal()`
      rebuilds the walker, the dispatch tables and the rule targets once.
      Rule references are shared by a lineage and follow the activated grammar.
- [x] Statement and extension-statement registries on dispatch tables.
- [x] Every slang file in the repository compiles to byte-identical bytecode;
      fixed point unchanged; parse benchmark at parity (the expression walker
      now exposes its first set, which also prunes statement attempts at block ends).
- Lesson: a reference created while the grammar is being sealed (inside a
  group's `add` function) had no target during the first-set analysis and
  silently disabled pruning for the call postfix (+12% parse time). Rule
  references now resolve through the sealed table during analysis.
  `SLANG_CALLPROFILE=1` (call counts per function, Go VM) found it.

### Phase 2: Expression walker `[x]`
- [x] `peg.walker(skip)`: instances and `derive`; level API (`level(name,
      {after, before})`, `primary/prefix/postfix/left/right/wrapper`); engine
      API (`nud(op, rbp, f)`, `led(op, lbp, f)` with callbacks that parse
      their operands through `w:parse_at`); `binding_powers()`; the walker is
      a parser and parsers are primaries. `g:walker()` / `p.walker()`.
- [x] The old group API is a shim over the walker; binding powers per level
      (base + 3 postfix and prefix operand, + 2 right, + 0 left) reproduce the
      nested-group semantics exactly.
- [x] Every file byte-identical, fixed point unchanged; parsing 26% faster
      (94 -> 70 ms on `bench/compile.slang`) since one nud/led loop replaces
      nine nested level calls per primary.
- Decided: nud alternatives are an ordered choice with fall-through (the old
  engine failed the whole expression when a prefix operator's operand failed:
  an accident, now fixed, affects only programs that did not parse); operators
  of one binding power are an ordered choice whose operand is not a
  backtracking point (PEG committed choice, kept).

### Phase 3: Core as extension zero `[x]`
- [x] slang's syntax is registered through the public API (`define`, `token`,
      the walker's `primary/level/...`) in `install_core`; it stays in
      `grammar.slang` next to the kernel rather than in a separate file, since
      the kernel/core boundary is the API, not the file. Tokens carry
      categories (`keyword`, `punctuation`, `operator`, `identifier`,
      `number`, `string`); trivia is a rule and the walker/dispatch skip
      follows it; the keyword registry is a grammar service.
- [x] The extension API is the grammar object (`require("slang/compiler").grammar()`)
      plus `slang/peg`: `token/keyword/rule/define/modify/rules`,
      `statement/extension_statement`, `expression()` (facade over the walker
      with named primaries and levels, decoding `{token, ast}` results),
      `walker()`, `error_at/origin/uniq_id`. `slang/parser` is gone; nodes are
      no longer copied and stripped of their tokens (generated code keeps the
      positions of what the user wrote).
- [x] All extensions, the dungeon DSLs and the tests ported; every untouched
      file compiles to byte-identical bytecode, fixed points unchanged.
- Found and fixed: boot never preloaded the bootstrap modules, so the first
  `require("slang/compiler")` created a second compiler instance with its own
  grammar (the old API hid this by preloading itself). Both VMs now register
  the bootstrap modules' results.

### Phase 4: Scoping, project file, dialects `[ ]`
- [ ] Phrase loop derives/restores per unit; ambient layer from
      `slang.project`; suffix dialects in `slang/package`; `--explain`.
- [ ] Cache key with project and extension contents.
- [ ] Examples: a `.json` dialect; the custom operators extension as an
      ambient project extension.

### Phase 5: Memoization placement `[ ]`
- [ ] Shared-prefix analysis at seal; memo per statement; measured on a
      deliberately bad extension (the wrapped-rule worst case).

### Phase 6: Tooling `[ ]`
- [ ] Syntax export and a VM-free highlighter; semantic tokens from codegen;
      `slang highlight`; restricted VM mode.
- [ ] Editor integration (VS Code, semantic tokens).

## Decisions (2026-10-26)

- `slang.project` is slang: a table literal parsed under the base grammar.
- No compatibility layer for the old `slang/parser` API. The scoping change is
  a semantic break anyway, so existing extensions and the dungeon DSLs are
  ported in Phase 3 and the old API is removed.

- Conflict reporting (a `modify` of a rule another extension already
  modified, a failed probe, the `choice(old, ...)` lint) is immediate, at the
  `modify` call, so the warning points at the offending line. Warnings are a
  development aid: off by default outside `slang run --explain` /
  `SLANG_GRAMMAR_WARNINGS=1`, and `slang.project` can disable them per
  extension (a temporarily conflicting intermediate state is legal, just not
  something correct code needs).

## Open points

- None at the moment.
