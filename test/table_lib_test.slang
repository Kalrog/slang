local t = require("slang/test")
local table = require("slang/table")

t.group("table"){
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