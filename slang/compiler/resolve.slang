// slang/resolve: which declaration each name in a chunk refers to, and
// what is known about each local, before code is generated.
//
//   local info = resolve.analyse(block)
//   local b = info.refs[identifier_node]     // its Binding, null: a global
//   if(b != null and b.writes == 0){ ... }   // never assigned again
//
// The scoping is the compiler's (see slang/codegen): a local is visible
// from its declaration to the end of its block, a declaration's own right
// side already sees it (so `local func f` can call itself), a local may
// shadow one of an enclosing scope, and a name that is no local of any
// enclosing function is a global. Code in quotes is data, except what an
// unquote (-{...}) in it computes, which runs where the quote is.

local str = require("slang/string")
local ast = require("slang/ast")

local resolve = {}

// A local or parameter.
// type Binding = {name: string, kind: string, node: table, value?: table,
//   function?: table, reads: int, writes: int, captured: bool,
//   written_inside?: bool}
// [kind]: "local" (declared, also by a pattern) or "parameter"
// [node]: the node that declares it (the Identifier, VarPattern or param)
// [value]: the node a `local name = value` declaration gives it
// [function]: the Function node it belongs to; null at the chunk's level
// [reads]: the uses of its value
// [writes]: the assignments after its declaration
// [captured]: an inner function uses it (it lives in an upvalue)
// [written_inside]: an inner function assigns it

// What [analyse] finds.
// type Info = {bindings: {Binding}, refs: {[table]: Binding},
//   decls: {[table]: Binding}}
// [bindings]: every local and parameter, in the order they are declared
// [refs]: the Identifier (or VarPattern) nodes that read or assign a
// local, by node; a name missing here is a global
// [decls]: the binding each declaring node makes, by node

local walker = {}
local walker_meta = {__index: walker}

local literals = {Int: true, Double: true, String: true, True: true,
  False: true, Null: true}

local func new_walker(){
  local w = {
    info: {bindings: {}, refs: {}, decls: {}},
    // the scopes of the function being walked, innermost last: name ->
    // binding
    scopes: {{}},
    // the Function node being walked (null: the chunk)
    function: null,
  }
  w.@meta = walker_meta
  return w
}

func walker.enter(w){
  append(w.scopes, {})
}

func walker.leave(w){
  remove(w.scopes, len(w.scopes) - 1)
}

func walker.declare(w, name, node, kind, value){
  local b = {
    name: name, kind: kind, node: node, value: value, function: w.function,
    reads: 0, writes: 0, captured: false, written_inside: false,
  }
  w.scopes[len(w.scopes) - 1][name] = b
  append(w.info.bindings, b)
  w.info.decls[node] = b
  return b
}

func walker.lookup(w, name){
  for(local i = len(w.scopes) - 1; i >= 0; i = i - 1){
    local b = w.scopes[i][name]
    if(b != null){
      return b
    }
  }
  return null
}

// a use of name at node: a read, or an assignment when write
func walker.use(w, name, node, write){
  local b = w:lookup(name)
  if(b == null){
    return null
  }
  w.info.refs[node] = b
  local inside = b.function != w.function
  if(inside){
    b.captured = true
  }
  if(write){
    b.writes = b.writes + 1
    if(inside){
      b.written_inside = true
    }
  } else {
    b.reads = b.reads + 1
  }
  return b
}

local visitors = {}

// every child node of n, through the node specs (see ast.specs)
func walker.children(w, n){
  local spec = ast.specs[n.type]
  if(spec == null){
    return null
  }
  for(let local field in values(spec)){
    local child = n[field[0]]
    if(child != null){
      if(field[1] == "list"){
        for(let local item in values(child)){
          w:visit(item)
        }
      } else if(field[1] != "value"){
        w:visit(child)
      }
    }
  }
}

func walker.visit(w, n){
  local f = visitors[n.type]
  if(f != null){
    f(w, n)
  } else {
    w:children(n)
  }
}

func visitors.Identifier(w, n){
  w:use(n.value, n, false)
}

func visitors.Block(w, n){
  w:enter()
  for(let local s in values(n.statements)){
    w:visit(s)
  }
  w:leave()
}

func visitors.Declaration(w, n){
  local left = n.left
  if(n.is_global){
    // `global name = value` names the global, never a local
    if(n.right != null){
      w:visit(n.right)
    }
    return null
  }
  if(left.type != "Identifier"){
    // o.name = value, func o.name(){}
    w:visit(left)
    if(n.right != null){
      w:visit(n.right)
    }
    return null
  }
  if(n.is_local){
    w:declare(left.value, left, "local", n.right)
  } else {
    // `func name(){}` and `name = value` as a declaration: like an
    // assignment, a local (of this or an enclosing function), else a global
    w:use(left.value, left, true)
  }
  if(n.right != null){
    w:visit(n.right)
  }
}

func visitors.Assignment(w, n){
  local left = n.left
  if(left.type == "Identifier"){
    w:use(left.value, left, true)
  } else {
    w:visit(left)
  }
  w:visit(n.right)
}

// the value is matched before the pattern's locals exist: in
// `let local x = x` the right side is the outer x
func visitors.Let(w, n){
  w:visit(n.right)
  w:visit(n.pattern)
}

visitors.LetStat = visitors.Let

// o:name(args): the name is a key, not a use
func visitors.Invoke(w, n){
  w:visit(n.receiver)
  for(let local a in values(n.args)){
    w:visit(a)
  }
}

func visitors.Function(w, n){
  local outer = w.function
  w.function = n
  w:enter()
  for(let local p in values(n.params)){
    local name = p.value
    if(str.starts_with(name, "...")){
      name = str.substring(name, 3)
    }
    w:declare(name, p, "parameter", null)
  }
  w:visit(n.body)
  w:leave()
  w.function = outer
}

func visitors.If(w, n){
  // the condition's pattern locals are seen by both branches
  w:enter()
  w:visit(n.condition)
  w:visit(n.thenBranch)
  if(n.elseBranch != null){
    w:visit(n.elseBranch)
  }
  w:leave()
}

func visitors.For(w, n){
  w:enter()
  if(n.init != null){
    w:visit(n.init)
  }
  w:visit(n.condition)
  w:visit(n.body)
  if(n.update != null){
    w:visit(n.update)
  }
  w:leave()
}

func visitors.ForIn(w, n){
  w:enter()
  w:visit(n.itterator)
  w:visit(n.pattern)
  w:visit(n.body)
  w:leave()
}

func visitors.Try(w, n){
  w:visit(n.body)
  for(let local c in values(n.catches)){
    w:enter()
    if(c.pattern != null){
      w:visit(c.pattern)
    }
    w:visit(c.body)
    w:leave()
  }
}

func visitors.VarPattern(w, n){
  local name = n.name.value
  if(n.isLocal){
    w:declare(name, n, "local", null)
  } else {
    w:use(name, n, true)
  }
}

// a matcher pattern's matcher is an expression, its type name a value
func visitors.MatcherPattern(w, n){
  if(n.matcher != null){
    w:visit(n.matcher)
  }
  if(n.sub != null){
    w:visit(n.sub)
  }
}

// quoted code is data: only its unquotes run, where the quote is
local func visit_quoted(w, n){
  if(n.type == "Unquote"){
    w:visit(n.ast)
    return null
  }
  local spec = ast.specs[n.type]
  if(spec == null){
    return null
  }
  for(let local field in values(spec)){
    local child = n[field[0]]
    if(child != null and field[1] == "list"){
      for(let local item in values(child)){
        visit_quoted(w, item)
      }
    } else if(child != null and field[1] != "value"){
      visit_quoted(w, child)
    }
  }
}

func visitors.Quote(w, n){
  visit_quoted(w, n.ast)
}

// analyse(block: ast.Node) -> Info
// The bindings of a parsed chunk and the binding each name in it refers
// to (see [Info]).
func resolve.analyse(block){
  local w = new_walker()
  w:visit(block)
  return w.info
}

// constant(b: Binding) -> ast.Node?
// The literal a local always holds: one declared with a literal and never
// assigned again (by the chunk, an inner function or a pattern). Null for
// anything else.
func resolve.constant(b){
  if(b == null or b.kind != "local" or b.writes > 0 or b.value == null){
    return null
  }
  if(literals[b.value.type]){
    return b.value
  }
  return null
}

return resolve
