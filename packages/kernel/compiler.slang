// kernel/compiler: the kernel language to the bytecode of kernel/vm. It runs
// when a .kernel file (or a slang file's inline kernels) is compiled: it
// reads the source, checks its types and turns every `kernel func` into a
// program, a table of plain lists that kernel.load makes callable.
//
//   local c = require("kernel/compiler")
//   local unit = c.compile(source, "voice.kernel")
//   // unit.kernels: {program}, unit.structs: {struct}
//
// The language (see README.md): slang's statements with types; int and
// float (64-bit) values, bool; arrays and structs in buffers; helpers
// (`func`) inlined where they are called.
//
// The bytecode: 32-bit words `op | a << 8 | b << 16 | c << 24`, some with a
// word after them (a jump's target, a load's offset). Two register files of
// 256: I (int and bool) and F (float). Constants live in registers from 255
// down, which the VM fills before it runs; locals and temporaries grow from
// 0. Arrays are slots: a base, a length and an element size.
local str = require("slang/string")
local re = require("slang/regex")

local compiler = {}

// ------------------------------------------------------------ the opcodes

// Their order is the VM's (native/vm.zig); kernel.load checks that both
// agree.
compiler.OPS = {
  "nop",
  "movi", "movf",
  "addi", "subi", "muli", "divi", "modi", "negi", "andi", "ori", "xori",
  "shli", "shri", "noti",
  "addf", "subf", "mulf", "divf", "modf", "negf", "powf", "madf",
  "itof", "ftoi",
  "lti", "lei", "eqi", "nei", "ltf", "lef", "eqf", "nef", "notb",
  "jmp", "jt", "jf", "jlti", "jlei", "jeqi", "jnei", "jltf", "jlef", "jeqf",
  "jnef", "jnltf", "jnlef",
  "seli", "self",
  "len",
  "sin", "cos", "tan", "asin", "acos", "atan", "exp", "exp2", "log", "log2",
  "sqrt", "absf", "floor", "ceil", "round", "trunc", "fract", "tanh", "sinh",
  "cosh", "signf",
  "atan2", "minf", "maxf", "mini", "maxi", "absi", "signi",
  "ret", "reti", "retf",
  "ld_float", "ld_double", "ld_int8", "ld_uint8", "ld_int16", "ld_uint16",
  "ld_int32", "ld_uint32", "ld_int64", "ld_uint64", "ld_bool",
  "st_float", "st_double", "st_int8", "st_uint8", "st_int16", "st_uint16",
  "st_int32", "st_uint32", "st_int64", "st_uint64", "st_bool",
  "addi_jlti", "addi_jlei", "addi_jgti", "addi_jgei",
}
local OP = {}
for(local i = 0; i < len(compiler.OPS); i = i + 1){
  OP[compiler.OPS[i]] = i
}

// storage kinds: the element types of arrays and struct fields, by the
// names slang/buffer uses; their index is the VM's kind number
compiler.KINDS = {"float", "double", "int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64", "bool"}
local KIND = {}
local KIND_SIZE = {4, 8, 1, 1, 2, 2, 4, 4, 8, 8, 1}
for(local i = 0; i < len(compiler.KINDS); i = i + 1){
  KIND[compiler.KINDS[i]] = i
}
// the kind number of an array of structs (its element size says which)
compiler.STRUCT_KIND = 11

// the value type a storage kind reads as
local func value_of_kind(k){
  if(k == "float" or k == "double"){
    return "float"
  }
  if(k == "bool"){
    return "bool"
  }
  return "int"
}

// parameter kinds for the VM
local P_INT = 1
local P_FLOAT = 2
local P_BOOL = 3
local P_ARRAY = 4
local P_STRUCT = 5

// ------------------------------------------------------------ errors

local func fail(origin, line, ...parts){
  local msg = concat(origin, ":", string(line), ": ")
  for(let local p in values(parts)){
    msg = concat(msg, string(p))
  }
  error(msg)
}

// ------------------------------------------------------------ the lexer

local name_re = re.compile("[A-Za-z_][A-Za-z0-9_]*")
local number_re = re.compile("0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*(\\.[0-9_]*)?([eE][+-]?[0-9]+)?|\\.[0-9][0-9_]*([eE][+-]?[0-9]+)?")
// longest first
local symbols = {
  "+=", "-=", "*=", "/=", "%=", "==", "!=", "<=", ">=", "<<", ">>",
  "+", "-", "*", "/", "%", "^", "&", "|", "~", "<", ">", "=", "(", ")",
  "{", "}", "[", "]", ",", ".", ":", ";",
}
local keywords = {
  kernel: true, func: true, local: true, struct: true, ["if"]: true,
  ["else"]: true, ["for"]: true, ["break"]: true, ["continue"]: true,
  ["return"]: true, ["and"]: true, ["or"]: true, ["not"]: true,
  ["true"]: true, ["false"]: true,
}

// tokens: {kind ("name", "keyword", "int", "float", "op", "eof"), value,
// line, nl (a newline came before it)}
local func lex(src, origin, first_line){
  local tokens = {}
  local i = 0
  local n = len(src)
  local line = first_line or 1
  local nl = true
  for(i < n){
    local ch = str.byte_at(src, i)
    if(ch == '\n'){
      line = line + 1
      nl = true
      i = i + 1
    } else if(ch == ' ' or ch == '\t' or ch == '\r'){
      i = i + 1
    } else if(ch == '/' and str.byte_at(src, i + 1) == '/'){
      // a // comment, to the end of the line
      for(i < n and str.byte_at(src, i) != '\n'){
        i = i + 1
      }
    } else if(ch == '/' and str.byte_at(src, i + 1) == '*'){
      local close = str.index_of(src, "*/", i + 2)
      if(close < 0){
        fail(origin, line, "unclosed /* comment")
      }
      for(local k = i; k < close; k = k + 1){
        if(str.byte_at(src, k) == '\n'){
          line = line + 1
          nl = true
        }
      }
      i = close + 2
    } else {
      local e = name_re:match_at(src, i)
      local kind = null
      local value = null
      if(e > i){
        value = str.substring(src, i, e)
        kind = "name"
        if(keywords[value]){
          kind = "keyword"
        }
      } else {
        e = number_re:match_at(src, i)
        if(e > i){
          local text = str.substring(src, i, e)
          local clean = str.join(str.split(text, "_"), "")
          local is_hex = str.starts_with(clean, "0x") or str.starts_with(clean, "0X") or
            str.starts_with(clean, "0b") or str.starts_with(clean, "0B")
          if(not is_hex and (str.contains(clean, ".") or str.contains(clean, "e") or str.contains(clean, "E"))){
            kind = "float"
            value = str.to_number(clean) * 1.0
          } else if(is_hex){
            kind = "int"
            value = str.parse_int(clean, 0)
          } else {
            kind = "int"
            value = str.parse_int(clean, 10)
          }
          if(value == null){
            fail(origin, line, "bad number ", text)
          }
        } else {
          for(let local s in values(symbols)){
            if(kind == null and str.starts_with(src, s, i)){
              kind = "op"
              value = s
              e = i + len(s)
            }
          }
          if(kind == null){
            fail(origin, line, "unexpected character ", str.substring(src, i, i + 1))
          }
        }
      }
      append(tokens, {kind: kind, value: value, line: line, nl: nl})
      nl = false
      i = e
    }
  }
  append(tokens, {kind: "eof", value: "end of file", line: line, nl: true})
  return tokens
}

// ------------------------------------------------------------ the parser

// The tree: expressions {k: "num" | "bool" | "name" | "bin" | "un" |
// "call" | "index" | "field", line, ...}, statements {k: "local" |
// "assign" | "expr" | "if" | "for" | "break" | "continue" | "return",
// line, ...}, top-level {k: "struct" | "func" | "const", ...}.

local parser_methods = {}
local parser_meta = {__index: parser_methods}

local func new_parser(tokens, origin){
  return {tokens: tokens, pos: 0, origin: origin, @meta: parser_meta}
}

func parser_methods.peek(self){
  return self.tokens[self.pos]
}

func parser_methods.next(self){
  local t = self.tokens[self.pos]
  if(t.kind != "eof"){
    self.pos = self.pos + 1
  }
  return t
}

func parser_methods.is(self, value){
  local t = self.tokens[self.pos]
  return (t.kind == "op" or t.kind == "keyword") and t.value == value
}

func parser_methods.accept(self, value){
  if(self:is(value)){
    return self:next()
  }
  return null
}

func parser_methods.fail(self, ...parts){
  fail(self.origin, self:peek().line, ...parts)
}

func parser_methods.expect(self, value){
  if(not self:is(value)){
    local t = self:peek()
    self:fail("expected ", value, ", found ", t.value)
  }
  return self:next()
}

func parser_methods.name(self){
  local t = self:peek()
  if(t.kind != "name"){
    self:fail("expected a name, found ", t.value)
  }
  return self:next().value
}

// a type: a name, or a name and [] (an array)
func parser_methods.type(self){
  local name = self:name()
  if(self:accept("[")){
    self:expect("]")
    return {array: name}
  }
  return name
}

// binary operators by level, lowest first; ^ is right-associative and
// above the unary minus
local levels = {
  {"or"},
  {"and"},
  {"==", "!=", "<", "<=", ">", ">="},
  {"|"},
  {"~"},
  {"&"},
  {"<<", ">>"},
  {"+", "-"},
  {"*", "/", "%"},
}

func parser_methods.expr(self){
  return self:binary(0)
}

func parser_methods.binary(self, level){
  if(level == 3){
    // `not` sits between and and the comparisons, as in Python
    local t = self:accept("not")
    if(t != null){
      return {k: "un", op: "not", e: self:binary(3), line: t.line}
    }
  }
  if(level >= len(levels)){
    return self:unary()
  }
  local left = self:binary(level + 1)
  for(true){
    local t = self:peek()
    local found = false
    if(t.kind == "op" or t.kind == "keyword"){
      for(let local op in values(levels[level])){
        if(t.value == op){
          found = true
        }
      }
    }
    if(not found){
      return left
    }
    self:next()
    local right = self:binary(level + 1)
    left = {k: "bin", op: t.value, l: left, r: right, line: t.line}
  }
}

func parser_methods.unary(self){
  local t = self:peek()
  if(self:is("-") or self:is("~")){
    self:next()
    return {k: "un", op: t.value, e: self:unary(), line: t.line}
  }
  return self:power()
}

func parser_methods.power(self){
  local base = self:postfix()
  local t = self:accept("^")
  if(t != null){
    // right-associative; the exponent may have a sign
    return {k: "bin", op: "^", l: base, r: self:unary(), line: t.line}
  }
  return base
}

func parser_methods.postfix(self){
  local e = self:primary()
  for(true){
    local t = self:peek()
    // ( and [ continue an expression only on its line (slang's rule)
    if(self:is("(") and not t.nl){
      if(e.k != "name"){
        self:fail("only functions by name can be called")
      }
      self:next()
      local args = {}
      if(not self:is(")")){
        append(args, self:expr())
        for(self:accept(",")){
          append(args, self:expr())
        }
      }
      self:expect(")")
      e = {k: "call", name: e.name, args: args, line: t.line}
    } else if(self:is("[") and not t.nl){
      self:next()
      local index = self:expr()
      self:expect("]")
      e = {k: "index", e: e, index: index, line: t.line}
    } else if(self:is(".")){
      self:next()
      e = {k: "field", e: e, name: self:name(), line: t.line}
    } else {
      return e
    }
  }
}

func parser_methods.primary(self){
  local t = self:next()
  if(t.kind == "int"){
    return {k: "num", value: t.value, int: true, line: t.line}
  }
  if(t.kind == "float"){
    return {k: "num", value: t.value, int: false, line: t.line}
  }
  if(t.kind == "name"){
    return {k: "name", name: t.value, line: t.line}
  }
  if(t.kind == "keyword" and (t.value == "true" or t.value == "false")){
    return {k: "bool", value: t.value == "true", line: t.line}
  }
  if(t.kind == "op" and t.value == "("){
    local e = self:expr()
    self:expect(")")
    return e
  }
  fail(self.origin, t.line, "expected an expression, found ", t.value)
}

func parser_methods.block(self){
  self:expect("{")
  local body = {}
  for(not self:is("}")){
    if(self:peek().kind == "eof"){
      self:fail("expected }")
    }
    append(body, self:statement())
  }
  self:expect("}")
  return body
}

local compound = {["+="]: "+", ["-="]: "-", ["*="]: "*", ["/="]: "/", ["%="]: "%"}

// a statement that is not a block: local, assignment, call
func parser_methods.simple(self){
  local t = self:peek()
  if(self:accept("local")){
    local name = self:name()
    local ty = null
    if(self:accept(":")){
      ty = self:type()
    }
    local init = null
    if(self:accept("=")){
      init = self:expr()
    }
    return {k: "local", name: name, type: ty, init: init, line: t.line}
  }
  local target = self:expr()
  local op = self:peek()
  if(op.kind == "op" and (op.value == "=" or compound[op.value] != null)){
    self:next()
    local value = self:expr()
    if(compound[op.value] != null){
      value = {k: "bin", op: compound[op.value], l: target, r: value, line: op.line}
    }
    return {k: "assign", target: target, value: value, line: t.line}
  }
  // a lone expression: a call as a statement, or a for's condition (the
  // code generator rejects others)
  return {k: "expr", e: target, line: t.line}
}

func parser_methods.statement(self){
  local t = self:peek()
  local s = null
  if(self:accept("if")){
    self:expect("(")
    local cond = self:expr()
    self:expect(")")
    local body = self:block()
    local other = null
    if(self:accept("else")){
      if(self:is("if")){
        // (bound first: {self:statement()} would be a field named self)
        local nested = self:statement()
        other = {nested}
      } else {
        other = self:block()
      }
    }
    s = {k: "if", cond: cond, body: body, other: other, line: t.line}
  } else if(self:accept("for")){
    self:expect("(")
    local init = null
    local cond = null
    local update = null
    // for(cond) or for(init; cond; update)
    local first = null
    if(not self:is(";")){
      first = self:simple()
    }
    if(self:accept(";")){
      init = first
      if(not self:is(";")){
        cond = self:expr()
      }
      self:expect(";")
      if(not self:is(")")){
        update = self:simple()
      }
    } else if(first != null and first.k == "expr"){
      cond = first.e
    } else {
      fail(self.origin, t.line, "for(...) takes a condition, or init; condition; update")
    }
    self:expect(")")
    s = {k: "for", init: init, cond: cond, update: update, body: self:block(), line: t.line}
  } else if(self:accept("break")){
    s = {k: "break", line: t.line}
  } else if(self:accept("continue")){
    s = {k: "continue", line: t.line}
  } else if(self:accept("return")){
    local value = null
    if(not self:is("}") and not self:peek().nl){
      value = self:expr()
    }
    s = {k: "return", value: value, line: t.line}
  } else {
    s = self:simple()
  }
  self:accept(";")
  return s
}

func parser_methods.params(self){
  self:expect("(")
  local params = {}
  if(not self:is(")")){
    for(true){
      local name = self:name()
      self:expect(":")
      append(params, {name: name, type: self:type()})
      if(not self:accept(",")){
        break
      }
    }
  }
  self:expect(")")
  return params
}

// the top level: structs, constants, helpers and kernels
func parser_methods.unit(self){
  local items = {}
  for(self:peek().kind != "eof"){
    local t = self:peek()
    if(self:accept("struct")){
      local name = self:name()
      self:expect("{")
      local fields = {}
      for(not self:is("}")){
        local fname = self:name()
        self:expect(":")
        append(fields, {name: fname, type: self:type(), line: self:peek().line})
        if(not self:accept(",")){
          self:accept(";")
        }
      }
      self:expect("}")
      append(items, {k: "struct", name: name, fields: fields, line: t.line})
    } else if(self:accept("local")){
      local name = self:name()
      self:expect("=")
      append(items, {k: "const", name: name, e: self:expr(), line: t.line})
    } else {
      local is_kernel = self:accept("kernel") != null
      self:expect("func")
      local name = self:name()
      local params = self:params()
      local ret = null
      if(self:accept(":")){
        ret = self:type()
      }
      append(items, {k: "func", kernel: is_kernel, name: name, params: params, ret: ret, body: self:block(), line: t.line})
    }
    self:accept(";")
  }
  return items
}

// ------------------------------------------------------------ constants

local builtin_consts = {
  PI: 3.141592653589793,
  TAU: 6.283185307179586,
  E: 2.718281828459045,
}

// the value of a constant expression: {t, value}
local func const_eval(e, consts, origin){
  if(e.k == "num"){
    if(e.int){
      return {t: "int", value: e.value}
    }
    return {t: "float", value: e.value}
  }
  if(e.k == "bool"){
    return {t: "bool", value: e.value}
  }
  if(e.k == "name"){
    if(consts[e.name] != null){
      return consts[e.name]
    }
    if(builtin_consts[e.name] != null){
      return {t: "float", value: builtin_consts[e.name]}
    }
    fail(origin, e.line, e.name, " is not a constant")
  }
  if(e.k == "un" and e.op == "-"){
    local v = const_eval(e.e, consts, origin)
    return {t: v.t, value: -v.value}
  }
  if(e.k == "bin"){
    local a = const_eval(e.l, consts, origin)
    local b = const_eval(e.r, consts, origin)
    local t = "int"
    if(a.t == "float" or b.t == "float"){
      t = "float"
    }
    local x = a.value
    local y = b.value
    if(e.op == "+"){
      return {t: t, value: x + y}
    } else if(e.op == "-"){
      return {t: t, value: x - y}
    } else if(e.op == "*"){
      return {t: t, value: x * y}
    } else if(e.op == "/"){
      if(t == "int"){
        return {t: t, value: to_int(require("slang/math").floor(x / y))}
      }
      return {t: t, value: x / y}
    } else if(e.op == "^"){
      return {t: "float", value: (x * 1.0) ^ y}
    }
  }
  fail(origin, e.line, "a top-level local needs a constant value (numbers, other constants, + - * / ^)")
}

// ------------------------------------------------------------ structs

// fields at their C offsets: {name, kind, struct?, offset}, size, align
local func layout_struct(item, structs, origin){
  local fields = {}
  local by_name = {}
  local offset = 0
  local align = 1
  for(let local f in values(item.fields)){
    local size = 0
    local a = 1
    local entry = {name: f.name}
    if(type(f.type) != "string"){
      fail(origin, f.line, "struct fields cannot be arrays (", item.name, ".", f.name, ")")
    }
    if(KIND[f.type] != null){
      size = KIND_SIZE[KIND[f.type]]
      a = size
      entry.kind = f.type
    } else if(structs[f.type] != null){
      fail(origin, f.line, "structs inside structs are not supported yet (", item.name, ".", f.name, ")")
    } else {
      fail(origin, f.line, "unknown field type ", f.type, " (a field is float, double, int8 .. uint64 or bool)")
    }
    offset = to_int((offset + a - 1) / a) * a
    entry.offset = offset
    offset = offset + size
    if(a > align){
      align = a
    }
    append(fields, entry)
    by_name[f.name] = entry
  }
  local size = to_int((offset + align - 1) / align) * align
  return {name: item.name, fields: fields, by_name: by_name, size: size, align: align}
}

// ------------------------------------------------------------ code generation

// The generator of one kernel: its code, registers, labels and scopes.
local gen_methods = {}
local gen_meta = {__index: gen_methods}

local func reg_file(t){
  if(t == "float"){
    return "f"
  }
  return "i"
}

local func new_gen(unit, origin, name){
  return {
    unit: unit,
    origin: origin,
    name: name,
    code: {},
    lines: {},
    last_line: -1,
    next: {i: 0, f: 0},
    high: {i: 0, f: 0},
    consts: {i: {}, f: {}},
    const_low: {i: 256, f: 256},
    const_list: {i: {}, f: {}},
    scopes: {},
    loops: {},
    slots: 0,
    inline: {},
    @meta: gen_meta,
  }
}

func gen_methods.fail(self, line, ...parts){
  fail(self.origin, line, ...parts)
}

func gen_methods.line(self, line){
  if(line != self.last_line){
    append(self.lines, len(self.code))
    append(self.lines, line)
    self.last_line = line
  }
}

func gen_methods.emit(self, op, a, b, c){
  local code = OP[op]
  if(code == null){
    error(concat("kernel compiler: no opcode ", op))
  }
  append(self.code, code | ((a or 0) << 8) | ((b or 0) << 16) | ((c or 0) << 24))
  return len(self.code) - 1
}

func gen_methods.word(self, w){
  append(self.code, w)
  return len(self.code) - 1
}

// labels: {at: pc or null, uses: {word index}}
func gen_methods.label(self){
  return {at: null, uses: {}}
}

func gen_methods.place(self, l){
  l.at = len(self.code)
  for(let local u in values(l.uses)){
    self.code[u] = l.at
  }
}

func gen_methods.target(self, l){
  if(l.at != null){
    return self:word(l.at)
  }
  local w = self:word(0)
  append(l.uses, w)
  return w
}

func gen_methods.jump(self, op, l, a, b){
  self:emit(op, a, b, 0)
  self:target(l)
}

// a fresh register of a file
func gen_methods.alloc(self, file){
  local r = self.next[file]
  self.next[file] = r + 1
  if(self.next[file] > self.high[file]){
    self.high[file] = self.next[file]
  }
  if(self.next[file] > self.const_low[file]){
    self:fail(self.last_line, "kernel ", self.name, " needs more than 256 registers")
  }
  return r
}

func gen_methods.temp(self, t){
  return {t: t, r: self:alloc(reg_file(t))}
}

// the register holding a constant (int, bool: i; float: f)
func gen_methods.const(self, t, value){
  local file = reg_file(t)
  local key = value
  if(t == "bool"){
    key = 0
    if(value){
      key = 1
    }
  }
  if(file == "f"){
    key = value * 1.0
  }
  local cs = self.consts[file]
  local r = cs[key]
  if(r == null){
    self.const_low[file] = self.const_low[file] - 1
    r = self.const_low[file]
    if(r < self.high[file]){
      self:fail(self.last_line, "kernel ", self.name, " needs more than 256 registers")
    }
    cs[key] = r
    append(self.const_list[file], {r, key})
  }
  // c: the value, so that a constant int needed as a float is a float
  // constant rather than a conversion
  return {t: t, r: r, c: key}
}

// scopes: {vars: {[name]: var}, entry: {i, f}, top: {i, f}, boundary}.
// Registers are a stack per file: a scope's locals sit from its entry to
// its top, a statement's temporaries above the top. entry is what was in
// use when the scope opened (an inlined helper opens one in the middle of
// an expression, whose temporaries stay live), and is restored at close.
func gen_methods.open(self, boundary){
  local at = {i: self.next.i, f: self.next.f}
  append(self.scopes, {vars: {}, entry: at, top: {i: at.i, f: at.f}, boundary: boundary or false})
}

func gen_methods.close(self){
  local s = remove(self.scopes, len(self.scopes) - 1)
  self.next = {i: s.entry.i, f: s.entry.f}
}

// after a statement its temporaries are free again
func gen_methods.reset(self){
  local s = self.scopes[len(self.scopes) - 1]
  self.next = {i: s.top.i, f: s.top.f}
}

// declare(name, v, line): v is {kind: "var", t, r}, {kind: "array", slot,
// elem} or {kind: "ref", slot, idx, struct}; a variable's register (and
// those below it) stays in use to the end of the scope
func gen_methods.declare(self, name, v, line){
  local s = self.scopes[len(self.scopes) - 1]
  if(s.vars[name] != null){
    self:fail(line, name, " is already declared in this block")
  }
  s.vars[name] = v
  if(v.kind == "var" or v.kind == "ref"){
    local file = "i"
    local r = v.idx
    if(v.kind == "var"){
      file = reg_file(v.t)
      r = v.r
    }
    if(r < self.const_low[file] and r + 1 > s.top[file]){
      s.top[file] = r + 1
    }
  }
}

// whether register r of a file is a temporary of the current statement
// (not a variable, not a constant)
func gen_methods.is_temp(self, file, r){
  local s = self.scopes[len(self.scopes) - 1]
  return r >= s.top[file] and r < self.const_low[file]
}

func gen_methods.lookup(self, name){
  for(local k = len(self.scopes) - 1; k >= 0; k = k - 1){
    local s = self.scopes[k]
    if(s.vars[name] != null){
      return s.vars[name]
    }
    if(s.boundary){
      break
    }
  }
  return null
}

// ---- moves and conversions

// v ({t, r}) into register r of type t: converts int to float, refuses
// the rest
func gen_methods.move(self, v, t, r, line){
  if(v.t == t){
    if(v.r != r){
      if(t == "float"){
        self:emit("movf", r, v.r)
      } else {
        self:emit("movi", r, v.r)
      }
    }
    return {t: t, r: r}
  }
  if(t == "float" and v.t == "int"){
    if(v.c != null){
      self:emit("movf", r, self:const("float", v.c * 1.0).r)
    } else {
      self:emit("itof", r, v.r)
    }
    return {t: t, r: r}
  }
  if(t == "int" and v.t == "float"){
    self:fail(line, "a float does not become an int by itself: write int(x)")
  }
  self:fail(line, "expected ", t, ", found ", v.t)
}

// v as a float (converted into a temporary when it is an int)
func gen_methods.as_float(self, v, line){
  if(v.t == "float"){
    return v
  }
  if(v.t != "int"){
    self:fail(line, "expected a number, found ", v.t)
  }
  if(v.c != null){
    return self:const("float", v.c * 1.0)
  }
  local t = self:temp("float")
  self:emit("itof", t.r, v.r)
  return t
}

func gen_methods.number(self, v, line){
  if(v.t != "int" and v.t != "float"){
    self:fail(line, "expected a number, found ", v.t)
  }
  return v
}

// a destination: the hint when it is of type t, else a temporary
func gen_methods.dest(self, hint, t){
  if(hint != null and hint.t == t){
    return hint
  }
  return self:temp(t)
}

// ---- places: what an index or field expression names

// {kind: "elem", slot, idx (an int register), struct?, kind (storage)} or
// a variable
func gen_methods.array_of(self, e){
  if(e.k != "name"){
    self:fail(e.line, "only arrays by name can be indexed")
  }
  local v = self:lookup(e.name)
  if(v == null or v.kind != "array"){
    self:fail(e.line, e.name, " is not an array")
  }
  return v
}

// the element an index expression names: {slot, idx, elem (storage kind or
// struct)}
func gen_methods.element(self, e){
  local arr = self:array_of(e.e)
  local idx = self:expr(e.index, null)
  if(idx.t != "int"){
    self:fail(e.line, "an index must be an int, found ", idx.t)
  }
  return {slot: arr.slot, idx: idx.r, elem: arr.elem}
}

// the struct element a field's receiver names: {slot, idx, struct}
func gen_methods.struct_ref(self, e){
  if(e.k == "name"){
    local v = self:lookup(e.name)
    if(v != null and v.kind == "ref"){
      return v
    }
    self:fail(e.line, e.name, " is not a struct")
  }
  if(e.k == "index"){
    local el = self:element(e)
    if(type(el.elem) == "string"){
      self:fail(e.line, "elements of a ", el.elem, " array have no fields")
    }
    return {kind: "ref", slot: el.slot, idx: el.idx, struct: el.elem}
  }
  self:fail(e.line, "only struct elements have fields")
}

// a storage place: {slot, idx, offset, kind} for an index or a field
func gen_methods.place_of(self, e){
  if(e.k == "index"){
    local el = self:element(e)
    if(type(el.elem) != "string"){
      self:fail(e.line, "a struct element is not a value: use its fields, or local x = a[i] to name it")
    }
    return {slot: el.slot, idx: el.idx, offset: 0, kind: el.elem}
  }
  local ref = self:struct_ref(e.e)
  local f = ref.struct.by_name[e.name]
  if(f == null){
    self:fail(e.line, ref.struct.name, " has no field ", e.name)
  }
  return {slot: ref.slot, idx: ref.idx, offset: f.offset, kind: f.kind}
}

func gen_methods.load(self, p, hint){
  local t = value_of_kind(p.kind)
  local d = self:dest(hint, t)
  self:emit(concat("ld_", p.kind), d.r, p.slot, p.idx)
  self:word(p.offset)
  return d
}

func gen_methods.store(self, p, v, line){
  local t = value_of_kind(p.kind)
  if(v.t != t){
    if(t == "float"){
      v = self:as_float(v, line)
    } else {
      self:fail(line, "a ", p.kind, " cannot hold a ", v.t)
    }
  }
  self:emit(concat("st_", p.kind), p.slot, p.idx, v.r)
  self:word(p.offset)
}

// ---- expressions

local arith_ops = {["+"]: "add", ["-"]: "sub", ["*"]: "mul", ["/"]: "div", ["%"]: "mod"}
local int_bit_ops = {["&"]: "andi", ["|"]: "ori", ["~"]: "xori", ["<<"]: "shli", [">>"]: "shri"}
local compare_ops = {["<"]: true, ["<="]: true, [">"]: true, [">="]: true, ["=="]: true, ["!="]: true}

// expr(e, hint?) -> {t, r}: the value of e, written into hint's register
// when it fits (else into a temporary, or the register of a variable)
func gen_methods.expr(self, e, hint){
  local k = e.k
  if(k == "num"){
    if(e.int and not (hint != null and hint.t == "float")){
      return self:const("int", e.value)
    }
    return self:const("float", e.value * 1.0)
  }
  if(k == "bool"){
    return self:const("bool", e.value)
  }
  if(k == "name"){
    local v = self:lookup(e.name)
    if(v != null){
      if(v.kind == "var"){
        return {t: v.t, r: v.r}
      }
      self:fail(e.line, e.name, " is not a value (an array or a struct)")
    }
    local c = self.unit.consts[e.name]
    if(c != null){
      return self:const(c.t, c.value)
    }
    if(builtin_consts[e.name] != null){
      return self:const("float", builtin_consts[e.name])
    }
    self:fail(e.line, "unknown name ", e.name)
  }
  if(k == "un"){
    if(e.op == "not"){
      return self:bool_value(e, hint)
    }
    if(e.op == "-" and e.e.k == "num"){
      return self:expr({k: "num", value: -e.e.value, int: e.e.int, line: e.line}, hint)
    }
    local v = self:expr(e.e, null)
    if(e.op == "-"){
      v = self:number(v, e.line)
      local d = self:dest(hint, v.t)
      if(v.t == "float"){
        self:emit("negf", d.r, v.r)
      } else {
        self:emit("negi", d.r, v.r)
      }
      return d
    }
    // ~x: bitwise not
    if(v.t != "int"){
      self:fail(e.line, "~ takes an int")
    }
    local d = self:dest(hint, "int")
    self:emit("noti", d.r, v.r)
    return d
  }
  if(k == "bin"){
    local op = e.op
    if(op == "and" or op == "or" or compare_ops[op]){
      return self:bool_value(e, hint)
    }
    if(op == "+" and hint != null and hint.t == "float"){
      // a + b * c in one instruction
      local fused = self:fma(e, hint)
      if(fused != null){
        return fused
      }
    }
    local a = self:number(self:expr(e.l, null), e.l.line)
    local b = self:number(self:expr(e.r, null), e.r.line)
    if(int_bit_ops[op] != null){
      if(a.t != "int" or b.t != "int"){
        self:fail(e.line, op, " takes ints")
      }
      local d = self:dest(hint, "int")
      self:emit(int_bit_ops[op], d.r, a.r, b.r)
      return d
    }
    if(op == "^"){
      a = self:as_float(a, e.line)
      b = self:as_float(b, e.line)
      local d = self:dest(hint, "float")
      self:emit("powf", d.r, a.r, b.r)
      return d
    }
    local base = arith_ops[op]
    if(base == null){
      self:fail(e.line, "unknown operator ", op)
    }
    if(a.t == "int" and b.t == "int"){
      local d = self:dest(hint, "int")
      self:emit(concat(base, "i"), d.r, a.r, b.r)
      return d
    }
    a = self:as_float(a, e.line)
    b = self:as_float(b, e.line)
    local d = self:dest(hint, "float")
    self:emit(concat(base, "f"), d.r, a.r, b.r)
    return d
  }
  if(k == "call"){
    return self:call(e, hint)
  }
  if(k == "index" or k == "field"){
    return self:load(self:place_of(e), hint)
  }
  self:fail(e.line, "unexpected ", k)
}

// a + b * c (or b * c + a) as madf, when the product is a float
func gen_methods.fma(self, e, hint){
  local prod = null
  local other = null
  if(e.r.k == "bin" and e.r.op == "*"){
    prod = e.r
    other = e.l
  } else if(e.l.k == "bin" and e.l.op == "*"){
    prod = e.l
    other = e.r
  } else {
    return null
  }
  local a = self:number(self:expr(other, null), other.line)
  local b = self:number(self:expr(prod.l, null), prod.line)
  local c = self:number(self:expr(prod.r, null), prod.line)
  if(a.t == "int" and b.t == "int" and c.t == "int"){
    // an int expression: the plain way (the operands are computed already)
    local p = self:temp("int")
    self:emit("muli", p.r, b.r, c.r)
    local d = self:dest(hint, "int")
    self:emit("addi", d.r, a.r, p.r)
    return d
  }
  a = self:as_float(a, e.line)
  b = self:as_float(b, e.line)
  c = self:as_float(c, e.line)
  local d = self:dest(hint, "float")
  self:emit("madf", d.r, a.r, b.r)
  self:word(c.r)
  return d
}

// a condition as a value: 1 or 0 in an int register
func gen_methods.bool_value(self, e, hint){
  if(e.k == "bin" and compare_ops[e.op]){
    local cmp = self:compare_operands(e)
    local d = self:dest(hint, "bool")
    local op = e.op
    local x = cmp.a.r
    local y = cmp.b.r
    if(op == ">" or op == ">="){
      x = cmp.b.r
      y = cmp.a.r
    }
    local name = {["<"]: "lt", [">"]: "lt", ["<="]: "le", [">="]: "le", ["=="]: "eq", ["!="]: "ne"}[op]
    local suffix = "i"
    if(cmp.t == "float"){
      suffix = "f"
    }
    self:emit(concat(name, suffix), d.r, x, y)
    return d
  }
  if(e.k == "un" and e.op == "not"){
    local v = self:expr(e.e, null)
    if(v.t != "bool"){
      self:fail(e.line, "not takes a bool")
    }
    local d = self:dest(hint, "bool")
    self:emit("notb", d.r, v.r)
    return d
  }
  // and, or: through jumps
  local d = self:dest(hint, "bool")
  local no = self:label()
  local done = self:label()
  self:cond(e, no, false)
  self:emit("movi", d.r, self:const("bool", true).r)
  self:jump("jmp", done)
  self:place(no)
  self:emit("movi", d.r, self:const("bool", false).r)
  self:place(done)
  return d
}

// both sides of a comparison, as ints or as floats: {t, a, b}
func gen_methods.compare_operands(self, e){
  local a = self:expr(e.l, null)
  local b = self:expr(e.r, null)
  if(a.t == "bool" or b.t == "bool"){
    if(a.t != b.t or (e.op != "==" and e.op != "!=")){
      self:fail(e.line, "bools compare only with == and != to bools")
    }
    return {t: "int", a: a, b: b}
  }
  a = self:number(a, e.line)
  b = self:number(b, e.line)
  if(a.t == "int" and b.t == "int"){
    return {t: "int", a: a, b: b}
  }
  return {t: "float", a: self:as_float(a, e.line), b: self:as_float(b, e.line)}
}

// cond(e, label, when): jumps to label when e is `when` (true or false)
func gen_methods.cond(self, e, label, when){
  if(e.k == "bool"){
    if(e.value == when){
      self:jump("jmp", label)
    }
    return null
  }
  if(e.k == "un" and e.op == "not"){
    return self:cond(e.e, label, not when)
  }
  if(e.k == "bin" and (e.op == "and" or e.op == "or")){
    // and jumping when false, or jumping when true: either side decides
    if((e.op == "and") != when){
      self:cond(e.l, label, when)
      self:cond(e.r, label, when)
    } else {
      local skip = self:label()
      self:cond(e.l, skip, not when)
      self:cond(e.r, label, when)
      self:place(skip)
    }
    return null
  }
  if(e.k == "bin" and compare_ops[e.op]){
    local c = self:compare_operands(e)
    local a = c.a.r
    local b = c.b.r
    local op = e.op
    if(c.t == "int"){
      // the negation of an int comparison is a comparison
      if(not when){
        op = {["<"]: ">=", ["<="]: ">", [">"]: "<=", [">="]: "<", ["=="]: "!=", ["!="]: "=="}[op]
      }
      if(op == "<"){
        self:jump("jlti", label, a, b)
      } else if(op == "<="){
        self:jump("jlei", label, a, b)
      } else if(op == ">"){
        self:jump("jlti", label, b, a)
      } else if(op == ">="){
        self:jump("jlei", label, b, a)
      } else if(op == "=="){
        self:jump("jeqi", label, a, b)
      } else {
        self:jump("jnei", label, a, b)
      }
      return null
    }
    // floats: NaN makes every comparison false, so the negations are their
    // own instructions
    if(op == ">" or op == ">="){
      local s = a
      a = b
      b = s
      op = {[">"]: "<", [">="]: "<="}[op]
    }
    local name = {["<"]: "ltf", ["<="]: "lef", ["=="]: "eqf", ["!="]: "nef"}[op]
    if(not when){
      name = {ltf: "nltf", lef: "nlef", eqf: "nef", nef: "eqf"}[name]
    }
    self:jump(concat("j", name), label, a, b)
    return null
  }
  local v = self:expr(e, null)
  if(v.t != "bool"){
    self:fail(e.line, "a condition must be a bool, found ", v.t)
  }
  if(when){
    self:jump("jt", label, v.r)
  } else {
    self:jump("jf", label, v.r)
  }
}

// ---- calls: builtins and inlined helpers

local unary_float = {
  sin: "sin", cos: "cos", tan: "tan", asin: "asin", acos: "acos",
  atan: "atan", exp: "exp", exp2: "exp2", log: "log", log2: "log2",
  sqrt: "sqrt", floor: "floor", ceil: "ceil", round: "round",
  trunc: "trunc", fract: "fract", tanh: "tanh", sinh: "sinh", cosh: "cosh",
}

func gen_methods.args(self, e, n){
  if(len(e.args) != n){
    self:fail(e.line, e.name, " takes ", n, " arguments, found ", len(e.args))
  }
  local out = {}
  for(let local a in values(e.args)){
    append(out, self:expr(a, null))
  }
  return out
}

func gen_methods.call(self, e, hint){
  local name = e.name
  if(unary_float[name] != null){
    local a = self:as_float(self:args(e, 1)[0], e.line)
    local d = self:dest(hint, "float")
    self:emit(unary_float[name], d.r, a.r)
    return d
  }
  if(name == "abs" or name == "sign"){
    local a = self:number(self:args(e, 1)[0], e.line)
    local d = self:dest(hint, a.t)
    local suffix = "i"
    if(a.t == "float"){
      suffix = "f"
    }
    self:emit(concat(name, suffix), d.r, a.r)
    return d
  }
  if(name == "min" or name == "max"){
    local args = self:args(e, 2)
    local a = self:number(args[0], e.line)
    local b = self:number(args[1], e.line)
    if(a.t == "int" and b.t == "int"){
      local d = self:dest(hint, "int")
      self:emit(concat(name, "i"), d.r, a.r, b.r)
      return d
    }
    a = self:as_float(a, e.line)
    b = self:as_float(b, e.line)
    local d = self:dest(hint, "float")
    self:emit(concat(name, "f"), d.r, a.r, b.r)
    return d
  }
  if(name == "atan2" or name == "pow"){
    local args = self:args(e, 2)
    local a = self:as_float(args[0], e.line)
    local b = self:as_float(args[1], e.line)
    local d = self:dest(hint, "float")
    if(name == "pow"){
      self:emit("powf", d.r, a.r, b.r)
    } else {
      self:emit("atan2", d.r, a.r, b.r)
    }
    return d
  }
  if(name == "clamp"){
    local args = self:args(e, 3)
    local x = self:number(args[0], e.line)
    local lo = self:number(args[1], e.line)
    local hi = self:number(args[2], e.line)
    if(x.t == "int" and lo.t == "int" and hi.t == "int"){
      local d = self:dest(hint, "int")
      self:emit("maxi", d.r, x.r, lo.r)
      self:emit("mini", d.r, d.r, hi.r)
      return d
    }
    x = self:as_float(x, e.line)
    lo = self:as_float(lo, e.line)
    hi = self:as_float(hi, e.line)
    local d = self:dest(hint, "float")
    self:emit("maxf", d.r, x.r, lo.r)
    self:emit("minf", d.r, d.r, hi.r)
    return d
  }
  if(name == "mix"){
    // a + (b - a) * t
    local args = self:args(e, 3)
    local a = self:as_float(args[0], e.line)
    local b = self:as_float(args[1], e.line)
    local t = self:as_float(args[2], e.line)
    local diff = self:temp("float")
    self:emit("subf", diff.r, b.r, a.r)
    local d = self:dest(hint, "float")
    self:emit("madf", d.r, a.r, diff.r)
    self:word(t.r)
    return d
  }
  if(name == "step"){
    // step(edge, x): 0 below the edge, else 1
    local args = self:args(e, 2)
    local edge = self:as_float(args[0], e.line)
    local x = self:as_float(args[1], e.line)
    local below = self:temp("bool")
    self:emit("ltf", below.r, x.r, edge.r)
    local d = self:dest(hint, "float")
    self:emit("self", d.r, self:const("float", 0.0).r, self:const("float", 1.0).r)
    self:word(below.r)
    return d
  }
  if(name == "smoothstep"){
    // t = clamp((x - e0) / (e1 - e0), 0, 1); t * t * (3 - 2 t)
    local args = self:args(e, 3)
    local e0 = self:as_float(args[0], e.line)
    local e1 = self:as_float(args[1], e.line)
    local x = self:as_float(args[2], e.line)
    local t = self:temp("float")
    local w = self:temp("float")
    self:emit("subf", t.r, x.r, e0.r)
    self:emit("subf", w.r, e1.r, e0.r)
    self:emit("divf", t.r, t.r, w.r)
    self:emit("maxf", t.r, t.r, self:const("float", 0.0).r)
    self:emit("minf", t.r, t.r, self:const("float", 1.0).r)
    // w = 3 - 2 t
    self:emit("mulf", w.r, t.r, self:const("float", -2.0).r)
    self:emit("addf", w.r, w.r, self:const("float", 3.0).r)
    local d = self:dest(hint, "float")
    self:emit("mulf", d.r, t.r, t.r)
    self:emit("mulf", d.r, d.r, w.r)
    return d
  }
  if(name == "select"){
    if(len(e.args) != 3){
      self:fail(e.line, "select takes 3 arguments")
    }
    local c = self:expr(e.args[0], null)
    if(c.t != "bool"){
      self:fail(e.line, "select's first argument is a bool")
    }
    local a = self:expr(e.args[1], null)
    local b = self:expr(e.args[2], null)
    if(a.t == b.t and a.t != "float"){
      local d = self:dest(hint, a.t)
      self:emit("seli", d.r, a.r, b.r)
      self:word(c.r)
      return d
    }
    a = self:as_float(a, e.line)
    b = self:as_float(b, e.line)
    local d = self:dest(hint, "float")
    self:emit("self", d.r, a.r, b.r)
    self:word(c.r)
    return d
  }
  if(name == "float"){
    local a = self:number(self:args(e, 1)[0], e.line)
    if(a.t == "float"){
      return a
    }
    local d = self:dest(hint, "float")
    self:emit("itof", d.r, a.r)
    return d
  }
  if(name == "int"){
    local a = self:args(e, 1)[0]
    if(a.t == "int"){
      return a
    }
    local d = self:dest(hint, "int")
    if(a.t == "bool"){
      self:emit("movi", d.r, a.r)
    } else {
      self:emit("ftoi", d.r, a.r)
    }
    return d
  }
  if(name == "len"){
    if(len(e.args) != 1){
      self:fail(e.line, "len takes 1 argument")
    }
    local arr = self:array_of(e.args[0])
    local d = self:dest(hint, "int")
    self:emit("len", d.r, arr.slot)
    return d
  }
  local f = self.unit.funcs[name]
  if(f == null){
    self:fail(e.line, "unknown function ", name)
  }
  return self:inline_call(f, e, hint)
}

// a helper's body in place of its call: its parameters bound to the
// arguments (arrays and structs by reference), its returns jumping to the
// end with the value in the result register
func gen_methods.inline_call(self, f, e, hint){
  if(self.inline[f.name]){
    self:fail(e.line, f.name, " calls itself: helpers are inlined, so they cannot recurse")
  }
  if(len(e.args) != len(f.params)){
    self:fail(e.line, f.name, " takes ", len(f.params), " arguments, found ", len(e.args))
  }
  local result = null
  local ret_t = null
  if(f.ret != null){
    ret_t = self:value_type(f.ret, f.line)
    result = self:dest(hint, ret_t)
  }
  // the arguments, evaluated before the helper's scope opens
  local bound = {}
  for(local i = 0; i < len(f.params); i = i + 1){
    local p = f.params[i]
    local a = e.args[i]
    if(type(p.type) != "string"){
      local arr = self:array_of(a)
      if(arr.elem != p.type.array and not (type(arr.elem) != "string" and arr.elem.name == p.type.array)){
        self:fail(a.line, f.name, "'s ", p.name, " is a ", p.type.array, "[]")
      }
      append(bound, arr)
    } else if(self.unit.structs[p.type] != null){
      local ref = self:struct_ref(a)
      if(ref.struct.name != p.type){
        self:fail(a.line, f.name, "'s ", p.name, " is a ", p.type)
      }
      append(bound, ref)
    } else {
      local t = self:value_type(p.type, f.line)
      local reg = self:temp(t)
      local v = self:expr(a, reg)
      self:move(v, t, reg.r, a.line)
      append(bound, {kind: "var", t: t, r: reg.r})
    }
  }
  self:open(true)
  for(local i = 0; i < len(f.params); i = i + 1){
    self:declare(f.params[i].name, bound[i], f.line)
  }
  local done = self:label()
  local outer_loops = self.loops
  self.loops = {}
  local outer_ret = self.ret
  self.ret = {t: ret_t, result: result, done: done}
  self.inline[f.name] = true
  local last = f.body[len(f.body) - 1]
  if(result != null and (last == null or last.k != "return")){
    // a helper that may end without a return gives 0
    self:move(self:const(ret_t, 0), ret_t, result.r, f.line)
  }
  self:statements(f.body)
  self.inline[f.name] = null
  self.ret = outer_ret
  self.loops = outer_loops
  self:place(done)
  self:close()
  if(result == null){
    // a call as a value needs a value
    return {t: "none", r: 0}
  }
  return result
}

// int, float (double), bool
func gen_methods.value_type(self, t, line){
  if(t == "int" or t == "bool" or t == "float"){
    return t
  }
  if(t == "double"){
    return "float"
  }
  self:fail(line, "unknown type ", t, " (a value is int, float or bool)")
}

// ---- statements

// whether statements (and the blocks in them) assign to a name
local func assigns(list, name){
  for(let local s in values(list or {})){
    if(s.k == "assign" and s.target.k == "name" and s.target.name == name){
      return true
    }
    if(s.k == "if" and (assigns(s.body, name) or assigns(s.other, name))){
      return true
    }
    if(s.k == "for" and (assigns(s.body, name) or assigns({s.init, s.update}, name))){
      return true
    }
  }
  return false
}

func gen_methods.statements(self, list){
  local outer = self.block_list
  self.block_list = list
  for(let local s in values(list)){
    self:statement(s)
    self:reset()
  }
  self.block_list = outer
}

func gen_methods.block(self, list){
  self:open(false)
  self:statements(list)
  self:close()
}

func gen_methods.statement(self, s){
  self:line(s.line)
  local k = s.k
  if(k == "local"){
    // local x = a[i] of a struct array: a name for the element
    if(s.init != null and s.type == null and s.init.k == "index"){
      local arr = self:lookup(s.init.e.name or "")
      if(arr != null and arr.kind == "array" and type(arr.elem) != "string"){
        local el = self:element(s.init)
        // the index is copied when the block may change it later, so that
        // the name does not move
        local idx = el.idx
        local index = s.init.index
        // (a computed index is a temporary of its own: nothing else writes it)
        local fixed = index.k != "name" or not assigns(self.block_list, index.name)
        if(not fixed){
          idx = self:alloc("i")
          self:emit("movi", idx, el.idx)
        }
        self:declare(s.name, {kind: "ref", slot: el.slot, idx: idx, struct: el.elem}, s.line)
        return null
      }
    }
    local t = null
    if(s.type != null){
      if(type(s.type) != "string"){
        self:fail(s.line, "locals cannot be arrays")
      }
      t = self:value_type(s.type, s.line)
    }
    if(s.init == null){
      if(t == null){
        self:fail(s.line, "local ", s.name, " needs a type or a value")
      }
      local r = self:alloc(reg_file(t))
      self:move(self:const(t, 0), t, r, s.line)
      self:declare(s.name, {kind: "var", t: t, r: r}, s.line)
      return null
    }
    if(t == null){
      // the type is the initializer's: compute it, and keep its register
      // when that is a temporary (else copy: a local is its own register)
      local v = self:expr(s.init, null)
      t = v.t
      if(t == "none"){
        self:fail(s.line, "this call gives no value")
      }
      local r = v.r
      if(not self:is_temp(reg_file(t), r)){
        r = self:alloc(reg_file(t))
        self:move(v, t, r, s.line)
      }
      self:declare(s.name, {kind: "var", t: t, r: r}, s.line)
      return null
    }
    local r = self:alloc(reg_file(t))
    local v = self:expr(s.init, {t: t, r: r})
    self:move(v, t, r, s.line)
    self:declare(s.name, {kind: "var", t: t, r: r}, s.line)
    return null
  }
  if(k == "assign"){
    local target = s.target
    if(target.k == "name"){
      local v = self:lookup(target.name)
      if(v == null){
        if(self.unit.consts[target.name] != null){
          self:fail(s.line, target.name, " is a constant")
        }
        self:fail(s.line, "unknown name ", target.name)
      }
      if(v.kind != "var"){
        self:fail(s.line, target.name, " cannot be assigned")
      }
      local x = self:expr(s.value, {t: v.t, r: v.r})
      self:move(x, v.t, v.r, s.line)
      return null
    }
    if(target.k == "index" or target.k == "field"){
      local p = self:place_of(target)
      local x = self:expr(s.value, null)
      self:store(p, x, s.line)
      return null
    }
    self:fail(s.line, "cannot assign to this")
  }
  if(k == "expr"){
    if(s.e.k != "call"){
      self:fail(s.line, "an expression on its own does nothing")
    }
    self:expr(s.e, null)
    return null
  }
  if(k == "if"){
    local other = self:label()
    local done = self:label()
    self:cond(s.cond, other, false)
    self:block(s.body)
    if(s.other != null){
      self:jump("jmp", done)
    }
    self:place(other)
    if(s.other != null){
      self:block(s.other)
    }
    self:place(done)
    return null
  }
  if(k == "for"){
    self:open(false)
    if(s.init != null){
      self:statement(s.init)
      self:reset()
    }
    local body = self:label()
    local test = self:label()
    local cont = self:label()
    local exit = self:label()
    local counting = self:counting(s)
    if(counting != null){
      // i < n once, then body; i += step and i < n in one instruction
      self:cond(s.cond, exit, false)
      self:reset()
    } else {
      // jump to the test at the bottom
      self:jump("jmp", test)
    }
    self:place(body)
    append(self.loops, {brk: exit, cont: cont})
    self:block(s.body)
    remove(self.loops, len(self.loops) - 1)
    self:place(cont)
    self:line(s.line)
    if(counting != null){
      self:emit(counting.op, counting.i, counting.step, counting.n)
      self:target(body)
    } else {
      if(s.update != null){
        self:statement(s.update)
        self:reset()
      }
      self:place(test)
      if(s.cond == null){
        self:jump("jmp", body)
      } else {
        self:cond(s.cond, body, true)
        self:reset()
      }
    }
    self:place(exit)
    self:close()
    return null
  }
  if(k == "break" or k == "continue"){
    if(len(self.loops) == 0){
      self:fail(s.line, k, " outside a loop")
    }
    local loop = self.loops[len(self.loops) - 1]
    if(k == "break"){
      self:jump("jmp", loop.brk)
    } else {
      self:jump("jmp", loop.cont)
    }
    return null
  }
  if(k == "return"){
    local r = self.ret
    if(r.t == null){
      if(s.value != null){
        self:fail(s.line, "this function returns nothing")
      }
    } else if(s.value == null){
      self:fail(s.line, "return needs a ", r.t)
    }
    if(r.done != null){
      // in an inlined helper
      if(s.value != null){
        local v = self:expr(s.value, r.result)
        self:move(v, r.t, r.result.r, s.line)
      }
      self:jump("jmp", r.done)
      return null
    }
    if(s.value == null){
      self:emit("ret")
      return null
    }
    local v = self:expr(s.value, null)
    if(r.t == "float"){
      v = self:as_float(v, s.line)
      self:emit("retf", v.r)
    } else {
      if(v.t != r.t){
        self:fail(s.line, "return needs a ", r.t, ", found ", v.t)
      }
      self:emit("reti", v.r)
    }
    return null
  }
  self:fail(s.line, "unexpected ", k)
}

// ------------------------------------------------------------ compaction

// the instructions with a word after them, and those whose word is a jump
// target
local WORD_OPS = {}
local TARGET_OPS = {}
for(let local name in values({"jmp", "jt", "jf", "jlti", "jlei", "jeqi", "jnei", "jltf", "jlef", "jeqf", "jnef", "jnltf", "jnlef", "addi_jlti", "addi_jlei", "addi_jgti", "addi_jgei"})){
  WORD_OPS[OP[name]] = true
  TARGET_OPS[OP[name]] = true
}
for(let local name in values({"seli", "self", "madf"})){
  WORD_OPS[OP[name]] = true
}
for(let local k in values(compiler.KINDS)){
  WORD_OPS[OP[concat("ld_", k)]] = true
  WORD_OPS[OP[concat("st_", k)]] = true
}

local func size_of(w){
  if(WORD_OPS[w & 255]){
    return 2
  }
  return 1
}

// compact(code, lines) -> {code, lines}: without nops and jumps to the
// next instruction (inlined returns, empty elses), targets and the line
// table moved to match
local func compact(code, lines){
  local n = len(code)
  local keep = {}
  local pc = 0
  for(pc < n){
    local w = code[pc]
    local size = size_of(w)
    local op = w & 255
    keep[pc] = not (op == OP.nop or (op == OP.jmp and code[pc + 1] == pc + 2))
    pc = pc + size
  }
  // new positions, filled from the end so that a dropped instruction maps
  // to the next kept one
  local at = {}
  local out = {}
  pc = 0
  for(pc < n){
    local size = size_of(code[pc])
    at[pc] = len(out)
    if(keep[pc]){
      for(local k = 0; k < size; k = k + 1){
        append(out, code[pc + k])
      }
    }
    pc = pc + size
  }
  at[n] = len(out)
  pc = 0
  for(pc < n){
    local w = code[pc]
    if(keep[pc] and TARGET_OPS[w & 255]){
      out[at[pc] + 1] = at[code[pc + 1]]
    }
    pc = pc + size_of(w)
  }
  local new_lines = {}
  for(local k = 0; k < len(lines); k = k + 2){
    local p = at[lines[k]]
    local count = len(new_lines)
    if(count > 0 and new_lines[count - 2] == p){
      new_lines[count - 1] = lines[k + 1]
    } else {
      append(new_lines, p)
      append(new_lines, lines[k + 1])
    }
  }
  return {code: out, lines: new_lines}
}

// a counting loop: for(...; i < n; i += step), with any of < <= > >= and
// += or -= (i = i + step, i = i - step), i an int variable and n and step
// an int variable or constant (nothing to compute per round; a step taken
// away must be a constant): {op, i, step, n} for an addi_j.. instruction,
// or null
local counting_ops = {["<"]: "addi_jlti", ["<="]: "addi_jlei", [">"]: "addi_jgti", [">="]: "addi_jgei"}

func gen_methods.counting(self, s){
  local c = s.cond
  local u = s.update
  if(c == null or u == null or c.k != "bin" or counting_ops[c.op] == null or c.l.k != "name"){
    return null
  }
  if(u.k != "assign" or u.target.k != "name" or u.target.name != c.l.name){
    return null
  }
  local v = u.value
  if(v.k != "bin" or (v.op != "+" and v.op != "-") or v.l.k != "name" or v.l.name != c.l.name){
    return null
  }
  local i = self:lookup(c.l.name)
  if(i == null or i.kind != "var" or i.t != "int"){
    return null
  }
  // an int variable or constant, without code
  local func plain(e, negate){
    local value = null
    if(e.k == "num" and e.int){
      value = e.value
    } else if(e.k == "name"){
      local x = self:lookup(e.name)
      if(x != null and x.kind == "var" and x.t == "int" and not negate){
        return x.r
      }
      local k = self.unit.consts[e.name]
      if(x == null and k != null and k.t == "int"){
        value = k.value
      }
    }
    if(value == null){
      return null
    }
    if(negate){
      value = -value
    }
    return self:const("int", value).r
  }
  local n = plain(c.r, false)
  local step = plain(v.r, v.op == "-")
  if(n == null or step == null){
    return null
  }
  return {op: counting_ops[c.op], i: i.r, step: step, n: n}
}

// ------------------------------------------------------------ units

// compile_kernel(unit, item) -> program
local func compile_kernel(unit, item, origin){
  local g = new_gen(unit, origin, item.name)
  g:open(true)
  local params = {}
  local ret_t = null
  local ret_code = 0
  if(item.ret != null){
    ret_t = g:value_type(item.ret, item.line)
    ret_code = {int: P_INT, float: P_FLOAT, bool: P_BOOL}[ret_t]
  }
  for(let local p in values(item.params)){
    if(type(p.type) != "string"){
      // an array: a slot
      local elem = p.type.array
      local kind = KIND[elem]
      local size = 0
      local e = elem
      if(kind == null){
        local st = unit.structs[elem]
        if(st == null){
          g:fail(item.line, "unknown array type ", elem, "[] for ", p.name)
        }
        kind = compiler.STRUCT_KIND
        size = st.size
        e = st
      } else {
        size = KIND_SIZE[kind]
      }
      local slot = g.slots
      g.slots = g.slots + 1
      append(params, {P_ARRAY, slot, kind, size})
      g:declare(p.name, {kind: "array", slot: slot, elem: e}, item.line)
    } else if(unit.structs[p.type] != null){
      // a struct: the first element of a buffer of it
      local st = unit.structs[p.type]
      local slot = g.slots
      g.slots = g.slots + 1
      append(params, {P_STRUCT, slot, compiler.STRUCT_KIND, st.size})
      g:declare(p.name, {kind: "ref", slot: slot, idx: g:const("int", 0).r, struct: st}, item.line)
    } else {
      local t = g:value_type(p.type, item.line)
      local r = g:alloc(reg_file(t))
      append(params, {{int: P_INT, float: P_FLOAT, bool: P_BOOL}[t], r, 0, 0})
      g:declare(p.name, {kind: "var", t: t, r: r}, item.line)
    }
  }
  if(g.slots > 64){
    g:fail(item.line, "a kernel takes at most 64 arrays")
  }
  g.ret = {t: ret_t}
  g:statements(item.body)
  // falling off the end returns nothing, or 0
  g:line(item.line)
  if(ret_t == null){
    g:emit("ret")
  } else if(ret_t == "float"){
    g:emit("retf", g:const("float", 0.0).r)
  } else {
    g:emit("reti", g:const(ret_t, 0).r)
  }
  local compacted = compact(g.code, g.lines)
  local flat_params = {}
  for(let local p in values(params)){
    for(let local x in values(p)){
      append(flat_params, x)
    }
  }
  local iconsts = {}
  for(let local c in values(g.const_list.i)){
    append(iconsts, c[0])
    append(iconsts, c[1])
  }
  local fregs = {}
  local fvals = {}
  for(let local c in values(g.const_list.f)){
    append(fregs, c[0])
    append(fvals, c[1])
  }
  return {
    name: item.name,
    origin: origin,
    line: item.line,
    code: compacted.code,
    iconsts: iconsts,
    fregs: fregs,
    fvals: fvals,
    params: flat_params,
    nparams: len(item.params),
    ret: ret_code,
    slots: g.slots,
    lines: compacted.lines,
    iregs: g.high.i,
    fregs_used: g.high.f,
  }
}

// compile(source: string, origin?: string, first_line?: int) -> Unit
// The kernels and structs of a kernel source.
// type Unit = {kernels: {Program}, structs: {Struct}}
// type Struct = {name: string, size: int, fields: {{name: string, kind:
//   string, offset: int}}}
// A Program is a table of lists (code words, constants, parameters, line
// table) that kernel.load turns into a callable kernel. Raises
// "origin:line: message" on an error.
func compiler.compile(source, origin, first_line){
  origin = origin or "kernel"
  local items = new_parser(lex(source, origin, first_line), origin):unit()
  return compiler.compile_items(items, origin, null)
}

// compile_items(items, origin, env?) -> Unit: env carries the structs,
// constants and helpers of earlier pieces of the same file (inline kernels)
func compiler.compile_items(items, origin, env){
  local unit = env or {structs: {}, consts: {}, funcs: {}}
  local out = {kernels: {}, structs: {}}
  for(let local item in values(items)){
    local taken = unit.structs[item.name] != null or unit.consts[item.name] != null or unit.funcs[item.name] != null
    if(taken and item.k != "func"){
      fail(origin, item.line, item.name, " is already defined")
    }
    if(item.k == "struct"){
      local st = layout_struct(item, unit.structs, origin)
      unit.structs[item.name] = st
      append(out.structs, {name: st.name, size: st.size, fields: st.fields})
    } else if(item.k == "const"){
      unit.consts[item.name] = const_eval(item.e, unit.consts, origin)
    } else {
      if(unit.funcs[item.name] != null){
        fail(origin, item.line, item.name, " is already defined")
      }
      unit.funcs[item.name] = item
      if(item.kernel){
        append(out.kernels, compile_kernel(unit, item, origin))
      }
    }
  }
  return out
}

// parse(source, origin, first_line) -> the top-level items (for the
// inline syntax, which compiles them with compile_items)
func compiler.parse(source, origin, first_line){
  return new_parser(lex(source, origin or "kernel", first_line), origin or "kernel"):unit()
}

// disassemble(program) -> string: the code, one instruction a line
func compiler.disassemble(p){
  local lines = {}
  local pc = 0
  local code = p.code
  local with_word = {
    jmp: true, jt: true, jf: true, jlti: true, jlei: true, jeqi: true,
    jnei: true, jltf: true, jlef: true, jeqf: true, jnef: true, jnltf: true,
    jnlef: true, seli: true, self: true, madf: true, addi_jlti: true,
    addi_jlei: true, addi_jgti: true, addi_jgei: true,
  }
  for(pc < len(code)){
    local w = code[pc]
    local name = compiler.OPS[w & 255]
    local text = concat(string(pc), "\t", name, " ", string((w >> 8) & 255), " ", string((w >> 16) & 255), " ", string((w >> 24) & 255))
    pc = pc + 1
    if(with_word[name] or str.starts_with(name, "ld_") or str.starts_with(name, "st_")){
      text = concat(text, " [", string(code[pc]), "]")
      pc = pc + 1
    }
    append(lines, text)
  }
  return str.join(lines, "\n")
}

return compiler
