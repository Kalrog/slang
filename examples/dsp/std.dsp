// std: the library of dsp programs (`import "std";`), written in the
// language itself. Oscillators take a frequency in Hz, filters a cutoff
// in Hz, envelopes times in seconds; SR is the sample rate.

PI = 3.141592653589793;
TAU = 2 * PI;

// ---------------------------------------------------------------- basics

// the fractional part: x - floor(x)
frac = _ <: _ - floor;

// n wires in parallel
bus(n) = par(i, n, _);

// the decibels x as a gain, and back
db2lin(x) = pow(10, x / 20);
lin2db(x) = 20 * log10(x);

// a MIDI note number as Hz
mtof(n) = 440 * pow(2, (n - 69) / 12);

// a one-pole smoother: c near 1 is slow (for sliders: smooth(0.999))
smooth(c) = *(1 - c) : + ~ *(c);
smoo = smooth(0.999);

// soft clipping
drive(k) = *(k) : tanh;

// equal-power panning, p from 0 (left) to 1 (right)
pan(p) = _ <: *(sqrt(1 - p)), *(sqrt(p));

// -------------------------------------------------------------- sources

// a ramp from 0 to 1, f times a second
phasor(f) = f / SR : (+ : frac) ~ _;

// a sine
osc(f) = phasor(f) : *(TAU) : sin;

// a sawtooth with its corners rounded (polyBLEP), so it does not alias
saw(f) = phasor(f) : \(t).(2 * t - 1 - blep(t, f / SR));

// a square, made of two saws half a period apart
square(f) = saw(f) -
  (phasor(f) : \(t).(2 * frac(t + 0.5) - 1 - blep(frac(t + 0.5), f / SR)));

// the correction of a step at the phase wrap of t (dt: the phase increment)
blep(t, dt) = select2(t < dt, select2(t > 1 - dt, 0, hi), lo) with {
  lo = 2 * (t / dt) - (t / dt) * (t / dt) - 1;
  hi = ((t - 1) / dt) * ((t - 1) / dt) + 2 * ((t - 1) / dt) + 1;
};

// white noise from -1 to 1: a linear congruential generator, modulo 2^32
// (its products stay below 2^53, so they are exact in doubles)
noise = noises(0);

// independent white noises, one for each k = 0, 1, 2...: the generator
// with another increment (every odd one runs through all 2^32 states)
noises(k) = (*(69069) : +(2 * k + 1) : %(4294967296)) ~ _
  : /(2147483648)
  : -(1);

// holds x from the moment t rises (above 0) until it rises again
latch(t, x) = (\(prev).(select2(t > 0, prev, x)) ~ _);

// ------------------------------------------------------------- filters

// a one-pole lowpass at fc Hz
lowpass1(fc) = smooth(exp(-TAU * fc / SR));

// a biquad: b0 + b1 z^-1 + b2 z^-2 over 1 + a1 z^-1 + a2 z^-2
tf2(b0, b1, b2, a1, a2) = sub ~ conv2(a1, a2) : conv3(b0, b1, b2) with {
  sub(x, y) = y - x;
  conv2(c0, c1) = _ <: *(c0), (mem : *(c1)) :> _;
  conv3(c0, c1, c2) = _ <: *(c0), (mem : *(c1)), (mem : mem : *(c2)) :> _;
};

// resonant filters of the RBJ cookbook: cutoff fc Hz, resonance q (0.707:
// none)
lowpass2(fc, q) = tf2(b0, 2 * b0, b0, a1, a2) with {
  w = TAU * fc / SR;
  alpha = sin(w) / (2 * q);
  a0 = 1 + alpha;
  b0 = (1 - cos(w)) / 2 / a0;
  a1 = -2 * cos(w) / a0;
  a2 = (1 - alpha) / a0;
};

highpass2(fc, q) = tf2(b0, -2 * b0, b0, a1, a2) with {
  w = TAU * fc / SR;
  alpha = sin(w) / (2 * q);
  a0 = 1 + alpha;
  b0 = (1 + cos(w)) / 2 / a0;
  a1 = -2 * cos(w) / a0;
  a2 = (1 - alpha) / a0;
};

bandpass2(fc, q) = tf2(alpha / a0, 0, -alpha / a0, a1, a2) with {
  w = TAU * fc / SR;
  alpha = sin(w) / (2 * q);
  a0 = 1 + alpha;
  a1 = -2 * cos(w) / a0;
  a2 = (1 - alpha) / a0;
};

// a DC blocker
dcblock = _ <: _ - mem : + ~ *(0.995);

// ----------------------------------------------------------- envelopes

// attack (linear), decay and release (exponential) in seconds, sustain
// as a level; gate above 0 holds the note
adsr(a, d, s, r, gate) = gate : (step ~ (_, _)) : (_, !) with {
  step(env, att, g) = next, natt with {
    on = g > 0;
    rise = on * (1 - (g' > 0));
    natt = on * max(rise, att * (env < 1));
    up = min(env + 1 / max(a * SR, 1), 1);
    down = s + (env - s) * exp(-4.6 / max(d * SR, 1));
    next = select2(
      on,
      env * exp(-4.6 / max(r * SR, 1)),
      select2(natt, down, up),
    );
  };
};

// a short pulse: 1 for the first n samples after gate rises
impulse(n, gate) = gate
  : (\(count, g).(select2(g > 0, 0, count + 1)) ~ _)
  : <=(n)
  : *(gate > 0);

// --------------------------------------------------------------- effects

// an echo of t seconds (at most 2), fed back by fb
echo(t, fb) = + ~ (@(min(t, 2) * SR) : *(fb));

// Freeverb's comb and allpass filters, n samples long
comb(n, fb, damp) = (+ : @(n - 1)) ~ (*(1 - damp) : (+ ~ *(damp)) : *(fb));
allpass(n, g) = _ <: ((+ : @(n - 1)) ~ *(g) : mem), *(-1) :> _;

// a mono reverb after Freeverb: room from 0 to 1, damp from 0 to 1
reverb(room, damp) = *(0.015)
  <: par(i, 8, comb(take(i + 1, combs), fb, damp * 0.4))
  :> seq(i, 4, allpass(take(i + 1, allpasses), 0.5)) with {
  fb = room * 0.28 + 0.7;
  combs = (1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617);
  allpasses = (556, 441, 341, 225);
};
