// sound/driveline/gears: the gears of the truck's driveline singing: the
// pair of the gearbox that is engaged (or the reverse gear and its
// idler), the transfer case's reduction gears in low range, and the ring
// and pinion of the axles.
//
// Two gears mesh once for every tooth that passes: a gear with z teeth
// on a shaft that turns f times a second makes a tone at z f, with
// overtones, the louder the more torque goes through it. No shaft runs
// quite true, so the tone wobbles once a turn of each shaft of the pair
// (sidebands beside it), and the engine's firing shakes it. The casing
// the gears sit in has resonances of its own: the tone grows and fades
// as it passes them, which is why it sounds like a gearbox and not like
// an oscillator.
//
// Output: all of it as one, heard from under the truck's middle (the
// axles' hum is too low to tell where it comes from).
import "std";

// ------------------------------------------------------------ controls

// (None of them is smoothed here: the mixer glides them block by block,
// which a phase does not hear; what scales a tone is smoothed below.)

// the gearbox's output shaft and the propeller shafts, turns a second
shaft = hslider("shaft", 0, 0, 200, 0.01);
prop = hslider("prop", 0, 0, 200, 0.01);
// the pair that is engaged: the teeth of its gear on the output shaft
// (0: none), and the turns of the input shaft for one of the output shaft
teeth = hslider("teeth", 0, 0, 80, 1);
ratio = hslider("ratio", 1, 0, 6, 0.001);
// the torque through the gearbox over the engine's most (negative: the
// wheels turn the engine), and the same at the axles (over what second
// gear puts on them)
torque = hslider("torque", 0, -2, 2, 0.001);
pull = hslider("pull", 0, -2, 2, 0.001);
// the gearbox in reverse, the transfer case in low range (0 or 1)
reverse = hslider("reverse", 0, 0, 1, 1);
low = hslider("low", 0, 0, 1, 1);

// ------------------------------------------------------------ the parts

// about a sine of a turn t (0 to 1), without one (a parabola each half)
wave(t) = -4 * u * (1 - abs(u)) with {
  u = 2 * t - 1;
};

// the tone of a mesh at the angle x (in turns of the tone) and its two
// overtones, from one cosine: a1 cos + a2 cos 2 + a3 cos 3
tone(x, a1, a2, a3) = c * (a1 - 3 * a3 + 4 * a3 * cc) + 2 * a2 * cc - a2 with {
  c = cos(TAU * x);
  cc = c * c;
};

// white noise (std's generator, with a fraction in place of its modulo)
hiss(k) = (*(69069) : +((2 * k + 1) / 4294967296) : frac) ~ _ : *(2) : -(1);

// a resonance of a casing: a two-pole filter at f Hz, as wide as f / q,
// g at its top
ring(f, q, g) = *(g * (1 - r) * 2 * sin(w))
  : (+ ~ (_ <: *(2 * r * cos(w)), (mem : *(0 - r * r)) :> _)) with {
  w = TAU * f / SR;
  r = exp(-PI * f / (q * SR));
};

// a level on its way to where the controls put it
glide = smooth(0.998);

// the shafts' angles, 0 to 1 a turn: the gearbox's output and input, the
// propeller shafts; and their wobble
turn_out = phasor(shaft);
turn_in = phasor(shaft * ratio);
turn_prop = phasor(prop);
wob_out = wave(turn_out);
wob_in = wave(turn_in);
wob_prop = wave(turn_prop);

// no speed is held exactly: the tones waver a little (in turns)
grain = hiss(11);
waver = grain : lowpass1(2.5) : *(1.2);

// the driving flanks of the teeth and the coasting ones, 0 to about 1.5
drive = max(torque, 0);
coast = max(-torque, 0);

// ------------------------------------------------------------ the gearbox

// in reverse; and how fast the teeth meet (a pair that stands is silent)
back = reverse * (0.5 + abs(torque));
swift = min(teeth * shaft / 420, 1);

// The engaged pair. Under load its first tone leads; on the overrun the
// teeth lie on their other flanks, which are not cut for it: quieter,
// its overtones up, and it rattles with the engine's firing (twice a
// turn of the input shaft). In reverse the gears are cut straight and an
// idler sits between them: every overtone is there, it wobbles more, and
// it is loud.
box = tone(
  teeth * turn_out + (0.055 + 0.07 * reverse) * wob_out + 0.04 * wob_in + waver,
  (0.1 + 0.9 * drive + 0.35 * coast + 3.6 * back) * swift : glide,
  (0.34 * drive + 0.5 * coast + 2.6 * back) * swift : glide,
  (0.12 * drive + 0.2 * coast + 1.8 * back) * swift : glide,
) *
  (
    1 + 0.22 * wob_out +
      (0.1 + 0.3 * coast + 0.3 * reverse) * (1 - 2 * wob_in * wob_in)
  );

// ------------------------------------------------------------ the transfer case

// In low range the drive goes through two more pairs: from the gearbox's
// output shaft (a gear of 22 teeth) to a cluster, and from the cluster
// to the propeller shafts (a gear of 35 teeth on them), 2.72 turns in
// for one out. They are cut for strength, not for silence. In high range
// the drive goes straight through.
load = low * (0.14 + 0.86 * (drive + 0.5 * coast));
reduction = (
  tone(22 * turn_out + 0.05 * wob_out + waver, 1, 0.4, 0) *
    (load * min(22 * shaft / 420, 1) : glide) +
    tone(35 * turn_prop + 0.06 * wob_prop - waver, 0.8, 0.3, 0) *
      (load * min(35 * prop / 420, 1) : glide)
) *
  (1 + 0.2 * wob_prop);

// the teeth are not smooth: a hiss with the tones, which the casing colors
teeth_hiss = grain *
  ((0.02 + 0.1 * abs(torque) + 0.3 * back + 0.15 * load) * swift : glide);

// the casing of the two (bolted together, they ring as one), which gives
// off what moves it the better the higher it is
casing = _
  <: *(0.22), ring(480, 3, 1), ring(1100, 4, 0.85), ring(2400, 5, 0.45)
  :> _
  <: _ - 0.85 * mem : *(3);

// ------------------------------------------------------------ the axles

// In each axle a pinion of 10 teeth on the propeller shaft turns a ring
// gear of 41: under load they hum, ten times a turn of the propeller
// shaft. At the truck's speeds that is only some fifty to two hundred
// times a second, so most of what is heard of it is its overtones; the
// housings are thick and full of oil, so it is never loud.
hum = (h * (0.6 * hh - 0.05) + 1.8 * hh - 0.9) *
  (min(abs(pull), 1) * min(prop / 6.5, 1) : glide) *
  (1 + 0.3 * wob_prop) with {
  h = cos(TAU * (10 * turn_prop + 0.06 * wob_prop + waver));
  hh = h * h;
};

// (Each part is used twice here, x + x, so that the kernel has it as a
// value of its own: as one expression the whole sum is too long for the
// kernel VM's registers, and the program would run a fifth slower.)
whole(x) = x + x;

process = whole(box) * 0.5 + whole(reduction) * 0.95 + teeth_hiss +
  whole(hum) * 0.5
  : casing;
