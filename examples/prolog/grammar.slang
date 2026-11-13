// The Prolog reader: text to terms (see ast.slang).
//
// Operators are Prolog's op/3 table on a Pratt walker. A term has a
// priority (0 for primaries and parenthesised terms, P for a term an
// operator of priority P built) and lower priorities bind tighter, so an
// operator of priority P gets the binding power 1201 - P, and parsing "a
// term of priority <= max" is parse_at with min_bp 1200 - max: the walker
// then applies exactly the operators with P <= max. The type of an operator
// says what its operands may be: x is < P, y is <= P (xfx, xfy, yfx, fy, fx,
// xf, yf). The walker only knows binding powers, so values in the walker
// are {term, priority} and every operator checks the priority of its left
// operand itself; that is what makes xfx non-associative (a = b = c is an
// error) and keeps xfy and yfx of one priority from mixing.
//
// Tokens follow the standard: names (foo, =.., !, ;, 'quoted'), variables
// (X, _x, _), numbers (1, 1.5, 1.0e10, 0'c, 0x1f, 0o17, 0b101), strings
// ("text"), punctuation and the end token (a "." followed by layout or the
// end of input). A name directly followed by "(" is a compound in
// functional notation, so -(1) is the compound and - (1) the operator;
// a "-" directly followed by a number is a negative number.
local peg = require("slang/peg")
local str = require("slang/string")
local utf8 = require("slang/utf8")
local ast = require("ast")

local M = {}

// ----------------------------------------------------------------- operators

local OP_CLASSES = {
  xfx: "infix", xfy: "infix", yfx: "infix",
  fy: "prefix", fx: "prefix",
  xf: "postfix", yf: "postfix",
}

local DEFAULT_OPS = {
  {1200, "xfx", {":-", "-->"}},
  {1200, "fx", {":-", "?-"}},
  {1150, "fx", {"dynamic", "discontiguous", "initialization", "multifile"}},
  {1100, "xfy", {";"}},
  {1050, "xfy", {"->", "*->"}},
  {1000, "xfy", {","}},
  {900, "fy", {"\\+"}},
  {700, "xfx", {
    "=", "\\=", "==", "\\==", "@<", "@>", "@=<", "@>=", "=..", "is",
    "=:=", "=\\=", "<", ">", "=<", ">=",
  }},
  {600, "xfy", {":"}},
  {500, "yfx", {"+", "-", "/\\", "\\/", "xor"}},
  {400, "yfx", {"*", "/", "//", "rem", "mod", "div", "<<", ">>"}},
  {200, "xfx", {"**"}},
  {200, "xfy", {"^"}},
  {200, "fy", {"-", "+", "\\"}},
}

local Operators = {}
Operators.__index = Operators
Operators.__type = "Operators"

// operators(empty?: bool) -> Operators: the standard operator table, or an
// empty one
func M.operators(empty){
  // version counts the changes, so that readers know when to rebuild
  local ops = {prefix: {}, infix: {}, postfix: {}, version: 0}
  ops.@meta = Operators
  if(not empty){
    for(let {local priority, local kind, local names} in values(DEFAULT_OPS)){
      for(let local name in values(names)){
        ops:add(priority, kind, name)
      }
    }
  }
  return ops
}

// add(priority: int, kind: string, name: string): op/3; priority 0 removes
// the operator of that class (prefix, infix or postfix)
func Operators.add(self, priority, kind, name){
  local class = OP_CLASSES[kind]
  if(class == null){
    raise(error.new(error.kinds.argument, concat(
      "operator type ", kind, " is not one of xfx xfy yfx fy fx xf yf"
    )))
  }
  if(type(priority) != "int" or priority < 0 or priority > 1200){
    raise(error.new(error.kinds.argument, concat(
      "operator priority ", priority, " is not 0..1200"
    )))
  }
  if(priority == 0){
    delete(self[class], name)
  } else {
    self[class][name] = {priority: priority, type: kind}
  }
  self.version = self.version + 1
}

// priority(name) -> int: the priority of the atom name as an operand: an
// operand stands where a prefix operator would, so that of its prefix
// definition, else the highest of the others (0 for no operator), so that
// - - is -(-) although - is also infix at 500
func Operators.priority(self, name){
  local prefix = self.prefix[name]
  if(prefix != null){
    return prefix.priority
  }
  local p = 0
  for(let local class in values({"infix", "postfix"})){
    local def = self[class][name]
    if(def != null and def.priority > p){
      p = def.priority
    }
  }
  return p
}

// -------------------------------------------------------------------- tokens

local func is_digit(b) => b != null and b >= '0' and b <= '9'

local func is_alnum(b) => b != null and (
  (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or is_digit(b)
  or b == '_'
)

local func is_layout(b) => b == ' ' or b == '\t' or b == '\n' or b == '\r'

local PUNCT = {
  ['(']: true, [')']: true, ['[']: true, [']']: true, ['{']: true,
  ['}']: true, [',']: true, ['|']: true,
}

local ESCAPES = {
  ['n']: "\n", ['t']: "\t", ['r']: "\r", ['s']: " ",
  ['a']: utf8.char(7), ['b']: utf8.char(8), ['f']: utf8.char(12),
  ['v']: utf8.char(11), ['e']: utf8.char(27),
  [92]: "\\", [39]: "'", [34]: "\"", [96]: "`",
}

// the position after layout (blanks, % and /* */ comments) at pos
local func skip_layout(buf, pos){
  local n = len(buf)
  for(pos < n){
    local b = str.byte_at(buf, pos)
    if(is_layout(b)){
      pos = pos + 1
    } else if(b == '%'){
      for(pos < n and str.byte_at(buf, pos) != '\n'){
        pos = pos + 1
      }
    } else if(b == '/' and str.byte_at(buf, pos + 1) == '*'){
      pos = pos + 2
      for(pos < n and not (str.byte_at(buf, pos) == '*'
        and str.byte_at(buf, pos + 1) == '/')){
        pos = pos + 1
      }
      pos = pos + 2
      if(pos > n){
        return n
      }
    } else {
      return pos
    }
  }
  return pos
}

// digits of base from pos up to the closing "\" of an escape:
// {code, stop} or {error}
local func escape_code(buf, pos, base){
  local start = pos
  for(is_alnum(str.byte_at(buf, pos))){
    pos = pos + 1
  }
  if(pos == start or str.byte_at(buf, pos) != 92){
    return {error: "malformed escape sequence"}
  }
  local code = str.parse_int(str.substring(buf, start, pos), base)
  if(code == null){
    return {error: "malformed escape sequence"}
  }
  return {code: code, stop: pos + 1}
}

// the escape sequence at pos (on the backslash): {text, stop} or {error}
local func read_escape(buf, pos){
  local c = str.byte_at(buf, pos + 1)
  if(c == '\n'){
    return {text: "", stop: pos + 2}
  }
  if(c == 'x'){
    local e = escape_code(buf, pos + 2, 16)
    if(e.error != null){
      return e
    }
    return {text: utf8.char(e.code), stop: e.stop}
  }
  if(c != null and c >= '0' and c <= '7'){
    local e = escape_code(buf, pos + 1, 8)
    if(e.error != null){
      return e
    }
    return {text: utf8.char(e.code), stop: e.stop}
  }
  local text = ESCAPES[c]
  if(c == null or text == null){
    return {error: "unknown escape sequence"}
  }
  return {text: text, stop: pos + 2}
}

// the text quoted by q from pos (on the opening quote): {text, stop} or
// {error}; a doubled quote stands for the quote
local func read_quoted(buf, pos, q){
  local out = ""
  local i = pos + 1
  local start = i
  for(true){
    local b = str.byte_at(buf, i)
    if(b == null){
      return {error: "unterminated quoted text"}
    }
    if(b == q){
      if(str.byte_at(buf, i + 1) != q){
        return {text: concat(out, str.substring(buf, start, i)), stop: i + 1}
      }
      out = concat(out, str.substring(buf, start, i + 1))
      i = i + 2
      start = i
    } else if(b == 92){
      out = concat(out, str.substring(buf, start, i))
      local e = read_escape(buf, i)
      if(e.error != null){
        return e
      }
      out = concat(out, e.text)
      i = e.stop
      start = i
    } else {
      i = i + 1
    }
  }
}

local func token(kind, start, stop, text, value) => {
  kind: kind, start: start, stop: stop, text: text, value: value,
}

local func error_token(start, message) => {
  kind: "error", start: start, stop: start, message: message,
}

local RADIX = {['x']: 16, ['o']: 8, ['b']: 2}

// a number token at start (a digit)
local func lex_number(buf, start){
  local b1 = str.byte_at(buf, start + 1)
  if(str.byte_at(buf, start) == '0' and b1 == 39){
    // 0'c: the code of the character c
    local c = str.byte_at(buf, start + 2)
    if(c == 92){
      local e = read_escape(buf, start + 2)
      if(e.error != null){
        return error_token(start, e.error)
      }
      return token("integer", start, e.stop, null, utf8.code_at(e.text, 0))
    }
    if(c == 39 and str.byte_at(buf, start + 3) == 39){
      return token("integer", start, start + 4, null, 39)
    }
    if(c == null){
      return error_token(start, "character expected after 0'")
    }
    return token(
      "integer", start, start + 2 + utf8.size_at(buf, start + 2), null,
      utf8.code_at(buf, start + 2),
    )
  }
  local base = null
  if(b1 != null){
    base = RADIX[b1]
  }
  if(str.byte_at(buf, start) == '0' and base != null){
    local pos = start + 2
    for(is_alnum(str.byte_at(buf, pos))){
      pos = pos + 1
    }
    local v = str.parse_int(str.substring(buf, start + 2, pos), base)
    if(v != null){
      return token("integer", start, pos, null, v)
    }
  }
  local pos = start
  for(is_digit(str.byte_at(buf, pos))){
    pos = pos + 1
  }
  if(str.byte_at(buf, pos) != '.' or not is_digit(str.byte_at(buf, pos + 1))){
    local text = str.substring(buf, start, pos)
    return token("integer", start, pos, null, str.parse_int(text, 10))
  }
  pos = pos + 1
  for(is_digit(str.byte_at(buf, pos))){
    pos = pos + 1
  }
  local e = str.byte_at(buf, pos)
  if(e == 'e' or e == 'E'){
    local q = pos + 1
    local s = str.byte_at(buf, q)
    if(s == '+' or s == '-'){
      q = q + 1
    }
    if(is_digit(str.byte_at(buf, q))){
      pos = q
      for(is_digit(str.byte_at(buf, pos))){
        pos = pos + 1
      }
    }
  }
  return token(
    "float", start, pos, null, to_float(str.substring(buf, start, pos)),
  )
}

// the token at start (after layout)
local func lex(buf, start){
  local b = str.byte_at(buf, start)
  if(b == null){
    return token("eof", start, start)
  }
  if(is_digit(b)){
    return lex_number(buf, start)
  }
  if(b == '_' or (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z')){
    local pos = start + 1
    for(is_alnum(str.byte_at(buf, pos))){
      pos = pos + 1
    }
    local kind = "name"
    if(b == '_' or (b >= 'A' and b <= 'Z')){
      kind = "variable"
    }
    return token(kind, start, pos, str.substring(buf, start, pos))
  }
  if(b == 39 or b == 34){
    local q = read_quoted(buf, start, b)
    if(q.error != null){
      return error_token(start, q.error)
    }
    local kind = "quoted"
    if(b == 34){
      kind = "string"
    }
    return token(kind, start, q.stop, q.text)
  }
  if(PUNCT[b]){
    return token("punct", start, start + 1, str.substring(buf, start, start + 1))
  }
  if(b == '!' or b == ';'){
    return token("name", start, start + 1, str.substring(buf, start, start + 1))
  }
  if(b == '.'){
    local next = str.byte_at(buf, start + 1)
    if(next == null or is_layout(next) or next == '%'){
      return token("end", start, start + 1, ".")
    }
  }
  if(ast.is_symbol_char(b)){
    local pos = start + 1
    for(ast.is_symbol_char(str.byte_at(buf, pos))){
      pos = pos + 1
    }
    return token("name", start, pos, str.substring(buf, start, pos))
  }
  return error_token(start, "unexpected character")
}

// the token at pos (before layout), lexed once per context
local func token_at(ctx, pos){
  local cache = ctx.prolog_tokens
  if(cache == null){
    cache = {}
    ctx.prolog_tokens = cache
  }
  local t = cache[pos]
  if(t == null){
    t = lex(ctx.buffer, skip_layout(ctx.buffer, pos))
    cache[pos] = t
  }
  return t
}

local func is_punct(t, text) => t.kind == "punct" and t.text == text

// a parser of one token that pred accepts; its value is the token. A
// mismatch is "<what> expected", or not recorded without what (operators:
// there are too many to list, and the first failure at a position is the
// one reported)
local func token_parser(pred, what) => peg.custom(func(self, ctx, pos){
  local t = token_at(ctx, pos)
  if(t.kind == "error"){
    return peg.fail(ctx, t.start, t.message)
  }
  if(pred(t, ctx)){
    ctx.value = t
    return t.stop
  }
  if(what == null){
    return -1
  }
  return peg.fail(ctx, t.start, concat(what, " expected"))
})

// a negative number: "-" directly followed by a number token
local func negative_number(ctx, t){
  if(t.kind != "name" or t.text != "-"){
    return null
  }
  local n = lex(ctx.buffer, t.stop)
  if(n.kind == "integer" or n.kind == "float"){
    return n
  }
  return null
}

// --------------------------------------------------------------------- terms

local func pv(term, priority) => {term: term, priority: priority}

// reader(ops?: Operators) -> {term, clause, program, ops}: parsers over the
// operator table (the standard one when not given). term parses a term of
// priority 1200, clause a term and the end token, program clauses up to the
// end of input. The parsers see ops as they are when they first run;
// after an op/3 change make a new reader.
func M.reader(ops){
  ops = ops or M.operators()
  local w = peg.walker()

  // a term of priority <= max at pos; the value is {term, priority}
  local func operand(ctx, pos, max){
    local r = w:parse_at(ctx, pos, 1200 - max)
    if(r < 0){
      return -1
    }
    if(ctx.value.priority > max){
      return peg.fail(ctx, pos, concat(
        "operator priority clash: a term of priority ", ctx.value.priority,
        " where at most ", max, " is allowed",
      ))
    }
    return r
  }

  local func expect(ctx, pos, text){
    local t = token_at(ctx, pos)
    if(is_punct(t, text)){
      return t.stop
    }
    return peg.fail(ctx, t.start, concat("\"", text, "\" expected"))
  }

  // an argument of a compound or a list element: a term of priority 999,
  // or an operator as an atom (f(-, +), [:-])
  local func argument(ctx, pos){
    local r = operand(ctx, pos, 999)
    if(r >= 0){
      ctx.value = ctx.value.term
      return r
    }
    local t = token_at(ctx, pos)
    if(t.kind == "name"){
      local after = token_at(ctx, t.stop)
      if(after.kind == "punct" and (after.text == "," or after.text == ")"
        or after.text == "|" or after.text == "]")){
        ctx.value = ast.atom(t.text)
        return t.stop
      }
    }
    return -1
  }

  // arguments separated by "," from pos; the value is the list
  local func arguments(ctx, pos){
    local items = {}
    local r = argument(ctx, pos)
    if(r < 0){
      return -1
    }
    append(items, ctx.value)
    for(is_punct(token_at(ctx, r), ",")){
      r = argument(ctx, token_at(ctx, r).stop)
      if(r < 0){
        return -1
      }
      append(items, ctx.value)
    }
    ctx.value = items
    return r
  }

  // ---- primaries

  w:primary(peg.custom(func(self, ctx, pos){
    local t = token_at(ctx, pos)
    local sign = 1
    local n = negative_number(ctx, t)
    if(n != null){
      sign = -1
      t = n
    }
    if(t.kind != "integer" and t.kind != "float"){
      return peg.fail(ctx, t.start, "term expected")
    }
    if(t.kind == "integer"){
      ctx.value = pv(ast.integer(sign * t.value), 0)
    } else {
      ctx.value = pv(ast.float(sign * t.value), 0)
    }
    return t.stop
  }), "number")

  w:primary(token_parser(
    func(t) => t.kind == "variable", "term",
  ):map(func(t) => pv(ast.variable(t.text), 0)), "variable")

  w:primary(token_parser(
    func(t) => t.kind == "string", "term",
  ):map(func(t) => pv(ast.string(t.text), 0)), "string")

  // an atom, or a compound in functional notation: name(args)
  w:primary(peg.custom(func(self, ctx, pos){
    local t = token_at(ctx, pos)
    if(t.kind != "name" and t.kind != "quoted"){
      return peg.fail(ctx, t.start, "term expected")
    }
    if(str.byte_at(ctx.buffer, t.stop) == '('){
      local r = arguments(ctx, t.stop + 1)
      if(r < 0){
        return -1
      }
      local items = ctx.value
      r = expect(ctx, r, ")")
      if(r < 0){
        return -1
      }
      ctx.value = pv(ast.compound(t.text, items), 0)
      return r
    }
    // an operator as an atom has the priority of the operator (quoted
    // atoms are never operators)
    local priority = 0
    if(t.kind == "name"){
      priority = ops:priority(t.text)
    }
    ctx.value = pv(ast.atom(t.text), priority)
    return t.stop
  }), "atom")

  // ( term )
  w:primary(peg.custom(func(self, ctx, pos){
    local r = expect(ctx, pos, "(")
    if(r < 0){
      return -1
    }
    r = operand(ctx, r, 1200)
    if(r < 0){
      return -1
    }
    local term = ctx.value.term
    r = expect(ctx, r, ")")
    if(r < 0){
      return -1
    }
    ctx.value = pv(term, 0)
    return r
  }), "parentheses")

  // [], [a, b], [a | T]
  w:primary(peg.custom(func(self, ctx, pos){
    local r = expect(ctx, pos, "[")
    if(r < 0){
      return -1
    }
    local t = token_at(ctx, r)
    if(is_punct(t, "]")){
      ctx.value = pv(ast.atom("[]"), 0)
      return t.stop
    }
    r = arguments(ctx, r)
    if(r < 0){
      return -1
    }
    local items = ctx.value
    local tail = null
    t = token_at(ctx, r)
    if(is_punct(t, "|")){
      r = argument(ctx, t.stop)
      if(r < 0){
        return -1
      }
      tail = ctx.value
    }
    r = expect(ctx, r, "]")
    if(r < 0){
      return -1
    }
    ctx.value = pv(ast.list(items, tail), 0)
    return r
  }), "list")

  // {}, {term}
  w:primary(peg.custom(func(self, ctx, pos){
    local r = expect(ctx, pos, "{")
    if(r < 0){
      return -1
    }
    local t = token_at(ctx, r)
    if(is_punct(t, "}")){
      ctx.value = pv(ast.atom("{}"), 0)
      return t.stop
    }
    r = operand(ctx, r, 1200)
    if(r < 0){
      return -1
    }
    local term = ctx.value.term
    r = expect(ctx, r, "}")
    if(r < 0){
      return -1
    }
    ctx.value = pv(ast.compound("{}", {term}), 0)
    return r
  }), "curly")

  // ---- operators

  // an operator token: an unquoted name, or "," and "|"
  local func operator_token(name) => func(t) => t.text == name and (
    t.kind == "name" or t.kind == "punct"
  )

  for(let {local name, local def} in entries(ops.prefix)){
    local priority = def.priority
    local max = priority
    if(def.type == "fx"){
      max = priority - 1
    }
    local is_name = operator_token(name)
    // not the name of a compound -(1), nor the sign of a number -1
    local op = token_parser(func(t, ctx) => is_name(t)
      and str.byte_at(ctx.buffer, t.stop) != '('
      and negative_number(ctx, t) == null)
    // when no operand follows, the operator is an atom (a primary)
    w:nud(op, 1201 - priority, func(w, ctx, pos, tok){
      local r = operand(ctx, pos, max)
      if(r < 0){
        return -1
      }
      ctx.value = pv(ast.compound(name, {ctx.value.term}), priority)
      return r
    })
  }

  for(let {local name, local def} in entries(ops.infix)){
    local priority = def.priority
    local left_max = priority - 1
    local right_max = priority - 1
    if(def.type == "yfx"){
      left_max = priority
    } else if(def.type == "xfy"){
      right_max = priority
    }
    w:led(
      token_parser(operator_token(name)), 1201 - priority,
      func(w, ctx, pos, left, tok){
        if(left.priority > left_max){
          return peg.fail(ctx, tok.start, concat(
            "operator priority clash: the left operand of ", name,
            " has priority ", left.priority, ", at most ", left_max,
            " is allowed",
          ))
        }
        local r = operand(ctx, pos, right_max)
        if(r < 0){
          return -1
        }
        ctx.value = pv(
          ast.compound(name, {left.term, ctx.value.term}), priority,
        )
        return r
      },
    )
  }

  for(let {local name, local def} in entries(ops.postfix)){
    local priority = def.priority
    local left_max = priority - 1
    if(def.type == "yf"){
      left_max = priority
    }
    w:led(
      token_parser(operator_token(name)), 1201 - priority,
      func(w, ctx, pos, left, tok){
        if(left.priority > left_max){
          return peg.fail(ctx, tok.start, concat(
            "operator priority clash: the operand of ", name,
            " has priority ", left.priority, ", at most ", left_max,
            " is allowed",
          ))
        }
        ctx.value = pv(ast.compound(name, {left.term}), priority)
        return pos
      },
    )
  }

  local term = peg.custom(func(self, ctx, pos){
    local r = operand(ctx, pos, 1200)
    if(r >= 0){
      ctx.value = ctx.value.term
    }
    return r
  })
  local clause = peg.seq(
    term,
    token_parser(func(t) => t.kind == "end", "\".\""),
  ):map(func(r) => r[0])
  local program = peg.seq(
    clause:star(),
    token_parser(func(t) => t.kind == "eof", "end of input"),
  ):map(func(r) => r[0])

  return {term: term, clause: clause, program: program, ops: ops}
}

// read_program(text, ops?) -> {"ok", {term}} | {"error", message}
func M.read_program(text, ops) => M.reader(ops).program:parse(text)

// ----------------------------------------------------- reading clause by clause

// A file can't be parsed in one go: an op/3 directive changes how the
// clauses after it read. A source is text being read one clause at a time,
// with a reader rebuilt whenever the operator table changed.

// source(text) -> a Source to read clauses from with read_clause
func M.source(text) => {
  ctx: peg.context(text), pos: 0, reader: null, ops: null, version: -1,
}

// the position after the next end token from pos (or the end of input):
// where reading goes on after a syntax error
local func skip_clause(ctx, pos){
  for(true){
    local t = token_at(ctx, pos)
    if(t.kind == "end"){
      return t.stop
    }
    if(t.kind == "eof"){
      return t.start
    }
    if(t.kind == "error"){
      // a character no token starts with: step over it
      pos = t.start + 1
    } else {
      pos = t.stop
    }
  }
}

// read_clause(src, ops) -> the next clause: {term} (a reader term, with
// Variable nodes), {error: message} for a syntax error (reading goes on
// after the clause's end token), or null at the end of the text
func M.read_clause(src, ops){
  if(src.reader == null or not same(src.ops, ops) or src.version != ops.version){
    src.reader = M.reader(ops)
    src.ops = ops
    src.version = ops.version
  }
  local ctx = src.ctx
  local first = token_at(ctx, src.pos)
  if(first.kind == "eof"){
    return null
  }
  ctx.fail_pos = -1
  ctx.far_pos = -1
  local r = src.reader.clause:parse_on(ctx, src.pos)
  if(r >= 0){
    src.pos = r
    return {term: ctx.value}
  }
  local at = ctx.fail_pos
  local msg = ctx.fail_msg
  if(ctx.far_pos > at){
    at = ctx.far_pos
    msg = ctx.far_msg
  }
  local lc = peg.line_col(ctx, at)
  src.pos = skip_clause(ctx, src.pos)
  return {error: concat(msg, " at line ", lc[0], ", column ", lc[1])}
}

// --------------------------------------------------------------------- tests

group("grammar"){
  // the canonical text of the one clause in text
  local func read(text, ops){
    local r = M.reader(ops).program:parse(text)
    assert(r[0] == "ok", concat("parse failed: ", r[1]))
    assert(len(r[1]) == 1, concat("expected one clause in ", text))
    return ast.canonical(r[1][0])
  }
  local func fails(text){
    local r = M.reader().program:parse(text)
    assert(r[0] == "error", concat("expected an error for ", text))
    return r[1]
  }
  local func check(text, expected){
    local got = read(text)
    assert(got == expected, concat(text, " read as ", got, ", not ", expected))
  }

  group("primaries"){
    test("atoms"){
      let {'Atom{name: "hello"}} = M.read_program("hello.")[1]
      assert(type(M.read_program("hello.")[1][0]) == "Atom")
      assert(type(M.read_program("'hello'.")[1][0]) == "Atom")
      check("heLL91oll.", "heLL91oll")
      check("'hello world'.", "'hello world'")
      check("'don''t'.", "'don\\'t'")
      check("'a\\nb'.", "'a\\nb'")
      check("[].", "[]")
      check("{}.", "{}")
      check("!.", "!")
      check("=.. .", "=..")
    }
    test("variables"){
      let {'Variable{name: "Hello"}} = M.read_program("Hello.")[1]
      check("_foo.", "_foo")
      check("_.", "_")
    }
    test("numbers"){
      let {'Integer{value: 123}} = M.read_program("123.")[1]
      let {'Float{value: 123.45}} = M.read_program("123.45.")[1]
      check("1.5e3.", "1500.0")
      check("0'a.", "97")
      check("0' .", "32")
      check("0x1f.", "31")
      check("0b101.", "5")
      check("-3.", "-3")
      check("- 3.", "-(3)")
      check("-(3).", "-(3)")
    }
    test("strings"){
      let {'String{value: "hi \"you\""}} = M.read_program(
        "\"hi \\\"you\\\"\"."
      )[1]
    }
    test("compounds"){
      let {
        'Compound{
          name: "hello",
          arguments: {
            'Atom{name: "h"},
            'Atom{name: "o"},
          },
        },
      } = M.read_program("hello(h,o).")[1]
      check("f(X, g(Y), 'a b').", "f(X,g(Y),'a b')")
      check("+(1, 2).", "+(1,2)")
    }
    test("lists and curly terms"){
      check("[a, b, c].", "[a,b,c]")
      check("[a | T].", "[a|T]")
      check("[a, b | [c]].", "[a,b,c]")
      check("'.'(a, []).", "[a]")
      check("{a, b}.", "{}(','(a,b))")
    }
    test("layout and comments"){
      check("  foo( /* here */ a ) % a comment\n  .", "foo(a)")
      fails("foo (a).")
    }
  }

  group("operators"){
    test("priorities"){
      check("a :- b, c ; d.", ":-(a,;(','(b,c),d))")
      check("1 + 2 * 3.", "+(1,*(2,3))")
      check("X is 1 + 2.", "is(X,+(1,2))")
      check("a :- \\+ b, c.", ":-(a,','(\\+(b),c))")
      check("(a :- b).", ":-(a,b)")
      check("- a * b.", "*(-(a),b)")
    }
    test("associativity"){
      check("1 - 2 - 3.", "-(-(1,2),3)")
      check("a , b , c.", "','(a,','(b,c))")
      check("2 ^ 3 ^ 4.", "^(2,^(3,4))")
      check("a - (b - c).", "-(a,-(b,c))")
    }
    test("xfx does not associate"){
      fails("a = b = c.")
      fails("a :- b :- c.")
      check("(a = b) = c.", "=(=(a,b),c)")
    }
    test("prefix operators"){
      check(":- dynamic foo/1, bar/2.", ":-(dynamic(','(/(foo,1),/(bar,2))))")
      check("- - a.", "-(-(a))")
      check("\\+ (a, b).", "\\+(','(a,b))")
      check("\\+(a, b).", "\\+(a,b)")
      check("a - -1.", "-(a,-1)")
      check("a-1.", "-(a,1)")
    }
    test("operators as atoms"){
      check("X = - .", "=(X,-)")
      check("f(-, +).", "f(-,+)")
      check("[-, :-].", "[-,:-]")
      check("- = x.", "=(-,x)")
      check("X = (:-).", "=(X,:-)")
      check("x :- - - .", ":-(x,-(-))")
      check("f(- -).", "f(-(-))")
      fails("X = :- .")
    }
    test("arguments are priority 999"){
      fails("f(a :- b).")
      check("f((a, b)).", "f(','(a,b))")
      check("f(a, b).", "f(a,b)")
    }
    test("a new operator"){
      local ops = M.operators()
      ops:add(700, "xfx", "===>")
      ops:add(200, "xf", "++")
      assert(read("a ===> b.", ops) == "===>(a,b)")
      assert(read("a ++ .", ops) == "++(a)")
      ops:add(0, "xfx", "===>")
      assert(M.reader(ops).program:parse("a ===> b.")[0] == "error")
    }
  }

  test("programs"){
    let {"ok", local clauses} = M.read_program(
      "app([], L, L).\napp([H|T], L, [H|R]) :- app(T, L, R).\n"
    )
    assert(len(clauses) == 2)
    assert(ast.canonical(clauses[1]) == ":-(app([H|T],L,[H|R]),app(T,L,R))")
    fails("foo")
    fails("foo(.")
    fails("'unterminated.")
  }
}

return M
