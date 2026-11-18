# slang tracker

A tracker: a song is patterns of rows, each row a sixteenth, each track a
column of notes; the patterns play in an order. The sound is
packages/studio's: every track is one of its instruments with its own
effects, sending to an echo and a hall, into a limiter on the master. The
window is a picture of 752 x 444 scaled by whole pixels, in raylib's own
pixel font.

```
make tracker               (or: cd examples/tracker && slang run main.slang)
slang run main.slang songs/relay.json
make tracker-test          no window, no sound card
slang run tool/render.slang songs/dusk.json out.wav
```

Needs raylib (`brew install raylib`). It opens the first song of `songs/`:
`dusk` is four chords at 100 (an 808, a bass, an electric piano, a pad
that ducks under the drums, a bell), `relay` four on the floor at 126 (an
acid line whose filter the lane plays, chords of seven saws pumped by the
kick, a plucked answer). Both are made by `tool/demos.slang`.

## The pattern

Per track, from left to right: one to four **note columns**, each a note
(`C-4`, or `===` where the note before ends) with a **velocity** (00 to
99; none is 80), and one **lane**: values from 00 to 99 for the parameter
the track's lane names (the bass's cutoff, say), 00 the bottom of that
parameter's slider and 99 its top. A note sounds until the next note of
its column or an `===`.

| key | does |
| --- | --- |
| arrows | move; with shift, select |
| tab, shift+tab | the next track, the one before |
| `Z S X D C V G B H N J M ,` | notes from C, at the cursor and heard at once |
| `Q 2 W 3 E R 5 T 6 Y 7 U I` | the same an octave up |
| `1` | `===`: the note ends here |
| `9`, `0` | an octave down, up |
| digits | in a velocity or a lane: its value (`4` then `5` is 45) |
| backspace, delete | clear the cell, or the selection |
| space | play the pattern round and round, or stop |
| shift+space | play the song from this place in the order |
| enter | play the pattern from the cursor's row |
| escape | no selection, no menu |
| F1 | the keys, on the screen (also command+G, and `keys` at the top) |

The note keys are where a piano's would be, whatever the keyboard's
layout types there. After a note the cursor moves on by STEP.

On a **drums** track the keys are the drums, whatever the octave, and the
pattern shows them by name: `Z` the bass drum (`BD`), `S` the rim (`RIM`),
`X` the snare (`SD`), `D` the clap (`CLP`), `C` a deeper snare (`SD-`),
`G` the closed hat (`HH`; `H` a shorter one), `J` the open hat (`OH`),
`V B N M ,` and `W` toms from low to high (`TM1` to `TM6`), `2` a long
open hat, `3` a long closed one, `6` the cowbell (`COW`). A hit rings
out by itself; a closed hat ends an open one. The track's panel has each
drum's level, tuning and decay, and the `kit` (plain or 808). A note that
is no drum (from a pattern pasted in, say) shows red and is silent.

With command (control elsewhere), by the letter your layout types:

| key | does |
| --- | --- |
| S, O | save; open the next song of `songs/` |
| shift+N | a new song (saved as `songs/untitled.json`; rename the file to name it) |
| Z, shift+Z | undo, redo (what was typed into patterns) |
| C, X, V | copy, cut, paste the selection |
| A | select the track's rows; again, the whole pattern |
| U, J | the selection's notes a semitone up, down (with shift, an octave) |
| I | fill a velocity or a lane between the selection's first and last row |
| N, D | a new pattern after this one; a copy of this one |
| T, K | a new track; remove the cursor's track |
| F | follow the song as it plays, or stay |
| P | show or hide the panel |
| E | render the song to a WAV file next to it, while it plays on |
| G | the keys, on the screen |

A new song or the next one asks once before it leaves unsaved changes
behind: the same key again does it.

## The rest of the window

- **The top**: BPM, LPB (rows a beat), SWING, OCT, STEP and ROWS (the
  pattern's length) change with the mouse wheel over them, or a click
  (left up, right down; shift for tens of BPM). `echo`, `hall` and `master`
  put that strip in the panel; `+` beside them adds a bus (up to four),
  named after the effect it starts with, and a bus's panel has
  `remove bus` at its top. Tracks send to a bus at the bottom of their
  panel. `keys` shows what the keys do. At the right, the master's scope
  and meters.
- **ORDER**, at the left: which pattern plays when. Click a place to see
  its pattern; the wheel over a place changes which pattern it is; `+ add`
  repeats the place, `- del` takes it out, `new` and `copy` make a pattern
  after it.
- **A track's header**: click it and the track is the panel's; right click
  mutes it. Its meter is under its name.
- **The panel**, at the right, shows one strip: a track, a bus or the
  master. Its tabs are the track's instrument and the strip's inserts
  (`+` adds one, up to four). Under them the unit (`change` picks another
  instrument, `remove` takes an insert out), its PATCH (click or wheel for
  the next), a track's LANE (the parameter its lane plays; right click for
  none) and COLS (its note columns), a compressor's HEARS (itself, or the
  track it ducks under). Then the unit's parameters: drag a slider, click
  what has few settings to step through them, right click for the default;
  the wheel scrolls. At the bottom the strip's GAIN, PAN and MUTE, and a
  track's sends to the buses.
- A **MIDI controller** plays the cursor's track.
- A song file dropped on the window is opened. A **WAV file** dropped on it
  becomes the recording of the cursor's track when that is a `sampler`
  (one zone, at its pitch on C-4) or `grains`.

## The files

| file | what it is |
| --- | --- |
| `song.slang` | the song as data: tracks, buses, patterns, the order; undo; JSON |
| `player.slang` | a studio built from a song and kept in step with it; rows sent as timed notes; offline rendering |
| `grid.slang` | the cursor, the selection and what keys do to cells |
| `view.slang`, `panel.slang`, `gfx.slang` | the pattern, the panel and text on the screen |
| `main.slang` | the window, the top, the order, the keys |
| `layout.slang` | which key types which letter (from examples/live) |

A song is saved as JSON: every track's instrument, patch and the
parameters changed from it, its inserts and sends, the patterns' cells.

`TRACKER_FRAMES=n` quits after n frames, `TRACKER_SCREENSHOT=file.png`
saves the last frame, `TRACKER_PLAY=1` starts playing, `TRACKER_MUTE=1`
keeps the sound card silent, `TRACKER_VIEW` says what is shown at the
start (`master`, a bus's name, `fx`, `menu`, `bus`, `keys`, `closed`,
`select`, a track's number; several with commas).

## What it does not do yet

- Undo covers what is typed into patterns, not tracks, inserts or
  parameters.
- Changing a track's instrument or removing a track builds every strip
  again, so what sounds stops for a moment.
- A sampler track has one recording; multisampled zones are the studio's
  but not the tracker's yet.
- Notes played on a MIDI controller are heard, not written down.
- A song's first second loads its instruments' kernels; the sound card
  waits for it.
