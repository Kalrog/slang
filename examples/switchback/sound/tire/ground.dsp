// sound/tire/ground: what the ground does under a tire, beside shaking it
// (sound/tire.dsp): the second of the programs a wheel runs. The tire's
// sound comes in, the ground's is added, and soft ground swallows the
// highs of both.
//
// - grit: stones and crumbs crushed under the tread, so many to a meter
//   (not to a second: the faster the wheel the more, and none when it
//   stands). Each is a tick with a pitch and a loudness of its own; a
//   few are loud, most barely there. On wet ground a tick is a squelch
//   (soft, its pitch falling), on wood a knock. Two voices sound them;
//   the second, once the tire slides, sounds what it throws against the
//   truck instead (stones ping, clods thud).
// - the fine of the ground (sand, blades of grass, dust) as a hiss in
//   the air, brighter the faster; and the tread peeling off the ground,
//   a faint grainy hiss that cares little for the speed
// - a sliding tire: what it tears loose or scrapes (a noise where the
//   ground has it: sand hisses, rock scrubs), and where the ground lets
//   it, a squeal: a resonance that narrows to a tone the harder it
//   slides (rubber holding and letting go)
//
// The controls are the sound's own (rates a second, pitches, levels):
// sound/layers/tires.slang works them out from the wheel's motion and
// from what the ground is like (sound/ground.slang).
//
// Input: the tire's sound. Output: the wheel's, on dry ground.
import "std";

// ------------------------------------------------------------ controls

// which wheel this is: each has its own noise
seed = nentry("seed", 0, 0, 255, 1);

// grit: how many crumbs are crushed a second; what one sounds like: its
// pitch (Hz), its ring (damped: 1 over the resonance's sharpness), how
// fast it dies (per second), how much of it is a blow and how much a puff
// of noise, how its pitch glides while it sounds, how alike they are in
// loudness (small: a few loud among many faint); and how loud the
// loudest
ticks = hslider("ticks", 0, 0, 20000, 0.01);
tick_pitch = hslider("tick_pitch", 2500, 40, 9000, 1);
tick_damped = hslider("tick_damped", 0.1, 0, 4, 0.0001);
tick_fade = hslider("tick_fade", 1000, 0, 20000, 1);
tick_hard = hslider("tick_hard", 1, 0, 4, 0.001);
tick_puff = hslider("tick_puff", 0, 0, 4, 0.0001);
tick_glide = hslider("tick_glide", 0, -1, 4, 0.001);
tick_even = hslider("tick_even", 0.05, 0.005, 4, 0.001);
gritty = hslider("gritty", 0, 0, 4, 0.0001);
// the second voice, the same: crumbs while the tire rolls, what it
// throws against the truck when it slides
knocks = hslider("knocks", 0, 0, 20000, 0.01);
knock_pitch = hslider("knock_pitch", 1800, 40, 9000, 1);
knock_damped = hslider("knock_damped", 0.07, 0, 4, 0.0001);
knock_fade = hslider("knock_fade", 500, 0, 20000, 1);
knock_hard = hslider("knock_hard", 1, 0, 4, 0.001);
knock_puff = hslider("knock_puff", 0, 0, 4, 0.0001);
knock_glide = hslider("knock_glide", 0, -1, 4, 0.001);
knock_even = hslider("knock_even", 0.05, 0.005, 4, 0.001);
knocking = hslider("knocking", 0, 0, 4, 0.0001);
// the fine of the ground: how many grains pass a second, how loud their
// hiss; and the peeling tread's
dust = hslider("dust", 0, 0, 20000, 0.01);
swish = hslider("swish", 0, 0, 4, 0.0001);
peel = hslider("peel", 0, 0, 4, 0.0001);
// sliding: the noise torn loose (how loud, where, how narrow) and the
// squeal (the same)
rasp = hslider("rasp", 0, 0, 4, 0.0001);
rasp_pitch = hslider("rasp_pitch", 2000, 40, 9000, 1);
rasp_damped = hslider("rasp_damped", 2, 0, 4, 0.0001);
squeal = hslider("squeal", 0, 0, 4, 0.0001);
squeal_pitch = hslider("squeal_pitch", 700, 40, 9000, 1);
squeal_damped = hslider("squeal_damped", 0.25, 0, 4, 0.0001);
// what soft ground swallows: nothing above this, Hz
damp = hslider("damp", 16000, 40, 20000, 1);

// ------------------------------------------------------------ noise

// one generator (std's, its increment drawn by the seed), from 0 to 1,
// and as many noises as are needed out of it: its value times a large
// number, less the whole of that
base = (*(69069) : -(0 - step) : %(4294967296)) ~ _ : /(4294967296) with {
  step = 2 * floor(frac((2 + 41 * seed) * 0.6180339887) * 2147483648) + 1;
};
uni(k) = frac(base * (1013.37 + 919.19 * k));
rnd(k) = uni(k) * 2 - 1;

// ------------------------------------------------------------ filters

// what is over fc Hz, gently (6 dB an octave)
over(fc) = _ <: _ - lowpass1(fc);

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

// ------------------------------------------------------------ things struck

// One voice of something struck. When t is 1 a new sound starts: as
// loud as `loudness` is then, at the pitch `pitch` is then (a turn per
// sample); a hard one is a blow of strength `blow`, a soft one a puff of
// noise (`puffed`: how much), and while it dies away (`dying` a sample)
// its pitch glides.
voice(t, loudness, pitch, blow, damped, glide, dying, puffed, noise) = t * blow +
  noise * env * puffed
  : ringing(f, damped) with {
  env = (\(e).(select2(t, e * dying, loudness))) ~ _;
  held = (\(p).(select2(t, p, pitch))) ~ _;
  f = min(held * (1 + glide * env), 1.2);
};

// one white noise for what hisses and puffs (each takes its own band of
// it)
white = rnd(1);

// ------------------------------------------------------------ grit

// The dice: a number drawn every sample. A crumb is crushed when it
// falls in the first voice's share of it, something is thrown when it
// falls in the second's (so many a second).
dice = uni(2);
// what is drawn for a sound: its place in the octave and a half around
// the ground's pitch (more of them low), and what its loudness is made
// of (a few are loud: 1 / (even + a number drawn))
place = 0.45 + 1.1 * uni(3) * uni(3);
drawn = uni(4);

tick_loud = tick_even / (tick_even + drawn);
tick_turn = turn(tick_pitch) * place;
crushed = voice(
  dice < min(ticks / SR, 0.3), tick_loud, tick_turn,
  tick_loud * tick_hard / tick_turn, tick_damped, tick_glide,
  1 - min(tick_fade / SR, 0.5), tick_puff * wide, white
) * (gritty : level);

knock_loud = knock_even / (knock_even + drawn);
knock_turn = turn(knock_pitch) * place;
knocked = voice(
  (dice >= 0.5) * (dice < 0.5 + min(knocks / SR, 0.3)), knock_loud, knock_turn,
  knock_loud * knock_hard / knock_turn, knock_damped, knock_glide,
  1 - min(knock_fade / SR, 0.5), knock_puff * wide, white
) * (knocking : level);

// ------------------------------------------------------------ the hiss

// the fine of the ground: a noise that takes a new value with every
// grain that passes and stays there (each stay longer or shorter by what
// the value is): read at the speed the ground passes
fines = (step ~ (_, _)) : (!, _) with {
  step(phase, held) = select2(wrapped, next, next - 1),
    select2(wrapped, held, rnd(5)) with {
    next = phase + min(dust / SR, 0.5) * (1 + 0.45 * held);
    wrapped = next >= 1;
  };
};
// the tread peeling off: a hiss whose loudness is drawn anew some three
// hundred times a second (grainy)
grain = (\(g).(select2(dice > 0.99375, g, drawn))) ~ _;
// what of them is over 1.5 kHz
hiss = fines * (swish : level) + white * grain * (peel : level) : over(1500);

// ------------------------------------------------------------ sliding

// what the tire tears loose or scrapes: a noise where the ground has it
// (dull at the top: earth in the air, not steam)
torn = white
  : ringing(turn(rasp_pitch), rasp_damped)
  : lowpass1(5000)
  : *(rasp * wide : level);

// the squeal: the same noise through a resonance, the narrower the
// harder the tire works the ground (the game lets its pitch wander, and
// lets it come and go)
sung = white
  : ringing(turn(squeal_pitch), squeal_damped)
  : *(squeal * wide : level);

// ------------------------------------------------------------ all of it

// with the tire's own sound, less what soft ground swallows
process = _ + crushed + knocked + hiss * 0.1 + torn * 0.3 + sung * 0.2
  : lowpass1(damp)
  : lowpass1(damp);
