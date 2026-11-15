// sound/air/ridge: the wind on bare heights: rock edges, gullies and
// gaps are pipes it blows across, and they moan: narrow bands of noise,
// low, whose pitch rises and falls with the wind's strength; and when a
// gust is hard enough something whistles for a moment.
//
// Inputs: a stereo pair to add to. Outputs: the pair with the heights
// in it.
import "std";

// the wind's strength on each side as it is now (0 still, 1 a gale),
// twice (the voice, sound/layers/air, moves them)
left_low = hslider("left_low", 0, 0, 1.5, 0.001);
left_high = hslider("left_high", 0, 0, 1.5, 0.001);
right_low = hslider("right_low", 0, 0, 1.5, 0.001);
right_high = hslider("right_high", 0, 0, 1.5, 0.001);
// how bare and how high the place is, 0 to 1
ridge = hslider("ridge", 0, 0, 1, 0.001);

// A number from 0 to 1 at random, one for each seed: std's generator
// with its state kept as a fraction (a multiply and a fract). The seeds
// are what it adds at every step: no two of them may be a simple
// fraction of each other, or their noises are alike (std's noises(0) and
// noises(1) are a third the same), and no two of the sound's programs
// may share one, or what they make cancels where it meets. These are
// from the roots of the primes.
rand(seed) = (*(69069) : +(seed / 4294967296) : frac) ~ _;
LEFT = 3418070365;
RIGHT = 1654270251;
// white noise from -0.5 to 0.5
white(seed) = rand(seed) - 0.5;

// how loud a pipe is at the strength u, 1 on a moderate day (0.22):
// next to nothing in a breeze, a howl in a gust
howl(u) = 37 * x / (1 + 9 * x) with {
  x = pow(u, 2.2);
};

// a pipe from f0 Hz in still air to f0 + f1 in a gale
moan(f0, f1, q, a, u) = bandpass2(f0 + f1 * u, q)
  : *(howl(u) * ridge * a : smooth(0.995));

// the whistle: only in the hardest of a gust
pipe(u) = bandpass2(950 + 1500 * u, 30)
  : *(hard * hard * ridge * 0.8 : smooth(0.995)) with {
  hard = max(u - 0.6, 0);
};

process(l, r) = l +
  (
    white(LEFT)
      <: moan(150, 150, 7, 0.194, left_low),
        moan(300, 330, 9, 0.116, left_high),
        pipe(left_high)
      :> _
  ),
  r +
    (
      white(RIGHT)
        <: moan(172, 165, 7, 0.194, right_low),
          moan(268, 300, 9, 0.116, right_high),
          pipe(right_low)
        :> _
    );
