// sound/body/struck: a thing that is struck: a blow, and what it leaves
// ringing. Six modes, each a frequency, the time it rings and its share,
// and beside them the blow's own noise (the grit between two surfaces,
// or air let out of a valve): a band of noise that comes up and dies
// away. What is struck (a panel, a jerry can, a gear lever's gate) is in
// the numbers, which whoever plays it sets with every blow (see
// sound/layers/body.slang and driveline.slang: one program, many things).
//
// A blow is the counter `hit` going up; `power` is how hard, `hard` how
// high the blow reaches (a soft thing on a soft thing: a hundred Hz or
// two; steel on steel: thousands).
import "std";

hit = hslider("hit", 0, 0, 1000000000, 1);
power = hslider("power", 0, 0, 8, 0.0001);
hard = hslider("hard", 2000, 20, 16000, 1);

// the modes: Hz, seconds (to a thousandth of where it began), share
f1 = hslider("f1", 200, 20, 16000, 0.1);
f2 = hslider("f2", 400, 20, 16000, 0.1);
f3 = hslider("f3", 800, 20, 16000, 0.1);
f4 = hslider("f4", 1600, 20, 16000, 0.1);
f5 = hslider("f5", 2400, 20, 16000, 0.1);
f6 = hslider("f6", 3200, 20, 16000, 0.1);
t1 = hslider("t1", 0.1, 0.001, 4, 0.001);
t2 = hslider("t2", 0.1, 0.001, 4, 0.001);
t3 = hslider("t3", 0.1, 0.001, 4, 0.001);
t4 = hslider("t4", 0.1, 0.001, 4, 0.001);
t5 = hslider("t5", 0.1, 0.001, 4, 0.001);
t6 = hslider("t6", 0.1, 0.001, 4, 0.001);
g1 = hslider("g1", 0, -4, 4, 0.0001);
g2 = hslider("g2", 0, -4, 4, 0.0001);
g3 = hslider("g3", 0, -4, 4, 0.0001);
g4 = hslider("g4", 0, -4, 4, 0.0001);
g5 = hslider("g5", 0, -4, 4, 0.0001);
g6 = hslider("g6", 0, -4, 4, 0.0001);

// the blow's noise: its share, how fast it comes up and how long it
// takes to die away (s), and its band (Hz, and how narrow)
rough = hslider("rough", 0, 0, 8, 0.0001);
rise = hslider("rise", 0.0005, 0.0001, 0.5, 0.0001);
fall = hslider("fall", 0.02, 0.001, 4, 0.001);
band = hslider("band", 2000, 40, 16000, 1);
width = hslider("width", 1, 0.3, 30, 0.01);

// white noise (std's generator, with a fraction in place of its modulo)
hiss(k) = (*(69069) : +((2 * k + 1) / 4294967296) : frac) ~ _ : *(2) : -(1);

// 1 for the block's first sample when a blow came
fired = hit != hit';

// the blow: a pulse as short as it is hard
blow = fired * power : lowpass1(hard) : lowpass1(hard);

// a mode: a two-pole resonator, which a pulse leaves ringing at f for t
// seconds
mode(f, t, g) = *(g * sin(w))
  : (+ ~ (_ <: *(2 * r * cos(w)), (mem : *(0 - r * r)) :> _)) with {
  w = TAU * min(f, 0.45 * SR) / SR;
  r = exp(-6.91 / (t * SR));
};

// the noise: up at once with the blow, down over `fall`, its start
// rounded over `rise`
swell = fired
  : (\(prev, t).(max(t, prev * exp(-6.91 / (fall * SR))))) ~ _
  : lowpass1(1 / (TAU * rise));
grit = hiss(3) * swell * latch(fired, rough * power) : bandpass2(band, width);

// (a blow leaves nothing standing: what is lowest of all is taken out)
process = (
  blow
    <: mode(f1, t1, g1),
      mode(f2, t2, g2),
      mode(f3, t3, g3),
      mode(f4, t4, g4),
      mode(f5, t5, g5),
      mode(f6, t6, g6)
    :> _
) +
  grit
  : dcblock;
