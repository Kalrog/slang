// A drawbar organ: four sines at 1, 2, 3 and 4 times the pitch, a slow
// tremolo. The voice of the organ unit.
import "std";

freq = hslider("freq", 220, 20, 4000, 0.01);
gate = button("gate");
bars = hslider("bar 8", 0.8, 0, 1, 0.01),
  hslider("bar 4", 0.5, 0, 1, 0.01),
  hslider("bar 2 2/3", 0.3, 0, 1, 0.01),
  hslider("bar 2", 0.2, 0, 1, 0.01);
tremolo = 1 +
  hslider("tremolo depth", 0.15, 0, 0.5, 0.01) *
    osc(hslider("tremolo", 5.5, 0, 9, 0.1));

process = sum(i, 4, osc(freq * (i + 1)) * take(i + 1, bars))
  : *(tremolo)
  : *(adsr(0.004, 0.05, 1, 0.06, gate))
  : *(0.25);
