// vehicle: the car as one thing to run: programs/inline4.dsp (the engine,
// the drivetrain and the car) feeding programs/acoustics.dsp (the tyres,
// the wind, and the listener beside the road or in the driver's seat).
//
//   local vehicle = require("vehicle")
//   local car = vehicle.new({sample_rate: 48000})
//   car:set("throttle", 0.5)
//   car:set("listener", 1)                 // in the driver's seat
//   car:compute(128)                       // into car.left, car.right
//   car.engine_out[vehicle.RPM][127]       // and the engine's telemetry
//
// The controls of both programs are one list, car.controls (the engine's
// first), each {label, control, instance}; set and get find a control by
// its label in either.
local kernel = require("kernel")
local inline4 = require("programs/inline4")
local acoustics = require("programs/acoustics")

local vehicle = {}

// the engine program's outputs
vehicle.EXHAUST = 0
vehicle.INTAKE = 1
vehicle.MECHANICS = 2
vehicle.VIBRATION = 3
vehicle.RPM = 4
vehicle.CYLINDER = 5
vehicle.PHASE = 6
vehicle.COLLECTOR = 7
vehicle.KMH = 8

// the controls of both programs, in order: {label, control, program}
func vehicle.controls(){
  local out = {}
  for(let local c in values(inline4.controls)){
    append(out, {label: c.label, control: c, program: "engine"})
  }
  for(let local c in values(acoustics.controls)){
    append(out, {label: c.label, control: c, program: "acoustics"})
  }
  return out
}

local methods = {}
local meta = {__index: methods, __type: "vehicle"}

// new(options?: {sample_rate?: int, block?: int}) -> Vehicle
// block: the most samples one compute makes (4096 by default)
func vehicle.new(options){
  options = options or {}
  local block = options.block or 4096
  local engine = inline4:new(options)
  local sound = acoustics:new(options)
  local engine_out = {}
  for(local j = 0; j < inline4.outputs; j = j + 1){
    append(engine_out, kernel.float:array(block))
  }
  local controls = vehicle.controls()
  local by_label = {}
  for(let local c in values(controls)){
    c.instance = if(c.program == "engine"){ engine } else { sound }
    by_label[c.label] = c
  }
  return {
    engine: engine,
    acoustics: sound,
    controls: controls,
    by_label: by_label,
    engine_out: engine_out,
    left: kernel.float:array(block),
    right: kernel.float:array(block),
    // the acoustics' inputs and outputs, built once
    stems: {
      engine_out[vehicle.EXHAUST],
      engine_out[vehicle.INTAKE],
      engine_out[vehicle.MECHANICS],
      engine_out[vehicle.VIBRATION],
      engine_out[vehicle.KMH],
    },
    @meta: meta,
  }
}

func methods.set(self, label, value){
  local c = self.by_label[label]
  if(c == null){
    raise(error.new(
      error.kinds.argument,
      concat("the car has no control \"", label, "\""),
    ))
  }
  c.instance:set(label, value)
}

func methods.get(self, label){
  return self.by_label[label].instance:get(label)
}

// compute(n): n samples of both programs, the sound into left and right,
// the engine's outputs into engine_out
func methods.compute(self, n){
  self.engine:compute(n, {}, self.engine_out)
  self.acoustics:compute(n, self.stems, {self.left, self.right})
}

return vehicle
