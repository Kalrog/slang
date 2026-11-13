// What the engine and the built-ins do with terms while a program runs:
// following variable bindings, copying, the standard order of terms,
// lists, and Prolog's error terms.
//
// Terms can be deep: a list of 100000 elements is a chain of 100000 '.'
// cells. So the walks here never recurse along a list's tail: they either
// keep an explicit stack (vars_of, compare) or loop along the list spine
// (rebuild).
local ast = require("ast")
local str = require("slang/string")

local M = {}

// deref(t) -> the term t stands for: bound variables are followed to what
// they are bound to, so the result is an unbound Var or a non-variable
func M.deref(t){
  for(type(t) == "Var" and t.ref != null){
    t = t.ref
  }
  return t
}

// is_list_cell(t) -> whether t is a list cell '.'(Head, Tail)
func M.is_list_cell(t) => type(t) == "Compound" and t.name == "."
  and len(t.arguments) == 2

func M.is_nil(t) => type(t) == "Atom" and t.name == "[]"

// is_callable(t) -> whether t can be a goal (an atom or a compound)
func M.is_callable(t) => type(t) == "Atom" or type(t) == "Compound"

func M.is_atomic(t) => type(t) == "Atom" or type(t) == "Integer"
  or type(t) == "Float" or type(t) == "String"

func M.is_number(t) => type(t) == "Integer" or type(t) == "Float"

// arguments(t) -> the arguments of a callable term ({} for an atom)
func M.arguments(t){
  if(type(t) == "Compound"){
    return t.arguments
  }
  return {}
}

// key(t) -> "name/arity" of a callable term: how predicates are named
func M.key(t) => concat(t.name, "/", len(M.arguments(t)))

// indicator(t) -> the term name/arity of a callable term, for errors
func M.indicator(t) => ast.compound("/", {
  ast.atom(t.name), ast.integer(len(M.arguments(t))),
})

// ---------------------------------------------------------------- rebuilding

// rebuild(t, leaf) -> a copy of t, following bound variables, in which
// every subterm that is not a compound is replaced by leaf(x): an unbound
// Var, a Slot, a reader Variable, an atom or a number. What leaf returns is
// taken as it is. copy_term, renaming clauses apart, compiling clauses and
// turning reader terms into runtime terms are all rebuilds with a
// different leaf.
func M.rebuild(t, leaf){
  t = M.deref(t)
  if(type(t) != "Compound"){
    return leaf(t)
  }
  if(not M.is_list_cell(t)){
    local args = {}
    for(let local a in values(t.arguments)){
      append(args, M.rebuild(a, leaf))
    }
    return ast.compound(t.name, args)
  }
  // a list: walk its spine in a loop, rebuilding the elements in order,
  // then put the cells back together from the end
  local heads = {}
  for(M.is_list_cell(t)){
    append(heads, M.rebuild(t.arguments[0], leaf))
    t = M.deref(t.arguments[1])
  }
  local out = M.rebuild(t, leaf)
  for(local i = len(heads) - 1; i >= 0; i = i - 1){
    out = ast.compound(".", {heads[i], out})
  }
  return out
}

// copy(t, fresh?) -> t with every unbound variable replaced by a new one
// (the same new one for every occurrence of a variable): copy_term/2.
// fresh maps variable ids to their copies; pass one to share it between
// copies.
func M.copy(t, fresh){
  fresh = fresh or {}
  return M.rebuild(t, func(x){
    if(type(x) == "Var"){
      local v = fresh[x.id]
      if(v == null){
        v = ast.var()
        fresh[x.id] = v
      }
      return v
    }
    return x
  })
}

// resolve(t) -> t with all bound variables replaced by their values (the
// unbound ones stay as they are): an answer to show or keep
func M.resolve(t) => M.rebuild(t, func(x) => x)

// Names of the variables of a term read from text: the reader's
// Variable{name} nodes become Vars, the same Var for the same name.
// vars maps names to Vars and order lists the names as they first appear.
func M.new_names() => {vars: {}, order: {}}

// from_source(t, names) -> the runtime term of a term the reader produced
func M.from_source(t, names){
  return M.rebuild(t, func(x){
    if(type(x) != "Variable"){
      return x
    }
    // every _ is a variable of its own
    if(x.name == "_"){
      return ast.var("_")
    }
    local v = names.vars[x.name]
    if(v == null){
      v = ast.var(x.name)
      names.vars[x.name] = v
      append(names.order, x.name)
    }
    return v
  })
}

// --------------------------------------------------------------- inspection

// vars_of(t) -> the unbound variables of t, each once, left to right
func M.vars_of(t){
  local out = {}
  local seen = {}
  local stack = {t}
  for(len(stack) > 0){
    local x = M.deref(remove(stack, len(stack) - 1))
    if(type(x) == "Var"){
      if(not seen[x.id]){
        seen[x.id] = true
        append(out, x)
      }
    } else if(type(x) == "Compound"){
      // pushed last to first, so that the first argument is taken first
      for(local i = len(x.arguments) - 1; i >= 0; i = i - 1){
        append(stack, x.arguments[i])
      }
    }
  }
  return out
}

func M.is_ground(t) => len(M.vars_of(t)) == 0

// The standard order of terms: Var < Number < Atom < String < Compound.
local RANK = {Var: 0, Float: 1, Integer: 1, Atom: 2, String: 3, Compound: 4}

local func sign(n){
  if(n < 0){
    return -1
  }
  if(n > 0){
    return 1
  }
  return 0
}

// compare two terms that are not compounds, or two compounds by their
// arity and name only
local func compare_node(a, b){
  local ra = RANK[type(a)]
  local rb = RANK[type(b)]
  if(ra != rb){
    return sign(ra - rb)
  }
  if(type(a) == "Var"){
    return sign(a.id - b.id)
  }
  if(M.is_number(a)){
    if(a.value < b.value){
      return -1
    }
    if(a.value > b.value){
      return 1
    }
    // equal values: a float comes before an integer (1.0 @< 1)
    if(type(a) == type(b)){
      return 0
    }
    if(type(a) == "Float"){
      return -1
    }
    return 1
  }
  if(type(a) == "Atom"){
    return str.compare(a.name, b.name)
  }
  if(type(a) == "String"){
    return str.compare(a.value, b.value)
  }
  // compounds: by arity, then by name; the caller compares the arguments
  local d = len(a.arguments) - len(b.arguments)
  if(d != 0){
    return sign(d)
  }
  return str.compare(a.name, b.name)
}

// compare(a, b) -> -1, 0 or 1 in the standard order of terms; 0 means
// identical (==)
func M.compare(a, b){
  local stack = {a, b}
  for(len(stack) > 0){
    local y = M.deref(remove(stack, len(stack) - 1))
    local x = M.deref(remove(stack, len(stack) - 1))
    local c = compare_node(x, y)
    if(c != 0){
      return c
    }
    if(type(x) == "Compound"){
      for(local i = len(x.arguments) - 1; i >= 0; i = i - 1){
        append(stack, x.arguments[i])
        append(stack, y.arguments[i])
      }
    }
  }
  return 0
}

// ---------------------------------------------------------------------- lists

// list_to_array(t) -> the elements of the proper list t, or null when t is
// not one (a partial list ending in a variable, or no list at all)
func M.list_to_array(t){
  local items = {}
  t = M.deref(t)
  for(M.is_list_cell(t)){
    append(items, t.arguments[0])
    t = M.deref(t.arguments[1])
  }
  if(not M.is_nil(t)){
    return null
  }
  return items
}

// array_to_list(items, tail?) -> the list of items (ending in tail, [] by
// default)
func M.array_to_list(items, tail) => ast.list(items, tail)

// --------------------------------------------------------------------- errors

// Built-ins report errors by throwing Prolog terms, as ISO says:
// error(type_error(integer, foo), Context). A thrown term travels as a
// slang error of kind "prolog" with the term in its ball field; the engine
// turns it back into a Prolog throw that catch/3 can catch.

// throw(ball) raises the term ball as a Prolog exception
func M.throw(ball){
  raise(error.new("prolog", "Prolog exception", {ball: ball}))
}

local func atom(name) => ast.atom(name)

local func throw_error(formal){
  M.throw(ast.compound("error", {formal, ast.var()}))
}

func M.instantiation_error() => throw_error(atom("instantiation_error"))

func M.type_error(expected, culprit) => throw_error(ast.compound(
  "type_error", {atom(expected), culprit},
))

func M.domain_error(domain, culprit) => throw_error(ast.compound(
  "domain_error", {atom(domain), culprit},
))

func M.existence_error(kind, culprit) => throw_error(ast.compound(
  "existence_error", {atom(kind), culprit},
))

func M.permission_error(action, kind, culprit) => throw_error(ast.compound(
  "permission_error", {atom(action), atom(kind), culprit},
))

func M.evaluation_error(what) => throw_error(ast.compound(
  "evaluation_error", {atom(what)},
))

func M.representation_error(what) => throw_error(ast.compound(
  "representation_error", {atom(what)},
))

// ------------------------------------------------------------ checked access

// The built-ins take their arguments apart with these: each derefs and
// either returns the value or throws the error ISO prescribes.

// callable(t) -> t when it is a goal; a variable is an instantiation error,
// anything else a type error
func M.callable(t){
  t = M.deref(t)
  if(type(t) == "Var"){
    M.instantiation_error()
  }
  if(not M.is_callable(t)){
    M.type_error("callable", t)
  }
  return t
}

// integer_value(t) -> the int of an Integer
func M.integer_value(t){
  t = M.deref(t)
  if(type(t) == "Var"){
    M.instantiation_error()
  }
  if(type(t) != "Integer"){
    M.type_error("integer", t)
  }
  return t.value
}

// atom_name(t) -> the name of an Atom
func M.atom_name(t){
  t = M.deref(t)
  if(type(t) == "Var"){
    M.instantiation_error()
  }
  if(type(t) != "Atom"){
    M.type_error("atom", t)
  }
  return t.name
}

// text_of(t) -> the text of an atom, string or number (atom_length/2,
// atom_codes/2 and friends accept all three)
func M.text_of(t){
  t = M.deref(t)
  if(type(t) == "Var"){
    M.instantiation_error()
  }
  if(type(t) == "Atom"){
    return t.name
  }
  if(type(t) == "String"){
    return t.value
  }
  if(M.is_number(t)){
    return concat("", t.value)
  }
  M.type_error("atomic", t)
}

// array(t) -> the elements of the proper list t; a partial list is an
// instantiation error, anything else a type error
func M.array(t){
  local items = M.list_to_array(t)
  if(items == null){
    local d = M.deref(t)
    local end = d
    for(M.is_list_cell(end)){
      end = M.deref(end.arguments[1])
    }
    if(type(end) == "Var"){
      M.instantiation_error()
    }
    M.type_error("list", d)
  }
  return items
}

return M
