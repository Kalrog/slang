// sound/air/leaves: the wind in leaves and in grass. The leaves of
// broadleaf trees and bushes strike each other: grains of noise, a few a
// second in nearly still air (a leaf here, a twig there), a rush of them
// in a gust: grainier than a conifer's hiss, and higher. Grass swishes,
// higher still and faint, as quick as the air over it.
//
// Inputs: a stereo pair to add to. Outputs: the pair with the leaves in
// it.
import "std";

// the wind's strength in the leaves and in the grass on each side as it
// is now (0 still, 1 a gale): the voice (sound/layers/air) moves them
leaves_left = hslider("leaves_left", 0, 0, 1.5, 0.001);
leaves_right = hslider("leaves_right", 0, 0, 1.5, 0.001);
blades_left = hslider("blades_left", 0, 0, 1.5, 0.001);
blades_right = hslider("blades_right", 0, 0, 1.5, 0.001);
// how much of each is around, 0 to 1
broadleaf = hslider("broadleaf", 0, 0, 1, 0.001);
grass = hslider("grass", 0, 0, 1, 0.001);

// A number from 0 to 1 at random, one for each seed: std's generator
// with its state kept as a fraction (a multiply and a fract). The seeds
// are what it adds at every step: no two of them may be a simple
// fraction of each other, or their noises are alike (std's noises(0) and
// noises(1) are a third the same), and no two of the sound's programs
// may share one, or what they make cancels where it meets. These are
// from the roots of the primes.
rand(seed) = (*(69069) : +(seed / 4294967296) : frac) ~ _;
LEFT = 528734635;
RIGHT = 1541459225;
// two white noises from -0.5 to 0.5 of one generator: its high bits and
// its low bits
white(seed) = rand(seed) - 0.5;
other(seed) = frac(rand(seed) * 4096) - 0.5;

// how loud the wind is at the strength u, 1 on a moderate day (0.22):
// next to nothing in a lull, twice and more in a gust, and a gale does
// not go on growing
swell(u) = 32.8 * x / (1 + 12.1 * x) with {
  x = u * u;
};

// the leaves: `rate` grains a second, each a burst of noise that dies
// away in some 9 ms, no two the same size (the generator's high bits say
// when one comes and how large, its low bits are the noise in it). The
// more grains, the more they add up to: `level` is how loud they are
// together (a sum of pulses at random: its mean and its spread), so that
// the wind's strength alone says how loud the leaves are.
leaves(seed, u) = grains * other(seed)
  : bandpass2(2600 + 1400 * u, 0.9)
  : *(swell(u) / level * broadleaf * 0.0645 : smooth(0.995)) with {
  rate = 150 + 1200 * pow(u, 1.5);
  size = rand(seed) * SR / rate;
  grains = (size < 1) * size : + ~ *(exp(-1 / (0.009 * SR)));
  level = sqrt(0.0015 * rate + 0.00002025 * rate * rate);
};

// the grass
blades(seed, u) = white(seed)
  : bandpass2(3800 + 1400 * u, 1.1)
  : *(swell(u) * grass * 0.0197 : smooth(0.995));

// one side: nothing low in it, and not all the way up
side(seed, l, b) = leaves(seed, l) + blades(seed, b)
  : highpass2(1400, 0.7)
  : lowpass1(6000);

process(l, r) = l + side(LEFT, leaves_left, blades_left),
  r + side(RIGHT, leaves_right, blades_right);
