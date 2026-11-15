// sound/life/whistle: a bird's whistle, one syllable at a time: a sine
// whose pitch runs along a curve while an envelope opens and closes it,
// with a little of its second and third harmonic, and duller the further
// away it is. Tits, finches, warblers, thrushes, the cuckoo, the buzzard
// and the marmot are all sung with it: what differs is the syllables,
// which sound/life.slang writes and sound/layers/life.slang hands over
// one by one.
//
// A syllable starts when `hit` changes, `delay` samples into that block
// (so it starts on its sample, not on a block's edge). Its controls must
// be set together with `hit` and left alone until the next: the program
// keeps no copy of them. A syllable with no release is held at its last
// pitch until the next one starts; one with no attack then takes over
// without a break: so a slide or a trill is drawn as several syllables in
// one breath.
//
// Output: the whistle (a full syllable peaks near 1).
import "std";

// ------------------------------------------------------------ controls

// the trigger and how many samples after it the syllable starts
hit = hslider("hit", 0, 0, 1000000000, 1);
delay = hslider("delay", 0, 0, 4096, 1);
// how long it is, s
dur = hslider("dur", 0.1, 0.001, 30, 0.0001);
// its pitch: where it starts and ends, Hz, and how far its middle lies
// above the straight line between them
from = hslider("from", 3000, 20, 12000, 0.1);
to = hslider("to", 3000, 20, 12000, 0.1);
arch = hslider("arch", 0, -8000, 8000, 0.1);
// how loud it starts and ends (0: no syllable yet)
loud = hslider("loud", 0, 0, 1, 0.001);
fade = hslider("fade", 0, 0, 1, 0.001);
// how long it takes to open and to close, s
attack = hslider("attack", 0.005, 0, 5, 0.0001);
release = hslider("release", 0.01, 0, 5, 0.0001);
// how much of the second and third harmonic the voice has
second = hslider("second", 0, 0, 1, 0.001);
third = hslider("third", 0, 0, 1, 0.001);
// what the air between leaves of it: a lowpass, Hz (sound/layers/life)
cutoff = hslider("cutoff", 16000, 100, 20000, 1);

// ------------------------------------------------------------ a syllable

// samples since the syllable began (negative: it has not yet)
fired = hit != hit';
age = (\(a).(select2(fired, a + 1, 0 - delay))) ~ _;

// how far through it is, 0 to 1 (held at 1 after its end)
length = max(dur * SR, 1);
u = min(age * (1 / length), 1);

// the envelope: up over the attack, down over the release at the end (no
// release: it stays up), between them from loud to fade; a short smoother
// takes the corners off, and off whatever step is left where two
// syllables join
closing = release * SR;
edge = min(
  (age + 1) * (1 / max(attack * SR, 1)),
  1 + (length - closing - age) * ((release > 0) / max(closing, 1)),
);
level = min(max(edge, 0), 1) * (loud + (fade - loud) * u) : smooth(0.985);

// the pitch as the phase's step: from, to and the arch are a parabola
step = from / SR + u * ((to - from + 4 * arch) / SR - u * (4 * arch / SR));
s = (step : (+ : frac) ~ _) * TAU : sin;

// the harmonics come from the sine itself: cos 2x = 1 - 2 sin^2 x,
// sin 3x = 3 sin x - 4 sin^3 x
q = s * s;
voice = s * (1 + 3 * third - 4 * third * q) + second - 2 * second * q;

// (two poles: the air takes the highs faster than one does)
process = voice * level : lowpass1(cutoff) : lowpass1(cutoff);
