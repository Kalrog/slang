// Acid: one line, its filter opened by the envelope, a slider and a knob
// (right click the slider, turn a knob: it is bound from then on).
bpm(130)
scale("major", "e1")

local cut = slider("cutoff", 0.35, 0.1, 0.8)
local res = slider("res", 0.6, 0, 0.95)
local drive = slider("drive", 0.6, 0, 0.95)

play("acid", "saw", `000<.9>`, {
  dur: 1 / 4,
  cutoff: cut + sine(5, -0.2, 0.6),
  res: res,
  env: 0.7,
  decay: 0.06,
  sustain: 0.0,
  release: 0.04,
  drive: drive,
  // delay: 0.25,
  // legato: 0.6,
  glide: func(e){
    if(e.len > 0.3){ return 0.08 }
    return 0.0
  },
})
// play("kick", "drum", `x.x. x.x.`, {dur: 1 / 2, gain: 0.9})
// play("hats", "drum", `-.-- -.-+ -.-- -.[--]`, {dur: 1 / 4, vel: 0.4, pan: 0.4})
// play("clap", "drum", `.c`, {dur: 1, room: 0.3, vel: 0.7})
// set("acid", {pan: sine(1, -0.4, 0.4)})

play("kick", "808", `x...x...x...x...`, {dur: 1 / 4, gain: 0.5})
play("hats", "808", `-.-- -.-+ -.-- -.[--]`, {dur: 1 / 4, vel: 0.7, pan: 0.4})
// play("kick", "808", `x...x...x...x...`, {dur: 1 / 4, gain: 0.5})
// delay(0.75, 0.5, 0.3)
reverb(0.5, 0.6)

// the picture: Sunset Ocean, a Shadertoy-style program as it is (its own
// functions and mainImage); iMouse follows a drag over the picture
shader("""
// Sunset Ocean: dark glassy waves rolling toward a huge neon sun
// Hold the mouse down and drag to look around. Before you click, the camera drifts gently on its own.

const vec3 SUN_DIR = vec3(0.0, 0.085, 1.0);

float hash21(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p){
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x), mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p){
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 5; i++){ s += a * vnoise(p); p = p * 2.03 + 4.1; a *= 0.5; }
    return s;
}
mat2 rot(float a){ float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }

// ---------- waves: a stack of rolling swells with sharp crests ----------
float waves(vec2 p, float t, int oct){
    float h = 0.0, a = 0.42, f = 0.55;
    vec2 q = p;
    for (int i = 0; i < 6; i++){
        if (i >= oct) break;
        float ang = 0.9 + float(i) * 1.37;
        vec2 dir = vec2(cos(ang), sin(ang));
        float ph = dot(q, dir) * f + t * (0.8 + 0.35 * float(i));
        float w = 1.0 - abs(sin(ph));                 // sharp crests, wide troughs
        h += a * (w * w - 0.35);
        q += dir * 0.35 * sin(ph);                    // pull crests into points
        a *= 0.52; f *= 1.9;
    }
    return h;
}

// ---------- sky: gradient, striped sun, streaky clouds, stars ----------
vec3 sky(vec3 rd, float t, float st){
    float e = rd.y;
    vec3 hor = vec3(1.00, 0.30, 0.38);
    vec3 mid = vec3(0.42, 0.08, 0.50);
    vec3 top = vec3(0.015, 0.010, 0.110);
    vec3 col = mix(hor, mid, smoothstep(0.0, 0.20, e));
    col = mix(col, top, smoothstep(0.12, 0.65, e));
    col += vec3(1.0, 0.55, 0.25) * exp(-max(e, 0.0) * 9.0) * 0.35;      // warm band at the horizon

    // stars
    vec2 sg = vec2(atan(rd.x, rd.z) * 60.0, e * 60.0);
    vec2 si = floor(sg);
    float sh = hash21(si);
    col += vec3(0.9, 0.85, 1.0) * step(0.985, sh) * smoothstep(0.16, 0.02, length(fract(sg) - 0.5)) * smoothstep(0.25, 0.6, e) * st * (0.6 + 0.4 * sin(t * 2.0 + sh * 40.0));

    // long thin clouds lit from below by the sun
    vec2 cp = vec2(atan(rd.x, rd.z) * 3.0 + t * 0.01, e * 14.0);
    float cl = fbm(vec2(cp.x * 1.5, cp.y * 4.5));
    float cm = smoothstep(0.52, 0.80, cl) * smoothstep(0.03, 0.12, e) * smoothstep(0.55, 0.15, e);
    vec3 ccol = mix(vec3(0.30, 0.06, 0.38), vec3(1.0, 0.42, 0.30), exp(-abs(e - 0.09) * 9.0));
    col = mix(col, ccol, cm * 0.85);

    // the sun, with slits cut into its lower half
    vec3 sd = normalize(SUN_DIR);
    vec2 sp = vec2(atan(rd.x, rd.z) - atan(sd.x, sd.z), e - sd.y);
    float sr = 0.17;
    float sdist = length(sp);
    float yy = (sp.y + sr) / (2.0 * sr);
    float slit = 1.0;
    if (yy < 0.55){ float band = 0.5 + 0.5 * sin(yy * 46.0); slit = step((0.55 - yy) * 1.6, band * 1.25); }
    vec3 scol = mix(vec3(1.0, 0.18, 0.50), vec3(1.0, 0.88, 0.35), smoothstep(0.1, 0.95, yy));
    col += scol * smoothstep(sr, sr - 0.004, sdist) * slit * 1.2;
    col += vec3(1.0, 0.45, 0.35) * exp(-sdist * 5.0) * 0.45;
    return col;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord){
    vec2 uv = (fragCoord - 0.5 * iResolution.xy) / iResolution.y;
    float t = iTime;

    // camera: low over the water, bobbing and slowly drifting
    vec2 m = iMouse.x > 0.0 ? (iMouse.xy / iResolution.xy - 0.5) : vec2(0.0);
    vec3 ro = vec3(0.0, 1.7 + 0.12 * sin(t * 0.6), t * 0.8);
    float yaw = 0.22 * sin(t * 0.07) + m.x * 1.8;
    float pitch = -0.045 + 0.02 * sin(t * 0.5) + m.y * 0.5;
    vec3 f = normalize(vec3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)));
    vec3 r = normalize(cross(vec3(0.0, 1.0, 0.0), f));
    vec3 u = cross(f, r);
    float roll = 0.03 * sin(t * 0.55);
    vec3 r2 = r * cos(roll) + u * sin(roll);
    vec3 u2 = u * cos(roll) - r * sin(roll);
    vec3 rd = normalize(f + 1.0 * (uv.x * r2 + uv.y * u2));

    vec3 col;
    if (rd.y >= -0.002){
        col = sky(rd, t, 1.0);
    } else {
        // find the water surface
        float tt = -ro.y / rd.y;
        for (int i = 0; i < 6; i++){
            vec3 p = ro + rd * tt;
            float h = waves(p.xz, t, 4) * 0.55;
            tt += (p.y - h) / (-rd.y) * 0.7;
        }
        vec3 p = ro + rd * tt;

        // surface normal; far away it flattens so it does not shimmer
        float eps = 0.04 + tt * 0.02;
        int oct = tt < 14.0 ? 6 : (tt < 35.0 ? 4 : 2);
        float h0 = waves(p.xz, t, oct);
        float hx = waves(p.xz + vec2(eps, 0.0), t, oct);
        float hz = waves(p.xz + vec2(0.0, eps), t, oct);
        vec3 n = normalize(vec3((h0 - hx) / eps * 0.55, 1.0, (h0 - hz) / eps * 0.55));
        n = normalize(mix(n, vec3(0.0, 1.0, 0.0), smoothstep(6.0, 70.0, tt)));

        vec3 rf = reflect(rd, n);
        rf.y = abs(rf.y);
        float fre = 0.03 + 0.97 * pow(1.0 - clamp(dot(n, -rd), 0.0, 1.0), 5.0);
        vec3 refl = sky(rf, t, 0.0);

        // deep water: dark violet, with a hint of pink in the crests
        float crest = smoothstep(0.05, 0.45, h0);
        vec3 deep = vec3(0.012, 0.012, 0.075) + vec3(0.30, 0.06, 0.28) * crest * 0.28;
        col = mix(deep, refl, clamp(fre * 1.15, 0.0, 1.0));

        // glitter path under the sun
        vec3 sd = normalize(SUN_DIR);
        float spec = pow(max(dot(rf, sd), 0.0), 450.0) * 6.0 + pow(max(dot(rf, sd), 0.0), 40.0) * 0.55;
        col += mix(vec3(1.0, 0.35, 0.40), vec3(1.0, 0.9, 0.55), 0.5) * spec;

        // haze toward the horizon
        float fog = 1.0 - exp(-tt * 0.012);
        col = mix(col, vec3(0.90, 0.28, 0.40) * 0.85, fog * fog);
    }

    col *= 1.0 - 0.42 * dot(uv, uv);
    col = col / (1.0 + 0.22 * col);
    col = pow(clamp(col, 0.0, 1.0), vec3(0.93));
    fragColor = vec4(col, 1.0);
}
""")
