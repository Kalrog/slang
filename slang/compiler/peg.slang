// slang/peg: parser combinators in the style of petitparser.
//
// A parser is a table with a `parse_on` function:
//   parser:parse_on(ctx, pos) -> new position, or -1 on failure
// On success the parsed value is left in ctx.value. On failure the message and
// position are recorded in ctx.fail_msg / ctx.fail_pos (the last failure wins,
// like petitparser's choice), and the farthest failure in ctx.far_*.

local str = require("slang/string")

local peg = {}
local methods = {}
local parser_meta = {__index: methods, __type: "parser"}

// a parser is a matcher: 'parser as PATTERN in a pattern parses the whole
// string and matches PATTERN against the parsed value (null: no parse)
func parser_meta.__match(self, text){
  if(type(text) != "string"){
    return null
  }
  local r = peg.run(peg.end(self), text)
  if(not r.ok){
    return null
  }
  return r.value
}

local next_id = 0

// fast(self, ctx, pos) parses without producing a value (used by flatten and
// lookaheads); it defaults to parse_on. Parsers whose actions may have side
// effects (map, where) keep the full parse as their fast variant.
local func new_parser(parse_on, children, kind, fast){
  next_id = next_id + 1
  local p = {parse_on: parse_on, fast: fast or parse_on, id: next_id, children: children or {}, kind: kind or "custom"}
  p.meta = parser_meta
  return p
}

local func fail(ctx, pos, msg){
  ctx.fail_pos = pos
  ctx.fail_msg = msg
  if(pos > ctx.far_pos){
    ctx.far_pos = pos
    ctx.far_msg = msg
  }
  return -1
}

// context(buffer, {record}) -> a parse context; with record, every token
// with a category and every comment is recorded (see peg.tokens)
func peg.context(buffer, options){
  local tokens = null
  if(options != null and options.record){
    tokens = {}
  }
  return {
    buffer: buffer,
    len: len(buffer),
    fail_pos: -1,
    far_pos: -1,
    tokens: tokens,
    memo: {},
    // results of memoized rules (peg.memoize); the phrase loop clears it
    // before every top-level statement
    rule_memo: {},
  }
}

// line_col(ctx, pos) -> {line, column} (1-based)
func peg.line_col(ctx, pos){
  return str.line_col(ctx.buffer, pos)
}

func peg.make_token(ctx, value, start, stop){
  local lc = peg.line_col(ctx, start)
  return {value: value, start: start, stop: stop, line: lc[0], column: lc[1]}
}

func peg.is_parser(value){
  return type(value) == "parser"
}

// ---------------------------------------------------------------- primitives

func peg.string(s, message){
  local msg = message or concat("\"", s, "\" expected")
  local n = len(s)
  local p = new_parser(func(self, ctx, pos){
    if(str.starts_with(ctx.buffer, s, pos)){
      ctx.value = s
      return pos + n
    }
    return fail(ctx, pos, msg)
  }, null, "string")
  p.literal = s
  return p
}

func peg.char(c, message){
  return peg.string(c, message or concat("\"", c, "\" expected"))
}

func peg.pattern(spec, message){
  local cls = str.char_class(spec)
  local msg = message or concat("[", spec, "] expected")
  local p = new_parser(func(self, ctx, pos){
    local n = str.class_match(cls, ctx.buffer, pos)
    if(n > 0){
      ctx.value = str.substring(ctx.buffer, pos, pos + n)
      return pos + n
    }
    return fail(ctx, pos, msg)
  }, null, "pattern", func(self, ctx, pos){
    local n = str.class_match(cls, ctx.buffer, pos)
    if(n > 0){
      return pos + n
    }
    return fail(ctx, pos, msg)
  })
  p.class = cls
  p.spec = spec
  return p
}

func peg.any(message){
  local msg = message or "input expected"
  return new_parser(func(self, ctx, pos){
    local n = str.rune_len_at(ctx.buffer, pos)
    if(n > 0){
      ctx.value = str.substring(ctx.buffer, pos, pos + n)
      return pos + n
    }
    return fail(ctx, pos, msg)
  }, null, "any", func(self, ctx, pos){
    local n = str.rune_len_at(ctx.buffer, pos)
    if(n > 0){
      return pos + n
    }
    return fail(ctx, pos, msg)
  })
}

func peg.digit(message){
  return peg.pattern("0-9", message or "digit expected")
}

func peg.letter(message){
  return peg.pattern("a-zA-Z", message or "letter expected")
}

func peg.word(message){
  return peg.pattern("a-zA-Z0-9_", message or "letter or digit expected")
}

func peg.whitespace(message){
  local msg = message or "whitespace expected"
  return new_parser(func(self, ctx, pos){
    local n = str.space_at(ctx.buffer, pos)
    if(n > 0){
      ctx.value = str.substring(ctx.buffer, pos, pos + n)
      return pos + n
    }
    return fail(ctx, pos, msg)
  }, null, "whitespace", func(self, ctx, pos){
    local n = str.space_at(ctx.buffer, pos)
    if(n > 0){
      return pos + n
    }
    return fail(ctx, pos, msg)
  })
}

func peg.end_of_input(message){
  local msg = message or "end of input expected"
  return new_parser(func(self, ctx, pos){
    if(pos == ctx.len){
      ctx.value = null
      return pos
    }
    return fail(ctx, pos, msg)
  }, null, "end")
}

func peg.epsilon(value){
  return new_parser(func(self, ctx, pos){
    ctx.value = value
    return pos
  }, null, "epsilon")
}

func peg.failure(message){
  return new_parser(func(self, ctx, pos){
    return fail(ctx, pos, message)
  }, null, "failure")
}

// --------------------------------------------------------------- combinators

local func choice_list(parsers){
  local n = len(parsers)
  return new_parser(func(self, ctx, pos){
    for(local i = 0; i < n; i = i + 1){
      local child = parsers[i]
      local p = child:parse_on(ctx, pos)
      if(p >= 0){
        return p
      }
    }
    return -1
  }, parsers, "choice", func(self, ctx, pos){
    for(local i = 0; i < n; i = i + 1){
      local child = parsers[i]
      local p = child.fast(child, ctx, pos)
      if(p >= 0){
        return p
      }
    }
    return -1
  })
}

local func seq_list(parsers){
  local n = len(parsers)
  return new_parser(func(self, ctx, pos){
    // the result list is allocated only once the first element matched,
    // since most sequence attempts fail on their first element
    local values = null
    for(local i = 0; i < n; i = i + 1){
      local child = parsers[i]
      pos = child:parse_on(ctx, pos)
      if(pos < 0){
        return -1
      }
      if(values == null){
        values = {}
      }
      list_push(values, ctx.value)
    }
    ctx.value = values or {}
    return pos
  }, parsers, "seq", func(self, ctx, pos){
    for(local i = 0; i < n; i = i + 1){
      local child = parsers[i]
      pos = child.fast(child, ctx, pos)
      if(pos < 0){
        return -1
      }
    }
    return pos
  })
}

func peg.seq(...parsers){
  return seq_list(parsers)
}

func peg.choice(...parsers){
  return choice_list(parsers)
}

func peg.seq_list(parsers){
  return seq_list(parsers)
}

func peg.choice_list(parsers){
  return choice_list(parsers)
}

func peg.star(child){
  local fast
  if(child.kind == "pattern"){
    local cls = child.class
    fast = func(self, ctx, pos){
      return str.class_run(cls, ctx.buffer, pos)
    }
  } else {
    fast = func(self, ctx, pos){
      for(true){
        local q = child.fast(child, ctx, pos)
        if(q < 0 or q == pos){
          break
        }
        pos = q
      }
      return pos
    }
  }
  return new_parser(func(self, ctx, pos){
    local values = {}
    for(true){
      local q = child:parse_on(ctx, pos)
      if(q < 0 or q == pos){
        break
      }
      list_push(values, ctx.value)
      pos = q
    }
    ctx.value = values
    return pos
  }, {child}, "star", fast)
}

func peg.plus(child){
  local fast
  if(child.kind == "pattern"){
    local cls = child.class
    local msg = concat("[", child.spec, "] expected")
    fast = func(self, ctx, pos){
      local q = str.class_run(cls, ctx.buffer, pos)
      if(q == pos){
        return fail(ctx, pos, msg)
      }
      return q
    }
  } else {
    fast = func(self, ctx, pos){
      local q = child.fast(child, ctx, pos)
      if(q < 0){
        return -1
      }
      pos = q
      for(true){
        q = child.fast(child, ctx, pos)
        if(q < 0 or q == pos){
          break
        }
        pos = q
      }
      return pos
    }
  }
  return new_parser(func(self, ctx, pos){
    local values = {}
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    list_push(values, ctx.value)
    pos = q
    for(true){
      q = child:parse_on(ctx, pos)
      if(q < 0 or q == pos){
        break
      }
      list_push(values, ctx.value)
      pos = q
    }
    ctx.value = values
    return pos
  }, {child}, "plus", fast)
}

func peg.optional(child, default_value){
  return new_parser(func(self, ctx, pos){
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      ctx.value = default_value
      return pos
    }
    return q
  }, {child}, "optional", func(self, ctx, pos){
    local q = child.fast(child, ctx, pos)
    if(q < 0){
      return pos
    }
    return q
  })
}

// child repeated lazily until limit matches (limit is not consumed)
func peg.star_lazy(child, limit){
  return new_parser(func(self, ctx, pos){
    local values = {}
    for(true){
      if(limit:parse_on(ctx, pos) >= 0){
        ctx.value = values
        return pos
      }
      local q = child:parse_on(ctx, pos)
      if(q < 0){
        return -1
      }
      list_push(values, ctx.value)
      pos = q
    }
  }, {child, limit}, "star_lazy", func(self, ctx, pos){
    for(true){
      if(limit.fast(limit, ctx, pos) >= 0){
        return pos
      }
      local q = child.fast(child, ctx, pos)
      if(q < 0){
        return -1
      }
      pos = q
    }
  })
}

local func separated(child, separator, at_least_one){
  local p = new_parser(func(self, ctx, pos){
    local elements = {}
    local separators = {}
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      if(at_least_one){
        return -1
      }
      ctx.value = {elements: elements, separators: separators}
      return pos
    }
    list_push(elements, ctx.value)
    pos = q
    for(true){
      q = separator:parse_on(ctx, pos)
      if(q < 0){
        break
      }
      local sep = ctx.value
      local r = child:parse_on(ctx, q)
      if(r < 0){
        break
      }
      list_push(separators, sep)
      list_push(elements, ctx.value)
      pos = r
    }
    ctx.value = {elements: elements, separators: separators}
    return pos
  }, {child, separator}, "separated")
  p.at_least_one = at_least_one
  return p
}

func peg.star_separated(child, separator){
  return separated(child, separator, false)
}

func peg.plus_separated(child, separator){
  return separated(child, separator, true)
}

// succeeds (with value null) only if child fails; consumes nothing
func peg.forbid(child, message){
  local msg = message or "success not expected"
  return new_parser(func(self, ctx, pos){
    if(child.fast(child, ctx, pos) >= 0){
      return fail(ctx, pos, msg)
    }
    ctx.value = null
    return pos
  }, {child}, "forbid", func(self, ctx, pos){
    if(child.fast(child, ctx, pos) >= 0){
      return fail(ctx, pos, msg)
    }
    return pos
  })
}

// lookahead: succeeds if child succeeds, consumes nothing
func peg.and(child){
  return new_parser(func(self, ctx, pos){
    if(child.fast(child, ctx, pos) < 0){
      return -1
    }
    return pos
  }, {child}, "and", func(self, ctx, pos){
    if(child.fast(child, ctx, pos) < 0){
      return -1
    }
    return pos
  })
}

// any single character that child does not match
func peg.neg(child, message){
  local msg = message or "input not expected"
  return new_parser(func(self, ctx, pos){
    if(child.fast(child, ctx, pos) >= 0){
      return fail(ctx, pos, msg)
    }
    local n = str.rune_len_at(ctx.buffer, pos)
    if(n > 0){
      ctx.value = str.substring(ctx.buffer, pos, pos + n)
      return pos + n
    }
    return fail(ctx, pos, "input expected")
  }, {child}, "neg", func(self, ctx, pos){
    if(child.fast(child, ctx, pos) >= 0){
      return fail(ctx, pos, msg)
    }
    local n = str.rune_len_at(ctx.buffer, pos)
    if(n > 0){
      return pos + n
    }
    return fail(ctx, pos, "input expected")
  })
}

func peg.pick(child, index){
  return new_parser(func(self, ctx, pos){
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    local list = ctx.value
    if(index < 0){
      ctx.value = list[len(list) + index]
    } else {
      ctx.value = list[index]
    }
    return q
  }, {child}, "pick", func(self, ctx, pos){
    return child.fast(child, ctx, pos)
  })
}

func peg.permute(child, ...indices){
  local n = len(indices)
  return new_parser(func(self, ctx, pos){
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    local list = ctx.value
    local out = {}
    for(local i = 0; i < n; i = i + 1){
      local index = indices[i]
      if(index < 0){
        list_push(out, list[len(list) + index])
      } else {
        list_push(out, list[index])
      }
    }
    ctx.value = out
    return q
  }, {child}, "permute", func(self, ctx, pos){
    return child.fast(child, ctx, pos)
  })
}

func peg.map(child, f){
  return new_parser(func(self, ctx, pos){
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    ctx.value = f(ctx.value)
    return q
  }, {child}, "map")
}

// replaces the value by the consumed input (the child is parsed without
// building values)
func peg.flatten(child, message){
  return new_parser(func(self, ctx, pos){
    local q = child.fast(child, ctx, pos)
    if(q < 0){
      if(message != null){
        return fail(ctx, pos, message)
      }
      return -1
    }
    ctx.value = str.substring(ctx.buffer, pos, q)
    return q
  }, {child}, "flatten", func(self, ctx, pos){
    local q = child.fast(child, ctx, pos)
    if(q < 0 and message != null){
      return fail(ctx, pos, message)
    }
    return q
  })
}

// token(child, category): the consumed input as a token {value, start, stop,
// line, column, category}; the category is what a highlighter shows
func peg.token(child, category){
  return new_parser(func(self, ctx, pos){
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    local t = peg.make_token(ctx, ctx.value, pos, q)
    if(category != null){
      t.category = category
      if(ctx.tokens != null){
        list_push(ctx.tokens, {category: category, start: pos, stop: q})
      }
    }
    ctx.value = t
    return q
  }, {child}, "token", func(self, ctx, pos){
    return child.fast(child, ctx, pos)
  })
}

local default_trimmer = peg.whitespace()

// repeatedly applies trimmer at pos; memoised per parser when trimmer.memo is set
local func consume(trimmer, ctx, pos){
  // a trimmer flagged `single` consumes everything in one call
  if(trimmer.single){
    local far_pos = ctx.far_pos
    local far_msg = ctx.far_msg
    local q = trimmer:parse_on(ctx, pos)
    ctx.far_pos = far_pos
    ctx.far_msg = far_msg
    if(q < 0){
      return pos
    }
    return q
  }
  local table
  if(trimmer.memo){
    table = ctx.memo[trimmer.id]
    if(table == null){
      table = {}
      ctx.memo[trimmer.id] = table
    }
    local cached = table[pos]
    if(cached != null){
      return cached
    }
  }
  local start = pos
  local far_pos = ctx.far_pos
  local far_msg = ctx.far_msg
  for(true){
    local q = trimmer:parse_on(ctx, pos)
    if(q < 0 or q == pos){
      break
    }
    pos = q
  }
  ctx.far_pos = far_pos
  ctx.far_msg = far_msg
  if(table != null){
    table[start] = pos
  }
  return pos
}

func peg.trim(child, before, after){
  before = before or default_trimmer
  after = after or before
  return new_parser(func(self, ctx, pos){
    pos = consume(before, ctx, pos)
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    local v = ctx.value
    q = consume(after, ctx, q)
    ctx.value = v
    return q
  }, {child, before, after}, "trim", func(self, ctx, pos){
    pos = consume(before, ctx, pos)
    local q = child.fast(child, ctx, pos)
    if(q < 0){
      return -1
    }
    return consume(after, ctx, q)
  })
}

func peg.where(child, predicate, message){
  local msg = message or "unexpected value"
  return new_parser(func(self, ctx, pos){
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    if(not predicate(ctx.value)){
      return fail(ctx, pos, msg)
    }
    return q
  }, {child}, "where")
}

func peg.end(child, message){
  return peg.pick(peg.seq(child, peg.end_of_input(message)), 0)
}

func peg.labeled(child, label){
  child.label = label
  return child
}

// a parser whose target can be replaced later
func peg.settable(target){
  local p = new_parser(func(self, ctx, pos){
    return self.target:parse_on(ctx, pos)
  }, null, "settable", func(self, ctx, pos){
    local target = self.target
    return target.fast(target, ctx, pos)
  })
  p.target = target
  return p
}

func methods.set(self, target){
  self.target = target
}

// ------------------------------------------------------------------ references
//
// ref(f, ...args) is a lazy parser: the first time it is used it calls
// f(...args) and delegates to the result. Calls with the same f and the same
// arguments share one target, so recursive grammars form a finite graph.

local ref_cache = {}

local func resolve_ref(f, args){
  local node = ref_cache[f]
  if(node == null){
    node = {}
    ref_cache[f] = node
  }
  local n = len(args)
  for(local i = 0; i < n; i = i + 1){
    local key = args[i]
    if(key == null){
      key = "__null"
    }
    local next = node[key]
    if(next == null){
      next = {}
      node[key] = next
    }
    node = next
  }
  local target = node.__target
  if(target == null){
    target = f(args[0], args[1], args[2], args[3])
    if(target == null){
      error("parser reference resolved to null")
    }
    node.__target = target
  }
  return target
}

func peg.ref(f, ...args){
  if(type(f) != "function"){
    error("ref expects a function, got ", type(f))
  }
  local p = new_parser(func(self, ctx, pos){
    local target = self.target
    if(target == null){
      target = resolve_ref(f, args)
      self.target = target
    }
    return target:parse_on(ctx, pos)
  }, null, "ref", func(self, ctx, pos){
    local target = self.target
    if(target == null){
      target = resolve_ref(f, args)
      self.target = target
    }
    return target.fast(target, ctx, pos)
  })
  p.ref_function = f
  p.ref_args = args
  return p
}

// resolve(parser): eagerly resolves every reference reachable from parser
// (grammar functions run now, so keywords they register take effect now).
func peg.resolve(parser){
  local seen = {}
  local stack = {parser}
  for(len(stack) > 0){
    local p = remove(stack, len(stack) - 1)
    if(p != null and seen[p] == null){
      seen[p] = true
      if(p.ref_function != null and p.target == null){
        p.target = resolve_ref(p.ref_function, p.ref_args)
      }
      if(p.target != null){
        append(stack, p.target)
      }
      for(let local c in values(p.children)){
        append(stack, c)
      }
    }
  }
  return parser
}

// custom(parse_on): a parser from a raw parse function (self, ctx, pos) -> pos | -1
func peg.custom(parse_on){
  return new_parser(parse_on)
}

// fail(ctx, pos, message): record a failure and return -1 (for custom parsers)
func peg.fail(ctx, pos, message){
  return fail(ctx, pos, message)
}

func peg.reset_refs(){
  ref_cache = {}
}

// --------------------------------------------------------------------- running

// parse(parser, input) -> {"ok", value} | {"error", "message at line:column"}
func peg.parse(parser, input){
  local ctx = peg.context(input)
  local pos = parser:parse_on(ctx, 0)
  if(pos >= 0){
    return {"ok", ctx.value}
  }
  local lc = peg.line_col(ctx, ctx.fail_pos)
  return {"error", concat(ctx.fail_msg, " at ", lc[0], ":", lc[1])}
}

// run(parser, input) -> {ok: bool, value, position, message, line, column, far_message, far_line, far_column}
func peg.run(parser, input){
  local ctx = peg.context(input)
  local pos = parser:parse_on(ctx, 0)
  if(pos >= 0){
    return {ok: true, value: ctx.value, position: pos}
  }
  local lc = peg.line_col(ctx, ctx.fail_pos)
  local far = peg.line_col(ctx, ctx.far_pos)
  return {
    ok: false,
    position: ctx.fail_pos,
    message: ctx.fail_msg,
    line: lc[0],
    column: lc[1],
    far_message: ctx.far_msg,
    far_line: far[0],
    far_column: far[1],
  }
}

// ---------------------------------------------------------- expression walker
//
// A Pratt-style walker: prefix operators, wrappers and primaries are the
// "nud" alternatives (what an expression can start with), postfix and infix
// operators the "led" alternatives (what can follow a value). Every operator
// carries binding powers; `parse(min_bp)` parses a value and then applies
// the operators whose left binding power exceeds min_bp. The level API
// derives binding powers from named, ordered levels; the engine API takes
// them as numbers. See peg.walker below, after the first-byte analysis the
// walker's dispatch tables are built with.

// --- first-byte analysis: {first: set of bytes | null (unknown), nullable: bool}

local UNKNOWN = {nullable: true}

local func union(a, b){
  if(a == null or b == null){
    return null
  }
  local out = {}
  for(let local k in keys(a)){
    out[k] = true
  }
  for(let local k in keys(b)){
    out[k] = true
  }
  return out
}

local whitespace_first = {}
for(let local b in values({9, 10, 11, 12, 13, 32})){
  whitespace_first[b] = true
}

local func info_of(p, memo, visiting){
  if(p == null){
    return UNKNOWN
  }
  local cached = memo[p]
  if(cached != null){
    return cached
  }
  if(visiting[p]){
    return UNKNOWN
  }
  visiting[p] = true
  local r = UNKNOWN
  local kind = p.kind
  local children = p.children
  if(kind == "string"){
    if(len(p.literal) == 0){
      r = {first: {}, nullable: true}
    } else {
      local first = {}
      first[str.byte_at(p.literal, 0)] = true
      r = {first: first, nullable: false}
    }
  } else if(kind == "pattern"){
    if(str.starts_with(p.spec, "^")){
      r = {nullable: false}
    } else {
      local first = {}
      for(local b = 0; b < 128; b = b + 1){
        if(str.class_match(p.class, str.chr(b), 0) > 0){
          first[b] = true
        }
      }
      r = {first: first, nullable: false}
    }
  } else if(kind == "any" or kind == "neg"){
    r = {nullable: false}
  } else if(kind == "whitespace"){
    r = {first: whitespace_first, nullable: false}
  } else if(kind == "end" or kind == "epsilon" or kind == "forbid" or kind == "and"){
    r = {first: {}, nullable: true}
  } else if(kind == "failure"){
    r = {first: {}, nullable: false}
  } else if(kind == "seq"){
    local first = {}
    local nullable = true
    for(let local c in values(children)){
      local ci = info_of(c, memo, visiting)
      first = union(first, ci.first)
      if(not ci.nullable){
        nullable = false
        break
      }
    }
    r = {first: first, nullable: nullable}
  } else if(kind == "choice" or kind == "dispatch"){
    local first = {}
    local nullable = false
    for(let local c in values(children)){
      local ci = info_of(c, memo, visiting)
      first = union(first, ci.first)
      if(ci.nullable){
        nullable = true
      }
    }
    r = {first: first, nullable: nullable}
  } else if(kind == "star" or kind == "optional"){
    r = {first: info_of(children[0], memo, visiting).first, nullable: true}
  } else if(kind == "star_lazy"){
    r = {first: union(info_of(children[0], memo, visiting).first, info_of(children[1], memo, visiting).first), nullable: true}
  } else if(kind == "separated"){
    local ci = info_of(children[0], memo, visiting)
    r = {first: ci.first, nullable: ci.nullable or not p.at_least_one}
  } else if(kind == "plus" or kind == "pick" or kind == "permute" or kind == "map" or kind == "flatten" or kind == "token" or kind == "trim" or kind == "where" or kind == "tag"){
    r = info_of(children[0], memo, visiting)
  } else if(kind == "settable"){
    r = info_of(p.target, memo, visiting)
  } else if(kind == "rule"){
    // a reference created while the grammar is being sealed has no target
    // yet; its lookup finds the rule in the sealed table (null for rules
    // that are not built yet, which is then correctly unknown)
    local target = p.target
    if(target == null and p.lookup != null){
      target = p.lookup(p)
    }
    r = info_of(target, memo, visiting)
  } else if(kind == "ref"){
    if(p.target == null){
      p.target = resolve_ref(p.ref_function, p.ref_args)
    }
    r = info_of(p.target, memo, visiting)
  } else if(p.first != null){
    r = {first: p.first, nullable: p.nullable == true}
  }
  visiting[p] = null
  memo[p] = r
  return r
}

// tag(child, category): parses child and, when recording, records its span
// again under category (a later record wins), so an extension can colour
// what a rule produced (an identifier as a function being declared, say)
// without changing the value
func peg.tag(child, category){
  return new_parser(func(self, ctx, pos){
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    if(ctx.tokens != null){
      // the span of the value: a token, or a node's token (nodes report
      // their own type, so anything that is not a primitive is indexable)
      local v = ctx.value
      local t = type(v)
      local span = null
      if(v != null and t != "string" and t != "int" and t != "double" and t != "bool" and t != "function" and t != "thread" and t != "userdata"){
        span = v
        if(v.token != null){
          span = v.token
        }
      }
      if(span != null and span.start != null and span.stop != null){
        list_push(ctx.tokens, {category: category, start: span.start, stop: span.stop})
      } else {
        list_push(ctx.tokens, {category: category, start: pos, stop: q})
      }
    }
    return q
  }, {child}, "tag", func(self, ctx, pos){
    return child.fast(child, ctx, pos)
  })
}

// ------------------------------------------------------------- memoization
//
// A parser is memoized where it can run twice at one position: as the
// leading parser of several alternatives of one choice or dispatch. The
// common case is the `old` of a modified rule appearing in both alternatives
// of choice(seq(old, tail), old), which would otherwise parse every instance
// of the rule twice. Results live in ctx.rule_memo per position; a cached
// result is shared, so parser actions must not mutate their inputs.

// memoize(p): makes p remember its results, in place (every grammar sharing
// the parser sees it)
func peg.memoize(p){
  if(p.memoized){
    return p
  }
  p.memoized = true
  local id = p.id
  local parse_on = p.parse_on
  local fast = p.fast
  local func table_of(ctx){
    local t = ctx.rule_memo[id]
    if(t == null){
      t = {}
      ctx.rule_memo[id] = t
    }
    return t
  }
  p.parse_on = func(self, ctx, pos){
    local t = table_of(ctx)
    local hit = t[pos]
    if(hit != null and hit.has_value){
      if(hit.stop < 0){
        return fail(ctx, hit.fail_pos, hit.fail_msg)
      }
      ctx.value = hit.value
      return hit.stop
    }
    local q = parse_on(self, ctx, pos)
    if(q < 0){
      t[pos] = {stop: -1, has_value: true, fail_pos: ctx.fail_pos, fail_msg: ctx.fail_msg}
    } else {
      t[pos] = {stop: q, has_value: true, value: ctx.value}
    }
    return q
  }
  p.fast = func(self, ctx, pos){
    local t = table_of(ctx)
    local hit = t[pos]
    if(hit != null){
      if(hit.stop < 0){
        return fail(ctx, hit.fail_pos, hit.fail_msg)
      }
      return hit.stop
    }
    local q = fast(self, ctx, pos)
    if(q < 0){
      t[pos] = {stop: -1, has_value: true, fail_pos: ctx.fail_pos, fail_msg: ctx.fail_msg}
    } else {
      t[pos] = {stop: q, has_value: false}
    }
    return q
  }
  return p
}

// leading_set(p) -> the set of parsers that may run at the position p starts
// at (p itself, the first elements of a sequence up to the first one that is
// not nullable, every alternative of a choice, through wrappers and
// references; an expression walker is a leaf)
local func leading_set(p, cache, visiting, memo){
  if(p == null){
    return {}
  }
  local cached = cache[p]
  if(cached != null){
    return cached
  }
  if(visiting[p]){
    return {}
  }
  visiting[p] = true
  local out = {}
  out[p] = true
  local func add(child){
    for(let local e in entries(leading_set(child, cache, visiting, memo))){
      out[e[0]] = true
    }
  }
  local kind = p.kind
  local children = p.children
  if(kind == "seq"){
    for(let local c in values(children)){
      add(c)
      if(not info_of(c, memo, {}).nullable){
        break
      }
    }
  } else if(kind == "choice" or kind == "dispatch"){
    for(let local c in values(children)){
      add(c)
    }
  } else if(kind == "star" or kind == "optional" or kind == "plus" or kind == "separated" or kind == "star_lazy" or
            kind == "pick" or kind == "permute" or kind == "map" or kind == "flatten" or kind == "token" or
            kind == "trim" or kind == "where" or kind == "tag"){
    add(children[0])
  } else if(kind == "settable"){
    add(p.target)
  } else if(kind == "rule"){
    local target = p.target
    if(target == null and p.lookup != null){
      target = p.lookup(p)
    }
    add(target)
  } else if(kind == "ref"){
    if(p.target == null){
      p.target = resolve_ref(p.ref_function, p.ref_args)
    }
    add(p.target)
  }
  visiting[p] = null
  cache[p] = out
  return out
}

// place_memos(roots, named) -> list of {parser, name}: memoizes every parser
// in `named` (parser -> name: the rules and the parsers they were modified
// from) that leads more than one alternative of a choice or dispatch
// reachable from roots
func peg.place_memos(roots, named){
  local placed = {}
  local placed_set = {}
  local seen = {}
  local cache = {}
  local memo = {}
  local stack = {}
  for(let local r in values(roots)){
    append(stack, r)
  }
  for(len(stack) > 0){
    local p = remove(stack, len(stack) - 1)
    if(p != null and seen[p] == null){
      seen[p] = true
      local kind = p.kind
      if(kind == "rule" and p.target == null and p.lookup != null){
        append(stack, p.lookup(p))
      } else if(kind == "ref" and p.target == null){
        p.target = resolve_ref(p.ref_function, p.ref_args)
      }
      if(p.target != null){
        append(stack, p.target)
      }
      for(let local c in values(p.children)){
        append(stack, c)
      }
      if(kind == "choice" or kind == "dispatch"){
        // alts[q]: the alternatives (by index) that q leads
        local alts = {}
        local index = 0
        for(let local c in values(p.children)){
          for(let local e in entries(leading_set(c, cache, {}, memo))){
            local q = e[0]
            if(named[q] != null){
              local a = alts[q]
              if(a == null){
                a = {}
                alts[q] = a
              }
              a[index] = true
            }
          }
          index = index + 1
        }
        local shared = {}
        for(let local e in entries(alts)){
          if(len(e[1]) > 1){
            shared[e[0]] = e[1]
          }
        }
        // a shared parser reached only through another shared one (it is in
        // that one's leading set, in the same alternatives) is parsed inside
        // it and needs no memo of its own
        for(let local e in entries(shared)){
          local q = e[0]
          local dominated = false
          for(let local f in entries(shared)){
            local o = f[0]
            if(o != q and not dominated and leading_set(o, cache, {}, memo)[q] != null){
              dominated = true
              for(let local a in entries(e[1])){
                if(f[1][a[0]] == null){
                  dominated = false
                }
              }
            }
          }
          if(not dominated and placed_set[q] == null){
            placed_set[q] = true
            peg.memoize(q)
            append(placed, {parser: q, name: named[q]})
          }
        }
      }
    }
  }
  return placed
}

// skip_space(ctx, pos) -> pos: skips slang whitespace and comments (the skip
// function of a walker or dispatch when the trivia rule is the default)
func peg.skip_space(ctx, pos){
  local q = str.skip_space(ctx.buffer, pos)
  if(ctx.tokens != null and q > pos){
    peg.record_comments(ctx, pos, q)
  }
  return q
}

// ------------------------------------------------------------ token recording
//
// A recording context collects {category, start, stop} for every token with
// a category and for every comment inside trivia. Alternatives that lost
// leave records too, so tokens(ctx) normalises: sorted by start, a later
// record wins over an earlier one at the same start, overlaps are dropped.

// record_comments(ctx, from, to): records the `//` comments in a trivia run
func peg.record_comments(ctx, from, to){
  local buffer = ctx.buffer
  local i = from
  for(i < to){
    if(str.byte_at(buffer, i) == 47 and i + 1 < to and str.byte_at(buffer, i + 1) == 47){
      local j = i
      for(j < to and str.byte_at(buffer, j) != 10){
        j = j + 1
      }
      list_push(ctx.tokens, {category: "comment", start: i, stop: j})
      i = j
    } else {
      i = i + 1
    }
  }
}

// stable merge sort of a list by a comparison less(a, b)
local func merge_sort(list, less){
  local n = len(list)
  if(n < 2){
    return list
  }
  local mid = n / 2
  mid = to_int(mid)
  local left = {}
  local right = {}
  for(local i = 0; i < mid; i = i + 1){
    list_push(left, list[i])
  }
  for(local i = mid; i < n; i = i + 1){
    list_push(right, list[i])
  }
  left = merge_sort(left, less)
  right = merge_sort(right, less)
  local out = {}
  local a = 0
  local b = 0
  for(a < len(left) and b < len(right)){
    if(less(right[b], left[a])){
      list_push(out, right[b])
      b = b + 1
    } else {
      list_push(out, left[a])
      a = a + 1
    }
  }
  for(a < len(left)){
    list_push(out, left[a])
    a = a + 1
  }
  for(b < len(right)){
    list_push(out, right[b])
    b = b + 1
  }
  return out
}

// tokens(ctx) -> the recorded tokens, normalised, as
// {category, start, stop, line, column, length}
func peg.tokens(ctx){
  if(ctx.tokens == null){
    return {}
  }
  local indexed = {}
  for(let local e in entries(ctx.tokens)){
    list_push(indexed, {order: e[0], t: e[1]})
  }
  local sorted = merge_sort(indexed, func(x, y){
    if(x.t.start != y.t.start){
      return x.t.start < y.t.start
    }
    return x.order > y.order
  })
  local out = {}
  local last_stop = -1
  for(let local e in values(sorted)){
    local t = e.t
    if(t.start >= last_stop and t.stop > t.start){
      local lc = peg.line_col(ctx, t.start)
      list_push(out, {category: t.category, start: t.start, stop: t.stop, line: lc[0], column: lc[1], length: t.stop - t.start})
      last_stop = t.stop
    }
  }
  return out
}

// a dispatch table: candidates per first byte, in the original order;
// skip(ctx, pos) -> pos finds the first byte that matters
local func make_dispatch(entries, skip, memo){
  local d = {all: entries, skip: skip}
  if(skip == null or len(entries) == 0){
    return d
  }
  local infos = {}
  for(let local e in values(entries)){
    local i = info_of(e.parser, memo, {})
    local first = i.first
    if(i.nullable){
      first = null
    }
    list_push(infos, first)
  }
  local by_byte = {}
  local n = len(entries)
  for(local b = 0; b < 128; b = b + 1){
    local list = null
    for(local i = 0; i < n; i = i + 1){
      local first = infos[i]
      if(first == null or first[b]){
        if(list == null){
          list = {}
        }
        append(list, entries[i])
      }
    }
    list_push(by_byte, list)
  }
  local at_end = {}
  for(local i = 0; i < n; i = i + 1){
    if(infos[i] == null){
      append(at_end, entries[i])
    }
  }
  d.by_byte = by_byte
  d.at_end = at_end
  return d
}

// tries the candidates of d at pos; returns the matching entry (its value is
// in ctx.value, the new position in ctx.op_pos) or null
local func try_ops(d, ctx, pos){
  local cands = d.all
  if(d.by_byte != null){
    local p
    if(ctx.skip_from == pos){
      p = ctx.skip_to
    } else {
      p = d.skip(ctx, pos)
      ctx.skip_from = pos
      ctx.skip_to = p
    }
    local b = str.byte_at(ctx.buffer, p)
    if(b == null){
      cands = d.at_end
    } else if(b < 128){
      cands = d.by_byte[b]
      if(cands == null){
        ctx.tried = false
        return null
      }
    }
  }
  ctx.tried = true
  local n = len(cands)
  for(local i = 0; i < n; i = i + 1){
    local c = cands[i]
    local q = c.parser:parse_on(ctx, pos)
    if(q >= 0){
      ctx.op_pos = q
      return c
    }
  }
  return null
}

// dispatch(parsers, skip, message): an ordered choice over parsers that only
// tries, in order, the alternatives whose first byte (after skip(ctx, pos),
// when given) can match. When no alternative can match, message (if given) is recorded
// as the failure. The tables are built now, from the current resolution of
// every rule reference, so a dispatch belongs to one sealed grammar.
func peg.dispatch(parsers, skip, message){
  local entries = {}
  for(let local p in values(parsers)){
    append(entries, {parser: p})
  }
  local d = make_dispatch(entries, skip, {})
  return new_parser(func(self, ctx, pos){
    local cand = try_ops(d, ctx, pos)
    if(cand != null){
      return ctx.op_pos
    }
    if(not ctx.tried and message != null){
      return fail(ctx, ctx.skip_to, message)
    }
    return -1
  }, parsers, "dispatch")
}

// the candidates of d at pos (the entries whose first byte can match, in
// their original order), or null when none can
local func candidates(d, ctx, pos){
  if(d.by_byte == null){
    return d.all
  }
  local p
  if(ctx.skip_from == pos){
    p = ctx.skip_to
  } else {
    p = d.skip(ctx, pos)
    ctx.skip_from = pos
    ctx.skip_to = p
  }
  local b = str.byte_at(ctx.buffer, p)
  if(b == null){
    return d.at_end
  }
  if(b < 128){
    return d.by_byte[b]
  }
  return d.all
}

// ---------------------------------------------------------------- walker
//
// peg.walker(skip) -> walker; skip(ctx, pos) -> pos finds the next byte that
// matters. Registration:
//   w:level(name, {after: tighter, before: looser, at: index, aliases})
//       -> level: a named level (null for an anonymous one); levels form a
//       total order, tightest first; without a placement the level is
//       appended (looser than everything so far). A level whose name or
//       alias is already used replaces that level.
//   w:primary(parser, name, {after, before, aliases})   a primary expression
//   w:prefix(op, level, func(op, operand))  a prefix operator at a level
//   w:postfix(op, level, func(left, op))
//   w:left(op, level, func(left, op, right))   left-associative infix
//   w:right(op, level, func(left, op, right))  right-associative infix
//   w:wrapper(left, right, level, func(left, value, right))
// Engine level, with binding powers (higher binds tighter) and callbacks
// that parse their own operands with w:parse_at(ctx, pos, min_bp):
//   w:nud(op, rbp, func(w, ctx, pos, op) -> pos | -1)
//   w:led(op, lbp, func(w, ctx, pos, left, op) -> pos | -1)
// Binding powers of levels are assigned by build(): level k (0 = tightest)
// gets base (n - k) * 10; within a level, postfix operators and the operand
// of a prefix operator bind at base + 3, right-associative operators at
// base + 2 (operand at base + 1) and left-associative operators at base
// (operand at base), so that within one level prefix < postfix < right <
// left in the order of application, as the nested-group semantics had it.
//
// Rules (those of PEG ordered choice): the nud alternatives are tried in
// order, loosest level first, primaries last; an alternative that fails
// (operator matched, operand not) falls through to the next. Operators of
// one binding power are an ordered choice and the operand is not a
// backtracking point: when the operand of the first matching operator fails,
// the other operators of that binding power are not tried, looser ones are.
//
// build() returns the expression parser (kind "expression"); w.loopback is
// a settable that parses a whole expression, for operators that embed one
// (`a[expr]`). The walker is itself usable as a parser after build().

local walker_methods = {}
local walker_meta = {__index: walker_methods, __type: "walker"}
local level_methods = {}
local level_meta = {__index: level_methods, __type: "expression_level"}

func peg.walker(skip){
  local w = {skip: skip, levels: {}, primaries: {}, nuds: {}, leds: {}, loopback: peg.settable(null), sealed: null}
  w.meta = walker_meta
  return w
}

local func new_level(w, name, aliases){
  local l = {walker: w, name: name, aliases: aliases or {}, wrappers: {}, prefixes: {}, postfixes: {}, rights: {}, lefts: {}}
  l.meta = level_meta
  return l
}

// whether entry (a level or a primary record) goes by name
local func named(entry, name){
  if(name == null){
    return false
  }
  if(entry.name == name){
    return true
  }
  for(let local a in values(entry.aliases)){
    if(a == name){
      return true
    }
  }
  return false
}

local func index_of(list, name){
  local n = len(list)
  for(local i = 0; i < n; i = i + 1){
    if(named(list[i], name)){
      return i
    }
  }
  return -1
}

local func level_index(w, name){
  return index_of(w.levels, name)
}

// inserts entry into list according to placement {after, before, at};
// an entry of the same name is removed first
local func place(list, entry, placement, what){
  placement = placement or {}
  local existing = index_of(list, entry.name)
  if(existing >= 0){
    remove(list, existing)
  }
  local index = len(list)
  if(placement.at != null){
    index = placement.at
  } else if(placement.after != null){
    local i = index_of(list, placement.after)
    if(i < 0){
      error(what, " ", placement.after, " not found")
    }
    index = i + 1
  } else if(placement.before != null){
    local i = index_of(list, placement.before)
    if(i < 0){
      error(what, " ", placement.before, " not found")
    }
    index = i
  }
  if(placement.after != null and placement.before != null){
    local j = index_of(list, placement.before)
    if(j < index){
      error(what, " ", entry.name, " cannot be after ", placement.after, " and before ", placement.before)
    }
  }
  local out = {}
  local n = len(list)
  for(local i = 0; i < n; i = i + 1){
    if(i == index){
      append(out, entry)
    }
    append(out, list[i])
  }
  if(index >= n){
    append(out, entry)
  }
  return out
}

// the level object for a level or a level name
local func resolve_level(w, level){
  if(type(level) == "expression_level"){
    return level
  }
  local i = level_index(w, level)
  if(i < 0){
    error("expression level ", level, " not found")
  }
  return w.levels[i]
}

func walker_methods.level(self, name, placement){
  placement = placement or {}
  local l = new_level(self, name, placement.aliases)
  self.levels = place(self.levels, l, placement, "expression level")
  self.sealed = null
  return l
}

func walker_methods.primary(self, parser, name, placement){
  placement = placement or {}
  local entry = {parser: parser, name: name, aliases: placement.aliases or {}}
  self.primaries = place(self.primaries, entry, placement, "primary expression")
  self.sealed = null
  return self
}

// level_names() -> the level names, tightest first; primary_names() -> the
// names of the primaries
func walker_methods.level_names(self){
  local out = {}
  for(let local l in values(self.levels)){
    append(out, l.name)
  }
  return out
}

func walker_methods.primary_names(self){
  local out = {}
  for(let local p in values(self.primaries)){
    append(out, p.name)
  }
  return out
}

func walker_methods.prefix(self, operator, level, callback){
  append(resolve_level(self, level).prefixes, {parser: operator, callback: callback})
  self.sealed = null
  return self
}

func walker_methods.postfix(self, operator, level, callback){
  append(resolve_level(self, level).postfixes, {parser: operator, callback: callback})
  self.sealed = null
  return self
}

func walker_methods.left(self, operator, level, callback){
  append(resolve_level(self, level).lefts, {parser: operator, callback: callback})
  self.sealed = null
  return self
}

func walker_methods.right(self, operator, level, callback){
  append(resolve_level(self, level).rights, {parser: operator, callback: callback})
  self.sealed = null
  return self
}

func walker_methods.wrapper(self, left, right, level, callback){
  append(resolve_level(self, level).wrappers, {left: left, right: right, callback: callback})
  self.sealed = null
  return self
}

// engine API: explicit binding powers, callbacks that parse their operands
func walker_methods.nud(self, operator, rbp, f){
  append(self.nuds, {parser: operator, kind: "nud", bp: rbp, nud: f})
  self.sealed = null
  return self
}

func walker_methods.led(self, operator, lbp, f){
  append(self.leds, {parser: operator, kind: "led", lbp: lbp, led: f})
  self.sealed = null
  return self
}

// level objects offer the same registration without naming the level
func level_methods.wrapper(self, left, right, callback){
  self.walker:wrapper(left, right, self, callback)
  return self
}

func level_methods.prefix(self, operator, callback){
  self.walker:prefix(operator, self, callback)
  return self
}

func level_methods.postfix(self, operator, callback){
  self.walker:postfix(operator, self, callback)
  return self
}

func level_methods.right(self, operator, callback){
  self.walker:right(operator, self, callback)
  return self
}

func level_methods.left(self, operator, callback){
  self.walker:left(operator, self, callback)
  return self
}

local func copy_entries(list){
  local out = {}
  for(let local e in values(list)){
    append(out, e)
  }
  return out
}

// derive() -> a walker with the same registrations; changes to either do
// not affect the other
func walker_methods.derive(self){
  local w = peg.walker(self.skip)
  for(let local l in values(self.levels)){
    local c = new_level(w, l.name, copy_entries(l.aliases))
    c.wrappers = copy_entries(l.wrappers)
    c.prefixes = copy_entries(l.prefixes)
    c.postfixes = copy_entries(l.postfixes)
    c.rights = copy_entries(l.rights)
    c.lefts = copy_entries(l.lefts)
    append(w.levels, c)
  }
  w.primaries = copy_entries(self.primaries)
  w.nuds = copy_entries(self.nuds)
  w.leds = copy_entries(self.leds)
  return w
}

// binding_powers() -> {name: base} after build (for debugging extensions)
func walker_methods.binding_powers(self){
  local out = {}
  local n = len(self.levels)
  for(local k = 0; k < n; k = k + 1){
    out[self.levels[k].name or concat("level ", k)] = (n - k) * 10
  }
  return out
}

local func sort_entries(list, key, descending){
  // insertion sort: stable, lists are short
  local n = len(list)
  for(local i = 1; i < n; i = i + 1){
    local e = list[i]
    local j = i - 1
    for(j >= 0 and ((descending and list[j][key] < e[key]) or (not descending and list[j][key] > e[key])); j = j - 1){
      list[j + 1] = list[j]
    }
    list[j + 1] = e
  }
  return list
}

// the nud and led tables of a walker from its levels and engine entries
local func build_tables(w){
  local n = len(w.levels)
  local nuds = {}
  local leds = {}
  for(local k = 0; k < n; k = k + 1){
    local l = w.levels[k]
    local base = (n - k) * 10
    for(let local e in values(l.prefixes)){
      local callback = e.callback
      local rbp = base + 3
      append(nuds, {parser: e.parser, kind: "prefix", bp: rbp, nud: func(w, ctx, pos, op){
        local r = w:parse_at(ctx, pos, rbp)
        if(r < 0){
          return -1
        }
        ctx.value = callback(op, ctx.value)
        return r
      }})
    }
    for(let local e in values(l.wrappers)){
      local callback = e.callback
      local right = e.right
      append(nuds, {parser: e.left, kind: "wrapper", bp: base + 3, nud: func(w, ctx, pos, left){
        local r = w:parse_at(ctx, pos, 0)
        if(r < 0){
          return -1
        }
        local value = ctx.value
        local q = right:parse_on(ctx, r)
        if(q < 0){
          return -1
        }
        ctx.value = callback(left, value, ctx.value)
        return q
      }})
    }
    for(let local e in values(l.postfixes)){
      local callback = e.callback
      append(leds, {parser: e.parser, kind: "led", lbp: base + 3, led: func(w, ctx, pos, left, op){
        ctx.value = callback(left, op)
        return pos
      }})
    }
    for(let local e in values(l.rights)){
      local callback = e.callback
      local rbp = base + 1
      append(leds, {parser: e.parser, kind: "led", lbp: base + 2, led: func(w, ctx, pos, left, op){
        local r = w:parse_at(ctx, pos, rbp)
        if(r < 0){
          return -1
        }
        ctx.value = callback(left, op, ctx.value)
        return r
      }})
    }
    for(let local e in values(l.lefts)){
      local callback = e.callback
      local rbp = base
      append(leds, {parser: e.parser, kind: "led", lbp: base, led: func(w, ctx, pos, left, op){
        local r = w:parse_at(ctx, pos, rbp)
        if(r < 0){
          return -1
        }
        ctx.value = callback(left, op, ctx.value)
        return r
      }})
    }
  }
  for(let local e in values(w.nuds)){
    append(nuds, e)
  }
  for(let local e in values(w.leds)){
    append(leds, e)
  }
  // nuds: loosest first (ascending binding power), primaries last
  sort_entries(nuds, "bp", false)
  for(let local p in values(w.primaries)){
    append(nuds, {parser: p.parser, kind: "primary", bp: 0})
  }
  // leds: tightest first
  sort_entries(leds, "lbp", true)
  local memo = {}
  local sealed = {
    nuds: make_dispatch(nuds, w.skip, memo),
    leds: make_dispatch(leds, w.skip, memo),
  }
  // the first set of an expression: what a nud can start with
  local first = {}
  for(let local e in values(nuds)){
    first = union(first, info_of(e.parser, memo, {}).first)
  }
  sealed.first = first
  return sealed
}

// parse_at(ctx, pos, min_bp) -> pos | -1: an expression whose operators
// bind tighter than min_bp; the value is in ctx.value
func walker_methods.parse_at(self, ctx, pos, min_bp){
  local sealed = self.sealed
  local cands = candidates(sealed.nuds, ctx, pos)
  local value = null
  local q = -1
  local tried_primary = false
  if(cands != null){
    local n = len(cands)
    for(local i = 0; i < n; i = i + 1){
      local e = cands[i]
      if(e.kind == "primary"){
        tried_primary = true
        local r = e.parser:parse_on(ctx, pos)
        if(r >= 0){
          value = ctx.value
          q = r
          break
        }
      } else {
        local r = e.parser:parse_on(ctx, pos)
        if(r >= 0){
          r = e.nud(self, ctx, r, ctx.value)
          if(r >= 0){
            value = ctx.value
            q = r
            break
          }
        }
      }
    }
  }
  if(q < 0){
    if(not tried_primary){
      return fail(ctx, pos, "expression expected")
    }
    return -1
  }
  for(true){
    local lc = candidates(sealed.leds, ctx, q)
    if(lc == null){
      break
    }
    local matched = false
    local n = len(lc)
    local i = 0
    for(i < n){
      local e = lc[i]
      if(e.lbp <= min_bp){
        break
      }
      local r = e.parser:parse_on(ctx, q)
      if(r >= 0){
        r = e.led(self, ctx, r, value, ctx.value)
        if(r >= 0){
          value = ctx.value
          q = r
          matched = true
          break
        }
        // the operand failed: the other operators of this binding power
        // are not tried (ordered choice), looser ones are
        local lbp = e.lbp
        for(i < n and lc[i].lbp == lbp){
          i = i + 1
        }
      } else {
        i = i + 1
      }
    }
    if(not matched){
      break
    }
  }
  ctx.value = value
  return q
}

// build() -> the expression parser
func walker_methods.build(self){
  self.sealed = build_tables(self)
  local w = self
  local children = {}
  for(let local e in values(self.sealed.nuds.all)){
    append(children, e.parser)
  }
  for(let local e in values(self.sealed.leds.all)){
    append(children, e.parser)
  }
  local expr = new_parser(func(self, ctx, pos){
    return w:parse_at(ctx, pos, 0)
  }, children, "expression")
  if(self.sealed.first != null){
    expr.first = self.sealed.first
    expr.nullable = false
  }
  self.loopback:set(expr)
  self.parser = expr
  return expr
}

// ---------------------------------------------------------------------- methods

methods.tag = peg.tag
methods.seq = peg.seq
methods.choice = peg.choice
methods.star = peg.star
methods.plus = peg.plus
methods.optional = peg.optional
methods.star_lazy = peg.star_lazy
methods.star_separated = peg.star_separated
methods.star_seperated = peg.star_separated
methods.plus_separated = peg.plus_separated
methods.plus_seperated = peg.plus_separated
methods.forbid = peg.forbid
methods.and = peg.and
methods.neg = peg.neg
methods.pick = peg.pick
methods.permute = peg.permute
methods.map = peg.map
methods.flatten = peg.flatten
methods.token = peg.token
methods.trim = peg.trim
methods.where = peg.where
methods.end = peg.end
methods.labeled = peg.labeled
methods.parse = peg.parse
methods.run = peg.run

return peg
