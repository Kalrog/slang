# microphone

Audio input for slang programs: the devices that record (CoreAudio on
macOS), read as float samples a block or a frame at a time.

```
local microphone = require("microphone")
microphone.devices()                 // {{name: "MacBook Pro Microphone",
                                     //   channels: 1, default: false, ...}}
local mic = microphone.open()        // the default input, or
                                     // open({device: "macbook"}) (part of
                                     // a name, or an index)
local samples = kernel.float:array(512)
local n = mic:read(samples)          // frames read, up to 512
mic.level                            // the peak since the last look, 0..1
mic:close()
```

- **Recording**: `open(options)` starts an AudioQueue on the device; the
  system calls back on its own thread about every 10 ms and the samples
  go into the input's ring (two seconds by default, `buffer` frames).
  `read(buffer)` takes what waits; `read()` returns it as a new buffer.
  Samples are floats, channels interleaved, at `sample_rate` (48000 by
  default; the system converts from the device's rate, so a 16 kHz headset
  reads as 48 kHz) and `channels` (1 by default). Nothing runs slang on the
  audio thread, so any isolate may open its own input: a synth's render
  isolate reads it every block.
- **A full ring** loses its oldest frames (`mic.dropped` counts them): a
  reader that falls behind hears the latest sound, not a growing delay.
- **Properties**: `level` (the loudest sample since it was last read),
  `waiting`, `dropped`, `name`, `sample_rate`, `channels`.
- **Virtual inputs**: `microphone.virtual(options)` has no device; what
  `write(buffer)` puts in is what `read` takes out. Tests use it, and a
  program can play a file into code written for the microphone.
- **Permission**: macOS asks once whether the app that runs slang (the
  terminal or editor) may use the microphone; until it may, it records
  silence. `microphone.permission()` says `"granted"`, `"denied"`,
  `"restricted"`, `"undetermined"` or `"unknown"` (from AVFoundation, through
  the Objective-C runtime). The setting is in System Settings, Privacy &
  Security, Microphone.
- `microphone.available()` says whether this platform can record (macOS so
  far; ALSA/PipeWire and WASAPI are to come).

examples/granular records with it.

## The native module

`native/microphone.c` (the module `microphone/native`, against slang.h)
ships prebuilt as `lib/<platform>/native.dylib`; `tool/build.sh` rebuilds
it (Zig 0.17 and, on macOS, the Xcode command line tools for AudioToolbox
and CoreAudio). `make microphone-test` runs the tests, which need no
device.
