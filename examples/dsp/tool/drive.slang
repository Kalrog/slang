// Drives the car (vehicle.slang: programs/inline4.dsp heard through
// programs/acoustics.dsp) through a little script and writes it to two WAV
// files, as heard beside the road and in the driver's seat (no window, no
// audio device):
//
//   slang run tool/drive.slang [name] [road]
//
// writes name_outside.wav and name_inside.wav (name: drive by default);
// road is 0 smooth asphalt (the default), 1 coarse chip seal, 2 cobbles.
// The script: the engine starts and idles; full throttle from a standing
// start, the automatic shifting up (driver.slang works the clutch); off
// the throttle at 120 km/h, a coast, braking to a stop (the automatic
// shifting down, blipping the throttle); idling again. Prints the time,
// gear, rpm, speed and level twice a second.
local kernel = require("kernel")
local math = require("slang/math")
local time = require("slang/time")
local str = require("slang/string")
local wav = require("wav")
local vehicle = require("vehicle")

local RATE = 48000
local BLOCK = 128
local MAX_SECONDS = 40
local name = args()[0] or "drive"
local road = to_int(str.to_number(args()[1] or "0"))

local func drive(listener, verbose){
  local car = vehicle.new({sample_rate: RATE, block: BLOCK})
  car:set("listener", listener)
  car:set("road", road)
  local driver = require("driver").new({automatic: true})
  local frames = MAX_SECONDS * RATE
  local left = kernel.float:array(frames)
  local right = kernel.float:array(frames)
  local dt = BLOCK / RATE
  local phase = "idle"
  local phase_at = 0.0
  local spent = 0.0
  local sum = 0.0
  local rpm = 0.0
  local kmh = 0.0
  local at = 0
  for(at < frames){
    local t = at / RATE
    // the script
    if(phase == "idle" and t > 2.5){
      phase = "pull"
      driver.pedal = 1.0
    } else if(phase == "pull" and kmh > 120){
      phase = "coast"
      phase_at = t
      driver.pedal = 0.0
    } else if(phase == "coast" and t - phase_at > 3){
      phase = "brake"
      driver.brake = 0.6
    } else if(phase == "brake" and kmh < 0.5){
      phase = "stopped"
      phase_at = t
      driver.brake = 0.0
    } else if(phase == "stopped" and t - phase_at > 3){
      break
    }
    local c = driver:step(dt, rpm, kmh)
    car:set("throttle", c.throttle)
    car:set("clutch", c.clutch)
    car:set("gear", c.gear)
    car:set("brake", c.brake)
    local t0 = time.clock()
    car:compute(BLOCK)
    spent = spent + (time.clock() - t0)
    rpm = car.engine_out[vehicle.RPM][BLOCK - 1]
    kmh = car.engine_out[vehicle.KMH][BLOCK - 1]
    for(local i = 0; i < BLOCK; i = i + 1){
      left[at + i] = car.left[i]
      right[at + i] = car.right[i]
      sum = sum + car.left[i] * car.left[i]
    }
    at = at + BLOCK
    if(at % (RATE / 2) < BLOCK){
      if(verbose){
        print(concat(
          string(math.round(at / RATE * 10) / 10), " s ", phase, ": gear ",
          string(c.gear), ", ", string(to_int(rpm)), " rpm, ",
          string(to_int(kmh)), " km/h, rms ",
          string(math.round(math.sqrt(sum / (RATE / 2)) * 1000) / 1000), "\n"
        ))
      }
      sum = 0.0
    }
  }
  local seconds = at / RATE
  local file = concat(
    name, if(listener > 0){ "_inside" } else { "_outside" }, ".wav"
  )
  // (a method call in a table literal would read as a field: locals first)
  local played_left = left:slice(0, at)
  local played_right = right:slice(0, at)
  wav.write(file, {played_left, played_right}, RATE)
  print(concat(
    file,
    ": ",
    string(math.round(seconds * 10) / 10),
    " s, ",
    string(to_int(spent / seconds)),
    " ms per second of sound\n",
  ))
}

drive(0, true)
drive(1, false)
