# Siege

A 3D catapult game in slang on the `raylib` and `jolt` packages. Drive a
catapult across a height-map world, aim with the mouse, hold to wind it
and let go to throw. The targets are buildings of stone (heavy, never
breaks), wood (breaks), glass (shatters) and barrels (explode), with
furniture inside that is worth the most. Points come for every part
knocked loose, smashed or blown up; each level has a target and limited
ammo. A level editor sculpts the ground, places parts, whole buildings,
decorations and joints, and saves levels as JSON.

```
make siege             # or: bin/slang run examples/siege/main.slang
make siege-test        # the tests, no window
```

The game runs in the browser too, on the website's graphics VM
(`make wasm-gfx`, then `make website`): the page under /siege/.

## Playing

- W A S D or the arrows drive, space is the handbrake, R rights the
  catapult, right drag looks around, the wheel zooms.
- The mouse aims: left and right turn the arm, up and down lift it. Hold
  the left button to wind, let go to throw. The dotted line shows where
  the shot lands.
- 1 2 3 4 or Tab choose the ammo: a rock, a triple shot, a bomb (goes
  off where it lands) and a chain shot (two balls on a rope).
- Water is the edge of the world: drive in and you start over at the
  spawn.
- Esc pauses, F1 shows the help.

## The editor

From the title screen: *Level editor* starts from flat ground, *Edit
selected* opens a copy of a level. The tools along the top:

- **Terrain**: raise, lower, smooth or flatten with a brush (shift
  reverses it); *new hills* makes a fresh landscape from a seed.
- **Water**: the water level.
- **Place**: one part of any material and shape; click a part to select
  it, drag it, Q/E turn it, R/F lift it, D with a modifier copies it, G
  selects its whole group, Delete removes it.
- **Build**: a wall, tower, house, stack of crates, pillar or bridge with
  its own parameters; the ground under it is flattened.
- **Decor**: trees, pines, bushes, flowers, boulders.
- **Joint**: fixed, hinge, point or distance joints between two parts.
- **Spawn**: where the catapult starts and its heading.
- **Level**: the name, the target, the ammo; *Settle parts* runs the
  physics until everything rests and keeps those positions.

*Test* plays the level as it is (Esc comes back), *Save* writes
`levels/<name>.json` next to the built-in levels, which the title screen
lists. In the browser the JSON is printed under the game instead, to
keep as a file.

## How it is built

- `game/world.slang`: the Jolt world. Every part is a body with a
  material; after each step the contacts Jolt reported say what hit what
  and how hard (the bodies' velocities as they hit, before the contact
  was resolved), so things break, barrels explode and points are
  awarded. Only Jolt's list of awake bodies is visited each frame.
- `game/vehicle.slang`: the catapult is a Jolt wheeled vehicle (ray-cast
  suspension, four driven wheels) with a turret drawn on top.
- `game/terrain.slang`: a height map that becomes a raylib mesh with
  vertex colors and a Jolt height field.
- `game/structures.slang`: procedural buildings: walls of staggered
  bricks cut around doors and windows with lintels over them, towers of
  rings, houses with gable roofs on a ridge beam and furniture inside,
  bridges, stacks; the cone roof of a tower is one piece through fixed
  joints.
- `game/render.slang`: one lighting shader (GLSL 330 on the desktop, 100
  in the browser) that samples every texture triplanar in the object's
  own space, so the generated shapes need no texture coordinates;
  `game/textures.slang` makes every texture at start from noise, and
  `game/sound.slang` every sound from numbers. The only file loaded is
  the font, Fredoka (OFL, `assets/`).
- `game/levels.slang`: the level format, a builder the built-in levels
  (`levels/*.slang`) are written with, JSON saving and loading.
- `game/editor.slang`, `game/ui.slang`, `game/hud.slang`,
  `game/particles.slang`, `game/ammo.slang`.

From the environment: `SIEGE_FRAMES=n` quits after n frames,
`SIEGE_LEVEL=n` starts in a level, `SIEGE_AUTOPLAY=1` drives and fires
by itself, `SIEGE_SHOT=n:file.png` saves screenshots, `SIEGE_DEBUG=1`
prints every scoring event, `SIEGE_EDITOR=n` opens the editor.
