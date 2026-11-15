// sound/master: the last thing before the loudspeakers. The truck and
// the world as they sound in their place (sound/place.dsp) and the
// interface's sound come in as stereo pairs; out goes one pair: the
// world dull and quiet while the game is paused (the interface is not),
// all of it at the settings' volume, and held under full scale by a
// limiter (a hand on the volume that is quick down and slow up), with a
// soft clip behind it for what is quicker still.
import "std";

master = hslider("master", 0.8, 0, 1, 0.01) : smooth(0.999);
interface = hslider("interface", 1, 0, 1, 0.01) : smooth(0.999);
paused = hslider("paused", 0, 0, 1, 0.01) : smooth(0.9995);
awake = hslider("awake", 0, 0, 1, 0.01) : smooth(0.9995);

// the world behind a pause menu: without its highs, and further away
behind = lowpass1(18000 * pow(0.035, paused)) : *(1 - 0.6 * paused);

// how loud a pair is now: the larger of the two, falling slowly
loudest(l, r) = max(abs(l), abs(r)) : (\(prev, x).(max(x, prev * 0.9994))) ~ _;

// a pair under the ceiling: turned down as far as its loudest asks
limited(l, r) = l * g, r * g with {
  g = min(1, 0.7 / max(loudest(l, r), 0.0001)) : smooth(0.99);
};

process(l, r, il, ir) = (
  ((l : behind) + il * interface) * master * awake,
    ((r : behind) + ir * interface) * master * awake
)
  : limited
  : (tanh, tanh);
