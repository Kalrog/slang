// slang live: a first piece. command+enter runs it; change a pattern,
// a number, the shader, and run it again while it plays.
bpm(118)
scale("minor", "a2")

local cut = slider("cutoff", 0.45, 0.1, 0.9)
local space = slider("space", 0.3, 0, 1)

play("drums", "drum", `x-o- x-[oo] x-o- [xx]-o-`, {dur: 1 / 2, room: 0.1})
play("hats", "drum", `-.-. -.-+`, {dur: 1 / 4, vel: 0.5, pan: 0.3})
play("bass", "saw", `0.0. 3.5. 0.0. -2.5.`, {
  dur: 1 / 2, cutoff: cut, env: 0.4, res: 0.3, decay: 0.15, sustain: 0.2, drive: 0.3,
})
play("lead", "square", `0<24>7 5<32>.`, {
  oct: 2, dur: 1 / 2, attack: 0.01, release: 0.4, cutoff: 0.6, delay: 0.5, vel: 0.5, pan: -0.3,
})
set("lead", {pw: sine(16, 0.2, 0.8)})
delay(0.75, 0.45, 0.4)
reverb(0.8, 0.4)
uniform("space", space)

shader("""
  float k = env[0];
  vec2 q = p * rot(beat * 0.1) * (1.0 + 0.3 * env[2]);
  float d = length(q) - 0.25 - 0.1 * k;
  float r = abs(sin(d * 30.0 - time * 2.0));
  vec3 c = pal(d + beat * 0.05, vec3(0.5), vec3(0.5), vec3(1.0, 0.7, 0.4), vec3(0.0, 0.15, 0.2));
  color = c * smoothstep(0.6, 0.0, r) * (0.6 + env[3]);
  color = mix(color, last * 0.96, space);
""")
