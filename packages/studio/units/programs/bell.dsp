// A two-operator FM bell: a sine whose phase another sine moves, the
// modulation decaying faster than the tone. The voice of the bell unit.
import "std";

freq = hslider("freq", 440, 20, 4000, 0.01);
gate = button("gate");
ratio = hslider("ratio", 3.5, 0.5, 8, 0.01);
index = hslider("index", 2.5, 0, 8, 0.01);
decay = hslider("decay", 1.5, 0.1, 6, 0.01);
modulator = osc(freq * ratio) * index * adsr(0.001, decay * 0.3, 0, 0.5, gate);

process = phasor(freq) + modulator / TAU
  : *(TAU)
  : sin
  : *(adsr(0.001, decay, 0, decay, gate))
  : *(0.3);
