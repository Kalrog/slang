// sound/life/rough: the voices that are not whistles: a train of pulses
// (a sawtooth: each of its steps is a blow) through two resonances. Slow
// pulses through a tree trunk's resonances are a woodpecker's drum roll;
// some fifty a second, unsteady and with breath among them, through a
// throat's formants are a raven's croak; a steady hundred and seventy
// through wide low ones are a bumblebee.
//
// A syllable starts as in sound/life/whistle.dsp (`hit`, `delay`; held
// with no release, joined with no attack), and its controls must be set
// together with `hit`; the voice's character (jitter, waver, hiss, the
// resonances) is set once for a song, while nothing sounds.
//
// Output: the voice (how loud depends on the resonances: sound/life.slang
// sets their gains so that a full syllable peaks near 1).
import "std";

// ------------------------------------------------------------ controls

// the trigger and how many samples after it the syllable starts
hit = hslider("hit", 0, 0, 1000000000, 1);
delay = hslider("delay", 0, 0, 4096, 1);
// how long it is, s
dur = hslider("dur", 0.1, 0.001, 30, 0.0001);
// the pulses a second: at its start and end, and how far its middle lies
// above the straight line between them
from = hslider("from", 50, 1, 2000, 0.01);
to = hslider("to", 50, 1, 2000, 0.01);
arch = hslider("arch", 0, -2000, 2000, 0.01);
// how loud it starts and ends (0: no syllable yet)
loud = hslider("loud", 0, 0, 1, 0.001);
fade = hslider("fade", 0, 0, 1, 0.001);
// how long it takes to open and to close, s
attack = hslider("attack", 0.005, 0, 5, 0.0001);
release = hslider("release", 0.01, 0, 5, 0.0001);
// 1: the first pulse comes with the syllable's start (a drum roll's first
// knock), and the roll has as many as its pitch says; 0: wherever the
// pulses are
strike = hslider("strike", 0, 0, 1, 1);
// how unsteady the pulses are (a share of their rate), and how fast that
// changes, Hz
jitter = hslider("jitter", 0, 0, 1, 0.001);
waver = hslider("waver", 100, 0.1, 2000, 0.1);
// how much of the voice is breath (noise) instead of pulses
hiss = hslider("hiss", 0, 0, 1, 0.001);
// the two resonances: where, how narrow, how loud
low = hslider("low", 1000, 50, 8000, 1);
low_q = hslider("low_q", 5, 0.3, 40, 0.01);
low_gain = hslider("low_gain", 1, 0, 50, 0.01);
high = hslider("high", 1800, 50, 8000, 1);
high_q = hslider("high_q", 5, 0.3, 40, 0.01);
high_gain = hslider("high_gain", 1, 0, 50, 0.01);
// what the air between leaves of it: a lowpass, Hz (sound/layers/life)
cutoff = hslider("cutoff", 16000, 100, 20000, 1);

// ------------------------------------------------------------ a syllable

// samples since the syllable began (negative: it has not yet)
fired = hit != hit';
age = (\(a).(select2(fired, a + 1, 0 - delay))) ~ _;

// how far through it is, 0 to 1 (held at 1 after its end)
length = max(dur * SR, 1);
u = min(age * (1 / length), 1);

// the envelope, as the whistle's
closing = release * SR;
edge = min(
  (age + 1) * (1 / max(attack * SR, 1)),
  1 + (length - closing - age) * ((release > 0) / max(closing, 1)),
);
level = min(max(edge, 0), 1) * (loud + (fade - loud) * u) : smooth(0.985);

// ------------------------------------------------------------ the voice

white = noises(43);
// the unsteadiness: noise through a lowpass, brought back to a spread of
// about 1 whatever the lowpass
slow = exp(-TAU * waver / SR);
wobble = white : smooth(slow) : *(sqrt(3 * (1 + slow) / (1 - slow)));

// the pulses: a sawtooth, its rate along the parabola of from, to and
// arch. A struck syllable starts just before a step, so that its first
// blow comes once the envelope is open
rate = (from / SR + u * ((to - from + 4 * arch) / SR - u * (4 * arch / SR))) *
  (1 + jitter * wobble);
phase = (\(p).(select2((age == 0) * strike, frac(p + rate), 0.9))) ~ _;
pulses = (2 * phase - 1) * (1 - hiss) + white * hiss;

// only the sawtooth's steps are wanted, not its slow ramps: what lies
// under the voice is taken off before the resonances
steps = _ <: _ - lowpass1(120);

process = pulses * level : steps
  <: bandpass2(low, low_q) * low_gain, bandpass2(high, high_q) * high_gain
  :> lowpass1(cutoff) : lowpass1(cutoff);
