// the |> example extension
local t = require("slang/test")

t.group("pipe operator"){
  t.test("the left value becomes the first argument"){
    local run = compile("""
      extension "examples/pipe/pipe"
      local func add(a, b){ return a + b }
      local func twice(n){ return n * 2 }
      local o = {}
      func o.scale(self, n, k){ return n * k }
      return {
        1 |> add(2),
        1 |> add(2) |> twice(),
        3 |> o:scale(10),
        5 |> twice,
        2 + 3 |> twice() == 10,
        2 |> add(3 |> twice()),
      }
    """, "pipe")
    assert(run() == {3, 6, 30, 10, true, 8}, concat("results ", run()))
  }
}
