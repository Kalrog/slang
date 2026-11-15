// sound/tire: a tire rolling on the ground: one wheel of the truck (a
// 33 inch mud-terrain tire, 0.42 m to the ground, some 52 tread blocks
// around it), heard from outside. The first of the three programs a
// wheel runs (sound/layers/tires.slang): this one is the tire itself,
// shaken by the ground; sound/tire/ground.dsp is what the ground does
// under it (grit crushed, dust, what a sliding tire tears loose),
// sound/tire/water.dsp the water it wades through. One program of all of
// it would not fit the kernel VM's registers.
//
// What moves and what stays: everything the ground does to the tire
// comes faster the faster the tire turns, and all of it sounds through
// the tire, whose own resonances stay where they are: the carcass
// (90 Hz), the air inside it (180 Hz, narrow), the tread and the horn
// between tire and ground (900 Hz, broad). A level that only grew with
// the speed would be a hand on a volume knob; a sound that only rose
// would be a tape running faster.
//
// - the ground's lumps: a height that changes every grain as the tire
//   rolls over it (a noise read at the speed the ground passes), each
//   change a blow to the tire: at a walk single soft thuds, a roar at
//   speed
// - the tread: every block strikes the ground, the blocks unevenly
//   spaced, in an order that comes round once a turn (a mud tire's hum;
//   in the air its whir)
// - a bump: the carcass thumps, and the wheel hops on its tire (13 Hz,
//   more felt than heard: for a moment the rolling flutters)
// - the wheel steered where it stands: the patch on the ground winds up
//   and lets go, over and over (a groan)
//
// How loud each is the game says (sound/layers/tires.slang works it out
// from the wheel's speed and load and from what the ground is like,
// sound/ground.slang): the controls here are the sound's own.
//
// Nothing of a tire's own sound is high (its resonances take what is
// over a few kHz): the layer runs this program at a quarter of the
// mixer's rate and draws lines between its samples.
import "std";

CIRC = 2.639; // the tire's circumference, m
LUGS = 52; // tread blocks around it

// ------------------------------------------------------------ controls

// which wheel this is: each has its own noise
seed = nentry("seed", 0, 0, 255, 1);

// the tread's speed, m/s (in the air too)
speed = hslider("speed", 0, 0, 60, 0.001);
// the ground's lumps: how many come under the tire a second, and how
// hard they shake it
lumps = hslider("lumps", 0, 0, 20000, 0.01);
shake = hslider("shake", 0, 0, 4, 0.0001);
// how hard the tread's blocks strike
slap = hslider("slap", 0, 0, 4, 0.0001);
// the wheel steered standing: how loud its groan
groan = hslider("groan", 0, 0, 4, 0.0001);
// a bump: hit changes when there is one, strength says how hard (the
// suspension's jolt, m/s)
hit = hslider("hit", 0, 0, 1, 1);
strength = hslider("strength", 0, 0, 4, 0.001);

// ------------------------------------------------------------ noise

// one generator (std's, its increment drawn by the seed), from 0 to 1,
// and the noises needed out of it: its value times a large number, less
// the whole of that
base = (*(69069) : -(0 - step) : %(4294967296)) ~ _ : /(4294967296) with {
  step = 2 * floor(frac((1 + 41 * seed) * 0.6180339887) * 2147483648) + 1;
};
rnd(k) = frac(base * (1013.37 + 919.19 * k)) * 2 - 1;

// ------------------------------------------------------------ filters

// a resonance at fc Hz, q its sharpness, 1 at its peak (a biquad that
// keeps two numbers)
peak(fc, q) = (step ~ (_, _)) : (!, !, _) with {
  w = TAU * fc / SR;
  alpha = sin(w) / (2 * q);
  b0 = alpha / (1 + alpha);
  a1 = -2 * cos(w) / (1 + alpha);
  a2 = (1 - alpha) / (1 + alpha);
  step(s1, s2, x) = s2 - a1 * y, 0 - b0 * x - a2 * y, y with {
    y = b0 * x + s1;
  };
};

// a level as a signal: glided (over some 12 ms), so that no step from
// block to block is heard
level = smooth(exp(-1 / (0.012 * SR)));

// a blow is one sample long, and the shorter a sample the less there is
// in it: blows are given for a rate of 12 kHz, and are this much harder
// at another
per = SR / 12000;

// ------------------------------------------------------------ the ground's lumps

// The ground's height as the tire comes over it: a noise that takes a
// new value `rate` times a second and stays there (each stay longer or
// shorter by what the value is, so no pitch comes of the lumps' length).
// What shakes the tire is the height changing: a blow at every lump,
// rounded as the tread's rubber rounds it, the sharper the faster the
// tire rolls. So the blows' spectrum reaches higher with the speed.
blows(k, rate) = (step ~ (_, _))
  : (!, _)
  : (_ <: _ - mem)
  : lowpass1(speed / 0.011 + 25) with {
  step(phase, held) = select2(wrapped, next, next - 1),
    select2(wrapped, held, rnd(k)) with {
    next = phase + min(rate / SR, 0.5) * (1 + 0.45 * held);
    wrapped = next >= 1;
  };
};
// the lumps themselves (at a walk single soft thuds: the carcass
// answers), and the grit on them, six to a lump: so many that they are a
// noise (the tread's roar)
coarse = blows(1, lumps);
small = blows(3, lumps * 6) * 0.5;

// ------------------------------------------------------------ the tread

// where the wheel is in its turn, and in which block's pitch
turn = phasor(speed / CIRC);
lug = turn * LUGS;
block = floor(lug);
within = lug - block;
// each block has its own place in its pitch and its own weight, the same
// every turn (numbers that neither repeat nor come round within the 52:
// blocks spaced by a short pattern would sing its tune)
own(k) = frac(block * (block + k) * 0.0773 + block * 0.6180339887);
edge = 0.12 + 0.55 * own(7);
struck = within >= edge;
strikes = (struck > struck') * (0.5 + 0.5 * own(23)) : lowpass1(900);
// (a tire is never quite round: once a turn it is a little louder)
round = 1 + 0.12 * (4 * abs(turn - 0.5) - 1);

// ------------------------------------------------------------ a bump

jolt = (hit != hit') * strength * per : lowpass1(300);
// the wheel hopping on its tire afterwards
hop = jolt : peak(13.5, 2.2) : *(125);

// ------------------------------------------------------------ steering

// the patch on the ground winds up and lets go, never twice the same: a
// ramp that falls back, some eighty-five times a second
wound = (wind ~ (_, _)) : (_, !) : -(0.5) with {
  wind(phase, own) = select2(let_go, next, next - 1),
    select2(let_go, own, rnd(2)) with {
    next = phase + 85 / SR * (1 + 0.4 * own);
    let_go = next >= 1;
  };
};
twisted = wound * (groan : level);

// ------------------------------------------------------------ the tire

// what shakes the tire: the lumps (and the hop's flutter on them), the
// blocks striking, the twisting
flutter = max(1 + hop, 0);
rolling(lump, grit) = (lump * coarse + grit * small) * (shake : level) *
  flutter * round * per;
struck_by = strikes * (slap : level) * round * per;

// its resonances: the tread and the horn (the grit and the blocks reach
// them), the air inside (it sings when the twisting patch lets go at its
// pitch: the groan), the carcass (the lumps', and a bump's most)
process = (
  rolling(0.3, 1) + struck_by + twisted * 0.15 + jolt * 1.5 : peak(900, 1.1)
) +
  (rolling(1, 0.5) + struck_by + twisted * 3 + jolt * 2.5 : peak(180, 16)) * 0.5 +
  (rolling(1, 0.2) + struck_by * 0.7 + twisted + jolt * 10.6 : peak(90, 2.5)) +
  hop * 0.02;
