// float arithmetic and field access (the benchmarks game n-body)
local time = require("slang/time")
local math = require("slang/math")
local sqrt = math.sqrt
local pi = 3.141592653589793
local solar_mass = 4 * pi * pi
local days = 365.24
local func body(x, y, z, vx, vy, vz, mass){
  return {
    x: x, y: y, z: z, vx: vx * days, vy: vy * days, vz: vz * days,
    mass: mass * solar_mass
  }
}
local bodies = {
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
    5.15138902046611451e-05)
}
local nb = len(bodies)
local func advance(dt){
  for(local i = 0; i < nb; i = i + 1){
    local a = bodies[i]
    for(local j = i + 1; j < nb; j = j + 1){
      local b = bodies[j]
      local dx = a.x - b.x
      local dy = a.y - b.y
      local dz = a.z - b.z
      local d2 = dx * dx + dy * dy + dz * dz
      local mag = dt / (d2 * sqrt(d2))
      local bm = b.mass * mag
      a.vx = a.vx - dx * bm
      a.vy = a.vy - dy * bm
      a.vz = a.vz - dz * bm
      local am = a.mass * mag
      b.vx = b.vx + dx * am
      b.vy = b.vy + dy * am
      b.vz = b.vz + dz * am
    }
  }
  for(local i = 0; i < nb; i = i + 1){
    local b = bodies[i]
    b.x = b.x + dt * b.vx
    b.y = b.y + dt * b.vy
    b.z = b.z + dt * b.vz
  }
}
local func energy(){
  local e = 0
  for(local i = 0; i < nb; i = i + 1){
    local a = bodies[i]
    e = e + 0.5 * a.mass * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz)
    for(local j = i + 1; j < nb; j = j + 1){
      local b = bodies[j]
      local dx = a.x - b.x
      local dy = a.y - b.y
      local dz = a.z - b.z
      e = e - a.mass * b.mass / sqrt(dx * dx + dy * dy + dz * dz)
    }
  }
  return e
}
local px = 0
local py = 0
local pz = 0
for(let local b in values(bodies)){
  px = px + b.vx * b.mass
  py = py + b.vy * b.mass
  pz = pz + b.vz * b.mass
}
bodies[0].vx = -px / solar_mass
bodies[0].vy = -py / solar_mass
bodies[0].vz = -pz / solar_mass
local t0 = time.clock()
for(local i = 0; i < 100000; i = i + 1){
  advance(0.01)
}
local e = to_int(energy() * 1000000000)
print("nbody: ", e, " in ", time.clock() - t0, " ms\n")
