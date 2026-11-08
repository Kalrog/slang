// Akina: a night run down the pass. Light streaks pour out of the
// vanishing point, white and yellow on the right, red on the left, and
// the last frame zooms in behind them so they trail. The kick pushes the
// speed, the snare flashes the sky. Eurobeat, naturally.
bpm(152)
scale("minor", "e2")

local speed = slider("speed", 0.6, 0.1, 1.5)
local trail = slider("trail", 0.85, 0.5, 0.97)

play("kick", "drum", `x.x. x.x.`, {dur: 1 / 2, gain: 0.9})
play("snare", "drum", `..o. ..o.`, {dur: 1 / 2, room: 0.3})
play("hats", "drum", `-.-- -.-+`, {dur: 1 / 4, vel: 0.45, pan: 0.3})
play("bass", "saw", `0 0 0 0 5 5 5 5 3 3 3 3 4 4 4 4`:then(`0 0 0 0 5 5 5 5 -3 -3 -3 -3 -2 -2 -2 -2`), {
  dur: 1 / 2, oct: -1, cutoff: 0.5, env: 0.3, res: 0.2, decay: 0.12, sustain: 0.1,
  release: 0.05, drive: 0.4, legato: 0.5,
  vel: func(e){ if(e.rep % 2 == 1){ return 0.8 } return 1.0 },
})
play("lead", "saw", `7.7.9 7.5.. 7.7.9 10.9.. <[7.7.9 7.5..][12.11.9 7.10..]>`, {
  dur: 1 / 4, oct: 1, attack: 0.01, release: 0.2, sustain: 0.7, cutoff: 0.7,
  detune: 12, delay: 0.3, room: 0.2, vel: 0.55, pan: -0.2,
})
play("chords", "square", `(024)___ (135)___ (-124)___ (-135)___`, {
  dur: 1 / 2, attack: 0.05, release: 0.3, sustain: 0.6, cutoff: 0.4, pw: 0.3,
  vel: 0.35, room: 0.4, pan: 0.4, detune: 7,
})
set("chords", {cutoff: sine(8, 0.3, 0.5)})
delay(0.75, 0.35, 0.4)
reverb(0.6, 0.5)
uniform("speed", speed)
uniform("trail", trail)

shader("""
  // the vanishing point, a little above the middle, swaying with the road
  vec2 v = vec2(0.08 * sin(beat * 0.11), 0.12);
  vec2 d = p - v;
  float r = length(d);
  float a = atan(d.y, d.x);
  float sp = speed * (1.0 + 1.5 * env[0]);
  vec3 c = vec3(0.0);
  // three layers of streaks radiating out, each lane its own light
  for(int i = 0; i < 3; i++){
    float fi = float(i);
    float lanes = 28.0 + fi * 14.0;
    float lane = floor(a * lanes / 6.28318 + fi * 0.37);
    float h = hash(vec2(lane, fi));
    if(h < 0.55) continue;
    float width = abs(fract(a * lanes / 6.28318 + fi * 0.37) - 0.5);
    float along = log(r + 0.02) * 2.5 - time * sp * (0.8 + h) - h * 7.0;
    float dash = fract(along);
    float len = 0.25 + 0.45 * hash(vec2(fi, lane + 3.0));
    float on = smoothstep(0.0, 0.08, dash) * smoothstep(len, len - 0.15, dash);
    float line = smoothstep(0.12, 0.0, width) * on;
    // headlights on the right, taillights on the left, a few amber
    vec3 light = d.x > 0.0 ? mix(vec3(1.0, 0.95, 0.8), vec3(1.0, 0.8, 0.3), step(0.8, h))
                           : vec3(1.0, 0.12, 0.08);
    c += light * line * smoothstep(0.02, 0.35, r) * (0.6 + 0.8 * r);
  }
  // the road: a dark wedge below the horizon with a dashed center line
  float horizon = v.y;
  float below = horizon - p.y;
  if(below > 0.0){
    float z = 0.08 / (below + 0.001);
    float center = abs(p.x - v.x) / (below + 0.001);
    float dashes = smoothstep(0.6, 0.4, fract(z * 2.0 - time * sp * 1.5));
    c += vec3(0.9, 0.85, 0.5) * smoothstep(0.08, 0.0, center) * dashes * smoothstep(0.0, 0.06, below) * 0.5;
    c += vec3(0.05, 0.05, 0.08) * smoothstep(1.2, 0.0, center) * smoothstep(0.0, 0.1, below);
  }
  // the sky: a glow at the horizon, a flash on the snare
  c += vec3(0.08, 0.05, 0.15) * smoothstep(0.5, 0.0, abs(p.y - horizon)) * (1.0 + 2.0 * env[1]);
  c += env[1] * 0.25 * vec3(0.6, 0.7, 1.0) * smoothstep(0.0, 0.6, p.y - horizon);
  // the trail: the last frame pulled outward from the vanishing point
  vec2 vuv = vec2(0.5, 0.5) + v * vec2(resolution.y / resolution.x, 1.0);
  vec3 pulled = texture(prev, vuv + (uv - vuv) * 0.985).rgb;
  color = max(c, pulled * trail);
""")
