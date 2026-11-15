// sound/interface/stage: where the jingles are played: the string a
// little to the left, the bell a little to the right, out of doors: no
// room rings after them. All the valley gives back is one faint echo
// from its far side, late, dull and quiet (and nothing at all with
// `echo` at 0).
//
// Inputs: the strings (sound/interface/pluck) and the bells
// (sound/interface/bell), each kind summed. Outputs: left, right.
import "std";

// the echo: how late it comes, in samples, and how loud beside what was
// played
late = hslider("late", 21600, 480, 30000, 1);
echo = hslider("echo", 0.06, 0, 1, 0.001);

// where the two sit: 0 left, 1 right (in the middle each ear gets what
// is played as it is)
seat(p) = _ <: *(sqrt(2 * (1 - p))), *(sqrt(2 * p));

// what comes back: once, without its highs
far = @(late) : lowpass1(1500) : lowpass1(1500) : *(echo);

process(strings, bells) = (strings : seat(0.4)),
  (bells : seat(0.62)),
  (strings + bells : far)
  // (the echo a little more from the right)
  : \(sl, sr, bl, br, back).(sl + bl + back * 0.85, sr + br + back * 1.15);
