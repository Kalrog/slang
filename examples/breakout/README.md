# Breakout

A breakout game on [raylib](https://www.raylib.com), written in slang. The
window, drawing and keyboard come from the raylib package
(`packages/raylib`), a dependency of this project by path (`slang.project`,
`slang.lock`); `require("raylib")` loads it.

```
brew install raylib        # raylib 5.x (the package calls it through slang/ffi)
make breakout
```

Left/right or A/D move the paddle, space launches the ball, R restarts,
escape quits.

`BREAKOUT_FRAMES=600 BREAKOUT_AUTOPLAY=1 make breakout` plays by itself for
600 frames and exits, which is how the package is smoke-tested.
