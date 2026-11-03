// midi/map: controllers bound to a program's controls, by MIDI learn: the
// program arms a target (any string naming one of its controls), and the
// next controller (a CC) that moves is bound to it. Bindings are saved to
// a JSON file at once, so they are there the next time.
//
//   local map = require("midi/map").load("midi_map.json")
//   map:arm("cutoff")                       // the user clicked a knob
//   for(let local m in values(input:read())){
//     if(m.kind == "cc"){
//       local target = map:target(m)        // binds first when armed
//       if(target != null){ set(target, m.value / 127) }
//     }
//   }
//   map:binding("cutoff")                   // "CC 74" (null when unbound)
//
// A controller moves one target; binding a target again moves it to the
// new controller.
local os = require("slang/os")
local json = require("slang/json")

local map = {}

local map_methods = {}
local map_meta = {__type: "midi.Map", __index: map_methods}

// a controller's key: "channel:number"
local func key_of(m){
  return concat(string(m.channel), ":", string(m.controller))
}

// load(path: string) -> Map: the bindings saved at path (none when the
// file does not exist)
func map.load(path){
  local bindings = {}
  if(os.exists(path)){
    bindings = json.decode(os.read_file(path), path)
  }
  return {path: path, bindings: bindings, armed: null, meta: map_meta}
}

func map_methods.save(self){
  os.write_file(self.path, json.encode(self.bindings, {indent: "  "}))
}

// arm(target: string?): the next controller to move binds to target (null:
// stop waiting)
func map_methods.arm(self, target){
  self.armed = target
}

// target(m: Message) -> string?: the target a cc message moves; when one
// is armed the controller is bound to it first
func map_methods.target(self, m){
  local key = key_of(m)
  if(self.armed != null){
    self:clear(self.armed)
    self.bindings[key] = self.armed
    self.armed = null
    self:save()
  }
  return self.bindings[key]
}

// clear(target: string): the target has no controller any more
func map_methods.clear(self, target){
  local gone = {}
  for(let local e in entries(self.bindings)){
    if(e[1] == target){
      append(gone, e[0])
    }
  }
  for(let local k in values(gone)){
    self.bindings[k] = null
  }
  if(len(gone) > 0){
    self:save()
  }
}

// binding(target: string) -> string?: "CC 21" (with the channel when it is
// not 1: "CC 21/2"), or null
func map_methods.binding(self, target){
  for(let local e in entries(self.bindings)){
    if(e[1] == target){
      local parts = require("slang/string").split(e[0], ":")
      if(parts[0] == "1"){
        return concat("CC ", parts[1])
      }
      return concat("CC ", parts[1], "/", parts[0])
    }
  }
  return null
}

return map
