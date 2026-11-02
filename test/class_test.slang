local test = require("slang/test")
local class = require("slang/class")

local func raises(f, needle){
  local r = pcall(f)
  assert(r[0] == "err", "expected an error")
  local str = require("slang/string")
  assert(str.contains(r[1].message, needle), r[1].message)
}

local Counter = class.new({
  name: "demo.Counter",
  methods: {
    add: func(self, n){
      self.state.n = self.state.n + n
    },
  },
  properties: {
    value: {get: func(self){ return self.state.n }},
    limit: {
      get: func(self){ return self.state.limit },
      set: func(self, v){ self.state.limit = v },
    },
    sink: {set: func(self, v){ self.state.sunk = v }},
  },
  resolve: func(key){
    if(key == "twice"){
      return {get: func(self){ return self.state.n * 2 }}
    }
    if(key == "get_value"){
      return {gone: "read the property (x.value)"}
    }
    return null
  },
})

test.group("slang/class", func(){
  test.test("methods, properties and the type"){
    local c = class.make(Counter, {state: {n: 0, limit: 10}})
    c:add(2)
    assert(c.value == 2 and c.twice == 4)
    assert(type(c) == "demo.Counter" and class.of(c) == Counter)
    c.limit = 20
    assert(c.limit == 20 and c.state.limit == 20)
  }
  test.test("read-only, write-only and gone keys"){
    local c = class.make(Counter, {state: {n: 1}})
    raises(func(){ c.value = 5 }, "demo.Counter.value is read-only")
    c.sink = "x"
    assert(c.sink == null and c.state.sunk == "x")
    raises(func(){ return c.get_value }, "is gone: read the property")
  }
  test.test("other keys are the object's own fields"){
    local c = class.make(Counter, {state: {n: 0}})
    assert(c.note == null)
    c.note = "mine"
    assert(c.note == "mine")
    assert(class.of({}) == null)
  }
})
