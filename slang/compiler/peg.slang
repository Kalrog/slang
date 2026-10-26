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

func peg.context(buffer){
  return {
    buffer: buffer,
    len: len(buffer),
    fail_pos: -1,
    far_pos: -1,
    memo: {},
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

func peg.token(child){
  return new_parser(func(self, ctx, pos){
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    ctx.value = peg.make_token(ctx, ctx.value, pos, q)
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

// ---------------------------------------------------------- expression builder
//
// Groups are applied in order; group 0 binds tightest. Each group is the
// equivalent of nesting, from the inside out: wrappers (around the whole
// expression), prefix operators, postfix operators, right-associative and
// left-associative infix operators, on top of the previous group. build()
// produces a single recursive parser with exactly those semantics, but
// without the intermediate lists of the combinator version, and with
// operators and primitives dispatched on the first byte after whitespace
// (when the builder has a `skip` function: skip(buffer, pos) -> pos).

local group_methods = {}
local group_meta = {__index: group_methods, __type: "expression_group"}
local builder_methods = {}
local builder_meta = {__index: builder_methods, __type: "expression_builder"}

func peg.expression_builder(skip){
  local b = {primitives: {}, groups: {}, loopback: peg.settable(null), skip: skip}
  b.meta = builder_meta
  return b
}

func builder_methods.primitive(self, parser){
  append(self.primitives, parser)
}

func builder_methods.group(self){
  local g = {wrappers: {}, prefixes: {}, postfixes: {}, rights: {}, lefts: {}, loopback: self.loopback}
  g.meta = group_meta
  append(self.groups, g)
  return g
}

func group_methods.wrapper(self, left, right, callback){
  append(self.wrappers, {left: left, right: right, callback: callback})
  return self
}

func group_methods.prefix(self, operator, callback){
  append(self.prefixes, {parser: operator, callback: callback})
  return self
}

func group_methods.postfix(self, operator, callback){
  append(self.postfixes, {parser: operator, callback: callback})
  return self
}

func group_methods.right(self, operator, callback){
  append(self.rights, {parser: operator, callback: callback})
  return self
}

func group_methods.left(self, operator, callback){
  append(self.lefts, {parser: operator, callback: callback})
  return self
}

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
  } else if(kind == "plus" or kind == "pick" or kind == "permute" or kind == "map" or kind == "flatten" or kind == "token" or kind == "trim" or kind == "where"){
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

// a dispatch table: candidates per first byte, in the original order
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
      p = d.skip(ctx.buffer, pos)
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
// tries, in order, the alternatives whose first byte (after skip, when given)
// can match. When no alternative can match, message (if given) is recorded
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

func builder_methods.build(self){
  local skip = self.skip
  local memo = {}
  local children = {}
  local prim_entries = {}
  for(let local p in values(self.primitives)){
    append(prim_entries, {parser: p})
    append(children, p)
  }
  local prim_dispatch = make_dispatch(prim_entries, skip, memo)
  local levels = {}
  for(let local g in values(self.groups)){
    local level = {wrappers: g.wrappers}
    for(let local w in values(g.wrappers)){
      append(children, w.left)
      append(children, w.right)
    }
    for(let local kind in values({"prefixes", "postfixes", "rights", "lefts"})){
      local ops = g[kind]
      if(len(ops) > 0){
        level[kind] = make_dispatch(ops, skip, memo)
        for(let local o in values(ops)){
          append(children, o.parser)
        }
      }
    }
    append(levels, level)
  }
  local n = len(levels)
  local loopback = self.loopback

  local parse_level

  local func parse_primitives(ctx, pos){
    local cand = try_ops(prim_dispatch, ctx, pos)
    if(cand == null){
      if(not ctx.tried){
        return fail(ctx, pos, "expression expected")
      }
      return -1
    }
    return ctx.op_pos
  }

  local func parse_wrapper(ctx, pos, k){
    local wrappers = levels[k].wrappers
    local nw = len(wrappers)
    for(local i = 0; i < nw; i = i + 1){
      local w = wrappers[i]
      local q = w.left:parse_on(ctx, pos)
      if(q >= 0){
        local left_value = ctx.value
        q = loopback:parse_on(ctx, q)
        if(q >= 0){
          local value = ctx.value
          q = w.right:parse_on(ctx, q)
          if(q >= 0){
            ctx.value = w.callback(left_value, value, ctx.value)
            return q
          }
        }
      }
    }
    return parse_level(ctx, pos, k - 1)
  }

  local func parse_prefix(ctx, pos, k){
    local d = levels[k].prefixes
    if(d == null){
      return parse_wrapper(ctx, pos, k)
    }
    local ops = null
    for(true){
      local cand = try_ops(d, ctx, pos)
      if(cand == null){
        break
      }
      if(ops == null){
        ops = {}
      }
      append(ops, {op: ctx.value, callback: cand.callback})
      pos = ctx.op_pos
    }
    local q = parse_wrapper(ctx, pos, k)
    if(q < 0){
      return -1
    }
    if(ops != null){
      local value = ctx.value
      for(local i = len(ops) - 1; i >= 0; i = i - 1){
        local o = ops[i]
        value = o.callback(o.op, value)
      }
      ctx.value = value
    }
    return q
  }

  local func parse_postfix(ctx, pos, k){
    local q = parse_prefix(ctx, pos, k)
    if(q < 0){
      return -1
    }
    local d = levels[k].postfixes
    if(d == null){
      return q
    }
    local value = ctx.value
    for(true){
      local cand = try_ops(d, ctx, q)
      if(cand == null){
        break
      }
      value = cand.callback(value, ctx.value)
      q = ctx.op_pos
    }
    ctx.value = value
    return q
  }

  local func parse_right(ctx, pos, k){
    local q = parse_postfix(ctx, pos, k)
    if(q < 0){
      return -1
    }
    local d = levels[k].rights
    if(d == null){
      return q
    }
    local first = ctx.value
    local elements = null
    local ops = null
    for(true){
      local cand = try_ops(d, ctx, q)
      if(cand == null){
        break
      }
      local op = ctx.value
      local r = parse_postfix(ctx, ctx.op_pos, k)
      if(r < 0){
        break
      }
      if(elements == null){
        elements = {}
        list_push(elements, first)
        ops = {}
      }
      list_push(elements, ctx.value)
      append(ops, {op: op, callback: cand.callback})
      q = r
    }
    if(elements == null){
      ctx.value = first
      return q
    }
    local result = elements[len(elements) - 1]
    for(local i = len(elements) - 2; i >= 0; i = i - 1){
      local o = ops[i]
      result = o.callback(elements[i], o.op, result)
    }
    ctx.value = result
    return q
  }

  local func parse_left(ctx, pos, k){
    local q = parse_right(ctx, pos, k)
    if(q < 0){
      return -1
    }
    local d = levels[k].lefts
    if(d == null){
      return q
    }
    local value = ctx.value
    for(true){
      local cand = try_ops(d, ctx, q)
      if(cand == null){
        break
      }
      local op = ctx.value
      local r = parse_right(ctx, ctx.op_pos, k)
      if(r < 0){
        break
      }
      value = cand.callback(value, op, ctx.value)
      q = r
    }
    ctx.value = value
    return q
  }

  func parse_level(ctx, pos, k){
    if(k < 0){
      return parse_primitives(ctx, pos)
    }
    return parse_left(ctx, pos, k)
  }

  local expr = new_parser(func(self, ctx, pos){
    return parse_level(ctx, pos, n - 1)
  }, children, "expression")
  // an expression starts with a primitive, a wrapper or a prefix operator
  local first = {}
  for(let local p in values(self.primitives)){
    first = union(first, info_of(p, memo, {}).first)
  }
  for(let local g in values(self.groups)){
    for(let local w in values(g.wrappers)){
      first = union(first, info_of(w.left, memo, {}).first)
    }
    for(let local o in values(g.prefixes)){
      first = union(first, info_of(o.parser, memo, {}).first)
    }
  }
  if(first != null){
    expr.first = first
    expr.nullable = false
  }
  self.loopback:set(expr)
  return expr
}

// ---------------------------------------------------------------------- methods

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
