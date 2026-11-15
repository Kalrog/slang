// sound/engine/intake: the engine's intake as waveguides: a runner from
// each cylinder's valve to the manifold, the charge pipe and the
// intercooler, the compressor, the airbox (a volume behind its filter),
// the last pipe (short behind the grille, long up a snorkel) and its
// mouth. Built as sound/engine/exhaust is.
//
// Inputs, for each cylinder: what its intake valve sends into its runner
// and how much of an arriving wave it sends back (sound/engine/cylinders).
// Output: what the intake's mouth radiates.
import "std";

CYL = 4;

// the intake's last pipe, m
snorkel = hslider("snorkel", 0.4, 0.2, 1.8, 0.01);

COLD = 345; // m/s in the intake

travel(len, c) = @(max(len * SR / c - 1, 1))
  : *(1 - 0.02 * len)
  : lowpass1(9000 / (0.5 + len));

ended(len, c, end) = travel(len, c) : end : (travel(len, c), _);

chamber(a, b, fc, end) = (\(y, e, x).(filling(a, b, fc, y, e, x))) ~ end
  : (!, _, _);
filling(a, b, fc, y, e, x) = p - y, p - x, e with {
  p = 2 * (a * x + b * y) / (a + b) : lowpass1(fc);
};

narrows(open, keep, fc, end) = (\(y, e, x).(pass(open, keep, fc, y, e, x))) ~
  end
  : (!, _, _);
pass(open, keep, fc, y, e, x) = (x : lowpass1(fc)) * open * keep +
  y * (1 - open),
  (y : lowpass1(fc)) * open * keep + x * (1 - open),
  e;

mouth(fc, r, x) = back, (x - back : \(u).(u - u')) with {
  back = -r * (x : lowpass1(fc));
};

star(n, wide) = bus(n)
  <: (par(i, n, *(area(i))) :> *(2 / (n - 1 + wide)) <: bus(n)),
    par(i, n, *(-1))
  :> bus(n) with {
  area(i) = select2(i < n - 1, wide, 1);
};

// from the manifold on
in = ended(0.7, COLD, narrows(0.7, 0.9, 2500, ended(
  0.4, COLD, chamber(1, 5, 700, ended(snorkel, COLD, mouth(2400, 0.95)))
)));

runner(k) = (travel(0.22 + 0.01 * k, COLD), _, _)
  : \(a, drive, back).(drive + a * back)
  : travel(0.22 + 0.01 * k, COLD);

ways = bus(CYL * 3 + 1)
  <: par(
    k,
    CYL,
    (
      only(CYL * 3 + 1, k),
        only(CYL * 3 + 1, CYL + 1 + 2 * k),
        only(CYL * 3 + 1, CYL + 2 + 2 * k)
    )
      : runner(k + 1)
  ),
    (only(CYL * 3 + 1, CYL) : in);

process = (ways : (star(CYL + 1, 3), _)) ~ bus(CYL + 1)
  : (par(i, CYL + 1, !), _)
  : dcblock
  : leveled(0.0004, 0.3, 12)
  : *(60);
