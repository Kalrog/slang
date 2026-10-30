local t = require("slang/test")

t.group("metatables"){
  t.test("metatable __index basic"){
    local foo = {type: "Foo", bar: 42}

    local bar = {type: "Bar", fooBar: 12}

    bar.meta = {__index: foo}

    assert(bar.bar == 42, "metatable get table (__index) correctly")
    assert(bar.fooBar == 12, "metatable get normal table value correctly")
  }

  t.test("metatable __index works for pattern matching"){
    local foo = {type: "Foo", bar: 42}

    local bar = {type: "Bar", fooBar: 12}

    bar.meta = {__index: foo}

    if(not let {bar: 42} = bar){
      assert(false, "should never reach here")
    }
  }

  t.test("metatable __index set value"){
    local foo = {type: "Foo", bar: 42}
    local bar = {type: "Bar", fooBar: 12}
    bar.meta = {__index: foo}
    bar.bar = 12
    assert(bar.bar == 12, "metatable set table value correctly")
    assert(foo.bar == 42, "metatable set table value correctly")
  }

  t.test("metatable __newindex"){
    local foo = {type: "Foo", bar: 42}
    local bar = {type: "Bar", fooBar: 12}
    bar.meta = {__newindex: foo}
    bar.bar = 12
    assert(foo.bar == 12, "metatable set table value correctly")
    bar.newField = 42
    assert(foo.newField == 42, "metatable set table value correctly")
    assert(
      bar.newField == null,
      "metatable set table only on meta table not on the table itself"
    )
  }

  t.test("metatable __index function"){
    local expectedField
    local expectedTable
    local func expect(table, field){
      expectedField = field
      expectedTable = table
    }
    local func index(table, key){
      assert(
        table == expectedTable,
        "metatable __index function table is correct"
      )
      assert(key == expectedField, "metatable __index function key is correct")
      return true
    }

    local foo = {type: "Foo", bar: 42}

    foo.meta = {__index: index}

    expect(null, null)
    assert(foo.bar == 42, "__index is only called when field is not found")
    expect(foo, "foo")
    assert(foo.foo == true, "__index works and is called")
  }

  t.test("metatable __newindex function"){
    local expectedField
    local expectedTable
    local expectedValue
    local func expect(table, field, value){
      expectedField = field
      expectedTable = table
      expectedValue = value
    }
    local func newindex(table, key, value){
      assert(
        table == expectedTable,
        "metatable __newindex function table is correct"
      )
      assert(
        key == expectedField,
        "metatable __newindex function key is correct"
      )
      assert(
        value == expectedValue,
        "metatable __newindex function value is correct"
      )
    }
    local foo = {type: "Foo", bar: 42}
    foo.meta = {__newindex: newindex}
    expect(null, null, null)
    foo.bar = 42
    assert(foo.bar == 42, "__newindex is only called when field is not found")
    expect(foo, "foo", 42)
    foo.foo = 42
    assert(foo.foo == null, "__newindex works and is called")
  }
}

t.group("operator metamethods"){
  local Vec = {}
  local vec_meta = {
    __index: Vec,
    __type: "Vec",
    __add: func(a, b){ return Vec.new(a.x + b.x, a.y + b.y) },
    __sub: func(a, b){ return Vec.new(a.x - b.x, a.y - b.y) },
    __mul: func(a, b){
      if(type(a) == "Vec" and type(b) == "Vec"){ return a.x * b.x + a.y * b.y }
      if(type(a) == "Vec"){ return Vec.new(a.x * b, a.y * b) }
      return Vec.new(a * b.x, a * b.y)
    },
    __div: func(a, b){ return Vec.new(a.x / b, a.y / b) },
    __mod: func(a, b){ return Vec.new(a.x % b, a.y % b) },
    __pow: func(a, b){ return Vec.new(a.x ^ b, a.y ^ b) },
    __unm: func(a){ return Vec.new(-a.x, -a.y) },
    __eq: func(a, b){ return a.x == b.x and a.y == b.y },
    __lt: func(a, b){ return a:sqlen() < b:sqlen() },
    __le: func(a, b){ return a:sqlen() <= b:sqlen() },
    __tostring: func(a){ return concat("(", a.x, ", ", a.y, ")") },
    __len: func(a){ return 2 },
  }
  func Vec.new(x, y){ return {x: x, y: y, meta: vec_meta} }
  func Vec.sqlen(self){ return self.x * self.x + self.y * self.y }
  Vec.meta = {__call: func(self, x, y){ return Vec.new(x, y) }}

  t.test("__call constructs through the type table"){
    local v = Vec(1, 2)
    assert(type(v) == "Vec", "type")
    assert(v.x == 1 and v.y == 2, "fields")
  }
  t.test("binary arithmetic metamethods"){
    local a = Vec(1, 2)
    local b = Vec(10, 20)
    assert((a + b).x == 11 and (a + b).y == 22, "__add")
    assert((b - a).x == 9 and (b - a).y == 18, "__sub")
    assert(a * b == 50, "__mul vec vec")
    assert((a * 3).y == 6, "__mul vec scalar")
    assert(
      (3 * a).y == 6,
      "__mul scalar vec uses the right operand's metatable"
    )
    assert((b / 2).x == 5.0, "__div")
    assert((b % 3).x == 1, "__mod")
    assert((a ^ 2).y == 4, "__pow")
    assert((-a).x == - 1 and (-a).y == - 2, "__unm")
    assert((a + b + a).x == 12, "chained")
  }
  t.test("__eq replaces structural equality"){
    local a = Vec(1, 2)
    local b = Vec(1, 2)
    b.tag = "different"
    assert(a == b, "__eq decides")
    assert(not(a != b), "!= is the negation")
    assert(a != Vec(2, 2), "different coordinates")
    assert(not(a == null), "__eq is not consulted for non-table operands")
    assert(a != 5, "nor for numbers")
    assert({x: 1} == {x: 1}, "tables without __eq still compare structurally")
  }
  t.test("ordering metamethods"){
    local small = Vec(1, 0)
    local big = Vec(3, 4)
    assert(small < big, "__lt")
    assert(small <= big, "__le")
    assert(big > small, "> is not <=")
    assert(big >= small, ">= is not <")
    assert(not(big < small), "__lt false")
    assert(Vec(3, 4) <= Vec(4, 3), "__le equal lengths")
  }
  t.test("__tostring and __len"){
    local v = Vec(1, 2)
    assert(string(v) == "(1, 2)", "string()")
    assert(concat("v = ", v) == "v = (1, 2)", "concat")
    assert(len(v) == 2, "len")
    local r = pcall(error, v)
    assert(r[1].message == "(1, 2)", "error message")
  }
  t.test("tables without metamethods still raise errors"){
    local r = pcall(func(){ return {} + 1 })
    assert(r[0] == "err", "add")
    r = pcall(func(){ return {} < {} })
    assert(r[0] == "err", "compare")
    local empty = {}
    r = pcall(func(){ return -empty })
    assert(r[0] == "err", "negate")
    r = pcall(func(){ return {}() })
    assert(r[0] == "err", "call")
  }
  t.test("errors inside metamethods propagate"){
    local bad = {meta: {__add: func(a, b){ error("no adding") }}}
    local r = pcall(func(){ return bad + 1 })
    assert(r[0] == "err" and r[1].message == "no adding", "error propagates")
  }
  t.test("userdata metamethods"){
    // files are userdata with an __index metatable; they have no __add
    local r = pcall(func(){ return open("README.md", "r") + 1 })
    assert(r[0] == "err", "no __add on files")
  }
}
