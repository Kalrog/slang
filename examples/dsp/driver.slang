// driver: who works the clutch and the gears of programs/inline4.dsp,
// for the car app (car.slang) and tool/drive.slang.
//
//   local driver = require("driver").new({automatic: true})
//   driver.pedal = 1                  // the throttle the foot asks for
//   driver:shift_to(2)                // (or the automatic does)
//   local c = driver:step(dt, rpm, kmh)
//   // c.throttle, c.clutch, c.gear, c.brake: the program's controls
//
// A shift lifts off the throttle and presses the clutch (SHIFT_OUT
// seconds), changes the gear and lets the clutch out (SHIFT_IN seconds),
// blipping the throttle on a downshift so the revs meet the lower gear.
// Pulling away the clutch bites as the revs rise, and it opens again
// below 1100 rpm at walking pace, so the engine idles when the car stops.
// The automatic shifts up at 6200 rpm and down when the revs fall low
// (later the harder the throttle is pressed).
local math = require("slang/math")

local driver = {}

driver.SHIFT_OUT = 0.12
driver.SHIFT_IN = 0.3

local methods = {}
local meta = {__index: methods, __type: "driver"}

// new(options?: {automatic?: bool}) -> Driver
func driver.new(options){
  return {
    gear: 0,
    automatic: (options or {}).automatic == true,
    pedal: 0.0,
    brake: 0.0,
    shift: null,
    @meta: meta,
  }
}

// shift_to(gear): starts a shift (0 neutral, 1-6), unless one is under way
func methods.shift_to(self, gear){
  if(self.shift == null and gear >= 0 and gear <= 6 and gear != self.gear){
    self.shift = {to: gear, from: self.gear, t: 0.0}
  }
}

// whether a shift is under way
func methods.shifting(self){
  return self.shift != null
}

// step(dt, rpm, kmh) -> {throttle, clutch, gear, brake}
// The controls for the next dt seconds, from the engine's rpm and the
// car's speed now.
func methods.step(self, dt, rpm, kmh){
  local throttle = self.pedal
  // pulling away: slipping until the revs are up
  local clutch = 1.0
  if(kmh <= 25){
    clutch = math.clamp((rpm - 1100) / 1400, 0, 1)
  }
  local s = self.shift
  if(s != null){
    s.t = s.t + dt
    if(s.t < driver.SHIFT_OUT){
      clutch = 0.0
      throttle = 0.0
    } else {
      self.gear = s.to
      local k = math.clamp((s.t - driver.SHIFT_OUT) / driver.SHIFT_IN, 0, 1)
      clutch = math.min(clutch, k)
      if(s.to < s.from and s.to > 0 and k < 1){
        // a blip, so the revs meet the lower gear
        throttle = 0.5
      } else {
        throttle = throttle * k
      }
      if(k >= 1){
        self.shift = null
      }
    }
  } else if(self.automatic){
    if(self.gear == 0 and self.pedal > 0){
      self:shift_to(1)
    } else if(self.gear > 0 and self.gear < 6 and rpm > 6200){
      self:shift_to(self.gear + 1)
    } else if(self.gear > 1 and rpm < 1700 + self.pedal * 1500){
      self:shift_to(self.gear - 1)
    }
  }
  return {
    throttle: throttle, clutch: clutch, gear: self.gear, brake: self.brake
  }
}

return driver
