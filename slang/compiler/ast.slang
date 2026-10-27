// slang/ast: helpers for AST nodes.
//
// A node is a table {type: "Name", ...fields, token} whose metatable has
// __type == "Name", so patterns like 'BinOp{left: local l} match it. The field
// layout follows the table encoding of the original implementation, so quoted
// code (+{...}) and extension-generated code use exactly the same shape.

local str = require("slang/string")

local ast = {}

// field specs per node type, in encoding order.
// kinds: "node" (child), "node?" (optional child), "list" (list of children), "value" (primitive)
local specs = {
  Int: {{"value", "value"}},
  Double: {{"value", "value"}},
  String: {{"value", "value"}},
  True: {},
  False: {},
  Null: {},
  Table: {{"fields", "list"}},
  Field: {{"key", "node?"}, {"value", "node"}},
  Spread: {{"value", "node"}},
  Identifier: {{"value", "value"}},
  Index: {{"receiver", "node"}, {"index", "node"}, {"dotStyle", "value"}},
  BinOp: {{"left", "node"}, {"op", "value"}, {"right", "node"}},
  UnOp: {{"op", "value"}, {"operand", "node"}},
  Function: {{"params", "list"}, {"body", "node"}},
  Call: {{"function", "node"}, {"args", "list"}},
  Invoke: {{"receiver", "node"}, {"name", "node"}, {"args", "list"}},
  Let: {{"pattern", "node"}, {"right", "node"}},
  LetStat: {{"pattern", "node"}, {"right", "node"}},
  Block: {{"statements", "list"}},
  CallStat: {{"call", "node"}},
  If: {{"condition", "node"}, {"thenBranch", "node"}, {"elseBranch", "node?"}},
  Return: {{"value", "node"}},
  Assignment: {{"left", "node"}, {"right", "node"}},
  Declaration: {{"is_local", "value"}, {"left", "node"}, {"right", "node?"}},
  Break: {},
  For: {{"init", "node?"}, {"condition", "node"}, {"update", "node?"}, {"body", "node"}},
  ForIn: {{"pattern", "node"}, {"itterator", "node"}, {"body", "node"}},
  VarPattern: {{"isLocal", "value"}, {"canBeNull", "value"}, {"name", "node"}},
  TablePattern: {{"type_check", "value"}, {"fields", "list"}},
  MatcherPattern: {{"matcher", "node?"}, {"type_name", "value"}, {"sub", "node?"}},
  FieldPattern: {{"key", "node?"}, {"value", "node"}},
  ConstPattern: {{"value", "node"}},
  Quote: {{"ast_type", "value"}, {"ast", "node"}},
  Unquote: {{"ast_type", "value"}, {"ast", "node"}},
}
ast.specs = specs

local statement_types = {
  Block: true, CallStat: true, If: true, Return: true, Assignment: true,
  Declaration: true, Break: true, For: true, ForIn: true, Unquote: true, LetStat: true,
}

local metas = {}
for(let local name in keys(specs)){
  metas[name] = {__type: name}
}

// node(type, fields, token): builds a node table
func ast.node(type_name, fields, token){
  if(metas[type_name] == null){
    error("unknown AST node type: ", type_name)
  }
  fields.type = type_name
  if(token != null){
    fields.token = token
  }
  fields.meta = metas[type_name]
  return fields
}

func ast.is_node(value){
  return type(value) != "table" and get_raw(value, "type") != null and specs[get_raw(value, "type")] != null
}

func ast.is_statement(node){
  return node != null and statement_types[node.type] == true
}

func ast.is_assignable(node){
  return node.type == "Identifier" or node.type == "Index" or node.type == "Unquote"
}

func ast.is_literal(node){
  local t = node.type
  return t == "Int" or t == "Double" or t == "String" or t == "True" or t == "False" or t == "Null"
}

// literal(token, value): the node for a primitive value
func ast.literal(token, value){
  local t = type(value)
  if(t == "string"){
    return ast.node("String", {value: value}, token)
  }
  if(t == "int"){
    return ast.node("Int", {value: value}, token)
  }
  if(t == "double"){
    return ast.node("Double", {value: value}, token)
  }
  if(t == "bool"){
    if(value){
      return ast.node("True", {}, token)
    }
    return ast.node("False", {}, token)
  }
  if(value == null){
    return ast.node("Null", {}, token)
  }
  error("cannot make a literal from a ", t)
}

// resolve_escapes("a\\nb") -> the string with escape sequences replaced
func ast.resolve_escapes(literal){
  if(str.index_of(literal, "\\") < 0){
    return literal
  }
  local pieces = {}
  local n = len(literal)
  local start = 0
  local i = 0
  for(i < n){
    if(str.byte_at(literal, i) == 92){
      if(i > start){
        append(pieces, str.substring(literal, start, i))
      }
      i = i + 1
      if(i >= n){
        error("Invalid escape sequence in ", literal)
      }
      local c = str.char_at(literal, i)
      if(c == "n"){
        append(pieces, "\n")
      } else if(c == "r"){
        append(pieces, "\r")
      } else if(c == "t"){
        append(pieces, "\t")
      } else if(c == "b"){
        append(pieces, "\b")
      } else if(c == "f"){
        append(pieces, "\f")
      } else if(c == "v"){
        append(pieces, "\v")
      } else if(c == "\\"){
        append(pieces, "\\")
      } else if(c == "\""){
        append(pieces, "\"")
      } else {
        error("Invalid escape sequence in ", literal)
      }
      i = i + 1
      start = i
    } else {
      i = i + 1
    }
  }
  if(start < n){
    append(pieces, str.substring(literal, start, n))
  }
  return str.join(pieces, "")
}

// ------------------------------------------------------------- quote support

local func field_literal(token, name, value_node){
  return ast.node("Field", {key: ast.node("String", {value: name}, token), value: value_node}, token)
}

local func table_node(token, fields){
  return ast.node("Table", {fields: fields}, token)
}

// quote(node): the Table-literal expression that rebuilds this node at run time
func ast.quote(node){
  if(node.type == "Unquote"){
    return node.ast
  }
  local spec = specs[node.type]
  if(spec == null){
    error("cannot quote unknown node type: ", node.type)
  }
  local token = node.token
  local fields = {}
  append(fields, field_literal(token, "type", ast.literal(token, node.type)))
  for(let local f in values(spec)){
    local name = f[0]
    local kind = f[1]
    local value = node[name]
    if(value != null){
      local enc
      if(kind == "list"){
        local items = {}
        for(let local item in values(value)){
          append(items, ast.node("Field", {value: ast.quote(item)}, token))
        }
        enc = table_node(token, items)
      } else if(kind == "value"){
        enc = ast.literal(token, value)
      } else {
        enc = ast.quote(value)
      }
      append(fields, field_literal(token, name, enc))
    }
  }
  append(fields, field_literal(token, "meta", table_node(token, {
    field_literal(token, "__type", ast.literal(token, node.type)),
  })))
  return table_node(token, fields)
}

// strip(node): a copy of the tree without tokens (what extensions see)
func ast.strip(node){
  if(node == null){
    return null
  }
  local spec = specs[node.type]
  if(spec == null){
    return node
  }
  local out = {}
  for(let local f in values(spec)){
    local name = f[0]
    local kind = f[1]
    local value = node[name]
    if(value != null){
      if(kind == "list"){
        local items = {}
        for(let local item in values(value)){
          append(items, ast.strip(item))
        }
        out[name] = items
      } else if(kind == "value"){
        out[name] = value
      } else {
        out[name] = ast.strip(value)
      }
    }
  }
  return ast.node(node.type, out, null)
}

// attach_token(node, token): gives every node of the tree that has no token this one
func ast.attach_token(node, token){
  if(node == null or token == null){
    return node
  }
  local spec = specs[node.type]
  if(spec == null){
    error("not an AST node: ", node)
  }
  if(node.token == null){
    node.token = token
  }
  for(let local f in values(spec)){
    local kind = f[1]
    local value = node[f[0]]
    if(value != null){
      if(kind == "list"){
        for(let local item in values(value)){
          ast.attach_token(item, token)
        }
      } else if(kind != "value"){
        ast.attach_token(value, token)
      }
    }
  }
  return node
}

// decode(value): the node from a parser/extension result; either a node or
// {token: t, ast: node}
func ast.decode(value){
  if(value == null){
    return null
  }
  if(type(value) == "table"){
    if(value.ast != null){
      return ast.attach_token(value.ast, value.token)
    }
    if(value.type != null and specs[value.type] != null){
      // a plain table in node shape (e.g. {type: "Identifier", value: "x"})
      value.meta = metas[value.type]
      return value
    }
    error("Invalid AST value: ", value)
  }
  if(specs[value.type] == null){
    error("Invalid AST node type: ", value.type)
  }
  return value
}

// --------------------------------------------------------------- to_string

local func escape_string(s){
  s = str.replace(s, "\"", "\\\"")
  s = str.replace(s, "\n", "\\n")
  s = str.replace(s, "\r", "\\r")
  s = str.replace(s, "\t", "\\t")
  s = str.replace(s, "\b", "\\b")
  s = str.replace(s, "\f", "\\f")
  return s
}

local writer = {}
local writer_meta = {__index: writer}

func writer.new(){
  local w = {parts: {}, indent: 0}
  w.meta = writer_meta
  return w
}

func writer.add(self, s){
  append(self.parts, s)
}

func writer.newline(self){
  append(self.parts, "\n")
  for(local i = 0; i < self.indent; i = i + 1){
    append(self.parts, " ")
  }
}

func writer.visit(self, node){
  local t = node.type
  if(t == "Int" or t == "Double"){
    self:add(string(node.value))
  } else if(t == "String"){
    self:add("\"")
    self:add(escape_string(node.value))
    self:add("\"")
  } else if(t == "True"){
    self:add("true")
  } else if(t == "False"){
    self:add("false")
  } else if(t == "Null"){
    self:add("null")
  } else if(t == "Table"){
    self:add("{")
    self.indent = self.indent + 2
    for(let local field in values(node.fields)){
      self:newline()
      self:visit(field)
      self:add(",")
    }
    self.indent = self.indent - 2
    self:newline()
    self:add("}")
  } else if(t == "Spread"){
    self:add("...")
    self:visit(node.value)
  } else if(t == "Field"){
    if(node.key != null){
      self:visit(node.key)
      self:add(":")
    }
    self:visit(node.value)
  } else if(t == "Identifier"){
    self:add(node.value)
  } else if(t == "Index"){
    self:visit(node.receiver)
    if(node.dotStyle){
      self:add(".")
      if(node.index.type == "String"){
        self:add(node.index.value)
      } else {
        self:visit(node.index)
      }
    } else {
      self:add("[")
      self:visit(node.index)
      self:add("]")
    }
  } else if(t == "BinOp"){
    self:add("(")
    self:visit(node.left)
    self:add(concat(" ", node.op, " "))
    self:visit(node.right)
    self:add(")")
  } else if(t == "UnOp"){
    self:add(node.op)
    self:visit(node.operand)
  } else if(t == "Function"){
    self:add("function(")
    for(let local param in values(node.params)){
      self:add(param.value)
      self:add(",")
    }
    self:add(")")
    self:visit(node.body)
  } else if(t == "Call" or t == "Invoke"){
    if(t == "Call"){
      self:visit(node.function)
    } else {
      self:visit(node.receiver)
      self:add(":")
      self:add(node.name.value)
    }
    self:add("(")
    for(let local arg in values(node.args)){
      self:visit(arg)
      self:add(",")
    }
    self:add(")")
  } else if(t == "Block"){
    self:add("{")
    self.indent = self.indent + 2
    for(let local statement in values(node.statements)){
      self:newline()
      self:visit(statement)
      self:add(";")
    }
    self.indent = self.indent - 2
    self:newline()
    self:add("}")
  } else if(t == "CallStat"){
    self:visit(node.call)
  } else if(t == "If"){
    self:add("if (")
    self:visit(node.condition)
    self:add(") ")
    self:visit(node.thenBranch)
    if(node.elseBranch != null){
      self:add(" else ")
      self:visit(node.elseBranch)
    }
  } else if(t == "For"){
    self:add("for (")
    if(node.init != null){
      self:visit(node.init)
    }
    self:add(";")
    self:visit(node.condition)
    self:add(";")
    if(node.update != null){
      self:visit(node.update)
    }
    self:add(")")
    self:visit(node.body)
  } else if(t == "ForIn"){
    self:add("for (")
    self:visit(node.pattern)
    self:add(" in ")
    self:visit(node.itterator)
    self:add(")")
    self:visit(node.body)
  } else if(t == "Return"){
    self:add("return")
    if(node.value != null){
      self:add(" ")
      self:visit(node.value)
    }
  } else if(t == "Assignment"){
    self:visit(node.left)
    self:add(" = ")
    self:visit(node.right)
  } else if(t == "Declaration"){
    if(node.is_local){
      self:add("local ")
    } else {
      self:add("global ")
    }
    self:visit(node.left)
    if(node.right != null){
      self:add(" = ")
      self:visit(node.right)
    }
  } else if(t == "ConstPattern"){
    self:visit(node.value)
  } else if(t == "FieldPattern"){
    if(node.key != null){
      self:visit(node.key)
      self:add(":")
    }
    self:visit(node.value)
  } else if(t == "MatcherPattern"){
    self:add("'")
    if(node.matcher != null){
      self:visit(node.matcher)
    } else {
      self:add(node.type_name)
    }
    if(node.sub != null){
      self:add(" as ")
      self:visit(node.sub)
    }
  } else if(t == "TablePattern"){
    if(node.type_check != null and node.type_check != "table"){
      self:add(concat("'", node.type_check))
    }
    self:add("{")
    for(let local field in values(node.fields)){
      self:visit(field)
      self:add(",")
    }
    self:add("}")
  } else if(t == "VarPattern"){
    if(node.isLocal){
      self:add("local ")
    } else {
      self:add("global ")
    }
    self:add(node.name.value)
    if(node.canBeNull){
      self:add("?")
    }
  } else if(t == "LetStat"){
    self:add("let ")
    self:visit(node.pattern)
    self:add(" = ")
    self:visit(node.right)
  } else if(t == "Let"){
    self:add("let ")
    self:visit(node.pattern)
    self:add(" = ")
    self:visit(node.right)
  } else if(t == "Break"){
    self:add("break")
  } else if(t == "Quote"){
    self:add("quote{")
    self:add(node.ast_type)
    self:add(":")
    self:visit(node.ast)
    self:add("}")
  } else if(t == "Unquote"){
    self:add("unquote{")
    self:add(node.ast_type)
    self:add(":")
    self:visit(node.ast)
    self:add("}")
  } else {
    error("to_string: unknown node type ", t)
  }
}

func ast.to_string(node){
  local w = writer.new()
  w:visit(node)
  return str.join(w.parts, "")
}

return ast
