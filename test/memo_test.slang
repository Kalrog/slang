// Memoization placement: a rule leading several alternatives of one choice
// parses once per position.
local t = require("slang/test")
local peg = require("slang/peg")
local compiler = require("slang/compiler")

// compiles a program under an extension counting how often `expr` runs
local func expr_runs_of(wrap_statement){
  local wrapper = ""
  if(wrap_statement){
    wrapper = """
      local afterwards = g:keyword("afterwards")
      g:modify("statement", func(old){
        return peg.choice(peg.seq(old, afterwards):pick(0), old)
      })
    """
  }
  expr_runs = 0
  local run = compile(concat("""
    extension {
      local peg = require("slang/peg")
      local g = require("slang/compiler").grammar()
      g:modify("expr", func(old){ return old:map(func(v){ expr_runs = expr_runs + 1 return v }) })
    """, wrapper, """
    }
    local x = 1 + 2
    local y = x * 3
    if(y > 5){ x = y }
    return x + y
  """), "memo")
  assert(run() == 18)
  return expr_runs
}

t.group("memoization"){
  t.test("the old rule of a wrapped statement parses once per statement"){
    local plain = expr_runs_of(false)
    local wrapped = expr_runs_of(true)
    assert(plain > 0)
    assert(wrapped == plain, concat(
      "expr ran ", wrapped, " times with the wrapper, ", plain, " without"
    ))
  }
  t.test("placement names the memoized rule"){
    local g = compiler.grammar()
    local func memo_names(){
      g:activate()
      local names = {}
      for(let local m in values(g.memos)){ append(names, m.name) }
      return names
    }
    // core's only shared prefix: the digits of the two numeric literals
    assert(
      memo_names() == {"number"},
      concat("memoized in the base grammar: ", memo_names())
    )
    local afterwards = g:keyword("afterwards")
    g:modify("statement", func(old){
      return peg.choice(peg.seq(old, afterwards):pick(0), old)
    })
    assert(
      memo_names() == {"number", "statement"},
      concat("memoized: ", memo_names())
    )
    compiler.reset()
  }
}
