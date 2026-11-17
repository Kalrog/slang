// A plucked string (Karplus-Strong): a burst of noise circulating in a
// delay line one period long, averaged a little on every pass. The voice
// of the pluck unit.
import "std";

freq = hslider("freq", 220, 40, 2000, 0.01);
gate = button("gate");
damping = hslider("damping", 0.3, 0, 1, 0.01);
brightness = hslider("brightness", 0.8, 0, 1, 0.01);
period = SR / freq;
excite = noise * impulse(period, gate) : lowpass1(200 + brightness * 12000);
string = \(x).((x + x') * (0.5 - damping * 0.004));

process = excite : + ~ (@(period - 1) : string) : *(0.6);
