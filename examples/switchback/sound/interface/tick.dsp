// sound/interface/tick: something small and hard touched or knocked: the
// interface's ticks (a menu's bar moving, an entry chosen, a pin stuck
// into the map, a part of the truck seating: sound/layers/interface says
// which numbers make which). What is struck rings in two modes that are
// gone in a few hundredths of a second, as wood does (so there is a hint
// of a tone and no beep), and the touch itself is a grain of noise in a
// band.
//
// Input: the other ticks that sound (each adds itself to the row).
// Output: the row with this tick.
import "std";

// a tick: the count of ticks so far (a change strikes), and how hard
hit = hslider("hit", 0, 0, 1000000000, 1);
level = hslider("level", 0.5, 0, 4, 0.0001);
// how round the knock is: the frequency above which it excites less, Hz
soft = hslider("soft", 3000, 50, 16000, 1);
// what is struck: its tone, Hz, and how long that rings, s (to 60 dB
// down); its second mode, how long, and how much of it
tone = hslider("tone", 800, 30, 8000, 0.01);
ring = hslider("ring", 0.04, 0.003, 2, 0.0001);
over = hslider("over", 2100, 30, 12000, 0.01);
short = hslider("short", 0.015, 0.003, 2, 0.0001);
share = hslider("share", 0.3, 0, 4, 0.001);
// the touch: how much noise, in a band around where, Hz, and how long, s
grain = hslider("grain", 0.3, 0, 4, 0.001);
band = hslider("band", 2500, 100, 12000, 1);
snap = hslider("snap", 0.004, 0.0005, 0.5, 0.0001);

fired = hit != hit';
knock = fired * level : lowpass1(soft);

// a mode at f Hz that rings for t seconds: struck by one sample it
// answers with a sine of that height
mode(f, t) = tf2(sin(w), 0, 0, -2 * r * cos(w), r * r) with {
  w = TAU * within(f) / SR;
  r = exp(-6.908 / (t * SR));
};
// (nothing is asked for above what the sample rate carries)
within(f) = min(f, 0.45 * SR);

// 1 at the strike, then dying: 60 dB down after `snap`
dying = (\(was).(select2(fired, was * exp(-6.908 / (snap * SR)), 1))) ~ _;
touch = noise * dying * level * grain : bandpass2(within(band), 1.4);

struck = knock <: mode(tone, ring), mode(over, short) * share :> _;

process = _ + struck + touch;
