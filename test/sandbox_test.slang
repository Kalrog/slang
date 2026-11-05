// compile(code, origin, env): code whose globals are a table of its own
local t = require("slang/test")

t.group("compile with an env"){
  t.test("globals are the env's, assignments stay in it"){
    assert(compile("return x * 2", "calc", {x: 21})() == 42)
    local env = {}
    compile("tally = 1\ntally = tally + 1", "counter", env)()
    assert(env.tally == 2)
    assert(tally == null, "the program's globals are untouched")
  }
  t.test("what the env does not hold is not there"){
    local f = compile("return require", "escape", {})
    assert(f() == null)
    t.raises(compile("print(1)", "print", {}))
  }
  t.test("functions made inside keep the env, wherever they are called"){
    local env = {base: 10}
    local add = compile(
      "return func(x){ total = base + x\n return total }", "f", env
    )()
    assert(add(5) == 15 and env.total == 15)
    env.base = 100
    assert(add(1) == 101)
  }
  t.test("an env with a meta reads through to other values"){
    local shared = {limit: 3}
    local env = {@meta: {__index: shared}}
    assert(compile("return limit + 1", "read", env)() == 4)
    compile("limit = 9", "write", env)()
    assert(env.limit == 9 and shared.limit == 3)
  }
  t.test("no code runs while a sandboxed source compiles"){
    local e = t.raises(func(){
      compile("return -{expr: +{expr: 1}}", "unquote", {})
    })
    assert(
      e.message ==
        "compile-time code (an unquote) is not allowed in a sandboxed compile",
      e.message,
    )
    e = t.raises(func(){
      compile("extension \"x\"{ }\nreturn 1", "extension", {})
    })
    assert(
      e.message ==
        "extension statements are not allowed in a sandboxed compile",
    )
    // the same source compiles without an env
    assert(compile("return -{expr: +{expr: 1}}", "unquote")() == 1)
  }
  t.test("env must be a table"){
    local e = t.raises(func(){ compile("return 1", "x", "globals") })
    assert(e.message == "compile: env must be a table, got string", e.message)
  }
}
