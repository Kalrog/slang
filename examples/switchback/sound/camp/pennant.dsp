// sound/camp/pennant: a camp's pennant on its pole, flapping. Cloth in
// wind: every flap is a soft thud, low, as the cloth bellies and is
// pulled straight; between the flaps it ruffles; and when it blows hard
// its tip snaps. When it flaps and how hard the voice says
// (sound/layers/camp: the quicker and harder the more wind there is).
//
// Output: the pennant, as it sounds beside its pole.
import "std";

// a flap: the voice counts them up, and says how hard this one is (0 to
// 1); and the wind (0 to 1)
flap = hslider("flap", 0, 0, 1000000000, 1);
hard = hslider("hard", 0, 0, 1, 0.001);
wind = hslider("wind", 0, 0, 1, 0.001);

// A number from 0 to 1 at random, one for each seed: std's generator
// with its state kept as a fraction. The seeds are what it adds at every
// step; no two of the sound's programs share one (see sound/air.dsp).
rand(seed) = (*(69069) : +(seed / 4294967296) : frac) ~ _;
CLOTH = 3814765975;
white(seed) = rand(seed) - 0.5;
other(seed) = frac(rand(seed) * 4096) - 0.5;

// 1 for the first sample after the voice counted a flap
fired = flap != flap';

// something struck by each flap that dies away in `time` seconds
struck(time) = fired * hard : + ~ *(exp(-1 / (time * SR)));

// the thud (cloth is soft: it takes a few milliseconds to come), the
// ruffle between the flaps (it never quite stops while there is wind),
// and the snap of the tip (only when it blows hard)
thud = white(CLOTH)
  : bandpass2(210, 0.9)
  : *(struck(0.035) : smooth(0.993) : *(0.75));
ruffle = other(CLOTH)
  : bandpass2(950, 0.7)
  : *((0.02 + 0.1 * struck(0.09)) * (wind : smooth(0.999)) * 1.5);
snap = white(CLOTH)
  : bandpass2(1900, 1.2)
  : *(struck(0.004) * strong * strong * 0.35) with {
  strong = min(max((wind - 0.3) / 0.5, 0), 1);
};

process = thud + ruffle + snap;
