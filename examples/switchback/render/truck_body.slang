// render/truck_body: the truck's body, built once: two prisms (the lower
// body from bumper to tailgate with its four wheel arches, and the
// cabin's upper part set in on it, leaning inward toward the roof) and
// what is fixed to them: glass, lamps, the grille, flares, mirrors,
// seams and handles, the rear bumper, and what hangs under the floor.
//
// The truck's frame: x to its left, y up, z forward, the origin between
// the axles at the height of the wheel centers; the ground is 0.42 under
// it. The shapes follow the hull the physics collides with (game/car).
local math = require("slang/math")
local vec = require("game/vec")
local kit = require("render/truck_mesh")

local m = {}
local v3 = kit.v3

// ---- the measures the other parts fit to
m.HALF = 0.9              // half the lower body's width
m.BELT = 0.955            // where the lower body ends and the windows begin
m.ROOF = 1.5              // the roof's height
m.NOSE = 2.1              // the front face
m.TAIL = -2.18            // the rear face
m.ARCH = 0.56             // a wheel arch's half length
m.AXLE = 1.36             // the axles, fore and aft of the origin

// half the cabin's width at a height: it leans in toward the roof
func m.upper_half(y){
  return 0.858 - (y - 0.94) * 0.105
}
local upper_half = m.upper_half
local LEAN = -0.105

// the windscreen's and the rear window's lines: z at a height
func m.screen_z(y){
  return 0.955 - 0.495 * (y - 0.94)
}
local screen_z = m.screen_z

func m.rear_z(y){
  return -2.15 + 0.058 * (y - 0.94)
}
local rear_z = m.rear_z

// ---- colors, as the screen shows them
m.DARK = {24, 25, 27}        // under the floor, inside the arches
m.TRIM = {30, 31, 34}        // black plastic: flares, mirrors, handles
m.RUBBER = {16, 16, 17}
m.STEEL = {44, 46, 50}       // bumpers, sliders
m.CHASSIS = {34, 35, 38}
m.BRIGHT = {198, 200, 204}   // bright metal
m.LENS = {255, 246, 224}
m.AMBER = {255, 148, 20}
m.RED = {206, 22, 18}
m.WHITE = {240, 240, 236}

local func colored(b, material, c, param){
  b:paint(material, param)
  b:color(c[0], c[1], c[2])
}

// an arch's edge, front to back, for the axle at z: {z, y} points
local func arch_points(z, low_front, low_back){
  return {
    {z: z + 0.56, y: low_front}, {z: z + 0.56, y: 0.36}, {z: z + 0.34, y: 0.6},
    {z: z - 0.34, y: 0.6}, {z: z - 0.56, y: 0.36}, {z: z - 0.56, y: low_back},
  }
}

// the same pushed out by the width of a flare
local func flare_points(z, low_front, low_back){
  return {
    {z: z + 0.635, y: low_front}, {z: z + 0.635, y: 0.395}, {z: z + 0.375, y: 0.675},
    {z: z - 0.375, y: 0.675}, {z: z - 0.635, y: 0.395}, {z: z - 0.635, y: low_back},
  }
}

// the two prisms
local func shell(b){
  local dark = m.DARK
  local P = kit.PAINT
  local lower = {
    {z: 2.1, y: 0.2, material: P},
    {z: 2.1, y: 0.56, material: P},
    {z: 2.085, y: 0.9, material: P},
    {z: 2.02, y: 0.955, material: P},
    {z: 1.0, y: 0.985, material: kit.MATTE, color: m.TRIM},
    {z: 0.93, y: m.BELT, material: P},
    {z: -2.17, y: m.BELT, material: P},
    {z: -2.19, y: 0.24, material: kit.MATTE, color: dark},
  }
  // the underside from the tail forward: the rear arch, the sill, the
  // front arch
  local rear = arch_points(-m.AXLE, 0.0, 0.16)
  for(local i = len(rear) - 1; i >= 0; i = i - 1){
    append(lower, {z: rear[i].z, y: rear[i].y, material: kit.MATTE, color: dark})
  }
  local front = arch_points(m.AXLE, 0.2, 0.0)
  for(local i = len(front) - 1; i >= 0; i = i - 1){
    append(lower, {z: front[i].z, y: front[i].y, material: kit.MATTE, color: dark})
  }
  b:prism(lower, func(y){
    return m.HALF
  }, {bevel: 0.03, side: {material: P}})

  local upper = {
    {z: screen_z(0.94), y: 0.94, material: P},
    {z: screen_z(1.455), y: 1.455, material: kit.ROOF},
    {z: 0.61, y: m.ROOF, material: kit.ROOF},
    {z: -2.03, y: m.ROOF, material: kit.ROOF},
    {z: rear_z(1.455), y: 1.455, material: P},
    {z: rear_z(0.94), y: 0.94},
  }
  b:prism(upper, upper_half, {bevel: 0.028, side: {material: P}, lean: LEAN})
}

// a pane on the cabin's side: its corners as {z, y}, with a rubber frame
local func side_pane(b, side, corners){
  local rim = {}
  local glass = {}
  local cz = 0
  local cy = 0
  for(let local c in values(corners)){
    cz = cz + c.z / len(corners)
    cy = cy + c.y / len(corners)
  }
  for(let local c in values(corners)){
    // the frame: a little larger than the glass
    local dz = c.z - cz
    local dy = c.y - cy
    local l = math.sqrt(dz * dz + dy * dy)
    local fz = c.z + dz / l * 0.028
    local fy = c.y + dy / l * 0.028
    append(rim, v3(side * (upper_half(fy) + 0.002), fy, fz))
    append(glass, v3(side * (upper_half(c.y) + 0.005), c.y, c.z))
  }
  local n = vec.normalize({x: side, y: -LEAN, z: 0})
  colored(b, kit.MATTE, m.RUBBER)
  b:quad(rim[0], rim[1], rim[2], rim[3], n)
  b:paint(kit.GLASS)
  b:quad(glass[0], glass[1], glass[2], glass[3], n)
}

local func glazing(b){
  // the windscreen and the rear window: on the prism's sloping faces
  local screens = {
    {low: 1.0, high: 1.425, line: screen_z, inset_low: 0.105, inset_high: 0.095, n: vec.normalize({x: 0, y: 0.255, z: 0.515})},
    {low: 1.03, high: 1.405, line: rear_z, inset_low: 0.17, inset_high: 0.15, n: vec.normalize({x: 0, y: 0.03, z: -0.515})},
  }
  for(let local s in values(screens)){
    local n = s.n
    for(let local layer in values({{0.03, 0.002, false}, {0, 0.005, true}})){
      local grow = layer[0]
      local out = layer[1]
      local yl = s.low - grow
      local yh = s.high + grow
      local wl = upper_half(yl) - s.inset_low + grow
      local wh = upper_half(yh) - s.inset_high + grow
      local zl = s.line(yl)
      local zh = s.line(yh)
      if(layer[2]){
        b:paint(kit.GLASS)
      } else {
        colored(b, kit.MATTE, m.RUBBER)
      }
      b:quad(
        v3(wl + n.x * out, yl + n.y * out, zl + n.z * out), v3(-wl + n.x * out, yl + n.y * out, zl + n.z * out),
        v3(-wh + n.x * out, yh + n.y * out, zh + n.z * out), v3(wh + n.x * out, yh + n.y * out, zh + n.z * out), n
      )
    }
  }
  for(let local side in values({1, -1})){
    // the front door's pane follows the windscreen's pillar
    side_pane(b, side, {
      {z: screen_z(0.995) - 0.125, y: 0.995}, {z: screen_z(1.41) - 0.105, y: 1.41},
      {z: -0.045, y: 1.41}, {z: -0.045, y: 0.995},
    })
    side_pane(b, side, {
      {z: -0.155, y: 0.995}, {z: -0.155, y: 1.41}, {z: -0.87, y: 1.41}, {z: -0.87, y: 0.995},
    })
    side_pane(b, side, {
      {z: -0.98, y: 0.995}, {z: -0.98, y: 1.41}, {z: rear_z(1.41) + 0.13, y: 1.41}, {z: rear_z(0.995) + 0.12, y: 0.995},
    })
  }
  // the wipers, parked
  colored(b, kit.MATTE, m.RUBBER)
  local n = screens[0].n
  for(let local w in values({{0.5, 0.03}, {-0.03, -0.5}})){
    local ya = 1.012
    local yb = 1.05
    b:rod(
      v3(w[0], ya + n.y * 0.014, screen_z(ya) + n.z * 0.014), v3(w[1], yb + n.y * 0.014, screen_z(yb) + n.z * 0.014),
      0.007, 5, 0.007, true, true
    )
  }
}

// black flares around the arches
local func flares(b){
  for(let local side in values({1, -1})){
    for(let local arch in values({{m.AXLE, 0.2, 0.0}, {-m.AXLE, 0.0, 0.16}})){
      local inner = arch_points(arch[0], arch[1], arch[2])
      local outer = flare_points(arch[0], arch[1], arch[2])
      local x0 = side * (m.HALF - 0.035)
      local x1 = side * (m.HALF + 0.05)
      local xb = side * (m.HALF - 0.002)
      colored(b, kit.MATTE, m.TRIM)
      local face = v3(side, 0, 0)
      for(local i = 0; i + 1 < len(inner); i = i + 1){
        local a = inner[i]
        local c = inner[i + 1]
        local oa = outer[i]
        local oc = outer[i + 1]
        // the face, the rim that looks away from the wheel, the lip
        // that looks at it
        b:quad(v3(x1, a.y, a.z), v3(x1, c.y, c.z), v3(x1, oc.y, oc.z), v3(x1, oa.y, oa.z), face)
        local away = vec.normalize({x: side * 0.5, y: (oa.y + oc.y - a.y - c.y), z: (oa.z + oc.z - a.z - c.z)})
        b:bent(
          v3(x1, oa.y, oa.z), v3(x1, oc.y, oc.z), v3(xb, oc.y + (oc.y - c.y) * 0.3, oc.z + (oc.z - c.z) * 0.3),
          v3(xb, oa.y + (oa.y - a.y) * 0.3, oa.z + (oa.z - a.z) * 0.3), face, face, away, away
        )
        local toward = vec.normalize({x: 0, y: a.y + c.y - oa.y - oc.y, z: a.z + c.z - oa.z - oc.z})
        b:quad(v3(x1, a.y, a.z), v3(x1, c.y, c.z), v3(x0, c.y, c.z), v3(x0, a.y, a.z), toward)
      }
      // the flare's two ends, closed
      for(let local end in values({0, len(inner) - 1})){
        local a = inner[end]
        local oa = outer[end]
        b:quad(v3(x1, a.y, a.z), v3(x1, oa.y, oa.z), v3(xb, oa.y, oa.z), v3(xb, a.y, a.z), v3(0, -1, 0))
      }
    }
  }
}

local func front(b){
  local z = m.NOSE
  // the mask: a dark band across the nose with the lamps and the grille
  colored(b, kit.MATTE, m.TRIM)
  b:box(0, 0.722, z + 0.004, 1.71, 0.3, 0.03, 0.012)
  colored(b, kit.METAL, {96, 98, 104})
  for(local i = 0; i < 5; i = i + 1){
    b:box(0, 0.622 + i * 0.05, z + 0.022, 0.98, 0.02, 0.014, 0.004)
  }
  for(let local x in values({-0.25, 0.25})){
    b:box(x, 0.722, z + 0.02, 0.018, 0.23, 0.012, 0.003)
  }
  for(let local side in values({1, -1})){
    local x = side * 0.672
    // a round lamp in a bright ring
    colored(b, kit.CHROME, m.BRIGHT)
    b:rod(v3(x, 0.722, z + 0.01), v3(x, 0.722, z + 0.038), 0.118, 20, 0.112, false, false)
    b:disc(v3(x, 0.722, z + 0.038), v3(0, 0, 1), 0.112, 20, 0.098)
    colored(b, kit.LIGHT, m.LENS, kit.HEAD)
    b:disc(v3(x, 0.722, z + 0.034), v3(0, 0, 1), 0.098, 20)
    // the indicator under it
    colored(b, kit.LIGHT, m.AMBER, kit.BLINK)
    b:box(x, 0.505, z + 0.006, 0.16, 0.05, 0.022, 0.006)
    // one more on the wing's flank
    b:box(side * (m.HALF + 0.002), 0.8, 1.99, 0.012, 0.035, 0.07, 0.004)
  }
  // the bonnet: a raised middle, and the seams along the wings
  local tilt = vec.quat_axis({x: 1, y: 0, z: 0}, math.atan2(0.03, 1.02))
  b:push(0, 0.97, 1.51, tilt)
  b:paint(kit.PAINT)
  b:box(0, 0.008, 0, 0.92, 0.03, 0.94, 0.014)
  colored(b, kit.MATTE, m.RUBBER)
  for(let local x in values({-0.79, 0.79})){
    b:box(x, 0.0015, 0, 0.007, 0.004, 1.0, 0)
  }
  b:box(0, 0.0015, 0.5, 1.58, 0.004, 0.007, 0)
  b:pop()
  // an aerial on the right wing
  b:rod(v3(-0.8, 0.96, 1.05), v3(-0.8, 1.0, 1.05), 0.012, 6, 0.008, false, true)
  b:rod(v3(-0.8, 1.0, 1.05), v3(-0.8, 1.86, 0.98), 0.004, 4, 0.003, false, true)
}

local func sides(b){
  for(let local side in values({1, -1})){
    local x = side * (m.HALF + 0.001)
    // the sill's cladding
    colored(b, kit.MATTE, m.TRIM)
    b:box(side * (m.HALF + 0.004), 0.062, 0.0, 0.016, 0.12, 1.5, 0.006)
    // the doors' seams: front, middle, behind the rear door, along the sill
    colored(b, kit.MATTE, m.RUBBER)
    b:box(x, 0.54, 0.742, 0.004, 0.83, 0.011, 0)
    b:box(x, 0.54, -0.1, 0.004, 0.83, 0.011, 0)
    b:box(x, 0.725, -0.925, 0.004, 0.46, 0.011, 0)
    b:box(x, 0.128, -0.02, 0.004, 0.01, 1.52, 0)
    // three louvres behind the front arch
    for(local i = 0; i < 3; i = i + 1){
      b:box(x + 0.002, 0.86 - i * 0.045, 1.36, 0.006, 0.02, 0.34, 0)
    }
    // handles
    colored(b, kit.MATTE, m.TRIM)
    b:box(side * (m.HALF + 0.012), 0.845, 0.03, 0.024, 0.032, 0.15, 0.008)
    b:box(side * (m.HALF + 0.012), 0.845, -0.79, 0.024, 0.032, 0.15, 0.008)
    // the mirror: an arm from the door, the housing, the glass
    b:rod(v3(side * 0.86, 1.045, 0.84), v3(side * 1.0, 1.075, 0.86), 0.016, 6, 0.016, false, false)
    b:box(side * 1.03, 1.1, 0.868, 0.1, 0.17, 0.062, 0.02)
    b:paint(kit.CHROME)
    b:color(210, 214, 220)
    b:quad(
      v3(side * 0.992, 1.03, 0.836), v3(side * 1.068, 1.03, 0.836),
      v3(side * 1.068, 1.17, 0.836), v3(side * 0.992, 1.17, 0.836), v3(0, 0, -1)
    )
  }
  // the filler cap, on the left
  colored(b, kit.MATTE, m.RUBBER)
  b:disc(v3(m.HALF + 0.002, 0.72, -1.62), v3(1, 0, 0), 0.078, 16, 0.07)
}

local func roof(b){
  b:paint(kit.ROOF)
  for(let local x in values({-0.52, -0.18, 0.18, 0.52})){
    b:box(x, m.ROOF + 0.004, -0.71, 0.085, 0.02, 2.36, 0.009)
  }
}

local func rear(b){
  local z = m.TAIL
  for(let local side in values({1, -1})){
    local x = side * 0.795
    colored(b, kit.MATTE, m.TRIM)
    b:box(x, 0.67, z + 0.005, 0.15, 0.45, 0.03, 0.01)
    colored(b, kit.LIGHT, m.RED, kit.TAIL)
    b:box(x, 0.805, z - 0.006, 0.115, 0.135, 0.022, 0.008)
    colored(b, kit.LIGHT, m.AMBER, kit.BLINK)
    b:box(x, 0.665, z - 0.006, 0.115, 0.105, 0.022, 0.008)
    colored(b, kit.LIGHT, m.WHITE, kit.REVERSE)
    b:box(x, 0.545, z - 0.006, 0.115, 0.095, 0.022, 0.008)
  }
  // the third brake lamp over the window
  colored(b, kit.LIGHT, m.RED, kit.TAIL)
  b:box(0, 1.44, m.rear_z(1.44) - 0.004, 0.3, 0.022, 0.014, 0.004)
  // the tailgate: its seam, hinged on the right, the handle on the left
  colored(b, kit.MATTE, m.RUBBER)
  b:box(0.7, 0.62, z - 0.001, 0.011, 0.64, 0.004, 0)
  b:box(-0.7, 0.62, z - 0.001, 0.011, 0.64, 0.004, 0)
  b:box(0, 0.3, z - 0.004, 1.41, 0.011, 0.004, 0)
  colored(b, kit.MATTE, m.TRIM)
  b:box(0.58, 0.86, z - 0.012, 0.14, 0.035, 0.026, 0.008)
  for(let local y in values({0.42, 0.84})){
    b:box(-0.715, y, z - 0.012, 0.05, 0.09, 0.024, 0.006)
  }
  // a plate
  colored(b, kit.MATTE, {214, 214, 204})
  b:box(0.5, 0.4, z - 0.008, 0.3, 0.1, 0.008, 0.002)
  // the bumper: a steel bar with two red reflectors, a hitch under it
  colored(b, kit.METAL, m.STEEL)
  b:box(0, 0.215, z - 0.055, 1.7, 0.13, 0.13, 0.03)
  for(let local side in values({1, -1})){
    b:box(side * 0.855, 0.215, z + 0.03, 0.09, 0.13, 0.3, 0.03)
  }
  colored(b, kit.LIGHT, m.RED, kit.TAIL)
  for(let local side in values({1, -1})){
    b:box(side * 0.62, 0.215, z - 0.121, 0.16, 0.04, 0.006, 0.002)
  }
  colored(b, kit.METAL, m.CHASSIS)
  b:box(0, 0.11, z - 0.03, 0.09, 0.09, 0.2, 0.012)
}

// what hangs under the floor: the frame's rails, the gearbox and the
// transfer case, a guard under the nose, the tank, the exhaust
local func underside(b){
  colored(b, kit.METAL, m.CHASSIS)
  for(let local side in values({1, -1})){
    b:box(side * 0.44, -0.035, 0.0, 0.08, 0.12, 1.66, 0.012)
    // the rails kick up over the axles
    b:box(side * 0.44, 0.3, m.AXLE, 0.08, 0.1, 1.1, 0.012)
    b:box(side * 0.44, 0.3, -m.AXLE, 0.08, 0.1, 1.1, 0.012)
    b:box(side * 0.44, 0.22, -2.0, 0.08, 0.1, 0.3, 0.012)
  }
  for(let local z in values({0.7, -0.05, -0.72})){
    b:box(0, -0.03, z, 0.9, 0.07, 0.07, 0.01)
  }
  // the engine's sump over the front axle, the gearbox, the transfer case
  colored(b, kit.METAL, {58, 60, 64})
  b:box(0, 0.47, 1.42, 0.5, 0.2, 0.62, 0.04)
  b:box(0, 0.06, 0.62, 0.34, 0.2, 0.6, 0.05)
  b:box(-0.06, -0.035, 0.12, 0.36, 0.17, 0.44, 0.04)
  // the guard: a plate from the bumper back under the engine
  colored(b, kit.METAL, {110, 112, 116})
  b:push(0, 0.2, 1.93, vec.quat_axis({x: 1, y: 0, z: 0}, -0.2))
  b:box(0, 0, 0, 0.8, 0.012, 0.42, 0.004)
  b:pop()
  // the tank behind the rear axle
  colored(b, kit.MATTE, m.DARK)
  b:box(0.05, 0.19, -1.985, 0.7, 0.16, 0.26, 0.03)
  // the exhaust: down the right side, over the axle, out at the back
  colored(b, kit.METAL, {84, 80, 76})
  b:tube({
    v3(-0.2, 0.05, 0.6), v3(-0.3, -0.02, 0.3), v3(-0.3, -0.02, -0.72), v3(-0.3, 0.12, -0.92),
    v3(-0.3, 0.33, -1.2), v3(-0.3, 0.33, -1.55), v3(-0.36, 0.17, -1.86), v3(-0.5, 0.15, -2.26),
  }, 0.03, 6)
  b:rod(v3(-0.3, -0.02, 0.05), v3(-0.3, -0.02, -0.55), 0.075, 10, 0.075, true, true)
}

// build(b: MeshBuilder): the body into a mesh being built
func m.build(b){
  shell(b)
  glazing(b)
  flares(b)
  front(b)
  sides(b)
  roof(b)
  rear(b)
  underside(b)
}

return m
