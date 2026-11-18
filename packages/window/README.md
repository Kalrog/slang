# window for slang

Windows, keyboard, mouse and gamepads, through [SDL3](https://libsdl.org)
and `slang/ffi`. The package draws nothing. It gives a renderer a window
to draw into (the `gpu` package's `device:surface(win)` takes one). It
ships SDL 3.4 built for macOS, so there is nothing to install.

```slang
local window = require("window")

local win = window.open({title: "hello", width: 800, height: 600, resizable: true})
for(win.open){
  for(let local e in values(win:events())){
    if(e.type == "key_down" and e.key == "escape"){
      win:close()
    }
  }
  if(window.key_down("w")){
    // ...
  }
}
```

## Using it

Add the package to the project's `slang.project`:

```
dependencies: {window: {git: "<repository>", version: "^1.0"}}
```

Inside the slang repository, use `{path: "../packages/window"}` instead, as
`examples/gpu` does. Then run `slang get`.

The package carries `lib/<platform>/libSDL3` for macos-aarch64 and
macos-x86_64 (about 3 MB each), built by `tool/build.sh` from a pinned SDL
release. Linux builds need a Linux machine with SDL's X11 and Wayland
development packages: run `tool/build.sh` there. `WINDOW_SDL` names
another SDL3 library file.

The package reads `include/window.h`, the part of SDL's API it uses, kept
by hand. SDL's own headers are too heavy on macros for `slang/ffi`, and
`SDL_Event` is a union. When the SDL pin moves, check the header against
the new release.

## In a browser

The package runs in a browser too: slang's graphics VM (`make wasm-gfx`,
the playground's VM) has SDL3 linked in. A window there is the page's
canvas (the element with the id `canvas`): `window.open` sizes it, the
canvas has the keyboard while it has the focus, and `win.native` is
`{kind: "canvas", selector: "#canvas"}`, which the gpu package draws into.
There is one window. `window/audio` is not there (it needs threads).

A browser shows a frame when the program hands it control, which
`surface:present()` of the gpu package does; a loop that never does keeps
the page from answering.

## Windows

`window.open(options)` takes `title`, `width` and `height` (in points, 800
x 600 by default), and the flags `resizable`, `fullscreen`, `hidden`,
`borderless`, `always_on_top` and `maximized`. It also takes `high_dpi`
(true by default), `position` (`{x, y}`) and `min_size`
(`{width, height}`).

A window's properties:

| property | |
|---|---|
| `open` | false once the close button was pressed, the program was asked to quit, or `close()` ran. Reading it takes waiting events in. |
| `title`, `size`, `position`, `fullscreen`, `resizable` | settable |
| `width`, `height` | in points |
| `pixel_size`, `pixel_density`, `display_scale` | what a renderer needs |
| `focused`, `minimized`, `occluded` | read-only state |
| `relative_mouse` | settable: captures the mouse for mouse-look (motion only, in `dx`/`dy`) |
| `text_input` | settable: turns `text` events on |
| `native` | the platform handle: `{kind: "metal", layer}` on macOS, `"x11"`, `"wayland"` or `"windows"` elsewhere |
| `handle`, `id` | the `SDL_Window` pointer and SDL's id |

Methods: `close()`, `events()`, `show()`, `hide()`, `raise_window()`,
`maximize()`, `minimize()`, `restore()`, `warp_mouse(x, y)` and
`message(text, {title, kind})`.

## Events

`win:events()` returns the window's events since the last call, plus the
events that belong to no window. `window.events()` returns every event.
Each event is a table with a `type`, plus `window` when it belongs to one:

| type | fields |
|---|---|
| `key_down`, `key_up` | `key` (the layout's key), `scancode` (the physical key, by its US name), `repeat`, `mods` (`{shift, ctrl, alt, gui}`) |
| `text` | `text` (typed text, with the `text_input` property on) |
| `mouse_move` | `x`, `y`, `dx`, `dy` |
| `mouse_down`, `mouse_up` | `button` (`"left"`, `"middle"`, `"right"`, `"x1"`, `"x2"`), `x`, `y`, `clicks` |
| `wheel` | `dx`, `dy`, `x`, `y` |
| `resize`, `pixel_resize` | `width`, `height` |
| `move` | `x`, `y` |
| `close`, `focus`, `blur`, `show`, `hide`, `expose`, `minimize`, `maximize`, `restore`, `mouse_enter`, `mouse_leave`, `occlude`, `display_scale`, `enter_fullscreen`, `leave_fullscreen` | none |
| `drop` | `path` (a file dropped on the window) |
| `quit` | none |
| `gamepad_added`, `gamepad_removed` | `gamepad` |
| `gamepad_down`, `gamepad_up` | `gamepad`, `button` |
| `gamepad_axis` | `gamepad`, `axis`, `value` (-1 to 1) |

Keys are named the way SDL names them, in lower case with `_` for spaces:
`"a"`, `"1"`, `"space"`, `"return"`, `"escape"`, `"left_shift"`, `"f1"`,
`"up"`.

## Input state

- `window.key_down(name)`: whether the key at that place on a US keyboard
  is held, whatever the layout ("w" is above "s" everywhere).
- `window.mods()`: `{shift, ctrl, alt, gui}`.
- `window.mouse()`: `{x, y, left, middle, right, x1, x2}`.
- `window.mouse_down(button)`
- `window.gamepads()`: the connected gamepads. Each has a `name`, `axis(name)`
  (-1 to 1; triggers 0 to 1), `button(name)` and `rumble(low, high, ms)`.
  Buttons are named by position (`south`, `east`, `west`, `north`),
  plus `start`, `back`, `dpad_up`, `left_shoulder` and so on. Axes are
  `leftx`, `lefty`, `rightx`, `righty`, `left_trigger` and `right_trigger`.
- `window.poll()` takes events in without handing them out.
  `window.wait(ms)` sleeps until an event arrives.

## Audio: window/audio

`require("window/audio")` plays sound through SDL's audio. It needs no
window.

```slang
local audio = require("window/audio")

// a stream computed in slang, in an isolate of its own
local player = audio.play(func(freq){
  local math = require("slang/math")
  local phase = 0.0
  return func(out, frames){
    for(local i = 0; i < frames; i = i + 1){
      out[i] = math.sin(phase * 2 * math.pi) * 0.2
      phase = (phase + freq / 48000.0) % 1.0
    }
  }
}, {args: {440.0}})

// sounds: WAV files or float samples, mixed by SDL
local hit = audio.sound("hit.wav")
hit:play({volume: 0.5, pitch: 1.2})
...
player:stop()
```

**Streams.** `audio.play(setup, options)` has the same API as
`raylib/stream`, so block functions written for it play here unchanged.
`setup(...options.args)` runs in a new isolate and returns
`block(out, frames)`. That isolate computes blocks and pushes them into an
SDL audio stream until SDL holds `latency` frames (1024 by default). SDL
keeps that buffer, so no slang runs on the audio thread and nothing in the
program holds up the sound.
- Options: `sample_rate` (48000), `channels` (1), `block` (128),
  `latency` and `args`.
- The player has `stats()`, which returns
  `{load, peak, underruns, blocks, playing}`, plus `stop()`, the
  `playing` property and a settable `volume`.

**Sounds.** `audio.sound(path)` loads a WAV file, and
`audio.sound(samples, {sample_rate, channels})` takes a slang/buffer of
floats. A sound has `sample_rate`, `channels`, `frames` and `duration` (ms).
- `sound:play({volume, pitch, loop})` returns a voice. Voices overlap, and
  SDL mixes them.
- A voice has `stop()`, `playing`, and settable `volume` and `pitch`.
- `audio.stop_all()` stops every voice.

**The device.** `audio.volume` (settable) is the gain of all sounds.
`audio.driver` and `audio.device_name` say what plays them.

Only WAV is decoded; SDL has no Ogg or MP3 decoder. `examples/tones.slang`
plays a stream and a computed sound over it.

## The rest

- `window.clipboard`: the clipboard's text (settable).
- `window.screen()`: the primary display's size, refresh rate and scale.
- `window.message(text, options)`: a message box.
- `window.open_url(url)`
- `window.cursor(visible)`
- `window.version()`
- `window.c`: every declared SDL function and constant under its C name.
