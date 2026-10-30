local t = require("slang/test")
local format = require("slang/format")
local os = require("slang/os")

local func formats(input, expected){
  local out = format.source(input, "format_test")
  assert(out == expected, concat("formatted:\n", out, "expected:\n", expected))
  // formatting is idempotent
  assert(format.source(out, "format_test") == out, concat("not idempotent:\n", out))
}

t.group("slang fmt"){
  t.test("spacing and one statement per line, ; dropped"){
    formats("local   x=1;local y = x+2", "local x = 1\nlocal y = x + 2\n")
  }
  t.test("bodies of statements on lines of their own"){
    formats("if (x) { f() } else if (y) { g() } else { h() }",
      "if(x){\n  f()\n} else if(y){\n  g()\n} else {\n  h()\n}\n")
    formats("for(local i = 0; i < 3; i = i + 1){ f(i) }\nfor(let local v in values(t)){ g(v) }",
      "for(local i = 0; i < 3; i = i + 1){\n  f(i)\n}\nfor(let local v in values(t)){\n  g(v)\n}\n")
    formats("try { f() } catch(local e) { g(e) }", "try {\n  f()\n} catch(local e) {\n  g(e)\n}\n")
  }
  t.test("a function expression of one statement stays on one line"){
    formats("local double = func(x){ return x * 2 }\nfunc named(x){ return x }",
      "local double = func(x){ return x * 2 }\nfunc named(x){\n  return x\n}\n")
  }
  t.test("tables break one field per line, with a trailing comma"){
    formats("local t = {alpha: \"aaaaaaaaaaaaaaaaaaaa\", beta: \"bbbbbbbbbbbbbbbbbbbbbbbb\", gamma: \"cccccccccccccc\"}",
      "local t = {\n  alpha: \"aaaaaaaaaaaaaaaaaaaa\",\n  beta: \"bbbbbbbbbbbbbbbbbbbbbbbb\",\n  gamma: \"cccccccccccccc\",\n}\n")
    formats("local short = {a: 1, b: 2,}", "local short = {a: 1, b: 2}\n")
  }
  t.test("a last argument that is a function or a table hugs the call"){
    formats("describe(\"something\", func(){\n  it(\"works\")\n  it(\"still works\")\n})",
      "describe(\"something\", func(){\n  it(\"works\")\n  it(\"still works\")\n})\n")
    formats("append(items, {name: \"a long name here\", owner: \"someone\", protected: false, history: {}})",
      "append(items, {\n  name: \"a long name here\",\n  owner: \"someone\",\n  protected: false,\n  history: {},\n})\n")
  }
  t.test("long calls and operators break"){
    formats("print(f(1, 2), f(3, 4), \"a long string that makes this call too long for one line\", g(5))",
      "print(\n  f(1, 2),\n  f(3, 4),\n  \"a long string that makes this call too long for one line\",\n  g(5)\n)\n")
    formats("local ok = first_condition_is_long and second_condition_is_long or third_condition_is_long",
      "local ok = first_condition_is_long and second_condition_is_long or\n  third_condition_is_long\n")
    formats("local r = the_receiver_object:first_method(argument):second_method(argument):third_method(arg)",
      "local r = the_receiver_object\n  :first_method(argument)\n  :second_method(argument)\n  :third_method(arg)\n")
  }
  t.test("comments and blank lines are kept"){
    formats("// head\n\n\nlocal a = 1   // trailing\n\n\n\n// before b\nlocal b = 2\nfunc f(){\n\n  g()\n  // last\n\n}",
      "// head\n\nlocal a = 1 // trailing\n\n// before b\nlocal b = 2\nfunc f(){\n  g()\n  // last\n}\n")
  }
  t.test("literals keep their spelling"){
    formats("local n = 0xff + 1_000 + 2.5e3\nlocal s = \"\"\"two  \n  lines\"\"\"",
      "local n = 0xff + 1_000 + 2.5e3\nlocal s = \"\"\"two  \n  lines\"\"\"\n")
    formats("local w = - 1\nlocal v = -x + not y", "local w = - 1\nlocal v = -x + not y\n")
  }
  t.test("an extension that marks its parsers is formatted"){
    formats("extension \"extensions/switch\"\nlocal v = 1\nswitch (v)  {\n  case 1 :\n    f()    // one\n      g()\n  case 2:   h()\n}",
      "extension \"extensions/switch\"\nlocal v = 1\nswitch(v){\n  case 1:\n    f() // one\n    g()\n  case 2:\n    h()\n}\n")
  }
  t.test("an extension without marks keeps its layout, core code in it is formatted"){
    // the whitespace between html tags is text: it stays as it is
    formats("extension \"extensions/html\"\nfunc f(x){\nreturn <div>\n    <b>{x   +  1}</b>\n  </div>\n}",
      "extension \"extensions/html\"\nfunc f(x){\n  return <div>\n    <b>{x + 1}</b>\n  </div>\n}\n")
  }
  t.test("a file that does not parse is an error"){
    local r = pcall(format.source, "local = ", "format_test")
    assert(r[0] == "err", "an error")
  }
  t.test("a library file formats, and stays as it is formatted again"){
    local path = "extensions/switch.slang"
    local once = format.source(os.read_file(path), path)
    assert(format.source(once, path) == once, concat("idempotent: ", path))
  }
}
