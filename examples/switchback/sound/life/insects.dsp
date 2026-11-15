// sound/life/insects: a meadow's insects on a warm day, as a quiet bed:
// three field crickets and two grasshoppers. A cricket chirps three or
// four times a second, each chirp three or four short pulses of one
// clear tone between four and five kilohertz, each pulse louder than the
// last; no two crickets have the same tone or the same pace, so their
// chirps drift through one another and never repeat. A grasshopper
// rasps: dry strokes of noise between six and ten kilohertz, some ten a
// second, in verses.
//
// Who sings when is not decided here: sound/layers/life.slang turns each
// cricket up and down (they sing for a while and pause), lets its pace
// wander a little, and shapes each grasshopper's verse, a block at a
// time.
//
// Outputs: three places around the listener, a cricket in each, a
// grasshopper in two of them (a cricket's pulse peaks at 1).
import "std";

// each cricket's loudness now, 0 to 1, and its chirps a second
one = hslider("one", 0, 0, 1, 0.001);
two = hslider("two", 0, 0, 1, 0.001);
three = hslider("three", 0, 0, 1, 0.001);
pace_one = hslider("pace_one", 3.137, 1, 6, 0.001);
pace_two = hslider("pace_two", 3.461, 1, 6, 0.001);
pace_three = hslider("pace_three", 2.823, 1, 6, 0.001);
// each grasshopper's, through its verse
rasp_one = hslider("rasp_one", 0, 0, 1, 0.001);
rasp_two = hslider("rasp_two", 0, 0, 1, 0.001);

// a cricket: its tone in Hz, its chirps a second, the pulses of a chirp
// and how many of them a second
cricket(tone, pace, count, beat) = osc(tone) * b * b * (x < count) *
  min(7.2 + 4.8 * x, 16) with {
  // the pulses since the chirp began, and how far through this one
  x = phasor(pace) * (beat / pace);
  y = min(frac(x) * (1 / 0.62), 1);
  // a pulse swells and dies: a smooth bump (b * b * 16 is 1 at its top)
  b = y - y * y;
};

// the grasshoppers' rasp: noise kept to their band, and a stroke that
// starts fast and dies slower, `pace` times a second
rasp = noises(41) : highpass2(6000, 1.1) : lowpass2(10000, 1.1);
stroke(pace) = y * (1 - y) * (1 - y) * 6.75 with {
  y = min(phasor(pace) * (1 / 0.7), 1);
};

process = cricket(4490, pace_one, 3, 27.5) * one + rasp * stroke(8.3) * rasp_one,
  cricket(4770, pace_two, 4, 29.3) * two + rasp * stroke(16.9) * rasp_two,
  cricket(4960, pace_three, 3, 26.1) * three;
