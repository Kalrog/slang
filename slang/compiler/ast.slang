// slang/ast: building, checking and printing the syntax tree that the
// parser produces, quotes (+{...}) build and extensions return.
//
//   local ast = require("slang/ast")
//   local sum = ast.node("BinOp", {
//     left: ast.literal(null, 1), op: "+", right: +{x * 2},
//   })
//   print(ast.to_source(sum))        // 1 + x * 2
//
// A node is a table {type: "Name", ...fields, token} whose metatable has
// __type == "Name": type(node) is "Name", and patterns like
// 'BinOp{left: local l} match it. Each node type has a fixed set of fields,
// listed in [specs]. Quoted code (+{...}) and the code extensions generate
// have exactly the same shape, so an extension may return either; a plain
// table in node shape ({type: "Identifier", value: "x"}) is accepted too
// wherever a parser result goes through [decode].

// A syntax tree node. Its other fields depend on its type (see [specs]).
// type Node = {type: string, token?: table}
// [type]: the node type: "Identifier", "BinOp", "Call", "Block", ...
// [token]: its source token (see slang/peg); null in generated code

// What [requires] finds.
// type Requires = {names: {{name: string, pos: int}}, computed: {int}}
// [names]: each require of a constant name, with the byte offset of the call
// [computed]: the byte offsets of the requires whose name is computed

local str = require("slang/string")
local utf8 = require("slang/utf8")

local ast = {}

// the fields of every node type (see ast.specs)
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
  Break: {{"label", "value"}},
  Continue: {{"label", "value"}},
  For: {
    {"init", "node?"}, {"condition", "node"}, {"update", "node?"},
    {"body", "node"}, {"label", "value"}
  },
  ForIn: {
    {"pattern", "node"}, {"itterator", "node"}, {"body", "node"},
    {"label", "value"}
  },
  VarPattern: {{"isLocal", "value"}, {"canBeNull", "value"}, {"name", "node"}},
  TablePattern: {{"type_check", "value"}, {"fields", "list"}},
  MatcherPattern: {
    {"matcher", "node?"}, {"type_name", "value"}, {"sub", "node?"}
  },
  FieldPattern: {{"key", "node?"}, {"value", "node"}},
  ConstPattern: {{"value", "node"}},
  Quote: {{"ast_type", "value"}, {"ast", "node"}},
  Unquote: {{"ast_type", "value"}, {"ast", "node"}},
  Try: {{"body", "node"}, {"catches", "list"}},
  Catch: {{"pattern", "node?"}, {"body", "node"}},
  Defer: {{"body", "node"}},
  Throw: {{"value", "node"}},
  IfExpr: {{"condition", "node"}, {"thenValue", "node"}, {"elseValue", "node"}},
}
// The fields of every node type, in order, as {name, kind} pairs:
// `specs.BinOp` is {{"left", "node"}, {"op", "value"}, {"right", "node"}}.
// The kinds: "node" (a child node), "node?" (an optional child), "list" (a
// list of child nodes) and "value" (a string, number or bool). A type not
// listed here is not a node type.
ast.specs = specs

local statement_types = {
  Block: true, CallStat: true, If: true, Return: true, Assignment: true,
  Declaration: true, Break: true, For: true, ForIn: true, Unquote: true,
  LetStat: true, Try: true, Defer: true, Throw: true, Continue: true
}

local metas = {}
for(let local name in keys(specs)){
  metas[name] = {__type: name}
}

// node(type_name: string, fields: table, token?: table) -> Node
// Makes fields a node of type type_name, in place, and returns it. Raises
// for an unknown node type; the fields are not checked against [specs].
//   ast.node("Identifier", {value: "x"}, null)
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

// is_node(value) -> bool
// Whether value is a node with its metatable. A plain table in node shape
// is not; [decode] makes it one.
func ast.is_node(value){
  return type(value) != "table" and get_raw(value, "type") != null and
    specs[get_raw(value, "type")] != null
}

// is_statement(node: Node?) -> bool
// Whether node may stand as a statement (a Block, If, Declaration,
// CallStat, Unquote, ...); false for null and for expressions.
func ast.is_statement(node){
  return node != null and statement_types[node.type] == true
}

// is_assignable(node: Node) -> bool
// Whether node may be assigned to: an Identifier, an Index or an Unquote.
func ast.is_assignable(node){
  return node.type == "Identifier" or node.type == "Index" or
    node.type == "Unquote"
}

// is_literal(node: Node) -> bool
// Whether node is a constant: Int, Double, String, True, False or Null.
func ast.is_literal(node){
  local t = node.type
  return t == "Int" or t == "Double" or t == "String" or t == "True" or
    t == "False" or t == "Null"
}

// requires(node: Node) -> Requires
// The modules the code requires: those given by a constant name
// (`require("a/b")`) and the places of those whose name is computed.
// Quoted code is not looked into; positions are 0 for generated nodes.
func ast.requires(node){
  local found = {names: {}, computed: {}}
  local func walk(n){
    if(n.type == "Quote"){
      return
    }
    if(n.type == "Call" and n.function.type == "Identifier" and
      n.function.value == "require"){
      local pos = 0
      if(n.token != null){
        pos = n.token.start
      }
      if(len(n.args) == 1 and n.args[0].type == "String"){
        append(found.names, {name: n.args[0].value, pos: pos})
      } else {
        append(found.computed, pos)
      }
    }
    for(let local spec in values(specs[n.type] or {})){
      local child = n[spec[0]]
      if(child != null){
        if(spec[1] == "list"){
          for(let local c in values(child)){
            walk(c)
          }
        } else if(spec[1] != "value"){
          walk(child)
        }
      }
    }
  }
  walk(node)
  return found
}

// literal(token: table?, value) -> Node
// The node for a string, int, double, bool or null value; raises for any
// other type.
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

// the value of the hex digits in literal[from, to), or null
local func hex_value(literal, from, to){
  if(to > len(literal)){
    return null
  }
  local v = 0
  for(local i = from; i < to; i = i + 1){
    local b = str.byte_at(literal, i)
    if(b >= 48 and b <= 57){
      v = v * 16 + b - 48
    } else if(b >= 97 and b <= 102){
      v = v * 16 + b - 87
    } else if(b >= 65 and b <= 70){
      v = v * 16 + b - 55
    } else {
      return null
    }
  }
  return v
}

// resolve_escapes(literal: string) -> string
// The text of a string literal's body with its escape sequences replaced:
// \n \r \t \b \f \v \\ \" and \xHH (a byte), \u{H...} (a code point,
// as UTF-8). Raises on any other escape.
//   ast.resolve_escapes("a\\nb")   // "a", a newline, "b"
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
        error("Invalid escape sequence at the end of the string")
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
      } else if(c == "x"){
        // \xHH: one byte
        local v = hex_value(literal, i + 1, i + 3)
        if(v == null){
          error("\\x needs two hex digits")
        }
        append(pieces, str.from_bytes({v}))
        i = i + 2
      } else if(c == "u"){
        // \u{H...}: a code point as UTF-8
        local close = str.index_of(literal, "}", i)
        local v = null
        if(str.char_at(literal, i + 1) == "{" and close > i + 2 and
          close <= i + 8){
          v = hex_value(literal, i + 2, close)
        }
        if(v == null or v > 1114111 or (v >= 55296 and v <= 57343)){
          error("\\u needs a code point in braces, like \\u{e9}")
        }
        append(pieces, utf8.char(v))
        i = close
      } else {
        error("Invalid escape sequence \\", c)
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
  return ast.node(
    "Field", {key: ast.node("String", {value: name}, token), value: value_node},
    token
  )
}

local func table_node(token, fields){
  return ast.node("Table", {fields: fields}, token)
}

// quote(node: Node) -> Node
// The Table literal expression that rebuilds node at run time (what
// +{...} compiles to). An Unquote inside becomes the expression it holds,
// so its value is spliced in.
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

// strip(node: Node?) -> Node?
// A copy of the tree without tokens. A value that is not a node is
// returned as it is.
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

// attach_token(node: Node?, token: table?) -> Node?
// Gives every node of the tree that has no token this one, in place, and
// returns node; generated code then reports errors at token.
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

// decode(value: Node | {token: table, ast: Node} | null) -> Node?
// The node an extension's parser or callback produced: a node; a
// {token, ast} pair, whose token goes to every node of ast that has none
// (see [attach_token]); or a plain table in node shape, which gets its
// metatable. Raises for anything else.
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

local hex_digits = "0123456789abcdef"

// the bytes of s with the other control bytes, and the high bytes when s
// is not UTF-8, written as \xHH
local func escape_bytes(s){
  local high = not utf8.valid(s)
  local pieces = {}
  local start = 0
  local n = len(s)
  for(local i = 0; i < n; i = i + 1){
    local b = str.byte_at(s, i)
    if(b < 32 or b == 127 or (high and b >= 128)){
      append(pieces, str.substring(s, start, i))
      append(pieces, concat(
        "\\x",
        str.char_at(hex_digits, b >> 4),
        str.char_at(hex_digits, b & 15),
      ))
      start = i + 1
    }
  }
  if(start == 0){
    return s
  }
  append(pieces, str.substring(s, start, n))
  return str.join(pieces, "")
}

local func escape_string(s){
  s = str.replace(s, "\\", "\\\\")
  s = str.replace(s, "\"", "\\\"")
  s = str.replace(s, "\n", "\\n")
  s = str.replace(s, "\r", "\\r")
  s = str.replace(s, "\t", "\\t")
  s = str.replace(s, "\b", "\\b")
  s = str.replace(s, "\f", "\\f")
  return escape_bytes(s)
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
  } else if(t == "Break" or t == "Continue"){
    self:add(t == "Break" and "break" or "continue")
    if(node.label != null){
      self:add(" ")
      self:add(node.label)
    }
  } else if(t == "Try"){
    self:add("try ")
    self:visit(node.body)
    for(let local c in values(node.catches)){
      self:visit(c)
    }
  } else if(t == "Catch"){
    self:add(" catch")
    if(node.pattern != null){
      self:add("(")
      self:visit(node.pattern)
      self:add(")")
    }
    self:add(" ")
    self:visit(node.body)
  } else if(t == "Defer"){
    self:add("defer ")
    self:visit(node.body)
  } else if(t == "Throw"){
    self:add("raise(")
    self:visit(node.value)
    self:add(")")
  } else if(t == "IfExpr"){
    self:add("if (")
    self:visit(node.condition)
    self:add(") { ")
    self:visit(node.thenValue)
    self:add(" } else ")
    if(node.elseValue.type == "IfExpr"){
      self:visit(node.elseValue)
    } else {
      self:add("{ ")
      self:visit(node.elseValue)
      self:add(" }")
    }
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

// to_string(node: Node) -> string
// The tree in a compact debugging form: expressions fully parenthesized,
// `(1 + (x * 2))`. Not meant to be parsed again; see [to_source].
func ast.to_string(node){
  local w = writer.new()
  w:visit(node)
  return str.join(w.parts, "")
}

// --------------------------------------------------------------- to_source
//
// to_source(node) -> slang source for an AST: what a file looks like once
// its extensions have been applied (every extension lowers to the core
// AST). Parsing the result gives the same bytecode again.

// binding powers for parentheses (looser first)
local binary_power = {
  ["or"]: 1, ["and"]: 2, ["=="]: 3, ["!="]: 3, ["<"]: 3, ["<="]: 3, [">"]: 3,
  [">="]: 3, ["|"]: 4, ["~"]: 5, ["&"]: 6, ["<<"]: 7, [">>"]: 7, ["+"]: 8,
  ["-"]: 8, ["*"]: 9, ["/"]: 9, ["%"]: 9
}
local unary_power = 10
local power_power = 11
local postfix_power = 12

local func is_name(s){
  if(len(s) == 0){ return false }
  for(local i = 0; i < len(s); i = i + 1){
    local b = str.byte_at(s, i)
    local ok = (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or b == 95 or
      (i > 0 and b >= 48 and b <= 57)
    if(not ok){ return false }
  }
  return true
}

local source = {}
local source_meta = {__index: source}

func source.new(){
  local w = {parts: {}, indent: 0}
  w.meta = source_meta
  return w
}

func source.add(self, s){
  append(self.parts, s)
}

func source.newline(self){
  append(self.parts, "\n")
  for(local i = 0; i < self.indent; i = i + 1){
    append(self.parts, " ")
  }
}

// the binding power of an expression node (how tightly it holds together)
local func power_of(node){
  local t = node.type
  if(t == "BinOp"){
    if(node.op == "^"){ return power_power }
    return binary_power[node.op] or 3
  }
  if(t == "UnOp"){ return unary_power }
  if(t == "Let"){ return 0 }
  return postfix_power + 1
}

// visits an operand, in parentheses when it binds looser than min_power
func source.operand(self, node, min_power){
  if(power_of(node) < min_power){
    self:add("(")
    self:expr(node)
    self:add(")")
  } else {
    self:expr(node)
  }
}

func source.list(self, items, separator, f){
  local first = true
  for(let local item in values(items)){
    if(not first){ self:add(separator) }
    first = false
    f(item)
  }
}

func source.params(self, params){
  self:add("(")
  self:list(params, ", ", func(p){ self:add(p.value) })
  self:add(")")
}

func source.function(self, node){
  self:add("func")
  self:params(node.params)
  self:block(node.body)
}

func source.expr(self, node){
  local t = node.type
  if(t == "Int" or t == "Double"){
    self:add(string(node.value))
  } else if(t == "String"){
    self:add(concat("\"", escape_string(node.value), "\""))
  } else if(t == "True"){
    self:add("true")
  } else if(t == "False"){
    self:add("false")
  } else if(t == "Null"){
    self:add("null")
  } else if(t == "Identifier"){
    self:add(node.value)
  } else if(t == "IfExpr"){
    self:add("if(")
    self:expr(node.condition)
    self:add("){ ")
    self:expr(node.thenValue)
    self:add(" } else ")
    if(node.elseValue.type == "IfExpr"){
      self:expr(node.elseValue)
    } else {
      self:add("{ ")
      self:expr(node.elseValue)
      self:add(" }")
    }
  } else if(t == "Table"){
    if(len(node.fields) == 0){
      self:add("{}")
      return null
    }
    self:add("{")
    self:list(node.fields, ", ", func(f){ self:expr(f) })
    self:add("}")
  } else if(t == "Field"){
    local key = node.key
    if(key != null){
      if(key.type == "String" and is_name(key.value)){
        self:add(key.value)
      } else {
        self:add("[")
        self:expr(key)
        self:add("]")
      }
      self:add(": ")
    }
    self:expr(node.value)
  } else if(t == "Spread"){
    self:add("...")
    self:operand(node.value, postfix_power)
  } else if(t == "Index"){
    self:operand(node.receiver, postfix_power)
    if(node.dotStyle and node.index.type == "String" and
      is_name(node.index.value)){
      self:add(concat(".", node.index.value))
    } else {
      self:add("[")
      self:expr(node.index)
      self:add("]")
    }
  } else if(t == "Call"){
    self:operand(node.function, postfix_power)
    self:args(node.args)
  } else if(t == "Invoke"){
    self:operand(node.receiver, postfix_power)
    self:add(concat(":", node.name.value))
    self:args(node.args)
  } else if(t == "BinOp"){
    local p = power_of(node)
    if(node.op == "^"){
      self:operand(node.left, p + 1)
      self:add(" ^ ")
      self:operand(node.right, p)
    } else {
      self:operand(node.left, p)
      self:add(concat(" ", node.op, " "))
      self:operand(node.right, p + 1)
    }
  } else if(t == "UnOp"){
    self:add(node.op)
    if(node.op == "not"){ self:add(" ") }
    self:operand(node.operand, unary_power)
  } else if(t == "Function"){
    self:function(node)
  } else if(t == "Let"){
    self:add("let ")
    self:pattern(node.pattern)
    self:add(" = ")
    self:expr(node.right)
  } else if(t == "Quote"){
    self:quoted("+{", node)
  } else if(t == "Unquote"){
    self:quoted("-{", node)
  } else {
    error("to_source: not an expression: ", t)
  }
}

func source.quoted(self, open, node){
  self:add(open)
  if(node.ast_type == "stat" or node.ast_type == "block"){
    self:add(concat(node.ast_type, ": "))
    if(node.ast_type == "block"){
      self:statements(node.ast.statements, " ")
    } else {
      self:statement(node.ast)
    }
  } else {
    self:expr(node.ast)
  }
  self:add("}")
}

func source.args(self, args){
  self:add("(")
  self:list(args, ", ", func(a){ self:expr(a) })
  self:add(")")
}

func source.pattern(self, node){
  local t = node.type
  if(t == "TablePattern"){
    if(node.type_check != null and node.type_check != "table"){
      self:add(concat("'", node.type_check))
    }
    self:add("{")
    self:list(node.fields, ", ", func(f){ self:pattern(f) })
    self:add("}")
  } else if(t == "FieldPattern"){
    local key = node.key
    if(key != null){
      if(key.type == "String" and is_name(key.value)){
        self:add(key.value)
      } else {
        self:add("[")
        self:expr(key)
        self:add("]")
      }
      self:add(": ")
    }
    self:pattern(node.value)
  } else if(t == "VarPattern"){
    if(node.isLocal){ self:add("local ") }
    self:add(node.name.value)
    if(node.canBeNull){ self:add("?") }
  } else if(t == "ConstPattern"){
    self:expr(node.value)
  } else if(t == "MatcherPattern"){
    self:add("'")
    if(node.matcher != null){
      // only a call or a field access may follow the quote bare
      local mt = node.matcher.type
      if(mt == "Call" or mt == "Index"){
        self:expr(node.matcher)
      } else {
        self:add("(")
        self:expr(node.matcher)
        self:add(")")
      }
    } else {
      self:add(node.type_name)
    }
    if(node.sub != null){
      self:add(" as ")
      self:pattern(node.sub)
    }
  } else {
    error("to_source: not a pattern: ", t)
  }
}

// a statement followed by a bare block needs a `;`, or the block would
// read as a block argument of the statement's last expression
local func before_block(list, i){
  local next = list[i + 1]
  return next != null and next.type == "Block" and len(next.statements) > 0
}

func source.block(self, node){
  self:add("{")
  if(len(node.statements) > 0){
    self.indent = self.indent + 2
    local list = node.statements
    for(local i = 0; i < len(list); i = i + 1){
      self:newline()
      self:statement(list[i])
      if(before_block(list, i)){
        self:add(";")
      }
    }
    self.indent = self.indent - 2
    self:newline()
  }
  self:add("}")
}

// statements separated by newlines (a chunk) or by separator
func source.statements(self, list, separator){
  local first = true
  for(local i = 0; i < len(list); i = i + 1){
    local s = list[i]
    // an empty block says nothing (an extension statement that produced none)
    if(not(s.type == "Block" and len(s.statements) == 0)){
      if(not first){
        if(separator != null){
          self:add(separator)
        } else {
          self:newline()
        }
      }
      first = false
      self:statement(s)
      if(separator == null and before_block(list, i)){
        self:add(";")
      }
    }
  }
}

func source.statement(self, node){
  local t = node.type
  if(t == "Block"){
    self:block(node)
  } else if(t == "CallStat"){
    self:expr(node.call)
  } else if(t == "Return"){
    self:add("return")
    if(node.value != null){
      self:add(" ")
      self:expr(node.value)
    }
  } else if(t == "Break" or t == "Continue"){
    self:add(t == "Break" and "break" or "continue")
    if(node.label != null){
      self:add(" ")
      self:add(node.label)
    }
  } else if(t == "Assignment"){
    self:expr(node.left)
    self:add(" = ")
    self:expr(node.right)
  } else if(t == "Declaration"){
    if(node.right != null and node.right.type == "Function"){
      if(node.is_local){ self:add("local ") }
      self:add("func ")
      self:expr(node.left)
      self:params(node.right.params)
      self:block(node.right.body)
    } else {
      if(node.is_local){ self:add("local ") }
      self:expr(node.left)
      if(node.right != null){
        self:add(" = ")
        self:expr(node.right)
      }
    }
  } else if(t == "If"){
    self:add("if(")
    self:expr(node.condition)
    self:add(")")
    self:statement(node.thenBranch)
    if(node.elseBranch != null){
      self:add(" else ")
      self:statement(node.elseBranch)
    }
  } else if(t == "For"){
    if(node.label != null){
      self:add(concat(":", node.label, ": "))
    }
    self:add("for(")
    if(node.init == null and node.update == null){
      self:expr(node.condition)
    } else {
      if(node.init != null){ self:statement(node.init) }
      self:add("; ")
      self:expr(node.condition)
      self:add(";")
      if(node.update != null){
        self:add(" ")
        self:statement(node.update)
      }
    }
    self:add(")")
    self:statement(node.body)
  } else if(t == "ForIn"){
    if(node.label != null){
      self:add(concat(":", node.label, ": "))
    }
    self:add("for(let ")
    self:pattern(node.pattern)
    self:add(" in ")
    self:expr(node.itterator)
    self:add(")")
    self:statement(node.body)
  } else if(t == "LetStat"){
    self:add("let ")
    self:pattern(node.pattern)
    self:add(" = ")
    self:expr(node.right)
  } else if(t == "Try"){
    self:add("try ")
    self:block(node.body)
    for(let local c in values(node.catches)){
      self:add(" catch")
      if(c.pattern != null){
        self:add("(")
        self:pattern(c.pattern)
        self:add(")")
      }
      self:add(" ")
      self:block(c.body)
    }
  } else if(t == "Defer"){
    self:add("defer ")
    self:block(node.body)
  } else if(t == "Throw"){
    self:add("raise(")
    self:expr(node.value)
    self:add(")")
  } else if(t == "Unquote"){
    self:quoted("-{", node)
  } else {
    error("to_source: not a statement: ", t)
  }
}

// to_source(node: Node) -> string
// slang source for a tree, ending with a newline: what a file looks like
// once its extensions have been applied (every extension lowers to the
// core AST). Parsing the result gives the same bytecode again. A Block at
// the top is printed as a chunk (no braces); a statement or an expression
// as itself, with parentheses only where precedence needs them.
func ast.to_source(node){
  local w = source.new()
  if(node.type == "Block"){
    w:statements(node.statements, null)
  } else if(str.ends_with(node.type, "Pattern")){
    w:pattern(node)
  } else if(ast.is_statement(node)){
    w:statement(node)
  } else {
    w:expr(node)
  }
  return concat(str.join(w.parts, ""), "\n")
}

return ast
