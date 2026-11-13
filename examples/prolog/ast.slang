// The terms of a Prolog program. Everything the reader produces is one of
// these nodes; operators are not special in the tree: `a + b` is the
// compound +(a, b), a list [a | T] is '.'(a, T) and {a} is '{}'(a), so a
// later stage (unification, clause storage) only has to know these types.
// Each kind of node is its own type: type(t) is "Atom", "Variable",
// "Integer", "Float", "String" or "Compound" (capitalised, so that they are
// not taken for slang's own "string" or "int"), and patterns match on it:
// let 'Atom{name: "foo"} = t.
//
// Two more types only exist while a program runs (see engine.slang):
//   Var{ref, id, name}: a logic variable. ref is null while it is unbound
//     and the term it is bound to after; id orders variables (standard
//     order) and names them when printed (_123).
//   Slot{index}: a variable of a stored clause, numbered 0..n-1, replaced
//     by a fresh Var each time the clause is used (renaming apart).
local str = require("slang/string")

local M = {}

local Primitive = {}
Primitive.__index = Primitive

func Primitive.new(class, t) => {
  type: t,
  @meta: class,
}

func Primitive.__call(self, v) => type(v) == self.type

func Primitive.__string(self) => concat("Type: ", self.type)

local func is_type(t) => Primitive:new(t)

local func field(name, t){
  if(type(t) == "string"){
    t = is_type(t)
  }
  return {name: name, type: t}
}

local NODE_DEFS = {
  Atom: {field("name", "string")},
  Variable: {field("name", "string")},
  Integer: {field("value", "int")},
  Float: {field("value", "double")},
  String: {field("value", "string")},
  // name(arguments...): the functor is name/len(arguments); a compound
  // has at least one argument (name/0 is the atom)
  Compound: {
    field("name", "string"),
    field("arguments", "table"),
  },
}

local func counted(next){
  local n = -1
  return func(){
    local v = next()
    if(same(v, stop)){
      return stop
    }
    n = n + 1
    return {n, v}
  }
}

local func zip(nextA, nextB){
  return func(){
    local a = nextA()
    local b = nextB()
    if(same(a, stop) or same(b, stop)){
      return stop
    }
    return {a, b}
  }
}

local func _check_args(typedef, args){
  if(len(args) != len(typedef)){
    raise(error.new(error.kinds.argument, concat(
      "expected ", len(typedef), " arguments, got ", len(args)
    )))
  }
  local node = {}
  for(let {local arg?, {name: local name, type: local t}} in zip(
    values(args), values(typedef)
  )){
    if(not t(arg)){
      raise(error.new(error.kinds.argument, concat(
        "argument ", name, " has value ", arg, " which is not ", t
      )))
    }
    node[name] = arg
  }
  return node
}

// the metatable of every node type, by type name: M.types.Atom, ...
M.types = {}
for(let local name in values({
  "Atom", "Variable", "Integer", "Float", "String", "Compound", "Var", "Slot",
})){
  local meta = {__type: name}
  meta.__index = meta
  M.types[name] = meta
}

// node(type: string, ...fields) -> a node of that type ("Atom", ...), its
// fields checked against the type's definition
func M.node(type, ...args){
  try {
    local typedef = NODE_DEFS[type]
    if(not typedef){
      raise(error.new(
        error.kinds.argument,
        concat(type, " is not a known ast node type"),
      ))
    }

    local node = _check_args(typedef, args)
    node.@meta = M.types[type]
    return node
  } catch(local e) {
    raise(error.wrap(e, concat("failed to build ast node ", type)))
  }
}

// The constructors below skip node()'s checks: the running program builds
// terms all the time (every clause it uses is copied), and these are
// called with values of the right types by construction.
local func make(type_name, fields){
  fields.@meta = M.types[type_name]
  return fields
}

func M.atom(name) => make("Atom", {name: name})
func M.variable(name) => make("Variable", {name: name})
func M.integer(value) => make("Integer", {value: value})
func M.float(value) => make("Float", {value: value})
func M.string(value) => make("String", {value: value})

// compound(name, arguments) -> the compound, or the atom when arguments is
// empty
func M.compound(name, arguments){
  if(len(arguments) == 0){
    return M.atom(name)
  }
  return make("Compound", {name: name, arguments: arguments})
}

// number(v: int | double) -> an Integer or a Float, by v's slang type
func M.number(v){
  if(type(v) == "int"){
    return M.integer(v)
  }
  return M.float(v)
}

local var_count = 0

// var(name?: string) -> a fresh unbound Var; name is only for printing
func M.var(name){
  var_count = var_count + 1
  return make("Var", {ref: null, id: var_count, name: name})
}

// newest_var_id() -> the id of the newest Var so far: every Var made later
// has a larger id
func M.newest_var_id() => var_count

func M.slot(index) => make("Slot", {index: index})

// list(items, tail?) -> '.'(item0, '.'(item1, ... tail)); tail is [] when
// not given
func M.list(items, tail){
  local out = tail or M.atom("[]")
  for(local i = len(items) - 1; i >= 0; i = i - 1){
    out = M.compound(".", {items[i], out})
  }
  return out
}

// ------------------------------------------------------------ canonical text

local SYMBOL_CHARS = "+-*/\\^<>=~:.?@#&$"

local func is_lower(b) => b >= 'a' and b <= 'z'

local func is_alnum(b) => is_lower(b) or (b >= 'A' and b <= 'Z')
  or (b >= '0' and b <= '9') or b == '_'

local SYMBOL_SET = {}
for(local i = 0; i < len(SYMBOL_CHARS); i = i + 1){
  SYMBOL_SET[str.byte_at(SYMBOL_CHARS, i)] = true
}

local func is_symbol(b) => SYMBOL_SET[b] == true

// is_symbol_char(b: int?) -> bool: b is one of the bytes symbol atoms
// such as =.. or :- are made of
func M.is_symbol_char(b) => b != null and is_symbol(b)

// an atom that reads back as itself without quotes
local func plain_atom(name){
  local n = len(name)
  if(n == 0){
    return false
  }
  if(name == "[]" or name == "{}" or name == "!" or name == ";"){
    return true
  }
  local b = str.byte_at(name, 0)
  if(is_lower(b)){
    for(local i = 1; i < n; i = i + 1){
      if(not is_alnum(str.byte_at(name, i))){
        return false
      }
    }
    return true
  }
  for(local i = 0; i < n; i = i + 1){
    if(not is_symbol(str.byte_at(name, i))){
      return false
    }
  }
  return true
}

local func quote(text, q){
  local out = q
  local n = len(text)
  local start = 0
  for(local i = 0; i < n; i = i + 1){
    local b = str.byte_at(text, i)
    local esc = null
    if(b == 92){
      esc = "\\\\"
    } else if(b == str.byte_at(q, 0)){
      esc = concat("\\", q)
    } else if(b == '\n'){
      esc = "\\n"
    } else if(b == '\t'){
      esc = "\\t"
    }
    if(esc != null){
      out = concat(out, str.substring(text, start, i), esc)
      start = i + 1
    }
  }
  return concat(out, str.substring(text, start, n), q)
}

local func atom_text(name){
  if(plain_atom(name)){
    return name
  }
  return quote(name, "'")
}

// atom_text(name) -> the atom as it is written quoted: as is when it reads
// back as itself, else in single quotes
func M.atom_text(name) => atom_text(name)

// quote(text, q: "'" | "\"") -> text in quotes q, with escapes
func M.quote(text, q) => quote(text, q)

// canonical(term) -> string: the term in functional notation, like
// write_canonical: no operators, quoted atoms where needed, lists as [...]
func M.canonical(t){
  if(type(t) == "Atom"){
    return atom_text(t.name)
  }
  if(type(t) == "Variable"){
    return t.name
  }
  if(type(t) == "Integer" or type(t) == "Float"){
    return concat("", t.value)
  }
  if(type(t) == "String"){
    return quote(t.value, "\"")
  }
  if(t.name == "." and len(t.arguments) == 2){
    local out = "["
    local first = true
    for(type(t) == "Compound" and t.name == "." and len(t.arguments) == 2){
      if(not first){
        out = concat(out, ",")
      }
      first = false
      out = concat(out, M.canonical(t.arguments[0]))
      t = t.arguments[1]
    }
    if(not (type(t) == "Atom" and t.name == "[]")){
      out = concat(out, "|", M.canonical(t))
    }
    return concat(out, "]")
  }
  local out = concat(atom_text(t.name), "(")
  local n = len(t.arguments)
  for(local i = 0; i < n; i = i + 1){
    if(i > 0){
      out = concat(out, ",")
    }
    out = concat(out, M.canonical(t.arguments[i]))
  }
  return concat(out, ")")
}

return M
