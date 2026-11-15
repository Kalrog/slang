// sound/driveline/brakes: the truck's brakes. The pads on the turning
// discs hiss, the more the harder they are pressed and the faster the
// discs turn; discs that have been through dust and mud grind a little as
// they slow. And now and then, in the last meters of a stop, a pad
// sticks and slips on its disc a couple of thousand times a second: a
// squeak, nearly a tone (whoever sets `squeak` decides when: see
// sound/layers/driveline.slang).
import "std";

// how hard the pads are pressed (0 to 1) and how fast the wheels turn,
// turns a second
press = hslider("press", 0, 0, 1, 0.001);
wheel = hslider("wheel", 0, 0, 40, 0.01);
// the squeak: how loud (0 to 1) and how high, Hz
squeak = hslider("squeak", 0, 0, 1, 0.001);
pitch = hslider("pitch", 2200, 500, 6000, 1);

// white noise (std's generator, with a fraction in place of its modulo)
hiss(k) = (*(69069) : +((2 * k + 1) / 4294967296) : frac) ~ _ : *(2) : -(1);

// a resonance: a two-pole filter at f Hz, as wide as f / q, g at its top
ring(f, q, g) = *(g * (1 - r) * 2 * sin(w))
  : (+ ~ (_ <: *(2 * r * cos(w)), (mem : *(0 - r * r)) :> _)) with {
  w = TAU * f / SR;
  r = exp(-PI * f / (q * SR));
};

// about a sine of a turn t (0 to 1), without one (a parabola each half)
wave(t) = -4 * u * (1 - abs(u)) with {
  u = 2 * t - 1;
};

glide = smooth(0.998);

// a disc is never quite flat: the pads' noise comes and goes with its
// turning
turn = phasor(wheel);
runout = 1 + 0.35 * wave(turn);

// the pads' hiss: the faster, the louder and the brighter; a wheel that
// stands makes none
speed = min(wheel / 6, 1);
rub = hiss(41) * (press * sqrt(speed) : glide) * runout;
pads = rub : bandpass2(2600 + 1800 * speed, 0.7);

// the grinding of a hard stop: lower, rougher (the noise in lumps), and
// most at a walking pace
grit = hiss(42) : lowpass1(900) : *(4);
grind = grit * grit * grit * (press * press * speed * (1.3 - speed) : glide) *
  runout
  : ring(760, 1.4, 1)
  <: _ - mem : *(8);

// the squeak: the pad's sticking and slipping (a ramp that falls back)
// rings the disc; it wanders a little, as the grip does
wander = hiss(43) : lowpass1(14) : *(9);
slip = phasor(pitch * (1 + 0.012 * wander)) - 0.5;
squeal = slip * (squeak : smooth(0.9985)) * (1 + 0.25 * wave(turn))
  <: ring(pitch, 28, 1), ring(2 * pitch, 22, 0.3)
  :> _;

process = pads + grind * 0.5 + squeal * 4;
