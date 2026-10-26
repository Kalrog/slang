// slang/compiler: the compiler driver. Defines the global `compile` and the
// `slang/parser` module through which programs extend the grammar.
local peg = require("slang/peg")
local ast = require("slang/ast")
local grammar = require("slang/grammar")
local codegen = require("slang/codegen")
local optimizer = require("slang/optimizer")
local vm = require("slang/vm")
local os = require("slang/os")
local str = require("slang/string")

local compiler = {}
local current = null

// runs a block of code at parse time (unquote)
local func run_block(block){
  local f = vm.load_proto(codegen.generate(block, "unquote"))
  return f()
}

// modules loaded by extension statements (forgotten on reset so they run again)
local loaded_extensions = {}

// load_extension(name) -> module: runs name.slang at compile time, like require
func compiler.load_extension(name){
  local m = require(name)
  append(loaded_extensions, name)
  return m
}

// runs an extension statement: a String node names a file, a Block node is code
local func run_extension(node, origin){
  if(node.type == "String"){
    return compiler.load_extension(node.value)
  }
  local f = vm.load_proto(codegen.generate(node, origin))
  return f()
}

// grammar warnings (modified rules, failed probes) are a development aid
local func warn(message){
  print("grammar warning: ", message, "\n")
}

local func new_grammar(){
  peg.reset_refs()
  local opts = {run_block: run_block, run_extension: run_extension, optimize: optimizer.optimize}
  if(os.getenv("SLANG_GRAMMAR_WARNINGS") != null){
    opts.warn = warn
  }
  return grammar.new(opts)
}

current = new_grammar()

func compiler.grammar(){
  return current
}

func compiler.reset(){
  if(not current:changes_allowed()){
    error("the grammar can only be reset at run time or from an extension statement")
  }
  for(let local name in values(loaded_extensions)){
    __PACKAGES.preloaded[name] = null
  }
  loaded_extensions = {}
  current = new_grammar()
}

// parse(source, origin) -> AST
func compiler.parse(source, origin){
  return current:parse_source(source, origin or "string")
}

// generate(node, origin) -> prototype table
func compiler.generate(node, origin){
  return codegen.generate(node, origin or "string")
}

// compile(code, origin) -> function; code is source text or an AST table
func compiler.compile(code, origin, trace){
  origin = origin or "string"
  local node
  if(type(code) == "string"){
    node = current:parse_source(code, origin)
  } else {
    node = ast.decode(code)
  }
  return vm.load_proto(codegen.generate(node, origin))
}

// ------------------------------------------------------------ bytecode cache
//
// Files loaded through load_file (require and `slang run`) are cached as
// bytecode in $SLANG_CACHE_DIR (default ~/.cache/slang), keyed by origin,
// path and content hash. A file is only cached when it was compiled with the
// unextended grammar and ran no code at compile time, so caching can never
// change what a program does. SLANG_NO_CACHE=1 disables the cache.

local cache_dir = null

local func get_cache_dir(){
  if(cache_dir != null){
    return cache_dir
  }
  cache_dir = ""
  if(os.getenv("SLANG_NO_CACHE") != null){
    return ""
  }
  local dir = os.getenv("SLANG_CACHE_DIR")
  if(dir == null){
    local home = os.getenv("HOME")
    if(home == null){
      return ""
    }
    dir = concat(home, "/.cache/slang")
  }
  if(let {"ok"} = pcall(os.mkdir_all, dir)){
    cache_dir = dir
  }
  return cache_dir
}

// load_file(path, origin) -> function
func compiler.load_file(path, origin){
  origin = origin or path
  local source = os.read_file(path)
  local cache_path = null
  if(not current.extended){
    local dir = get_cache_dir()
    if(dir != ""){
      cache_path = concat(dir, "/", str.hash(concat(origin, "\n", path)), "-", str.hash(source), ".slb")
      if(os.exists(cache_path)){
        return vm.load_bytecode(cache_path)
      }
    }
  }
  local state = current.state
  local outer_effects = state.compile_time_effects
  state.compile_time_effects = false
  local node = current:parse_source(source, origin)
  local f = vm.load_proto(codegen.generate(node, origin))
  if(cache_path != null and not state.compile_time_effects and not current.extended){
    pcall(os.write_file, cache_path, vm.to_bytes(f))
  }
  state.compile_time_effects = outer_effects or state.compile_time_effects
  return f
}

// compile_repl(source) -> function returning the value of an expression or null
func compiler.compile_repl(source){
  local node = current:parse_repl(source)
  return vm.load_proto(codegen.generate(node, "repl"))
}

compile = compiler.compile

// ------------------------------------------------------------ slang/parser

local p = {}

local func decode_statement(value){
  local node = ast.decode(value)
  if(not ast.is_statement(node)){
    error("expected a statement, got ", node)
  }
  return node
}

local func decode_expression(value){
  return ast.decode(value)
}

// expression groups handed to extension code
local group_methods = {}
local group_meta = {__index: group_methods, __type: "group"}

local func wrap_group(group){
  local w = {group: group}
  w.meta = group_meta
  return w
}

func group_methods.prefix(self, parser, callback){
  self.group:prefix(parser, func(op, exp){
    return ast.decode(callback(op, ast.strip(exp)))
  })
  return self
}

func group_methods.postfix(self, parser, callback){
  self.group:postfix(parser, func(exp, op){
    return ast.decode(callback(ast.strip(exp), op))
  })
  return self
}

func group_methods.left(self, parser, callback){
  self.group:left(parser, func(left, op, right){
    return ast.decode(callback(ast.strip(left), op, ast.strip(right)))
  })
  return self
}

func group_methods.right(self, parser, callback){
  self.group:right(parser, func(left, op, right){
    return ast.decode(callback(ast.strip(left), op, ast.strip(right)))
  })
  return self
}

local func group_level(name, f){
  return {names: {name}, add: func(builder){
    local group = builder:group()
    f(wrap_group(group))
    return group
  }}
}

func p.string(s){
  return peg.string(s)
}

func p.token(s){
  return peg.ref(current.token, s)
}

func p.keyword(s){
  return current:keyword(s)
}

func p.add_statement(name, parser){
  current:add_statement(name, parser:map(decode_statement))
}

// add_extension_statement(name, parser, apply): a top-level-only statement
// whose apply(result) runs at compile time with grammar changes allowed and
// returns the statement to emit ({token, ast} or a node) or null
func p.add_extension_statement(name, parser, apply){
  current:add_extension_statement(name, parser, apply)
}

func p.add_primitive_expression(name, parser){
  current:add_primitive_expression({names: {name}, parser: parser:map(decode_expression)})
}

func p.add_primitive_expression_after(after, name, parser){
  current:add_primitive_expression_after(after, {names: {name}, parser: parser:map(decode_expression)})
}

func p.add_primitive_expression_before(before, name, parser){
  current:add_primitive_expression_before(before, {names: {name}, parser: parser:map(decode_expression)})
}

func p.add_expression_group_after(after, name, f){
  current:add_expression_group_after(after, group_level(name, f))
}

func p.add_expression_group_before(before, name, f){
  current:add_expression_group_before(before, group_level(name, f))
}

func p.add_expression_group_at(index, name, f){
  current:add_expression_group_at(index, group_level(name, f))
}

func p.add_expression_group(name, f){
  current:add_expression_group(group_level(name, f))
}

func p.get_primitive_expression_names(){
  return current:primitive_expression_names()
}

func p.get_expression_group_names(){
  return current:expression_group_names()
}

func p.identifier(){
  return peg.ref(current.identifier):map(ast.strip)
}

func p.expr(){
  return peg.ref(current.expr):map(ast.strip)
}

func p.stat(){
  return peg.ref(current.statement):map(ast.strip)
}

func p.block(brackets){
  if(brackets == false){
    return peg.ref(current.chunk):map(ast.strip)
  }
  return peg.ref(current.block):map(ast.strip)
}

func p.slang_pattern(){
  return peg.ref(current.slang_pattern):map(ast.strip)
}

func p.table_literal(){
  return peg.ref(current.table_literal):map(ast.strip)
}

local uniq_counter = 0

// origin() -> the name of the source being parsed (null outside a parse)
func p.origin(){
  return current.state.origin
}

// error_at(token, message...): raises a compile error located at token (a
// token as produced by p.token/p.keyword, or any table with line and column)
func p.error_at(token, ...message){
  local location = null
  if(type(token) == "table" and token.line != null){
    location = {line: token.line, column: token.column, origin: current.state.origin or "string"}
  }
  local text = ""
  for(let local part in values(message)){
    text = concat(text, part)
  }
  raise({message: text, location: location})
}

func p.uniq_id(){
  uniq_counter = uniq_counter + 1
  return {type: "Identifier", value: concat("uuid-", uniq_counter)}
}

func p.ast_to_string(value){
  if(value == null){
    return "null"
  }
  return ast.to_string(ast.decode(value))
}

// the rule registry: rule(name) refers to a grammar rule, define/modify
// change it (modify's function gets the current parser and returns the new
// one), rules() lists every rule with its provenance
func p.rule(name){
  return current:rule(name)
}

func p.define(name, parser, options){
  current:define(name, parser, options)
}

func p.modify(name, f){
  current:modify(name, f)
}

func p.rules(){
  return current:rules()
}

func p.resolve(parser){
  return peg.resolve(parser)
}

func p.reset(){
  compiler.reset()
}

p.char = peg.char
p.digit = peg.digit
p.seq = peg.seq
p.choice = peg.choice
p.pattern = peg.pattern
p.ref = peg.ref
p.any = peg.any
p.star = peg.star
p.star_lazy = peg.star_lazy
p.star_seperated = peg.star_separated
p.star_separated = peg.star_separated
p.plus = peg.plus
p.plus_seperated = peg.plus_separated
p.plus_separated = peg.plus_separated
p.optional = peg.optional
p.forbid = peg.forbid
p.pick = peg.pick
p.permute = peg.permute
p.map = peg.map
p.flatten = peg.flatten
p.end = peg.end
p.trim = peg.trim
p.letter = peg.letter
p.word = peg.word
p.whitespace = peg.whitespace
p.epsilon = peg.epsilon
p.parse = peg.parse

__PACKAGES.preloaded["slang/parser"] = {true, p}

return compiler
