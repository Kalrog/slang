// sound/interface/bell: a bar struck by a soft mallet, one note at a
// time: the second instrument of the interface's jingles (sound/jingles,
// played by sound/layers/interface). A bar rings in a few modes, each a
// sine that dies at its own pace: the note itself, long; a partial two
// octaves up that is gone in a third of the time; and a high one that is
// only the mallet's touch. The modes of a tuned bar (a vibraphone's)
// stand at 1, 4 and about 10 times its note, so the bell is in tune with
// the string whatever it plays.
//
// A mode is a resonator of two poles: struck by one sample it answers
// with a sine of that height, 60 dB down after its time. The mallet is
// that sample made round (the softer the mallet, the less of the high
// modes).
//
// Input: the other bars that sound (each adds itself to the row).
// Output: the row with this bar.
import "std";

// a note: the count of notes so far (a change strikes), and how hard
hit = hslider("hit", 0, 0, 1000000000, 1);
level = hslider("level", 0.5, 0, 4, 0.0001);
// its frequency, Hz, and how long it rings, s (to 60 dB down)
freq = hslider("freq", 880, 40, 8000, 0.001);
ring = hslider("ring", 1.5, 0.02, 10, 0.001);
// the mallet's softness: the frequency above which it excites less, Hz
mallet = hslider("mallet", 2500, 100, 16000, 1);

fired = hit != hit';
strike = fired * level : lowpass1(mallet);

// a mode at f Hz that rings for t seconds
mode(f, t) = tf2(sin(w), 0, 0, -2 * r * cos(w), r * r) with {
  w = TAU * f / SR;
  r = exp(-6.908 / (t * SR));
};

// (a partial that would be above what a bar gives, or above what the
// sample rate carries, is left out, going quietly from 3 kHz under that)
top = min(11000, 0.45 * SR);
heard(f) = max(0, min(1, (top - f) / 3000));
partial(ratio, gain, share) = mode(min(freq * ratio, top), ring * share) *
  gain *
  heard(freq * ratio);

bar = strike
  <: partial(1, 1, 1), partial(4, 0.22, 0.3), partial(10, 0.07, 0.08)
  :> _;

process = _ + bar;
