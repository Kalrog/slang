// slang/grammar: the slang grammar, built with slang/peg on top of a rule
// registry that lets programs extend and modify the parser at compile time.
//
// A grammar is a registry of named rules plus the registries of statements,
// extension statements and the expression walker (primaries, levels and
// operators, see peg.walker). Rules are
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
//   opts.warn(message, owner)             reports grammar warnings (development)
//   opts.explain(origin, unit)            called after a unit parsed under its own grammar

local func new_lineage(opts){
  return {
    opts: opts,
    refs: {},
    active: null,
    // the root grammar of the lineage, and the grammar of the unit being
    // parsed (the innermost one; null at run time)
    root: null,
    current: null,
    // the origin of the main file: the only unit allowed `extension global`
    main_origin: null,
    // set while the ambient layer (the project's extensions) is applied: those
    // changes are part of the base grammar and do not make it `extended`
    ambient: false,
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
    // token_fn(source, name, category) -> parser, set by install_core; shared
    // so that peg.ref(lin.token_fn, text) caches one parser per text
    token_fn: null,
    uniq_counter: 0,
    // for highlighting (parse_source with {record: true}): the recording
    // context, the tokens it produced, the last parse failure
    // {message, pos, far_pos, far_message} and the start of the top-level
    // statement being parsed
    record_ctx: null,
    last_tokens: null,
    last_failure: null,
    phrase_pos: 0,
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
    g.expression_walker = null
    g.extended = false
    g.loaded_extensions = {}
    g.dialect = null
    g.cache_key = null
  } else {
    g.rule_table = {}
    for(let local name in values(parent.rule_order)){
      local e = parent.rule_table[name]
      g.rule_table[name] = {name: e.name, parser: e.parser, build: e.build, wrappers: copy_list(e.wrappers), bases: copy_list(e.bases),
                            owner: e.owner, protected: e.protected, probe: e.probe, history: copy_list(e.history)}
    }
    g.rule_order = copy_list(parent.rule_order)
    g.keywords = copy_table(parent.keywords)
    g.statements = copy_table(parent.statements)
    g.statement_order = copy_list(parent.statement_order)
    g.extension_statements = copy_table(parent.extension_statements)
    g.extension_statement_order = copy_list(parent.extension_statement_order)
    g.expression_walker = parent.expression_walker:derive()
    g.extended = parent.extended
    g.loaded_extensions = copy_list(parent.loaded_extensions)
    g.dialect = parent.dialect
    g.cache_key = parent.cache_key
    // shared helpers of the lineage
    g.initial_statement = parent.initial_statement
    g.builtin_extension = parent.builtin_extension
    g.default_trivia = parent.default_trivia
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
  local lin = g.state
  if(lin.parse_depth > 0 and lin.current != null and g != lin.current){
    error(what, " was called on a grammar that is not the grammar of the unit being parsed (an extension loaded for another unit kept it); use the grammar passed to an apply function or require(\"slang/compiler\").grammar() at the time of the change, or extension global")
  }
}

// every change: the grammar needs sealing again, references resolve anew
local func touch(g){
  g.dirty = true
  if(g.state.owner != "core" and not g.state.ambient){
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
    w(text, g.state.owner)
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
    // the parsers this rule was modified from (memoization placement)
    bases: {},
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
  append(entry.bases, old)
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

// root() -> the root grammar of the lineage (slang plus the ambient layer)
func methods.root(g){
  return g.state.root
}

// unit() -> the grammar of the unit being parsed, this one at run time
func methods.unit(g){
  return g.state.current or g
}

// the extensions loaded into this grammar, by name (inherited by derivation)
func methods.has_extension(g, name){
  for(let local n in values(g.loaded_extensions)){
    if(n == name){
      return true
    }
  }
  return false
}

func methods.add_extension(g, name){
  append(g.loaded_extensions, name)
}

func methods.extensions(g){
  return copy_list(g.loaded_extensions)
}

// with_owner(owner, f) -> f(): runs f with grammar changes attributed to owner
func methods.with_owner(g, owner, f){
  local lin = g.state
  local outer = lin.owner
  lin.owner = owner
  local r = pcall(f)
  lin.owner = outer
  if(let {"err", local e} = r){
    raise(e)
  }
  return r[1]
}


// keyword(word) -> token parser; the word is reserved (not an identifier)
func methods.keyword(g, s){
  if(g.keywords[s] != true){
    check_changes(g, "keyword")
    g.keywords[s] = true
    touch(g)
  }
  return peg.ref(g.state.token_fn, s)
}

// token(source, name, category) -> parser: a token trimmed by trivia. source
// is a string (the token's text; word-like tokens may not be followed by an
// identifier character) or a parser (name says what the error message
// expects). category is what a highlighter shows; it defaults to "keyword"
// for words, "punctuation" for other strings and name for parsers.
func methods.token(g, source, name, category){
  if(type(source) == "string"){
    return peg.ref(g.state.token_fn, source, name, category)
  }
  return g.state.token_fn(source, name, category)
}

// tag(parser, category) -> parser: what parser produced, recorded again
// under category for highlighting (see peg.tag)
func methods.tag(g, parser, category){
  return peg.tag(parser, category)
}

// origin() -> the name of the source being parsed (null outside a parse)
func methods.origin(g){
  return g.state.origin
}

// error_at(token, message...): raises a compile error located at token (a
// token as produced by token/keyword, or any table with line and column)
func methods.error_at(g, token, ...message){
  local location = null
  if(type(token) == "table" and token.line != null){
    location = {line: token.line, column: token.column, origin: g.state.origin or "string"}
  }
  local text = ""
  for(let local part in values(message)){
    text = concat(text, part)
  }
  raise({message: text, location: location})
}

// uniq_id() -> an identifier node with a name no program can write
func methods.uniq_id(g){
  g.state.uniq_counter = g.state.uniq_counter + 1
  return ast.node("Identifier", {value: concat("uuid-", g.state.uniq_counter)}, null)
}

local func decode_statement(value){
  local node = ast.decode(value)
  if(not ast.is_statement(node)){
    error("expected a statement, got ", node)
  }
  return node
}

// ------------------------------------------------------------ expression API
//
// expression() -> the expression registry of the grammar: the walker (see
// peg.walker) behind a facade that decodes what extension callbacks return
// ({token, ast} or a node) and names primaries and levels.

local expression_methods = {}
local expression_meta = {__index: expression_methods, __type: "expression_registry"}
local level_facade_methods = {}
local level_facade_meta = {__index: level_facade_methods, __type: "expression_level"}

func methods.expression(g){
  local e = {grammar: g}
  e.meta = expression_meta
  return e
}

local func facade_walker(e){
  local g = e.grammar
  check_changes(g, "expression")
  touch(g)
  return g.expression_walker
}

local func level_facade(e, level){
  local f = {registry: e, level: level}
  f.meta = level_facade_meta
  return f
}

// primary(name, parser, {after, before, at, aliases})
func expression_methods.primary(self, name, parser, placement){
  local w = facade_walker(self)
  peg.resolve(parser)
  w:primary(parser:map(ast.decode), name, placement)
  return self
}

// level(name, {after, before, at, aliases}) -> level
func expression_methods.level(self, name, placement){
  local w = facade_walker(self)
  return level_facade(self, w:level(name, placement))
}

func expression_methods.prefix(self, operator, level, callback){
  local w = facade_walker(self)
  w:prefix(operator, level, func(op, exp){ return ast.decode(callback(op, exp)) })
  return self
}

func expression_methods.postfix(self, operator, level, callback){
  local w = facade_walker(self)
  w:postfix(operator, level, func(exp, op){ return ast.decode(callback(exp, op)) })
  return self
}

func expression_methods.left(self, operator, level, callback){
  local w = facade_walker(self)
  w:left(operator, level, func(left, op, right){ return ast.decode(callback(left, op, right)) })
  return self
}

func expression_methods.right(self, operator, level, callback){
  local w = facade_walker(self)
  w:right(operator, level, func(left, op, right){ return ast.decode(callback(left, op, right)) })
  return self
}

func expression_methods.wrapper(self, left, right, level, callback){
  local w = facade_walker(self)
  w:wrapper(left, right, level, func(l, value, r){ return ast.decode(callback(l, value, r)) })
  return self
}

func expression_methods.levels(self){
  return self.grammar.expression_walker:level_names()
}

func expression_methods.primaries(self){
  return self.grammar.expression_walker:primary_names()
}

func level_facade_methods.prefix(self, operator, callback){
  self.registry:prefix(operator, self.level, callback)
  return self
}

func level_facade_methods.postfix(self, operator, callback){
  self.registry:postfix(operator, self.level, callback)
  return self
}

func level_facade_methods.left(self, operator, callback){
  self.registry:left(operator, self.level, callback)
  return self
}

func level_facade_methods.right(self, operator, callback){
  self.registry:right(operator, self.level, callback)
  return self
}

func level_facade_methods.wrapper(self, left, right, callback){
  self.registry:wrapper(left, right, self.level, callback)
  return self
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
  entry.base = p
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
  // memoization placement: the rules and the parsers they were modified
  // from are memoized where they lead several alternatives of one choice
  g.memos = {}
  if(g.state.opts.memoize != false){
    local named = {}
    local roots = {}
    for(let local name in values(g.rule_order)){
      local e = g.rule_table[name]
      named[sealed[name]] = name
      append(roots, sealed[name])
      if(e.base != null){
        named[e.base] = name
      }
      for(let local b in values(e.bases)){
        named[b] = name
      }
    }
    g.memos = peg.place_memos(roots, named)
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

// statement(name, parser): a statement; the parser yields a statement node
// or {token, ast}
func methods.statement(g, name, parser){
  check_changes(g, "statement")
  peg.resolve(parser)
  if(g.statements[name] == null){
    append(g.statement_order, name)
  }
  g.statements[name] = parser:map(decode_statement)
  touch(g)
}

// extension_statement(name, parser, apply): a statement that is only
// recognised at the top level; after it parsed, apply(result, g) runs between
// statements with grammar changes allowed (g is the grammar of the unit being
// parsed) and returns the statement to emit (or null)
func methods.extension_statement(g, name, parser, apply){
  check_changes(g, "extension_statement")
  peg.resolve(parser)
  if(g.extension_statements[name] == null){
    append(g.extension_statement_order, name)
  }
  g.extension_statements[name] = parser:map(func(result){
    return {apply: apply, result: result}
  })
  touch(g)
}

// the skip function of the walker and the dispatch tables: the native
// whitespace/comment skipper while the trivia rule is the default, the
// trivia parser itself once an extension changed it
local func trivia_skip(g){
  local entry = g.rule_table.trivia
  if(entry != null and entry.parser == g.default_trivia){
    return peg.skip_space
  }
  local trivia = rule_ref(g.state, "trivia")
  return func(ctx, pos){
    for(true){
      local far_pos = ctx.far_pos
      local far_msg = ctx.far_msg
      local q = trivia:parse_on(ctx, pos)
      ctx.far_pos = far_pos
      ctx.far_msg = far_msg
      if(q < 0 or q == pos){
        return pos
      }
      pos = q
    }
  }
}

// walker() -> a fresh expression walker skipping slang trivia, for
// extensions that define their own expression language (see peg.walker)
func methods.walker(g){
  return peg.walker(trivia_skip(g))
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
    if(ctx.tokens != null){
      peg.record_comments(ctx, pos, q)
    }
    ctx.value = null
    return q
  })
  trivia.single = true
  define("trivia", trivia)
  g.default_trivia = trivia

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

  // token(source, name, category): a token parser trimmed by trivia (see
  // methods.token). Word-like tokens (keywords, `not`, `and`, ...) must not
  // be followed by an identifier character, so that `notify` or `localVar`
  // stay identifiers.
  lin.token_fn = func(source, name, category){
    if(type(source) == "string"){
      local p = peg.string(source, concat("Expected: ", name or source))
      if(is_word(source)){
        p = peg.seq(p, peg.pattern("a-zA-Z0-9_"):forbid()):pick(0)
        category = category or "keyword"
      } else {
        category = category or "punctuation"
      }
      return p:token(category):trim(space)
    }
    if(peg.is_parser(source)){
      return source:flatten(name):token(category or name):trim(space)
    }
    error("Invalid token source: ", source)
  }

  local func tok(s, category){
    return peg.ref(lin.token_fn, s, null, category)
  }
  local func token(source, name, category){
    return lin.token_fn(source, name, category)
  }

  // ------------------------------------------------------------ literals

  define("number", peg.digit():plus())

  local sign = peg.choice(peg.char("-"), peg.char("+")):optional()

  define("int_literal", token(peg.seq(sign, rule("number")), "int", "number"):map(func(t){
    return ast.node("Int", {value: to_int(t.value)}, t)
  }))

  define("double_literal", token(peg.seq(sign, rule("number"), peg.char("."), rule("number")), "double", "number"):map(func(t){
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
  ):pick(1):token("string"))

  define("multiline_string", peg.seq(
    peg.string("\"\"\""),
    peg.choice(rule("slang_char"), peg.char("\n")):star_lazy(peg.string("\"\"\"")):map(join_chars),
    peg.string("\"\"\"")
  ):pick(1):token("string"))

  define("string_literal", peg.choice(rule("multiline_string"), rule("double_quoted_string")):map(func(t){
    return ast.node("String", {value: ast.resolve_escapes(t.value)}, t)
  }))

  define("true_literal", tok("true"):map(func(t){ return ast.node("True", {}, t) }))
  define("false_literal", tok("false"):map(func(t){ return ast.node("False", {}, t) }))
  define("null_literal", tok("null"):map(func(t){ return ast.node("Null", {}, t) }))

  define("identifier", token(
    peg.seq(peg.pattern("a-zA-Z_"), peg.pattern("a-zA-Z0-9_"):star())
      :flatten("Expected: identifier")
      :where(func(name){ return lin.active.keywords[name] != true }),
    "identifier"
  ):map(func(t){
    return ast.node("Identifier", {value: t.value}, t)
  }))

  // param: an identifier, or ...name for the rest parameter
  define("param", token(
    peg.seq(peg.string("..."):optional(), peg.pattern("a-zA-Z_"), peg.pattern("a-zA-Z0-9_"):star())
      :flatten("Expected: parameter")
      :where(func(name){ return lin.active.keywords[name] != true }),
    "parameter", "parameter"
  ):map(func(t){
    return ast.node("Identifier", {value: t.value}, t)
  }))

  // spread: ...expr in an argument list or a table literal
  define("spread", peg.seq(tok("...", "operator"), rule("expr")):map(func(v){
    return ast.node("Spread", {value: v[1]}, v[0])
  }))

  // name: an identifier where keywords are allowed: after `.` and `:` and as
  // table keys, so that keywords added by extensions never make a field
  // unreachable
  define("name", token(
    peg.seq(peg.pattern("a-zA-Z_"), peg.pattern("a-zA-Z0-9_"):star()):flatten("Expected: name"),
    "name", "identifier"
  ):map(func(t){
    return ast.node("Identifier", {value: t.value}, t)
  }))

  // ------------------------------------------------------------ tables

  // field: name: value | [key]: value | value
  define("field", peg.choice(rule("spread"), peg.seq(
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
  })))

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
      peg.seq(tok("("), peg.choice(rule("spread"), rule("expr")):star_separated(tok(",")):map(elements), tok(")")):pick(1),
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

  define("params", rule("param"):star_separated(tok(",")):map(elements))

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

  // the expression registry (see peg.walker); names and aliases are what
  // extensions place their own primaries and levels relative to
  local w = peg.walker(peg.skip_space)
  g.expression_walker = w
  w:primary(rule("unquote"), "unquote", {aliases: {"-{}"}})
  w:primary(rule("quote"), "quote", {aliases: {"+{}"}})
  w:primary(rule("identifier"), "identifier", {aliases: {"id"}})
  w:primary(rule("double_literal"), "doubleLiteral", {aliases: {"double", "float"}})
  w:primary(rule("int_literal"), "intLiteral", {aliases: {"integer", "int"}})
  w:primary(rule("string_literal"), "stringLiteral", {aliases: {"string", "str"}})
  w:primary(rule("true_literal"), "trueLiteral", {aliases: {"true"}})
  w:primary(rule("false_literal"), "falseLiteral", {aliases: {"false"}})
  w:primary(rule("null_literal"), "nullLiteral", {aliases: {"null"}})
  w:primary(rule("pattern_assignment_exp"), "patternAssignmentExp", {aliases: {"let"}})
  w:primary(rule("table_literal"), "listLiteral", {aliases: {"list", "tableLiteral", "table"}})
  w:primary(rule("function_expression"), "functionExpression", {aliases: {"function"}})

  w:level("bracket", {aliases: {"()"}})
  w:wrapper(tok("("), tok(")"), "bracket", func(left, value, right){ return value })

  w:level("indexAndCall", {aliases: {".", "[]", ":()"}})
  w:postfix(peg.seq(tok("."), rule("name")), "indexAndCall", func(left, op){
    local name = op[1]
    return ast.node("Index", {receiver: left, index: ast.node("String", {value: name.value}, name.token), dotStyle: true}, op[0])
  })
  w:postfix(peg.seq(tok("["), rule("expr"), tok("]")), "indexAndCall", func(left, op){
    return ast.node("Index", {receiver: left, index: op[1], dotStyle: false}, op[0])
  })
  w:postfix(rule("name_and_args"), "indexAndCall", func(left, op){
    local name = op[0]
    local args = op[1]
    local token = op[2]
    if(name != null){
      return ast.node("Invoke", {receiver: left, name: name, args: args}, token)
    }
    return ast.node("Call", {function: left, args: args}, token)
  })

  w:level("power", {aliases: {"^"}})
  w:right(tok("^", "operator"), "power", binop)

  w:level("unary")
  w:prefix(peg.choice(not_brace(tok("-", "operator")), tok("not", "operator"), tok("~", "operator")), "unary", func(op, exp){
    return ast.node("UnOp", {op: op.value, operand: exp}, op)
  })

  w:level("multiply", {aliases: {"*", "/", "%"}})
  w:left(peg.choice(tok("*", "operator"), tok("/", "operator"), tok("%", "operator")), "multiply", binop)

  w:level("add", {aliases: {"+", "-"}})
  w:left(peg.choice(not_brace(tok("-", "operator")), not_brace(tok("+", "operator"))), "add", binop)

  // bitwise operators sit between arithmetic and comparison, as in Lua:
  // `a & b == c` is `(a & b) == c`, `a + b << 1` is `(a + b) << 1`
  w:level("shift", {aliases: {"<<", ">>"}})
  w:left(peg.choice(tok("<<", "operator"), tok(">>", "operator")), "shift", binop)

  w:level("bitAnd", {aliases: {"&"}})
  w:left(tok("&", "operator"), "bitAnd", binop)

  w:level("bitXor", {aliases: {"~"}})
  w:left(tok("~", "operator"), "bitXor", binop)

  w:level("bitOr", {aliases: {"|"}})
  w:left(tok("|", "operator"), "bitOr", binop)

  w:level("compare", {aliases: {"<=", ">=", "!=", "==", ">"}})
  w:left(peg.choice(tok("<=", "operator"), tok(">=", "operator"), tok("!=", "operator"), tok("==", "operator"), tok(">", "operator"), tok("<", "operator")), "compare", binop)

  w:level("and")
  w:left(tok("and", "operator"), "and", binop)

  w:level("or")
  w:left(tok("or", "operator"), "or", binop)

  // the expression walker is built at seal time
  define("expr", null, {build: func(g){
    g.expression_walker.skip = trivia_skip(g)
    return peg.resolve(g.expression_walker:build())
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
    return peg.dispatch(alternatives, trivia_skip(g), "statement expected")
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

  // the built-in extension statement yields {builtin: node, global: bool};
  // extension statements registered by extensions yield {apply: f, result: value}
  //     extension global "file"   changes the root grammar (main file only)
  g.builtin_extension = peg.seq(tok("extension"), tok("global"):optional(), peg.choice(rule("string_literal"), rule("block"))):map(func(r){
    return {builtin: r[2], global: r[1] != null}
  })

  define("extension_statement", null, {protected: true, build: func(g){
    local alternatives = {g.builtin_extension}
    for(let local n in values(g.extension_statement_order)){
      append(alternatives, g.extension_statements[n])
    }
    return peg.dispatch(alternatives, trivia_skip(g))
  }})
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

// raises a parse failure, leaving its details in lin.last_failure
local func fail_parse(lin, ctx, origin, message, pos){
  local far_pos = ctx.far_pos
  if(far_pos < 0){
    far_pos = pos
  }
  lin.last_failure = {message: message, pos: pos, far_pos: far_pos, far_message: ctx.far_msg or message}
  error(fail_message(ctx, origin, message, pos))
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
  local result = with_changes_allowed(g, owner, parsed.apply, parsed.result, g)
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

// Grammar changes made by a unit end with the unit: the first extension
// statement derives the unit's own grammar from the one the unit started
// with (scoped units; the REPL is not scoped). `extension global` changes the
// root grammar instead and is only allowed in the main file, before any other
// extension statement of it.
local func parse_top_level(g, source, origin, scoped, record){
  local lin = g.state
  local tok_semicolon = peg.ref(lin.token_fn, ";"):optional()
  local parsers = {
    statement: peg.seq(rule_ref(lin, "statement"), tok_semicolon):pick(0),
    final: peg.seq(rule_ref(lin, "final_statement"), tok_semicolon):pick(0),
    extension_statement: peg.seq(rule_ref(lin, "extension_statement"), tok_semicolon):pick(0),
  }
  local ctx = peg.context(source, {record: record})
  if(record){
    lin.record_ctx = ctx
  }
  local statements = {}
  local pos = 0
  local unit = g
  lin.origin = origin
  lin.current = unit
  for(true){
    unit:activate()
    ctx.rule_memo = {}
    lin.phrase_pos = pos
    local q = parsers.extension_statement:parse_on(ctx, pos)
    if(q >= 0){
      local parsed = ctx.value
      local target = null
      if(parsed.global and scoped){
        if(lin.parse_depth != 1 or origin != lin.main_origin){
          fail_parse(lin, ctx, origin, "extension global is only allowed at the top level of the main file", pos)
        }
        if(g != lin.root){
          fail_parse(lin, ctx, origin, "extension global is not available in a file compiled under a dialect", pos)
        }
        if(unit != g){
          fail_parse(lin, ctx, origin, "extension global must come before the other extension statements of the file", pos)
        }
        target = lin.root
      } else {
        if(scoped and unit == g){
          unit = g:derive()
          lin.current = unit
        }
        target = unit
      }
      local node = target:run_extension(parsed, origin)
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
    fail_parse(lin, ctx, origin, "end of input expected", stop)
  }
  local block = ast.node("Block", {statements: statements}, peg.make_token(ctx, null, 0, pos))
  if(lin.opts.optimize != null){
    block = lin.opts.optimize(block)
  }
  if(lin.opts.explain != null and (unit != g or g.dialect != null)){
    lin.opts.explain(origin, unit)
  }
  return block
}

// parse_source(source, origin, {scoped, record}) -> Block node (raises on
// failure). Extension statements of a scoped unit (the default) only affect
// that unit. With record, the tokens are left in g.state.last_tokens (also
// after a failure, whose details are in g.state.last_failure).
func methods.parse_source(g, source, origin, options){
  local lin = g.state
  local outer_origin = lin.origin
  local outer_current = lin.current
  local outer_active = lin.active
  local scoped = options == null or options.scoped != false
  local record = options != null and options.record == true
  if(record){
    lin.last_failure = null
  }
  lin.parse_depth = lin.parse_depth + 1
  local r = pcall(parse_top_level, g, source, origin, scoped, record)
  lin.parse_depth = lin.parse_depth - 1
  if(record){
    lin.last_tokens = peg.tokens(lin.record_ctx)
    lin.record_ctx = null
  }
  lin.origin = outer_origin
  lin.current = outer_current
  // a nested parse (from an unquote or a parser callback) must leave the
  // rule references pointing at the grammar of the enclosing unit
  if(lin.parse_depth > 0 and outer_active != null and lin.active != outer_active){
    outer_active:activate()
  }
  if(let {"err", local e} = r){
    raise(e)
  }
  return r[1]
}

// parse_repl(source) -> node: a chunk, or an expression wrapped in a return.
// The REPL is one unit spread over many lines: its extension statements are
// not scoped.
func methods.parse_repl(g, source){
  local r = pcall(g.parse_source, g, source, "repl", {scoped: false})
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
  lin.root = g
  install_core(g)
  lin.owner = "runtime"
  return g
}

return grammar
