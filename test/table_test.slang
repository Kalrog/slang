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
    local t1 = {1, 2}
    local t2 = {1, 2}
    assert(t1 == t2, "Tables should be equal")
    t1[0] = 3
    assert(t1 != t2, "Tables should not be equal")

    t1 = {a: 1, b: {hello: "world"}}
    t2 = {a: 1, b: {hello: "world"}}
    assert(t1 == t2, "Tables should be equal")
    t1 .b.hello = "moon"
    assert(t1 != t2, "Tables should not be equal")
  }
  t.test("sort"){
    assert(table.sort({3, 1, 2}) == {1, 2, 3})
    assert(table.sort({"b", "c", "a"}) == {"a", "b", "c"}, "strings byte by byte")
    assert(table.sort({}) == {} and table.sort({5}) == {5})
    local people = {
      {name: "a", age: 30}, {name: "b", age: 20}, {name: "c", age: 30},
      {name: "d", age: 20}
    }
    table.sort(people, func(x, y){ return x.age < y.age })
    local names = table.map(people, func(p){ return p.name })
    assert(names == {"b", "d", "a", "c"}, "stable: equal ages keep their order")
    local many = {}
    for(local i = 0; i < 100; i = i + 1){
      append(many, (i * 37) % 100)
    }
    table.sort(many, func(x, y){ return x > y })
    for(local i = 1; i < 100; i = i + 1){
      assert(many[i - 1] >= many[i], "descending with a less function")
    }
  }
  t.test("insert, index_of, reverse, slice"){
    local l = {1, 3}
    table.insert(l, 1, 2)
    table.insert(l, 3, 4)
    table.insert(l, 0, 0)
    assert(l == {0, 1, 2, 3, 4})
    assert(pcall(table.insert, l, 9, 1)[0] == "err")
    assert(table.index_of(l, 3) == 3 and table.index_of(l, 7) == -1)
    assert(table.reverse({1, 2, 3}) == {3, 2, 1} and table.reverse({}) == {})
    assert(table.slice(l, 1, 3) == {1, 2})
    assert(table.slice(l, -2) == {3, 4})
    assert(table.slice(l) == l and table.slice(l, 3, 99) == {3, 4})
  }
}
