// Anthem: supersaw chords pumping against an 808 kick, a bass in octaves,
// a lead that answers every second bar. The chords are a supersequence:
// each repetition takes the next one. Sliders: the width of the saws and
// how open their filter is; the pump is a saw signal ducking the pad on
// every beat.
bpm(138)
scale("minor", "a2")

local width = slider("width", 22, 4, 50)
local open = slider("open", 0.55, 0.2, 0.9)

play("pad", "supersaw", `(024)<(135)(357)(246)(135)>`, {
  dur: 4, legato: 1.0, oct: 1, attack: 0.03, release: 0.6, sustain: 1.0,
  detune: width, pw: 0.8, cutoff: open, env: 0.15, res: 0.15, room: 0.35,
  delay: 0.15, vel: 0.55,
})
set("pad", {gain: saw(1, 0.25, 1.0)})
play("bass", "saw", `0 0 7 0  0 0 7 7`:then(`0 0 7 0  0 0 5 3`), {
  dur: 1 / 2, oct: -1, cutoff: 0.35, env: 0.35, res: 0.2, decay: 0.12,
  sustain: 0.3, release: 0.05, drive: 0.3, gain: 0.7,
})
set("bass", {gain: saw(1, 0.5, 1.0)})
play("lead", "supersaw", `........ 7.5.4.2. ........ 4.2.0.-3`, {
  dur: 1 / 2, oct: 2, attack: 0.01, release: 0.3, sustain: 0.6, cutoff: 0.7,
  detune: 14, pw: 0.5, delay: 0.45, room: 0.3, vel: 0.5, pan: sine(2, -0.5, 0.5),
})
play("kick", "808", `x.x.x.x.`, {dur: 1 / 2, gain: 0.95})
play("clap", "808", `..c...c.`, {dur: 1 / 2, room: 0.3, vel: 0.8})
play("hats", "808", `-.-+-.-+ -.-+-.--`, {dur: 1 / 4, vel: 0.5, pan: 0.3})
delay(0.75, 0.45, 0.4)
reverb(0.7, 0.4)
uniform("open", open)

shader("""
  // a sun over a wireframe plain, the grid scrolling at the tempo, flashing
  // with the kick
  float horizon = 0.08;
  vec3 c = vec3(0.0);
  if(p.y > horizon){
    float d = length(p - vec2(0.0, 0.32));
    float sun = smoothstep(0.26, 0.25, d);
    float slits = step(0.5, fract((p.y - 0.14) * 28.0 + beat * 0.5)) * step(p.y, 0.32);
    vec3 sc = mix(vec3(1.0, 0.25, 0.55), vec3(1.0, 0.9, 0.3), smoothstep(0.1, 0.5, p.y));
    c = mix(vec3(0.08, 0.0, 0.16), vec3(0.4, 0.05, 0.4), smoothstep(0.6, 0.08, p.y));
    c += sc * sun * (1.0 - slits * 0.9) * (0.9 + 0.3 * env[3]);
    c += vec3(1.0, 0.4, 0.6) * exp(-d * 6.0) * 0.4;
    float star = step(0.995, hash(floor(p * 90.0))) * smoothstep(0.3, 0.6, p.y);
    c += star * (0.5 + 0.5 * sin(time * 3.0 + p.x * 40.0));
  } else {
    float z = 0.08 / (horizon - p.y + 0.001);
    float x = p.x * z * 8.0;
    // a line's width grows with the distance, so it stays the same on
    // the screen: with z across, with z squared along
    float gx = 1.0 - smoothstep(0.0, 0.1 * z, 0.5 - abs(fract(x) - 0.5));
    float gz = 1.0 - smoothstep(0.0, 0.3 * z * z, 0.5 - abs(fract(z * 2.0 - beat * 2.0) - 0.5));
    float line = max(gx, gz);
    float fade = exp(-z * 0.05);
    vec3 glow = mix(vec3(0.9, 0.2, 0.8), vec3(0.2, 0.9, 1.0), open);
    c = vec3(0.02, 0.0, 0.05) + glow * line * fade * (0.5 + 0.8 * env[3]);
  }
  color = mix(c, last * 0.9, 0.35);
""")
