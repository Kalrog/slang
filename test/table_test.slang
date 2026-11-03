local str = require("slang/string")
local t = require("slang/test")
local table = require("slang/table")

t.group("table"){
  t.test("assigning null removes that key only, a list index too"){
    local held = {"C", "C#", "D", "E"}
    held[1] = null
    assert(held[0] == "C" and held[1] == null and held[2] == "D" and held[3] == "E")
    assert(len(held) == 1 and count(held) == 3, "the list ends at the gap")
    held[1] = "C#"
    assert(held == {"C", "C#", "D", "E"}, "filled again, a list again")
    held[3] = null
    assert(held == {"C", "C#", "D"}, "the last one")
  }
  t.test("remove takes an element out of a list and shifts the rest"){
    local l = {"a", "b", "c"}
    assert(remove(l, 1) == "b" and l == {"a", "c"})
    assert(remove(l, 1) == "c" and l == {"a"})
    local r = pcall(remove, l, 5)
    assert(r[0] == "err" and r[1].message == "remove: index 5 is not in the list (length 1)", r[1].message)
    r = pcall(remove, {x: 1}, "x")
    assert(r[0] == "err", "a key is removed with t.x = null")
  }
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
  t.test("callbacks may collect, raise, and compare with __lt"){
    local vm = require("slang/vm")
    // what map builds survives collections in its callback
    local out = table.map({1, 2, 3}, func(x){
      vm.collect()
      return {x * 2}
    })
    assert(out == {{2}, {4}, {6}})
    local r = pcall(table.sort, {3, 1, 2}, func(a, b){ error("no order") })
    assert(r[0] == "err" and r[1].message == "no order", r[1].message)
    r = pcall(table.sort, {1, "a"})
    assert(r[0] == "err", "numbers and strings need a less function")
    local v = {__lt: func(a, b){ return a.n < b.n }}
    local sorted = table.sort({{n: 2, @meta: v}, {n: 1, @meta: v}})
    assert(sorted[0].n == 1 and sorted[1].n == 2)
    assert(table.contains({1, false}, false), "false is a value like any other")
    assert(table.keys({1, x: 2}) == {0, "x"})
  }
  t.test("len is the list, count every entry"){
    local t = {"a", "b", x: 1}
    assert(len(t) == 2 and count(t) == 3)
    assert(len({x: 1}) == 0 and count({x: 1}) == 1 and count({}) == 0)
    append(t, "c")
    assert(t[2] == "c" and len(t) == 3, "append adds to the list")
    local n = 0
    for(let local v in values({1, false, 3})){
      n = n + 1
    }
    assert(n == 3, "values goes on past false")
    local matched = false
    if(let local x = false){
      matched = true
    }
    assert(matched, "a local pattern matches anything but null")
  }
  t.test("map, filter, fold take lists; maps go through entries"){
    assert(table.map({1, 2, 3}, func(x){ if(x == 2){ return null } return x * 10 }) == {10, 30})
    assert(table.filter({1, 2, 3, 4}, func(v){ return v % 2 == 0 }) == {2, 4})
    assert(table.map({1, x: 5}, func(v){ return v }) == {1}, "named keys are not the list")
    assert(table.entries({"a", x: 1}) == {{0, "a"}, {"x", 1}})
    local ages = {ann: 20, bob: 12, cid: 40}
    local adults = table.from_entries(table.filter(table.entries(ages), func(e){ return e[1] >= 18 }))
    assert(adults == {ann: 20, cid: 40})
    assert(pcall(table.from_entries, {1})[0] == "err")
  }
  t.test("a list holds no null: gaps keep positions"){
    local func pass(...a){ return a }
    local func forward(...a){ return pass(...a) }
    local a = forward(1, null, 3)
    assert(a[0] == 1 and a[1] == null and a[2] == 3 and len(a) == 1, "a rest parameter keeps positions")
    local func three(x, y, z){ return {x, y, z} }
    local gappy = {"a"}
    gappy[2] = "c"
    local r = three(...gappy)
    assert(r[0] == "a" and r[1] == null and r[2] == "c", "a spread passes a gap as null")
    local e = pcall(append, {}, null)
    assert(e[0] == "err" and str.index_of(e[1].message, "no null") >= 0, e[1].message)
    local p = pcall(func(){ return null })
    assert(p[0] == "ok" and p[1] == null and len(p) == 1)
    // the arguments as they were passed, trailing nulls included
    local vm = require("slang/vm")
    local func counted(...rest){ return vm.arg_count() }
    local func two(a, b){ return vm.arg_count() }
    assert(counted() == 0 and counted(null) == 1 and counted(1, null, null) == 3)
    assert(two(1) == 1 and two(1, 2) == 2)
  }
  t.test("same is identity, == compares contents"){
    local x = {1}
    assert(same(x, x) and not same(x, {1}) and x == {1})
    assert(same("a", "a") and same(1, 1.0) and not same(1, 2) and not same(x, null))
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
