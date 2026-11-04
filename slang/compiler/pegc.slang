// pegc: compiles a sealed peg grammar (slang/grammar) into slang source.
//
//   local pegc = require("slang/pegc")
//   local c = pegc.compile(g)        // g: a grammar that has parsed (sealed)
//   c.source                         // the generated parser as slang
//   local parsers = c:load()         // {rules, trees, fasts}: by rule name
//   parsers.rules.statement(ctx, 0)  // as parser:parse_on(ctx, 0)
//
// The combinators of slang/peg interpret the grammar; this generates the
// code they would run for it, once. Every parser node reachable from the
// grammar's rules becomes straight-line code inlined into its parent,
// except nodes that are shared (several parents, rules, memoized nodes,
// dispatch candidates), which become functions. Each node is generated
// in the mode its parent needs: the value path, the fast path that only
// finds the end position (under flatten and lookaheads), or the tree
// path that also builds the lossless tree (ctx.tree, for the language
// server and the formatter). Actions (map, where), custom parsers,
// regexes and the walker's callbacks stay what they are and are called
// through a table of statics. The generated code keeps the context
// contract of slang/peg (ctx.value, the farthest failure, rule_memo,
// skip_from/skip_to), so it reports the same failures and builds the
// same ASTs; only peg's "last failure" (ctx.fail_pos, ctx.fail_msg),
// which the grammar's parse never reads, is not recorded.
//
// The grammar installs the generated parsers as the targets of its rule
// references (see slang/grammar), so every parse under a grammar that
// was generated runs them, the tree parse included.
local str = require("slang/string")
local peg = require("slang/peg")
local hash = require("slang/hash")

local pegc = {}

local func quote(s){
  local out = {"\""}
  for(local i = 0; i < len(s); i = i + 1){
    local b = str.byte_at(s, i)
    if(b == '"'){ append(out, "\\\"") }
    else if(b == '\\'){ append(out, "\\\\") }
    else if(b == 10){ append(out, "\\n") }
    else if(b == 13){ append(out, "\\r") }
    else if(b == 9){ append(out, "\\t") }
    else if(b < 32){ append(out, concat("\\x", str.format("%02x", b))) }
    else { append(out, str.substring(s, i, i + 1)) }
  }
  append(out, "\"")
  return str.join(out, "")
}

// the fast path of a node is its value path when its action runs anyway
local value_only = {map: true, where: true, separated: true, star_lazy: true}

local func identifier_name(s){
  local out = {}
  for(local i = 0; i < len(s); i = i + 1){
    local c = str.byte_at(s, i)
    local ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or (c >= '0' and c <= '9')
    append(out, if(ok){ str.substring(s, i, i + 1) } else { "_" })
  }
  return str.join(out, "")
}

local Gen = {}
local gen_meta = {__index: Gen}

// ------------------------------------------------------------- the graph

// the node a reference stands for
local func target_of(p){
  for(p != null and (p.kind == "rule" or p.kind == "ref" or p.kind == "settable" or p.generated == true)){
    if(p.generated == true){
      // a reference installed with a generated parser: the grammar's own
      p = p.children[0]
    } else {
      if(p.target == null and p.kind == "ref"){ peg.resolve(p) }
      if(p.target == null and p.kind == "rule"){ p.lookup(p) }
      p = p.target
    }
  }
  return p
}

// the children a node's code runs (transparent kinds aside)
local func children_of(p, g){
  if(p.kind == "literal_token"){ return {p.children[0]} }
  if(p.kind == "dispatch"){
    local out = {}
    for(let local e in values(p.dispatch.all)){ append(out, e.parser) }
    return out
  }
  if(p.kind == "expression"){
    // the walker's entries: their operator parsers and the wrappers' closers
    local out = {}
    local w = g.expression_walker
    if(w != null and w.parser == p){
      for(let local e in values(w.sealed.nuds.all)){
        append(out, e.parser)
        if(e.right != null){ append(out, e.right) }
      }
      for(let local e in values(w.sealed.leds.all)){ append(out, e.parser) }
    }
    return out
  }
  return p.children or {}
}

func Gen.scan(self, roots){
  local parents = {}
  local stack = {}
  for(let local p in values(roots)){
    local t = target_of(p)
    parents[t] = 2     // rules are functions
    append(stack, t)
  }
  local seen = {}
  for(len(stack) > 0){
    local p = remove(stack, len(stack) - 1)
    if(seen[p] == null){
      seen[p] = true
      for(let local c in values(children_of(p, self.grammar))){
        local t = target_of(c)
        if(t == null){ error("pegc: unresolved reference in ", p.kind) }
        parents[t] = (parents[t] or 0) + 1
        append(stack, t)
      }
    }
  }
  self.parents = parents
}

// a shared node is inlined anyway (a copy per use) when it is small and
// not recursive: no call for identifiers, numbers, keywords
func Gen.is_function(self, p, mode){
  if(p.memoized == true or p.kind == "dispatch" or p.kind == "expression"){ return true }
  if(mode == "tree"){
    // the tree path is not inlined across shared nodes, and a big node
    // is a function even when used once: a function has 255 registers
    return (self.parents[p] or 2) > 1 or self:size_of(p) > self.tree_split
  }
  if((self.parents[p] or 2) <= 1){ return false }
  return self:size_of(p) > self.inline_limit
}

// the number of nodes p's code inlines; "infinite" when p reaches itself
// or a node that is a function anyway stops the count there
func Gen.size_of(self, p){
  local known = self.sizes[p]
  if(known != null){ return known }
  self.sizes[p] = 1000000       // provisionally recursive
  local n = 1
  for(let local c in values(children_of(p, self.grammar))){
    local t = target_of(c)
    if(t.memoized == true or t.kind == "dispatch" or t.kind == "expression"){
      n = n + 1
    } else {
      n = n + self:size_of(t)
    }
  }
  self.sizes[p] = n
  return n
}

// ------------------------------------------------------------- writing

func Gen.line(self, s){
  append(self.lines, concat(str.join(self.pad, ""), s))
}
func Gen.open(self, s){
  self:line(s)
  append(self.pad, "  ")
}
func Gen.close(self, s){
  remove(self.pad, len(self.pad) - 1)
  self:line(s or "}")
}
func Gen.temp(self, base){
  self.counter = self.counter + 1
  return concat(base, self.counter)
}
// S[k] for a value the generated code needs as it is; what describes
// it for the legend at the top of the source
func Gen.static(self, v, what){
  local k = self.static_ids[v]
  if(k == null){
    k = len(self.statics)
    append(self.statics, v)
    self.static_ids[v] = k
    local d = what
    if(d == null){
      if(type(v) == "string"){ d = concat("message ", quote(v)) }
      else if(type(v) == "function"){ d = "a function" }
      else if(type(v) == "table"){ d = "a table" }
      else { d = type(v) }
    }
    self.descriptions[k] = d
  }
  return concat("S[", k, "]")
}

// how generated code refers to a function of the tree group: a local, or
// a field of the table G when the group is too big for a frame's registers
func Gen.tree_ref(self, name){
  if(self.tabled){ return concat("G.", name) }
  return name
}

// the name of the function for node p in mode, generating it when new
func Gen.fn(self, p, mode){
  if(mode == "fast" and (value_only[p.kind] or (p.kind == "custom" and p.fast == p.parse_on))){ mode = "value" }
  local table = if(mode == "fast"){ self.fast_fns } else if(mode == "tree"){ self.tree_fns } else { self.value_fns }
  local name = table[p]
  if(name != null){ return if(mode == "tree"){ self:tree_ref(name) } else { name } }
  name = self:temp(if(mode == "fast"){ "f" } else if(mode == "tree"){ "T" } else { "n" })
  table[p] = name
  append(self.queue, {p: p, mode: mode, name: name})
  if(mode == "tree"){ return self:tree_ref(name) }
  return name
}


// ------------------------------------------------------------- nodes
//
// emit(p, mode, pos, r, v, t): statements that set r to the position
// after p at pos (a variable), or -1 (with the failure recorded). In
// value mode they set the variable v to p's value on success; in tree
// mode also t to p's node of the lossless tree (peg.Tree: {p, start,
// stop, kids?, value}), built as peg's tree paths build it. Values and
// trees travel in locals inside a generated function and through
// ctx.value and ctx.tree only between functions.

func Gen.emit(self, p, mode, pos, r, v, t){
  if(mode == "tree" and p.kind == "rule"){
    // a rule reference: its node wraps the rule's tree, with the owner
    // of the rule (the extension that defined it)
    local inner = self:temp("tr")
    self:line(concat("local ", inner))
    self:emit(p.target or target_of(p), mode, pos, r, v, inner)
    self:open(concat("if(", r, " >= 0){"))
    local owner = ""
    local entry = self.grammar.rule_table[p.rule_name]
    if(entry != null and entry.owner != null){ owner = concat(", owner: ", self:static(entry.owner, concat("the owner of the rule ", p.rule_name))) }
    self:line(concat(t, " = {p: ", self:static(p, concat("the rule ", p.rule_name)), ", start: ", pos, ", stop: ", r, ", kids: {", inner, "}", owner, ", value: ", v, "}"))
    self:close()
    return
  }
  p = target_of(p)
  if(self:is_function(p, mode)){
    self:line(concat(r, " = ", self:fn(p, mode), "(ctx, ", pos, ")"))
    if(mode != "fast"){ self:line(concat(v, " = ctx.value")) }
    if(mode == "tree"){ self:line(concat(t, " = ctx.tree")) }
    self:resync()
    return
  }
  self:emit_inline(p, mode, pos, r, v, t)
}

// the failure bookkeeping, inline: only the farthest failure is kept
// (peg's last failure, fail_pos/fail_msg, is read by nothing the
// grammar's parse uses); with far_cache the farthest position is a
// local of the function, re-read after every call
func Gen.emit_fail(self, pos, msg){
  if(self.far_cache){
    self:open(concat("if(", pos, " > far){"))
    self:line(concat("far = ", pos))
  } else {
    self:open(concat("if(", pos, " > ctx.far_pos){"))
  }
  self:line(concat("ctx.far_pos = ", pos))
  self:line(concat("ctx.far_msg = ", msg))
  self:close()
}

// after a call: the callee may have moved the farthest failure
func Gen.resync(self){
  if(self.far_cache){ self:line("far = ctx.far_pos") }
}

func Gen.else_branch(self, s){
  self:close(s or "} else {")
  append(self.pad, "  ")
}

// the parser as a static, for the p of its tree nodes
func Gen.parser_ref(self, p){
  return self:static(p, concat("a ", p.kind, " parser"))
}

// t = a leaf of p from pos to r, with value v
func Gen.emit_leaf(self, p, pos, r, v, t){
  self:line(concat(t, " = {p: ", self:parser_ref(p), ", start: ", pos, ", stop: ", r, ", value: ", v, "}"))
}

// t = the node of p over kids (a list literal's inside), with value v
func Gen.emit_node(self, p, pos, r, v, t, kids, extra){
  self:line(concat(t, " = {p: ", self:parser_ref(p), ", start: ", pos, ", stop: ", r, ", kids: ", kids, extra or "", ", value: ", v, "}"))
}

func Gen.emit_inline(self, p, mode, pos, r, v, t){
  local k = p.kind
  local tree = mode == "tree"
  local value = mode != "fast"
  if(value_only[k]){ value = true }
  if(value and v == null){
    // a value nobody asked for (an action under a fast parent)
    v = self:temp("v")
    self:line(concat("local ", v))
  }
  local child_mode = if(tree){ "tree" } else if(value){ "value" } else { "fast" }
  if(k == "string"){
    local s = p.literal
    self:open(concat("if(starts_with(buf, ", quote(s), ", ", pos, ")){"))
    if(value){ self:line(concat(v, " = ", quote(s))) }
    self:line(concat(r, " = ", pos, " + ", len(s)))
    if(tree){ self:emit_leaf(p, pos, r, v, t) }
    self:else_branch()
    self:emit_fail(pos, self:string_message(p))
    self:line(concat(r, " = -1"))
    self:close()
    return
  }
  if(k == "pattern" or k == "whitespace"){
    local re = self:static(if(k == "pattern"){ p.class } else { self.space_char },
      if(k == "pattern"){ concat("the class [", p.spec, "]") } else { "the whitespace class" })
    self:line(concat(r, " = match_at(", re, ", buf, ", pos, ")"))
    self:open(concat("if(", r, " >= 0){"))
    if(value){ self:line(concat(v, " = substring(buf, ", pos, ", ", r, ")")) }
    if(tree){ self:emit_leaf(p, pos, r, v, t) }
    self:else_branch()
    self:emit_fail(pos, self:static(self:message_of(p)))
    self:line(concat(r, " = -1"))
    self:close()
    return
  }
  if(k == "any"){
    local n = self:temp("n")
    self:line(concat("local ", n, " = size_at(buf, ", pos, ")"))
    self:open(concat("if(", n, " > 0){"))
    if(value){ self:line(concat(v, " = substring(buf, ", pos, ", ", pos, " + ", n, ")")) }
    self:line(concat(r, " = ", pos, " + ", n))
    if(tree){ self:emit_leaf(p, pos, r, v, t) }
    self:else_branch()
    self:emit_fail(pos, self:static(self:message_of(p)))
    self:line(concat(r, " = -1"))
    self:close()
    return
  }
  if(k == "end"){
    self:open(concat("if(", pos, " == ctx.len){"))
    if(value){ self:line(concat(v, " = null")) }
    self:line(concat(r, " = ", pos))
    if(tree){ self:emit_leaf(p, pos, r, v, t) }
    self:else_branch()
    self:emit_fail(pos, self:static(self:message_of(p)))
    self:line(concat(r, " = -1"))
    self:close()
    return
  }
  if(k == "epsilon"){
    if(value){ self:line(concat(v, " = ", self:static_value(p))) }
    self:line(concat(r, " = ", pos))
    if(tree){ self:emit_leaf(p, pos, r, v, t) }
    return
  }
  if(k == "failure"){
    self:emit_fail(pos, self:static(self:message_of(p)))
    self:line(concat(r, " = -1"))
    return
  }
  if(k == "seq"){ return self:emit_seq(p, child_mode, pos, r, v, t) }
  if(k == "choice"){
    for(local i = 0; i < len(p.children); i = i + 1){
      if(i == 0){
        self:emit(p.children[0], child_mode, pos, r, v, t)
      } else {
        self:open(concat("if(", r, " < 0){"))
        self:emit(p.children[i], child_mode, pos, r, v, t)
        self:close()
      }
    }
    return
  }
  if(k == "star" or k == "plus"){ return self:emit_star(p, child_mode, pos, r, v, t) }
  if(k == "optional"){
    local tc = null
    if(tree){
      tc = self:temp("tr")
      self:line(concat("local ", tc))
    }
    self:emit(p.children[0], child_mode, pos, r, v, tc)
    self:open(concat("if(", r, " < 0){"))
    if(value){ self:line(concat(v, " = ", self:static_value_of(p.default_value))) }
    self:line(concat(r, " = ", pos))
    if(tree){ self:emit_node(p, pos, pos, v, t, "{}") }
    if(tree){
      self:else_branch()
      self:emit_node(p, pos, r, v, t, concat("{", tc, "}"))
    }
    self:close()
    return
  }
  if(k == "star_lazy"){ return self:emit_star_lazy(p, tree, pos, r, v, t) }
  if(k == "separated"){ return self:emit_separated(p, tree, pos, r, v, t) }
  if(k == "forbid" or k == "and"){
    local la = self:temp("la")
    self:line(concat("local ", la))
    self:emit(p.children[0], "fast", pos, la)
    if(k == "forbid"){
      self:open(concat("if(", la, " >= 0){"))
      self:emit_fail(pos, self:static(self:message_of(p)))
      self:line(concat(r, " = -1"))
    } else {
      self:open(concat("if(", la, " < 0){"))
      self:line(concat(r, " = -1"))
    }
    self:else_branch()
    if(value){ self:line(concat(v, " = null")) }
    self:line(concat(r, " = ", pos))
    if(tree){ self:emit_leaf(p, pos, pos, v, t) }
    self:close()
    return
  }
  if(k == "neg"){
    local la = self:temp("la")
    self:line(concat("local ", la))
    self:emit(p.children[0], "fast", pos, la)
    self:open(concat("if(", la, " >= 0){"))
    self:emit_fail(pos, self:static(self:message_of(p)))
    self:line(concat(r, " = -1"))
    self:else_branch()
    local n = self:temp("n")
    self:line(concat("local ", n, " = size_at(buf, ", pos, ")"))
    self:open(concat("if(", n, " > 0){"))
    if(value){ self:line(concat(v, " = substring(buf, ", pos, ", ", pos, " + ", n, ")")) }
    self:line(concat(r, " = ", pos, " + ", n))
    if(tree){ self:emit_leaf(p, pos, r, v, t) }
    self:else_branch()
    self:emit_fail(pos, quote("input expected"))
    self:line(concat(r, " = -1"))
    self:close()
    self:close()
    return
  }
  // the kinds whose node has their child's as its one kid
  local tc = null
  if(tree){
    tc = self:temp("tr")
    self:line(concat("local ", tc))
  }
  if(k == "pick"){
    self:emit(p.children[0], child_mode, pos, r, v, tc)
    self:open(concat("if(", r, " >= 0){"))
    if(value){
      local index = p.index
      if(index < 0){
        self:line(concat(v, " = ", v, "[len(", v, ") ", index, "]"))
      } else {
        self:line(concat(v, " = ", v, "[", index, "]"))
      }
    }
    if(tree){ self:emit_node(p, pos, r, v, t, concat("{", tc, "}")) }
    self:close()
    return
  }
  if(k == "permute"){
    self:emit(p.children[0], child_mode, pos, r, v, tc)
    self:open(concat("if(", r, " >= 0){"))
    if(value){
      local parts = {}
      for(let local index in values(p.indices)){
        if(index < 0){ append(parts, concat(v, "[len(", v, ") ", index, "]")) }
        else { append(parts, concat(v, "[", index, "]")) }
      }
      self:line(concat(v, " = {", str.join(parts, ", "), "}"))
    }
    if(tree){ self:emit_node(p, pos, r, v, t, concat("{", tc, "}")) }
    self:close()
    return
  }
  if(k == "map"){
    self:emit(p.children[0], if(tree){ "tree" } else { "value" }, pos, r, v, tc)
    self:open(concat("if(", r, " >= 0){"))
    self:line(concat(v, " = ", self:static(p.fn, "an action (map)"), "(", v, ")"))
    if(tree){ self:emit_node(p, pos, r, v, t, concat("{", tc, "}")) }
    self:close()
    return
  }
  if(k == "where"){
    self:emit(p.children[0], if(tree){ "tree" } else { "value" }, pos, r, v, tc)
    self:open(concat("if(", r, " >= 0){"))
    self:open(concat("if(not ", self:static(p.predicate, "a predicate (where)"), "(", v, ")){"))
    self:emit_fail(pos, self:static(p.message))
    self:line(concat(r, " = -1"))
    if(tree){
      self:else_branch()
      self:emit_node(p, pos, r, v, t, concat("{", tc, "}"))
    }
    self:close()
    self:close()
    return
  }
  if(k == "flatten"){
    self:emit(p.children[0], "fast", pos, r)
    if(value){
      self:open(concat("if(", r, " >= 0){"))
      self:line(concat(v, " = substring(buf, ", pos, ", ", r, ")"))
      if(tree){
        self:line(concat(t, " = raw_leaf(", self:parser_ref(p), ", ctx, ", pos, ", ", r, ")"))
        self:line(concat(t, ".value = ", v))
      }
      if(p.message != null){
        self:else_branch()
        self:emit_fail(pos, self:static(p.message))
      }
      self:close()
    } else if(p.message != null){
      self:open(concat("if(", r, " < 0){"))
      self:emit_fail(pos, self:static(p.message))
      self:close()
    }
    return
  }
  if(k == "token"){
    self:emit(p.children[0], child_mode, pos, r, v, tc)
    if(value){
      self:open(concat("if(", r, " >= 0){"))
      local category = ""
      if(type(p.category) == "string"){ category = concat(", category: ", quote(p.category)) }
      self:line(concat(v, " = {value: ", v, ", start: ", pos, ", stop: ", r, ", buffer: buf", category, ", @meta: TM}"))
      if(tree){ self:emit_node(p, pos, r, v, t, concat("{", tc, "}")) }
      self:close()
    }
    return
  }
  if(k == "trim"){ return self:emit_trim(p, child_mode, pos, r, v, t) }
  if(k == "literal_token"){
    // the direct form assumes slang's own trivia, as the grammar's does
    if(tree or self.grammar.native_trivia == false){ return self:emit(p.children[0], child_mode, pos, r, v, t) }
    return self:emit_literal_token(p, mode, pos, r, v)
  }
  if(k == "tag" or k == "layer"){
    self:emit(children_of(p, self.grammar)[0], child_mode, pos, r, v, tc)
    if(tree){
      self:open(concat("if(", r, " >= 0){"))
      self:emit_node(p, pos, r, v, t, concat("{", tc, "}"))
      self:close()
    }
    return
  }
  if(k == "custom"){
    if(p.trivia){
      // slang's trivia: one native call, no failure recorded
      self:line(concat(r, " = match_at(SPACE, buf, ", pos, ")"))
      self:open(concat("if(", r, " == ", pos, "){"))
      self:line(concat(r, " = -1"))
      self:else_branch()
      if(value){ self:line(concat(v, " = null")) }
      if(tree){
        self:line(concat(t, " = raw_leaf(", self:parser_ref(p), ", ctx, ", pos, ", ", r, ")"))
        self:line(concat(t, ".value = null"))
      }
      self:close()
      return
    }
    local s = self:static(p, "a custom parser")
    if(tree){
      self:line(concat(r, " = parse_tree(", s, ", ctx, ", pos, ")"))
      self:line(concat(v, " = ctx.value"))
      self:line(concat(t, " = ctx.tree"))
    } else {
      local f = if(mode == "fast" and p.fast != p.parse_on){ "fast" } else { "parse_on" }
      self:line(concat(r, " = ", s, ".", f, "(", s, ", ctx, ", pos, ")"))
      if(value){ self:line(concat(v, " = ctx.value")) }
    }
    self:resync()
    return
  }
  if(k == "dispatch"){ return self:emit_dispatch(p, mode, pos, r, v, t) }
  if(k == "expression"){
    if(tree){
      self:line(concat(r, " = ", self:walker_fn(p, "tree"), "(ctx, ", pos, ", 0)"))
    } else {
      self:line(concat(r, " = ", self:walker_fn(p, "value"), "(ctx, ", pos, ", 0)"))
    }
    if(value){ self:line(concat(v, " = ctx.value")) }
    if(tree){ self:line(concat(t, " = ctx.tree")) }
    self:resync()
    return
  }
  error("pegc: cannot generate a ", k, " parser")
}

// a keyword or punctuation token as the grammar's literal_token parses
// it: trivia, the literal, no word character after a word, the token,
// trivia; its composed child says what the pieces are
func Gen.emit_literal_token(self, p, mode, pos, r, v){
  local composed = target_of(p.children[0])
  local inner = target_of(composed.children[0])     // trim's child: the token
  local category = inner.category
  local literal = target_of(inner.children[0])
  local forbid = null
  if(literal.kind == "pick"){
    local seq = target_of(literal.children[0])
    forbid = target_of(seq.children[1])
    literal = target_of(seq.children[0])
  }
  if(literal.kind != "string"){ return self:emit(composed, mode, pos, r, v) }
  local s = literal.literal
  local start = self:temp("p")
  local stop = self:temp("p")
  self:line(concat("local ", start, " = match_at(SPACE, buf, ", pos, ")"))
  self:open(concat("if(not starts_with(buf, ", quote(s), ", ", start, ")){"))
  self:emit_fail(start, self:string_message(literal))
  self:line(concat(r, " = -1"))
  self:else_branch()
  self:line(concat("local ", stop, " = ", start, " + ", len(s)))
  if(forbid != null){
    local cls = self:static(target_of(forbid.children[0]).class, "the word character class")
    self:open(concat("if(match_at(", cls, ", buf, ", stop, ") >= 0){"))
    self:emit_fail(stop, quote("success not expected"))
    self:line(concat(r, " = -1"))
    self:else_branch()
  }
  if(mode == "value"){
    local cat = ""
    if(type(category) == "string"){ cat = concat(", category: ", quote(category)) }
    self:line(concat(v, " = {value: ", quote(s), ", start: ", start, ", stop: ", stop, ", buffer: buf", cat, ", @meta: TM}"))
  }
  self:line(concat(r, " = match_at(SPACE, buf, ", stop, ")"))
  if(forbid != null){ self:close() }
  self:close()
}

// the message a primitive fails with is captured in its closure: it is
// recovered by running the parser on an empty input
func Gen.message_of(self, p){
  local m = self.messages[p]
  if(m == null){
    local ctx = peg.context("")
    if(p.kind == "any" or p.kind == "pattern" or p.kind == "whitespace" or p.kind == "neg" or p.kind == "failure"){
      p.fast(p, ctx, 0)
    } else if(p.kind == "end"){
      ctx = peg.context("x")
      p.parse_on(p, ctx, 0)
    } else if(p.kind == "forbid"){
      m = "success not expected"
    }
    if(m == null){ m = ctx.fail_msg or "unexpected input" }
    self.messages[p] = m
  }
  return m
}

func Gen.string_message(self, p){
  local m = self.messages[p]
  if(m == null){
    local ctx = peg.context("")
    p.parse_on(p, ctx, 0)
    m = ctx.fail_msg
    self.messages[p] = m
  }
  return self:static(m)
}

func Gen.static_value(self, p){
  local ctx = peg.context("")
  p.parse_on(p, ctx, 0)
  return self:static_value_of(ctx.value)
}

func Gen.static_value_of(self, v){
  if(v == null){ return "null" }
  if(type(v) == "string"){ return quote(v) }
  if(type(v) == "int" or type(v) == "bool"){ return string(v) }
  return self:static(v)
}

func Gen.emit_seq(self, p, mode, pos, r, v, t){
  local n = len(p.children)
  local value = mode != "fast"
  local tree = mode == "tree"
  self:line(concat(r, " = -1"))
  local vars = {}
  local trees = {}
  local at = pos
  for(local i = 0; i < n; i = i + 1){
    local q = self:temp("q")
    local vi = null
    local ti = null
    self:line(concat("local ", q))
    if(value){
      vi = self:temp("v")
      self:line(concat("local ", vi))
      append(vars, vi)
    }
    if(tree){
      ti = self:temp("tr")
      self:line(concat("local ", ti))
      append(trees, ti)
    }
    self:emit(p.children[i], mode, at, q, vi, ti)
    self:open(concat("if(", q, " >= 0){"))
    at = q
  }
  if(value){ self:line(concat(v, " = {", str.join(vars, ", "), "}")) }
  self:line(concat(r, " = ", at))
  if(tree){ self:emit_node(p, pos, r, v, t, concat("{", str.join(trees, ", "), "}")) }
  for(local i = 0; i < n; i = i + 1){ self:close() }
}

func Gen.emit_star(self, p, mode, pos, r, v, t){
  local child = target_of(p.children[0])
  local value = mode != "fast"
  local tree = mode == "tree"
  if(not value and child.kind == "pattern"){
    local run = self:static(child.run, concat("the run [", child.spec, "]*"))
    self:line(concat(r, " = match_at(", run, ", buf, ", pos, ")"))
    if(p.kind == "plus"){
      self:open(concat("if(", r, " == ", pos, "){"))
      self:emit_fail(pos, self:static(concat("[", child.spec, "] expected")))
      self:line(concat(r, " = -1"))
      self:close()
    }
    return
  }
  local vs = self:temp("vs")
  local ts = self:temp("ts")
  local at = self:temp("p")
  local q = self:temp("q")
  local vq = null
  local tq = null
  if(value){
    vq = self:temp("v")
    self:line(concat("local ", vs, " = {}"))
    self:line(concat("local ", vq))
  }
  if(tree){
    tq = self:temp("tr")
    self:line(concat("local ", ts, " = {}"))
    self:line(concat("local ", tq))
  }
  self:line(concat("local ", at, " = ", pos))
  self:line(concat("local ", q))
  local func loop(){
    self:open("for(true){")
    self:emit(child, mode, at, q, vq, tq)
    self:line(concat("if(", q, " < 0 or ", q, " == ", at, "){ break }"))
    if(value){ self:line(concat("append(", vs, ", ", vq, ")")) }
    if(tree){ self:line(concat("append(", ts, ", ", tq, ")")) }
    self:line(concat(at, " = ", q))
    self:close()
    if(value){ self:line(concat(v, " = ", vs)) }
    self:line(concat(r, " = ", at))
    if(tree){ self:emit_node(p, pos, r, v, t, ts) }
  }
  if(p.kind == "plus"){
    self:emit(child, mode, at, q, vq, tq)
    self:open(concat("if(", q, " < 0){"))
    self:line(concat(r, " = -1"))
    self:else_branch()
    if(value){ self:line(concat("append(", vs, ", ", vq, ")")) }
    if(tree){ self:line(concat("append(", ts, ", ", tq, ")")) }
    self:line(concat(at, " = ", q))
    loop()
    self:close()
  } else {
    loop()
  }
}

func Gen.emit_star_lazy(self, p, tree, pos, r, v, t){
  local vs = self:temp("vs")
  local ts = self:temp("ts")
  local at = self:temp("p")
  local q = self:temp("q")
  local la = self:temp("la")
  local vq = self:temp("v")
  local tq = null
  self:line(concat("local ", vs, " = {}"))
  if(tree){
    tq = self:temp("tr")
    self:line(concat("local ", ts, " = {}"))
    self:line(concat("local ", tq))
  }
  self:line(concat("local ", at, " = ", pos))
  self:line(concat("local ", q))
  self:line(concat("local ", la))
  self:line(concat("local ", vq))
  self:open("for(true){")
  self:emit(p.children[1], "fast", at, la)
  self:open(concat("if(", la, " >= 0){"))
  self:line(concat(v, " = ", vs))
  self:line(concat(r, " = ", at))
  if(tree){ self:emit_node(p, pos, r, v, t, ts) }
  self:line("break")
  self:close()
  self:emit(p.children[0], if(tree){ "tree" } else { "value" }, at, q, vq, tq)
  self:open(concat("if(", q, " < 0){"))
  self:line(concat(r, " = -1"))
  self:line("break")
  self:close()
  self:line(concat("append(", vs, ", ", vq, ")"))
  if(tree){ self:line(concat("append(", ts, ", ", tq, ")")) }
  self:line(concat(at, " = ", q))
  self:close()
}

func Gen.emit_separated(self, p, tree, pos, r, v, t){
  local mode = if(tree){ "tree" } else { "value" }
  local es = self:temp("es")
  local ss = self:temp("ss")
  local ts = self:temp("ts")
  local at = self:temp("p")
  local q = self:temp("q")
  local ve = self:temp("v")
  local vsep = self:temp("v")
  local te = null
  local tsep = null
  local r2 = self:temp("r")
  self:line(concat("local ", es, " = {}"))
  self:line(concat("local ", ss, " = {}"))
  if(tree){
    te = self:temp("tr")
    tsep = self:temp("tr")
    self:line(concat("local ", ts, " = {}"))
    self:line(concat("local ", te))
    self:line(concat("local ", tsep))
  }
  self:line(concat("local ", at, " = ", pos))
  self:line(concat("local ", q))
  self:line(concat("local ", ve))
  self:emit(p.children[0], mode, at, q, ve, te)
  self:open(concat("if(", q, " < 0){"))
  if(p.at_least_one){
    self:line(concat(r, " = -1"))
  } else {
    self:line(concat(v, " = {elements: ", es, ", separators: ", ss, "}"))
    self:line(concat(r, " = ", at))
    if(tree){ self:emit_node(p, pos, pos, v, t, ts) }
  }
  self:else_branch()
  self:line(concat("append(", es, ", ", ve, ")"))
  if(tree){ self:line(concat("append(", ts, ", ", te, ")")) }
  self:line(concat(at, " = ", q))
  self:line(concat("local ", vsep))
  self:line(concat("local ", r2))
  self:open("for(true){")
  self:emit(p.children[1], mode, at, q, vsep, tsep)
  self:line(concat("if(", q, " < 0){ break }"))
  self:emit(p.children[0], mode, q, r2, ve, te)
  self:line(concat("if(", r2, " < 0){ break }"))
  self:line(concat("append(", ss, ", ", vsep, ")"))
  self:line(concat("append(", es, ", ", ve, ")"))
  if(tree){
    self:line(concat("append(", ts, ", ", tsep, ")"))
    self:line(concat("append(", ts, ", ", te, ")"))
  }
  self:line(concat(at, " = ", r2))
  self:close()
  self:line(concat(v, " = {elements: ", es, ", separators: ", ss, "}"))
  self:line(concat(r, " = ", at))
  if(tree){ self:emit_node(p, pos, r, v, t, ts) }
  self:close()
}

// the position after trimmer at pos, into out (trimmer: a parser); with
// kids, the trimmer's tree nodes go to that list (peg's consume_tree)
func Gen.emit_consume(self, trimmer, pos, out, kids){
  // the flags live on the reference (space.single) or its target
  // (trivia.single, trivia.trivia); in a tree the reference's node counts
  local target = target_of(trimmer)
  local single = trimmer.single or target.single
  if(target.trivia and kids == null){
    self:line(concat("local ", out, " = match_at(SPACE, buf, ", pos, ")"))
    return
  }
  if(kids == null){ trimmer = target }
  local far = self:temp("far")
  local msg = self:temp("msg")
  self:line(concat("local ", far, " = ctx.far_pos"))
  self:line(concat("local ", msg, " = ctx.far_msg"))
  local q = self:temp("q")
  local mode = if(kids != null){ "tree" } else { "fast" }
  local vq = null
  local tq = null
  if(kids != null){
    vq = self:temp("v")
    tq = self:temp("tr")
    self:line(concat("local ", vq))
    self:line(concat("local ", tq))
  }
  if(single){
    self:line(concat("local ", q))
    self:emit(trimmer, mode, pos, q, vq, tq)
    if(kids != null){ self:line(concat("if(", q, " >= 0 and ", q, " != ", pos, "){ append(", kids, ", ", tq, ") }")) }
    self:line(concat("local ", out, " = if(", q, " < 0){ ", pos, " } else { ", q, " }"))
  } else {
    self:line(concat("local ", out, " = ", pos))
    self:line(concat("local ", q))
    self:open("for(true){")
    self:emit(trimmer, mode, out, q, vq, tq)
    self:line(concat("if(", q, " < 0 or ", q, " == ", out, "){ break }"))
    if(kids != null){ self:line(concat("append(", kids, ", ", tq, ")")) }
    self:line(concat(out, " = ", q))
    self:close()
  }
  self:line(concat("ctx.far_pos = ", far))
  self:line(concat("ctx.far_msg = ", msg))
  self:resync()
}

func Gen.emit_trim(self, p, mode, pos, r, v, t){
  local tree = mode == "tree"
  local kids = null
  if(tree){
    kids = self:temp("kids")
    self:line(concat("local ", kids, " = {}"))
  }
  local p1 = self:temp("p")
  self:emit_consume(p.children[1], pos, p1, kids)
  local q = self:temp("q")
  local tc = null
  self:line(concat("local ", q))
  if(tree){
    tc = self:temp("tr")
    self:line(concat("local ", tc))
  }
  self:emit(p.children[0], mode, p1, q, v, tc)
  self:open(concat("if(", q, " < 0){"))
  self:line(concat(r, " = -1"))
  self:else_branch()
  local at = null
  if(tree){
    at = self:temp("at")
    self:line(concat("local ", at, " = len(", kids, ")"))
    self:line(concat("append(", kids, ", ", tc, ")"))
  }
  local p2 = self:temp("p")
  self:emit_consume(p.children[2], q, p2, kids)
  self:line(concat(r, " = ", p2))
  if(tree){ self:emit_node(p, pos, r, v, t, kids, concat(", at: ", at)) }
  self:close()
}

// ------------------------------------------------------------- dispatch and the walker

// cands = the candidate entries of dispatch d at pos (by first byte), into
// a variable: indexes into the entries' function tables
func Gen.emit_candidates(self, d, pos, cands){
  if(d.by_byte == null){
    self:line(concat("local ", cands, " = ", self:static(self:index_list(d.all, d.all), "all the candidates")))
    return
  }
  local skipped = self:temp("p")
  if(d.skip == peg.skip_space){
    self:line(concat("local ", skipped))
    self:open(concat("if(ctx.skip_from == ", pos, "){"))
    self:line(concat(skipped, " = ctx.skip_to"))
    self:close("} else {")
    append(self.pad, "  ")
    self:line(concat(skipped, " = match_at(SPACE, buf, ", pos, ")"))
    self:line(concat("ctx.skip_from = ", pos))
    self:line(concat("ctx.skip_to = ", skipped))
    self:close()
  } else {
    self:line(concat("local ", skipped, " = ", self:static(d.skip, "a skip function"), "(ctx, ", pos, ")"))
  }
  local b = self:temp("b")
  self:line(concat("local ", b, " = byte_at(buf, ", skipped, ")"))
  local by_byte = {}
  for(local i = 0; i < 128; i = i + 1){
    if(d.by_byte[i] != null){ by_byte[i] = self:index_list(d.by_byte[i], d.all) }
  }
  self:line(concat("local ", cands))
  self:open(concat("if(", b, " == null){"))
  self:line(concat(cands, " = ", self:static(self:index_list(d.at_end, d.all), "the candidates at the end of the input")))
  self:close(concat("} else if(", b, " < 128){"))
  append(self.pad, "  ")
  self:line(concat(cands, " = ", self:static(by_byte, "the candidates by first byte"), "[", b, "]"))
  self:close("} else {")
  append(self.pad, "  ")
  self:line(concat(cands, " = ", self:static(self:index_list(d.all, d.all), "all the candidates")))
  self:close()
}

// the indexes of entries in all
func Gen.index_list(self, list, all){
  local out = {}
  for(let local e in values(list)){
    for(local i = 0; i < len(all); i = i + 1){
      if(all[i] == e){ append(out, i) }
    }
  }
  return out
}

// a table of the entries' parser functions in mode, assigned at the end
func Gen.entry_table(self, entries, mode){
  local fns = self:temp("fns")
  local names = {}
  for(let local e in values(entries)){
    local p = e.parser
    if(mode == "tree" and p.kind == "rule"){
      // the rule reference adds its node: as a function of its own
      append(names, self:ref_fn(p))
    } else {
      append(names, self:fn(target_of(p), mode))
    }
  }
  local ref = fns
  if(mode == "tree"){ ref = self:tree_ref(fns) }
  append(self.tables, {mode: mode, text: concat(ref, " = {", str.join(names, ", "), "}"), name: fns})
  return ref
}

// a rule reference's tree path as a function (the node around the rule)
func Gen.ref_fn(self, p){
  local name = self.ref_fns[p]
  if(name == null){
    name = self:temp("R")
    self.ref_fns[p] = name
    append(self.ref_queue, {p: p, name: name})
  }
  return self:tree_ref(name)
}

func Gen.generate_ref(self, item){
  self:line(concat("// the reference to the rule ", item.p.rule_name, ", tree path"))
  self:open(concat(self:tree_ref(item.name), " = func(ctx, pos){"))
  self:line("local buf = ctx.buffer")
  if(self.far_cache){ self:line("local far = ctx.far_pos") }
  self:line("local r")
  self:line("local v")
  self:line("local t")
  self:emit(item.p, "tree", "pos", "r", "v", "t")
  self:line("if(r >= 0){ ctx.value = v ctx.tree = t }")
  self:line("return r")
  self:close()
}

func Gen.emit_dispatch(self, p, mode, pos, r, v, t){
  local d = p.dispatch
  local fns = self:entry_table(d.all, if(mode == "fast"){ "value" } else { mode })
  local cands = self:temp("cands")
  self:emit_candidates(d, pos, cands)
  self:line(concat(r, " = -1"))
  self:open(concat("if(", cands, " == null){"))
  self:line("ctx.tried = false")
  if(p.message != null){ self:emit_fail("ctx.skip_to", self:static(p.message)) }
  self:else_branch()
  self:line("ctx.tried = true")
  local i = self:temp("i")
  self:open(concat("for(local ", i, " = 0; ", i, " < len(", cands, "); ", i, " = ", i, " + 1){"))
  self:line(concat(r, " = ", fns, "[", cands, "[", i, "]](ctx, ", pos, ")"))
  self:line(concat("if(", r, " >= 0){ break }"))
  self:close()
  if(v != null){ self:line(concat(v, " = ctx.value")) }
  if(mode == "tree"){ self:line(concat(t, " = ctx.tree")) }
  self:resync()
  self:close()
}

// the walker's parse_at as a function (ctx, pos, min_bp), in value or
// tree mode (parse_at_tree)
func Gen.walker_fn(self, p, mode){
  local table = if(mode == "tree"){ self.tree_walkers } else { self.walkers }
  local name = table[p]
  if(name == null){
    name = self:temp(if(mode == "tree"){ "W" } else { "w" })
    table[p] = name
    append(self.walker_queue, {p: p, name: name, mode: mode})
  }
  if(mode == "tree"){ return self:tree_ref(name) }
  return name
}

func Gen.generate_walker(self, p, name, mode){
  local tree = mode == "tree"
  self:line(concat("// the expression walker: parse_at", if(tree){ "_tree" } else { "" }, "(ctx, pos, min_bp)"))
  local w = self.grammar.expression_walker
  if(w == null or w.parser != p){ error("pegc: the expression parser is not the grammar's walker's") }
  if(len(w.nuds) > 0 or len(w.leds) > 0){ error("pegc: engine entries (nud/led) are not supported") }
  local sealed = w.sealed
  local nuds = sealed.nuds.all
  local leds = sealed.leds.all
  // one function per entry: nud_k(ctx, pos) -> q (value in ctx.value, in
  // tree mode the node in ctx.tree); led_k(ctx, pos, left, left_tree) ->
  // q, -1 (operator absent) or -2 (operand failed)
  local self_ref = if(tree){ self:tree_ref(name) } else { name }
  local func op_parser(e){
    if(tree and e.parser.kind == "rule"){ return self:ref_fn(e.parser) }
    return self:fn(target_of(e.parser), mode)
  }
  local func entry_node(e, start, stop, kids){
    return concat("ctx.tree = {p: ", self:static(e, concat("the walker's ", e.form or e.kind, " entry")), ", start: ", start, ", stop: ", stop, ", kids: ", kids, ", value: ctx.value}")
  }
  local nud_names = {}
  local first_primary = len(nuds)
  for(local k = 0; k < len(nuds); k = k + 1){
    local e = nuds[k]
    local fname = self:temp(if(tree){ "nudt" } else { "nud" })
    append(nud_names, if(tree){ self:tree_ref(fname) } else { fname })
    local parser = op_parser(e)
    if(e.kind == "primary"){
      if(k < first_primary){ first_primary = k }
      append(self.entry_fns, {name: fname, mode: mode, params: "ctx, pos", lines: {concat("return ", parser, "(ctx, pos)")}})
    } else if(e.kind == "prefix"){
      local lines = {
        concat("local r = ", parser, "(ctx, pos)"),
        "if(r < 0){ return -1 }",
        "local op = ctx.value",
      }
      if(tree){ append(lines, "local op_tree = ctx.tree") }
      append(lines, concat("r = ", self_ref, "(ctx, r, ", e.bp, ")"))
      append(lines, "if(r < 0){ return -1 }")
      if(tree){ append(lines, "local operand_tree = ctx.tree") }
      append(lines, concat("ctx.value = ", self:static(e.callback, "a prefix operator's callback"), "(op, ctx.value)"))
      if(tree){ append(lines, entry_node(e, "pos", "r", "{op_tree, operand_tree}")) }
      append(lines, "return r")
      append(self.entry_fns, {name: fname, mode: mode, params: "ctx, pos", lines: lines})
    } else if(e.kind == "wrapper"){
      local right = if(tree and e.right.kind == "rule"){ self:ref_fn(e.right) } else { self:fn(target_of(e.right), mode) }
      local lines = {
        concat("local r = ", parser, "(ctx, pos)"),
        "if(r < 0){ return -1 }",
        "local open = ctx.value",
      }
      if(tree){ append(lines, "local op_tree = ctx.tree") }
      append(lines, concat("r = ", self_ref, "(ctx, r, 0)"))
      append(lines, "if(r < 0){ return -1 }")
      append(lines, "local value = ctx.value")
      if(tree){ append(lines, "local inner_tree = ctx.tree") }
      append(lines, concat("local q = ", right, "(ctx, r)"))
      append(lines, "if(q < 0){ return -1 }")
      if(tree){ append(lines, "local right_tree = ctx.tree") }
      append(lines, concat("ctx.value = ", self:static(e.callback, "a wrapper's callback"), "(open, value, ctx.value)"))
      if(tree){ append(lines, entry_node(e, "pos", "q", "{op_tree, inner_tree, right_tree}")) }
      append(lines, "return q")
      append(self.entry_fns, {name: fname, mode: mode, params: "ctx, pos", lines: lines})
    } else {
      error("pegc: unknown nud kind ", e.kind)
    }
  }
  local led_names = {}
  local lbps = {}
  for(local k = 0; k < len(leds); k = k + 1){
    local e = leds[k]
    local fname = self:temp(if(tree){ "ledt" } else { "led" })
    append(led_names, if(tree){ self:tree_ref(fname) } else { fname })
    append(lbps, e.lbp)
    local parser = op_parser(e)
    local callback = self:static(e.callback, concat("a ", e.form, " operator's callback"))
    local lines = {concat("local r = ", parser, "(ctx, pos)"), "if(r < 0){ return -1 }", "local op = ctx.value"}
    if(tree){ append(lines, "local op_tree = ctx.tree") }
    if(e.form == "postfix"){
      append(lines, concat("ctx.value = ", callback, "(left, op)"))
      if(tree){ append(lines, entry_node(e, "left_tree.start", "r", "{left_tree, op_tree}")) }
      append(lines, "return r")
    } else if(e.form == "right" or e.form == "left"){
      append(lines, concat("r = ", self_ref, "(ctx, r, ", e.rbp, ")"))
      append(lines, "if(r < 0){ return -2 }")
      if(tree){ append(lines, "local right_tree = ctx.tree") }
      append(lines, concat("ctx.value = ", callback, "(left, op, ctx.value)"))
      if(tree){ append(lines, entry_node(e, "left_tree.start", "r", "{left_tree, op_tree, right_tree}")) }
      append(lines, "return r")
    } else {
      error("pegc: unknown led form ", e.form)
    }
    append(self.entry_fns, {name: fname, mode: mode, params: "ctx, pos, left, left_tree", lines: lines})
  }
  local nud_table = self:temp("nuds")
  local led_table = self:temp("leds")
  local nud_ref = nud_table
  local led_ref = led_table
  if(tree){
    nud_ref = self:tree_ref(nud_table)
    led_ref = self:tree_ref(led_table)
  }
  append(self.tables, {mode: mode, text: concat(nud_ref, " = {", str.join(nud_names, ", "), "}"), name: nud_table})
  append(self.tables, {mode: mode, text: concat(led_ref, " = {", str.join(led_names, ", "), "}"), name: led_table})
  local lbp_table = self:static(lbps, "the left binding powers of the operators")
  self:open(concat(self_ref, " = func(ctx, pos, min_bp){"))
  self:line("local buf = ctx.buffer")
  local cands = self:temp("cands")
  self:emit_candidates(sealed.nuds, "pos", cands)
  self:line("local value = null")
  if(tree){ self:line("local tree = null") }
  self:line("local q = -1")
  self:line("local tried_primary = false")
  self:open(concat("if(", cands, " != null){"))
  self:open(concat("for(local i = 0; i < len(", cands, "); i = i + 1){"))
  self:line(concat("local e = ", cands, "[i]"))
  self:line(concat("if(e >= ", first_primary, "){ tried_primary = true }"))
  self:line(concat("local r = ", nud_ref, "[e](ctx, pos)"))
  self:line(concat("if(r >= 0){ value = ctx.value ", if(tree){ "tree = ctx.tree " } else { "" }, "q = r break }"))
  self:close()
  self:close()
  self:open("if(q < 0){")
  self:line(concat("if(not tried_primary and pos > ctx.far_pos){ ctx.far_pos = pos ctx.far_msg = ", quote("expression expected"), " }"))
  self:line("return -1")
  self:close()
  self:open("for(true){")
  local lc = self:temp("lc")
  self:emit_candidates(sealed.leds, "q", lc)
  self:line(concat("if(", lc, " == null){ break }"))
  self:line("local matched = false")
  self:line(concat("local n = len(", lc, ")"))
  self:line("local i = 0")
  self:open("for(i < n){")
  self:line(concat("local e = ", lc, "[i]"))
  self:line(concat("local lbp = ", lbp_table, "[e]"))
  self:line("if(lbp <= min_bp){ break }")
  self:line(concat("local r = ", led_ref, "[e](ctx, q, value", if(tree){ ", tree" } else { "" }, ")"))
  self:open("if(r >= 0){")
  self:line(concat("value = ctx.value ", if(tree){ "tree = ctx.tree " } else { "" }, "q = r matched = true break"))
  self:close("} else if(r == -2){")
  append(self.pad, "  ")
  self:line(concat("for(i < n and ", lbp_table, "[", lc, "[i]] == lbp){ i = i + 1 }"))
  self:close("} else {")
  append(self.pad, "  ")
  self:line("i = i + 1")
  self:close()
  self:close()
  self:line("if(not matched){ break }")
  self:close()
  self:line("ctx.value = value")
  if(tree){ self:line("ctx.tree = tree") }
  self:line("return q")
  self:close()
}

// ------------------------------------------------------------- functions

func Gen.generate_function(self, item){
  local p = item.p
  local mode = item.mode
  local tree = mode == "tree"
  local defined = if(tree){ self:tree_ref(item.name) } else { item.name }
  if(item.rule != null){
    self:line(concat("// the rule ", item.rule, if(tree){ ", tree path" } else { "" }))
  } else {
    local why = if(p.memoized){ "memoized" } else { concat("shared by ", self.parents[p] or "?", " parents") }
    self:line(concat("// a ", p.kind, " (", why, if(mode == "fast"){ ", fast path)" } else if(tree){ ", tree path)" } else { ")" }))
  }
  self:open(concat(defined, " = func(ctx, pos){"))
  self:line("local buf = ctx.buffer")
  if(self.far_cache){ self:line("local far = ctx.far_pos") }
  if(p.memoized){
    // the memo table is the parser's (by its id, shared with the
    // combinators); the id is a static, so that the generated text does
    // not depend on the order parsers were made in
    local id = self:static(p.id, "the id of a memoized parser")
    self:line(concat("local t = ctx.rule_memo[", id, "]"))
    self:line(concat("if(t == null){ t = {} ctx.rule_memo[", id, "] = t }"))
    self:line("local hit = t[pos]")
    if(mode == "value"){
      self:open("if(hit != null and hit.has_value){")
    } else if(tree){
      self:open("if(hit != null and hit.has_value and (hit.stop < 0 or hit.tree != null)){")
    } else {
      self:open("if(hit != null){")
    }
    self:line("if(hit.stop < 0){ return -1 }")
    if(mode != "fast"){ self:line("ctx.value = hit.value") }
    if(tree){ self:line("ctx.tree = hit.tree") }
    self:line("return hit.stop")
    self:close()
  }
  self:line("local r")
  if(mode != "fast"){ self:line("local v") }
  if(tree){ self:line("local tr") }
  self:emit_inline(p, mode, "pos", "r", "v", "tr")
  if(p.memoized){
    self:open("if(r < 0){")
    self:line("t[pos] = {stop: -1, has_value: true}")
    self:else_branch()
    if(mode == "value"){
      self:line("t[pos] = {stop: r, has_value: true, value: v}")
    } else if(tree){
      self:line("t[pos] = {stop: r, has_value: true, value: v, tree: tr}")
    } else {
      self:line("t[pos] = {stop: r, has_value: false}")
    }
    self:close()
  }
  if(mode == "value"){ self:line("if(r >= 0){ ctx.value = v }") }
  if(tree){ self:line("if(r >= 0){ ctx.value = v ctx.tree = tr }") }
  self:line("return r")
  self:close()
}

// ------------------------------------------------------------- entry point

// compile(g: Grammar, options?: {inline: int, far_cache: bool, tree: bool}) -> {source, statics, load}
// g must have parsed once (it is sealed). The result's load() returns
// {rules: {name: func(ctx, pos)}, trees: {name: func(ctx, pos)}, fasts:
// {name: func(ctx, pos)?}}: the generated parser of every rule as the
// rule's parse_on, parse_tree (with tree) and fast would be called.
// [far_cache]: keeps the farthest failure position in a local per
// function, re-read after calls (on by default; false compares against
// ctx.far_pos at every failure)
// [inline]: shared nodes of up to this many nodes (30 by default) are
// inlined at every use instead of becoming functions, so identifiers,
// numbers and keywords cost no call; 0 inlines single-use nodes only.
// Recursive rules are functions whatever the limit.
// [tree]: also generate the tree paths (on by default)
local func generate(g, options, tabled){
  if(g.sealed == null){ g:seal() }
  local self = {
    tabled: tabled,
    lines: {}, pad: {}, counter: 0, statics: {}, static_ids: {}, value_fns: {}, fast_fns: {}, tree_fns: {},
    queue: {}, walkers: {}, tree_walkers: {}, walker_queue: {}, ref_fns: {}, ref_queue: {},
    entry_fns: {}, tables: {},
    messages: {}, descriptions: {}, space_char: pegc.space_char, grammar: g, sizes: {},
    inline_limit: if(options != null and options.inline != null){ options.inline } else { 30 },
    far_cache: options == null or options.far_cache != false,
    with_tree: options == null or options.tree != false,
    tree_split: if(options != null and options.tree_split != null){ options.tree_split } else { 40 }, @meta: gen_meta,
  }
  // in the order the rules were defined: the generated source must be the
  // same from one process to the next, so that the bytecode cache and the
  // parsers shipped with the compiler match it (a table's key order is not)
  local roots = {}
  local rule_names = {}
  for(let local name in values(g.rule_order)){
    if(g.sealed[name] != null){
      append(roots, g.sealed[name])
      append(rule_names, name)
    }
  }
  for(let local name in keys(g.sealed)){
    local known = false
    for(let local n in values(rule_names)){ if(n == name){ known = true } }
    if(not known){ error("pegc: the rule ", name, " is sealed but not in the grammar's rule order") }
  }
  self:scan(roots)
  // rules are named after themselves (an identifier made of the name)
  local rule_fns = {}
  local tree_fns = {}
  local fast_fns = {}
  for(let local name in values(rule_names)){
    local t = target_of(g.sealed[name])
    local id = identifier_name(name)
    if(self.value_fns[t] == null){
      local fname = concat("rule_", id)
      self.value_fns[t] = fname
      append(self.queue, {p: t, mode: "value", name: fname, rule: name})
    }
    rule_fns[name] = self.value_fns[t]
    if(self.with_tree){
      if(self.tree_fns[t] == null){
        local fname = concat("tree_", id)
        self.tree_fns[t] = fname
        append(self.queue, {p: t, mode: "tree", name: fname, rule: name})
      }
      tree_fns[name] = self.tree_fns[t]
    }
  }
  // generate until nothing is queued
  local functions = {}
  for(len(self.queue) > 0 or len(self.walker_queue) > 0 or len(self.ref_queue) > 0){
    self.lines = {}
    self.pad = {}
    if(len(self.queue) > 0){
      local item = remove(self.queue, 0)
      self:generate_function(item)
      append(functions, {name: item.name, mode: item.mode, lines: self.lines})
    } else if(len(self.ref_queue) > 0){
      local item = remove(self.ref_queue, 0)
      self:generate_ref(item)
      append(functions, {name: item.name, mode: "tree", lines: self.lines})
    } else {
      local item = remove(self.walker_queue, 0)
      self:generate_walker(item.p, item.name, item.mode)
      append(functions, {name: item.name, mode: item.mode, lines: self.lines})
    }
  }
  // the fast paths of the rules that got one
  for(let local name in values(rule_names)){
    local f = self.fast_fns[target_of(g.sealed[name])]
    if(f != null){ fast_fns[name] = f }
  }
  local out = {}
  append(out, "// generated by pegc from the sealed grammar: a function of the statics")
  append(out, "// S (listed below), SPACE (the regex of slang's trivia), TM (the")
  append(out, "// metatable of tokens), raw_leaf and parse_tree (peg's), returning the")
  append(out, "// rules by name. In every parser function, r is the position after the")
  append(out, "// match or -1, v its value, tr its node of the lossless tree.")
  for(local k = 0; k < len(self.statics); k = k + 1){
    // on one line: a class may hold a newline or a tab
    local d = str.replace(str.replace(str.replace(self.descriptions[k], "\\", "\\\\"), "\n", "\\n"), "\t", "\\t")
    append(out, concat("//   S[", k, "]: ", str.replace(d, "\r", "\\r")))
  }
  append(out, "local str = require(\"slang/string\")")
  append(out, "local utf8 = require(\"slang/utf8\")")
  append(out, "return func(S, SPACE, TM, raw_leaf, parse_tree){")
  append(out, "// the natives the code calls, as locals: no table lookup per call")
  append(out, "local starts_with = str.starts_with")
  append(out, "local substring = str.substring")
  append(out, "local byte_at = str.byte_at")
  append(out, "local size_at = utf8.size_at")
  append(out, "local match_at = SPACE.match_at")
  // A function has 255 registers, and every generated function is a
  // local: the value and fast paths live in the module's scope, the tree
  // paths (which only call downward, into them) in a nested scope.
  local func field_list(table, group){
    local fields = {}
    for(let local name in values(rule_names)){
      if(table[name] != null){
        local ref = if(group){ self:tree_ref(table[name]) } else { table[name] }
        append(fields, concat("[", quote(name), "]: ", ref))
      }
    }
    return str.join(fields, ", ")
  }
  local func scope(group, indent){
    local names = {}
    for(let local f in values(functions)){ if((f.mode == "tree") == group){ append(names, f.name) } }
    for(let local f in values(self.entry_fns)){ if((f.mode == "tree") == group){ append(names, f.name) } }
    for(let local t in values(self.tables)){ if((t.mode == "tree") == group){ append(names, t.name) } }
    if(len(names) > 240 and not (group and self.tabled)){
      if(group){ return false }
      error("pegc: ", len(names), " generated functions in one scope: more than a function's registers")
    }
    if(group and self.tabled){
      append(out, concat(indent, "local G = {}"))
    } else {
      for(let local n in values(names)){ append(out, concat(indent, "local ", n)) }
    }
    for(let local f in values(functions)){
      if((f.mode == "tree") == group){
        for(let local l in values(f.lines)){ append(out, concat(indent, l)) }
      }
    }
    for(let local f in values(self.entry_fns)){
      if((f.mode == "tree") == group){
        append(out, concat(indent, if(group and self.tabled){ "G." } else { "" }, f.name, " = func(", f.params, "){"))
        for(let local l in values(f.lines)){ append(out, concat(indent, "  ", l)) }
        append(out, concat(indent, "}"))
      }
    }
    for(let local t in values(self.tables)){
      if((t.mode == "tree") == group){ append(out, concat(indent, t.text)) }
    }
    return true
  }
  scope(false, "")
  append(out, "local trees = run{")
  if(not scope(true, "  ")){ return {too_big: true} }
  append(out, concat("  return {", field_list(tree_fns, true), "}"))
  append(out, "}")
  append(out, concat("return {rules: {", field_list(rule_fns), "}, trees: trees, fasts: {", field_list(fast_fns), "}}"))
  append(out, "}")
  local source = str.join(out, "\n")
  local tree_count = 0
  for(let local f in values(functions)){ if(f.mode == "tree"){ tree_count = tree_count + 1 } }
  for(let local f in values(self.entry_fns)){ if(f.mode == "tree"){ tree_count = tree_count + 1 } }
  for(let local t in values(self.tables)){ if(t.mode == "tree"){ tree_count = tree_count + 1 } }
  local result = {
    source: source, hash: str.format("%x", hash.fnv1a(source)), statics: self.statics,
    functions: len(functions), tree_count: tree_count, tabled: tabled,
  }
  // load(compiled?): the generated parsers; compiled is the compiled
  // source (a function) when the caller has it, from a cache or shipped
  // with the compiler (see embeddable)
  result.load = func(self, compiled){
    local f = compiled or compile(self.source, "pegc")
    local module = f()
    if(type(module) == "table"){ module = module.make }
    return module(self.statics, peg.space, peg.token_meta, peg.raw_leaf, peg.parse_tree)
  }
  // embeddable(): the source as a module that returns {hash, make}, for
  // a parser shipped with the compiler: the hash says which generated
  // source it is the compiled form of (slang/seed_parsers.slang)
  result.embeddable = func(self){
    local marker = "return func(S, SPACE, TM, raw_leaf, parse_tree){"
    if(not str.contains(self.source, marker)){ error("pegc: the module's entry was not found") }
    return concat(
      "local M = {hash: ", quote(self.hash), "}\n",
      str.replace(self.source, marker, "M.make = func(S, SPACE, TM, raw_leaf, parse_tree){"),
      "\nreturn M\n"
    )
  }
  return result
}

func pegc.compile(g, options){
  local r = generate(g, options, false)
  if(r.too_big){
    // the tree group would not fit a frame's registers: as a table
    r = generate(g, options, true)
  }
  return r
}

// the regex of one whitespace character (peg.whitespace's)
pegc.space_char = require("slang/regex").compile("[ \\t\\n\\r]")

return pegc
