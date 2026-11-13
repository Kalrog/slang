// engine: the player's audio. engine.new runs in the render isolate of
// raylib/stream (or in a test, or tool/render.slang): an instance of every
// instrument, the echo and the reverb, and a block function that renders
// the chosen instrument through both into interleaved stereo.
//
// The player talks to it through one shared buffer of doubles, params
// (see engine.layout): the instrument, the note, the gate, and every
// slider of every program; the block function reads them at each block.
extension "kernel/syntax"
local kernel = require("kernel")
local instruments = require("instruments")

local engine = {}

// the cells of params before the sliders
engine.PROGRAM = 0
engine.FREQ = 1
engine.GATE = 2
// a count that changes with every new note: the gate goes down for a
// block, so that a note played legato starts again
engine.NOTE = 3
engine.FIRST = 4

// layout() -> {size, sliders: {{program, label, slot, control}}, by_program}
// Where every slider lives in params: the instruments' (but freq and gate,
// which the player sets) and the effects'. The same in every isolate.
func engine.layout(){
  local sliders = {}
  local by_program = {}
  local slot = engine.FIRST
  local programs = {...instruments.list, instruments.echo, instruments.reverb}
  for(local k = 0; k < len(programs); k = k + 1){
    local p = programs[k]
    local own = {}
    for(let local c in values(p.controls)){
      if(c.label == "freq" or c.label == "gate"){
        continue
      }
      local s = {program: k, label: c.label, slot: slot, control: c}
      append(sliders, s)
      append(own, s)
      slot = slot + 1
    }
    append(by_program, own)
  }
  return {
    size: slot, sliders: sliders, by_program: by_program, programs: programs
  }
}

// params(layout) -> Buffer: the shared parameters at their start values
func engine.params(layout){
  local params = kernel.double:array(layout.size, {shared: true})
  params[engine.FREQ] = 220.0
  for(let local s in values(layout.sliders)){
    params[s.slot] = s.control.init
  }
  return params
}

kernel {
  func interleave(out: float[], l: float[], r: float[], n: int){
    for(local i = 0; i < n; i += 1){
      out[2 * i] = l[i]
      out[2 * i + 1] = r[i]
    }
  }
}

// new(params, sample_rate) -> func(out, frames)
// The block function: frames stereo frames into out (interleaved).
func engine.new(params, sample_rate){
  local layout = engine.layout()
  local voices = {}
  for(let local p in values(layout.programs)){
    append(voices, p:new({sample_rate: sample_rate}))
  }
  local n_instruments = len(instruments.list)
  local echo = voices[n_instruments]
  local reverb = voices[n_instruments + 1]
  local size = 0
  local mono = null
  local wet = null
  local left = null
  local right = null
  local silence = null
  local last_note = -1.0
  return func(out, frames){
    if(frames > size){
      size = frames
      mono = kernel.float:array(size)
      wet = kernel.float:array(size)
      left = kernel.float:array(size)
      right = kernel.float:array(size)
      silence = kernel.float:array(size)
    }
    local k = to_int(params[engine.PROGRAM])
    local v = voices[k]
    for(let local s in values(layout.by_program[k])){
      v.state[s.control.field] = params[s.slot]
    }
    for(let local s in values(layout.by_program[n_instruments])){
      echo.state[s.control.field] = params[s.slot]
    }
    for(let local s in values(layout.by_program[n_instruments + 1])){
      reverb.state[s.control.field] = params[s.slot]
    }
    v.freq = params[engine.FREQ]
    local note = params[engine.NOTE]
    if(note != last_note){
      last_note = note
      v.gate = 0
    } else {
      v.gate = params[engine.GATE]
    }
    v:compute(frames, {}, {mono})
    echo:compute(frames, {mono}, {wet})
    reverb:compute(frames, {wet, silence}, {left, right})
    interleave(out, left, right, frames)
  }
}

return engine
