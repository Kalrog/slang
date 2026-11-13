// The built-in predicates written in slang. Each is a function
// func(query, args) -> bool: true for success (with its bindings made
// through query:unify), false for failure; errors are thrown as Prolog
// terms (see terms.slang). A built-in with several answers proves the
// first and leaves the others as alternatives (query:push_alternatives),
// and one that goes on in Prolog pushes a goal (query:push_goal).
//
// What is easier to read in Prolog itself (lists, between/3, retract/1,
// length/2, ...) is in prelude.pl instead.
local ast = require("ast")
local terms = require("terms")
local arith = require("arith")
local compile = require("compile")
local engine = require("engine")
local writer = require("writer")
local grammar = require("grammar")
local str = require("slang/string")
local utf8 = require("slang/utf8")
local tbl = require("slang/table")
local os = require("slang/os")
local time = require("slang/time")

local M = {}

local deref = terms.deref
local atom = ast.atom
local integer = ast.integer

local func compound(name, args) => ast.compound(name, args)

local func is_compound(t, name, arity) => type(t) == "Compound"
  and t.name == name and len(t.arguments) == arity

local func list(items, tail) => terms.array_to_list(items, tail)

local func equals(a, b) => compound("=", {a, b})

local func both(a, b) => compound(",", {a, b})

// the built-ins: "name/arity" -> func(q, args) -> bool
local B = {}

local func def(name, arity, f){
  B[concat(name, "/", arity)] = f
}

// install(db) adds the built-ins to a database
func M.install(db){
  for(let {local key, local f} in entries(B)){
    db.builtins[key] = f
  }
}

// ------------------------------------------------------------------ type tests

local func type_test(name, test){
  def(name, 1, func(q, args) => test(deref(args[0])))
}

type_test("var", func(t) => type(t) == "Var")
type_test("nonvar", func(t) => type(t) != "Var")
type_test("atom", func(t) => type(t) == "Atom")
type_test("number", func(t) => terms.is_number(t))
type_test("integer", func(t) => type(t) == "Integer")
type_test("float", func(t) => type(t) == "Float")
type_test("atomic", func(t) => terms.is_atomic(t))
type_test("compound", func(t) => type(t) == "Compound")
type_test("callable", func(t) => terms.is_callable(t))
type_test("string", func(t) => type(t) == "String")
type_test("is_list", func(t) => terms.list_to_array(t) != null)
type_test("ground", func(t) => terms.is_ground(t))

// ------------------------------------------------------- unification, order

def("=", 2, func(q, args) => q:unify(args[0], args[1]))

// \= succeeds when unification fails, and never leaves bindings
def("\\=", 2, func(q, args){
  local mark = len(q.trail)
  local ok = q:unify(args[0], args[1])
  q:undo_to(mark)
  return not ok
})

def("unify_with_occurs_check", 2, func(q, args) => q:unify(
  args[0], args[1], true,
))

local func order(name, test){
  def(name, 2, func(q, args) => test(terms.compare(args[0], args[1])))
}

order("==", func(c) => c == 0)
order("\\==", func(c) => c != 0)
order("@<", func(c) => c < 0)
order("@>", func(c) => c > 0)
order("@=<", func(c) => c <= 0)
order("@>=", func(c) => c >= 0)

local func order_atom(c){
  if(c < 0){
    return atom("<")
  }
  if(c > 0){
    return atom(">")
  }
  return atom("=")
}

def("compare", 3, func(q, args) => q:unify(
  args[0], order_atom(terms.compare(args[1], args[2])),
))

// ----------------------------------------------------------------- arithmetic

def("is", 2, func(q, args) => q:unify(
  args[0], ast.number(arith.eval(args[1])),
))

local func numeric(name, test){
  def(name, 2, func(q, args) => test(arith.compare(args[0], args[1])))
}

numeric("=:=", func(c) => c == 0)
numeric("=\\=", func(c) => c != 0)
numeric("<", func(c) => c < 0)
numeric(">", func(c) => c > 0)
numeric("=<", func(c) => c <= 0)
numeric(">=", func(c) => c >= 0)

def("succ", 2, func(q, args){
  local x = deref(args[0])
  if(type(x) == "Integer"){
    if(x.value < 0){
      terms.type_error("not_less_than_zero", x)
    }
    return q:unify(args[1], integer(x.value + 1))
  }
  local y = terms.integer_value(args[1])
  if(y <= 0){
    return false
  }
  return q:unify(x, integer(y - 1))
})

def("plus", 3, func(q, args){
  local x = deref(args[0])
  local y = deref(args[1])
  if(type(x) != "Var" and type(y) != "Var"){
    return q:unify(args[2], integer(terms.integer_value(x) + terms.integer_value(y)))
  }
  local z = terms.integer_value(args[2])
  if(type(x) == "Var"){
    return q:unify(x, integer(z - terms.integer_value(y)))
  }
  return q:unify(y, integer(z - terms.integer_value(x)))
})

// -------------------------------------------------------- building terms

// fresh(n) -> n new variables
local func fresh(n){
  local vars = {}
  for(local i = 0; i < n; i = i + 1){
    append(vars, ast.var())
  }
  return vars
}

def("functor", 3, func(q, args){
  local t = deref(args[0])
  if(type(t) != "Var"){
    if(type(t) == "Compound"){
      return q:unify(args[1], atom(t.name))
        and q:unify(args[2], integer(len(t.arguments)))
    }
    return q:unify(args[1], t) and q:unify(args[2], integer(0))
  }
  local name = deref(args[1])
  local n = terms.integer_value(args[2])
  if(type(name) == "Var"){
    terms.instantiation_error()
  }
  if(n == 0){
    if(not terms.is_atomic(name)){
      terms.type_error("atomic", name)
    }
    return q:unify(t, name)
  }
  if(type(name) != "Atom"){
    terms.type_error("atom", name)
  }
  return q:unify(t, compound(name.name, fresh(n)))
})

def("arg", 3, func(q, args){
  local t = deref(args[1])
  if(type(t) != "Compound"){
    terms.type_error("compound", t)
  }
  local n = deref(args[0])
  if(type(n) == "Var"){
    // every argument, one after the other
    local alternatives = {}
    for(local i = 0; i < len(t.arguments); i = i + 1){
      append(alternatives, both(equals(n, integer(i + 1)),
        equals(args[2], t.arguments[i])))
    }
    return q:push_alternatives(alternatives)
  }
  local i = terms.integer_value(n)
  if(i < 1 or i > len(t.arguments)){
    return false
  }
  return q:unify(args[2], t.arguments[i - 1])
})

// T =.. [Name | Args]
def("=..", 2, func(q, args){
  local t = deref(args[0])
  if(type(t) == "Compound"){
    return q:unify(args[1], list({atom(t.name)}, list(t.arguments)))
  }
  if(type(t) != "Var"){
    return q:unify(args[1], list({t}))
  }
  local items = terms.array(args[1])
  if(len(items) == 0){
    terms.domain_error("non_empty_list", atom("[]"))
  }
  local name = deref(items[0])
  if(len(items) == 1){
    return q:unify(t, name)
  }
  if(type(name) == "Var"){
    terms.instantiation_error()
  }
  if(type(name) != "Atom"){
    terms.type_error("atom", name)
  }
  local rest = {}
  for(local i = 1; i < len(items); i = i + 1){
    append(rest, items[i])
  }
  return q:unify(t, compound(name.name, rest))
})

def("copy_term", 2, func(q, args) => q:unify(args[1], terms.copy(args[0])))

def("term_variables", 2, func(q, args) => q:unify(
  args[1], list(terms.vars_of(args[0])),
))

// -------------------------------------------------------- atoms and strings

// the characters of text, each a string
local func chars_of(text){
  local out = {}
  local i = 0
  for(i < len(text)){
    local n = utf8.size_at(text, i)
    append(out, str.substring(text, i, i + n))
    i = i + n
  }
  return out
}

local func code_of(char) => utf8.code_at(char, 0)

// text_of_list(t) -> the text of a list of character codes or of
// one-character atoms
local func text_of_list(t){
  local parts = {}
  for(let local item in values(terms.array(t))){
    item = deref(item)
    if(type(item) == "Integer"){
      append(parts, utf8.char(item.value))
    } else if(type(item) == "Atom"){
      append(parts, item.name)
    } else if(type(item) == "Var"){
      terms.instantiation_error()
    } else {
      terms.type_error("character_code", item)
    }
  }
  return str.join(parts, "")
}

local func codes_list(text){
  local items = {}
  for(let local c in values(chars_of(text))){
    append(items, integer(code_of(c)))
  }
  return list(items)
}

local func chars_list(text){
  local items = {}
  for(let local c in values(chars_of(text))){
    append(items, atom(c))
  }
  return list(items)
}

// parse_term(q, text) -> the term text reads as (with the database's
// operators), or null when it does not read
local func parse_term(q, text){
  local src = grammar.source(concat(text, " ."))
  local r = grammar.read_clause(src, q.db.ops)
  if(r == null or r.error != null){
    return null
  }
  return terms.from_source(r.term, terms.new_names())
}

// number_of_text(q, text) -> the Integer or Float text is, or null
local func number_of_text(q, text){
  local t = parse_term(q, text)
  if(t == null or not terms.is_number(t)){
    return null
  }
  return t
}

// A conversion between a term and a list: atom_codes(A, L) and friends.
// When the term is known, the list is made from it; else the term is made
// from the list.
local func conversion(name, to_list, from_text){
  def(name, 2, func(q, args){
    local t = deref(args[0])
    if(type(t) != "Var"){
      return q:unify(args[1], to_list(terms.text_of(t)))
    }
    local made = from_text(q, text_of_list(args[1]))
    if(made == null){
      return false
    }
    return q:unify(t, made)
  })
}

local func as_atom(q, text) => atom(text)
local func as_string(q, text) => ast.string(text)

local func as_number(q, text){
  local n = number_of_text(q, text)
  if(n == null){
    terms.throw(compound("error", {
      compound("syntax_error", {atom("illegal_number")}), ast.var(),
    }))
  }
  return n
}

conversion("atom_codes", codes_list, as_atom)
conversion("atom_chars", chars_list, as_atom)
conversion("number_codes", codes_list, as_number)
conversion("number_chars", chars_list, as_number)
conversion("string_codes", codes_list, as_string)
conversion("string_chars", chars_list, as_string)

// char_code(Char, Code) the other way round: from the code
def("char_code", 2, func(q, args){
  local c = deref(args[0])
  if(type(c) == "Atom"){
    return q:unify(args[1], integer(code_of(c.name)))
  }
  return q:unify(c, atom(utf8.char(terms.integer_value(args[1]))))
})

def("atom_length", 2, func(q, args) => q:unify(
  args[1], integer(len(chars_of(terms.text_of(args[0])))),
))
def("string_length", 2, func(q, args) => q:unify(
  args[1], integer(len(chars_of(terms.text_of(args[0])))),
))

def("atom_number", 2, func(q, args){
  local a = deref(args[0])
  if(type(a) == "Var"){
    local n = deref(args[1])
    if(type(n) == "Var"){
      terms.instantiation_error()
    }
    return q:unify(a, atom(terms.text_of(n)))
  }
  local n = number_of_text(q, terms.atom_name(a))
  return n != null and q:unify(args[1], n)
})

def("number_string", 2, func(q, args){
  local s = deref(args[1])
  if(type(s) == "Var"){
    return q:unify(s, ast.string(terms.text_of(args[0])))
  }
  local n = number_of_text(q, str.trim(terms.text_of(s)))
  return n != null and q:unify(args[0], n)
})

def("atom_string", 2, func(q, args){
  local a = deref(args[0])
  if(type(a) == "Var"){
    return q:unify(a, atom(terms.text_of(args[1])))
  }
  return q:unify(args[1], ast.string(terms.text_of(a)))
})

def("string_to_atom", 2, func(q, args){
  local s = deref(args[0])
  if(type(s) == "Var"){
    return q:unify(s, ast.string(terms.text_of(args[1])))
  }
  return q:unify(args[1], atom(terms.text_of(s)))
})

def("string", 1, func(q, args) => type(deref(args[0])) == "String")

def("upcase_atom", 2, func(q, args) => q:unify(
  args[1], atom(str.upper(terms.text_of(args[0]))),
))
def("downcase_atom", 2, func(q, args) => q:unify(
  args[1], atom(str.lower(terms.text_of(args[0]))),
))
def("string_upper", 2, func(q, args) => q:unify(
  args[1], ast.string(str.upper(terms.text_of(args[0]))),
))
def("string_lower", 2, func(q, args) => q:unify(
  args[1], ast.string(str.lower(terms.text_of(args[0]))),
))

// concatenation of two texts; with the whole known and a part unknown,
// every way of splitting the whole
local func concatenation(make){
  return func(q, args){
    local a = deref(args[0])
    local b = deref(args[1])
    if(type(a) != "Var" and type(b) != "Var"){
      return q:unify(args[2], make(concat(terms.text_of(a), terms.text_of(b))))
    }
    local chars = chars_of(terms.text_of(args[2]))
    local alternatives = {}
    for(local i = 0; i <= len(chars); i = i + 1){
      local front = {}
      local back = {}
      for(local k = 0; k < len(chars); k = k + 1){
        if(k < i){
          append(front, chars[k])
        } else {
          append(back, chars[k])
        }
      }
      append(alternatives, both(equals(a, make(str.join(front, ""))),
        equals(b, make(str.join(back, "")))))
    }
    return q:push_alternatives(alternatives)
  }
}

def("atom_concat", 3, concatenation(atom))
def("string_concat", 3, concatenation(ast.string))

// sub_atom(Atom, Before, Length, After, Sub): Sub is the part of Atom after
// Before characters, Length long, with After characters after it
local func sub_text(make){
  return func(q, args){
    local chars = chars_of(terms.text_of(args[0]))
    local n = len(chars)
    local sub = deref(args[4])
    local alternatives = {}
    local func candidate(b, l){
      local part = {}
      for(local k = b; k < b + l; k = k + 1){
        append(part, chars[k])
      }
      append(alternatives, both(
        both(equals(args[1], integer(b)), equals(args[2], integer(l))),
        both(equals(args[3], integer(n - b - l)),
          equals(sub, make(str.join(part, "")))),
      ))
    }
    if(type(sub) != "Var"){
      // only the places where Sub occurs
      local want = chars_of(terms.text_of(sub))
      local l = len(want)
      for(local b = 0; b + l <= n; b = b + 1){
        local found = true
        for(local k = 0; k < l; k = k + 1){
          if(chars[b + k] != want[k]){
            found = false
            break
          }
        }
        if(found){
          candidate(b, l)
        }
      }
    } else {
      for(local b = 0; b <= n; b = b + 1){
        for(local l = 0; b + l <= n; l = l + 1){
          candidate(b, l)
        }
      }
    }
    return q:push_alternatives(alternatives)
  }
}

def("sub_atom", 5, sub_text(atom))
def("sub_string", 5, sub_text(ast.string))

// atomic_list_concat(List, Separator, Atom): join, or split when Atom is
// known and List is not
local func atomic_list_concat(q, items_term, sep, result){
  local items = terms.list_to_array(items_term)
  local ground = items != null
  if(ground){
    for(let local item in values(items)){
      if(type(deref(item)) == "Var"){
        ground = false
      }
    }
  }
  if(ground){
    local parts = {}
    for(let local item in values(items)){
      append(parts, terms.text_of(item))
    }
    return q:unify(result, atom(str.join(parts, sep)))
  }
  if(sep == ""){
    terms.instantiation_error()
  }
  local pieces = {}
  for(let local piece in values(str.split(terms.text_of(result), sep))){
    append(pieces, atom(piece))
  }
  return q:unify(items_term, list(pieces))
}

def("atomic_list_concat", 2, func(q, args) => atomic_list_concat(
  q, args[0], "", args[1],
))
def("atomic_list_concat", 3, func(q, args) => atomic_list_concat(
  q, args[0], terms.text_of(args[1]), args[2],
))

// split_string(String, SepChars, PadChars, Parts)
def("split_string", 4, func(q, args){
  local text = terms.text_of(args[0])
  local seps = chars_of(terms.text_of(args[1]))
  local pad = chars_of(terms.text_of(args[2]))
  local func member(c, set){
    for(let local x in values(set)){
      if(x == c){
        return true
      }
    }
    return false
  }
  local func strip(chars){
    local a = 0
    local b = len(chars)
    for(a < b and member(chars[a], pad)){
      a = a + 1
    }
    for(b > a and member(chars[b - 1], pad)){
      b = b - 1
    }
    local out = {}
    for(local i = a; i < b; i = i + 1){
      append(out, chars[i])
    }
    return ast.string(str.join(out, ""))
  }
  local parts = {}
  local current = {}
  for(let local c in values(chars_of(text))){
    if(member(c, seps)){
      append(parts, strip(current))
      current = {}
    } else {
      append(current, c)
    }
  }
  append(parts, strip(current))
  return q:unify(args[3], list(parts))
})

def("term_to_atom", 2, func(q, args){
  local t = deref(args[0])
  local a = deref(args[1])
  if(type(a) != "Var"){
    local parsed = parse_term(q, terms.text_of(a))
    if(parsed == null){
      terms.throw(compound("error", {
        compound("syntax_error", {atom("cannot_parse")}), ast.var(),
      }))
    }
    return q:unify(t, parsed)
  }
  return q:unify(a, atom(writer.format(t, {quoted: true, ops: q.db.ops})))
})

def("term_string", 2, func(q, args){
  local s = deref(args[1])
  if(type(s) != "Var"){
    local parsed = parse_term(q, terms.text_of(s))
    return parsed != null and q:unify(args[0], parsed)
  }
  return q:unify(s, ast.string(writer.format(args[0], {
    quoted: true, ops: q.db.ops,
  })))
})

// ----------------------------------------------------------------- sorting

// sorted(items, cmp) -> items sorted by cmp(a, b) -> -1/0/1, keeping
// equal items in their order (stable)
local func sorted(items, cmp){
  local decorated = {}
  for(local i = 0; i < len(items); i = i + 1){
    append(decorated, {item: items[i], index: i})
  }
  tbl.sort(decorated, func(a, b){
    local c = cmp(a.item, b.item)
    if(c != 0){
      return c < 0
    }
    return a.index < b.index
  })
  local out = {}
  for(let local d in values(decorated)){
    append(out, d.item)
  }
  return out
}

// without_duplicates(items, cmp) -> sorted items with only the first of
// each run of equal ones
local func without_duplicates(items, cmp){
  local out = {}
  for(let local item in values(items)){
    if(len(out) == 0 or cmp(out[len(out) - 1], item) != 0){
      append(out, item)
    }
  }
  return out
}

def("msort", 2, func(q, args) => q:unify(
  args[1], list(sorted(terms.array(args[0]), terms.compare)),
))

def("sort", 2, func(q, args) => q:unify(args[1], list(without_duplicates(
  sorted(terms.array(args[0]), terms.compare), terms.compare,
))))

// sort(Key, Order, List, Sorted): by argument Key (0: the whole term),
// Order @< @> (dropping equal ones) or @=< @>= (keeping them)
def("sort", 4, func(q, args){
  local key = terms.integer_value(args[0])
  local order = terms.atom_name(args[1])
  local func key_of(t){
    if(key == 0){
      return t
    }
    t = deref(t)
    if(type(t) != "Compound" or len(t.arguments) < key){
      terms.type_error("compound", t)
    }
    return t.arguments[key - 1]
  }
  local func cmp(a, b) => terms.compare(key_of(a), key_of(b))
  local func reversed(a, b) => cmp(b, a)
  local items = terms.array(args[2])
  if(order == "@<"){
    items = without_duplicates(sorted(items, cmp), cmp)
  } else if(order == "@=<"){
    items = sorted(items, cmp)
  } else if(order == "@>"){
    items = without_duplicates(sorted(items, reversed), reversed)
  } else if(order == "@>="){
    items = sorted(items, reversed)
  } else {
    terms.domain_error("order", deref(args[1]))
  }
  return q:unify(args[3], list(items))
})

// keysort(Pairs, Sorted): pairs Key-Value by key, keeping the order of
// equal keys
def("keysort", 2, func(q, args){
  local items = terms.array(args[0])
  for(let local p in values(items)){
    local d = deref(p)
    if(type(d) == "Var"){
      terms.instantiation_error()
    }
    if(not is_compound(d, "-", 2)){
      terms.type_error("pair", d)
    }
  }
  return q:unify(args[1], list(sorted(items, func(a, b) => terms.compare(
    deref(a).arguments[0], deref(b).arguments[0],
  ))))
})

// -------------------------------------------------------------- all solutions

// findall(Template, Goal, List): a copy of Template for every solution
local func findall(q, template, goal){
  local results = {}
  q:solutions(terms.callable(goal), func(){
    append(results, terms.copy(template))
  })
  return results
}

def("findall", 3, func(q, args) => q:unify(
  args[2], list(findall(q, args[0], args[1])),
))

def("findall", 4, func(q, args) => q:unify(
  args[2], list(findall(q, args[0], args[1]), args[3]),
))

// forall(Cond, Action): Action holds for every solution of Cond
def("forall", 2, func(q, args){
  local ok = true
  local action = args[1]
  q:solutions(terms.callable(args[0]), func(){
    local found = false
    q:solutions(terms.callable(action), func(){
      found = true
      return false
    })
    ok = found
    return found
  })
  return ok
})

// aggregate_all(count | sum(E) | max(E) | min(E) | bag(E) | set(E), Goal, R)
def("aggregate_all", 3, func(q, args){
  local spec = deref(args[0])
  local goal = args[1]
  if(type(spec) == "Atom" and spec.name == "count"){
    local n = 0
    q:solutions(terms.callable(goal), func(){ n = n + 1 })
    return q:unify(args[2], integer(n))
  }
  if(type(spec) != "Compound" or len(spec.arguments) != 1){
    terms.domain_error("aggregate_spec", spec)
  }
  local values_found = findall(q, spec.arguments[0], goal)
  local kind = spec.name
  if(kind == "count"){
    return q:unify(args[2], integer(len(values_found)))
  }
  if(kind == "bag"){
    return q:unify(args[2], list(values_found))
  }
  if(kind == "set"){
    return q:unify(args[2], list(without_duplicates(
      sorted(values_found, terms.compare), terms.compare,
    )))
  }
  if(kind == "sum"){
    local total = 0
    for(let local v in values(values_found)){
      total = arith.eval(compound("+", {ast.number(total), v}))
    }
    return q:unify(args[2], ast.number(total))
  }
  if(kind == "max" or kind == "min"){
    if(len(values_found) == 0){
      return false
    }
    local best = arith.eval(values_found[0])
    for(let local v in values(values_found)){
      local x = arith.eval(v)
      if(kind == "max" and x > best or kind == "min" and x < best){
        best = x
      }
    }
    return q:unify(args[2], ast.number(best))
  }
  terms.domain_error("aggregate_spec", spec)
})

// variant(a, b) -> whether a and b are the same term up to renaming the
// variables consistently: f(X, Y, X) and f(A, B, A) are variants
local func variant(a, b){
  local ab = {}
  local ba = {}
  local stack = {a, b}
  for(len(stack) > 0){
    local y = deref(remove(stack, len(stack) - 1))
    local x = deref(remove(stack, len(stack) - 1))
    if(type(x) == "Var" and type(y) == "Var"){
      if(ab[x.id] == null and ba[y.id] == null){
        ab[x.id] = y.id
        ba[y.id] = x.id
      } else if(ab[x.id] != y.id){
        return false
      }
    } else if(type(x) == "Compound" and type(y) == "Compound"){
      if(x.name != y.name or len(x.arguments) != len(y.arguments)){
        return false
      }
      for(local i = 0; i < len(x.arguments); i = i + 1){
        append(stack, x.arguments[i])
        append(stack, y.arguments[i])
      }
    } else if(terms.compare(x, y) != 0){
      return false
    }
  }
  return true
}

// bagof(Template, Goal, Bag) and setof/3. Unlike findall/3 they group the
// solutions by the variables of Goal that are not in Template (the free
// variables), and give one Bag per group on backtracking. V^Goal marks V
// as not free: bagof(C, P^parent(P, C), L) is one list for every P.
local func bagof(q, args, as_set){
  local template = args[0]
  local goal = deref(args[1])
  local bound = {}
  for(let local v in values(terms.vars_of(template))){
    bound[v.id] = true
  }
  for(is_compound(goal, "^", 2)){
    for(let local v in values(terms.vars_of(goal.arguments[0]))){
      bound[v.id] = true
    }
    goal = deref(goal.arguments[1])
  }
  local free = {}
  for(let local v in values(terms.vars_of(goal))){
    if(not bound[v.id]){
      append(free, v)
    }
  }
  local witness = compound("$w", free)
  local pairs = findall(q, compound("-", {witness, template}), goal)
  if(len(pairs) == 0){
    return false
  }
  local func finish(items){
    if(as_set){
      return list(without_duplicates(sorted(items, terms.compare), terms.compare))
    }
    return list(items)
  }
  if(len(free) == 0){
    local items = {}
    for(let local p in values(pairs)){
      append(items, p.arguments[1])
    }
    return q:unify(args[2], finish(items))
  }
  // the groups, by variant witnesses, in the standard order of witnesses
  local groups = {}
  for(let local p in values(pairs)){
    local w = p.arguments[0]
    local group = null
    for(let local g in values(groups)){
      if(variant(g.witness, w)){
        group = g
        break
      }
    }
    if(group == null){
      group = {witness: w, items: {}}
      append(groups, group)
    }
    append(group.items, p.arguments[1])
  }
  groups = sorted(groups, func(a, b) => terms.compare(a.witness, b.witness))
  local alternatives = {}
  for(let local g in values(groups)){
    append(alternatives, both(equals(witness, g.witness),
      equals(args[2], finish(g.items))))
  }
  return q:push_alternatives(alternatives)
}

def("bagof", 3, func(q, args) => bagof(q, args, false))
def("setof", 3, func(q, args) => bagof(q, args, true))

// ------------------------------------------------------------------ database

def("assert", 1, func(q, args){
  q.db:add_clause(args[0], false)
  return true
})
def("assertz", 1, func(q, args){
  q.db:add_clause(args[0], false)
  return true
})
def("asserta", 1, func(q, args){
  q.db:add_clause(args[0], true)
  return true
})

// '$clauses'(Head, List): the clauses of Head's predicate as it is now,
// each Id-(Head :- Body) with fresh variables; clause/2, retract/1 and
// retractall/1 in prelude.pl are built on it
def("$clauses", 2, func(q, args){
  local head = terms.callable(args[0])
  local key = terms.key(head)
  if(q.db:is_builtin(key)){
    terms.permission_error("access", "private_procedure", terms.indicator(head))
  }
  local p = q.db.predicates[key]
  local items = {}
  if(p != null){
    for(let local c in values(p.clauses)){
      append(items, compound("-", {integer(c.id), compile.as_term(c)}))
    }
  }
  return q:unify(args[1], list(items))
})

def("$erase", 2, func(q, args){
  q.db:erase(terms.key(terms.callable(args[0])), terms.integer_value(args[1]))
  return true
})

// the predicate indicators in a dynamic/1 declaration: a/1, (a/1, b/2) or
// [a/1, b/2]
local func indicators(spec){
  spec = deref(spec)
  if(is_compound(spec, ",", 2)){
    local out = indicators(spec.arguments[0])
    for(let local x in values(indicators(spec.arguments[1]))){
      append(out, x)
    }
    return out
  }
  if(terms.is_list_cell(spec) or terms.is_nil(spec)){
    local out = {}
    for(let local item in values(terms.array(spec))){
      for(let local x in values(indicators(item))){
        append(out, x)
      }
    }
    return out
  }
  if(not is_compound(spec, "/", 2)){
    terms.type_error("predicate_indicator", spec)
  }
  return {{
    name: terms.atom_name(spec.arguments[0]),
    arity: terms.integer_value(spec.arguments[1]),
  }}
}

def("dynamic", 1, func(q, args){
  for(let local pi in values(indicators(args[0]))){
    local key = concat(pi.name, "/", pi.arity)
    if(q.db:is_builtin(key)){
      terms.permission_error("modify", "static_procedure", deref(args[0]))
    }
    q.db:predicate(key, pi.name, pi.arity).dynamic = true
  }
  return true
})

def("discontiguous", 1, func(q, args) => true)

// '$ensure_dynamic'(Head): retractall/1 on an unknown predicate makes it
// a dynamic one, so that calling it fails instead of raising an error
def("$ensure_dynamic", 1, func(q, args){
  local head = terms.callable(args[0])
  local p = q.db:predicate(terms.key(head), head.name, len(terms.arguments(head)))
  if(len(p.clauses) == 0){
    p.dynamic = true
  }
  return true
})

// ------------------------------------------------------------------- output

// the text of t for write/1 (quoted: false), writeq/1 and print/1
local func text_of_term(q, t, quoted) => writer.format(t, {
  quoted: quoted, ops: q.db.ops,
})

// print/1 and ~p: like writeq, but asking the program's portray/1 first
local func printed(q, t) => writer.format(t, {
  quoted: true, ops: q.db.ops, portray: engine.portray_hook(q.db),
})

local func out(q, text){
  q.db.output(text)
  return true
}

def("write", 1, func(q, args) => out(q, text_of_term(q, args[0], false)))
def("print", 1, func(q, args) => out(q, printed(q, args[0])))
def("writeq", 1, func(q, args) => out(q, text_of_term(q, args[0], true)))
def("writeln", 1, func(q, args) => out(q, concat(
  text_of_term(q, args[0], false), "\n",
)))
def("write_canonical", 1, func(q, args) => out(q, writer.format(args[0], {
  quoted: true, ignore_ops: true,
})))
def("nl", 0, func(q, args) => out(q, "\n"))
// spaces(n) -> n spaces
local func spaces(n){
  local out_spaces = {}
  for(local i = 0; i < n; i = i + 1){
    append(out_spaces, " ")
  }
  return str.join(out_spaces, "")
}

def("tab", 1, func(q, args) => out(q, spaces(arith.eval(args[0]))))
def("put_char", 1, func(q, args) => out(q, terms.atom_name(args[0])))

// write_term(T, Options): quoted(true), ignore_ops(true)
def("write_term", 2, func(q, args){
  local options = {ops: q.db.ops}
  for(let local o in values(terms.array(args[1]))){
    o = deref(o)
    if(type(o) == "Compound" and len(o.arguments) == 1){
      local v = deref(o.arguments[0])
      local on = type(v) == "Atom" and v.name == "true"
      if(o.name == "quoted"){
        options.quoted = on
      } else if(o.name == "ignore_ops"){
        options.ignore_ops = on
      }
    }
  }
  return out(q, writer.format(args[0], options))
})

// fixed(x, n) -> x with n digits after the point
local func fixed(x, n){
  if(x != x){
    return "nan"
  }
  local sign = ""
  if(x < 0){
    sign = "-"
    x = -x
  }
  local scale = 1
  for(local i = 0; i < n; i = i + 1){
    scale = scale * 10
  }
  local scaled = require("slang/math").round(to_float(x) * scale)
  if(scaled >= 9.0e18){
    return concat(sign, x)
  }
  // the digits of round(x * 10^n), with a point n digits from the right
  local whole = to_int(scaled)
  local int_part = concat("", to_int((whole - whole % scale) / scale))
  if(n == 0){
    return concat(sign, int_part)
  }
  local frac = concat("", whole % scale)
  for(len(frac) < n){
    frac = concat("0", frac)
  }
  return concat(sign, int_part, ".", frac)
}

// with_thousands(digits) -> 1234567 as 1,234,567
local func with_thousands(digits){
  local sign = ""
  if(str.starts_with(digits, "-")){
    sign = "-"
    digits = str.substring(digits, 1, len(digits))
  }
  local parts = {}
  local i = len(digits)
  for(i > 3){
    append(parts, str.substring(digits, i - 3, i))
    i = i - 3
  }
  append(parts, str.substring(digits, 0, i))
  local out_parts = {}
  for(local k = len(parts) - 1; k >= 0; k = k - 1){
    append(out_parts, parts[k])
  }
  return concat(sign, str.join(out_parts, ","))
}

// format_text(q, fmt, args) -> the text format/2 writes. Directives:
//   ~w write  ~p print  ~q writeq  ~a atom  ~d integer (~Nd: N decimals)
//   ~D integer with thousands separators  ~f ~e ~g float (~Nf: N digits)
//   ~s string or codes  ~c character code  ~n newline  ~~ a tilde
//   ~i skip an argument  ~t fill  ~N| column N  ~N+ N columns on
local func format_text(q, fmt, args){
  local chars = chars_of(fmt)
  local output = {}
  // the column bookkeeping for ~t ~| ~+: where the current column segment
  // starts in output, and where its fill point is (if any)
  local segment_start = 0
  local line_start = 0
  local fill_at = -1
  local arg_index = 0
  local func next_arg(){
    if(arg_index >= len(args)){
      terms.throw(compound("error", {
        compound("format", {ast.string("not enough arguments")}), ast.var(),
      }))
    }
    arg_index = arg_index + 1
    return args[arg_index - 1]
  }
  local func emit(text){
    append(output, text)
  }
  local func current_column(){
    local n = 0
    for(local k = line_start; k < len(output); k = k + 1){
      n = n + len(chars_of(output[k]))
    }
    return n
  }
  // pad the current segment to reach column target
  local func pad_to(target){
    local width = current_column()
    if(width >= target){
      return
    }
    local fill = spaces(target - width)
    if(fill_at >= 0){
      // insert at the fill point: the text after it moves right
      local rest = {}
      for(local k = fill_at; k < len(output); k = k + 1){
        append(rest, output[k])
      }
      for(len(output) > fill_at){
        remove(output, len(output) - 1)
      }
      append(output, fill)
      for(let local r in values(rest)){
        append(output, r)
      }
    } else {
      append(output, fill)
    }
  }
  local i = 0
  for(i < len(chars)){
    local c = chars[i]
    i = i + 1
    if(c != "~"){
      emit(c)
      if(c == "\n"){
        line_start = len(output)
        segment_start = len(output)
        fill_at = -1
      }
      continue
    }
    // an optional numeric argument: digits, or * for the next argument
    local num = null
    local digits = ""
    for(i < len(chars) and str.contains("0123456789", chars[i])){
      digits = concat(digits, chars[i])
      i = i + 1
    }
    if(digits != ""){
      num = str.parse_int(digits, 10)
    } else if(i < len(chars) and chars[i] == "*"){
      num = terms.integer_value(next_arg())
      i = i + 1
    }
    local d = chars[i]
    i = i + 1
    if(d == "w"){
      emit(text_of_term(q, next_arg(), false))
    } else if(d == "p"){
      emit(printed(q, next_arg()))
    } else if(d == "q"){
      emit(text_of_term(q, next_arg(), true))
    } else if(d == "a"){
      emit(terms.text_of(next_arg()))
    } else if(d == "d" or d == "D"){
      local v = arith.eval(next_arg())
      if(type(v) != "int"){
        terms.type_error("integer", ast.number(v))
      }
      local text = concat("", v)
      if(num != null and num > 0){
        local sign = ""
        if(v < 0){
          sign = "-"
          text = concat("", -v)
        }
        for(len(text) <= num){
          text = concat("0", text)
        }
        text = concat(sign, str.substring(text, 0, len(text) - num), ".",
          str.substring(text, len(text) - num, len(text)))
      } else if(d == "D"){
        text = with_thousands(text)
      }
      emit(text)
    } else if(d == "f" or d == "e" or d == "g"){
      local v = to_float(arith.eval(next_arg()))
      if(d == "f"){
        emit(fixed(v, num or 6))
      } else if(d == "e"){
        local math = require("slang/math")
        local e = 0
        if(v != 0){
          e = to_int(math.floor(math.log10(math.abs(v))))
        }
        local mantissa = v / (10.0 ^ to_float(e))
        local exp_sign = "+"
        if(e < 0){
          exp_sign = "-"
          e = -e
        }
        local exp_text = concat("", e)
        if(len(exp_text) < 2){
          exp_text = concat("0", exp_text)
        }
        emit(concat(fixed(mantissa, num or 6), "e", exp_sign, exp_text))
      } else {
        emit(concat("", v))
      }
    } else if(d == "s"){
      local a = deref(next_arg())
      if(type(a) == "String"){
        emit(a.value)
      } else {
        emit(text_of_list(a))
      }
    } else if(d == "c"){
      local code = terms.integer_value(next_arg())
      for(local k = 0; k < (num or 1); k = k + 1){
        emit(utf8.char(code))
      }
    } else if(d == "n"){
      for(local k = 0; k < (num or 1); k = k + 1){
        emit("\n")
      }
      line_start = len(output)
      segment_start = len(output)
      fill_at = -1
    } else if(d == "~"){
      emit("~")
    } else if(d == "i"){
      next_arg()
    } else if(d == "t"){
      fill_at = len(output)
    } else if(d == "|" or d == "+"){
      local target = num or 0
      if(d == "+"){
        // N columns after the previous column stop (8 by default)
        local start = 0
        for(local k = line_start; k < segment_start; k = k + 1){
          start = start + len(chars_of(output[k]))
        }
        target = start + (num or 8)
      }
      pad_to(target)
      segment_start = len(output)
      fill_at = -1
    } else {
      terms.throw(compound("error", {
        compound("format", {ast.string(concat("unknown directive ~", d))}),
        ast.var(),
      }))
    }
  }
  return str.join(output, "")
}

// the arguments of format/2: a list, or one term that is not a list
local func format_args(t){
  local items = terms.list_to_array(t)
  if(items == null){
    return {t}
  }
  return items
}

def("format", 1, func(q, args) => out(q, format_text(
  q, terms.text_of(args[0]), {},
)))
def("format", 2, func(q, args) => out(q, format_text(
  q, terms.text_of(args[0]), format_args(args[1]),
)))
// format(atom(A), Fmt, Args) and string(S), codes(C): to a term, not out
def("format", 3, func(q, args){
  local sink = deref(args[0])
  local text = format_text(q, terms.text_of(args[1]), format_args(args[2]))
  if(is_compound(sink, "atom", 1)){
    return q:unify(sink.arguments[0], atom(text))
  }
  if(is_compound(sink, "string", 1)){
    return q:unify(sink.arguments[0], ast.string(text))
  }
  if(is_compound(sink, "codes", 1)){
    return q:unify(sink.arguments[0], codes_list(text))
  }
  // a stream (user_output, user_error): written out
  return out(q, text)
})

// --------------------------------------------------------------- listing

// letter_name(i) -> A, B, ..., Z, A1, B1, ...: how portray_clause/1 names
// variables
local func letter_name(i){
  local letter = utf8.char('A' + i % 26)
  local round = to_int((i - i % 26) / 26)
  if(round == 0){
    return letter
  }
  return concat(letter, round)
}

// clause_text(q, clause) -> the clause as portray_clause/1 writes it: one
// goal per line, variables named A, B, ...
local func clause_text(q, clause){
  local var_names = {}
  local vars = terms.vars_of(clause)
  for(local i = 0; i < len(vars); i = i + 1){
    var_names[vars[i].id] = letter_name(i)
  }
  local func show(t, priority) => writer.format(t, {
    quoted: true, ops: q.db.ops, var_names: var_names, priority: priority,
    spaced: true,
  })
  clause = deref(clause)
  local head = clause
  local body = atom("true")
  if(is_compound(clause, ":-", 2)){
    head = clause.arguments[0]
    body = deref(clause.arguments[1])
  }
  if(type(body) == "Atom" and body.name == "true"){
    return concat(show(head, 1199), ".\n")
  }
  local goals = {}
  for(is_compound(body, ",", 2)){
    append(goals, concat("    ", show(body.arguments[0], 999)))
    body = deref(body.arguments[1])
  }
  append(goals, concat("    ", show(body, 999)))
  return concat(show(head, 1199), " :-\n", str.join(goals, ",\n"), ".\n")
}

def("portray_clause", 1, func(q, args) => out(q, clause_text(q, args[0])))

// listing(Name) or listing(Name/Arity): the clauses of those predicates
def("listing", 1, func(q, args){
  local spec = deref(args[0])
  local name = null
  local arity = null
  if(is_compound(spec, "/", 2)){
    name = terms.atom_name(spec.arguments[0])
    arity = terms.integer_value(spec.arguments[1])
  } else {
    name = terms.atom_name(spec)
  }
  local found = {}
  for(let local p in values(q.db.predicates)){
    if(p.name == name and (arity == null or p.arity == arity)){
      append(found, p)
    }
  }
  found = sorted(found, func(a, b) => a.arity - b.arity)
  for(let local p in values(found)){
    if(p.dynamic){
      out(q, concat(":- dynamic ", ast.atom_text(p.name), "/", p.arity, ".\n\n"))
    }
    for(let local c in values(p.clauses)){
      out(q, clause_text(q, compile.as_term(c)))
    }
    out(q, "\n")
  }
  return true
})

// --------------------------------------------------------------------- input

// read(T): the next term from standard input (end_of_file at its end)
def("read", 1, func(q, args){
  local text = ""
  for(true){
    local line = os.read_line()
    if(line == null){
      if(str.trim(text) == ""){
        return q:unify(args[0], atom("end_of_file"))
      }
      local t = parse_term(q, text)
      return t != null and q:unify(args[0], t)
    }
    text = concat(text, line, "\n")
    local t = parse_term(q, text)
    if(t != null){
      return q:unify(args[0], t)
    }
  }
})

// ------------------------------------------------------------ the rest

def("halt", 0, func(q, args){
  raise(error.new("halt", "halt", {status: 0}))
})
def("halt", 1, func(q, args){
  raise(error.new("halt", "halt", {status: terms.integer_value(args[0])}))
})

// op(Priority, Type, Name or [Names])
def("op", 3, func(q, args){
  local priority = terms.integer_value(args[0])
  local kind = terms.atom_name(args[1])
  local names = deref(args[2])
  local list_of = {names}
  if(terms.is_list_cell(names)){
    list_of = terms.array(names)
  }
  for(let local n in values(list_of)){
    local name = terms.atom_name(n)
    if(name == ","){
      terms.permission_error("modify", "operator", atom(name))
    }
    q.db.ops:add(priority, kind, name)
  }
  return true
})

// current_op(Priority, Type, Name): every operator, on backtracking
def("current_op", 3, func(q, args){
  local want = deref(args[2])
  local alternatives = {}
  for(let local class in values({"prefix", "infix", "postfix"})){
    for(let {local name, local d} in entries(q.db.ops[class])){
      if(type(want) == "Var" or type(want) == "Atom" and want.name == name){
        append(alternatives, both(
          both(equals(args[0], integer(d.priority)), equals(args[1], atom(d.type))),
          equals(want, atom(name)),
        ))
      }
    }
  }
  return q:push_alternatives(alternatives)
})

local start_ms = time.clock()
local last_runtime = 0

// statistics(Key, Value): runtime ([Ms, MsSinceLast]), cputime (seconds),
// walltime ([Ms, MsSinceLast]), inferences
def("statistics", 2, func(q, args){
  local key = terms.atom_name(args[0])
  local now = to_int(time.clock() - start_ms)
  if(key == "runtime" or key == "walltime" or key == "process_cputime"
    or key == "real_time"){
    local since = now - last_runtime
    last_runtime = now
    return q:unify(args[1], list({integer(now), integer(since)}))
  }
  if(key == "cputime"){
    return q:unify(args[1], ast.float(to_float(now) / 1000.0))
  }
  if(key == "inferences"){
    return q:unify(args[1], integer(q.db.inferences))
  }
  terms.domain_error("statistics_key", atom(key))
})

// nb_setval(Key, Value) / nb_getval(Key, Value): global values that
// survive backtracking (a copy is stored)
def("nb_setval", 2, func(q, args){
  q.db.globals[terms.atom_name(args[0])] = terms.copy(args[1])
  return true
})
def("b_setval", 2, func(q, args){
  q.db.globals[terms.atom_name(args[0])] = terms.copy(args[1])
  return true
})
local func getval(q, args){
  local key = terms.atom_name(args[0])
  local v = q.db.globals[key]
  if(v == null){
    terms.existence_error("variable", atom(key))
  }
  return q:unify(args[1], v)
}
def("nb_getval", 2, getval)
def("b_getval", 2, getval)

def("consult", 1, func(q, args){
  q.db.consult(terms.text_of(args[0]))
  return true
})
def("ensure_loaded", 1, func(q, args){
  q.db.consult(terms.text_of(args[0]))
  return true
})

// phrase(Body, List, Rest): the grammar body Body between List and Rest
def("phrase", 2, func(q, args){
  q:push_goal(compile.dcg_body(terms.callable(args[0]), args[1], atom("[]")))
  return true
})
def("phrase", 3, func(q, args){
  q:push_goal(compile.dcg_body(terms.callable(args[0]), args[1], args[2]))
  return true
})

// Lambdas (library yall): call([X, Y]>>Goal, A, B) proves a copy of Goal
// with X = A and Y = B. The lambda is copied for every call, so it can be
// used again; the variables of Free in Free/[X]>>Goal are shared instead.
local func lambda(q, lambda_term, extra){
  local t = deref(lambda_term)
  local shared = {}
  local params = deref(t.arguments[0])
  if(is_compound(params, "/", 2)){
    for(let local v in values(terms.vars_of(params.arguments[0]))){
      shared[v.id] = v
    }
  }
  local copy = deref(terms.copy(t, shared))
  params = deref(copy.arguments[0])
  local body = copy.arguments[1]
  if(is_compound(params, "/", 2)){
    params = deref(params.arguments[1])
  }
  local names = terms.list_to_array(params) or {}
  local rest = {}
  for(local i = 0; i < len(extra); i = i + 1){
    if(i < len(names)){
      if(not q:unify(names[i], extra[i])){
        return false
      }
    } else {
      append(rest, extra[i])
    }
  }
  local goal = terms.callable(body)
  if(len(rest) > 0){
    goal = compile.add_args(goal, rest)
  }
  q:push_goal(goal)
  return true
}

for(local n = 2; n <= 9; n = n + 1){
  def(">>", n, func(q, args){
    local extra = {}
    for(local i = 2; i < len(args); i = i + 1){
      append(extra, args[i])
    }
    return lambda(q, compound(">>", {args[0], args[1]}), extra)
  })
}

return M
