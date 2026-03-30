# Plan: Self-host slang compiler + parser in slang on the Go VM

## Summary

Write the slang grammar and bytecode compiler in slang, using the existing Go PEG library exposed as a `slang/peg` stdlib module. The grammar is written in slang using PEG combinators; the PEG execution engine runs in Go. The whole compiler is compiled once by the Dart VM to produce a bootstrap `compiler.slb`, committed to the repo and loaded at Go VM startup.

## Phases

### Phase 1 — UTF-8 string encoding migration (small)

The Dart side historically writes UTF-16 code units for strings; the Go loader reads UTF-8. Fix this before the bootstrap compiler can produce correct output.

**Files to modify:**
- `lib/src/bytes.dart`
  - `writeString(s)`: switch from UTF-16 code units to `dart:convert` `utf8.encode(s)` bytes
  - `readString()`: mirror change — read as UTF-8
- `lib/src/vm/function_prototype.dart`
  - Audit `PrototypeEncoder` for any independent UTF-16 paths; remove them

**Validation:**
```
dart test
dart run bin/slangc.dart test/example.slang && go test ./go_slang/vm/...
```

---

### Phase 2 — Go VM plumbing: `vm.Invoke()`, `load()`, `slang/bitwise`, file-based `require()` (medium)

Wire up four missing capabilities required by later phases.

#### 2a — `vm.Invoke()` — re-entrant slang calls from Go

This is required so PEG `map` callbacks can call back into slang closures during parsing.

**File to modify:** `go_slang/vm/vm.go` (or `exec.go`)
- Add `func (vm *VM) Invoke(closure Value, args []Value) (Value, error)`
- Semantics: push args onto stack, create a new call frame for the closure, run the dispatch loop until the frame returns, return the result value (or error on `SlangException`)
- Must be safe to call while the VM is already executing (re-entrant on the Go call stack, not on the slang call stack — each `Invoke` gets its own frame)

#### 2b — `coreLoad` — expose `.slb` bytes → closure

**File to modify:** `go_slang/vm/stdlib_core.go`
- Replace `coreCompileStub` for `"load"` with `coreLoad(vm *VM) bool`:
  ```go
  // arg 0: slang table of ints (1-indexed), values 0–255
  // returns: ClosureVal wrapping the loaded root prototype
  func coreLoad(vm *VM) bool {
      t := vm.GetTableArg(0)
      n := int(t.Length())
      buf := make([]byte, n)
      for i := 0; i < n; i++ {
          buf[i] = byte(t.Get(IntVal(int64(i + 1))).ToInt())
      }
      proto, err := LoadPrototype(bytes.NewReader(buf))
      if err != nil { panic(&SlangException{Message: err.Error()}) }
      cl := &SlangClosure{Proto: proto, Upvalues: make([]*Upvalue, len(proto.Upvalues))}
      vm.Push(ClosureVal(cl))
      return true
  }
  ```
- Add `var bootstrapCompiler Value` package-level var and `SetBootstrapCompiler(v Value)`
- Replace `"compile"` stub with `coreCompile` that calls `bootstrapCompiler` via `vm.Invoke`

#### 2c — `slang/bitwise` module

**File to create:** `go_slang/vm/stdlib_bitwise.go`
```go
func buildBitwiseModule() *SlangTable {
    // band(a,b), bor(a,b), bxor(a,b), lshift(a,n), rshift(a,n)
    // each: vm.GetIntArg(0), vm.GetIntArg(1), vm.Push(IntVal(result))
}
```

#### 2d — File-based `require()`

**File to modify:** `go_slang/vm/stdlib_package.go`
- `RegisterStdlib(vm *VM, bootstrapPath string)` — add bootstrap path parameter
  - If `bootstrapPath != ""`: load `.slb`, call `SetBootstrapCompiler`, preload `slang/compiler` module
- `pkg.Preload("slang/bitwise", buildBitwiseModule())`
- `requireFn`: after preloaded lookup fails:
  - `.slb` suffix → `os.ReadFile` → `LoadPrototype` → `ClosureVal` → cache + push
  - `.slang` suffix or bare module path → call `coreCompile` source → call `coreLoad` → cache + push

**Validation:**
```
go test ./go_slang/vm/...
go build ./go_slang/...
```

---

### Phase 3 — `slang/peg` stdlib module (medium)

Expose the existing Go PEG library (`go_slang/peg/peg.go`) as a `slang/peg` module. Slang code calls these functions to build parsers and run them.

**File to create:** `go_slang/vm/stdlib_peg.go`

#### Parser value representation

PEG parser objects are wrapped as `UserData` slang values containing a `peg.Parser` interface. Slang code treats them as opaque handles passed between combinator functions.

#### Value conversion (Go ↔ slang)

```
Go any → slang Value:
  string         → StringVal
  int / int64    → IntVal
  float64        → FloatVal
  bool           → BoolVal
  nil            → NilVal
  []any          → SlangTable (1-indexed integer keys)
  peg.Token      → SlangTable {type: StringVal, value: StringVal}
  *SlangTable    → TableVal (pass-through from map callbacks)
  Value          → pass-through (already a slang value)

slang Value → Go any:
  StringVal  → string
  IntVal     → int64
  FloatVal   → float64
  BoolVal    → bool
  NilVal     → nil
  TableVal   → *SlangTable (pass-through, usable in further maps)
  UserData   → the wrapped Go value
```

#### Exposed functions

| Slang call | Go peg equivalent | Notes |
|---|---|---|
| `peg.string(s)` | `peg.String(s)` | literal match |
| `peg.pattern(re)` | `peg.Pattern(re)` | regex match from position |
| `peg.any_char()` | `peg.AnyChar()` | any single char |
| `peg.seq(p1, p2, ...)` | `peg.Seq(...)` | vararg, returns `[]any` |
| `peg.choice(p1, p2, ...)` | `peg.Choice(...)` | ordered choice |
| `peg.star(p)` | `peg.Star(p)` | possessive `*` |
| `peg.lazy_star(p, limit)` | `peg.LazyStar(p, limit)` | lazy `*` until limit |
| `peg.lazy_plus(p, limit)` | `peg.LazyPlus(p, limit)` | lazy `+` until limit |
| `peg.separated_star(p, sep)` | `peg.SeperatedStar(p, sep, false)` | `*` with separator |
| `peg.separated_plus(p, sep)` | `peg.SeperatedPlus(p, sep, false)` | `+` with separator |
| `peg.map(p, fn)` | `peg.Map(p, ...)` | fn is a slang closure; uses `vm.Invoke` |
| `peg.keep(p, i)` | `peg.Keep(p, i)` | single index keep |
| `peg.token(p, type_str)` | `peg.ToToken(p, type_str)` | wraps result as Token |
| `peg.start()` | `peg.Start()` | assert start of input |
| `peg.end()` | `peg.End()` | assert end of input |
| `peg.parse(p, input)` | `p.ParseOn(peg.NewContext(input))` | runs the parser |

#### `peg.map` implementation detail

```go
func pegMapFn(vm *VM) bool {
    parserUD := vm.GetArg(0).ToUserdata().(peg.Parser)
    mapperCl := vm.GetArg(1) // slang closure Value

    vmRef := vm
    mapped := peg.Map(parserUD, func(v any) any {
        slangArg := anyToSlangValue(v)
        result, err := vmRef.Invoke(mapperCl, []Value{slangArg})
        if err != nil { panic(err) }
        return slangValueToAny(result)
    })
    vm.Push(UserdataVal(mapped))
    return true
}
```

#### `peg.parse` return value

```
{ok: true,  value: <slang_value>, position: int}
{ok: false, error: "parse failure message", position: int}
```

#### Registration

```go
func buildPegModule(vm *VM) *SlangTable {
    t := NewSlangTable()
    t.Set(StringVal("string"),         GoFuncVal(pegStringFn))
    t.Set(StringVal("pattern"),        GoFuncVal(pegPatternFn))
    // ... all combinators ...
    t.Set(StringVal("map"),            GoFuncVal(pegMapFn(vm)))
    t.Set(StringVal("parse"),          GoFuncVal(pegParseFn))
    return t
}
// In RegisterStdlib: pkg.Preload("slang/peg", buildPegModule(vm))
```

**Validation:**
```
go test ./go_slang/vm/... -run TestPeg
```
Write a small Go test that exercises `slang/peg` via the VM: parse `"hello"` with `peg.string("hello")`, assert success.

---

### Phase 4 — Slang grammar (large)

Write the full slang grammar in slang using `slang/peg` combinators. This is the parser half of the self-hosted compiler.

**File to create:** `go_slang/src/grammar.slang`

#### Rule organization

Mirror `slang_grammar.dart` rule structure directly. Each grammar rule is a slang function that returns a PEG parser (UserData). Rules reference each other via closures (forward references handled by `let` + reassignment or via a `ref` table).

Forward reference pattern (for mutually recursive rules):
```slang
-- Pre-declare mutable refs for all rules
let rules = {}

-- Define each rule as a lazy wrapper
let expr_rule = peg.map(peg.choice(
  peg.map(peg.seq(...), fun(v) { ... }),
  ...
), fun(v) { v })

-- Assign into rules table for cross-reference
rules.expr = expr_rule
```

#### Grammar rule mapping (Dart → slang)

| Dart rule | Slang equivalent | Notes |
|---|---|---|
| `start()` | top-level `parse(source)` entry | `chunk` + `end` |
| `chunk()` | `chunk_rule` | `(statement ';'?)*` + optional `finalStatement` |
| `block()` | `block_rule` | `'{' chunk '}'` |
| `statement()` | `statement_rule` | ordered choice of all statement types |
| `localDeclaration()` | `local_decl_rule` | `'local' expr ('=' expr)?` |
| `ifStatement()` | `if_stmt_rule` | `'if' '(' expr ')' stmt ('else' stmt)?` |
| `forLoop()` | `for_loop_rule` | C-style for |
| `forInLoop()` | `for_in_rule` | `'for' '(' 'let' pattern 'in' expr ')' stmt` |
| `functionDefinitionStatement()` | `fun_def_rule` | `'local'? 'func' identAndIndex funDef` |
| `returnStatement()` | `return_rule` | `'return' expr` |
| `breakStatement()` | `break_rule` | `'break'` |
| `exprStatement()` | `expr_stmt_rule` | `expr ('=' expr)?` |
| `expr()` | `expr_rule` | delegates to ExpressionBuilder equivalent |
| `intLiteral()` | `int_lit_rule` | `[+-]?[0-9]+` |
| `doubleLiteral()` | `double_lit_rule` | `[+-]?[0-9]+\.[0-9]+` |
| `stringLiteral()` | `string_lit_rule` | `"..."` and `"""..."""` |
| `trueLiteral()` / `falseLiteral()` / `nullLiteral()` | bool/null rules | |
| `tableLiteral()` | `table_lit_rule` | `'{' fields '}'` |
| `functionExpression()` | `fun_expr_rule` | `'func' funDef` |
| `identifier()` | `ident_rule` | `[a-zA-Z_][a-zA-Z0-9_]*` excluding keywords |
| `identifierAndIndex()` | `ident_and_index_rule` | ident + `(.field | [expr])*` |
| `nameAndArgs()` | `name_and_args_rule` | `(':' ident)?` + `args` |
| `args()` | `args_rule` | `'(' expr,* ')'` + optional block, or bare block |
| `slangPattern()` | `pattern_rule` | table/const/var pattern |
| `patternAssignmentExp()` | `let_expr_rule` | `'let' pattern '=' expr` |
| `quote()` | `quote_rule` | `'+' '{' quoteBody '}'` |
| `unquote()` | `unquote_rule` | `'-' '{' quoteBody '}'` |
| `space()` | `space_rule` | whitespace + `//` comments |

#### Expression precedence (ExpressionBuilder equivalent)

Implement precedence climbing directly with `peg.choice` and `peg.map`:

```slang
-- Each level: parse left, then loop over right-associative / left-associative ops
let or_expr   = left_assoc(and_expr,   [["or"]])
let and_expr  = left_assoc(cmp_expr,   [["==","!=","<","<=",">",">="]])
let cmp_expr  = left_assoc(add_expr,   [["+","-"]])
let add_expr  = left_assoc(mul_expr,   [["*","/","%"]])
let mul_expr  = right_assoc(unary,     ["^"])
let unary     = prefix(postfix,        ["not", "-"])
let postfix   = postfix_loop(primary)  -- .field, [idx], :name(args), (args)
```

#### AST node format

Every node: `{type: "...", line: int, col: int, ...fields}`

| AST type | Fields |
|---|---|
| `Program` | `body: [stmt]` |
| `Block` | `body: [stmt]` |
| `LocalDecl` | `name_expr, value (nullable)` |
| `Assign` | `target, value` |
| `IfStmt` | `cond, then_branch, else_branch (nullable)` |
| `ForLoop` | `init, cond (nullable), step (nullable), body` |
| `ForIn` | `pattern, iter, body` |
| `FunDeclStmt` | `local: bool, target, params, body` |
| `ReturnStmt` | `value` |
| `BreakStmt` | — |
| `ExprStmt` | `expr` |
| `BinOp` | `op, left, right` |
| `UnaryOp` | `op, operand` |
| `IntLit` | `value: int` |
| `FloatLit` | `value: float` |
| `StringLit` | `value: string` |
| `BoolLit` | `value: bool` |
| `NilLit` | — |
| `Ident` | `name: string` |
| `FunExpr` | `params: [pattern], vararg: bool, body` |
| `TableExpr` | `fields: [{key (nullable), value}]` |
| `FieldAccess` | `object, field: string` |
| `IndexAccess` | `object, index` |
| `MethodCall` | `object, method: string, args: [expr]` |
| `Call` | `func, args: [expr]` |
| `LetExpr` | `pattern, value` |
| `Quote` | `body` |
| `Unquote` | `body` |

#### Entry point

```slang
let peg = require("slang/peg")

-- ... all rule definitions ...

fun parse(source) {
  let result = peg.parse(program_rule, source)
  if result.ok then
    {ok: true, ast: result.value}
  else
    {ok: false, error: result.error}
}
```

**Validation:** Call `parse(source)` on `go_slang/vm/testdata/integration_vm_test.slang` and print the resulting AST. Manual inspection against expected structure.

---

### Phase 5 — Slang codegen (large)

Bytecode emitter that walks the AST tables and produces a `.slb` binary as a byte-table.

**File to create:** `go_slang/src/codegen.slang`

#### Assembler table

```slang
{
  instructions: [],    -- list of encoded uint32 values (as ints)
  constants: [],       -- {type_marker: int, value: any}
  upvalues: [],        -- {name: str, index: int, is_local: bool}
  children: [],        -- child assembler tables (nested functions)
  locals: {},          -- name → {reg: int, scope_depth: int}
  scope_depth: 0,
  reg_top: 0,
  nargs: 0,
  is_vararg: false,
  source_locs: [],     -- {first_instruction: int, origin: str, line: int, col: int}
  parent: nil,         -- parent assembler (upvalue resolution)
}
```

#### Instruction encoding (uses `slang/bitwise` from Phase 2)

```slang
let bit = require("slang/bitwise")

fun encode_iABC(op, a, b, c) {
  bit.bor(bit.bor(op % 64, bit.lshift(a, 6)),
          bit.bor(bit.lshift(c, 14), bit.lshift(b, 23)))
}
fun encode_iABx(op, a, bx)   { (op % 64) + a * 64 + bx * 16384 }
fun encode_iAsBx(op, a, sbx) { encode_iABx(op, a, sbx + 131071) }
fun encode_iAx(op, ax)        { (op % 64) + ax * 64 }
```

#### Opcode constants (mirror `go_slang/vm/bytecode.go`)

```slang
let OP_MOVE=0, OP_LOADCONST=1, OP_LOADBOOL=2, OP_LOADNIL=3,
    OP_GETUPVALUE=4, OP_SETUPVALUE=5, OP_GETTABLE=6, OP_SETTABLE=7,
    OP_NEWTABLE=8, OP_ADD=9, OP_SUB=10, OP_MUL=11, OP_DIV=12,
    OP_MOD=13, OP_POW=14, OP_UNM=15, OP_NOT=16, OP_LEN=17,
    OP_CONCAT=18, OP_JMP=19, OP_EQ=20, OP_LT=21, OP_LE=22,
    OP_TEST=23, OP_CALL=24, OP_RETURN=25, OP_CLOSURE=26
```

#### Key functions

```
new_asm(parent)              → assembler table
asm_emit(asm, instr)         → append encoded instruction; return instruction index
asm_add_const(asm, tm, val)  → dedup + add constant; return index
asm_alloc_reg(asm)           → return reg_top++
asm_push_scope(asm)          → scope_depth++
asm_pop_scope(asm)           → remove locals at current depth; scope_depth--
asm_define_local(asm, name)  → alloc reg, map name at current scope_depth
asm_resolve(asm, name)       → {kind:"local",reg} | {kind:"upvalue",idx} | {kind:"global"}
asm_add_upvalue(asm, name, index, is_local) → upvalue index
asm_patch_jmp(asm, instr_idx, target) → rewrite JMP instruction at instr_idx
asm_add_source_loc(asm, node) → append source location from node.line / node.col

codegen(asm, node, dest)     → emit code for node into dest register; return dest
  dispatch on node.type:
    IntLit/FloatLit/StringLit → LOADCONST
    BoolLit                   → LOADBOOL
    NilLit                    → LOADNIL
    Ident                     → local MOVE | GETUPVALUE | global GETTABLE from _ENV
    BinOp                     → codegen left, right; arithmetic/compare/logical op
    UnaryOp                   → codegen operand; UNM / NOT / LEN
    Call                      → codegen func + args; CALL
    MethodCall                → codegen self; GETTABLE method; CALL with self
    FunExpr / FunDeclStmt     → new child_asm; recurse; CLOSURE
    TableExpr                 → NEWTABLE; SETTABLE for each field
    FieldAccess               → GETTABLE with string const
    IndexAccess               → GETTABLE with computed index
    Assign                    → SETTABLE / SETUPVALUE / global SETTABLE on _ENV
    LocalDecl                 → codegen value; asm_define_local
    IfStmt / IfExpr           → TEST; JMP (patch); codegen branches
    While                     → loop header; TEST; JMP back
    ForLoop                   → numeric loop
    ForIn                     → CALL iter; TEST; JMP back
    ReturnStmt                → codegen value; RETURN
    Block                     → push scope; codegen stmts; pop scope
    Quote                     → emit table construction for quoted AST
    Unquote                   → emit nested codegen call
    Program                   → wrap in top-level function; return root prototype

codegen_function(parent, node) → child assembler (complete)
```

#### `.slb` serializer

```slang
fun serialize(asm) {
  let buf = {}  -- 1-indexed byte table

  -- magic: "SLANG"
  write_bytes(buf, [83, 76, 65, 78, 71])
  write_prototype(buf, asm)

  buf
}

fun write_byte(buf, b)       { append(buf, b % 256) }
fun write_int32_le(buf, n)   { write_byte(buf, n%256); write_byte(buf, (n/256)%256); ... }
fun write_bool(buf, b)       { write_byte(buf, if b then 1 else 0) }
fun write_string(buf, s)     { -- length-prefixed UTF-8:
  let bytes = string_to_utf8_bytes(s)  -- via slang/string or char-by-char
  let n = len(bytes)
  if n < 255 then
    write_byte(buf, n)
  else
    write_byte(buf, 255); write_int32_le(buf, n)
  write_bytes(buf, bytes)
}
fun write_prototype(buf, asm) {
  write_int32_le(buf, asm.reg_top)      -- maxVarStackSize
  write_int32_le(buf, asm.nargs)
  write_bool(buf, asm.is_vararg)
  write_int32_le(buf, len(asm.instructions))
  for instr in asm.instructions do write_int32_le(buf, instr)
  write_int32_le(buf, len(asm.source_locs))
  for loc in asm.source_locs do
    write_int32_le(buf, loc.first_instruction)
    write_string(buf, loc.origin)
    write_int32_le(buf, loc.line)
    write_int32_le(buf, loc.col)
  write_int32_le(buf, len(asm.constants))
  for c in asm.constants do write_constant(buf, c)
  write_int32_le(buf, len(asm.upvalues))
  for uv in asm.upvalues do
    write_string(buf, uv.name)
    write_int32_le(buf, uv.index)
    write_bool(buf, uv.is_local)
  write_int32_le(buf, len(asm.children))
  for child in asm.children do write_prototype(buf, child)
}
```

For UTF-8 string → byte array: implement `string_to_utf8_bytes(s)` using `substring` + char-code table (ASCII + common characters). Or add a `slang/string` helper `bytes(s)` in Go (preferred — add `string_bytes` to `stdlib_string.go`).

**Validation:** Codegen a minimal program (`print("hello")`), call `load(serialize(asm))`, call the resulting closure, assert `"hello"` is printed.

---

### Phase 6 — Compiler entry point + bootstrap (medium)

**File to create:** `go_slang/src/compiler.slang` — single self-contained file (no `require` to other `.slang` files; grammar.slang and codegen.slang are inlined or compiled separately by Dart).

```slang
let peg_mod = require("slang/peg")
let bit_mod = require("slang/bitwise")

-- [all grammar rule definitions from grammar.slang]
-- [all codegen functions from codegen.slang]

fun compile(source) {
  let parse_result = parse(source)
  if not parse_result.ok then
    error("parse error: " + parse_result.error)
  let asm = new_asm(nil)
  codegen(asm, parse_result.ast, 0)
  serialize(asm)
}

fun compile_to_file(source, path) {
  let bytes = compile(source)
  let f = open(path, "wb")
  f:writeBytes(bytes)
  f:close()
}

{compile: compile, compile_to_file: compile_to_file}
```

**Bootstrap compilation:**
```bash
dart run bin/slangc.dart go_slang/src/compiler.slang -o go_slang/bootstrap/compiler.slb
```
Commit `go_slang/bootstrap/compiler.slb`.

**File to create:** `go_slang/vm/bootstrap.go`
```go
func LoadBootstrapCompiler(path string) error {
    data, err := os.ReadFile(path)
    if err != nil { return fmt.Errorf("bootstrap: %w", err) }
    proto, err := LoadPrototype(bytes.NewReader(data))
    if err != nil { return fmt.Errorf("bootstrap: %w", err) }
    cl := &SlangClosure{Proto: proto, Upvalues: make([]*Upvalue, len(proto.Upvalues))}
    SetBootstrapCompiler(ClosureVal(cl))
    return nil
}
```

**Wire-up** — `RegisterStdlib(vm, bootstrapPath)`:
- If `bootstrapPath != ""`: `LoadBootstrapCompiler`, call it with no args to get module table, preload as `slang/compiler`
- `compile(source)`: `coreCompile` calls `vm.Invoke(bootstrapCompiler, [StringVal(source)])` → returns byte table
- `require("slang/compiler")` returns `{compile, compile_to_file}` table

**Validation:**
```bash
go build ./go_slang/...
# Compile a .slang file with the self-hosted compiler:
go run go_slang/main.go --bootstrap go_slang/bootstrap/compiler.slb /tmp/test.slang
```

---

### Phase 7 — Integration tests (small)

**File to modify:** `go_slang/vm/integration_test.go`

- `TestSelfHostedCompile`:
  1. `LoadBootstrapCompiler("testdata/bootstrap/compiler.slb")`
  2. Read `testdata/integration_vm_test.slang`
  3. Call `vm.Invoke(compileFunc, [StringVal(source)])` → byte table
  4. Call `coreLoad` with byte table → closure
  5. `vm.Invoke(closure, [])` → assert no panic, output matches

- `TestCompilerOutputMatchesDart`:
  1. Compile `integration_vm_test.slang` with self-hosted compiler → bytes
  2. Load precompiled `integration_vm_test.slb` bytes
  3. Byte-diff; on mismatch decode both via `LoadPrototype` and print structural diff

**Validation:**
```
go test ./go_slang/vm/... -v
```
Full suite green including pre-existing `TestIntegrationVM`.

---

## Constraints

- **`slang/peg` is the parser engine**: the grammar must be written in slang using `slang/peg` combinators. No hand-rolled character-by-character tokenizer.
- **`peg.map` requires `vm.Invoke`**: Phase 2 must implement re-entrant VM calls before Phase 3 can work.
- **No regex-free fallback**: the PEG `pattern` combinator uses Go's `regexp` package, which is available via `slang/peg`. Slang grammar rules should use it for character classes.
- **Single-file bootstrap**: `compiler.slang` must be self-contained (no `require` to other `.slang` files) to be compilable by the Dart VM in one pass.
- **No constant folding**: deferred. Codegen always emits runtime evaluation.
- **No tail-call optimization**: use iterative patterns in codegen loops (instruction emission, constant table construction) to avoid deep Go stack recursion during parse map callbacks.
- **UTF-8 only**: Phase 1 must be complete before the bootstrap `.slb` is generated.
- **`.slb` format is frozen**: do not modify `loader.go`; emit bytes that match the existing decoder exactly.
- **Grammar parity**: the slang grammar rules must produce the same AST structure as the Dart compiler for the same source, so the codegen can be validated by diffing `.slb` output.

## Test Strategy

### Per-phase smoke tests
- Phase 2: `go test ./go_slang/vm/...` — existing integration test must pass; add a unit test for `vm.Invoke` and `slang/bitwise`
- Phase 3: Go unit test — build a small `slang/peg` grammar inline, verify `peg.parse` returns expected result; test `peg.map` with a slang closure callback
- Phase 4: Compile `grammar.slang` with Dart VM, load in Go VM, call `parse(source)` on a small snippet, print AST
- Phase 5: Codegen `print("hello")`, serialize, `load()`, run — assert `hello` printed
- Phase 6: Full end-to-end compile + run of integration test source

### Bootstrap correctness
- Compile `testdata/integration_vm_test.slang` with both Dart VM and self-hosted compiler
- Byte-diff the two `.slb` files
- On mismatch: decode both prototypes and print the differing field (instruction list, constant pool, upvalue list, etc.)

### Regression
- `go test ./go_slang/vm/...` must stay green after every phase

### Patterns to follow
- PEG grammar structure: mirror `slang_grammar.dart` (`SlangGrammar extends GrammarDefinition`) rule-by-rule
- Codegen visitor pattern: mirror `lib/src/compiler/codegen/slang_code_generator.dart`
- Assembler state: mirror `lib/src/compiler/codegen/function_assembler.dart`
- `.slb` format: mirror `lib/src/vm/function_prototype.dart` `PrototypeEncoder` exactly
- Go stdlib function signature: `func(vm *VM) bool`, push exactly one result, return `true`

## Checklist

- [x] **Phase 1 — UTF-8 migration**
  - [x] `lib/src/bytes.dart` `writeString` emits UTF-8 bytes via `dart:convert`
  - [x] `lib/src/bytes.dart` `readString` reads UTF-8 bytes
  - [x] `lib/src/vm/function_prototype.dart` audited for any independent UTF-16 paths
  - [x] `dart test` passes

- [x] **Phase 2 — Go VM plumbing**
  - [x] `vm.Invoke(closure, args) (Value, error)` implemented and tested
  - [x] `coreLoad` implemented in `stdlib_core.go`
  - [x] `coreCompile` calls `bootstrapCompiler` via `vm.Invoke`
  - [x] `go_slang/vm/stdlib_bitwise.go` created with `band`, `bor`, `bxor`, `lshift`, `rshift`
  - [x] `RegisterStdlib` signature updated to accept bootstrap path
  - [x] `pkg.Preload("slang/bitwise", ...)` added
  - [x] File-based `require()` implemented in `stdlib_package.go`
  - [x] `go test ./go_slang/vm/...` passes

- [x] **Phase 3 — `slang/peg` module**
  - [x] `go_slang/vm/stdlib_peg.go` created
  - [x] All combinators exposed: `string`, `pattern`, `any_char`, `seq`, `choice`, `star`, `lazy_star`, `lazy_plus`, `separated_star`, `separated_plus`, `map`, `keep`, `token`, `start`, `end`, `parse`
  - [x] `peg.map` uses `vm.Invoke` for slang closure callbacks
  - [x] Value conversion `anyToSlangValue` / `slangValueToAny` implemented
  - [x] `pkg.Preload("slang/peg", buildPegModule(vm))` added to `RegisterStdlib`
  - [x] Go unit test: parse a small grammar from within the VM, assert result
  - [x] `go test ./go_slang/vm/...` passes

- [ ] **Phase 4 — Slang grammar**
  - [ ] `go_slang/src/grammar.slang` created
  - [ ] All statement rules implemented
  - [ ] All expression rules implemented with correct precedence
  - [ ] Quote / unquote rules implemented
  - [ ] Pattern rules implemented (table, const, var)
  - [ ] Source location (`line`, `col`) on every AST node
  - [ ] `parse(source)` entry point returns `{ok, ast/error}`
  - [ ] Smoke test: parse integration test source, inspect AST manually

- [ ] **Phase 5 — Slang codegen**
  - [ ] `go_slang/src/codegen.slang` created
  - [ ] All 27 opcodes emitted correctly
  - [ ] Scope management: push/pop, local shadowing, register reuse
  - [ ] Upvalue resolution across function boundaries
  - [ ] Source location records emitted (full, per-instruction origin tracking)
  - [ ] Nested functions / CLOSURE opcode
  - [ ] `.slb` serializer with magic, prototype recursion, all fields
  - [ ] `string_bytes(s)` helper added to `go_slang/vm/stdlib_string.go`
  - [ ] Smoke test: compile `print("hello")`, `load()`, run → prints `hello`

- [ ] **Phase 6 — Bootstrap**
  - [ ] `go_slang/src/compiler.slang` created (single-file, inlines grammar + codegen)
  - [ ] Bootstrap: `dart run bin/slangc.dart go_slang/src/compiler.slang -o go_slang/bootstrap/compiler.slb`
  - [ ] `go_slang/bootstrap/compiler.slb` committed
  - [ ] `go_slang/vm/bootstrap.go` created with `LoadBootstrapCompiler`
  - [ ] `RegisterStdlib` loads bootstrap and preloads `slang/compiler`
  - [ ] `go build ./go_slang/...` passes
  - [ ] End-to-end smoke test: compile + run a `.slang` file via Go VM

- [ ] **Phase 7 — Integration tests**
  - [ ] `TestSelfHostedCompile` added and passing
  - [ ] `TestCompilerOutputMatchesDart` added; byte-diff clean (or diff explained)
  - [ ] All existing `go test ./go_slang/vm/...` tests still green
