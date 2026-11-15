// sound/water/lake: the lake's shore. Still water makes no sound of its
// own; what is heard is small waves coming in: each runs up the shore
// with a soft rush that brightens as it comes and dies away as it runs
// back. When they come and how large each is the voice says
// (sound/layers/water: one every two or three seconds, never quite on
// time); here is what a wave sounds like. There are two shores of it,
// to the left and to the right of where the water lies for the listener.
//
// Outputs: the two halves of the waves.
import "std";

// how loud (by the shore's distance), and how much of a wave there is on
// each shore just now (0: none, 1: a large one at its highest)
level = hslider("level", 0, 0, 4, 0.001) : smooth(0.999);
surge_a = hslider("surge_a", 0, 0, 1, 0.001);
surge_b = hslider("surge_b", 0, 0, 1, 0.001);

// A number from 0 to 1 at random, one for each seed: std's generator
// with its state kept as a fraction. The seeds are what it adds at every
// step; no two of the sound's programs share one (see sound/air.dsp).
rand(seed) = (*(69069) : +(seed / 4294967296) : frac) ~ _;
white(seed) = rand(seed) - 0.5;

// a wave: noise in a band that rises with it, from 380 Hz as it starts
// to run up to 1900 at its highest
shore(seed, surge) = white(seed)
  : bandpass2(380 + 1500 * surge, 0.9)
  : *(surge * level * 0.33 : smooth(0.995));

process = shore(3479995859, surge_a), shore(796084093, surge_b);
