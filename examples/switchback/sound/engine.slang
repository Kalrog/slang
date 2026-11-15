// sound/engine: the truck's engine as one thing to run: four programs, a
// kernel each (one program of all of it would not fit the kernel VM's
// registers and run three times slower): the cylinders
// (sound/engine/cylinders.dsp), whose valves feed the exhaust and the
// intake (waveguides: sound/engine/exhaust.dsp, intake.dsp), and whose
// pressure strikes the block (sound/engine/block.dsp, with the
// turbocharger).
//
//   local engine = require("sound/engine")
//   local e = engine.new({sample_rate: 48000, block: 128})
//   e:set("rpm", 1800)
//   e:set("fuel", 0.6)
//   e:compute(128)             // into e.out[engine.EXHAUST] ...
//
// Controls (each set on every program that has it): rpm, fuel (0 to 1),
// boost (0 to 1), starter (0 or 1), damage (0 to 1), clatter, roughness,
// muffler, growl, snorkel (the intake's last pipe, m).
local kernel = require("kernel")
local block = require("sound/engine/block")

local m = {}

// the engines there are, by their number of cylinders: the four the truck
// has, and a five and a six of the same parts to compare it with
// (sound/engine5, sound/engine6)
local func programs_of(count){
  local dir = if(count == 4){ "sound/engine" } else { concat("sound/engine", string(count)) }
  return {
    require(concat(dir, "/cylinders")), require(concat(dir, "/exhaust")),
    require(concat(dir, "/intake")), block,
  }
}

// the outputs: what the tailpipe radiates, the intake's mouth, the
// engine's own mechanical noise, the turbocharger
m.EXHAUST = 0
m.INTAKE = 1
m.MECHANICS = 2
m.TURBO = 3

local methods = {}
local meta = {__index: methods, __type: "sound.Engine"}

// new(options?: {sample_rate?: int, block?: int, cylinders?: int}) -> Engine
// block: the most samples one compute makes (1024 by default);
// cylinders: 4 (the truck's), 5 or 6
func m.new(options){
  options = options or {}
  local size = options.block or 1024
  local parts = {}
  local by_label = {}
  local programs = programs_of(options.cylinders or 4)
  local cylinders = programs[0]
  for(let local p in values(programs)){
    local inst = p:new(options)
    append(parts, inst)
    for(let local c in values(p.controls)){
      if(by_label[c.label] == null){
        by_label[c.label] = {}
      }
      append(by_label[c.label], {state: inst.state, field: c.field})
    }
  }
  local func arrays(count){
    local list = {}
    for(local i = 0; i < count; i = i + 1){
      append(list, kernel.float:array(size))
    }
    return list
  }
  // the cylinders' outputs: four per cylinder (the exhaust valve's two,
  // the intake valve's two), then the block's four
  local cyl = arrays(cylinders.outputs)
  local count = to_int((cylinders.outputs - 4) / 4)
  local to_exhaust = {}
  local to_intake = {}
  for(local k = 0; k < count; k = k + 1){
    append(to_exhaust, cyl[k * 4])
    append(to_exhaust, cyl[k * 4 + 1])
    append(to_intake, cyl[k * 4 + 2])
    append(to_intake, cyl[k * 4 + 3])
  }
  local out = arrays(4)
  return {
    parts: parts,
    by_label: by_label,
    out: out,
    cyl: cyl,
    to_exhaust: to_exhaust,
    to_intake: to_intake,
    to_block: {cyl[count * 4], cyl[count * 4 + 1], cyl[count * 4 + 2], cyl[count * 4 + 3]},
    exhaust_out: {out[m.EXHAUST]},
    intake_out: {out[m.INTAKE]},
    block_out: {out[m.MECHANICS], out[m.TURBO]},
    none: {},
    @meta: meta,
  }
}

// set(name, value): a control, on every program that has it
func methods.set(self, name, value){
  local list = self.by_label[name]
  if(list == null){
    raise(error.new(error.kinds.argument, concat("the engine has no control \"", name, "\"")))
  }
  for(local i = 0; i < len(list); i = i + 1){
    local c = list[i]
    c.state[c.field] = value
  }
}

// compute(n): n samples into out
func methods.compute(self, n){
  local p = self.parts
  p[0]:compute(n, self.none, self.cyl)
  p[1]:compute(n, self.to_exhaust, self.exhaust_out)
  p[2]:compute(n, self.to_intake, self.intake_out)
  p[3]:compute(n, self.to_block, self.block_out)
}

return m
