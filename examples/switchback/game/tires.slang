// game/tires: how much a tire can push along and across its rolling
// direction, from the ground under it and from how it slips.
//
// The physics engine holds each tire to the ground as a contact that may
// not slip, up to a limit, so a tire below its limit holds exactly: a
// truck parked across a slope stays where it is, and a slow traverse does
// not creep downhill. This module says where the limits are, once a
// step, as two friction coefficients per wheel:
//
//   local grip = tires.grip(surface, slip_ratio, side_slip, load_share)
//   grip.along, grip.across
//
// A tire that spins or slides has less than one that holds, loose ground
// gives its best only to a wheel that digs a little, and a sliding tire's
// grip goes against the slide (a spinning wheel steers badly, a wheel
// sliding sideways brakes badly).
local math = require("slang/math")

local m = {}

// below this speed slips are measured against it, so that a crawl and a
// standstill have slips of a sane size (m/s)
m.LOW_SPEED = 2.2

// slips(along_speed, across_speed, wheel_speed) -> {ratio, side}
// The slips of a tire: how much faster (or slower) its tread runs than the
// ground passes along it, and how much it slides across, both over the
// speed it travels at (not less than LOW_SPEED). All speeds in m/s; the
// wheel's is its turning speed times its radius.
func m.slips(along, across, wheel){
  local reference = math.max(math.abs(along), m.LOW_SPEED)
  return {ratio: (wheel - along) / reference, side: across / reference}
}

// grip(surface: Surface, ratio: float, side: float, load?: float)
//   -> {along: float, across: float}
// The friction coefficients a tire has along and across its rolling
// direction on a surface (game/surfaces), slipping by ratio and sliding
// sideways by side (see [slips]); load is the wheel's load over its share
// of the truck's weight (a tire carrying more grips a little less for its
// load).
//
// A tire that holds may be asked for its whole grip either way. One
// that slides has what the surface leaves a sliding tire, and has it
// against the way it slides: a spinning wheel pushes forward and hardly
// holds sideways, a locked one sliding downhill brakes and hardly
// steers.
func m.grip(surface, ratio, side, load){
  // the slips over the slip that brings the peak: 1 is the tire's limit
  local along_slip = math.abs(ratio) / surface.slip
  local across_slip = math.abs(side) / (surface.slip * 1.1)
  local slip = math.sqrt(along_slip * along_slip + across_slip * across_slip)
  local whole = surface.grip
  if(slip > 1){
    whole = whole * (surface.slide + (1 - surface.slide) * math.exp(-(slip - 1) * 0.9))
  }
  // loose ground gives its best along only to a wheel that digs
  local bite = surface.bite + (1 - surface.bite) * math.min(along_slip, 1)
  local along = whole * bite
  local across = whole
  // sliding: the grip goes against the slide
  local sliding = (slip - 0.6) / 1.0
  if(sliding > 0){
    if(sliding > 1){
      sliding = 1
    }
    sliding = sliding * sliding * (3 - 2 * sliding)
    along = along * (1 - sliding + sliding * math.max(along_slip / slip, 0.2))
    across = across * (1 - sliding + sliding * math.max(across_slip / slip, 0.2))
  }
  if(load != null){
    local k = 1.07 - 0.07 * load
    if(k < 0.86){
      k = 0.86
    } else if(k > 1.07){
      k = 1.07
    }
    along = along * k
    across = across * k
  }
  return {along: along, across: across}
}

return m
