# kernel

Inner loops in a small typed language of the slang family, run without
slang's tags, tables, checks and collector: numeric code over arrays
(audio, images, simulations) runs several times faster than the same loop
in slang. The language is to slang what GLSL is to C: the same
look, made for one job.

Kernels are written in the slang file that uses them, in a `kernel { }`
block (with the extension `kernel/syntax`):

```
extension "kernel/syntax"
local kernel = require("kernel")

kernel {
  struct Osc { phase: double, inc: double, gain: float = 0.3 }

  func saws(out: float[], oscs: Osc[], n: int){
    for(local i = 0; i < n; i += 1){
      local s = 0.0
      for(local k = 0; k < len(oscs); k += 1){
        local o = oscs[k]
        o.phase = fract(o.phase + o.inc)
        s += (o.phase * 2 - 1) * o.gain
      }
      out[i] = s
    }
  }
}

local oscs = Osc:array(3)                 // three Osc, gain 0.3
oscs[0].inc = 440 / 48000
local out = kernel.float:array(128)
saws(out, oscs, 128)
```

The block is compiled with the file: a mistake in it is a compile error at
its line, and running the file compiles nothing. Its structs and entry
points (`func`) are locals after it. It is highlighted and formatted by
the kernel grammar, like slang code around it.

The same code also works in a `.kernel` file, a module of its own
(`{dialects: {[".kernel"]: {compile: "kernel/dialect"}}}` in slang.project;
`require("osc")` gives a table of its structs and entry points), and from
a string: `require("kernel").compile(source)` gives the same table.

## Structs and arrays in slang

A struct of a kernel module is a value with two constructors:

- `Osc:new({inc: 0.01})`: one struct, its fields at their defaults and
  then as given. It reads and writes its fields (`o.phase`) and passes to a
  kernel's parameter of type `Osc`.
- `Osc:array(n)` or `Osc:array({{inc: 0.01}, {inc: 0.02}})`: an array of
  structs, for `Osc[]` parameters. An element (`oscs[1]`) is a struct
  value; assigning a table to one sets its fields.

Arrays of numbers come from the kinds: `kernel.float:array(128)`,
`kernel.int32:array({1, 2, 3})`, and so on for every kind below.
`{shared: true}` as a last argument makes memory isolates share (for an
audio thread).

Underneath, arrays are slang/buffer buffers and struct values pointers into
them: `len`, `slice` and the other buffer methods work, `Osc.type` is the
slang/ctypes type (`buffer.new(Osc.type, n)`), and `Osc.fields` lists the
fields with their kinds, offsets and defaults.

## The language

- **Values**: `int` (64-bit), `float` (64-bit; `double` means the same),
  `bool`. A local takes its initializer's type (`local x = 0.0`) or a
  declared one (`local x: float = 0`).
- **Numbers**: an int meets a float as a float, and int literals become
  floats where a float is wanted; a float becomes an int only with
  `int(x)` (truncates; saturates; NaN is 0). `int / int` and `int % int`
  are floored, as is `%` on floats (so `x % 1.0` wraps a phase into 0..1).
  Int arithmetic wraps; division by zero raises.
- **Operators**: `+ - * / %`, `^` (power), `== != < <= > >=`, `and or not`,
  on ints `& | ~ << >>` (`~` between two ints is xor, before one is not),
  and `+= -= *= /= %=`.
- **Statements**: `local`, assignment, `if / else if / else`,
  `for(init; cond; update)`, `for(cond)`, `break`, `continue`, `return`.
- **Arrays** are parameters `name: T[]` that take an array of that type:
  `float` (32-bit), `double`, `int8` .. `uint64`, `bool`, or a struct.
  Elements read as values and convert back when written; indexes are
  checked. `len(a)` is the length.
- **Structs** (`struct Op { phase: double, level: float = 1 }`) are laid
  out as C lays them out; a field may have a constant default.
  `local op = ops[k]` names an element (not a copy); a parameter of a
  struct type takes a struct value (or an array of the struct, meaning its
  first element).
- **Builtins**: `sin cos tan asin acos atan atan2 exp exp2 log log2 sqrt pow
  abs floor ceil round trunc fract sign min max clamp mix step smoothstep
  tanh sinh cosh select(c, a, b) float(x) int(x) len(a)`, and `PI`, `TAU`,
  `E`.
- **Functions**: `func` are the entry points slang calls; `local func` are
  helpers, inlined where they are called (they cannot recurse) and taking
  arrays and structs by reference.
- **Constants and state**: a top-level `local` that no function assigns is
  a constant (`local HALF = 0.5`). One that a function assigns is state:
  it keeps its value between calls, and the kernels of a module share it
  (slang does not see it; every load of the module has its own). Scalars
  (`local phase = 0.0`, `local on: bool`), fixed arrays
  (`local history: float[4096]`, zeroed) and structs (`local lfo: Lfo`, at
  its defaults). In a call scalars live in registers, so a loop over them
  costs what one over a local does.
- **use**: `use "voice"` takes the structs, constants and helpers of the
  kernel module voice (a .kernel file found as require finds it), so that
  several modules share structs; in slang the structs are voice's own
  values.
- **Errors**: the compiler names the file and line of a mistake
  (`osc.kernel:12: a float does not become an int by itself: write int(x)`);
  a run raises for an index out of range or an int divided by zero, with
  the kernel's line; the arguments are checked on every call.

## How fast

On an M2 Pro (`make kernel-bench`), ns per sample in blocks of 128, with
the JIT and with the interpreter (`SLANG_KERNEL_JIT=0`):

| loop                       | slang | interpreter | JIT |
| -------------------------- | ----- | ----------- | --- |
| sawtooth                   | 20    | 5.4         | 1.7 |
| FM chain, 6 sine operators | 425   | 181         | 79  |
| 4-pole ladder filter       | 180   | 60          | 36  |

The interpreter dispatches an instruction in about 2 ns; what remains is
the number of instructions and the time a value takes to travel through
the register file in memory between dependent instructions. A kernel call
costs well under a microsecond, so call kernels per block, not per sample.

## How it works

- `grammar.slang`: the language as slang/peg parsers, with the token
  categories and format marks that highlight and format it (the same
  grammar for blocks, .kernel files and strings).
- `compiler.slang` (slang, at compile time): a code generator that checks
  types as it goes and writes 32-bit instructions for
  a machine with 256 int and 256 float registers. Constants are registers
  the interpreter fills before it runs; helpers are inlined; counting loops
  test once at the top and then increment and compare in one instruction;
  `a + b * c` is one instruction.
- `native/vm.zig` (the module `kernel/vm`, prebuilt): loads a program,
  checks that its code cannot leave its registers, arrays or itself, binds
  the arguments and the module's state and runs it: as arm64 code from
  `native/jit.zig` where it can, else with a threaded dispatch (one
  indirect branch per instruction handler).
- `init.slang`: struct values, kinds, `kernel.module`, `kernel.compile`;
  `syntax.slang`: `kernel { }` in slang files; `dialect.slang`: `.kernel`
  files as modules.

## Building the native module

The package ships `lib/<platform>/vm.dylib` (or `.so`). After a change to
`native/vm.zig`, rebuild it with `tool/build.sh` (needs Zig 0.17);
`tool/build.sh x86_64-macos aarch64-linux` builds for other platforms.
The compiler and the interpreter check at load that they agree on the
instruction set.

`make kernel-test` runs the tests, `make kernel-bench` the benchmark.
