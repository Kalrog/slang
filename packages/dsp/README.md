# dsp

Audio processing as block diagrams, in the style of
[Faust](https://faust.grame.fr): a grammar extension adds a small
functional language to slang, and every program written in it is compiled,
when the slang file is, into a kernel (packages/kernel) that computes a
block of samples in one tight loop.

```
extension "dsp"

dsp synth {
  import "std";

  freq = hslider("freq", 110, 20, 4000, 0.01);
  gate = button("gate");
  cutoff = hslider("cutoff", 900, 50, 8000, 1) : smoo;

  process = saw(freq)
    : lowpass2(cutoff, 3)
    : *(adsr(0.005, 0.3, 0.7, 0.25, gate))
    : drive(1.5);
}

local voice = synth:new({sample_rate: 48000})
voice.freq = 220
voice.gate = 1
voice:compute(128, {}, {out})       // 128 samples into out
print(synth.source)                 // the kernel the compiler wrote
```

A project uses it by depending on the package and saying where the
language is written:

```
// slang.project
{
  dependencies: {
    kernel: {path: "../../packages/kernel"},
    dsp: {path: "../../packages/dsp"},
  },
  extensions: {"dsp"},                           // dsp name { } in slang files
  dialects: {[".dsp"]: {grammar: "dsp/file"}},   // .dsp files as programs
}
```

```
make dsp-test       # the package's tests and the example's (no audio device)
```

`examples/dsp` is written with it: a player with five instruments, an echo
and a reverb, and a car to drive (a physical model of a four-cylinder
engine, its tyres and the wind). `examples/switchback` computes all of its
sound with it.

## The language

A program is a list of definitions; `process` is what it computes. A name
is defined once in its scope (a second definition is an error that names
the first; `with` and parameters may shadow outer names).
Everything is a block diagram: a box with inputs and outputs. Numbers are
boxes with no input and one output, `_` is a wire, `!` cuts a signal, and
operators are boxes (`+` has two inputs and one output).

| syntax       | meaning                                                                            |
| ------------ | ---------------------------------------------------------------------------------- |
| `a <: b`     | split: a's outputs copied round onto b's inputs (a multiple of them)                |
| `a :> b`     | merge: a's outputs summed onto b's inputs                                          |
| `a : b`      | sequence: a's outputs into b's inputs (as many)                                    |
| `a , b`      | in parallel                                                                        |
| `a ~ b`      | feedback: b's outputs, one sample late, into a's first inputs                      |
| `a + b`      | `a, b : +`, likewise `- * / % ^ < <= > >= == != & \| xor << >>`; `-x` is `0 - x`     |
| `x @ d`      | x delayed by d samples (d must be bounded: a constant or a slider's range)         |
| `x'`         | x one sample late (`mem`)                                                          |
| `f(a, b)`    | a definition with parameters applied; a box applied to fewer signals than it takes gets them on its last inputs: `*(2)` is `_, 2 : *`, `-(1)` subtracts 1 |
| `\(x).(e)`   | a function; a function used as a box has an input per parameter                   |
| `par(i, n, e)`, `seq`, `sum`, `prod` | n copies of e with i = 0 .. n-1, in parallel, in sequence, summed, multiplied |
| `e with { definitions }` | local definitions, which see the parameters                            |
| `import "std";` | the definitions of std.dsp (any .dsp file found as `require` finds modules)     |

The operators bind from the loosest, `<: :>`, then `:`, `,`, `~`, the
comparisons, `+ - |`, `* / % & xor`, `^`, `@`, to `'` and application, all
left-associative. In an argument list `,` separates the arguments:
`f(a : b, c)` has two.

Builtins: `mem`, `int` (truncates), `float`, `sin cos tan asin acos atan
exp log log10 sqrt abs floor ceil rint tanh`, `min max pow atan2 fmod`,
`select2(s, a, b)` (a when s is 0, else b), `select3`, `attach`,
`take(i, (a, b, c))` (from 1), `SR` (the sample rate), and the controls
`hslider(label, init, min, max, step)`, `vslider`, `nentry`,
`button(label)` and `checkbox(label)`. std.dsp, written in the language,
adds oscillators (`osc`, `phasor`, `saw` and `square` with polyBLEP,
`noise`), filters (`smooth`, `lowpass1`, the RBJ biquads `lowpass2`,
`highpass2`, `bandpass2` over `tf2`, `dcblock`), `adsr`, `impulse`,
`echo`, Freeverb's `comb`, `allpass` and `reverb`, and helpers (`bus`,
`only`, `pan`, `drive`, `leveled`, `mtof`, `db2lin`).

Programs are written in two places:

- a `dsp name { definitions }` statement in a slang file (the extension
  `dsp`: `extension "dsp"` at the top of a file, or `extensions: {"dsp"}`
  in slang.project); after it `name` is a local holding the program;
- a `.dsp` file (the dialect `{grammar: "dsp/file"}`): `require("reverb")`
  of a reverb.dsp gives the program; a file without a `process` is a
  library for `import` (std.dsp).

A program has `inputs`, `outputs`, `controls` (label, kind, init, min, max,
step, as written), `source` (the kernel) and `new(options)`. An instance
has `compute(n, inputs, outputs)` over 32-bit float arrays
(`kernel.float:array(n)`), its controls as properties by label
(`voice.cutoff = 2000`, or `set` / `get`), and `reset()`.

## From diagram to kernel

The extension parses the block with the language's grammar and does the
rest at compile time:

1. **Evaluation** (dsp/eval): definitions are evaluated lazily to boxes,
   functions and labels. Composition checks the numbers of inputs and
   outputs as the table above says, and a mistake is a compile error of
   the slang file at the operator that does not fit:

   ```
   error (compile): a : b needs as many outputs of a as inputs of b; a has 1 output, b 2 inputs
     at main.slang:3:15
     3 |   process = x : _, _;
       |               ^
   ```

2. **Signals** (dsp/signal): `process` is applied to its input signals,
   giving a graph of signal expressions. Nodes are hash-consed (the same
   operation on the same operands is one node), constants fold (`x * 1`,
   `x / c` is `x * (1 / c)`, `(x + 1) + 2` is `x + 3`...), and a feedback
   loop that computes what another computes from the same signals is that
   loop: a smoothed slider used in five places is smoothed once. Every node
   knows its rate (constant, control, sample) and an interval of its
   values, from which a delay line gets its length.
3. **Code** (dsp/codegen): kernel source text, compiled to the kernel VM
   with the slang file (kernel/lower) and embedded in its bytecode. What
   depends only on controls is computed before the loop, once a block;
   state is a struct field loaded into registers for the loop and stored
   after it; a value used twice is a local, one used once is written where
   it is used, so the kernel compiler sees whole expressions; every
   delayed signal gets one ring buffer, a power of two long, in the
   instance's `ring`.

4. **Big programs**: the kernel VM has 256 float registers. The loop's
   temporaries live in a pool of locals, each reused once its value is
   read for the last time (a register for every value computes the same,
   but slower: the fewer registers a kernel has, the more of them the
   machine keeps in its own). When a program's kernel still needs more
   than there are, it is generated again with fewer, step by step, until
   it fits: the values computed once a block kept in the instance
   (`d.c3`), then the state too (`d.m7`), then
   more and more of the constants, the least used first (`d.k4`, a field
   with the constant as its default), then fewer and fewer of the pool in
   registers and the rest in a scratch array of doubles. Every step
   computes bit for bit what the first does (a test checks it); only the
   speed differs. A big program takes a second or so to compile, once:
   its bytecode is cached like any other.

The voice of examples/dsp's `tool/bench.slang`,
`osc(freq) : lowpass2(cutoff, 2)`, becomes:

```
func compute(d: State, ring: float[], n: int, out0: float[]){
  local ui_cutoff = clamp(d.ui_cutoff, 50.0, 8000.0)
  local sr = d.sr
  local c0 = ui_cutoff * 6.283185307179586 / sr
  local c1 = cos(c0)
  local c2 = sin(c0) * 0.25
  local c3 = c2 + 1.0
  local c4 = (1.0 - c1) * 0.5 / c3
  local ui_freq = clamp(d.ui_freq, 20.0, 2000.0)
  local c6 = ui_freq / sr
  local c13 = c4 * 2.0
  local c14 = c1 * -2.0 / c3
  local c15 = (1.0 - c2) / c3
  local m5 = d.m5
  local m7 = d.m7
  local m10 = d.m10
  local m12 = d.m12
  for(local i = 0; i < n; i += 1){
    local s8 = c6 + m7
    local s9 = fract(s8)
    local s11 = sin(s9 * 6.283185307179586) - m10
    out0[i] = c4 * m5 + (s11 * c4 + m12 * c13)
    m5 = m12
    m7 = s9
    m10 = s11 * c14 + m12 * c15
    m12 = s11
  }
  d.m5 = m5
  d.m7 = m7
  d.m10 = m10
  d.m12 = m12
}
```

On an M2 Pro, in blocks of 128 (examples/dsp/tool/bench.slang):

| the voice                          | ns per sample |
| ---------------------------------- | ------------- |
| dsp block (`voice.compute` direct) | 10            |
| dsp block (`instance:compute`)     | 12.5          |
| the same kernel written by hand    | 11.5          |
| plain slang                        | 108           |

Each of the instruments of examples/dsp's player with the echo and the
stereo reverb (Freeverb: 16 combs, 8 allpasses) takes 7 to 12 ms per second
of sound, about 1% of a core. A program too big for the registers runs
three to five times slower than it would in them: several programs
chained in slang (each instance's outputs the next one's inputs) are
faster than one (examples/switchback's engine is four).

## Formatting and highlighting

The grammar (grammar.slang) is slang/peg parsers whose tokens carry
highlighting categories (keywords, `function.declaration` for what a
definition defines, `function.defaultLibrary` for builtins, `parameter`,
`string` labels, `operator` for every composition) and whose parsers carry
the formatter's marks: definitions one a line with blank lines kept,
`with { }` indented, argument lists laid out like slang calls, `,` lists
grouped, and a chain of `:` or `<:` that does not fit broken before every
operator:

```
voice = saw(freq)
  : lowpass2(cutoff, 2)
  : *(adsr(0.01, 0.2, 0.5, 0.3, gate))
  : drive(1.5);
```

So `slang fmt`, `slang highlight` and the language server treat dsp code
as they treat slang, in `dsp { }` blocks and in .dsp files alike.

## Files

- `init.slang`: the extension (`dsp name { }`), `file.slang`: the .dsp
  dialect
- `grammar.slang`: the language as peg parsers, with tokens and marks
- `eval.slang`: block diagram algebra, from definitions to signals
- `signal.slang`: the signal graph (hash-consing, folding, rates,
  intervals, shared feedback loops)
- `codegen.slang`: signals to kernel source
- `build.slang`: the pipeline, imports, and the slang code a block
  expands to; `runtime.slang`: programs and instances at run time
- `std.dsp`: the library (`import "std";`)
- `wav.slang`: WAV files from buffers of samples (`require("dsp/wav")`)
- `test/dsp_test.slang`

## Not (yet) like Faust

- Signals are all 64-bit floats (delay lines store 32-bit floats); `%` is
  the kernel's floored modulo (`fmod` truncates, as C's), `int` truncates.
- No pattern matching (`case`), no `rdtable` / `rwtable`, no `letrec`, no
  environments with `.` access, no `declare`, no polyphony (`nvoices`)
  of its own.
- The sample rate is a control from 8000 to 96000 Hz: delays sized with
  `SR` are sized for 96000.
- An error inside an imported definition is reported at the dsp block, with
  the file and line in std.dsp, not at the call that caused it.
