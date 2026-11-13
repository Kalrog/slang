// bench/compare/slang/nbody.slang in JavaScript
const PI = 3.141592653589793;
const SOLAR_MASS = 4 * PI * PI;
const DAYS = 365.24;
function body(x, y, z, vx, vy, vz, mass) {
  return {x, y, z, vx: vx * DAYS, vy: vy * DAYS, vz: vz * DAYS, mass: mass * SOLAR_MASS};
}
const bodies = [
  body(0, 0, 0, 0, 0, 0, 1),
  body(4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
    1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05,
    9.54791938424326609e-04),
  body(8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
    -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05,
    2.85885980666130812e-04),
  body(1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
    2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05,
    4.36624404335156298e-05),
  body(1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
    2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05,
    5.15138902046611451e-05),
];
const nb = bodies.length;
function advance(dt) {
  for (let i = 0; i < nb; i++) {
    const a = bodies[i];
    for (let j = i + 1; j < nb; j++) {
      const b = bodies[j];
      const dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
      const d2 = dx * dx + dy * dy + dz * dz;
      const mag = dt / (d2 * Math.sqrt(d2));
      const bm = b.mass * mag;
      a.vx -= dx * bm; a.vy -= dy * bm; a.vz -= dz * bm;
      const am = a.mass * mag;
      b.vx += dx * am; b.vy += dy * am; b.vz += dz * am;
    }
  }
  for (let i = 0; i < nb; i++) {
    const b = bodies[i];
    b.x += dt * b.vx; b.y += dt * b.vy; b.z += dt * b.vz;
  }
}
function energy() {
  let e = 0;
  for (let i = 0; i < nb; i++) {
    const a = bodies[i];
    e += 0.5 * a.mass * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz);
    for (let j = i + 1; j < nb; j++) {
      const b = bodies[j];
      const dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
      e -= a.mass * b.mass / Math.sqrt(dx * dx + dy * dy + dz * dz);
    }
  }
  return e;
}
let px = 0, py = 0, pz = 0;
for (const b of bodies) { px += b.vx * b.mass; py += b.vy * b.mass; pz += b.vz * b.mass; }
bodies[0].vx = -px / SOLAR_MASS;
bodies[0].vy = -py / SOLAR_MASS;
bodies[0].vz = -pz / SOLAR_MASS;
const t0 = performance.now();
for (let i = 0; i < 100000; i++) advance(0.01);
const e = Math.trunc(energy() * 1000000000);
console.log(`nbody: ${e} in ${(performance.now() - t0).toFixed(3)} ms`);
