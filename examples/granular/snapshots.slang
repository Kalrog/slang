// snapshots: the sound's settings (the knobs and the LFOs) kept in
// numbered slots, and a morph to them. Recalling a slot morphs from where
// the knobs are to it over a glide time; the morph can also be held and
// moved by hand, back and forth between the two.
//
//   local snaps = snapshots.new(shared.ctl)
//   snaps:store(1)
//   snaps:recall(1)          // morph starts, at ctl[GLIDE] seconds
//   snaps:step(dt)           // every frame
//   snaps:morph(0.5)         // halfway (stops the glide)
//   snaps:touch(cell)        // a knob was turned: it keeps its new value
//
// Knobs morph along their sliders; the LFOs' shape and destination switch
// halfway.
local engine = require("engine")
local json = require("slang/json")
local os = require("slang/os")

local snapshots = {}
snapshots.SLOTS = 8

// what a snapshot holds, each with the knob it morphs along (null: a
// choice, which switches halfway)
local PARTS = {}
for(let local k in values(engine.knobs)){
  append(PARTS, {cell: k.cell, knob: k})
}
for(let local o in values(engine.lfos)){
  append(PARTS, {cell: o.rate.cell, knob: o.rate})
  append(PARTS, {cell: o.depth.cell, knob: o.depth})
  append(PARTS, {cell: o.shape, knob: null})
  append(PARTS, {cell: o.dest, knob: null})
}

local methods = {}

// the settings now, by cell (as strings, so that they save as JSON)
local func capture(self){
  local now = {}
  for(let local p in values(PARTS)){
    now[string(p.cell)] = self.ctl[p.cell]
  }
  return now
}

local func apply(self, t){
  self.ctl[engine.cells.MORPH] = t
  for(let local p in values(PARTS)){
    local key = string(p.cell)
    local a = self.from[key]
    local b = self.to[key]
    if(a != null and b != null){
      if(p.knob == null){
        self.ctl[p.cell] = if(t < 0.5){ a } else { b }
      } else {
        local ta = engine.t_of(p.knob, a)
        local tb = engine.t_of(p.knob, b)
        self.ctl[p.cell] = engine.from_t(p.knob, ta + (tb - ta) * t)
      }
    }
  }
}

// store(slot): the settings now into slot (1..SLOTS)
func methods.store(self, slot){
  self.slots[string(slot)] = capture(self)
  self.current = slot
}

// has(slot) -> bool
func methods.has(self, slot){
  return self.slots[string(slot)] != null
}

// recall(slot) -> bool: starts the morph from the settings now to slot;
// false when the slot is empty
func methods.recall(self, slot){
  local to = self.slots[string(slot)]
  if(to == null){
    return false
  }
  self.from = capture(self)
  self.to = to
  self.current = slot
  if(self.ctl[engine.cells.GLIDE] <= 0.0){
    self.gliding = false
    apply(self, 1.0)
  } else {
    self.gliding = true
    apply(self, 0.0)
  }
  return true
}

// step(dt): the glide, dt seconds on
func methods.step(self, dt){
  if(not self.gliding){
    return null
  }
  local t = self.ctl[engine.cells.MORPH] + dt / self.ctl[engine.cells.GLIDE]
  if(t >= 1.0){
    t = 1.0
    self.gliding = false
  }
  apply(self, t)
}

// morph(t): the settings at t between before the recall (0) and the
// snapshot (1); stops a glide
func methods.morph(self, t){
  self.gliding = false
  if(self.to == null){
    self.ctl[engine.cells.MORPH] = t
    return null
  }
  apply(self, t)
}

// touch(cell): its value was set by hand; morphing leaves it there
func methods.touch(self, cell){
  if(self.to == null){
    return null
  }
  local key = string(cell)
  if(self.to[key] != null){
    // a copy: the slot itself keeps what was stored
    local to = {}
    for(let local k in keys(self.to)){
      to[k] = self.to[k]
    }
    to[key] = self.ctl[cell]
    self.to = to
    self.from[key] = self.ctl[cell]
  }
}

// save(file) / load(file): the slots and the glide time, as JSON
func methods.save(self, file){
  os.write_file(file, json.encode({
    glide: self.ctl[engine.cells.GLIDE],
    slots: self.slots,
  }))
}

func methods.load(self, file){
  if(not os.exists(file)){
    return false
  }
  local data = try { json.decode(os.read_file(file)) } catch { null }
  if(data == null or data.slots == null){
    return false
  }
  self.slots = data.slots
  if(data.glide != null){
    self.ctl[engine.cells.GLIDE] = data.glide
  }
  return true
}

local meta = {__type: "granular.Snapshots", __index: methods}

// new(ctl) -> Snapshots
func snapshots.new(ctl){
  return {
    ctl: ctl,
    slots: {},
    from: null,
    to: null,
    current: null,
    gliding: false,
    @meta: meta,
  }
}

return snapshots
