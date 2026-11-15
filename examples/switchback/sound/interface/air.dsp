// sound/interface/air: air and cloth moving: the map unfolded and folded
// away, paint sprayed, the truck swung back onto its wheels
// (sound/layers/interface shapes each: it moves the band and the
// loudness block by block). Noise in a band
// with nothing much above and below it (a hiss over all frequencies is a
// radio, not air), a little different in each ear so that it is wide, and
// uneven as cloth is: it comes and goes a few dozen times a second.
//
// Outputs: left, right (no input).
import "std";

// how loud (made smooth here: the layer sets it in steps), the band's
// middle, Hz, and how far it reaches to either side, as a ratio (2: an
// octave down and an octave up)
gain = hslider("gain", 0, 0, 4, 0.0001) : smooth(0.996);
center = hslider("center", 1200, 60, 12000, 1);
wide = hslider("wide", 1.5, 1.05, 4, 0.01);
// how uneven: 0 a steady hiss, 1 cloth
rough = hslider("rough", 0, 0, 1, 0.01);

// (its upper edge never above what the sample rate carries)
banded = highpass2(center / wide, 0.7)
  : lowpass2(min(center * wide, min(16000, 0.4 * SR)), 0.7);
// two noises that have nothing in common. (std's noises(k) is one
// sequence times 2k + 1: two of them are alike by one over the product
// of those numbers as a fraction in lowest terms, so noises(0) and
// noises(1) are a third the same, and 23 and 27 next to nothing.)
mid = noises(11) : banded;
side = noises(13) : banded;
// the unevenness: slow noise around 1, never below nothing and never
// more than half as loud again
flap = min(
  1.5,
  max(0, 1 + rough * (noises(8) : lowpass1(38) : lowpass1(38) : *(26))),
);

// what both ears hear, and what they hear differently
process = (mid + side * 0.55) * gain * flap, (mid - side * 0.55) * gain * flap;
