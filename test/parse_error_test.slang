// Parse and compile errors: what they say and where (slang/parse_error)
local t = require("slang/test")
local str = require("slang/string")

// the error compiling source raises
local func error_of(source){
  local r = pcall(compile, source, "src")
  assert(r[0] == "err", concat("should not compile: ", source))
  return r[1]
}

// asserts the error's message contains text and its location is line:column
local func fails(source, text, line, column){
  local e = error_of(source)
  assert(str.index_of(e.message, text) >= 0, e.message)
  assert(
    e.location.line == line and e.location.column == column,
    concat(e.message, " at ", e.location.line, ":", e.location.column),
  )
  return e
}

t.group("parse errors"){
  t.test("are syntax errors with a location and the line, not a traceback"){
    local e = fails("local x = 1\nlocal y = x +* 2\n", "expected an expression, found `*`", 2, 14)
    assert(e.kind == "syntax" and e.location.origin == "src")
    assert(str.index_of(e.stack, "local y = x +* 2") >= 0, e.stack)
    assert(str.index_of(e.stack, "slang/grammar") < 0, e.stack)
  }
  t.test("name everything expected"){
    fails("func f(a b){\n  return a\n}\n", "expected `,` or `)`, found `b`", 1, 10)
    fails("local t = {a: 1 b: 2}\n", "expected `,` or `}`, found `b`", 1, 17)
  }
  t.test("a bracket left open on its line is reported at the line's end"){
    fails("local x = foo(1, 2\nlocal y = 3\n", "expected `,` or `)` after number `2`", 1, 19)
    local e = fails(
      "local t = {\n  a: 1,\n  b: 2\n  c: 3,\n}\n",
      "expected `,` or `}` after number `2`", 3, 7,
    )
    assert(str.index_of(e.stack, "note: src:1:11") >= 0, e.stack)
  }
  t.test("a missing } is looked for by indentation"){
    fails(
      "func f(a){\n  if(a > 1){\n    print(a)\n  \n}\n\nfunc g(){\n  return 2\n}\n",
      "a `}` is probably missing before this line", 5, 1,
    )
    fails(
      "func f(){\n  print(2)\n\nfunc g(){\n  return 2\n}\n",
      "a `}` is probably missing before this line", 4, 1,
    )
    fails("print(1))\n", "this `)` has no `(` to close", 1, 9)
  }
  t.test("an unclosed string is reported where it starts"){
    fails("print(\"hello)\nprint(2)\n", "this string is not closed", 1, 7)
    fails("local s = \"\"\"abc\nprint(s)\n", "this \"\"\" string is not closed", 1, 11)
  }
  t.test("other languages' syntax gets a hint"){
    local hint = func(source, text){
      local e = error_of(source)
      assert(str.index_of(e.stack, text) >= 0, e.stack)
    }
    hint("local a = 1\nif(a == 1 && a == 1){\n}\n", "`and`")
    hint("for(local i = 0; i < 3; i++){\n}\n", "no ++")
    hint("local x = 1\nx += 2\n", "no +=")
    hint("local s = \"a\" .. \"b\"\n", "concat")
    hint("local x = [1, 2]\n", "`{1, 2}`")
    hint("function f() end\n", "func name")
    hint("if x > 1 {\n}\n", "parentheses")
  }
  t.test("the language server gets the same message and the notes"){
    local compiler = require("slang/compiler")
    local g = compiler.grammar()
    pcall(g.parse_source, g, "local x = foo(\n  1,\n  2,\n\nlocal y = 3\n", "src", {recover: true})
    local f = g.state.failures[0]
    assert(f.far_message == "expected an expression or `)` after `,`", f.far_message)
    assert(len(f.notes) == 1, string(f.notes))
  }
  t.test("recovering skips the block whose header failed"){
    local compiler = require("slang/compiler")
    local g = compiler.grammar()
    local source = "local a = 1\nif(a == 1 && a == 2){\n  print(a)\n}\nlocal b = 2\n"
    pcall(g.parse_source, g, source, "src", {recover: true})
    local fs = g.state.failures
    assert(len(fs) == 1, string(fs))
  }
}

t.group("compile errors"){
  t.test("are located at the program's line"){
    local e = fails("func f(){\n  local x = 1\n  local x = 2\n}\n", "Variable already declared: x", 3, 9)
    assert(e.kind == "compile" and str.index_of(e.stack, "local x = 2") >= 0, e.stack)
    fails("local x = 1\nbreak\n", "break outside of a loop", 2, 1)
  }
  t.test("a while loop is reported as one"){
    fails("while(true){\n  break\n}\n", "slang has no while loop", 1, 1)
  }
}
