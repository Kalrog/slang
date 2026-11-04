// mix: an online partial evaluator for a subset of slang.
//
//   local mix = require("mix")
//   local program = +{block:
//     func power(x, n){
//       local r = 1
//       for(local i = 0; i < n; i = i + 1){ r = r * x }
//       return r
//     }
//   }
//   local spec = mix.specialize(program, "power", {n: 3})
//   print(spec:source())      // local func power(x){ return 1 * x * x * x }
//   spec:load()(2)            // 8
//
// A program is a quoted block of function declarations. specialize takes
// one of them, the entry, and the values of some of its parameters (the
// static ones; the others stay dynamic) and returns the residual program:
// the entry function with the static parameters gone and everything that
// depended only on them computed, together with the specialized versions
// of the functions it still calls.
//
// How it works: the AST is walked with an environment that holds, for
// every variable, either its value (static) or nothing but its name
// (dynamic). Expressions over static values are evaluated; the rest are
// rebuilt as residual code. A static condition picks its branch, a
// dynamic one keeps both and afterwards every variable the branches
// disagree on becomes dynamic (each branch assigns its value). A loop
// whose condition stays static is unrolled; otherwise the variables it
// changes are made dynamic before it and it is emitted as a loop. A call
// of a program function with some static arguments specializes that
// function to them (memoized on the static values, so recursion over
// static data terminates when the data does); a specialized function
// without recursion is inlined at the call site. Table literals of static
// fields are static values; static tables are read-only (a write to one
// is an error: build it at run time instead, or wrap it in dynamic(...)).
// Calls of unknown functions stay in the residual, except the pure
// builtins (len, count, type, concat, string, ...) and whatever
// options.pure lists, which are evaluated on static arguments.
//
// Calls of error and raise never return, so nothing after them is
// specialized. The residual code is tidied (a local read once, first,
// is written where it is read; {a, b}[0] is a; {...{a: 1}, b: 2} is
// {a: 1, b: 2}) and arity-raised: a residual function whose calls all
// pass a table literal in a parameter takes the literal's fields as
// parameters instead, so f({n: a}) with env.n in its body becomes f(a)
// with n in its body (see examples/futamura/lisp.slang, where this
// turns the interpreter's environments into parameters).
//
// Supported: literals, tables (spread included), identifiers, indexing,
// operators, if, for, break, continue, return, local declarations,
// assignments, function literals (closures) and calls, method calls
// (never evaluated). Not supported: let patterns, for-in, try, throw,
// defer, labels, rest parameters.
//
// options: {statics: {name: value}, pure: {function, ...}, unroll: int,
//           limit: int, raise: bool}
//   statics: values the program refers to by global name (modules, say);
//     the residual refers to them by the same name and spec:load() binds
//     them.
//   pure: functions that may be called at specialization time on static
//     arguments.
//   unroll: the most iterations a static loop is unrolled (default 256);
//     beyond it the loop is emitted as a loop.
//   limit: the most specializations of one function (default 1000); more
//     is an error, usually a static argument that should be dynamic.
//   raise: false leaves the arity raising out.
//
// Residual functions are named after the program function they
// specialize, plus the identifier-like strings among the static
// arguments (lookup(program, "main") gives lookup_main), or after a
// hint(name) statement in the function's body with a static name (an
// interpreter names the specialization of a function body after the
// function it interprets); hint does nothing at run time.
local ast = require("slang/ast")
local str = require("slang/string")

local mix = {}

local func N(t, fields){ return ast.node(t, fields, null) }
local func ident(name){ return N("Identifier", {value: name}) }
local func S(v){ return {static: true, value: v} }
local func D(n){ return {static: false, node: n} }

local fn_meta = {__type: "MixFunction"}
local spec_meta = {__type: "MixSpecialization"}

local simple_types = {Identifier: true, Int: true, Double: true, String: true, True: true, False: true, Null: true}

local func is_name(s){
  if(type(s) != "string" or len(s) == 0){ return false }
  for(local i = 0; i < len(s); i = i + 1){
    local c = str.byte_at(s, i)
    local ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or (i > 0 and c >= '0' and c <= '9')
    if(not ok){ return false }
  }
  return true
}

local keywords = {
  ["local"]: true, ["func"]: true, ["if"]: true, ["else"]: true, ["for"]: true, ["in"]: true,
  ["let"]: true, ["return"]: true, ["break"]: true, ["continue"]: true, ["true"]: true,
  ["false"]: true, ["null"]: true, ["and"]: true, ["or"]: true, ["not"]: true, ["try"]: true,
  ["catch"]: true, ["throw"]: true, ["defer"]: true, ["extension"]: true, ["module"]: true,
  ["run"]: true, ["async"]: true, ["await"]: true,
}

// a usable identifier made from any string: other characters become _
local func identifier_name(s){
  local out = {}
  for(local i = 0; i < len(s); i = i + 1){
    local c = str.byte_at(s, i)
    local ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or (i > 0 and c >= '0' and c <= '9')
    append(out, if(ok){ str.substring(s, i, i + 1) } else { "_" })
  }
  local name = str.join(out, "")
  if(keywords[name]){ name = concat(name, "_") }
  return name
}

local func same_value(a, b){
  if(same(a, b)){ return true }
  if(type(a) == "table" and type(b) == "table"){ return a == b }
  if(type(a) == "table" or type(b) == "table"){ return false }
  if(type(a) == "MixFunction" or type(b) == "MixFunction"){ return false }
  return a == b
}

// ------------------------------------------------------------ environment

local func new_env(){ return {scopes: {{}}} }

local func push_scope(env){ append(env.scopes, {}) }
local func pop_scope(env){ remove(env.scopes, len(env.scopes) - 1) }

local func lookup(env, name){
  for(local i = len(env.scopes) - 1; i >= 0; i = i - 1){
    local b = env.scopes[i][name]
    if(b != null){ return b }
  }
  return null
}

local func declare(env, name, binding){
  env.scopes[len(env.scopes) - 1][name] = binding
}

local func copy_env(env){
  local scopes = {}
  for(let local scope in values(env.scopes)){
    local c = {}
    for(let local name in keys(scope)){
      c[name] = {...scope[name]}
    }
    append(scopes, c)
  }
  return {scopes: scopes}
}

// env becomes a copy of the snapshot again (in place: every context
// shares the env object)
local func restore_env(env, snapshot){
  env.scopes = copy_env(snapshot).scopes
}

// the bindings of old (by scope and name) that differ in new
local func env_diff(old, new){
  local diffs = {}
  for(local i = 0; i < len(old.scopes); i = i + 1){
    local scope = old.scopes[i]
    for(let local name in keys(scope)){
      local a = scope[name]
      local b = new.scopes[i][name]
      if(a.static and (not b.static or not same_value(a.value, b.value))){
        append(diffs, {scope: i, name: name, old: a, new: b})
      }
    }
  }
  return diffs
}

// ------------------------------------------------------------ residual AST helpers

local func placeholder(){
  return N("Block", {statements: {}, placeholder: true})
}

// the placeholder becomes `local name = value` (the declaration of a
// variable that turned dynamic; value is null for a plain `local name`)
// and says whether it did
local func resolve_placeholder(node, name, value){
  if(node == null or node.type != "Block"){ return false }
  node.statements = null
  node.placeholder = null
  node.left = ident(name)
  node.right = value
  node.is_local = true
  ast.node("Declaration", node, null)
  return true
}

local func has_declaration(block){
  if(block.type != "Block"){ return false }
  for(let local s in values(block.statements)){
    if(s.type == "Declaration" and s.is_local){ return true }
  }
  return false
}

// a break or continue in these statements that no loop here catches
local func has_loose_jump(stmts){
  for(let local s in values(stmts)){
    local t = s.type
    if(t == "Break" or t == "Continue"){ return true }
    if(t == "Block" and has_loose_jump(s.statements)){ return true }
    if(t == "If"){
      if(has_loose_jump(s.thenBranch.statements)){ return true }
      if(s.elseBranch != null and has_loose_jump(s.elseBranch.statements)){ return true }
    }
  }
  return false
}

// a return in these statements (outside nested functions)
local func has_return(stmts){
  for(let local s in values(stmts)){
    local t = s.type
    if(t == "Return"){ return true }
    if(t == "Block" and has_return(s.statements)){ return true }
    if(t == "If"){
      if(has_return(s.thenBranch.statements)){ return true }
      if(s.elseBranch != null and has_return(s.elseBranch.statements)){ return true }
    }
    if(t == "For" and has_return(s.body.statements)){ return true }
  }
  return false
}

local func block_of(stmts){ return N("Block", {statements: stmts}) }

// a literal node (a table literal of literals included) back to a static value
local func unlift(node){
  local t = node.type
  if(t == "Int" or t == "Double" or t == "String"){ return S(node.value) }
  if(t == "True"){ return S(true) }
  if(t == "False"){ return S(false) }
  if(t == "Null"){ return S(null) }
  if(t == "Table"){
    local value = {}
    for(let local f in values(node.fields)){
      if(f.type != "Field"){ return D(node) }
      local v = unlift(f.value)
      if(not v.static){ return D(node) }
      if(f.key == null){
        value[count(value)] = v.value
      } else {
        local k = unlift(f.key)
        if(not k.static or k.value == null){ return D(node) }
        value[k.value] = v.value
      }
    }
    return S(value)
  }
  return D(node)
}

local func clone(node, map){
  if(node == null){ return null }
  if(node.type == "Identifier"){
    local r = map[node.value]
    if(r != null){ return clone(r, {}) }
    r = ident(node.value)
    r.tag = node.tag
    return r
  }
  if(node.type == "Function"){
    local inner = {...map}
    for(let local p in values(node.params)){ inner[p.value] = null }
    local params = {}
    for(let local p in values(node.params)){ append(params, ident(p.value)) }
    return N("Function", {params: params, body: clone(node.body, inner)})
  }
  if(node.type == "Block"){
    local inner = {...map}
    local stmts = {}
    for(let local s in values(node.statements)){
      append(stmts, clone(s, inner))
      if(s.type == "Declaration" and s.is_local and s.left.type == "Identifier"){
        inner[s.left.value] = null
      }
    }
    return N("Block", {statements: stmts, placeholder: node.placeholder})
  }
  if(node.type == "For"){
    local inner = {...map}
    local init = clone(node.init, inner)
    if(node.init != null and node.init.type == "Declaration" and node.init.left.type == "Identifier"){
      inner[node.init.left.value] = null
    }
    return N("For", {
      init: init, condition: clone(node.condition, inner), update: clone(node.update, inner),
      body: clone(node.body, inner), label: node.label,
    })
  }
  local fields = {tag: node.tag}
  for(let local f in values(ast.specs[node.type])){
    local v = node[f[0]]
    if(f[1] == "list"){
      local l = {}
      for(let local x in values(v)){ append(l, clone(x, map)) }
      fields[f[0]] = l
    } else if(f[1] == "value"){
      fields[f[0]] = v
    } else {
      fields[f[0]] = clone(v, map)
    }
  }
  return N(node.type, fields)
}

local func strip_tags(node){
  if(node == null){ return }
  node.tag = null
  for(let local f in values(ast.specs[node.type])){
    local v = node[f[0]]
    if(f[1] == "list"){
      for(let local x in values(v)){ strip_tags(x) }
    } else if(f[1] != "value"){
      strip_tags(v)
    }
  }
}

local func has_call(node){
  if(node == null){ return false }
  if(node.type == "Call" or node.type == "Invoke"){ return true }
  for(let local f in values(ast.specs[node.type])){
    local v = node[f[0]]
    if(f[1] == "list"){
      for(let local x in values(v)){ if(has_call(x)){ return true } }
    } else if(f[1] != "value"){
      if(has_call(v)){ return true }
    }
  }
  return false
}

// the tags of node in evaluation order, or null when a tagged node is
// evaluated conditionally (the right side of and/or, a branch of an if
// expression, a function body)
local func tag_order(node, tags, conditional){
  if(node == null){ return true }
  if(node.tag != null){
    if(conditional){ return false }
    append(tags, node.tag)
  }
  local t = node.type
  if(t == "BinOp" and (node.op == "and" or node.op == "or")){
    return tag_order(node.left, tags, conditional) and tag_order(node.right, tags, true)
  }
  if(t == "IfExpr"){
    return tag_order(node.condition, tags, conditional) and
      tag_order(node.thenValue, tags, true) and tag_order(node.elseValue, tags, true)
  }
  if(t == "Function"){ return tag_order(node.body, tags, true) }
  for(let local f in values(ast.specs[t])){
    local v = node[f[0]]
    if(f[1] == "list"){
      for(let local x in values(v)){ if(not tag_order(x, tags, conditional)){ return false } }
    } else if(f[1] != "value"){
      if(not tag_order(v, tags, conditional)){ return false }
    }
  }
  return true
}

// every name node declares (locals and nested parameters) and every
// identifier it mentions
local func names_in(node, declared, used){
  if(node == null){ return }
  if(node.type == "Identifier"){ used[node.value] = true return }
  if(node.type == "Declaration" and node.is_local and node.left.type == "Identifier"){
    declared[node.left.value] = true
  }
  if(node.type == "Function"){
    for(let local p in values(node.params)){ declared[p.value] = true }
  }
  for(let local f in values(ast.specs[node.type])){
    local v = node[f[0]]
    if(f[1] == "list"){
      for(let local x in values(v)){ names_in(x, declared, used) }
    } else if(f[1] != "value"){
      names_in(v, declared, used)
    }
  }
}

local func count_uses(node, name){
  if(node == null){ return 0 }
  if(node.type == "Identifier"){ return if(node.value == name){ 1 } else { 0 } }
  local n = 0
  for(let local f in values(ast.specs[node.type])){
    local v = node[f[0]]
    if(f[1] == "list"){
      for(let local x in values(v)){ n = n + count_uses(x, name) }
    } else if(f[1] != "value"){
      n = n + count_uses(v, name)
    }
  }
  return n
}

// Whether a statement reaches a use of name before anything with an
// effect runs: only names and literals are evaluated before it, no call,
// operator or index (metamethods), and not inside a conditional part (the
// right side of and/or, a branch of an if expression, a function). Then
// an expression computed right before the statement can be computed at
// that use instead.
local func use_first(stmt, name){
  local t = stmt.type
  local parts = null
  if(t == "Return"){ parts = {stmt.value} }
  else if(t == "Declaration"){ parts = {stmt.right} }
  else if(t == "CallStat"){ parts = {stmt.call} }
  else if(t == "If"){ parts = {stmt.condition} }
  else if(t == "Assignment"){
    if(stmt.left.type == "Identifier"){ parts = {stmt.right} }
    else if(stmt.left.type == "Index"){ parts = {stmt.left.receiver, stmt.left.index, stmt.right} }
    else { return false }
  } else { return false }
  // "found", "blocked" or null (nothing yet)
  local scan
  local func scan_all(nodes){
    for(let local n in values(nodes)){
      local r = scan(n)
      if(r != null){ return r }
    }
    return null
  }
  scan = func(node){
    if(node == null){ return null }
    local k = node.type
    if(k == "Identifier"){ return if(node.value == name){ "found" } else { null } }
    if(simple_types[k] != null or k == "Null" or k == "True" or k == "False"){ return null }
    if(k == "Table"){
      for(let local f in values(node.fields)){
        local r
        if(f.type == "Spread"){ r = scan(f.value) }
        else if(f.type == "Field"){ r = scan_all({f.key, f.value}) }
        else { return "blocked" }
        if(r != null){ return r }
      }
      return null
    }
    if(k == "Index"){ return scan_all({node.receiver, node.index}) or "blocked" }
    if(k == "BinOp"){
      if(node.op == "and" or node.op == "or"){ return scan(node.left) or "blocked" }
      return scan_all({node.left, node.right}) or "blocked"
    }
    if(k == "UnOp"){ return scan(node.operand) or "blocked" }
    if(k == "Call"){ return scan(node.function) or scan_all(node.args) or "blocked" }
    if(k == "Invoke"){ return scan(node.receiver) or scan_all(node.args) or "blocked" }
    if(k == "IfExpr"){ return scan(node.condition) or "blocked" }
    return "blocked"
  }
  return scan_all(parts) == "found"
}

// an expression without effects: a name, a literal, a table literal of such
local func pure_node(node){
  if(node == null){ return false }
  if(simple_types[node.type] != null){ return true }
  if(node.type != "Table"){ return false }
  for(let local f in values(node.fields)){
    if(f.type == "Spread"){
      if(not pure_node(f.value)){ return false }
    } else if(f.type != "Field" or not pure_node(f.value) or
              (f.key != null and f.key.type != "String" and f.key.type != "Int")){
      return false
    }
  }
  return true
}

// the key a literal index picks: an int for t[0], a string for t.a
local func literal_key(index){
  if(index.type == "Int" or index.type == "String"){ return index.value }
  return null
}

// the uses of name that index it with a constant (t[0]); a bare use counts 0
local func count_indexed_uses(node, name){
  if(node == null){ return 0 }
  if(node.type == "Index" and node.receiver.type == "Identifier" and node.receiver.value == name and
     literal_key(node.index) != null){
    return 1 + count_indexed_uses(node.index, name)
  }
  local n = 0
  for(let local f in values(ast.specs[node.type])){
    local v = node[f[0]]
    if(f[1] == "list"){
      for(let local x in values(v)){ n = n + count_indexed_uses(x, name) }
    } else if(f[1] != "value"){
      n = n + count_indexed_uses(v, name)
    }
  }
  return n
}

// node becomes a copy of other, in place
local func replace_node(node, other){
  for(let local f in values(ast.specs[node.type])){ node[f[0]] = null }
  node.tag = null
  for(let local f in values(ast.specs[other.type])){ node[f[0]] = other[f[0]] }
  ast.node(other.type, node, null)
}

// {...{a: 1}, b: 2} is {a: 1, b: 2}: a spread of a literal is its fields
local func flatten_table(node){
  if(node.type != "Table"){ return }
  local fields = {}
  for(let local f in values(node.fields)){
    if(f.type == "Spread" and f.value.type == "Table"){
      for(let local g in values(f.value.fields)){ append(fields, g) }
    } else {
      append(fields, f)
    }
  }
  node.fields = fields
}

// {a, b}[1] is b, {...t, a: 1}.a is 1 and {...t, a: 1}.b is t.b, when the
// literal has no effects to lose (pure) and the field is not in doubt
local func simplify_index(node){
  if(node.type != "Index" or node.receiver.type != "Table"){ return }
  local key = literal_key(node.index)
  if(key == null or not pure_node(node.receiver)){ return }
  local fields = node.receiver.fields
  local position = 0
  local found = null
  local spread = null
  for(let local f in values(fields)){
    if(f.type == "Spread"){
      if(spread != null or found != null){ return }   // two spreads, or one after the field
      spread = f.value
    } else if(f.key == null){
      if(key == position){ found = f.value }
      position = position + 1
    } else if(f.key.value == key){
      found = f.value
    }
  }
  if(found != null){
    replace_node(node, found)
  } else if(spread != null){
    replace_node(node, N("Index", {receiver: spread, index: node.index, dotStyle: node.dotStyle}))
  } else {
    replace_node(node, N("Null", {}))
  }
}

local func is_local_value(s){
  return s.type == "Declaration" and s.is_local and s.left.type == "Identifier" and
    s.right != null and s.right.type != "Function"
}

// finished residual code: placeholders that were never resolved go;
// `local x` directly followed by `x = e` is `local x = e`; `local v = e`
// followed by `v = f(v)` (v once, evaluated first) is `local v = f(e)`;
// and `local v = e` followed by the only remaining use of v, evaluated
// first in that statement, puts e there. Evaluation order never changes:
// e was computed right before the statement that now computes it first.
local tidy_node
local func tidy_list(stmts){
  local out = {}
  for(let local s in values(stmts)){
    if(not (s.type == "Block" and s.placeholder)){
      tidy_node(s)
      append(out, s)
    }
  }
  local i = 0
  for(i < len(out)){
    local s = out[i]
    local next = out[i + 1]
    if(next == null){ break }
    local declares = s.type == "Declaration" and s.is_local and s.left.type == "Identifier"
    local v = if(declares){ s.left.value } else { null }
    if(declares and s.right == null and next.type == "Assignment" and next.left.type == "Identifier" and
       next.left.value == v){
      s.right = next.right
      remove(out, i + 1)
      continue
    }
    if(is_local_value(s)){
      local reassigns = next.type == "Assignment" and next.left.type == "Identifier" and next.left.value == v
      local in_next = count_uses(if(reassigns){ next.right } else { next }, v)
      if(reassigns and in_next == 0 and pure_node(s.right)){
        // a value overwritten before any use
        s.right = next.right
        remove(out, i + 1)
        continue
      }
      // every use of a pure table picks a field: the copies vanish
      local indexed = pure_node(s.right) and not reassigns and in_next > 0 and
        count_indexed_uses(next, v) == in_next
      if((in_next == 1 or indexed) and use_first(next, v)){
        if(reassigns){
          s.right = clone(next.right, {[v]: s.right})
          tidy_node(s)
          remove(out, i + 1)
          continue
        }
        local later = 0
        for(local j = i + 2; j < len(out); j = j + 1){ later = later + count_uses(out[j], v) }
        if(later == 0){
          out[i + 1] = clone(next, {[v]: s.right})
          tidy_node(out[i + 1])
          remove(out, i)
          continue
        }
      }
    }
    i = i + 1
  }
  return out
}
tidy_node = func(node){
  if(node == null){ return }
  if(node.type == "Block"){
    node.statements = tidy_list(node.statements)
    return
  }
  for(let local f in values(ast.specs[node.type])){
    local v = node[f[0]]
    if(f[1] == "list"){
      for(let local x in values(v)){ tidy_node(x) }
    } else if(f[1] != "value"){
      tidy_node(v)
    }
  }
  flatten_table(node)
  simplify_index(node)
}

// a deep copy of a node, substituting identifiers by map (scope-aware:
// a local declaration of a name hides its substitution from then on)
// ------------------------------------------------------------ static evaluation

local binops = {
  ["+"]: func(a, b) => a + b, ["-"]: func(a, b) => a - b, ["*"]: func(a, b) => a * b,
  ["/"]: func(a, b) => a / b, ["%"]: func(a, b) => a % b, ["^"]: func(a, b) => a ^ b,
  ["=="]: func(a, b) => a == b, ["!="]: func(a, b) => a != b,
  ["<"]: func(a, b) => a < b, ["<="]: func(a, b) => a <= b,
  [">"]: func(a, b) => a > b, [">="]: func(a, b) => a >= b,
  ["&"]: func(a, b) => a & b, ["|"]: func(a, b) => a | b, ["~"]: func(a, b) => a ~ b,
  ["<<"]: func(a, b) => a << b, [">>"]: func(a, b) => a >> b,
}
local unops = {
  ["-"]: func(a) => -a, ["not"]: func(a) => not a, ["~"]: func(a) => ~a,
}

local default_pure = {len, count, type, concat, string, to_int, to_float, same, get_raw}

// the globals every slang program has: the residual refers to them by name
local builtins = {
  print: print, len: len, count: count, type: type, concat: concat, string: string,
  keys: keys, values: values, entries: entries, append: append, remove: remove,
  error: error, same: same, get_raw: get_raw, set_raw: set_raw, to_int: to_int,
  to_float: to_float, assert: assert, raise: raise, pcall: pcall, require: require,
  compile: compile,
}

// ------------------------------------------------------------ the specializer

local Mix = {}
local mix_meta = {__index: Mix}

local func unsupported(node){
  error("mix: ", node.type, " is not supported")
}

// lift(w) -> node: a wrapped value as residual code
func Mix.lift(self, w){
  if(not w.static){ return w.node }
  return self:lift_value(w.value)
}

func Mix.lift_value(self, v){
  local t = type(v)
  if(t == "int"){ return N("Int", {value: v}) }
  if(t == "double"){ return N("Double", {value: v}) }
  if(t == "string"){ return N("String", {value: v}) }
  if(t == "bool"){ return N(if(v){ "True" } else { "False" }, {}) }
  if(v == null){ return N("Null", {}) }
  if(t == "MixFunction"){
    local spec = self:specialize_function(v, {})
    self.current_calls[spec] = true
    return ident(self:name_of(spec))
  }
  local path = self.paths[v]
  if(path != null){ return clone(path, {}) }
  if(t == "function"){ error("mix: cannot put a function value into the residual program") }
  if(t != "table" or v.@meta != null){
    error("mix: cannot put a ", t, " with a metatable into the residual program")
  }
  local fields = {}
  local n = len(v)
  for(local i = 0; i < n; i = i + 1){
    append(fields, N("Field", {key: null, value: self:lift_value(v[i])}))
  }
  for(let local k in keys(v)){
    if(not (type(k) == "int" and k >= 0 and k < n)){
      append(fields, N("Field", {key: self:lift_value(k), value: self:lift_value(v[k])}))
    }
  }
  return N("Table", {fields: fields})
}

func Mix.unique(self, base){
  if(self.names[base] == null){
    self.names[base] = 1
    return base
  }
  local n = self.names[base]
  for(true){
    local name = concat(base, "_", n)
    n = n + 1
    if(self.names[name] == null){
      self.names[base] = n
      self.names[name] = 1
      return name
    }
  }
}

// a specialization is named when the residual first refers to it
// a specialization is named when the residual first refers to it: after
// its hint(...), or after the identifier-like strings among its static
// arguments (lookup(program, "main") is lookup_main), or its function
func Mix.name_of(self, spec){
  if(spec.name != null){ return spec.name }
  local base = spec.fn.name
  if(spec.hint != null){
    base = identifier_name(spec.hint)
  } else {
    local parts = {base}
    for(let local a in values(spec.args)){
      local v = a.value
      if(a.static and type(v) == "string" and len(v) <= 24 and is_name(v) and not keywords[v] and len(parts) < 3){
        append(parts, v)
      }
    }
    base = str.join(parts, "_")
  }
  spec.name = self:unique(base)
  return spec.name
}

// x is dynamic from here on, holding its static value: its declaration
// becomes `local x = value` when it is still open (no residual code read x
// in between), otherwise x = value is emitted here
func Mix.generalize(self, ctx, name, binding){
  if(not binding.static){ return }
  local value = binding.value
  binding.static = false
  local lifted = null
  if(value != null){ lifted = self:lift_value(value) }
  if(binding.placeholder != null){
    local ph = binding.placeholder
    binding.placeholder = null
    if(resolve_placeholder(ph, name, lifted)){ return }
  }
  if(lifted == null){ lifted = N("Null", {}) }
  append(ctx.out, N("Assignment", {left: ident(name), right: lifted}))
}

func Mix.emit(self, ctx, stmt){ append(ctx.out, stmt) }

// ----------------------------------------------------------- expressions

func Mix.expr(self, ctx, node){
  local t = node.type
  if(t == "Int" or t == "Double" or t == "String"){ return S(node.value) }
  if(t == "True"){ return S(true) }
  if(t == "False"){ return S(false) }
  if(t == "Null"){ return S(null) }
  if(t == "Identifier"){ return self:identifier(ctx, node.value) }
  if(t == "BinOp"){ return self:binop(ctx, node) }
  if(t == "UnOp"){
    local w = self:expr(ctx, node.operand)
    if(w.static){
      local r = pcall(unops[node.op], w.value)
      if(r[0] == "ok"){ return S(r[1]) }
    }
    return D(N("UnOp", {op: node.op, operand: self:lift(w)}))
  }
  if(t == "Index"){ return self:index(ctx, node) }
  if(t == "Meta"){
    return D(N("Meta", {receiver: self:lift(self:expr(ctx, node.receiver))}))
  }
  if(t == "Call"){ return self:call(ctx, node) }
  if(t == "Invoke"){
    local args = {}
    for(let local a in values(node.args)){ append(args, self:lift(self:expr(ctx, a))) }
    return D(N("Invoke", {
      receiver: self:lift(self:expr(ctx, node.receiver)), name: ident(node.name.value), args: args,
    }))
  }
  if(t == "Table"){ return self:table(ctx, node) }
  if(t == "Function"){ return self:closure(ctx, node) }
  if(t == "IfExpr"){
    local c = self:expr(ctx, node.condition)
    if(c.static){
      return self:expr(ctx, if(c.value){ node.thenValue } else { node.elseValue })
    }
    return D(N("IfExpr", {
      condition: c.node,
      thenValue: self:lift(self:expr(ctx, node.thenValue)),
      elseValue: self:lift(self:expr(ctx, node.elseValue)),
    }))
  }
  unsupported(node)
}

func Mix.identifier(self, ctx, name){
  local b = lookup(ctx.env, name)
  if(b != null){
    if(b.static){ return S(b.value) }
    return D(ident(name))
  }
  b = self.globals[name]
  if(b != null){ return S(b.value) }
  return D(ident(name))
}

func Mix.binop(self, ctx, node){
  local op = node.op
  local l = self:expr(ctx, node.left)
  if(op == "and" or op == "or"){
    if(l.static){
      local truthy = l.value != null and l.value != false
      if((op == "and") == truthy){ return self:expr(ctx, node.right) }
      return l
    }
    return D(N("BinOp", {left: l.node, op: op, right: self:lift(self:expr(ctx, node.right))}))
  }
  local r = self:expr(ctx, node.right)
  if(l.static and r.static){
    local res = pcall(binops[op], l.value, r.value)
    if(res[0] == "ok"){ return S(res[1]) }
  }
  return D(N("BinOp", {left: self:lift(l), op: op, right: self:lift(r)}))
}

func Mix.index(self, ctx, node){
  local r = self:expr(ctx, node.receiver)
  local k = self:expr(ctx, node.index)
  if(r.static and k.static){
    if(type(r.value) == "MixFunction"){ error("mix: indexing a program function") }
    local res = pcall(func(t, k) => t[k], r.value, k.value)
    if(res[0] == "ok"){
      local v = res[1]
      if((type(v) == "table" or type(v) == "function") and self.paths[r.value] != null and self.paths[v] == null){
        self.paths[v] = N("Index", {receiver: self.paths[r.value], index: self:lift_value(k.value), dotStyle: is_name(k.value)})
      }
      return S(v)
    }
  }
  local key = self:lift(k)
  return D(N("Index", {receiver: self:lift(r), index: key, dotStyle: key.type == "String" and is_name(key.value)}))
}

func Mix.table(self, ctx, node){
  local all_static = true
  local fields = {}
  for(let local f in values(node.fields)){
    if(f.type == "Field"){
      local k = null
      if(f.key != null){ k = self:expr(ctx, f.key) }
      local v = self:expr(ctx, f.value)
      if(not v.static or (k != null and not k.static)){ all_static = false }
      append(fields, {key: k, value: v})
    } else if(f.type == "Spread"){
      local v = self:expr(ctx, f.value)
      if(v.static and type(v.value) == "table"){
        // a static table spread: its entries, in place
        local t = v.value
        local n = len(t)
        for(local i = 0; i < n; i = i + 1){ append(fields, {key: null, value: S(t[i])}) }
        for(let local k in keys(t)){
          if(not (type(k) == "int" and k >= 0 and k < n)){ append(fields, {key: S(k), value: S(t[k])}) }
        }
      } else {
        all_static = false
        append(fields, {spread: true, value: v})
      }
    } else if(f.type == "MetaField"){
      all_static = false
      append(fields, {meta: true, value: self:expr(ctx, f.value)})
    } else {
      unsupported(f)
    }
  }
  if(all_static){
    local t = {}
    local n = 0
    for(let local f in values(fields)){
      if(f.key == null){
        t[n] = f.value.value
        n = n + 1
      } else {
        t[f.key.value] = f.value.value
      }
    }
    return S(t)
  }
  local nodes = {}
  for(let local f in values(fields)){
    if(f.meta){
      append(nodes, N("MetaField", {value: self:lift(f.value)}))
    } else if(f.spread){
      append(nodes, N("Spread", {value: self:lift(f.value)}))
    } else {
      local key = null
      if(f.key != null){ key = self:lift(f.key) }
      append(nodes, N("Field", {key: key, value: self:lift(f.value)}))
    }
  }
  return D(N("Table", {fields: nodes}))
}

// a function literal: the static locals it mentions become dynamic (it
// captures them by reference), then its body is specialized on its own
func Mix.closure(self, ctx, node){
  local declared = {}
  local used = {}
  names_in(node, declared, used)
  for(let local name in keys(used)){
    local b = lookup(ctx.env, name)
    if(b != null and b.static){ self:generalize(ctx, name, b) }
  }
  push_scope(ctx.env)
  local params = {}
  for(let local p in values(node.params)){
    if(len(p.value) > 3 and p.value[0] == '.'){ error("mix: rest parameters are not supported") }
    declare(ctx.env, p.value, {static: false})
    append(params, ident(p.value))
  }
  local inner = {env: ctx.env, out: {}, loop_depth: 0}
  self:block(inner, node.body, true)
  pop_scope(ctx.env)
  return D(N("Function", {params: params, body: block_of(inner.out)}))
}

// ----------------------------------------------------------- calls

// call(ctx, node, as_statement?) -> wrapped value, or null when the call
// was inlined as statements (as_statement only)
func Mix.call(self, ctx, node, as_statement){
  local f = node.function
  if(f.type == "Identifier" and f.value == "dynamic" and lookup(ctx.env, "dynamic") == null){
    if(len(node.args) != 1){ error("mix: dynamic takes one argument") }
    return D(self:lift(self:expr(ctx, node.args[0])))
  }
  if(f.type == "Identifier" and f.value == "hint" and lookup(ctx.env, "hint") == null){
    // hint(name): names the specialization being made; nothing at run time
    if(len(node.args) != 1){ error("mix: hint takes one argument") }
    local w = self:expr(ctx, node.args[0])
    if(w.static and type(w.value) == "string" and self.current_spec != null){ self.current_spec.hint = w.value }
    return S(null)
  }
  local fw = self:expr(ctx, f)
  local args = {}
  for(let local a in values(node.args)){ append(args, self:expr(ctx, a)) }
  if(fw.static){
    local v = fw.value
    if(type(v) == "MixFunction"){
      return self:call_program_function(ctx, v, args, as_statement)
    }
    if(type(v) == "function"){
      local all_static = self.pure[v] != null
      for(let local a in values(args)){ if(not a.static){ all_static = false } }
      if(all_static){
        local vals = {}
        for(local i = 0; i < len(args); i = i + 1){ vals[i] = args[i].value }
        local r = pcall(v, ...vals)
        if(r[0] == "ok"){ return S(r[1]) }
      }
    } else {
      error("mix: calling a static ", type(v), " value")
    }
  }
  local lifted = {}
  for(let local a in values(args)){ append(lifted, self:lift(a)) }
  local d = D(N("Call", {function: self:lift(fw), args: lifted}))
  if(fw.static and (fw.value == error or fw.value == raise)){ d.terminates = true }
  return d
}

func Mix.call_program_function(self, ctx, fn, args, as_statement){
  if(len(args) > len(fn.params)){
    error("mix: ", fn.name, " takes ", len(fn.params), " arguments, called with ", len(args))
  }
  for(local i = len(args); i < len(fn.params); i = i + 1){ append(args, S(null)) }
  local spec = self:specialize_function(fn, args)
  local dyn = {}    // the dynamic arguments, aligned with spec.params
  for(local i = 0; i < len(args); i = i + 1){
    if(not args[i].static){ append(dyn, args[i].node) }
  }
  local inlined = self:inline(ctx, spec, dyn, as_statement)
  if(inlined != null){
    for(let local callee in keys(spec.calls)){ self.current_calls[callee] = true }
    if(inlined.statements != null){
      for(let local s in values(inlined.statements)){ self:emit(ctx, s) }
      if(inlined.terminates){ return {static: false, node: null, terminates: true} }
      return null
    }
    if(inlined.value.terminates){ return inlined.value }
    tidy_node(inlined.value.node)
    return unlift(inlined.value.node)
  }
  self.current_calls[spec] = true
  return D(N("Call", {function: ident(self:name_of(spec)), args: dyn}))
}

// inline(ctx, spec, args, as_statement) -> {value: wrapped} | {statements} | null
func Mix.inline(self, ctx, spec, args, as_statement){
  if(not spec.done or spec.recursive){ return null }
  local body = spec.body
  local declared = {}
  local used = {}
  for(let local s in values(body)){ names_in(s, declared, used) }
  local map = {}
  local pre = {}
  for(local i = 0; i < len(spec.params); i = i + 1){
    local p = spec.params[i]
    local a = args[i]
    local a_declared = {}
    local a_used = {}
    names_in(a, a_declared, a_used)
    local captured = false
    for(let local n in keys(a_used)){ if(declared[n]){ captured = true } }
    local simple = simple_types[a.type] != null
    local uses = 0
    local indexed = 0
    for(let local s in values(body)){
      uses = uses + count_uses(s, p)
      indexed = indexed + count_indexed_uses(s, p)
    }
    if(simple and not captured){
      map[p] = a
    } else if(pure_node(a) and uses == indexed and not captured){
      // every use picks a field: the copies vanish (simplify_index)
      map[p] = a
    } else if(as_statement){
      local tmp = self:unique(p)
      append(pre, N("Declaration", {is_local: true, left: ident(tmp), right: a}))
      map[p] = ident(tmp)
    } else if(uses == 1 and not captured){
      map[p] = a
    } else {
      return null
    }
  }
  if(spec.term == "stop" and len(body) == 1 and body[0].type == "CallStat"){
    local d = D(clone(body[0].call, map))
    d.terminates = true
    if(as_statement){ return {statements: {N("CallStat", {call: d.node})}, terminates: true} }
    return {value: d}
  }
  if(not as_statement){ return self:inline_expression(body, map) }
  local stmts = {}
  local last = body[len(body) - 1]
  local n = len(body)
  if(last != null and last.type == "Return"){ n = n - 1 }
  local head = {}
  for(local i = 0; i < n; i = i + 1){ append(head, body[i]) }
  if(has_return(head)){ return null }
  for(let local s in values(head)){ append(stmts, clone(s, map)) }
  if(last != null and last.type == "Return" and last.value != null and (last.value.type == "Call" or last.value.type == "Invoke")){
    append(stmts, N("CallStat", {call: clone(last.value, map)}))
  }
  local needs_block = false
  for(let local s in values(stmts)){
    if(s.type == "Declaration" and s.is_local){ needs_block = true }
  }
  if(needs_block or len(pre) > 0){
    stmts = {block_of({...pre, ...stmts})}
  }
  return {statements: stmts}
}

// a body of `local x = e` declarations and a return as one expression:
// each local is used once, unconditionally, and in declaration order (so
// nothing is evaluated in another order than it was)
func Mix.inline_expression(self, body, map){
  local n = len(body)
  if(n == 0){ return null }
  local last = body[n - 1]
  if(last.type != "Return" or last.value == null){ return null }
  local names = {}
  local rhs = {}
  for(local i = 0; i < n - 1; i = i + 1){
    local d = body[i]
    local ok = d.type == "Declaration" and d.is_local and d.left.type == "Identifier" and d.right != null
    if(not ok){ return null }
    append(names, d.left.value)
    local e = clone(d.right, map)
    e.tag = i
    append(rhs, e)
  }
  local result = clone(last.value, map)
  for(local i = 0; i < len(names); i = i + 1){
    local name = names[i]
    local uses = count_uses(result, name)
    for(local j = i + 1; j < len(rhs); j = j + 1){ uses = uses + count_uses(rhs[j], name) }
    if(uses == 0 and not has_call(rhs[i])){ continue }
    if(uses != 1){ return null }
    local m = {[name]: rhs[i]}
    result = clone(result, m)
    for(local j = i + 1; j < len(rhs); j = j + 1){ rhs[j] = clone(rhs[j], m) }
  }
  local tags = {}
  if(not tag_order(result, tags, false)){ return null }
  for(local i = 1; i < len(tags); i = i + 1){
    if(tags[i] <= tags[i - 1]){ return null }
  }
  strip_tags(result)
  return {value: D(result)}
}

// a specialization of fn to the static arguments among args (memoized)
func Mix.specialize_function(self, fn, args){
  for(let local s in values(fn.specs)){
    local equal = len(s.args) == len(args)
    if(equal){
      for(local i = 0; i < len(args); i = i + 1){
        local a = s.args[i]
        local b = args[i]
        if(a.static != b.static or (a.static and not same_value(a.value, b.value))){ equal = false }
      }
    }
    if(equal){
      if(not s.done){ s.recursive = true }
      return s
    }
  }
  if(len(fn.specs) >= self.limit){
    local shown = {}
    for(let local a in values(args)){ append(shown, if(a.static){ string(a.value) } else { "?" }) }
    error("mix: ", fn.name, " was specialized more than ", self.limit, " times (last: ", str.join(shown, ", "), "); one of its arguments should be dynamic")
  }
  local spec = {
    fn: fn, args: args, name: null, params: {}, body: null,
    done: false, recursive: false, calls: {}, @meta: spec_meta,
  }
  append(fn.specs, spec)
  local env = new_env()
  local out = {}
  for(local i = 0; i < len(fn.params); i = i + 1){
    local p = fn.params[i].value
    if(len(p) > 3 and p[0] == '.'){ error("mix: rest parameters are not supported (", fn.name, ")") }
    local a = args[i]
    if(a == null or not a.static){
      declare(env, p, {static: false})
      append(spec.params, p)
    } else {
      local ph = placeholder()
      append(out, ph)
      declare(env, p, {static: true, value: a.value, placeholder: ph})
    }
  }
  local ctx = {env: env, out: out, loop_depth: 0}
  local saved = self.current_calls
  local saved_spec = self.current_spec
  self.current_calls = spec.calls
  self.current_spec = spec
  spec.term = self:block(ctx, fn.node.body, true)
  self.current_calls = saved
  self.current_spec = saved_spec
  spec.body = tidy_list(out)
  spec.done = true
  append(self.order, spec)
  return spec
}

// ----------------------------------------------------------- statements

// block(ctx, block, scoped?) -> termination: null, "return", "break",
// "continue" or "stop" (both branches of a residual if ended)
func Mix.block(self, ctx, block, scoped){
  if(scoped){ push_scope(ctx.env) }
  local term = null
  for(let local s in values(block.statements)){
    term = self:statement(ctx, s)
    if(term != null){ break }
  }
  if(scoped){ pop_scope(ctx.env) }
  return term
}

// a branch or loop body (a block, or the if of an else-if) as residual
// statements, into a list of its own
func Mix.sub_block(self, ctx, block){
  local inner = {env: ctx.env, out: {}, loop_depth: ctx.loop_depth}
  local term
  if(block.type == "Block"){
    term = self:block(inner, block, true)
  } else {
    push_scope(ctx.env)
    term = self:statement(inner, block)
    pop_scope(ctx.env)
  }
  return {out: inner.out, term: term}
}

// the statements of a specialized branch, spliced when the source block
// declares nothing (then no name can be captured)
func Mix.emit_branch(self, ctx, source, out){
  if(has_declaration(source)){
    if(len(out) > 0){ self:emit(ctx, block_of(out)) }
  } else {
    for(let local s in values(out)){ self:emit(ctx, s) }
  }
}

func Mix.statement(self, ctx, node){
  local t = node.type
  if(t == "Block"){
    local r = self:sub_block(ctx, node)
    self:emit_branch(ctx, node, r.out)
    return r.term
  }
  if(t == "CallStat"){
    if(node.call.type == "Call"){
      local w = self:call(ctx, node.call, true)
      if(w != null and not w.static and w.node != null){ self:emit(ctx, N("CallStat", {call: w.node})) }
      if(w != null and w.terminates){ return "stop" }
    } else {
      self:emit(ctx, N("CallStat", {call: self:lift(self:expr(ctx, node.call))}))
    }
    return null
  }
  if(t == "Return"){
    local value = null
    if(node.value != null){ value = self:lift(self:expr(ctx, node.value)) }
    self:emit(ctx, N("Return", {value: value}))
    return "return"
  }
  if(t == "Break" or t == "Continue"){
    if(node.label != null){ error("mix: labels are not supported") }
    self:emit(ctx, N(t, {label: null}))
    return if(t == "Break"){ "break" } else { "continue" }
  }
  if(t == "Declaration"){ return self:declaration(ctx, node) }
  if(t == "Assignment"){ return self:assignment(ctx, node) }
  if(t == "If"){ return self:if_statement(ctx, node) }
  if(t == "For"){ return self:for_statement(ctx, node) }
  unsupported(node)
}

func Mix.declaration(self, ctx, node){
  if(not node.is_local or node.left.type != "Identifier"){
    return self:assignment(ctx, N("Assignment", {left: node.left, right: node.right}))
  }
  local name = node.left.value
  local w = S(null)
  if(node.right != null){ w = self:expr(ctx, node.right) }
  if(w.terminates){
    self:emit(ctx, N("CallStat", {call: w.node}))
    return "stop"
  }
  if(w.static){
    local ph = placeholder()
    self:emit(ctx, ph)
    declare(ctx.env, name, {static: true, value: w.value, placeholder: ph})
  } else {
    self:emit(ctx, N("Declaration", {is_local: true, left: ident(name), right: w.node}))
    declare(ctx.env, name, {static: false})
  }
  return null
}

func Mix.assignment(self, ctx, node){
  local left = node.left
  if(left.type == "Identifier"){
    local name = left.value
    local b = lookup(ctx.env, name)
    if(b == null and self.globals[name] != null){
      error("mix: assignment to ", name, ", a program function or a static")
    }
    local w = self:expr(ctx, node.right)
    if(w.terminates){
      self:emit(ctx, N("CallStat", {call: w.node}))
      return "stop"
    }
    if(b == null){
      self:emit(ctx, N("Assignment", {left: ident(name), right: self:lift(w)}))
      return null
    }
    if(w.static and b.static){
      b.value = w.value
      return null
    }
    if(b.static){
      b.static = false
      b.value = null
      if(b.placeholder != null){
        resolve_placeholder(b.placeholder, name, null)
        b.placeholder = null
      }
    }
    self:emit(ctx, N("Assignment", {left: ident(name), right: self:lift(w)}))
    return null
  }
  if(left.type == "Index"){
    local r = self:expr(ctx, left.receiver)
    if(r.static){
      error("mix: a static table is read-only (", ast.to_source(left), "); build it at run time or wrap it in dynamic(...)")
    }
    local k = self:expr(ctx, left.index)
    local key = self:lift(k)
    local w = self:expr(ctx, node.right)
    self:emit(ctx, N("Assignment", {
      left: N("Index", {receiver: r.node, index: key, dotStyle: key.type == "String" and is_name(key.value)}),
      right: self:lift(w),
    }))
    return null
  }
  if(left.type == "Meta"){
    local r = self:lift(self:expr(ctx, left.receiver))
    self:emit(ctx, N("Assignment", {left: N("Meta", {receiver: r}), right: self:lift(self:expr(ctx, node.right))}))
    return null
  }
  unsupported(left)
}

func Mix.if_statement(self, ctx, node){
  local c = self:expr(ctx, node.condition)
  if(c.static){
    local branch = if(c.value != null and c.value != false){ node.thenBranch } else { node.elseBranch }
    if(branch == null){ return null }
    local r = self:sub_block(ctx, branch)
    self:emit_branch(ctx, branch, r.out)
    return r.term
  }
  local env = ctx.env
  local before = copy_env(env)
  local then_r = self:sub_block(ctx, node.thenBranch)
  local then_env = copy_env(env)
  restore_env(env, before)
  local else_r = {out: {}, term: null}
  if(node.elseBranch != null){ else_r = self:sub_block(ctx, node.elseBranch) }
  local else_env = copy_env(env)
  // merge the environments of the branches that fall through
  if(then_r.term != null and else_r.term == null){
    // the else state is the live one already
  } else if(then_r.term == null and else_r.term != null){
    restore_env(env, then_env)
  } else {
    for(local i = 0; i < len(then_env.scopes); i = i + 1){
      local scope = then_env.scopes[i]
      for(let local name in keys(scope)){
        local a = scope[name]
        local b = else_env.scopes[i][name]
        if(a.static and b.static and same_value(a.value, b.value)){ continue }
        if(a.static){
          self:generalize({out: then_r.out}, name, a)
        }
        if(b.static){
          self:generalize({out: else_r.out}, name, b)
        }
        a.static = false
        a.placeholder = null
      }
    }
    restore_env(env, then_env)
  }
  local then_b = block_of(then_r.out)
  local else_b = null
  if(len(else_r.out) > 0){ else_b = block_of(else_r.out) }
  if(len(then_r.out) == 0 and else_b != null){
    then_b = else_b
    else_b = null
    c = D(N("UnOp", {op: "not", operand: c.node}))
  }
  if(len(then_b.statements) == 0){
    if(c.node.type == "Call" or c.node.type == "Invoke"){ self:emit(ctx, N("CallStat", {call: c.node})) }
    return null
  }
  self:emit(ctx, N("If", {condition: c.node, thenBranch: then_b, elseBranch: else_b}))
  if(then_r.term != null and else_r.term != null){
    if(then_r.term == else_r.term and then_r.term != "stop"){ return then_r.term }
    return "stop"
  }
  return null
}

func Mix.for_statement(self, ctx, node){
  if(node.label != null){ error("mix: labels are not supported") }
  push_scope(ctx.env)
  local pre = {}      // init, and later the lifts before a residual loop
  local pre_ctx = {env: ctx.env, out: pre, loop_depth: ctx.loop_depth}
  if(node.init != null){ self:statement(pre_ctx, node.init) }
  local start = copy_env(ctx.env)
  // unroll while the condition is static
  local unrolled = self:unroll(ctx, node)
  local init_declared = node.init != null and node.init.type == "Declaration" and node.init.is_local
  if(unrolled == null){
    restore_env(ctx.env, start)
    local init_name = null
    if(init_declared and node.init.left.type == "Identifier"){ init_name = node.init.left.value }
    unrolled = self:residual_loop(ctx, node, init_name)
    local loop = unrolled.out[len(unrolled.out) - 1]
    if(loop.init == null and len(pre) == 1 and pre[0].type == "Declaration" and init_name != null and
       pre[0].left.value == init_name){
      loop.init = pre[0]
      pre = {}
    }
  }
  local stmts = {...pre, ...unrolled.out}
  local has_local = false
  for(let local s in values(stmts)){ if(s.type == "Declaration" and s.is_local){ has_local = true } }
  pop_scope(ctx.env)
  if(init_declared and has_local){
    self:emit(ctx, block_of(stmts))
  } else {
    for(let local s in values(stmts)){ self:emit(ctx, s) }
  }
  return unrolled.term
}

// unroll(ctx, node) -> {out, term} | null (when the loop cannot be unrolled)
func Mix.unroll(self, ctx, node){
  local out = {}
  local n = 0
  for(true){
    local c = self:expr(ctx, node.condition)
    if(not c.static){ return null }
    if(c.value == null or c.value == false){ return {out: out, term: null} }
    if(n >= self.unroll_limit){ return null }
    n = n + 1
    local r = self:sub_block(ctx, node.body)
    local body = r.out
    if(r.term == "break" or r.term == "continue"){ remove(body, len(body) - 1) }
    if(has_loose_jump(body)){ return null }
    if(has_declaration(node.body)){
      if(len(body) > 0){ append(out, block_of(body)) }
    } else {
      for(let local s in values(body)){ append(out, s) }
    }
    if(r.term == "break"){ return {out: out, term: null} }
    if(r.term == "return"){ return {out: out, term: "return"} }
    if(r.term == "stop"){ return {out: out, term: "return"} }
    if(node.update != null){
      local u = {env: ctx.env, out: out, loop_depth: ctx.loop_depth}
      self:statement(u, node.update)
    }
  }
}

// the loop as a loop: the variables it changes are generalized before it
func Mix.residual_loop(self, ctx, node, init_name){
  local start = copy_env(ctx.env)
  local lifts = {}
  local init = null
  for(true){
    restore_env(ctx.env, start)
    local c = self:expr(ctx, node.condition)
    local inner = {env: ctx.env, out: {}, loop_depth: ctx.loop_depth + 1}
    local term = self:block(inner, node.body, true)
    local update = {env: ctx.env, out: {}, loop_depth: ctx.loop_depth}
    if(node.update != null and term != "return"){ self:statement(update, node.update) }
    local diffs = env_diff(start, ctx.env)
    if(len(diffs) == 0){
      local body = inner.out
      local upd = null
      if(len(update.out) == 1){ upd = update.out[0] }
      if(len(update.out) > 1){ for(let local s in values(update.out)){ append(body, s) } }
      local loop = N("For", {init: init, condition: self:lift(c), update: upd, body: block_of(body), label: null})
      return {out: {...lifts, loop}, term: null}
    }
    for(let local d in values(diffs)){
      local b = start.scopes[d.scope][d.name]
      if(d.name == init_name and d.scope == len(start.scopes) - 1 and b.placeholder != null){
        // the loop variable: declared by the residual loop itself
        init = N("Declaration", {is_local: true, left: ident(d.name), right: self:lift_value(b.value)})
        b.static = false
        b.placeholder = null
      } else {
        self:generalize({out: lifts}, d.name, b)
      }
    }
  }
}

// ----------------------------------------------------------- arity raising
//
// A residual function whose every call passes a table literal for a
// parameter, and whose body only picks fields of that parameter, takes
// the fields as parameters instead: f({n: a}) with env.n in its body
// becomes f(a) with n in its body. The shape of the literal is what all
// the calls agree on: a table of fields (positional or by literal key,
// with a spread first at most), a constant, or anything else (a leaf,
// which becomes one parameter). Fields of the parameter the body reads
// beyond the shape index the new parameter; the parameter itself, or a
// field that is a table in the shape, is rebuilt as a literal.

local func leaf(){ return {kind: "leaf"} }

local func shape_of(node){
  if(node == null){ return leaf() }
  local t = node.type
  if(t == "Int" or t == "Double" or t == "String" or t == "True" or t == "False" or t == "Null"){
    return {kind: "const", node: node}
  }
  if(t != "Table"){ return leaf() }
  local shape = {kind: "table", spread: null, entries: {}}
  local position = 0
  for(local i = 0; i < len(node.fields); i = i + 1){
    local f = node.fields[i]
    if(f.type == "Spread"){
      if(i != 0){ return leaf() }
      shape.spread = leaf()
    } else if(f.type == "Field"){
      local key = null
      if(f.key == null){
        key = position
        position = position + 1
      } else {
        key = literal_key(f.key)
        if(key == null){ return leaf() }
      }
      append(shape.entries, {key: key, shape: shape_of(f.value)})
    } else {
      return leaf()
    }
  }
  return shape
}

local func intersect(a, b){
  if(a.kind == "const" and b.kind == "const" and a.node.type == b.node.type and a.node.value == b.node.value){
    return a
  }
  if(a.kind == "table" and b.kind == "table" and (a.spread == null) == (b.spread == null)){
    // positional entries must agree; a keyed entry missing on one side
    // is the constant null there (a field holding null does not exist)
    local entries = {}
    local absent = {kind: "const", node: N("Null", {})}
    local func entry_of(shape, key){
      for(let local e in values(shape.entries)){ if(e.key == key){ return e.shape } }
      if(type(key) == "int"){ return null }
      return absent
    }
    for(let local e in values(a.entries)){
      local other = entry_of(b, e.key)
      if(other == null){ return leaf() }
      append(entries, {key: e.key, shape: intersect(e.shape, other)})
    }
    for(let local e in values(b.entries)){
      if(entry_of(a, e.key) == absent){ append(entries, {key: e.key, shape: intersect(absent, e.shape)}) }
      else if(type(e.key) == "int" and entry_of(a, e.key) == null){ return leaf() }
    }
    local spread = null
    if(a.spread != null){ spread = leaf() }
    return {kind: "table", spread: spread, entries: entries}
  }
  return leaf()
}

// the calls of name in node (the call nodes), and how often name is used
// otherwise (as a value: then its arity cannot change)
local func collect_calls(node, name, calls, other){
  if(node == null){ return }
  if(node.type == "Call" and node.function.type == "Identifier" and node.function.value == name){
    append(calls, node)
    for(let local a in values(node.args)){ collect_calls(a, name, calls, other) }
    return
  }
  if(node.type == "Identifier"){
    if(node.value == name){ other[0] = other[0] + 1 }
    return
  }
  for(let local f in values(ast.specs[node.type])){
    local v = node[f[0]]
    if(f[1] == "list"){
      for(let local x in values(v)){ collect_calls(x, name, calls, other) }
    } else if(f[1] != "value"){
      collect_calls(v, name, calls, other)
    }
  }
}

// names the leaves of shape (in order), avoiding taken names
local func name_leaves(shape, param, path, taken, names){
  if(shape.kind == "leaf"){
    local last = path[len(path) - 1]
    local candidate = null
    if(type(last) == "string" and is_name(last) and not keywords[last]){ candidate = last }
    if(candidate == null or taken[candidate]){
      local parts = {param}
      for(let local k in values(path)){ append(parts, string(k)) }
      candidate = str.join(parts, "_")
      for(local n = 2; taken[candidate]; n = n + 1){ candidate = concat(str.join(parts, "_"), "_", n) }
    }
    taken[candidate] = true
    shape.name = candidate
    append(names, candidate)
  } else if(shape.kind == "table"){
    if(shape.spread != null){
      local candidate = param
      for(local n = 2; taken[candidate]; n = n + 1){ candidate = concat(param, "_", n) }
      taken[candidate] = true
      shape.spread.name = candidate
      append(names, candidate)
    }
    for(let local e in values(shape.entries)){
      name_leaves(e.shape, param, {...path, e.key}, taken, names)
    }
  }
}

local func key_node(key){
  if(type(key) == "int"){ return N("Int", {value: key}) }
  return N("String", {value: key})
}

// the value of a shape as code, from the new parameters
local func rebuild(shape){
  if(shape.kind == "leaf"){ return ident(shape.name) }
  if(shape.kind == "const"){ return clone(shape.node, {}) }
  local fields = {}
  if(shape.spread != null){ append(fields, N("Spread", {value: ident(shape.spread.name)})) }
  for(let local e in values(shape.entries)){
    local key = null
    if(type(e.key) == "string"){ key = key_node(e.key) }
    append(fields, N("Field", {key: key, value: rebuild(e.shape)}))
  }
  return N("Table", {fields: fields})
}

local func index_path(node, path, from){
  for(local i = from; i < len(path); i = i + 1){
    local key = path[i]
    node = N("Index", {receiver: node, index: key_node(key), dotStyle: type(key) == "string" and is_name(key)})
  }
  return node
}

// the code for parameter[path...] under shape
local func resolve(shape, path, i){
  if(i == len(path)){ return rebuild(shape) }
  if(shape.kind == "table"){
    for(let local e in values(shape.entries)){
      if(e.key == path[i]){ return resolve(e.shape, path, i + 1) }
    }
    if(shape.spread != null){ return index_path(ident(shape.spread.name), path, i) }
    return index_path(N("Null", {}), path, i)
  }
  if(shape.kind == "leaf"){ return index_path(ident(shape.name), path, i) }
  return index_path(clone(shape.node, {}), path, i)
}

// node with every use of param rewritten through shape
local func rewrite_uses(node, param, shape){
  if(node == null){ return null }
  if(node.type == "Identifier"){
    if(node.value == param){ return rebuild(shape) }
    return node
  }
  if(node.type == "Index"){
    local path = {}
    local root = node
    for(root.type == "Index" and literal_key(root.index) != null){
      path[len(path)] = literal_key(root.index)
      root = root.receiver
    }
    if(root.type == "Identifier" and root.value == param){
      // the path was collected innermost last
      local ordered = {}
      for(local i = len(path) - 1; i >= 0; i = i - 1){ append(ordered, path[i]) }
      return resolve(shape, ordered, 0)
    }
  }
  for(let local f in values(ast.specs[node.type])){
    local v = node[f[0]]
    if(f[1] == "list"){
      for(local i = 0; i < len(v); i = i + 1){ v[i] = rewrite_uses(v[i], param, shape) }
    } else if(f[1] != "value"){
      node[f[0]] = rewrite_uses(v, param, shape)
    }
  }
  return node
}

// the arguments a literal contributes under shape, in leaf order
local func extract(shape, arg, out){
  if(shape.kind == "leaf"){
    append(out, arg or N("Null", {}))
  } else if(shape.kind == "table"){
    local position = 0
    local fields = arg.fields
    local start = 0
    if(shape.spread != null){
      append(out, fields[0].value)
      start = 1
    }
    for(let local e in values(shape.entries)){
      local found = null
      for(local i = start; i < len(fields); i = i + 1){
        local f = fields[i]
        if(f.key == null){
          if(e.key == position){ found = f.value }
          position = position + 1
        } else if(f.key.value == e.key){
          found = f.value
        }
      }
      extract(e.shape, found, out)
    }
  }
}

// one round; whether anything changed
local func raise_arity_round(functions, entry){
  local changed = false
  for(let local fn in values(functions)){
    if(fn == entry or len(fn.params) == 0){ continue }
    local calls = {}
    local other = {0}
    for(let local g in values(functions)){
      for(let local s in values(g.body)){ collect_calls(s, fn.name, calls, other) }
    }
    if(other[0] > 0 or len(calls) == 0){ continue }
    local usable = true
    for(let local c in values(calls)){ if(len(c.args) != len(fn.params)){ usable = false } }
    if(not usable){ continue }
    local declared = {}
    local used = {}
    for(let local s in values(fn.body)){ names_in(s, declared, used) }
    local shapes = {}
    for(local i = 0; i < len(fn.params); i = i + 1){
      local shape = shape_of(calls[0].args[i])
      for(let local c in values(calls)){ shape = intersect(shape, shape_of(c.args[i])) }
      if(declared[fn.params[i]]){ shape = leaf() }
      shapes[i] = shape
    }
    local taken = {}
    for(let local n in keys(declared)){ taken[n] = true }
    for(let local n in keys(used)){ taken[n] = true }
    for(local i = 0; i < len(fn.params); i = i + 1){
      if(shapes[i].kind == "leaf"){ taken[fn.params[i]] = true } else { taken[fn.params[i]] = null }
    }
    local params = {}
    for(local i = 0; i < len(fn.params); i = i + 1){
      if(shapes[i].kind == "leaf"){
        shapes[i].name = fn.params[i]
        append(params, fn.params[i])
      } else {
        name_leaves(shapes[i], fn.params[i], {}, taken, params)
      }
    }
    for(local i = 0; i < len(fn.params); i = i + 1){
      if(shapes[i].kind != "leaf"){
        for(local j = 0; j < len(fn.body); j = j + 1){
          fn.body[j] = rewrite_uses(fn.body[j], fn.params[i], shapes[i])
        }
      }
    }
    local raised = false
    for(local i = 0; i < len(fn.params); i = i + 1){ if(shapes[i].kind != "leaf"){ raised = true } }
    if(not raised){ continue }
    for(let local c in values(calls)){
      local args = {}
      for(local i = 0; i < len(fn.params); i = i + 1){ extract(shapes[i], c.args[i], args) }
      c.args = args
    }
    fn.params = params
    changed = true
  }
  return changed
}

// raising one function can turn the calls of another into literals (a
// rebuilt {...env, op: op} flattens once env is a literal): repeat until
// nothing changes
local func raise_arity(functions, entry){
  for(local round = 0; round < 20; round = round + 1){
    local changed = raise_arity_round(functions, entry)
    for(let local f in values(functions)){ f.body = tidy_list(f.body) }
    if(not changed){ return }
  }
}

// ----------------------------------------------------------- results

local Spec = {}
local result_meta = {__index: Spec}

// the residual program as a list of statements (functions in dependency order)
func Spec.statements(self){
  local stmts = {}
  for(let local s in values(self.functions)){
    if(s.recursive){
      append(stmts, N("Declaration", {is_local: true, left: ident(s.name), right: null}))
    }
  }
  for(let local s in values(self.functions)){
    local params = {}
    for(let local p in values(s.params)){ append(params, ident(p)) }
    local f = N("Function", {params: params, body: block_of(s.body)})
    if(s.recursive){
      append(stmts, N("Assignment", {left: ident(s.name), right: f}))
    } else {
      append(stmts, N("Declaration", {is_local: true, left: ident(s.name), right: f}))
    }
  }
  return stmts
}

// source() -> string: the residual program as slang
func Spec.source(self){
  return ast.to_source(block_of(self:statements()))
}

// load() -> function: the residual entry, compiled, with the statics bound
func Spec.load(self){
  local stmts = {}
  for(let local name in keys(self.statics)){
    append(stmts, N("Declaration", {
      is_local: true, left: ident(name),
      right: N("Index", {receiver: ident("__statics"), index: N("String", {value: name}), dotStyle: true}),
    }))
  }
  for(let local s in values(self:statements())){ append(stmts, s) }
  append(stmts, N("Return", {value: ident(self.entry)}))
  local wrapper = block_of({N("Return", {value: N("Function", {params: {ident("__statics")}, body: block_of(stmts)})})})
  return compile(wrapper, "mix")()(self.statics)
}

// ----------------------------------------------------------- entry points

// the functions a program block declares, by name
local func program_functions(program){
  if(type(program) != "Block"){ error("mix: the program must be a quoted block (+{block: ...})") }
  local fns = {}
  for(let local s in values(program.statements)){
    local ok = s.type == "Declaration" and s.left.type == "Identifier" and s.right != null and s.right.type == "Function"
    if(not ok){
      error("mix: a program holds function declarations only, not ", ast.to_source(s))
    }
    fns[s.left.value] = {name: s.left.value, params: s.right.params, node: s.right, specs: {}, @meta: fn_meta}
  }
  return fns
}

// specialize(program: Block, entry: string, args: {[param]: value}, options?) -> Spec
// The residual program for entry with the given parameters fixed.
func mix.specialize(program, entry, args, options){
  options = options or {}
  args = args or {}
  local fns = program_functions(program)
  local fn = fns[entry]
  if(fn == null){ error("mix: no function ", entry, " in the program") }
  for(let local name in keys(args)){
    local found = false
    for(let local p in values(fn.params)){ if(p.value == name){ found = true } }
    if(not found){ error("mix: ", entry, " has no parameter ", name) }
  }
  local self = {
    globals: {}, statics: options.statics or {}, paths: {}, pure: {}, names: {},
    order: {}, limit: options.limit or 1000, unroll_limit: options.unroll or 256, current_calls: {},
    @meta: mix_meta,
  }
  for(let local name in keys(builtins)){
    self.globals[name] = {static: true, value: builtins[name]}
    self.paths[builtins[name]] = ident(name)
  }
  for(let local name in keys(fns)){ self.globals[name] = {static: true, value: fns[name]} }
  for(let local name in keys(self.statics)){
    self.globals[name] = {static: true, value: self.statics[name]}
    self.paths[self.statics[name]] = ident(name)
  }
  for(let local f in values(default_pure)){ self.pure[f] = true }
  for(let local f in values(options.pure or {})){ self.pure[f] = true }
  local wrapped = {}
  for(let local p in values(fn.params)){
    if(args[p.value] != null){
      append(wrapped, S(args[p.value]))
    } else {
      append(wrapped, D(ident(p.value)))
    }
  }
  local top = self:specialize_function(fn, wrapped)
  self:name_of(top)
  // the functions the entry reaches, callees first
  local reachable = {}
  local func reach(spec){
    if(reachable[spec]){ return }
    reachable[spec] = true
    for(let local callee in keys(spec.calls)){ reach(callee) }
  }
  reach(top)
  local functions = {}
  for(let local s in values(self.order)){ if(reachable[s]){ append(functions, s) } }
  if(options.raise != false){ raise_arity(functions, top) }
  return {entry: top.name, functions: functions, statics: self.statics, @meta: result_meta}
}

// load(program: Block) -> {[name]: function}: the program as it is, for
// running it unspecialized
func mix.load(program){
  local fns = program_functions(program)
  local stmts = {}
  local fields = {}
  for(let local s in values(program.statements)){
    append(stmts, N("Declaration", {is_local: true, left: ident(s.left.value), right: null}))
  }
  for(let local s in values(program.statements)){
    append(stmts, N("Assignment", {left: ident(s.left.value), right: s.right}))
  }
  for(let local name in keys(fns)){
    append(fields, N("Field", {key: N("String", {value: name}), value: ident(name)}))
  }
  append(stmts, N("Return", {value: N("Table", {fields: fields})}))
  return compile(block_of(stmts), "mix program")()
}

// dynamic(x) -> x: marks x as unknown to mix; the identity at run time
func mix.dynamic(x){ return x }
dynamic = mix.dynamic

// hint(name): names the specialization mix is making; nothing at run time
func mix.hint(name){ }
hint = mix.hint

return mix
