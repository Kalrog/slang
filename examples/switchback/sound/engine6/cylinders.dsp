// sound/engine6/cylinders: sound/engine/cylinders.dsp with six cylinders
// (firing order 1-5-3-6-2-4), to compare. The cylinders of the truck's engine, a
// turbocharged diesel: the pressure in each
// through its cycle, sample by sample, from what the game's drivetrain
// says (the crank's speed, the fuel, the turbo's boost), and what the
// valves do with it. The first of four programs (see sound/engine.slang):
// the exhaust and the intake take each cylinder's valves as this one puts
// them out, the block what strikes it.
//
// After the petrol four of examples/dsp (programs/inline4.dsp); what a
// diesel changes:
//
// - no throttle plate: the cylinders always fill, with the manifold's
//   pressure (an atmosphere, more with boost), and compress it 17.5 times
// - the fuel lights by itself: what was injected before it lit burns at
//   once (a steep rise of the pressure that strikes the block: the
//   clatter, most of the sound at idle), the rest as it is injected, over
//   some sixty degrees. With no fuel (off the pedal above idle, at the
//   limiter) the cylinders only compress and let go: the engine brakes
//   and sounds hollow.
//
// Outputs, for each cylinder k: what its exhaust valve sends into its
// header (the cylinder's pressure times the valve's opening), how much of
// an arriving wave that valve sends back, and the same two for its intake
// valve; then, for the block: the pressures' jumps, the injectors' pulses,
// the valves' seatings, the pistons' sliding.
import "std";

// ------------------------------------------------------------ controls

// from the game, glided by the mixer: the crank's speed, the fuel as a
// share of the most at this speed (0: none), the turbo's boost (0 to 1)
rpm = hslider("rpm", 0, 0, 6000, 1) : smooth(0.998);
fuel = hslider("fuel", 0, 0, 1, 0.001) : smooth(0.997);
boost = hslider("boost", 0, 0, 1, 0.001) : smooth(0.999);
// how worn the engine is (it misses, 0 to 1), and its character
damage = hslider("damage", 0, 0, 1, 0.01);
clatter = hslider("clatter", 0.6, 0, 1, 0.01);
roughness = hslider("roughness", 0.35, 0, 1, 0.01);

// ------------------------------------------------------------ the crank

CYL = 6;
// each cylinder's place in the firing order (1-5-3-6-2-4)
FIRING = (0, 4, 2, 5, 1, 3);
DEG = 1 / 720;

// the cycle: 0 to 1 over two turns of the crank; cylinder k (from 1) is
// at the top before its intake stroke at 0, fires at 0.5
crank = phasor(rpm / 120);
late(k) = take(k, FIRING) / CYL;
phase(k) = frac(crank - late(k) + 1);

// the cosine and sine of the crank's angle, once for all cylinders: each
// has them turned by its place in the firing order
turn_c = cos(crank * 4 * PI);
turn_s = sin(crank * 4 * PI);
cos_of(k) = turn_c * cos(late(k) * 4 * PI) + turn_s * sin(late(k) * 4 * PI);
sin_of(k) = turn_s * cos(late(k) * 4 * PI) - turn_c * sin(late(k) * 4 * PI);

// the manifold's pressure in bar: an atmosphere and the boost, which the
// turbine only makes once the engine turns fast enough to drive it
spool = min(max((rpm - 900) / 1300, 0), 1);
map = 1 + 1.2 * boost * spool;

// ------------------------------------------------------------ a cylinder

R = 17.5; // compression ratio
IVC = 0.25 + 36 * DEG; // intake valve closes after bottom dead centre
EVO = 0.75 - 50 * DEG; // exhaust valve opens before bottom dead centre
INJECT = 0.5 - 9 * DEG; // the injection starts
LIGHT = 0.5 - 3 * DEG; // the fuel lights
PREMIX = 7 * DEG; // how long what was injected before burns
BURN = 62 * DEG; // how long the rest burns
EXHAUST = 1 + 10 * DEG - EVO; // how long the exhaust valve is open
INTAKE = IVC + 12 * DEG; // and the intake valve

// the volume in units of the displacement, from the cosine of the crank's
// angle (with the rod's second harmonic)
volume_of(c) = 1 / (R - 1) + (1 - c + (2 - 2 * c * c) * 0.14) / 2.28;
volume_at(f) = volume_of(cos(f * 4 * PI));

// how the pressure rises as a gas is squeezed to 1 / x of its volume
// (polytropic, x^1.375, without a pow)
squeezed(x) = x * sqrt(sqrt(x * x * x));

// what is left of the compression's rise when the exhaust valve opens
LEFT = squeezed(volume_at(IVC) / volume_at(EVO));

// a rise from 0 to 1 while t goes from 0 to 1: soft at both ends, and one
// that starts at once and tails off
rise(t) = x * x * (3 - 2 * x) with {
  x = min(max(t, 0), 1);
};
tail(t) = 1 - y * y * y with {
  y = 1 - min(max(t, 0), 1);
};

// a valve t after it began to open, open for dur (cycle phase): how far
// it lets the gas through (0 to 0.45: a little lift lets almost all
// through), and the area it has let through so far
opening(t, dur) = (t < dur) * 0.45 * min(1, 6.8 * u * (1 - u)) with {
  u = t / dur;
};
opened(t, dur) = dur * 16 *
  (u * u * u / 3 - u * u * u * u / 2 + u * u * u * u * u / 5) with {
  u = min(t / dur, 1);
};

// what cylinder k puts out: see the top
cylinder(k) = p * exhaust_open,
  1 - 2 * exhaust_open,
  (p - (map - 1)) * intake_open,
  1 - 2 * intake_open,
  p - p',
  (f >= INJECT) * (f' < INJECT),
  (exhaust_open == 0) * (exhaust_open' > 0) +
    (intake_open == 0) * (intake_open' > 0),
  abs(s) with {
  f = phase(k);
  c = cos_of(k);
  s = sin_of(k);
  started = f < f';
  // this cycle's fuel: no two cylinders and no two cycles alike, and a
  // worn engine misses some
  missed = (latch(started, noises(2)) + 1) / 2 < damage * 0.3;
  share = fuel * (1 + 0.06 * sin(k * 2.4)) *
    (1 + (roughness + damage) * 0.45 * latch(started, noises(1))) * (1 - missed);
  heat = 2.8 * share;
  // the less fuel, the more of it has gathered before it lights
  premixed = min((0.15 + 0.5 * (1 - fuel) * (1 - fuel)) * (0.4 + clatter), 0.9);
  burnt = premixed * rise((f - LIGHT) / PREMIX) +
    (1 - premixed) * tail((f - LIGHT) / BURN);
  // the piston's speed, -1 to 1
  speed = s * (1 + 0.56 * c);
  // the intake stroke: the manifold's pressure, less what the piston's
  // suction costs (none of it left by the time the valve shuts)
  intake = map - 1 -
    0.2 * (rpm / 3000) * speed * (1 - rise((f - 0.25) / (IVC - 0.25)));
  sealed = map * squeezed(volume_at(IVC) / volume_of(c)) * (1 + heat * burnt);
  // the blowdown: the gas leaves as fast as the exhaust valve lets it
  // (about exp(-x), without an exp); then the exhaust stroke against the
  // turbine's back pressure, and at its end, with both valves open, the
  // manifold's pressure takes over
  blowdown = (map * LEFT * (1 + heat) - 1) / (y * y * y * y) +
    (pushed + (map - 1 - pushed) * rise((f - (1 - 12 * DEG)) / (12 * DEG))) *
      rise((f - EVO) / (40 * DEG)) with {
    y = 1 + opened(f - EVO, EXHAUST) / 0.028;
    pushed = 0.25 * boost * spool - 0.1 * (rpm / 3000) * speed;
  };
  // the chamber's own resonance, rung by how fast the charge burns
  // (only as it burns: at the cycle's end burnt falls back to 0)
  ring = max(burnt - burnt', 0) * heat * map * 30 : bandpass2(5500, 20);
  p = select2(f < IVC, select2(f < EVO, blowdown, sealed - 1), intake) + ring;
  exhaust_open = opening(frac(f - EVO + 1), EXHAUST);
  intake_open = opening(frac(f - (1 - 12 * DEG) + 1), INTAKE);
};

// the cylinders side by side, and what the block gets summed over them
process = par(k, CYL, cylinder(k + 1))
  <: par(k, CYL, par(j, 4, only(CYL * 8, k * 8 + j))),
    par(j, 4, par(k, CYL, only(CYL * 8, k * 8 + 4 + j)) :> _);
