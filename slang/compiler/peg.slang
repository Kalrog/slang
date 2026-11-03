// slang/peg: parser combinators in the style of petitparser (PEG: ordered
// choice, no ambiguity), the expression walker extensions add operators
// with, and the lossless tree that highlighting and formatting read.
// Grammar extensions build their syntax with it (see slang/grammar).
//
//   local peg = require("slang/peg")
//   local number = peg.digit():plus():flatten():trim():map(to_int)
//   local numbers = number:star_separated(peg.char(",")):map(func(r){
//     return r.elements
//   })
//   numbers:end():parse("1, 2 ,3")      // {"ok", {1, 2, 3}}
//   numbers:end():parse("1, x")         // {"error", "end of input expected at 1:2"}
//
// Every combinator is a function of peg and a method of [Parser]:
// `peg.star(p)` is `p:star()`. A parser matches at a position and produces
// a value: a primitive its text, [seq] the list of its children's values,
// [map] what its function returns, and so on. Strings are not parsers:
// write peg.string("if"), not "if". A parser is also a matcher in
// patterns: `let 'numbers as local xs = "7,8"` parses the whole string
// and matches the value.
//
// Under the methods, a parser is a table with a `parse_on` function:
//   parser:parse_on(ctx, pos) -> new position, or -1 on failure
// On success the parsed value is left in ctx.value. On failure the message and
// position are recorded in ctx.fail_msg / ctx.fail_pos (the last failure wins,
// like petitparser's choice), and the farthest failure in ctx.far_* (see
// [Context]). [custom] makes a parser from such a function.
//
// A parser can also build the lossless tree of what it parsed:
// peg.parse_tree(parser, ctx, pos) parses like parse_on and leaves the node
// of the parser in ctx.tree (a [Tree]). A node without kids is a leaf and
// stands for the text it spans. Every character a parse consumes is covered
// by exactly one leaf, so joining the leaves gives back the input
// ([text]). Parsing for a tree is a separate path (see "the lossless tree"
// below), so a parse without one costs nothing extra; a parser that has no
// tree path of its own becomes a leaf. [run] with {tree: true} returns one;
// [evaluate] computes values from it in layers, [highlights] the
// highlighter's spans.

// The state of one parse, passed to every parse_on. Custom parsers read the
// input from it and leave their value in it.
// type Context = {buffer: string, len: int, value: any, fail_pos: int,
//   fail_msg?: string, far_pos: int, far_msg?: string, tree?: Tree,
//   tree_on: bool}
// [buffer]: the input
// [len]: the length of the input in bytes
// [value]: the value of the parser that succeeded last
// [fail_pos]: where the last failure happened (-1: none yet)
// [fail_msg]: what the last failure expected
// [far_pos]: the farthest position a failure happened at
// [far_msg]: the message of the farthest failure
// [tree]: the node a tree path left (see [parse_tree])
// [tree_on]: whether this parse builds a tree

// A node of the lossless tree: what parser p matched from start to stop
// (byte offsets, stop exclusive).
// type Tree = {p: any, start: int, stop: int, kids?: {Tree}, value?: any}
// [p]: the parser, or the walker entry of an operator application
// [kids]: the children in source order; null for a leaf (it stands for its text)
// [value]: the value the parser produced (the default layer)

// A token: what [token] produces. line and column (1-based) are computed
// when first read.
// type Token = {value: any, start: int, stop: int, line: int, column: int,
//   category?: string}
// [value]: the value of the parser inside (for a string or flatten, the text)
// [category]: what a highlighter shows it as

// What [run] returns.
// type Result = {ok: bool, value?: any, position: int, tree?: Tree,
//   message?: string, line?: int, column?: int, far_message?: string,
//   far_line?: int, far_column?: int}
// [position]: where the parse stopped; on failure, where it failed
// [tree]: the lossless tree, with {tree: true}
// [message]: on failure, what was expected (the last failure)
// [far_message]: on failure, the farthest failure, often the better message

local str = require("slang/string")
local regex = require("slang/regex")
local utf8 = require("slang/utf8")
local tbl = require("slang/table")

// slang's whitespace (what Go's unicode.IsSpace accepts) and `//` comments
local space_class = "[\\t\\n\\x0B\\f\\r \\x{85}\\x{A0}\\x{1680}\\x{2000}-\\x{200A}\\x{2028}\\x{2029}\\x{202F}\\x{205F}\\x{3000}]"
local space_char = regex.compile(space_class)
local space_run = regex.compile(concat("(?:", space_class, "+|//[^\\n]*)*"))
// the method as a plain function: the hot paths call it without a method
// lookup
local match_at = space_run.match_at

// The regex character class of a pattern spec: the spec's characters and
// ranges, with the regex metacharacters of a class escaped.
local func class_regex(spec){
  local out = {"["}
  for(let local c in values(str.split(spec, ""))){
    if(c == "\\" or c == "]" or c == "["){
      append(out, "\\")
    }
    append(out, c)
  }
  append(out, "]")
  return str.join(out, "")
}

local peg = {}
// A parser. Every combinator of the module is also one of its methods, with
// the parser as its first argument: `p:map(f)` is `peg.map(p, f)`. Its
// fields: parse_on(self, ctx, pos) and fast(self, ctx, pos) (the same
// parse without building values), kind (the combinator's name), children.
// type Parser
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
  local p = {
    parse_on: parse_on,
    fast: fast or parse_on,
    id: next_id,
    children: children or {},
    kind: kind or "custom",
  }
  p.@meta = parser_meta
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

local func node(p, start, stop, kids){
  return {p: p, start: start, stop: stop, kids: kids}
}

local func leaf(p, start, stop){
  return {p: p, start: start, stop: stop}
}

// node(p, start: int, stop: int, kids: {Tree}) -> Tree
// A tree node, for the tree paths of custom parsers (see [custom]).
peg.node = node
// leaf(p, start: int, stop: int) -> Tree
// A leaf of the tree (no kids), for the tree paths of custom parsers.
peg.leaf = leaf

// the tree paths by parser kind, filled in "the lossless tree" below
local tree_kinds = {}

// the parser of the trivia a raw leaf ends with
local trailing_trivia = {kind: "trivia", trivia: true}

// a leaf of raw text: what a parser without a tree path consumed. When the
// context knows where trivia starts (ctx.trivia_start(buffer, from, to) ->
// position, set by a grammar), the whitespace and comments it ends with are
// a trivia leaf of their own: a node {raw: true} with the two leaves.
local func raw_leaf(p, ctx, start, stop){
  local f = ctx.trivia_start
  if(f != null and stop > start){
    local k = f(ctx.buffer, start, stop)
    if(k > start and k < stop){
      local n = node(p, start, stop, {
        leaf(p, start, k),
        leaf(trailing_trivia, k, stop),
      })
      n.raw = true
      return n
    }
  }
  return leaf(p, start, stop)
}

// The trees of what a parser without a tree path parses through others:
// while it runs, ctx.collect is a list, and the parsers that can build a
// tree on their own (rules of a grammar, the expression walker) put theirs
// there (see peg.collect). A tree that starts before the end of the one
// before it was parsed on a path that was backtracked over and is left out.
local func weave(p, ctx, start, stop, trees){
  local kids = {}
  local at = start
  for(local i = 0; i < len(trees); i = i + 1){
    local t = trees[i]
    if(t.start >= at and t.stop <= stop and t.stop > t.start){
      if(t.start > at){
        list_push(kids, raw_leaf(p, ctx, at, t.start))
      }
      list_push(kids, t)
      at = t.stop
    }
  }
  if(at < stop){
    list_push(kids, raw_leaf(p, ctx, at, stop))
  }
  return kids
}

// a custom parser without a tree path of its own: a leaf of what it
// consumed, or woven from the trees of the rules it parsed
local func tree_custom(p, ctx, pos){
  local saved = ctx.collect
  local trees = {}
  ctx.collect = trees
  local q = p:parse_on(ctx, pos)
  ctx.collect = saved
  if(q >= 0){
    if(len(trees) == 0){
      ctx.tree = raw_leaf(p, ctx, pos, q)
    } else {
      local n = node(p, pos, q, weave(p, ctx, pos, q, trees))
      n.woven = true
      ctx.tree = n
    }
  }
  return q
}

// the other parsers without a tree path (strings, patterns, flatten, ...)
// are leaves of what they consumed
local func tree_leaf(p, ctx, pos){
  if(p.kind == "custom"){
    return tree_custom(p, ctx, pos)
  }
  local q = p:parse_on(ctx, pos)
  if(q >= 0){
    // (what a flatten consumed may end with trivia)
    if(p.kind == "flatten"){
      ctx.tree = raw_leaf(p, ctx, pos, q)
    } else {
      ctx.tree = leaf(p, pos, q)
    }
  }
  return q
}

// every node keeps the value its parser produced (node.value): the default
// layer of the tree
local func tparse(p, ctx, pos){
  local f = p.parse_tree
  if(f == null){
    f = tree_kinds[p.kind] or tree_leaf
  }
  local q = f(p, ctx, pos)
  if(q >= 0){
    ctx.tree.value = ctx.value
  }
  return q
}

// parse_tree(parser: Parser, ctx: Context, pos: int) -> int
// Parses like parser:parse_on(ctx, pos) (the new position, or -1) and also
// leaves the node of parser in ctx.tree, with its value in node.value. For
// the tree paths of custom parsers; [run] with {tree: true} does it for a
// whole input.
peg.parse_tree = tparse

// collect(ctx: Context, pos: int,
//   tree_path: func(ctx: Context, pos: int): int) -> int
// For code that runs inside a parser without a tree path while ctx.collect
// is set: parses with tree_path(ctx, pos) and adds the tree it left to the
// trees the enclosing node is woven from. Returns the new position or -1.
// [sub] is the usual way in.
func peg.collect(ctx, pos, tree_path){
  local list = ctx.collect
  ctx.collect = null
  local q = tree_path(ctx, pos)
  ctx.collect = list
  if(q >= 0){
    list_push(list, ctx.tree)
  }
  return q
}

// sub(parser: Parser, ctx: Context, pos: int) -> int
// parser:parse_on(ctx, pos), for a custom parser that parses others itself.
// When a tree is being built, their tree becomes part of the custom
// parser's node (highlighting and formatting see inside it).
func peg.sub(parser, ctx, pos){
  if(ctx.collect != null){
    return peg.collect(ctx, pos, func(c, at){ return tparse(parser, c, at) })
  }
  return parser:parse_on(ctx, pos)
}

// context(buffer: string, options?: {tree?: bool}) -> Context
// A fresh parse context for buffer; tree marks a context parsed with
// [parse_tree]. [run] and [parse] make their own.
func peg.context(buffer, options){
  local tree_on = false
  if(options != null){
    tree_on = options.tree == true
  }
  return {
    buffer: buffer,
    len: len(buffer),
    fail_pos: -1,
    far_pos: -1,
    tree_on: tree_on,
    collect: null,
    memo: {},
    // results of memoized rules (peg.memoize); the phrase loop clears it
    // before every top-level statement
    rule_memo: {},
  }
}

// line_col(ctx: Context, pos: int) -> {int}
// {line, column} of a byte offset, both 1-based.
func peg.line_col(ctx, pos){
  return str.line_col(ctx.buffer, pos)
}

// a token's line and column are computed when first read: most tokens are
// never asked (those of alternatives that lost, of a parse for highlighting)
local token_meta = {
  __index: func(t, key){
    if(key != "line" and key != "column"){
      return null
    }
    local lc = str.line_col(t.buffer, t.start)
    t.line = lc[0]
    t.column = lc[1]
    return key == "line" and lc[0] or lc[1]
  },
}

// The metatable of tokens, for parsers that make their own: a table
// {value, start, stop, buffer} with it gets line and column on demand.
peg.token_meta = token_meta

// make_token(ctx: Context, value, start: int, stop: int) -> Token
// A token for ctx's input, without a category.
func peg.make_token(ctx, value, start, stop){
  return {
    value: value, start: start, stop: stop, buffer: ctx.buffer, @meta: token_meta
  }
}

// is_parser(value) -> bool
func peg.is_parser(value){
  return type(value) == "parser"
}

// ---------------------------------------------------------------- primitives

// string(s: string, message?: string) -> Parser
// Matches s exactly; its value is s.
// [message]: the failure message, `"s" expected` by default
func peg.string(s, message){
  local msg = message or concat("\"", s, "\" expected")
  local n = len(s)
  local p = new_parser(func(self, ctx, pos){
    if(str.starts_with(ctx.buffer, s, pos)){
      ctx.value = s
      return pos + n
    }
    // fail(ctx, pos, msg), inlined: strings fail more than anything else
    ctx.fail_pos = pos
    ctx.fail_msg = msg
    if(pos > ctx.far_pos){
      ctx.far_pos = pos
      ctx.far_msg = msg
    }
    return -1
  }, null, "string")
  p.literal = s
  return p
}

// char(c: string, message?: string) -> Parser
// The same as [string]; c is usually one character.
func peg.char(c, message){
  return peg.string(c, message or concat("\"", c, "\" expected"))
}

// pattern(spec: string, message?: string) -> Parser
// One character of a class: single characters and ranges, negated by a
// leading `^` (a regex character class without the brackets). Its value is
// the character. [star] and [plus] of a pattern run natively.
//   peg.pattern("a-zA-Z_")
func peg.pattern(spec, message){
  local cls = regex.compile(class_regex(spec))
  local msg = message or concat("[", spec, "] expected")
  local p = new_parser(
    func(self, ctx, pos){
      local q = match_at(cls, ctx.buffer, pos)
      if(q > 0){
        ctx.value = str.substring(ctx.buffer, pos, q)
        return q
      }
      return fail(ctx, pos, msg)
    },
    null,
    "pattern",
    func(self, ctx, pos){
      local q = match_at(cls, ctx.buffer, pos)
      if(q > 0){
        return q
      }
      return fail(ctx, pos, msg)
    },
  )
  p.class = cls
  p.run = regex.compile(concat(class_regex(spec), "*"))
  p.spec = spec
  return p
}

// any(message?: string) -> Parser
// Any one character (a UTF-8 sequence); fails only at the end of the input.
func peg.any(message){
  local msg = message or "input expected"
  return new_parser(
    func(self, ctx, pos){
      local n = utf8.size_at(ctx.buffer, pos)
      if(n > 0){
        ctx.value = str.substring(ctx.buffer, pos, pos + n)
        return pos + n
      }
      return fail(ctx, pos, msg)
    },
    null,
    "any",
    func(self, ctx, pos){
      local n = utf8.size_at(ctx.buffer, pos)
      if(n > 0){
        return pos + n
      }
      return fail(ctx, pos, msg)
    },
  )
}

// digit(message?: string) -> Parser: one character 0-9
func peg.digit(message){
  return peg.pattern("0-9", message or "digit expected")
}

// letter(message?: string) -> Parser: one character a-z or A-Z
func peg.letter(message){
  return peg.pattern("a-zA-Z", message or "letter expected")
}

// word(message?: string) -> Parser
// One letter, digit or underscore (not a whole word: use [plus]).
func peg.word(message){
  return peg.pattern("a-zA-Z0-9_", message or "letter or digit expected")
}

// whitespace(message?: string) -> Parser
// One whitespace character; the default trimmer of [trim].
func peg.whitespace(message){
  local msg = message or "whitespace expected"
  return new_parser(
    func(self, ctx, pos){
      local q = match_at(space_char, ctx.buffer, pos)
      if(q > 0){
        ctx.value = str.substring(ctx.buffer, pos, q)
        return q
      }
      return fail(ctx, pos, msg)
    },
    null,
    "whitespace",
    func(self, ctx, pos){
      local q = match_at(space_char, ctx.buffer, pos)
      if(q > 0){
        return q
      }
      return fail(ctx, pos, msg)
    },
  )
}

// end_of_input(message?: string) -> Parser
// Succeeds, with value null, only at the end of the input.
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

// epsilon(value?) -> Parser
// Always succeeds without consuming anything; its value is value.
func peg.epsilon(value){
  return new_parser(func(self, ctx, pos){
    ctx.value = value
    return pos
  }, null, "epsilon")
}

// failure(message: string) -> Parser: always fails with message
func peg.failure(message){
  return new_parser(func(self, ctx, pos){
    return fail(ctx, pos, message)
  }, null, "failure")
}

// --------------------------------------------------------------- combinators

local func choice_list(parsers){
  local n = len(parsers)
  return new_parser(
    func(self, ctx, pos){
      for(local i = 0; i < n; i = i + 1){
        local child = parsers[i]
        local p = child:parse_on(ctx, pos)
        if(p >= 0){
          return p
        }
      }
      return -1
    },
    parsers,
    "choice",
    func(self, ctx, pos){
      for(local i = 0; i < n; i = i + 1){
        local child = parsers[i]
        local p = child.fast(child, ctx, pos)
        if(p >= 0){
          return p
        }
      }
      return -1
    },
  )
}

local func seq_list(parsers){
  local n = len(parsers)
  return new_parser(
    func(self, ctx, pos){
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
    },
    parsers,
    "seq",
    func(self, ctx, pos){
      for(local i = 0; i < n; i = i + 1){
        local child = parsers[i]
        pos = child.fast(child, ctx, pos)
        if(pos < 0){
          return -1
        }
      }
      return pos
    },
  )
}

// seq(...parsers: Parser) -> Parser
// Each parser in turn; fails if any fails. Its value is the list of their
// values (a new list on every parse).
func peg.seq(...parsers){
  return seq_list(parsers)
}

// choice(...parsers: Parser) -> Parser
// The first parser that succeeds (ordered choice: once one matched, the
// others are not tried, even when what follows fails). Its value is that
// parser's.
func peg.choice(...parsers){
  return choice_list(parsers)
}

// seq_list(parsers: {Parser}) -> Parser: [seq] of a list
func peg.seq_list(parsers){
  return seq_list(parsers)
}

// choice_list(parsers: {Parser}) -> Parser: [choice] of a list
func peg.choice_list(parsers){
  return choice_list(parsers)
}

// star(child: Parser) -> Parser
// child zero or more times, as often as it matches (greedy, no
// backtracking); its value is the list of child's values. A match that
// consumes nothing ends the repetition.
func peg.star(child){
  local fast
  if(child.kind == "pattern"){
    local run = child.run
    fast = func(self, ctx, pos){
      return match_at(run, ctx.buffer, pos)
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

// plus(child: Parser) -> Parser
// child one or more times; otherwise as [star].
func peg.plus(child){
  local fast
  if(child.kind == "pattern"){
    local run = child.run
    local msg = concat("[", child.spec, "] expected")
    fast = func(self, ctx, pos){
      local q = match_at(run, ctx.buffer, pos)
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

// optional(child: Parser, default_value?) -> Parser
// child, or nothing: when child fails it succeeds without consuming, with
// default_value (null by default) as its value.
func peg.optional(child, default_value){
  local p = new_parser(
    func(self, ctx, pos){
      local q = child:parse_on(ctx, pos)
      if(q < 0){
        ctx.value = default_value
        return pos
      }
      return q
    },
    {child},
    "optional",
    func(self, ctx, pos){
      local q = child.fast(child, ctx, pos)
      if(q < 0){
        return pos
      }
      return q
    },
  )
  p.default_value = default_value
  return p
}

// star_lazy(child: Parser, limit: Parser) -> Parser
// child repeated until limit matches; limit is tried first at every
// position and is not consumed. Fails when child fails before limit
// matched. Its value is the list of child's values.
//   peg.any():star_lazy(peg.string("*/")):flatten()   // a comment's text
func peg.star_lazy(child, limit){
  return new_parser(
    func(self, ctx, pos){
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
    },
    {child, limit},
    "star_lazy",
    func(self, ctx, pos){
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
    },
  )
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

// The value of [star_separated] and [plus_separated].
// type Separated = {elements: {any}, separators: {any}}
// [elements]: the values of the elements
// [separators]: the values of the separators between them

// star_separated(child: Parser, separator: Parser) -> Parser
// Zero or more child separated by separator; a separator is only consumed
// when an element follows it. Its value is a [Separated].
//   peg.digit():star_separated(peg.char(","))   // "1,2,3"
func peg.star_separated(child, separator){
  return separated(child, separator, false)
}

// plus_separated(child: Parser, separator: Parser) -> Parser
// One or more child separated by separator; otherwise as [star_separated].
func peg.plus_separated(child, separator){
  return separated(child, separator, true)
}

// forbid(child: Parser, message?: string) -> Parser
// Negative lookahead: succeeds, with value null, only where child fails;
// consumes nothing.
// [message]: the failure where child matches, "success not expected" by default
func peg.forbid(child, message){
  local msg = message or "success not expected"
  return new_parser(
    func(self, ctx, pos){
      if(child.fast(child, ctx, pos) >= 0){
        return fail(ctx, pos, msg)
      }
      ctx.value = null
      return pos
    },
    {child},
    "forbid",
    func(self, ctx, pos){
      if(child.fast(child, ctx, pos) >= 0){
        return fail(ctx, pos, msg)
      }
      return pos
    },
  )
}

// and(child: Parser) -> Parser
// Lookahead: succeeds, with value null, where child succeeds; consumes
// nothing.
func peg.and(child){
  return new_parser(
    func(self, ctx, pos){
      if(child.fast(child, ctx, pos) < 0){
        return -1
      }
      ctx.value = null
      return pos
    },
    {child},
    "and",
    func(self, ctx, pos){
      if(child.fast(child, ctx, pos) < 0){
        return -1
      }
      return pos
    },
  )
}

// neg(child: Parser, message?: string) -> Parser
// Any one character where child does not match; its value is the character.
//   peg.char("\""):neg():star()   // the inside of a string
func peg.neg(child, message){
  local msg = message or "input not expected"
  return new_parser(
    func(self, ctx, pos){
      if(child.fast(child, ctx, pos) >= 0){
        return fail(ctx, pos, msg)
      }
      local n = utf8.size_at(ctx.buffer, pos)
      if(n > 0){
        ctx.value = str.substring(ctx.buffer, pos, pos + n)
        return pos + n
      }
      return fail(ctx, pos, "input expected")
    },
    {child},
    "neg",
    func(self, ctx, pos){
      if(child.fast(child, ctx, pos) >= 0){
        return fail(ctx, pos, msg)
      }
      local n = utf8.size_at(ctx.buffer, pos)
      if(n > 0){
        return pos + n
      }
      return fail(ctx, pos, "input expected")
    },
  )
}

// pick(child: Parser, index: int) -> Parser
// child (whose value is a list, as a [seq]'s) with the element at index as
// its value; a negative index counts from the end.
//   peg.seq(open, body, close):pick(1)
func peg.pick(child, index){
  local p = new_parser(
    func(self, ctx, pos){
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
    },
    {child},
    "pick",
    func(self, ctx, pos){
      return child.fast(child, ctx, pos)
    },
  )
  p.index = index
  return p
}

// permute(child: Parser, ...indices: int) -> Parser
// child (whose value is a list) with a list of the elements at indices as
// its value; negative indices count from the end.
func peg.permute(child, ...indices){
  local n = len(indices)
  local p = new_parser(
    func(self, ctx, pos){
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
    },
    {child},
    "permute",
    func(self, ctx, pos){
      return child.fast(child, ctx, pos)
    },
  )
  p.indices = indices
  return p
}

// map(child: Parser, f: func(value): any) -> Parser
// child with f(value) as its value. f runs on every match, also of
// alternatives that are later backtracked over, so it should not have
// effects; a memoized parser shares one result, so f must not change its
// input either.
func peg.map(child, f){
  local p = new_parser(func(self, ctx, pos){
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    ctx.value = f(ctx.value)
    return q
  }, {child}, "map")
  p.fn = f
  return p
}

// flatten(child: Parser, message?: string) -> Parser
// child with the text it consumed as its value. child is parsed without
// building values where that can be skipped ([map] and [where] still run).
// [message]: replaces child's failure message
func peg.flatten(child, message){
  local p = new_parser(
    func(self, ctx, pos){
      local q = child.fast(child, ctx, pos)
      if(q < 0){
        if(message != null){
          return fail(ctx, pos, message)
        }
        return -1
      }
      ctx.value = str.substring(ctx.buffer, pos, q)
      return q
    },
    {child},
    "flatten",
    func(self, ctx, pos){
      local q = child.fast(child, ctx, pos)
      if(q < 0 and message != null){
        return fail(ctx, pos, message)
      }
      return q
    },
  )
  // what it is called, for descriptions of the grammar (slang doc's EBNF)
  p.message = message
  return p
}

// token(child: Parser, category?: string | func(value): string?) -> Parser
// child with a [Token] of what it consumed as its value (its value
// inside). The category is what a highlighter shows (see [highlights]); it
// may be a function of child's value returning the category or null (a
// word that is a keyword only in some cases).
func peg.token(child, category){
  local static = null
  if(type(category) == "string"){
    static = category
  }
  local p = new_parser(
    func(self, ctx, pos){
      local q = child:parse_on(ctx, pos)
      if(q < 0){
        return -1
      }
      local t = peg.make_token(ctx, ctx.value, pos, q)
      if(static != null){
        t.category = static
      }
      ctx.value = t
      return q
    },
    {child},
    "token",
    func(self, ctx, pos){
      return child.fast(child, ctx, pos)
    },
  )
  p.category = category
  return p
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

// trim(child: Parser, before?: Parser, after?: Parser) -> Parser
// child with whatever before matches skipped in front of it and whatever
// after matches skipped behind it; each trimmer is applied as often as it
// matches. Its value is child's.
// [before]: [whitespace] by default
// [after]: before by default
func peg.trim(child, before, after){
  before = before or default_trimmer
  after = after or before
  return new_parser(
    func(self, ctx, pos){
      pos = consume(before, ctx, pos)
      local q = child:parse_on(ctx, pos)
      if(q < 0){
        return -1
      }
      local v = ctx.value
      q = consume(after, ctx, q)
      ctx.value = v
      return q
    },
    {child, before, after},
    "trim",
    func(self, ctx, pos){
      pos = consume(before, ctx, pos)
      local q = child.fast(child, ctx, pos)
      if(q < 0){
        return -1
      }
      return consume(after, ctx, q)
    },
  )
}

// where(child: Parser, predicate: func(value): bool,
//   message?: string) -> Parser
// child, but only where predicate(value) is true; otherwise it fails at
// child's start with message ("unexpected value" by default).
//   ident:where(func(t){ return t.value != "end" })
func peg.where(child, predicate, message){
  local msg = message or "unexpected value"
  local p = new_parser(func(self, ctx, pos){
    local q = child:parse_on(ctx, pos)
    if(q < 0){
      return -1
    }
    if(not predicate(ctx.value)){
      return fail(ctx, pos, msg)
    }
    return q
  }, {child}, "where")
  p.predicate = predicate
  p.message = msg
  return p
}

// end(child: Parser, message?: string) -> Parser
// child followed by the end of the input; its value is child's.
// [message]: the failure when input is left, "end of input expected" by default
func peg.end(child, message){
  return peg.pick(peg.seq(child, peg.end_of_input(message)), 0)
}

// settable(target?: Parser) -> Parser
// A parser that parses with target, which [Parser.set] replaces later: for
// a grammar whose parts refer to each other.
//   local expr = peg.settable()
//   local group = peg.seq(peg.char("("), expr, peg.char(")"))
//   expr:set(peg.choice(group, peg.digit()))
func peg.settable(target){
  local p = new_parser(
    func(self, ctx, pos){
      return self.target:parse_on(ctx, pos)
    },
    null,
    "settable",
    func(self, ctx, pos){
      local target = self.target
      return target.fast(target, ctx, pos)
    },
  )
  p.target = target
  return p
}

// set(target: Parser): the parser a [settable] parses with from now on
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

// ref(f: func(...args): Parser, ...args) -> Parser
// A lazy parser: the first time it is used (or [resolve]d) it calls
// f(...args), at most four arguments, and parses with the result. Calls
// with the same f and arguments share one target, so a grammar written as
// functions that refer to each other forms a finite graph.
//   local func list(){
//     return peg.seq(peg.char("("), peg.ref(list):star(), peg.char(")"))
//   }
func peg.ref(f, ...args){
  if(type(f) != "function"){
    error("ref expects a function, got ", type(f))
  }
  local p = new_parser(
    func(self, ctx, pos){
      local target = self.target
      if(target == null){
        target = resolve_ref(f, args)
        self.target = target
      }
      return target:parse_on(ctx, pos)
    },
    null,
    "ref",
    func(self, ctx, pos){
      local target = self.target
      if(target == null){
        target = resolve_ref(f, args)
        self.target = target
      }
      return target.fast(target, ctx, pos)
    },
  )
  p.ref_function = f
  p.ref_args = args
  return p
}

// resolve(parser: Parser) -> Parser
// Resolves every [ref] reachable from parser now and returns parser: the
// functions behind them run now, so keywords they register take effect now.
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

// custom(parse_on: func(self: Parser, ctx: Context, pos: int): int,
//   parse_tree?: func(self: Parser, ctx: Context, pos: int): int) -> Parser
// A parser from a raw parse function, which returns the new position and
// leaves its value in ctx.value, or returns [fail]. In a tree it is a leaf
// of what it consumed (with the trees of the parsers it ran through [sub]
// woven in), unless parse_tree parses and leaves its node in ctx.tree.
//   local upper = peg.custom(func(self, ctx, pos){
//     local b = str.byte_at(ctx.buffer, pos)
//     if(b != null and b >= 65 and b <= 90){
//       ctx.value = utf8.char(b)
//       return pos + 1
//     }
//     return peg.fail(ctx, pos, "capital expected")
//   })
func peg.custom(parse_on, parse_tree){
  local p = new_parser(parse_on)
  p.parse_tree = parse_tree
  return p
}

// fail(ctx: Context, pos: int, message: string) -> int
// Records a failure at pos and returns -1, for custom parsers.
func peg.fail(ctx, pos, message){
  return fail(ctx, pos, message)
}

// reset_refs()
// Forgets the targets [ref] has made, so new references call their
// functions again; references that were already resolved keep theirs.
func peg.reset_refs(){
  ref_cache = {}
}

// --------------------------------------------------------------------- running

// parse(parser: Parser, input: string) -> {any}
// Parses input from its start: {"ok", value} or {"error", message}. It
// need not consume all of it: use [end]. The error is "message at
// line:column", for the failure that got furthest into the input.
func peg.parse(parser, input){
  local ctx = peg.context(input)
  local pos = parser:parse_on(ctx, 0)
  if(pos >= 0){
    return {"ok", ctx.value}
  }
  // the failure that got furthest says the most (a choice that fell back
  // to an alternative failing early would hide it)
  local at = ctx.fail_pos
  local msg = ctx.fail_msg
  if(ctx.far_pos > at){
    at = ctx.far_pos
    msg = ctx.far_msg
  }
  local lc = peg.line_col(ctx, at)
  return {"error", concat(msg, " at ", lc[0], ":", lc[1])}
}

// run(parser: Parser, input: string, options?: {tree?: bool}) -> Result
// Parses input from its start, as [parse] does, with the details of the
// result or failure. With {tree: true} the result has the lossless tree.
func peg.run(parser, input, options){
  local ctx = peg.context(input, options)
  local pos
  if(ctx.tree_on){
    pos = tparse(parser, ctx, 0)
  } else {
    pos = parser:parse_on(ctx, 0)
  }
  if(pos >= 0){
    return {ok: true, value: ctx.value, position: pos, tree: ctx.tree}
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

// first-byte analysis: {first: set of bytes | null (unknown), nullable: bool}

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
        if(p.class:match_at(utf8.char(b), 0) > 0){
          first[b] = true
        }
      }
      r = {first: first, nullable: false}
    }
  } else if(kind == "any" or kind == "neg"){
    r = {nullable: false}
  } else if(kind == "whitespace"){
    r = {first: whitespace_first, nullable: false}
  } else if(kind == "end" or kind == "epsilon" or kind == "forbid" or
    kind == "and"){
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
    r = {
      first: union(
        info_of(children[0], memo, visiting).first,
        info_of(children[1], memo, visiting).first,
      ),
      nullable: true,
    }
  } else if(kind == "separated"){
    local ci = info_of(children[0], memo, visiting)
    r = {first: ci.first, nullable: ci.nullable or not p.at_least_one}
  } else if(kind == "plus" or kind == "pick" or kind == "permute" or
    kind == "map" or kind == "flatten" or kind == "token" or kind == "trim" or
    kind == "where" or kind == "tag" or kind == "layer"){
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

// ------------------------------------------------------------- tags

// tag(child: Parser, category: string) -> Parser
// Parses child; its span is highlighted again under category (it wins over
// the tokens inside), so an extension can colour what a rule produced (an
// identifier as a function being declared, say) without changing the value
// (see [highlights]).
func peg.tag(child, category){
  local p = new_parser(
    func(self, ctx, pos){
      return child:parse_on(ctx, pos)
    },
    {child},
    "tag",
    func(self, ctx, pos){
      return child.fast(child, ctx, pos)
    },
  )
  p.category = category
  return p
}

// ------------------------------------------------------------- memoization
//
// A parser is memoized where it can run twice at one position: as the
// leading parser of several alternatives of one choice or dispatch. The
// common case is the `old` of a modified rule appearing in both alternatives
// of choice(seq(old, tail), old), which would otherwise parse every instance
// of the rule twice. Results live in ctx.rule_memo per position; a cached
// result is shared, so parser actions must not mutate their inputs.

// memoize(p: Parser) -> Parser
// Makes p remember its result per position in ctx.rule_memo, in place
// (every grammar sharing the parser sees it), and returns p. A grammar
// places these itself (see [place_memos]).
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
      t[pos] = {
        stop: -1,
        has_value: true,
        fail_pos: ctx.fail_pos,
        fail_msg: ctx.fail_msg,
      }
    } else {
      t[pos] = {stop: q, has_value: true, value: ctx.value}
    }
    return q
  }
  // the tree path: a cached result is used when it has a node (a result
  // cached by parse_on, from a custom parser's plain parse, has none)
  local tree_path = p.parse_tree or tree_kinds[p.kind] or tree_leaf
  p.parse_tree = func(self, ctx, pos){
    local t = table_of(ctx)
    local hit = t[pos]
    if(hit != null and hit.has_value and (hit.stop < 0 or hit.tree != null)){
      if(hit.stop < 0){
        return fail(ctx, hit.fail_pos, hit.fail_msg)
      }
      ctx.value = hit.value
      ctx.tree = hit.tree
      return hit.stop
    }
    local q = tree_path(self, ctx, pos)
    if(q < 0){
      t[pos] = {
        stop: -1,
        has_value: true,
        fail_pos: ctx.fail_pos,
        fail_msg: ctx.fail_msg,
      }
    } else {
      t[pos] = {stop: q, has_value: true, value: ctx.value, tree: ctx.tree}
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
      t[pos] = {
        stop: -1,
        has_value: true,
        fail_pos: ctx.fail_pos,
        fail_msg: ctx.fail_msg,
      }
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
  } else if(kind == "star" or kind == "optional" or kind == "plus" or
    kind == "separated" or kind == "star_lazy" or kind == "pick" or
    kind == "permute" or kind == "map" or kind == "flatten" or
    kind == "token" or kind == "trim" or kind == "where" or kind == "tag" or
    kind == "layer"){
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

// place_memos(roots: {Parser},
//   named: {[Parser]: string}) -> {{parser: Parser, name: string}}
// Memoizes every parser in named (the rules of a grammar and the parsers
// they were modified from, by name) that leads more than one alternative
// of a choice or dispatch reachable from roots; returns what it memoized.
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
            if(o != q and not dominated and
              leading_set(o, cache, {}, memo)[q] != null){
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

// skip_space(ctx: Context, pos: int) -> int
// The position after the slang whitespace and `//` comments at pos: the
// skip function of a walker or dispatch for slang's own trivia.
func peg.skip_space(ctx, pos){
  return match_at(space_run, ctx.buffer, pos)
}

// space_end(s: string, pos: int) -> int
// [skip_space] on a string: the position after the whitespace and `//`
// comments at pos.
func peg.space_end(s, pos){
  return match_at(space_run, s, pos)
}

// The regex of [space_end], for scanners that call its match_at directly.
peg.space = space_run

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

// dispatch(parsers: {Parser}, skip?: func(ctx: Context, pos: int): int,
//   message?: string) -> Parser
// An ordered choice over parsers that only tries, in order, the
// alternatives whose first byte (after skip(ctx, pos)) can match; without
// skip it tries them all. When no alternative can match, message (if
// given) is recorded as the failure. The tables are built now, from the
// current resolution of every rule reference, so a dispatch belongs to one
// sealed grammar.
func peg.dispatch(parsers, skip, message){
  local entries = {}
  for(let local p in values(parsers)){
    append(entries, {parser: p})
  }
  local d = make_dispatch(entries, skip, {})
  local p = new_parser(func(self, ctx, pos){
    local cand = try_ops(d, ctx, pos)
    if(cand != null){
      return ctx.op_pos
    }
    if(not ctx.tried and message != null){
      return fail(ctx, ctx.skip_to, message)
    }
    return -1
  }, parsers, "dispatch")
  p.dispatch = d
  p.message = message
  return p
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
// build() returns the expression parser (kind "expression"), also kept in
// w.parser; w.loopback is a settable that parses a whole expression, for
// operators that embed one (`a[expr]`).

// Where a level or primary goes among the others (by name or alias).
// type Placement = {after?: string, before?: string, at?: int,
//   aliases?: {string}}
// [after]: just after this one (for levels: looser than it)
// [before]: just before this one (for levels: tighter than it)
// [at]: at this index of the list (0: first, the tightest level)
// [aliases]: other names the new entry goes by

// An expression walker (see [walker]): a Pratt parser for operators and
// primaries, registered by level.
// type Walker
local walker_methods = {}
local walker_meta = {__index: walker_methods, __type: "walker"}
// A precedence level of a [Walker]: the walker's operator registration
// without naming the level. Each method returns the level.
// type Level
local level_methods = {}
local level_meta = {__index: level_methods, __type: "expression_level"}

// walker(skip?: func(ctx: Context, pos: int): int) -> Walker
// A new, empty expression walker. skip finds the next byte that matters
// (usually [skip_space]); with it the walker dispatches on first bytes.
// Register levels (tightest first), operators and primaries, then
// [Walker.build] the parser.
//   local w = peg.walker(peg.skip_space)
//   local num = peg.digit():plus():flatten():trim():map(to_int)
//   local func op(s){ return peg.string(s):trim() }
//   w:primary(num)
//   w:level("product"):left(op("*"), func(a, o, b){ return a * b })
//   w:level("sum"):left(op("+"), func(a, o, b){ return a + b })
//   w:build():end():parse("1 + 2 * 3")       // {"ok", 7}
func peg.walker(skip){
  local w = {
    skip: skip, levels: {}, primaries: {}, nuds: {}, leds: {},
    loopback: peg.settable(null), sealed: null
  }
  w.@meta = walker_meta
  return w
}

local func new_level(w, name, aliases){
  local l = {
    walker: w, name: name, aliases: aliases or {}, wrappers: {}, prefixes: {},
    postfixes: {}, rights: {}, lefts: {}
  }
  l.@meta = level_meta
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
      error(
        what, " ", entry.name, " cannot be after ", placement.after,
        " and before ", placement.before
      )
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

// level(name?: string, placement?: Placement) -> Level
// A new precedence level. Levels form a total order, tightest first;
// without a placement the level is looser than all so far. A level of a
// name already in use replaces that level. Raises when a placement names a
// level that does not exist.
func walker_methods.level(self, name, placement){
  placement = placement or {}
  local l = new_level(self, name, placement.aliases)
  self.levels = place(self.levels, l, placement, "expression level")
  self.sealed = null
  return l
}

// primary(parser: Parser, name?: string, placement?: Placement) -> Walker
// Adds a primary expression (what an operand can be). Primaries are tried
// in order, after every prefix operator and wrapper.
func walker_methods.primary(self, parser, name, placement){
  placement = placement or {}
  local entry = {parser: parser, name: name, aliases: placement.aliases or {}}
  self.primaries = place(self.primaries, entry, placement, "primary expression")
  self.sealed = null
  return self
}

// level_names() -> {string?}: the level names, tightest first
func walker_methods.level_names(self){
  local out = {}
  for(let local l in values(self.levels)){
    append(out, l.name)
  }
  return out
}

// primary_names() -> {string?}: the names of the primaries, in order
func walker_methods.primary_names(self){
  local out = {}
  for(let local p in values(self.primaries)){
    append(out, p.name)
  }
  return out
}

// prefix(operator: Parser, level: string | Level,
//   callback: func(op, operand): any) -> Walker
// A prefix operator at a level; the expression's value is what callback
// returns from the operator's and the operand's values.
func walker_methods.prefix(self, operator, level, callback){
  append(resolve_level(self, level).prefixes, {
    parser: operator, callback: callback
  })
  self.sealed = null
  return self
}

// postfix(operator: Parser, level: string | Level,
//   callback: func(left, op): any) -> Walker
func walker_methods.postfix(self, operator, level, callback){
  append(resolve_level(self, level).postfixes, {
    parser: operator, callback: callback
  })
  self.sealed = null
  return self
}

// left(operator: Parser, level: string | Level,
//   callback: func(left, op, right): any) -> Walker
// A left-associative infix operator: a - b - c is (a - b) - c.
func walker_methods.left(self, operator, level, callback){
  append(resolve_level(self, level).lefts, {
    parser: operator, callback: callback
  })
  self.sealed = null
  return self
}

// right(operator: Parser, level: string | Level,
//   callback: func(left, op, right): any) -> Walker
// A right-associative infix operator: a ^ b ^ c is a ^ (b ^ c).
func walker_methods.right(self, operator, level, callback){
  append(resolve_level(self, level).rights, {
    parser: operator, callback: callback
  })
  self.sealed = null
  return self
}

// wrapper(left: Parser, right: Parser, level: string | Level,
//   callback: func(left, value, right): any) -> Walker
// A whole expression between left and right, such as parentheses.
func walker_methods.wrapper(self, left, right, level, callback){
  append(resolve_level(self, level).wrappers, {
    left: left, right: right, callback: callback
  })
  self.sealed = null
  return self
}

// nud(operator: Parser, rbp: int,
//   f: func(w: Walker, ctx: Context, pos: int, op): int) -> Walker
// Engine API: an operator an expression can start with, at an explicit
// binding power. After operator matched, f parses the rest itself from pos
// (with [Walker.parse_at]), leaves the value in ctx.value and returns the
// new position or -1.
func walker_methods.nud(self, operator, rbp, f){
  append(self.nuds, {parser: operator, kind: "nud", bp: rbp, nud: f})
  self.sealed = null
  return self
}

// led(operator: Parser, lbp: int,
//   f: func(w: Walker, ctx: Context, pos: int, left, op): int) -> Walker
// Engine API: an operator that follows a value, applied when lbp is
// higher than the binding power being parsed; f gets the value on its left
// and parses the rest as for [Walker.nud].
func walker_methods.led(self, operator, lbp, f){
  append(self.leds, {parser: operator, kind: "led", lbp: lbp, led: f})
  self.sealed = null
  return self
}

// wrapper(left: Parser, right: Parser,
//   callback: func(left, value, right): any) -> Level
// [Walker.wrapper] at this level.
func level_methods.wrapper(self, left, right, callback){
  self.walker:wrapper(left, right, self, callback)
  return self
}

// prefix(operator: Parser, callback: func(op, operand): any) -> Level
// [Walker.prefix] at this level.
func level_methods.prefix(self, operator, callback){
  self.walker:prefix(operator, self, callback)
  return self
}

// postfix(operator: Parser, callback: func(left, op): any) -> Level
// [Walker.postfix] at this level.
func level_methods.postfix(self, operator, callback){
  self.walker:postfix(operator, self, callback)
  return self
}

// right(operator: Parser, callback: func(left, op, right): any) -> Level
// [Walker.right] at this level.
func level_methods.right(self, operator, callback){
  self.walker:right(operator, self, callback)
  return self
}

// left(operator: Parser, callback: func(left, op, right): any) -> Level
// [Walker.left] at this level.
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

// derive() -> Walker
// A walker with the same registrations; changes to either do not affect
// the other. Build it before use.
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

// binding_powers() -> {[string]: int}
// The base binding power of every level by name (higher binds tighter),
// for debugging extensions.
func walker_methods.binding_powers(self){
  local out = {}
  local n = len(self.levels)
  for(local k = 0; k < n; k = k + 1){
    out[self.levels[k].name or concat("level ", k)] = (n - k) * 10
  }
  return out
}

local func sort_entries(list, key, descending){
  if(descending){
    return tbl.sort(list, func(a, b){ return a[key] > b[key] })
  }
  return tbl.sort(list, func(a, b){ return a[key] < b[key] })
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
      append(nuds, {
        parser: e.parser, kind: "prefix", form: "prefix", level: l.name,
        callback: callback, bp: rbp, nud: func(w, ctx, pos, op){
          local r = w:parse_at(ctx, pos, rbp)
          if(r < 0){
            return -1
          }
          ctx.value = callback(op, ctx.value)
          return r
        }
      })
    }
    for(let local e in values(l.wrappers)){
      local callback = e.callback
      local right = e.right
      append(nuds, {
        parser: e.left, kind: "wrapper", form: "wrapper", level: l.name,
        callback: callback, right: right, bp: base + 3,
        nud: func(w, ctx, pos, left){
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
        }
      })
    }
    for(let local e in values(l.postfixes)){
      local callback = e.callback
      append(leds, {
        parser: e.parser, kind: "led", form: "postfix", level: l.name,
        callback: callback, lbp: base + 3, led: func(w, ctx, pos, left, op){
          ctx.value = callback(left, op)
          return pos
        }
      })
    }
    for(let local e in values(l.rights)){
      local callback = e.callback
      local rbp = base + 1
      append(leds, {
        parser: e.parser, kind: "led", form: "right", level: l.name,
        callback: callback, rbp: rbp, lbp: base + 2,
        led: func(w, ctx, pos, left, op){
          local r = w:parse_at(ctx, pos, rbp)
          if(r < 0){
            return -1
          }
          ctx.value = callback(left, op, ctx.value)
          return r
        }
      })
    }
    for(let local e in values(l.lefts)){
      local callback = e.callback
      local rbp = base
      append(leds, {
        parser: e.parser, kind: "led", form: "left", level: l.name,
        callback: callback, rbp: rbp, lbp: base,
        led: func(w, ctx, pos, left, op){
          local r = w:parse_at(ctx, pos, rbp)
          if(r < 0){
            return -1
          }
          ctx.value = callback(left, op, ctx.value)
          return r
        }
      })
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

// parse_at(ctx: Context, pos: int, min_bp: int) -> int
// Parses an expression whose operators bind tighter than min_bp and
// returns the new position or -1; the value is in ctx.value. For the
// callbacks of [Walker.nud] and [Walker.led]; needs [Walker.build] first.
func walker_methods.parse_at(self, ctx, pos, min_bp){
  // a change since the last build cleared the tables: build them again
  if(self.sealed == null){
    self:build()
  }
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

// ---- the tree path of the walker: the same parse as parse_at, building a
// node per operator application with the entry as p (entry.form "prefix",
// "wrapper", "postfix", "right" or "left", entry.level the level's name) and
// the operator's and operands' nodes as kids. The engine entries (nud, led)
// parse their operands themselves: their node holds the operator's node and
// a leaf for the rest.

// the walker an engine entry's callback gets while a tree is built: its
// parse_at puts the operand's tree in ctx.collect (see weave)
local func collecting_walker(w){
  local c = w.collecting
  if(c == null){
    c = {}
    c.@meta = {__index: w}
    c.parse_at = func(self, ctx, pos, min_bp){
      if(ctx.collect == null){
        return w:parse_at(ctx, pos, min_bp)
      }
      return peg.collect(ctx, pos, func(cx, at){
        return w:parse_at_tree(cx, at, min_bp)
      })
    }
    w.collecting = c
  }
  return c
}

local func nud_tree(w, e, ctx, pos, op, op_tree, start){
  local form = e.form
  if(form == "prefix"){
    local r = w:parse_at_tree(ctx, pos, e.bp)
    if(r < 0){
      return -1
    }
    local operand_tree = ctx.tree
    ctx.value = e.callback(op, ctx.value)
    ctx.tree = node(e, start, r, {op_tree, operand_tree})
    ctx.tree.value = ctx.value
    return r
  }
  if(form == "wrapper"){
    local r = w:parse_at_tree(ctx, pos, 0)
    if(r < 0){
      return -1
    }
    local value = ctx.value
    local inner_tree = ctx.tree
    local q = tparse(e.right, ctx, r)
    if(q < 0){
      return -1
    }
    local right_tree = ctx.tree
    ctx.value = e.callback(op, value, ctx.value)
    ctx.tree = node(e, start, q, {op_tree, inner_tree, right_tree})
    ctx.tree.value = ctx.value
    return q
  }
  local saved = ctx.collect
  local trees = {}
  ctx.collect = trees
  local r = e.nud(collecting_walker(w), ctx, pos, op)
  ctx.collect = saved
  if(r < 0){
    return -1
  }
  local kids = {op_tree}
  for(let local k in values(weave(e, ctx, op_tree.stop, r, trees))){
    list_push(kids, k)
  }
  ctx.tree = node(e, start, r, kids)
  ctx.tree.value = ctx.value
  return r
}

local func led_tree(w, e, ctx, pos, left, left_tree, op, op_tree){
  local form = e.form
  local start = left_tree.start
  if(form == "postfix"){
    ctx.value = e.callback(left, op)
    ctx.tree = node(e, start, pos, {left_tree, op_tree})
    ctx.tree.value = ctx.value
    return pos
  }
  if(form == "left" or form == "right"){
    local r = w:parse_at_tree(ctx, pos, e.rbp)
    if(r < 0){
      return -1
    }
    local right_tree = ctx.tree
    ctx.value = e.callback(left, op, ctx.value)
    ctx.tree = node(e, start, r, {left_tree, op_tree, right_tree})
    ctx.tree.value = ctx.value
    return r
  }
  local saved = ctx.collect
  local trees = {}
  ctx.collect = trees
  local r = e.led(collecting_walker(w), ctx, pos, left, op)
  ctx.collect = saved
  if(r < 0){
    return -1
  }
  local kids = {left_tree, op_tree}
  for(let local k in values(weave(e, ctx, op_tree.stop, r, trees))){
    list_push(kids, k)
  }
  ctx.tree = node(e, start, r, kids)
  ctx.tree.value = ctx.value
  return r
}

// parse_at_tree(ctx: Context, pos: int, min_bp: int) -> int
// [Walker.parse_at], also leaving the node in ctx.tree.
func walker_methods.parse_at_tree(self, ctx, pos, min_bp){
  if(self.sealed == null){
    self:build()
  }
  local sealed = self.sealed
  local cands = candidates(sealed.nuds, ctx, pos)
  local value = null
  local tree = null
  local q = -1
  local tried_primary = false
  if(cands != null){
    local n = len(cands)
    for(local i = 0; i < n; i = i + 1){
      local e = cands[i]
      if(e.kind == "primary"){
        tried_primary = true
      }
      local r = tparse(e.parser, ctx, pos)
      if(r >= 0 and e.kind != "primary"){
        r = nud_tree(self, e, ctx, r, ctx.value, ctx.tree, pos)
      }
      if(r >= 0){
        value = ctx.value
        tree = ctx.tree
        q = r
        break
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
      local r = tparse(e.parser, ctx, q)
      if(r >= 0){
        r = led_tree(self, e, ctx, r, value, tree, ctx.value, ctx.tree)
        if(r >= 0){
          value = ctx.value
          tree = ctx.tree
          q = r
          matched = true
          break
        }
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
  ctx.tree = tree
  return q
}

// build() -> Parser
// Builds the dispatch tables and returns the expression parser. A parser
// from an earlier build rebuilds the tables itself after a change; build
// again anyway to get a parser whose first-byte set knows the change.
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
  expr.parse_tree = func(self, ctx, pos){
    return w:parse_at_tree(ctx, pos, 0)
  }
  if(self.sealed.first != null){
    expr.first = self.sealed.first
    expr.nullable = false
  }
  self.loopback:set(expr)
  self.parser = expr
  return expr
}

// ------------------------------------------------------------ the lossless tree
//
// The tree paths of the combinators (tparse picks them by kind). Each parses
// like the combinator's parse_on, with its children's tree paths, and leaves
// its node in ctx.tree. Kinds without an entry (the primitives, flatten,
// lookaheads, custom parsers) are leaves.

tree_kinds.choice = func(self, ctx, pos){
  for(let local child in values(self.children)){
    local q = tparse(child, ctx, pos)
    if(q >= 0){
      return q
    }
  }
  return -1
}

tree_kinds.seq = func(self, ctx, pos){
  local parsers = self.children
  local n = len(parsers)
  local values = {}
  local trees = {}
  local start = pos
  for(local i = 0; i < n; i = i + 1){
    pos = tparse(parsers[i], ctx, pos)
    if(pos < 0){
      return -1
    }
    list_push(values, ctx.value)
    list_push(trees, ctx.tree)
  }
  ctx.value = values
  ctx.tree = node(self, start, pos, trees)
  return pos
}

// star and plus: plus requires (and keeps) a first match even when it is empty
local func repeat_tree(self, ctx, pos, at_least_one){
  local child = self.children[0]
  local values = {}
  local trees = {}
  local start = pos
  local first = at_least_one
  for(true){
    local q = tparse(child, ctx, pos)
    if(q < 0 and first){
      return -1
    }
    if(q < 0 or (q == pos and not first)){
      break
    }
    first = false
    list_push(values, ctx.value)
    list_push(trees, ctx.tree)
    pos = q
  }
  ctx.value = values
  ctx.tree = node(self, start, pos, trees)
  return pos
}

tree_kinds.star = func(self, ctx, pos){
  return repeat_tree(self, ctx, pos, false)
}

tree_kinds.plus = func(self, ctx, pos){
  return repeat_tree(self, ctx, pos, true)
}

tree_kinds.optional = func(self, ctx, pos){
  local q = tparse(self.children[0], ctx, pos)
  if(q < 0){
    ctx.value = self.default_value
    ctx.tree = node(self, pos, pos, {})
    return pos
  }
  ctx.tree = node(self, pos, q, {ctx.tree})
  return q
}

tree_kinds.star_lazy = func(self, ctx, pos){
  local child = self.children[0]
  local limit = self.children[1]
  local values = {}
  local trees = {}
  local start = pos
  for(true){
    if(limit:parse_on(ctx, pos) >= 0){
      ctx.value = values
      ctx.tree = node(self, start, pos, trees)
      return pos
    }
    local q = tparse(child, ctx, pos)
    if(q < 0){
      return -1
    }
    list_push(values, ctx.value)
    list_push(trees, ctx.tree)
    pos = q
  }
}

// the node has the elements and separators interleaved
tree_kinds.separated = func(self, ctx, pos){
  local child = self.children[0]
  local separator = self.children[1]
  local elements = {}
  local separators = {}
  local trees = {}
  local start = pos
  local q = tparse(child, ctx, pos)
  if(q < 0){
    if(self.at_least_one){
      return -1
    }
    ctx.value = {elements: elements, separators: separators}
    ctx.tree = node(self, pos, pos, trees)
    return pos
  }
  list_push(elements, ctx.value)
  list_push(trees, ctx.tree)
  pos = q
  for(true){
    q = tparse(separator, ctx, pos)
    if(q < 0){
      break
    }
    local sep = ctx.value
    local sep_tree = ctx.tree
    local r = tparse(child, ctx, q)
    if(r < 0){
      break
    }
    list_push(separators, sep)
    list_push(elements, ctx.value)
    list_push(trees, sep_tree)
    list_push(trees, ctx.tree)
    pos = r
  }
  ctx.value = {elements: elements, separators: separators}
  ctx.tree = node(self, start, pos, trees)
  return pos
}

tree_kinds.pick = func(self, ctx, pos){
  local q = tparse(self.children[0], ctx, pos)
  if(q < 0){
    return -1
  }
  local list = ctx.value
  local index = self.index
  if(index < 0){
    ctx.value = list[len(list) + index]
  } else {
    ctx.value = list[index]
  }
  ctx.tree = node(self, pos, q, {ctx.tree})
  return q
}

tree_kinds.permute = func(self, ctx, pos){
  local q = tparse(self.children[0], ctx, pos)
  if(q < 0){
    return -1
  }
  local list = ctx.value
  local out = {}
  for(let local index in values(self.indices)){
    if(index < 0){
      list_push(out, list[len(list) + index])
    } else {
      list_push(out, list[index])
    }
  }
  ctx.value = out
  ctx.tree = node(self, pos, q, {ctx.tree})
  return q
}

tree_kinds.map = func(self, ctx, pos){
  local q = tparse(self.children[0], ctx, pos)
  if(q < 0){
    return -1
  }
  local tree = ctx.tree
  ctx.value = self.fn(ctx.value)
  ctx.tree = node(self, pos, q, {tree})
  return q
}

tree_kinds.where = func(self, ctx, pos){
  local q = tparse(self.children[0], ctx, pos)
  if(q < 0){
    return -1
  }
  local tree = ctx.tree
  if(not self.predicate(ctx.value)){
    return fail(ctx, pos, self.message)
  }
  ctx.tree = node(self, pos, q, {tree})
  return q
}

tree_kinds.token = func(self, ctx, pos){
  local q = tparse(self.children[0], ctx, pos)
  if(q < 0){
    return -1
  }
  local tree = ctx.tree
  local t = peg.make_token(ctx, ctx.value, pos, q)
  if(type(self.category) == "string"){
    t.category = self.category
  }
  ctx.value = t
  ctx.tree = node(self, pos, q, {tree})
  return q
}

tree_kinds.tag = func(self, ctx, pos){
  local q = tparse(self.children[0], ctx, pos)
  if(q < 0){
    return -1
  }
  ctx.tree = node(self, pos, q, {ctx.tree})
  return q
}

// the trimmer's nodes go to kids (no position memo, which would skip them)
local func consume_tree(trimmer, ctx, pos, kids){
  local far_pos = ctx.far_pos
  local far_msg = ctx.far_msg
  for(true){
    local q = tparse(trimmer, ctx, pos)
    if(q < 0 or q == pos){
      break
    }
    list_push(kids, ctx.tree)
    pos = q
    if(trimmer.single){
      break
    }
  }
  ctx.far_pos = far_pos
  ctx.far_msg = far_msg
  return pos
}

// the node of a trim: what before consumed, the child (kids[node.at]), what
// after consumed
tree_kinds.trim = func(self, ctx, pos){
  local child = self.children[0]
  local start = pos
  local kids = {}
  pos = consume_tree(self.children[1], ctx, pos, kids)
  local q = tparse(child, ctx, pos)
  if(q < 0){
    return -1
  }
  local v = ctx.value
  local at = len(kids)
  list_push(kids, ctx.tree)
  q = consume_tree(self.children[2], ctx, q, kids)
  ctx.value = v
  local t = node(self, start, q, kids)
  t.at = at
  ctx.tree = t
  return q
}

tree_kinds.settable = func(self, ctx, pos){
  return tparse(self.target, ctx, pos)
}

tree_kinds.ref = func(self, ctx, pos){
  local target = self.target
  if(target == null){
    target = resolve_ref(self.ref_function, self.ref_args)
    self.target = target
  }
  return tparse(target, ctx, pos)
}

tree_kinds.dispatch = func(self, ctx, pos){
  local cands = candidates(self.dispatch, ctx, pos)
  if(cands == null){
    if(self.message != null){
      return fail(ctx, ctx.skip_to, self.message)
    }
    return -1
  }
  for(let local c in values(cands)){
    local q = tparse(c.parser, ctx, pos)
    if(q >= 0){
      return q
    }
  }
  return -1
}

// leaves(tree: Tree?) -> {Tree}: the leaves of tree in source order
func peg.leaves(tree){
  local out = {}
  if(tree == null){
    return out
  }
  local stack = {tree}
  for(len(stack) > 0){
    local t = remove(stack, len(stack) - 1)
    if(t != null){
      local kids = t.kids
      if(kids == null){
        list_push(out, t)
      } else {
        for(local i = len(kids) - 1; i >= 0; i = i - 1){
          list_push(stack, kids[i])
        }
      }
    }
  }
  return out
}

// text(tree: Tree, buffer: string) -> string
// The text of the leaves of tree, joined: the part of buffer (the input
// the tree was parsed from) that tree spans.
func peg.text(tree, buffer){
  local parts = {}
  for(let local l in values(peg.leaves(tree))){
    list_push(parts, str.substring(buffer, l.start, l.stop))
  }
  return str.join(parts, "")
}

// tree_gap(tree: Tree) -> {at: int, leaf?: Tree}?
// null when the leaves of tree cover its span exactly, in order; otherwise
// the position where the next leaf should have started and the leaf found
// there (null when the leaves end early). For testing tree paths.
func peg.tree_gap(tree){
  local at = tree.start
  for(let local l in values(peg.leaves(tree))){
    if(l.start != at){
      return {at: at, leaf: l}
    }
    at = l.stop
  }
  if(at != tree.stop){
    return {at: at}
  }
  return null
}

// ------------------------------------------------------------------- layers
//
// A layer is a value computed from a lossless tree after the parse. peg's
// own lossy behaviour is tagged:
//   trivia   trim drops what its trimmers consumed
//   absent   an unmatched optional is its default value, a lookahead null
//   select   pick and permute keep some elements, separated splits into
//            {elements, separators}
//   wrap     token makes a token table
//   map      map applies its function, the walker its callbacks, a custom
//            parser gives the value it produced
// and the built-in layers apply some of them:
//   "text"      none: the source as nested lists of strings
//   "raw"       trivia and absent: the parse without whitespace, before any
//               transform
//   "default"   all: the values the parse produced (kept in the nodes)
// Without a tag, pick, permute, map and token give their child's value,
// trim the list of everything it consumed, separated the interleaved list,
// an unmatched optional or a lookahead "", a custom parser its text, a
// walker node the list of its operator's and operands' values.
//
// A custom layer starts from one built-in layer and adds operations with
// p:on(layer, f), where f gets the layer's value pipeline (map, pick,
// permute, flatten, mark) and nothing that consumes input:
//   transforms (map, pick, permute, flatten) change the layer's value at
//   that parser's node; marks (mark(data)) attach data to the node and leave
//   the value alone (read with peg.marks). Custom layers do not build on
//   each other: a parent's transforms would see values its child changed.

local all_tags = {
  trivia: true, absent: true, select: true, wrap: true, map: true
}
local builtin_layers = {
  text: {name: "text", tags: {}},
  raw: {name: "raw", tags: {trivia: true, absent: true}},
  default: {name: "default", tags: all_tags},
}

// A custom layer, made by [layer]: a key for the operations parsers carry
// for it ([on], [mark]) and for [evaluate].
// type Layer = {name: string, base: string, custom: bool}
// [base]: the built-in layer it starts from

// layer(name: string, base: string) -> Layer
// A custom layer starting from the built-in layer base: "text", "raw" or
// "default". Raises for any other base.
func peg.layer(name, base){
  local b = builtin_layers[base]
  if(b == null){
    error("a layer starts from \"text\", \"raw\" or \"default\", not ", base)
  }
  return {name: name, base: base, tags: b.tags, custom: true}
}

// The value pipeline a layer's operations are recorded on: what the
// function given to [on] receives and returns. Each method adds an
// operation and returns the pipeline.
// type Pipeline
local pipeline_methods = {}
local pipeline_meta = {__index: pipeline_methods, __type: "layer_pipeline"}

local func add_op(self, op){
  list_push(self.ops, op)
  return self
}
// map(f: func(value): any) -> Pipeline: replaces the value by f(value)
func pipeline_methods.map(self, f){
  return add_op(self, {op: "map", fn: f})
}
// pick(index: int) -> Pipeline: the element at index of a list value
func pipeline_methods.pick(self, index){
  return add_op(self, {op: "pick", index: index})
}
// permute(...indices: int) -> Pipeline: a list of the elements at indices
func pipeline_methods.permute(self, ...indices){
  return add_op(self, {op: "permute", indices: indices})
}
// flatten() -> Pipeline: replaces the value by the node's text
func pipeline_methods.flatten(self){
  return add_op(self, {op: "flatten"})
}
// mark(data) -> Pipeline
// Attaches data to the node, leaving the value alone (see [marks]).
func pipeline_methods.mark(self, data){
  return add_op(self, {op: "mark", data: data})
}

// the kinds whose parse functions keep their state in upvalues and that have
// a node of their own: on() gives such a parser a copy with the operations,
// which parses with the same code. Any other parser gets a wrapper: rules,
// settables and custom parsers (state in fields), and choice, dispatch and
// ref, whose tree is their child's.
local copyable = {}
for(let local k in values({
  "string", "pattern", "any", "whitespace", "end", "epsilon", "failure", "seq",
  "star", "plus", "optional", "star_lazy", "separated", "forbid", "and", "neg",
  "pick", "permute", "map", "flatten", "token", "trim", "where", "tag", "layer"
})){
  copyable[k] = true
}

local func layer_wrapper(child){
  local p = new_parser(
    func(self, ctx, pos){
      return child:parse_on(ctx, pos)
    },
    {child},
    "layer",
    func(self, ctx, pos){
      return child.fast(child, ctx, pos)
    },
  )
  return p
}

tree_kinds.layer = func(self, ctx, pos){
  local q = tparse(self.children[0], ctx, pos)
  if(q < 0){
    return -1
  }
  ctx.tree = node(self, pos, q, {ctx.tree})
  return q
}

// on(parser: Parser, layer: Layer, f: func(v: Pipeline): Pipeline) -> Parser
// A parser that parses like parser and carries the operations f records
// for layer. The parser itself is not changed: a shared parser (a rule
// reference, say) keeps no operations from one use. Also a method:
// p:on(layer, f).
//   local names = peg.layer("names", "raw")
//   local id = peg.word():plus():on(names, func(v){ return v:flatten() })
func peg.on(parser, layer, f){
  if(type(layer) != "table" or not layer.custom){
    error("on() takes a layer made with peg.layer")
  }
  local pipe = {ops: {}}
  pipe.@meta = pipeline_meta
  f(pipe)
  local p
  if(copyable[parser.kind]){
    p = {}
    for(let local e in entries(parser)){
      p[e[0]] = e[1]
    }
    p.@meta = parser_meta
    // an id of its own: memos are kept by id, and the copy's nodes carry
    // other layer operations
    next_id = next_id + 1
    p.id = next_id
  } else {
    p = layer_wrapper(parser)
  }
  local ops = {}
  if(parser.layer_ops != null and copyable[parser.kind]){
    for(let local e in entries(parser.layer_ops)){
      ops[e[0]] = e[1]
    }
  }
  local list = {}
  for(let local op in values(ops[layer] or {})){
    list_push(list, op)
  }
  for(let local op in values(pipe.ops)){
    list_push(list, op)
  }
  ops[layer] = list
  p.layer_ops = ops
  return p
}

// mark(parser: Parser, layer: Layer, data) -> Parser
// on(parser, layer, func(v){ return v:mark(data) }): data attached to the
// nodes of parser, read with [marks]. Also a method: p:mark(layer, data).
func peg.mark(parser, layer, data){
  return peg.on(parser, layer, func(v){
    return v:mark(data)
  })
}

// marks(n: Tree, layer: Layer) -> {any}
// The data marked on the node's parser for layer, in order.
func peg.marks(n, layer){
  local out = {}
  local ops = n.p.layer_ops
  if(ops != null and ops[layer] != null){
    for(let local op in values(ops[layer])){
      if(op.op == "mark"){
        list_push(out, op.data)
      }
    }
  }
  return out
}

local leaf_text_kinds = {
  string: true, pattern: true, any: true, whitespace: true, neg: true,
  flatten: true
}

local func leaf_value(n, tags, buffer){
  if(n.start == n.stop){
    if(tags.absent){
      return n.value
    }
    return ""
  }
  if(tags.map and not leaf_text_kinds[n.p.kind]){
    return n.value
  }
  return str.substring(buffer, n.start, n.stop)
}

local func at(list, index){
  if(index < 0){
    return list[len(list) + index]
  }
  return list[index]
}

// the value of a node from the values of its kids, with tags
local func node_value(n, kids, tags, buffer){
  local p = n.p
  if(n.woven){
    // a parser without a tree path, with the trees of rules it parsed
    if(tags.map){
      return n.value
    }
    return kids
  }
  if(n.raw){
    // a raw leaf and the trivia it ends with
    if(tags.map){
      return n.value
    }
    if(tags.trivia){
      return kids[0]
    }
    return kids
  }
  local form = p.form
  if(form != null){
    if(not tags.map){
      return kids
    }
    if(form == "prefix" or form == "postfix"){
      return p.callback(kids[0], kids[1])
    }
    return p.callback(kids[0], kids[1], kids[2])
  }
  local kind = p.kind
  if(kind == "seq" or kind == "star" or kind == "plus" or kind == "star_lazy" or
    kind == "unit"){
    return kids
  }
  if(kind == "optional"){
    if(len(n.kids) == 0){
      if(tags.absent){
        return p.default_value
      }
      return ""
    }
    return kids[0]
  }
  if(kind == "separated"){
    if(not tags.select){
      return kids
    }
    local elements = {}
    local separators = {}
    for(local i = 0; i < len(n.kids); i = i + 1){
      if(i % 2 == 0){
        list_push(elements, kids[i])
      } else {
        list_push(separators, kids[i])
      }
    }
    return {elements: elements, separators: separators}
  }
  if(kind == "pick"){
    if(tags.select){
      return at(kids[0], p.index)
    }
    return kids[0]
  }
  if(kind == "permute"){
    if(tags.select){
      local out = {}
      for(let local index in values(p.indices)){
        list_push(out, at(kids[0], index))
      }
      return out
    }
    return kids[0]
  }
  if(kind == "map"){
    if(tags.map){
      return p.fn(kids[0])
    }
    return kids[0]
  }
  if(kind == "token"){
    if(tags.wrap){
      local t = peg.make_token({buffer: buffer}, kids[0], n.start, n.stop)
      if(p.category != null){
        t.category = p.category
      }
      return t
    }
    return kids[0]
  }
  if(kind == "trim"){
    if(tags.trivia){
      return kids[n.at]
    }
    return kids
  }
  if(p.form == null and (kind == "nud" or kind == "led")){
    // an engine entry of the walker: its callback parsed for itself
    if(tags.map){
      return n.value
    }
    return kids
  }
  // rule, where, tag, layer: the child's value
  return kids[0]
}

local func apply_ops(n, v, ops, buffer){
  for(let local op in values(ops)){
    local o = op.op
    if(o == "map"){
      v = op.fn(v)
    } else if(o == "pick"){
      v = at(v, op.index)
    } else if(o == "permute"){
      local out = {}
      for(let local index in values(op.indices)){
        list_push(out, at(v, index))
      }
      v = out
    } else if(o == "flatten"){
      v = str.substring(buffer, n.start, n.stop)
    }
  }
  return v
}

// the value of n in layer; changed (for a layer on "default") says whether
// some operation of the layer applied in the subtree, and with it whether
// the stored value can be used
local func evaluate(n, layer, tags, buffer, use_stored){
  local kids = n.kids
  local changed = false
  local v
  if(kids == null){
    v = leaf_value(n, tags, buffer)
  } else {
    local values = {}
    for(local i = 0; i < len(kids); i = i + 1){
      local r = evaluate(kids[i], layer, tags, buffer, use_stored)
      list_push(values, r.value)
      if(r.changed){
        changed = true
      }
    }
    if(use_stored and not changed){
      v = n.value
    } else {
      v = node_value(n, values, tags, buffer)
    }
  }
  local ops = n.p.layer_ops
  if(layer != null and ops != null and ops[layer] != null){
    local list = ops[layer]
    for(let local op in values(list)){
      if(op.op != "mark"){
        changed = true
      }
    }
    v = apply_ops(n, v, list, buffer)
  }
  return {value: v, changed: changed}
}

// evaluate(tree: Tree, layer: string | Layer, buffer: string,
//   options?: {replay?: bool}) -> any
// The value of tree in layer: a built-in layer's name ("text", "raw",
// "default") or a layer made with [layer]. buffer is the input the tree
// was parsed from. The default layer is the value the parse produced, kept
// in the tree; {replay: true} computes it from the tree instead, running
// the functions of map and the walker again.
//   local r = peg.run(numbers, "4,5", {tree: true})
//   peg.evaluate(r.tree, "text", "4,5")   // {{"4"}, ",", {"5"}}
func peg.evaluate(tree, layer, buffer, options){
  local replay = options != null and options.replay
  if(type(layer) == "string"){
    local b = builtin_layers[layer]
    if(b == null){
      error("no built-in layer ", layer)
    }
    if(layer == "default" and not replay){
      return tree.value
    }
    return evaluate(tree, null, b.tags, buffer, false).value
  }
  return evaluate(
    tree, layer, layer.tags, buffer, layer.base == "default" and not replay
  ).value
}

// on(layer: Layer, f: func(v: Pipeline): Pipeline) -> Parser
// See [on].
methods.on = peg.on
// mark(layer: Layer, data) -> Parser
// See [mark].
methods.mark = peg.mark

// ------------------------------------------------------------- highlighting

local func value_span(v){
  local t = type(v)
  if(v == null or t == "string" or t == "int" or t == "double" or t == "bool" or
    t == "function" or t == "thread" or t == "userdata"){
    return null
  }
  // (nodes report their own type, so anything else is indexable)
  if(v.token != null and v.token.start != null){
    return v.token
  }
  if(v.start != null and v.stop != null){
    return v
  }
  return null
}

// A highlighted span of the source: what [highlights] returns.
// type Span = {category: string, start: int, stop: int, line: int,
//   column: int, length: int}
// [category]: an LSP token type with modifiers after dots ("keyword", "enumMember.declaration")

// highlights(tree: Tree, buffer: string,
//   options?: {trivia?: func(buffer: string, start: int, stop: int): {Span}}
// ) -> {Span}
// The tokens of a tree as a highlighter shows them, sorted and not
// overlapping. They come from
//   token(child, category)   its span (category may be a function of the
//                            child's value returning a category or null)
//   tag(child, category)     the span of the child's value (a token, or a
//                            node's token) or of the child
//   leaves whose parser has highlight(buffer, start, stop) -> spans
//   trivia: options.trivia(buffer, start, stop) -> spans (comments) for the
//            leaves of trimmers (p.trivia, whitespace, a rule named
//            "trivia")
// An outer span wins over the ones inside it that start where it starts;
// the others overlapping it are dropped.
func peg.highlights(tree, buffer, options){
  options = options or {}
  local trivia = options.trivia
  // the spans in source order, not overlapping: the children of a node come
  // in order, and a node's own span replaces those inside it
  local out = {}
  local func add(category, start, stop){
    if(category != null and stop > start){
      local n = len(out)
      if(n == 0 or out[n - 1].stop <= start){
        list_push(out, {category: category, start: start, stop: stop})
      }
    }
  }
  local func add_all(spans){
    for(let local s in values(spans or {})){
      add(s.category, s.start, s.stop)
    }
  }
  // a span of a node over the ones its children added from index mark on:
  // those before it stay, those overlapping it go, those after it stay
  local func cover(mark, category, start, stop){
    if(category == null or stop <= start){
      return null
    }
    local after = {}
    for(len(out) > mark){
      local s = remove(out, len(out) - 1)
      if(s.start >= stop){
        list_push(after, s)
      } else if(s.stop <= start){
        list_push(out, s)
        break
      }
    }
    add(category, start, stop)
    for(local i = len(after) - 1; i >= 0; i = i - 1){
      add(after[i].category, after[i].start, after[i].stop)
    }
  }
  local func walk(n, in_trivia){
    local p = n.p
    if(p.kind == "rule" and p.rule_name == "trivia"){
      in_trivia = true
    }
    local kids = n.kids
    if(kids == null){
      if(p.highlight != null){
        add_all(p.highlight(buffer, n.start, n.stop))
      } else if(trivia != null and
        (in_trivia or p.trivia or p.kind == "whitespace")){
        add_all(trivia(buffer, n.start, n.stop))
      }
      return null
    }
    local mark = len(out)
    for(local i = 0; i < len(kids); i = i + 1){
      walk(kids[i], in_trivia)
    }
    if(p.kind == "token" and p.category != null){
      local category = p.category
      if(type(category) == "function"){
        local v = n.value
        category = category(v and v.value)
      }
      cover(mark, category, n.start, n.stop)
    } else if(p.kind == "tag"){
      local span = value_span(n.value)
      if(span != null){
        cover(mark, p.category, span.start, span.stop)
      } else {
        cover(mark, p.category, n.start, n.stop)
      }
    }
  }
  if(tree != null){
    walk(tree, false)
  }
  local ctx = {buffer: buffer}
  for(let local s in values(out)){
    local lc = peg.line_col(ctx, s.start)
    s.line = lc[0]
    s.column = lc[1]
    s.length = s.stop - s.start
  }
  return out
}

// ---------------------------------------------------------------------- methods

// The combinators as methods of [Parser], the parser as the first argument.

// tag(category: string) -> Parser
// See [tag].
methods.tag = peg.tag
// seq(...parsers: Parser) -> Parser
// This parser, then parsers (see [seq]).
methods.seq = peg.seq
// choice(...parsers: Parser) -> Parser
// This parser, or else parsers (see [choice]).
methods.choice = peg.choice
// star() -> Parser
// Zero or more times (see [star]).
methods.star = peg.star
// plus() -> Parser
// One or more times (see [plus]).
methods.plus = peg.plus
// optional(default_value?) -> Parser
// See [optional].
methods.optional = peg.optional
// star_lazy(limit: Parser) -> Parser
// Repeated until limit matches (see [star_lazy]).
methods.star_lazy = peg.star_lazy
// star_separated(separator: Parser) -> Parser
// See [star_separated].
methods.star_separated = peg.star_separated
// star_seperated(separator: Parser) -> Parser
// The old spelling of [Parser.star_separated].
methods.star_seperated = peg.star_separated
// plus_separated(separator: Parser) -> Parser
// See [plus_separated].
methods.plus_separated = peg.plus_separated
// plus_seperated(separator: Parser) -> Parser
// The old spelling of [Parser.plus_separated].
methods.plus_seperated = peg.plus_separated
// forbid(message?: string) -> Parser
// Negative lookahead (see [forbid]).
methods.forbid = peg.forbid
// and() -> Parser
// Lookahead (see [and]).
methods.and = peg.and
// neg(message?: string) -> Parser
// One character this parser does not match (see [neg]).
methods.neg = peg.neg
// pick(index: int) -> Parser
// One element of the value (see [pick]).
methods.pick = peg.pick
// permute(...indices: int) -> Parser
// Some elements of the value (see [permute]).
methods.permute = peg.permute
// map(f: func(value): any) -> Parser
// The value replaced by f(value) (see [map]).
methods.map = peg.map
// flatten(message?: string) -> Parser
// The consumed text as the value (see [flatten]).
methods.flatten = peg.flatten
// token(category?: string | func(value): string?) -> Parser
// See [token].
methods.token = peg.token
// trim(before?: Parser, after?: Parser) -> Parser
// See [trim].
methods.trim = peg.trim
// where(predicate: func(value): bool, message?: string) -> Parser
// See [where].
methods.where = peg.where
// end(message?: string) -> Parser
// Followed by the end of the input (see [end]).
methods.end = peg.end
// parse(input: string) -> {any}
// See [parse].
methods.parse = peg.parse
// run(input: string, options?: {tree?: bool}) -> Result
// See [run].
methods.run = peg.run

return peg
