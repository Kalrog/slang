// render/truck_gear: what a setup of the garage puts on the truck: the
// front bumper (plain, with a hoop, or with a winch), what rides on the
// roof (a basket, an expedition's load, a tent), the light bar, the
// snorkel, the spare wheel on the tailgate, sliders or steps along the
// sills, mud flaps. Built into one mesh whenever the setup changes.
local math = require("slang/math")
local vec = require("game/vec")
local kit = require("render/truck_mesh")
local body = require("render/truck_body")
local wheels = require("render/truck_wheels")

local m = {}
local v3 = kit.v3

local STEEL = body.STEEL
local BLACK = {26, 27, 29}
local ALLOY = {150, 153, 158}

local func colored(b, material, c, param){
  b:paint(material, param)
  b:color(c[0], c[1], c[2])
}

// a quarter turn of a bar: points on an arc from a toward b around a
// corner c (all {x, y, z})
local func arc(points, from, corner, to, steps){
  for(local i = 1; i <= steps; i = i + 1){
    local t = i / steps * math.pi / 2
    local cb = 1 - math.cos(t)
    // from + (corner - from) * sin + (to - corner) * (1 - cos)
    append(points, v3(
      from.x + (corner.x - from.x) * math.sin(t) + (to.x - corner.x) * cb,
      from.y + (corner.y - from.y) * math.sin(t) + (to.y - corner.y) * cb,
      from.z + (corner.z - from.z) * math.sin(t) + (to.z - corner.z) * cb
    ))
  }
}

// a bar around a rectangle in a plane of constant y with round corners:
// x from -hx to hx, z from z0 to z1
local func hoop(b, y, hx, z0, z1, radius, bend){
  local points = {}
  local corners = {
    {v3(hx - bend, y, z1), v3(hx, y, z1), v3(hx, y, z1 - bend)},
    {v3(hx, y, z0 + bend), v3(hx, y, z0), v3(hx - bend, y, z0)},
    {v3(-hx + bend, y, z0), v3(-hx, y, z0), v3(-hx, y, z0 + bend)},
    {v3(-hx, y, z1 - bend), v3(-hx, y, z1), v3(-hx + bend, y, z1)},
  }
  append(points, v3(0, y, z1))
  for(let local c in values(corners)){
    append(points, c[0])
    arc(points, c[0], c[1], c[2], 4)
  }
  append(points, v3(0, y, z1))
  b:tube(points, radius, 6)
}

// ---- bumpers

// where the winch's rope leaves the truck, in its frame
m.FAIRLEAD = {x: 0, y: 0.335, z: 2.345}

local func bumper_stock(b){
  colored(b, kit.MATTE, {40, 41, 44})
  b:box(0, 0.325, 2.16, 1.74, 0.17, 0.14, 0.035)
  for(let local side in values({1, -1})){
    b:box(side * 0.87, 0.325, 2.07, 0.09, 0.17, 0.3, 0.035)
  }
  // the plate's place
  colored(b, kit.MATTE, {214, 214, 204})
  b:box(0, 0.325, 2.232, 0.3, 0.1, 0.006, 0.002)
}

// two eyes for a shackle
local func shackles(b, z, y){
  for(let local side in values({1, -1})){
    colored(b, kit.METAL, STEEL, 0.3)
    b:box(side * 0.36, y, z, 0.03, 0.09, 0.07, 0.008)
    colored(b, kit.METAL, {196, 40, 28}, 0.5)
    b:tube({
      v3(side * 0.36 - 0.035, y + 0.01, z + 0.02), v3(side * 0.36 - 0.035, y - 0.01, z + 0.07),
      v3(side * 0.36, y - 0.02, z + 0.095), v3(side * 0.36 + 0.035, y - 0.01, z + 0.07),
      v3(side * 0.36 + 0.035, y + 0.01, z + 0.02),
    }, 0.011, 5)
  }
}

// a steel bumper: a middle box, wings swept back to the arches
local func bumper_steel(b, depth){
  colored(b, kit.METAL, STEEL, 0.3)
  b:box(0, 0.325, 2.1 + depth / 2, 1.0, 0.2, depth, 0.02)
  for(let local side in values({1, -1})){
    b:push(side * 0.5, 0.335, 2.1 + depth - 0.05, vec.quat_axis({x: 0, y: 1, z: 0}, side * 0.42))
    b:box(side * 0.215, 0, 0, 0.47, 0.17, 0.09, 0.02)
    b:pop()
    b:box(side * 0.89, 0.335, 2.04, 0.05, 0.17, 0.22, 0.02)
  }
}

local func bumper_bar(b){
  bumper_steel(b, 0.16)
  // a hoop over the grille and a bar across it
  colored(b, kit.METAL, {34, 35, 38}, 0.45)
  local z = 2.215
  local points = {v3(-0.4, 0.42, z + 0.02)}
  append(points, v3(-0.4, 0.8, z))
  arc(points, v3(-0.4, 0.8, z), v3(-0.4, 0.9, z - 0.01), v3(-0.3, 0.9, z - 0.01), 4)
  append(points, v3(0.3, 0.9, z - 0.01))
  arc(points, v3(0.3, 0.9, z - 0.01), v3(0.4, 0.9, z - 0.01), v3(0.4, 0.8, z), 4)
  append(points, v3(0.4, 0.42, z + 0.02))
  b:tube(points, 0.028, 8)
  b:rod(v3(-0.4, 0.6, z + 0.008), v3(0.4, 0.6, z + 0.008), 0.02, 6, 0.02, false, false)
  // guards for the lamps
  for(let local side in values({1, -1})){
    b:tube({
      v3(side * 0.4, 0.86, z - 0.005), v3(side * 0.7, 0.86, z - 0.03), v3(side * 0.86, 0.82, z - 0.09),
      v3(side * 0.88, 0.6, z - 0.12), v3(side * 0.88, 0.42, z - 0.13),
    }, 0.02, 6)
  }
  shackles(b, 2.27, 0.3)
  colored(b, kit.MATTE, {214, 214, 204})
  b:box(0, 0.33, 2.263, 0.3, 0.1, 0.006, 0.002)
}

local func bumper_winch(b){
  bumper_steel(b, 0.2)
  // the winch in the bumper's top: the drum with its rope, the motor,
  // the gears' housing
  colored(b, kit.METAL, {58, 60, 64}, 0.35)
  b:box(0, 0.45, 2.2, 0.62, 0.05, 0.17, 0.012)
  b:rod(v3(0.14, 0.505, 2.2), v3(0.3, 0.505, 2.2), 0.058, 10, 0.058, true, true)
  b:rod(v3(-0.3, 0.505, 2.2), v3(-0.14, 0.505, 2.2), 0.062, 10, 0.062, true, true)
  b:rod(v3(-0.14, 0.505, 2.2), v3(-0.125, 0.505, 2.2), 0.07, 10, 0.07, true, true)
  b:rod(v3(0.125, 0.505, 2.2), v3(0.14, 0.505, 2.2), 0.07, 10, 0.07, true, true)
  colored(b, kit.MATTE, {64, 104, 150})
  b:rod(v3(-0.125, 0.505, 2.2), v3(0.125, 0.505, 2.2), 0.052, 12, 0.052, false, false)
  // the fairlead: a bright plate with a slot, the hook on its strap
  colored(b, kit.METAL, ALLOY, 0.6)
  b:box(0, m.FAIRLEAD.y, 2.31, 0.3, 0.085, 0.02, 0.008)
  colored(b, kit.MATTE, {8, 8, 9})
  b:box(0, m.FAIRLEAD.y, 2.321, 0.2, 0.03, 0.004, 0)
  colored(b, kit.METAL, {196, 40, 28}, 0.5)
  b:box(0.04, m.FAIRLEAD.y - 0.005, 2.335, 0.035, 0.05, 0.03, 0.008)
  b:tube({
    v3(0.04, m.FAIRLEAD.y - 0.03, 2.34), v3(0.04, m.FAIRLEAD.y - 0.075, 2.345),
    v3(0.04, m.FAIRLEAD.y - 0.095, 2.325), v3(0.04, m.FAIRLEAD.y - 0.075, 2.305),
  }, 0.009, 5)
  shackles(b, 2.31, 0.29)
}

// ---- along the sills

local func sliders(b){
  colored(b, kit.METAL, STEEL, 0.3)
  for(let local side in values({1, -1})){
    local x = side * 0.955
    b:tube({
      v3(side * 0.9, 0.0, 0.76), v3(x, -0.035, 0.7), v3(x, -0.035, -0.7), v3(side * 0.9, 0.0, -0.76),
    }, 0.034, 8)
    for(let local z in values({0.52, -0.02, -0.56})){
      b:rod(v3(side * 0.5, -0.035, z), v3(x, -0.035, z), 0.024, 6, 0.024, false, false)
    }
    b:box(side * 0.86, -0.036, 0, 0.16, 0.012, 1.34, 0.004)
  }
}

local func steps(b){
  for(let local side in values({1, -1})){
    colored(b, kit.METAL, ALLOY, 0.5)
    b:box(side * 1.0, -0.06, -0.01, 0.17, 0.035, 1.44, 0.012)
    colored(b, kit.MATTE, {22, 22, 24})
    for(local i = 0; i < 9; i = i + 1){
      b:box(side * 1.0, -0.041, -0.57 + i * 0.14, 0.13, 0.004, 0.1, 0)
    }
    b:box(side * 1.0, -0.06, 0.725, 0.172, 0.037, 0.03, 0.01)
    b:box(side * 1.0, -0.06, -0.745, 0.172, 0.037, 0.03, 0.01)
    colored(b, kit.METAL, STEEL, 0.3)
    for(let local z in values({0.5, -0.52})){
      b:rod(v3(side * 0.5, -0.03, z), v3(side * 0.96, -0.07, z), 0.02, 6, 0.02, false, false)
    }
  }
}

local func flaps(b){
  colored(b, kit.MATTE, {20, 20, 22})
  for(let local side in values({1, -1})){
    b:box(side * 0.8, -0.06, body.AXLE - body.ARCH - 0.012, 0.25, 0.22, 0.012, 0.004)
    b:box(side * 0.8, 0.03, -body.AXLE - body.ARCH - 0.012, 0.25, 0.26, 0.012, 0.004)
  }
}

// ---- the snorkel: up the right pillar to over the roof
local func snorkel(b){
  colored(b, kit.MATTE, BLACK)
  local x = -(body.HALF + 0.03)
  b:box(x + 0.008, 0.83, 1.2, 0.045, 0.15, 0.36, 0.02)
  local points = {v3(x, 0.84, 1.08), v3(x, 0.93, 1.0)}
  for(let local y in values({1.0, 1.15, 1.3, 1.45})){
    append(points, v3(-(body.upper_half(y) + 0.062), y, body.screen_z(y) - 0.06))
  }
  append(points, v3(-(body.upper_half(1.5) + 0.064), 1.6, body.screen_z(1.5) - 0.07))
  b:tube(points, 0.042, 8)
  // the head: a scoop that faces the wind
  local top = points[len(points) - 1]
  b:box(top.x, top.y + 0.045, top.z + 0.035, 0.105, 0.14, 0.17, 0.03)
  colored(b, kit.MATTE, {6, 6, 7})
  b:box(top.x, top.y + 0.045, top.z + 0.121, 0.075, 0.105, 0.004, 0)
  // a clip to the pillar
  colored(b, kit.METAL, STEEL, 0.3)
  b:box(-(body.upper_half(1.3) + 0.02), 1.3, body.screen_z(1.3) - 0.06, 0.05, 0.02, 0.05, 0.004)
}

// ---- the roof

// feet on the roof's edges and bars across, for anything carried
local func cross_bars(b, y, zs){
  colored(b, kit.METAL, BLACK, 0.3)
  for(let local z in values(zs)){
    b:box(0, y, z, 1.5, 0.028, 0.055, 0.01)
    for(let local side in values({1, -1})){
      b:box(side * 0.72, y - 0.035, z, 0.06, 0.06, 0.09, 0.012)
    }
  }
}

local func rack_basket(b){
  local floor = body.ROOF + 0.085
  local rail = floor + 0.13
  cross_bars(b, floor - 0.02, {0.2, -0.76, -1.72})
  colored(b, kit.METAL, {28, 29, 31}, 0.4)
  hoop(b, floor, 0.66, -1.94, 0.42, 0.014, 0.08)
  hoop(b, rail, 0.7, -1.98, 0.5, 0.017, 0.12)
  // the floor's bars and the posts of the rail
  for(local i = 0; i < 9; i = i + 1){
    local z = 0.3 - i * 0.27
    b:rod(v3(-0.66, floor, z), v3(0.66, floor, z), 0.01, 5, 0.01, false, false)
  }
  for(let local x in values({-0.33, 0, 0.33})){
    b:rod(v3(x, floor, -1.94), v3(x, floor, 0.42), 0.008, 5, 0.008, false, false)
  }
  for(let local side in values({1, -1})){
    for(local i = 0; i < 6; i = i + 1){
      local z = 0.26 - i * 0.42
      b:rod(v3(side * 0.66, floor, z), v3(side * 0.7, rail, z), 0.01, 5, 0.01, false, false)
    }
  }
  for(let local x in values({-0.36, 0.36})){
    b:rod(v3(x, floor, -1.94), v3(x, rail, -1.98), 0.01, 5, 0.01, false, false)
    b:rod(v3(x, floor, 0.42), v3(x, rail, 0.5), 0.01, 5, 0.01, false, false)
  }
  // a plate that turns the wind
  colored(b, kit.MATTE, {22, 22, 24})
  b:push(0, floor + 0.045, 0.49, vec.quat_axis({x: 1, y: 0, z: 0}, -0.6))
  b:box(0, 0, 0, 1.1, 0.1, 0.006, 0.002)
  b:pop()
  return rail
}

// a flat platform of slats
local func platform(b){
  local y = body.ROOF + 0.07
  cross_bars(b, y - 0.02, {0.2, -0.76, -1.72})
  colored(b, kit.METAL, {30, 31, 33}, 0.4)
  for(local i = 0; i < 9; i = i + 1){
    b:box(-0.6 + i * 0.15, y + 0.008, -0.76, 0.1, 0.02, 2.36, 0.006)
  }
  for(let local z in values({0.43, -1.95})){
    b:box(0, y + 0.008, z, 1.36, 0.03, 0.04, 0.008)
  }
  for(let local side in values({1, -1})){
    b:box(side * 0.68, y + 0.008, -0.76, 0.03, 0.03, 2.42, 0.008)
  }
  return y + 0.02
}

// a can of fuel, lying on its side
local func can(b, x, y, z, c){
  colored(b, kit.MATTE, c)
  b:box(x, y + 0.085, z, 0.34, 0.17, 0.46, 0.03)
  // the pressed cross, the handle, the cap
  colored(b, kit.MATTE, {c[0] * 0.8, c[1] * 0.8, c[2] * 0.8})
  b:box(x, y + 0.171, z - 0.02, 0.2, 0.004, 0.02, 0)
  b:box(x, y + 0.171, z - 0.02, 0.02, 0.004, 0.24, 0)
  colored(b, kit.METAL, {40, 40, 42}, 0.3)
  b:rod(v3(x - 0.09, y + 0.11, z + 0.24), v3(x - 0.09, y + 0.11, z + 0.275), 0.028, 8, 0.028, false, true)
  b:box(x + 0.05, y + 0.1, z + 0.245, 0.14, 0.02, 0.03, 0.006)
}

local func load_expedition(b){
  local y = platform(b)
  // two cans at the back, on the right
  can(b, -0.4, y, -1.62, {74, 90, 52})
  can(b, -0.03, y, -1.62, {166, 40, 28})
  colored(b, kit.MATTE, {16, 16, 17})
  b:box(-0.215, y + 0.172, -1.62, 0.76, 0.006, 0.04, 0)
  // boards for the sand, two on each other, on the left
  for(local i = 0; i < 2; i = i + 1){
    colored(b, kit.MATTE, {226, 104, 22})
    b:box(0.47, y + 0.022 + i * 0.045, -1.1, 0.31, 0.036, 1.18, 0.012)
    colored(b, kit.MATTE, {170, 74, 14})
    for(local k = 0; k < 7; k = k + 1){
      b:box(0.47, y + 0.041 + i * 0.045, -1.58 + k * 0.16, 0.2, 0.004, 0.07, 0)
    }
  }
  colored(b, kit.MATTE, {16, 16, 17})
  for(let local z in values({-0.75, -1.45})){
    b:box(0.47, y + 0.09, z, 0.33, 0.006, 0.04, 0)
  }
  // a case of aluminium at the front
  colored(b, kit.METAL, {168, 171, 176}, 0.55)
  b:box(-0.12, y + 0.14, -0.2, 0.86, 0.28, 0.62, 0.03)
  colored(b, kit.METAL, {120, 122, 126}, 0.4)
  for(let local z in values({-0.38, -0.2, -0.02})){
    b:box(-0.12, y + 0.283, z, 0.8, 0.006, 0.03, 0)
  }
  colored(b, kit.MATTE, {20, 20, 22})
  for(let local x in values({-0.36, 0.12})){
    b:box(x, y + 0.2, 0.112, 0.07, 0.05, 0.012, 0.004)
  }
  // a shovel along the left edge
  colored(b, kit.MATTE, {150, 108, 64})
  b:rod(v3(0.47, y + 0.03, -0.42), v3(0.47, y + 0.03, 0.3), 0.017, 6, 0.017, true, true)
  colored(b, kit.METAL, {70, 72, 76}, 0.4)
  b:box(0.47, y + 0.02, -0.01, 0.2, 0.012, 0.28, 0.006)
  b:box(0.47, y + 0.03, 0.31, 0.11, 0.03, 0.03, 0.008)
  return y + 0.06
}

local func load_tent(b){
  local y = platform(b)
  // the tent folded in its cover, strapped down, its ladder on top
  colored(b, kit.MATTE, {70, 76, 64})
  b:box(0, y + 0.15, -0.9, 1.34, 0.3, 2.0, 0.05)
  colored(b, kit.MATTE, {50, 54, 46})
  b:box(0, y + 0.1, -0.9, 1.35, 0.06, 2.01, 0.03)
  colored(b, kit.MATTE, {18, 18, 19})
  for(let local z in values({-0.2, -0.9, -1.6})){
    b:box(0, y + 0.303, z, 1.3, 0.006, 0.05, 0)
    for(let local side in values({1, -1})){
      b:box(side * 0.672, y + 0.2, z, 0.006, 0.2, 0.05, 0)
    }
  }
  colored(b, kit.METAL, {160, 163, 168}, 0.55)
  for(let local x in values({-0.2, 0.2})){
    b:box(x, y + 0.325, -0.9, 0.035, 0.03, 1.7, 0.008)
  }
  for(local i = 0; i < 6; i = i + 1){
    b:rod(v3(-0.2, y + 0.325, -1.65 + i * 0.3), v3(0.2, y + 0.325, -1.65 + i * 0.3), 0.012, 5, 0.012, false, false)
  }
  return y + 0.03
}

// the light bar: on the roof's front edge, or on what is carried there
local func light_bar(b, y, z){
  colored(b, kit.METAL, {24, 25, 27}, 0.4)
  b:box(0, y + 0.05, z, 1.06, 0.07, 0.075, 0.016)
  for(let local side in values({1, -1})){
    b:box(side * 0.45, y + 0.005, z - 0.01, 0.03, 0.05, 0.05, 0.006)
  }
  colored(b, kit.LIGHT, {232, 240, 255}, kit.BAR)
  for(local i = 0; i < 8; i = i + 1){
    b:box(-0.4375 + i * 0.125, y + 0.05, z + 0.036, 0.108, 0.046, 0.008, 0.003)
  }
}

// the spare on the tailgate, on its carrier
local func spare(b, style){
  colored(b, kit.METAL, STEEL, 0.3)
  b:box(-0.05, 0.74, body.TAIL - 0.05, 0.22, 0.22, 0.09, 0.02)
  b:rod(v3(-0.72, 0.5, body.TAIL - 0.03), v3(-0.1, 0.7, body.TAIL - 0.06), 0.02, 6, 0.02, false, false)
  b:rod(v3(-0.72, 0.86, body.TAIL - 0.03), v3(-0.1, 0.78, body.TAIL - 0.06), 0.02, 6, 0.02, false, false)
  // (a wheel's outer face is its +x: here it looks back)
  b:push(-0.05, 0.74, body.TAIL - 0.245, vec.quat_axis({x: 0, y: 1, z: 0}, math.pi / 2))
  wheels.wheel(b, style)
  b:pop()
}

// build(b: MeshBuilder, setup: garage.Setup): the setup's gear into a
// mesh being built
func m.build(b, setup){
  if(setup.bumper == "bar"){
    bumper_bar(b)
  } else if(setup.bumper == "winch"){
    bumper_winch(b)
  } else {
    bumper_stock(b)
  }
  if(setup.sides == "sliders"){
    sliders(b)
  } else if(setup.sides == "steps"){
    steps(b)
  }
  if(setup.flaps == "flaps"){
    flaps(b)
  }
  if(setup.snorkel == "snorkel"){
    snorkel(b)
  }
  // the roof's load, and where a light bar then sits
  local bar_y = body.ROOF + 0.012
  local bar_z = 0.5
  if(setup.roof == "rack"){
    rack_basket(b)
    bar_y = body.ROOF + 0.2
    bar_z = 0.55
  } else if(setup.roof == "expedition"){
    bar_y = load_expedition(b) - 0.045
    bar_z = 0.5
  } else if(setup.roof == "tent"){
    bar_y = load_tent(b) - 0.02
    bar_z = 0.5
  }
  if(setup.light_bar == "roof"){
    light_bar(b, bar_y, bar_z)
  }
  if(setup.spare == "tailgate"){
    spare(b, setup.wheels)
  }
}

return m
