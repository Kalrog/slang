// sound/tire/water: wheels in water: the third of the tire's programs,
// one for each axle (the water round two wheels a track apart is one
// sound), and only while it is wet (sound/layers/tires.slang).
//
// Water moved by a tire is a body of water moved: its weight is low and
// in the middle, and it swells; it does not hiss and it does not crack.
//
// - wading: the water the tires push aside and churn, a dull rush that
//   grows with the speed (the game lets it swell and sink: it sloshes)
// - a splash as a wheel goes in: it swells over some tens of
//   milliseconds and dies over a third of a second, darker as it dies,
//   over the low push of the water giving way; the faster the wheel goes
//   in the bigger and the brighter, and slowly there is next to none
// - drops: the spray falling back, the tread shedding water (and for a
//   moment after the wheels are out, draining): short plips
// - bubbles: air dragged under and let go: short tones that rise
//
// The controls are the sound's own (rates a second, pitches, levels):
// sound/layers/tires.slang works them out from how deep the wheels are
// in and how they move.
//
// Output: the water's sound.
import "std";

// ------------------------------------------------------------ controls

// which axle this is: each has its own noise
seed = nentry("seed", 0, 0, 255, 1);

// the rush: how loud, and where it sits (Hz)
rush = hslider("rush", 0, 0, 4, 0.0001);
rush_pitch = hslider("rush_pitch", 900, 40, 9000, 1);
// drops and bubbles: how many a second, how loud
drops = hslider("drops", 0, 0, 20000, 0.01);
dripping = hslider("dripping", 0, 0, 4, 0.0001);
bubbles = hslider("bubbles", 0, 0, 20000, 0.01);
bubbling = hslider("bubbling", 0, 0, 4, 0.0001);
// a splash: hit changes when there is one, strength says how big (0 to
// 1)
hit = hslider("hit", 0, 0, 1, 1);
strength = hslider("strength", 0, 0, 4, 0.001);

// ------------------------------------------------------------ noise

// one generator (std's, its increment drawn by the seed), from 0 to 1,
// and the noises needed out of it: its value times a large number, less
// the whole of that
base = (*(69069) : -(0 - step) : %(4294967296)) ~ _ : /(4294967296) with {
  step = 2 * floor(frac((3 + 41 * seed) * 0.6180339887) * 2147483648) + 1;
};
uni(k) = frac(base * (1013.37 + 919.19 * k));
rnd(k) = uni(k) * 2 - 1;

// ------------------------------------------------------------ filters

// a resonator whose pitch may move from sample to sample (a state
// variable filter): what it rings with at f (a turn per sample) when x
// strikes it; damped: 1 over its sharpness
ringing(f, damped) = (step ~ (_, _)) : (!, _) with {
  step(low, band, x) = moved, band + f * (x - moved - damped * band) with {
    moved = low + f * band;
  };
};

// a pitch in Hz as that filter's turn per sample
turn(hz) = 2 * sin(PI * hz / SR);

// a level as a signal: glided, so that no step from block to block is
// heard
level = smooth(0.998);

// (levels given for a noise of a second's width are for this rate's)
wide = sqrt(SR);

// what of a signal is under a pitch that may move from sample to sample
// (a: the filter's step, about 2 pi Hz / SR), gently
under(a) = (\(y, x).(y + a * (x - y))) ~ _;

// One voice of something struck (as in sound/tire/ground.dsp): when t is
// 1 a new sound starts, as loud as `loudness` is then, at the pitch
// `pitch` is then; a blow of strength `blow`, and while it dies away
// (`dying` a sample) its pitch glides.
voice(t, loudness, pitch, blow, damped, glide, dying) = t * blow
  : ringing(f, damped) with {
  env = (\(e).(select2(t, e * dying, loudness))) ~ _;
  held = (\(p).(select2(t, p, pitch))) ~ _;
  f = min(held * (1 + glide * env), 1.2);
};

// ------------------------------------------------------------ wading

white = rnd(1);
// a noise around the rush's pitch, wide, and without its highs
rushing = white
  : ringing(turn(rush_pitch), 1.4)
  : lowpass1(1200)
  : *(rush * wide : level);

// ------------------------------------------------------------ a splash

struck = hit != hit';
// how much of it is left: all when the wheel goes in, a fifth after 0.4
// s; and what is heard of that: it swells (water takes some 30 ms to
// get out of the way), it does not burst
left = (\(e).(select2(struck, e * exp(-4 / SR), strength))) ~ _;
swell = left : lowpass1(6);
// the water thrown up: a noise without its highs, the brighter the
// bigger the splash, darker as it dies (from about 1.1 kHz down to 450
// Hz); and the water giving way under it: the same noise, low
thrown = white * swell
  <: (under(reach) : under(reach)), ringing(turn(130), 0.9) * 0.25
  :> _ with {
  reach = min(0.06 + 0.09 * swell, 0.25);
};
splash = thrown * (wide * 0.0024);

// ------------------------------------------------------------ drops and bubbles

// the dice: a number drawn every sample: a drop falls when it is in the
// drops' share of it, a bubble bursts when it is in the bubbles'
dice = uni(2);
// what is drawn for one: its place among the pitches (more of them low),
// what its loudness is made of
place = uni(3) * uni(3);
drawn = uni(4);

// drops: short plips (1.2 to 3.6 kHz), a few of them loud
drop_turn = turn(1500) * (0.8 + 1.6 * place);
drop_loud = 0.1 / (0.1 + drawn);
dropped = voice(
  dice < min(drops / SR, 0.2), drop_loud, drop_turn, drop_loud / drop_turn,
  0.22, -0.15, exp(-400 / SR)
) * (dripping : level);

// bubbles: a tone that rises as it dies (the air's pocket closing)
bubble_turn = turn(420) * (0.7 + 2.6 * place);
bubble_loud = 0.25 / (0.25 + drawn);
bubbled = voice(
  (dice >= 0.5) * (dice < 0.5 + min(bubbles / SR, 0.2)), bubble_loud,
  bubble_turn, bubble_loud / bubble_turn, 0.06, -0.3, exp(-90 / SR)
) * (bubbling : level);

// ------------------------------------------------------------ all of it

// (what is small and hard in it, without its edge)
process = rushing + splash + (dropped + bubbled : lowpass1(3000));
