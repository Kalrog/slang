extension "kernel/syntax"
// studio/units/rack: a modular synthesizer as an instrument (the one of
// examples/modular): a rack of modules patched with cables, where a clock
// drives step sequencers into oscillators, filters, envelopes and drums.
// Its sequencers play by themselves while `run` is on; the track's notes
// reach its KBD module (pitch, gate and velocity, the last key held), the
// mod wheel its WHL output.
//
//   s:track("acid", "rack", {rack: "acid"})         // one that comes with it
//   s:track("mine", "rack", {rack: "patches/mine.json"})
//
//   // a rack the program patches while it plays:
//   local patch = require("studio/units/rack/patch")
//   local r = patch.new(buffer.shared)
//   local vco = r:add("VCO")
//   local out = r:add("OUT")
//   r:connect(vco, 0, out, 0)
//   s:track("drone", "rack", {rack: r.a})
//   r:set_param(vco, 0, 3)                          // heard at once
//
// `rack` is the name of one of studio/units/rack/patches (first_song,
// acid, play, generative, electric, lofi, electro, drift), a path to a
// rack saved as JSON, or the buffers of a Rack (`r.a`, made with
// buffer.shared when the studio plays through a stream).
// studio/units/rack/patch has the modules and how to patch them.
local kernel = require("kernel")
local buffer = require("slang/buffer")
local json = require("slang/json")
local os = require("slang/os")
local param = require("studio/param")
local events = require("studio/events")
local engine = require("studio/units/rack/engine")

kernel {
  // the rack's block (interleaved) into the track's sides
  func spread(
    l: float[], r: float[], start: int, n: int, src: float[], gain: float
  ){
    for(local i = 0; i < n; i += 1){
      l[start + i] = src[i * 2] * gain
      r[start + i] = src[i * 2 + 1] * gain
    }
  }
}

local params = param.set({
  {name: "run", kind: "switch", default: 1},
  {name: "pattern", min: 1.0, max: 8.0, default: 1.0, step: 1.0},
  {name: "gain", min: 0.0, max: 2.0, default: 1.0},
})

local func new(ctx){
  local p = ctx.params
  local base = ctx.base
  local a = ctx.options.rack or "play"
  if(type(a) == "string"){
    local patch = require("studio/units/rack/patch")
    local patches = require("studio/units/rack/patches")
    local text = patches[a]
    if(text == null or a == "names"){
      text = os.read_file(a)
    }
    local r = patch.new(func(t, n){ return buffer.new(t, n) })
    r:from_table(json.decode(text))
    a = r.a
  }
  local block = engine.new(a, ctx.sample_rate)
  local out = kernel.float:array(ctx.block * 2)
  local live = a.live
  local L = engine.live
  local held = {}

  local func release(note){
    local rest = {}
    for(local i = 0; i < len(held); i = i + 1){
      if(held[i] != note){
        append(rest, held[i])
      }
    }
    held = rest
  }

  return {
    note_on: func(note, vel){
      release(note)
      append(held, note)
      live[L.PITCH] = (note - 60) / 12
      live[L.VEL] = vel
      live[L.GATE] = 1
    },
    note_off: func(note){
      release(note)
      if(len(held) > 0){
        live[L.PITCH] = (held[len(held) - 1] - 60) / 12
      } else {
        live[L.GATE] = 0
      }
    },
    control: func(which, value){
      if(which == events.controls.MOD){
        live[L.WHEEL] = value
      }
    },
    hush: func(){
      held = {}
      live[L.GATE] = 0
    },
    panic: func(){
      held = {}
      live[L.GATE] = 0
      // every module's state cleared at the next control step
      for(local m = 0; m < engine.MAX; m = m + 1){
        a.flags[m] = 1
      }
    },
    render: func(l, r, start, n){
      live[L.RUN] = p[base]
      live[L.PATTERN] = p[base + 1] - 1
      block(out, n)
      spread(l, r, start, n, out, p[base + 2])
    },
  }
}

return {
  name: "rack",
  kind: "instrument",
  params: params,
  options: {"rack"},
  new: new,
}
