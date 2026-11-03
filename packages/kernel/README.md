# kernel

Inner loops in a small typed language of the slang family, run by an
interpreter without slang's tags, tables and checks: numeric code over
buffers (audio, images, simulations) runs two to four times faster than the
same loop in slang. The language is to slang what GLSL is to C: the same
look, made for one job.

```
// osc.kernel
struct Osc { phase: double, inc: double, gain: float }

kernel func saws(out: float[], oscs: Osc[], n: int){
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
```

```
// main.slang, with {dialects: {[".kernel"]: {compile: "kernel/dialect"}}}
// in slang.project
local buffer = require("slang/buffer")
local osc = require("osc")
local oscs = buffer.new(osc.Osc, 3)      // a struct type for slang/buffer
oscs[0].inc = 440 / 48000
oscs[0].gain = 0.3
local out = buffer.new("float", 128)
osc.saws(out, oscs, 128)
```

Kernels also compile from a string: `require("kernel").compile(source)`
gives the same table.

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
- **Arrays** are parameters `name: T[]` that take a slang buffer of that
  type: `float` (32-bit), `double`, `int8` .. `uint64`, `bool`, or a struct.
  Elements read as values and convert back when written; indexes are
  checked. `len(a)` is the length.
- **Structs** (`struct Op { phase: double, level: float }`) are laid out as
  C lays them out, so the module's `Op` is a slang/ctypes type for
  `buffer.new(m.Op, n)`. `local op = ops[k]` names an element (not a copy);
  a parameter of a struct type takes a buffer of it and means its first
  element.
- **Builtins**: `sin cos tan asin acos atan atan2 exp exp2 log log2 sqrt pow
  abs floor ceil round trunc fract sign min max clamp mix step smoothstep
  tanh sinh cosh select(c, a, b) float(x) int(x) len(a)`, and `PI`, `TAU`,
  `E`.
- **Functions**: `kernel func` are the entry points slang calls; `func` are
  helpers, inlined where they are called (they cannot recurse) and taking
  arrays and structs by reference. A top-level `local` is a constant.
- **Errors**: the compiler names the file and line of a mistake
  (`osc.kernel:12: a float does not become an int by itself: write int(x)`);
  a run raises for an index out of range or an int divided by zero, with
  the kernel's line; the arguments are checked on every call.

## How fast

On an M2 Pro (`make kernel-bench`), ns per sample in blocks of 128:

| loop                      | slang | kernel |      |
| ------------------------- | ----- | ------ | ---- |
| sawtooth                  | 20    | 5.4    | 3.7x |
| FM chain, 6 sine operators| 440   | 178    | 2.5x |
| 4-pole ladder filter      | 178   | 59     | 3.0x |

The interpreter dispatches an instruction in about 2 ns; what remains is
the number of instructions and the time a value takes to travel through
the register file in memory between dependent instructions. A kernel call
costs well under a microsecond, so call kernels per block, not per sample.

## How it works

- `compiler.slang` (slang, at compile time): a lexer, a parser and a code
  generator that checks types as it goes and writes 32-bit instructions for
  a machine with 256 int and 256 float registers. Constants are registers
  the interpreter fills before it runs; helpers are inlined; counting loops
  test once at the top and then increment and compare in one instruction;
  `a + b * c` is one instruction.
- `native/vm.zig` (the module `kernel/vm`, prebuilt): loads a program,
  checks that its code cannot leave its registers, arrays or itself, binds
  the arguments and runs with a threaded dispatch (one indirect branch per
  instruction handler).
- `init.slang`: `kernel.load`, `kernel.module`, `kernel.compile`;
  `dialect.slang`: `.kernel` files as modules.

## Building the native module

The package ships `lib/<platform>/vm.dylib` (or `.so`). After a change to
`native/vm.zig`, rebuild it with `tool/build.sh` (needs Zig 0.17);
`tool/build.sh x86_64-macos aarch64-linux` builds for other platforms.
The compiler and the interpreter check at load that they agree on the
instruction set.

`make kernel-test` runs the tests, `make kernel-bench` the benchmark.
