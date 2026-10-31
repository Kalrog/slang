// `switch(value){ case pattern: statements ... }`: picks the first case
// whose pattern matches the value, as `if(let ...)` does for one pattern.
//
// A case is a slang pattern, a colon and the statements up to the next
// case or the closing brace; no braces, no `break`, no falling through.
// The cases are tried in order and only the first that matches runs; when
// none does, nothing happens. `case local other:` at the end is a default
// for any value but null (a `local` pattern does not match null).
// The locals a pattern binds are visible in its case only. `return`,
// `break` and `continue` in a case act on the enclosing function or loop.
//
//   local func describe(shape){
//     switch(shape){
//       case {kind: "circle", r: local r}:
//         return concat("circle of radius ", r)
//       case {kind: "rect", w: local w, h: local h}:
//         local area = w * h
//         return concat("rectangle of area ", area)
//       case local other:
//         return concat("not a shape: ", other)
//     }
//   }
//   print(describe({kind: "circle", r: 2}), "\n")
//   print(describe({kind: "rect", w: 2, h: 3}), "\n")
//   print(describe(42), "\n")
//
// The value is evaluated once, into a hidden local of a block, and the
// cases become a chain of `if(let pattern = __subjectN) ... else if(...)`.
// A switch needs at least one case.
local peg = require("slang/peg")
local fmt = require("slang/format")
local g = require("slang/compiler").grammar()
local switch_statement = {}
local switch_count = 0
local case_block = {}

func switch_statement.new(token, value, case_blocks){
  local obj = {
    token: token,
    value: value,
    case_blocks: case_blocks,
    meta: {__index: switch_statement},
  }
  return obj
}

// the value is evaluated once, into a hidden local the cases test
func switch_statement.build(self){
  if(len(self.case_blocks) == 0){
    g:error_at(self.token, "a switch needs at least one case")
  }
  // a name per switch of the file: nested switches may not share one
  switch_count = switch_count + 1
  local name = concat("__subject", string(switch_count))
  local hidden = {type: "Identifier", value: name}
  local current = {}
  local result = current
  for(let local c in values(self.case_blocks)){
    local ast = c:build(hidden)
    current.elseBranch = ast
    current = ast
  }
  return {
    token: self.token,
    ast: {
      type: "Block",
      statements: {
        {type: "Declaration", is_local: true, left: hidden, right: self.value},
        result.elseBranch,
      },
    },
  }
}

// the marks tell `slang fmt` the layout:
//   switch(value){
//     case PATTERN:
//       statements
//   }
func switch_statement.parser(){
  return peg.seq(
    fmt.gaps(g:keyword("switch"), null, "none"),
    fmt.gaps(g:token("("), "none", "none"),
    g:rule("expr"),
    fmt.gaps(g:token(")"), "none", "none"),
    g:token("{"),
    fmt.indent(case_block.parser():star(), "hardline"),
    fmt.gaps(g:token("}"), "hardline"),
  ):map(func(result){
    return switch_statement.new(result[0], result[2], result[5])
  })
}

func case_block.new(token, pattern, body){
  local obj = {
    token: token,
    pattern: pattern,
    body: body,
    meta: {__index: case_block},
  }
  return obj
}

func case_block.build(self, value){
  return +{stat:
    if(-{{type: "Let", pattern: self.pattern, right: value}}) -{self.body}
  }
}

func case_block.parser(){
  return peg.seq(
    fmt.gaps(g:keyword("case"), "hardline", "space"),
    g:rule("slang_pattern"),
    fmt.gaps(g:token(":"), "none"),
    fmt.indent(g:rule("chunk"), "hardline"),
  ):map(func(result){
    return case_block.new(result[0], result[1], result[3])
  })
}

g:statement("switch", switch_statement.parser():map(func(result){
  return result:build()
}))
