// sound/water/bubbles: what makes water sound like water: air caught in
// it. A bubble rings at a pitch of its size (a millimetre across some
// 3 kHz, a centimetre 300 Hz), the higher the shorter, and its pitch
// rises while it rings, as it does for a bubble coming up to the
// surface: a plink, a blip, a bloop. They come at random, so many a
// second, most of them faint, and a voice of six takes each (one still
// ringing is taken over). A babbling river is many of them, a lake's
// shore a few low ones, more when a wave comes in.
//
// Outputs: two halves of them, three voices each (the voice,
// sound/layers/water, puts them left and right of where the water lies).
import "std";

// how many a second, their pitches from low to high, Hz, and how loud
rate = hslider("rate", 0, 0, 400, 0.1);
low = hslider("low", 350, 100, 2000, 1);
high = hslider("high", 2800, 200, 8000, 1);
level = hslider("level", 0, 0, 4, 0.001) : smooth(0.999);

VOICES = 6;
// how quickly a bubble dies away (as a share of its pitch: they all ring
// some thirty times), how quickly its pitch rises, and the highest it
// may get (as a turn per sample: 0.9 is 6.9 kHz)
DAMP = 0.03;
RISE = 0.0012;
TOP = 0.9;

// A number from 0 to 1 at random: std's generator with its state kept as
// a fraction. The seed is what it adds at every step; no two of the
// sound's programs share one (see sound/air.dsp).
rand(seed) = (*(69069) : +(seed / 4294967296) : frac) ~ _;
SEED = 2438529371;

// Every sample one number at random, stretched so that its whole part is
// under VOICES as often as a bubble should come: then that is the voice
// that takes it, and the fraction left over is a number at random of
// its own, which says what bubble it is.
draw = rand(SEED) * VOICES * SR / max(rate, 0.01);

// the bubble of a fraction: its pitch as the turn per sample of what
// rings (from low to high, more of them low), and how hard it is struck
// (most of them faint, the low ones harder)
turn(part) = TAU * low / SR * wide * wide with {
  wide = 1 + (sqrt(high / low) - 1) * part;
};
strike(part) = size * size * (1.4 - 0.8 * part) with {
  size = frac(part * 64);
};

// A voice: a pair of numbers that turn into each other, a little every
// sample (a sine without a sine: its pitch is the turn, one multiply).
// A hit sets the turn and strikes it; then it dies away, and the turn
// grows.
voice = (step ~ (_, _, _)) : (_, !, !) with {
  step(x, y, e, hit, new, hard) = x1, y1, e1 with {
    e1 = select2(hit, min(e * (1 + RISE * e), TOP), new);
    x1 = x + e1 * y;
    y1 = y * (1 - DAMP * e1) - e1 * x1 + hit * hard;
  };
};

// the voices from `from`: each takes the bubbles drawn for it
half(q, from) = sum(
  k,
  VOICES / 2,
  (floor(q) == from + k, turn(q - floor(q)), strike(q - floor(q))) : voice
);

process = draw : \(q).(half(q, 0) * level, half(q, VOICES / 2) * level);
