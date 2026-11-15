// sound/air/conifer: the wind in conifers. Every needle sheds its
// eddies, and a wood of them soughs: a soft rush between 600 Hz and
// 4 kHz that swells and brightens with each gust, its loudness and its
// brightness by themselves, as the trees below and their tops are not
// in the same air.
//
// Inputs: a stereo pair to add to. Outputs: the pair with the wood in
// it.
import "std";

// the wind's strength in the needles and in the tops on each side as it
// is now (0 still, 1 a gale): the voice (sound/layers/air) moves them
needles_left = hslider("needles_left", 0, 0, 1.5, 0.001);
needles_right = hslider("needles_right", 0, 0, 1.5, 0.001);
tops_left = hslider("tops_left", 0, 0, 1.5, 0.001);
tops_right = hslider("tops_right", 0, 0, 1.5, 0.001);
// how thick the conifers stand around, 0 to 1
conifer = hslider("conifer", 0, 0, 1, 0.001);

// A number from 0 to 1 at random, one for each seed: std's generator
// with its state kept as a fraction (a multiply and a fract). The seeds
// are what it adds at every step: no two of them may be a simple
// fraction of each other, or their noises are alike (std's noises(0) and
// noises(1) are a third the same), and no two of the sound's programs
// may share one, or what they make cancels where it meets. These are
// from the roots of the primes.
rand(seed) = (*(69069) : +(seed / 4294967296) : frac) ~ _;
LEFT = 1359893119;
RIGHT = 2600822925;
// white noise from -0.5 to 0.5
white(seed) = rand(seed) - 0.5;

// how loud the wind is at the strength u, 1 on a moderate day (0.22):
// next to nothing in a lull, twice and more in a gust, and a gale does
// not go on growing
swell(u) = 32.8 * x / (1 + 12.1 * x) with {
  x = u * u;
};

// one side: a band of noise from 600 Hz or so up to where the air in the
// tops puts its upper edge: under 2 kHz in a lull, 4 in a hard gust (the
// rush brightens as it swells, and not in step with it; it is soft, not
// a hiss: a wood is heard from below and through itself)
side(seed, n, t) = white(seed)
  : highpass2(600 + 400 * n, 0.7)
  : lowpass2(1600 + 2600 * t, 0.5)
  : *(swell(n) * conifer * 0.106 : smooth(0.995));

process(l, r) = l + side(LEFT, needles_left, tops_left),
  r + side(RIGHT, needles_right, tops_right);
