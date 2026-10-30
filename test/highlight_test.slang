// token recording for highlighting: compiler.highlight and slang/json
local t = require("slang/test")
local str = require("slang/string")
local compiler = require("slang/compiler")
local json = require("slang/json")

// the categories of the tokens of source, as "category:text" in order
local func spell(source, path){
  local r = compiler.highlight(source, path or "snippet.slang")
  local out = {}
  for(let local tk in values(r.tokens)){
    append(out, concat(
      tk.category, ":", str.substring(source, tk.start, tk.stop)
    ))
  }
  return {spelled: out, diagnostics: r.diagnostics}
}

t.group("highlighting"){
  t.test("core tokens carry their categories"){
    local r = spell("local x = 1 + 2.5 // sum\nif(x > 3){ print(\"big\") }")
    assert(
      r.spelled == {
        "keyword:local", "identifier:x", "punctuation:=", "number:1",
        "operator:+", "number:2.5", "comment:// sum", "keyword:if",
        "punctuation:(", "identifier:x", "operator:>", "number:3",
        "punctuation:)", "punctuation:{", "identifier:print", "punctuation:(",
        "string:\"big\"", "punctuation:)", "punctuation:}",
      },
      str.join(r.spelled, " ")
    )
    assert(len(r.diagnostics) == 0)
  }
  t.test("tokens of alternatives that lost are dropped"){
    // `a.b = 1` is tried as an expression statement before the assignment
    local r = spell("a.b = 1\nf(a)[2] = 3")
    assert(
      r.spelled == {
        "identifier:a", "punctuation:.", "identifier:b", "punctuation:=",
        "number:1", "identifier:f", "punctuation:(", "identifier:a",
        "punctuation:)", "punctuation:[", "number:2", "punctuation:]",
        "punctuation:=", "number:3",
      },
      str.join(r.spelled, " ")
    )
  }
  t.test("an extension's keywords and operators are highlighted"){
    local r = spell("""extension "extensions/custom_operators"
infix _<>_ (a, b){ return a + b }
local v = 1 <> 2
""")
    local text = str.join(r.spelled, " ")
    assert(
      str.index_of(
        text,
        "keyword:extension string:\"extensions/custom_operators\""
      ) >= 0,
      text
    )
    assert(str.index_of(text, "keyword:infix") >= 0, text)
    assert(str.index_of(text, "number:1 operator:<> number:2") >= 0, text)
    assert(len(r.diagnostics) == 0)
  }
  t.test("extensions tag their syntax with LSP token types and modifiers"){
    local r = spell("""extension "extensions/enum"
enum Color { Red, Green }
local c = Color.Red
""")
    local text = str.join(r.spelled, " ")
    assert(
      str.index_of(
        text,
        "keyword:enum enum.declaration:Color punctuation:{ enumMember.declaration:Red punctuation:, enumMember.declaration:Green punctuation:}"
      ) >= 0,
      text
    )
    assert(len(r.diagnostics) == 0)
    local run = compile(
      "extension \"extensions/enum\"\nenum Color { Red, Green }\nreturn Color.Green",
      "enum"
    )
    assert(run() == "Green", "the enum works")
    local d = spell("""extension "extensions/dollar"
macro hello(args){ return +{1} }
local v = $hello()
""")
    local dt = str.join(d.spelled, " ")
    assert(
      str.index_of(dt, "keyword:macro function.declaration:hello") >= 0,
      dt
    )
    assert(str.index_of(dt, "macro:$ identifier:hello") >= 0, dt)
    local o = spell("""extension "extensions/custom_operators"
infix _<>_ (a, b){ return a + b }
local v = 1 <> 2
""")
    local ot = str.join(o.spelled, " ")
    assert(str.index_of(ot, "number:1 operator:<> number:2") >= 0, ot)
  }
  t.test("a parse error gives the tokens before it and a diagnostic"){
    local r = spell("local x = 1\nlocal y = = 2\nlocal z = 3")
    assert(
      r.spelled[0] == "keyword:local" and r.spelled[4] == "keyword:local",
      str.join(r.spelled, " ")
    )
    assert(len(r.diagnostics) >= 1)
    local d = r.diagnostics[0]
    assert(
      d.line == 2 and d.column >= 10,
      concat("at ", d.line, ":", d.column, " ", d.message)
    )
    assert(d.severity == "error")
  }
  t.test(
    "an error raised by compile-time code is a diagnostic at its statement"
  ){
    local r = spell(
      "local a = 1\n-{block: error(\"compile-time boom\")}\nlocal b = 2"
    )
    assert(len(r.diagnostics) == 1)
    assert(r.diagnostics[0].line == 2, concat("line ", r.diagnostics[0].line))
    assert(
      str.index_of(r.diagnostics[0].message, "compile-time boom") >= 0,
      r.diagnostics[0].message
    )
  }
  t.test("a dialect file is highlighted with its grammar"){
    compiler.load_project("test/project/slang.project")
    local r = spell("local v = twice 5", "test/project/module.twice")
    assert(
      str.index_of(str.join(r.spelled, " "), "keyword:twice number:5") >= 0,
      str.join(r.spelled, " ")
    )
    local j = compiler.highlight("{\"a\": 1}", "test/project/data.json")
    assert(len(j.tokens) == 0, "a compile dialect has no tokens")
    compiler.reset()
    for(let local name in values({"data", "module", "plain"})){
      __PACKAGES.preloaded[name] = null
    }
  }
  t.test("a project file is a table literal"){
    local r = spell(
      "// the project\n{\n  extensions: {\"a\"},\n}\n",
      "some/dir/slang.project"
    )
    assert(len(r.diagnostics) == 0, concat("diagnostics: ", len(r.diagnostics)))
    assert(
      r.spelled[0] == "comment:// the project" and
        r.spelled[1] == "punctuation:{",
      str.join(r.spelled, " ")
    )
    local raw = compiler.highlight(
      "// the project\n{\n  extensions: {\"a\"},\n}\n",
      "some/dir/slang.project"
    )
    assert(
      raw.tokens[0].line == 1 and raw.tokens[0].column == 1 and
        raw.tokens[1].line == 2,
      "positions are those of the file"
    )
    local bad = compiler.highlight("{ extensions: }", "x/slang.project")
    assert(
      len(bad.diagnostics) >= 1 and bad.diagnostics[0].line == 1 and
        bad.diagnostics[0].column <= 15,
      "a diagnostic in the file's coordinates"
    )
  }
  t.test("highlight_json"){
    local text = compiler.highlight_json("test/scope_module.slang")
    local v = json.decode(text, "highlight")
    assert(
      v.tokens[0].category == "comment" and v.tokens[0].line == 1,
      concat(text)
    )
    assert(len(v.diagnostics) == 0)
  }
}

t.group("utf16 positions"){
  t.test("utf16_len counts code units"){
    assert(str.utf16_len("abc") == 3)
    assert(str.utf16_len("héllo") == 5)
    assert(str.utf16_len("日本") == 2)
    assert(str.utf16_len("a😀b") == 4, "an astral code point is two units")
    assert(str.utf16_len("") == 0)
  }
}

t.group("json"){
  t.test("encode and decode round trip"){
    local v = {
      name: "x\"y\n",
      list: {1, 2.5, true, false},
      nested: {deep: {}},
      empty: json.array({}),
    }
    local text = json.encode(v)
    assert(str.index_of(text, "\"name\":\"x\\\"y\\n\"") >= 0, text)
    assert(str.index_of(text, "\"empty\":[]") >= 0, text)
    assert(str.index_of(text, "\"nested\":{\"deep\":{}}") >= 0, text)
    local back = json.decode(text)
    assert(back.name == "x\"y\n" and back.list == {
          1, 2.5, true, false,
        } and back.empty == {})
    local pretty = json.encode({a: {1, 2}}, {indent: "  "})
    assert(pretty == "{\n  \"a\": [\n    1,\n    2\n  ]\n}", pretty)
    local r = pcall(json.encode, {f: func(){}})
    assert(r[0] == "err")
  }
}
