// Multi-clause functions with pattern-matched parameters, as in Elixir:
//
//   def fact(0){ return 1 }
//   def fact(n) when(n > 0){ return n * fact(n - 1) }
//
//   def area('Circle{radius: r}){ return 3.14159 * r * r }
//   def area({w, h}){ return w * h }
//   def area(_){ error("not a shape") }
//
//   def sum(first, ...rest){ return first + sum(...rest) }
//   def sum(){ return 0 }
//
// Every parameter is a pattern (a bare name binds, `_` ignores, tables,
// constants and matchers work as in `let`); the clauses of one name are
// tried in definition order, the first whose patterns match, whose arity
// fits and whose `when(...)` guard holds runs; none matching is an error.
// `local def` declares the name in the current scope. The guard takes
// parentheses because an expression followed by `{` would be a call with
// a block argument.
//
// How it works: a clause lowers to NAME = __def.define(NAME, name, n,
// has_rest, func(args){ local matched = (let {P1, P2, ...} = args)
// if(not matched){ return __def.no_match } ... body }), and __def.define returns a callable
// dispatcher (a table with __call) holding the clauses. A def is slower
// than a func: each call allocates its argument list and runs the patterns.
local peg = require("slang/peg")
local ast = require("slang/ast")
local g = require("slang/compiler").grammar()

// ------------------------------------------------------------ runtime

local no_match = {}
local dispatcher_methods = {}
local dispatcher_meta = {__index: dispatcher_methods, __type: "def"}

func dispatcher_meta.__call(self, ...args){
  local n = len(args)
  for(let local c in values(self.clauses)){
    if(n == c.n or (c.rest and n >= c.n)){
      local r = c.f(args)
      if(r != no_match){
        return r
      }
    }
  }
  local shown = {}
  for(local i = 0; i < n; i = i + 1){
    append(shown, string(args[i]))
  }
  error("no clause of ", self.name, " matches (", require("slang/string").join(shown, ", "), ")")
}

func dispatcher_meta.__tostring(self){
  return concat("def ", self.name, " (", len(self.clauses), " clauses)")
}

local def = {no_match: no_match}

// define(existing, name, n, has_rest, clause) -> the dispatcher for name
func def.define(existing, name, n, has_rest, clause){
  local d = existing
  if(type(d) != "def"){
    d = {name: name, clauses: {}}
    d.meta = dispatcher_meta
  }
  append(d.clauses, {n: n, rest: has_rest, f: clause})
  return d
}

// rest(args, n) -> the arguments from index n on
func def.rest(args, n){
  local out = {}
  for(local i = n; i < len(args); i = i + 1){
    append(out, args[i])
  }
  return out
}

__def = def

// ------------------------------------------------------------ syntax

// names bound by a parameter pattern are locals that accept any value
local func localize(node){
  local t = type(node)
  if(t == "VarPattern"){
    node.isLocal = true
    node.canBeNull = true
  } else if(t == "TablePattern"){
    for(let local f in values(node.fields)){
      localize(f.value)
    }
  } else if(t == "MatcherPattern"){
    if(node.sub != null){
      localize(node.sub)
    }
  }
  return node
}

local func id(name, token){
  return ast.node("Identifier", {value: name}, token)
}
local func field(receiver, name, token){
  return ast.node("Index", {receiver: receiver, index: ast.node("String", {value: name}, token), dotStyle: true}, token)
}
local func no_match_return(token){
  return ast.node("Block", {statements: {ast.node("Return", {value: field(id("__def", token), "no_match", token)}, token)}}, token)
}

// a clause is a function of the argument list: pattern check, rest, guard, body
local func clause_function(params, rest_name, guard, body, token){
  local statements = {}
  local pattern = ast.node("TablePattern", {type_check: "table", fields: {}}, token)
  for(let local p in values(params)){
    append(pattern.fields, ast.node("FieldPattern", {value: p}, token))
  }
  // the let binds in the clause's scope when it is a declaration's value
  // (inside an if condition its locals would end with the if)
  local check = ast.node("Let", {pattern: pattern, right: id("args", token)}, token)
  append(statements, ast.node("Declaration", {is_local: true, left: id("__def_matched", token), right: check}, token))
  append(statements, ast.node("If", {condition: ast.node("UnOp", {op: "not", operand: id("__def_matched", token)}, token), thenBranch: no_match_return(token)}, token))
  if(rest_name != null){
    local rest_call = ast.node("Call", {function: field(id("__def", token), "rest", token), args: {id("args", token), ast.node("Int", {value: len(params)}, token)}}, token)
    append(statements, ast.node("Declaration", {is_local: true, left: id(rest_name, token), right: rest_call}, token))
  }
  if(guard != null){
    append(statements, ast.node("If", {condition: ast.node("UnOp", {op: "not", operand: guard}, token), thenBranch: no_match_return(token)}, token))
  }
  for(let local s in values(body.statements)){
    append(statements, s)
  }
  return ast.node("Function", {params: {id("args", token)}, body: ast.node("Block", {statements: statements}, token)}, token)
}

local declared = {}

local param = peg.choice(
  peg.seq(g:token("...", "...", "operator"), g:rule("identifier")):map(func(v){ return {rest: v[1].value} }),
  g:rule("slang_pattern"):map(localize)
)

g:statement("def", peg.seq(
  g:token("local"):optional(),
  g:keyword("def"),
  g:tag(g:rule("identifier"), "function.declaration"),
  g:token("("), param:star_separated(g:token(",")):map(func(s){ return s.elements }), g:token(")"),
  peg.seq(g:token("when", "when", "keyword"), g:token("("), g:rule("expr"), g:token(")")):pick(2):optional(),
  g:rule("block")
):map(func(v){
  local token = v[1]
  local name = v[2].value
  local params = {}
  local rest_name = null
  for(let local p in values(v[4])){
    if(p.rest != null){
      rest_name = p.rest
    } else {
      append(params, p)
    }
  }
  local f = clause_function(params, rest_name, v[6], v[7], token)
  local existing = id(name, token)
  local is_local = v[0] != null
  local first = declared[name] == null
  declared[name] = true
  if(is_local and first){
    existing = ast.node("Null", {}, token)
  }
  local define = ast.node("Call", {function: field(id("__def", token), "define", token), args: {
    existing, ast.node("String", {value: name}, token), ast.node("Int", {value: len(params)}, token),
    ast.node(rest_name != null and "True" or "False", {}, token), f,
  }}, token)
  if(is_local and first){
    return {token: token, ast: ast.node("Declaration", {is_local: true, left: id(name, token), right: define}, token)}
  }
  return {token: token, ast: ast.node("Assignment", {left: id(name, token), right: define}, token)}
}))
