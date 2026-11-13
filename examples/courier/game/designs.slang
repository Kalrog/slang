// game/designs: what the cars look like, with no window. A design is a
// size class (the box its physics has) and a list of parts in the car's
// own frame (forward +z, +x its left, up +y, centered in its box): lofts
// (profiles along z, smooth), boxes, and lights. A part's color is fixed
// or a slot the car's palette fills ("body", "accent", "light"), so one
// mesh serves every car of a design (game/render draws them instanced,
// the shader painting the slots).
//
// The traffic's designs come in classes, from the compact city pods to
// freighters twice as long as a saloon; the cars flying free (the
// player's, the flyers, rivals and targets) share the player's box and
// are designs of their own.
local math = require("slang/math")

local m = {}

// what a part is, for the shader (the city's kinds, and the cars')
m.NEON = 1
m.DARK = 2
m.METAL = 6
// a METAL part with this seed is glass
m.GLASS = 7

// the size classes: half extents of the physics box, and how often the
// traffic has one
m.CLASSES = {
  compact: {half: {x: 1.0, y: 0.75, z: 1.8}, weight: 0.2},
  standard: {half: {x: 1.25, y: 0.85, z: 2.3}, weight: 0.45},
  van: {half: {x: 1.35, y: 1.2, z: 2.8}, weight: 0.15},
  long: {half: {x: 1.3, y: 0.85, z: 3.6}, weight: 0.07},
  freight: {half: {x: 1.6, y: 1.6, z: 5.2}, weight: 0.13},
}
m.CLASS_ORDER = {"compact", "standard", "van", "long", "freight"}

// the colors that are not the palette's
local RED = {255, 40, 70}
local WARM = {255, 236, 200}
local CYAN = {0, 220, 255}
local MAGENTA = {255, 50, 170}
local AMBER = {255, 150, 50}
local GLASS_TINT = {20, 26, 38}
local TRIM = {26, 28, 36}
local CHROME = {150, 156, 172}

// ------------------------------------------------------------ parts

// a loft section: z along the car, half width and height, center height,
// the squareness (under 1 squares the corners), the center across
local func sec(z, w, h, yc, e, xc){
  return {z: z, w: w, h: h, yc: yc, e: e, xc: xc}
}

// lofted sections moved across by x (a pod on one side)
local func shifted(secs, x){
  local out = {}
  for(let local s in values(secs)){
    append(out, sec(s.z, s.w, s.h, s.yc, s.e, (s.xc or 0) + x))
  }
  return out
}

// a color or a slot: a part's paint
local func paint(part, c){
  if(type(c) == "string"){
    part.slot = c
  } else {
    part.color = c
  }
  return part
}

// the parts of a design, as it builds them
local func builder(){
  local parts = {}
  local b = {parts: parts}
  // hull(sections, paint, n?): a smooth lacquered loft
  b.hull = func(secs, c, n){
    append(parts, paint({kind: m.METAL, seed: 3, n: n or 14, sections: secs}, c))
  }
  // glass(sections, n?)
  b.glass = func(secs, n){
    append(parts, {kind: m.METAL, seed: m.GLASS, n: n or 12, sections: secs, color: GLASS_TINT})
  }
  // box(x0, y0, z0, x1, y1, z1, kind, paint)
  b.box = func(x0, y0, z0, x1, y1, z1, kind, c){
    append(parts, paint({
      x0: math.min(x0, x1), y0: math.min(y0, y1), z0: math.min(z0, z1),
      x1: math.max(x0, x1), y1: math.max(y0, y1), z1: math.max(z0, z1),
      kind: kind, seed: 3,
    }, c))
  }
  // metal(...) and light(...): a box of each
  b.metal = func(x0, y0, z0, x1, y1, z1, c){
    b.box(x0, y0, z0, x1, y1, z1, m.METAL, c)
  }
  b.light = func(x0, y0, z0, x1, y1, z1, c){
    b.box(x0, y0, z0, x1, y1, z1, m.NEON, c)
  }
  // both(f): f(side) for the left (+1) and the right (-1)
  b.both = func(f){
    f(1)
    f(-1)
  }
  // head(z, y, x0, x1, h): a headlight on each side, from x0 to x1 out,
  // its face at z
  b.head = func(z, y, x0, x1, h){
    b.both(func(s){
      b.light(s * x0, y - h / 2, z - 0.08, s * x1, y + h / 2, z, "light")
    })
  }
  // tail(z, y, w, h): a bar of red across the back at z
  b.tail = func(z, y, w, h){
    b.light(-w, y - h / 2, z, w, y + h / 2, z + 0.08, RED)
  }
  // strip(x, y, z0, z1): a line of the accent along each side, x out
  b.strip = func(x, y, z0, z1){
    b.both(func(s){
      b.light(s * x - 0.03, y - 0.04, z0, s * x + 0.03, y + 0.04, z1, "accent")
    })
  }
  // pads(y, x, zs, w, l): the hover pads underneath, glowing, at x either
  // side and each z
  b.pads = func(y, x, zs, w, l){
    for(let local z in values(zs)){
      b.both(func(s){
        b.metal(s * x - w / 2 - 0.05, y + 0.02, z - l / 2 - 0.05, s * x + w / 2 + 0.05, y + 0.1, z + l / 2 + 0.05, TRIM)
        b.light(s * x - w / 2, y - 0.02, z - l / 2, s * x + w / 2, y + 0.02, z + l / 2, "accent")
      })
    }
  }
  // nozzle(x, y, z, r, l): a round thruster pointing back from z, a glow
  // in its mouth
  b.nozzle = func(x, y, z, r, l){
    append(parts, {kind: m.METAL, seed: 3, n: 10, color: TRIM, sections: {
      sec(z - l, r, r, y, 1, x), sec(z - l + 0.06, r * 1.08, r * 1.08, y, 1, x),
      sec(z - l * 0.4, r, r, y, 1, x), sec(z, r * 0.7, r * 0.7, y, 1, x),
    }})
    b.light(x - r * 0.6, y - r * 0.6, z - l - 0.02, x + r * 0.6, y + r * 0.6, z - l + 0.02, "accent")
  }
  // mirror(z, y, x): a wing mirror on each side
  b.mirrors = func(z, y, x){
    b.both(func(s){
      b.metal(s * x, y - 0.06, z - 0.06, s * (x + 0.22), y + 0.07, z + 0.08, "body")
    })
  }
  // band(secs, z, l, c?): a pillar that follows the glass: a ring around
  // the cabin lofted from the glass's own section at z, a little larger,
  // l long
  b.band = func(secs, z, l, c){
    local a = null
    local bb = null
    for(local i = 0; i + 1 < len(secs); i = i + 1){
      if(secs[i].z <= z and secs[i + 1].z >= z){
        a = secs[i]
        bb = secs[i + 1]
      }
    }
    if(a == null){
      return
    }
    local t = (z - a.z) / math.max(0.001, bb.z - a.z)
    local w = (a.w + (bb.w - a.w) * t) * 1.04 + 0.01
    local h = (a.h + (bb.h - a.h) * t) * 1.05 + 0.01
    local yc = a.yc + (bb.yc - a.yc) * t
    local e = a.e or 0.5
    append(parts, paint({kind: m.METAL, seed: 3, n: 12, sections: {
      sec(z - l / 2, w, h, yc, e), sec(z + l / 2, w, h, yc, e),
    }}, c or "body"))
  }
  // pillars(x, y0, y1, zs, c?): posts across the side glass at each z
  b.pillars = func(x, y0, y1, zs, c){
    for(let local z in values(zs)){
      b.both(func(s){
        b.metal(s * (x - 0.04), y0, z - 0.06, s * (x + 0.03), y1, z + 0.06, c or "body")
      })
    }
  }
  // rocker(x, y, z0, z1, h?): a dark band low along each side, the body
  // two-toned
  b.rocker = func(x, y, z0, z1, h){
    local hh = (h or 0.16) / 2
    b.both(func(s){
      b.metal(s * (x - 0.06), y - hh, z0, s * (x + 0.02), y + hh, z1, TRIM)
    })
  }
  // grille(z, y, w, h): an intake at the front: dark, with bars of chrome
  b.grille = func(z, y, w, h){
    b.metal(-w, y - h / 2, z - 0.1, w, y + h / 2, z, TRIM)
    local n = 3
    for(local k = 0; k < n; k = k + 1){
      local yy = y - h / 2 + (k + 0.5) * h / n
      b.metal(-w + 0.04, yy - 0.012, z - 0.02, w - 0.04, yy + 0.012, z + 0.015, CHROME)
    }
  }
  // diffuser(z, y, w, h): fins under the tail
  b.diffuser = func(z, y, w, h){
    b.metal(-w, y - h / 2, z, w, y + h / 2, z + 0.25, TRIM)
    for(local k = -2; k <= 2; k = k + 1){
      local x = k * w / 2.5
      b.metal(x - 0.025, y - h / 2 - 0.04, z - 0.04, x + 0.025, y + h / 2, z + 0.3, TRIM)
    }
  }
  // antenna(x, y, z, h): a thin whip with a lit tip
  b.antenna = func(x, y, z, h){
    b.metal(x - 0.015, y, z - 0.015, x + 0.015, y + h, z + 0.015, TRIM)
    b.light(x - 0.03, y + h, z - 0.03, x + 0.03, y + h + 0.05, z + 0.03, RED)
  }
  return b
}

// ------------------------------------------------------------ the traffic

// a rounded saloon: the commuter's car, the most common
local func saloon(b){
  b.hull({sec(-2.3, 1.0, 0.3, -0.42, 0.5), sec(-2.05, 1.2, 0.42, -0.36, 0.5), sec(-0.6, 1.25, 0.46, -0.34, 0.5),
    sec(1.0, 1.22, 0.42, -0.36, 0.5), sec(1.8, 1.12, 0.32, -0.42, 0.55), sec(2.3, 0.86, 0.18, -0.48, 0.6)}, "body")
  local cabin = {sec(-1.6, 0.86, 0.1, 0.1, 0.6), sec(-1.2, 1.0, 0.42, 0.26, 0.6), sec(0.5, 0.98, 0.4, 0.27, 0.6), sec(1.2, 0.8, 0.1, 0.1, 0.6)}
  b.glass(cabin)
  // the pillar between the windows, a panel line along the doors, a
  // two-tone skirt
  b.band(cabin, -0.35, 0.14)
  b.metal(-1.27, -0.38, -1.6, 1.27, -0.34, 1.5, TRIM)
  b.rocker(1.24, -0.66, -1.9, 1.9)
  b.grille(2.27, -0.6, 0.45, 0.16)
  b.diffuser(-2.38, -0.7, 0.7, 0.12)
  b.antenna(-0.4, 0.55, -1.3, 0.5)
  b.head(2.24, -0.44, 0.35, 0.85, 0.12)
  b.tail(-2.32, -0.38, 0.95, 0.12)
  b.strip(1.27, -0.55, -1.8, 1.8)
  b.mirrors(0.95, 0.0, 1.0)
  b.pads(-0.82, 0.7, {-1.3, 1.2}, 0.45, 0.6)
}

// a low wedge: sharp nose, a wing over the tail
local func wedge(b){
  b.hull({sec(-2.3, 1.08, 0.24, -0.5, 0.45), sec(-1.85, 1.25, 0.35, -0.45, 0.45), sec(0.5, 1.22, 0.33, -0.48, 0.5),
    sec(1.6, 1.08, 0.24, -0.54, 0.55), sec(2.2, 0.75, 0.1, -0.6, 0.6), sec(2.35, 0.5, 0.05, -0.62, 0.6)}, "body")
  b.glass({sec(-1.05, 0.66, 0.08, -0.12, 0.7), sec(-0.45, 0.8, 0.3, -0.02, 0.7), sec(0.6, 0.76, 0.26, -0.06, 0.7), sec(1.35, 0.5, 0.06, -0.22, 0.7)})
  // the wing on two struts
  b.both(func(s){
    b.metal(s * 0.75, -0.2, -2.15, s * 0.85, 0.15, -1.95, TRIM)
    // an intake on each flank
    b.metal(s * 1.2, -0.62, -0.9, s * 1.27, -0.4, 0.1, TRIM)
  })
  b.metal(-1.15, 0.15, -2.3, 1.15, 0.22, -1.85, "body")
  b.light(-1.15, 0.22, -2.3, 1.15, 0.25, -2.25, "accent")
  b.rocker(1.2, -0.72, -1.8, 1.6, 0.12)
  b.diffuser(-2.4, -0.68, 0.8, 0.1)
  b.head(2.12, -0.58, 0.3, 0.75, 0.06)
  b.tail(-2.34, -0.42, 1.0, 0.08)
  b.strip(1.24, -0.62, -1.6, 1.5)
  b.pads(-0.82, 0.75, {-1.4, 1.1}, 0.5, 0.6)
}

// a coupe: a long hood, a fastback, twin thrusters
local func coupe(b){
  b.hull({sec(-2.3, 1.0, 0.3, -0.36, 0.45), sec(-1.9, 1.22, 0.4, -0.34, 0.45), sec(-0.2, 1.25, 0.38, -0.4, 0.5),
    sec(1.4, 1.18, 0.3, -0.46, 0.5), sec(2.1, 0.95, 0.18, -0.52, 0.55), sec(2.32, 0.7, 0.08, -0.55, 0.6)}, "body")
  local cabin = {sec(-2.0, 0.6, 0.05, 0.02, 0.65), sec(-1.2, 0.84, 0.28, 0.12, 0.65), sec(-0.1, 0.86, 0.3, 0.12, 0.65), sec(0.6, 0.62, 0.05, -0.04, 0.65)}
  b.glass(cabin)
  b.nozzle(0.55, -0.35, -1.9, 0.22, 0.55)
  b.nozzle(-0.55, -0.35, -1.9, 0.22, 0.55)
  // a vent on the hood
  b.metal(-0.35, -0.08, 0.9, 0.35, -0.03, 1.6, TRIM)
  b.band(cabin, -0.45, 0.12)
  b.rocker(1.22, -0.7, -1.8, 1.9, 0.12)
  b.grille(2.3, -0.62, 0.35, 0.1)
  b.head(2.25, -0.5, 0.45, 0.95, 0.08)
  b.tail(-2.33, -0.18, 1.0, 0.06)
  b.strip(1.26, -0.45, -1.4, 2.0)
  b.mirrors(0.75, -0.05, 1.05)
  b.pads(-0.82, 0.8, {1.2}, 0.5, 0.6)
}

// a taxi: the saloon in amber, a sign on the roof, checks down the side
local func taxi(b){
  saloon(b)
  b.metal(-0.45, 0.68, -0.4, 0.45, 0.72, 0.2, TRIM)
  b.light(-0.4, 0.72, -0.35, 0.4, 0.95, 0.15, AMBER)
  for(local k = 0; k < 6; k = k + 1){
    local z = -1.2 + k * 0.42
    local y = if(k % 2 == 0){ -0.22 } else { -0.3 }
    b.both(func(s){
      b.metal(s * 1.24, y - 0.04, z, s * 1.29, y + 0.04, z + 0.21, TRIM)
    })
  }
}

// a patrol car: dark, white doors, a bar of red and blue on the roof
local func patrol(b){
  b.hull({sec(-2.3, 1.02, 0.3, -0.42, 0.45), sec(-2.05, 1.22, 0.42, -0.36, 0.45), sec(-0.6, 1.25, 0.46, -0.34, 0.45),
    sec(1.0, 1.22, 0.42, -0.36, 0.45), sec(1.8, 1.14, 0.3, -0.42, 0.5), sec(2.3, 0.9, 0.18, -0.48, 0.55)}, {28, 30, 40})
  local cabin = {sec(-1.6, 0.86, 0.1, 0.1, 0.6), sec(-1.2, 1.0, 0.42, 0.26, 0.6), sec(0.5, 0.98, 0.4, 0.27, 0.6), sec(1.2, 0.8, 0.1, 0.1, 0.6)}
  b.glass(cabin)
  b.band(cabin, -0.35, 0.14, {28, 30, 40})
  b.both(func(s){
    b.metal(s * 1.22, -0.6, -1.1, s * 1.29, -0.12, 0.9, {210, 214, 224})
  })
  b.metal(-0.75, 0.68, -0.35, 0.75, 0.74, 0.15, TRIM)
  b.light(0.05, 0.74, -0.3, 0.7, 0.88, 0.1, RED)
  b.light(-0.7, 0.74, -0.3, -0.05, 0.88, 0.1, {40, 90, 255})
  // a push bar, a spotlight by the mirror, antennas
  b.metal(-0.9, -0.75, 2.25, 0.9, -0.45, 2.38, TRIM)
  b.light(0.95, 0.05, 0.85, 1.12, 0.17, 1.02, WARM)
  b.antenna(-0.5, 0.55, -1.4, 0.7)
  b.antenna(0.5, 0.55, -1.4, 0.5)
  b.head(2.24, -0.4, 0.35, 0.85, 0.1)
  b.tail(-2.32, -0.38, 0.95, 0.12)
  b.strip(1.27, -0.66, -1.8, 1.8)
  b.pads(-0.82, 0.7, {-1.3, 1.2}, 0.45, 0.6)
}

// a city pod: a bubble of glass on a round tub, one ring thruster
local func bubble(b){
  b.hull({sec(-1.8, 0.6, 0.25, -0.35, 0.8), sec(-1.6, 0.85, 0.4, -0.32, 0.8), sec(-0.6, 0.98, 0.45, -0.32, 0.8),
    sec(0.8, 0.95, 0.42, -0.34, 0.8), sec(1.5, 0.8, 0.32, -0.38, 0.85), sec(1.8, 0.5, 0.15, -0.42, 0.9)}, "body", 16)
  b.glass({sec(-1.1, 0.6, 0.05, 0.05, 0.95), sec(-0.8, 0.82, 0.45, 0.15, 0.95), sec(0.4, 0.84, 0.5, 0.12, 0.95), sec(1.25, 0.55, 0.06, -0.02, 0.95)}, 16)
  b.nozzle(0, -0.25, -1.55, 0.3, 0.35)
  b.rocker(0.96, -0.55, -1.4, 1.4, 0.1)
  b.head(1.75, -0.38, 0.15, 0.6, 0.08)
  b.tail(-1.82, -0.15, 0.45, 0.06)
  b.strip(0.98, -0.42, -1.2, 1.2)
  b.pads(-0.72, 0.55, {-0.9, 0.9}, 0.35, 0.45)
}

// a boxy little runabout: tall windows, a flat back
local func mini(b){
  b.hull({sec(-1.8, 0.95, 0.68, -0.05, 0.3), sec(-1.65, 1.0, 0.72, -0.03, 0.3), sec(0.9, 1.0, 0.7, -0.05, 0.3),
    sec(1.45, 0.96, 0.48, -0.25, 0.35), sec(1.8, 0.85, 0.3, -0.38, 0.4)}, "body")
  b.glass({sec(-1.55, 0.98, 0.25, 0.4, 0.3), sec(0.75, 0.98, 0.25, 0.4, 0.3), sec(1.05, 0.9, 0.12, 0.25, 0.4)})
  // a rack on the roof
  b.both(func(s){
    b.metal(s * 0.6, 0.72, -1.4, s * 0.68, 0.78, 0.6, CHROME)
  })
  for(let local z in values({-1.1, -0.3, 0.4})){
    b.metal(-0.68, 0.76, z, 0.68, 0.8, z + 0.08, CHROME)
  }
  b.pillars(0.99, 0.18, 0.62, {-0.4, 0.45})
  b.rocker(0.98, -0.62, -1.6, 1.6, 0.2)
  b.grille(1.82, -0.5, 0.35, 0.14)
  b.head(1.78, -0.32, 0.4, 0.82, 0.14)
  b.tail(-1.82, -0.1, 0.85, 0.1)
  b.strip(1.0, -0.55, -1.5, 1.4)
  b.pads(-0.72, 0.6, {-1.0, 1.0}, 0.4, 0.5)
}

// the hauler: a tall van, the cab at the front
local func hauler(b){
  b.hull({sec(-2.8, 1.22, 1.08, -0.1, 0.25), sec(-2.65, 1.33, 1.15, -0.05, 0.25), sec(1.7, 1.33, 1.15, -0.05, 0.25),
    sec(2.4, 1.25, 0.9, -0.28, 0.3), sec(2.8, 1.1, 0.6, -0.5, 0.35)}, "body")
  b.glass({sec(1.5, 1.2, 0.12, 0.72, 0.4), sec(1.9, 1.24, 0.32, 0.55, 0.4), sec(2.45, 1.14, 0.22, 0.38, 0.4), sec(2.6, 1.0, 0.06, 0.3, 0.4)})
  // ribs down the cargo box, a door at the back
  for(local k = 0; k < 5; k = k + 1){
    local z = -2.3 + k * 0.85
    b.both(func(s){
      b.metal(s * 1.31, -0.9, z, s * 1.37, 0.95, z + 0.12, TRIM)
    })
  }
  b.metal(-1.0, -0.9, -2.86, 1.0, 0.9, -2.8, TRIM)
  b.rocker(1.34, -1.0, -2.6, 2.6, 0.24)
  b.grille(2.82, -0.85, 0.6, 0.2)
  b.head(2.78, -0.62, 0.45, 1.0, 0.16)
  b.tail(-2.88, -0.85, 1.15, 0.14)
  // marker lights along the roof's edges
  b.both(func(s){
    b.light(s * 1.12, 1.12, -2.6, s * 1.2, 1.18, 1.4, "accent")
  })
  b.strip(1.36, -0.95, -2.5, 2.4)
  b.pads(-1.18, 0.85, {-1.9, 0.0, 1.9}, 0.5, 0.7)
}

// a medic van: white, a band of the accent, amber lights on the roof
local func medic(b){
  b.hull({sec(-2.8, 1.22, 1.08, -0.1, 0.25), sec(-2.65, 1.33, 1.15, -0.05, 0.25), sec(1.2, 1.33, 1.15, -0.05, 0.25),
    sec(2.2, 1.25, 0.75, -0.42, 0.3), sec(2.8, 1.05, 0.45, -0.62, 0.35)}, {205, 210, 220})
  b.glass({sec(1.05, 1.2, 0.1, 0.62, 0.4), sec(1.35, 1.24, 0.38, 0.42, 0.4), sec(2.15, 1.14, 0.2, 0.0, 0.4), sec(2.4, 1.0, 0.06, -0.12, 0.4)})
  b.both(func(s){
    b.light(s * 1.31, 0.15, -2.6, s * 1.36, 0.3, 1.1, "accent")
    // a cross on each flank
    b.light(s * 1.31, -0.5, -1.0, s * 1.37, 0.0, -0.84, RED)
    b.light(s * 1.31, -0.33, -1.17, s * 1.37, -0.17, -0.67, RED)
  })
  b.light(-1.0, 1.1, 0.9, -0.3, 1.25, 1.15, AMBER)
  b.light(0.3, 1.1, 0.9, 1.0, 1.25, 1.15, AMBER)
  b.head(2.75, -0.72, 0.45, 1.0, 0.14)
  b.tail(-2.88, -0.85, 1.15, 0.14)
  b.pads(-1.18, 0.85, {-1.9, 0.0, 1.9}, 0.5, 0.7)
}

// a limousine: long and low, a row of dark windows, chrome
local func limo(b){
  b.hull({sec(-3.6, 1.0, 0.28, -0.4, 0.45), sec(-3.3, 1.24, 0.42, -0.34, 0.45), sec(2.0, 1.27, 0.42, -0.36, 0.45),
    sec(3.0, 1.16, 0.32, -0.44, 0.5), sec(3.6, 0.85, 0.16, -0.5, 0.55)}, "body")
  local cabin = {sec(-2.8, 1.0, 0.08, 0.1, 0.55), sec(-2.5, 1.08, 0.36, 0.2, 0.55), sec(1.4, 1.08, 0.36, 0.2, 0.55), sec(2.2, 0.85, 0.06, 0.06, 0.55)}
  b.glass(cabin)
  // pillars between the windows
  for(let local z in values({-1.5, -0.3, 0.8})){
    b.band(cabin, z, 0.14)
  }
  b.both(func(s){
    b.metal(s * 1.26, -0.32, -3.2, s * 1.31, -0.27, 3.1, CHROME)
  })
  b.metal(-0.6, -0.3, 3.55, 0.6, -0.12, 3.62, CHROME)
  b.grille(3.62, -0.58, 0.5, 0.14)
  b.rocker(1.27, -0.7, -3.3, 3.3, 0.12)
  b.head(3.55, -0.42, 0.55, 1.0, 0.08)
  b.tail(-3.62, -0.35, 1.0, 0.08)
  b.strip(1.28, -0.6, -3.0, 3.0)
  b.pads(-0.82, 0.75, {-2.6, 0.0, 2.4}, 0.45, 0.6)
}

// a bus: a long tall box, a band of windows, a sign over the front
local func bus(b){
  b.hull({sec(-5.2, 1.48, 1.45, 0.0, 0.2), sec(-5.0, 1.58, 1.55, 0.0, 0.2), sec(4.4, 1.58, 1.55, 0.0, 0.2),
    sec(5.0, 1.5, 1.4, -0.08, 0.25), sec(5.2, 1.38, 1.2, -0.2, 0.3)}, "body", 16)
  b.both(func(s){
    for(local k = 0; k < 9; k = k + 1){
      local z = -4.4 + k * 0.98
      b.metal(s * 1.58, 0.05, z, s * 1.64, 1.0, z + 0.12, "body")
    }
    b.light(s * 1.58, -0.25, -4.8, s * 1.63, -0.15, 4.8, "accent")
  })
  // the glass band, as one glass part per side
  b.both(func(s){
    append(b.parts, {x0: math.min(s * 1.55, s * 1.61), y0: 0.12, z0: -4.6, x1: math.max(s * 1.55, s * 1.61), y1: 0.95, z1: 4.3,
      kind: m.METAL, seed: m.GLASS, color: GLASS_TINT})
  })
  b.glass({sec(4.3, 1.4, 0.05, 0.6, 0.3), sec(4.6, 1.45, 0.5, 0.45, 0.3), sec(5.05, 1.3, 0.4, 0.35, 0.3), sec(5.15, 1.2, 0.05, 0.3, 0.3)})
  b.light(-1.0, 1.15, 5.05, 1.0, 1.4, 5.12, AMBER)
  b.head(5.18, -0.95, 0.6, 1.3, 0.18)
  b.tail(-5.24, -1.0, 1.35, 0.18)
  b.both(func(s){
    b.light(s * 1.36, 1.5, -4.5, s * 1.46, 1.56, 4.0, "accent")
  })
  b.pads(-1.58, 1.0, {-3.6, -1.2, 1.2, 3.6}, 0.6, 0.9)
}

// a freighter: a cab at the front, a ribbed container behind it
local func freighter(b){
  // the cab
  b.hull({sec(2.6, 1.45, 1.1, -0.45, 0.3), sec(2.8, 1.55, 1.2, -0.4, 0.3), sec(4.4, 1.55, 1.2, -0.4, 0.3),
    sec(4.95, 1.45, 0.9, -0.6, 0.35), sec(5.2, 1.3, 0.55, -0.85, 0.4)}, "body", 16)
  b.glass({sec(4.0, 1.4, 0.1, 0.55, 0.4), sec(4.3, 1.45, 0.35, 0.38, 0.4), sec(4.85, 1.35, 0.25, 0.05, 0.4), sec(5.0, 1.25, 0.05, -0.05, 0.4)})
  // the coupling
  b.metal(-0.4, -1.2, 2.2, 0.4, -0.6, 2.7, TRIM)
  // the container: ribs and corner posts
  b.metal(-1.5, -1.3, -5.2, 1.5, 1.55, 2.2, {70, 76, 90})
  for(local k = 0; k < 11; k = k + 1){
    local z = -5.0 + k * 0.68
    b.both(func(s){
      b.metal(s * 1.5, -1.25, z, s * 1.57, 1.5, z + 0.1, {58, 62, 74})
    })
  }
  b.both(func(s){
    b.metal(s * 1.42, -1.35, -5.25, s * 1.6, 1.6, -5.05, TRIM)
    b.metal(s * 1.42, -1.35, 2.0, s * 1.6, 1.6, 2.2, TRIM)
    b.light(s * 1.56, 1.3, -5.0, s * 1.6, 1.4, 2.0, "accent")
  })
  b.light(-1.0, 1.0, -5.28, 1.0, 1.1, -5.22, RED)
  b.head(5.18, -0.95, 0.6, 1.25, 0.16)
  b.tail(-5.3, -1.15, 1.3, 0.12)
  b.pads(-1.58, 1.0, {-4.0, -1.5, 1.0, 3.7}, 0.6, 0.9)
}

// a tanker: the cab, a long round tank on a frame
local func tanker(b){
  b.hull({sec(2.6, 1.45, 1.1, -0.45, 0.3), sec(2.8, 1.55, 1.2, -0.4, 0.3), sec(4.4, 1.55, 1.2, -0.4, 0.3),
    sec(4.95, 1.45, 0.9, -0.6, 0.35), sec(5.2, 1.3, 0.55, -0.85, 0.4)}, "body", 16)
  b.glass({sec(4.0, 1.4, 0.1, 0.55, 0.4), sec(4.3, 1.45, 0.35, 0.38, 0.4), sec(4.85, 1.35, 0.25, 0.05, 0.4), sec(5.0, 1.25, 0.05, -0.05, 0.4)})
  // the frame under the tank
  b.metal(-1.2, -1.45, -5.0, 1.2, -1.2, 2.5, TRIM)
  // the tank: a loft of round sections, rounded ends
  append(b.parts, {kind: m.METAL, seed: 3, n: 18, color: CHROME, sections: {
    sec(-5.2, 0.6, 0.6, 0.05, 1), sec(-5.05, 1.25, 1.25, 0.05, 1), sec(-4.85, 1.45, 1.45, 0.05, 1),
    sec(1.8, 1.45, 1.45, 0.05, 1), sec(2.0, 1.25, 1.25, 0.05, 1), sec(2.12, 0.6, 0.6, 0.05, 1),
  }})
  // bands round the tank, a walkway on top
  for(let local z in values({-3.6, -1.5, 0.6})){
    append(b.parts, {kind: m.METAL, seed: 3, n: 18, color: TRIM, sections: {
      sec(z, 1.5, 1.5, 0.05, 1), sec(z + 0.18, 1.5, 1.5, 0.05, 1),
    }})
  }
  b.metal(-0.35, 1.48, -4.6, 0.35, 1.55, 1.6, TRIM)
  b.light(-0.3, 1.55, -4.6, 0.3, 1.58, 1.6, "accent")
  b.head(5.18, -0.95, 0.6, 1.25, 0.16)
  b.tail(-5.25, -1.3, 1.1, 0.12)
  b.pads(-1.58, 1.0, {-4.0, -1.5, 1.0, 3.7}, 0.6, 0.9)
}

// ------------------------------------------------------------ cars flying free

// the player's courier: a low wedge of a hull, a bubble canopy, two
// thruster pods, fins, light (its nozzles are game/render's NOZZLES)
local func courier(b){
  b.hull({sec(-2.2, 0.82, 0.16, 0.02, 0.45), sec(-1.9, 1.0, 0.27, 0.0, 0.45), sec(-0.7, 1.06, 0.31, -0.03, 0.45),
    sec(0.7, 1.0, 0.27, -0.08, 0.5), sec(1.7, 0.84, 0.19, -0.14, 0.55), sec(2.25, 0.5, 0.08, -0.18, 0.6)}, "body")
  b.glass({sec(-1.25, 0.44, 0.06, 0.24, 0.7), sec(-0.85, 0.6, 0.27, 0.28, 0.7), sec(0.15, 0.62, 0.29, 0.26, 0.7), sec(0.95, 0.4, 0.1, 0.2, 0.7)})
  b.both(func(s){
    // a pod: a round nacelle along the side, its nozzle at the back
    append(b.parts, {kind: m.METAL, seed: 3, n: 10, color: {28, 30, 40}, sections: {
      sec(-2.3, 0.2, 0.2, -0.12, 1, s * 1.02), sec(-2.05, 0.26, 0.25, -0.12, 1, s * 1.05),
      sec(-0.2, 0.24, 0.23, -0.12, 1, s * 1.05), sec(0.7, 0.12, 0.12, -0.14, 1, s * 1.0),
    }})
    // a fin over the pod
    append(b.parts, paint({kind: m.METAL, seed: 3, n: 6, sections: {
      sec(-2.15, 0.04, 0.24, 0.3, 0.6, s * 0.92), sec(-1.45, 0.05, 0.1, 0.18, 0.6, s * 0.95),
    }}, "body"))
    b.light(s * 1.05 - 0.02, -0.36, -1.9, s * 1.05 + 0.02, -0.33, 0.3, CYAN)
    b.light(s * 0.25, -0.2, 1.95, s * 0.62, -0.13, 2.02, WARM)
    b.light(s * 0.65 - 0.2, -0.31, 0.9, s * 0.65 + 0.2, -0.27, 1.3, CYAN)
    b.light(s * 0.65 - 0.2, -0.31, -1.5, s * 0.65 + 0.2, -0.27, -1.1, CYAN)
  })
  b.tail(-2.22, 0.07, 0.75, 0.06)
}

// a dart: a needle nose, swept wings, one big thruster
local func dart(b){
  b.hull({sec(-2.2, 0.55, 0.3, 0.0, 0.7), sec(-1.8, 0.7, 0.36, 0.0, 0.7), sec(-0.4, 0.66, 0.34, -0.02, 0.7),
    sec(1.0, 0.45, 0.24, -0.06, 0.75), sec(2.0, 0.22, 0.12, -0.1, 0.8), sec(2.25, 0.06, 0.04, -0.1, 0.8)}, "body")
  b.glass({sec(-0.6, 0.3, 0.05, 0.22, 0.8), sec(-0.3, 0.4, 0.2, 0.26, 0.8), sec(0.5, 0.38, 0.18, 0.2, 0.8), sec(1.1, 0.2, 0.04, 0.1, 0.8)})
  b.both(func(s){
    // a wing: a thin loft out to the side, swept back
    append(b.parts, paint({kind: m.METAL, seed: 3, n: 6, sections: {
      sec(-2.0, 0.42, 0.04, -0.1, 0.5, s * 0.95), sec(-1.2, 0.35, 0.05, -0.08, 0.5, s * 0.85), sec(-0.2, 0.08, 0.03, -0.06, 0.5, s * 0.6),
    }}, "body"))
    b.light(s * 1.33, -0.13, -2.05, s * 1.38, -0.07, -1.5, "accent")
  })
  b.nozzle(0, 0.0, -1.95, 0.32, 0.45)
  b.light(-0.25, -0.15, 2.0, 0.25, -0.1, 2.08, WARM)
  b.tail(-2.22, 0.3, 0.4, 0.05)
}

// an interceptor: wide and flat, four pods at the corners
local func interceptor(b){
  b.hull({sec(-2.2, 0.9, 0.2, -0.05, 0.4), sec(-1.9, 1.0, 0.3, -0.02, 0.4), sec(0.5, 0.95, 0.3, -0.05, 0.4),
    sec(1.6, 0.8, 0.2, -0.12, 0.45), sec(2.2, 0.4, 0.08, -0.16, 0.5)}, "body")
  b.glass({sec(-1.0, 0.5, 0.06, 0.2, 0.6), sec(-0.6, 0.58, 0.24, 0.22, 0.6), sec(0.6, 0.55, 0.2, 0.18, 0.6), sec(1.2, 0.35, 0.04, 0.1, 0.6)})
  b.both(func(s){
    for(let local z in values({-1.5, 1.2})){
      append(b.parts, {kind: m.METAL, seed: 3, n: 10, color: TRIM, sections: {
        sec(z - 0.5, 0.2, 0.2, -0.2, 1, s * 0.95), sec(z - 0.4, 0.26, 0.26, -0.2, 1, s * 0.95),
        sec(z + 0.4, 0.26, 0.26, -0.2, 1, s * 0.95), sec(z + 0.5, 0.18, 0.18, -0.2, 1, s * 0.95),
      }})
      b.light(s * 0.95 - 0.15, -0.47, z - 0.3, s * 0.95 + 0.15, -0.44, z + 0.3, "accent")
    }
    b.light(s * 1.0 - 0.02, 0.05, -1.8, s * 1.0 + 0.02, 0.1, 1.2, "accent")
  })
  b.light(-0.6, 0.0, 2.05, 0.6, 0.06, 2.12, WARM)
  b.tail(-2.22, 0.05, 0.8, 0.06)
}

// a skiff: a round hull, an open cockpit behind a screen, a long tail fin
local func skiff(b){
  b.hull({sec(-2.2, 0.7, 0.3, -0.05, 0.85), sec(-1.8, 0.95, 0.38, -0.05, 0.85), sec(0.0, 1.05, 0.4, -0.06, 0.85),
    sec(1.4, 0.9, 0.32, -0.1, 0.9), sec(2.2, 0.35, 0.12, -0.14, 0.95)}, "body", 16)
  b.glass({sec(0.2, 0.7, 0.04, 0.3, 0.9), sec(0.6, 0.72, 0.2, 0.32, 0.9), sec(0.9, 0.6, 0.04, 0.26, 0.9)})
  // the seats, the fin
  b.metal(-0.5, 0.2, -0.9, 0.5, 0.45, 0.1, TRIM)
  append(b.parts, paint({kind: m.METAL, seed: 3, n: 6, sections: {
    sec(-2.2, 0.04, 0.45, 0.6, 0.6), sec(-1.2, 0.05, 0.2, 0.4, 0.6), sec(-0.4, 0.03, 0.05, 0.3, 0.6),
  }}, "accent"))
  b.nozzle(0.5, -0.15, -1.9, 0.2, 0.4)
  b.nozzle(-0.5, -0.15, -1.9, 0.2, 0.4)
  b.strip(1.02, -0.1, -1.6, 1.3)
  b.light(-0.5, -0.12, 2.05, 0.5, -0.06, 2.12, WARM)
  b.tail(-2.22, 0.12, 0.5, 0.05)
}

// ------------------------------------------------------------ the catalogue

// name, class, how often among its class, the builder
m.TRAFFIC = {
  {name: "bubble", class: "compact", weight: 1, make: bubble},
  {name: "mini", class: "compact", weight: 1, make: mini},
  {name: "saloon", class: "standard", weight: 3, make: saloon},
  {name: "wedge", class: "standard", weight: 2, make: wedge},
  {name: "coupe", class: "standard", weight: 2, make: coupe},
  {name: "taxi", class: "standard", weight: 1, make: taxi},
  {name: "patrol", class: "standard", weight: 0.5, make: patrol},
  {name: "hauler", class: "van", weight: 2, make: hauler},
  {name: "medic", class: "van", weight: 0.5, make: medic},
  {name: "limo", class: "long", weight: 1, make: limo},
  {name: "bus", class: "freight", weight: 1, make: bus},
  {name: "freighter", class: "freight", weight: 1.5, make: freighter},
  {name: "tanker", class: "freight", weight: 0.7, make: tanker},
}

// the cars flying free: the player's box (game/car HALF)
m.FREE = {
  {name: "courier", make: courier},
  {name: "dart", make: dart},
  {name: "interceptor", make: interceptor},
  {name: "skiff", make: skiff},
}

// parts(design, palette?: {body, light, accent}) -> the parts, the slots
// kept (part.slot) and, with a palette, their colors filled in
func m.parts(design, palette){
  local b = builder()
  design.make(b)
  if(palette != null){
    for(let local part in values(b.parts)){
      if(part.slot == "body"){
        part.color = palette[0]
      } else if(part.slot == "light"){
        part.color = palette[1]
      } else if(part.slot == "accent"){
        part.color = palette[2]
      } else if(part.color == null){
        part.color = TRIM
      }
    }
  }
  return b.parts
}

// half(design) -> the half extents of a traffic design's box
func m.half(design){
  return m.CLASSES[design.class].half
}

// pick(rng) -> the index of a traffic design: a class by its weight,
// then a design of it by its weight
func m.pick(rng){
  local r = rng:next()
  local class = "standard"
  for(let local name in values(m.CLASS_ORDER)){
    local w = m.CLASSES[name].weight
    if(r < w){
      class = name
      break
    }
    r = r - w
  }
  local total = 0
  for(let local d in values(m.TRAFFIC)){
    if(d.class == class){
      total = total + d.weight
    }
  }
  local x = rng:next() * total
  local last = 0
  for(local i = 0; i < len(m.TRAFFIC); i = i + 1){
    local d = m.TRAFFIC[i]
    if(d.class == class){
      last = i
      if(x < d.weight){
        return i
      }
      x = x - d.weight
    }
  }
  return last
}

return m
