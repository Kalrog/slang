local test = require("slang/test")

test.group("for in loop", func(){
  test.test("basic for in over all values", func(){
    local testTable = {1, 2, 3, 4}

    local current = 1

    for(let local v in values(testTable)){
      assert(v == current, "value is not equal to current")
      current = current + 1
    }
  })

  test.test("an element that does not match raises; let? skips it", func(){
    local testTable = {
      {name: "Jane", age: 21},
      {name: "John", age: 20},
      {name: "Doe", age: 22},
    }
    local current = 0
    for(let? {name: "John"} in values(testTable)){
      current = current + 1
    }
    assert(current == 1, "let? visits the matching element only")
    local e = test.raises(func(){
      for(let {name: "John"} in values(testTable)){ }
    })
    assert(e.kind == "for", "let raises at the first")
    local seen = 0
    for(let local v? in values({1, null, 3})){
      seen = seen + 1
    }
    assert(seen == 3, "a null element is an element")
    // local v does not take null
    test.raises(func(){ for(let local v in values({1, null, 3})){ } })
  })

  test.test("for in entries"){
    local shoppingList = {apples: 5, oranges: 10, bananas: 15}

    for(let {local key, local value} in entries(shoppingList)){
      assert(shoppingList[key] == value, "value is not equal to current")
    }
  }

  // keys, values and entries of a table are walked in the loop itself
  // (forin_prep, forin_next): live, nothing copied, the order of keys
  test.test("keys, values and entries: lists, then the other keys in order", func(){
    local t = {10, 20, 30, b: 2, a: 1}
    local ks = {}
    local vs = {}
    local es = {}
    for(let local k in keys(t)){ append(ks, k) }
    for(let local v in values(t)){ append(vs, v) }
    for(let local e in entries(t)){ append(es, e) }
    assert(ks == {0, 1, 2, "b", "a"}, concat("keys ", ks))
    assert(vs == {10, 20, 30, 2, 1}, concat("values ", vs))
    assert(es == {{0, 10}, {1, 20}, {2, 30}, {"b", 2}, {"a", 1}})
    // null elements are elements; null iterates nothing for values and entries
    local n = 0
    for(let local v? in values({null, null, x: null})){ n = n + 1 }
    for(let local v in values(null)){ n = n + 100 }
    for(let local e in entries(null)){ n = n + 100 }
    assert(n == 3, n)
    local ds = {}
    for(let {local k, local v} in entries({x: 1})){ append(ds, k) append(ds, v) }
    assert(ds == {"x", 1})
  })

  test.test("the walk is live: added keys come, deleted ones not yet reached go", func(){
    local q = {1}
    local seen = {}
    for(let local v in values(q)){
      append(seen, v)
      if(v < 4){ append(q, v + 1) }
    }
    assert(seen == {1, 2, 3, 4}, concat("a list that grows ", seen))
    local t = {a: 1, b: 2, c: 3}
    local got = {}
    for(let local k in keys(t)){
      append(got, k)
      if(k == "a"){
        delete(t, "b")
        t.d = 4
      }
    }
    assert(got == {"a", "c", "d"}, concat("keys ", got))
    // values are read when reached
    local u = {1, 2, 3}
    local sum = 0
    for(let local v in values(u)){
      sum = sum + v
      u[2] = 30
    }
    assert(sum == 33, sum)
  })

  test.test("break, continue, nested loops and closures over the element", func(){
    local t = {1, 2, 3, 4, 5}
    local s = 0
    for(let local v in values(t)){
      if(v == 2){ continue }
      if(v == 5){ break }
      for(let local w in values(t)){
        if(w > 1){ break }
        s = s + v * 10 + w
      }
    }
    assert(s == 10 + 1 + 30 + 1 + 40 + 1, s)
    local fs = {}
    for(let local v in values(t)){ append(fs, func(){ return v }) }
    assert(fs[0]() == 1 and fs[4]() == 5, "each closure has its element")
  })

  test.test("anything else is called as before: other functions, buffers, a shadowed values", func(){
    local buffer = require("slang/buffer")
    local b = buffer.from({1.5, 2.5}, "double")
    local s = 0.0
    for(let local v in values(b)){ s = s + v }
    for(let local k in keys(b)){ s = s + k }
    assert(s == 5.0, s)
    local func count(n){
      local i = 0
      return func(){
        if(i >= n){ return stop }
        i = i + 1
        return i
      }
    }
    local c = 0
    for(let local i in count(3)){ c = c + i }
    assert(c == 6, c)
    // keys of something that is not a table: null, which is not callable
    test.raises(func(){ for(let local k in keys(5)){ } })
    test.raises(func(){ for(let local v in values(5)){ } })
    local values = func(t){ return count(2) }
    local d = 0
    for(let local i in values({100, 200})){ d = d + i }
    assert(d == 3, "a local named values is not the built-in")
  })

  test.test("values() as a function still works outside loops", func(){
    local it = values({1, 2})
    assert(it() == 1 and it() == 2 and it() == stop)
    local ek = entries({x: 1})
    assert(ek() == {"x", 1} and ek() == stop)
  })
})
