# studio

Instruments and effects on tracks, mixed through buses to a master and
played from timed notes: the core a tracker, a live coding environment or
a workstation is built on. It draws nothing and needs no sound card; the
synthesizers of this repository's examples are its instruments.

```slang
local studio = require("studio")
local sequence = require("studio/sequence")

local s = studio.new()
local hall = s:bus("hall")
hall:insert("hall", {decay: 2400, mix: 1})

local keys = s:track("keys", "six", {patch: "TINE PIANO"})
keys:insert("chorus")
keys:send(hall, 0.3)

local drums = s:track("drums", "drums", {kit: "808"})
s.master:insert("limiter")

keys:note(60, {length: 500})              // now, for half a second
keys.unit.params.feedback = 5             // a parameter of the instrument

local song = sequence.new(s, {bpm: 100, loop: true})
song:notes(drums, {{0, 1, 36}, {1, 1, 38}, {2, 1, 36}, {3, 1, 38}})   // beat, length, note

local sound = song:render()               // offline: {left, right}
require("studio/wav").write("out.wav", {sound.left, sound.right}, 48000)

// or through a sound card:
s:start(require("window/audio"))          // or require("raylib/stream")
song:start()
// ... every frame: song:tick()
```

`make studio-test` runs the tests, `make studio-demo` renders a piece that
uses most of the package to `demo.wav`.

## How it is put together

- A **studio** is strips: **tracks** (an instrument each), **buses** (which
  gather what tracks send them) and the **master**. Every strip has
  **inserts** (effects in a row), a `gain`, a `pan` and a `mute`. A track
  goes to the master or to a bus (`track.to = bus`) and sends to any
  number of buses (`track:send(bus, 0.3)`).
- An instrument or an effect is a **unit**. A unit has named
  **parameters**, each one number with a range, and everything that moves
  a parameter does it the same way: `unit.params.cutoff = 0.4`, a patch, a
  timed instruction, an LFO, a snapshot's morph, a MIDI knob.
- The sound is made by an **engine**: in the program's isolate while the
  studio renders offline, in the audio stream's isolate after `start()`.
  The program talks to it through shared buffers either way, so the same
  code renders a file and plays live.
- Notes and parameter changes are **instructions** with a time in samples
  of the engine's clock (`s.clock`). The engine renders up to an
  instruction, applies it, and goes on: a note sounds at its sample
  however coarsely the program runs. `track:note(60, {at: s:after(250)})`
  is a note a quarter of a second from now.
- Per block, slang decides which unit renders into which buffer; every
  sample is computed by kernels (packages/kernel).

## Instruments

| unit | what it is | from |
| --- | --- | --- |
| `poly` | a general voice: saw, square, triangle, sine, noise, an FM pair or a supersaw into a resonant lowpass, drive and pan; 16 voices, 8 patches | examples/live |
| `drums` | two drum machines on General MIDI's notes: a plain kit and an 808, each drum with its level, tuning and decay | examples/live |
| `mini` | a monophonic three-oscillator synthesizer with a ladder filter; 12 patches | examples/synth |
| `six` | six-operator FM: 32 algorithms, 16 voices, a bank of 32 patches; every field of a patch is a parameter | examples/fm |
| `sampler` | recordings in zones by key and velocity, pitched, looped or one shot, mono or stereo | new |
| `grains` | a granular synthesizer over a sample or what a microphone hears | examples/granular |
| `rack` | a modular synthesizer: 22 kinds of module patched with cables, its own sequencers; 8 racks come with it | examples/modular |
| `organ`, `pluck`, `bell`, `wind` | drawbars, a plucked string, an FM bell, blown noise: dsp programs | examples/dsp |

`six` and `mini` give the samples their examples give, to the bit. One
thing differs on purpose: `poly`'s supersaw has the envelope of the other
waves (in examples/live it rings out like a drum). `grains` leaves its
delay and LFOs to the studio's.

## Effects

| unit | what it is |
| --- | --- |
| `filter` | a four-pole ladder: low, band or high pass, with drive |
| `delay` | a tape delay whose time slides; `cross` for ping-pong |
| `room` | a small reverb of combs and allpasses, in stereo |
| `hall` | a feedback delay network of eight lines for long tails: decay, size, damping, predelay, modulation |
| `chorus` | two moving taps a side; with a short delay and feedback, a flanger |
| `phaser` | 2 to 12 allpass stages swept by an LFO |
| `eq` | a low cut, a low shelf, two bells, a high shelf |
| `compressor` | threshold, ratio, knee, attack, release, makeup; `sidechain: track` to duck under another track |
| `limiter` | a ceiling with 5 ms of lookahead |
| `drive` | tanh, soft, fold or hard clipping, with a tone |
| `crush` | fewer bits, a lower sample rate |

`studio.units` lists both. `strip.reduction` is the dB a strip's
compressor or limiter takes off, `strip.peak` its level, `track.voices`
the notes sounding.

## Parameters

```slang
local u = keys.unit                  // or what insert() returned
u.params.cutoff = 0.4                // now
u.params.wave = "square"             // an enumeration by its label
u:set("cutoff", 0.8, s:after(500))   // at a time
u:get("cutoff")                      // as it was set
u:effective("cutoff")                // as the sound has it: with the LFOs
u:patch("Pluck")                     // one of u.patches; or a table
u.info.list                          // every parameter: name, range, unit...
keys:note(60, {params: {pan: -1}})   // for this note only
```

Times are in milliseconds, frequencies in Hz, levels 0 to 1 unless a
parameter says otherwise (`mini` keeps its panel's 0 to 1 knobs, `six` the
0 to 99 of the keyboards it is after). `studio/param` has the ranges,
curves and how a value reads on a panel.

- **LFOs**: `local lfo = s:lfo({rate: 0.2, shape: "drift"})`, then
  `lfo:to(u, "cutoff", 0.25)`. A depth of 1 sweeps the parameter's whole
  slider. Shapes: sine, triangle, ramp, square, random, drift.
- **Snapshots** (`studio/snapshot`): `take`, `apply`, `morph(a, b, t)` and
  `glide` between the parameters of units, along their sliders.
- **MIDI**: `s:midi(track)` lets a controller play a track (read by the
  engine every block, so within a few milliseconds).
  `require("studio/midi").open(s)` binds its knobs to parameters by MIDI
  learn. macOS only, as packages/midi is.

## Sequences

`studio/sequence` is notes and parameter curves on a timeline of beats:
`note`, `notes`, `curve`, `midi(path, tracks)` for a Standard MIDI File,
`loop`, `swing`, `bpm` (settable while it plays). `render()` gives the
whole of it offline; `start()` and then `tick()` every frame play it
through a stream, sent a little ahead of the clock so that timing does not
depend on the frame rate.

A program with its own idea of time (a tracker's rows, a live coder's
patterns) does what a sequence does: `track:note(..., {at: ...})` for what
falls within the next tenth of a second, every frame.

## Samples

`studio/wav` reads 16- and 24-bit PCM and 32-bit float WAV files and
writes 16-bit ones. What `read` gives is what the sampler's zones and
`grains` take:

```slang
local wav = require("studio/wav")
s:track("kit", "sampler", {mode: "one shot", zones: {
  {sample: wav.read("kick.wav"), root: 36, low: 36, high: 36},
  {sample: wav.read("snare.wav"), root: 38, low: 38, high: 38},
}})
```

## Units of your own

A unit is a module that returns `{name, kind, params, new}`; `new(ctx)`
makes one running copy: a table with `render(l, r, start, n)` and, for an
instrument, `note_on` and `note_off`. `studio/units` describes all of it.
A track or insert names it by its module path:
`s:track("lead", "my/units/bell")`.

The short way is a dsp program (packages/dsp): `studio/program` makes an
instrument of a voice with the controls "freq" and "gate", or an effect of
a program with inputs. `units/organ.slang` is four lines.

A unit keeps its state in what `new` makes (structs, arrays), never in a
kernel's module state, which every copy of the unit would share.

## What it costs

On an M2 Pro at 48 kHz, as a share of one core (`slang run
tool/bench.slang`): eight held notes of `six` 3%, of `poly` 1.9%, of
`mini`'s one voice 0.6%, of the sampler 0.3%; a `rack` playing a song 5%;
the hall 0.7%, the other effects 0.05 to 0.5%. The demo piece (five
tracks, six effects, a bus) takes about 15%.

## What is not there

- Nothing draws. The examples keep their own engines and panels for now.
- The sampler does not band-limit a recording played far above its pitch.
- A rack's sequencers run on the rack's own clock, not a sequence's.
- Changing strips or inserts while a stream plays is heard at the next
  block; `start()` itself begins from silence (notes sounding offline do
  not move over).
- MIDI and the microphone are macOS only.
