// sound/body/creak: something that sticks and slips: two parts pressed
// together and moved against each other hold until the push is more than
// they can hold, slip, and hold again. Every slip is a small blow on what
// the parts are fixed to, which rings: slow slips are heard one by one
// (a ticking, a cracking), fast ones as a groan whose pitch is how often
// it slips. No two slips are alike, which is what makes it a creak and
// not a tone.
//
// The truck's frame and body creak like this when its axles twist
// against each other (the modes of a steel body, low), and so does the
// winch's line under load on its drum (`tune` higher, `dry` shorter):
// see sound/layers/body.slang.
import "std";

// how often it slips, times a second, and how loud (0 to 1)
rate = hslider("rate", 0, 0, 400, 0.01);
level = hslider("level", 0, 0, 1, 0.001);
// what rings: its modes this many times higher, ringing this many times
// as long
tune = hslider("tune", 1, 0.25, 8, 0.01);
dry = hslider("dry", 1, 0.1, 4, 0.01);

// white noise (std's generator, with a fraction in place of its modulo)
hiss(k) = (*(69069) : +((2 * k + 1) / 4294967296) : frac) ~ _ : *(2) : -(1);

// a mode: a two-pole resonator, which a blow leaves ringing at f for t
// seconds
mode(f, t, g) = *(g * sin(w))
  : (+ ~ (_ <: *(2 * r * cos(w)), (mem : *(0 - r * r)) :> _)) with {
  w = TAU * min(f * tune, 0.45 * SR) / SR;
  r = exp(-6.91 / (t * dry * SR));
};

// the push building up: faster and slower as the grip changes, and each
// time it lets go (the ramp falls back) a blow, no two as hard
grip = hiss(71) : lowpass1(9) : *(14);
push = phasor(rate * max(1 + 0.6 * grip, 0.2));
slips = push < push';
blow = slips * (0.35 + 0.65 * abs(latch(slips, hiss(72)))) *
  (level : smooth(0.998))
  : lowpass1(1400 * tune);

// (what rings is heard by how fast it moves, not by how far: without
// that every slip would be a thump)
process = blow
  <: mode(96, 0.11, 1),
    mode(152, 0.1, 1),
    mode(247, 0.08, 0.8),
    mode(410, 0.06, 0.5),
    mode(655, 0.045, 0.3),
    mode(1040, 0.035, 0.18)
  :> _
  <: _ - mem : *(24 / tune);
