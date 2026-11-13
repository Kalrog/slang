# dsp

Audio processing as block diagrams, in the style of
[Faust](https://faust.grame.fr): a grammar extension adds a small
functional language to slang, and every program written in it is compiled,
when the slang file is, into a kernel (packages/kernel) that computes a
block of samples in one tight loop.

```
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

```
make dsp            # the player: five instruments, an echo, a reverb
make car            # a car to drive: engine, gears, tyres, wind, inside or out
make dsp-test       # the tests (no window, no audio device)
cd examples/dsp && ../../bin/slang run tool/bench.slang     # how fast
cd examples/dsp && ../../bin/slang run tool/render.slang out # WAVs
```

In the player, A W S E D F T G Y H U J K play an octave (by position, as
on a piano), Z / X move it, 1-5 or the tabs pick the instrument, sliders
change what the program declares, and the code beside them is the kernel
generated for the instrument.

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
`pan`, `drive`, `mtof`, `db2lin`).

Programs are written in two places:

- a `dsp name { definitions }` statement in a slang file (the extension
  `dsp`, on in this project's slang.project); after it `name` is a local
  holding the program;
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

4. **Big programs**: the kernel VM has 256 float registers. When a
   program's kernel needs more, it is generated again with fewer, step by
   step, until it fits: the loop's temporaries in a pool of locals reused
   once a value is read for the last time, then the values computed once a
   block kept in the instance (`d.c3`), then the state too (`d.m7`), then
   more and more of the constants, the least used first (`d.k4`, a field
   with the constant as its default), then fewer and fewer of the pool in
   registers and the rest in a scratch array of doubles. Every step
   computes bit for bit what the first does (a test checks it); only the
   speed differs. A big program takes a second or so to compile, once:
   its bytecode is cached like any other.

The voice of `tool/bench.slang`, `osc(freq) : lowpass2(cutoff, 2)`,
becomes:

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

On an M2 Pro, in blocks of 128 (tool/bench.slang):

| the voice                          | ns per sample |
| ---------------------------------- | ------------- |
| dsp block (`voice.compute` direct) | 10            |
| dsp block (`instance:compute`)     | 12.5          |
| the same kernel written by hand    | 11.5          |
| plain slang                        | 108           |

Each of the player's instruments with the echo and the stereo reverb
(Freeverb: 16 combs, 8 allpasses) takes 7 to 12 ms per second of sound,
about 1% of a core.

## A car

`programs/inline4.dsp` is a physical model of a car: a 1.8 litre petrol
four-cylinder with firing order 1-3-4-2, a clutch, a six-speed gearbox and
1250 kg of car, written in the language (some 340 lines with its comments)
and compiled to one kernel of some 1000 lines. `make car` drives it:

| key        | does                                |
| ---------- | ----------------------------------- |
| W, up      | throttle                            |
| S, down    | brake                               |
| E / Q      | shift up / down                     |
| A          | the automatic on and off            |
| V          | in the driver's seat / beside the road |
| R          | the road: asphalt, chip seal, cobbles |

The clutch is worked for you (driver.slang): a shift lifts off the
throttle, presses the clutch, changes the gear and lets the clutch out
over 0.3 s (blipping the throttle on a downshift to match the revs);
pulling away the clutch bites as the revs rise, and it opens again below
1100 rpm at walking pace, so the engine idles when the car stops. The
automatic shifts up at 6200 rpm and down when the revs fall (later the
harder the throttle is pressed). The window shows the tachometer, the
speedometer, the gear, the pedals, the pressure in cylinder 1 over its
cycle and the pressure in the exhaust collector; the sliders change the
engine.

Petrol decides the architecture: a throttle plate meters the air, so the
manifold holds a vacuum at idle and the cylinders start compressing from a
third of an atmosphere; a spark lights the charge, which burns over some 55
degrees; the engine revs to a limiter that cuts the sparks.

- **Crank and car**: two states in one feedback loop, the crank's speed
  and the car's. The combustion's torque (180 Nm at most, at 4200 rpm)
  less friction and pumping (engine braking with the throttle shut) turns
  the crank and flywheel; the clutch carries the torque the slip between
  the crank and the gearbox asks for, up to its grip, so it slips pulling
  away and while it is let out after a shift; through the gearbox (3.5,
  2.1, 1.4, 1.03, 0.82, 0.68) and the differential (4.1) to the wheels,
  against the air (0.39 v²), the tyres' rolling and the brakes. An idle
  valve keeps the engine at 800 rpm; the limiter cuts the sparks at 6800
  rpm and lets go 250 rpm lower (it bounces). The cycle is two turns, each
  cylinder a quarter of it after the last in the firing order. Flat out
  the car reaches 100 km/h in about 11 s.
- **Cylinders**: volume from the crank angle (with the rod's second
  harmonic), suction while the intake valve is open, polytropic compression
  and expansion while both are shut, the combustion's pressure rise as a
  Wiebe function after the spark, and the blowdown, as fast as the exhaust
  valve opens. The combustion varies from cycle to cycle, and its rate
  rings the chamber's first acoustic mode (around 6.5 kHz).
- **Valves**: cam timing with overlap at top dead centre; each valve an
  orifice between its cylinder and its port, its share of the port's
  impedance growing quickly with its lift (the gas through the first
  millimetres at the speed of sound), so the blowdown is a steep pulse.
  No two cylinders burn quite alike (a fixed bias each, and the roughness
  from cycle to cycle): the idle has a little burble.
- **Gas paths**: thirteen digital waveguides (pairs of delay lines as long
  as the pipe at the speed of sound in its gas, hot or cool, with losses
  that grow with length and take the highs first), joined where pipes meet
  by scattering junctions weighted by area. On the exhaust side there are four
  header runners of slightly different lengths, a four-into-one collector,
  the down pipe, the muffler and the tailpipe. The muffler is a volume (its
  junction's pressure follows the waves through a lowpass, as a volume
  fills and empties), a chamber whose packing absorbs the highs (more the
  higher the `muffler` control), and a perforated outlet that reflects
  little, so the tailpipe does not ring. On the intake side there are four
  runners, the plenum, the throttle body (the plate an orifice as open as
  the throttle) and the air filter's snorkel. Closed valves reflect waves;
  the open ends reflect them inverted but for the highs, and what they
  radiate is the flow out of them changing (a pulsating source, heard from
  afar), rising 6 dB an octave. All 26 waves go round one `~` loop.
- **Mechanics**: the block's modes struck by the cylinders' pressure
  changes, the valve train ticking as valves seat, piston-ring friction,
  the alternator's whine, and afterfire pops on the overrun.

The program is a library as well: a `dsp` block can
`import "programs/inline4";` and compute its own `process` from the
engine's definitions (a probe of the valves, another mix).

### Hearing it

`programs/inline4.dsp` does not mix: it puts out stems, the sound
radiated at the tailpipe and at the air filter, the mechanical noise and
the engine's vibration (gas torque ripple and the second-order inertia an
inline four does not balance), with the speed. `programs/acoustics.dsp`
takes them as inputs, adds what the car meets, and is the listener
(`vehicle.slang` runs the two programs one after the other, a kernel
each):

- **Tyres**, four of them with noises of their own: tread blocks of three
  lengths striking the road (so they do not whistle), the air pumped out
  of the closing grooves (louder with the square of the speed, in the
  horn's band between tyre and road), the road's texture shaking tread and
  carcass (its pitch rising with the speed), the cavity resonance of the
  air in the tyre (some 215 Hz), and cobbles striking one by one. The
  `road` control picks smooth asphalt, coarse chip seal or cobbles.
- **Wind**: the turbulent boundary layer (its pressure growing with the
  cube of the speed, so with the sixth power in sound power), in gusts,
  and the vortices shed behind the mirrors.
- **Beside the road**, a few metres from the left side: each source at
  its place (the exhaust behind, the engine in front, a tyre at each
  corner) and the ground's reflection 1.8 ms late.
- **In the driver's seat**: the sound through the walls, each its own
  (the floor for the exhaust, the bulkhead for the engine, the wheel
  arches for the tyres, the glass and seals for the wind), letting less
  through the higher it is; the vibration through the engine mounts and
  the suspension into the body, whose lowest modes boom; then the cabin,
  its first modes (69, 122, 149 Hz) and a short reverberation the seats
  and carpets damp. When the firing frequency meets a cabin mode the car
  drones (around 3300 rpm: 110 Hz).

Measured with `tool/spectrum.slang`: beside the road the engine leads
below 500 Hz and the tyres above, from about 50 km/h; at 120 km/h the
wind is a real part of it. In the seat the highs are 20 dB and more down,
and the engine's boom, the tyres' roar and the wind stand at about the
same loudness on the motorway.

The whole car costs about 9% of a core in real time (the engine 6, the
acoustics 3). `tool/drive.slang` renders a drive with the same driver,
beside the road and in the seat (two WAVs): the engine starts and idles,
the car pulls away flat out through the gears, coasts from 120 km/h,
brakes to a stop shifting down, and idles again.

## Formatting and highlighting

The grammar (dsp/grammar) is slang/peg parsers whose tokens carry
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

- `dsp.slang`: the extension (`dsp name { }`), `dsp/file.slang`: the .dsp
  dialect
- `dsp/grammar.slang`: the language as peg parsers, with tokens and marks
- `dsp/eval.slang`: block diagram algebra, from definitions to signals
- `dsp/signal.slang`: the signal graph (hash-consing, folding, rates,
  intervals, shared feedback loops)
- `dsp/codegen.slang`: signals to kernel source
- `dsp/build.slang`: the pipeline, imports, and the slang code a block
  expands to; `dsp/runtime.slang`: programs and instances at run time
- `std.dsp`: the library; `programs/stereo_reverb.dsp`: a program as a file
- `instruments.slang`: the player's instruments and echo as `dsp` blocks;
  `engine.slang`: the audio, in raylib/stream's render isolate;
  `main.slang`: the player
- `programs/inline4.dsp`: the car; `programs/acoustics.dsp`: tyres, wind
  and the listener; `vehicle.slang`: the two as one; `car.slang`: driving
  it; `driver.slang`:
  the clutch and the gears worked for you; `tool/drive.slang`: a drive to two
  WAVs (outside and inside); `tool/realtime.slang`: the car on the audio device, with the
  stream's load and underruns once a second; `tool/spectrum.slang`: its
  sound in octave bands and harmonics, per path, at three speeds (for
  tuning the model by numbers)
- `tool/render.slang`, `tool/bench.slang`, `test/dsp_test.slang`

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
