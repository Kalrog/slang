# Switchback

An off-road drive up a valley made from a seed, in slang on the raylib,
Jolt and kernel packages. A trail leads from the meadow by the river
through a ford, mud holes, washouts and moguls, past the lake, up the
hillside in switchbacks, between rock walls, over ledges, through rock
gardens and fallen trees, into the snow and onto the summit of the
valley's highest mountain. The clock runs from the trailhead to the
summit, with checkpoints between; the truck is yours to fit out.

```sh
make switchback        # or: slang run examples/switchback/main.slang
make switchback-test   # the drivetrain, the truck, the land, the trail, the bot and a run, without a window
```

![Switchback](switchback.png)

Sound is not in yet.

## Driving

`W` and `S` (or the arrows) drive and brake; `S` again at a standstill
reverses. `A` and `D` steer, `Space` is the hand brake. `Q` changes
between high and low range, `E` goes through the differential locks (open,
rear, rear and front; in low range the center is locked as well). `F`
hooks the winch to the nearest tree ahead (or to a ground anchor where
none stands) and pulls; `F` again lets go. Holding `R` puts the truck back
on the trail, for twenty seconds on the clock. `C` changes the camera, the
mouse looks around, `Esc` pauses.

A gamepad works too: right trigger drive, left trigger brake, left stick
steer, A hand brake, X low range, Y locks, d-pad up the winch, B (held)
back on the trail, right stick look, Start pause.

The gearbox shifts by itself. On a slope the truck holds itself when you
let go of the pedals and rolls away without rolling back when you drive
on. Knocks do damage, shown in the HUD; a wreck costs forty-five seconds.

## The truck

One truck, built from code (`render/truck*.slang`), with a garage on the
title screen and in the pause menu: ten paints and a roof color, three
kinds of wheels, a stock bumper, a bull bar or a winch bumper, a basket
rack, an expedition load or a roof tent, a light bar, a snorkel, the spare
on the tailgate, rock sliders or side steps, mud flaps. What you choose is
kept in `~/.switchback/settings.json`, your best time of each valley in
`~/.switchback/best.json`.

Underneath it is a Jolt body on four wheels (`game/car.slang`). Jolt finds
the ground under each wheel and carries the truck on springs that are part
of its solver, so the suspension settles in one swing and never rings;
each tire is held to the ground as a contact that does not slip until it
is asked for more than it has, which is why the truck stands still parked
across a slope and does not creep downhill on a slow traverse. Everything
else is slang:

- `game/drivetrain.slang`: an engine with a torque curve, a turbo's lag,
  an idle governor and a limiter; a clutch, five gears and a low range;
  center, front and rear differentials that can be locked. Engine and
  wheels are one system of equations solved once a step, so the engine's
  speed follows the road's while the clutch holds, the engine brakes the
  truck downhill, and a spinning wheel takes the revs up.
- `game/tires.slang` and `game/surfaces.slang`: what a tire can push and
  hold on rock, dirt, gravel, grass, sand, mud, snow, ice and a river's
  bed, by how it slips: loose ground gives its best only to a wheel that
  digs, and a sliding tire's grip goes against the slide.
- `game/winch.slang`: the line as a spring that the drum shortens.

`tool/lab.slang` is the test bench: the truck on tilted planes of every
surface, with numbers for what it does.

## The valley

Every seed is a valley (`game/terrain.slang`, its kernels in
`game/land.kernel`): a river winding through a lake, a floor of meadows,
foothills, benches and strata, mountains shaped by erosion, and one
mountain over the rest with a snow dome for a summit (its natural tops
are horns no track could climb). The heights are computed on every core
in a second or two.

The trail is nobody's drawing (`game/route.slang`): it is the cheapest way
over the land for something that cannot turn on the spot and may not climb
steeply, so it winds up slopes in switchbacks by itself, five to seven
kilometers to the top. It is cut into the land as a track with banks,
fords the river where the river is given a shallow, crosses a ridge by a
pass where it would otherwise be a trench, and gets an obstacle every few
hundred meters that suits where it is: mud holes, moguls, washouts,
off-camber stretches, narrows between rock, rock steps, rock gardens,
deadfall. The truck drives on the same triangles the picture shows, half
a meter to the sample.

Woods, bushes, boulders and logs are set on the land by kernels
(`game/plants.slang`), not on the track, and what stands near the truck is
solid. The grass is placed by the graphics card, lies down under the truck
and stays down where its wheels went; the wheels leave tracks in mud, snow
and sand (`render/tracks.slang`) and throw up dust, clods and spray
(`render/dust.slang`), and the truck gets muddy until a ford washes it.

`New valley` on the title screen takes the next seed.

## How it is laid out

- `game/`: the game without a window: the land, the trail, the truck, the
  world they are in, the run's rules (`run.slang`), the bot that drives
  the trail in the tests (`bot.slang`).
- `render/`: the picture: the scene's passes (`scene.slang`: shadows, the
  land as a clipmap, plants, grass, water, dust, then bloom and grading),
  the HUD and the menus.
- `tool/`: `lab` (the physics bench), `map` (a valley as a picture),
  `drive` (the bot drives a whole trail and reports), `view` (a camera on
  the bot), `showroom` (the truck), `arboretum` (the plants), `ui_preview`
  (the HUD and menus).
- `test/`: what `make switchback-test` runs.

For tests and pictures `main.slang` reads the environment
(`SWITCHBACK_SEED`, `SWITCHBACK_AUTOPLAY`, `SWITCHBACK_AT`,
`SWITCHBACK_SHOT` and others, listed at its top).
