// A Prolog system: a database with the built-ins and the library loaded,
// consulting programs, and running queries with answers as text. main.slang
// puts a toplevel (?- prompt) on top of this; the tests use it directly.
//
//   local prolog = require("prolog")
//   local p = prolog.new()
//   p:consult("parent(tom, bob). parent(bob, ann).")
//   for(let local a in values(p:answers("parent(tom, X)"))){ print(a) }
//   // X = bob
local ast = require("ast")
local terms = require("terms")
local grammar = require("grammar")
local engine = require("engine")
local compile = require("compile")
local builtins = require("builtins")
local writer = require("writer")
local os = require("slang/os")
local path = require("slang/path")
local str = require("slang/string")

local M = {}

local deref = terms.deref

local func is_compound(t, name, arity) => type(t) == "Compound"
  and t.name == name and len(t.arguments) == arity

local Prolog = {}
Prolog.__index = Prolog

// where prelude.pl is: next to this file
local func prelude_path(){
  local here = __PACKAGES.find_source("prolog").path
  return path.join(path.dir(here), "prelude.pl")
}

// new(options?) -> a Prolog system. options.output: func(text) for what
// the program writes (printing by default); options.warn: func(text) for
// warnings and errors while consulting
func M.new(options){
  options = options or {}
  local db = engine.database(grammar.operators())
  builtins.install(db)
  local p = {
    db: db,
    warn: options.warn or func(text){ print(concat("Warning: ", text, "\n")) },
    // each consult has a number; a predicate belongs to the consult that
    // defined it (see add_clause)
    consults: 0,
  }
  p.@meta = Prolog
  if(options.output != null){
    db.output = options.output
  }
  db.consult = func(file){ p:consult_file(file) }
  p:consult(os.read_file(prelude_path()), "prelude.pl")
  return p
}

// ------------------------------------------------------------------ errors

// error_message(ball, ops?) -> a sentence for an uncaught exception term
func M.error_message(ball, ops){
  local func show(t) => writer.format(t, {quoted: true, ops: ops})
  ball = deref(ball)
  if(not is_compound(ball, "error", 2)){
    return concat("Unhandled exception: ", show(ball))
  }
  local e = deref(ball.arguments[0])
  local func arg(i) => show(e.arguments[i])
  if(type(e) == "Atom" and e.name == "instantiation_error"){
    return "Arguments are not sufficiently instantiated"
  }
  if(is_compound(e, "existence_error", 2)){
    local kind = deref(e.arguments[0])
    if(type(kind) == "Atom" and kind.name == "procedure"){
      return concat("Unknown procedure: ", arg(1))
    }
    return concat("Unknown ", arg(0), ": ", arg(1))
  }
  if(is_compound(e, "type_error", 2)){
    return concat("Type error: ", arg(0), " expected, found ", arg(1))
  }
  if(is_compound(e, "domain_error", 2)){
    return concat("Domain error: ", arg(0), " expected, found ", arg(1))
  }
  if(is_compound(e, "evaluation_error", 1)){
    return concat("Arithmetic: evaluation error: ", arg(0))
  }
  if(is_compound(e, "permission_error", 3)){
    return concat("No permission to ", arg(0), " ", arg(1), " ", arg(2))
  }
  if(is_compound(e, "system_error", 1)){
    return concat("System error: ", terms.text_of(e.arguments[0]))
  }
  return concat("Unhandled exception: ", show(ball))
}

// ----------------------------------------------------------------- consult

// the "name/arity" of the predicate a clause term belongs to (null when
// its head is not callable: storing it reports the error)
local func clause_key(term){
  local head = deref(term)
  if(is_compound(head, ":-", 2)){
    head = deref(head.arguments[0])
  }
  if(not terms.is_callable(head)){
    return null
  }
  return terms.key(head)
}

// add_clause(term, consult_id): a clause read from a file. A predicate
// belongs to the consult that first gave it clauses: when another consult
// gives it clauses again, its old clauses go. That is how a program's own
// append/3 replaces the library's, and how consulting a file again
// replaces what it defined before instead of doubling it.
func Prolog.add_clause(self, term, consult_id){
  local key = clause_key(term)
  local p = null
  if(key != null){
    p = self.db.predicates[key]
  }
  if(p != null and p.owner != null and p.owner != consult_id){
    p.clauses = {}
  }
  self.db:add_clause(term, false)
  self.db.predicates[key].owner = consult_id
}

// run_directive(goal, where): a :- goal in a file, run once
func Prolog.run_directive(self, goal, where){
  local q = engine.query(self.db, goal)
  try {
    if(not q:next()){
      self.warn(concat(where, ": goal (directive) failed: ", writer.format(goal, {
        quoted: true, ops: self.db.ops,
      })))
    }
  } catch(local e) {
    if(error.is(e, "halt")){
      raise(e)
    }
    self.warn(concat(where, ": ", M.error_message(engine.ball_of(e), self.db.ops)))
  }
  q:close()
}

// consult(text, name?) loads a program: clauses are stored, directives
// (:- Goal) run as they are read, grammar rules (-->) become clauses, and
// initialization(G) goals run at the end
func Prolog.consult(self, text, name){
  name = name or "user"
  self.consults = self.consults + 1
  local id = self.consults
  local src = grammar.source(text)
  local after_load = {}
  for(true){
    local r = grammar.read_clause(src, self.db.ops)
    if(r == null){
      break
    }
    if(r.error != null){
      self.warn(concat(name, ": syntax error: ", r.error))
      continue
    }
    local t = deref(terms.from_source(r.term, terms.new_names()))
    try {
      if(is_compound(t, ":-", 1) or is_compound(t, "?-", 1)){
        local goal = deref(t.arguments[0])
        if(is_compound(goal, "initialization", 1)){
          append(after_load, goal.arguments[0])
        } else {
          self:run_directive(goal, name)
        }
      } else if(is_compound(t, "-->", 2)){
        self:add_clause(compile.dcg_rule(t), id)
      } else {
        self:add_clause(t, id)
      }
    } catch(local e) {
      if(error.is(e, "halt")){
        raise(e)
      }
      self.warn(concat(name, ": ", M.error_message(engine.ball_of(e), self.db.ops)))
    }
  }
  for(let local goal in values(after_load)){
    self:run_directive(goal, name)
  }
}

// consult_file(file) loads a file (".pl" is added when the name has no
// extension and that file exists)
func Prolog.consult_file(self, file){
  if(not os.exists(file) and os.exists(concat(file, ".pl"))){
    file = concat(file, ".pl")
  }
  if(not os.exists(file)){
    terms.existence_error("source_sink", ast.atom(file))
  }
  self:consult(os.read_file(file), file)
}

// ------------------------------------------------------------------ queries

// read_query(text) -> {goal, names} for the query text (the end "." may be
// left out), or raises a syntax error
func Prolog.read_query(self, text){
  local trimmed = str.trim(text)
  if(not str.ends_with(trimmed, ".")){
    trimmed = concat(trimmed, " .")
  }
  local r = grammar.read_clause(grammar.source(trimmed), self.db.ops)
  if(r == null){
    raise(error.new("syntax", "empty query"))
  }
  if(r.error != null){
    raise(error.new("syntax", concat("syntax error: ", r.error)))
  }
  local names = terms.new_names()
  return {goal: terms.from_source(r.term, names), names: names}
}

// answer_text(names) -> the current bindings of a query's variables:
// "X = 1, Y = f(Z)", or "true" when there is nothing to show. Variables
// whose name starts with _ are not shown.
func Prolog.answer_text(self, names){
  // unbound query variables print by their names
  local var_names = {}
  for(let local name in values(names.order)){
    local v = deref(names.vars[name])
    if(type(v) == "Var" and var_names[v.id] == null){
      var_names[v.id] = name
    }
  }
  local portray = engine.portray_hook(self.db)
  local parts = {}
  for(let local name in values(names.order)){
    if(not str.starts_with(name, "_")){
      local v = names.vars[name]
      local value = deref(v)
      // an unbound variable that stands for itself shows nothing
      if(not (type(value) == "Var" and var_names[value.id] == name)){
        append(parts, concat(name, " = ", writer.format(value, {
          quoted: true, ops: self.db.ops, spaced: true, var_names: var_names,
          priority: 699, portray: portray,
        })))
      }
    }
  }
  if(len(parts) == 0){
    return "true"
  }
  return str.join(parts, ", ")
}

// query(text) -> {next(), text(), has_more(), close()}: the answers of a
// query one at a time. next() -> whether there is another answer; text()
// is that answer.
func Prolog.query(self, text){
  local parsed = self:read_query(text)
  local q = engine.query(self.db, parsed.goal)
  local system = self
  return {
    next: func() => q:next(),
    text: func() => system:answer_text(parsed.names),
    has_more: func() => q:has_choices(),
    close: func(){ q:close() },
    names: parsed.names,
  }
}

// answers(text, limit?) -> the answers of a query as text, at most limit
// of them; {"false"} when there are none, and an error as {"error: ..."}
func Prolog.answers(self, text, limit){
  limit = limit or 1000
  local out = {}
  local a = self:query(text)
  try {
    for(len(out) < limit and a.next()){
      append(out, a.text())
    }
  } catch(local e) {
    a.close()
    if(error.is(e, "prolog")){
      append(out, concat("error: ", M.error_message(e.ball, self.db.ops)))
      return out
    }
    raise(e)
  }
  a.close()
  if(len(out) == 0){
    return {"false"}
  }
  return out
}

return M
