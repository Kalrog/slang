// render/truck_wheels: what turns and moves under the truck: a wheel (a
// mud tire with blocks of tread on a rim of one of three kinds), the
// two axles with their differentials, a spring over a damper, and a
// plain rod for the links and the shafts between them.
//
// A wheel is built around its axle (the x axis), its outer face toward
// +x; an axle around its middle, along x; the spring and the rod one
// unit long (along y and z), to be stretched to where they reach.
local math = require("slang/math")
local vec = require("game/vec")
local kit = require("render/truck_mesh")

local m = {}
local v3 = kit.v3

m.RADIUS = 0.42
m.WIDTH = 0.29
m.RIM = 0.235

local TIRE = {20, 20, 21}

local func colored(b, material, c, param){
  b:paint(material, param)
  b:color(c[0], c[1], c[2])
}

// the tire: its carcass turned around the axle, then the tread's blocks
local func tire(b){
  local hw = m.WIDTH / 2
  local base = m.RADIUS - 0.017
  colored(b, kit.TIRE, TIRE)
  b:turned({
    {a: -0.112, r: m.RIM - 0.004}, {a: -0.128, r: m.RIM + 0.02}, {a: -hw + 0.004, r: 0.325},
    {a: -hw + 0.012, r: 0.385}, {a: -0.112, r: base, hard: true},
    {a: 0.112, r: base, hard: true}, {a: hw - 0.012, r: 0.385},
    {a: hw - 0.004, r: 0.325}, {a: 0.128, r: m.RIM + 0.02}, {a: 0.112, r: m.RIM - 0.004},
  }, 32, false)
  // the blocks: a row down the middle, a row on each shoulder set half a
  // step off and wrapping down the side
  local count = 20
  local step = 2 * math.pi / count
  for(local k = 0; k < count; k = k + 1){
    local a = k * step
    b:push(0, 0, 0, vec.quat_axis({x: 1, y: 0, z: 0}, a))
    // (y is away from the axle here, z along the tread)
    b:box(0.0, m.RADIUS - 0.012, 0, 0.084, 0.024, 0.08, 0)
    b:pop()
    b:push(0, 0, 0, vec.quat_axis({x: 1, y: 0, z: 0}, a + step / 2))
    for(let local side in values({1, -1})){
      b:box(side * 0.096, m.RADIUS - 0.014, 0, 0.07, 0.028, 0.072, 0)
      // the lug down the side
      b:box(side * (hw - 0.006), m.RADIUS - 0.05, 0, 0.022, 0.064, 0.05, 0)
    }
    b:pop()
  }
}

// behind every rim: the drum of the brake and the hub, and the inner
// side closed
local func hub(b){
  colored(b, kit.METAL, {46, 46, 48})
  b:turned({
    {a: -0.105, r: 0.0}, {a: -0.105, r: 0.2, hard: true}, {a: -0.02, r: 0.2, hard: true}, {a: -0.02, r: 0.0},
  }, 20, false)
  b:rod(v3(-0.16, 0, 0), v3(-0.1, 0, 0), 0.085, 12, 0.085, true, false)
}

// five nuts around the hub
local func nuts(b, at, radius, c){
  colored(b, kit.CHROME, c or {190, 192, 196})
  for(local k = 0; k < 5; k = k + 1){
    local a = k * 2 * math.pi / 5 + 0.3
    local y = math.cos(a) * radius
    local z = math.sin(a) * radius
    b:rod(v3(at, y, z), v3(at + 0.022, y, z), 0.013, 6, 0.011, false, true)
  }
}

// pressed steel: a dish with round holes, a domed cap
local func rim_steel(b){
  local c = {222, 218, 204}
  colored(b, kit.METAL, c, 0.45)
  b:turned({
    {a: -0.118, r: m.RIM}, {a: 0.118, r: m.RIM, hard: true}, {a: 0.13, r: m.RIM - 0.006},
    {a: 0.118, r: m.RIM - 0.022, hard: true}, {a: 0.07, r: 0.2}, {a: 0.042, r: 0.172},
    {a: 0.045, r: 0.105}, {a: 0.078, r: 0.082, hard: true}, {a: 0.078, r: 0.0},
  }, 28, false)
  // the holes: dark rounds on the dish
  colored(b, kit.MATTE, {10, 10, 11})
  for(local k = 0; k < 8; k = k + 1){
    local a = k * math.pi / 4
    b:disc(v3(0.0475, math.cos(a) * 0.14, math.sin(a) * 0.14), v3(1, 0, 0), 0.023, 10)
  }
  colored(b, kit.CHROME, {200, 202, 206})
  b:turned({
    {a: 0.078, r: 0.05}, {a: 0.1, r: 0.046}, {a: 0.115, r: 0.03}, {a: 0.12, r: 0.0},
  }, 14, false)
  nuts(b, 0.078, 0.066)
}

// black with a bolted ring that clamps the tire's bead
local func rim_beadlock(b){
  colored(b, kit.METAL, {34, 35, 38}, 0.3)
  b:turned({
    {a: -0.118, r: m.RIM}, {a: 0.112, r: m.RIM, hard: true}, {a: 0.112, r: 0.196, hard: true},
    {a: 0.086, r: 0.19}, {a: 0.07, r: 0.1}, {a: 0.088, r: 0.078, hard: true}, {a: 0.088, r: 0.0},
  }, 28, false)
  // windows between eight spokes
  colored(b, kit.MATTE, {8, 8, 9})
  for(local k = 0; k < 8; k = k + 1){
    local a0 = k * math.pi / 4 + 0.12
    local a1 = (k + 1) * math.pi / 4 - 0.12
    local func at(r, a){
      return v3(0.07 + (r - 0.1) / 0.09 * 0.016 + 0.003, math.cos(a) * r, math.sin(a) * r)
    }
    b:quad(at(0.118, a0 + 0.05), at(0.176, a0), at(0.176, a1), at(0.118, a1 - 0.05), v3(1, 0, 0))
  }
  // the ring and its bolts
  colored(b, kit.METAL, {150, 152, 158}, 0.6)
  b:turned({
    {a: 0.112, r: 0.262, hard: true}, {a: 0.126, r: 0.262, hard: true}, {a: 0.126, r: 0.2, hard: true}, {a: 0.112, r: 0.2},
  }, 28, false)
  colored(b, kit.CHROME, {200, 202, 206})
  for(local k = 0; k < 16; k = k + 1){
    local a = (k + 0.5) * math.pi / 8
    b:rod(v3(0.126, math.cos(a) * 0.232, math.sin(a) * 0.232), v3(0.134, math.cos(a) * 0.232, math.sin(a) * 0.232), 0.009, 6, 0.009, false, true)
  }
  nuts(b, 0.088, 0.058, {120, 122, 126})
}

// cast alloy: six spokes
local func rim_alloy(b){
  local c = {104, 108, 116}
  colored(b, kit.METAL, c, 0.7)
  b:turned({
    {a: -0.118, r: m.RIM}, {a: 0.118, r: m.RIM, hard: true}, {a: 0.128, r: m.RIM - 0.008},
    {a: 0.112, r: m.RIM - 0.026, hard: true}, {a: 0.02, r: 0.2, hard: true},
  }, 28, false)
  // the barrel's back, dark
  colored(b, kit.MATTE, {12, 12, 13})
  b:disc(v3(0.012, 0, 0), v3(1, 0, 0), 0.205, 20)
  colored(b, kit.METAL, {70, 70, 74}, 0.3)
  b:rod(v3(0.014, 0, 0), v3(0.03, 0, 0), 0.165, 20, 0.165, false, true)
  colored(b, kit.METAL, c, 0.7)
  for(local k = 0; k < 6; k = k + 1){
    b:push(0, 0, 0, vec.quat_axis({x: 1, y: 0, z: 0}, k * math.pi / 3))
    b:push(0.085, 0.14, 0, vec.quat_axis({x: 0, y: 0, z: 1}, 0.17))
    b:box(0, 0, 0, 0.03, 0.165, 0.062, 0.012)
    b:pop()
    b:pop()
  }
  b:turned({
    {a: 0.06, r: 0.085}, {a: 0.1, r: 0.078}, {a: 0.106, r: 0.06, hard: true}, {a: 0.106, r: 0.0},
  }, 16, false)
  nuts(b, 0.106, 0.045, {30, 30, 32})
}

local rims = {steel: rim_steel, beadlock: rim_beadlock, alloy: rim_alloy}

// wheel(b, style: string): a wheel with a rim of a garage style
func m.wheel(b, style){
  tire(b)
  hub(b)
  local rim = rims[style] or rim_steel
  rim(b)
}

// axle(b, front: bool): a live axle: the tube, the differential (off to
// the right at the front), the ends, the seats of the springs; the front
// one's steering rod
func m.axle(b, front){
  local steel = {50, 51, 55}
  colored(b, kit.METAL, steel, 0.25)
  b:rod(v3(-0.64, 0, 0), v3(0.64, 0, 0), 0.047, 10, 0.047, false, false)
  local dx = if(front){ -0.2 } else { 0 }
  local toward = if(front){ -1 } else { 1 }
  b:push(dx, 0, 0)
  b:turned({
    {a: -0.2, r: 0.05}, {a: -0.15, r: 0.1}, {a: -0.07, r: 0.15}, {a: 0.07, r: 0.15},
    {a: 0.15, r: 0.1}, {a: 0.2, r: 0.05},
  }, 14, false)
  // the nose the shaft turns, and the cover on the other side
  b:rod(v3(0, 0.01, toward * 0.1), v3(0, 0.02, toward * 0.3), 0.07, 8, 0.045, false, true)
  colored(b, kit.METAL, {74, 76, 82}, 0.5)
  b:rod(v3(0, 0, -toward * 0.1), v3(0, 0, -toward * 0.155), 0.125, 12, 0.1, false, true)
  b:pop()
  colored(b, kit.METAL, steel, 0.25)
  for(let local side in values({1, -1})){
    b:rod(v3(side * 0.6, 0, 0), v3(side * 0.66, 0, 0), 0.085, 10, 0.085, true, true)
    b:box(side * 0.5, 0.055, 0, 0.11, 0.03, 0.11, 0.008)
    // where the link takes hold
    b:box(side * 0.4, -0.05, toward * 0.03, 0.05, 0.09, 0.08, 0.008)
  }
  if(front){
    colored(b, kit.METAL, {88, 90, 94}, 0.4)
    b:rod(v3(-0.62, -0.02, -0.15), v3(0.62, -0.02, -0.15), 0.015, 6, 0.015, true, true)
    for(let local side in values({1, -1})){
      b:rod(v3(side * 0.62, -0.02, -0.15), v3(side * 0.64, 0, 0), 0.02, 6, 0.02, false, false)
    }
  }
}

// spring(b): a coil spring over a damper, from 0 to 1 along y
func m.spring(b){
  // the damper: its body below, the rod above
  colored(b, kit.METAL, {32, 60, 110}, 0.5)
  b:rod(v3(0, 0.02, 0), v3(0, 0.6, 0), 0.03, 8, 0.03, true, true)
  colored(b, kit.CHROME, {200, 202, 206})
  b:rod(v3(0, 0.6, 0), v3(0, 0.98, 0), 0.012, 6, 0.012, false, false)
  colored(b, kit.METAL, {40, 41, 44}, 0.3)
  b:rod(v3(0, 0.0, 0), v3(0, 0.04, 0), 0.07, 10, 0.07, true, true)
  b:rod(v3(0, 0.95, 0), v3(0, 1.0, 0), 0.07, 10, 0.07, true, true)
  // the coil
  colored(b, kit.METAL, {214, 168, 30}, 0.5)
  local points = {}
  local turns = 5.5
  local steps = 60
  for(local i = 0; i <= steps; i = i + 1){
    local t = i / steps
    local a = t * turns * 2 * math.pi
    append(points, v3(math.cos(a) * 0.056, 0.05 + t * 0.89, math.sin(a) * 0.056))
  }
  b:tube(points, 0.011, 5)
}

// rod(b): a plain round bar from 0 to 1 along z, one unit thick (to be
// scaled to its length and its radius)
func m.rod(b){
  colored(b, kit.METAL, {46, 47, 51}, 0.3)
  b:rod(v3(0, 0, 0), v3(0, 0, 1), 1, 8, 1, true, true)
}

return m
