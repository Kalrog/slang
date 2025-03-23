local t = require("slang/test")
local table = require("slang/table")

t.group("table"){
  t.test("create table"){
    local t = {}
    assert(type(t) == "table", "Table should be a table")
  }
  t.test("named fields"){
    local t = {a: 1, b: 2}
    assert(t.a == 1, "Table should have a field a with value 1")
    assert(t.b == 2, "Table should have a field b with value 2")
    t.a = 3
    assert(t.a == 3, "Table should have a field a with value 3")
  }
  t.test("index fields"){
    local t = {1, 2}
    assert(t[0] == 1, "Table should have a field 1 with value 1")
    assert(t[1] == 2, "Table should have a field 2 with value 2")
    t[0] = 3
    assert(t[0] == 3, "Table should have a field 1 with value 3")
  }
  t.test("equality"){
    local t1 = {1, 2};
    local t2 = {1, 2};
    assert(t1 == t2, "Tables should be equal")
    t1[0] = 3
    assert(t1 != t2, "Tables should not be equal")

    t1 = {a:1, b:{hello: "world"}}
    t2 = {a:1, b:{hello: "world"}}
    assert(t1 == t2, "Tables should be equal")
    t1.b.hello = "moon"
    assert(t1 != t2, "Tables should not be equal")
  }
  t.test("table.dequeue"){
    local t = {1, 2, 3}
    assert(table.dequeue(t) == 1, "table.dequeue should return the first element")
    print(t)
    assert(len(t) == 2, "table.dequeue should remove the first element")
    assert(table.dequeue(t) == 2, "table.dequeue should return the first element")
    assert(len(t) == 1, "table.dequeue should remove the first element")
    assert(table.dequeue(t) == 3, "table.dequeue should return the first element")
    assert(len(t) == 0, "table.dequeue should remove the first element")
  }
}
