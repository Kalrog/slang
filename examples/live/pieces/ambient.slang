// Ambient: a slow chord that changes every repetition, long tails, and
// the keyboard or a MIDI controller to play over it (hover KEYS and press
// asdf, or plug a controller in before starting).
bpm(60)
scale("lydian", "c3")

local shimmer = slider("shimmer", 0.5, 0, 1)

play("pad", "tri", `(024)<(135)(246)>`, {
  dur: 4, attack: 1.2, release: 2.5, sustain: 0.8, cutoff: 0.45, room: 0.6,
  detune: 8, vel: 0.5, legato: 1.0,
})
play("drops", "sine", `..7. 9... .5.. ...8`, {
  dur: 1 / 2, oct: 1, attack: 0.002, decay: 0.3, sustain: 0.0, delay: 0.6,
  room: 0.5, vel: 0.5, pan: rand(1, -0.8, 0.8),
})
play("keys", "fm", keyboard(), {
  attack: 0.01, release: 1.0, sustain: 0.7, fm: 1.5, ratio: 2.0, room: 0.5, delay: 0.3,
})
play("midi", "saw", midi(), {
  attack: 0.02, release: 0.8, sustain: 0.7, cutoff: 0.5, env: 0.2, room: 0.4,
})
set("pad", {cutoff: sine(16, 0.3, 0.55)})
delay(1.5, 0.55, 0.3)
reverb(0.95, 0.3)
uniform("shimmer", shimmer)

shader("""
  float t = time * 0.05;
  vec2 q = p * 1.5;
  float n = noise(q + vec2(t, -t)) * 0.6 + noise(q * 3.0 + t * 2.0 + env[0]) * 0.4;
  float bands = smoothstep(0.2, 0.8, fract(n * 3.0 - beat * 0.03));
  vec3 c = pal(n * 0.6 + beat * 0.01, vec3(0.55, 0.45, 0.6), vec3(0.4, 0.4, 0.3), vec3(0.6, 0.8, 1.0), vec3(0.1, 0.4, 0.6));
  c *= 0.5 + 0.6 * bands * (0.5 + env[0]);
  c += env[1] * vec3(1.0, 0.9, 0.7) * smoothstep(0.35, 0.0, length(p - vec2(sin(beat), cos(beat * 0.7)) * 0.4));
  c += (env[2] + env[3]) * vec3(0.3, 0.4, 0.5);
  color = mix(c, last, 0.4 + 0.5 * shimmer);
""")
