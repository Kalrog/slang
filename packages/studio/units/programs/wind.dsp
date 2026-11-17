// Wind: noise through a resonant bandpass at the note. The voice of the
// wind unit.
import "std";

freq = hslider("freq", 440, 20, 4000, 0.01);
gate = button("gate");
q = hslider("q", 25, 1, 80, 0.1);
breath = hslider("breath", 0.3, 0, 1, 0.01);

process = noise
  : bandpass2(freq, q) + noise * breath * 0.05
  : *(adsr(0.12, 0.2, 0.8, 0.4, gate))
  : *(8);
