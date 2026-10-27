// the pipe and holes example extensions (examples/functional)
local t = require("slang/test")
local str = require("slang/string")
local compiler = require("slang/compiler")

local func run(source, origin){
  return compile(concat("extension \"examples/functional/pipe\"\nextension \"examples/functional/holes\"\nextension \"examples/functional/def\"\n", source), origin or "functional")()
}

t.group("pipe operator"){
  t.test("the left value becomes the first argument"){
    local r = run("""
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
    """)
    assert(r == {3, 6, 30, 10, true, 8}, concat("results ", r))
  }
}

t.group("holes"){
  t.test("an argument with holes is a function of them"){
    local r = run("""
      local table = require("slang/table")
      local people = {{name: "a", age: 1}, {name: "b", age: 50}}
      return {
        table.map({1, 2, 3}, _ + 5),
        table.filter({1, 2, 3, 4, 5, 6, 7}, _ > 2 and _ < 6),
        table.fold({1, 2, 3}, 0, _ + _2),
        table.map(people, _.name),
        table.map({1, 2}, _),
        table.fold({1, 2}, 10, _2),
      }
    """)
    assert(r[0] == {6, 7, 8}, concat("map ", r[0]))
    assert(len(r[1]) == 3 and r[1][2] == 3 and r[1][4] == 5, concat("filter keeps keys: ", r[1]))
    assert(r[2] == 6, "fold with two holes")
    assert(r[3] == {"a", "b"}, "field access on a hole")
    assert(r[4] == {1, 2}, "a lone hole is the identity")
    assert(r[5] == 2, "_2 alone still declares _")
  }
  t.test("a hole belongs to the nearest argument"){
    local r = run("""
      local func twice(f, x){ return f(f(x)) }
      local func inc(x){ return x + 1 }
      local nested = twice(_ + 1, 5)
      local inner = pcall(func(){ return require("slang/table").map({1}, inc(_ * 10)) })
      return {nested, inner[0]}
    """)
    assert(r[0] == 7, "the function went to twice")
    assert(r[1] == "err", "inc received a function, not a number")
  }
  t.test("=> claims every hole in its body"){
    local r = run("""
      local table = require("slang/table")
      local func inc(x){ return x + 1 }
      local average = => (_ + _2) / 2
      local thunk = => 42
      local nested = => table.map(_, => _ * 2)
      return {
        table.map({1, 2, 3}, => inc(_ * 10)),
        average(3, 4),
        thunk(),
        nested({1, 2}),
        {1, 2, 3} |> table.map(_ * 2) |> table.fold(0, _ + _2),
        (=> _2)(1, 2),
      }
    """)
    assert(r[0] == {11, 21, 31}, concat("arrow ", r[0]))
    assert(r[1] == 3.5 and r[2] == 42)
    assert(r[3] == {2, 4}, "an arrow inside an arrow owns its holes")
    assert(r[4] == 12, "pipes and holes compose")
    assert(r[5] == 2)
  }
  t.test("outside arguments and arrows, _ is a variable"){
    local r = run("local _ = 3\nlocal _2 = 4\nreturn _ + _2")
    assert(r == 7)
  }
  t.test("holes are highlighted as parameters"){
    local h = compiler.highlight("extension \"examples/functional/holes\"\nlocal f = => _ + _2\n", "holes.slang")
    local cats = {}
    for(let local tk in values(h.tokens)){ append(cats, tk.category) }
    assert(str.index_of(str.join(cats, " "), "operator parameter operator parameter") >= 0, str.join(cats, " "))
    assert(len(h.diagnostics) == 0)
  }
}

t.group("def"){
  t.test("clauses are tried in order with patterns, guards and arity"){
    local r = run("""
      def fact(0){ return 1 }
      def fact(n) when(n > 0){ return n * fact(n - 1) }
      local Circle = {meta: {__type: "Circle"}, radius: 2}
      def area('Circle{radius: r}){ return 3 * r * r }
      def area({w, h}){ return w * h }
      def area(_){ return "other" }
      def greet("en", name){ return concat("hello ", name) }
      def greet("de", name){ return concat("hallo ", name) }
      def pair(a, b){ return {a, b} }
      def pair(a){ return {a} }
      return {fact(5), area(Circle), area({4, 5}), area("x"), greet("de", "welt"), pair(1), pair(1, 2)}
    """)
    assert(r[0] == 120 and r[1] == 12 and r[2] == 20 and r[3] == "other", concat("results ", r))
    assert(r[4] == "hallo welt" and r[5] == {1} and r[6] == {1, 2})
  }
  t.test("no matching clause is an error that names the function"){
    local r = run("""
      def only_small(n) when(n < 10){ return n }
      local r = pcall(only_small, 50)
      return r[1].message
    """)
    assert(str.index_of(r, "no clause of only_small matches (50)") >= 0, r)
  }
  t.test("rest parameters, local defs and falsy arguments"){
    local r = run("""
      local def total(){ return 0 }
      local def total(first, ...rest){ return first + total(...rest) }
      def describe(nil_or_false){ return type(nil_or_false) }
      def describe(a, b){ return "two" }
      return {total(1, 2, 3), total(), describe(false), describe(null), describe(1, 2), type(total)}
    """)
    assert(r == {6, 0, "bool", "null", "two", "def"}, concat("results ", r))
  }
}
