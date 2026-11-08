# slang live

A live coding environment for music and visuals: a piece is a slang file
whose code is edited in the window, over the picture its shader draws,
and run again while the music plays. Patterns say what the players play,
in a notation of their own (backtick literals, a grammar extension of
this project); sliders in the panel and a MIDI controller turn what the
code names; the sound is one kernel (packages/kernel) in the render
isolate of raylib/stream.

```
make live                  (or: cd examples/live && slang run main.slang pieces/first.slang)
make live-test             no window, no audio device
slang run main.slang --watch pieces/first.slang      no editor: the file is watched
slang run tool/render.slang pieces/acid.slang out.wav 16
```

Needs raylib (`brew install raylib`). The window is an 800 x 450 picture
scaled by whole pixels, in raylib's own pixel font.

## Playing it

- **command+enter** (control+enter elsewhere) runs the code. What it
  registers replaces what the last run registered: a player keeps its
  voices and takes its new pattern at the next beat, a slider keeps its
  position, the clock keeps counting, the shader keeps its last frame.
  An error shows in the status line and underlines its line; the music
  plays on as it was.
- **command+S** saves. The file is watched: a change saved from another
  editor is loaded and run (unless there are unsaved changes here;
  **command+R** reloads anyway). With **`--watch`** (or `LIVE_WATCH=1`)
  there is no editor in the window at all: the picture fills it, and the
  piece is edited in an editor of your own, every save loading and running
  it (within a quarter of a second; an error shows in the status line with
  its line number). The keyboard then plays the `keyboard()` players
  without hovering KEYS. **command+E** shows and hides the editor at any
  time, in either mode. **escape** or **command+D** hushes every
  player. Shortcuts are command (control elsewhere) with a letter only,
  and the letter as your keyboard layout places it: on macOS the layout
  is read (`layout.slang`, through Carbon), so command+K is the key that
  types k on a Dvorak or Bone keyboard too; elsewhere the US place of the
  letter is assumed, as raylib names keys.
- The editor has a cursor, a selection (shift and the arrows, or the
  mouse; command+A takes everything), the clipboard (command+C, X, V;
  with nothing selected, copy and cut take the whole line, and pasting
  such a line puts it above the cursor's line), undo (command+Z),
  **command+K** to comment out the selected lines (or the cursor's) and
  to uncomment them again, tab for two spaces, enter keeping the indent.
- **Sliders** drag. A right click on one arms MIDI learn: the next knob
  turned is bound to it, and stays so (`pieces/midi_map.json`).
- With the mouse over **KEYS**, the keyboard plays the players of
  `keyboard()`: the home row asdfghjkl; is the degrees 0 to 9,
  qwertyuiop starts at 7, zxcvbnm,./ at -7; shift is full velocity,
  control half, alt a semitone up.
- A **MIDI controller** plugged in before the start plays the players of
  `midi()` (`MIDI_INPUT=name` picks one); white keys are the degrees of
  the scale from the root at C4, black keys sharpen the white key below,
  so the keys are always in key. `midi({abs: true})` plays the notes as
  they are, `midi({perc: true})` maps General MIDI drum notes to the kit.
  `midi_cc(74)` is a knob as a signal.

`LIVE_FRAMES=n` quits after n frames, `LIVE_SCREENSHOT=file.png` saves the
last frame, `LIVE_SCALE=n` sets the pixel size.

## A piece

```
bpm(118)
scale("minor", "a2")
local cut = slider("cutoff", 0.45, 0.1, 0.9)

play("drums", "drum", `x-o- x-[oo]`, {dur: 1/2})
play("bass", "saw", `0.0. 3.5. 0.0. -2.5.`, {dur: 1/2, cutoff: cut, env: 0.4})
play("lead", "square", `0<24>7 5<32>.`, {oct: 2, dur: 1/2, delay: 0.5})
set("lead", {pw: sine(16, 0.2, 0.8)})
delay(0.75, 0.45, 0.4)

shader("""
  float d = length(p * rot(beat * 0.1)) - 0.25 - 0.1 * env[0];
  color = pal(d + beat * 0.05, vec3(0.5), vec3(0.5), vec3(1.0, 0.7, 0.4), vec3(0.0, 0.15, 0.2))
    * smoothstep(0.6, 0.0, abs(sin(d * 30.0 - time * 2.0)));
  color = mix(color, last * 0.96, 0.3);
""")
```

### The notation

A pattern is a string of steps in backticks, after Limut: each character
is a step, and a step takes `dur` beats (a parameter of the player, 1 by
default). Whitespace and double quotes mean nothing, so steps can be
grouped by eye.

| written | meaning |
| ------- | ------- |
| `0123` | scale degrees (any digit; a tonal player) |
| `x-o-` | letters: hits of the kit (a drum player); in a tonal player, the root |
| `-1 0#  3b` | a minus before a digit: below the root; sharp, flat |
| `.` `_` | a rest; a hold, which lengthens the step before by a step |
| `0= 0! 0^ 0v` | longer by half, shorter by a third, louder by half, quieter by a third |
| `0g 1g` | other letters after a digit are flags the piece reads (`func(e){ ... e.flags ... }`) |
| `0[12]3` | a subsequence: its steps share one step (a triplet here) |
| `0(357)` | a chord: its steps play together |
| `0<12>` | a supersequence: its next step each time the pattern repeats (`0102`) |
| `${x}` | a slang value in the pattern: a number is a degree, a letter a hit, a string or a pattern a subsequence |

A pattern is a value: `` `12`:then(`34`) `` plays one after the other,
`:times(2)` repeats, `:crop(5)` takes five steps (repeating when it is
shorter), `:rev()` reverses, `:map(f)`, `:add(n)`, `:mul(k)` change the
values, `:loop(2)` plays twice from the run and stops, `:now()` starts
at its first step on the beat after the run instead of as if it had
played since beat 0. `pattern("0123")` reads the notation from a string.

The kit: `x` kick, `X` a heavier one, `o` snare, `O` a deeper one, `-`
closed hat, `+` open hat, `c` clap, `t` `T` toms, `r` rim, `b` cowbell.
A player registered as `808` instead of `drum` plays the same letters
with the 808's sounds: a kick whose pitch sweeps down from a driven hit,
a snare of two resonators and snappy noise, hats of six square waves
where a closed one chokes an open one, a clap of three bursts and a
tail, the cowbell. A kit's decay (and its open filter) apply where the
player sets none: `{decay: 0.8}` makes every hit of the player ring.

### Players

`play(name, wave, pattern, params)` registers a player: `saw`, `square`,
`tri`, `sine`, `noise`, `fm`, `supersaw` (seven saws spread around the
pitch, the trance stack), `drum` or `808`. Its parameters are numbers,
patterns (`` `0369`:map(...) ``, read at each note's step), signals
(`sine(beats, lo, hi)`, `saw`, `tri`, `square`, `rand(beats, lo, hi)`,
`steps({...}, beats)`), sliders, or functions of the event
(`func(e){ return e.len > 0.3 and 0.1 or 0 }`; `e.value`, `e.len`,
`e.vel`, `e.acc`, `e.flags`, `e.start`, `e.rep`), taken when each note
starts. Signals, sliders and numbers add up with `+ - * / ^ %` and `-x`
into a signal: `cut + sine(5, -0.2, 0.2)` is the slider moved by a sine,
`2 * rand(1)` a doubled random walk.

| parameter | what |
| --------- | ---- |
| `dur` | beats per step (1); `legato` how much of a step a note holds (0.9) |
| `oct`, `scale`, `root` | the player's octave shift, scale and root (else the piece's `scale(name, root)`) |
| `attack decay sustain release` | the envelope, in seconds |
| `cutoff res env` | the filter: 0..1 (20 Hz to 20 kHz), resonance, how far the envelope opens it |
| `gain pan vel` | loudness, -1..1, velocity |
| `detune pw` | a second oscillator in cents (saw, square); the pulse width. For the supersaw: the outer saws' cents (18 when 0) and how loud the six beside the middle one are (0.5) |
| `fm ratio` | the fm wave's index and ratio |
| `drive` | saturation |
| `delay room` | sends to the delay and the reverb |
| `glide` | seconds to the next note's pitch |

`set(name, {...})` sets parameters from now on, for the voices sounding
too: a number at once, a signal or a slider followed every sixteenth of a
beat, so a filter sweeps under a held chord. `delay(beats, feedback,
tone)`, `reverb(size, damp)` and `master(gain)` set the effects the same
way. `hush(name)` lets a player's voices go; `beat()` is the clock.

The scales: major, minor, dorian, phrygian, lydian, mixolydian, locrian,
harmonic_minor, melodic_minor, pentatonic, minor_pentatonic, blues,
whole, chromatic.

### The picture

`shader(glsl)` is the fragment shader of the picture (GLSL 330). The
code is the body of `main`: `uv` (0..1, up), `p` (centered, the
picture's aspect), `last` (this pixel of the last frame) are given,
`color` is the result. It may instead be a whole program with its own
functions and a `void main` (the position is then `gl_FragCoord.xy /
resolution`, not `fragTexCoord`), or a **Shadertoy** program with
`mainImage(out vec4 fragColor, in vec2 fragCoord)`: `iResolution`,
`iTime`, `iMouse` (the mouse while dragged over the picture), `iTimeDelta`
and `iFrame` are defined, so a shader from there runs as it is, and may
read the music too. The uniforms: `time`, `beat`, `resolution`, `mouse`,
`level` (the output's peak), `env[8]` (each player's loudest envelope, in
the order the piece makes them), and `uniform("name", value)` adds one
from a number, a slider or a signal. Helpers: `hash`, `noise`, `pal`
(cosine palettes), `hsv`, `rot`; one the code defines itself is left out.
A shader that does not compile leaves the last one running and says so
(the GLSL errors are printed in the terminal). `glsl.slang` assembles the
program.

## How it is built

- `mini.slang` parses the notation into steps (slang/peg), and
  `notation.slang` is the grammar extension: a backtick literal compiles
  to a call of `pattern.from_tree` with the steps as a table literal, so
  a wrong pattern is a compile error at its line and the editor
  highlights the digits, letters and brackets. `slang.project` loads it
  into every file of the project.
- `pattern.slang` turns steps into events per repetition (a
  supersequence picks by the repetition, a nested one by how often it was
  reached), with the operations on patterns and the signals.
- `engine.slang` is the kernel: 32 voices, each a wave, an envelope, a
  state variable filter, drive and panning, into a tape delay and a
  Schroeder reverb; a player is a row of parameters a voice copies when
  it starts. Instructions arrive through a ring of events in a shared
  buffer, each with a time in samples, and the block function renders up
  to each before applying it, so notes land on the sample.
- `session.slang` keeps the players, controls, tempo and shader across
  runs of the code, evaluates a piece with `api.slang` as its globals
  (`compile` with an environment), and schedules: every frame it asks each
  player's pattern for the events in the next 120 ms and sends them with
  their parameters resolved; live parameters go on a grid of sixteenths.
- `editor.slang` is the text editor and the pixel text; `main.slang` the
  window, the stream, the file, the panel and the shader, drawn into two
  render textures that swap, so a shader can read its last frame.
- `offline.slang` runs a session with the engine in the program itself,
  for `tool/render.slang` and the tests.

On an M2 Pro the first piece takes about 7% of a core at 48 kHz and
renders at ten times real time offline.
