# granular

A granular synthesizer that plays what the microphone heard. Record a few
seconds, then play the recording from the keyboard: every key held is a
voice that scatters short grains of it, each read at its own place, pitch,
direction and pan, dozens a second. In live mode the grains come from the
last six seconds the microphone heard, as it hears them.

```
make granular                 (or: cd examples/granular && slang run main.slang)
slang run main.slang some.wav start from a WAV file
make granular-test            the tests: no window, no audio device
```

## Playing

| key (by position)         | does                                                       |
| ------------------------- | ---------------------------------------------------------- |
| A W S E D F T G Y H U J K | an octave; A in octave 4 plays the sound at its own pitch  |
| Z / X                     | octave down / up                                           |
| space                     | hold: notes keep sounding after their keys (again: let go) |
| R                         | start / stop recording (30 s at most)                      |
| P                         | play the whole recording as it is (again: stop)            |
| L                         | live mode on / off                                         |
| Q                         | freeze: live mode stops listening, scan stands still       |
| 1 - 8                     | morph to that snapshot (over the glide time)               |
| shift + 1 - 8             | store the knobs and LFOs as that snapshot                  |

A click (or drag) on the waveform sets the position; the sliders turn with
the mouse; a WAV file dropped on the window is loaded. MIDI notes play too,
and knobs sending CC 70-77 (the MPK mini's eight) turn position, size,
density, spray, pitch, detune, scan and mix.

A take is saved to `takes/last.wav` when recording stops, and loaded at the
next start; until there is one, a demo sample made in `sample.slang`
(plucked strings over a pad) plays. macOS asks once whether the terminal or
editor that runs slang may use the microphone; until it may, recording
records silence (the MIC meter stays flat).

| knob     | what it does                                                              |
| -------- | ------------------------------------------------------------------------- |
| size     | a grain's length, 5 ms to 1 s                                             |
| density  | grains a second per voice (quieter each as more overlap)                  |
| spray    | how far from the position a grain may start, up to half a second          |
| skew     | where in a grain its window peaks: early is percussive, late is reversed  |
| pitch    | transposes every voice, in semitones                                      |
| detune   | a random pitch per grain, up to that many semitones off                   |
| reverse  | the share of grains that play backwards                                   |
| stereo   | how far grains are spread from the middle                                 |
| position | where grains start, 0..1 of the recording (live: 1 is now)                |
| scan     | moves the position through the recording; 1 is real time, below 0 back    |
| attack   | a voice's fade in                                                         |
| release  | its fade out after the key                                                |
| cutoff   | a lowpass filter on the sum                                               |
| delay    | the ping-pong echo's time (it glides, so turning it bends the echoes)     |
| feedback | how long the echoes ring                                                  |
| mix      | how loud they are                                                         |
| gain     | into a soft clipper                                                       |

Every knob glides to where it is turned (50 ms), so a jump does not click.

**Two LFOs** each move one knob (picked under *moves*; click for the next,
right click or the wheel to go back) around where its slider is: *depth* 1
sweeps the whole slider, below 0 the other way round. Shapes: sine,
triangle, ramp, square, random (a new value each cycle) and drift (gliding
between random values). A green mark on a slider shows where the sound has
that knob right now.

**Snapshots** keep the knobs and the LFOs in eight slots (shift+1-8, or
shift+click on a slot), saved to `takes/snapshots.json`. 1-8 (or a click)
morphs from where the knobs are to the snapshot over *glide* seconds (0:
at once); *morph* is where that is, and dragging it moves back and forth
between the two by hand. Knobs morph along their sliders, an LFO's shape
and target switch halfway; a knob turned during a morph stays where it was
turned.

## How it works

- **The microphone** is the [microphone package](../../packages/microphone)
  (native code on CoreAudio: an AudioQueue fills a ring on the system's
  audio thread). The render isolate of raylib/stream opens it and reads it
  every block of 128 frames: into the recording while recording, and into a
  six-second ring for live mode always.
- **The engine** (`engine.slang`) is one kernel, `render`: per sample it
  steps the voices' envelopes, starts a grain when a voice's timer runs out
  (at the density, with some jitter so grains do not buzz), and sums up to
  128 grains, each read with cubic interpolation and shaped by its window;
  then a state variable lowpass and a ping-pong delay with a darkening
  loop. The voices, the grains and the effects' state live in the kernel
  module (structs and fixed arrays), so a block costs one call. Eight
  voices at 200 grains a second each take about 18% of real time on an M2
  Pro; the defaults about 1-4%.
- **Gliding and the LFOs** run in the same kernel, once a block: each knob
  follows its slider with a one-pole glide, the LFOs add to it in the
  slider's terms (so they follow the curve of size or density), and the
  results go back into `ctl` (cells 60-76) for the window to show. Gain
  and mix also ramp across the block. Snapshots are the window's
  (`snapshots.slang`): a morph only writes the knobs, and the engine glides
  after them.
- **The window and the engine** share buffers (`engine.shared`): the
  recording, the live ring, the knobs and the cells the engine reports in
  (`ctl`), a slot per voice (`keys`: note, gate, velocity and a serial
  that starts a note again) and where each grain reads (`view`), which the
  window draws as the cloud over the waveform. The waveform's columns come
  from a kernel too (`peaks`), so a 30-second take draws every frame.
- **WAV files** (`sample.slang`): 16- and 24-bit PCM and 32-bit float in,
  mixed to mono and resampled to 48 kHz by kernels; 16-bit out.

Environment variables for smoke tests: `GRANULAR_DEVICE=name` picks a
microphone (part of its name), `GRANULAR_MIC=0` opens none,
`GRANULAR_LIVE=1` starts in live mode, `GRANULAR_NOTE=1` holds a note,
`GRANULAR_PLAY=1` plays the recording,
`GRANULAR_FRAMES=n` quits after n frames and `GRANULAR_SCREENSHOT=file.png`
saves the last (relative to the working directory).
