// Property and method lookups: ns per operation, the loop's own time
// taken off, best of three. Compares plain tables, __index tables (also
// several levels deep), __get/__set properties, __index/__newindex
// functions (as a class helper would write them) and accessor methods.
local time = require("slang/time")

local n = 5000000

local func best(f){
  local least = null
  for(local k = 0; k < 3; k = k + 1){
    local t0 = time.clock()
    f()
    local dt = time.clock() - t0
    if(least == null or dt < least){
      least = dt
    }
  }
  return least * 1000000 / n
}

local loop = best(func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    s = s + 1
  }
  return s
})
print("loop alone: ", to_int(loop * 10) / 10, " ns (taken off below)\n")

local func row(name, f){
  local ns = best(f) - loop
  print(name, ": ", to_int(ns * 10) / 10, " ns\n")
}

// ------------------------------------------------------------ the objects

local methods = {
  m: func(self){ return 1 },
  get_x: func(self){ return self.x },
  set_x: func(self, v){ self.x = v },
}
local plain = {x: 1}
local with_meta = {x: 1}
with_meta.meta = {__index: methods}

// a chain of __index tables: the method on the last one
local func chained(depth){
  local top = methods
  for(local d = 1; d < depth; d = d + 1){
    local level = {}
    level.meta = {__index: top}
    top = level
  }
  local o = {x: 1}
  o.meta = {__index: top}
  return o
}

// properties through __index and __newindex functions, as a class helper
// would make them
local helper_methods = {m: func(self){ return 1 }}
local helper_props = {
  x: {
    get: func(self){ return self.state_x },
    set: func(self, v){ self.state_x = v },
  },
}
local helper = {state_x: 1}
helper.meta = {
  __index: func(self, key){
    local f = helper_methods[key]
    if(f != null){
      return f
    }
    local p = helper_props[key]
    if(p != null){
      return p.get(self)
    }
    return null
  },
  __newindex: func(self, key, v){
    local p = helper_props[key]
    if(p != null){
      p.set(self, v)
      return
    }
    set_raw(self, key, v)
  },
}

// properties through __get and __set, methods through the __index table
local with_get = {vx: 1}
with_get.meta = {
  __index: methods,
  __get: {px: func(self){ return self.vx }},
  __set: {px: func(self, v){ self.vx = v }},
}

// a chain of __index tables whose every metatable has a __get (the
// method still on the last table), and one where only the last does,
// holding the property: inherited from depth levels up
local func chained_get(depth, everywhere){
  local top = methods
  local top_meta_get = {px: func(self){ return self.vx }}
  for(local d = 1; d < depth; d = d + 1){
    local level = {}
    level.meta = {__index: top}
    if(everywhere or d == 1){
      level.meta.__get = d == 1 and top_meta_get or {other: func(self){ return 0 }}
    }
    top = level
  }
  local o = {vx: 1}
  o.meta = {__index: top}
  if(depth == 1 or everywhere){
    o.meta.__get = depth == 1 and top_meta_get or {other: func(self){ return 0 }}
  }
  return o
}

// an __newindex function that a store of an existing key never reaches
local guarded = {x: 1}
guarded.meta = {__index: methods, __newindex: func(t, k, v){ set_raw(t, k, v) }}

// ------------------------------------------------------------ reads

print("\n-- reads\n")
row("own field, no metatable (o.x)", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){ s = s + plain.x }
})
row("own field, metatable (o.x)", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){ s = s + with_meta.x }
})
row("method, __index table (o:m())", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){ s = s + with_meta:m() }
})
row("method, __index function (o:m())", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){ s = s + helper:m() }
})
row("getter method, __index table (o:get_x())", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){ s = s + with_meta:get_x() }
})
row("property, __index function (o.x)", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){ s = s + helper.x }
})
row("missing key, __index table (o.nope)", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    if(with_meta.nope == null){ s = s + 1 }
  }
})
row("missing key, __index function (o.nope)", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    if(helper.nope == null){ s = s + 1 }
  }
})

print("\n-- with __get and __set\n")
row("own field, metatable with __get (o.vx)", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){ s = s + with_get.vx }
})
row("method, __index table + __get (o:m())", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){ s = s + with_get:m() }
})
row("property, __get (o.px)", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){ s = s + with_get.px }
})
row("missing key, __index table + __get (o.nope)", func(){
  local s = 0
  for(local i = 0; i < n; i = i + 1){
    if(with_get.nope == null){ s = s + 1 }
  }
})

print("\n-- __index chains (method on the last table)\n")
for(let local depth in values({1, 2, 4, 8})){
  local o = chained(depth)
  row(concat("method, depth ", depth, " (o:m())"), func(){
    local s = 0
    for(local i = 0; i < n; i = i + 1){ s = s + o:m() }
  })
}
for(let local depth in values({1, 2, 4, 8})){
  local o = chained(depth)
  row(concat("missing key, depth ", depth, " (o.nope)"), func(){
    local s = 0
    for(local i = 0; i < n; i = i + 1){
      if(o.nope == null){ s = s + 1 }
    }
  })
}

for(let local depth in values({1, 2, 4, 8})){
  local o = chained_get(depth, true)
  row(concat("method, depth ", depth, ", __get on every level"), func(){
    local s = 0
    for(local i = 0; i < n; i = i + 1){ s = s + o:m() }
  })
}
for(let local depth in values({1, 2, 4, 8})){
  local o = chained_get(depth, false)
  row(concat("property inherited from depth ", depth, " (o.px)"), func(){
    local s = 0
    for(local i = 0; i < n; i = i + 1){ s = s + o.px }
  })
}

// ------------------------------------------------------------ writes

print("\n-- writes\n")
row("own field, no metatable (o.x = v)", func(){
  for(local i = 0; i < n; i = i + 1){ plain.x = i }
})
row("own field, metatable (o.x = v)", func(){
  for(local i = 0; i < n; i = i + 1){ with_meta.x = i }
})
row("own field, metatable with __newindex (o.x = v)", func(){
  for(local i = 0; i < n; i = i + 1){ guarded.x = i }
})
row("setter method, __index table (o:set_x(v))", func(){
  for(local i = 0; i < n; i = i + 1){ with_meta:set_x(i) }
})
row("property, __index function (o.x = v)", func(){
  for(local i = 0; i < n; i = i + 1){ helper.x = i }
})
local plain_meta = {__type: "bench.Plain"}
local method_meta = {__index: methods}
row("new object, then a new field, metatable without __index", func(){
  for(local i = 0; i < n; i = i + 1){
    local o = {}
    o.meta = plain_meta
    o.x = i
  }
})
row("new object, then a new field, metatable with __index table", func(){
  for(local i = 0; i < n; i = i + 1){
    local o = {}
    o.meta = method_meta
    o.x = i
  }
})
row("own field, metatable with __set (o.vx = v)", func(){
  for(local i = 0; i < n; i = i + 1){ with_get.vx = i }
})
row("property, __set (o.px = v)", func(){
  for(local i = 0; i < n; i = i + 1){ with_get.px = i }
})
