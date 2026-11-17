// studio/units: the units by name.
//
//   local units = require("studio/units")
//   units.find("six")          // the module studio/units/six
//   units.find("my/bell")      // a unit of the program's own: the module my/bell
//   units.names                // the units that come with the package
//
// A unit is a module that returns what the engine and the program's side
// need of it:
//
//   return {
//     name: "tone",
//     kind: "instrument",                // or "effect"
//     params: param.set({{name: "gain", min: 0, max: 1, default: 0.5}}),
//     patches: {{name: "Soft", gain: 0.2}},        // optional
//     new: func(ctx){ ... return {render: ..., note_on: ..., ...} },
//   }
//
// new(ctx) makes one running copy in the engine's isolate. ctx is
// {sample_rate, params (the buffer of parameter cells), base (this unit's
// first cell: its parameter i is params[base + i]), options (what the
// program gave besides parameters), block (the most frames a render call
// asks for), meters, meter (the strip's cells in meters)}. The copy is a
// table of functions; all but render are optional:
//
//   render(l, r, start, n, sl, sr)   an instrument writes frames start ..
//                                    start + n - 1 of l and r; an effect
//                                    changes them in place (sl, sr: what
//                                    it listens to, l and r themselves
//                                    unless a sidechain is set)
//   note_on(note, velocity)          velocity 0..1; note may be fractional
//   note_off(note)
//   next(i, value)                   parameter i for the next note only
//   control(which, value)            events.controls: bend, mod, sustain
//   set(i, value)                    parameter i changed (the cell already
//                                    holds it): for what is derived from it
//   hush()                           every note released
//   panic()                          silence at once
//   voices() -> int                  notes sounding
//   message(m)                       something besides numbers (a sample)
//   close()                          the unit was removed
//
// A unit keeps all its state in its copy (structs and arrays made in new),
// never in a kernel's module state, which every copy would share.
local units = {}

units.names = {
  instruments: {
    "poly",
    "drums",
    "mini",
    "six",
    "sampler",
    "grains",
    "rack",
    "organ",
    "pluck",
    "bell",
    "wind",
  },
  effects: {
    "filter",
    "delay",
    "room",
    "hall",
    "chorus",
    "phaser",
    "eq",
    "compressor",
    "limiter",
    "drive",
    "crush",
  },
}

local found = {}

// find(name: string) -> Unit
// The unit of that name: studio/units/<name>, or the module `name` itself
// when it has a slash. Raises when there is none or it is not a unit.
func units.find(name){
  local u = found[name]
  if(u != null){
    return u
  }
  local path = name
  if(require("slang/string").index_of(name, "/") < 0){
    path = concat("studio/units/", name)
  }
  u = try { require(
    path,
  ) } catch(local e) { raise(error.new(error.kinds.argument, concat(
    "studio: no unit \"", name, "\" (", string(e.message or e), ")"
  ))) }
  if(type(u) != "table" or u.new == null or u.params == null){
    raise(error.new(error.kinds.argument, concat(
      "studio: ", path, " is not a unit (it needs params and new)"
    )))
  }
  found[name] = u
  return u
}

return units
