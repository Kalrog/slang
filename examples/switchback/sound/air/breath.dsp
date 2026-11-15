// sound/air/breath: the wind in the open: not one thing it blows
// through but all the land around at once, far enough away to have lost
// its highs: a soft breath, low and wide, that swells and brightens with
// every gust. It is there wherever there is wind, less so in a wood.
//
// Inputs: a stereo pair to add to. Outputs: the pair with the breath in
// it.
import "std";

// the wind's strength on each side as it is now (0 still, 1 a gale),
// twice: how loud the breath is and how bright change by themselves
// (the voice, sound/layers/air, moves them: the gusts, the turbulence)
left_low = hslider("left_low", 0, 0, 1.5, 0.001);
left_high = hslider("left_high", 0, 0, 1.5, 0.001);
right_low = hslider("right_low", 0, 0, 1.5, 0.001);
right_high = hslider("right_high", 0, 0, 1.5, 0.001);
// how open the place is, 0 to 1
open = hslider("open", 0, 0, 1, 0.001);

// A number from 0 to 1 at random, one for each seed: std's generator
// with its state kept as a fraction (a multiply and a fract). The seeds
// are what it adds at every step: no two of them may be a simple
// fraction of each other, or their noises are alike (std's noises(0) and
// noises(1) are a third the same), and no two of the sound's programs
// may share one, or what they make cancels where it meets. These are
// from the roots of the primes.
rand(seed) = (*(69069) : +(seed / 4294967296) : frac) ~ _;
LEFT = 1013904243;
RIGHT = 2773480763;
// white noise from -0.5 to 0.5
white(seed) = rand(seed) - 0.5;

// how loud the wind is at the strength u, 1 on a moderate day (0.22):
// still air is silent, a breeze swells quickly, and a gale is only twice
// a moderate day (all the land at once does not swell as one tree does)
swell(u) = 20.55 * x / (1 + 9.27 * x) with {
  x = pow(u, 1.6);
};

// one side: a broad band about 300 Hz, as loud as the low wind says,
// and as much of its highs as the distance leaves, which the high wind
// says (more in a gust: the breath brightens)
side(seed, l, h) = white(seed)
  : bandpass2(220 + 260 * l, 0.45)
  : lowpass2(900 + 2600 * h, 0.6)
  : *(swell(l) * open * 0.143 : smooth(0.995));

process(l, r) = l + side(LEFT, left_low, left_high),
  r + side(RIGHT, right_low, right_high);
