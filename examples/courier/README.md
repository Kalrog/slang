# Courier

Deliveries by flying car through a night city, in slang on the raylib and
Jolt packages. The city is made from a seed and a level: blocks of towers
in tiers, with ledges, fins, billboards, halo platforms and antenna masts
sticking out of them, skybridges and glass tubes across the streets, and
traffic, thousands of cars, flying both ways along every street at six
heights. Pick up a
package at one pad and deliver it to another before the clock runs out.
Pay comes from the distance, the time left and the package in one piece.

```sh
make courier           # or: slang run examples/courier/main.slang
make courier-test      # the city, the car, the traffic and the jobs, without a window
```

![Courier](courier.png)

## Flying

The mouse steers: moving it pushes a reticle away from the middle of the
screen, and the car turns toward the reticle, pitching and banking into
the turn; let the mouse rest and the reticle drifts back, and the car
levels itself. `W` is thrust, `S` brake and reverse, `Space` or the left
button boost. The full set is there for whoever wants it: `A`/`D` roll,
`Q`/`E` yaw, the arrow keys pitch and roll. A gamepad works too: left
stick pitch and roll, right stick yaw, triggers thrust and brake, A boost,
X magnet.

`F` or the right button is the magnet. Near a wall, a roof, the underside of a bridge or the
ground, the car is pulled onto the surface and drives along it as if that
were the ground: steer with yaw or roll, thrust and brake as before, and
the camera rolls with you, so a wall becomes a road and the street a
cliff. Drive off the edge and you fly again; press it again to let go with a
hop. Hard knocks shake it loose.

Speed is the point, and the question is always how much of it you can
afford:

- **Boost** burns a meter. It refills slowly by itself, fast when you
  **skim** a surface at speed (within a few meters, a wall, a roof or a
  bridge) or ride one with the magnet, and in a jump for every **close
  call** with traffic. Flying close to things is how you go faster.
- **Hits** cost hull by how hard you hit (anything above a scratch), knock
  the boost meter down, send the other car spinning out of its lane, and in the deliver phase bruise the package,
  which pays less; fragile packages bruise twice as fast and pay more.
- The hull gone, the car is **wrecked**: the job is lost, the fine is $50,
  and you start again at the last pad.
- The pad wants you **slow**: under 65 km/h within seven meters, so every
  run ends in braking you have to time.
- The clock runs from the moment the job is posted; a **late** delivery
  pays a third. `R` takes you back to the last pad for $20 when you are
  lost.

## Districts

The game has levels, the districts of `game/levels.slang`. You start in
the **Outskirts**: a wide grid of low, plain towers with few bridges,
wide streets, a few slow cars in three lanes of height, and a generous
clock. Three deliveries move you to **Midtown**, then **Downtown**
(the city of the screenshot), then **The Core**: tall towers with
everything hanging off them, bridges and tubes everywhere, seven heights
of traffic with three fast lanes side by side in each direction, and a
clock that assumes you fly fast. Past the Core the city comes back faster
each time. Credits and the count of deliveries carry over; the hull is
new. Each district is a table of numbers: the grid, the street width, the
heights, how much sticks out of the towers, the bridges, the lane heights
and offsets (three lanes each way in the Core), the cars and their speeds, the time budget and the
deliveries needed. The title screen is the menu: choose a district with
the arrow keys or the mouse and press Enter (or click) to start there;
`COURIER_LEVEL=n` picks district n from the start.

## How it is built

- `game/city.slang`: the generator. Everything solid is an axis-aligned
  box with a kind (facade, neon, structure, billboard, pad, ground) in a
  spatial grid. Towers are stacks of inset tiers, decorated per tier;
  bridges span neighbouring blocks at heights between the traffic lanes
  (open slabs with rails, or tubes with lit walls to fly through); pads
  are placed last, only where the air above them is clear.
- `game/car.slang`: the car is a Jolt rigid body. Thrust, drag (little
  forward, a lot sideways, less of it the faster it goes, so it drifts),
  the turning rates and the self-leveling are forces and torques; the
  magnet is a spring to the surface and a torque to its normal. Jolt
  resolves the collisions, and its contact reports become hits.
- `game/traffic.slang`: thousands of cars, and nothing is stepped. Every
  lane is a conveyor: its cars share its speed and keep their order, so a
  car's place is a formula of the time (start plus speed times time,
  wrapped at the city's edge). The renderer moves every car in the vertex
  shader from that formula, in one static mesh per 65k vertices; only the
  cars near the player get kinematic Jolt bodies from a small pool, found
  by a binary search along each nearby lane.
- `game/world.slang`: the physics world with every box as a static body,
  the fixed steps, the jobs, the pay, the wrecks.
- `game/bot.slang`: an autopilot with ray feelers, for the tests and
  `COURIER_AUTOPLAY=1`.
- `game/render.slang`: one shader paints every surface from what its
  vertices say it is: facades grow their lit windows in the fragment
  shader (a grid of cells, each lit or dark by a hash, warm or cold, some
  flickering), neon glows, billboards animate, bridges run their lights,
  pads pulse, the street grid shines up through the haze. The frame is
  drawn to a texture, its bright parts blurred into a bloom, and
  composited with a radial blur that grows with speed, chromatic
  aberration when boosting, and a vignette. A sky pass behind it draws the
  haze at the horizon and the stars. The city's boxes become one mesh per
  block.
- `game/hud.slang`, `game/sound.slang` (every sound computed at start),
  `game/fx.slang` (sparks, streaks), `main.slang` (the window, the input,
  the camera).

For a smoke test with a window: `COURIER_SEED=11 COURIER_AUTOPLAY=1
COURIER_FRAMES=600 COURIER_SHOT=500:frame.png slang run main.slang`
(`COURIER_START=1` skips the title without the autopilot).

## Tuning the handling

The numbers at the top of `game/car.slang` are the feel: `ACCEL` and
`TOP_SPEED` (drag is derived so they balance), `BOOST_FACTOR` and
`BOOST_DRAIN`, the `PITCH_RATE`, `ROLL_RATE` and `YAW_RATE` at full stick,
`STEER_RATE` on a surface, and the grip in `control` (how fast sideways
velocity dies, and how much less at speed). The camera's lag, distance
and field of view with speed are in `update_camera` in `main.slang`.
