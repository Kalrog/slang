// sound/body/crunch: what gives way in a crash: sheet metal and plastic
// folding, glass and trim shaking loose. A slam of noise at the blow,
// and after it a crackle: many small breaks, thick at first and thinning
// out, each ringing a moment in what it broke. Played with the thud and
// the clang of a hard knock (sound/layers/body.slang).
//
// A crash is the counter `hit` going up; `power` is how loud, `length`
// the seconds the crackle takes to thin out.
import "std";

hit = hslider("hit", 0, 0, 1000000000, 1);
power = hslider("power", 0, 0, 8, 0.0001);
length = hslider("length", 0.25, 0.02, 2, 0.001);

// white noise (std's generator, with a fraction in place of its modulo)
hiss(k) = (*(69069) : +((2 * k + 1) / 4294967296) : frac) ~ _ : *(2) : -(1);

// what a break leaves ringing: a two-pole filter at f Hz, as wide as f / q
ring(f, q, g) = *(g * (1 - r) * 2 * sin(w))
  : (+ ~ (_ <: *(2 * r * cos(w)), (mem : *(0 - r * r)) :> _)) with {
  w = TAU * f / SR;
  r = exp(-PI * f / (q * SR));
};

// 1 for the block's first sample when a crash came
fired = hit != hit';

// something that is 1 at the crash and dies away over t seconds
dying(t) = fired : (\(prev, x).(max(x, prev * exp(-6.91 / (t * SR))))) ~ _;

// the slam: all of it at once, gone in a twentieth of a second
// (it comes up over a couple of thousandths of a second: mass, not a
// click)
slam = hiss(51) * (dying(0.05) : lowpass1(110)) : lowpass1(1200);

// the breaks: a grain of noise now and then, the oftener the fresher the
// crash (a thousand a second at first), no two as big, the last ones
// small
thin = dying(length);
breaks = (abs(hiss(52)) < thin * 0.02) * hiss(53) * (0.08 + thin);

process = (
  slam * 0.5 +
    (
      breaks <: ring(760, 2.2, 1), ring(1750, 2.6, 0.9), ring(3500, 3, 0.7) :> _
    ) * 2.6
) *
  latch(fired, power)
  : dcblock;
