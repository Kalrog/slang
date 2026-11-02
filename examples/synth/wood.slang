// Walnut, as a GLSL function for main3d.slang's shader: solid wood computed
// for every pixel on the GPU, so it is as sharp as the screen at any
// distance and every board, with its own seed, is cut from its own part of
// the log. No textures.
//
// The board's own coordinates come in with x along the grain. Rings are
// cylinders around a trunk axis that runs along x, off to the side of the
// board (long bands on its faces, arcs at its ends), bent by slow noise;
// a figure of middle-sized noise darkens and lightens them; streaks and
// pores are noise stretched along the grain, faded out where one pixel
// would cover several of them (so the wood does not shimmer from afar).
local wood = {}

wood.glsl = """
float woodHash(vec3 p){
  p = fract(p * 0.3183099 + vec3(0.71, 0.113, 0.419));
  p *= 17.0;
  return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// value noise in [-1, 1]
float woodNoise(vec3 x){
  vec3 i = floor(x);
  vec3 f = fract(x);
  f = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(mix(woodHash(i), woodHash(i + vec3(1, 0, 0)), f.x),
        mix(woodHash(i + vec3(0, 1, 0)), woodHash(i + vec3(1, 1, 0)), f.x), f.y),
    mix(mix(woodHash(i + vec3(0, 0, 1)), woodHash(i + vec3(1, 0, 1)), f.x),
        mix(woodHash(i + vec3(0, 1, 1)), woodHash(i + vec3(1, 1, 1)), f.x), f.y),
    f.z) * 2.0 - 1.0;
}

float woodFbm(vec3 p){
  float a = 0.5;
  float s = 0.0;
  for(int k = 0; k < 4; k++){
    s += a * woodNoise(p);
    p = p * 2.03 + vec3(1.7, 9.2, 3.4);
    a *= 0.5;
  }
  return s;
}

// fine noise along the grain, faded where a pixel spans more than a cycle
float woodFine(vec3 p){
  float spread = length(fwidth(p));
  return woodNoise(p) * (1.0 - smoothstep(0.35, 1.1, spread));
}

// q: the board's coordinates in world units, x along the grain
vec3 woodColor(vec3 q, float seed){
  vec3 o = vec3(seed * 13.7, seed * 7.3, seed * 3.1);
  // where the trunk's axis passes, beside the board
  vec2 c = q.yz + vec2(2.6 + 0.9 * sin(seed * 2.3), 1.8 + 0.7 * cos(seed * 1.7));
  float bend = woodFbm(vec3(q.x * 0.3, q.y * 1.1, q.z * 1.1) + o);
  float figure = woodFbm(vec3(q.x * 1.0, q.y * 3.5, q.z * 3.5) + o * 1.9);
  float t = length(c) * 6.5 + bend * 2.0 + figure * 0.3;
  float s = 0.5 + 0.5 * sin(t * 6.2831853);
  s = s * s;
  float streak = woodFine(vec3(q.x * 1.4, q.y * 60.0, q.z * 60.0) + o);
  float pore = woodFine(vec3(q.x * 8.0, q.y * 220.0, q.z * 220.0) + o);
  float d = clamp(s * 0.45 + streak * 0.25 + pore * 0.1 + figure * 0.12 + 0.2, 0.0, 1.0);
  vec3 light = vec3(150.0, 94.0, 54.0) / 255.0;
  vec3 dark = vec3(58.0, 31.0, 16.0) / 255.0;
  vec3 col = mix(light, dark, d);
  // a little warmth where the slow noise is high
  float warm = 1.0 + bend * 0.08;
  return vec3(col.r * warm, col.g, col.b / warm);
}
"""

return wood
