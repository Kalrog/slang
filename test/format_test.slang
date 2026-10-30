local t = require("slang/test")
local format = require("slang/format")
local os = require("slang/os")

local func formats(input, expected){
  local out = format.source(input, "format_test")
  assert(out == expected, concat("formatted:\n", out, "expected:\n", expected))
  // formatting is idempotent
  assert(
    format.source(out, "format_test") == out,
    concat("not idempotent:\n", out)
  )
}

t.group("slang fmt"){
  t.test("spacing and one statement per line, ; dropped"){
    formats("local   x=1;local y = x+2", "local x = 1\nlocal y = x + 2\n")
  }
  t.test(
    "a body of one statement keeps its line; next to else and catch it breaks"
  ){
    formats(
      "if (x) { f() } else if (y) { g() } else { h() }",
      "if(x){\n  f()\n} else if(y){\n  g()\n} else {\n  h()\n}\n"
    )
    formats(
      "for(local i = 0; i < 3; i = i + 1){ f(i) }\nfor(let local v in values(t)){ g(v) }",
      "for(local i = 0; i < 3; i = i + 1){ f(i) }\nfor(let local v in values(t)){ g(v) }\n"
    )
    formats(
      "try { f() } catch(local e) { g(e) }",
      "try {\n  f()\n} catch(local e) {\n  g(e)\n}\n"
    )
  }
  t.test("the source decides between one line and a line per element"){
    // written a line per element: kept, unless it all fits on one line
    formats("local t = {\n  a: 1,\n  b: 2,\n}", "local t = {a: 1, b: 2}\n")
    formats(
      "local ok = alpha_condition_value and\n  beta_condition_value and\n  gamma_condition_value and\n  delta_condition_value",
      "local ok = alpha_condition_value and\n  beta_condition_value and\n  gamma_condition_value and\n  delta_condition_value\n"
    )
    formats(
      "local ok = alpha_condition_value and beta_condition_value and gamma_condition_value and delta_condition_value",
      "local ok = alpha_condition_value and beta_condition_value and\n  gamma_condition_value and delta_condition_value\n"
    )
    // a body written over several lines keeps them
    formats(
      "local f = func(x){\n  return x\n}",
      "local f = func(x){\n  return x\n}\n"
    )
  }
  t.test("a function of one statement stays on one line"){
    formats(
      "local double = func(x){ return x * 2 }\nfunc named(x){ return x }",
      "local double = func(x){ return x * 2 }\nfunc named(x){ return x }\n"
    )
  }
  t.test("tables break one field per line, with a trailing comma"){
    formats(
      "local t = {alpha: \"aaaaaaaaaaaaaaaaaaaa\", beta: \"bbbbbbbbbbbbbbbbbbbbbbbb\", gamma: \"cccccccccccccc\"}",
      "local t = {\n  alpha: \"aaaaaaaaaaaaaaaaaaaa\",\n  beta: \"bbbbbbbbbbbbbbbbbbbbbbbb\",\n  gamma: \"cccccccccccccc\",\n}\n"
    )
    formats("local short = {a: 1, b: 2,}", "local short = {a: 1, b: 2}\n")
  }
  t.test("a last argument that is a function or a table hugs the call"){
    formats(
      "describe(\"something\", func(){\n  it(\"works\")\n  it(\"still works\")\n})",
      "describe(\"something\", func(){\n  it(\"works\")\n  it(\"still works\")\n})\n"
    )
    formats(
      "append(items, {name: \"a long name here\", owner: \"someone\", protected: false, history: {}})",
      "append(items, {\n  name: \"a long name here\", owner: \"someone\", protected: false, history: {},\n})\n"
    )
  }
  t.test("long calls and operators break"){
    // mostly short arguments are packed, a long one gets a line of its own
    formats(
      "print(f(1, 2), f(3, 4), \"a long string that makes this call too long for one line\", g(5))",
      "print(\n  f(1, 2), f(3, 4), \"a long string that makes this call too long for one line\",\n  g(5)\n)\n"
    )
    formats(
      "print(\"tables: acc=\", acc.x, \",\", acc.y, \" items=\", len(list), \" sum=\", sum, \" in \", (t1 - t0) * 1000, \" ms\")",
      "print(\n  \"tables: acc=\", acc.x, \",\", acc.y, \" items=\", len(list), \" sum=\", sum, \" in \",\n  (t1 - t0) * 1000, \" ms\"\n)\n"
    )
    // medium arguments get a line each
    formats(
      "check(first_argument_value_x, second_argument_value_x, third_argument_value_x, fourth_argument_value)",
      "check(\n  first_argument_value_x,\n  second_argument_value_x,\n  third_argument_value_x,\n  fourth_argument_value\n)\n"
    )
    // a small call as the last argument moves to the next line whole
    formats(
      "local x = builder:group():left(peg.choice(tok(\"<=\"), tok(\">=\"), tok(\"!=\"), tok(\"==\"), tok(\">\"), tok(\"<\")), binop)",
      "local x = builder:group():left(\n  peg.choice(tok(\"<=\"), tok(\">=\"), tok(\"!=\"), tok(\"==\"), tok(\">\"), tok(\"<\")),\n  binop\n)\n"
    )
    // a table of plain elements is packed, named fields get a line each
    formats(
      "local primes = {2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73}",
      "local primes = {\n  2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73,\n}\n"
    )
    formats(
      "local ok = first_condition_is_long and second_condition_is_long or third_condition_is_long",
      "local ok = first_condition_is_long and second_condition_is_long or\n  third_condition_is_long\n"
    )
    formats(
      "local r = the_receiver_object:first_method(argument):second_method(argument):third_method(arg)",
      "local r = the_receiver_object\n  :first_method(argument)\n  :second_method(argument)\n  :third_method(arg)\n"
    )
  }
  t.test("comments and blank lines are kept"){
    formats(
      "// head\n\n\nlocal a = 1   // trailing\n\n\n\n// before b\nlocal b = 2\nfunc f(){\n\n  g()\n  // last\n\n}",
      "// head\n\nlocal a = 1 // trailing\n\n// before b\nlocal b = 2\nfunc f(){\n  g()\n  // last\n}\n"
    )
  }
  t.test("literals keep their spelling"){
    formats(
      "local n = 0xff + 1_000 + 2.5e3\nlocal s = \"\"\"two  \n  lines\"\"\"",
      "local n = 0xff + 1_000 + 2.5e3\nlocal s = \"\"\"two  \n  lines\"\"\"\n"
    )
    formats(
      "local w = - 1\nlocal v = -x + not y",
      "local w = - 1\nlocal v = -x + not y\n"
    )
  }
  t.test("an extension that marks its parsers is formatted"){
    formats(
      "extension \"extensions/switch\"\nlocal v = 1\nswitch (v)  {\n  case 1 :\n    f()    // one\n      g()\n  case 2:   h()\n}",
      "extension \"extensions/switch\"\nlocal v = 1\nswitch(v){\n  case 1:\n    f() // one\n    g()\n  case 2:\n    h()\n}\n"
    )
  }
  t.test(
    "an extension without marks keeps its layout, core code in it is formatted"
  ){
    formats(
      "extension \"extensions/lambda_shorthand\"\nlocal f = |a,  b|   a  +  b",
      "extension \"extensions/lambda_shorthand\"\nlocal f = |a,  b|   a + b\n"
    )
  }
  t.test("html templates: tags, attributes and code laid out"){
    local h = "extension \"extensions/html\"\n"
    formats(
      concat(h, "local x = <p   class=\"a\" >Hello <b>{name   +   1}</b></p >"),
      concat(h, "local x = <p class=\"a\">Hello <b>{name + 1}</b></p>\n")
    )
    // the structure as written stays; code in braces is formatted
    formats(
      concat(h, "func f(x){\nreturn <div>\n    <b>{x   +  1}</b>\n  </div>\n}"),
      concat(h, "func f(x){\n  return <div>\n    <b>{x + 1}</b>\n  </div>\n}\n")
    )
    // a tag too long: one attribute per line, the > on its own line
    formats(
      concat(
        h,
        "local y = <input name=\"text\" placeholder=\"What needs doing today?\" autocomplete=\"off\" required/>"
      ),
      concat(
        h,
        "local y = <input\n  name=\"text\"\n  placeholder=\"What needs doing today?\"\n  autocomplete=\"off\"\n  required\n/>\n"
      )
    )
  }
  t.test("html templates: text flows, its meaning stays"){
    local h = "extension \"extensions/html\"\n"
    // words wrap at 80 columns; a line break in text is a space
    formats(
      concat(
        h,
        "local p = <p>\n  one two three four five six seven eight nine ten eleven twelve thirteen\n  fourteen\n</p>"
      ),
      concat(
        h,
        "local p = <p>\n  one two three four five six seven eight nine ten eleven twelve thirteen\n  fourteen\n</p>\n"
      )
    )
    formats(
      concat(
        h,
        "local p = <p>alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi</p>"
      ),
      concat(
        h,
        "local p = <p>\n  alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi\n</p>\n"
      )
    )
    // spaces next to tags and between elements mean something: kept
    formats(
      concat(h, "local q = <b> x  y </b>\nlocal r = <i><a/> <a/></i>"),
      concat(h, "local q = <b> x  y </b>\nlocal r = <i><a/> <a/></i>\n")
    )
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
