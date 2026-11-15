// sound/water: the river as the listener hears it. Its bed is made here:
// water over stones is a wash of noise, low and broad, with a brighter
// hiss on it, each swelling and sinking by itself as the eddies do
// (the voice, sound/layers/water, moves them); the faster the water
// runs the louder both are, and rapids roar. The bubbles
// (sound/water/bubbles.dsp) and the lake's waves (sound/water/lake.dsp)
// come in; and all of it goes through what the distance leaves of it:
// from far away a river is a dull rush.
//
// There are two halves of everything, to the left and to the right of
// where the water lies for the listener: the voice puts them there, wide
// apart when the water is near.
//
// Inputs: the bubbles' two halves, the lake's two halves. Outputs: the
// two halves of the water.
import "std";

// how loud the river's bed is (by its distance: 1 at ten meters), how
// fast it runs (0 still, 1 rapids), and the highest the distance leaves,
// Hz
river = hslider("river", 0, 0, 4, 0.001) : smooth(0.999);
flow = hslider("flow", 0.5, 0, 1, 0.001);
dull = hslider("dull", 8000, 200, 16000, 1);
// the eddies: how much of the wash and of the hiss of each half there is
// just now (about 1)
wash_a = hslider("wash_a", 1, 0, 3, 0.001) : smooth(0.995);
hiss_a = hslider("hiss_a", 1, 0, 3, 0.001) : smooth(0.995);
wash_b = hslider("wash_b", 1, 0, 3, 0.001) : smooth(0.995);
hiss_b = hslider("hiss_b", 1, 0, 3, 0.001) : smooth(0.995);

// A number from 0 to 1 at random, one for each seed: std's generator
// with its state kept as a fraction. The seeds are what it adds at every
// step; no two of the sound's programs share one (see sound/air.dsp).
rand(seed) = (*(69069) : +(seed / 4294967296) : frac) ~ _;
A = 355462361;
B = 1731405415;
// two white noises from -0.5 to 0.5 of one generator: its high bits and
// its low bits
white(seed) = rand(seed) - 0.5;
other(seed) = frac(rand(seed) * 4096) - 0.5;

// the wash: lower and broader the faster the water (rapids roar)
wash(seed) = white(seed)
  : bandpass2(600 - 250 * flow, 0.7 - 0.3 * flow)
  : *((0.5 + 1.2 * flow) * 0.215);
// the hiss (the word is too bright for it: it lies in the middle): next
// to nothing on a slow stretch
hiss(seed) = other(seed)
  : bandpass2(1400 + 900 * flow, 0.8)
  : *((0.25 + 1.4 * flow * flow) * 0.05);

// what is under it: a river does not rumble, only rapids do a little
// (and a bubble's first moment is a thump)
low_cut = _ <: _ - lowpass1(220 - 120 * flow);

// one half of the river: its bed and its bubbles, the lake's waves, and
// all of it as far as it carries
half(seed, washing, hissing, bubbles, waves) = (
  wash(seed) * washing + hiss(seed) * hissing
) * river + bubbles
  : low_cut
  : +(waves)
  : lowpass2(dull, 0.6);

process(bubbles_a, bubbles_b, waves_a, waves_b) = half(
  A, wash_a, hiss_a, bubbles_a, waves_a
),
  half(B, wash_b, hiss_b, bubbles_b, waves_b);
