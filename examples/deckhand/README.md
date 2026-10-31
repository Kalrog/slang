# Deckhand

A first-person heist game in the spirit of Quadrilateral Cowboy, written in
slang on the raylib package (`packages/raylib`). You break into buildings
with a deck, a laptop you plug into hack ports, and what you type into it
is **slang**: the doors, cameras and lasers on the port's network are its
globals.

```
brew install raylib
make deckhand          # or: bin/slang run examples/deckhand/main.slang
make deckhand-test     # the tests, no window
```

WASD (or the arrows) move, the mouse looks, E jacks into the port you look
at. On the deck, Enter runs what you typed, Shift+Enter starts a new line,
Up and Down recall earlier entries, Ctrl+C stops every running script, and
Esc unplugs. Scripts keep running after you unplug, so the craft is timing:
start a script, then run through the gap it opens. Esc pauses during play.

```slang
door1.open(3)                          // open for three seconds
cam1.off(6); wait(2); laser1.off(4)    // one thing after another
for(local i = 0; i < 4; i = i + 1){    // loops, functions, locals: all of slang
  cam1.off(2); cam2.off(2); wait(2)
}
help()                                 // what this port reaches
```

Six jobs teach it in turn: a door, `wait`, a camera, a sequence of two
objects, a loop around short-lived cameras, and two networks behind glass
(glass stops you, not the camera behind it). A camera that sees you for
half a second, or a laser you touch, raises the alarm: R tries again.
Objects can have a *limit* (the longest they open or switch off) and a
*rest* (time before they can again), which is what makes the puzzles.

## How it uses slang

- **The deck is a sandbox.** `compile(code, origin, env)` compiles the
  player's code with globals of its own: the network's objects and a few
  builtins (`wait`, `print`, `help`, `stop`, `math`, ...). `require` and
  the rest of the program are not there.
- **It cannot hang the game.** Before compiling, the player's AST is
  rewritten: every loop body and function body starts with a call to
  `tick!`, a name no program can write. The tick counts steps and suspends
  the script once its slice of the frame is spent, so `for(true){}` costs a
  frame budget, not the game. Each script is a coroutine and `wait(s)`
  yields it until the world's clock has moved on (`game/deck.slang`).
- **Maps are ASCII art in a grammar extension.** `dsl/map.slang` adds a
  `map NAME { ... }` statement that parses and checks the art while the
  file compiles: an unknown glyph or a door without walls on both sides is
  a compile error on its row. `game/missions.slang` is written in it:

  ```slang
  map doorman {
    ###########
    #S....P####
    #......D.$#
    #......####
    ##E########
  }
  ```

  `#` wall, `.` floor, `%` glass, `S` start, `$` dossier, `E` exit, `D`
  door, `L` laser, `P` port, `^ > v <` a camera looking that way. Objects
  are named in reading order (`door1`, `cam1`, ...); `game/grid.slang` has
  the details.
- **No image files.** Walls are one raylib cubicmap model; its texture
  atlas is drawn pixel by pixel in `game/render.slang`.

## Layout

```
main.slang            the window, the screens and the input
dsl/map.slang         the map statement (a grammar extension)
game/grid.slang       parsing and checking maps
game/world.slang      the simulation: moving, doors, cameras, lasers, the deck's objects
game/deck.slang       running the player's code: sandbox, tick guard, scheduler
game/editor.slang     the deck's input line
game/missions.slang   the jobs
game/solutions.slang  a way through each job (for the tests and the demo)
game/autopilot.slang  plays steps as a player would: path finding, jacking in, typing
game/render.slang     3D drawing
game/hud.slang        the deck panel, the HUD and the screens
test/                 the tests
PLAN.md               the plan and what was found along the way
```

Everything but `render`, `hud` and `main` runs without a window. The tests
play every job with the autopilot to prove it can be won, and play the
obvious shortcut to prove it fails.

## Demo mode

```
DECKHAND_DEMO=relay DECKHAND_SHOT="300:a.png,600:b.png" bin/slang run examples/deckhand/main.slang
```

`DECKHAND_DEMO=<job>` lets the autopilot play that job's solution on screen,
typing its code into the deck; `DECKHAND_FRAMES=n` quits after n frames;
`DECKHAND_SHOT=n:file.png,...` saves screenshots (into the working
directory).
