# slang mini

A monophonic analog-style synthesizer in the spirit of the classic
three-oscillator keyboard synths: three oscillators and noise into a mixer,
a 4-pole ladder filter with its own contour, a loudness contour, glide, and
a mod wheel that sends osc 3 or noise to the pitch and the filter. The sound
is computed in slang, sample by sample; the panel is drawn with raylib.

```
make synth            (or: cd examples/synth && slang run main.slang)
make synth3d          the same synth in 3D (main3d.slang)
make synth-test       the engine's tests: no window, no audio device
```

Needs raylib (`brew install raylib`).

## Playing it

- **Knobs**: drag up and down (hold shift to turn finely) or use the mouse
  wheel; a double click puts a knob back where it started.
- **Rotary switches** (RANGE, WAVEFORM) step the same way.
- **Switches** flip with a click: the mixer's inputs, OSC MOD and FILTER MOD
  (where the mod wheel goes), OSC 3 CTRL (osc 3 follows the keys; off, with
  RANGE LO, it is an LFO), KBD CTRL (the filter follows the keys) and DECAY
  (a released key fades with the decay time instead of stopping).
- **Keys**: click or glide over the keyboard, or play the computer keyboard:
  `Z S X D C V G B H N J M ,` and `Q 2 W 3 E R 5 T 6 Y 7 U I`. Left and right
  shift the octave; space lets go of every note. Like the original, a key
  pressed while another is held changes the pitch without restarting the
  contours, and releasing it goes back to the key still held.
- **Wheels**: PITCH bends two semitones and springs back; MOD sets how much
  modulation goes where OSC MOD and FILTER MOD send it.
- **Patches**: up and down, or the arrows at the right of the strip, step
  through premade sounds: Init (the panel's defaults), Fat Bass, Pluck
  Bass, Lead, Brass, Flute, Fifths, Slow Pad, Filter Sweep, Wobble, Zap and
  Wind. A patch sets every control (those it does not name go to their
  defaults); turn knobs from there. `patches.slang` holds them, written as
  a song's `patch` is, so adding one is a few lines; Lead, Flute and Wobble
  run osc 3 as an LFO that the MOD wheel sends to the pitch or the filter.

The strip under the panel shows the output on an oscilloscope, the DSP load
(the time spent computing samples over the time they last), underruns
(blocks the audio device found empty, heard as clicks) and the patch.

## A MIDI controller

A controller plugged in before the synth starts plays it (macOS, through
the midi package's CoreMIDI module; `MIDI_INPUT=name` picks one controller,
else every one is heard). Its notes go straight to the engine, read every
block in the render isolate, so they sound within a couple of milliseconds;
its pitch bend and mod wheel (CC 1) move the wheels on screen.

Its knobs turn the synth's by **MIDI learn**: F1 (or `` ` ``) starts it,
click a control, turn a knob on the controller, and the two are bound;
bound controls show their controller (`CC 74`) while learning, BACKSPACE
unbinds the control clicked, F1 again ends it. The bindings are kept in
`midi_map.json` next to the program. A knob moves a rotary switch through
its positions and flips a switch at its middle.

## Songs

The synth plays songs: **Enter** plays or stops the chosen one, **Tab**
picks the next from `songs/`, and a song named on the command line plays at
once:

```
slang run main3d.slang songs/bach_prelude.slang
```

Four come with it, all public domain, editions included (see
`songs/README.md`): the Prelude of Bach's Cello Suite No. 1, Grieg's "In
the Hall of the Mountain King", Bach's Invention No. 8 and the first
movement of his Brandenburg Concerto No. 2. While a song plays its keys go down and its
knobs turn: a song sets the sound it starts with and moves controls over
time, and you can still play along or turn knobs yourself.

A song file is slang returning a table (`song.slang` describes every
field):

```
return {
  title: "Prelude, Cello Suite No. 1",
  composer: "J. S. Bach",
  midi: "bach_prelude.mid",     // or notes: {{beat, length, note}, ...}, bpm
  voice: "top",                 // one line: the highest note sounding
  transpose: 12,
  patch: {wave1: "SAW", cutoff: 0.36, emphasis: 0.25},
  automation: {                 // {beat, value}: knobs ramp, switches step
    cutoff: {{0, 0.34}, {56, 0.5}, {140, 0.7}, {168, 0.36}},
  },
}
```

`midi/file` (in packages/midi) reads Standard MIDI Files (formats 0 and
1): notes, the tempo map, track names. The song is sent to the engine whole, and the engine plays
its notes and moves its controls in the render isolate, to 16 samples (a
third of a millisecond), so a song's timing does not depend on the frames.

## Recording and mixing

The synth plays one note at a time, as its models did; records of Bach on
synthesizers were made one line at a time and mixed. `mixdown.slang` does
that with a song of several parts: it records every part through the
synth's engine into a WAV of its own (a stem), pans and sums the stems,
adds a hall (a Freeverb-style reverb) and writes the stereo mix:

```
slang run mixdown.slang songs/bach_brandenburg2.slang      # WAVs into mixdown/
make synth-mix                                             # every song
```

Nothing plays meanwhile: it computes as fast as it can, the parts at the
same time, each in an isolate of its own, as are the mix's time slices and
the hall's two channels. The Brandenburg concerto's first movement (nine
parts, 4:41) takes about 30 seconds on an M2 Pro.

A song file gets parts (see `song.slang`): each names its tracks and the
voice it plays (`"top"`, `"bottom"` or a rank, so a chord can become
several lines), and has its own patch, automation, gain and pan, over the
song's. The trumpet, recorder, oboe and violins of the concerto each have a
sound of their own, with vibrato from osc 3 run as a slow LFO (RANGE LO,
OSC 3 CTRL off) on the mod wheel. On screen the synth plays the part named
`live`.

## In 3D

`main3d.slang` is the same instrument as a keyboard on a desk: the panel
leans back over the keys, knobs, rocker switches and wheels are meshes that
turn, flip and roll, keys tip down on their back hinge while they sound, and
the case is walnut. Drag with the right button to look around; the mouse
wheel off the controls moves closer.

- The face (labels, scales, oscilloscope, load) is drawn every frame by the
  same code that draws the flat version, into a render texture at twice the
  window's resolution, with mipmaps so it stays sharp at a slant.
- The mouse picks by rays. A ray that meets the panel becomes a position on
  the face, where the flat version's hit tests decide; keys and wheels are
  boxes the ray may enter. `SYNTH_PICKTEST=1` projects every control to the
  screen and picks it back, printing the misses.
- The walnut is solid wood computed on the GPU for every pixel
  (`wood.slang` holds the GLSL): growth rings are cylinders around a trunk
  running along the board's grain, bent by slow noise, with a figure and
  fine streaks and pores stretched along the grain. It is as sharp as the
  screen at any distance, each board has its own seed (no two look alike),
  and the finest detail fades where a pixel would cover several cycles.
- No two overlapping parts of the case share a face's plane, so joints do
  not flicker (the depth buffer could not tell which is in front).
- `SYNTH_VIEW=yaw,pitch,distance[,x,y,z]` places the camera (for
  screenshots).

## How it is built

- `engine.slang` is the voice. Every sample is plain slang arithmetic on
  locals: band-limited (PolyBLEP) saw and pulse waves, a triangle, noise
  from an LCG, two passes of the ladder filter per sample (it runs at twice
  the rate) with a soft clip in its feedback. Pitch, the filter cutoff and
  its contour change every 16 samples.
- It runs under `raylib/stream` (in packages/raylib): a render isolate calls
  the engine for blocks of 128 frames and keeps a ring buffer about 21 ms
  ahead of the audio device; raylib's audio callback runs in a second
  isolate and only copies from the ring. The main program never computes a
  sample, so drawing the panel cannot make the sound stutter.
- `panel.slang` is what both versions share: starting the sound, the
  notes held, drawing the face, and what clicks, drags and keys do.
- `params.slang` lists the controls. Their values live in a shared buffer
  (`buffer.shared`) that the panel writes and the engine reads at every
  block; notes go to the engine through a channel. A patch
  (`patches.slang`) is the panel writing every control at once.

`SYNTH_FRAMES=n` quits after n frames, `SYNTH_DEMO=1` plays a phrase by
itself, `SYNTH_SCREENSHOT=file.png` saves the last frame.

## How fast

On an M2 Pro the engine computes a sample in about 0.7 to 0.9 µs (the
engine test prints it), so the synth takes 4 to 7% of one core at 48 kHz.
That is with the interpreter's fused instructions; heavier DSP (many voices,
oversampling) is what typed kernels are planned for.
