// Entity types and instances. Types are declared with the entity DSL
// (dsl/entity); this module is their runtime.
//
//   local g = entities.Goblin(3, 4)      // an instance at tile (3, 4)
//   g.hp                                 // the default from the declaration
//   type(g) == "Goblin"                  // and 'Goblin{...} patterns match
//   entities.is_a(g, "Monster")          // true when Goblin extends Monster
local m = {}

entities = entities or {}

func m.define(name, base_name, fields){
  local base = null
  if(base_name != null){
    base = entities[base_name]
    if(base == null){
      error("entity ", name, ": base entity ", base_name, " is not defined")
    }
    fields.meta = {__index: base.fields}
  }
  local T = {name: name, base: base, fields: fields}
  T.instance_meta = {__index: fields, __type: name}
  T.meta = {
    __index: fields,
    __call: func(self, x, y, overrides){ return m.spawn(T, x, y, overrides) },
    __tostring: func(self){ return concat("entity type ", name) },
  }
  entities[name] = T
  return T
}

// spawn(T, x, y, overrides) -> instance
func m.spawn(T, x, y, overrides){
  local e = {type: T, x: x, y: y}
  if(overrides != null){
    for(let local k in keys(overrides)){
      e[k] = overrides[k]
    }
  }
  e.meta = T.instance_meta
  if(e.init != null){
    e:init()
  }
  return e
}

// is_a(e, name) -> whether e's type is name or extends it
func m.is_a(e, name){
  local T = e.type
  for(T != null){
    if(T.name == name){
      return true
    }
    T = T.base
  }
  return false
}

return m
