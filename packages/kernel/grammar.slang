// kernel/grammar: the kernel language as slang/peg parsers. One grammar
// for every place kernel code is written: a `kernel { ... }` block in a
// slang file (kernel/syntax), a .kernel file, and kernel.compile(source).
// Its tokens carry highlighting categories and its parsers the formatter's
// marks, so kernel code is highlighted and formatted the same way
// wherever it is.
//
//   local grammar = require("kernel/grammar")
//   local items = grammar.parse("func twice(x: int): int { return x * 2 }", "k")
//
// The parsers produce the tree kernel/compiler reads: expressions
// {k: "num" | "bool" | "name" | "bin" | "un" | "call" | "index" | "field",
// line, ...}, statements {k: "local" | "assign" | "expr" | "if" | "for" |
// "break" | "continue" | "return", line, ...} and top-level items
// {k: "struct" | "func" | "global" | "use", line, ...}. Lines are those of
// the text being parsed: a slang file's own in a block.
local peg = require("slang/peg")
local fmt = require("slang/format")
local str = require("slang/string")

local grammar = {}

// ------------------------------------------------------------ tokens

// whitespace and comments, as slang's (the formatter keeps them because
// the parser says it is trivia)
local space_re = peg.space
local trivia = peg.custom(func(self, ctx, pos){
  local q = space_re:match_at(ctx.buffer, pos)
  if(q == pos){
    return -1
  }
  ctx.value = null
  return q
})
trivia.single = true
trivia.trivia = true
grammar.trivia = trivia

local keywords = {
  local: true,
  func: true,
  struct: true,
  use: true,
  ["if"]: true,
  ["else"]: true,
  ["for"]: true,
  ["break"]: true,
  ["continue"]: true,
  ["return"]: true,
  ["and"]: true,
  ["or"]: true,
  ["not"]: true,
  ["true"]: true,
  ["false"]: true,
}
grammar.keywords = keywords

local word_char = peg.pattern("a-zA-Z0-9_")

// a literal token: a keyword (a word not followed by a word character) or
// punctuation
local func tok(s, category){
  local p = peg.string(s, concat("expected ", s))
  if(keywords[s] == true or (category == "keyword")){
    p = peg.seq(p, word_char:forbid()):pick(0)
    category = category or "keyword"
  }
  return p:token(category or "punctuation"):trim(trivia)
}

// tok with the formatter's gaps around it ("none", "space", "line",
// "softline", "hardline", "brace"; null keeps the source's)
local func ftok(s, before, after, category){
  return fmt.gaps(tok(s, category), before, after)
}

// a name (not a keyword) highlighted as category
local name_chars = peg.seq(peg.pattern("a-zA-Z_"), word_char:star())
  :flatten("expected a name")
  :where(func(w){ return keywords[w] != true }, "expected a name")
local func name(category){
  return name_chars:token(category):trim(trivia)
}

// numbers: decimal with _ between digits, hex, binary; a float has a
// fraction or an exponent
local number_re_text = "0[xX][0-9a-fA-F_]+|0[bB][01_]+|[0-9][0-9_]*(\\.[0-9_]*)?([eE][+-]?[0-9]+)?|\\.[0-9][0-9_]*([eE][+-]?[0-9]+)?"
local number_re = require("slang/regex").compile(number_re_text)
local number_chars = peg.custom(func(self, ctx, pos){
  local q = number_re:match_at(ctx.buffer, pos)
  if(q <= pos){
    return peg.fail(ctx, pos, "expected an expression")
  }
  if(word_char:parse_on(ctx, q) >= 0){
    return peg.fail(ctx, q, "a number runs into a name")
  }
  ctx.value = str.substring(ctx.buffer, pos, q)
  return q
})

local func number_value(text){
  local clean = str.join(str.split(text, "_"), "")
  local lower = str.lower(clean)
  if(str.starts_with(lower, "0x") or str.starts_with(lower, "0b")){
    return {value: str.parse_int(clean, 0), int: true}
  }
  if(str.contains(clean, ".") or str.contains(lower, "e")){
    return {value: str.to_number(clean) * 1.0, int: false}
  }
  return {value: str.parse_int(clean, 10), int: true}
}

local number = number_chars:token("number"):trim(trivia):map(func(t){
  local n = number_value(t.value)
  return {k: "num", value: n.value, int: n.int, line: t.line}
})

// "text": a module name for use
local string_chars = peg.seq(
  peg.char("\""),
  peg.pattern("^\"\n"):star(),
  peg.char("\""),
):flatten("expected a string")
local string_lit = string_chars:token("string"):trim(trivia):map(func(t){
  return {value: str.substring(t.value, 1, len(t.value) - 1), line: t.line, token: t}
})

// matches nothing, and only when no line break comes before the next
// token: a call's ( and an index's [ continue an expression only on its
// line (slang's rule)
local same_line = peg.custom(func(self, ctx, pos){
  local buf = ctx.buffer
  local i = pos - 1
  for(i >= 0){
    local b = str.byte_at(buf, i)
    if(b == '\n'){
      return peg.fail(ctx, pos, "on the same line")
    }
    if(b != ' ' and b != '\t' and b != '\r'){
      break
    }
    i = i - 1
  }
  local q = space_re:match_at(buf, pos)
  if(q > pos and str.index_of(str.substring(buf, pos, q), "\n") >= 0){
    return peg.fail(ctx, pos, "on the same line")
  }
  ctx.value = null
  return pos
})

local func elements(sep_list){
  return sep_list.elements
}

// ------------------------------------------------------------ types

// float | Voice | float[] | float[64]
local type_p = peg.seq(
  name("type"),
  peg.seq(
    ftok("[", "none", "none"), number:optional(), ftok("]", "none")
  ):optional(),
):map(func(v){
  local t = v[0]
  if(v[1] == null){
    return {name: t.value, line: t.line}
  }
  local size = null
  if(v[1][1] != null){
    size = v[1][1]
  }
  return {name: t.value, array: true, size: size, line: t.line}
})

// the tree's form of a type: a name, or {array: name, size?}
local func type_of(t){
  if(t == null){
    return null
  }
  if(t.array){
    return {array: t.name, size: t.size}
  }
  return t.name
}

local type_mark = peg.seq(ftok(":", "none", "space"), type_p):pick(1)

// ------------------------------------------------------------ expressions

local expr = peg.settable(null)

local func bin(l, op, r){
  return {k: "bin", op: op.value, l: l, r: r, line: op.line}
}

// an operator: s not followed by any character of not_next (so that < is
// not the start of <= or <<, nor - of -=)
local func op(s, not_next){
  local p = peg.string(s, concat("expected ", s))
  if(not_next != null){
    p = peg.seq(p, peg.pattern(not_next):forbid()):pick(0)
  }
  return p:token("operator"):trim(trivia)
}

local args = fmt.mark(
  peg.seq(
    same_line,
    tok("("),
    fmt.indent(fmt.mark(expr:star_separated(ftok(",", "none", "line")), {
      fill: true,
    }):map(
      elements,
    ), "softline"),
    fmt.trailing_comma(tok(","):optional()),
    fmt.gaps(tok(")"), "softline"),
  ),
  {group: true, hug: true, huggable: "call", before: "none"},
):pick(
  2,
)

local w = peg.walker(peg.skip_space)
w:primary(number, "number")
w:primary(peg.choice(tok("true"), tok("false")):map(func(t){
  return {k: "bool", value: t.value == "true", line: t.line}
}), "bool")
// a call: a name with arguments on its line (only functions by name are
// called); otherwise a name
w:primary(peg.seq(name("function"), args):map(func(v){
  return {k: "call", name: v[0].value, args: v[1], line: v[0].line}
}), "call")
w:primary(name("variable"):map(func(t){
  return {k: "name", name: t.value, line: t.line}
}), "name")

w:level("bracket")
w:wrapper(tok("("), tok(")"), "bracket", func(left, value, right){
  return value
})

w:level("postfix")
w:postfix(
  peg.seq(same_line, ftok("[", "none", "none"), expr, ftok("]", "none")),
  "postfix",
  func(left, v){
    return {k: "index", e: left, index: v[2], line: v[1].line}
  },
)
w:postfix(
  peg.seq(ftok(".", "none", "none"), name("property")),
  "postfix",
  func(left, v){
    return {k: "field", e: left, name: v[1].value, line: v[0].line}
  },
)

// ^ is right-associative and above the unary minus; its exponent may have
// a sign
w:level("power")
w:right(op("^", "="), "power", bin)

w:level("unary")
w:prefix(peg.choice(op("-", "="), op("~", "=")), "unary", func(o, e){
  return {k: "un", op: o.value, e: e, line: o.line}
})

w:level("multiply")
w:left(peg.choice(op("*", "="), op("/", "="), op("%", "=")), "multiply", bin)
w:level("add")
w:left(peg.choice(op("+", "="), op("-", "=")), "add", bin)
w:level("shift")
w:left(peg.choice(op("<<"), op(">>")), "shift", bin)
w:level("bitAnd")
w:left(op("&", "="), "bitAnd", bin)
w:level("bitXor")
w:left(op("~", "="), "bitXor", bin)
w:level("bitOr")
w:left(op("|", "="), "bitOr", bin)
w:level("compare")
w:left(peg.choice(
  op("<="),
  op(">="),
  op("!="),
  op("=="),
  op("<", "<="),
  op(">", ">="),
), "compare", bin)
// `not` sits between and and the comparisons, as in Python
w:level("not")
w:prefix(tok("not", "operator"), "not", func(o, e){
  return {k: "un", op: "not", e: e, line: o.line}
})
w:level("and")
w:left(tok("and", "operator"), "and", bin)
w:level("or")
w:left(tok("or", "operator"), "or", bin)

expr:set(w:build())
grammar.expr = expr

// ------------------------------------------------------------ statements

local statement = peg.settable(null)

local func semicolon(){
  return fmt.drop(tok(";"):optional())
}

// { statements }, one a line
local block = peg.seq(
  tok("{"),
  fmt.indent(fmt.mark(peg.seq(statement, semicolon()):pick(0), {
    before: "hardline",
    blank: true,
  }):star(), "hardline", "hardline"),
  fmt.gaps(tok("}"), "hardline"),
):pick(1)

local compound = {
  ["+="]: "+", ["-="]: "-", ["*="]: "*", ["/="]: "/", ["%="]: "%"
}

// local name: type = value
local local_stat = peg.seq(
  ftok("local", null, "space"),
  name("variable"),
  type_mark:optional(),
  peg.seq(ftok("=", "space", "space"), expr):pick(1):optional(),
):map(func(v){
  return {
    k: "local", name: v[1].value, type: type_of(v[2]), init: v[3],
    line: v[0].line
  }
})

// target = value, target += value, or a lone expression (a call; a for's
// condition)
local assign_op = peg.choice(
  op("+="),
  op("-="),
  op("*="),
  op("/="),
  op("%="),
  op("=", "="),
)
local expr_stat = peg.seq(
  expr,
  peg.seq(fmt.gaps(assign_op, "space", "space"), expr):optional(),
):map(func(v){
  local target = v[0]
  if(v[1] == null){
    return {k: "expr", e: target, line: target.line}
  }
  local o = v[1][0]
  local value = v[1][1]
  if(compound[o.value] != null){
    value = {k: "bin", op: compound[o.value], l: target, r: value, line: o.line}
  }
  return {k: "assign", target: target, value: value, line: target.line}
})

local simple = peg.choice(local_stat, expr_stat)

local if_stat = peg.settable(null)
if_stat:set(
  peg.seq(
    ftok("if", null, "none"),
    ftok("(", "none", "none"),
    expr,
    ftok(")", "none", "brace"),
    fmt.gaps(block, "none"),
    peg.seq(
      ftok("else", "space", "space"),
      peg.choice(if_stat, fmt.gaps(block, "none")),
    ):pick(1):optional(),
  )
    :map(func(v){
      local other = v[5]
      if(other != null and other.k == "if"){
        other = {other}
      }
      return {k: "if", cond: v[2], body: v[4], other: other, line: v[0].line}
    }),
)

// for(init; cond; update) with each part optional, or for(cond)
local for_stat = peg.seq(
  ftok("for", null, "none"),
  ftok("(", "none", "none"),
  peg.choice(peg.seq(
    simple:optional(),
    ftok(";", "none", "space"),
    expr:optional(),
    ftok(";", "none", "space"),
    simple:optional(),
  ):map(func(v){
    return {init: v[0], cond: v[2], update: v[4]}
  }), expr:map(func(e){ return {cond: e} })),
  ftok(")", "none", "brace"),
  fmt.gaps(block, "none"),
)
  :map(func(v){
    local h = v[2]
    return {
      k: "for", init: h.init, cond: h.cond, update: h.update, body: v[4],
      line: v[0].line
    }
  })

local return_stat = peg.seq(tok("return"), expr:optional()):map(func(v){
  return {k: "return", value: v[1], line: v[0].line}
})

statement:set(peg.choice(
  if_stat,
  for_stat,
  tok("break"):map(func(t){ return {k: "break", line: t.line} }),
  tok("continue"):map(func(t){ return {k: "continue", line: t.line} }),
  return_stat,
  simple,
))

// ------------------------------------------------------------ items

// struct Name { field: type = default, ... }
local field = peg.seq(
  name("property.declaration"),
  type_mark,
  peg.seq(ftok("=", "space", "space"), expr):pick(1):optional(),
  peg.choice(ftok(",", "none"), ftok(";", "none")):optional(),
):map(func(v){
  return {name: v[0].value, type: type_of(v[1]), default: v[2], line: v[0].line}
})

local struct_item = peg.seq(
  ftok("struct", null, "space"),
  name("type.declaration"),
  ftok("{", "space"),
  fmt.indent(
    fmt.mark(field, {before: "hardline"}):star(), "hardline", "hardline"
  ),
  fmt.gaps(tok("}"), "hardline"),
):map(func(v){
  return {
    k: "struct", name: v[1].value, fields: v[3], line: v[0].line, token: v[1]
  }
})

local param = peg.seq(name("parameter"), type_mark):map(func(v){
  return {name: v[0].value, type: type_of(v[1]), line: v[0].line}
})

local params = fmt.mark(
  peg.seq(
    tok("("),
    fmt.indent(fmt.mark(param:star_separated(ftok(",", "none", "line")), {
      fill: true,
    }):map(
      elements,
    ), "softline"),
    fmt.trailing_comma(tok(","):optional()),
    fmt.gaps(tok(")"), "softline"),
  ),
  {group: true, before: "none"},
):pick(
  1,
)

// func name(params): type { body }: an entry point slang calls;
// local func: a helper, inlined where it is called
local func_item = peg.seq(
  ftok("local", null, "space"):optional(),
  ftok("func", null, "space"),
  name("function.declaration"),
  params,
  // f(x){ as slang writes it; a space after a result type: f(x): int {
  peg.choice(
    peg.seq(type_mark, fmt.gaps(block, "space")),
    fmt.gaps(block, "none"):map(func(b){ return {null, b} }),
  ),
):map(func(v){
  return {
    k: "func",
    kernel: v[0] == null,
    name: v[2].value,
    params: v[3],
    ret: type_of(v[4][0]),
    body: v[4][1],
    line: v[2].line,
    token: v[2],
  }
})

// local name: type = value: a constant, or the kernels' state when a
// function assigns it
local global_item = peg.seq(
  ftok("local", null, "space"),
  name("variable.declaration"),
  type_mark:optional(),
  peg.seq(ftok("=", "space", "space"), expr):pick(1):optional(),
):map(func(v){
  return {
    k: "global", name: v[1].value, type: type_of(v[2]), init: v[3],
    line: v[1].line
  }
})

// use "module": the structs, constants and helpers of another kernel module
local use_item = peg.seq(ftok("use", null, "space"), string_lit):map(func(v){
  return {k: "use", module: v[1].value, line: v[0].line, token: v[1].token}
})

// one top-level item, with its optional `;`
grammar.item = peg.seq(
  peg.choice(struct_item, func_item, global_item, use_item),
  semicolon(),
):pick(0)

// items, one a line (a blank line between them kept)
grammar.items = fmt.mark(grammar.item, {before: "hardline", blank: true}):star()

// ------------------------------------------------------------ parsing

// parse(source: string, origin?: string, first_line?: int) -> {table}
// The top-level items of kernel source. Raises "origin:line: message"
// (kind compile) when it does not parse. first_line is the line the source
// starts at in its file.
func grammar.parse(source, origin, first_line){
  origin = origin or "kernel"
  // lines count from the source's first line in its file: as many line
  // breaks before it
  local shift = (first_line or 1) - 1
  if(shift > 0){
    source = concat("\n" * shift, source)
  }
  local r = peg.run(
    peg.seq(trivia:optional(), grammar.items):pick(1):end(),
    source,
  )
  if(not r.ok){
    local line = r.far_line or r.line
    local msg = r.far_message or r.message or "syntax error"
    raise(error.new(
      error.kinds.compile,
      concat(origin, ":", string(line), ": ", msg),
      {origin: origin, line: line},
    ))
  }
  return r.value
}

return grammar
