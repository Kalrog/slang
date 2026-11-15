// sound/interface/pluck: a plucked string, one note at a time: the first
// of the two instruments of the interface's jingles (sound/jingles, played
// by sound/layers/interface). It is Karplus and Strong's string: a delay
// line one period long whose end goes back into its start, losing a
// little on every round, the highs first, as a string's do.
//
// The loop is the delay line, a sample for the feedback, a sample for the
// filter that takes the highs (three taps, the same delay at every
// frequency) and an allpass for the part of the period that is not whole
// samples: without it a note would be up to a sixth of a tone off. Who
// plays the note works these out from its frequency (see the layer):
//
//   period = SR / f
//   delay  = floor(period - 2.2)
//   rest   = period - 2 - delay                 (0.2 to 1.2 samples)
//   tune   = sin((1 - rest) w / 2) / sin((1 + rest) w / 2),  w = TAU f / SR
//   loss   = 0.001 ^ (1 / (seconds * f))        (60 dB down in seconds)
//
// Input: the other strings that sound (each adds itself to the row: the
// layer runs them one after the other on one array). Output: the row with
// this string.
import "std";

// a note: the count of notes so far (a change plucks the string), and
// how hard
hit = hslider("hit", 0, 0, 1000000000, 1);
level = hslider("level", 0.5, 0, 4, 0.0001);
// the string's length: whole samples, and the allpass's coefficient
delay = hslider("delay", 100, 2, 1020, 1);
tune = hslider("tune", 0, -0.99, 0.99, 0.00001);
// what a round takes: of the highs (0: nothing, 0.25: the most), and of
// everything (a note is stopped by taking more)
damp = hslider("damp", 0.12, 0, 0.25, 0.0001);
loss = hslider("loss", 0.995, 0, 1, 0.000001);
// the finger: how round its pull is (Hz: the higher the brighter), and
// how far from the string's end it pulls (samples)
pick = hslider("pick", 600, 30, 12000, 1);
place = hslider("place", 20, 1, 500, 1);

// the pluck: a bump as high as the note is hard, and the same bump
// upside down a little later (the string let go some way from its end:
// it pulls no weight, and what goes round is the wave of a plucked
// string, without the harmonics that have a node under the finger)
fired = hit != hit';
round = exp(-TAU * pick / SR);
bump = fired * level * (2.718281828 / (1 - round))
  : smooth(round)
  : smooth(round);
pluck = bump <: _, @(place) : -;

// the highs' loss: a weighted mean of three samples
soften(a) = _ <: *(a), (mem : *(1 - 2 * a)), (mem : mem : *(a)) :> _;
// the rest of the period: an allpass of the first order
fraction(k) = tf2(k, 1, 0, k, 0);

string = (+ : @(delay)) ~ (soften(damp) : fraction(tune) : *(loss));

process = _ + (pluck : string);
