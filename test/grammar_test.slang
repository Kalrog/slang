// The rule registry: named rules, modification, provenance, derivation.
local test = require("slang/test")
local grammar = require("slang/grammar")
local peg = require("slang/peg")
local ast = require("slang/ast")
local p = require("slang/parser")

// rule references follow the grammar that was activated last (the phrase
// loop activates the grammar of each unit; here we do it by hand)
local func parse(g, name, source){
  g:activate()
  local r = peg.run(g:rule(name):end(), source)
  if(not r.ok){
    return null
  }
  return r.value
}

test.group("grammar registry", func(){
  test.test("rules have provenance"){
    local g = grammar.new({})
    local found = null
    for(let local r in values(g:rules())){
      if(r.name == "if_statement"){ found = r }
    }
    assert(found != null)
    assert(found.owner == "core")
    assert(len(found.history) == 0)
    assert(not found.protected)
  }

  test.test("rule references parse the active grammar"){
    local g = grammar.new({})
    local e = parse(g, "expr", "1 + 2 * 3")
    assert(e.type == "BinOp" and e.op == "+")
    assert(e.right.op == "*")
  }

  test.test("modify replaces a rule everywhere it is referenced"){
    local g = grammar.new({})
    // integers written as #42 (the old parser is still used for the digits)
    g:modify("int_literal", func(old){
      return peg.seq(peg.string("#"), old):pick(1)
    })
    local e = parse(g, "expr", "#4 + #2")
    assert(e.type == "BinOp")
    assert(e.left.value == 4 and e.right.value == 2)
    assert(parse(g, "expr", "4") == null)
    local found = null
    for(let local r in values(g:rules())){
      if(r.name == "int_literal"){ found = r }
    }
    assert(found.history == {"runtime"})
  }

  test.test("rules built at seal time can be wrapped"){
    local g = grammar.new({})
    g:modify("expr", func(old){
      return peg.seq(peg.string("!"):optional(), old):map(func(v){
        if(v[0] == null){ return v[1] }
        return ast.node("UnOp", {op: "not", operand: v[1]}, v[1].token)
      })
    })
    local e = parse(g, "expr", "!x")
    assert(e.type == "UnOp" and e.op == "not")
    assert(parse(g, "expr", "x").type == "Identifier")
  }

  test.test("protected rules refuse modification"){
    local g = grammar.new({})
    local r = pcall(g.modify, g, "quote", func(old){ return old })
    assert(r[0] == "err")
    assert(r[1].message == "grammar rule quote is protected and cannot be modified")
  }

  test.test("define adds a rule that other rules can reference"){
    local g = grammar.new({})
    g:define("shout", peg.seq(rule_name_free(g, "identifier"), peg.string("!")):pick(0):map(func(id){
      return ast.node("String", {value: concat(id.value, "!")}, id.token)
    }))
    g:modify("expr", func(old){ return peg.choice(g:rule("shout"), old) })
    local e = parse(g, "expr", "hey!")
    assert(e.type == "String" and e.value == "hey!")
  }

  test.test("derived grammars change independently"){
    local g = grammar.new({})
    local child = g:derive()
    child:modify("int_literal", func(old){
      return peg.seq(peg.string("#"), old):pick(1)
    })
    assert(parse(child, "expr", "#7").value == 7)
    // the parent is unaffected, even after the child was active
    assert(parse(g, "expr", "7").value == 7)
    assert(parse(g, "expr", "#7") == null)
    // and the child still works afterwards
    assert(parse(child, "expr", "#7").value == 7)
    local found = null
    for(let local r in values(g:rules())){
      if(r.name == "int_literal"){ found = r }
    }
    assert(len(found.history) == 0)
  }

  test.test("keywords of a derived grammar are its own"){
    local g = grammar.new({})
    local child = g:derive()
    child:keyword("unless")
    assert(parse(child, "expr", "unless") == null)
    assert(parse(g, "expr", "unless").type == "Identifier")
  }

  test.test("warnings: repeated modification, bad shape, failed probe"){
    local messages = {}
    local g = grammar.new({warn: func(m){ append(messages, m) }})
    local old_int = g:rule("int_literal")
    g:modify("int_literal", func(old){ return old })
    assert(len(messages) == 0)
    g:modify("int_literal", func(old){ return old })
    assert(len(messages) == 1)
    assert(messages[0] == "rule int_literal was already modified by runtime; runtime modifies it again")
    g:modify("if_statement", func(old){
      return peg.choice(old, peg.seq(old, peg.string("!")))
    })
    assert(messages[1] == "rule if_statement: choice(old, seq(old, ...)) never reaches its second alternative; use seq(old, tail:optional())")
    g:modify("block", func(old){ return peg.string("nope") })
    assert(str_starts(messages[2], "rule block no longer parses its probe after runtime"))
  }

  test.test("the compiler grammar accepts modifications through the parser API"){
    p.modify("int_literal", func(old){
      return peg.seq(peg.string("#"), old):pick(1)
    })
    local f = compile("return #40 + #2", "modified")
    assert(f() == 42)
    local names = {}
    for(let local r in values(p.rules())){
      if(r.name == "int_literal"){ names = r.history }
    }
    assert(names == {"runtime"})
    p.reset()
    assert(compile("return 40 + 2", "reset")() == 42)
  }
})

// a reference to a rule by name, for readability in the test above
func rule_name_free(g, name){
  return g:rule(name)
}

func str_starts(s, prefix){
  return require("slang/string").starts_with(s, prefix)
}
