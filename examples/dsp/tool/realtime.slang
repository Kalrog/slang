// Plays the car (vehicle.slang) on the audio device for 22 s (the
// automatic driving: idle, flat out through the gears, braking) and prints
// the stream once a second: the load, the slowest block, the underruns.
// The test suite checks the kernel keeps up without a device
// (test/dsp_test.slang); this checks the whole path to the speakers,
// which also depends on the machine and what else it is doing.
//
//   slang run tool/realtime.slang
//
// The first 2 s are start-up (loading the program in the audio isolate);
// the last line counts the underruns after them. CAR_INSIDE=1 listens
// from the driver's seat.
local kernel = require("kernel")
local time = require("slang/time")
local stream = require("raylib/stream")
local vehicle = require("vehicle")
local controls = vehicle.controls()
local params = kernel.double:array(len(controls), {shared: true})
local slot = {}
for(local i = 0; i < len(controls); i = i + 1){
  params[i] = controls[i].control.init
  slot[controls[i].label] = i
}
// the listener: CAR_INSIDE=1 in the driver's seat
local os = require("slang/os")
if(os.getenv("CAR_INSIDE") != null){
  params[slot.listener] = 1
}
local probe = kernel.double:array(2, {shared: true})
local player = stream.play(func(params, probe){
  local vehicle = require("vehicle")
  local car = vehicle.new({sample_rate: 48000, block: 1024})
  return func(out, frames){
    for(local i = 0; i < len(car.controls); i = i + 1){
      local c = car.controls[i]
      c.instance.state[c.control.field] = params[i]
    }
    car:compute(frames)
    for(local i = 0; i < frames; i = i + 1){
      out[2 * i] = car.left[i]
      out[2 * i + 1] = car.right[i]
    }
    probe[0] = car.engine_out[vehicle.RPM][frames - 1]
    probe[1] = car.engine_out[vehicle.KMH][frames - 1]
  }
}, {args: {params, probe}, sample_rate: 48000, channels: 2, block: 128})
local driver = require("driver").new({automatic: true})
local t0 = time.clock()
local last = 0.0
local base = null
for(time.clock() - t0 < 22000){
  local t = (time.clock() - t0) / 1000
  driver.pedal = if(t > 2 and t < 16){ 1.0 } else { 0.0 }
  driver.brake = if(t > 16){ 0.7 } else { 0.0 }
  local c = driver:step(0.01, probe[0], probe[1])
  params[slot.throttle] = c.throttle
  params[slot.clutch] = c.clutch
  params[slot.gear] = c.gear
  params[slot.brake] = c.brake
  if(t - last >= 1){
    last = t
    local s = player:stats()
    if(base == null and t >= 2){ base = s.underruns }
    print(concat(
      string(to_int(t)), " s: gear ", string(c.gear), ", ",
      string(to_int(probe[0])), " rpm, ", string(to_int(probe[1])),
      " km/h, load ", string(to_int(s.load * 1000) / 10.0), "%, worst block ",
      string(to_int(s.peak * 1000) / 10.0), "%, underruns ",
      string(s.underruns), "\n"
    ))
  }
  time.sleep(10)
}
local s = player:stats()
print(concat(
  "underruns after the first 2 s: ",
  string(s.underruns - base),
  "\n",
))
player:stop()
