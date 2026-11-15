# dsp

A player and a car, written in the block-diagram language of
[packages/dsp](../../packages/dsp) (after [Faust](https://faust.grame.fr):
programs compiled, when the slang file is, into kernels that compute a
block of samples in one tight loop; the language is described there).

```
make dsp            # the player: five instruments, an echo, a reverb
make car            # a car to drive: engine, gears, tyres, wind, inside or out
make dsp-test       # the package's tests and this example's (no window, no audio device)
cd examples/dsp && ../../bin/slang run tool/bench.slang     # how fast
cd examples/dsp && ../../bin/slang run tool/render.slang out # WAVs
```

In the player, A W S E D F T G Y H U J K play an octave (by position, as
on a piano), Z / X move it, 1-5 or the tabs pick the instrument, sliders
change what the program declares, and the code beside them is the kernel
generated for the instrument.

## A car

`programs/inline4.dsp` is a physical model of a car: a 1.8 litre petrol
four-cylinder with firing order 1-3-4-2, a clutch, a six-speed gearbox and
1250 kg of car, written in the language (some 340 lines with its comments)
and compiled to one kernel of some 1000 lines. `make car` drives it:

| key        | does                                |
| ---------- | ----------------------------------- |
| W, up      | throttle                            |
| S, down    | brake                               |
| E / Q      | shift up / down                     |
| A          | the automatic on and off            |
| V          | in the driver's seat / beside the road |
| R          | the road: asphalt, chip seal, cobbles |

The clutch is worked for you (driver.slang): a shift lifts off the
throttle, presses the clutch, changes the gear and lets the clutch out
over 0.3 s (blipping the throttle on a downshift to match the revs);
pulling away the clutch bites as the revs rise, and it opens again below
1100 rpm at walking pace, so the engine idles when the car stops. The
automatic shifts up at 6200 rpm and down when the revs fall (later the
harder the throttle is pressed). The window shows the tachometer, the
speedometer, the gear, the pedals, the pressure in cylinder 1 over its
cycle and the pressure in the exhaust collector; the sliders change the
engine.

Petrol decides the architecture: a throttle plate meters the air, so the
manifold holds a vacuum at idle and the cylinders start compressing from a
third of an atmosphere; a spark lights the charge, which burns over some 55
degrees; the engine revs to a limiter that cuts the sparks.

- **Crank and car**: two states in one feedback loop, the crank's speed
  and the car's. The combustion's torque (180 Nm at most, at 4200 rpm)
  less friction and pumping (engine braking with the throttle shut) turns
  the crank and flywheel; the clutch carries the torque the slip between
  the crank and the gearbox asks for, up to its grip, so it slips pulling
  away and while it is let out after a shift; through the gearbox (3.5,
  2.1, 1.4, 1.03, 0.82, 0.68) and the differential (4.1) to the wheels,
  against the air (0.39 v²), the tyres' rolling and the brakes. An idle
  valve keeps the engine at 800 rpm; the limiter cuts the sparks at 6800
  rpm and lets go 250 rpm lower (it bounces). The cycle is two turns, each
  cylinder a quarter of it after the last in the firing order. Flat out
  the car reaches 100 km/h in about 11 s.
- **Cylinders**: volume from the crank angle (with the rod's second
  harmonic), suction while the intake valve is open, polytropic compression
  and expansion while both are shut, the combustion's pressure rise as a
  Wiebe function after the spark, and the blowdown, as fast as the exhaust
  valve opens. The combustion varies from cycle to cycle, and its rate
  rings the chamber's first acoustic mode (around 6.5 kHz).
- **Valves**: cam timing with overlap at top dead centre; each valve an
  orifice between its cylinder and its port, its share of the port's
  impedance growing quickly with its lift (the gas through the first
  millimetres at the speed of sound), so the blowdown is a steep pulse.
  No two cylinders burn quite alike (a fixed bias each, and the roughness
  from cycle to cycle): the idle has a little burble.
- **Gas paths**: thirteen digital waveguides (pairs of delay lines as long
  as the pipe at the speed of sound in its gas, hot or cool, with losses
  that grow with length and take the highs first), joined where pipes meet
  by scattering junctions weighted by area. On the exhaust side there are four
  header runners of slightly different lengths, a four-into-one collector,
  the down pipe, the muffler and the tailpipe. The muffler is a volume (its
  junction's pressure follows the waves through a lowpass, as a volume
  fills and empties), a chamber whose packing absorbs the highs (more the
  higher the `muffler` control), and a perforated outlet that reflects
  little, so the tailpipe does not ring. On the intake side there are four
  runners, the plenum, the throttle body (the plate an orifice as open as
  the throttle) and the air filter's snorkel. Closed valves reflect waves;
  the open ends reflect them inverted but for the highs, and what they
  radiate is the flow out of them changing (a pulsating source, heard from
  afar), rising 6 dB an octave. All 26 waves go round one `~` loop.
- **Mechanics**: the block's modes struck by the cylinders' pressure
  changes, the valve train ticking as valves seat, piston-ring friction,
  the alternator's whine, and afterfire pops on the overrun.

The program is a library as well: a `dsp` block can
`import "programs/inline4";` and compute its own `process` from the
engine's definitions (a probe of the valves, another mix).

### Hearing it

`programs/inline4.dsp` does not mix: it puts out stems, the sound
radiated at the tailpipe and at the air filter, the mechanical noise and
the engine's vibration (gas torque ripple and the second-order inertia an
inline four does not balance), with the speed. `programs/acoustics.dsp`
takes them as inputs, adds what the car meets, and is the listener
(`vehicle.slang` runs the two programs one after the other, a kernel
each):

- **Tyres**, four of them with noises of their own: tread blocks of three
  lengths striking the road (so they do not whistle), the air pumped out
  of the closing grooves (louder with the square of the speed, in the
  horn's band between tyre and road), the road's texture shaking tread and
  carcass (its pitch rising with the speed), the cavity resonance of the
  air in the tyre (some 215 Hz), and cobbles striking one by one. The
  `road` control picks smooth asphalt, coarse chip seal or cobbles.
- **Wind**: the turbulent boundary layer (its pressure growing with the
  cube of the speed, so with the sixth power in sound power), in gusts,
  and the vortices shed behind the mirrors.
- **Beside the road**, a few metres from the left side: each source at
  its place (the exhaust behind, the engine in front, a tyre at each
  corner) and the ground's reflection 1.8 ms late.
- **In the driver's seat**: the sound through the walls, each its own
  (the floor for the exhaust, the bulkhead for the engine, the wheel
  arches for the tyres, the glass and seals for the wind), letting less
  through the higher it is; the vibration through the engine mounts and
  the suspension into the body, whose lowest modes boom; then the cabin,
  its first modes (69, 122, 149 Hz) and a short reverberation the seats
  and carpets damp. When the firing frequency meets a cabin mode the car
  drones (around 3300 rpm: 110 Hz).

Measured with `tool/spectrum.slang`: beside the road the engine leads
below 500 Hz and the tyres above, from about 50 km/h; at 120 km/h the
wind is a real part of it. In the seat the highs are 20 dB and more down,
and the engine's boom, the tyres' roar and the wind stand at about the
same loudness on the motorway.

The whole car costs about 9% of a core in real time (the engine 6, the
acoustics 3). `tool/drive.slang` renders a drive with the same driver,
beside the road and in the seat (two WAVs): the engine starts and idles,
the car pulls away flat out through the gears, coasts from 120 km/h,
brakes to a stop shifting down, and idles again.

## Files

- `instruments.slang`: the player's instruments and echo as `dsp` blocks;
  `programs/stereo_reverb.dsp`: a program as a file;
  `engine.slang`: the audio, in raylib/stream's render isolate;
  `main.slang`: the player
- `programs/inline4.dsp`: the car; `programs/acoustics.dsp`: tyres, wind
  and the listener; `vehicle.slang`: the two as one; `car.slang`: driving
  it; `driver.slang`:
  the clutch and the gears worked for you; `tool/drive.slang`: a drive to two
  WAVs (outside and inside); `tool/realtime.slang`: the car on the audio device, with the
  stream's load and underruns once a second; `tool/spectrum.slang`: its
  sound in octave bands and harmonics, per path, at three speeds (for
  tuning the model by numbers)
- `tool/render.slang`, `tool/bench.slang`, `test/dsp_test.slang`
