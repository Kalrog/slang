// kernel/syntax: kernels written in the slang file that uses them.
//
//   extension "kernel/syntax"     // or extensions: {"kernel/syntax"} in slang.project
//
//   kernel {
//     struct Osc { phase: double, inc: double, gain: float = 0.3 }
//     local phase = 0.0
//     func saws(out: float[], oscs: Osc[], n: int){ ... }
//   }
//
//   local oscs = Osc:array(4)
//   saws(require("kernel").float:array(128), oscs, 128)
//
// A `kernel { ... }` statement holds kernel code (the language of
// README.md). It is compiled when the slang file is: a mistake in it is a
// compile error at its line in the file. After it, every struct and every
// entry point (`func`) of the block is a local of the slang code, as if
// declared there: structs as kernel.Struct values, entry points as
// kernels to call. Helpers (`local func`), constants and state stay
// inside. The compiled kernels are part of the file's code; running it
// loads them (once, when the statement runs) without compiling anything.
//
// The kernel code is highlighted and formatted by the kernel grammar
// (kernel/grammar), as in a .kernel file. The word `kernel` stays usable
// as a name: `kernel {` starts the statement only where a statement
// starts.
local peg = require("slang/peg")
local ast = require("slang/ast")
local fmt = require("slang/format")
local str = require("slang/string")
local buffer = require("slang/buffer")
local grammar = require("kernel/grammar")
local compiler = require("kernel/compiler")
local g = require("slang/compiler").grammar()

// ------------------------------------------------------------ the unit as code

// the numeric lists of a program, by the type the VM reads them as: packed
// into strings (buffer.from takes their bytes back)
local packed = {
  code: "uint32",
  iconsts: "int64",
  fregs: "int32",
  fvals: "double",
  params: "int32",
  lines: "int32",
  binds: "int64",
}

// Lines are written as "origin:line" strings, the form slang/format
// recognises as a location: formatting the file moves the kernel code to
// other lines without changing what the code means.
local func pack(program, origin){
  local out = {}
  for(let local e in entries(program)){
    local t = packed[e[0]]
    if(e[0] == "lines"){
      local pcs = {}
      local at = {}
      for(local i = 0; i < len(e[1]); i = i + 2){
        append(pcs, e[1][i])
        append(at, concat(origin, ":", string(e[1][i + 1])))
      }
      out.line_pcs = buffer.from(pcs, "int32"):to_string()
      out.line_at = at
    } else if(e[0] == "line"){
      out.line = concat(origin, ":", string(e[1]))
    } else if(t != null){
      out[e[0]] = buffer.from(e[1], t):to_string()
    } else {
      out[e[0]] = e[1]
    }
  }
  return out
}

// the AST of a value: a literal, or a table literal of its elements and
// fields
local func value_ast(v, token){
  if(type(v) != "table"){
    return ast.literal(token, v)
  }
  local fields = {}
  local n = len(v)
  for(local i = 0; i < n; i = i + 1){
    append(fields, ast.node(
      "Field", {key: null, value: value_ast(v[i], token)}, token
    ))
  }
  for(let local e in entries(v)){
    local key = e[0]
    if(type(key) == "int" and key >= 0 and key < n){
      continue
    }
    append(fields, ast.node("Field", {
      key: ast.literal(token, key),
      value: value_ast(e[1], token),
    }, token))
  }
  return ast.node("Table", {fields: fields}, token)
}

// ------------------------------------------------------------ the statement

// the message of a compiler error without its "origin:line: "
local func bare_message(e, origin){
  local msg = e.message
  local prefix = concat(origin, ":", string(e.line or 0), ": ")
  if(str.starts_with(msg, prefix)){
    return str.substring(msg, len(prefix))
  }
  return msg
}

local func expand(word, items){
  local origin = g:origin() or "kernel"
  local unit = null
  try {
    unit = compiler.compile_items(items, origin, null)
  } catch(local e) {
    if(e.line != null){
      g:error_at({line: e.line, column: 1}, bare_message(e, origin))
    }
    raise(e)
  }
  local programs = {}
  for(let local p in values(unit.kernels)){
    append(programs, pack(p, origin))
  }
  unit.kernels = programs
  // let {Osc: local Osc, saws: local saws} = kernel.module(<unit>)
  local runtime = g:unit_local("kernel", +{require("kernel")})
  local call = +{-{runtime}.module(-{value_ast(unit, word)})}
  local fields = {}
  local func bind(name, token){
    local id = ast.node("Identifier", {value: name}, token)
    append(fields, ast.node("FieldPattern", {
      key: ast.node("String", {value: name}, token),
      value: ast.node(
        "VarPattern", {isLocal: true, canBeNull: false, name: id}, token
      ),
    }, token))
  }
  local used = {}
  for(let local u in values(unit.uses)){
    used[u.module] = u.structs
  }
  for(let local item in values(items)){
    if(item.k == "struct" or (item.k == "func" and item.kernel)){
      bind(item.name, item.token)
    } else if(item.k == "use"){
      // the structs of a used module are locals too (its own values)
      for(let local name in values(used[item.module] or {})){
        bind(name, item.token)
      }
    }
  }
  if(len(fields) == 0){
    return {token: word, ast: ast.node("CallStat", {call: call}, word)}
  }
  local pattern = ast.node(
    "TablePattern", {type_check: "table", fields: fields}, word
  )
  return {
    token: word,
    ast: ast.node("LetStat", {pattern: pattern, right: call}, word),
  }
}

local tok = func(s, category){
  return peg.string(s):token(category or "punctuation"):trim(grammar.trivia)
}

g:statement("kernel_block", peg.seq(fmt.gaps(
  peg.seq(peg.string("kernel"), peg.pattern("a-zA-Z0-9_"):forbid())
    :pick(0)
    :token("keyword")
    :trim(grammar.trivia),
  null,
  "space",
), tok("{"), fmt.indent(grammar.items, "hardline", "hardline"), fmt.gaps(tok("}"), "hardline")):map(func(v){
  return expand(v[0], v[2])
}))
