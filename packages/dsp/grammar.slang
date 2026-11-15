// dsp/grammar: the block-diagram language as slang/peg parsers, for every
// place it is written: a `dsp name { ... }` block in a slang file (the
// extension dsp.slang), a .dsp file (dsp/file) and dsp.compile(source).
// Tokens carry highlighting categories and parsers the formatter's marks,
// so the code is highlighted and formatted the same way wherever it is.
//
// A program is a list of definitions:
//
//   import "std";                         // the definitions of std.dsp
//   gain = hslider("gain", 0.5, 0, 1, 0.01);
//   lowpass(c) = *(1 - c) : + ~ *(c);     // a definition with parameters
//   process = _ : lowpass(0.9) : *(gain);
//
// Expressions are block diagrams. From the loosest operator to the
// tightest:
//
//   a <: b   a :> b     split (copy a's outputs onto b's inputs), merge (sum)
//   a : b               sequence (a's outputs into b's inputs)
//   a , b               in parallel
//   a ~ b               feedback (b's outputs back into a's first inputs,
//                       one sample late)
//   < <= > >= == !=     comparisons, then + - |, then * / % & xor,
//                       then ^, then @ (delay): `a + b` is `a, b : +`
//   x'  f(args)         one sample of delay; application
//
// Primaries: numbers, `_` (a wire), `!` (a cut), names, strings (labels),
// operators as boxes (`+`, `*`, `@`...), `(expr)`, `par(i, n, e)`,
// `seq(i, n, e)`, `sum(i, n, e)`, `prod(i, n, e)`, and lambdas
// `\(x, y).(e)`. A definition may end in `with { definitions }`.
//
// The tree: expressions {k: "num" | "wire" | "cut" | "name" | "str" | "op"
// | "bin" | "comp" | "app" | "mem" | "iter" | "lambda", line, ...};
// definitions {k: "def", name, params, body, with?, line, token} and
// {k: "import", module, line, token}.
local peg = require("slang/peg")
local fmt = require("slang/format")
local str = require("slang/string")

local grammar = {}

// ------------------------------------------------------------ tokens

// whitespace and comments, as slang's (trivia: the formatter keeps them)
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
  import: true,
  with: true,
  par: true,
  seq: true,
  sum: true,
  prod: true,
  xor: true,
}
grammar.keywords = keywords

// the primitives the evaluator knows, highlighted as builtins
grammar.builtins = {
  mem: true,
  int: true,
  float: true,
  hslider: true,
  vslider: true,
  nentry: true,
  button: true,
  checkbox: true,
  select2: true,
  select3: true,
  attach: true,
  take: true,
  SR: true,
  min: true,
  max: true,
  pow: true,
  atan2: true,
  fmod: true,
  sin: true,
  cos: true,
  tan: true,
  asin: true,
  acos: true,
  atan: true,
  exp: true,
  log: true,
  log10: true,
  sqrt: true,
  abs: true,
  floor: true,
  ceil: true,
  rint: true,
  tanh: true,
}

local word_char = peg.pattern("a-zA-Z0-9_")

// a literal token: a keyword (not followed by a word character) or
// punctuation
local func tok(s, category){
  local p = peg.string(s, concat("expected ", s))
  if(keywords[s] == true){
    p = peg.seq(p, word_char:forbid()):pick(0)
    category = category or "keyword"
  }
  return p:token(category or "punctuation"):trim(trivia)
}

local func ftok(s, before, after, category){
  return fmt.gaps(tok(s, category), before, after)
}

// an operator: s not followed by any character of not_next (so that < is
// not the start of <= or <:)
local func op(s, not_next){
  local p = peg.string(s, concat("expected ", s))
  if(not_next != null){
    p = peg.seq(p, peg.pattern(not_next):forbid()):pick(0)
  }
  return p:token("operator"):trim(trivia)
}

local name_chars = peg.seq(peg.pattern("a-zA-Z_"), word_char:star())
  :flatten("expected a name")
  :where(func(w){ return keywords[w] != true and w != "_" }, "expected a name")

// a name used in an expression: builtins apart
local name_use = name_chars:token(func(w){
  if(grammar.builtins[w] == true){
    return "function.defaultLibrary"
  }
  return "variable"
}):trim(trivia)

local func name(category){
  return name_chars:token(category):trim(trivia)
}

// numbers: 440, 0.5, .5, 1e-3, 2.5e3; an optional minus sign right before
// the digits makes a negative constant (-1), not the box `-`
local number_re = require("slang/regex").compile(
  "-?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?",
)
local number_chars = peg.custom(func(self, ctx, pos){
  local q = number_re:match_at(ctx.buffer, pos)
  if(q <= pos){
    return peg.fail(ctx, pos, "expected a number")
  }
  if(word_char:parse_on(ctx, q) >= 0){
    return peg.fail(ctx, q, "a number runs into a name")
  }
  ctx.value = str.substring(ctx.buffer, pos, q)
  return q
})
local number = number_chars:token("number"):trim(trivia):map(func(t){
  return {k: "num", value: str.to_number(t.value) * 1.0, line: t.line}
})

// "text": a label or a module name
local string_chars = peg.seq(
  peg.char("\""),
  peg.pattern("^\"\n"):star(),
  peg.char("\""),
):flatten("expected a string")
local string_lit = string_chars:token("string"):trim(trivia):map(func(t){
  return {
    k: "str",
    value: str.substring(t.value, 1, len(t.value) - 1),
    line: t.line,
    token: t,
  }
})

local func elements(sep_list){
  return sep_list.elements
}

// ------------------------------------------------------------ expressions

// expr: a whole diagram; arg: one without `,` at its top (an argument of
// an application, where `,` separates the arguments)
local expr = peg.settable(null)
local arg = peg.settable(null)
grammar.expr = expr

// (a, b, c): a list laid out as a call's arguments
local func list_of(item){
  return fmt.mark(
    peg.seq(
      tok("("),
      fmt.indent(fmt.mark(item:star_separated(ftok(",", "none", "line")), {
        fill: true,
      }):map(elements), "softline"),
      fmt.trailing_comma(tok(","):optional()),
      fmt.gaps(tok(")"), "softline"),
    ),
    {group: true, hug: true, huggable: "call", before: "none"},
  ):pick(1)
}

local args = list_of(arg)

// operators that are boxes when written alone: `+` is the box with two
// inputs and one output that adds; `+(1)` adds 1 to its one input
local op_boxes = peg.choice(
  op("<:"),
  op(":>"),
  op("<<"),
  op(">>"),
  op("<=", null),
  op(">=", null),
  op("==", null),
  op("!=", null),
  op("<", "=:<"),
  op(">", "=>"),
  op("+"),
  op("-"),
  op("*"),
  op("/"),
  op("%"),
  op("^"),
  op("@"),
  op("&"),
  op("|"),
  tok("xor", "operator"),
):map(func(t){
  return {k: "op", op: t.value, line: t.line}
})

// par(i, n, e), seq(...), sum(...), prod(...): n copies of e, i bound to
// 0 .. n-1 in each
local iteration = peg.seq(
  peg.choice(tok("par"), tok("seq"), tok("sum"), tok("prod")),
  fmt.mark(peg.seq(tok("("), fmt.indent(peg.seq(
    name("parameter"),
    ftok(",", "none", "line"),
    arg,
    ftok(",", "none", "line"),
    arg,
  ), "softline"), fmt.gaps(tok(")"), "softline")), {group: true, before: "none"}),
)
  :map(func(v){
    local inner = v[1][1]
    return {
      k: "iter",
      op: v[0].value,
      var: inner[0].value,
      count: inner[2],
      body: inner[4],
      line: v[0].line,
    }
  })

// \(x, y).(e): a function of its parameters
local lambda = peg.seq(
  ftok("\\", null, "none", "operator"),
  list_of(name("parameter")),
  ftok(".", "none", "none", "operator"),
  ftok("(", "none", "none"),
  expr,
  ftok(")", "none"),
):map(func(v){
  local params = {}
  for(let local p in values(v[1])){
    append(params, p.value)
  }
  return {k: "lambda", params: params, body: v[4], line: v[0].line}
})

local func bin(l, o, r){
  return {k: "bin", op: o.value, a: l, b: r, line: o.line, column: o.column}
}

local func comp(l, o, r){
  return {k: "comp", op: o.value, a: l, b: r, line: o.line, column: o.column}
}

// a chain of compositions: on one line, or one operand a line with the
// operator in front
local func chain(p){
  return fmt.mark(p, {break_before: true, style: "lines"})
}

// the tight operators: everything up to ~
local func inner_walker(){
  local w = peg.walker(peg.skip_space)
  w:primary(number, "number")
  w:primary(ftok("_", null, null, "variable.defaultLibrary"):map(func(t){
    return {k: "wire", line: t.line}
  }), "wire")
  w:primary(op("!", "="):map(func(t){
    return {k: "cut", line: t.line}
  }), "cut")
  w:primary(iteration, "iteration")
  w:primary(lambda, "lambda")
  w:primary(name_use:map(func(t){
    return {k: "name", name: t.value, line: t.line, column: t.column, token: t}
  }), "name")
  w:primary(string_lit, "string")
  w:primary(op_boxes, "operator")
  // (e): a whole diagram, loose operators and all
  w:primary(fmt.mark(peg.seq(
    tok("("),
    fmt.indent(expr, "softline"),
    fmt.gaps(tok(")"), "softline"),
  ), {group: true, hug: true}):pick(1), "bracket")

  // x' (a sample of delay) and f(args)
  w:level("postfix")
  w:postfix(fmt.gaps(op("'"), "none"), "postfix", func(left, o){
    return {k: "mem", e: left, line: o.line}
  })
  w:postfix(args, "postfix", func(left, a){
    return {k: "app", f: left, args: a, line: left.line, column: left.column}
  })

  // -x is 0 - x, for a name right after the minus (-(1) is the box -
  // applied to 1: 1 subtracted from its input)
  w:level("unary")
  w:prefix(
    peg.seq(peg.string("-"), peg.and(peg.pattern("a-zA-Z")))
      :pick(0)
      :token("operator")
      :trim(trivia),
    "unary",
    func(o, e){
      return {
        k: "bin", op: "-", a: {k: "num", value: 0.0, line: o.line}, b: e,
        line: o.line
      }
    },
  )

  w:level("delay")
  w:left(op("@"), "delay", bin)
  w:level("power")
  w:left(op("^"), "power", bin)
  w:level("multiply")
  w:left(
    peg.choice(op("*"), op("/"), op("%"), op("&"), tok("xor", "operator")),
    "multiply", bin
  )
  w:level("add")
  w:left(peg.choice(op("+"), op("-"), op("|")), "add", bin)
  w:level("shift")
  w:left(peg.choice(op("<<"), op(">>")), "shift", bin)
  w:level("compare")
  w:left(peg.choice(
    op("<="),
    op(">="),
    op("=="),
    op("!="),
    op("<", "=:<"),
    op(">", "=>"),
  ), "compare", bin)
  w:level("rec")
  w:left(op("~"), "rec", comp)
  return w:build()
}

// the loose operators : <: :> over operands
local func outer_walker(operand){
  local w = peg.walker(peg.skip_space)
  w:primary(operand, "operand")
  w:level("seq")
  w:left(chain(op(":", ">")), "seq", comp)
  w:level("split")
  w:left(chain(peg.choice(op("<:"), op(":>"))), "split", comp)
  return w:build()
}

local tight = inner_walker()

// a , b , c: in parallel; a broken list continues indented
local parallel = fmt.mark(peg.seq(tight, fmt.indent(
  peg.seq(ftok(",", "none", "line", "operator"), tight),
  null,
):star(,
)), {group: true}):map(func(v){
  local e = v[0]
  for(let local tail in values(v[1])){
    e = {
      k: "comp",
      op: ",",
      a: e,
      b: tail[1],
      line: tail[0].line,
      column: tail[0].column,
    }
  }
  return e
})

expr:set(outer_walker(parallel))
arg:set(outer_walker(tight))

// ------------------------------------------------------------ definitions

local definition = peg.settable(null)

local func semicolon(){
  return fmt.gaps(tok(";"), "none")
}

// name = e;   name(x, y) = e;   ... = e with { definitions };
local with_clause = peg.seq(
  ftok("with", "space", "space"),
  tok("{"),
  fmt.indent(
    fmt.mark(definition, {before: "hardline", blank: true}):star(), "hardline",
    "hardline"
  ),
  fmt.gaps(tok("}"), "hardline"),
):pick(2)

local def_item = peg.seq(
  name("function.declaration"),
  list_of(name("parameter")):optional(),
  ftok("=", "space", "space"),
  expr,
  with_clause:optional(),
  semicolon(),
):map(func(v){
  local params = null
  if(v[1] != null){
    params = {}
    for(let local p in values(v[1])){
      append(params, p.value)
    }
  }
  return {
    k: "def",
    name: v[0].value,
    params: params,
    body: v[3],
    with: v[4],
    line: v[0].line,
    token: v[0],
  }
})

// import "std"; the definitions of std.dsp, as if written here
local import_item = peg.seq(
  ftok("import", null, "space"), string_lit, semicolon()
)
  :map(func(v){
    return {k: "import", module: v[1].value, line: v[0].line, token: v[1].token}
  })

definition:set(peg.choice(import_item, def_item))

// one top-level item
grammar.item = definition

// items, one a line (a blank line between them kept)
grammar.items = fmt.mark(definition, {before: "hardline", blank: true}):star()

// ------------------------------------------------------------ parsing

// parse(source: string, origin?: string) -> {table}
// The definitions of a program. Raises an error of kind compile with
// {origin, line} when it does not parse.
func grammar.parse(source, origin){
  origin = origin or "dsp"
  local r = peg.run(
    peg.seq(trivia:optional(), grammar.items):pick(1):end(),
    source,
  )
  if(not r.ok){
    local line = r.far_line or r.line
    local msg = r.far_message or r.message or "syntax error"
    raise(error.new(
      error.kinds.compile,
      msg,
      {origin: origin, line: line, located: true},
    ))
  }
  return r.value
}

return grammar
