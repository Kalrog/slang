// The car's sound in octave bands, for tuning programs/inline4.dsp and
// programs/acoustics.dsp by numbers (no window, no audio device):
//
//   slang run tool/spectrum.slang
//
// The left channel's level in each band (dB relative to a full scale
// sine), for the whole sound and for the engine (exhaust, intake,
// mechanics), the exhaust, the tyres and the wind alone, beside the road and in the driver's seat, at idle and cruising at
// 50 km/h (third gear) and 120 km/h (fifth). The exhaust's line beside the
// road is followed by its harmonics one by one: dB relative to the firing
// frequency (rpm / 30 for a four-cylinder), at half of it (differences
// between the cylinders) and 2 to 8 times it.
//
// A real car's exhaust is loudest at the firing frequency and its first
// harmonics and falls some 10 dB an octave above them; tyres take over from
// about 50 km/h, the wind from about 120 km/h; in the cabin the highs are
// gone and the lows boom.
local kernel = require("kernel")
local math = require("slang/math")
local str = require("slang/string")
local vehicle = require("vehicle")

local RATE = 48000
local BLOCK = 128
local BANDS = {31, 63, 125, 250, 500, 1000, 2000, 4000, 8000}
local N = 9600

// the power at frequency f in x (Hann window; a full scale sine gives 1)
local func power(x, f){
  local re = 0.0
  local im = 0.0
  for(local i = 0; i < N; i = i + 1){
    local w = 0.5 - 0.5 * math.cos(2 * math.pi * i / N)
    re = re + x[i] * w * math.cos(2 * math.pi * f * i / RATE)
    im = im + x[i] * w * math.sin(2 * math.pi * f * i / RATE)
  }
  return (re * re + im * im) / (N * N) * 16
}

// the power in the octave around each band's centre: bins a twelfth of
// an octave apart, averaged and scaled to the octave
local func bands(x){
  local out = {}
  for(let local fc in values(BANDS)){
    local sum = 0.0
    local k = 0
    for(local f = fc / 1.41; f < fc * 1.41; f = f * 1.06){
      sum = sum + power(x, f)
      k = k + 1
    }
    append(out, sum / k * 12)
  }
  return out
}

// the strongest power within a percent of f (rpm drifts a little)
local func power_near(x, f){
  local best = 0.0
  for(local g = f * 0.99; g <= f * 1.01; g = g + f * 0.0025){
    best = math.max(best, power(x, g))
  }
  return best
}

// the car driven to a steady kmh (0: idling in neutral) in gear, the
// controls set as given, then N samples of its left channel
local func measure(kmh, gear, settings){
  local car = vehicle.new({sample_rate: RATE, block: BLOCK})
  for(let local e in entries(settings)){
    car:set(e[0], e[1])
  }
  local driver = require("driver").new({automatic: kmh > 0})
  local cruising = false
  local rpm = 0.0
  local speed = 0.0
  local x = kernel.float:array(N)
  local seconds = if(kmh > 0){ 30 } else { 4 }
  local blocks = to_int(seconds * RATE / BLOCK)
  for(local b = 0; b < blocks; b = b + 1){
    if(kmh > 0){
      // flat out until near the speed, then the cruising gear and a
      // throttle that holds the speed
      cruising = cruising or speed > kmh - 8
      if(cruising){
        driver.automatic = false
        driver:shift_to(gear)
        driver.pedal = math.clamp(0.25 + (kmh - speed) * 0.08, 0, 1)
      } else {
        driver.pedal = 1.0
      }
    }
    local c = driver:step(BLOCK / RATE, rpm, speed)
    car:set("throttle", c.throttle)
    car:set("clutch", c.clutch)
    car:set("gear", c.gear)
    car:compute(BLOCK)
    rpm = car.engine_out[vehicle.RPM][BLOCK - 1]
    speed = car.engine_out[vehicle.KMH][BLOCK - 1]
    local at = (b - (blocks - to_int(N / BLOCK))) * BLOCK
    if(at >= 0){
      for(local i = 0; i < BLOCK; i = i + 1){
        x[at + i] = car.left[i]
      }
    }
  }
  return {samples: x, rpm: rpm, kmh: speed}
}

local func db(p){
  return to_int(math.round(10 * math.log10(p + 1e-12)))
}

// s padded with spaces to width, on the left (or the right)
local func pad(s, width, right){
  local fill = " " * math.max(0, width - len(s))
  if(right){
    return concat(s, fill)
  }
  return concat(fill, s)
}

local ENGINE = {"exhaust level", "intake level", "mechanics level"}
local PATHS = {
  {"all", {}},
  {"engine", {"tyre level", "wind level"}},
  {"exhaust", {"intake level", "mechanics level", "tyre level", "wind level"}},
  {"tyres", {...ENGINE, "wind level"}},
  {"wind", {...ENGINE, "tyre level"}},
}
local CONDITIONS = {{"idle", 0, 0}, {"50 km/h", 50, 3}, {"120 km/h", 120, 5}}

local header = {}
for(let local fc in values(BANDS)){
  append(
    header,
    pad(if(fc >= 1000){ concat(string(to_int(fc / 1000)), "k") } else { string(
      fc,
    ) }, 5),
  )
}
print(concat(
  pad("dB per octave band", 36, true), str.join(header, ""), "  Hz\n"
))
for(let local c in values(CONDITIONS)){
  for(let local where in values({{"outside", 0}, {"inside", 1}})){
    for(let local p in values(PATHS)){
      local settings = {listener: where[1]}
      for(let local m in values(p[1])){
        settings[m] = 0
      }
      local r = measure(c[1], c[2], settings)
      local cells = {}
      for(let local b in values(bands(r.samples))){
        append(cells, pad(string(db(b)), 5))
      }
      local label = concat(
        where[0], " ", p[0], " (", string(to_int(r.rpm)), " rpm, ",
        string(to_int(r.kmh)), " km/h)"
      )
      print(concat(pad(label, 36, true), str.join(cells, ""), "\n"))
      if(p[0] == "exhaust" and where[1] == 0){
        local f0 = r.rpm / 30
        local base = power_near(r.samples, f0)
        local hs = {}
        for(let local k in values({0.5, 1, 2, 3, 4, 5, 6, 8})){
          append(hs, concat(
            "x", string(k), " ",
            string(db(power_near(r.samples, f0 * k) / base))
          ))
        }
        print(concat(
          "  harmonics of ", string(to_int(f0)), " Hz: ", str.join(hs, ", "),
          "\n"
        ))
      }
    }
  }
  print("\n")
}
