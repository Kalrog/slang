# slang modular

A modular synthesizer in pixel art: a rack of modules patched with
cables, where a clock drives step sequencers into oscillators, filters,
envelopes and drums, through a mixer, delay and reverb to the speakers.
Patterns chain into songs. Every module is computed by one kernel
(packages/kernel) in the render isolate of raylib/stream; the window is a
640 x 360 screen drawn with raylib and scaled up by whole pixels, with a
3 x 5 font made for it.

```
make modular               (or: cd examples/modular && slang run main.slang)
slang run main.slang patches/acid.json
make modular-test          no window, no audio device
```

Needs raylib (`brew install raylib`). It starts with the first patch of
`patches/`: `first_song` is a song of four chords (bass, arpeggio,
drums, a verse and a chorus chained over 20 bars, a scope on the bass),
`acid` a squelching line with swing whose cutoff follows a sample & hold
of noise, through a bitcrusher the envelope opens, over 808 drums, `play` a sound for the computer keyboard or a MIDI controller,
and `generative` a patch without a sequencer: noise sampled on every
sixteenth and snapped to a minor pentatonic is the melody, noise sampled
on eighths straight into the envelope's gate is the rhythm (the gate
opens when the held value is above a half), over a drone and sparse
drums. Start it and it plays on, never the same bar twice. `electric`
is three FM voices (a bass and a marimba from sequencers, a tine piano
for the keys) with 808 drums, a delay and a hall. Three more are each
in a style of their own: `lofi` is lo-fi hip hop at 82 BPM with swing, a
ii-V-I-vi played by three tine pianos (a chord tone each) through a
bitcrusher and a delay, vibes in the hall, a synth bass, a slow LFO
wobbling the pianos' pitch as worn tape would, and a soft 808; `electro`
is electro at 128 BPM, the 808 with cowbell, claps on the snare and an
accent row from a second trigger sequencer, a saw bass through the
filter, brass stabs from one sequencer into two FM voices (the second a
fifth up through MATH), and glockenspiel blips from noise snapped to a
minor pentatonic; `drift` is ambient at 55 BPM with no drums, two glass
pads and slow strings holding a chord for two bars at a time, a chime
melody from noise sampled on the beats, a long delay and a big hall.

## Playing it

- **SPACE** starts and stops the clock. **1-8** choose the pattern the
  sequencers play and show (the letter in their title); with SONG on at
  the clock they follow the song's chain instead.
- **Cables**: drag from an output jack (the dark band at the bottom of a
  module) to an input jack, or the other way. An input takes one cable;
  drag it away by its end to move it, right click to unplug. The output
  jacks glow with their signal.
- **Knobs**: drag up and down (shift for a fine turn) or use the wheel; a
  double click puts one back to its default. Steppers (OCT, STEP, scales)
  turn the same way. The status line shows the value.
- **SEQ**: 16 columns, a note each (-12..+12 semitones from C4 shown; up
  to two octaves). Click a step to turn it on, drag to set its note, wheel
  for a semitone, click again for off, right click to tie it to the next
  step (no new attack). STEP sets the length, OCT and TRNS transpose, GATE
  how long a step sounds.
- **TRIGS**: four rows of 16 triggers for the drums; click or paint.
- **CLOCK**: BPM, SWING, the song chain (click a slot for the next
  pattern, right click to end the chain there), BARS per chain slot, and
  SONG, which makes the chain pick the pattern. The top bar shows the
  bar and beat.
- **A** opens the menu of modules; click one to add it at the end of the
  rack. **DEL** (or BACKSPACE) removes the module under the mouse with its
  cables.
- **TAB** loads the next patch of `patches/`, **F2** saves (a new rack
  becomes `patches/patch_N.json`), **F4** empties the rack, **F5** and
  **F6** copy and paste the shown pattern of every sequencer, to make a
  variation.
- **F3** renders the song to `patches/<name>.wav` in an isolate while it
  keeps playing: the chain (or 8 bars of the pattern) and two seconds of
  tail. `slang run tool/render.slang patch.json out.wav` does the same
  without a window.
- **Keys**: Z S X D C V G B H N J M , L . ; / play notes (< and > shift
  the octave) through a KBD module, as does a MIDI controller plugged in
  before the start (`MIDI_INPUT=name` picks one; its mod wheel is WHL).
- **E** (or a click on its face) opens an FM module's editor page: every
  value of its patch, and the bank of presets. See "The FM module" below.

`MODULAR_FRAMES=n` quits after n frames, `MODULAR_RUN=1` starts the
clock, `MODULAR_SCREENSHOT=file.png` saves the last frame,
`MODULAR_EDIT=slot` opens that FM module's editor page.

## The modules

Signals are numbers: audio -1..1, pitch in octaves from C4 (1 V/oct),
gates and triggers 0 or 1, envelopes 0..1. Any output goes into any
input, so an LFO can be a clock and an envelope a pitch.

| module | knobs | in | out |
| ------ | ----- | -- | --- |
| OUT    | VOL | L, R (L alone plays on both) | MON, with a scope |
| VCO    | OCT, SEMI, FINE, PW, FM | V/O, FM (linear), PWM, SYN | SAW, PLS, TRI, SIN (band-limited saw and pulse) |
| VCF    | CUT, RES, CV (amount, bipolar), DRV | IN, CV, RES | LP, BP, HP (a four-pole ladder run twice a sample) |
| VCA    | GAIN, CV | IN, CV | OUT (IN times CV, or GAIN alone) |
| ADSR   | A, D, S, R | GAT, TRG | ENV, INV |
| LFO    | RATE | CV, RST | SIN, TRI, SQR, SAW |
| MIX    | 1, 2, 3, 4, SPRD | 1..4 | MON, L, R (1 and 3 lean left, 2 and 4 right) |
| NOISE  | LVL | TRG | WHT, PNK, S&H |
| S&H    | SLEW | IN, TRG | S&H (IN at the trigger's rising edge), T&H (IN while it is high), SLW (the held value slewed) |
| DELAY  | TIME, FB, MIX, TONE | IN, CV | MIX, WET (a tape delay: the time slides) |
| REVERB | SIZE, DAMP, MIX | IN | MIX, WET (four combs, two allpasses) |
| CRUSH  | BITS, RATE, MIX | IN, BIT, RTE | OUT (rounded to the bits, held at the divided rate; the CVs crush more) |
| SEQ    | STEP, OCT, GATE, TRNS | CLK, RST | CV, GAT, TRG, RMP; 8 patterns of 16 |
| TRIGS  | STEP | CLK, RST | 1..4; 8 patterns of 4 x 16 |
| FM     | PATCH, LVL, MOD | V/O, GAT, VEL, MOD | OUT, EG (a six-operator FM voice; see below) |
| 808    | TUNE, KDEC, TONE, STUN, SNAP, SDEC, CLAP, HTON, CHAT, OHAT, ACC, LVL | BD, SD, CP, CH, OH, CB, ACC | BD, SD, CP, HH, CB, MIX (see below) |
| DRUMS  | TUNE, KDEC, TONE, SDEC, HDEC, LVL | KCK, SNR, HAT | KCK, SNR, HAT, MIX (the simple drums) |
| CLOCK  | BPM, SWNG, BARS, SONG | RUN | 16, 8, 4, BAR; the song chain |
| KBD    | GLID | | CV, GAT, VEL, WHL |
| QUANT  | SCL, ROOT | IN | OUT (the nearest note of the scale) |
| SCOPE  | TIME, TRIG, GAIN | IN, TRG | OUT (IN, through); the window from a rising edge |
| MATH   | KA, KB, OFFS | A, B | SUM (A*KA + B*KB + OFFS), A*B, MAX, MIN |

The SCOPE is an oscilloscope: it waits for IN (or TRG, when patched) to
rise through the TRIG level, then captures TIME of the signal (2 ms to
200 ms) for its screen, so a periodic wave stands still and shows its
shape; without an edge for two windows it captures anyway. Each column
shows the least and the most of its samples, so a wave faster than the
window shows as its envelope. GAIN scales the screen.

A pattern is one bar of sixteenths when the sequencer runs from the
clock's 16 output; from the 8 output it is two bars, and BARS on the
clock says how many bars a chain slot lasts. Sequencers and trigger
sequencers start over when the clock starts, or at a trigger on RST.

## The 808

A drum machine's voices after the classic one, each fired by a trigger:
the **kick** (BD) is a sine whose pitch sweeps down from the hit and whose
body is driven, TUNE its pitch (40 to 80 Hz), KDEC its decay, TONE the
drive and the sweep; the **snare** (SD) is two resonators (STUN) and
noise through a high pass, each decaying (SDEC), SNAP the noise's share;
the **clap** (CP) is noise through a band pass in three bursts 9 ms apart
and a tail (CLAP); the **hats** (CH, OH) are six square waves at the
808's frequencies (HTON tunes them and the high pass) with one envelope,
closed (CHAT) or open (OHAT), so a closed hat chokes an open one; the
**cowbell** (CB) is two squares through a band pass. A hit's loudness
follows the ACC input at the moment of the trigger (full when nothing is
patched) by the ACC knob: with ACC at 50%, a hit with ACC low is half as
loud, so a trigger row into ACC accents steps as the 808 did. Each voice
has its own output, and MIX has them all.

## The FM module

A voice of the six-operator FM synthesizer of examples/fm, as a module:
a note starts when GAT rises (its pitch from V/O, which it keeps
following, so glides and tied steps work; its loudness from VEL when
patched), sounds while GAT is high and releases when it falls. The same
32 algorithms, envelopes of four rates and four levels per operator,
feedback, LFO, pitch envelope, velocity and keyboard scaling, and the
same bank of 32 patches (the presets); the FM example's README explains
the parameters. MOD (the knob and the input) is the mod wheel: more
vibrato, as far as the patch's PITCH SENS allows. OUT is the voice, EG the
first carrier's envelope (0..1), for a filter to follow.

On the panel, PATCH steps through the presets and the face shows the
algorithm: the carriers (heard) at the bottom, each modulator above what
it modulates, the feedback loop in teal; a dim operator is off or silent.
**E** over the module, or a click on its face, opens the **editor page**:
the operator table (one row per operator, every field a cell), the voice's
row (algorithm, feedback, sync, transpose, the LFO, pitch sensitivity, the
pitch envelope), the six envelopes and the pitch envelope as graphs, and
the presets. Drag a cell up or down (shift: one step at a time) or turn
the wheel over it; a switch (ON, MODE, the curves, the LFO's wave, SYNC)
flips with a click; a double click puts the preset's value back; clicking
an operator in the diagram mutes it, which is how an FM sound is
understood. The sound changes at once, on a held note too, and the keys
still play. A click on a preset loads it, undoing the edits (the panel
shows the name with a `*` while edited). E or ESC closes the page. An
edited patch is saved with the rack (`fm` in the module's entry of the
JSON); an unedited one is just its preset number.

## How it is built

- `engine.slang` holds the kernel: a `Mod` struct of state per slot and
  one `render` entry point that, for every sample, runs the modules in
  order with a dispatch on their kind, reading each input from the
  `sig` cell its cable names. The knobs, cables, sequences and song are
  shared buffers (`buffer.shared`) the rack writes and the kernel reads at
  every sample, so patching never compiles anything, and a module keeps
  its state (a note playing, a delay's tail) while cables move around it.
  Exponentials (pitch, cutoff, times) are taken every 16 samples in a
  control step. Back come `meters` (every output's last value, for the
  jack LEDs), `status` (the clock's place, a sequencer's step, the scope's
  position) and the scope. The FM module is the same kernel's: six
  `FmOp` structs per slot and a data-driven voice (each operator's
  modulators are indices the rack writes from the algorithm, so one
  render loop serves all 32 algorithms); its patch is a shared buffer
  `fmdata` in the units of examples/fm's patch files, which the kernel
  turns into rates and gains when a note starts or the patch's version
  changes. The 808 keeps its voices (the hats' phases and envelope, the
  band passes, each hit's accent) and its coefficients in the slot's delay
  memory, which it has no other use for.
- examples/fm's `patch.slang` (the fields and their ranges), `patches.slang`
  (the bank) and `algorithms.slang` are used as they are, through the
  project's search path. `fmui.slang` draws the algorithm diagram and the
  editor page.
- `rack.slang` is the patch as data: the catalog of kinds (knobs, jacks,
  defaults, how a value reads), the modules in their slots, the cables,
  the sequences, the song chain, and the order the kernel runs them in
  (sources before what they feed; a cable backwards reads the previous
  sample, so feedback patches work). It reads and writes the JSON
  patches.
- `ui.slang` lays the modules out in three rows (a module's width comes
  from its knobs and jacks), draws them with rectangles, lines and the
  font of `font.slang`, and tells what the mouse is over. `main.slang`
  opens the window, the stream and the patches, and turns clicks, drags
  and keys into changes of the rack.
- `tool/demos.slang` writes the patches that come with it, with the
  rack's API; `tool/render.slang` renders a patch to a WAV.

## How fast

On an M2 Pro the `first_song` patch (24 modules, 35 cables) takes about
7% of one core at 48 kHz, and renders offline at 25 times real time: a
module costs 50 to 300 ns a sample in the kernel's JIT, the VCF with its
two passes and the reverb the most.
