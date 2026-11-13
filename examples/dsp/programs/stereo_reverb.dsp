// A stereo reverb after Freeverb: two banks of combs and allpasses, the
// right one a little longer, so the sides decorrelate. A .dsp file: a
// program of its own, required as a module (require("programs/stereo_reverb")).
import "std";

room = hslider("room", 0.75, 0, 1, 0.01);
damp = hslider("damp", 0.4, 0, 1, 0.01);
wet = hslider("wet", 0.3, 0, 1, 0.01);

side(spread) = *(0.015)
  <: par(i, 8, comb(take(i + 1, combs) + spread, fb, damp * 0.4))
  :> seq(i, 4, allpass(take(i + 1, allpasses) + spread, 0.5)) with {
  fb = room * 0.28 + 0.7;
  combs = (1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617);
  allpasses = (556, 441, 341, 225);
};

mix(dry, l, r) = dry * (1 - wet) + l * wet, dry * (1 - wet) + r * wet;

// two inputs summed to mono, two outputs
process = + <: _, side(0), side(23) : mix;
