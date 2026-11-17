// studio: instruments and effects on tracks, mixed through buses to a
// master, played from timed notes. The core a tracker, a live coding
// environment or a workstation is built on; it draws nothing.
//
//   local studio = require("studio")
//   local s = studio.new()
//   local hall = s:bus("hall")
//   hall:insert("hall", {decay: 2400})
//   local keys = s:track("keys", "six", {patch: "TINE PIANO"})
//   keys:insert("chorus")
//   keys:send(hall, 0.3)
//   keys.gain = 0.8
//   keys:note(60, {length: 500})             // now, for half a second
//   keys:note(64, {at: s.clock + 24000})     // half a second from now
//   keys.unit.params.feedback = 5            // a parameter of the instrument
//
//   local sound = s:render(2000)             // two seconds, here and now
//   // or, through a sound card:
//   s:start(require("window/audio"))         // or require("raylib/stream")
//
// A studio is strips: tracks (an instrument each), buses (which gather
// what tracks send them) and the master. Every strip has inserts (effects
// in a row), a gain, a pan and a mute. An instrument or an effect is a
// unit (studio/units lists them); each has named parameters, numbers that
// are set, automated by timed instructions, moved by LFOs and bound to
// MIDI knobs all in the same way.
//
// The sound is made by an engine (studio/engine): in this isolate while
// the studio renders offline, in the audio stream's isolate after start().
// Either way the program talks to it through shared buffers: notes and
// parameter changes are instructions with a time in samples of the
// engine's clock (s.clock), applied to the sample.
local buffer = require("slang/buffer")
local math = require("slang/math")
local time = require("slang/time")
local events = require("studio/events")
local param = require("studio/param")
local units = require("studio/units")

local studio = {}

studio.units = units.names
studio.param = param

local K = events.kinds

// the parameters every strip has
local STRIP = param.set({
  {name: "gain", min: 0.0, max: 4.0, default: 1.0, curve: 2.0},
  {name: "pan", min: -1.0, max: 1.0, default: 0.0, bipolar: true},
  {name: "mute", kind: "switch", default: 0},
})
local SEND = param.set({
  {name: "amount", min: 0.0, max: 2.0, default: 0.0, curve: 2.0},
}).list[0]
local LFO = param.set({
  {name: "rate", min: 0.01, max: 40.0, default: 1.0, unit: "Hz", curve: 3.0},
  {
    name: "shape",
    labels: {"sine", "triangle", "ramp", "square", "random", "drift"},
    default: "sine",
  },
  {name: "value", min: -1.0, max: 1.0, default: 0.0},
})
local DEPTH = param.set({
  {name: "depth", min: -1.0, max: 1.0, default: 0.0, bipolar: true},
}).list[0]

local func fail(message){
  raise(error.new(error.kinds.argument, concat("studio: ", message)))
}

// ------------------------------------------------------------ units

// An instrument or an effect on a strip.
// type Unit = {name: string, kind: string, info: ParamSet, params: table,
//   patches: {string},
//   set: func(name: string, value: number | string | bool, at?: number),
//   get: func(name: string): number,
//   effective: func(name: string): number,
//   patch: func(p: string | table),
//   values: func(): table,
//   message: func(m: table)}
// [name]: the unit's name ("six")
// [kind]: "instrument" or "effect"
// [info]: its parameters (studio/param)
// [params]: the parameters as properties: `unit.params.cutoff = 0.4`
//   sets one now, `unit.params.cutoff` reads it
// [patches]: the names of the sounds that come with the unit
// [set]: a parameter by name, now or at a time of the engine's clock
// [get]: a parameter as it was last set
// [effective]: a parameter as the sound uses it: where the LFOs have it
// [patch]: every parameter from a patch: one of the unit's by name, or a
//   table of values (what it leaves out goes to its default)
// [values]: every parameter by name, as a patch's table
// [message]: something the unit takes besides parameters
local unit_methods = {}
local unit_meta = {__type: "studio.Unit", __index: unit_methods}

local func cell_of(unit, name){
  local i = unit.info.index[name]
  if(i == null){
    fail(concat(unit.name, " has no parameter \"", string(name), "\""))
  }
  return i
}

func unit_methods.set(self, name, value, at){
  local i = cell_of(self, name)
  local v = param.value(self.info.list[i], value)
  self.studio:emit(at or 0, K.PARAM, self.base + i, v)
}

func unit_methods.get(self, name){
  return self.studio.state.values[self.base + cell_of(self, name)]
}

func unit_methods.effective(self, name){
  return self.studio.state.eff[self.base + cell_of(self, name)]
}

func unit_methods.patch(self, p){
  if(type(p) == "string"){
    local found = null
    for(let local c in values(self.def.patches or {})){
      if(c.name == p){
        found = c
      }
    }
    if(found == null){
      fail(concat(self.name, " has no patch \"", p, "\""))
    }
    p = found
  }
  for(let local e in entries(p)){
    if(e[0] != "name" and self.info.index[e[0]] == null){
      fail(concat(self.name, " has no parameter \"", string(e[0]), "\""))
    }
  }
  for(local i = 0; i < self.info.count; i = i + 1){
    local d = self.info.list[i]
    local v = p[d.name]
    if(v == null){
      v = d.default
    }
    self.studio:emit(0, K.PARAM, self.base + i, param.value(d, v))
  }
}

func unit_methods.values(self){
  local out = {}
  for(local i = 0; i < self.info.count; i = i + 1){
    out[self.info.list[i].name] = self.studio.state.values[self.base + i]
  }
  return out
}

func unit_methods.message(self, m){
  self.studio:tell(self.id, m)
}

local func params_proxy(unit){
  return {
    @meta: {
      __index: func(self, key){
        return unit:get(key)
      },
      __newindex: func(self, key, value){
        unit:set(key, value)
      },
    },
  }
}

// ------------------------------------------------------------ strips

// A track, a bus or the master.
// type Strip = {name: string, kind: string, unit?: Unit, inserts: {Unit},
//   gain: number, pan: number, mute: bool, to?: Strip,
//   peak: {left: number, right: number}, voices: int,
//   set: func(name: string, value: number | bool, at?: number),
//   insert: func(unit: string, options?: table, at?: int): Unit,
//   remove: func(unit: Unit),
//   send: func(bus: Strip, amount: number, at?: number),
//   note: func(note: number, options?: NoteOptions),
//   off: func(note: number, at?: number),
//   hush: func(), panic: func(),
//   bend: number, mod: number, sustain: bool}
// [kind]: "track", "bus" or "master"
// [unit]: a track's instrument
// [inserts]: its effects, in the order the sound goes through them
// [gain]: its fader, 1 as it is (settable)
// [pan]: -1 left to 1 right (settable)
// [mute]: settable
// [to]: where a track's sound goes: a bus, or null for the master (settable)
// [peak]: its loudest samples lately, after the fader
// [voices]: notes sounding on a track
// [set]: "gain", "pan" or "mute" at a time of the engine's clock (the
//   properties set them now)
// [insert]: a new effect at the end of its inserts (or at index `at`);
//   options are the effect's parameters by name, `patch`, and
//   `sidechain: track` for an effect that listens to another track
// [remove]: an insert taken out
// [send]: how much of the strip (after its fader) goes to a bus as well
// [note]: a note of a track's instrument
// [off]: the end of a note that was played without a length
// [hush]: every note released; [panic]: silence at once
// [bend]: the pitch wheel, -1..1; [mod]: the mod wheel, 0..1; [sustain]:
//   the pedal (all three only set)
//
// type NoteOptions = {velocity?: number, length?: number, at?: number,
//   params?: table}
// [velocity]: 0..1, 0.8 when absent
// [length]: milliseconds until its note off; without it the note sounds
//   until off(note)
// [at]: when, in samples of the engine's clock; now when absent
// [params]: parameters of the instrument for this note only
local strip_methods = {}
local strip_get = {}
local strip_set = {}
local strip_meta = {
  __type: "studio.Strip",
  __index: strip_methods,
  __get: strip_get,
  __set: strip_set,
}

local func strip_param(self, i, v, at){
  self.studio:emit(
    at or 0, K.PARAM, self.base + i, param.value(STRIP.list[i], v)
  )
}

// gain(self) -> number
func strip_get.gain(self){
  return self.studio.state.values[self.base]
}
func strip_set.gain(self, v){
  strip_param(self, 0, v)
}

// pan(self) -> number
func strip_get.pan(self){
  return self.studio.state.values[self.base + 1]
}
func strip_set.pan(self, v){
  strip_param(self, 1, v)
}

// mute(self) -> bool
func strip_get.mute(self){
  return self.studio.state.values[self.base + 2] >= 0.5
}
func strip_set.mute(self, v){
  strip_param(self, 2, v)
}

// to(self) -> Strip?
func strip_get.to(self){
  return self.out
}
func strip_set.to(self, bus){
  if(self.kind != "track"){
    fail("only a track's output can go to a bus")
  }
  if(bus != null and bus.kind != "bus"){
    fail("a track goes to a bus or (null) to the master")
  }
  self.out = bus
  self.studio:sync()
}

// peak(self) -> {left: number, right: number}
func strip_get.peak(self){
  local m = self.studio.state.meters
  local at = self.slot * events.METER
  return {left: m[at], right: m[at + 1]}
}

// voices(self) -> int
func strip_get.voices(self){
  return to_int(self.studio.state.meters[self.slot * events.METER + 2])
}

// reduction(self) -> number
// How much the strip's compressor or limiter takes off right now, in dB.
func strip_get.reduction(self){
  return self.studio.state.meters[self.slot * events.METER + 3]
}

local func need_track(self, what){
  if(self.kind != "track"){
    fail(concat(what, ": ", self.name, " is not a track"))
  }
}

func strip_set.bend(self, v){
  need_track(self, "bend")
  self.studio:emit(
    0, K.CONTROL, self.slot, events.controls.BEND,
    math.clamp(v * 1.0, -1.0, 1.0)
  )
}

func strip_set.mod(self, v){
  need_track(self, "mod")
  self.studio:emit(
    0, K.CONTROL, self.slot, events.controls.MOD, math.clamp(v * 1.0, 0.0, 1.0)
  )
}

func strip_set.sustain(self, v){
  need_track(self, "sustain")
  self.studio:emit(
    0, K.CONTROL, self.slot, events.controls.SUSTAIN, if(v){ 1.0 } else { 0.0 }
  )
}

func strip_methods.set(self, name, value, at){
  local i = STRIP.index[name]
  if(i == null){
    fail(concat("a strip has gain, pan and mute, not ", string(name)))
  }
  strip_param(self, i, value, at)
}

func strip_methods.insert(self, name, options, at){
  local u = self.studio:unit(name, "effect", options)
  u.strip = self
  if(at == null or at >= len(self.inserts)){
    append(self.inserts, u)
  } else {
    local k = len(self.inserts)
    for(k > at){
      self.inserts[k] = self.inserts[k - 1]
      k = k - 1
    }
    self.inserts[at] = u
  }
  self.studio:sync()
  return u
}

func strip_methods.remove(self, unit){
  for(local i = 0; i < len(self.inserts); i = i + 1){
    if(same(self.inserts[i], unit)){
      remove(self.inserts, i)
      self.studio:release(unit.base, unit.info.count)
      self.studio:sync()
      return null
    }
  }
  fail(concat(self.name, " has no such insert"))
}

func strip_methods.send(self, bus, amount, at){
  if(bus == null or bus.kind != "bus"){
    fail("send: a bus is where a send goes")
  }
  if(self.kind == "master" or same(self, bus)){
    fail(concat("send: ", self.name, " cannot send to ", bus.name))
  }
  local send = null
  for(let local s in values(self.sends)){
    if(same(s.bus, bus)){
      send = s
    }
  }
  if(send == null){
    send = {bus: bus, cell: self.studio:cells(1)}
    append(self.sends, send)
    self.studio:sync()
  }
  self.studio:emit(at or 0, K.PARAM, send.cell, param.value(SEND, amount))
}

func strip_methods.note(self, note, options){
  need_track(self, "note")
  local s = self.studio
  local at = 0
  local velocity = 0.8
  local length = null
  if(options != null){
    at = options.at or 0
    velocity = options.velocity or 0.8
    length = options.length
    if(options.params != null){
      for(let local e in entries(options.params)){
        local i = cell_of(self.unit, e[0])
        s:emit(
          at, K.NEXT, self.slot, i, param.value(self.unit.info.list[i], e[1])
        )
      }
    }
  }
  s:emit(
    at, K.NOTE_ON, self.slot, note * 1.0, math.clamp(velocity * 1.0, 0.0, 1.0)
  )
  if(length != null){
    local start = at
    if(start <= 0){
      start = s.state.ctl[events.ctl.PLAYED]
    }
    s:emit(
      start + math.max(1, length * s.sample_rate / 1000), K.NOTE_OFF, self.slot,
      note * 1.0
    )
  }
}

func strip_methods.off(self, note, at){
  need_track(self, "off")
  self.studio:emit(at or 0, K.NOTE_OFF, self.slot, note * 1.0)
}

func strip_methods.hush(self){
  need_track(self, "hush")
  self.studio:emit(0, K.HUSH, self.slot)
}

func strip_methods.panic(self){
  need_track(self, "panic")
  self.studio:emit(0, K.PANIC, self.slot)
}

// ------------------------------------------------------------ LFOs

// A slow wave that moves parameters around where they are set.
// type Lfo = {rate: number, shape: string, value: number,
//   to: func(unit: Unit | Strip, name: string, depth: number): Route,
//   remove: func()}
// [rate]: cycles a second (settable)
// [shape]: "sine", "triangle", "ramp", "square", "random" (a new value
//   each cycle) or "drift" (gliding between random values) (settable)
// [value]: where it is now, -1..1
// [to]: the LFO moves that parameter (of a unit, or a strip's "gain" or
//   "pan"); depth 1 sweeps the parameter's whole slider, below 0 the other
//   way round
// [remove]: the LFO and its routes taken out
//
// type Route = {depth: number, remove: func()}
// [depth]: settable
local lfo_methods = {}
local lfo_get = {}
local lfo_set = {}
local lfo_meta = {
  __type: "studio.Lfo",
  __index: lfo_methods,
  __get: lfo_get,
  __set: lfo_set,
}
local route_methods = {}
local route_get = {}
local route_set = {}
local route_meta = {
  __type: "studio.Route",
  __index: route_methods,
  __get: route_get,
  __set: route_set,
}

// rate(self) -> number
func lfo_get.rate(self){
  return self.studio.state.values[self.base]
}
func lfo_set.rate(self, v){
  self.studio:emit(0, K.PARAM, self.base, param.value(LFO.list[0], v))
}

// shape(self) -> string
func lfo_get.shape(self){
  return LFO.list[1].labels[to_int(self.studio.state.values[self.base + 1])]
}
func lfo_set.shape(self, v){
  self.studio:emit(0, K.PARAM, self.base + 1, param.value(LFO.list[1], v))
}

// value(self) -> number
func lfo_get.value(self){
  return self.studio.state.eff[self.base + 2]
}

func lfo_methods.to(self, target, name, depth){
  local cell = 0
  local p = null
  if(target.@meta == strip_meta){
    local i = STRIP.index[name]
    if(i == null or i > 1){
      fail(concat("an LFO moves a strip's gain or pan, not ", string(name)))
    }
    cell = target.base + i
    p = STRIP.list[i]
  } else {
    local i = cell_of(target, name)
    cell = target.base + i
    p = target.info.list[i]
  }
  local s = self.studio
  local route = {
    studio: s,
    lfo: self,
    cell: cell,
    param: p,
    depth_cell: s:cells(1),
    @meta: route_meta,
  }
  append(s.routes, route)
  s:emit(0, K.PARAM, route.depth_cell, param.value(DEPTH, depth or 0))
  s:sync()
  return route
}

func lfo_methods.remove(self){
  local s = self.studio
  local keep = {}
  for(let local r in values(s.routes)){
    if(same(r.lfo, self)){
      s:release(r.depth_cell, 1)
    } else {
      append(keep, r)
    }
  }
  s.routes = keep
  for(local i = 0; i < len(s.lfos); i = i + 1){
    if(same(s.lfos[i], self)){
      remove(s.lfos, i)
      break
    }
  }
  s:release(self.base, LFO.count)
  s:sync()
}

// depth(self) -> number
func route_get.depth(self){
  return self.studio.state.values[self.depth_cell]
}
func route_set.depth(self, v){
  self.studio:emit(0, K.PARAM, self.depth_cell, param.value(DEPTH, v))
}

func route_methods.remove(self){
  local s = self.studio
  for(local i = 0; i < len(s.routes); i = i + 1){
    if(same(s.routes[i], self)){
      remove(s.routes, i)
      break
    }
  }
  s:release(self.depth_cell, 1)
  s:sync()
}

// ------------------------------------------------------------ the studio

// type Studio = {sample_rate: int, master: Strip, tracks: {Strip},
//   buses: {Strip}, clock: number, time: number, playing: bool,
//   track: func(name: string, unit: string, options?: table): Strip,
//   bus: func(name: string): Strip,
//   find: func(name: string): Strip?,
//   remove: func(strip: Strip),
//   lfo: func(options?: {rate?: number, shape?: string}): Lfo,
//   midi: func(track: Strip?, options?: {input?: string}),
//   after: func(ms: number): number,
//   hush: func(), panic: func(),
//   render: func(ms: number): {left: Buffer, right: Buffer},
//   block: func(out: Buffer, frames: int),
//   start: func(audio: table, options?: table), stop: func(),
//   stats: func(): table, scope: func(into?: Buffer): Buffer}
// [master]: the strip everything ends in
// [tracks], [buses]: in the order they were made
// [clock]: the engine's clock: samples it has rendered. Instructions are
//   timed by it.
// [time]: the same in milliseconds
// [playing]: whether an audio stream plays the studio (after start)
// [track]: a new track with an instrument. options are the instrument's
//   parameters by name, `patch` (one of its patches, or a table), and what
//   else the unit takes (`voices`, a sample)
// [bus]: a new bus
// [find]: a track or bus by its name
// [remove]: a track or bus taken out, with its units
// [lfo]: a new LFO
// [midi]: a MIDI controller plays that track (null: none): its notes,
//   pitch wheel, mod wheel and pedal, read by the engine every block, so
//   they sound within a few milliseconds. input is part of a controller's
//   name (else the environment's MIDI_INPUT, else every controller).
//   studio/midi binds a controller's knobs to parameters.
// [after]: the clock's value ms milliseconds from now, for `at`
// [hush]: every note of every track released; [panic]: silence at once
// [render]: the next ms milliseconds of sound, computed here and now
//   (float buffers, 48000 samples a second unless the studio was made
//   otherwise). Not while a stream plays the studio.
// [block]: the next frames (interleaved stereo floats) into out, for a
//   loop of the program's own (a sequencer stepping between blocks)
// [start]: the studio plays through a sound card from here on: audio is
//   require("window/audio") or require("raylib/stream"); options are the
//   stream's (block, latency). Start before playing notes: the notes that
//   sound and the instructions not yet due do not move over.
// [stop]: the stream ended; the studio renders offline again
// [stats]: the stream's {load, peak, underruns, ...}
// [scope]: the master's last samples (2048 of them, oldest first)
local studio_methods = {}
local studio_get = {}
local studio_meta = {
  __type: "studio.Studio",
  __index: studio_methods,
  __get: studio_get,
}

// new(options?: {sample_rate?: int}) -> Studio
func studio.new(options){
  options = options or {}
  local rate = options.sample_rate or 48000
  local s = {
    sample_rate: rate,
    state: events.state(rate),
    tracks: {},
    buses: {},
    lfos: {},
    routes: {},
    next_cell: 0,
    free: {},
    next_id: 1,
    slots: {},
    local_engine: null,
    player: null,
    commands: null,
    out: null,
    midi_target: null,
    midi_input: null,
    @meta: studio_meta,
  }
  s.master = s:strip("master", "master")
  return s
}

// clock(self) -> number
func studio_get.clock(self){
  return self.state.ctl[events.ctl.PLAYED]
}

// time(self) -> number
func studio_get.time(self){
  return self.state.ctl[events.ctl.PLAYED] * 1000 / self.sample_rate
}

// playing(self) -> bool
func studio_get.playing(self){
  return self.player != null
}

// dropped(self) -> int
// Instructions lost because the ring was full (a stream that fell behind).
func studio_get.dropped(self){
  return to_int(self.state.ctl[events.ctl.DROPPED])
}

// cells(n) -> the first of n parameter cells
func studio_methods.cells(self, n){
  local free = self.free[n]
  if(free != null and len(free) > 0){
    local base = free[len(free) - 1]
    remove(free, len(free) - 1)
    return base
  }
  if(self.next_cell + n > events.CELLS){
    fail("out of parameter cells: too many units")
  }
  local base = self.next_cell
  self.next_cell = base + n
  return base
}

func studio_methods.release(self, base, n){
  if(self.free[n] == null){
    self.free[n] = {}
  }
  append(self.free[n], base)
}

// the cells of a parameter set at their defaults, written here: the
// engine does not know them until the next sync
func studio_methods.fresh(self, set){
  local base = self:cells(set.count)
  for(local i = 0; i < set.count; i = i + 1){
    self.state.values[base + i] = set.list[i].default
    self.state.eff[base + i] = set.list[i].default
  }
  return base
}

func studio_methods.strip(self, name, kind){
  local slot = 0
  for(self.slots[slot] != null){
    slot = slot + 1
  }
  if(slot >= events.STRIPS){
    fail(concat("no more than ", string(events.STRIPS), " strips"))
  }
  local strip = {
    studio: self,
    name: name,
    kind: kind,
    slot: slot,
    id: self.next_id,
    base: self:fresh(STRIP),
    unit: null,
    inserts: {},
    sends: {},
    out: null,
    @meta: strip_meta,
  }
  self.next_id = self.next_id + 1
  self.slots[slot] = strip
  return strip
}

// a unit's handle: its cells at their defaults, then the options that
// name parameters or a patch; the rest goes to the unit as it is
func studio_methods.unit(self, name, kind, options){
  local def = units.find(name)
  if(def.kind != kind){
    fail(concat(name, " is an ", def.kind, ", not an ", kind))
  }
  local u = {
    studio: self,
    id: self.next_id,
    name: name,
    kind: def.kind,
    def: def,
    info: def.params,
    base: self:fresh(def.params),
    options: {},
    sidechain: null,
    patches: {},
    @meta: unit_meta,
  }
  self.next_id = self.next_id + 1
  u.params = params_proxy(u)
  for(let local p in values(def.patches or {})){
    append(u.patches, p.name)
  }
  if(options != null){
    if(options.patch != null){
      u:patch(options.patch)
    }
    for(let local e in entries(options)){
      local key = e[0]
      if(key == "patch"){
      // done
      } else if(key == "sidechain"){
        if(e[1] == null or e[1].@meta != strip_meta or e[1].kind != "track"){
          fail("sidechain: a track is what an effect listens to")
        }
        u.sidechain = e[1]
      } else if(def.params.index[key] != null){
        u:set(key, e[1])
      } else {
        local known = false
        for(let local o in values(def.options or {})){
          if(o == key){
            known = true
          }
        }
        if(not known){
          fail(concat(
            name, " has no parameter or option \"", string(key), "\""
          ))
        }
        u.options[key] = e[1]
      }
    }
  }
  return u
}

func studio_methods.track(self, name, unit, options){
  if(self:find(name) != null){
    fail(concat("there is a strip named ", name, " already"))
  }
  local u = self:unit(unit, "instrument", options)
  local strip = self:strip(name, "track")
  strip.unit = u
  u.strip = strip
  append(self.tracks, strip)
  self:sync()
  return strip
}

func studio_methods.bus(self, name){
  if(self:find(name) != null){
    fail(concat("there is a strip named ", name, " already"))
  }
  local strip = self:strip(name, "bus")
  append(self.buses, strip)
  self:sync()
  return strip
}

func studio_methods.find(self, name){
  for(let local t in values(self.tracks)){
    if(t.name == name){
      return t
    }
  }
  for(let local b in values(self.buses)){
    if(b.name == name){
      return b
    }
  }
  return null
}

func studio_methods.remove(self, strip){
  if(strip.kind == "master"){
    fail("the master stays")
  }
  local list = if(strip.kind == "track"){ self.tracks } else { self.buses }
  local found = false
  for(local i = 0; i < len(list); i = i + 1){
    if(same(list[i], strip)){
      remove(list, i)
      found = true
      break
    }
  }
  if(not found){
    fail(concat(strip.name, " is not a strip of this studio"))
  }
  // what went or sent to it, or listened to it, no longer does
  for(let local t in values(self.tracks)){
    if(t.out != null and same(t.out, strip)){
      t.out = null
    }
    local keep = {}
    for(let local send in values(t.sends)){
      if(same(send.bus, strip)){
        self:release(send.cell, 1)
      } else {
        append(keep, send)
      }
    }
    t.sends = keep
  }
  for(local slot = 0; slot < events.STRIPS; slot = slot + 1){
    local other = self.slots[slot]
    if(other != null){
      for(let local u in values(other.inserts)){
        if(u.sidechain != null and same(u.sidechain, strip)){
          u.sidechain = null
        }
      }
    }
  }
  for(let local send in values(strip.sends)){
    self:release(send.cell, 1)
  }
  for(let local u in values(strip.inserts)){
    self:release(u.base, u.info.count)
  }
  if(strip.unit != null){
    self:release(strip.unit.base, strip.unit.info.count)
  }
  self:release(strip.base, STRIP.count)
  self.slots[strip.slot] = null
  self:sync()
}

func studio_methods.lfo(self, options){
  local o = {
    studio: self, id: self.next_id, base: self:fresh(LFO), @meta: lfo_meta
  }
  self.next_id = self.next_id + 1
  append(self.lfos, o)
  if(options != null){
    if(options.rate != null){
      o.rate = options.rate
    }
    if(options.shape != null){
      o.shape = options.shape
    }
  }
  self:sync()
  return o
}

func studio_methods.midi(self, track, options){
  if(track == null){
    self.midi_target = null
  } else {
    if(track.kind != "track"){
      fail(concat("midi: ", track.name, " is not a track"))
    }
    self.midi_target = track
    self.midi_input = (options or {}).input or
      require("slang/os").getenv("MIDI_INPUT")
  }
  self:sync()
}

func studio_methods.after(self, ms){
  return self.state.ctl[events.ctl.PLAYED] + ms * self.sample_rate / 1000
}

func studio_methods.hush(self){
  self:emit(0, K.HUSH, -1)
}

func studio_methods.panic(self){
  self:emit(0, K.PANIC, -1)
}

// the strips, units, LFOs and routes as the engine takes them: plain data
func studio_methods.layout(self){
  local func unit_entry(u){
    local e = {
      id: u.id, unit: u.name, base: u.base, options: u.options, sidechain: -1
    }
    if(u.sidechain != null){
      e.sidechain = u.sidechain.slot
    }
    return e
  }
  local strips = {}
  local func add(strip){
    local e = {
      id: strip.id,
      slot: strip.slot,
      kind: strip.kind,
      base: strip.base,
      to: -1,
      sends: {},
      instrument: null,
      inserts: {},
    }
    if(strip.out != null){
      e.to = strip.out.slot
    }
    for(let local send in values(strip.sends)){
      append(e.sends, {to: send.bus.slot, cell: send.cell})
    }
    if(strip.unit != null){
      e.instrument = unit_entry(strip.unit)
    }
    for(let local u in values(strip.inserts)){
      append(e.inserts, unit_entry(u))
    }
    append(strips, e)
  }
  for(let local t in values(self.tracks)){
    add(t)
  }
  for(let local b in values(self.buses)){
    add(b)
  }
  add(self.master)
  local lfos = {}
  for(let local o in values(self.lfos)){
    append(lfos, {id: o.id, base: o.base})
  }
  local routes = {}
  for(let local r in values(self.routes)){
    append(routes, {
      lfo: r.lfo.id,
      cell: r.cell,
      depth: r.depth_cell,
      min: r.param.min,
      max: r.param.max,
      curve: r.param.curve,
    })
  }
  local midi = null
  if(self.midi_target != null){
    midi = {target: self.midi_target.slot, input: self.midi_input}
  }
  return {strips: strips, lfos: lfos, routes: routes, midi: midi}
}

// the engine hears of a change of the layout
func studio_methods.sync(self){
  if(self.player != null){
    self.commands:send({layout: self:layout()})
  } else if(self.local_engine != null){
    self.local_engine.configure(self:layout())
  }
}

func studio_methods.tell(self, id, m){
  if(self.player != null){
    self.commands:send({unit: id, message: m})
  } else {
    self:engine().message(id, m)
  }
}

// the engine in this isolate, made when it is first needed
func studio_methods.engine(self){
  if(self.player != null){
    fail("a stream plays the studio: stop() before rendering here")
  }
  if(self.local_engine == null){
    self.local_engine = require("studio/engine").new(self.state)
    self.local_engine.configure(self:layout())
  }
  return self.local_engine
}

// an instruction on its way. Without an engine yet, a parameter set now
// is written as it is; offline, an instruction for now applies at once;
// with a stream, at the engine's next block.
func studio_methods.emit(self, at, kind, target, a, b, c){
  if(self.player == null and self.local_engine == null){
    if(kind == K.PARAM and at <= 0){
      self.state.values[target] = a
      self.state.eff[target] = a
      return null
    }
    self:engine()
  }
  if(self.player != null){
    // the stream takes the ring's instructions every block
    local tries = 0
    for(not events.send(self.state, at, kind, target, a, b, c)){
      tries = tries + 1
      if(tries > 200){
        fail("the engine takes no instructions (is the stream running?)")
      }
      self.state.ctl[events.ctl.DROPPED] = self.state.ctl[events.ctl.DROPPED] -
        1
      time.sleep(1)
    }
    return null
  }
  if(events.room(self.state) == 0){
    self.local_engine.take()
  }
  events.send(self.state, at, kind, target, a, b, c)
  if(at <= self.state.ctl[events.ctl.PLAYED]){
    self.local_engine.flush()
  }
}

func studio_methods.block(self, out, frames){
  self:engine().block(out, frames)
}

func studio_methods.render(self, ms){
  local e = self:engine()
  local frames = to_int(ms * self.sample_rate / 1000)
  local left = buffer.new("float", frames)
  local right = buffer.new("float", frames)
  if(self.out == null){
    self.out = buffer.new("float", 256)
  }
  local out = self.out
  local at = 0
  for(at < frames){
    local n = math.min(128, frames - at)
    e.block(out, n)
    for(local i = 0; i < n; i = i + 1){
      left[at + i] = out[i * 2]
      right[at + i] = out[i * 2 + 1]
    }
    at = at + n
  }
  return {left: left, right: right}
}

// what the stream's isolate runs: nothing of this file's locals
local func stream_setup(state, layout, commands){
  return require("studio/engine").stream(state, layout, commands)
}

func studio_methods.start(self, audio, options){
  if(self.player != null){
    return null
  }
  if(audio == null or audio.play == null){
    fail(
      "start takes an audio module: require(\"window/audio\") or require(\"raylib/stream\")",
    )
  }
  options = options or {}
  self.local_engine = null
  self.commands = require("slang/isolate").channel()
  // (in a table literal `self:layout()` would be a field named self)
  local layout = self:layout()
  self.player = audio.play(stream_setup, {
    sample_rate: self.sample_rate,
    channels: 2,
    block: options.block or 128,
    latency: options.latency,
    args: {self.state, layout, self.commands},
  })
}

func studio_methods.stop(self){
  if(self.player == null){
    return null
  }
  local p = self.player
  self.player = null
  self.commands = null
  p:stop()
}

func studio_methods.stats(self){
  if(self.player == null){
    fail("stats: no stream plays the studio")
  }
  return self.player:stats()
}

func studio_methods.scope(self, into){
  local n = events.SCOPE
  into = into or buffer.new("float", n)
  local at = to_int(self.state.ctl[events.ctl.SCOPE_AT])
  local scope = self.state.scope
  for(local i = 0; i < n; i = i + 1){
    into[i] = scope[(at + i) % n]
  }
  return into
}

return studio
