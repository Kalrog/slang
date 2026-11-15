// sound/air: the air past the listener, who rides behind the truck: what
// is heard of the truck's own speed through the air, and of a wind that
// blows hard enough to be felt (the voice, sound/layers/air, hands in
// the speed of the air past each ear: the truck's against the wind's).
//
// The air is a source and the things in it are filters, as an engine's
// pulses are and its pipes. What the speed changes is the source: its
// loudness goes with the cube of the speed (the sound power of air torn
// at edges with the sixth: 18 dB for twice the speed, which is why it is
// nothing at a walk and most of what is heard on a fast road), and its
// frequencies go up in step with the speed (an eddy shed by a thing d
// wide comes 0.2 v / d times a second). What the speed does not change
// are the hollows the air blows across, which ring at their own pitches:
// so the sound gets louder and brighter with speed, and is never a noise
// with a volume knob, nor a tape run faster.
//
// Inputs: a stereo pair to add to. Outputs: the pair with the air in it.
import "std";

// the air's speed past each ear as it is now, m/s (with its turbulence:
// the voice's)
left = hslider("left", 0, 0, 60, 0.01);
right = hslider("right", 0, 0, 60, 0.01);
// how much on the truck whistles, 0 to 1 (a load on the roof, a light bar)
rack = hslider("rack", 0.4, 0, 1, 0.01);

// the speed the levels below are meant at: 60 km/h
V0 = 16.67;

// A number from 0 to 1 at random, one for each seed: std's generator
// with its state kept as a fraction (a multiply and a fract). The seeds
// are what it adds at every step: no two of them may be a simple
// fraction of each other, or their noises are alike (std's noises(0) and
// noises(1) are a third the same), and no two of the sound's programs
// may share one, or what they make cancels where it meets. These are
// from the roots of the primes.
rand(seed) = (*(69069) : +(seed / 4294967296) : frac) ~ _;
LEFT = 1779033703;
RIGHT = 3144134277;
// two white noises from -0.5 to 0.5 of one generator: its high bits and
// its low bits (two bands of one noise would cancel where they meet)
white(seed) = rand(seed) - 0.5;
other(seed) = frac(rand(seed) * 4096) - 0.5;

// how loud the air is at the speed v, 1 at V0. (The bands below widen
// with the speed and let more of the noise through, by its root: the
// rest of the cube is made up here.)
loud(v) = pow(v / V0, 2.5);

// the turbulent air along the truck and round the head: a rumble whose
// upper edge rises with the speed
rumble(v) = bandpass2(max(4.5 * v, 15), 0.6) : lowpass1(max(9 * v, 30));
// the air torn at edges (the pillars, the mirrors, the ears): a broad
// rush whose middle rises with the speed
rush(v) = bandpass2(max(45 * v, 80), 0.7) : lowpass1(max(180 * v, 320));
// one ear's air
side(seed, v) = (white(seed) : rumble(v) * 0.46) +
  (other(seed) : rush(v) * 0.073)
  : *(loud(v) : smooth(0.995));

// what stays where it is: the hollows of the truck's body, which the air
// of both sides blows across: they ring at their own pitches, in the
// middle, where the truck is
body = _ <: bandpass2(240, 2.2) * 0.8, bandpass2(2000, 2.5) * 0.6 :> _;

// something thin in the wind sings: a narrow band at the pitch of its
// eddies, which wavers as the air does; only from 35 km/h or so
whistle(v) = white(LEFT) + white(RIGHT)
  : bandpass2(max(42 * v, 100), 22)
  : *(sing * sing * loud(v) * rack * 0.15 : smooth(0.995)) with {
  sing = min(max((v - 9) / 9, 0), 1);
};

// (each side is made once and handed on by name: a definition that is
// used twice is computed twice)
process(l, r) = side(LEFT, left),
  side(RIGHT, right),
  whistle((left + right) / 2)
  : \(a, b, w).((a + b : body) + w, a, b)
  : \(middle, a, b).(l + a + middle, r + b + middle);
