# Plan: Reimplement Slang VM in Go

## Summary

Implement a complete Slang VM execution engine in Go that loads pre-compiled `.slb` bytecode files (produced by the Dart compiler) and executes them faithfully. The Go VM is a direct port of `slang_vm.dart`, covering all 27 opcodes, the upvalue lifecycle, metamethods (`__index`, `__newindex`, `__type`), and the call/return/pCall mechanisms. Parallel processing, stdlib, compiler, and parser are explicitly out of scope.

---

## Dispatch Loop Decision: `for` + `switch` with Inlined Handlers

Go offers no computed goto, no guaranteed TCO, and function pointer calls carry non-trivial overhead due to goroutine stack management and inability to inline through them. Benchmarks in gopher-lua and similar Go VMs consistently show that a dense `switch` statement on the opcode integer outperforms a dispatch-table of function pointers.

**Approach**: one tight `for` loop in `run()` containing a `switch inst & 0x3F`. All 27 handlers live inline as `case` bodies. No `Instruction func(vm, inst)` dispatch table (the existing `opCodes []OpCode` array is removed from the hot path).

**Additional hot-path optimisations**:
1. Pre-allocate frame stack at call time via `make([]Value, maxVarStackSize)` (mirrors Dart's `setTop`), so push/pop never trigger `append` growth in the normal case — just `stack[top] = v; top++`.
2. Cache `frame`, `instrs`, `consts`, `stack`, `top` in locals at the top of the loop; reload them after any opcode that changes the active frame (`opCall`, `opReturn`, `opGetTable`/`opSetTable` when metamethods fire).
3. Decode the instruction as a raw `uint32`; extract opcode with `inst & 0x3F` and fields inline — no method dispatch.
4. The tagged `Value` struct (see Phase 1) eliminates `interface{}` type assertions for arithmetic, which are among the most common operations.

---

## Open Questions — Resolved

| # | Question | Decision |
|---|----------|----------|
| 1 | `interface{}` vs tagged union | **Tagged union** `Value{Type, IVal int64, FVal float64, Obj interface{}}` |
| 2 | String encoding in .slb | **UTF-8** — Dart side will be changed to emit UTF-8 |
| 3 | `type` opcode strings | `"null"`, `"int"`, `"double"`, `"string"`, `"bool"`, `"function"`, `"userdata"`, `"table"`, `"thread"` |
| 4 | `__type` metamethod | Checked and confirmed: if metamethod is a Closure, call it with the value; otherwise push the string |
| 5 | `toBool` semantics | `value != nil && value != false` only — `0`, `""` are truthy |
| 6 | Arithmetic metamethods | **None** — `add/sub/mul/div/mod/neg` do direct arithmetic only |
| 7 | `test` opcode | `if toBool(-1) != (C != 0): jump(1)`; **always** `pop()` after |
| 8 | `pop` opcode | `pop(keep=A, bx=Bx)` → pops `keep+bx` values, pushes back the top `keep` |
| 9 | `_ENV` injection | upvalue[0] if `prototype.upvalues[0].name == "_ENV"`, points to `vm.globals` |
| 10 | Module path | `go_slang/vm/` (existing) |

---

## Phases

### Phase 1 — Value System & Core Types
**Scope: small**

#### Files

**`go_slang/vm/value.go`** *(new)*
```go
type ValueType uint8
const (
    TypeNil ValueType = iota
    TypeBool
    TypeInt
    TypeFloat
    TypeString
    TypeTable
    TypeClosure
    TypeUserdata
    TypeThread
)
type Value struct {
    Type ValueType
    IVal int64      // TypeBool (0=false,1=true) and TypeInt
    FVal float64    // TypeFloat
    Obj  interface{} // TypeString→string, TypeTable→*SlangTable,
                     // TypeClosure→*Closure, TypeUserdata→*Userdata, TypeThread→*VM
}
// Constructors: NilVal(), BoolVal(bool), IntVal(int64), FloatVal(float64),
// StringVal(string), TableVal(*SlangTable), ClosureVal(*Closure),
// UserdataVal(*Userdata), ThreadVal(*VM)
// Helpers: (v Value) ToBool() bool, TypeName() string
```

**`go_slang/vm/table.go`** *(new)*
```go
type SlangTable struct {
    list []Value
    hash map[Value]Value  // Note: Value is not hashable if Obj is map — use interface{} key
    Meta *SlangTable
}
// Methods: Get(key Value) Value, Set(key Value, val Value),
//          Append(val Value), fixList(), Length() int
// Note: key "meta" intercepted to read/write Meta field
```

**`go_slang/vm/vm.go`** *(rewrite)*
```go
type GoFunction func(vm *VM) bool

type UpvalueDef struct { Name string; Index int; IsLocal bool }
type SourceLocationInfo struct { FirstInstruction int; Origin string; Line, Col int }

type FunctionPrototype struct {
    MaxVarStackSize  int
    Nargs            int
    IsVarArg         bool
    Instructions     []uint32
    SourceLocations  []SourceLocationInfo
    Constants        []Value
    Upvalues         []UpvalueDef
    Children         []*FunctionPrototype
}

type UpvalueHolder struct {
    frame *StackFrame // nil when closed
    index int
    value Value
}
func (u *UpvalueHolder) Get() Value
func (u *UpvalueHolder) Set(v Value)
func (u *UpvalueHolder) Migrate()

type Closure struct {
    Prototype  *FunctionPrototype // nil for native
    GoFunc     GoFunction         // nil for slang
    Upvalues   []*UpvalueHolder
}

type Userdata struct {
    Value     interface{}
    MetaTable *SlangTable
}

type SlangException struct {
    Message  string
    Location *SourceLocationInfo
}
func (e *SlangException) Error() string

type StackFrame struct {
    pc               int
    stack            []Value
    top              int
    parent           *StackFrame
    closure          *Closure
    openUpvalues     map[int]*UpvalueHolder
    exceptionHandler func(vm *VM, err error) bool
}

type VM struct {
    frame   *StackFrame
    globals *SlangTable
}
func NewVM() *VM
```

**`go_slang/vm/bytecode.go`** *(fix OpModes)*
- Fix opcodes 2, 13, 20, 21, 22:
  - `opLoadClosure` → `iAx` (was `iABx`)
  - `opMove` → `iAsBx` (was `iABC`)
  - `opSetUpvalue` → `iAx` (was `iABC`)
  - `opGetUpvalue` → `iAx` (was `iABC`)
  - `opCloseUpvalues` → `iAx` (was `iABC`)
- Remove `Instruction func(vm *VM, inst BytecodeInstruction)` type and `opCodes []OpCode` array (not used in for+switch dispatch)
- Keep: `OpMode` constants, opcode name constants, `BytecodeInstruction` decode methods

**Validation**: `go build ./go_slang/vm/`

---

### Phase 2 — Binary Loader (.slb)
**Scope: medium**

#### Files

**`go_slang/vm/loader.go`** *(new)*
```go
// LoadPrototype reads a .slb binary and returns the root FunctionPrototype.
func LoadPrototype(r io.Reader) (*FunctionPrototype, error)
```

Implementation details:
- Check magic header `[0x53, 0x4C, 0x41, 0x4E, 0x47]` ("SLANG")
- Read `int32` as big-endian (match Dart's `ByteData.setInt32` default)
- `readPrototype(r)` is recursive; call for each child
- String encoding: **UTF-8** length-prefixed (small-length: 1 byte; long: 0xFF + int32)
- Constant type markers: `0=string, 1=int32, 2=float64, 3=bool, 4=null`
- `int32` constants cast to `int64` in `Value`
- `bool` constants: byte `0x00`=false, `0x01`=true

**`go_slang/vm/loader_test.go`** *(new)*
- Compile a minimal `.slb` with the Dart toolchain; load it; assert prototype fields match expected values.

**Validation**: `go test ./go_slang/vm/ -run TestLoader`

---

### Phase 3 — Execution Engine (Core Loop)
**Scope: large**

#### Files

**`go_slang/vm/vm.go`** — add/implement:

```go
// run executes until vm.frame returns to parentFrame
func (vm *VM) run()

// execSlang runs the inner for+switch dispatch loop for a slang frame.
// Called from run(); returns when the frame changes (call/return) so run()
// can decide whether to continue.
func (vm *VM) execSlang()
```

**Dispatch loop skeleton** (inside `run()`):
```go
func (vm *VM) run() {
    target := vm.frame.parent
    for vm.frame != target {
        frame := vm.frame
        if frame.closure == nil {
            break
        }
        if frame.closure.GoFunc != nil {
            vm.stepNative()
            continue
        }
        instrs := frame.closure.Prototype.Instructions
        consts := frame.closure.Prototype.Constants
        stack  := frame.stack
        // inner tight loop — exits when pc goes out of range OR an opcode
        // changes vm.frame (call, return, metamethod invocation)
        for frame == vm.frame {
            inst := instrs[frame.pc]
            frame.pc++
            switch inst & 0x3F {
            case opLoadConstant:
                bx := inst >> 14
                stack[frame.top] = consts[bx]
                frame.top++
            case opLoadBool:
                // ...
            // all 27 cases inlined
            }
        }
    }
}
```

**All 27 opcode implementations** (inline in switch):

| Opcode | Key implementation notes |
|--------|--------------------------|
| `loadConstant` | `stack[top] = consts[Bx]; top++` |
| `loadBool` | push `B!=0`; if `C!=0` skip (pc++) |
| `loadClosure` | create `Closure`, wire upvalues, share open upvalue holders; push |
| `add/sub/mul/div/mod` | type-switch on `TypeInt`/`TypeFloat`; no metamethods |
| `neg` | negate int or float |
| `not` | `!(nil or false)` → bool; non-bool non-nil → false |
| `eq/lt/leq` | compare; push bool result |
| `move` | `stack[sBx] = stack[top-1]; top--` |
| `push` | `stack[top] = stack[sBx]; top++` (note: `push` uses `Bx` from research) |
| `pop` | remove `Bx` values from under top `A` values |
| `returnOp` | grab `stack[top-1]`; `popFrame()`; push result onto parent |
| `newTable` | allocate `SlangTable` with pre-sized arrays |
| `setTable` | pop value, key, table → `_setTable()` (with `__newindex` metamethod) |
| `getTable` | pop key, table → `_getTable()` (with `__index` metamethod); push result |
| `setUpvalue` | `frame.closure.Upvalues[Ax].Set(stack[top-1]); top--` |
| `getUpvalue` | `stack[top] = frame.closure.Upvalues[Ax].Get(); top++` |
| `closeUpvalues` | migrate open upvalues with `index >= Ax` |
| `test` | `if toBool(stack[top-1]) != (C!=0): pc++`; always `top--` |
| `jump` | `pc += sBx` |
| `call` | `prepareCall(Bx)`; breaks inner loop (frame changed) |
| `type` | pop value; check `__type` metamethod or return type string; push |

**`prepareCall(nargs int)`**:
1. Pop `nargs` args from stack (in correct order)
2. Pop closure
3. Push new `StackFrame` onto `vm.frame`
4. For slang: push normal args; if vararg, pack extra into a table; `setTop(maxVarStackSize)`
5. For native: store args on new frame; set `closure.GoFunc` on frame

**`popFrame()`**:
1. Migrate all open upvalues: `for _, uv := range frame.openUpvalues { uv.Migrate() }`
2. `vm.frame = vm.frame.parent`

**`_getTable(table Value, key Value)`** and **`_setTable(table Value, key Value, val Value)`**:
- `__index`: if raw get misses and metamethod exists → call closure or delegate to table
- `__newindex`: if raw get misses and metamethod exists → call closure or delegate to table
- Both may recursively call run() for closures; set `vm.frame` back to inner loop after

**`toBool(v Value) bool`**: `v.Type != TypeNil && !(v.Type == TypeBool && v.IVal == 0)`

**`stepNative()`**:
```go
func (vm *VM) stepNative() {
    frame := vm.frame
    fn := frame.closure.GoFunc
    returned := fn(vm)
    var retVal Value
    if returned {
        retVal = vm.frame.stack[vm.frame.top-1]
    }
    vm.popFrame()
    if returned {
        vm.frame.stack[vm.frame.top] = retVal
        vm.frame.top++
    }
}
```

**Validation**: `go test ./go_slang/vm/ -run TestExec`

---

### Phase 4 — Public API
**Scope: small**

**`go_slang/vm/vm.go`** — add public methods:

```go
// Entry points
func (vm *VM) LoadAndRun(proto *FunctionPrototype) error
func (vm *VM) Call(nargs int)
func (vm *VM) PCall(nargs int) (err error)

// Host registration
func (vm *VM) RegisterGoFunction(name string, fn GoFunction)

// Stack access (negative index = from top)
func (vm *VM) GetTop() int
func (vm *VM) Push(v Value)
func (vm *VM) Pop() Value
func (vm *VM) GetIntArg(n int) int64
func (vm *VM) GetFloatArg(n int) float64
func (vm *VM) GetStringArg(n int) string
func (vm *VM) GetBoolArg(n int) bool
func (vm *VM) GetTableArg(n int) *SlangTable
func (vm *VM) GetClosureArg(n int) *Closure
func (vm *VM) GetUserdataArg(n int) *Userdata
func (vm *VM) PushNil()
func (vm *VM) PushBool(b bool)
func (vm *VM) PushInt(i int64)
func (vm *VM) PushFloat(f float64)
func (vm *VM) PushString(s string)
func (vm *VM) PushTable(t *SlangTable)
func (vm *VM) Globals() *SlangTable
```

**`pCall` semantics** (mirrors Dart):
- Set `exceptionHandler` on frame before call
- On error: pop to handler frame, push `{err: {message, location}}`
- Return `nil` on success, wrapped `*SlangException` on error

**Validation**: `go build ./go_slang/vm/` + `go vet ./go_slang/vm/`

---

### Phase 5 — Integration Test
**Scope: small**

**`go_slang/vm/integration_test.go`** *(new)*

Test cases (using `.slb` files compiled by Dart CLI):
1. **arithmetic**: `1 + 2 * 3` → result `7` on stack
2. **closures/upvalues**: counter factory returning incrementing values
3. **tables**: create table, set/get keys, metamethod `__index`
4. **pCall**: error propagation wraps into `{err: {...}}` table
5. **native functions**: register a Go function, call from slang, verify return value

Pre-compile `.slb` fixtures with `dart run tool/compile.dart test/fixtures/...` and commit them.

**Validation**: `go test ./go_slang/vm/ -run TestIntegration -v`

---

## Constraints

- **No goroutine/thread/parallel**: all `thread`, `yield`, `resume`, `parallel` opcode/method paths are omitted
- **No stdlib**: `RegisterGoFunction` exists but VM starts with empty globals
- **No compiler/parser**: VM only accepts `*FunctionPrototype` produced by the Dart toolchain
- **No `opCodes []OpCode` dispatch table** in the hot path: remove it. Keep opcode constants
- **No `instruction.go` handler functions**: all handlers live inline in the switch. Delete the file or leave it as package stub
- **Exact binary format**: magic header, field sizes, and ordering must match Dart's `function_prototype.dart` serialization
- **No backwards-compat shims**: the existing (broken) `vm.go` is a complete rewrite, not an incremental patch

---

## Test Strategy

- **Unit tests per phase**: each phase has a focused test added before or alongside the implementation
- **Table-driven tests** for value operations (arithmetic, toBool, type names)
- **Loader tests** against actual `.slb` binary fixtures — do not hand-craft test bytes
- **Integration tests** require the Dart compiler to be available; gate behind a build tag `//go:build integration`
- Follow existing Go test conventions: `_test.go` files in `go_slang/vm/`

---

## Checklist

- [x] **Phase 1 — Value System & Core Types**
  - [x] `value.go`: `Value` tagged union + constructors + `ToBool()` + `TypeName()`
  - [x] `table.go`: `SlangTable` with `Get`/`Set`/`fixList`
  - [x] `vm.go` rewrite: all struct types (`FunctionPrototype`, `UpvalueHolder`, `Closure`, `Userdata`, `StackFrame`, `VM`)
  - [x] `bytecode.go`: fix 5 wrong OpModes; remove dispatch table
  - [x] `go build ./go_slang/vm/` passes

- [x] **Phase 2 — Binary Loader**
  - [x] `loader.go`: magic check, recursive `readPrototype`, UTF-8 strings, all constant types
  - [x] `loader_test.go`: load a real `.slb` fixture; assert fields
  - [x] `go test ./go_slang/vm/ -run TestLoader` passes

- [x] **Phase 3 — Execution Engine**
  - [x] `run()` outer loop (handles slang + native frames)
  - [x] `for + switch` inner loop with all 27 opcodes inlined
  - [x] `prepareCall` (slang + native, vararg handling)
  - [x] `popFrame` (upvalue migration)
  - [x] `_getTable` / `_setTable` with `__index` / `__newindex` metamethods
  - [x] `stepNative`
  - [x] `go test ./go_slang/vm/ -run TestExec` passes

- [ ] **Phase 4 — Public API**
  - [ ] Stack access methods (Get*Arg, Push*, Pop, GetTop)
  - [ ] `RegisterGoFunction`, `Call`, `PCall`, `LoadAndRun`
  - [ ] `go build` + `go vet` clean

- [ ] **Phase 5 — Integration Tests**
  - [ ] Fixture `.slb` files compiled and committed
  - [ ] 5 integration test cases pass end-to-end
  - [ ] `go test ./go_slang/vm/ -tags integration -run TestIntegration -v` passes
