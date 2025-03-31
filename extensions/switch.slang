local p = require("slang/parser")

local switch_statement = {}
local case = {}

func switch_statement.new(token,value, cases){
  local obj = {
    token: token,
    value: value,
    cases: cases,
    meta: {
      __index: switch_statement
    }
  }
  return obj
}

func switch_statement.build(self){
  local current = {}
  local result = current
  for(let local case in values(self.cases)){
    local ast = case:build(self.value)
    current.elseBranch = ast
    current = ast
  }
  return result.elseBranch
}

func switch_statement.parser(){
  return p.seq(
    p.keyword("switch"),
    p.token("("),
    p.expr(),
    p.token(")"),
    p.token("{"),
    case.parser():star(),
    p.token("}")
  ):map(func(result){
    return switch_statement.new(result[0],result[2],result[5])
  })
}

func case.new(token,pattern,body){
  local obj = {
    token: token,
    pattern: pattern,
    body: body,
    meta: {
      __index: case
    }
  }
  return obj
}

func case.build(self,value){
  return +{stat:
    if(-{{type:"Let",pattern:self.pattern,right:value}})
    -{self.body}
  } 
}

func case.parser(){
  return p.seq(
    p.keyword("case"),
    p.slang_pattern(),
    p.token(":"),
    p.block(false)
  ):map(func(result){
    return case.new(result[0],result[1],result[3])
  })
}

p.add_statement(
  "switch",
  switch_statement.parser():map(func (switch){
    return switch:build();
  })
)
