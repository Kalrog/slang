// slang/optimizer: constant folding on the AST (applied to parsed chunks).
local ast = require("slang/ast")

local optimizer = {}
local visitors = {}

local func visit(node){
  local f = visitors[node.type]
  if(f == null){
    return node
  }
  return f(node)
}

local func maybe(node){
  if(node == null){
    return null
  }
  return visit(node)
}

local func visit_list(list){
  local out = {}
  for(let local item in values(list)){
    append(out, visit(item))
  }
  return out
}

local func value_of(node){
  local t = node.type
  if(t == "True"){
    return true
  }
  if(t == "False"){
    return false
  }
  if(t == "Null"){
    return null
  }
  return node.value
}

local func is_number(v){
  local t = type(v)
  return t == "int" or t == "double"
}

local func fold_binop(node, left, right){
  local a = value_of(left)
  local b = value_of(right)
  local op = node.op
  local numbers = is_number(a) and is_number(b)
  local strings = type(a) == "string" and type(b) == "string"
  local token = node.token
  if(op == "+"){
    if(numbers or strings){
      return ast.literal(token, a + b)
    }
  } else if(op == "-"){
    if(numbers){
      return ast.literal(token, a - b)
    }
  } else if(op == "*"){
    if(numbers or (type(a) == "string" and type(b) == "int")){
      return ast.literal(token, a * b)
    }
  } else if(op == "/"){
    if(numbers and b != 0){
      return ast.literal(token, a / b)
    }
  } else if(op == "%"){
    if(numbers and b != 0){
      return ast.literal(token, a % b)
    }
  } else if(op == "=="){
    return ast.literal(token, a == b)
  } else if(op == "!="){
    return ast.literal(token, a != b)
  } else if(op == "<"){
    if(numbers){
      return ast.literal(token, a < b)
    }
  } else if(op == "<="){
    if(numbers){
      return ast.literal(token, a <= b)
    }
  } else if(op == ">"){
    if(numbers){
      return ast.literal(token, a > b)
    }
  } else if(op == ">="){
    if(numbers){
      return ast.literal(token, a >= b)
    }
  } else if(type(a) == "int" and type(b) == "int"){
    // bitwise operators on integers (the compiler runs on the same VM, so
    // folding gives exactly the run-time result; a negative shift amount is
    // a run-time error and is left alone)
    if(op == "&"){
      return ast.literal(token, a & b)
    } else if(op == "|"){
      return ast.literal(token, a | b)
    } else if(op == "~"){
      return ast.literal(token, a ~ b)
    } else if(op == "<<" and b >= 0){
      return ast.literal(token, a << b)
    } else if(op == ">>" and b >= 0){
      return ast.literal(token, a >> b)
    }
  }
  return ast.node("BinOp", {left: left, op: op, right: right}, token)
}

func visitors.Assignment(n){
  return ast.node("Assignment", {left: n.left, right: visit(n.right)}, n.token)
}

func visitors.BinOp(n){
  local left = visit(n.left)
  local right = visit(n.right)
  if(ast.is_literal(left) and ast.is_literal(right)){
    return fold_binop(n, left, right)
  }
  return ast.node("BinOp", {left: left, op: n.op, right: right}, n.token)
}

func visitors.Block(n){
  return ast.node("Block", {statements: visit_list(n.statements)}, n.token)
}

func visitors.Field(n){
  return ast.node("Field", {key: maybe(n.key), value: visit(n.value)}, n.token)
}

func visitors.For(n){
  return ast.node("For", {init: maybe(n.init), condition: visit(n.condition), update: maybe(n.update), body: visit(n.body)}, n.token)
}

func visitors.Call(n){
  return ast.node("Call", {function: visit(n.function), args: visit_list(n.args)}, n.token)
}

func visitors.Invoke(n){
  return ast.node("Invoke", {receiver: visit(n.receiver), name: n.name, args: visit_list(n.args)}, n.token)
}

func visitors.MatcherPattern(n){
  return ast.node("MatcherPattern", {matcher: maybe(n.matcher), type_name: n.type_name, sub: n.sub}, n.token)
}

func visitors.LetStat(n){
  return ast.node("LetStat", {pattern: n.pattern, right: visit(n.right)}, n.token)
}

func visitors.Spread(n){
  return ast.node("Spread", {value: visit(n.value)}, n.token)
}

func visitors.Function(n){
  return ast.node("Function", {params: n.params, body: visit(n.body)}, n.token)
}

func visitors.CallStat(n){
  return ast.node("CallStat", {call: visit(n.call)}, n.token)
}

func visitors.If(n){
  return ast.node("If", {condition: visit(n.condition), thenBranch: visit(n.thenBranch), elseBranch: maybe(n.elseBranch)}, n.token)
}

func visitors.Index(n){
  return ast.node("Index", {receiver: visit(n.receiver), index: visit(n.index), dotStyle: n.dotStyle}, n.token)
}

func visitors.Return(n){
  return ast.node("Return", {value: maybe(n.value)}, n.token)
}

func visitors.Table(n){
  return ast.node("Table", {fields: visit_list(n.fields)}, n.token)
}

func visitors.UnOp(n){
  local operand = visit(n.operand)
  if(ast.is_literal(operand)){
    local v = value_of(operand)
    if(n.op == "not"){
      return ast.literal(n.token, not v)
    }
    if(n.op == "-" and is_number(v)){
      return ast.literal(n.token, -v)
    }
    if(n.op == "~" and type(v) == "int"){
      return ast.literal(n.token, ~v)
    }
  }
  return ast.node("UnOp", {op: n.op, operand: operand}, n.token)
}

func visitors.Declaration(n){
  return ast.node("Declaration", {is_local: n.is_local, left: n.left, right: maybe(n.right)}, n.token)
}

func optimizer.optimize(node){
  return visit(node)
}

return optimizer
