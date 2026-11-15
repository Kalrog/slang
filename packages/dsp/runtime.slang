// dsp/runtime: a compiled program as slang uses it.
//
//   dsp organ { process = hslider("freq", 440, 50, 2000, 1) : osc; }
//
//   local voice = organ:new({sample_rate: 48000})
//   voice.freq = 220                       // a control, by its label
//   local out = kernel.float:array(128)
//   voice:compute(128, {}, {out})          // 128 samples into out
//
// A [Dsp] is the program: its numbers of inputs and outputs, its controls
// and its kernel source. An [Instance] is one running copy of it, with
// its own state (every instance of a reverb has its own delay lines).
local kernel = require("kernel")

local runtime = {}

// A program: what `dsp name { }` makes and what a .dsp file returns.
// type Dsp = {name: string, inputs: int, outputs: int,
//   controls: {Control}, source: string, compute: Kernel, State: Struct,
//   new: func(options?: {sample_rate?: int}): Instance}
// [inputs]: the number of input signals (arrays) compute takes
// [outputs]: the number of output signals
// [controls]: the sliders, buttons and checkboxes, in order of appearance
// [source]: the kernel code generated for the program (packages/kernel)
// [compute]: the kernel itself: compute(state, ring, tmp, n, ...ins, ...outs)
// [State]: the struct of an instance's state (kernel.Struct)
// [new]: a new instance, its controls at their start values
//
// type Control = {label: string, field: string, kind: string,
//   init: float, min: float, max: float, step: float}
// [kind]: "hslider", "vslider", "nentry", "button" or "checkbox"
// [field]: its field in State
local dsp_methods = {}
local dsp_meta = {__index: dsp_methods, __type: "dsp"}

// One running copy of a program. Its controls are properties by label
// (`voice.freq = 220`, `voice["cut off"]`), clamped to their range by
// the kernel.
// type Instance = {dsp: Dsp, state: any, ring: Buffer, sample_rate: int,
//   compute: func(n: int, inputs: {Buffer}, outputs: {Buffer}),
//   set: func(label: string, value: float), get: func(label: string): float,
//   reset: func()}
// [state]: its State struct value
// [ring]: its delay lines (32-bit floats)
// [compute]: n samples from the input arrays into the output arrays (32-bit
//   float arrays, kernel.float:array(n), at least n long)
// [reset]: the state as new: silence, controls at their start values
local instance_methods = {}
local instance_meta = {__type: "dsp.instance"}

func runtime.new(info, module){
  local by_label = {}
  for(let local c in values(info.controls)){
    by_label[c.label] = c
  }
  return {
    name: info.name,
    inputs: info.inputs,
    outputs: info.outputs,
    controls: info.controls,
    by_label: by_label,
    ring: info.ring,
    scratch: info.scratch or 0,
    source: info.source,
    compute: module.compute,
    State: module.State,
    @meta: dsp_meta,
  }
}

local SR_MIN = 8000
local SR_MAX = 96000

func dsp_methods.new(self, options){
  options = options or {}
  local rate = options.sample_rate or 48000
  if(rate < SR_MIN or rate > SR_MAX){
    raise(error.new(error.kinds.argument, concat(
      "dsp: a sample rate from ", string(SR_MIN), " to ", string(SR_MAX),
      ", not ", string(rate)
    )))
  }
  local inst = {
    dsp: self,
    sample_rate: rate,
    state: self.State:new({sr: rate}),
    ring: kernel.float:array(if(self.ring > 0){ self.ring } else { 1 }),
    tmp: kernel.double:array(if(self.scratch > 0){ self.scratch } else { 1 }),
    args: {},
    @meta: instance_meta,
  }
  return inst
}

func instance_methods.compute(self, n, inputs, outputs){
  local d = self.dsp
  if(len(inputs) != d.inputs or len(outputs) != d.outputs){
    raise(error.new(error.kinds.argument, concat(
      "dsp ", d.name or "", ": compute takes ", string(d.inputs),
      " inputs and ", string(d.outputs), " outputs, not ", string(len(inputs)),
      " and ", string(len(outputs))
    )))
  }
  // (one argument list per instance, filled again: no garbage per block)
  local args = self.args
  args[0] = self.state
  args[1] = self.ring
  args[2] = self.tmp
  args[3] = n
  local k = 4
  for(local i = 0; i < d.inputs; i = i + 1){
    args[k] = inputs[i]
    k = k + 1
  }
  for(local j = 0; j < d.outputs; j = j + 1){
    args[k] = outputs[j]
    k = k + 1
  }
  d.compute(...args)
}

local func control(self, label){
  local c = self.dsp.by_label[label]
  if(c == null){
    raise(error.new(error.kinds.argument, concat(
      "dsp ", self.dsp.name or "", " has no control \"", string(label), "\""
    )))
  }
  return c
}

func instance_methods.set(self, label, value){
  self.state[control(self, label).field] = value
}

func instance_methods.get(self, label){
  return self.state[control(self, label).field]
}

func instance_methods.reset(self){
  self.state = self.dsp.State:new({sr: self.sample_rate})
  self.ring = kernel.float:array(len(self.ring))
}

func instance_meta.__index(self, key){
  local m = instance_methods[key]
  if(m != null){
    return m
  }
  local c = self.dsp.by_label[key]
  if(c != null){
    return self.state[c.field]
  }
  return null
}

func instance_meta.__newindex(self, key, value){
  self.state[control(self, key).field] = value
}

return runtime
