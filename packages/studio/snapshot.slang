// studio/snapshot: the parameters of units kept and brought back, at once
// or by a morph between two of them.
//
//   local snapshot = require("studio/snapshot")
//   local a = snapshot.take({cloud.unit, delay})      // what they are now
//   ... turn knobs ...
//   local b = snapshot.take({cloud.unit, delay})
//   snapshot.apply(a)                                  // back, at once
//   snapshot.morph(a, b, 0.25)                         // a quarter of the way to b
//   snapshot.glide(s, a, b, 2000)                      // from a to b in two seconds
//
// A morph goes along each parameter's slider (so a time in milliseconds
// morphs as evenly as a level); switches and enumerations change at the
// middle. A snapshot is plain data: snapshot.save writes one as JSON.
local json = require("slang/json")
local math = require("slang/math")
local os = require("slang/os")
local param = require("studio/param")

local snapshot = {}

// type Snapshot = {units: {{unit: Unit, values: table}}}

// take(units: {Unit}) -> Snapshot
// The parameters of the units as they are set now.
func snapshot.take(units){
  local snap = {units: {}}
  for(let local u in values(units)){
    append(snap.units, {unit: u, values: u:values()})
  }
  return snap
}

// apply(snap: Snapshot, at?: number)
// Every parameter of the snapshot set, now or at a time of the clock.
func snapshot.apply(snap, at){
  for(let local e in values(snap.units)){
    local info = e.unit.info
    for(local i = 0; i < info.count; i = i + 1){
      local d = info.list[i]
      if(d.kind != "meter" and e.values[d.name] != null){
        e.unit:set(d.name, e.values[d.name], at)
      }
    }
  }
}

// morph(a: Snapshot, b: Snapshot, t: number, at?: number)
// The parameters set between a (t 0) and b (t 1). Both are of the same
// units, in the same order.
func snapshot.morph(a, b, t, at){
  if(len(a.units) != len(b.units)){
    raise(error.new(
      error.kinds.argument,
      "studio/snapshot: morph between snapshots of the same units",
    ))
  }
  for(local k = 0; k < len(a.units); k = k + 1){
    local ea = a.units[k]
    local eb = b.units[k]
    if(not same(ea.unit, eb.unit)){
      raise(error.new(
        error.kinds.argument,
        "studio/snapshot: morph between snapshots of the same units",
      ))
    }
    local info = ea.unit.info
    for(local i = 0; i < info.count; i = i + 1){
      local d = info.list[i]
      local va = ea.values[d.name]
      local vb = eb.values[d.name]
      if(d.kind == "meter" or va == null or vb == null){
        continue
      }
      local v = va
      if(va != vb){
        if(d.step != null){
          v = if(t < 0.5){ va } else { vb }
        } else {
          local ta = param.t_of(d, va)
          v = param.from_t(d, ta + (param.t_of(d, vb) - ta) * t)
        }
      }
      if(v != ea.unit:get(d.name) or at != null){
        ea.unit:set(d.name, v, at)
      }
    }
  }
}

// glide(studio: Studio, a: Snapshot, b: Snapshot, ms: number, steps?: int)
// A morph from a to b over ms milliseconds from now, as timed
// instructions (a step every 10 ms unless `steps` says how many).
func snapshot.glide(studio, a, b, ms, steps){
  steps = steps or math.max(1, to_int(ms / 10))
  for(local k = 1; k <= steps; k = k + 1){
    snapshot.morph(a, b, k / steps, studio:after(ms * k / steps))
  }
}

// save(snap: Snapshot, path: string)
// The snapshot's values as JSON: a list of {unit: its name, values}.
func snapshot.save(snap, path){
  local out = {}
  for(let local e in values(snap.units)){
    append(out, {unit: e.unit.name, values: e.values})
  }
  os.write_file(path, json.encode(out, {indent: "  "}))
}

// load(path: string, units: {Unit}) -> Snapshot
// A saved snapshot for these units (in the order they were saved in).
// Raises when a unit is of another kind than the one saved.
func snapshot.load(path, units){
  local list = json.decode(os.read_file(path), path)
  local snap = {units: {}}
  for(local i = 0; i < len(list); i = i + 1){
    local u = units[i]
    if(u == null or u.name != list[i].unit){
      raise(error.new(error.kinds.argument, concat(
        "studio/snapshot: ", path, ": entry ", string(i), " is of a ",
        string(list[i].unit)
      )))
    }
    append(snap.units, {unit: u, values: list[i].values})
  }
  return snap
}

return snapshot
