# slang six

A polyphonic six-operator FM synthesizer in the spirit of the classic
digital keyboards of the 1980s: 32 algorithms, an envelope of four rates
and four levels on every operator, feedback, an LFO, a pitch envelope,
velocity and keyboard scaling, sixteen voices, and a bank of 32 patches
made for it. Every sample is computed by kernels (packages/kernel) in an
isolate of its own; the panel is drawn with raylib.

```
make fm           (or: cd examples/fm && slang run main.slang)
make fm3d         the same synth in 3D, with a hardware panel (main3d.slang)
make fm-test      the engine's tests: no window, no audio device
```

Needs raylib (`brew install raylib`).

## Playing it

- **Keys**: click or glide over the keyboard (lower on a key is louder), or
  play the computer keyboard: `Z S X D C V G B H N J M ,` and
  `Q 2 W 3 E R 5 T 6 Y 7 U I`. Left and right change the octave, TAB is the
  sustain pedal, SPACE lets go of everything.
- **Patches**: click one of the 32 in the bank, or step with up and down.
  The display shows its name, with a `*` once it is edited; choosing it
  again undoes the edits.
- **Editing**: every number is a cell: drag it up or down (hold shift for
  single steps), or turn the mouse wheel over it; switches (ON, MODE, SYNC,
  curves, the LFO's wave) flip with a click. Clicking an operator in the
  algorithm diagram mutes it, as soloing operators is how FM sounds are
  understood. The sound changes at once, on held notes too.
- **Wheels**: PITCH bends two semitones and springs back; MOD adds vibrato
  (the patch's PITCH SENS sets how much).

## A MIDI controller

A controller plugged in before the synth starts plays it (macOS, through
the midi package's CoreMIDI module; `MIDI_INPUT=name` picks one, else every
one is heard): its notes with their velocity and its sustain pedal (CC 64)
go straight to the engine, read every block (1.3 ms); its pitch bend and
mod wheel (CC 1) move the wheels.

Knobs are bound by **MIDI learn**: F1 (or `` ` ``) starts it, click a value
(2D) or a knob (3D), turn a knob on the controller; BACKSPACE unbinds,
F1 ends it. In 2D any value of the table can be bound (`op3.level`,
`voice.feedback`); in 3D the controller's knobs turn the **encoders**, so
they edit whatever page is shown, as hardware with encoders does: CC 70
to 77 (the knobs of an MPK mini and many small controllers) are bound to
the eight encoders until learning says otherwise. The bindings live in
`midi_map.json` and `midi_map_3d.json` next to the program.

## The voice

An operator is a sine oscillator with an envelope. In the diagram, an
operator above another modulates it: its output moves the other's phase.
The bottom row are the carriers, which are heard; the teal line is the
feedback loop, an operator modulating itself (or, in algorithms 4 and 6, a
loop through three or two of them). The table has one row per operator:

- **FREQ** is a ratio to the key's pitch (COARSE 0 is 0.5, FINE adds
  hundredths of it), or with MODE FIXED a frequency of 1, 10, 100 or
  1000 Hz times 10^(FINE/100). DET detunes by a cent and a half a step.
- **LEVEL** is the output, 0 to 99: eight steps double it. For a modulator
  it sets the depth: at 99 it moves its carrier's phase by two cycles, at
  83 by half a cycle, which is where most bright sounds live.
- **VEL** is how much the key's velocity matters, **R.SC** how much faster
  the envelope runs on higher keys, **AMS** how much the LFO changes the
  level.
- **R1..R4, L1..L4**: the envelope goes to L1 at rate R1, to L2 at R2, to
  L3 at R3, holds L3 while the key is down, and goes to L4 at R4 when it is
  released. Rate 99 crosses the range in a millisecond and a half, rate 0
  in a minute and a half. The graph at the end of the row draws it.
- **BREAK, L.DEP, R.DEP, L.CRV, R.CRV**: keyboard level scaling: below and
  above the break point the level falls (-) or rises (+), linearly or
  exponentially with the distance in octaves.

Under the diagram: the algorithm, the feedback (0..7), OSC SYNC (phases
restart with every note) and a transposition in semitones. The LFO row
has its wave (triangle, saws down and up, square, sine, sample and hold),
speed, delay, pitch and amplitude depth, sync and pitch sensitivity; the
pitch envelope has the same rates and levels as the operators', with 50 as
the key's pitch.

## In 3D

`main3d.slang` is the same instrument as a keyboard in a walnut case (the
case, shader and camera of examples/synth's 3D version), with a panel as
hardware of its time would have it, since a knob for each of its 150
parameters would not fit:

- **The display** shows the patch, the algorithm (the chosen operator
  lit, muted ones dim) and one **page** of eight values, each over one of
  the **eight encoders** under it: drag an encoder up or down (shift: one
  step at a time) or turn the mouse wheel over it; a double click puts the
  value back as the bank has it.
- **PAGE** buttons choose what the encoders turn: OSC (mode, coarse,
  fine, detune, level, velocity, rate scaling, AMS), ENV (the four rates
  and levels, drawn above them), SCALE (keyboard level scaling, drawn
  across the keys), VOICE (algorithm, feedback, sync, transpose), LFO and
  P.EG. **OPERATOR** buttons choose the operator the OSC, ENV and SCALE
  pages show; with shift a click turns it on or off (its LED says which).
- **INTERNAL MEMORY**: the 32 patch buttons, their names printed above
  them; the chosen one is lit.
- The keys play louder nearer their front; the wheels roll; drag with
  the right button to look around, the mouse wheel off the controls moves
  closer.

`hardware.slang` lays out the face and says what each control does, in the
face's own pixels; `main3d.slang` draws it into a texture, puts the knobs,
buttons, LEDs, keys and wheels on it as meshes and picks them with mouse
rays (`FM_PICKTEST=1` checks every one). `FM_VIEW=yaw,pitch,distance` and
`FM_PAGE=n` set the camera and the page for screenshots.

## How it is built

- `algorithms.slang` writes the 32 algorithms as edges (`"2>1 4>3 6>5
  fb6"`) and lays them out for the diagram.
- `dsp.slang` is the sound, as kernel source: a **control** kernel moves
  every operator's envelope and the pitch envelope by a block's time (64
  samples) and works out each operator's phase increment and the amplitude
  it ramps to by the block's end; a **render** kernel computes one voice:
  there is one per algorithm, generated from its edges, so the routing is
  fixed and an operator's input is plain additions; **finish** limits the
  mix and fills the oscilloscope. The 34 kernels compile when the engine
  starts, in about a tenth of a second.
- `engine.slang` runs in raylib/stream's render isolate: per block it
  takes the events (notes, the pedal, patches), moves the LFO and calls the
  kernels. Voices are a buffer of structs the kernels share with slang.
- `patch.slang` defines the parameters and how patches are written,
  `patches.slang` is the bank. `app.slang` is what both versions share
  (the sound, the patch being edited, the computer keyboard); `panel.slang`
  and `main.slang` are the 2D version, `hardware.slang` and `main3d.slang`
  the 3D one, `gfx.slang` the text and envelope drawing of both.

Sixteen voices take about 95 ms per second of sound on an M2 Pro (10% of a
core), the panel's DSP figure. `FM_FRAMES=n` quits after n frames,
`FM_DEMO=1` plays chords by itself, `FM_PATCH=n` starts on patch n,
`FM_SCREENSHOT=file.png` saves the last frame.
