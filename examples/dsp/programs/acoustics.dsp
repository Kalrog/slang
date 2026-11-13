// What a listener hears of the car of programs/inline4.dsp: its stems
// (exhaust, intake, mechanics, the engine's vibration) and its speed in,
// the tyres on the road and the wind made here, and all of it as someone
// standing beside the road hears it, or someone in the driver's seat.
//
// - the tyres, four of them, each with its own noise: tread blocks
//   striking the road (blocks of three lengths, so they do not whistle),
//   air pumped out of the closing grooves (boosted by the horn between the
//   tyre and the road), the road's texture shaking the tread and the
//   carcass, the air in the tyre ringing (its cavity resonance), cobbles
//   striking the tyres one by one
// - the wind: the turbulent air along the body (its sound power growing
//   with the sixth power of the speed) in gusts, and the vortices behind
//   the mirrors
// - outside, a few metres from the car's left side: every source at its
//   place (the exhaust at the rear, the engine at the front, a tyre at
//   each corner) and the ground's reflection, a few milliseconds late
// - inside, in the driver's seat: the sound through the panels and the
//   glass (the heavier the wall, the more it keeps out, the highs most),
//   the vibration through the engine mounts and the suspension into the
//   body, whose panels sound it (the drone), the cabin's resonances and its
//   short, damped reverberation
//
// Inputs: exhaust, intake, mechanics, vibration, speed (km/h). Outputs:
// left, right.
import "std";

// ------------------------------------------------------------ controls

// 0 beside the road, 1 in the driver's seat (a short crossfade)
listener = hslider("listener", 0, 0, 1, 1) : smooth(0.9995);
// 0 smooth asphalt, 1 coarse chip seal, 2 cobbles
road = nentry("road", 0, 0, 2, 1);
tyre_level = hslider("tyre level", 1, 0, 2, 0.01);
wind_level = hslider("wind level", 1, 0, 2, 0.01);

// a value per road surface
surface(values) = sum(i, 3, (int(road + 0.5) == i) * take(i + 1, values));

// ------------------------------------------------------------ the tyres

// a clock ticking as the tyre rolls at v m/s, every lo to hi metres (a
// new random interval each tick): 1 at a tick, else 0 (k: its own noise)
ticks(k, v, lo, hi) = (step ~ (_, _)) : (\(phase).(phase < phase'), !) with {
  step(phase, s) = next, select2(next < phase, s, (noises(k) + 1) / 2) with {
    next = frac(phase + v / (lo + (hi - lo) * s) / SR);
  };
};

// wheel k (1-4) at v m/s: what it sends into the air, and into the body
// through the suspension
tyre_air(k, v) = (tread + pumping + texture + cobbles) * tyre_level * 1.6 with {
  // tread blocks 21-29 mm long striking the road; the rubber rings
  tread = ticks(10 + k, v, 0.021, 0.029) * min(v / 30, 1.5)
    : bandpass2(950, 3)
    : *(0.25);
  // air squeezed out of the grooves, louder fast (the horn's band)
  pumping = noises(20 + k) * (v / 30) ^ 2 : bandpass2(1700, 1.4) : *(0.05);
  // the road's texture: the rougher the road and the faster, the higher
  texture = road_texture(k, v)
    : bandpass2(max(v / surface((0.02, 0.012, 0.02)), 40), 0.7);
  cobbles = cobble_hits(k, v) : bandpass2(420, 2) : *(0.6);
};

tyre_body(k, v) = (road_texture(k, v) + cobble_hits(k, v) * 2)
  <: bandpass2(92, 3), bandpass2(215, 35) * 0.6
  :> *(tyre_level);

road_texture(k, v) = noises(30 + k) * surface((0.25, 1, 0.5)) *
  min(v / 30, 2) ^ 1.5;

// cobbles, 11-17 cm apart, each a blow (on the other surfaces none)
cobble_hits(k, v) = ticks(40 + k, v, 0.11, 0.17) * surface((0, 0, 1)) *
  min(v / 8, 1);

// ------------------------------------------------------------ the wind

wind(v) = (turbulence + mirrors) * wind_level * (v / 40) ^ 3 with {
  // gusts: a new strength now and then, glided to
  gust = latch(phasor(2.3) <: _ < _', noises(50)) : smooth(0.9997);
  turbulence = noises(51)
    : lowpass2(250 + 40 * v, 0.6)
    : highpass2(60, 0.7)
    : *(0.15 * (1 + 0.4 * gust));
  // vortices shed behind the mirrors' stalks (3.5 cm): St = 0.2
  mirrors = noises(52) : bandpass2(max(0.2 * v / 0.035, 30), 4) : *(0.08);
};

// ------------------------------------------------------------ outside

// the ground's reflection, 1.8 ms late and duller
ground = _ <: _, (@(int(SR * 0.0018)) : lowpass1(3000) : *(0.45)) :> _;

// ------------------------------------------------------------ inside

// a wall that lets through what is below fc, and less of it the higher
// above (two poles: the mass law and the damping layers on it)
panel(fc, g) = lowpass1(fc) : lowpass1(fc * 2) : *(g);

// the body's panels and frame, struck: their lowest modes
body = _ <: bandpass2(38, 4), bandpass2(64, 5), bandpass2(103, 6) :> _;

// the cabin: its first modes (2.5 m long, 1.4 m wide, 1.15 m high) on the
// sound, then a short reverberation the seats and carpets damp
cabin(delays) = _ <: _, modes, reverb :> _ with {
  modes = _ <: bandpass2(69, 6), bandpass2(122, 5), bandpass2(149, 5) :> *(0.5);
  reverb = _ <: par(i, 4, comb(take(i + 1, delays), 0.55, 0.6)) :> *(0.08);
};

// ------------------------------------------------------------ the listener

process(exhaust, intake, mechanics, vibration, kmh) = mix(outside_l, inside_l),
  mix(outside_r, inside_r) with {
  v = kmh / 3.6;
  front = tyre_air(1, v) + tyre_air(2, v);
  rear = tyre_air(3, v) + tyre_air(4, v);
  air = wind(v);
  // beside the car, on its left: the exhaust behind on the left, the
  // engine in front on the right
  outside_l = exhaust + intake * 0.32 + mechanics + rear * 0.9 + front * 0.45 +
    air * 0.7
    : ground;
  outside_r = exhaust * 0.4 + intake + mechanics + front * 0.9 + rear * 0.45 +
    air * 0.7
    : ground;
  // in the driver's seat
  through_walls = (exhaust : panel(220, 0.1)) + (intake : panel(400, 0.2)) +
    (mechanics : panel(500, 0.25)) + (front + rear : panel(350, 0.3)) +
    (air : panel(1500, 0.5));
  shaking = (vibration : lowpass1(180) : *(0.3)) +
    sum(k, 4, tyre_body(k + 1, v)) * 0.08
    : body;
  inside = through_walls + shaking * 0.5;
  inside_l = inside : cabin((97, 131, 163, 199));
  inside_r = inside : cabin((103, 127, 157, 211));
  mix(out, in) = tanh(out * (1 - listener) + in * listener * 2.5);
};
