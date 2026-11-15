// sound/engine/block: what the engine itself sounds like, beside its
// exhaust and its intake: the block struck by the combustion (a diesel's
// clatter), the injectors' ticks, the valves seating, the pistons on
// their bores, the timing gears, the fan, the starter motor; and the
// turbocharger: its whistle as it spins up, the air's hiss, a sigh when
// the pedal is lifted.
//
// Inputs (sound/engine/cylinders): the cylinders' pressure jumps, the
// injectors' pulses, the valves' seatings, the pistons' sliding.
// Outputs: the mechanical noise, the turbocharger.
import "std";

rpm = hslider("rpm", 0, 0, 6000, 1) : smooth(0.998);
fuel = hslider("fuel", 0, 0, 1, 0.001) : smooth(0.997);
boost = hslider("boost", 0, 0, 1, 0.001) : smooth(0.999);
// the starter motor turning the engine (1)
starter = hslider("starter", 0, 0, 1, 1) : smooth(0.9995);

// the block's modes, struck
block = _
  <: bandpass2(690, 8),
    bandpass2(1320, 11),
    bandpass2(2250, 13),
    bandpass2(3700, 16)
  :> _;

// an injector's tick: harder the more fuel
injectors = *((0.4 + fuel) * (fuel > 0.004))
  <: bandpass2(3900, 9), bandpass2(6200, 12) * 0.4
  :> _;

// a valve seating: a click
valves = *(0.5 + rpm / 6000) <: bandpass2(2900, 25), bandpass2(4900, 35) :> _;

// piston rings on the bores: noise as fast as the pistons slide
friction = *(noises(1) * (rpm / 4500)) : bandpass2(1700, 0.8);

// the timing gears (their teeth never quite even: the tone wavers) and
// the alternator's belt
waver = 1 + 0.004 * (noises(7) : lowpass1(9));
gears = osc(rpm / 60 * 23 * waver) * 0.2 + osc(rpm / 60 * 46 * waver) * 0.08 +
  osc(rpm / 60 * 2.9) * 0.2;

// the fan on the crank's nose: the air it moves, and a little of its
// blades' tone
fan = (osc(rpm / 60 * 1.15 * 7) * 0.05 + (noises(2) : bandpass2(420, 0.6))) *
  (rpm / 3000) * (rpm / 3000) * sqrt(rpm / 3000 + 0.01);

// the starter motor: its pinion on the flywheel's ring gear
cranking = starter * (saw(max(rpm, 30) / 60 * 110) : bandpass2(1250, 1.2)) *
  (0.6 + 0.4 * min(rpm / 200, 1));

mechanics(strike, ticks, seats, rub) = (strike : block) * 0.045 +
  (ticks : injectors) * 0.22 +
  (seats : valves) * 0.25 +
  (rub : friction) * 0.05 +
  gears * 0.0035 * min(rpm / 1500, 1) +
  fan * 0.05 +
  cranking * 0.12;

// the turbocharger's wheel, 0 to 1: it follows the boost a little behind,
// and turns faster the more gas the engine sends through it
spool = min(max((rpm - 900) / 1300, 0), 1);
wheel = (0.06 + 0.94 * boost * spool) * min(rpm / 700, 1) *
  (0.55 + 0.45 * min(rpm / 4000, 1))
  : smooth(0.9996);
// what it loses when the pedal is lifted comes out as a sigh
falling = max(wheel' - wheel, 0) * SR : smooth(0.9992);
// (the whistle is heard as the wheel spins up, less once the engine roars)
whistle = (
  osc(500 + 2900 * wheel + 22 * (noises(4) : lowpass1(6))) +
    osc(1000 + 5800 * wheel) * 0.2
) * wheel * wheel * (1 - 0.55 * fuel * wheel);
hiss = (noises(5) : bandpass2(3600, 0.7)) * wheel * sqrt(wheel);
sigh = (noises(6) : lowpass2(1300, 0.8)) * min(falling * 0.8, 1) *
  (0.6 + 0.4 * osc(31));
turbo = whistle * 0.012 + hiss * 0.06 + sigh * 0.18;

// (the engine bay keeps the highest of it in)
process = (mechanics : dcblock : lowpass2(5200, 0.7)), turbo;
