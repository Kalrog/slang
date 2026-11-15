// tool/scenes/driveline_whine: the gears alone, by hand: a pull through
// the five gears in high range (each 1200 to 4200 rpm under load, then a
// moment without), fifth on the overrun, second in low range (a pull,
// then held at 3000 rpm with little load, then the overrun), and
// reverse up to 3000 rpm and back. The listener is behind the truck.
// Arguments: "gears" (without the axles' hum) or "axles" (the hum alone).
local math = require("slang/math")

// the gears' teeth and ratios (sound/layers/driveline, game/drivetrain)
local TEETH = {50, 47, 41, 40, 34}
local GEARS = {4.17, 2.34, 1.52, 1.14, 0.87}

return func(kit, args){
  local part = args[0] or "all"
  return kit.mix(46, func(t, set, send){
    local gear = 1
    local rpm = 0
    local torque = 0
    local reverse = 0
    local low = 0
    if(t < 20){
      gear = math.min(5, to_int(t / 4) + 1)
      local k = (t - (gear - 1) * 4) / 4
      rpm = 1200 + 3000 * math.min(k / 0.85, 1)
      torque = if(k < 0.85){ 0.9 } else { 0 }
    } else if(t < 26){
      gear = 5
      rpm = 4200 - 2700 * (t - 20) / 6
      torque = -0.25
    } else if(t < 27){
      rpm = 0
    } else if(t < 39){
      gear = 2
      low = 1
      if(t < 32){
        rpm = 1000 + 3000 * (t - 27) / 5
        torque = 1
      } else if(t < 36){
        rpm = 3000
        torque = 0.12
      } else {
        rpm = 3000 - 2000 * (t - 36) / 3
        torque = -0.3
      }
    } else if(t < 40){
      rpm = 0
    } else {
      gear = 0
      reverse = 1
      rpm = 900 + 2100 * math.sin((t - 40) / 6 * math.pi)
      torque = 0.5
    }
    local ratio = if(reverse == 1){ 3.72 } else { GEARS[gear - 1] }
    local shaft = rpm / 60 / ratio
    local whole = ratio * 4.10 * (if(low == 1){ 2.72 } else { 1 })
    set("driveline_shaft", shaft)
    set("driveline_prop", if(low == 1){ shaft / 2.72 } else { shaft })
    set(
      "driveline_teeth",
      if(part == "axles"){ 0 } else if(reverse == 1){ 48 } else { TEETH[gear - 1] },
    )
    set("driveline_ratio", ratio)
    set("driveline_torque", if(part == "axles"){ 0 } else { torque })
    set(
      "driveline_pull",
      if(part == "gears"){ 0 } else { torque * whole / (2.34 * 4.10) },
    )
    set("driveline_low", low)
    set("driveline_reverse", reverse)
    for(let local name in values({"mid", "front", "rear"})){
      set(concat("driveline_", name, "_left"), 0.6)
      set(concat("driveline_", name, "_right"), 0.6)
    }
  }, {only: {"driveline"}})
}
