// render/flora: the woods and the rocks drawn. Every kind of game/plants
// has its shapes (render/flora_mesh) in up to three levels of detail:
// near (branches and foliage cards), mid (a few cards), far (a cone or a
// blob of a few triangles). The plants of a square of the land are baked
// into meshes, a square and a level each (render/flora_bake.kernel puts
// every instance's vertices in their place in the world): the far level
// for the whole land when it is loaded, the mid and near levels for the
// squares around the eye as it moves, in parts of a few thousand
// vertices, about a millisecond's worth a frame. A frame then draws a
// hundred meshes or so, each one plain draw call. (Instanced drawing
// would need no baking, but one instanced call costs as much as a
// hundred plain ones here.)
//
// The shaders leave out, tree by tree, what is not at a level's
// distance, and where two levels meet each draws the pixels the other
// leaves out (a dither), so that nothing pops. The wind bends the
// trunks, bobs the branches and flutters the leaves. The foliage is
// cards cut out of a texture painted at the start
// (render/flora_paint.kernel): a spruce's frond, a pine's tufts, a spray
// of birch leaves, a cluster of oak leaves.
//
//   flora.init(land, plants.scatter(land))
//   flora.prepare(truck_position)   // at the start and after a reset
//   flora.draw(view)          // in the scene, and in the sun's shadow pass
//   flora.unload()
//
// init keeps what it bakes on the plants' squares (their near and mid
// meshes), so one set of plants is drawn by one flora at a time.
local rl = require("raylib")
local math = require("slang/math")
local kernel = require("kernel")
local time = require("slang/time")
local vec = require("game/vec")
local plants = require("game/plants")
local terrain = require("game/terrain")
local ground = require("render/terrain")
local paint = require("render/flora_paint")
local baker = require("render/flora_bake")
local shapes = require("render/flora_mesh")
local shaders = require("render/shaders")

local m = {}

// how far each level of detail is drawn, in meters: thinning in from ..
// to, thinning out from .. to
m.NEAR = {0, 0, 100, 125}
m.MID = {100, 125, 380, 430}
m.FAR = {380, 430, 100000, 100001}
// rocks smaller than these (meters) are left out of the mid and the far
// level; a rock smaller than SMALL is drawn as a coarse stone
m.MID_ROCK = 0.4
m.FAR_ROCK = 0.8
m.SMALL = 0.5
// a square's level is baked in parts of at most this many vertices, a
// mesh each (smaller: shorter frames while driving, more draw calls)
m.PART = 24000
// the time a frame may spend baking, in ms (it bakes one part at least),
// and when many squares are missing at once (after a jump that
// [prepare] was not called for)
m.BAKE_MS = 0.8
m.BAKE_MS_MANY = 30
// for looking at one level alone (tool/arboretum): 0 near, 1 mid, 2 far
m.only = null

// the wind, for both shaders: p is the vertex in the world, at where its
// plant stands
local wind = """
vec3 blown(vec3 p, vec2 at, float sway, float flutter, float branch){
  // gusts wander over the land; trunks bend with them, branches bob,
  // leaves flutter
  float gust = vnoise(at * 0.011 + vec2(time * 0.21, time * 0.13));
  float slow = 0.5 + 0.5 * sin(time * 1.15 + at.x * 0.05 + at.y * 0.07);
  float bend = sway * (0.05 + 0.34 * gust * (0.55 + 0.45 * slow));
  p.xz += vec2(0.82, 0.57) * bend;
  p.y -= bend * bend * 0.4;
  p.y += flutter * sin(time * 1.9 + branch + at.x) * 0.05 * (0.4 + gust);
  p.xz += flutter * vec2(sin(time * 3.7 + branch * 1.7 + p.y * 2.1), cos(time * 3.1 + branch * 1.3 + p.x * 2.1)) * 0.02 * (0.3 + gust);
  return p;
}

// how much of a plant at `at` a level draws: x thinning in, y thinning out
uniform float eyeAbove;   // how high the eye is over the ground under it
vec2 level(vec2 at, vec4 lod){
  // no two trees change their level at the same distance
  float d = length(vec3(at - eye.xz, eyeAbove)) * (0.93 + 0.14 * hash12(at));
  float fadeIn = lod.y > 0.0 ? smoothstep(lod.x, lod.y, d) : 1.0;
  float fadeOut = 1.0 - smoothstep(lod.z, lod.w, d);
  return vec2(fadeIn, fadeOut);
}
"""

// the land's stone on a rock, for both fragment shaders: the same
// reading of the same texture as render/terrain's rock, so that a
// boulder and a cliff are one stone; then what lies on a boulder: lichen,
// moss low in the valley, snow up high, damp and the ground's own color
// at its foot
local stone = """
uniform sampler2D stoneMap;   // the land's detail texture: r grain, g stones with dark gaps, b blotches, a pebbles

// a normal tilted by a relief h (a height over the surface, m)
vec3 embossed(vec3 n, vec3 pos, float h){
  vec3 dpx = dFdx(pos);
  vec3 dpy = dFdy(pos);
  float dhx = dFdx(h);
  float dhy = dFdy(h);
  vec3 r1 = cross(dpy, n);
  vec3 r2 = cross(n, dpx);
  float det = dot(dpx, r1);
  vec3 grad = sign(det) * (dhx * r1 + dhy * r2);
  return normalize(abs(det) * n - grad);
}

// the texture read from the three sides a surface faces
vec4 stoneTex(vec3 pos, vec3 w, float scale, float shift){
  return texture(stoneMap, pos.zy * scale + shift) * w.x + texture(stoneMap, pos.xz * scale + shift) * w.y +
    texture(stoneMap, pos.xy * scale + shift) * w.z;
}

// stone: a rock's color at pos. n: its face's normal; bed: the direction
// across its strata; tint: a number of the rock's own; above: how high
// over the ground (m); soil: the ground's color; border: how far from
// the face's border (m); pebble: 1 for a river stone or a rock far off
// (no faces to tell apart). nb gets the normal with the stone's relief,
// sky how much of the sky's light arrives.
vec3 stone(vec3 pos, vec3 n, vec3 bed, float tint, float above, vec3 soil, float border, float pebble,
  out vec3 nb, out float sky){
  float dist = distance(pos, eye);
  float near = 1.0 - smoothstep(30.0, 90.0, dist);
  float close = 1.0 - smoothstep(9.0, 26.0, dist);
  vec3 w = abs(n);
  w = w * w * w * w;
  w /= w.x + w.y + w.z;
  vec4 r = stoneTex(pos, w, 0.19, 0.0);
  vec4 mid = stoneTex(pos, w, 0.052, 0.37);
  vec4 fine = vec4(0.5);
  if(near > 0.0){
    fine = mix(fine, stoneTex(pos, w, 0.33, 0.0), near);
  }
  vec3 c = mix(vec3(0.105, 0.097, 0.088), vec3(0.27, 0.25, 0.225), r.b * 0.4 + mid.b * 0.3 + fine.r * 0.3);
  // the strata: bands across the rock's own bedding
  float band = vnoise(vec2(dot(pos, bed) * 1.1 + mid.b * 2.5, 3.7 + tint * 9.0));
  c *= 0.8 + 0.4 * band;
  // cracks between the blocks: thin, and not everywhere
  float cracks = (1.0 - smoothstep(0.02, 0.12, r.g)) * smoothstep(0.3, 0.6, mid.r);
  c *= 1.0 - 0.42 * cracks;
  c *= mix(vec3(1.04, 0.98, 0.9), vec3(0.93, 0.97, 1.03), vnoise(pos.xz * 0.0043 + 3.0));
  // no two rocks the same, nor two faces of one
  c *= 0.9 + 0.2 * tint;
  float facet = hash12(floor(n.xz * 31.0) + floor(n.y * 17.0) * 7.0);
  c *= mix(0.86 + 0.28 * facet, 1.0, pebble);
  float relief = r.r * 0.04 + smoothstep(0.02, 0.12, r.g) * 0.03 + fine.r * 0.02 + band * 0.02;
  if(close > 0.0){
    // from near: the grain, hairline cracks, and edges knocked round
    vec4 g = stoneTex(pos, w, 1.31, 0.61);
    vec4 g2 = stoneTex(pos, w, 0.67, 0.23);
    // (blotches, pits, and thin cracks that run through the rock)
    vec2 q = pos.xz * 2.3 + pos.y * vec2(1.7, 2.9);
    float vein = 1.0 - smoothstep(0.0, 0.03, abs(vnoise(q) - 0.5) + 0.3 * (1.0 - smoothstep(0.35, 0.6, vnoise(q * 0.37 + 7.0))));
    float pits = smoothstep(0.62, 0.9, g.a);
    c *= mix(1.0, (0.72 + 0.56 * g.r) * (0.78 + 0.44 * g2.b) * (1.0 - 0.22 * pits) * (1.0 - 0.5 * vein), close);
    relief += close * (g.r * 0.008 + (g2.b - 0.5) * 0.03 + g2.r * 0.01 - vein * 0.012 - pits * 0.006);
    float worn = (1.0 - smoothstep(0.0, 0.03 + 0.03 * g2.r, border)) * (1.0 - pebble);
    c *= 1.0 + 0.3 * worn * close;
    relief -= close * 0.022 * worn * worn;
  }
  // lichen: pale crusts, and a few ochre ones
  float crust = smoothstep(0.6, 0.72, vnoise(pos.xz * 2.3 + pos.y * 1.7 + 17.0) * 0.72 + mid.a * 0.28);
  c = mix(c, vec3(0.3, 0.31, 0.26) * (0.75 + 0.5 * fine.g), crust * 0.5);
  float ochre = smoothstep(0.84, 0.9, vnoise(pos.zx * 9.0 - pos.y * 6.0 + 41.0) * 0.8 + vnoise(pos.xz * 1.3 + 9.0) * 0.2) * near;
  c = mix(c, vec3(0.3, 0.22, 0.08), ochre * 0.5);
  // moss on what faces up, low in the valley, thicker toward the foot
  float low = 1.0 - smoothstep(170.0, 290.0, pos.y);
  float ragged = (vnoise(pos.xz * 9.0 + pos.y * 5.0) - 0.5) * 0.3 + (fine.r - 0.5) * 0.2;
  float mossy = smoothstep(0.4, 0.8, n.y + ragged) *
    smoothstep(0.5, 0.64, tint * 0.22 + vnoise(pos.xz * 1.7 + pos.y * 0.9 + 5.0) * 0.62 + r.b * 0.16 +
      0.2 * (1.0 - smoothstep(0.05, 0.5, above))) * low * (1.0 - 0.6 * pebble);
  c = mix(c, mix(vec3(0.03, 0.058, 0.018), vec3(0.075, 0.115, 0.03), fine.r), mossy * 0.92);
  relief = mix(relief, fine.r * 0.03 + 0.02, mossy * 0.8);
  // damp where it meets the ground, and the ground creeping up its foot
  float foot = above + (fine.r - 0.5) * 0.06;
  c *= 1.0 - 0.34 * (1.0 - smoothstep(0.0, 0.1, foot));
  float creep = 1.0 - smoothstep(0.0, 0.07, above + (fine.g - 0.5) * 0.06);
  c = mix(c, soil * 0.9, creep * 0.85);
  // snow on what is not steep, above the snow line (as the ground has it)
  float patchy = vnoise(pos.xz * 0.011 + 40.0);
  float snow = smoothstep(405.0, 460.0, pos.y + 55.0 * (patchy - 0.5)) * smoothstep(0.4, 0.75, n.y + (fine.r - 0.5) * 0.2);
  c = mix(c, vec3(0.55, 0.57, 0.6) * (0.9 + 0.1 * mid.r), snow);
  relief = mix(relief, mid.r * 0.02, snow);
  nb = n;
  if(near > 0.0){
    nb = normalize(mix(n, embossed(n, pos, relief * 1.6), near));
  }
  // less of the sky at the foot and underneath
  sky = (0.62 + 0.38 * smoothstep(0.0, 0.22, above)) * (0.6 + 0.4 * smoothstep(-0.7, 0.2, n.y));
  return c;
}

// the light on a rock: the sun, the sky, and what the sunlit ground
// around it (of the color soil) throws back at its sides
vec3 stoneLight(vec3 albedo, vec3 pos, vec3 n, vec3 nb, float sky, vec3 soil){
  float shadow = sunShadow(pos, n);
  // (a face turned from the sun is not lit through its bumps)
  float ndl = max(dot(nb, sunDir), 0.0) * smoothstep(-0.05, 0.1, dot(n, sunDir));
  // (how much of the sky the land leaves open here, and whether the
  // mountains leave the sun: as the ground under the rock has them)
  vec2 open = vec2(1.0);
  if(landInfo.w > 0.5){
    open = texture(landLight, (pos.xz + landInfo.x) * landInfo.y + 0.5 * landInfo.z).ba;
  }
  vec3 bounce = soil * sunColor * max(sunDir.y, 0.0) * open.y * cloudShadow(pos) * (0.62 - 0.38 * nb.y);
  return albedo * (sunColor * ndl * shadow + ambientLight(nb) * sky * (0.35 + 0.65 * open.x) + bounce);
}
"""

local vertex = concat(wind, """
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec2 vertexTexCoord2;
in vec3 vertexNormal;
in vec4 vertexColor;
in vec4 vertexTangent;
uniform vec4 lod;         // thinning in from .. to, thinning out from .. to (meters)
out vec3 worldPos;
out vec3 normal;
out vec2 uv;
out vec4 paint;           // the vertex's color, what it is made of
out vec3 more;            // how open to the sky (a rock: how far from its face's border), thinning in, thinning out
out vec3 soil;            // a rock: the color of the ground it lies on

void main(){
  vec2 fades = level(vertexTexCoord2, lod);
  worldPos = vertexPosition;
  normal = vertexNormal;
  uv = vertexTexCoord;
  paint = vertexTangent;
  more = vec3(vertexColor.b, fades);
  soil = vertexColor.rga * vertexColor.rga;
  if(fades.x <= 0.0 || fades.y <= 0.0){
    gl_Position = vec4(0.0, 0.0, -2.0, 1.0);
    return;
  }
  if(vertexTangent.a < 2.5){
    worldPos = blown(vertexPosition, vertexTexCoord2, vertexColor.r, vertexColor.g, vertexColor.a * 6.2831);
  }
  gl_Position = viewProj * vec4(worldPos, 1.0);
}
""")

local fragment = concat(stone, """
in vec3 worldPos;
in vec3 normal;
in vec2 uv;
in vec4 paint;
in vec3 more;
in vec3 soil;
uniform sampler2D atlas;
out vec4 finalColor;

// noise that comes around: the same at x and x + period
float ringNoise(vec2 p, float period){
  vec2 i = floor(p);
  vec2 f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  float x0 = mod(i.x, period);
  float x1 = mod(i.x + 1.0, period);
  return mix(mix(hash12(vec2(x0, i.y)), hash12(vec2(x1, i.y)), f.x),
    mix(hash12(vec2(x0, i.y + 1.0)), hash12(vec2(x1, i.y + 1.0)), f.x), f.y);
}

// cells that come around: x how far from the cell's border (0 on it), y
// a number of the cell's own
vec2 ringCells(vec2 p, float period){
  vec2 ip = floor(p);
  vec2 fp = fract(p);
  float d1 = 9.0;
  float d2 = 9.0;
  float id = 0.0;
  for(int j = -1; j <= 1; j++){
    for(int i = -1; i <= 1; i++){
      vec2 g = vec2(float(i), float(j));
      vec2 cell = vec2(mod(ip.x + g.x, period), ip.y + g.y);
      vec2 o = vec2(hash12(cell), hash12(cell + 17.3));
      vec2 r = g + 0.15 + 0.7 * o - fp;
      float d = dot(r, r);
      if(d < d1){
        d2 = d1;
        d1 = d;
        id = o.x;
      } else if(d < d2){
        d2 = d;
      }
    }
  }
  return vec2(sqrt(d2) - sqrt(d1), id);
}

// bark: its color and its relief (m) at a place on a trunk (u: around,
// in turns; v: along, in meters); kind: which bark (render/flora_mesh)
vec3 bark(vec3 base, float kind, vec2 at, out float relief){
  float u = at.x;
  float v = at.y;
  float grain = ringNoise(vec2(u * 46.0, v * 14.0), 46.0);
  vec3 c;
  if(kind < 0.075){
    // a spruce's, a fir's: small scales
    vec2 s = ringCells(vec2(u * 21.0, v * 12.0), 21.0);
    vec2 big = ringCells(vec2(u * 6.0, v * 2.2), 6.0);
    float gap = 1.0 - smoothstep(0.0, 0.2, s.x);
    c = base * (0.7 + 0.6 * s.y) * (1.0 - 0.55 * gap) * (0.85 + 0.3 * grain) * (0.82 + 0.36 * big.y);
    relief = s.y * 0.005 - gap * 0.006 + big.y * 0.004;
  } else if(kind < 0.225){
    // a pine's: plates, greyer in the middle, with deep dark seams
    vec2 s = ringCells(vec2(u * 9.0, v * 4.6), 9.0);
    vec2 flakes = ringCells(vec2(u * 26.0, v * 17.0), 26.0);
    float gap = 1.0 - smoothstep(0.0, 0.16, s.x);
    c = mix(base, base * vec3(0.78, 0.86, 0.95), smoothstep(0.2, 0.7, s.x) * 0.6) * (0.8 + 0.4 * s.y);
    c *= (1.0 - 0.72 * gap) * (0.82 + 0.36 * flakes.y) * (1.0 - 0.3 * (1.0 - smoothstep(0.0, 0.1, flakes.x)));
    relief = smoothstep(0.0, 0.3, s.x) * 0.012 + flakes.y * 0.003 - gap * 0.006;
  } else if(kind < 0.375){
    // an oak's: long narrow ridges with deep furrows between
    vec2 s = ringCells(vec2(u * 19.0, v * 4.6), 19.0);
    float ridge = smoothstep(0.0, 0.4, s.x);
    c = base * (0.45 + 0.75 * ridge) * (0.8 + 0.4 * grain) * (0.85 + 0.3 * s.y);
    relief = ridge * 0.014 + grain * 0.003;
  } else if(kind < 0.475){
    // bare wood: the grain along it, long cracks, weathered grey
    float lines = ringNoise(vec2(u * 60.0, v * 1.3), 60.0);
    vec2 s = ringCells(vec2(u * 6.0, v * 0.45), 6.0);
    float crack = 1.0 - smoothstep(0.0, 0.07, s.x);
    c = base * (0.72 + 0.56 * lines) * (1.0 - 0.7 * crack) * (0.9 + 0.2 * s.y);
    relief = lines * 0.004 - crack * 0.014;
  } else if(kind < 0.55){
    // a cut end: the rings around its middle, and cracks from it
    vec2 d = at - 0.5;
    float r = length(d) * 2.0;
    float a = atan(d.y, d.x);
    float ring = 0.5 + 0.5 * sin(r * 42.0 + 2.5 * vnoise(d * 9.0));
    float split = 1.0 - smoothstep(0.0, 0.06, abs(fract(a * 1.11 + 0.3 * vnoise(vec2(r * 3.0, 2.0))) - 0.5) * 2.0 + 0.5 * (1.0 - r));
    c = base * (0.78 + 0.34 * ring) * (1.0 - 0.6 * split) * mix(0.8, 1.05, r);
    relief = ring * 0.002 - split * 0.006;
  } else {
    // a birch's: white, in faint bands, with dark dashes across it, black
    // scars where branches were and rough black bark at its foot
    c = base * (0.9 + 0.2 * ringNoise(vec2(u * 3.0, v * 21.0), 3.0)) * (0.92 + 0.16 * grain);
    vec2 q = vec2(u * 8.0, v * 15.0);
    vec2 iq = floor(q);
    vec2 fq = fract(q) - 0.5;
    vec2 cell = vec2(mod(iq.x, 8.0), iq.y);
    float h1 = hash12(cell);
    float h2 = hash12(cell + 31.7);
    float dash = step(0.5, h1) * (1.0 - smoothstep(0.03, 0.08, abs(fq.y + (h2 - 0.5) * 0.5))) *
      (1.0 - smoothstep(0.1 + 0.28 * h2, 0.16 + 0.3 * h2, abs(fq.x)));
    c = mix(c, vec3(0.05, 0.045, 0.04), dash * 0.85);
    float scar = smoothstep(0.64, 0.7, ringNoise(vec2(u * 3.0, v * 1.2 + 3.0), 3.0) + 0.12 * grain);
    float old = (1.0 - smoothstep(0.5, 1.9, v + 0.7 * ringNoise(vec2(u * 4.0, 1.5), 4.0))) *
      smoothstep(0.25, 0.5, ringCells(vec2(u * 7.0, v * 2.2), 7.0).x + 0.3 * grain);
    scar = max(scar, old);
    c = mix(c, vec3(0.035, 0.03, 0.027) * (0.6 + 0.9 * grain), scar);
    relief = scar * (0.006 + 0.01 * grain) - dash * 0.003;
  }
  return c;
}

void main(){
  // where two levels of detail meet, each draws the pixels the other
  // leaves out
  float h = hash12(floor(gl_FragCoord.xy));
  if(h > more.z || 1.0 - h > more.y){
    discard;
  }
  float made = paint.a;
  vec3 n = normalize(normal);
  vec3 albedo;
  float through = 0.0;
  float open = more.x;
  if(made > 2.5){
    // rock: nothing of it is cut out
    if(depthPass > 0.5){
      finalColor = packDepth(gl_FragCoord.z);
      return;
    }
    vec3 nb;
    float sky;
    albedo = stone(worldPos, n, normalize(paint.rgb), uv.x, uv.y, soil, more.x * 0.4, step(3.5, made), nb, sky);
    finalColor = vec4(finish(stoneLight(albedo, worldPos, n, nb, sky, soil), worldPos), 1.0);
    return;
  }
  if(made > 0.75 && made < 1.5){
    // foliage: cut out of the texture
    vec4 tex = texture(atlas, uv);
    float away = clamp(distance(worldPos, eye) / 80.0, 0.0, 1.0);
    if(tex.a < mix(0.42, 0.18, away)){
      discard;
    }
    albedo = tex.rgb * tex.rgb * paint.rgb;
    // a leaf seen from the side that faces into the crown: its paler
    // underside
    vec3 face = cross(dFdx(worldPos), dFdy(worldPos));
    if(dot(face, eye - worldPos) < 0.0){
      face = -face;
    }
    float under = step(dot(face, n), 0.0);
    albedo = mix(albedo, albedo * vec3(1.12, 1.16, 1.3) + vec3(0.004, 0.006, 0.004), under * 0.55);
    through = 0.55;
  } else if(made < 0.75){
    if(depthPass > 0.5){
      finalColor = packDepth(gl_FragCoord.z);
      return;
    }
    // bark, flat from afar
    float dist = distance(worldPos, eye);
    float detail = 1.0 - smoothstep(30.0, 70.0, dist);
    albedo = paint.rgb;
    if(detail > 0.0){
      float relief;
      albedo = mix(albedo, bark(paint.rgb, made, uv, relief), detail);
      n = normalize(mix(n, embossed(n, worldPos, relief * 1.5), detail * (1.0 - smoothstep(12.0, 34.0, dist))));
    }
  } else {
    // a crown as one shape: one color, mottled
    albedo = paint.rgb * (0.82 + 0.36 * vnoise(worldPos.xz * 0.9 + worldPos.y * 0.6));
    through = 0.3;
  }
  if(depthPass > 0.5){
    finalColor = packDepth(gl_FragCoord.z);
    return;
  }
  float shadow = sunShadow(worldPos, n);
  vec3 color = through > 0.0 ? shadeLeaf(albedo, n, worldPos, shadow, through) : shade(albedo, n, worldPos, shadow);
  if(through > 0.0){
    // light goes from leaf to leaf: a crown's shade is green, not black,
    // and its sunny side not as bright as a wall's
    color = color * 0.82 + albedo * ambientLight(n) * 1.5;
  }
  // inside a crown little of the sky arrives
  color *= 0.45 + 0.55 * open;
  finalColor = vec4(finish(color, worldPos), 1.0);
}
""")

// the far level: a vertex is its place, its normal, where its plant
// stands and one color (a rock: see render/flora_bake.kernel)
local far_vertex = concat(wind, """
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform vec4 lod;
out vec3 worldPos;
out vec3 normal;
out vec4 paint;
out vec2 more;

void main(){
  vec2 fades = level(vertexTexCoord, lod);
  worldPos = vertexPosition;
  normal = vertexNormal;
  paint = vertexColor;
  more = fades;
  if(fades.x <= 0.0 || fades.y <= 0.0){
    gl_Position = vec4(0.0, 0.0, -2.0, 1.0);
    return;
  }
  if(vertexColor.a < 0.999){
    worldPos = blown(vertexPosition, vertexTexCoord, vertexColor.a, 0.0, 0.0);
  }
  gl_Position = viewProj * vec4(worldPos, 1.0);
}
""")

local far_fragment = concat(stone, """
in vec3 worldPos;
in vec3 normal;
in vec4 paint;
in vec2 more;
out vec4 finalColor;

void main(){
  float h = hash12(floor(gl_FragCoord.xy));
  if(h > more.y || 1.0 - h > more.x){
    discard;
  }
  if(depthPass > 0.5){
    finalColor = packDepth(gl_FragCoord.z);
    return;
  }
  vec3 n = normalize(normal);
  float shadow = sunShadow(worldPos, n);
  if(paint.a > 0.999){
    // a rock, as the near level draws it
    vec3 nb;
    float sky;
    vec3 rock = stone(worldPos, n, vec3(0.0, 1.0, 0.0), paint.r, 9.0, vec3(0.1), 1.0, 1.0, nb, sky);
    finalColor = vec4(finish(stoneLight(rock, worldPos, n, nb, sky, vec3(0.12, 0.12, 0.08)), worldPos), 1.0);
    return;
  }
  // (the color was stored as its root)
  vec3 albedo = paint.rgb * paint.rgb * (0.82 + 0.36 * vnoise(worldPos.xz * 0.9 + worldPos.y * 0.6));
  vec3 color = paint.a > 0.0 ? shadeLeaf(albedo, n, worldPos, shadow, 0.3) : shade(albedo, n, worldPos, shadow);
  if(paint.a > 0.0){
    color = color * 0.82 + albedo * ambientLight(n) * 1.5;
  }
  finalColor = vec4(finish(color, worldPos), 1.0);
}
""")

local state = {}

// ------------------------------------------------------------ the texture

local SIZE = 1024
local TILE = 512

// a twig with its needles, for the frond
local func twig(image, rng, x0, y0, x1, y1, tips){
  local dx = x1 - x0
  local dy = y1 - y0
  local long = math.sqrt(dx * dx + dy * dy)
  if(long < 4){
    return
  }
  paint.stroke(image, SIZE, SIZE, x0, y0, x1, y1, 3.4, 1.4, 66, 50, 32)
  dx = dx / long
  dy = dy / long
  local steps = to_int(long / 6.2)
  for(local i = 1; i <= steps; i = i + 1){
    local s = i / steps
    local px = x0 + dx * long * s
    local py = y0 + dy * long * s
    local needle = (19 - 7 * s) * rng:range(0.8, 1.15)
    // lighter toward the end: this year's growth
    local k = s * tips + rng:range(-0.12, 0.12)
    local r = 34 + 34 * k
    local g = 66 + 40 * k
    local bl = 36 + 14 * k
    for(let local side in values({-1, 1})){
      local a = side * rng:range(0.85, 1.15)
      local nx = dx * math.cos(a) - dy * math.sin(a)
      local ny = dx * math.sin(a) + dy * math.cos(a)
      paint.stroke(image, SIZE, SIZE, px, py, px + nx * needle, py + ny * needle, 3.7, 1.3, r, g, bl)
    }
  }
}

// the foliage texture: four tiles, each with a margin of nothing around it
local func paint_atlas(){
  local image = kernel.uint8:array(SIZE * SIZE * 4)
  paint.fill(image, SIZE, SIZE, 52, 88, 42)
  local rng = vec.random(2024)
  // a spruce's frond: the stem up the middle from the bottom, twigs to
  // both sides, needles on all of them
  local cx = 256
  paint.stroke(image, SIZE, SIZE, cx, 498, cx, 16, 6, 2.2, 60, 44, 28)
  local pairs = 17
  for(local i = 0; i < pairs; i = i + 1){
    local t = (i + 0.5) / pairs
    local y = 498 - 478 * t
    local long = 226 * math.min(1, t * 5 + 0.42) * (1 - t) ^ (0.72)
    local a = (64 - 28 * t) * math.pi / 180
    for(let local side in values({-1, 1})){
      local l = long * rng:range(0.86, 1.06)
      twig(image, rng, cx, y, cx + side * math.sin(a) * l, y - math.cos(a) * l, 1)
    }
  }
  twig(image, rng, cx, 498, cx, 16, 0.6)
  // a pine's needles: tufts of long needles, one over the other
  local ox = TILE
  for(let local c in values({{256, 250, 1.0}, {142, 322, 0.66}, {372, 310, 0.7}, {250, 392, 0.6}})){
    local count = to_int(96 * c[2]) + 20
    for(local i = 0; i < count; i = i + 1){
      local a = rng:range(0, 2 * math.pi)
      local long = 198 * c[2] * rng:range(0.72, 1.0)
      local bend = rng:range(-0.16, 0.16)
      local mx = ox + c[0] + math.cos(a) * long * 0.5
      local my = c[1] + math.sin(a) * long * 0.5
      local ex = ox + c[0] + math.cos(a + bend) * long
      local ey = c[1] + math.sin(a + bend) * long
      local k = rng:next()
      paint.stroke(image, SIZE, SIZE, ox + c[0], c[1], mx, my, 4.2, 3.2, 50 + 22 * k, 86 + 24 * k, 40 + 10 * k)
      paint.stroke(image, SIZE, SIZE, mx, my, ex, ey, 3.2, 1.3, 58 + 28 * k, 96 + 28 * k, 42 + 12 * k)
    }
    paint.stroke(image, SIZE, SIZE, ox + c[0] - 6, c[1] + 4, ox + c[0] + 6, c[1] - 4, 9, 7, 70, 50, 32)
  }
  // a spray of small leaves hanging from a twig (a birch's)
  local oy = TILE
  local func spray(x0, y0, x1, y1, leaves, big){
    local last_x = x0
    local last_y = y0
    for(local i = 1; i <= leaves; i = i + 1){
      local s = i / leaves
      local px = x0 + (x1 - x0) * s + 16 * math.sin(s * 9 + x0)
      local py = y0 + (y1 - y0) * s
      paint.stroke(image, SIZE, SIZE, last_x, last_y, px, py, 3.2, 2.2, 74, 60, 44)
      local down = math.atan2(py - last_y, px - last_x)
      local side = if(i % 2 == 0){ 1 } else { -1 }
      local a = down + side * rng:range(0.65, 1.15)
      local k = rng:next()
      paint.leaf(image, SIZE, SIZE, px, py, a, big * rng:range(0.85, 1.12), big * 0.62 * rng:range(0.9, 1.1), 0,
        92 + 44 * k, 136 + 26 * k, 38 + 14 * k)
      last_x = px
      last_y = py
    }
  }
  spray(256, oy + 14, 250, oy + 404, 24, 80)
  spray(250, oy + 110, 118, oy + 372, 9, 72)
  spray(262, oy + 170, 396, oy + 384, 8, 72)
  spray(256, oy + 40, 378, oy + 240, 7, 70)
  spray(252, oy + 60, 132, oy + 232, 6, 70)
  // a cluster of broad leaves around a twig's end (an oak's)
  for(local i = 0; i < 34; i = i + 1){
    local a = rng:range(0, 2 * math.pi)
    local r = rng:range(6, 78)
    local px = ox + 256 + math.cos(a) * r
    local py = oy + 256 + math.sin(a) * r
    local k = rng:next()
    paint.leaf(image, SIZE, SIZE, px, py, a + rng:range(-0.5, 0.5), rng:range(124, 150), rng:range(76, 96), 3.2,
      48 + 34 * k, 92 + 30 * k, 30 + 14 * k)
  }
  local texture = rl.texture.load_from_image({
    data: image, width: SIZE, height: SIZE, mipmaps: 1,
    format: rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
  })
  texture:gen_mipmaps()
  texture.filter = rl.TEXTURE_FILTER_TRILINEAR
  texture.wrap = rl.TEXTURE_WRAP_CLAMP
  return {texture: texture, image: image}
}

// ------------------------------------------------------------ baking

// the most vertices a mesh may have (its indices are 16 bits wide)
local ROOM = 65000
// what a square's levels keep on it: the meshes, where the baking
// stands, whether it is done
local LEVELS = {
  near: {meshes: "near", at: "near_at", done: "near_done"},
  mid: {meshes: "mid", at: "mid_at", done: "mid_done"},
}

local identity = {
  m0: 1, m1: 0, m2: 0, m3: 0, m4: 0, m5: 1, m6: 0, m7: 0,
  m8: 0, m9: 0, m10: 1, m11: 0, m12: 0, m13: 0, m14: 0, m15: 1,
}

// what a level bakes of a kind: its shapes with the sizes they are for
local func plan(k, level){
  local kind = plants.KINDS[k]
  local made = state.shapes[k]
  if(made == null){
    made = shapes.shapes(k)
    state.shapes[k] = made
  }
  if(kind.group == "rock"){
    if(level == "near"){
      return {{made.near, m.SMALL, 1.0e9}, {made.small, 0, m.SMALL}}
    }
    if(level == "mid"){
      return {{made.mid, m.MID_ROCK, 1.0e9}}
    }
    return {{made.far, m.FAR_ROCK, 1.0e9}}
  }
  local shape = made[level]
  if(shape == null){
    return {}
  }
  return {{shape, 0, 1.0e9}}
}

// what was baked so far as a mesh ready to draw
local func flush(level, v, i, out){
  if(v == 0){
    return
  }
  local s = state.scratch
  local model = null
  if(level == "far"){
    model = rl.mesh({
      vertices: s.pos:slice(0, v * 3), normals: s.nrm:slice(0, v * 3), texcoords: s.at:slice(0, v * 2),
      colors: s.col:slice(0, v * 4), indices: s.idx:slice(0, i),
    }):to_model()
    local material = shaders.use(model, state.far_shader)
    material.maps[rl.MATERIAL_MAP_METALNESS].texture = state.stone
  } else {
    model = rl.mesh({
      vertices: s.pos:slice(0, v * 3), normals: s.nrm:slice(0, v * 3), texcoords: s.uv:slice(0, v * 2),
      texcoords2: s.at:slice(0, v * 2), colors: s.col:slice(0, v * 4), tangents: s.tan:slice(0, v * 4),
      indices: s.idx:slice(0, i),
    }):to_model()
    local material = shaders.use(model, state.shader)
    material.maps[rl.MATERIAL_MAP_ALBEDO].texture = state.atlas
    material.maps[rl.MATERIAL_MAP_METALNESS].texture = state.stone
  }
  append(out, {model: model, mesh: model.meshes[0], material: model.materials[0], vertices: v, triangles: to_int(i / 3)})
  state.stats.baked_vertices = state.stats.baked_vertices + v
}

// bake_run(chunks, level, cursor, room, out) -> bool: the plants of some
// squares at a level of detail baked into one mesh of at most room
// vertices, appended to out, from where the cursor ({c, k, item, first}:
// the square, the kind, which of its shapes, the record) stands; the
// cursor moves on, and true comes back once everything is baked
local EMPTY = {}

local func bake_run(chunks, level, cursor, room, out){
  local s = state.scratch
  local v = 0
  local i = 0
  local kinds = len(plants.KINDS)
  for(cursor.c < len(chunks)){
    local chunk = chunks[cursor.c]
    for(cursor.k < kinds){
      local from = chunk.starts[cursor.k]
      local n = chunk.starts[cursor.k + 1] - from
      local items = if(n > 0){ plan(cursor.k, level) } else { EMPTY }
      for(cursor.item < len(items)){
        local item = items[cursor.item]
        local shape = item[0]
        local first = from + cursor.first
        local left = n - cursor.first
        local done = 0
        if(level == "far"){
          done = baker.bake_far(s.pos, s.nrm, s.at, s.col, s.idx, v, i, room, shape.pos, shape.nrm, shape.col,
            shape.tan, shape.idx, shape.vertices, shape.indices, chunk.data, first, left, item[1], item[2])
        } else {
          local g = state.ground
          done = baker.bake(s.pos, s.nrm, s.uv, s.at, s.col, s.tan, s.idx, v, i, room, shape.pos, shape.nrm,
            shape.uv, shape.col, shape.tan, shape.idx, shape.vertices, shape.indices, chunk.data, first, left,
            item[1], item[2], g.heights, g.n, g.spacing, g.origin, g.cover, g.cover2, g.cover_n, g.cover_spacing)
        }
        local wrote = baker.written()
        v = v + wrote * shape.vertices
        i = i + wrote * shape.indices
        if(done < left){
          // the mesh is full: the rest goes into the next
          cursor.first = cursor.first + done
          flush(level, v, i, out)
          return false
        }
        cursor.first = 0
        cursor.item = cursor.item + 1
      }
      cursor.item = 0
      cursor.k = cursor.k + 1
    }
    cursor.k = 0
    cursor.c = cursor.c + 1
  }
  flush(level, v, i, out)
  return true
}

local func unload_meshes(list){
  for(let local item in values(list)){
    state.stats.baked_vertices = state.stats.baked_vertices - item.vertices
    item.model:unload()
  }
}

// ------------------------------------------------------------ init

// init(land: terrain.Terrain, p: plants.Plants): the texture, the
// shaders, the far level of the whole land; returns [stats]
func m.init(land, p){
  m.unload()
  local started = time.clock()
  state.plants = p
  state.shader = shaders.load(vertex, fragment)
  state.shader.locs[rl.SHADER_LOC_MAP_ALBEDO] = state.shader:location("atlas")
  state.shader.locs[rl.SHADER_LOC_MAP_METALNESS] = state.shader:location("stoneMap")
  state.far_shader = shaders.load(far_vertex, far_fragment)
  state.far_shader.locs[rl.SHADER_LOC_MAP_METALNESS] = state.far_shader:location("stoneMap")
  // the land's own stone: the texture the ground's rock is drawn from
  // (render/terrain's, when it has one; else one made the same way)
  local shared = ground.textures()
  if(shared != null and shared.detail != null){
    state.stone = shared.detail
    state.stone_own = false
  } else {
    local detail = terrain.detail(512, land.seed)
    state.stone = rl.texture.load_from_image({
      data: detail.data, width: detail.size, height: detail.size, mipmaps: 1,
      format: rl.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8,
    })
    state.stone:gen_mipmaps()
    state.stone.filter = rl.TEXTURE_FILTER_TRILINEAR
    state.stone.wrap = rl.TEXTURE_WRAP_REPEAT
    state.stone_own = true
  }
  // the ground under a rock: its heights (the finest there are) and what
  // covers it
  local heights = land.fine or land
  state.ground = {
    heights: heights.heights, n: heights.n, spacing: heights.spacing, origin: -land.half,
    cover: land.cover or kernel.uint8:array(4), cover2: land.cover2 or kernel.uint8:array(4),
    cover_n: if(land.cover != null){ land.n } else { 0 }, cover_spacing: land.spacing,
  }
  local painted = paint_atlas()
  state.atlas = painted.texture
  state.image = painted.image
  // what each kind's foliage looks like from far off: its tile's mean
  // color, tinted, and darker for the shade inside a crown
  local mean = kernel.float:array(4)
  for(let local e in entries(shapes.TINTS)){
    local tile = e[1].tile
    paint.mean(state.image, SIZE, (tile % 2) * TILE, to_int(tile / 2) * TILE, TILE, mean)
    local far = shapes.FAR[e[0]]
    // (a bush as a blob stands out of the grass: a little darker still)
    local shade = if(e[0] == "bush" or e[0] == "shrub"){ 0.56 } else { 0.78 }
    for(local c = 0; c < 3; c = c + 1){
      far[c] = mean[c] * e[1].tint[c] * shade
    }
  }
  state.shapes = {}
  state.scratch = {
    pos: kernel.float:array(ROOM * 3), nrm: kernel.float:array(ROOM * 3), uv: kernel.float:array(ROOM * 2),
    at: kernel.float:array(ROOM * 2), col: kernel.uint8:array(ROOM * 4), tan: kernel.float:array(ROOM * 4),
    idx: kernel.uint16:array(ROOM * 6),
  }
  state.stats = {
    draws: 0, triangles: 0, ms: 0, shadow_ms: 0, shadow_draws: 0, baked: 0, baked_vertices: 0, init_ms: 0,
    near: 0, mid: 0, bake_ms: 0, bake_most: 0,
  }
  // the squares: where each is, and what is baked of it
  local half = p.size / 2
  for(let local chunk in values(p.chunks)){
    chunk.cx_m = chunk.x0 + half
    chunk.cz_m = chunk.z0 + half
    chunk.cy_m = (chunk.low + chunk.high) / 2 + 5
    chunk.radius = p.size * 0.7072 + (chunk.high - chunk.low) / 2 + 13
    chunk.near = null
    chunk.near_done = false
    chunk.mid = null
    chunk.mid_done = false
  }
  state.near = {}     // the squares with a near level baked, by index
  state.mid = {}
  // the far level: the squares in blocks of four by four
  local supers = {}
  local block = 4
  local side = to_int(math.ceil(p.side / block))
  for(local sz = 0; sz < side; sz = sz + 1){
    for(local sx = 0; sx < side; sx = sx + 1){
      local chunks = {}
      local low = 1.0e9
      local high = -1.0e9
      for(local cz = sz * block; cz < math.min(p.side, (sz + 1) * block); cz = cz + 1){
        for(local cx = sx * block; cx < math.min(p.side, (sx + 1) * block); cx = cx + 1){
          local chunk = p.chunks[cz * p.side + cx]
          if(chunk.count > 0){
            append(chunks, chunk)
            low = math.min(low, chunk.low)
            high = math.max(high, chunk.high)
          }
        }
      }
      local meshes = {}
      local cursor = {c: 0, k: 0, item: 0, first: 0}
      for(not bake_run(chunks, "far", cursor, ROOM, meshes)){
      }
      if(len(meshes) > 0){
        local reach = block * p.size
        append(supers, {
          meshes: meshes,
          x: p.origin + (sx + 0.5) * reach, y: (low + high) / 2 + 6, z: p.origin + (sz + 0.5) * reach,
          radius: reach * 0.7072 + (high - low) / 2 + 16,
        })
      }
    }
  }
  state.supers = supers
  state.stats.far_vertices = state.stats.baked_vertices
  state.stats.init_ms = time.clock() - started
  return state.stats
}

// ------------------------------------------------------------ streaming

// the squares of a list of {chunk, d}, the nearest first
local func nearest(list){
  local best = 0
  for(local i = 1; i < len(list); i = i + 1){
    if(list[i].d < list[best].d){
      best = i
    }
  }
  local item = list[best]
  list[best] = list[len(list) - 1]
  remove(list, len(list) - 1)
  return item.chunk
}

// the next part of a square's level baked
local func bake_part(chunk, level){
  local keys = LEVELS[level]
  if(chunk[keys.meshes] == null){
    chunk[keys.meshes] = {}
    chunk[keys.at] = {c: 0, k: 0, item: 0, first: 0}
    state[level][chunk.index] = chunk
  }
  chunk[keys.done] = bake_run({chunk}, level, chunk[keys.at], m.PART, chunk[keys.meshes])
  state.stats.baked = state.stats.baked + 1
}

// bake_some(want_near, want_mid, limit) -> ms: parts of the squares that
// are missing a level, the nearest first and the near level before the
// mid one, until limit ms are spent (one part at least); the time it took
local func bake_some(want_near, want_mid, limit){
  local from = time.clock()
  local first = true
  for(len(want_near) > 0 and (first or time.clock() - from < limit)){
    local chunk = nearest(want_near)
    for(not chunk.near_done and (first or time.clock() - from < limit)){
      bake_part(chunk, "near")
      first = false
    }
  }
  for(len(want_mid) > 0 and (first or time.clock() - from < limit)){
    local chunk = nearest(want_mid)
    for(not chunk.mid_done and (first or time.clock() - from < limit)){
      bake_part(chunk, "mid")
      first = false
    }
  }
  return time.clock() - from
}

// how far from the eye a square's near and mid levels are wanted, and
// how far it is let go of (distances to the square's middle)
local func reaches(){
  local side = state.plants.size * 0.7072
  local near_out = m.NEAR[3] * 1.07
  local mid_out = m.MID[3] * 1.07
  return {
    side: side, near_out: near_out, mid_out: mid_out, mid_in: m.MID[0] * 0.93,
    near_want: near_out + 20 + side, mid_want: mid_out + 24 + side,
    near_drop: near_out + 70 + side, mid_drop: mid_out + 110 + side,
  }
}

// prepare(position: Vec3): bakes everything around a place at once (a
// few hundred ms), so that the first frames there do not have to: for
// the start, and for when the truck is set down somewhere else
func m.prepare(position){
  if(state.shader == null){
    return
  }
  local p = state.plants
  local r = reaches()
  local above = math.max(0, position.y - terrain.height_at(p.land, position.x, position.z) - 12)
  local want_near = {}
  local want_mid = {}
  for(let local chunk in values(plants.near(p, position.x, position.z, r.mid_want))){
    if(chunk.count == 0){
      continue
    }
    local ex = chunk.cx_m - position.x
    local ez = chunk.cz_m - position.z
    local d = math.sqrt(ex * ex + ez * ez + above * above)
    if(d < r.near_want and not chunk.near_done){
      append(want_near, {chunk: chunk, d: d})
    }
    if(d < r.mid_want and not chunk.mid_done){
      append(want_mid, {chunk: chunk, d: d})
    }
  }
  bake_some(want_near, want_mid, 1.0e9)
}

// ------------------------------------------------------------ drawing

local func draw_meshes(list, stats){
  for(let local item in values(list)){
    rl.draw.mesh(item.mesh, item.material, identity)
    stats.draws = stats.draws + 1
    stats.triangles = stats.triangles + item.triangles
  }
}

local func level_lod(level){
  if(m.only != null){
    return {0, 0, 100000, 100001}
  }
  return level
}

// draw(view: scene.View): everything that stands on the land, as the
// view sees it; with view.depth_pass, what is near enough to cast a
// shadow into the sun's shadow map (around view.center, view.reach wide)
func m.draw(view){
  if(state.shader == null){
    return
  }
  local from = time.clock()
  local p = state.plants
  local stats = state.stats
  local eye = view.eye
  local shadows = view.depth_pass == true
  local counted = {draws: 0, triangles: 0}
  shaders.apply(state.shader, view)
  // from high up everything is far, also what is straight below
  local above = math.max(0, eye.y - terrain.height_at(p.land, eye.x, eye.z) - 12)
  state.shader:set("eyeAbove", above * 1.0)

  // the squares around the eye: which to draw, which to bake
  local r = reaches()
  local near_out = r.near_out
  local mid_in = r.mid_in
  local mid_out = r.mid_out
  local reach = mid_out + 24
  local center = eye
  local within = 1.0e9
  if(shadows){
    // a tree throws its shadow a few of its heights: the squares around
    // the shadow map's middle, whichever way the eye looks
    center = view.center or view.focus or eye
    within = (view.reach or 60) + 42
    reach = within
  }
  local f = view.forward
  local th = math.tan(view.fovy / 2) * math.sqrt(1 + view.aspect * view.aspect)
  local sec = math.sqrt(1 + th * th)
  local cx0 = math.max(0, to_int(math.floor((center.x - reach - p.origin) / p.size)) - 1)
  local cx1 = math.min(p.side - 1, to_int(math.floor((center.x + reach - p.origin) / p.size)) + 1)
  local cz0 = math.max(0, to_int(math.floor((center.z - reach - p.origin) / p.size)) - 1)
  local cz1 = math.min(p.side - 1, to_int(math.floor((center.z + reach - p.origin) / p.size)) + 1)
  local near_list = {}
  local mid_list = {}
  local want_near = {}
  local want_mid = {}
  local side = p.size * 0.7072
  for(local cz = cz0; cz <= cz1; cz = cz + 1){
    for(local cx = cx0; cx <= cx1; cx = cx + 1){
      local chunk = p.chunks[cz * p.side + cx]
      if(chunk.count == 0){
        continue
      }
      local ex = chunk.cx_m - eye.x
      local ez = chunk.cz_m - eye.z
      local d = math.sqrt(ex * ex + ez * ez + above * above)
      if(not shadows){
        // what is missing here
        if(d < r.near_want and not chunk.near_done){
          append(want_near, {chunk: chunk, d: d})
        }
        if(d < r.mid_want and not chunk.mid_done){
          append(want_mid, {chunk: chunk, d: d})
        }
      }
      local seen = true
      if(shadows){
        local qx = chunk.cx_m - center.x
        local qz = chunk.cz_m - center.z
        seen = qx * qx + qz * qz < (within + side) * (within + side)
      } else {
        local ey = chunk.cy_m - eye.y
        local along = ex * f.x + ey * f.y + ez * f.z
        local round = chunk.radius
        if(along < -round){
          seen = false
        } else {
          local across = ex * ex + ey * ey + ez * ez - along * along
          local limit = math.max(along, 0) * th + round * sec
          seen = across <= limit * limit
        }
      }
      if(seen){
        if(chunk.near != null and d < near_out + side){
          append(near_list, chunk.near)
        }
        if(chunk.mid != null and d < mid_out + side and d > mid_in - side){
          append(mid_list, chunk.mid)
        }
      }
    }
  }

  // bake what is missing, and let go of what the eye has left behind
  if(not shadows){
    local many = len(want_near) + len(want_mid) > 40
    stats.bake_ms = bake_some(want_near, want_mid, if(many){ m.BAKE_MS_MANY } else { m.BAKE_MS })
    if(not many and stats.bake_ms > stats.bake_most){
      stats.bake_most = stats.bake_ms
    }
    for(let local chunk in values({...state.near})){
      local ex = chunk.cx_m - eye.x
      local ez = chunk.cz_m - eye.z
      if(ex * ex + ez * ez + above * above > r.near_drop * r.near_drop){
        unload_meshes(chunk.near)
        chunk.near = null
        chunk.near_done = false
        delete(state.near, chunk.index)
      }
    }
    for(let local chunk in values({...state.mid})){
      local ex = chunk.cx_m - eye.x
      local ez = chunk.cz_m - eye.z
      if(ex * ex + ez * ez + above * above > r.mid_drop * r.mid_drop){
        unload_meshes(chunk.mid)
        chunk.mid = null
        chunk.mid_done = false
        delete(state.mid, chunk.index)
      }
    }
  }

  // the levels, the nearest first
  if(m.only == null or m.only == 0){
    state.shader:set("lod", level_lod(m.NEAR), rl.SHADER_UNIFORM_VEC4)
    for(let local meshes in values(near_list)){
      draw_meshes(meshes, counted)
    }
  }
  if(m.only == null or m.only == 1){
    state.shader:set("lod", level_lod(m.MID), rl.SHADER_UNIFORM_VEC4)
    for(let local meshes in values(mid_list)){
      draw_meshes(meshes, counted)
    }
  }
  if(not shadows and (m.only == null or m.only == 2)){
    shaders.apply(state.far_shader, view)
    state.far_shader:set("eyeAbove", above * 1.0)
    state.far_shader:set("lod", level_lod(m.FAR), rl.SHADER_UNIFORM_VEC4)
    local far_in = m.FAR[0] * 0.93
    for(let local block in values(state.supers)){
      local ex = block.x - eye.x
      local ey = block.y - eye.y
      local ez = block.z - eye.z
      local r = block.radius
      if(m.only == null and math.sqrt(ex * ex + ez * ez + above * above) + r < far_in){
        continue
      }
      local along = ex * f.x + ey * f.y + ez * f.z
      if(along < -r){
        continue
      }
      local across = ex * ex + ey * ey + ez * ez - along * along
      local limit = math.max(along, 0) * th + r * sec
      if(across > limit * limit){
        continue
      }
      draw_meshes(block.meshes, counted)
    }
  }
  if(shadows){
    stats.shadow_ms = time.clock() - from
    stats.shadow_draws = counted.draws
  } else {
    stats.ms = time.clock() - from
    stats.draws = counted.draws
    stats.triangles = counted.triangles
    stats.near = count(state.near)
    stats.mid = count(state.mid)
  }
}

// stats() -> {draws, triangles, ms, shadow_draws, shadow_ms, near, mid,
//   baked, baked_vertices, far_vertices, bake_ms, bake_most, init_ms}
// The last frame: its draw calls and triangles and the time flora.draw
// took in slang (ms, the baking included), the same for the shadow pass;
// how many squares have a near and a mid level baked now; how many
// parts of squares were baked in all; the vertices in baked meshes now
// (and in the far level);
// the time the last frame spent baking and the most a frame did (but for
// the frames that had everything around the eye to bake); init's time.
func m.stats(){
  return state.stats
}

// sizes() -> {[kind name]: {near, mid, far}}: the triangles of the
// shapes made so far
func m.sizes(){
  local out = {}
  for(let local e in entries(state.shapes)){
    local made = e[1]
    out[plants.KINDS[e[0]].name] = {
      near: made.near.triangles,
      mid: if(made.mid != null){ made.mid.triangles } else { 0 },
      far: if(made.far != null){ made.far.triangles } else { 0 },
    }
  }
  return out
}

// atlas() -> {texture, image, size}: the foliage texture and its pixels
// (r, g, b, a bytes), for looking at
func m.atlas(){
  return {texture: state.atlas, image: state.image, size: SIZE}
}

func m.unload(){
  if(state.shader == null){
    return
  }
  for(let local chunk in values({...state.near})){
    unload_meshes(chunk.near)
    chunk.near = null
    chunk.near_done = false
  }
  for(let local chunk in values({...state.mid})){
    unload_meshes(chunk.mid)
    chunk.mid = null
    chunk.mid_done = false
  }
  for(let local block in values(state.supers)){
    unload_meshes(block.meshes)
  }
  state.atlas:unload()
  if(state.stone_own){
    state.stone:unload()
  }
  state.stone = null
  state.ground = null
  state.shader:unload()
  state.far_shader:unload()
  state.shader = null
  state.far_shader = null
  state.plants = null
  state.supers = null
  state.scratch = null
}

return m
