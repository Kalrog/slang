local t = require("slang/test")
local str = require("slang/string")

local func message_of(result){
  return result[1].message
}

t.group("extension statements"){
  t.test("an inline extension changes the grammar for the statements after it"){
    local run = compile("""
      extension {
        local p = require("slang/parser")
        p.add_primitive_expression("fortytwo", p.keyword("fortytwo"):map(func(token){
          return {token: token, ast: +{42}}
        }))
      }
      return fortytwo
    """, "inline extension")
    assert(run() == 42, "fortytwo should be 42")
  }
  t.test("an extension loaded from a file"){
    local run = compile("""
      extension "extensions/lambda_shorthand"
      local add = |a, b| a + b
      return add(20, 22)
    """, "file extension")
    assert(run() == 42, "lambda shorthand should work after the extension statement")
  }
  t.test("ordinary unquotes may not change the grammar"){
    local r = pcall(compile, """
      -{block:
        local p = require("slang/parser")
        p.add_statement("nope", p.keyword("nope"):map(func(token){
          return {token: token, ast: +{stat: print("")}}
        }))
      }
    """, "unquote mutation")
    assert(r[0] == "err", "compile should fail")
    assert(str.index_of(message_of(r), "extension statement") >= 0, concat("message: ", message_of(r)))
  }
  t.test("extension statements are only allowed at the top level"){
    local r = pcall(compile, """
      func f(){
        extension { }
      }
    """, "nested extension")
    assert(r[0] == "err", "compile should fail")
  }
  t.test("extension statements cannot run while a statement is being parsed"){
    local r = pcall(compile, """
      -{block: compile("extension { }", "nested unit")}
    """, "extension from unquote")
    assert(r[0] == "err", "compile should fail")
    assert(str.index_of(message_of(r), "while a statement is being parsed") >= 0, concat("message: ", message_of(r)))
  }
  t.test("an unquote runs once even when the parser backtracks across it"){
    unquote_runs = 0
    stored = null
    local run = compile("""
      extension {
        local p = require("slang/parser")
        // a statement that parses a whole expression and then needs the word `afterwards`,
        // so the plain call statement below is parsed twice
        p.add_statement("afterwards", p.seq(p.expr(), p.keyword("afterwards")):map(func(r){
          return {token: r[1], ast: +{stat: print("")}}
        }))
      }
      local func store(v){
        stored = v
      }
      store(-{block: unquote_runs = unquote_runs + 1 return +{7}} + 1)
    """, "unquote memo")
    assert(unquote_runs == 1, concat("the unquote block ran ", unquote_runs, " times"))
    run()
    assert(stored == 8, "the spliced value should be used")
  }
  t.test("compile-time code may still compute and splice code"){
    computed = null
    local run = compile("""
      -{block:
        local n = 0
        for(local i = 1; i <= 4; i = i + 1){ n = n + i }
        return +{stat: computed = -{{type: "Int", value: n}}}
      }
    """, "pure unquote")
    run()
    assert(computed == 10, "the spliced statement should run")
    local f = compile("return -{block: return {type: \"Int\", value: 10}} * 2", "pure unquote expr")
    assert(f() == 20, "spliced value should be usable")
  }
  t.test("keywords stay usable as field names"){
    local run = compile("""
      extension {
        local p = require("slang/parser")
        p.add_statement("shout", p.seq(p.keyword("shout"), p.expr()):map(func(r){
          return {token: r[0], ast: +{stat: print(-{r[1]})}}
        }))
      }
      local t = {shout: 1}
      func t.loud(self, n){ return self.shout + n }
      if(let {shout: local v} = t){ t.shout = v + 1 }
      local u = {}
      func u.shout(self){ return 5 }
      return t:loud(10) + t.shout + u:shout()
    """, "keyword fields")
    assert(run() == 19, "shout is a keyword but still a field, a method and a pattern key")
    local r = pcall(compile, "local shout = 1", "keyword identifier")
    assert(r[0] == "err", "but not a variable name")
  }
  t.test("extensions can define their own extension statements"){
    local run = compile("""
      extension {
        local p = require("slang/parser")
        // `alias NEW OLD` makes NEW a primitive expression standing for the global OLD
        p.add_extension_statement("alias", p.seq(p.keyword("alias"), p.identifier(), p.identifier()), func(r){
          local new_name = r[1].value
          local old = r[2]
          p.add_primitive_expression(new_name, p.keyword(new_name):map(func(token){
            return {token: token, ast: old}
          }))
          return null
        })
      }
      alias say print
      say("")
      return say == print
    """, "user extension statement")
    assert(run() == true, "say should stand for print")
    local r = pcall(compile, """
      func f(){
        alias a b
      }
    """, "nested user extension statement")
    assert(r[0] == "err", "extension statements defined by extensions are top-level only")
  }
}
