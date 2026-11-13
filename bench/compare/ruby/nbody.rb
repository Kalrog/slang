# bench/compare/slang/nbody.slang in Ruby
def now = Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000
PI = 3.141592653589793
SOLAR_MASS = 4 * PI * PI
DAYS = 365.24
class Body
  attr_accessor :x, :y, :z, :vx, :vy, :vz, :mass
  def initialize(x, y, z, vx, vy, vz, mass)
    @x, @y, @z = x, y, z
    @vx, @vy, @vz = vx * DAYS, vy * DAYS, vz * DAYS
    @mass = mass * SOLAR_MASS
  end
end
BODIES = [
  Body.new(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0),
  Body.new(4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
    1.66007664274403694e-03, 7.69901118419740425e-03, -6.90460016972063023e-05,
    9.54791938424326609e-04),
  Body.new(8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
    -2.76742510726862411e-03, 4.99852801234917238e-03, 2.30417297573763929e-05,
    2.85885980666130812e-04),
  Body.new(1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
    2.96460137564761618e-03, 2.37847173959480950e-03, -2.96589568540237556e-05,
    4.36624404335156298e-05),
  Body.new(1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
    2.68067772490389322e-03, 1.62824170038242295e-03, -9.51592254519715870e-05,
    5.15138902046611451e-05),
]
NB = BODIES.size
def advance(dt)
  i = 0
  while i < NB
    a = BODIES[i]
    j = i + 1
    while j < NB
      b = BODIES[j]
      dx = a.x - b.x
      dy = a.y - b.y
      dz = a.z - b.z
      d2 = dx * dx + dy * dy + dz * dz
      mag = dt / (d2 * Math.sqrt(d2))
      bm = b.mass * mag
      a.vx -= dx * bm
      a.vy -= dy * bm
      a.vz -= dz * bm
      am = a.mass * mag
      b.vx += dx * am
      b.vy += dy * am
      b.vz += dz * am
      j += 1
    end
    i += 1
  end
  BODIES.each do |b|
    b.x += dt * b.vx
    b.y += dt * b.vy
    b.z += dt * b.vz
  end
end
def energy
  e = 0.0
  NB.times do |i|
    a = BODIES[i]
    e += 0.5 * a.mass * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz)
    ((i + 1)...NB).each do |j|
      b = BODIES[j]
      dx = a.x - b.x
      dy = a.y - b.y
      dz = a.z - b.z
      e -= a.mass * b.mass / Math.sqrt(dx * dx + dy * dy + dz * dz)
    end
  end
  e
end
px = py = pz = 0.0
BODIES.each do |b|
  px += b.vx * b.mass
  py += b.vy * b.mass
  pz += b.vz * b.mass
end
BODIES[0].vx = -px / SOLAR_MASS
BODIES[0].vy = -py / SOLAR_MASS
BODIES[0].vz = -pz / SOLAR_MASS
t0 = now
100_000.times { advance(0.01) }
e = (energy * 1_000_000_000).truncate
puts format("nbody: %d in %.3f ms", e, now - t0)
