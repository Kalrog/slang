# Breakout

A breakout game on [raylib](https://www.raylib.com), written in slang. The
window, drawing and keyboard come from the native extension
`extensions/native/raylib.c`, a 200-line C file against `zig/include/slang.h`
that `zig build` compiles into `zig/zig-out/lib/raylib.dylib` (or `.so`);
`require("raylib")` loads it at run time.

```
brew install raylib        # or any raylib 5.x; see -Draylib-prefix in zig/build.zig
make breakout
```

Left/right or A/D move the paddle, space launches the ball, R restarts,
escape quits.

`BREAKOUT_FRAMES=600 BREAKOUT_AUTOPLAY=1 make breakout` plays by itself for
600 frames and exits, which is how the extension is smoke-tested.
