// sound/camp: a camp's fire in its ring of stones: embers and a low
// flame. It crackles: the wood splits at random, a few times a second,
// each a burst of noise a few milliseconds long through a band of its
// kind: snaps, ticks, cracks, and now and then a pop, most of them
// faint. Under them the embers hiss and the flame flutters, low: how
// much just now the voice says (sound/layers/camp), and both are only
// heard from near. Wind fans it.
//
// Output: the fire, as it sounds beside it (the voice puts it where it
// is for the listener).
import "std";

// how near the listener is (1 beside it, 0 at the edge of earshot), and
// the wind (0 to 1)
near = hslider("near", 1, 0, 1, 0.001);
wind = hslider("wind", 0.2, 0, 1, 0.001);
// the flame's flutter and the embers' glow just now (about 1)
flutter = hslider("flutter", 1, 0, 3, 0.001) : smooth(0.99);
glow = hslider("glow", 1, 0, 3, 0.001) : smooth(0.999);

// A number from 0 to 1 at random, one for each seed: std's generator
// with its state kept as a fraction. The seeds are what it adds at every
// step; no two of the sound's programs share one (see sound/air.dsp).
rand(seed) = (*(69069) : +(seed / 4294967296) : frac) ~ _;
CRACK = 1830299339;
EMBER = 2336478295;
// two white noises from -0.5 to 0.5 of one generator: its high bits and
// its low bits
white(seed) = rand(seed) - 0.5;
other(seed) = frac(rand(seed) * 4096) - 0.5;

// Every sample one number at random, stretched so that it is under 1 as
// often as the wood should crack (more often in wind). Then it says what
// kind of crack it is (most are snaps, few are pops), and another
// number made of it how hard.
draw = rand(CRACK) * SR / (7 + 9 * wind);
hard(q) = 0.2 + 0.8 * size * size with {
  size = frac(q * 37);
};

// a kind of crack: those drawn between `from` and `to`; each a burst of
// the noise that dies away in `time` seconds, through a band at f Hz
kind(q, from, to, time, f, res, loud) = (
  (q >= from) * (q < to) * hard(q) : + ~ *(exp(-1 / (time * SR)))
) * other(CRACK)
  : bandpass2(f, res)
  : *(loud);

crackle(q) = kind(q, 0, 0.5, 0.0015, 3800, 2, 0.5) +
  kind(q, 0.5, 0.8, 0.003, 2400, 2.5, 0.75) +
  kind(q, 0.8, 0.94, 0.006, 1500, 3, 1.1) +
  kind(q, 0.94, 1, 0.014, 650, 2.5, 1.3);

// the embers' hiss and the flame's flutter
hiss = white(EMBER)
  : bandpass2(3000, 0.8)
  : *(glow * (0.6 + 0.8 * wind) * near * 0.045);
flame = other(EMBER)
  : bandpass2(170, 0.7)
  : *(flutter * (0.5 + wind) * near * near * 0.21);

// (from far away the highs are lost)
process = (draw : crackle) * 0.65 + hiss + flame : lowpass1(2200 + 5800 * near);
