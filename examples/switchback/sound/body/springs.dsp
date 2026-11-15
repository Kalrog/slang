// sound/body/springs: the truck's suspension at work, and its frame with
// it: springs in their seats, links in their rubber bushings, the frame
// where it is bolted and riveted. Worked slowly and far, each sticks and
// slips: it holds until the push is more than it can hold, slips, and
// holds again, and every slip is a small blow on the steel around it.
// Slow slips are heard one by one, a ticking and cracking; faster ones
// as a groan. Each corner has a pitch of its own, the frame the lowest.
// With them the dampers' breath on a quick stroke: oil through small
// holes, faint.
//
// (One program for the five of them, and one sound: sound/layers/
// body.slang places it where most of it comes from.)
import "std";

// for the frame (0) and the corners (1 front left, 2 front right, 3 rear
// left, 4 rear right): how often it slips, times a second, and how hard
// (0 to 1)
rate0 = hslider("rate0", 0, 0, 400, 0.01);
rate1 = hslider("rate1", 0, 0, 400, 0.01);
rate2 = hslider("rate2", 0, 0, 400, 0.01);
rate3 = hslider("rate3", 0, 0, 400, 0.01);
rate4 = hslider("rate4", 0, 0, 400, 0.01);
level0 = hslider("level0", 0, 0, 1, 0.001);
level1 = hslider("level1", 0, 0, 1, 0.001);
level2 = hslider("level2", 0, 0, 1, 0.001);
level3 = hslider("level3", 0, 0, 1, 0.001);
level4 = hslider("level4", 0, 0, 1, 0.001);
// the dampers' breath, 0 to 1
breath = hslider("breath", 0, 0, 1, 0.001);

// white noise (std's generator, with a fraction in place of its modulo)
hiss(k) = (*(69069) : +((2 * k + 1) / 4294967296) : frac) ~ _ : *(2) : -(1);

// a mode: a two-pole resonator, which a blow leaves ringing at f for t
// seconds
mode(f, t, g) = *(g * sin(w))
  : (+ ~ (_ <: *(2 * r * cos(w)), (mem : *(0 - r * r)) :> _)) with {
  w = TAU * f / SR;
  r = exp(-6.91 / (t * SR));
};

// the grip changes all the time, so no two slips are as far apart, nor
// as hard
size = hiss(91);
grip = hiss(92) : lowpass1(9) : *(14);

// One of them: the push builds up, faster or slower with the grip (each
// feels it its own way: sway), and when it lets go (the ramp falls back)
// a blow, which rings what it is fixed to (f Hz for t seconds, and
// something smaller and higher beside it).
slipping(rate, level, sway, f, t, high) = slips * (0.35 + 0.65 * abs(size)) *
  level
  <: mode(f, t, 1), mode(high, t * 0.6, 0.4)
  :> _ with {
  push = phasor(rate * max(1 + sway * grip, 0.2));
  slips = push < push';
};

work = slipping(rate0, level0, 0.6, 118, 0.1, 390) +
  slipping(rate1, level1, -0.5, 232, 0.07, 760) +
  slipping(rate2, level2, 0.4, 271, 0.06, 910) +
  slipping(rate3, level3, -0.7, 187, 0.08, 610) +
  slipping(rate4, level4, 0.55, 204, 0.075, 680);

// oil through the dampers' valves: a breath, no hiss
sigh = hiss(93) * (breath : smooth(0.999))
  : lowpass1(500)
  : lowpass1(900)
  : dcblock;

// (what rings is heard by how fast it moves, not by how far: without
// that every slip would be a thump)
process = (work <: _ - mem : *(12)) + sigh * 1.6;
