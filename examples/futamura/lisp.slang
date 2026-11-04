// A small first-order Lisp: the reader, the printer and an interpreter
// written for mix (examples/futamura/mix.slang).
//
//   local lisp = require("lisp")
//   local program = lisp.read("(define (main n) (fib n)) (define (fib n) ...)")
//   lisp.show(program)                     // the forms, printed back
//   mix.load(lisp.interpreter).run(program, 20)
//   mix.specialize(lisp.interpreter, "run", {program: program})
//
// Data: a number, a symbol (a slang string), a pair {car, cdr} and the
// empty list, which is null; #t and #f are slang's booleans. A string
// literal "abc" reads as (quote abc), so it is the symbol. A program is a
// list of definitions, (define (name param ...) body), and runs by
// calling main; run(program, a, b, c) passes a, b and c to main's parameters.
// The forms: a constant, a variable, (quote d), (if c a b), (let ((x e)
// ...) body) with the bindings in sequence, a call of a primitive (car
// cdr cons null? pair? number? symbol? eq? not + - * < error) or of a
// defined function.
//
// The interpreter is a quoted block (an AST, for mix) in the subset mix
// handles, written so that it specializes well: it recurses rather than
// loops, and the environment is a table of the variables by name, built
// as a literal, so that with the program static a variable specializes
// to env.x, a call's environment to {x: ..., y: ...}, and a defined
// function's body to a residual function of its environment (named after
// the Lisp function through hint, and with mix's arity raising, a
// function of the variables themselves).
//
// `lisp` is also a dialect module: with {dialects: {[".lisp"]: {compile:
// "lisp"}}} in slang.project, require("sint") loads sint.lisp as its
// program.
local str = require("slang/string")

local lisp = {}

// -------------------------------------------------------------- the reader

local func is_space(b){ return b == 32 or b == 9 or b == 10 or b == 13 }
local func is_delimiter(b){ return is_space(b) or b == '(' or b == ')' or b == '\'' or b == ';' }

local func quoted(v){ return {"quote", {v, null}} }

// read(text) -> list: the forms of text as a Lisp list
func lisp.read(text){
  local pos = 0
  local n = len(text)
  local func skip(){
    for(pos < n){
      local b = str.byte_at(text, pos)
      if(b == ';'){
        for(pos < n and str.byte_at(text, pos) != 10){ pos = pos + 1 }
      } else if(is_space(b)){
        pos = pos + 1
      } else {
        return
      }
    }
  }
  local read_form
  local func read_list(){
    local items = {}
    for(true){
      skip()
      if(pos >= n){ error("lisp: missing )") }
      if(str.byte_at(text, pos) == ')'){
        pos = pos + 1
        break
      }
      append(items, read_form())
    }
    local list = null
    for(local i = len(items) - 1; i >= 0; i = i - 1){ list = {items[i], list} }
    return list
  }
  read_form = func(){
    skip()
    if(pos >= n){ error("lisp: unexpected end of input") }
    local b = str.byte_at(text, pos)
    if(b == '('){
      pos = pos + 1
      return read_list()
    }
    if(b == ')'){ error("lisp: unexpected ) at ", pos) }
    if(b == '\''){
      pos = pos + 1
      return quoted(read_form())
    }
    if(b == '"'){
      local start = pos + 1
      pos = start
      for(pos < n and str.byte_at(text, pos) != '"'){ pos = pos + 1 }
      if(pos >= n){ error("lisp: missing \"") }
      pos = pos + 1
      return quoted(str.substring(text, start, pos - 1))
    }
    local start = pos
    for(pos < n and not is_delimiter(str.byte_at(text, pos))){ pos = pos + 1 }
    local token = str.substring(text, start, pos)
    if(token == "#t"){ return quoted(true) }
    if(token == "#f"){ return quoted(false) }
    local number = str.to_number(token)
    if(number != null){ return number }
    return token
  }
  local forms = {}
  for(true){
    skip()
    if(pos >= n){ break }
    append(forms, read_form())
  }
  local list = null
  for(local i = len(forms) - 1; i >= 0; i = i - 1){ list = {forms[i], list} }
  return list
}

// show(value) -> string: a value as the reader would read it
func lisp.show(v){
  if(v == null){ return "()" }
  if(v == true){ return "#t" }
  if(v == false){ return "#f" }
  if(type(v) != "table"){ return string(v) }
  local parts = {}
  for(v != null and type(v) == "table"){
    append(parts, lisp.show(v[0]))
    v = v[1]
  }
  if(v != null){ append(parts, concat(". ", lisp.show(v))) }
  return concat("(", str.join(parts, " "), ")")
}

// to_list(value) -> table: a Lisp list as a slang list
func lisp.to_list(v){
  local out = {}
  for(v != null){
    append(out, v[0])
    v = v[1]
  }
  return out
}

// ----------------------------------------------------------- the interpreter

lisp.interpreter = +{block:
  func car(p){ return p[0] }
  func cdr(p){ return p[1] }

  // run(program, a, b, c): calls main with as many of a, b and c as it
  // has parameters
  func run(program, a, b, c){
    local def = lookup(program, "main")
    local params = params_of(def)
    local env = {}
    if(params != null){
      env = {[car(params)]: a}
      if(cdr(params) != null){
        env = {...env, [car(cdr(params))]: b}
        if(cdr(cdr(params)) != null){ env = {...env, [car(cdr(cdr(params)))]: c} }
      }
    }
    return apply_def(program, def, env)
  }

  // (define (name param ...) body)
  func params_of(def){ return cdr(car(cdr(def))) }
  func body_of(def){ return car(cdr(cdr(def))) }
  func lookup(program, name){
    if(program == null){ error("lisp: undefined function ", name) }
    if(car(car(cdr(car(program)))) == name){ return car(program) }
    return lookup(cdr(program), name)
  }

  // the body of def in env, a table of the variables by name; mix names
  // the specialization after the function
  func apply_def(program, def, env){
    hint(car(car(cdr(def))))
    return eval(program, body_of(def), env)
  }

  func eval(program, e, env){
    if(type(e) == "string"){ return env[e] }
    if(type(e) != "table"){ return e }
    local op = car(e)
    local args = cdr(e)
    if(op == "quote"){ return car(args) }
    if(op == "if"){
      return if(eval(program, car(args), env)){
        eval(program, car(cdr(args)), env)
      } else {
        eval(program, car(cdr(cdr(args))), env)
      }
    }
    if(op == "let"){ return let_form(program, car(args), car(cdr(args)), env) }
    if(op == "car"){ return car(eval(program, car(args), env)) }
    if(op == "cdr"){ return cdr(eval(program, car(args), env)) }
    if(op == "cons"){ return {eval(program, car(args), env), eval(program, car(cdr(args)), env)} }
    if(op == "null?"){ return eval(program, car(args), env) == null }
    if(op == "pair?"){ return type(eval(program, car(args), env)) == "table" }
    if(op == "number?"){ return type(eval(program, car(args), env)) == "int" }
    if(op == "symbol?"){ return type(eval(program, car(args), env)) == "string" }
    if(op == "not"){ return not eval(program, car(args), env) }
    if(op == "eq?"){ return eval(program, car(args), env) == eval(program, car(cdr(args)), env) }
    if(op == "+"){ return eval(program, car(args), env) + eval(program, car(cdr(args)), env) }
    if(op == "-"){ return eval(program, car(args), env) - eval(program, car(cdr(args)), env) }
    if(op == "*"){ return eval(program, car(args), env) * eval(program, car(cdr(args)), env) }
    if(op == "<"){ return eval(program, car(args), env) < eval(program, car(cdr(args)), env) }
    if(op == "error"){ error("lisp: ", eval(program, car(args), env)) }
    local def = lookup(program, op)
    return apply_def(program, def, bind(program, params_of(def), args, env))
  }

  // the environment of a call: the parameters, bound to the arguments
  // evaluated in the caller's environment
  func bind(program, params, args, env){
    if(params == null){ return {} }
    return {[car(params)]: eval(program, car(args), env), ...bind(program, cdr(params), cdr(args), env)}
  }

  // (let ((x e) ...) body): each binding sees the ones before it
  func let_form(program, bindings, body, env){
    if(bindings == null){ return eval(program, body, env) }
    local binding = car(bindings)
    return let_form(
      program, cdr(bindings), body,
      {...env, [car(binding)]: eval(program, car(cdr(binding)), env)}
    )
  }
}

// ------------------------------------------------------------- the dialect

// compile(source, origin) -> func(): the program read from a .lisp file
func lisp.compile(source, origin){
  local program = lisp.read(source)
  return func(){ return program }
}

return lisp
