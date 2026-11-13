// The instruments of the player (main.slang), each a program in a `dsp`
// block: a mono voice with the controls "freq" (Hz) and "gate" (1 while a
// key is held), which the player sets, and sliders of its own.
//
//   local instruments = require("instruments")
//   local synth = instruments.list[1]          // a dsp program
//   print(synth.source)                        // its kernel
//
// Every block is compiled with this file: running it compiles nothing.

// drawbars: four sines at 1, 2, 3 and 4 times the pitch, a slow tremolo
dsp organ {
  import "std";

  freq = hslider("freq", 220, 20, 4000, 0.01);
  gate = button("gate");
  bars = hslider("8'", 0.8, 0, 1, 0.01),
    hslider("4'", 0.5, 0, 1, 0.01),
    hslider("2 2/3'", 0.3, 0, 1, 0.01),
    hslider("2'", 0.2, 0, 1, 0.01);
  tremolo = 1 + 0.15 * osc(hslider("tremolo", 5.5, 0, 9, 0.1));

  process = sum(i, 4, osc(freq * (i + 1)) * take(i + 1, bars))
    : *(tremolo)
    : *(adsr(0.004, 0.05, 1, 0.06, gate))
    : *(0.25);
}

// a subtractive synth: a saw (polyBLEP) and a square an octave down
// through a resonant lowpass the envelope opens
dsp synth {
  import "std";

  freq = hslider("freq", 110, 20, 4000, 0.01);
  gate = button("gate");
  cutoff = hslider("cutoff", 900, 50, 8000, 1) : smoo;
  resonance = hslider("resonance", 3, 0.7, 12, 0.1);
  amount = hslider("env amount", 2500, 0, 8000, 1);
  sub = hslider("sub", 0.4, 0, 1, 0.01);
  env = adsr(0.005, 0.25, 0.3, 0.2, gate);

  process = saw(freq) + square(freq / 2) * sub
    : lowpass2(min(cutoff + env * amount, 18000), resonance)
    : *(adsr(0.005, 0.3, 0.7, 0.25, gate))
    : drive(1.5)
    : *(0.3);
}

// a plucked string (Karplus-Strong): a burst of noise circulating in a
// delay line one period long, averaged a little on every pass
dsp pluck {
  import "std";

  freq = hslider("freq", 220, 40, 2000, 0.01);
  gate = button("gate");
  damping = hslider("damping", 0.3, 0, 1, 0.01);
  brightness = hslider("brightness", 0.8, 0, 1, 0.01);
  period = SR / freq;
  excite = noise * impulse(period, gate) : lowpass1(200 + brightness * 12000);
  string = \(x).((x + x') * (0.5 - damping * 0.004));

  process = excite : + ~ (@(period - 1) : string) : *(0.6);
}

// a two-operator FM bell: a sine whose phase another sine moves, the
// modulation decaying faster than the tone
dsp bell {
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
}

// wind: noise through a resonant bandpass at the note
dsp wind {
  import "std";

  freq = hslider("freq", 440, 20, 4000, 0.01);
  gate = button("gate");
  q = hslider("q", 25, 1, 80, 0.1);
  breath = hslider("breath", 0.3, 0, 1, 0.01);

  process = noise
    : bandpass2(freq, q) + noise * breath * 0.05
    : *(adsr(0.12, 0.2, 0.8, 0.4, gate))
    : *(8);
}

// the effects after the instrument: an echo (mono)
dsp echo {
  import "std";

  time = hslider("echo time", 0.32, 0.02, 1.5, 0.01);
  feedback = hslider("echo feedback", 0.35, 0, 0.95, 0.01);
  level = hslider("echo level", 0.3, 0, 1, 0.01);

  process = _ <: _, (echo(time, feedback) : *(level)) :> _;
}

return {
  list: {organ, synth, pluck, bell, wind},
  names: {"organ", "synth", "pluck", "bell", "wind"},
  echo: echo,
  // the stereo reverb is a .dsp file of its own
  reverb: require("programs/stereo_reverb"),
}
