// Grammar scoping: extension statements end with their unit; files are
// compiled under the root grammar; the project file supplies the ambient
// layer and the dialects.
local t = require("slang/test")
local str = require("slang/string")
local compiler = require("slang/compiler")
local os = require("slang/os")

local func message_of(result){
  return result[1].message
}

local shout_extension = """
  extension {
    local peg = require("slang/peg")
    local g = require("slang/compiler").grammar()
    g:statement("shout", peg.seq(g:keyword("shout"), g:rule("expr")):map(func(r){
      return {token: r[0], ast: +{stat: shouted = -{r[1]}}}
    }))
  }
"""

t.group("grammar scoping"){
  t.test("an extension statement's changes end with the unit"){
    global shouted = null
    compile(concat(shout_extension, "shout 1"), "unit one")()
    assert(shouted == 1, "the statement works in its unit")
    local r = pcall(compile, "shout 2", "unit two")
    assert(r[0] == "err", "and is unknown in the next unit")
    assert(str.index_of(message_of(r), "Failed to parse") >= 0, message_of(r))
  }
  t.test("compile from an unquote parses with the grammar of its unit"){
    global shouted = null
    compile(concat(shout_extension, """
      -{block:
        nested = compile("shout 3", "nested")
        return +{stat: print("")}
      }
    """), "outer")()
    nested()
    assert(shouted == 3, "the nested unit saw the extension of the outer one")
  }
  t.test("a required module is compiled with the root grammar"){
    local run = compile("""
      extension {
        local peg = require("slang/peg")
        local g = require("slang/compiler").grammar()
        // integers must be written #42 in this unit
        g:modify("int_literal", func(old){ return peg.seq(peg.string("#"), old):pick(1) })
      }
      __PACKAGES.preloaded["test/scope_module"] = null
      local m = require("test/scope_module")
      return m + #1
    """, "modified unit")
    assert(run() == 43, "the module's plain integers still parse")
  }
  t.test("an extension file's own extension statements are scoped to it"){
    global shouted = null
    global scope_inner = null
    local run = compile("""
      extension "test/scope_ext"
      shout 4
    """, "uses scope_ext")
    run()
    assert(
      shouted == 4,
      "what the extension registers at run time is available",
    )
    assert(
      scope_inner == 1,
      "the extension's own inner statement ran when it loaded",
    )
    local r = pcall(compile, """
      extension "test/scope_ext"
      inner 5
    """, "inner leaks?")
    assert(
      r[0] == "err",
      "the inner statement does not leak out of the extension file",
    )
  }
  t.test("an extension runs once per unit that loads it"){
    local source = """
      extension "test/scope_ext"
      extension "test/scope_ext"
      shout 6
    """
    global shouted = null
    compile(source, "twice")()
    assert(shouted == 6)
    local g = compiler.grammar()
    assert(len(g:extensions()) == 0, "the root grammar did not load it")
  }
  t.test("extension global is only allowed in the main file"){
    local r = pcall(compile, "extension global { }", "not main")
    assert(r[0] == "err", "compile should fail")
    assert(str.index_of(message_of(r), "main file") >= 0, message_of(r))
  }
  t.test("the root grammar can still be changed at run time"){
    local peg = require("slang/peg")
    local g = compiler.grammar()
    g:statement(
      "whisper", peg.seq(g:keyword("whisper"), g:rule("expr")):map(func(r){
        return {token: r[0], ast: +{stat: whispered = -{r[1]}}}
      })
    )
    global whispered = null
    compile("whisper 7", "after runtime change")()
    assert(whispered == 7, "a run-time change is global")
    compiler.reset()
    local r = pcall(compile, "whisper 8", "after reset")
    assert(r[0] == "err", "reset forgets it")
  }
}

t.group("project file"){
  t.test("ambient extensions, dialects and search paths"){
    local paths = __PACKAGES.search_paths
    compiler.load_project("test/project/slang.project")
    local p = compiler.project()
    assert(p.extensions == {"test/project_ext"}, "extensions")
    assert(
      __PACKAGES.dialect_suffixes == {".json", ".twice"},
      "dialect suffixes",
    )
    assert(
      __PACKAGES.search_paths[0] == "test/project",
      "the project directory comes first",
    )
    assert(
      __PACKAGES.search_paths[1] == "test/project/../..",
      "then its search paths",
    )
    for(let local name in values({"data", "module", "plain"})){
      __PACKAGES.preloaded[name] = null
    }
    local result = compiler.load_main("test/project/main.slang")()
    assert(
      result.doubled == 42,
      "the ambient extension applies without an extension statement",
    )
    assert(result.name == "data", "a .json module")
    assert(result.list == {1, "two", {three: 3}}, "json arrays and objects")
    assert(result.module == 10, "a .twice module is compiled with its dialect")
    assert(
      result.plain == "plain",
      "a plain module required from a dialect file",
    )
    local data = require("data")
    assert(data.escaped == "a\"b\nA", "json escapes")
    // the ambient layer is part of the base grammar: files stay cacheable
    assert(
      not compiler.grammar().extended,
      "root is not extended by the ambient layer",
    )
    assert(len(p.key) > 0, "the project key records the extension sources")
    compiler.reset()
    assert(compiler.project() == null, "reset forgets the project")
    assert(__PACKAGES.search_paths == paths, "and restores the search paths")
    local r = pcall(compile, "return twice 1", "after reset")
    assert(r[0] == "err" or r[1]() == null, "the ambient extension is gone")
    for(let local name in values({"data", "module", "plain"})){
      __PACKAGES.preloaded[name] = null
    }
  }
  t.test("a dialect's compile function must return a function"){
    local json = require("extensions/json")
    local r = pcall(json.decode, "{\"a\": }", "bad")
    assert(r[0] == "err", "malformed json fails")
    assert(
      str.index_of(message_of(r), "invalid JSON in bad") >= 0,
      message_of(r),
    )
    assert(
      json.compile("[1, 2.5, -3, 1e2]", "numbers")() == {1, 2.5, -3, 100.0},
      "numbers",
    )
  }
}
