// studio/midi: a MIDI controller's knobs bound to parameters, by MIDI
// learn. (Its keys play a track through the studio itself: s:midi(track).)
//
//   local knobs = require("studio/midi").open(s, {path: "midi_map.json"})
//   knobs:learn(lead.unit, "cutoff")      // the next knob turned is bound to it
//   // every frame:
//   knobs:poll()
//
//   knobs:binding(lead.unit, "cutoff")    // "CC 74", for a panel to show
//
// A knob moves a parameter along its slider: half a turn is half the
// slider, whatever the parameter's range and curve. Bindings are kept in
// the JSON file (midi/map), by the strip's name, the unit's place on it
// and the parameter's name, so they hold the next time the same studio is
// built.
local param = require("studio/param")
local map = require("midi/map")

local knobs = {}

// type Knobs = {learn: func(target: Unit | Strip, name: string),
//   forget: func(target: Unit | Strip, name: string),
//   binding: func(target: Unit | Strip, name: string): string?,
//   poll: func(), handle: func(m: table): bool, close: func(),
//   learning: bool}
// [learn]: the next controller that moves is bound to the parameter (a
//   unit's, or a strip's "gain" or "pan")
// [forget]: the parameter has no controller any more
// [binding]: "CC 74" for a bound parameter, else null
// [poll]: the controller's messages since the last poll move what they
//   are bound to
// [handle]: the same for one message ({kind: "cc", channel, controller,
//   value}) from elsewhere; true when it moved something
// [close]: the controller let go
// [learning]: whether a learn waits for a controller
local methods = {}
local getters = {}
local meta = {__type: "studio.Knobs", __index: methods, __get: getters}

// open(studio: Studio, options?: {path?: string, input?: string | bool})
//   -> Knobs
// path is where the bindings are kept ("midi_map.json" when absent).
// input is part of a controller's name (every controller when absent);
// false opens none (handle is then how messages come).
func knobs.open(studio, options){
  options = options or {}
  local k = {
    studio: studio,
    map: map.load(options.path or "midi_map.json"),
    input: null,
    @meta: meta,
  }
  if(options.input != false){
    k.input = try { require("midi").open(options.input) } catch { null }
  }
  return k
}

// the name a parameter is bound by: "strip/unit/param" (unit: "unit" for
// the instrument, "insert N" for an effect, "strip" for the strip itself)
local func target_of(target, name){
  if(target.info == null){
    return concat(target.name, "/strip/", name)
  }
  local strip = target.strip
  if(same(strip.unit, target)){
    return concat(strip.name, "/unit/", name)
  }
  for(local i = 0; i < len(strip.inserts); i = i + 1){
    if(same(strip.inserts[i], target)){
      return concat(strip.name, "/insert ", string(i), "/", name)
    }
  }
  raise(error.new(
    error.kinds.argument,
    "studio/midi: that unit is on no strip",
  ))
}

func methods.learn(self, target, name){
  // (raises for a parameter the target does not have)
  if(target.info != null){
    target:get(name)
  } else if(name != "gain" and name != "pan"){
    raise(error.new(
      error.kinds.argument,
      "studio/midi: a strip's gain or pan can be learned",
    ))
  }
  self.map:arm(target_of(target, name))
}

func methods.forget(self, target, name){
  self.map:clear(target_of(target, name))
}

func methods.binding(self, target, name){
  return self.map:binding(target_of(target, name))
}

// learning(self) -> bool
func getters.learning(self){
  return self.map.armed != null
}

func methods.handle(self, m){
  if(m.kind != "cc"){
    return false
  }
  local bound = self.map:target(m)
  if(bound == null){
    return false
  }
  local parts = require("slang/string").split(bound, "/")
  local s = self.studio
  local strip = s:find(parts[0])
  if(strip == null and parts[0] == s.master.name){
    strip = s.master
  }
  if(strip == null or len(parts) < 3){
    return false
  }
  local t = m.value / 127
  if(parts[1] == "strip"){
    if(parts[2] == "gain"){
      // a fader: its top is twice as loud as it is
      strip.gain = t * t * 2
    } else {
      strip.pan = t * 2 - 1
    }
    return true
  }
  local unit = strip.unit
  if(parts[1] != "unit"){
    unit = strip.inserts[to_int(require("slang/string").substring(parts[1], 7))]
  }
  if(unit == null or unit.info.index[parts[2]] == null){
    return false
  }
  local d = unit.info.list[unit.info.index[parts[2]]]
  unit:set(parts[2], param.from_t(d, t))
  return true
}

func methods.poll(self){
  if(self.input == null){
    return null
  }
  for(let local m in values(self.input:read())){
    self:handle(m)
  }
}

func methods.close(self){
  if(self.input != null){
    self.input:close()
    self.input = null
  }
}

return knobs
