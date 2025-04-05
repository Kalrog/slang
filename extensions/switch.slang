local p = require("slang/parser")
local switch_statement = {}
local case_block = {}

func switch_statement.new(token,value, case_blocks){
  local obj = {
    token: token,
    value: value,
    case_blocks: case_blocks,
    meta: {
      __index: switch_statement
    }
  }
  return obj
}

func switch_statement.build(self){
  local current = {}
  local result = current
  for(let local c in values(self.case_blocks)){
    local ast = c:build(self.value)
    current.elseBranch = ast
    current = ast
  }
  return {
    token: self.token,
    ast: result.elseBranch
  }
}

func switch_statement.parser(){
  return p.seq(
    p.keyword("switch"),
    p.token("("),
    p.expr(),
    p.token(")"),
    p.token("{"),
    case_block.parser():star(),
    p.token("}")
  ):map(func(result){
    return switch_statement.new(result[0],result[2],result[5])
  })
}

func case_block.new(token,pattern,body){
  local obj = {
    token: token,
    pattern: pattern,
    body: body,
    meta: {
      __index: case_block
    }
  }
  return obj
}

func case_block.build(self,value){
  return +{stat:
    if(-{{type:"Let",pattern:self.pattern,right:value}})
    -{self.body}
  } 
}

func case_block.parser(){
  return p.seq(
    p.keyword("case"),
    p.slang_pattern(),
    p.token(":"),
    p.block(false)
  ):map(func(result){
    return case_block.new(result[0],result[1],result[3])
  })
}

p.add_statement(
  "switch",
  switch_statement.parser():map(func (result){
    return result:build();
  })
)
