// slang/grammar: the slang grammar, built with slang/peg, including the
// registry that lets programs extend the parser at compile time.
local peg = require("slang/peg")
local ast = require("slang/ast")
local str = require("slang/string")

local grammar = {}

local func list(...items){
  return items
}

local func elements(sep_list){
  return sep_list.elements
}

local func join_chars(chars){
  return str.join(chars, "")
}

// new(opts) -> grammar object
//   opts.run_block(block_node) -> value   executes an unquote at parse time
//   opts.optimize(block_node) -> node     applied to a parsed chunk
func grammar.new(opts){
  opts = opts or {}
  local g = {}
  g.keywords = {
    ["if"]: true, ["else"]: true, ["for"]: true, ["func"]: true, ["return"]: true,
    ["local"]: true, ["true"]: true, ["false"]: true, ["null"]: true, ["let"]: true,
    ["break"]: true,
  }
  g.in_quote = false
  // set once the grammar was extended / once an unquote ran (bytecode of a
  // file is only cached when neither happened)
  g.extended = false
  g.unquotes_executed = false

  // ------------------------------------------------------------ lexical

  func g.comment(){
    return peg.seq(peg.string("//"), peg.any():star_lazy(peg.char("\n")))
  }

  // whitespace and comments are skipped by one native call
  func g.space(){
    local p = peg.custom(func(self, ctx, pos){
      local q = str.skip_space(ctx.buffer, pos)
      if(q == pos){
        return peg.fail(ctx, pos, "whitespace expected")
      }
      ctx.value = null
      return q
    })
    p.single = true
    return p
  }

  local space = peg.ref(g.space)
  space.single = true

  local ident_class = str.char_class("a-zA-Z0-9_")
  local letter_class = str.char_class("a-zA-Z")

  // is_word("local") -> true: letters/digits/underscores with at least one letter
  local func is_word(s){
    local n = len(s)
    local has_letter = false
    for(local i = 0; i < n; i = i + 1){
      if(str.class_match(ident_class, s, i) != 1){
        return false
      }
      if(str.class_match(letter_class, s, i) == 1){
        has_letter = true
      }
    }
    return has_letter
  }

  // token(source, message): a token parser trimmed by whitespace and comments.
  // Word-like tokens (keywords, `not`, `and`, ...) must not be followed by an
  // identifier character, so that `notify` or `localVar` stay identifiers.
  func g.token(source, message){
    if(type(source) == "string"){
      local p = peg.string(source, concat("Expected: ", message or source))
      if(is_word(source)){
        p = peg.seq(p, peg.pattern("a-zA-Z0-9_"):forbid()):pick(0)
      }
      return p:token():trim(space)
    }
    if(peg.is_parser(source)){
      return source:flatten(message):token():trim(space)
    }
    error("Invalid token source: ", source)
  }

  local func tok(s){
    return peg.ref(g.token, s)
  }

  func g.keyword(s){
    g.keywords[s] = true
    g.extended = true
    return tok(s)
  }

  // ------------------------------------------------------------ literals

  func g.number(){
    return peg.digit():plus()
  }

  local sign = peg.choice(peg.char("-"), peg.char("+")):optional()

  func g.int_literal(){
    return g.token(peg.seq(sign, peg.ref(g.number)), "int"):map(func(t){
      return ast.node("Int", {value: to_int(t.value)}, t)
    })
  }

  func g.double_literal(){
    return g.token(peg.seq(sign, peg.ref(g.number), peg.char("."), peg.ref(g.number)), "double"):map(func(t){
      return ast.node("Double", {value: str.to_number(t.value)}, t)
    })
  }

  func g.valid_escape(){
    return peg.seq(
      peg.char("\\"),
      peg.choice(peg.char("\""), peg.char("\\"), peg.char("n"), peg.char("r"),
                 peg.char("t"), peg.char("b"), peg.char("f"), peg.char("v"))
    ):flatten()
  }

  func g.slang_char(){
    return peg.choice(peg.ref(g.valid_escape), peg.char("\n"):neg())
  }

  func g.double_quoted_string(){
    return peg.seq(
      peg.char("\""),
      peg.ref(g.slang_char):star_lazy(peg.char("\"")):map(join_chars),
      peg.char("\"")
    ):pick(1):token()
  }

  func g.multiline_string(){
    return peg.seq(
      peg.string("\"\"\""),
      peg.choice(peg.ref(g.slang_char), peg.char("\n")):star_lazy(peg.string("\"\"\"")):map(join_chars),
      peg.string("\"\"\"")
    ):pick(1):token()
  }

  func g.string_literal(){
    return peg.choice(peg.ref(g.multiline_string), peg.ref(g.double_quoted_string)):map(func(t){
      return ast.node("String", {value: ast.resolve_escapes(t.value)}, t)
    })
  }

  func g.true_literal(){
    return tok("true"):map(func(t){ return ast.node("True", {}, t) })
  }

  func g.false_literal(){
    return tok("false"):map(func(t){ return ast.node("False", {}, t) })
  }

  func g.null_literal(){
    return tok("null"):map(func(t){ return ast.node("Null", {}, t) })
  }

  func g.identifier(){
    return g.token(
      peg.seq(peg.string("..."):optional(), peg.pattern("a-zA-Z_"), peg.pattern("a-zA-Z0-9_"):star())
        :flatten("Expected: identifier")
        :where(func(name){ return g.keywords[name] != true }),
      "identifier"
    ):map(func(t){
      return ast.node("Identifier", {value: t.value}, t)
    })
  }

  // ------------------------------------------------------------ tables

  // field: name: value | [key]: value | value
  func g.field(){
    return peg.seq(
      peg.choice(
        peg.seq(peg.ref(g.identifier), tok(":")):pick(0),
        peg.seq(tok("["), g.expr(), tok("]"), tok(":")):pick(1)
      ):optional(),
      g.expr()
    ):token():map(func(t){
      local key = t.value[0]
      if(key != null and key.type == "Identifier"){
        key = ast.node("String", {value: key.value}, key.token)
      }
      return ast.node("Field", {key: key, value: t.value[1]}, t)
    })
  }

  func g.table_literal(){
    return peg.seq(
      tok("{"),
      peg.ref(g.field):star_separated(tok(",")),
      tok(","):optional(),
      tok("}")
    ):pick(1):map(elements):token():map(func(t){
      return ast.node("Table", {fields: t.value}, t)
    })
  }

  // ------------------------------------------------------------ calls

  func g.identifier_and_index(){
    return peg.seq(
      peg.ref(g.identifier),
      peg.choice(
        peg.seq(tok("["), g.expr(), tok("]")):pick(1):map(func(e){ return {e, "bracket"} }),
        peg.seq(tok("."), peg.ref(g.identifier):map(func(id){
          return ast.node("String", {value: id.value}, id.token)
        })):pick(1):map(func(e){ return {e, "dot"} })
      ):star()
    ):map(func(v){
      local node = v[0]
      for(let local right in values(v[1])){
        node = ast.node("Index", {receiver: node, index: right[0], dotStyle: right[1] == "dot"}, right[0].token)
      }
      return node
    })
  }

  func g.name_and_args(){
    return peg.seq(
      peg.seq(tok(":"), peg.ref(g.identifier)):pick(1):optional(),
      peg.ref(g.args)
    ):token():map(func(t){
      return list(t.value[0], t.value[1], t)
    })
  }

  func g.args(){
    return peg.choice(
      peg.seq(
        peg.seq(tok("("), g.expr():star_separated(tok(",")):map(elements), tok(")")):pick(1),
        peg.ref(g.block):optional()
      ),
      peg.ref(g.block)
    ):map(func(args){
      if(type(args) == "Block"){
        return {ast.node("Function", {params: {}, body: args}, args.token)}
      }
      local normal = args[0]
      local block = args[1]
      if(block != null){
        append(normal, ast.node("Function", {params: {}, body: block}, block.token))
      }
      return normal
    })
  }

  // ------------------------------------------------------------ statements

  func g.expr_statement(){
    return peg.seq(g.expr(), peg.seq(tok("="), g.expr()):optional()):map(func(v){
      local exp = v[0]
      local assignment = v[1]
      if(assignment != null){
        if(not ast.is_assignable(exp)){
          error("Invalid assignment: ", ast.to_string(exp), " is not an assignable expression")
        }
        return ast.node("Assignment", {left: exp, right: assignment[1]}, assignment[0])
      }
      if(exp.type == "Call" or exp.type == "Invoke"){
        return ast.node("CallStat", {call: exp}, exp.token)
      }
      if(exp.type == "Null"){
        return null
      }
      return exp
    })
  }

  func g.local_declaration(){
    return peg.seq(tok("local"), g.expr(), peg.seq(tok("="), g.expr()):optional()):map(func(v){
      local right = null
      if(v[2] != null){
        right = v[2][1]
      }
      return ast.node("Declaration", {is_local: true, left: v[1], right: right}, v[0])
    })
  }

  func g.if_statement(){
    return peg.seq(
      tok("if"), tok("("), g.expr(), tok(")"), g.statement(),
      peg.seq(tok("else"), g.statement()):optional()
    ):map(func(v){
      local else_branch = null
      if(v[5] != null){
        else_branch = v[5][1]
      }
      return ast.node("If", {condition: v[2], thenBranch: v[4], elseBranch: else_branch}, v[0])
    })
  }

  func g.for_loop(){
    return peg.seq(
      tok("for"), tok("("),
      peg.ref(g.expression_or_statement),
      peg.seq(tok(";"), peg.ref(g.expression_or_statement)):pick(1):optional(),
      peg.seq(tok(";"), g.statement()):pick(1):optional(),
      peg.char(")"),
      g.statement()
    ):map(func(v){
      local head = {}
      for(local i = 2; i <= 4; i = i + 1){
        if(v[i] != null){
          append(head, v[i])
        }
      }
      local body = v[6]
      local n = len(head)
      if(n == 3){
        return ast.node("For", {init: head[0], condition: head[1], update: head[2], body: body}, v[0])
      }
      if(n == 2){
        if(ast.is_statement(head[0])){
          return ast.node("For", {init: head[0], condition: head[1], body: body}, v[0])
        }
        return ast.node("For", {condition: head[0], update: head[1], body: body}, v[0])
      }
      if(n == 1){
        return ast.node("For", {condition: head[0], body: body}, v[0])
      }
      error("Invalid for loop")
    })
  }

  func g.for_in_loop(){
    return peg.seq(
      tok("for"), tok("("), tok("let"), peg.ref(g.slang_pattern), tok("in"), g.expr(), tok(")"), g.statement()
    ):map(func(v){
      return ast.node("ForIn", {pattern: v[3], itterator: v[5], body: v[7]}, v[0])
    })
  }

  func g.function_definition_statement(){
    return peg.seq(tok("local"):optional(), tok("func"), peg.ref(g.identifier_and_index), peg.ref(g.function_definition)):map(func(v){
      return ast.node("Declaration", {is_local: v[0] != null, left: v[2], right: v[3]}, v[1])
    })
  }

  func g.expression_or_statement(){
    return peg.choice(
      peg.ref(g.local_declaration),
      peg.ref(g.if_statement),
      peg.ref(g.for_loop),
      peg.ref(g.for_in_loop),
      peg.ref(g.block),
      peg.ref(g.function_definition_statement),
      peg.ref(g.expr_statement)
    )
  }

  func g.chunk(){
    return peg.seq(
      peg.seq(g.statement(), tok(";"):optional()):pick(0):star(),
      peg.seq(peg.ref(g.final_statement), tok(";"):optional()):pick(0):optional()
    ):token():map(func(t){
      local statements = {}
      local items = t.value[0]
      local n = len(items)
      for(local i = 0; i < n; i = i + 1){
        if(items[i] != null){
          append(statements, items[i])
        }
      }
      if(t.value[1] != null){
        append(statements, t.value[1])
      }
      return ast.node("Block", {statements: statements}, t)
    })
  }

  func g.block(){
    return peg.seq(tok("{"), peg.ref(g.chunk), tok("}")):pick(1)
  }

  func g.break_statement(){
    return tok("break"):map(func(t){ return ast.node("Break", {}, t) })
  }

  func g.return_statement(){
    return peg.seq(tok("return"), g.expr()):map(func(v){
      return ast.node("Return", {value: v[1]}, v[0])
    })
  }

  func g.final_statement(){
    return peg.choice(peg.ref(g.return_statement), peg.ref(g.break_statement))
  }

  // ------------------------------------------------------------ functions

  func g.params(){
    return peg.ref(g.identifier):star_separated(tok(",")):map(elements)
  }

  func g.function_definition(){
    return peg.seq(
      tok("("), peg.ref(g.params), tok(")"),
      peg.choice(peg.ref(g.block), peg.seq(tok("=>"), g.expr()))
    ):token():map(func(t){
      local v = t.value
      local body = v[3]
      if(type(body) == "table"){
        local e = body[1]
        body = ast.node("Block", {statements: {ast.node("Return", {value: e}, e.token)}}, t)
      }
      return ast.node("Function", {params: v[1], body: body}, t)
    })
  }

  func g.function_expression(){
    return peg.seq(tok("func"), peg.ref(g.function_definition)):pick(1)
  }

  // ------------------------------------------------------------ patterns

  func g.slang_pattern(){
    return peg.choice(peg.ref(g.table_pattern), peg.ref(g.const_pattern), peg.ref(g.var_pattern))
  }

  func g.table_pattern(){
    return peg.seq(
      peg.seq(tok("'"), peg.ref(g.identifier)):pick(1):optional(),
      tok("{"),
      peg.ref(g.field_pattern):star_separated(tok(",")),
      tok("}")
    ):map(func(v){
      local type_name = "table"
      if(v[0] != null){
        type_name = v[0].value
      }
      return ast.node("TablePattern", {type_check: type_name, fields: v[2].elements}, v[1])
    })
  }

  func g.field_pattern(){
    return peg.seq(
      peg.choice(
        peg.seq(peg.ref(g.identifier), tok(":")):pick(0),
        peg.seq(tok("["), g.expr(), tok("]"), tok(":")):pick(1)
      ):map(func(exp){
        if(exp.type == "Identifier"){
          return ast.node("String", {value: exp.value}, exp.token)
        }
        return exp
      }):optional(),
      peg.ref(g.slang_pattern)
    ):map(func(v){
      local key = v[0]
      local value = v[1]
      local token = value.token
      if(key != null){
        token = key.token
      }
      return ast.node("FieldPattern", {key: key, value: value}, token)
    })
  }

  func g.const_pattern(){
    return peg.choice(
      peg.ref(g.int_literal), peg.ref(g.double_literal), peg.ref(g.string_literal),
      peg.ref(g.true_literal), peg.ref(g.false_literal), peg.ref(g.null_literal)
    ):map(func(exp){
      return ast.node("ConstPattern", {value: exp}, exp.token)
    })
  }

  func g.var_pattern(){
    return peg.seq(tok("local"):optional(), peg.ref(g.identifier), tok("?"):optional()):map(func(v){
      return ast.node("VarPattern", {isLocal: v[0] != null, canBeNull: v[2] != null, name: v[1]}, v[1].token)
    })
  }

  func g.pattern_assignment_exp(){
    return peg.seq(tok("let"), peg.ref(g.slang_pattern), tok("="), g.expr()):map(func(v){
      return ast.node("Let", {pattern: v[1], right: v[3]}, v[0])
    })
  }

  // ------------------------------------------------------------ quoting

  func g.quote_body(){
    return peg.choice(
      peg.seq(tok("id"), tok(":"), peg.ref(g.identifier)),
      peg.seq(tok("block"), tok(":"), peg.ref(g.chunk)),
      peg.seq(tok("stat"), tok(":"), peg.choice(g.statement(), peg.ref(g.final_statement))),
      peg.seq(peg.seq(tok("expr"), tok(":")):optional(), g.expr())
    )
  }

  local func split_quote_body(body){
    if(len(body) == 3){
      return list(body[0].value, body[2])
    }
    return list("expr", body[1])
  }

  func g.quote(){
    local body_ref = peg.ref(g.quote_body)
    local body = peg.custom(func(self, ctx, pos){
      local prev = g.in_quote
      g.in_quote = true
      local q = body_ref:parse_on(ctx, pos)
      g.in_quote = prev
      return q
    })
    return peg.seq(tok("+"), tok("{"), body, tok("}")):pick(2):token():map(func(t){
      local parts = split_quote_body(t.value)
      return ast.node("Quote", {ast_type: parts[0], ast: parts[1]}, t)
    })
  }

  func g.unquote(){
    local body_ref = peg.ref(g.quote_body):token()
    local body = peg.custom(func(self, ctx, pos){
      local q = body_ref:parse_on(ctx, pos)
      if(q < 0){
        return -1
      }
      local t = ctx.value
      local parts = split_quote_body(t.value)
      local type_name = parts[0]
      local node = parts[1]
      if(g.in_quote){
        ctx.value = ast.node("Unquote", {ast_type: type_name, ast: node}, t)
        return q
      }
      if(type_name != "expr" and type_name != "block"){
        return peg.fail(ctx, pos, "Unquote outside of quote can only be used with expr or block")
      }
      if(type_name == "expr"){
        node = ast.node("Block", {statements: {ast.node("Return", {value: node}, node.token)}}, node.token)
      }
      if(opts.run_block == null){
        error("this grammar cannot execute unquotes")
      }
      g.unquotes_executed = true
      local result = opts.run_block(node)
      if(result == null){
        ctx.value = ast.node("Null", {}, t)
      } else {
        ctx.value = ast.decode(result)
      }
      return q
    })
    return peg.seq(tok("-"), tok("{"), body, tok("}")):pick(2)
  }

  // ------------------------------------------------------------ expressions

  local func binop(left, op, right){
    return ast.node("BinOp", {left: left, op: op.value, right: right}, op)
  }

  local func not_brace(parser){
    return peg.seq(parser, peg.char("{"):forbid()):pick(0)
  }

  g.primitive_levels = {
    {names: {"unquote", "-{}"}, parser: peg.ref(g.unquote)},
    {names: {"quote", "+{}"}, parser: peg.ref(g.quote)},
    {names: {"identifier", "id"}, parser: peg.ref(g.identifier)},
    {names: {"doubleLiteral", "double", "float"}, parser: peg.ref(g.double_literal)},
    {names: {"intLiteral", "integer", "int"}, parser: peg.ref(g.int_literal)},
    {names: {"stringLiteral", "string", "str"}, parser: peg.ref(g.string_literal)},
    {names: {"trueLiteral", "true"}, parser: peg.ref(g.true_literal)},
    {names: {"falseLiteral", "false"}, parser: peg.ref(g.false_literal)},
    {names: {"nullLiteral", "null"}, parser: peg.ref(g.null_literal)},
    {names: {"patternAssignmentExp", "let"}, parser: peg.ref(g.pattern_assignment_exp)},
    {names: {"listLiteral", "list", "tableLiteral", "table"}, parser: peg.ref(g.table_literal)},
    {names: {"functionExpression", "function"}, parser: peg.ref(g.function_expression)},
  }

  g.group_levels = {
    {names: {"bracket", "()"}, add: func(builder){
      return builder:group():wrapper(tok("("), tok(")"), func(left, value, right){ return value })
    }},
    {names: {"indexAndCall", ".", "[]", ":()"}, add: func(builder){
      local group = builder:group()
      group:postfix(peg.seq(tok("."), peg.ref(g.identifier)), func(left, op){
        local name = op[1]
        return ast.node("Index", {receiver: left, index: ast.node("String", {value: name.value}, name.token), dotStyle: true}, op[0])
      })
      group:postfix(peg.seq(tok("["), builder.loopback, tok("]")), func(left, op){
        return ast.node("Index", {receiver: left, index: op[1], dotStyle: false}, op[0])
      })
      group:postfix(peg.ref(g.name_and_args), func(left, op){
        local name = op[0]
        local args = op[1]
        local token = op[2]
        if(name != null){
          return ast.node("Invoke", {receiver: left, name: name, args: args}, token)
        }
        return ast.node("Call", {function: left, args: args}, token)
      })
      return group
    }},
    {names: {"power", "^"}, add: func(builder){
      return builder:group():right(tok("^"), binop)
    }},
    {names: {"unary"}, add: func(builder){
      return builder:group():prefix(peg.choice(not_brace(tok("-")), tok("not")), func(op, exp){
        return ast.node("UnOp", {op: op.value, operand: exp}, op)
      })
    }},
    {names: {"multiply", "*", "/", "%"}, add: func(builder){
      return builder:group():left(peg.choice(tok("*"), tok("/"), tok("%")), binop)
    }},
    {names: {"add", "+", "-"}, add: func(builder){
      return builder:group():left(peg.choice(not_brace(tok("-")), not_brace(tok("+"))), binop)
    }},
    {names: {"compare", "<=", ">=", "!=", "==", ">"}, add: func(builder){
      return builder:group():left(peg.choice(tok("<="), tok(">="), tok("!="), tok("=="), tok(">"), tok("<")), binop)
    }},
    {names: {"and"}, add: func(builder){
      return builder:group():left(tok("and"), binop)
    }},
    {names: {"or"}, add: func(builder){
      return builder:group():left(tok("or"), binop)
    }},
  }

  g.expression_parser = peg.settable(null)

  func g.expr(){
    return g.expression_parser
  }

  func g.rebuild(){
    local builder = peg.expression_builder(str.skip_space)
    for(let local level in values(g.primitive_levels)){
      builder:primitive(level.parser)
    }
    for(let local level in values(g.group_levels)){
      level.add(builder)
    }
    g.expression_parser:set(peg.resolve(builder:build()))
  }


  // ------------------------------------------------------------ statement registry

  local initial_statement = peg.ref(g.expression_or_statement):where(func(v){
    return v == null or ast.is_statement(v)
  })
  g.statement_parser = peg.settable(initial_statement)
  g.statements = {}
  g.statement_order = {}

  func g.statement(){
    return g.statement_parser
  }

  func g.add_statement(name, parser){
    g.extended = true
    peg.resolve(parser)
    if(g.statements[name] == null){
      append(g.statement_order, name)
    }
    g.statements[name] = parser
    local alternatives = {}
    for(let local n in values(g.statement_order)){
      append(alternatives, g.statements[n])
    }
    append(alternatives, initial_statement)
    g.statement_parser:set(peg.choice_list(alternatives))
  }

  // ------------------------------------------------------------ expression registry

  local func remove_level(levels, names){
    local kept = {}
    for(let local level in values(levels)){
      local all_contained = true
      for(let local n in values(level.names)){
        local found = false
        for(let local m in values(names)){
          if(m == n){
            found = true
          }
        }
        if(not found){
          all_contained = false
        }
      }
      if(not all_contained){
        append(kept, level)
      }
    }
    return kept
  }

  local func index_of_level(levels, name){
    local i = 0
    for(let local level in values(levels)){
      for(let local n in values(level.names)){
        if(n == name){
          return i
        }
      }
      i = i + 1
    }
    return -1
  }

  local func insert_at(levels, index, level){
    local out = {}
    local n = len(levels)
    for(local i = 0; i < n; i = i + 1){
      if(i == index){
        append(out, level)
      }
      append(out, levels[i])
    }
    if(index >= n){
      append(out, level)
    }
    return out
  }

  func g.add_expression_group_after(name, level){
    g.extended = true
    g.group_levels = remove_level(g.group_levels, level.names)
    local index = index_of_level(g.group_levels, name)
    if(index < 0){
      error("Expression group ", name, " not found")
    }
    g.group_levels = insert_at(g.group_levels, index + 1, level)
    g.rebuild()
  }

  func g.add_expression_group_before(name, level){
    g.extended = true
    g.group_levels = remove_level(g.group_levels, level.names)
    local index = index_of_level(g.group_levels, name)
    if(index < 0){
      error("Expression group ", name, " not found")
    }
    g.group_levels = insert_at(g.group_levels, index, level)
    g.rebuild()
  }

  func g.add_expression_group_at(index, level){
    g.extended = true
    g.group_levels = remove_level(g.group_levels, level.names)
    g.group_levels = insert_at(g.group_levels, index, level)
    g.rebuild()
  }

  func g.add_expression_group(level){
    g.extended = true
    g.group_levels = remove_level(g.group_levels, level.names)
    append(g.group_levels, level)
    g.rebuild()
  }

  func g.add_primitive_expression(level){
    g.extended = true
    peg.resolve(level.parser)
    g.primitive_levels = remove_level(g.primitive_levels, level.names)
    append(g.primitive_levels, level)
    g.rebuild()
  }

  func g.add_primitive_expression_after(name, level){
    g.extended = true
    peg.resolve(level.parser)
    local index = index_of_level(g.primitive_levels, name)
    if(index < 0){
      error("Primitive expression ", name, " not found")
    }
    g.primitive_levels = insert_at(g.primitive_levels, index + 1, level)
    g.rebuild()
  }

  func g.add_primitive_expression_before(name, level){
    g.extended = true
    peg.resolve(level.parser)
    local index = index_of_level(g.primitive_levels, name)
    if(index < 0){
      error("Primitive expression ", name, " not found")
    }
    g.primitive_levels = insert_at(g.primitive_levels, index, level)
    g.rebuild()
  }

  func g.expression_group_names(){
    local out = {}
    for(let local level in values(g.group_levels)){
      append(out, level.names)
    }
    return out
  }

  func g.primitive_expression_names(){
    local out = {}
    for(let local level in values(g.primitive_levels)){
      append(out, level.names)
    }
    return out
  }

  // ------------------------------------------------------------ entry points

  func g.start(){
    // trailing trim so that files containing only whitespace or comments are
    // valid (leading whitespace is consumed by the first token; the chunk
    // token keeps starting at position 0)
    local p = peg.ref(g.chunk):trim(peg.epsilon(), space):end()
    if(opts.optimize != null){
      p = p:map(opts.optimize)
    }
    return p
  }

  g.start_parser = peg.ref(g.start)

  local func fail_message(result, origin){
    return concat("Failed to parse source: ", result.message, ":", origin, ":", result.line, ":", result.column,
      " (farthest: ", result.far_message, " at ", result.far_line, ":", result.far_column, ")")
  }

  // parse_source(source, origin) -> Block node (raises on failure)
  func g.parse_source(source, origin){
    local result = peg.run(g.start_parser, source)
    if(not result.ok){
      error(fail_message(result, origin))
    }
    return result.value
  }

  // parse_repl(source) -> node: a chunk, or an expression wrapped in a return
  func g.parse_repl(source){
    local result = peg.run(g.start_parser, source)
    if(result.ok){
      return result.value
    }
    local exp = peg.run(g.expr():end(), source)
    if(exp.ok){
      return ast.node("Return", {value: exp.value}, exp.value.token)
    }
    error(fail_message(result, "repl"))
  }

  // build the expression parser once everything is defined (resolution is eager)
  g.rebuild()

  return g
}

return grammar
