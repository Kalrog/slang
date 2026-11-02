// slang/class: classes of objects with methods and properties, for
// libraries whose objects stand for something else (a C struct, a
// physics body, a database handle). A property reads as a field and is
// written as one: `body.position` calls its getter, `body.position = p`
// its setter, both through the object's metatable.
//
//   local class = require("slang/class")
//   local Counter = class.new({
//     name: "demo.Counter",
//     methods: {
//       add: func(self, n){ self.state.n = self.state.n + n },
//     },
//     properties: {
//       value: {get: func(self){ return self.state.n }},
//       limit: {
//         get: func(self){ return self.state.limit },
//         set: func(self, v){ self.state.limit = v },
//       },
//     },
//   })
//   local c = class.make(Counter, {state: {n: 0, limit: 10}})
//   c:add(2)
//   c.value          // 2
//   c.limit = 20     // the setter
//   c.value = 5      // raises: demo.Counter.value is read-only
//   c.note = "mine"  // not a property: an ordinary field of c
//
// A key the class does not know can be looked up lazily by
// options.resolve(key), which returns {method: f}, {get?: f, set?: f},
// {gone: text} (a key that used to exist; reading or writing it raises
// with the text) or null; the answer is kept per class. Like any
// metatable, the class sees only keys the object does not hold itself:
// keep an object's own data under keys that are not property names.
local m = {}

// Class = {name: string, meta: table, methods: table, properties: table}

// new(options: {name: string, methods?: table, properties?: table,
//   resolve?: function}) -> Class
// A class: [Class.meta] is the metatable of its objects (its __type is
// name).
func m.new(options){
  local name = options.name
  local methods = options.methods or {}
  local properties = options.properties or {}
  local resolve = options.resolve
  local cache = {}
  local func lookup(key){
    local p = properties[key]
    if(p != null){
      return p
    }
    local r = cache[key]
    if(r == null){
      r = false
      if(resolve != null){
        r = resolve(key) or false
      }
      cache[key] = r
    }
    return r
  }
  local class = {name: name, methods: methods, properties: properties}
  class.meta = {
    __index: func(self, key){
      local f = methods[key]
      if(f != null){
        return f
      }
      local r = lookup(key)
      if(r == false){
        return null
      }
      if(r.get != null){
        return r.get(self)
      }
      if(r.method != null){
        return r.method
      }
      if(r.gone != null){
        error(name, ".", key, " is gone: ", r.gone)
      }
      // write-only
      return null
    },
    __newindex: func(self, key, v){
      if(methods[key] == null){
        local r = lookup(key)
        if(r != false){
          if(r.set != null){
            r.set(self, v)
            return
          }
          if(r.get != null){
            error(name, ".", key, " is read-only")
          }
          if(r.gone != null){
            error(name, ".", key, " is gone: ", r.gone)
          }
        }
      }
      set_raw(self, key, v)
    },
    __type: name,
    __class: class,
  }
  return class
}

// make(class: Class, fields?: table) -> table
// An object of the class holding fields as its own (they are set raw:
// no setter runs).
func m.make(class, fields){
  local o = fields or {}
  o.meta = class.meta
  return o
}

// the types of values without a metatable (type() reports a class's own
// name, so only these are ruled out)
local plain = {
  null: true,
  bool: true,
  int: true,
  double: true,
  string: true,
  function: true,
  thread: true,
}

// of(v: any) -> Class?
// The class of an object made by [make] (or given its meta), or null.
func m.of(v){
  if(plain[type(v)]){
    return null
  }
  local mt = v.meta
  if(mt == null){
    return null
  }
  return mt.__class
}

return m
