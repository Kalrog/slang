// sound/engine5/exhaust: sound/engine/exhaust.dsp with five cylinders, to compare: the engine's exhaust as waveguides: a header
// runner from each cylinder's valve to the collector, the turbine (which
// takes the edges off the pulses), the down pipe, the muffler (a chamber
// several times the pipe's area, its packing taking the highs), the
// tailpipe and its mouth. Pipes are pairs of delay lines, junctions
// scatter the waves, the mouth reflects the lows and radiates.
//
// Inputs, for each cylinder: what its exhaust valve sends into its runner
// and how much of an arriving wave it sends back (sound/engine/cylinders).
// Output: what the tailpipe radiates.
import "std";

CYL = 5;

rpm = hslider("rpm", 0, 0, 6000, 1) : smooth(0.998);
boost = hslider("boost", 0, 0, 1, 0.001) : smooth(0.999);
muffler = hslider("muffler", 0.55, 0, 1, 0.01);
// how much the pulses steepen when they are strong (0: not at all)
growl = hslider("growl", 0.5, 0, 1, 0.01);

HOT = 520; // m/s in the exhaust before the turbine
WARM = 450; // and after it

// a wave's way down a pipe of len meters where sound runs at c m/s: the
// longer the pipe, the more the walls take, the highs first (a sample of
// the length is the loop's own)
travel(len, c) = @(max(len * SR / c - 1, 1))
  : *(1 - 0.02 * len)
  : lowpass1(9000 / (0.5 + len));

// A pipe and what it ends in. An end takes the wave arriving and gives
// the wave it sends back and one more signal (what it radiates): ended is
// such an end again, a pipe further from it.
ended(len, c, end) = travel(len, c) : end : (travel(len, c), _);

// where a pipe of area a meets an end of area b: the pressure there is
// the same for both, each gets it less the wave it brought
step(a, b, end) = (\(y, e, x).(scatter(a, b, y, e, x))) ~ end : (!, _, _);
scatter(a, b, y, e, x) = p - y, p - x, e with {
  p = 2 * (a * x + b * y) / (a + b);
};

// the same into a volume: the pressure follows through a lowpass at fc,
// as a chamber fills and empties
chamber(a, b, fc, end) = (\(y, e, x).(filling(a, b, fc, y, e, x))) ~ end
  : (!, _, _);
filling(a, b, fc, y, e, x) = p - y, p - x, e with {
  p = 2 * (a * x + b * y) / (a + b) : lowpass1(fc);
};

// a narrow place (the turbine's wheel): part of a wave gets through,
// weaker and without its highs, the rest goes back
narrows(open, keep, fc, end) = (\(y, e, x).(pass(open, keep, fc, y, e, x))) ~
  end
  : (!, _, _);
pass(open, keep, fc, y, e, x) = (x : lowpass1(fc)) * open * keep +
  y * (1 - open),
  (y : lowpass1(fc)) * open * keep + x * (1 - open),
  e;

// an open end: the lows come back inverted, the highs leave; what it
// radiates is the flow out of it changing
mouth(fc, r, x) = back, (x - back : \(u).(u - u')) with {
  back = -r * (x : lowpass1(fc));
};

// n pipes meeting (the last of area wide, the others 1): from the waves
// arriving, the waves leaving
star(n, wide) = bus(n)
  <: (par(i, n, *(area(i))) :> *(2 / (n - 1 + wide)) <: bus(n)),
    par(i, n, *(-1))
  :> bus(n) with {
  area(i) = select2(i < n - 1, wide, 1);
};

// from the collector on: the turbine, the down pipe, the muffler, the
// tailpipe
out = narrows(0.62, 0.85, 1800, ended(1.3, WARM, chamber(
  1,
  2 + muffler * 7,
  150 + (1 - muffler) * (1 - muffler) * 2500,
  ended(0.5, WARM, step(2.2, 1, ended(1.1, WARM - 40, mouth(2800, 0.97)))),
)));

// a header runner, from the collector to its cylinder's valve and back:
// the wave, what the valve sends in, how much it sends back
header(k) = (travel(0.38 + 0.04 * k, HOT), _, _)
  : \(a, drive, back).(drive + a * back)
  : travel(0.38 + 0.04 * k, HOT);

// the runners and the way out, joined at the collector. Its inputs: the
// waves leaving the collector (the loop's), then each cylinder's two
ways = bus(CYL * 3 + 1)
  <: par(
    k,
    CYL,
    (
      only(CYL * 3 + 1, k),
        only(CYL * 3 + 1, CYL + 1 + 2 * k),
        only(CYL * 3 + 1, CYL + 2 + 2 * k)
    )
      : header(k + 1)
  ),
    (only(CYL * 3 + 1, CYL) : out);

pipes = (ways : (star(CYL + 1, 2.2), _)) ~ bus(CYL + 1)
  : (par(i, CYL + 1, !), _);

// the gas leaving the tailpipe hisses, the more of it the louder
spool = min(max((rpm - 900) / 1300, 0), 1);
flow = min(rpm / 4000, 1.2) * (1 + 1.2 * boost * spool) / 2.2;
jet = noises(3) * flow * flow * flow : bandpass2(1300, 0.6) : lowpass1(3000);

// Strong waves in a pipe steepen as they travel (their crests run faster
// than their troughs), which a delay line does not do: the pulses are
// bent here instead, the more the stronger they are, the crests more
// than the troughs. It is what makes an engine under load growl: the
// firing frequency's harmonics between 200 and 600 Hz.
steepened(x) = x + growl * (bent - x) with {
  y = x * 9;
  bent = (tanh(y + 0.35 * y * abs(y)) - 0.1 * y * y / (1 + y * y)) / 9 * 1.25;
};

// (leveled: at idle the pulses are a thirtieth of what they are flat out)
process = pipes + jet * 0.005
  : dcblock
  : leveled(0.002, 0.3, 60)
  : *(40)
  : steepened
  : dcblock;
