# Deckhand: plan

A first-person heist game in the spirit of Quadrilateral Cowboy, written in
slang on the raylib package. Started 2026-10-31.

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done, `[-]` dropped.

## The game

You break into buildings with a deck: a laptop you plug into hack ports.
What you type into the deck is **real slang**, compiled in a sandbox whose
globals are the objects on that port's network:

```slang
door1.open(3)              // open for three seconds
cam1.off(5); wait(1); laser1.off(4)
for(local i = 0; i < 3; i = i + 1){ door2.open(1); wait(2) }
```

Scripts keep running after you unplug, so the craft is timing: start a
script, then run through the gap it opens. Cameras sweep and see along the
grid (walls and closed doors block them); lasers trip on contact. Seen or
tripped means the alarm: retry. Take the dossier, reach the exit.

## Design decisions

- **The deck language is slang itself.** `compile(code, origin, env)`
  sandboxes names. Two things it does not do are added by the game:
  - *No hangs*: the player's AST is rewritten before compiling. A call to
    a hidden tick function (named `tick!`, which no program can write) is
    prepended to every loop body and function body. The tick counts steps
    and yields the script's coroutine when its slice is used up, so an
    infinite loop costs a frame budget, not the game.
  - *Time*: every script is a coroutine; `wait(s)` yields until world time
    passes. Scripts run in world time, so tests step the world with no
    window.
- **Limits are the puzzle levers.** An object may cap how long it can be
  opened or switched off (`door1.open(30)` on a door with a 4 s limit
  opens it for 4 s and says so). A port reaches only its network.
- **Maps are ASCII art in a grammar extension** (`dsl/map.slang`), checked
  while the file compiles: rectangular, known glyphs, one start, one
  dossier, one exit, every door between two walls, every camera on a wall.
  Objects are named in reading order (`door1`, `door2`, ...), and the
  mission table configures them by name.
- **Everything but drawing is headless**: `game/world.slang` (simulation),
  `game/deck.slang` (scripts), `game/editor.slang` (the deck's text input)
  and `game/autopilot.slang` (scripted play) never touch raylib, so
  `slang test test` checks them, including a solution run of every
  mission and a failing run for each one's main hazard.
- **Rendering**: walls are one raylib cubicmap model with a procedurally
  drawn texture atlas (no image files); doors, cameras, view cones, lasers,
  ports and props are drawn per frame. The deck and HUD are 2D overlays in
  raylib's pixel font.

## Steps

1. [x] Deck runtime: sandboxed compile, tick injection, coroutine
       scheduler, `wait`, `print`, REPL-style results, errors, stop.
2. [x] Map DSL with compile-time checks.
3. [x] World: grid, collision, doors, cameras (sweep, view cone, line of
       sight, detection meter), lasers, ports, dossier, exit, alarms.
4. [x] Autopilot (path finding + scripted steps) and solution tests.
5. [x] Editor (text input, history) and its tests.
6. [x] Rendering: cubicmap + atlas, objects, labels, cones.
7. [x] HUD, deck panel, screens (title, briefing, failed, complete).
8. [x] Missions: a tutorial curve of six (door, wait, camera, sequence,
       loop, two networks behind glass).
9. [x] Demo mode (`DECKHAND_DEMO`, `DECKHAND_FRAMES`, `DECKHAND_SHOT`) and
       screenshots checked by eye; Makefile target; README.

## Found along the way

- `packages/raylib`: `is_count` took `fontSize` for the length of the
  text before it, so `measure_text(text, size)` measured at the text's
  length (and `measure_text_ex`, `image_text`, `load_font_ex` were off
  too). Fixed in `names.slang`, with a test; stubs regenerated.
- AST nodes report their node type from `type()` (`"For"`, not
  `"table"`), so a generic tree walk must test for "not a primitive".
- `str.char_at` with a double index returns null: grid cells are ints.

## Later

- A weevil: a small robot the deck drives (`weevil.forward(2)`) through
  vents to reach switches.
- Saved programs on the deck, per mission.
- Guards with patrol routes.
