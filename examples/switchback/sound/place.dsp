// sound/place: the place the truck and the world sound in. Out of doors
// there is no room, but there is the ground, which sends everything
// back a moment late; rock walls and steep slopes, which send it back
// much later, as echoes from where they stand; and woods and gorges,
// which scatter it into a faint tail. The truck's and the world's sound
// come in as stereo pairs (and are turned to the settings' volumes); out
// goes one pair: both, with what the place adds. What the place is like
// the game says (sound/space.slang).
import "std";

// (behind a pause menu the game stands still: the truck, held at
// whatever it was doing, all but falls silent; the world goes on)
paused = hslider("paused", 0, 0, 1, 0.01) : smooth(0.9995);
truck = hslider("truck", 1, 0, 1, 0.01) : smooth(0.999) : *(1 - 0.92 * paused);
world = hslider("world", 1, 0, 1, 0.01) : smooth(0.999);

// the ground's reflection: how strong (soft ground gives little back) and
// how late, in samples (the longer way down and up again)
ground = hslider("ground", 0.35, 0, 1, 0.01) : smooth(0.999);
ground_delay = hslider("ground delay", 44, 4, 400, 0.1) : smooth(0.9995);

// two walls: how late each one's echo comes (samples: there and back),
// and how loud on the left and on the right
wall1_delay = hslider("wall1 delay", 4000, 200, 28000, 1) : smooth(0.99985);
wall1_left = hslider("wall1 left", 0, 0, 1, 0.001) : smooth(0.9995);
wall1_right = hslider("wall1 right", 0, 0, 1, 0.001) : smooth(0.9995);
wall2_delay = hslider("wall2 delay", 6000, 200, 28000, 1) : smooth(0.99985);
wall2_left = hslider("wall2 left", 0, 0, 1, 0.001) : smooth(0.9995);
wall2_right = hslider("wall2 right", 0, 0, 1, 0.001) : smooth(0.9995);

// the tail: how much of the sound goes into it (out in the open it is
// barely there), how long it lasts (0 to 1), how dull it is (leaves and
// snow swallow the highs)
tail = hslider("tail", 0.2, 0, 1, 0.01) : smooth(0.999);
size = hslider("size", 0.5, 0, 1, 0.01);
damp = hslider("damp", 0.5, 0, 1, 0.01);

// a signal d samples late (most at the most), d gliding (between two
// samples: a line)
late(d, most) = _ <: @(whole) * (1 - part), @(whole + 1) * part :> _ with {
  whole = min(max(floor(d), 1), most);
  part = min(max(d - whole, 0), 1);
};

// an echo off a wall: late, without its highs (the air and the rock
// take them)
echo(d) = late(d, 28000) : lowpass1(2600);

// the tail of one side: four combs and two allpasses (after Freeverb,
// its delays longer: out of doors the reflections are far apart)
scatter(c1, c2, c3, c4, a1, a2) = _
  <: comb(c1, back, dull),
    comb(c2, back, dull),
    comb(c3, back, dull),
    comb(c4, back, dull)
  :> allpass(a1, 0.5) : allpass(a2, 0.5) with {
  back = 0.5 + 0.3 * size;
  dull = 0.15 + 0.5 * damp;
};

process(tl, tr, wl, wr) = left, right with {
  l = tl * truck + wl * world;
  r = tr * truck + wr * world;
  // (the walls and the tail hear the truck most: the world's own sound
  // is everywhere already)
  mono = (tl + tr) * truck * 0.5 + (wl + wr) * world * 0.15;
  bounce(x) = x : late(ground_delay, 400) : lowpass1(2400) : *(ground);
  first = mono : echo(wall1_delay);
  second = mono : echo(wall2_delay);
  // (four combs make some three times what they are fed: with tail at 1
  // the tail is 18 dB under the sound, at a quarter 30 dB)
  feed = mono * tail * 0.04;
  left = l + bounce(l) + first * wall1_left + second * wall2_left +
    (feed : scatter(1789, 2043, 2269, 2587, 556, 341));
  right = r + bounce(r) + first * wall1_right + second * wall2_right +
    (feed : scatter(1901, 2137, 2389, 2671, 579, 363));
};
