// sql{ ... } literals: SQL that reads as SQL, with slang values bound
// safely, for slang/sqlite.
//
//   local rows = db:all(sql{
//     select id, text, done from todos
//     where done = {done} and id in ({...ids})
//     order by id
//   })
//   local where = done == null and sql{} or sql{ where done = {done} }
//   db:all(sql{ select * from todos {where} })
//
// `{expr}` is a bound parameter, never text; `{...list}` expands to one
// parameter per element (an empty list to null); a `{fragment}` whose
// value is itself a sql{} literal is spliced in with its own parameters.
// Comments (-- and /* */) are dropped and whitespace collapsed, so the
// text is one line in error messages and as a cache key. SQL keywords,
// strings and numbers are tagged for the highlighter. A literal lowers to
// sqlite.query(text, {values}, "file:line"); one without values is made
// once per unit.
local peg = require("slang/peg")
local ast = require("slang/ast")
local str = require("slang/string")
local g = require("slang/compiler").grammar()

// ------------------------------------------------------------ lexical pieces

local keyword_list = {
  "select", "from", "where", "and", "or", "not", "null", "is", "in", "like",
  "glob", "between", "order", "by", "group", "having", "limit", "offset", "asc",
  "desc", "distinct", "all", "as", "on", "using", "join", "left", "right",
  "inner", "outer", "cross", "natural", "union", "except", "intersect", "with",
  "recursive", "insert", "into", "values", "update", "set", "delete", "replace",
  "returning", "default", "conflict", "do", "nothing", "create", "table", "if",
  "exists", "drop", "index", "view", "trigger", "alter", "add", "column",
  "rename", "to", "primary", "key", "unique", "check", "references", "foreign",
  "constraint", "autoincrement", "without", "rowid", "integer", "int", "text",
  "real", "blob", "boolean", "bool", "numeric", "varchar", "case", "when",
  "then", "else", "end", "cast", "collate", "escape", "exists", "begin",
  "commit", "rollback", "transaction", "savepoint", "release", "pragma",
  "explain", "vacuum", "analyze", "true", "false", "current_timestamp",
  "current_date", "current_time"
}
local keywords = {}
for(let local k in values(keyword_list)){
  keywords[k] = true
}

local ws = peg.pattern(" \t\r\n"):star()

local func punct(s){
  return peg.token(peg.string(s), "punctuation")
}

// a word: a keyword is highlighted, any other identifier is left alone
local word_chars = peg.seq(
  peg.pattern("a-zA-Z_"),
  peg.pattern("a-zA-Z0-9_"):star(),
):flatten("word expected")
local word = peg.token(word_chars, func(w){
  if(keywords[str.lower(w)] == true){
    return "keyword"
  }
  return null
}):map(func(t){ return {text: t.value} })

local number = peg.token(peg.seq(
  peg.digit():plus(),
  peg.seq(peg.char("."), peg.digit():star()):optional(),
):flatten("number expected"), "number"):map(func(t){
  return {text: t.value}
})

// 'text' with '' for a quote inside
local sql_string = peg.token(peg.custom(func(self, ctx, pos){
  local buf = ctx.buffer
  if(str.substring(buf, pos, pos + 1) != "'"){
    return peg.fail(ctx, pos, "string expected")
  }
  local i = pos + 1
  local n = len(buf)
  for(i < n){
    local c = str.substring(buf, i, i + 1)
    if(c == "'"){
      if(str.substring(buf, i + 1, i + 2) == "'"){
        i = i + 2
      } else {
        ctx.value = str.substring(buf, pos, i + 1)
        return i + 1
      }
    } else {
      i = i + 1
    }
  }
  return peg.fail(ctx, pos, "unterminated SQL string")
}), "string"):map(func(t){
  return {text: t.value}
})

// -- to the end of the line, /* */ blocks; dropped from the text
local line_comment = peg.token(
  peg.seq(peg.string("--"), peg.pattern("^\n"):star()):flatten(),
  "comment",
):map(func(t){
  return {text: " "}
})
local block_comment = peg.token(peg.custom(func(self, ctx, pos){
  local buf = ctx.buffer
  if(str.substring(buf, pos, pos + 2) != "/*"){
    return peg.fail(ctx, pos, "comment expected")
  }
  local stop = str.index_of(buf, "*/", pos + 2)
  if(stop < 0){
    return peg.fail(ctx, pos, "unterminated comment")
  }
  ctx.value = str.substring(buf, pos, stop + 2)
  return stop + 2
}), "comment"):map(func(t){
  return {text: " "}
})

// anything else up to the next brace, quote, word, digit or comment start
local other_class = str.char_class("^{}'a-zA-Z0-9_/-")
local other = peg.custom(func(self, ctx, pos){
  local q = str.class_run(other_class, ctx.buffer, pos)
  if(q == pos){
    return peg.fail(ctx, pos, "sql expected")
  }
  ctx.value = {text: str.substring(ctx.buffer, pos, q)}
  return q
})
// a lone - or / that does not start a comment
local lone = peg.pattern("/-"):map(func(c){ return {text: c} })

local hole = peg.choice(
  peg.seq(
    punct("{"), ws, peg.token(peg.string("..."), "operator"), g:rule("expr"),
    ws, punct("}")
  )
    :map(func(v){
      return {list: v[3]}
    }),
  peg.seq(punct("{"), ws, g:rule("expr"), ws, punct("}")):map(func(v){
    return {value: v[2]}
  }),
)

local piece = peg.choice(
  hole, sql_string, line_comment, block_comment, word, number, other, lone
)

// ------------------------------------------------------------ building

// the runtime module, required once per unit
local func runtime(name, token){
  local module = g:unit_local("slang/sqlite", +{require("slang/sqlite")})
  return ast.node(
    "Index",
    {
      receiver: module, index: ast.node("String", {value: name}, token),
      dotStyle: true
    }, token
  )
}
local func runtime_call(name, args, token){
  return ast.node("Call", {function: runtime(name, token), args: args}, token)
}

local space_class = str.char_class(" \t\r\n")
// whitespace runs collapsed to one space, the ends trimmed
local func collapse(text){
  local out = {}
  local n = len(text)
  local i = 0
  for(i < n){
    local q = str.class_run(space_class, text, i)
    if(q > i){
      if(len(out) > 0){
        append(out, " ")
      }
      i = q
    } else {
      local c = str.rune_len_at(text, i)
      append(out, str.substring(text, i, i + c))
      i = i + c
    }
  }
  local joined = str.join(out, "")
  return str.trim(joined)
}

local func build(pieces, token){
  local text = {}
  local holes = {}
  for(let local p in values(pieces)){
    if(p.text != null){
      append(text, p.text)
    } else {
      append(text, "?")
      if(p.list != null){
        append(holes, runtime_call("list", {p.list}, token))
      } else {
        append(holes, p.value)
      }
    }
  }
  local sql = collapse(str.join(text, ""))
  local origin = concat(g:origin() or "sql", ":", token.line)
  local text_node = ast.node("String", {value: sql}, token)
  local origin_node = ast.node("String", {value: origin}, token)
  if(len(holes) == 0){
    local node = g:unit_local(concat("sql_", str.hash(sql)), runtime_call(
      "query", {text_node, ast.node("Null", {}, token), origin_node}, token
    ))
    node.token = token
    return node
  }
  local fields = {}
  for(let local v in values(holes)){
    append(fields, ast.node("Field", {value: v}, token))
  }
  // the count, because a null value would end the list's length early
  local count_node = ast.node("Int", {value: len(holes)}, token)
  return runtime_call(
    "query",
    {
      text_node, ast.node("Table", {fields: fields}, token), origin_node,
      count_node
    }, token
  )
}

// ------------------------------------------------------------ syntax

g
  :expression()
  :primary(
    "sql",
    peg.seq(g:keyword("sql"), punct("{"), piece:star(), punct("}")):map(func(v){
      return {token: v[0], ast: build(v[2], v[0])}
    }),
  )
