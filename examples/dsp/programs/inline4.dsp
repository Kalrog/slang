// A four-cylinder petrol engine, as a car has one: 1.8 litres, firing order
// 1-3-4-2, a throttle plate, spark ignition, a four-into-one exhaust
// header, a muffler and a tailpipe, an intake plenum with four runners and
// an air filter snorkel.
//
// Petrol (spark ignition) decides the architecture: the throttle plate
// throttles the air, so at idle the manifold holds a vacuum and every
// cylinder starts compressing from a third of an atmosphere; the spark
// starts a combustion that burns over some 55 degrees (a Wiebe function);
// the engine revs to 6800 rpm, where a limiter cuts the sparks.
//
// The model, every part of it sample by sample:
//
// - the crank and the car: the crank's speed from the combustion's torque
//   against friction, pumping and the clutch; the clutch slipping until it
//   grips, a six-speed gearbox, the differential, the wheels, and the car's
//   mass against the air, the tyres and the brakes; an idle valve; a rev
//   limiter; one phase per cycle of two turns (720 degrees), each cylinder
//   a quarter cycle after the one before it in the firing order
// - each cylinder: its volume from the crank angle, its pressure in bar:
//   suction while the intake valve is open, polytropic compression and
//   expansion with the combustion's pressure rise while both are shut,
//   the blowdown when the exhaust valve opens; the combustion varies from
//   cycle to cycle, and its rate rings the cylinder's first acoustic mode
//   (knock ringing, around 6.5 kHz)
// - the valves: lift curves with the cam timing (overlap at top dead
//   centre), each an orifice between the cylinder and its port, its
//   opening the flow's share of the port's impedance
// - the gas paths as digital waveguides: thirteen pipes, each a pair of
//   delay lines (a wave travelling each way) as long as the pipe at the
//   speed of sound in its gas (hot exhaust, cool intake), with losses that
//   take the highs first; junctions scatter the waves where pipes meet
//   (the header's collector, the plenum, the muffler's expansion chamber),
//   the closed valves reflect them, the open ends (tailpipe, air filter)
//   reflect the lows inverted and let the highs out
// - the mechanics: the block's modes struck by the combustion pressure,
//   the valve train ticking as valves seat, piston friction, the
//   alternator's whine
//
// Outputs, the stems for programs/acoustics.dsp: the sound radiated at
// the tailpipe and at the air filter, the mechanical noise, the engine's
// vibration (into the body through the mounts); then for gauges, scopes
// and the acoustics: rpm, the pressure in cylinder 1 (bar above an
// atmosphere), its phase in the cycle (0 to 1: 720 degrees from the top
// dead centre before its intake stroke), the pressure in the exhaust
// collector, and the car's speed in km/h.
import "std";

// ------------------------------------------------------------ controls

throttle = hslider("throttle", 0, 0, 1, 0.01) : smooth(0.998);
advance = hslider("spark advance", 22, 0, 45, 0.5);
roughness = hslider("roughness", 0.3, 0, 1, 0.01);
header_length = hslider("header length", 0.65, 0.2, 1.5, 0.01);
pipe_length = hslider("exhaust length", 1.4, 0.3, 3, 0.01);
muffler = hslider("muffler", 0.7, 0, 1, 0.01);
pops = hslider("pops", 0.4, 0, 1, 0.01);
exhaust_level = hslider("exhaust level", 0.8, 0, 2, 0.01);
intake_level = hslider("intake level", 0.5, 0, 2, 0.01);
mechanics_level = hslider("mechanics level", 0.5, 0, 2, 0.01);

// ------------------------------------------------------------ the crank

DEG = 1 / 720;
IDLE = 850;
LIMIT = 6800;

// ------------------------------------------------------------ the drivetrain

// the driver's other controls: the gear (0 neutral, 1-6), the clutch
// (1 engaged), the brake
gear = nentry("gear", 0, 0, 6, 1);
clutch = hslider("clutch", 1, 0, 1, 0.01) : smooth(0.995);
brake = hslider("brake", 0, 0, 1, 0.01) : smooth(0.995);

GEARS = (0, 3.5, 2.1, 1.4, 1.03, 0.82, 0.68);
FINAL = 4.1; // the differential
MASS = 1250; // kg, with the driver
WHEEL = 0.31; // m, the tyres' rolling radius
INERTIA = 0.16; // kg m^2: crank, flywheel, clutch
TO_RPM = 60 / TAU; // rad/s to rpm

// engine turns per wheel turn, through the gearbox and the differential
// (0 in neutral)
ratio = sum(i, 7, (int(gear + 0.5) == i) * take(i + 1, GEARS)) * FINAL;

// the air the engine gets: the throttle, or the idle valve's below
// IDLE rpm (which keeps it running, and pulls it up from a stall)
air(r) = max(throttle, min(0.35, max(0, 0.11 + (IDLE - r) * 0.0006)));

// manifold absolute pressure in bar: a vacuum at idle, an atmosphere at
// full throttle
manifold(r) = 0.25 + 0.75 * air(r);

// the combustion's torque in Nm (180 at full load, most at 4200 rpm) and
// what friction and pumping take (more with the throttle shut: engine
// braking)
combustion(r, m) = 180 * max(m - 0.25, 0) / 0.75 * (1 - ((r - 4200) / 6000) ^ 2);
losses(r) = 10 + r * 0.005 + (1 - throttle) * r * 0.003;

// The crank's speed (rad/s), the car's (m/s) and the limiter, one sample
// on. The clutch carries the torque the slip between the crank and the
// gearbox asks for, up to its grip; the car feels it through the gears
// against the air, the tyres' rolling and the brakes. The limiter cuts
// the sparks at LIMIT and lets go 250 rpm below it.
dynamics = (step ~ (_, _, _)) with {
  step(w, v, cut) = max(w + (torque - load) / INERTIA / SR, 0),
    max(v + force / MASS / SR, 0),
    next_cut with {
    r = w * TO_RPM;
    torque = select2(cut > 0, combustion(r, manifold(r)), 0) - losses(r);
    slip = w - v / WHEEL * ratio;
    grip = clutch * 400 * (ratio > 0);
    load = max(-grip, min(grip, slip * 300));
    force = load * ratio * 0.92 / WHEEL - 0.39 * v * v - 150 * min(v * 2, 1) -
      brake * 11000 * min(v * 4, 1);
    next_cut = select2(cut > 0, r > LIMIT, r > LIMIT - 250);
  };
};
rpm = dynamics : (*(TO_RPM), !, !);
kmh = dynamics : (!, *(3.6), !); // the speed in km/h
cut = dynamics : (!, !, _);
map = manifold(rpm);

// the cycle: 0 to 1 over two turns of the crank
crank = phasor(rpm / 120);

// the phase of cylinder k (1-4): firing order 1-3-4-2, a quarter cycle
// apart, so cylinder 1 fires at 0.5, 3 at 0.75, 4 at 1.0, 2 at 1.25
phase(k) = frac(crank - take(k, (0, 3, 1, 2)) * 0.25 + 1);

// ------------------------------------------------------------ a cylinder

R = 9.5; // compression ratio
IVC = 0.25 + 42 * DEG; // intake valve closes after bottom dead centre
EVO = 0.75 - 46 * DEG; // exhaust valve opens before bottom dead centre
BURN = 55 * DEG; // how long the combustion lasts
spark = 0.5 - advance * DEG;

// the volume in units of the displacement: the clearance at top dead
// centre plus the piston's travel (with the rod's second harmonic)
volume(f) = 1 / (R - 1) + (1 - cos(a) + (1 - cos(2 * a)) * 0.14) / 2.28 with {
  a = f * 4 * PI;
};

// the piston's speed, signed, about -1 to 1
speed(f) = sin(f * 4 * PI) + 0.28 * sin(f * 8 * PI);

// the share of the charge burnt (Wiebe), and how fast it burns
burnt(f) = 1 - exp(-5 * pow(max(f - spark, 0) / BURN, 3));
burning(f) = burnt(f) - burnt(f - 0.5 * DEG);

// the pressure, absolute, while both valves are shut: polytropic from the
// manifold's pressure at IVC, raised by the combustion (load: how much of
// it burns this cycle)
sealed(f, load) = map * pow(volume(IVC) / volume(f), 1.32) *
  (1 + 3.2 * load * burnt(f));

// the pressure in cylinder k, gauge (bar above an atmosphere)
cylinder(k) = select2(f < IVC, select2(f < EVO, blowdown, compressed), intake) +
  ring with {
  f = phase(k);
  // this cycle's combustion: a little different every time, none while
  // the limiter cuts
  started = f < f';
  // (no two cylinders burn alike: injectors, charge, deposits)
  load = (1 - cut) * take(k, (1, 0.93, 1.05, 0.96)) *
    (1 + roughness * 0.5 * latch(started, noise));
  intake = map - 1 - 0.25 * (rpm / 3000) * speed(f);
  compressed = sealed(f, load) - 1;
  // the blowdown: the gas leaves as fast as the exhaust valve lets it,
  // so the pressure falls with the area the valve has opened so far
  blowdown = (sealed(EVO, load) - 1) * exp(-opened(f - EVO, EXHAUST) / 0.007) +
    0.12 * (rpm / 3000) * -speed(f);
  // the first acoustic mode of the chamber, rung by the burn rate
  ring = burning(f) * load * map * 60 : bandpass2(6500, 25);
};

// valve lift, 0 to 1: opens at open, closes dur later (cycle phase)
lift(f, open, dur) = select2(t < dur, 0, sin(t / dur * PI) ^ 2) with {
  t = frac(f - open + 1);
};

EXHAUST = 1 + 12 * DEG - EVO; // how long the exhaust valve is open
INTAKE = IVC + 14 * DEG; // and the intake valve

exhaust_lift(k) = lift(phase(k), EVO, EXHAUST);
intake_lift(k) = lift(phase(k), 1 - 14 * DEG, INTAKE);

// the area a valve has let through t after it began to open: the integral
// of its lift (sin^2) over the dur it is open
opened(t, dur) = select2(
  t < dur, dur / 2, t / 2 - dur / (4 * PI) * sin(2 * PI * t / dur)
);

// a valve at the end of a port: the wave a arriving, the wave sent back;
// shut it reflects a, open it couples the port to the cylinder's pressure
// p (above the port's own: the manifold's vacuum on the intake side)
valve(open, p, a) = p * o + a * (1 - 2 * o) with {
  // (the flow grows quickly with a little lift: the curtain area round
  // the valve's edge, the gas through it at the speed of sound; a third
  // of the lift lets almost all through)
  o = 0.45 * min(1, sqrt(open) * 1.7);
};

// ------------------------------------------------------------ the pipes

// a pipe of len metres in a gas where sound runs at c m/s, with losses:
// two inputs (the waves entering at the left end and at the right end),
// two outputs (the waves arriving at the right end and at the left end)
pipe(len, c) = travel, travel with {
  // (one sample of the length is the feedback's; the longer the pipe, the
  // more the walls take, the highs most)
  travel = @(max(len * SR / c - 1, 1))
    : *(1 - 0.02 * len)
    : lowpass1(9000 / (0.5 + len));
};

// the muffler's chamber: a pipe whose packing (glass wool round a
// perforated tube) takes the highs, more the higher the muffler control
muffling(len, c) = travel, travel with {
  travel = @(max(len * SR / c - 1, 1))
    : *(0.92)
    : lowpass2(200 + (1 - muffler) ^ 2 * 6600, 0.6);
};

HOT = 520; // m/s in the exhaust
COLD = 345; // m/s in the intake

// the 13 pipes: header runners 1-4, the down pipe, the muffler's chamber,
// the tailpipe; intake runners 1-4, the throttle body, the snorkel
pipes = pipe(header_length, HOT),
  pipe(header_length + 0.07, HOT),
  pipe(header_length + 0.12, HOT),
  pipe(header_length + 0.04, HOT),
  pipe(pipe_length, HOT),
  muffling(0.35, HOT),
  pipe(0.35, HOT),
  pipe(0.3, COLD),
  pipe(0.29, COLD),
  pipe(0.31, COLD),
  pipe(0.3, COLD),
  pipe(0.12, COLD),
  pipe(0.45, COLD);

// ------------------------------------------------------------ the junctions

// From the waves arriving at both ends of every pipe (r: at its right end,
// l: at its left end), the waves leaving every end, pipe by pipe (left end
// first), then the sound radiated at the tailpipe and at the air filter,
// and the pressure in the collector.
junctions(
  e1r, e1l, e2r, e2l, e3r, e3l, e4r, e4l, dr, dl, cr, cl, tr, tl, i1r, i1l, i2r,
  i2l, i3r, i3l, i4r, i4l, br, bl, sr, sl
) = valve(exhaust_lift(1), cylinder(1), e1l),
  collector - e1r,
  valve(exhaust_lift(2), cylinder(2), e2l),
  collector - e2r,
  valve(exhaust_lift(3), cylinder(3), e3l),
  collector - e3r,
  valve(exhaust_lift(4), cylinder(4), e4l),
  collector - e4r,
  collector - dl,
  inlet - dr,
  inlet - cl,
  outlet - cr,
  outlet - tl,
  tail_back,
  valve(intake_lift(1), cylinder(1) - (map - 1), i1l),
  plenum - i1r,
  valve(intake_lift(2), cylinder(2) - (map - 1), i2l),
  plenum - i2r,
  valve(intake_lift(3), cylinder(3) - (map - 1), i3l),
  plenum - i3r,
  valve(intake_lift(4), cylinder(4) - (map - 1), i4l),
  plenum - i4r,
  plenum - bl,
  through(br, sl),
  through(sl, br),
  mouth_back,
  radiated(tr, tail_back),
  radiated(sr, mouth_back),
  collector with {
  // where pipes meet the pressure is the same in all: twice the waves
  // arriving weighted by the pipes' areas, over the areas; each pipe gets
  // that pressure less the wave it brought
  collector = 2 * (e1r + e2r + e3r + e4r + 2.2 * dl) / (4 + 2.2) + afterfire;
  // the muffler: a down pipe into a chamber two to ten times its area (as
  // the muffler control says) and out again
  chamber = 2 + muffler * 8;
  // a junction with a volume behind it fills and empties: its pressure
  // follows the waves through a lowpass, the lower the bigger the volume
  // (the muffler's body, bigger the higher the control)
  inlet = 2 * (dr + chamber * cl) / (1 + chamber)
    : lowpass1(120 + (1 - muffler) ^ 2 * 3000);
  // (the way out is a perforated tube in the packing: a smaller step
  // that reflects less, so the tailpipe does not ring between it and its
  // open end)
  outlet = 2 * (2.2 * cr + tl) / (2.2 + 1);
  // an open end reflects the waves inverted, all but the highs (above
  // about 3 kHz, where the pipe's mouth is no longer small against the
  // wavelength)
  tail_back = -0.98 * (tr : lowpass1(3000));
  // the plenum: four runners and the throttle body, a bigger volume
  plenum = 2 * (i1r + i2r + i3r + i4r + 3 * bl) / (4 + 3);
  // the throttle plate: an orifice as open as the throttle
  open = 0.04 + 0.96 * throttle;
  through(from, other) = (1 - open) * from + open * other;
  mouth_back = -0.95 * (sr : lowpass1(2500));
  // what an open end sends out: the flow out of it (the difference of the
  // waves) changing, as a small pulsating source sounds from afar
  radiated(arriving, back) = arriving - back : \(x).(x - x');
  // unburnt fuel lighting in the hot header when the throttle shuts at
  // high rpm (on the overrun)
  afterfire = pops * (throttle < 0.05) * (rpm > 2500) * (noise > 0.9997) * 1.5
    : lowpass1(3000);
};

// the waveguides closed into a loop: 26 waves round; out come the two
// sounds and the collector's pressure
gas = (pipes : junctions) ~ bus(26) : (par(i, 26, !), _, _, _);

// ------------------------------------------------------------ mechanics

// the block, struck by the pressure's changes in every cylinder
strike = sum(k, 4, cylinder(k + 1) - cylinder(k + 1)') * 0.4;
block = strike
  <: bandpass2(620, 9),
    bandpass2(1270, 12),
    bandpass2(2350, 14),
    bandpass2(3900, 18)
  :> _;

// a valve seating: a click when its lift returns to 0
seats(k) = (exhaust_lift(k) == 0) * (exhaust_lift(k)' > 0) +
  (intake_lift(k) == 0) * (intake_lift(k)' > 0);
ticks = sum(k, 4, seats(k + 1)) * (0.6 + rpm / 8000)
  <: bandpass2(3100, 30), bandpass2(5200, 40)
  :> _;

// piston rings on the bores: noise as fast as the pistons slide
friction = noise * sum(k, 4, abs(speed(phase(k + 1)))) * (rpm / 6000)
  : bandpass2(1800, 0.8)
  : *(0.03);

// the alternator, belt-driven 2.8 times as fast as the crank
whine = osc(rpm / 60 * 2.8) * 0.002 + osc(rpm / 60 * 5.6) * 0.001;

mechanics = (block * 0.04 + ticks * 0.3 + friction * 2 + whine * 2) *
  mechanics_level;

// ------------------------------------------------------------ the sound

// what shakes the body through the engine mounts: the four cylinders'
// gas pressure (the crank's torque ripple) and the pistons' inertia, which
// in an inline four does not balance at twice the crank's speed (the
// pistons accelerate harder near the top of their stroke than near the
// bottom); both at the firing frequency and its harmonics
vibration = sum(k, 4, cylinder(k + 1)) * 0.02 +
  (rpm / 6000) ^ 2 * cos(crank * 8 * PI) * 0.3
  : dcblock;

// the stems, scaled so that a listener a few metres away hears them at
// about these levels (the acoustics program places and mixes them)
process = gas, mechanics, vibration, rpm, cylinder(1), phase(1), kmh
  : \(exhaust, intake, collector, m, vib, r, p1, f1, v).(exhaust *
    exhaust_level * 275,
    intake * intake_level * 137,
    m * 0.55,
    vib * mechanics_level,
    r,
    p1,
    f1,
    collector,
    v);
