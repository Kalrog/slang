// slang/grammar: the slang grammar, built with slang/peg on top of a rule
// registry that lets programs extend and modify the parser at compile time.
//
// A grammar is a registry of named rules plus the registries of statements,
// primitive expressions, operator groups and extension statements. Rules are
// referenced by name (g:rule(name)) and resolved late: the first parse after
// a change seals the grammar (builds the expression walker, the dispatch
// tables and the rule targets) once. Grammars derive from each other; the
// rule references are shared by a whole lineage and always point at the
// rules of the grammar that was activated last.
local peg = require("slang/peg")
local ast = require("slang/ast")
local str = require("slang/string")

local grammar = {}
local methods = {}
local grammar_meta = {__index: methods, __type: "grammar"}

local func list(...items){
  return items
}

local func elements(sep_list){
  return sep_list.elements
}

local func join_chars(chars){
  return str.join(chars, "")
}

local func copy_table(t){
  local out = {}
  for(let local e in entries(t)){
    out[e[0]] = e[1]
  }
  return out
}

local func copy_list(t){
  local out = {}
  for(let local v in values(t)){
    append(out, v)
  }
  return out
}

// ------------------------------------------------------------ lineage
//
// The state shared by a grammar and everything derived from it: the rule
// references, the parse-time state and the grammar that is active.
//   opts.run_block(block_node) -> value   executes an unquote at parse time
//   opts.run_extension(node, origin)      runs an extension statement
//   opts.optimize(block_node) -> node     applied to a parsed chunk
//   opts.warn(message)                    reports grammar warnings (development)

local func new_lineage(opts){
  return {
    opts: opts,
    refs: {},
    active: null,
    // the extension (or "core", "runtime") that is changing the grammar
    owner: "core",
    // Grammar changes are allowed at run time (no parse in progress) and from
    // extension statements, which the top-level loop runs between two
    // top-level statements. They are never allowed while a statement is being
    // parsed, at any nesting level (a nested parse started by an unquote or
    // a parser callback runs while an outer statement is being parsed).
    origin: null,
    parse_depth: 0,
    statement_depth: 0,
    extension_depth: 0,
    in_quote: false,
    // set once code ran at compile time (unquote or extension statement); the
    // bytecode of a file is only cached when that did not happen
    compile_time_effects: false,
  }
}

// A rule reference: parses whatever the active grammar defines under the
// name. Targets are installed by activate() and cleared by every change, so
// a reference with no target activates the current grammar (sealing it when
// it changed) before parsing.
local func resolve_rule(ref){
  local lin = ref.lineage
  lin.active:activate()
  local target = ref.target
  if(target == null){
    error("grammar rule ", ref.rule_name, " is not defined")
  }
  return target
}

local func rule_ref(lin, name){
  local p = lin.refs[name]
  if(p != null){
    return p
  }
  p = peg.custom(func(self, ctx, pos){
    local target = self.target
    if(target == null){
      target = resolve_rule(self)
    }
    return target:parse_on(ctx, pos)
  })
  p.fast = func(self, ctx, pos){
    local target = self.target
    if(target == null){
      target = resolve_rule(self)
    }
    return target.fast(target, ctx, pos)
  }
  p.kind = "rule"
  p.rule_name = name
  p.lineage = lin
  // for the first-set analysis while sealing (see peg.info_of)
  p.lookup = func(self){
    local active = lin.active
    if(active != null and active.sealed != null){
      return active.sealed[self.rule_name]
    }
    return null
  }
  lin.refs[name] = p
  return p
}

local func invalidate(lin){
  for(let local ref in values(lin.refs)){
    ref.target = null
  }
}

// ------------------------------------------------------------ grammar objects

local func new_grammar(lin, parent){
  local g = {state: lin, parent: parent, dirty: true, sealed: null}
  g.meta = grammar_meta
  if(parent == null){
    g.rule_table = {}
    g.rule_order = {}
    g.keywords = {}
    g.statements = {}
    g.statement_order = {}
    g.extension_statements = {}
    g.extension_statement_order = {}
    g.primitive_levels = {}
    g.group_levels = {}
    g.extended = false
  } else {
    g.rule_table = {}
    for(let local name in values(parent.rule_order)){
      local e = parent.rule_table[name]
      g.rule_table[name] = {name: e.name, parser: e.parser, build: e.build, wrappers: copy_list(e.wrappers),
                            owner: e.owner, protected: e.protected, probe: e.probe, history: copy_list(e.history)}
    }
    g.rule_order = copy_list(parent.rule_order)
    g.keywords = copy_table(parent.keywords)
    g.statements = copy_table(parent.statements)
    g.statement_order = copy_list(parent.statement_order)
    g.extension_statements = copy_table(parent.extension_statements)
    g.extension_statement_order = copy_list(parent.extension_statement_order)
    g.primitive_levels = copy_list(parent.primitive_levels)
    g.group_levels = copy_list(parent.group_levels)
    g.extended = parent.extended
    // shared helpers of the lineage
    g.token = parent.token
    g.initial_statement = parent.initial_statement
    g.builtin_extension = parent.builtin_extension
    g.identifier = parent.identifier
    g.expr = parent.expr
    g.statement = parent.statement
    g.chunk = parent.chunk
    g.block = parent.block
    g.slang_pattern = parent.slang_pattern
    g.table_literal = parent.table_literal
    g.final_statement = parent.final_statement
  }
  return g
}

func methods.changes_allowed(g){
  local lin = g.state
  return lin.parse_depth == 0 or (lin.extension_depth > 0 and lin.statement_depth == 0)
}

local func check_changes(g, what){
  if(not g:changes_allowed()){
    error("the grammar can only be changed by an extension statement (extension \"file\" or extension { ... } at the top level); ", what, " was called from code running while a statement is being parsed")
  }
}

// every change: the grammar needs sealing again, references resolve anew
local func touch(g){
  g.dirty = true
  if(g.state.owner != "core"){
    g.extended = true
  }
  invalidate(g.state)
}

local func warn(g, ...parts){
  local w = g.state.opts.warn
  if(w != null){
    local text = ""
    for(let local part in values(parts)){
      text = concat(text, part)
    }
    w(text)
  }
}

// ------------------------------------------------------------ rule registry

// rule(name) -> a parser referring to the rule, resolved at parse time
func methods.rule(g, name){
  return rule_ref(g.state, name)
}

// define(name, parser, {protected, probe}): registers a rule. A rule may also
// be built at seal time: define(name, null, {build: func(g) -> parser}).
func methods.define(g, name, parser, options){
  check_changes(g, "define")
  options = options or {}
  if(g.rule_table[name] == null){
    append(g.rule_order, name)
  }
  g.rule_table[name] = {
    name: name, parser: parser, build: options.build, wrappers: {},
    owner: g.state.owner, protected: options.protected == true, probe: options.probe, history: {},
  }
  touch(g)
}

// the shape choice(old, seq(old, ...)) never reaches its second alternative
local func check_shape(g, name, old, new){
  if(new.kind != "choice" or new.children[0] != old){
    return null
  }
  for(let local c in values(new.children)){
    if(c != old and c.kind == "seq" and c.children[0] == old){
      warn(g, "rule ", name, ": choice(old, seq(old, ...)) never reaches its second alternative; use seq(old, tail:optional())")
      return null
    }
  }
}

local func check_probe(g, entry){
  if(entry.probe == null){
    return null
  }
  g:activate()
  local r = peg.run(peg.end(rule_ref(g.state, entry.name)), entry.probe)
  if(not r.ok){
    warn(g, "rule ", entry.name, " no longer parses its probe after ", g.state.owner, ": ", r.message, " at ", r.line, ":", r.column)
  }
}

// modify(name, func(old) -> new): replaces the rule by f(old); replacing is
// just not using old. Rules built at seal time are wrapped after building.
func methods.modify(g, name, f){
  check_changes(g, "modify")
  local entry = g.rule_table[name]
  if(entry == null){
    error("grammar rule ", name, " is not defined")
  }
  if(entry.protected){
    error("grammar rule ", name, " is protected and cannot be modified")
  }
  local owner = g.state.owner
  if(len(entry.history) > 0 and g.state.opts.warn != null){
    warn(g, "rule ", name, " was already modified by ", str.join(entry.history, ", "), "; ", owner, " modifies it again")
  }
  append(entry.history, owner)
  if(entry.build != null){
    append(entry.wrappers, f)
    touch(g)
    return null
  }
  local old = entry.parser
  local new = f(old)
  if(not peg.is_parser(new)){
    error("modify(", name, ") must return a parser")
  }
  entry.parser = new
  touch(g)
  if(g.state.opts.warn != null){
    check_shape(g, name, old, new)
    check_probe(g, entry)
  }
}

// rules() -> {{name, owner, protected, history}}: every rule with its provenance
func methods.rules(g){
  local out = {}
  for(let local name in values(g.rule_order)){
    local e = g.rule_table[name]
    append(out, {name: name, owner: e.owner, protected: e.protected, history: copy_list(e.history)})
  }
  return out
}

// derive() -> a grammar that starts as a copy of this one; changes to either
// do not affect the other
func methods.derive(g){
  return new_grammar(g.state, g)
}

func methods.keyword(g, s){
  if(g.keywords[s] != true){
    check_changes(g, "keyword")
    g.keywords[s] = true
    touch(g)
  }
  return peg.ref(g.token, s)
}

// ------------------------------------------------------------ sealing

local func install(g){
  local sealed = g.sealed
  for(let local e in entries(g.state.refs)){
    e[1].target = sealed[e[0]]
  }
}

local func build_rule(g, entry){
  local p = entry.build(g)
  for(let local w in values(entry.wrappers)){
    p = w(p)
    if(not peg.is_parser(p)){
      error("modify(", entry.name, ") must return a parser")
    }
  }
  return p
}

// seal(): builds the rule targets, the expression walker and the dispatch
// tables of this grammar. Rules built at seal time (expr, statement,
// extension_statement) are built in that order, each installed before the
// next is analysed, so first sets never come from a stale definition.
func methods.seal(g){
  local sealed = {}
  local built = {}
  for(let local name in values(g.rule_order)){
    local e = g.rule_table[name]
    if(e.build == null){
      sealed[name] = e.parser
    } else {
      append(built, e)
    }
  }
  g.sealed = sealed
  g.state.active = g
  install(g)
  for(let local e in values(built)){
    sealed[e.name] = build_rule(g, e)
    install(g)
  }
  g.dirty = false
}

// activate(): makes this grammar the one the rule references parse with,
// sealing it first when it changed
func methods.activate(g){
  if(g.dirty){
    g:seal()
  } else if(g.state.active != g){
    g.state.active = g
    install(g)
  }
}

// ------------------------------------------------------------ registries

func methods.add_statement(g, name, parser){
  check_changes(g, "add_statement")
  peg.resolve(parser)
  if(g.statements[name] == null){
    append(g.statement_order, name)
  }
  g.statements[name] = parser
  touch(g)
}

// add_extension_statement(name, parser, apply): a statement that is only
// recognised at the top level; after it parsed, apply(result) runs between
// statements with grammar changes allowed and returns the statement to emit
// (or null)
func methods.add_extension_statement(g, name, parser, apply){
  check_changes(g, "add_extension_statement")
  peg.resolve(parser)
  if(g.extension_statements[name] == null){
    append(g.extension_statement_order, name)
  }
  g.extension_statements[name] = parser:map(func(result){
    return {apply: apply, result: result}
  })
  touch(g)
}

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

func methods.add_expression_group_after(g, name, level){
  check_changes(g, "add_expression_group_after")
  g.group_levels = remove_level(g.group_levels, level.names)
  local index = index_of_level(g.group_levels, name)
  if(index < 0){
    error("Expression group ", name, " not found")
  }
  g.group_levels = insert_at(g.group_levels, index + 1, level)
  touch(g)
}

func methods.add_expression_group_before(g, name, level){
  check_changes(g, "add_expression_group_before")
  g.group_levels = remove_level(g.group_levels, level.names)
  local index = index_of_level(g.group_levels, name)
  if(index < 0){
    error("Expression group ", name, " not found")
  }
  g.group_levels = insert_at(g.group_levels, index, level)
  touch(g)
}

func methods.add_expression_group_at(g, index, level){
  check_changes(g, "add_expression_group_at")
  g.group_levels = remove_level(g.group_levels, level.names)
  g.group_levels = insert_at(g.group_levels, index, level)
  touch(g)
}

func methods.add_expression_group(g, level){
  check_changes(g, "add_expression_group")
  g.group_levels = remove_level(g.group_levels, level.names)
  append(g.group_levels, level)
  touch(g)
}

func methods.add_primitive_expression(g, level){
  check_changes(g, "add_primitive_expression")
  peg.resolve(level.parser)
  g.primitive_levels = remove_level(g.primitive_levels, level.names)
  append(g.primitive_levels, level)
  touch(g)
}

func methods.add_primitive_expression_after(g, name, level){
  check_changes(g, "add_primitive_expression_after")
  peg.resolve(level.parser)
  local index = index_of_level(g.primitive_levels, name)
  if(index < 0){
    error("Primitive expression ", name, " not found")
  }
  g.primitive_levels = insert_at(g.primitive_levels, index + 1, level)
  touch(g)
}

func methods.add_primitive_expression_before(g, name, level){
  check_changes(g, "add_primitive_expression_before")
  peg.resolve(level.parser)
  local index = index_of_level(g.primitive_levels, name)
  if(index < 0){
    error("Primitive expression ", name, " not found")
  }
  g.primitive_levels = insert_at(g.primitive_levels, index, level)
  touch(g)
}

func methods.expression_group_names(g){
  local out = {}
  for(let local level in values(g.group_levels)){
    append(out, level.names)
  }
  return out
}

func methods.primitive_expression_names(g){
  local out = {}
  for(let local level in values(g.primitive_levels)){
    append(out, level.names)
  }
  return out
}

// ------------------------------------------------------------ core
//
// slang's own syntax, registered through the same API extensions use.

local func install_core(g){
  local lin = g.state
  local opts = lin.opts
  local func rule(name){
    return rule_ref(lin, name)
  }
  local func define(name, parser, options){
    g:define(name, parser, options)
  }

  g.keywords = {
    ["if"]: true, ["else"]: true, ["for"]: true, ["func"]: true, ["return"]: true,
    ["local"]: true, ["true"]: true, ["false"]: true, ["null"]: true, ["let"]: true,
    ["break"]: true, ["extension"]: true,
  }

  // ------------------------------------------------------------ lexical

  // trivia: whitespace and comments, skipped by one native call
  local trivia = peg.custom(func(self, ctx, pos){
    local q = str.skip_space(ctx.buffer, pos)
    if(q == pos){
      return peg.fail(ctx, pos, "whitespace expected")
    }
    ctx.value = null
    return q
  })
  trivia.single = true
  define("trivia", trivia)

  local space = rule("trivia")
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

  // token(source, message): a token parser trimmed by trivia. Word-like
  // tokens (keywords, `not`, `and`, ...) must not be followed by an
  // identifier character, so that `notify` or `localVar` stay identifiers.
  g.token = func(source, message){
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

  // ------------------------------------------------------------ literals

  define("number", peg.digit():plus())

  local sign = peg.choice(peg.char("-"), peg.char("+")):optional()

  define("int_literal", g.token(peg.seq(sign, rule("number")), "int"):map(func(t){
    return ast.node("Int", {value: to_int(t.value)}, t)
  }))

  define("double_literal", g.token(peg.seq(sign, rule("number"), peg.char("."), rule("number")), "double"):map(func(t){
    return ast.node("Double", {value: str.to_number(t.value)}, t)
  }))

  define("valid_escape", peg.seq(
    peg.char("\\"),
    peg.choice(peg.char("\""), peg.char("\\"), peg.char("n"), peg.char("r"),
               peg.char("t"), peg.char("b"), peg.char("f"), peg.char("v"))
  ):flatten())

  define("slang_char", peg.choice(rule("valid_escape"), peg.char("\n"):neg()))

  define("double_quoted_string", peg.seq(
    peg.char("\""),
    rule("slang_char"):star_lazy(peg.char("\"")):map(join_chars),
    peg.char("\"")
  ):pick(1):token())

  define("multiline_string", peg.seq(
    peg.string("\"\"\""),
    peg.choice(rule("slang_char"), peg.char("\n")):star_lazy(peg.string("\"\"\"")):map(join_chars),
    peg.string("\"\"\"")
  ):pick(1):token())

  define("string_literal", peg.choice(rule("multiline_string"), rule("double_quoted_string")):map(func(t){
    return ast.node("String", {value: ast.resolve_escapes(t.value)}, t)
  }))

  define("true_literal", tok("true"):map(func(t){ return ast.node("True", {}, t) }))
  define("false_literal", tok("false"):map(func(t){ return ast.node("False", {}, t) }))
  define("null_literal", tok("null"):map(func(t){ return ast.node("Null", {}, t) }))

  define("identifier", g.token(
    peg.seq(peg.string("..."):optional(), peg.pattern("a-zA-Z_"), peg.pattern("a-zA-Z0-9_"):star())
      :flatten("Expected: identifier")
      :where(func(name){ return lin.active.keywords[name] != true }),
    "identifier"
  ):map(func(t){
    return ast.node("Identifier", {value: t.value}, t)
  }))

  // name: an identifier where keywords are allowed: after `.` and `:` and as
  // table keys, so that keywords added by extensions never make a field
  // unreachable
  define("name", g.token(
    peg.seq(peg.pattern("a-zA-Z_"), peg.pattern("a-zA-Z0-9_"):star()):flatten("Expected: name"),
    "name"
  ):map(func(t){
    return ast.node("Identifier", {value: t.value}, t)
  }))

  // ------------------------------------------------------------ tables

  // field: name: value | [key]: value | value
  define("field", peg.seq(
    peg.choice(
      peg.seq(rule("name"), tok(":")):pick(0),
      peg.seq(tok("["), rule("expr"), tok("]"), tok(":")):pick(1)
    ):optional(),
    rule("expr")
  ):token():map(func(t){
    local key = t.value[0]
    if(key != null and key.type == "Identifier"){
      key = ast.node("String", {value: key.value}, key.token)
    }
    return ast.node("Field", {key: key, value: t.value[1]}, t)
  }))

  define("table_literal", peg.seq(
    tok("{"),
    rule("field"):star_separated(tok(",")),
    tok(","):optional(),
    tok("}")
  ):pick(1):map(elements):token():map(func(t){
    return ast.node("Table", {fields: t.value}, t)
  }))

  // ------------------------------------------------------------ calls

  define("identifier_and_index", peg.seq(
    rule("identifier"),
    peg.choice(
      peg.seq(tok("["), rule("expr"), tok("]")):pick(1):map(func(e){ return {e, "bracket"} }),
      peg.seq(tok("."), rule("name"):map(func(id){
        return ast.node("String", {value: id.value}, id.token)
      })):pick(1):map(func(e){ return {e, "dot"} })
    ):star()
  ):map(func(v){
    local node = v[0]
    for(let local right in values(v[1])){
      node = ast.node("Index", {receiver: node, index: right[0], dotStyle: right[1] == "dot"}, right[0].token)
    }
    return node
  }))

  define("name_and_args", peg.seq(
    peg.seq(tok(":"), rule("name")):pick(1):optional(),
    rule("args")
  ):token():map(func(t){
    return list(t.value[0], t.value[1], t)
  }))

  define("args", peg.choice(
    peg.seq(
      peg.seq(tok("("), rule("expr"):star_separated(tok(",")):map(elements), tok(")")):pick(1),
      rule("block"):optional()
    ),
    rule("block")
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
  }))

  // ------------------------------------------------------------ statements

  define("expr_statement", peg.seq(rule("expr"), peg.seq(tok("="), rule("expr")):optional()):map(func(v){
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
  }))

  define("local_declaration", peg.seq(tok("local"), rule("expr"), peg.seq(tok("="), rule("expr")):optional()):map(func(v){
    local right = null
    if(v[2] != null){
      right = v[2][1]
    }
    return ast.node("Declaration", {is_local: true, left: v[1], right: right}, v[0])
  }), {probe: "local x = 1"})

  define("if_statement", peg.seq(
    tok("if"), tok("("), rule("expr"), tok(")"), rule("statement"),
    peg.seq(tok("else"), rule("statement")):optional()
  ):map(func(v){
    local else_branch = null
    if(v[5] != null){
      else_branch = v[5][1]
    }
    return ast.node("If", {condition: v[2], thenBranch: v[4], elseBranch: else_branch}, v[0])
  }), {probe: "if (x) { f() } else { g() }"})

  define("for_loop", peg.seq(
    // for(init; condition; update), for(condition; update), for(condition);
    // init and update may also be left empty: for(; condition; update)
    tok("for"), tok("("),
    rule("expression_or_statement"):optional(),
    peg.seq(tok(";"), rule("expression_or_statement")):pick(1):optional(),
    peg.seq(tok(";"), rule("statement"):optional()):pick(1):optional(),
    peg.char(")"),
    rule("statement")
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
  }), {probe: "for(local i = 0; i < 3; i = i + 1){ f(i) }"})

  define("for_in_loop", peg.seq(
    tok("for"), tok("("), tok("let"), rule("slang_pattern"), tok("in"), rule("expr"), tok(")"), rule("statement")
  ):map(func(v){
    return ast.node("ForIn", {pattern: v[3], itterator: v[5], body: v[7]}, v[0])
  }), {probe: "for(let local x in values(t)){ f(x) }"})

  define("function_definition_statement", peg.seq(tok("local"):optional(), tok("func"), rule("identifier_and_index"), rule("function_definition")):map(func(v){
    return ast.node("Declaration", {is_local: v[0] != null, left: v[2], right: v[3]}, v[1])
  }), {probe: "func f(a, b){ return a }"})

  define("expression_or_statement", peg.choice(
    rule("local_declaration"),
    rule("if_statement"),
    rule("for_loop"),
    rule("for_in_loop"),
    rule("block"),
    rule("function_definition_statement"),
    rule("expr_statement")
  ))

  define("chunk", peg.seq(
    peg.seq(rule("statement"), tok(";"):optional()):pick(0):star(),
    peg.seq(rule("final_statement"), tok(";"):optional()):pick(0):optional()
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
  }))

  define("block", peg.seq(tok("{"), rule("chunk"), tok("}")):pick(1), {probe: "{ x = 1; f(x) }"})

  define("break_statement", tok("break"):map(func(t){ return ast.node("Break", {}, t) }))

  // the value is optional: a bare `return` returns null
  define("return_statement", peg.seq(tok("return"), rule("expr"):optional()):map(func(v){
    return ast.node("Return", {value: v[1]}, v[0])
  }))

  define("final_statement", peg.choice(rule("return_statement"), rule("break_statement")))

  // ------------------------------------------------------------ functions

  define("params", rule("identifier"):star_separated(tok(",")):map(elements))

  define("function_definition", peg.seq(
    tok("("), rule("params"), tok(")"),
    peg.choice(rule("block"), peg.seq(tok("=>"), rule("expr")))
  ):token():map(func(t){
    local v = t.value
    local body = v[3]
    if(type(body) == "table"){
      local e = body[1]
      body = ast.node("Block", {statements: {ast.node("Return", {value: e}, e.token)}}, t)
    }
    return ast.node("Function", {params: v[1], body: body}, t)
  }))

  define("function_expression", peg.seq(tok("func"), rule("function_definition")):pick(1))

  // ------------------------------------------------------------ patterns

  define("slang_pattern", peg.choice(rule("table_pattern"), rule("const_pattern"), rule("var_pattern")))

  define("table_pattern", peg.seq(
    peg.seq(tok("'"), rule("identifier")):pick(1):optional(),
    tok("{"),
    rule("field_pattern"):star_separated(tok(",")),
    tok("}")
  ):map(func(v){
    local type_name = "table"
    if(v[0] != null){
      type_name = v[0].value
    }
    return ast.node("TablePattern", {type_check: type_name, fields: v[2].elements}, v[1])
  }))

  define("field_pattern", peg.seq(
    peg.choice(
      peg.seq(rule("name"), tok(":")):pick(0),
      peg.seq(tok("["), rule("expr"), tok("]"), tok(":")):pick(1)
    ):map(func(exp){
      if(exp.type == "Identifier"){
        return ast.node("String", {value: exp.value}, exp.token)
      }
      return exp
    }):optional(),
    rule("slang_pattern")
  ):map(func(v){
    local key = v[0]
    local value = v[1]
    local token = value.token
    if(key != null){
      token = key.token
    }
    return ast.node("FieldPattern", {key: key, value: value}, token)
  }))

  define("const_pattern", peg.choice(
    rule("int_literal"), rule("double_literal"), rule("string_literal"),
    rule("true_literal"), rule("false_literal"), rule("null_literal")
  ):map(func(exp){
    return ast.node("ConstPattern", {value: exp}, exp.token)
  }))

  define("var_pattern", peg.seq(tok("local"):optional(), rule("identifier"), tok("?"):optional()):map(func(v){
    return ast.node("VarPattern", {isLocal: v[0] != null, canBeNull: v[2] != null, name: v[1]}, v[1].token)
  }))

  define("pattern_assignment_exp", peg.seq(tok("let"), rule("slang_pattern"), tok("="), rule("expr")):map(func(v){
    return ast.node("Let", {pattern: v[1], right: v[3]}, v[0])
  }))

  // ------------------------------------------------------------ quoting
  //
  // Quote and unquote are how extensions produce code; they are protected.

  define("quote_body", peg.choice(
    peg.seq(tok("id"), tok(":"), rule("identifier")),
    peg.seq(tok("block"), tok(":"), rule("chunk")),
    peg.seq(tok("stat"), tok(":"), peg.choice(rule("statement"), rule("final_statement"))),
    peg.seq(peg.seq(tok("expr"), tok(":")):optional(), rule("expr"))
  ), {protected: true})

  local func split_quote_body(body){
    if(len(body) == 3){
      return list(body[0].value, body[2])
    }
    return list("expr", body[1])
  }

  local quote_body = peg.custom(func(self, ctx, pos){
    local prev = lin.in_quote
    lin.in_quote = true
    local q = rule("quote_body"):parse_on(ctx, pos)
    lin.in_quote = prev
    return q
  })
  define("quote", peg.seq(tok("+"), tok("{"), quote_body, tok("}")):pick(2):token():map(func(t){
    local parts = split_quote_body(t.value)
    return ast.node("Quote", {ast_type: parts[0], ast: parts[1]}, t)
  }), {protected: true})

  // An executed unquote is memoised per parse context and position: when the
  // parser backtracks and reaches the same unquote again, the AST produced by
  // the first execution is spliced again instead of running the code twice.
  local unquote_body_ref = rule("quote_body"):token()
  local unquote_body = peg.custom(func(self, ctx, pos){
    local memo = ctx.unquote_memo
    if(memo != null){
      local hit = memo[pos]
      if(hit != null){
        ctx.value = hit.node
        return hit.stop
      }
    }
    local q = unquote_body_ref:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    local t = ctx.value
    local parts = split_quote_body(t.value)
    local type_name = parts[0]
    local node = parts[1]
    if(lin.in_quote){
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
    lin.compile_time_effects = true
    local result = opts.run_block(node)
    if(result == null){
      ctx.value = ast.node("Null", {}, t)
    } else {
      ctx.value = ast.decode(result)
    }
    if(memo == null){
      memo = {}
      ctx.unquote_memo = memo
    }
    memo[pos] = {node: ctx.value, stop: q}
    return q
  })
  define("unquote", peg.seq(tok("-"), tok("{"), unquote_body, tok("}")):pick(2), {protected: true})

  // ------------------------------------------------------------ expressions

  local func binop(left, op, right){
    return ast.node("BinOp", {left: left, op: op.value, right: right}, op)
  }

  local func not_brace(parser){
    return peg.seq(parser, peg.char("{"):forbid()):pick(0)
  }

  g.primitive_levels = {
    {names: {"unquote", "-{}"}, parser: rule("unquote")},
    {names: {"quote", "+{}"}, parser: rule("quote")},
    {names: {"identifier", "id"}, parser: rule("identifier")},
    {names: {"doubleLiteral", "double", "float"}, parser: rule("double_literal")},
    {names: {"intLiteral", "integer", "int"}, parser: rule("int_literal")},
    {names: {"stringLiteral", "string", "str"}, parser: rule("string_literal")},
    {names: {"trueLiteral", "true"}, parser: rule("true_literal")},
    {names: {"falseLiteral", "false"}, parser: rule("false_literal")},
    {names: {"nullLiteral", "null"}, parser: rule("null_literal")},
    {names: {"patternAssignmentExp", "let"}, parser: rule("pattern_assignment_exp")},
    {names: {"listLiteral", "list", "tableLiteral", "table"}, parser: rule("table_literal")},
    {names: {"functionExpression", "function"}, parser: rule("function_expression")},
  }

  g.group_levels = {
    {names: {"bracket", "()"}, add: func(builder){
      return builder:group():wrapper(tok("("), tok(")"), func(left, value, right){ return value })
    }},
    {names: {"indexAndCall", ".", "[]", ":()"}, add: func(builder){
      local group = builder:group()
      group:postfix(peg.seq(tok("."), rule("name")), func(left, op){
        local name = op[1]
        return ast.node("Index", {receiver: left, index: ast.node("String", {value: name.value}, name.token), dotStyle: true}, op[0])
      })
      group:postfix(peg.seq(tok("["), builder.loopback, tok("]")), func(left, op){
        return ast.node("Index", {receiver: left, index: op[1], dotStyle: false}, op[0])
      })
      group:postfix(rule("name_and_args"), func(left, op){
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

  // the expression walker is built at seal time from the registries
  define("expr", null, {build: func(g){
    local builder = peg.expression_builder(str.skip_space)
    for(let local level in values(g.primitive_levels)){
      builder:primitive(level.parser)
    }
    for(let local level in values(g.group_levels)){
      level.add(builder)
    }
    return peg.resolve(builder:build())
  }})

  // ------------------------------------------------------------ statement registry

  g.initial_statement = rule("expression_or_statement"):where(func(v){
    return v == null or ast.is_statement(v)
  })

  define("statement", null, {build: func(g){
    local alternatives = {}
    for(let local n in values(g.statement_order)){
      append(alternatives, g.statements[n])
    }
    append(alternatives, g.initial_statement)
    return peg.dispatch(alternatives, str.skip_space, "statement expected")
  }})

  // ------------------------------------------------------------ top level
  //
  // A compilation unit is parsed one top-level statement at a time by this
  // loop, which only ever moves forward. Between two statements the grammar
  // may change: an extension statement
  //     extension "file"       runs the file at compile time
  //     extension { code }     runs the block at compile time
  // executes with grammar changes allowed and takes effect from the next
  // statement on. Extension statements exist only here, not in nested blocks,
  // so no parse of a statement can ever see the grammar change.

  // the built-in extension statement yields {builtin: node}; extension
  // statements registered by extensions yield {apply: f, result: value}
  g.builtin_extension = peg.seq(tok("extension"), peg.choice(rule("string_literal"), rule("block"))):pick(1):map(func(node){
    return {builtin: node}
  })

  define("extension_statement", null, {protected: true, build: func(g){
    local alternatives = {g.builtin_extension}
    for(let local n in values(g.extension_statement_order)){
      append(alternatives, g.extension_statements[n])
    }
    return peg.dispatch(alternatives, str.skip_space)
  }})

  // accessors used by the slang/parser API
  g.identifier = func(){ return rule("identifier") }
  g.expr = func(){ return rule("expr") }
  g.statement = func(){ return rule("statement") }
  g.chunk = func(){ return rule("chunk") }
  g.block = func(){ return rule("block") }
  g.slang_pattern = func(){ return rule("slang_pattern") }
  g.table_literal = func(){ return rule("table_literal") }
  g.final_statement = func(){ return rule("final_statement") }
}

// ------------------------------------------------------------ parsing

local func fail_message(ctx, origin, message, pos){
  local lc = peg.line_col(ctx, pos)
  local far_pos = ctx.far_pos
  if(far_pos < 0){
    far_pos = pos
  }
  local far = peg.line_col(ctx, far_pos)
  return concat("Failed to parse source: ", message, ":", origin, ":", lc[0], ":", lc[1],
    " (farthest: ", ctx.far_msg or message, " at ", far[0], ":", far[1], ")")
}

// runs compile-time code with grammar changes allowed; only valid between
// top-level statements
local func with_changes_allowed(g, owner, f, a, b){
  local lin = g.state
  if(lin.statement_depth > 0){
    error("extension statements cannot run from code that executes while a statement is being parsed")
  }
  lin.compile_time_effects = true
  lin.extension_depth = lin.extension_depth + 1
  local outer_owner = lin.owner
  lin.owner = owner
  local r = pcall(f, a, b)
  lin.owner = outer_owner
  lin.extension_depth = lin.extension_depth - 1
  if(let {"err", local e} = r){
    raise(e)
  }
  return r[1]
}

// runs a parsed extension statement; returns a statement node to emit or null
func methods.run_extension(g, parsed, origin){
  local opts = g.state.opts
  if(parsed.builtin != null){
    if(opts.run_extension == null){
      error("this grammar cannot run extension statements")
    }
    local node = parsed.builtin
    local owner = concat(origin, ":", node.token.line)
    if(node.type == "String"){
      owner = node.value
    }
    with_changes_allowed(g, owner, opts.run_extension, node, origin)
    return null
  }
  local token = parsed.result
  local owner = origin
  if(type(token) == "table" and token.line != null){
    owner = concat(origin, ":", token.line)
  }
  local result = with_changes_allowed(g, owner, parsed.apply, parsed.result)
  if(result == null){
    return null
  }
  local node = ast.decode(result)
  if(not ast.is_statement(node)){
    error("an extension statement must produce a statement, got ", node.type)
  }
  return node
}

local func parse_statement(lin, parser, ctx, pos){
  lin.statement_depth = lin.statement_depth + 1
  local r = pcall(parser.parse_on, parser, ctx, pos)
  lin.statement_depth = lin.statement_depth - 1
  if(let {"err", local e} = r){
    raise(e)
  }
  return r[1]
}

local func parse_top_level(g, source, origin){
  local lin = g.state
  local tok_semicolon = peg.ref(g.token, ";"):optional()
  local parsers = {
    statement: peg.seq(rule_ref(lin, "statement"), tok_semicolon):pick(0),
    final: peg.seq(rule_ref(lin, "final_statement"), tok_semicolon):pick(0),
    extension_statement: peg.seq(rule_ref(lin, "extension_statement"), tok_semicolon):pick(0),
  }
  local ctx = peg.context(source)
  local statements = {}
  local pos = 0
  lin.origin = origin
  for(true){
    g:activate()
    local q = parsers.extension_statement:parse_on(ctx, pos)
    if(q >= 0){
      local node = g:run_extension(ctx.value, origin)
      if(node != null){
        append(statements, node)
      }
      pos = q
    } else {
      q = parse_statement(lin, parsers.statement, ctx, pos)
      if(q >= 0){
        if(ctx.value != null){
          append(statements, ctx.value)
        }
        pos = q
      } else {
        q = parse_statement(lin, parsers.final, ctx, pos)
        if(q >= 0){
          append(statements, ctx.value)
          pos = q
        }
        break
      }
    }
  }
  local stop = str.skip_space(source, pos)
  if(stop != len(source)){
    error(fail_message(ctx, origin, "end of input expected", stop))
  }
  local block = ast.node("Block", {statements: statements}, peg.make_token(ctx, null, 0, pos))
  if(lin.opts.optimize != null){
    block = lin.opts.optimize(block)
  }
  return block
}

// parse_source(source, origin) -> Block node (raises on failure)
func methods.parse_source(g, source, origin){
  local lin = g.state
  local outer_origin = lin.origin
  lin.parse_depth = lin.parse_depth + 1
  local r = pcall(parse_top_level, g, source, origin)
  lin.parse_depth = lin.parse_depth - 1
  lin.origin = outer_origin
  if(let {"err", local e} = r){
    raise(e)
  }
  return r[1]
}

// parse_repl(source) -> node: a chunk, or an expression wrapped in a return
func methods.parse_repl(g, source){
  local r = pcall(g.parse_source, g, source, "repl")
  if(let {"ok", local block} = r){
    return block
  }
  g:activate()
  local exp = peg.run(rule_ref(g.state, "expr"):end(), source)
  if(exp.ok){
    return ast.node("Return", {value: exp.value}, exp.value.token)
  }
  raise(r[1])
}

// new(opts) -> the root grammar of a new lineage, with slang's syntax
func grammar.new(opts){
  local lin = new_lineage(opts or {})
  local g = new_grammar(lin, null)
  lin.active = g
  install_core(g)
  lin.owner = "runtime"
  return g
}

return grammar
