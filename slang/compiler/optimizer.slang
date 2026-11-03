// slang/optimizer: constant folding on the AST, applied by the grammar to
// every parsed chunk.
//
//   local node = optimizer.optimize(ast_node)   // 2 * 3 + x is 6 + x
//
// Operators on literals are computed when the result is certain to be the
// run-time one: arithmetic and comparisons on numbers, + on strings,
// string * int, bitwise operators on integers, not, - and ~ of literals.
// Division and modulo by zero, negative shifts, non-finite doubles and
// strings longer than MAX_STRING are left to run time. `and` and `or` with
// a literal left side become one of their operands, an if (statement or
// expression) with a literal condition becomes the branch it takes, and the
// statements after a return, break, continue or throw are dropped. A
// local declared with a literal and never assigned again is replaced by
// that literal where it is read (see resolve.constant), so its uses fold
// too: `local DEBUG = false` makes `if(DEBUG){ ... }` disappear.
local ast = require("slang/ast")
local resolve = require("slang/resolve")

local optimizer = {}
local visitors = {}

// the longest string a fold may produce; longer ones are built at run time
// instead of being stored in the compiled code
local MAX_STRING = 4096

local visit = null

// what slang/resolve found in the chunk being optimized
local names = null

// the node itself when none of its children changed, otherwise a copy with
// the visited children (the fields in ast.specs; quoted code is data and is
// not looked into)
local func visit_children(node){
  local spec = ast.specs[node.type]
  if(spec == null or node.type == "Quote" or node.type == "Unquote"){
    return node
  }
  local fields = {}
  local changed = false
  for(let local field in values(spec)){
    local name = field[0]
    local child = node[name]
    if(child != null and field[1] == "list"){
      local out = {}
      for(let local item in values(child)){
        local v = visit(item)
        changed = changed or v != item
        append(out, v)
      }
      child = out
    } else if(child != null and field[1] != "value"){
      local v = visit(child)
      changed = changed or v != child
      child = v
    }
    fields[name] = child
  }
  if(not changed){
    return node
  }
  return ast.node(node.type, fields, node.token)
}

visit = func(node){
  local f = visitors[node.type]
  if(f == null){
    return visit_children(node)
  }
  return f(node)
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

// the literal for a folded value, or null when it is better left to run
// time: inf and nan have no literal, a long string would bloat the code
local func literal(token, v){
  if(type(v) == "double" and v - v != 0){
    return null
  }
  if(type(v) == "string" and len(v) > MAX_STRING){
    return null
  }
  return ast.literal(token, v)
}

// the folded value of op on two literals, or null for no fold
local func fold_binop(node, left, right){
  local a = value_of(left)
  local b = value_of(right)
  local op = node.op
  local numbers = is_number(a) and is_number(b)
  local strings = type(a) == "string" and type(b) == "string"
  local token = node.token
  if(op == "+"){
    if(numbers or (strings and len(a) + len(b) <= MAX_STRING)){
      return literal(token, a + b)
    }
  } else if(op == "-"){
    if(numbers){
      return literal(token, a - b)
    }
  } else if(op == "*"){
    if(numbers){
      return literal(token, a * b)
    }
    if(type(a) == "string" and type(b) == "int" and
      (b <= 0 or len(a) <= MAX_STRING / b)){
      return literal(token, a * b)
    }
  } else if(op == "/"){
    if(numbers and b != 0){
      return literal(token, a / b)
    }
  } else if(op == "%"){
    if(numbers and b != 0){
      return literal(token, a % b)
    }
  } else if(op == "=="){
    return literal(token, a == b)
  } else if(op == "!="){
    return literal(token, a != b)
  } else if(op == "<"){
    if(numbers){
      return literal(token, a < b)
    }
  } else if(op == "<="){
    if(numbers){
      return literal(token, a <= b)
    }
  } else if(op == ">"){
    if(numbers){
      return literal(token, a > b)
    }
  } else if(op == ">="){
    if(numbers){
      return literal(token, a >= b)
    }
  } else if(type(a) == "int" and type(b) == "int"){
    // bitwise operators on integers (the compiler runs on the same VM, so
    // folding gives exactly the run-time result; a negative shift amount is
    // a run-time error and is left alone)
    if(op == "&"){
      return literal(token, a & b)
    } else if(op == "|"){
      return literal(token, a | b)
    } else if(op == "~"){
      return literal(token, a ~ b)
    } else if(op == "<<" and b >= 0){
      return literal(token, a << b)
    } else if(op == ">>" and b >= 0){
      return literal(token, a >> b)
    }
  }
  return null
}

// whether a statement ends the code after it in its block
local func is_jump(node){
  local t = node.type
  return t == "Return" or t == "Break" or t == "Continue" or t == "Throw"
}

func visitors.BinOp(n){
  local left = visit(n.left)
  local right = visit(n.right)
  if(ast.is_literal(left)){
    // `and` and `or` give one of their operands; which one only depends on
    // whether the left one is truthy (anything but null and false)
    local truthy = value_of(left) != null and value_of(left) != false
    if(n.op == "and"){
      if(truthy){
        return right
      }
      return left
    }
    if(n.op == "or"){
      if(truthy){
        return left
      }
      return right
    }
    if(ast.is_literal(right)){
      local folded = fold_binop(n, left, right)
      if(folded != null){
        return folded
      }
    }
  }
  if(left == n.left and right == n.right){
    return n
  }
  return ast.node("BinOp", {left: left, op: n.op, right: right}, n.token)
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
  if(operand == n.operand){
    return n
  }
  return ast.node("UnOp", {op: n.op, operand: operand}, n.token)
}

func visitors.IfExpr(n){
  local condition = visit(n.condition)
  if(ast.is_literal(condition)){
    local v = value_of(condition)
    if(v != null and v != false){
      return visit(n.thenValue)
    }
    return visit(n.elseValue)
  }
  return visit_children(n)
}

// an If with a literal condition becomes the branch it takes, as a Block
// (a scope of its own, like the If was), or nothing when that branch is
// missing
func visitors.If(n){
  local condition = visit(n.condition)
  if(not ast.is_literal(condition)){
    return visit_children(n)
  }
  local v = value_of(condition)
  local branch = n.elseBranch
  if(v != null and v != false){
    branch = n.thenBranch
  }
  if(branch == null){
    return ast.node("Block", {statements: {}}, n.token)
  }
  branch = visit(branch)
  if(branch.type != "Block" and branch.type != "If"){
    branch = ast.node("Block", {statements: {branch}}, n.token)
  }
  return branch
}

// the statements without the empty blocks of ifs that take no branch and
// without the unreachable ones after a return, break, continue or throw
func visitors.Block(n){
  local statements = {}
  local changed = false
  for(let local s in values(n.statements)){
    local v = visit(s)
    changed = changed or v != s
    if(v.type != "Block" or len(v.statements) > 0 or s.type != "If"){
      append(statements, v)
    }
    if(is_jump(v)){
      break
    }
  }
  if(not changed and len(statements) == len(n.statements)){
    return n
  }
  return ast.node("Block", {statements: statements}, n.token)
}

// a read of a local that always holds a literal is that literal
func visitors.Identifier(n){
  if(names == null){
    return n
  }
  local c = resolve.constant(names.refs[n])
  if(c == null){
    return n
  }
  return ast.literal(n.token, value_of(c))
}

// optimize(node: table, opts?: {constants?: bool}) -> table
// node with its constant expressions folded. Nodes are not modified in
// place: a changed node is a copy, and an unchanged subtree is returned as
// it is.
// [constants]: also replace the reads of locals that always hold a literal
// (codegen does; the parser folds only, so that tools see every name)
func optimizer.optimize(node, opts){
  // (compile-time code may compile a chunk of its own meanwhile)
  local outer = names
  defer {
    names = outer
  }
  names = null
  if(opts != null and opts.constants){
    names = resolve.analyse(node)
  }
  return visit(node)
}

return optimizer
