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
local fmt = require("slang/format")

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
    // the lossless tree of the last parse_source with {tree: true} (with
    // the statements parsed so far after a failure), the last parse failure
    // {message, pos, far_pos, far_message}, the failures a parse with
    // {recover: true} went past, and the start of the top-level statement
    // being parsed
    last_tree: null,
    tree_parts: null,
    last_failure: null,
    failures: null,
    phrase_pos: 0,
    // every parse of a unit gets a fresh id (g:unit_id()), so an extension
    // can keep state per unit even when it was loaded once for a project
    unit_counter: 0,
    unit_id: 0,
    // the unit locals of the unit being parsed (g:unit_local): names by
    // key, and the declarations waiting to go before the current statement
    unit_locals: null,
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
  // in a tree, a rule has a node of its own (p.kind "rule", p.rule_name)
  p = peg.custom(
    func(self, ctx, pos){
      local target = self.target
      if(target == null){
        target = resolve_rule(self)
      }
      return target:parse_on(ctx, pos)
    },
    func(self, ctx, pos){
      local target = self.target
      if(target == null){
        target = resolve_rule(self)
      }
      local q = peg.parse_tree(target, ctx, pos)
      if(q >= 0){
        local n = peg.node(self, pos, q, {ctx.tree})
        // core rules are formatted, also inside an extension's syntax
        local entry = lin.active.rule_table[name]
        if(entry != null){
          n.owner = entry.owner
        }
        ctx.tree = n
      }
      return q
    }
  )
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
      g.rule_table[name] = {
        name: e.name,
        parser: e.parser,
        build: e.build,
        wrappers: copy_list(e.wrappers),
        bases: copy_list(e.bases),
        owner: e.owner,
        protected: e.protected,
        probe: e.probe,
        history: copy_list(e.history),
      }
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
  return lin.parse_depth == 0 or
    (lin.extension_depth > 0 and lin.statement_depth == 0)
}

local func check_changes(g, what){
  if(not g:changes_allowed()){
    error(
      "the grammar can only be changed by an extension statement (extension \"file\" or extension { ... } at the top level); ",
      what,
      " was called from code running while a statement is being parsed"
    )
  }
  local lin = g.state
  if(lin.parse_depth > 0 and lin.current != null and g != lin.current){
    error(
      what,
      " was called on a grammar that is not the grammar of the unit being parsed (an extension loaded for another unit kept it); use the grammar passed to an apply function or require(\"slang/compiler\").grammar() at the time of the change, or extension global"
    )
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
  // the syntax an extension defines is formatted by its marks, or keeps its
  // layout without any (see format.extension)
  if(parser != null and g.state.owner != "core"){
    parser = fmt.extension(parser)
  }
  g.rule_table[name] = {
    // the parsers this rule was modified from (memoization placement)
    bases: {},
    name: name,
    parser: parser,
    build: options.build,
    wrappers: {},
    owner: g.state.owner,
    protected: options.protected == true,
    probe: options.probe,
    history: {},
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
      warn(
        g, "rule ", name,
        ": choice(old, seq(old, ...)) never reaches its second alternative; use seq(old, tail:optional())"
      )
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
    warn(
      g, "rule ", entry.name, " no longer parses its probe after ",
      g.state.owner, ": ", r.message, " at ", r.line, ":", r.column
    )
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
    warn(
      g, "rule ", name, " was already modified by ",
      str.join(entry.history, ", "), "; ", owner, " modifies it again"
    )
  }
  append(entry.history, owner)
  // for the formatter: what the extension adds is formatted by its marks or
  // keeps its layout (format.extension), the rule it was given is formatted
  local by_extension = owner != "core"
  if(entry.build != null){
    if(by_extension){
      local given = f
      f = func(p){ return fmt.extension(given(fmt.formatted(p))) }
    }
    append(entry.wrappers, f)
    touch(g)
    return null
  }
  local old = entry.parser
  if(by_extension){
    old = fmt.formatted(old)
  }
  append(entry.bases, old)
  local new = f(old)
  if(not peg.is_parser(new)){
    error("modify(", name, ") must return a parser")
  }
  if(g.state.opts.warn != null){
    check_shape(g, name, old, new)
  }
  if(by_extension){
    new = fmt.extension(new)
  }
  entry.parser = new
  touch(g)
  if(g.state.opts.warn != null){
    check_probe(g, entry)
  }
}

// rules() -> {{name, owner, protected, history}}: every rule with its provenance
func methods.rules(g){
  local out = {}
  for(let local name in values(g.rule_order)){
    local e = g.rule_table[name]
    append(out, {
      name: name,
      owner: e.owner,
      protected: e.protected,
      history: copy_list(e.history),
    })
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

// unit_id() -> a number identifying the parse of the current unit (a new
// one for every unit, including nested compiles), for per-unit extension state
func methods.unit_id(g){
  return g.state.unit_id
}

// origin() -> the name of the source being parsed (null outside a parse)
func methods.origin(g){
  return g.state.origin
}

// unit_local(key, expr) -> Identifier: a local of the unit being parsed,
// declared once per unit as `local <name> = expr`, placed before the
// top-level statement that first asked for it. For the code an extension
// generates in expression position, where it cannot declare anything: a
// runtime module is required once per unit instead of at every use. The
// name is `__` and key with every other character replaced by `_`.
local name_class = str.char_class("a-zA-Z0-9_")
func methods.unit_local(g, key, expr){
  local locals = g.state.unit_locals
  if(locals == null){
    error("unit_local is only available while a unit is being parsed")
  }
  local name = locals.names[key]
  local token = expr.token
  if(name == null){
    local parts = {"__"}
    for(local i = 0; i < len(key); i = i + 1){
      local c = str.substring(key, i, i + 1)
      append(parts, str.class_match(name_class, c, 0) > 0 and c or "_")
    }
    name = str.join(parts, "")
    locals.names[key] = name
    local left = ast.node("Identifier", {value: name}, token)
    append(locals.pending, ast.node(
      "Declaration", {is_local: true, left: left, right: expr}, token
    ))
  }
  return ast.node("Identifier", {value: name}, token)
}

// error_at(token, message...): raises a compile error located at token (a
// token as produced by token/keyword, or any table with line and column)
func methods.error_at(g, token, ...message){
  local location = null
  if(type(token) == "table" and token.line != null){
    location = {
      line: token.line,
      column: token.column,
      origin: g.state.origin or "string",
    }
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
  return ast.node(
    "Identifier", {value: concat("uuid-", g.state.uniq_counter)}, null
  )
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
local expression_meta = {
  __index: expression_methods,
  __type: "expression_registry",
}
local level_facade_methods = {}
local level_facade_meta = {
  __index: level_facade_methods,
  __type: "expression_level",
}

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
  w:primary(fmt.extension(parser:map(ast.decode)), name, placement)
  return self
}

// level(name, {after, before, at, aliases}) -> level
func expression_methods.level(self, name, placement){
  local w = facade_walker(self)
  return level_facade(self, w:level(name, placement))
}

// the operators an extension adds are formatted by their marks or keep their
// own layout (format.extension); the formatter places them like the core's
local func operator_of(parser){
  peg.resolve(parser)
  return fmt.extension(parser)
}

func expression_methods.prefix(self, operator, level, callback){
  local w = facade_walker(self)
  w:prefix(operator_of(operator), level, func(op, exp){
    return ast.decode(callback(op, exp))
  })
  return self
}

func expression_methods.postfix(self, operator, level, callback){
  local w = facade_walker(self)
  w:postfix(operator_of(operator), level, func(exp, op){
    return ast.decode(callback(exp, op))
  })
  return self
}

func expression_methods.left(self, operator, level, callback){
  local w = facade_walker(self)
  w:left(operator_of(operator), level, func(left, op, right){
    return ast.decode(callback(left, op, right))
  })
  return self
}

func expression_methods.right(self, operator, level, callback){
  local w = facade_walker(self)
  w:right(operator_of(operator), level, func(left, op, right){
    return ast.decode(callback(left, op, right))
  })
  return self
}

func expression_methods.wrapper(self, left, right, level, callback){
  local w = facade_walker(self)
  w:wrapper(operator_of(left), operator_of(right), level, func(l, value, r){
    return ast.decode(callback(l, value, r))
  })
  return self
}

// engine API: nud(operator, rbp, f) and led(operator, lbp, f), where
// f(w, ctx, pos, op) (or f(w, ctx, pos, left, op)) parses its own operands
// through w:parse_at(ctx, pos, bp) and leaves an AST node in ctx.value
// (see peg.walker); for syntax that must act before its operand is parsed
func expression_methods.nud(self, operator, rbp, f){
  local w = facade_walker(self)
  w:nud(operator_of(operator), rbp, f)
  return self
}

func expression_methods.led(self, operator, lbp, f){
  local w = facade_walker(self)
  w:led(operator_of(operator), lbp, f)
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
  local p = parser:map(decode_statement)
  if(g.state.owner != "core"){
    p = fmt.extension(p)
  }
  g.statements[name] = p
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
  g.extension_statements[name] = fmt.extension(parser:map(func(result){
    return {apply: apply, result: result}
  }))
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
    ["if"]: true,
    ["else"]: true,
    ["for"]: true,
    ["func"]: true,
    ["return"]: true,
    ["local"]: true,
    ["true"]: true,
    ["false"]: true,
    ["null"]: true,
    ["let"]: true,
    ["break"]: true,
    ["continue"]: true,
    ["extension"]: true,
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
  trivia.trivia = true
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

  // ftok(s, before, after): a token with the formatter's gaps around it (see
  // slang/format: "none", "space", "line", "softline", "hardline", "brace";
  // null leaves a gap to the source)
  local func ftok(s, before, after, category){
    local p = tok(s, category)
    peg.resolve(p)
    return fmt.gaps(p.target, before, after)
  }

  // ------------------------------------------------------------ literals

  // Numbers: decimal digits with single underscores between them
  // (1_000_000); ints also in hex, octal and binary (0xff, 0o17, 0b1010,
  // up to 64 bits, so 0xffffffffffffffff is -1); doubles with a fraction,
  // an exponent or both (1.5, 1e9, 2.5e-3). A number must not run into an
  // identifier character, so 1abc and 0x are errors, not two tokens.
  local func digits_of(class){
    local d = peg.pattern(class)
    return peg.seq(d, peg.seq(peg.char("_"):optional(), d):star())
  }
  local decimal = digits_of("0-9")
  define("number", decimal)

  local sign = peg.choice(peg.char("-"), peg.char("+")):optional()
  local func radix(letters, class){
    return peg.seq(peg.char("0"), peg.pattern(letters), digits_of(class))
  }
  local radix_int = peg.choice(
    radix("xX", "0-9a-fA-F"), radix("oO", "0-7"), radix("bB", "01")
  )
  local exponent = peg.seq(peg.pattern("eE"), sign, decimal)
  local number_end = peg.pattern("a-zA-Z0-9_"):forbid("Expected: end of number")

  // the value of an int literal's text, or null when it needs more than 64 bits
  local func int_value(text){
    local s = str.replace(text, "_", "")
    local negative = false
    local first = str.char_at(s, 0)
    if(first == "-" or first == "+"){
      negative = first == "-"
      s = str.substring(s, 1)
    }
    local bits = 0
    if(len(s) > 2){
      local prefix = str.lower(str.substring(s, 0, 2))
      bits = prefix == "0x" and 4 or prefix == "0o" and 3 or
        prefix == "0b" and 1 or 0
    }
    if(bits == 0){
      local r = pcall(to_int, concat(negative and "-" or "", s))
      return r[0] == "ok" and r[1] or null
    }
    local v = 0
    for(local i = 2; i < len(s); i = i + 1){
      if(v >> (64 - bits) != 0){
        return null
      }
      v = (v << bits) | str.index_of(
        "0123456789abcdef",
        str.lower(str.char_at(s, i))
      )
    }
    return negative and -v or v
  }

  define(
    "int_literal",
    token(
      peg.seq(
        sign,
        peg.choice(radix_int, decimal),
        peg.seq(peg.char("."), peg.digit()):forbid(),
        number_end
      ), "int", "number"
    )
      :map(func(t){
        local v = int_value(t.value)
        if(v == null){
          g:error_at(t, "integer literal out of range: ", t.value)
        }
        return ast.node("Int", {value: v}, t)
      })
  )

  define(
    "double_literal",
    token(
      peg.seq(
        sign, decimal,
        peg.choice(
          peg.seq(peg.char("."), decimal, exponent:optional()),
          exponent
        ), number_end
      ), "double", "number"
    )
      :map(func(t){
        local v = str.to_number(str.replace(t.value, "_", ""))
        if(v - v != 0){
          g:error_at(t, "double literal out of range: ", t.value)
        }
        return ast.node("Double", {value: v + 0.0}, t)
      })
  )

  define("valid_escape", peg.seq(peg.char("\\"), peg.choice(
    peg.char("\""), peg.char("\\"), peg.char("n"), peg.char("r"), peg.char("t"),
    peg.char("b"), peg.char("f"), peg.char("v")
  )):flatten())

  define("slang_char", peg.choice(rule("valid_escape"), peg.char("\n"):neg()))

  define(
    "double_quoted_string",
    peg.seq(
      peg.char("\""),
      rule("slang_char"):star_lazy(peg.char("\"")):map(join_chars),
      peg.char("\"")
    )
      :pick(1)
      :token("string")
  )

  define(
    "multiline_string",
    peg.seq(
      peg.string("\"\"\""),
      peg.choice(rule("slang_char"), peg.char("\n"))
        :star_lazy(peg.string("\"\"\""))
        :map(join_chars), peg.string("\"\"\"")
    )
      :pick(1)
      :token("string")
  )

  define(
    "string_literal",
    peg.choice(rule("multiline_string"), rule("double_quoted_string"))
      :map(func(t){
        local r = pcall(ast.resolve_escapes, t.value)
        if(r[0] == "err"){
          g:error_at(t, r[1].message or r[1])
        }
        return ast.node("String", {value: r[1]}, t)
      })
  )

  define(
    "true_literal",
    tok("true"):map(func(t){ return ast.node("True", {}, t) })
  )
  define(
    "false_literal",
    tok("false"):map(func(t){ return ast.node("False", {}, t) })
  )
  define(
    "null_literal",
    tok("null"):map(func(t){ return ast.node("Null", {}, t) })
  )

  define(
    "identifier",
    token(
      peg.seq(peg.pattern("a-zA-Z_"), peg.pattern("a-zA-Z0-9_"):star())
        :flatten("Expected: identifier")
        :where(func(name){ return lin.active.keywords[name] != true }),
      "identifier"
    )
      :map(func(t){ return ast.node("Identifier", {value: t.value}, t) })
  )

  // param: an identifier, or ...name for the rest parameter
  define(
    "param",
    token(
      peg.seq(
        peg.string("..."):optional(),
        peg.pattern("a-zA-Z_"),
        peg.pattern("a-zA-Z0-9_"):star()
      )
        :flatten("Expected: parameter")
        :where(func(name){ return lin.active.keywords[name] != true }),
      "parameter", "parameter"
    )
      :map(func(t){ return ast.node("Identifier", {value: t.value}, t) })
  )

  // spread: ...expr in an argument list or a table literal
  define(
    "spread",
    peg.seq(ftok("...", null, "none", "operator"), rule("expr")):map(func(v){
      return ast.node("Spread", {value: v[1]}, v[0])
    })
  )

  // name: an identifier where keywords are allowed: after `.` and `:` and as
  // table keys, so that keywords added by extensions never make a field
  // unreachable
  define(
    "name",
    token(
      peg.seq(peg.pattern("a-zA-Z_"), peg.pattern("a-zA-Z0-9_"):star()):flatten(
        "Expected: name"
      ), "name", "identifier"
    )
      :map(func(t){ return ast.node("Identifier", {value: t.value}, t) })
  )

  // ------------------------------------------------------------ tables

  // field: name: value | [key]: value | value
  define(
    "field",
    peg.choice(
      rule("spread"),
      peg.seq(
        peg.choice(
          peg.seq(rule("name"), ftok(":", "none", "space")):pick(0):map(func(n){
            return ast.node("String", {value: n.value}, n.token)
          }),
          peg.seq(
            ftok("[", null, "none"),
            rule("expr"),
            ftok("]", "none", "none"),
            ftok(":", "none", "space")
          ):pick(1)
        ):optional(),
        rule("expr")
      )
        :token()
        :map(func(t){
          local key = t.value[0]
          return ast.node("Field", {key: key, value: t.value[1]}, t)
        })
    )
  )

  // a table that is the last argument of a call may hug it: f(x, {
  define(
    "table_literal",
    fmt.mark(
      peg.seq(
        tok("{"),
        fmt.indent(
          fmt.mark(rule("field"):star_separated(ftok(",", "none", "line")), {
            fill: true,
          }),
          "softline"
        ),
        fmt.trailing_comma(tok(","):optional()),
        fmt.gaps(tok("}"), "softline")
      ),
      {group: true, huggable: true}
    )
      :pick(1)
      :map(elements)
      :token()
      :map(func(t){ return ast.node("Table", {fields: t.value}, t) })
  )

  // ------------------------------------------------------------ calls

  define("identifier_and_index", peg.seq(rule("identifier"), peg.choice(
    peg.seq(tok("["), rule("expr"), tok("]")):pick(1):map(func(e){
      return {e, "bracket"}
    }),
    peg.seq(tok("."), rule("name"):map(func(id){
      return ast.node("String", {value: id.value}, id.token)
    })):pick(1):map(func(e){ return {e, "dot"} })
  ):star()):map(func(v){
    local node = v[0]
    for(let local right in values(v[1])){
      node = ast.node(
        "Index", {receiver: node, index: right[0], dotStyle: right[1] == "dot"},
        right[0].token
      )
    }
    return node
  }))

  define(
    "name_and_args",
    peg.seq(
      peg.seq(ftok(":", null, "none"), rule("name")):pick(1):optional(),
      rule("args")
    )
      :token()
      :map(func(t){ return list(t.value[0], t.value[1], t) })
  )

  // same_line: matches nothing, and only when no line break separates the
  // previous token from the next one. A call's ( and a block argument's {
  // must be on the line where the expression they continue ends, so that
  //     f(x)
  //     { ... }
  // is a call and then a block, not a call with a block argument (as in
  // Kotlin). Tokens skip the whitespace after them, so the break may lie
  // before or after pos.
  local same_line = peg.custom(func(self, ctx, pos){
    local buf = ctx.buffer
    local i = pos - 1
    for(i >= 0){
      local b = str.byte_at(buf, i)
      if(b == 10){
        return peg.fail(ctx, pos, "on the same line")
      }
      if(b != 32 and b != 9 and b != 13){
        break
      }
      i = i - 1
    }
    local q = str.skip_space(buf, pos)
    if(q > pos and str.index_of(str.substring(buf, pos, q), "\n") >= 0){
      return peg.fail(ctx, pos, "on the same line")
    }
    ctx.value = null
    return pos
  })

  // the arguments break all at once; when one of them must break (a
  // function), the others stay on the call's line if they fit
  define(
    "args",
    peg.choice(
      peg.seq(
        fmt.mark(
          peg.seq(
            same_line,
            tok("("),
            fmt.indent(
              fmt.mark(
                peg.choice(rule("spread"), rule("expr")):star_separated(
                  ftok(",", "none", "line")
                ),
                {fill: true}
              ):map(elements),
              "softline"
            ),
            fmt.gaps(tok(")"), "softline")
          ),
          {group: true, hug: true, huggable: "call", before: "none"}
        ):pick(2),
        peg.seq(same_line, fmt.gaps(rule("block"), "none")):pick(1):optional()
      ),
      peg.seq(same_line, fmt.gaps(rule("block"), "none")):pick(1)
    )
      :map(func(args){
        if(type(args) == "Block"){
          return {ast.node("Function", {params: {}, body: args}, args.token)}
        }
        local normal = args[0]
        local block = args[1]
        if(block != null){
          append(normal, ast.node(
            "Function", {params: {}, body: block}, block.token
          ))
        }
        return normal
      })
  )

  // ------------------------------------------------------------ statements

  define(
    "expr_statement",
    peg.seq(rule("expr"), peg.seq(
      ftok("=", "space", "space"),
      rule("expr")
    ):optional())
      :map(func(v){
        local exp = v[0]
        local assignment = v[1]
        if(assignment != null){
          if(not ast.is_assignable(exp)){
            error(
              "Invalid assignment: ",
              ast.to_string(exp),
              " is not an assignable expression"
            )
          }
          return ast.node(
            "Assignment", {left: exp, right: assignment[1]}, assignment[0]
          )
        }
        if(exp.type == "Call" or exp.type == "Invoke"){
          return ast.node("CallStat", {call: exp}, exp.token)
        }
        if(exp.type == "Null"){
          return null
        }
        return exp
      })
  )

  define(
    "local_declaration",
    peg.seq(ftok("local", null, "space"), rule("expr"), peg.seq(
      ftok("=", "space", "space"),
      rule("expr")
    ):optional())
      :map(func(v){
        local right = null
        if(v[2] != null){
          right = v[2][1]
        }
        return ast.node(
          "Declaration", {is_local: true, left: v[1], right: right}, v[0]
        )
      }),
    {probe: "local x = 1"}
  )

  // if(c){ a } else { b }: an expression; else is required, and else if
  // chains
  define(
    "if_expression",
    peg.seq(
      ftok("if", null, "none"),
      ftok("(", "none", "none"),
      rule("expr"),
      ftok(")", "none", "none"),
      ftok("{", "none", "space"),
      rule("expr"),
      ftok("}", "space", "space"),
      ftok("else", "space", "space"),
      peg.choice(
        rule("if_expression"),
        peg.seq(
          ftok("{", null, "space"), rule("expr"), ftok("}", "space")
        ):pick(1)
      )
    )
      :map(func(v){
        return ast.node(
          "IfExpr", {condition: v[2], thenValue: v[5], elseValue: v[8]}, v[0]
        )
      })
  )

  define(
    "if_statement",
    peg.seq(
      ftok("if", null, "none"),
      ftok("(", "none", "none"),
      rule("expr"),
      ftok(")", "none", "brace"),
      rule("statement"),
      peg.seq(ftok("else", "space", "space"), rule("statement")):optional()
    )
      :map(func(v){
        local else_branch = null
        if(v[5] != null){
          else_branch = v[5][1]
        }
        return ast.node(
          "If", {condition: v[2], thenBranch: v[4], elseBranch: else_branch},
          v[0]
        )
      }),
    {probe: "if (x) { f() } else { g() }"}
  )

  define("for_loop", peg.seq(
    // for(init; condition; update), for(condition; update), for(condition);
    // init and update may also be left empty: for(; condition; update)
    ftok("for", null, "none"),
    ftok("(", "none", "none"),
    rule("expression_or_statement"):optional(),
    peg.seq(ftok(";", "none", "space"), rule("expression_or_statement"))
      :pick(1)
      :optional(),
    peg.seq(ftok(";", "none", "space"), rule("statement"):optional())
      :pick(1)
      :optional(),
    fmt.gaps(peg.char(")"), "none", "brace"),
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
      return ast.node(
        "For", {init: head[0], condition: head[1], update: head[2], body: body},
        v[0]
      )
    }
    if(n == 2){
      if(ast.is_statement(head[0])){
        return ast.node(
          "For", {init: head[0], condition: head[1], body: body}, v[0]
        )
      }
      return ast.node(
        "For", {condition: head[0], update: head[1], body: body}, v[0]
      )
    }
    if(n == 1){
      // the one element is the condition; a lone call parsed as a statement
      // (for(st:step())) is the call's value
      local condition = head[0]
      if(condition.type == "CallStat"){
        condition = condition.call
      }
      return ast.node("For", {condition: condition, body: body}, v[0])
    }
    error("Invalid for loop")
  }), {probe: "for(local i = 0; i < 3; i = i + 1){ f(i) }"})

  define(
    "for_in_loop",
    peg.seq(
      ftok("for", null, "none"),
      ftok("(", "none", "none"),
      ftok("let", "none", "space"),
      rule("slang_pattern"),
      ftok("in", "space", "space"),
      rule("expr"),
      ftok(")", "none", "brace"),
      rule("statement")
    )
      :map(func(v){
        return ast.node(
          "ForIn", {pattern: v[3], itterator: v[5], body: v[7]}, v[0]
        )
      }),
    {probe: "for(let local x in values(t)){ f(x) }"}
  )

  define(
    "function_definition_statement",
    peg.seq(
      ftok("local", null, "space"):optional(),
      ftok("func", null, "space"),
      rule("identifier_and_index"),
      rule("function_definition")
    )
      :map(func(v){
        return ast.node(
          "Declaration", {is_local: v[0] != null, left: v[2], right: v[3]}, v[1]
        )
      }),
    {probe: "func f(a, b){ return a }"}
  )

  // let PATTERN = expr as a statement: binds, or raises when the value does
  // not match (the expression form is the condition of an if)
  // try { ... } catch(pattern) { ... } ...: the first clause whose pattern
  // matches the raised value runs; none matching raises it again. A clause
  // without a pattern catches everything.
  define(
    "catch_clause",
    peg.seq(
      ftok("catch", "space"),
      peg.seq(
        ftok("(", "none", "none"),
        rule("slang_pattern"),
        ftok(")", "none", "space")
      )
        :pick(1)
        :optional(),
      fmt.mark(rule("block"), {before: "space", hard_body: true})
    )
      :map(func(v){
        return ast.node("Catch", {pattern: v[1], body: v[2]}, v[0])
      })
  )

  define(
    "try_statement",
    peg.seq(
      ftok("try", null, "space"),
      rule("block"),
      rule("catch_clause"):plus()
    )
      :map(func(v){
        return ast.node("Try", {body: v[1], catches: v[2]}, v[0])
      }),
    {probe: "try { f() } catch(local e) { g(e) }"}
  )

  // defer statement: runs when the enclosing block is left, however it is
  // left (the end, a return, a break, an error), last in first out
  define(
    "defer_statement",
    peg.seq(tok("defer"), rule("statement")):map(func(v){
      local body = v[1]
      if(body.type != "Block"){
        body = ast.node("Block", {statements: {body}}, v[0])
      }
      return ast.node("Defer", {body: body}, v[0])
    }),
    {probe: "defer f()"}
  )

  // :name: for(...){ ... }: a loop that break name and continue name in
  // nested loops refer to
  define(
    "labeled_loop",
    peg.seq(
      ftok(":", null, "none"),
      rule("identifier"),
      ftok(":", "none", "space"),
      peg.choice(rule("for_in_loop"), rule("for_loop"))
    )
      :map(func(v){
        // a copy: parse results may be shared (memoized)
        local loop = {}
        for(let local e in entries(v[3])){
          loop[e[0]] = e[1]
        }
        loop.meta = v[3].meta
        loop.label = v[1].value
        return loop
      }),
    {probe: ":outer: for(true){ break outer }"}
  )

  define(
    "let_statement",
    peg.seq(
      ftok("let", null, "space"),
      rule("slang_pattern"),
      ftok("=", "space", "space"),
      rule("expr")
    )
      :map(func(v){
        return ast.node("LetStat", {pattern: v[1], right: v[3]}, v[0])
      }),
    {probe: "let {name: local n} = t"}
  )

  define("expression_or_statement", peg.choice(
    rule("local_declaration"),
    rule("let_statement"),
    rule("if_statement"),
    rule("try_statement"),
    rule("defer_statement"),
    rule("labeled_loop"),
    rule("for_loop"),
    rule("for_in_loop"),
    rule("block"),
    rule("function_definition_statement"),
    rule("expr_statement")
  ))

  // statements on lines of their own, one blank line between them kept;
  // the formatter drops their `;`
  define(
    "chunk",
    peg.seq(
      fmt.mark(
        peg.seq(rule("statement"), fmt.drop(tok(";"):optional())):pick(0),
        {before: "hardline", blank: true}
      ):star(),
      fmt.mark(
        peg.seq(rule("final_statement"), fmt.drop(tok(";"):optional())):pick(0),
        {before: "hardline", blank: true}
      ):optional()
    )
      :token()
      :map(func(t){
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
  )

  define(
    "block",
    peg.seq(
      tok("{"), fmt.indent(rule("chunk"), "hardline", "hardline"), tok("}")
    ):pick(1),
    {probe: "{ x = 1; f(x) }"}
  )

  // break and continue, optionally with the label of an enclosing loop
  define(
    "break_statement",
    peg.seq(tok("break"), rule("identifier"):optional()):map(func(v){
      return ast.node("Break", {label: v[1] and v[1].value}, v[0])
    })
  )
  define(
    "continue_statement",
    peg.seq(tok("continue"), rule("identifier"):optional()):map(func(v){
      return ast.node("Continue", {label: v[1] and v[1].value}, v[0])
    })
  )

  // the value is optional: a bare `return` returns null
  define(
    "return_statement",
    peg.seq(tok("return"), rule("expr"):optional()):map(func(v){
      return ast.node("Return", {value: v[1]}, v[0])
    })
  )

  define("final_statement", peg.choice(
    rule("return_statement"),
    rule("break_statement"),
    rule("continue_statement")
  ))

  // ------------------------------------------------------------ functions

  define(
    "params",
    fmt.mark(rule("param"):star_separated(ftok(",", "none", "line")), {
      fill: true,
    }):map(elements)
  )

  define(
    "function_definition",
    peg.seq(
      fmt.mark(
        peg.seq(
          tok("("),
          fmt.indent(rule("params"), "softline"),
          fmt.gaps(tok(")"), "softline")
        ),
        {group: true, before: "none"}
      ),
      peg.choice(
        fmt.gaps(rule("block"), "none"),
        peg.seq(ftok("=>", "space", "space"), rule("expr"))
      )
    )
      :token()
      :map(func(t){
        local v = {t.value[0][0], t.value[0][1], t.value[0][2], t.value[1]}
        local body = v[3]
        if(type(body) == "table"){
          local e = body[1]
          body = ast.node(
            "Block", {statements: {ast.node("Return", {value: e}, e.token)}}, t
          )
        }
        return ast.node("Function", {params: v[1], body: body}, t)
      })
  )

  define(
    "function_expression",
    peg.seq(ftok("func", null, "none"), rule("function_definition")):pick(1)
  )

  // ------------------------------------------------------------ patterns

  define("slang_pattern", peg.choice(
    rule("quoted_pattern"),
    rule("table_pattern"),
    rule("const_pattern"),
    rule("var_pattern")
  ))

  define(
    "table_pattern",
    peg.seq(
      ftok("{", null, "none"),
      rule("field_pattern"):star_separated(ftok(",", "none", "space")),
      ftok("}", "none")
    )
      :map(func(v){
        return ast.node(
          "TablePattern", {type_check: "table", fields: v[1].elements}, v[0]
        )
      })
  )

  // 'Name{...} checks the type (and matches the fields); 'Name as PATTERN
  // checks the type and matches PATTERN against the same value. Anything
  // else after the quote (a call, a field, a parenthesised value) is a
  // matcher: its __match(value) returns null for no match, or the value the
  // rest of the pattern continues with: 'm, 'm{...}, 'm as PATTERN.
  local matcher_expr = peg.choice(
    peg.seq(tok("("), rule("expr"), tok(")")):pick(1):map(func(e){
      return {parenthesised: e}
    }),
    peg.seq(
      rule("identifier_and_index"),
      peg.seq(
        tok("("),
        peg.choice(rule("spread"), rule("expr"))
          :star_separated(tok(","))
          :map(elements), tok(")")
      )
        :pick(1)
        :optional()
    )
      :map(func(v){
        if(v[1] == null){
          return v[0]
        }
        return ast.node("Call", {function: v[0], args: v[1]}, v[0].token)
      })
  )
  define(
    "quoted_pattern",
    peg.seq(ftok("'", null, "none"), matcher_expr, peg.choice(
      peg.seq(tok("as"), rule("slang_pattern")):pick(1),
      rule("table_pattern")
    ):optional())
      :map(func(v){
        local m = v[1]
        local sub = v[2]
        if(m.parenthesised != null){
          return ast.node(
            "MatcherPattern",
            {matcher: m.parenthesised, type_name: null, sub: sub}, v[0]
          )
        }
        if(m.type == "Identifier"){
          // a type name
          if(sub == null){
            return ast.node(
              "TablePattern", {type_check: m.value, fields: {}}, v[0]
            )
          }
          if(sub.type == "TablePattern" and sub.type_check == "table" and
            sub.token.value == "{"){
            sub.type_check = m.value
            return sub
          }
          return ast.node(
            "MatcherPattern", {matcher: null, type_name: m.value, sub: sub},
            v[0]
          )
        }
        return ast.node(
          "MatcherPattern", {matcher: m, type_name: null, sub: sub}, v[0]
        )
      })
  )

  define(
    "field_pattern",
    peg.seq(
      peg.choice(
        peg.seq(rule("name"), ftok(":", "none", "space")):pick(0),
        peg.seq(
          ftok("[", null, "none"),
          rule("expr"),
          ftok("]", "none", "none"),
          ftok(":", "none", "space")
        ):pick(1)
      )
        :map(func(exp){
          if(exp.type == "Identifier"){
            return ast.node("String", {value: exp.value}, exp.token)
          }
          return exp
        })
        :optional(),
      rule("slang_pattern")
    )
      :map(func(v){
        local key = v[0]
        local value = v[1]
        local token = value.token
        if(key != null){
          token = key.token
        }
        return ast.node("FieldPattern", {key: key, value: value}, token)
      })
  )

  define(
    "const_pattern",
    peg.choice(
      rule("int_literal"),
      rule("double_literal"),
      rule("string_literal"),
      rule("true_literal"),
      rule("false_literal"),
      rule("null_literal")
    )
      :map(func(exp){
        return ast.node("ConstPattern", {value: exp}, exp.token)
      })
  )

  define(
    "var_pattern",
    peg.seq(tok("local"):optional(), rule("identifier"), tok("?"):optional())
      :map(func(v){
        return ast.node(
          "VarPattern",
          {isLocal: v[0] != null, canBeNull: v[2] != null, name: v[1]},
          v[1].token
        )
      })
  )

  define(
    "pattern_assignment_exp",
    peg.seq(
      ftok("let", null, "space"),
      rule("slang_pattern"),
      ftok("=", "space", "space"),
      rule("expr")
    )
      :map(func(v){
        return ast.node("Let", {pattern: v[1], right: v[3]}, v[0])
      })
  )

  // ------------------------------------------------------------ quoting
  //
  // Quote and unquote are how extensions produce code; they are protected.

  define(
    "quote_body",
    // laid out as +{stat: x} when it fits, else with the body on lines of
    // its own (see the quote and unquote rules)
    peg.choice(
      peg.seq(
        tok("id"),
        ftok(":", "none", "line"),
        fmt.indent(rule("identifier"), "softline")
      ),
      peg.seq(
        tok("block"),
        ftok(":", "none", "line"),
        fmt.indent(rule("chunk"), "softline")
      ),
      peg.seq(tok("stat"), ftok(":", "none", "line"), fmt.indent(
        peg.choice(rule("statement"), rule("final_statement")),
        "softline"
      )),
      peg.seq(
        peg.seq(tok("expr"), ftok(":", "none", "line")):optional(),
        fmt.indent(rule("expr"), "softline")
      )
    ),
    {protected: true}
  )

  local func split_quote_body(body){
    if(len(body) == 3){
      return list(body[0].value, body[2])
    }
    return list("expr", body[1])
  }

  local quote_body = peg.custom(func(self, ctx, pos){
    local prev = lin.in_quote
    lin.in_quote = true
    local q = peg.sub(rule("quote_body"), ctx, pos)
    lin.in_quote = prev
    return q
  })
  define(
    "quote",
    fmt.mark(
      peg.seq(tok("+"), ftok("{", "none"), quote_body, ftok("}", "softline")),
      {group: true, hug: true}
    )
      :pick(2)
      :token()
      :map(func(t){
        local parts = split_quote_body(t.value)
        return ast.node("Quote", {ast_type: parts[0], ast: parts[1]}, t)
      }),
    {protected: true}
  )

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
        if(ctx.collect != null and hit.tree != null){
          list_push(ctx.collect, hit.tree)
        }
        return hit.stop
      }
    }
    local q = peg.sub(unquote_body_ref, ctx, pos)
    if(q < 0){
      return - 1
    }
    // (the tree of the body, when one is built, for a memo hit)
    local body_tree = null
    if(ctx.collect != null){
      body_tree = ctx.collect[len(ctx.collect) - 1]
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
      return peg.fail(
        ctx, pos, "Unquote outside of quote can only be used with expr or block"
      )
    }
    if(type_name == "expr"){
      node = ast.node(
        "Block", {statements: {ast.node("Return", {value: node}, node.token)}},
        node.token
      )
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
    memo[pos] = {node: ctx.value, stop: q, tree: body_tree}
    return q
  })
  define(
    "unquote",
    fmt.mark(
      peg.seq(tok("-"), ftok("{", "none"), unquote_body, ftok("}", "softline")),
      {group: true, hug: true}
    ):pick(2),
    {protected: true}
  )

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
  w:primary(rule("double_literal"), "doubleLiteral", {
    aliases: {"double", "float"},
  })
  w:primary(rule("int_literal"), "intLiteral", {aliases: {"integer", "int"}})
  w:primary(rule("string_literal"), "stringLiteral", {
    aliases: {"string", "str"},
  })
  w:primary(rule("true_literal"), "trueLiteral", {aliases: {"true"}})
  w:primary(rule("false_literal"), "falseLiteral", {aliases: {"false"}})
  w:primary(rule("null_literal"), "nullLiteral", {aliases: {"null"}})
  w:primary(rule("pattern_assignment_exp"), "patternAssignmentExp", {
    aliases: {"let"},
  })
  w:primary(rule("table_literal"), "listLiteral", {
    aliases: {"list", "tableLiteral", "table"},
  })
  w:primary(rule("if_expression"), "ifExpression", {aliases: {"if"}})
  w:primary(rule("function_expression"), "functionExpression", {
    aliases: {"function"},
  })

  w:level("bracket", {aliases: {"()"}})
  w:wrapper(tok("("), tok(")"), "bracket", func(left, value, right){
    return value
  })

  w:level("indexAndCall", {aliases: {".", "[]", ":()"}})
  w:postfix(
    peg.seq(ftok(".", "none", "none"), rule("name")),
    "indexAndCall",
    func(left, op){
      local name = op[1]
      return ast.node(
        "Index",
        {
          receiver: left,
          index: ast.node("String", {value: name.value}, name.token),
          dotStyle: true,
        }, op[0]
      )
    }
  )
  w:postfix(
    peg.seq(ftok("[", "none", "none"), rule("expr"), ftok("]", "none")),
    "indexAndCall",
    func(left, op){
      return ast.node(
        "Index", {receiver: left, index: op[1], dotStyle: false}, op[0]
      )
    }
  )
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
  w:prefix(
    peg.choice(
      not_brace(tok("-", "operator")),
      tok("not", "operator"),
      tok("~", "operator")
    ),
    "unary",
    func(op, exp){ return ast.node("UnOp", {op: op.value, operand: exp}, op) }
  )

  w:level("multiply", {aliases: {"*", "/", "%"}})
  w:left(
    peg.choice(
      tok("*", "operator"), tok("/", "operator"), tok("%", "operator")
    ), "multiply", binop
  )

  w:level("add", {aliases: {"+", "-"}})
  w:left(
    peg.choice(
      not_brace(tok("-", "operator")),
      not_brace(tok("+", "operator"))
    ), "add", binop
  )

  // bitwise operators sit between arithmetic and comparison, as in Lua:
  // `a & b == c` is `(a & b) == c`, `a + b << 1` is `(a + b) << 1`
  w:level("shift", {aliases: {"<<", ">>"}})
  w:left(
    peg.choice(tok("<<", "operator"), tok(">>", "operator")), "shift", binop
  )

  w:level("bitAnd", {aliases: {"&"}})
  w:left(tok("&", "operator"), "bitAnd", binop)

  w:level("bitXor", {aliases: {"~"}})
  w:left(tok("~", "operator"), "bitXor", binop)

  w:level("bitOr", {aliases: {"|"}})
  w:left(tok("|", "operator"), "bitOr", binop)

  w:level("compare", {aliases: {"<=", ">=", "!=", "==", ">"}})
  w:left(
    peg.choice(
      tok("<=", "operator"),
      tok(">=", "operator"),
      tok("!=", "operator"),
      tok("==", "operator"),
      tok(">", "operator"),
      tok("<", "operator")
    ), "compare", binop
  )

  w:level("and")
  w:left(tok("and", "operator"), "and", binop)

  w:level("or")
  w:left(tok("or", "operator"), "or", binop)

  // the expression walker is built at seal time
  define("expr", null, {
    build: func(g){
      g.expression_walker.skip = trivia_skip(g)
      return peg.resolve(g.expression_walker:build())
    },
  })

  // ------------------------------------------------------------ statement registry

  g.initial_statement = rule("expression_or_statement"):where(func(v){
    return v == null or ast.is_statement(v)
  })

  define("statement", null, {
    build: func(g){
      local alternatives = {}
      for(let local n in values(g.statement_order)){
        append(alternatives, g.statements[n])
      }
      append(alternatives, g.initial_statement)
      return peg.dispatch(alternatives, trivia_skip(g), "statement expected")
    },
  })

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
  g.builtin_extension = peg.seq(
    tok("extension"),
    tok("global"):optional(),
    peg.choice(rule("string_literal"), rule("block"))
  )
    :map(func(r){ return {builtin: r[2], global: r[1] != null} })

  define("extension_statement", null, {
    protected: true,
    build: func(g){
      local alternatives = {g.builtin_extension}
      for(let local n in values(g.extension_statement_order)){
        append(alternatives, g.extension_statements[n])
      }
      return peg.dispatch(alternatives, trivia_skip(g))
    },
  })
}

// ------------------------------------------------------------ parsing

local func fail_message(ctx, origin, message, pos){
  local lc = peg.line_col(ctx, pos)
  local far_pos = ctx.far_pos
  if(far_pos < 0){
    far_pos = pos
  }
  local far = peg.line_col(ctx, far_pos)
  return concat(
    "Failed to parse source: ", message, ":", origin, ":", lc[0], ":", lc[1],
    " (farthest: ", ctx.far_msg or message, " at ", far[0], ":", far[1], ")"
  )
}

// raises a parse failure, leaving its details in lin.last_failure
local func fail_parse(lin, ctx, origin, message, pos){
  local far_pos = ctx.far_pos
  if(far_pos < 0){
    far_pos = pos
  }
  lin.last_failure = {
    message: message,
    pos: pos,
    far_pos: far_pos,
    far_message: ctx.far_msg or message,
  }
  error(fail_message(ctx, origin, message, pos))
}

// runs compile-time code with grammar changes allowed; only valid between
// top-level statements
local func with_changes_allowed(g, owner, f, a, b){
  local lin = g.state
  if(lin.statement_depth > 0){
    error(
      "extension statements cannot run from code that executes while a statement is being parsed"
    )
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

// node goes after the unit locals that were requested while parsing it
local func emit(lin, statements, node){
  local pending = lin.unit_locals.pending
  if(len(pending) > 0){
    for(local i = 0; i < len(pending); i = i + 1){
      append(statements, pending[i])
    }
    lin.unit_locals.pending = {}
  }
  if(node != null){
    append(statements, node)
  }
}

// parses with the tree path in a context made for a tree
local func parse_with(parser, ctx, pos){
  if(ctx.tree_on){
    return peg.parse_tree(parser, ctx, pos)
  }
  return parser:parse_on(ctx, pos)
}

local func parse_statement(lin, parser, ctx, pos){
  lin.statement_depth = lin.statement_depth + 1
  local r = pcall(parse_with, parser, ctx, pos)
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
// the node of a whole unit in a lossless tree
local unit_parser = {kind: "unit"}

local func is_space_byte(b){
  return b == 32 or b == 9 or b == 10 or b == 13
}

// where the slang trivia (whitespace, // comments) that buf[from, to) ends
// with starts (see peg's raw leaves): back over whitespace, then over a
// comment when the line has a // outside of a string before that point
local func trivia_start(buf, from, to){
  local k = to
  for(true){
    for(k > from and is_space_byte(str.byte_at(buf, k - 1))){
      k = k - 1
    }
    local line = k
    for(line > from and str.byte_at(buf, line - 1) != 10){
      line = line - 1
    }
    local comment = - 1
    local in_string = false
    local i = line
    for(i < k - 1){
      local b = str.byte_at(buf, i)
      if(in_string){
        if(b == 92){
          i = i + 1
        } else if(b == 34){
          in_string = false
        }
      } else if(b == 34){
        in_string = true
      } else if(b == 47 and str.byte_at(buf, i + 1) == 47){
        comment = i
        break
      }
      i = i + 1
    }
    if(comment < 0){
      return k
    }
    k = comment
  }
}

// comments(buffer, start, stop) -> the `//` comments in a run of trivia, as
// highlighter spans
func grammar.comments(buffer, start, stop){
  local out = {}
  local i = str.index_of(buffer, "//", start)
  for(i >= 0 and i < stop){
    local j = str.index_of(buffer, "\n", i)
    if(j < 0 or j > stop){
      j = stop
    }
    list_push(out, {category: "comment", start: i, stop: j})
    i = str.index_of(buffer, "//", j)
  }
  return out
}

local word_class = str.char_class("a-zA-Z0-9_")
local digit_class = str.char_class("0-9")

// a region a parse with {recover: true} went past: highlighted by its words
// (keywords of the grammar, identifiers, numbers), strings and comments
local func error_region(keywords){
  return {
    kind: "error", highlight: func(buffer, start, stop){
      local out = {}
      local i = start
      for(i < stop){
        local b = str.byte_at(buffer, i)
        local j = i + 1
        local category = null
        if(b == 47 and str.byte_at(buffer, i + 1) == 47){
          j = str.index_of(buffer, "\n", i)
          if(j < 0 or j > stop){
            j = stop
          }
          category = "comment"
        } else if(b == 34){
          for(j < stop and str.byte_at(buffer, j) != 34 and
            str.byte_at(buffer, j) != 10){
            if(str.byte_at(buffer, j) == 92){
              j = j + 1
            }
            j = j + 1
          }
          if(j < stop and str.byte_at(buffer, j) == 34){
            j = j + 1
          }
          category = "string"
        } else if(str.class_match(word_class, buffer, i) > 0){
          j = i + str.class_run(word_class, buffer, i) - i
          local w = str.substring(buffer, i, j)
          if(str.class_match(digit_class, buffer, i) > 0){
            category = "number"
          } else if(keywords[w] == true){
            category = "keyword"
          } else {
            category = "identifier"
          }
        }
        if(category != null){
          list_push(out, {category: category, start: i, stop: j})
        }
        i = j
      }
      return out
    },
  }
}

local func parse_top_level(g, source, origin, scoped, recover, tree){
  local lin = g.state
  local tok_semicolon = fmt.drop(peg.ref(lin.token_fn, ";"):optional())
  local parsers = {
    statement: peg.seq(rule_ref(lin, "statement"), tok_semicolon):pick(0),
    final: peg.seq(rule_ref(lin, "final_statement"), tok_semicolon):pick(0),
    extension_statement: peg.seq(
      rule_ref(lin, "extension_statement"),
      tok_semicolon
    ):pick(0),
  }
  local ctx = peg.context(source, {tree: tree})
  ctx.trivia_start = trivia_start
  local statements = {}
  // with a tree: the node of each top-level statement and the value its
  // parse produced (the unit's default layer)
  local trees = {}
  local tree_values = {}
  lin.tree_parts = trees
  local pos = 0
  local unit = g
  lin.origin = origin
  lin.current = unit
  lin.unit_counter = lin.unit_counter + 1
  lin.unit_id = lin.unit_counter
  lin.unit_locals = {names: {}, pending: {}}
  // With recover, a statement that fails to parse does not end the parse:
  // the failure is kept in lin.failures and the parse goes on at the first
  // later line where a statement parses; the text skipped is an error region
  // in the tree. (For highlighting: the tree, not the result, is what counts.)
  local stop = 0
  local region = null
  for(true){
    for(true){
      unit:activate()
      ctx.rule_memo = {}
      lin.phrase_pos = pos
      local q = parse_with(parsers.extension_statement, ctx, pos)
      if(q >= 0){
        local parsed = ctx.value
        local target = null
        if(parsed.global and scoped){
          if(lin.parse_depth != 1 or origin != lin.main_origin){
            fail_parse(
              lin, ctx, origin,
              "extension global is only allowed at the top level of the main file",
              pos
            )
          }
          if(g != lin.root){
            fail_parse(
              lin, ctx, origin,
              "extension global is not available in a file compiled under a dialect",
              pos
            )
          }
          if(unit != g){
            fail_parse(
              lin, ctx, origin,
              "extension global must come before the other extension statements of the file",
              pos
            )
          }
          target = lin.root
        } else {
          if(scoped and unit == g){
            unit = g:derive()
            lin.current = unit
          }
          target = unit
        }
        if(tree){
          list_push(trees, ctx.tree)
          list_push(tree_values, parsed)
        }
        local node = target:run_extension(parsed, origin)
        emit(lin, statements, node)
        pos = q
      } else {
        q = parse_statement(lin, parsers.statement, ctx, pos)
        if(q >= 0){
          if(tree){
            list_push(trees, ctx.tree)
            list_push(tree_values, ctx.value)
          }
          emit(lin, statements, ctx.value)
          pos = q
        } else {
          q = parse_statement(lin, parsers.final, ctx, pos)
          if(q >= 0){
            if(tree){
              list_push(trees, ctx.tree)
              list_push(tree_values, ctx.value)
            }
            emit(lin, statements, ctx.value)
            pos = q
          }
          break
        }
      }
    }
    stop = str.skip_space(source, pos)
    if(stop == len(source) or not recover){
      break
    }
    local far_pos = ctx.far_pos
    if(far_pos < stop){
      far_pos = stop
    }
    if(region == null or region.stop != pos){
      list_push(lin.failures, {
        message: "end of input expected",
        pos: stop,
        far_pos: far_pos,
        far_message: ctx.far_msg or "end of input expected",
      })
      region = peg.leaf(error_region(unit.keywords), pos, pos)
      list_push(trees, region)
      list_push(tree_values, false)
    }
    // the next line after the farthest failure
    local next = str.index_of(source, "\n", far_pos)
    if(next < 0){
      next = len(source)
    } else {
      next = next + 1
    }
    region.stop = next
    pos = next
    ctx.far_pos = - 1
    ctx.far_msg = null
    if(pos >= len(source)){
      stop = pos
      break
    }
  }
  if(stop != len(source)){
    fail_parse(lin, ctx, origin, "end of input expected", stop)
  }
  if(tree){
    // trivia no token took (a file of nothing but comments)
    if(pos < stop){
      local rest = peg.leaf(g.default_trivia, pos, stop)
      list_push(trees, rest)
      list_push(tree_values, rest.value)
    }
    lin.last_tree = peg.node(unit_parser, 0, stop, trees)
    lin.last_tree.value = tree_values
  }
  local block = ast.node(
    "Block",
    {statements: statements},
    peg.make_token(ctx, null, 0, pos)
  )
  if(lin.opts.optimize != null){
    block = lin.opts.optimize(block)
  }
  if(lin.opts.explain != null and (unit != g or g.dialect != null)){
    lin.opts.explain(origin, unit)
  }
  return block
}

// parse_source(source, origin, {scoped, tree, recover}) -> Block node
// (raises on failure; the details of a parse failure are in
// g.state.last_failure). Extension statements of a scoped unit (the default)
// only affect that unit. With tree, the lossless tree of the unit is left in
// g.state.last_tree (see slang/peg): a node of kind "unit" whose kids are the
// top-level statements; after a failure, the statements parsed before it.
// recover (with tree, for highlighting) goes past statements that fail to
// parse: they are error regions in the tree (with highlight functions, see
// peg.highlights) and their failures are in g.state.failures.
func methods.parse_source(g, source, origin, options){
  local lin = g.state
  local outer_origin = lin.origin
  local outer_current = lin.current
  local outer_active = lin.active
  local outer_unit_id = lin.unit_id
  local outer_unit_locals = lin.unit_locals
  local scoped = options == null or options.scoped != false
  local tree = options != null and
    (options.tree == true or options.recover == true)
  local recover = tree and options.recover == true
  lin.last_failure = null
  if(tree){
    lin.last_tree = null
    lin.failures = {}
  }
  local outer_parts = lin.tree_parts
  lin.parse_depth = lin.parse_depth + 1
  local r = pcall(parse_top_level, g, source, origin, scoped, recover, tree)
  lin.parse_depth = lin.parse_depth - 1
  if(tree and r[0] == "err" and lin.tree_parts != null){
    local parts = lin.tree_parts
    local stop = 0
    if(len(parts) > 0){
      stop = parts[len(parts) - 1].stop
    }
    lin.last_tree = peg.node(unit_parser, 0, stop, parts)
  }
  lin.tree_parts = outer_parts
  lin.origin = outer_origin
  lin.current = outer_current
  lin.unit_id = outer_unit_id
  lin.unit_locals = outer_unit_locals
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
