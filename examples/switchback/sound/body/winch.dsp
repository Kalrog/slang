// sound/body/winch: the electric winch on the truck's bumper: a motor
// that turns some ninety times a second with nothing to pull, through
// three stages of planet gears to a drum that turns once in two seconds.
// What is heard is the first stage's teeth (eleven to a turn of the
// motor, a whirring whine), the second stage's far below it (a growl),
// and the brushes on the commutator (a rasp). Under load the motor slows,
// by a third when the line pulls all it can, and the growl comes up;
// with the line free (running in after it is unhooked) it runs fast and
// light, and the line sings through the fairlead's rollers.
import "std";

// how fast the drum takes the line in over its speed without load (0:
// standing, 1: pulling in, more: the line running in free), and how hard
// the line pulls over the most it can (0 to 1)
run = hslider("run", 0, 0, 2, 0.001);
strain = hslider("strain", 0, 0, 1, 0.001);

// white noise (std's generator, with a fraction in place of its modulo)
hiss(k) = (*(69069) : +((2 * k + 1) / 4294967296) : frac) ~ _ : *(2) : -(1);

// a resonance of the winch's housing: a two-pole filter at f Hz, as wide
// as f / q, g at its top
ring(f, q, g) = *(g * (1 - r) * 2 * sin(w))
  : (+ ~ (_ <: *(2 * r * cos(w)), (mem : *(0 - r * r)) :> _)) with {
  w = TAU * f / SR;
  r = exp(-PI * f / (q * SR));
};

// about a sine of a turn t (0 to 1), without one (a parabola each half)
wave(t) = -4 * u * (1 - abs(u)) with {
  u = 2 * t - 1;
};

// the motor: it comes up to speed in a fifth of a second and runs down
// as fast; the load slows it
turning = run : smooth(0.9997);
motor = 90 * turning * (1 - 0.34 * strain);
turn = phasor(motor);
wob = wave(turn);
// how much there is to hear: nothing standing, all of it at speed
on = min(turning * 3, 1);

// the first stage's teeth, wobbling with the motor's shaft, and their
// octave
c = cos(TAU * (11 * turn + 0.12 * wob));
whir = (c + 0.5 * (2 * c * c - 1)) * (1 + 0.3 * wob);
// the second stage, far below: the growl, louder under load
growl = wave(frac(2 * turn)) * (0.25 + 0.7 * strain);
// the brushes: a rasp twelve times a turn
rasp = hiss(81) * (0.6 + 0.4 * wave(frac(12 * turn))) * (0.5 + 0.5 * strain)
  : ring(3300, 1.2, 1);
// the line through the rollers when it runs in free
sing = hiss(82) * max(turning - 1.1, 0) : ring(2900, 5, 2.5);

housing = _ <: *(0.3), ring(820, 3, 1), ring(2100, 3.5, 0.7) :> _;

process = ((whir + growl : housing) + rasp * 1.5) * on + sing
  <: _ - 0.8 * mem : dcblock;
