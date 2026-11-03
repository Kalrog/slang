# midi

MIDI for slang programs: input from controllers and other programs
(CoreMIDI on macOS), Standard MIDI Files, and MIDI learn.

```
local midi = require("midi")
midi.inputs()                        // {"MPK mini 3", ...}
local input = midi.open()            // every source, or open(0), or
                                     // open("mpk") (part of a name)
for(let local m in values(input:read())){
  if(m.kind == "note_on"){ ... m.note, m.velocity ... }
  else if(m.kind == "cc"){ ... m.controller, m.value ... }
  else if(m.kind == "bend"){ ... m.value (-1..1) ... }
}
input:close()
```

- **Input** (`midi`): messages arrive on CoreMIDI's thread and wait in the
  input's ring (4096 of them) until `read`, which returns them decoded:
  `{kind, channel (1..16), ...}` for note_on, note_off (a note on with
  velocity 0 too), cc, bend, program, pressure and aftertouch. Sysex and
  real-time bytes (clock, start, stop) are dropped. Nothing runs slang on
  CoreMIDI's thread, so any isolate may open its own input: a synth's
  render isolate reads the notes every block, its window every frame.
  `midi.available()` says whether this platform has MIDI input (macOS so
  far; ALSA and Windows are to come).
- **Files** (`midi/file`): `read(path)` gives the notes of each track,
  the tempo map and track names of a Standard MIDI File (formats 0 and 1);
  `seconds(m, tick)` places a tick in time.
- **MIDI learn** (`midi/map`): `load(path)` keeps bindings of controllers
  to a program's targets (strings) in a JSON file; `arm(target)` makes the
  next controller that moves bind to it, `target(message)` says what a cc
  message moves, `binding(target)` gives "CC 74" for drawing.

examples/synth and examples/fm are played with it.

## The native module

`native/midi.c` (the module `midi/native`, against slang.h) ships
prebuilt as `lib/<platform>/native.dylib`; `tool/build.sh` rebuilds it
(Zig 0.17 and, on macOS, the Xcode command line tools for CoreMIDI).
`make midi-test` runs the tests, which need no device.
