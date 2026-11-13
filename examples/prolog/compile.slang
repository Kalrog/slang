// From terms to stored clauses, and back.
//
// A clause is stored with its variables numbered: every distinct variable
// becomes a Slot{index}, so `app([H|T], L, [H|R]) :- app(T, L, R)` is kept
// as app([S0|S1], S2, [S0|S3]) :- app(S1, S2, S3) with nvars = 4. Each use
// of the clause gets fresh variables for its slots (renaming apart), and
// variables of one use never leak into another.
//
// Also here: the DCG translation (Head --> Body to an ordinary clause),
// which turns grammar rules into clauses before they are stored.
local ast = require("ast")
local terms = require("terms")

local M = {}

local deref = terms.deref

local func is_compound(t, name, arity) => type(t) == "Compound"
  and t.name == name and len(t.arguments) == arity

// --------------------------------------------------------------------- bodies

// body(t) -> the clause body t ready to run: a variable where a goal goes
// (in a conjunction, disjunction or if-then-else) means call(X), and a
// number there is an error
func M.body(t){
  t = deref(t)
  if(type(t) == "Var"){
    return ast.compound("call", {t})
  }
  if(not terms.is_callable(t)){
    terms.type_error("callable", t)
  }
  if(is_compound(t, ",", 2) or is_compound(t, ";", 2)
    or is_compound(t, "->", 2)){
    return ast.compound(t.name, {M.body(t.arguments[0]), M.body(t.arguments[1])})
  }
  return t
}

// --------------------------------------------------------------- first argument

// index_key(t) -> what the first argument of a call or a clause head must
// agree on to unify: "a:foo" for the atom foo, "c:f/2" for a compound f/2,
// and so on; null for a variable, which unifies with anything. A call only
// tries the clauses whose key is null or the same as its own, so
// `len([], 0)` and `len([_|T], N)` are never both candidates, and a call
// with one candidate leaves no choice point behind.
func M.index_key(t){
  t = deref(t)
  local kind = type(t)
  if(kind == "Atom"){
    return concat("a:", t.name)
  }
  if(kind == "Integer"){
    return concat("i:", t.value)
  }
  if(kind == "Float"){
    return concat("f:", t.value)
  }
  if(kind == "String"){
    return concat("s:", t.value)
  }
  if(kind == "Compound"){
    return concat("c:", t.name, "/", len(t.arguments))
  }
  // Var or Slot
  return null
}

// -------------------------------------------------------------------- clauses

// clause(term) -> the stored form of a clause term (Head or Head :- Body):
//   head, body: the terms with Slots for the variables
//   nvars: how many slots
//   key: "name/arity" of the predicate
//   first: index_key of the head's first argument
//   is_fact: the body is true
func M.clause(term){
  term = deref(term)
  local head = term
  local body = ast.atom("true")
  if(is_compound(term, ":-", 2)){
    head = deref(term.arguments[0])
    body = term.arguments[1]
  }
  if(type(head) == "Var"){
    terms.instantiation_error()
  }
  if(not terms.is_callable(head)){
    terms.type_error("callable", head)
  }
  body = M.body(body)

  // number the variables in the order they first appear
  local slots = {}
  local nvars = 0
  local func slot_of(x){
    if(type(x) != "Var"){
      return x
    }
    local s = slots[x.id]
    if(s == null){
      s = ast.slot(nvars)
      slots[x.id] = s
      nvars = nvars + 1
    }
    return s
  }
  head = terms.rebuild(head, slot_of)
  body = terms.rebuild(body, slot_of)

  local first = null
  if(type(head) == "Compound"){
    first = M.index_key(head.arguments[0])
  }
  return {
    head: head, body: body, nvars: nvars, key: terms.key(head),
    first: first, is_fact: type(body) == "Atom" and body.name == "true",
  }
}

// instantiate(t, frame) -> the stored term t with its slots filled in from
// frame, an array of what each slot is in this use of the clause. A slot
// that has nothing yet gets a fresh variable.
func M.instantiate(t, frame){
  return terms.rebuild(t, func(x){
    if(type(x) != "Slot"){
      return x
    }
    local v = frame[x.index]
    if(v == null){
      v = ast.var()
      frame[x.index] = v
    }
    return v
  })
}

// as_term(clause) -> the clause as a term (Head :- Body) with fresh
// variables, for clause/2 and listing/1
func M.as_term(clause){
  local frame = {}
  return ast.compound(":-", {
    M.instantiate(clause.head, frame), M.instantiate(clause.body, frame),
  })
}

// ------------------------------------------------------------------------ DCG

// A grammar rule Head --> Body describes a list: every nonterminal gets
// two more arguments, the list before it (S0) and what is left after it
// (S). `greeting --> [hello], name.` becomes
//   greeting(S0, S) :- S0 = [hello|S1], name(S1, S).

// add_args(goal, extra) -> goal with the terms of extra added as arguments
func M.add_args(goal, extra){
  local args = {}
  for(let local a in values(terms.arguments(goal))){
    append(args, a)
  }
  for(let local a in values(extra)){
    append(args, a)
  }
  return ast.compound(goal.name, args)
}

local func equals(a, b) => ast.compound("=", {a, b})

local func conj(a, b) => ast.compound(",", {a, b})

// the codes of a string, for "abc" in a grammar body
local func string_codes(text){
  local utf8 = require("slang/utf8")
  local codes = {}
  local i = 0
  for(i < len(text)){
    append(codes, ast.integer(utf8.code_at(text, i)))
    i = i + utf8.size_at(text, i)
  }
  return codes
}

// dcg_body(body, S0, S) -> the goal that body of a grammar rule means
// between the lists S0 and S
func M.dcg_body(b, s0, s){
  b = deref(b)
  if(type(b) == "Var"){
    return ast.compound("phrase", {b, s0, s})
  }
  if(is_compound(b, ",", 2)){
    local mid = ast.var()
    return conj(M.dcg_body(b.arguments[0], s0, mid),
      M.dcg_body(b.arguments[1], mid, s))
  }
  if(is_compound(b, ";", 2) or is_compound(b, "|", 2)){
    return ast.compound(";", {
      M.dcg_body(b.arguments[0], s0, s), M.dcg_body(b.arguments[1], s0, s),
    })
  }
  if(is_compound(b, "->", 2)){
    local mid = ast.var()
    return ast.compound("->", {
      M.dcg_body(b.arguments[0], s0, mid), M.dcg_body(b.arguments[1], mid, s),
    })
  }
  if(is_compound(b, "\\+", 1)){
    return conj(
      ast.compound("\\+", {M.dcg_body(b.arguments[0], s0, ast.var())}),
      equals(s0, s),
    )
  }
  // { Goal }: a plain goal, consuming nothing
  if(is_compound(b, "{}", 1)){
    return conj(b.arguments[0], equals(s0, s))
  }
  if(type(b) == "Atom" and b.name == "!"){
    return conj(b, equals(s0, s))
  }
  if(terms.is_nil(b)){
    return equals(s0, s)
  }
  // a list of terminals: S0 is those elements followed by S
  if(terms.is_list_cell(b)){
    local items = terms.list_to_array(b)
    if(items == null){
      terms.type_error("list", b)
    }
    return equals(s0, terms.array_to_list(items, s))
  }
  if(type(b) == "String"){
    return equals(s0, terms.array_to_list(string_codes(b.value), s))
  }
  if(is_compound(b, "call", len(terms.arguments(b)))){
    return M.add_args(b, {s0, s})
  }
  if(not terms.is_callable(b)){
    terms.type_error("callable", b)
  }
  return M.add_args(b, {s0, s})
}

// dcg_rule(rule) -> the clause of the grammar rule Head --> Body
func M.dcg_rule(rule){
  local head = deref(rule.arguments[0])
  local body = rule.arguments[1]
  local s0 = ast.var()
  local s = ast.var()
  // Head, Pushback --> Body: after Body, the terminals of Pushback are put
  // back in front of what is left
  if(is_compound(head, ",", 2)){
    local pushback = terms.list_to_array(head.arguments[1])
    if(pushback == null){
      terms.type_error("list", head.arguments[1])
    }
    local mid = ast.var()
    head = deref(head.arguments[0])
    return ast.compound(":-", {
      M.add_args(terms.callable(head), {s0, s}),
      conj(M.dcg_body(body, s0, mid), equals(s, terms.array_to_list(pushback, mid))),
    })
  }
  return ast.compound(":-", {
    M.add_args(terms.callable(head), {s0, s}), M.dcg_body(body, s0, s),
  })
}

return M
