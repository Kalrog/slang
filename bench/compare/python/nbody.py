# bench/compare/slang/nbody.slang in Python
import time, math
PI = 3.141592653589793
SOLAR_MASS = 4 * PI * PI
DAYS = 365.24
class Body:
    __slots__ = ("x", "y", "z", "vx", "vy", "vz", "mass")
    def __init__(self, x, y, z, vx, vy, vz, mass):
        self.x, self.y, self.z = x, y, z
        self.vx, self.vy, self.vz = vx * DAYS, vy * DAYS, vz * DAYS
        self.mass = mass * SOLAR_MASS
bodies = [
    Body(0, 0, 0, 0, 0, 0, 1),
    Body(4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
         1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05,
         9.54791938424326609e-04),
    Body(8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
         -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05,
         2.85885980666130812e-04),
    Body(1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
         2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05,
         4.36624404335156298e-05),
    Body(1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
         2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05,
         5.15138902046611451e-05),
]
NB = len(bodies)
sqrt = math.sqrt
def advance(dt):
    for i in range(NB):
        a = bodies[i]
        for j in range(i + 1, NB):
            b = bodies[j]
            dx = a.x - b.x
            dy = a.y - b.y
            dz = a.z - b.z
            d2 = dx * dx + dy * dy + dz * dz
            mag = dt / (d2 * sqrt(d2))
            bm = b.mass * mag
            a.vx -= dx * bm
            a.vy -= dy * bm
            a.vz -= dz * bm
            am = a.mass * mag
            b.vx += dx * am
            b.vy += dy * am
            b.vz += dz * am
    for b in bodies:
        b.x += dt * b.vx
        b.y += dt * b.vy
        b.z += dt * b.vz
def energy():
    e = 0.0
    for i in range(NB):
        a = bodies[i]
        e += 0.5 * a.mass * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz)
        for j in range(i + 1, NB):
            b = bodies[j]
            dx = a.x - b.x
            dy = a.y - b.y
            dz = a.z - b.z
            e -= a.mass * b.mass / sqrt(dx * dx + dy * dy + dz * dz)
    return e
px = py = pz = 0.0
for b in bodies:
    px += b.vx * b.mass
    py += b.vy * b.mass
    pz += b.vz * b.mass
bodies[0].vx = -px / SOLAR_MASS
bodies[0].vy = -py / SOLAR_MASS
bodies[0].vz = -pz / SOLAR_MASS
t0 = time.perf_counter()
for _ in range(100000):
    advance(0.01)
e = int(energy() * 1000000000)
print(f"nbody: {e} in {(time.perf_counter() - t0) * 1000:.3f} ms")
