// sound/body/brush: a bush taking the truck's side: leaves and thin
// twigs swept along the panels. Leaves are heard one by one when there
// are few and as a rush when there are many, so the noise comes in
// grains, more of them and brighter the faster the truck goes; a twig
// dragged along sheet metal sticks and slips, a dry scraping that the
// panel under it colors. (A twig that snaps is a blow: sound/body/
// struck.dsp, played by sound/layers/body.slang.)
import "std";

// how much of the truck is in leaves (0 to 1), how fast it goes through
// them (0 to 1: about 8 m/s and more), and how much wood there is to
// scrape (0 to 1)
leaves = hslider("leaves", 0, 0, 1, 0.001);
speed = hslider("speed", 0, 0, 1, 0.001);
twigs = hslider("twigs", 0, 0, 1, 0.001);

// white noise (std's generator, with a fraction in place of its modulo)
hiss(k) = (*(69069) : +((2 * k + 1) / 4294967296) : frac) ~ _ : *(2) : -(1);

// a resonance: a two-pole filter at f Hz, as wide as f / q, g at its top
ring(f, q, g) = *(g * (1 - r) * 2 * sin(w))
  : (+ ~ (_ <: *(2 * r * cos(w)), (mem : *(0 - r * r)) :> _)) with {
  w = TAU * f / SR;
  r = exp(-PI * f / (q * SR));
};

glide = smooth(0.998);

// the leaves: each one that is struck a grain (some hundreds a second at
// a crawl, thousands at speed), over a rush that is always there
struck = (abs(hiss(61)) < 0.004 + 0.03 * speed) : lowpass1(180) : *(22);
rush = hiss(62) * (0.3 + struck) * (leaves * (0.35 + 0.65 * speed) : glide)
  : bandpass2(1700 + 2600 * speed, 0.55);

// the twigs: sticking and slipping some hundreds of times a second,
// never evenly, and in fits (a twig lets go, the next one catches)
fits = hiss(63) : lowpass1(5) : *(45) : max(0) : min(1);
grip = hiss(64) : lowpass1(30) : *(8);
drag = phasor((140 + 420 * speed) * max(1 + 0.5 * grip, 0.2)) - 0.5;
scrape = drag * fits * (twigs * speed : glide)
  <: ring(1350, 3, 1), ring(2500, 3.5, 0.7)
  :> _
  <: _ - mem;

process = rush + scrape * 24;
