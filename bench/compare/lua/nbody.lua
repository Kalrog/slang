-- bench/compare/slang/nbody.slang in Lua
local sqrt = math.sqrt
local pi = 3.141592653589793
local solar_mass = 4 * pi * pi
local days = 365.24
local function body(x, y, z, vx, vy, vz, mass)
  return {x = x, y = y, z = z, vx = vx * days, vy = vy * days, vz = vz * days,
    mass = mass * solar_mass}
end
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
    5.15138902046611451e-05),
}
local nb = #bodies
local function advance(dt)
  for i = 1, nb do
    local a = bodies[i]
    for j = i + 1, nb do
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
    end
  end
  for i = 1, nb do
    local b = bodies[i]
    b.x = b.x + dt * b.vx
    b.y = b.y + dt * b.vy
    b.z = b.z + dt * b.vz
  end
end
local function energy()
  local e = 0
  for i = 1, nb do
    local a = bodies[i]
    e = e + 0.5 * a.mass * (a.vx * a.vx + a.vy * a.vy + a.vz * a.vz)
    for j = i + 1, nb do
      local b = bodies[j]
      local dx = a.x - b.x
      local dy = a.y - b.y
      local dz = a.z - b.z
      e = e - a.mass * b.mass / sqrt(dx * dx + dy * dy + dz * dz)
    end
  end
  return e
end
local px, py, pz = 0, 0, 0
for _, b in ipairs(bodies) do
  px = px + b.vx * b.mass
  py = py + b.vy * b.mass
  pz = pz + b.vz * b.mass
end
bodies[1].vx = -px / solar_mass
bodies[1].vy = -py / solar_mass
bodies[1].vz = -pz / solar_mass
local t0 = os.clock()
for _ = 1, 100000 do
  advance(0.01)
end
local e = energy() * 1000000000
e = e < 0 and math.ceil(e) or math.floor(e)
print(string.format("nbody: %.0f in %.3f ms", e, (os.clock() - t0) * 1000))
