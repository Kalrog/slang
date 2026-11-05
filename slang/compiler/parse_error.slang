// slang/parse_error: parse failures as messages people can read.
//
// A parse that fails knows the farthest position it reached and everything
// that was expected there (slang/grammar parses the statement again to
// collect it, see ctx.expected in slang/peg). describe turns that into a
// message, the position to report it at, notes at other positions and
// hints. The position is not always the farthest one: a bracket left open
// is reported where it was opened, a `}` that closes the wrong block where
// its indentation says a `}` is missing, an unclosed string where it
// starts, a missing `)` at the end of the line instead of at the start of
// the next one. The hints name what other languages write that slang
// does not (`&&`, `++`, `function`, `while`, ...).
//
//   local d = parse_error.describe(source, pos, {"Expected: )"})
//   // {message: "expected `)`, found `}`", pos: ..., notes: {...}, hints: {...}}
local str = require("slang/string")

local func char(b){
  return str.from_bytes({b})
}

local parse_error = {}

// What [describe] gives.
// type Diagnosis = {message: string, pos: int, notes: {Note}, hints: {string}}
// [pos]: the byte offset to report the message at
// [hints]: suggestions, each a sentence
// type Note = {pos: int, message: string}

local func byte(s, i){
  if(i < 0 or i >= len(s)){
    return -1
  }
  return str.byte_at(s, i)
}

local func is_space(b){
  return b == ' ' or b == '\t' or b == '\r' or b == '\n'
}

local func is_word(b){
  return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
    (b >= '0' and b <= '9') or b == '_'
}

local func is_digit(b){
  return b >= '0' and b <= '9'
}

// the operator characters (brackets, quotes and separators are not)
local func is_op(b){
  return b >= 0 and str.index_of("+-*/%=<>!&|^~.?@#$\\", char(b)) >= 0
}

local func line_start(s, pos){
  local i = pos
  for(i > 0 and byte(s, i - 1) != '\n'){
    i = i - 1
  }
  return i
}

local func line_end(s, pos){
  local i = str.index_of(s, "\n", pos)
  if(i < 0){
    return len(s)
  }
  return i
}

local func line_of(s, pos){
  return str.line_col(s, pos)[0]
}

// the indentation of the line pos is on, as text
local func indent_of(s, pos){
  local start = line_start(s, pos)
  local i = start
  for(byte(s, i) == ' ' or byte(s, i) == '\t'){
    i = i + 1
  }
  return str.substring(s, start, i)
}

local func first_on_line(s, pos){
  local i = pos - 1
  for(i >= 0 and (byte(s, i) == ' ' or byte(s, i) == '\t')){
    i = i - 1
  }
  return i < 0 or byte(s, i) == '\n'
}

local func where(s, pos){
  local lc = str.line_col(s, pos)
  return concat(string(lc[0]), ":", string(lc[1]))
}

// ------------------------------------------------------------ brackets

local closer_of = {['(']: ')', ['{']: '}', ['[']: ']'}
local opener_of = {[')']: '(', ['}']: '{', [']']: '['}

// Brackets, strings and comments of s up to stop, the way slang reads
// them: {open: the brackets not closed yet ({ch, pos}, innermost last),
// pairs: {open, close, ch} of every matched pair, stray: the first closer
// with nothing open or the wrong bracket open ({ch, pos, open?}),
// string: the first "..." that reaches the end of its line or a """
// that reaches stop ({pos, triple})}. It starts at from (0); with after,
// it stops at the first line end at or after after where no bracket it
// saw is open, and gives the next line's start as resume.
local func scan(s, stop, from, after){
  local open = {}
  local pairs = {}
  local stray = null
  local bad_string = null
  local i = from or 0
  for(i < stop){
    local b = byte(s, i)
    if(b == '/' and byte(s, i + 1) == '/'){
      i = line_end(s, i)
    } else if(b == '"' and byte(s, i + 1) == '"' and byte(s, i + 2) == '"'){
      local j = str.index_of(s, "\"\"\"", i + 3)
      if(j < 0 or j >= stop){
        if(bad_string == null){
          bad_string = {pos: i, triple: true}
        }
        i = stop
      } else {
        i = j + 3
      }
    } else if(b == '"'){
      local j = i + 1
      for(j < stop and byte(s, j) != '"' and byte(s, j) != '\n'){
        if(byte(s, j) == '\\'){
          j = j + 1
        }
        j = j + 1
      }
      if(byte(s, j) != '"' and bad_string == null){
        bad_string = {pos: i, triple: false}
      }
      i = j + 1
    } else if(b == '\''){
      // a character literal: one character or escape between quotes
      local j = i + 1
      if(byte(s, j) == '\\'){
        j = j + 2
        for(j < stop and j < i + 12 and byte(s, j) != '\'' and byte(s, j) != '\n'){
          j = j + 1
        }
      } else if(byte(s, j) >= 0){
        j = j + 1
        // the rest of a UTF-8 sequence
        for((byte(s, j) & 0xC0) == 0x80){
          j = j + 1
        }
      }
      if(byte(s, j) == '\''){
        i = j + 1
      } else {
        i = i + 1
      }
    } else if(closer_of[b] != null){
      append(open, {ch: b, pos: i})
      i = i + 1
    } else if(opener_of[b] != null){
      local top = open[len(open) - 1]
      if(top != null and top.ch == opener_of[b]){
        remove(open, len(open) - 1)
        append(pairs, {open: top.pos, close: i, ch: top.ch})
      } else {
        if(stray == null){
          stray = {ch: b, pos: i, open: top}
        }
        if(top != null){
          remove(open, len(open) - 1)
        }
      }
      i = i + 1
    } else {
      if(b == '\n' and after != null and i >= after and len(open) == 0){
        return {open: open, pairs: pairs, stray: stray, string: bad_string, resume: i + 1}
      }
      i = i + 1
    }
  }
  return {open: open, pairs: pairs, stray: stray, string: bad_string}
}

// resume_at(source: string, start: int, far: int) -> int
// Where a parse that recovers from a statement starting at start, which
// failed at far, should go on: the next line after far where the brackets
// the statement opened are closed again (so that the body of a block
// whose header failed is skipped with it); -1 when they never close.
func parse_error.resume_at(source, start, far){
  local r = scan(source, len(source), start, far)
  return r.resume or -1
}

// a pair whose `}` is the first thing on its line, indented differently
// from the line of its `{`: where a `}` was probably left out (the first
// such pair after from)
local func misindented(s, pairs, from){
  local best = null
  for(let local p in values(pairs)){
    if(p.open > from and first_on_line(s, p.close) and
      line_of(s, p.open) != line_of(s, p.close) and
      indent_of(s, p.open) != indent_of(s, p.close)){
      if(best == null or p.close < best.close){
        best = p
      }
    }
  }
  return best
}

// the first line after the one of pos that is indented no deeper than
// it and does not start with a closer: where a block opened at pos
// probably should have ended (-1: none)
local func dedented(s, pos){
  local depth = len(indent_of(s, pos))
  local i = line_end(s, pos)
  for(i < len(s)){
    local start = i + 1
    local j = start
    for(byte(s, j) == ' ' or byte(s, j) == '\t'){
      j = j + 1
    }
    local b = byte(s, j)
    if(b >= 0 and b != '\n' and b != '\r' and
      not (b == '/' and byte(s, j + 1) == '/')){
      if(j - start <= depth and opener_of[b] == null){
        return start
      }
    }
    i = line_end(s, start)
  }
  return -1
}

// ------------------------------------------------------------ tokens

local twos = {
  "==", "!=", "<=", ">=", "&&", "||", "++", "--", "+=", "-=", "*=", "/=",
  "%=", "..", "=>", "->", "<<", ">>", "::",
}

// the token that starts at pos, as text (null at the end of the input)
local func token_at(s, pos){
  local b = byte(s, pos)
  if(b < 0){
    return null
  }
  if(is_word(b)){
    local j = pos
    for(is_word(byte(s, j))){
      j = j + 1
    }
    return str.substring(s, pos, j)
  }
  if(str.starts_with(s, "\"\"\"", pos) or str.starts_with(s, "...", pos)){
    return str.substring(s, pos, pos + 3)
  }
  local two = str.substring(s, pos, pos + 2)
  for(let local t in values(twos)){
    if(t == two){
      return two
    }
  }
  return str.substring(s, pos, pos + 1)
}

// where the token before pos ends: back over whitespace and comments
local func previous_end(s, pos){
  local k = pos
  for(true){
    for(k > 0 and is_space(byte(s, k - 1))){
      k = k - 1
    }
    // a // comment on this line, outside of a string
    local start = line_start(s, k)
    local comment = -1
    local quoted = false
    for(local i = start; i < k - 1; i = i + 1){
      local b = byte(s, i)
      if(quoted){
        if(b == '\\'){
          i = i + 1
        } else if(b == '"'){
          quoted = false
        }
      } else if(b == '"'){
        quoted = true
      } else if(b == '/' and byte(s, i + 1) == '/'){
        comment = i
        break
      }
    }
    if(comment < 0){
      return k
    }
    k = comment
  }
}

// the token that ends at stop
local func token_before(s, stop){
  if(stop <= 0){
    return null
  }
  local b = byte(s, stop - 1)
  if(is_word(b)){
    local j = stop
    for(j > 0 and is_word(byte(s, j - 1))){
      j = j - 1
    }
    return str.substring(s, j, stop)
  }
  if(b == '"'){
    return "a string"
  }
  local two = str.substring(s, stop - 2, stop)
  for(let local t in values(twos)){
    if(t == two and stop >= 2){
      return two
    }
  }
  return str.substring(s, stop - 1, stop)
}

local func show(t){
  if(t == null){
    return "end of input"
  }
  if(t == "a string"){
    return t
  }
  if(t == "\n"){
    return "end of line"
  }
  if(is_digit(str.byte_at(t, 0))){
    return concat("number `", t, "`")
  }
  return concat("`", t, "`")
}

// ------------------------------------------------------------ expectations

local nouns = {
  expression: "an expression", statement: "a statement", name: "a name",
  identifier: "a name", parameter: "a name", number: "a number",
  ["[0-9]"]: "a number", ["[a-zA-Z_]"]: "a name",
  ["end of input"]: "the end of the input",
}

// labels only a token's own insides expect (a number's digits, a string's
// escapes), or conditions rather than tokens
local dropped = {
  ["success not"]: true, ["input not"]: true,
  ["on the same line"]: true, ["end of number"]: true,
}

// what can continue an expression that is complete: when a separator or a
// closer is expected too, these are not what is missing
local continuations = {
  ["("]: true, ["{"]: true, ["["]: true, [":"]: true, ["."]: true,
  ["="]: true, ["@meta"]: true,
}

// what can start an expression: implied when an expression is expected
local starters = {
  ["("]: true, ["{"]: true, ["["]: true, ["-"]: true, ["+"]: true,
  ["not"]: true, ["func"]: true, ["\""]: true, ["\"\"\""]: true,
  ["..."]: true, ["let"]: true,
}

local func label_of(raw){
  local t = raw
  if(str.starts_with(t, "Expected: ")){
    t = str.substring(t, 10)
  } else if(str.ends_with(t, " expected")){
    t = str.substring(t, 0, len(t) - 9)
  } else {
    return null
  }
  if(len(t) >= 2 and str.starts_with(t, "\"") and str.ends_with(t, "\"")){
    t = str.substring(t, 1, len(t) - 1)
  }
  if(dropped[t] or t == ""){
    return null
  }
  if(nouns[t] != null){
    return {text: nouns[t], noun: true, raw: t}
  }
  if(str.starts_with(t, "[")){
    // a character class inside a token
    return null
  }
  local b = str.byte_at(t, 0)
  // a number's or a word's insides: "0", "_", "e"
  if(len(t) == 1 and (is_word(b) or t == "\\")){
    return null
  }
  return {text: concat("`", t, "`"), noun: false, raw: t}
}

// the labels of the raw expectations, in order, once each, without the
// ones another label implies
local func labels(expected){
  local out = {}
  local seen = {}
  for(let local raw in values(expected)){
    local l = label_of(raw)
    if(l != null and not seen[l.text]){
      seen[l.text] = true
      append(out, l)
    }
  }
  local has_noun = func(n){ return seen[n] == true }
  local closes = seen["`)`"] or seen["`}`"] or seen["`]`"] or seen["`,`"]
  local statement_ends = seen["`}`"] or seen["`return`"] or
    seen["a statement"]
  local kept = {}
  for(let local l in values(out)){
    local drop = false
    if(has_noun("an expression") and starters[l.raw]){
      drop = true
    }
    if(closes and continuations[l.raw]){
      drop = true
    }
    if(has_noun("a name") and l.raw == "@meta"){
      drop = true
    }
    // the optional `;` after a statement, and the statements a block may
    // end with, when the block's `}` is expected
    if(statement_ends and (l.raw == ";" or l.raw == "return" or
      l.raw == "break" or l.raw == "continue")){
      drop = true
    }
    if(not drop){
      append(kept, l)
    }
  }
  if(len(kept) == 0){
    return out
  }
  // nouns first: "an expression or `{`"
  local sorted = {}
  for(let local l in values(kept)){
    if(l.noun){ append(sorted, l) }
  }
  for(let local l in values(kept)){
    if(not l.noun){ append(sorted, l) }
  }
  return sorted
}

local func join_labels(ls){
  local texts = {}
  for(let local l in values(ls)){
    append(texts, l.text)
  }
  local n = len(texts)
  if(n == 0){
    return "something else"
  }
  if(n == 1){
    return texts[0]
  }
  local head = {}
  for(local i = 0; i < n - 1; i = i + 1){
    append(head, texts[i])
  }
  return concat(str.join(head, ", "), " or ", texts[n - 1])
}

local func has_label(ls, raw){
  for(let local l in values(ls)){
    if(l.raw == raw){
      return true
    }
  }
  return false
}

// ------------------------------------------------------------ hints

// the run of operator characters at pos, and the one just before it
local func operator_run(s, pos){
  local a = pos
  for(a > 0 and is_op(byte(s, a - 1))){
    a = a - 1
  }
  local b = pos
  for(is_op(byte(s, b))){
    b = b + 1
  }
  return str.substring(s, a, b)
}

local word_hints = {
  ["function"]: "slang declares functions with func: `func name(a, b){ ... }`",
  ["then"]: "slang writes blocks in braces: `if(c){ ... }`",
  ["do"]: "slang writes blocks in braces: `for(c){ ... }`",
  ["end"]: "slang writes blocks in braces: `if(c){ ... }`",
  ["elif"]: "slang writes `else if(c){ ... }`",
  ["elseif"]: "slang writes `else if(c){ ... }`",
  ["while"]: "slang has no while: `for(condition){ ... }` loops while the condition holds",
  ["var"]: "slang declares variables with local: `local x = 1`",
  ["let"]: "slang declares variables with local: `local x = 1`",
  ["const"]: "slang declares variables with local: `local x = 1`",
  ["def"]: "slang declares functions with func: `func name(a, b){ ... }`",
  ["fn"]: "slang declares functions with func: `func name(a, b){ ... }`",
  ["elsif"]: "slang writes `else if(c){ ... }`",
  ["in"]: "a for-in loop binds with a pattern: `for(let local x in values(t)){ ... }`",
}

local func hints(s, pos, found, before, ls){
  local out = {}
  local run = operator_run(s, pos)
  if(str.index_of(run, "&&") >= 0){
    append(out, "slang writes `and` for &&")
  }
  if(str.index_of(run, "||") >= 0){
    append(out, "slang writes `or` for ||")
  }
  if(str.starts_with(run, "!") and not str.starts_with(run, "!=")){
    append(out, "slang writes `not x` for !x")
  }
  if(str.index_of(run, "++") >= 0 or str.index_of(run, "--") >= 0){
    append(out, "slang has no ++ or --: write `i = i + 1`")
  } else if(len(run) == 2 and str.ends_with(run, "=") and
    str.index_of("+-*/%", str.substring(run, 0, 1)) >= 0){
    append(out, concat(
      "slang has no ", run, ": write `x = x ", str.substring(run, 0, 1), " y`"
    ))
  }
  if(run == ".."){
    append(out, "slang joins strings with concat: `concat(a, b)`")
  }
  if(found == "[" and has_label(ls, "expression")){
    append(out, "slang writes lists and tables in braces: `{1, 2}`")
  }
  local word = null
  if(found != null and word_hints[found] != null){
    word = found
  } else if(before != null and word_hints[before] != null){
    word = before
  }
  if(word != null){
    append(out, word_hints[word])
  }
  if((before == "if" or before == "for") and has_label(ls, "(")){
    append(out, concat(
      "slang writes the condition in parentheses: `", before, "(x > 1){ ... }`"
    ))
  }
  return out
}

// ------------------------------------------------------------ describe

// describe(source: string, pos: int, expected: {string}) -> Diagnosis
// What a parse that failed at pos (its farthest failure) should say, given
// the messages of everything that was expected there.
func parse_error.describe(source, pos, expected){
  local s = source
  local stop = previous_end(s, pos)
  local before = token_before(s, stop)
  local found = token_at(s, pos)
  if(byte(s, pos) == '"'){
    found = "a string"
  }
  local ls = labels(expected)
  local d = {message: null, pos: pos, notes: {}, hints: hints(s, pos, found, before, ls)}

  // a string not closed before the failure
  local whole = scan(s, len(s))
  local bad = whole.string
  if(bad != null and bad.pos <= pos and
    (bad.triple or line_of(s, bad.pos) == line_of(s, pos))){
    d.pos = bad.pos
    if(bad.triple){
      d.message = "this \"\"\" string is not closed"
    } else {
      d.message = "this string is not closed"
      append(d.hints, "a \"...\" string ends on its line; \"\"\"...\"\"\" strings span lines")
    }
    return d
  }

  local upto = scan(s, pos)
  local innermost = upto.open[len(upto.open) - 1]

  // the end of the input inside an open bracket
  if(found == null and innermost != null){
    local suspect = misindented(s, whole.pairs, innermost.pos)
    local ch = char(innermost.ch)
    local close = char(closer_of[innermost.ch])
    if(suspect != null){
      d.pos = suspect.close
      d.message = concat("a `", close, "` is probably missing before this line")
      append(d.hints, concat(
        "this `", close, "` closes the `", ch, "` on line ",
        line_of(s, suspect.open), ", but it is indented like line ",
        line_of(s, innermost.pos)
      ))
      append(d.notes, {
        pos: innermost.pos,
        message: concat("this `", ch, "` is not closed"),
      })
    } else {
      local line = dedented(s, innermost.pos)
      if(line >= 0){
        d.pos = line
        d.message = concat("a `", close, "` is probably missing before this line")
        append(d.hints, concat(
          "the `", ch, "` on line ", line_of(s, innermost.pos),
          " is not closed, and this line is indented like that one"
        ))
        append(d.notes, {
          pos: innermost.pos,
          message: concat("this `", ch, "` is not closed"),
        })
      } else {
        d.pos = innermost.pos
        d.message = concat("this `", ch, "` is not closed")
      }
    }
    return d
  }

  // a closer with nothing to close
  local here = scan(s, pos + 1)
  if(found != null and opener_of[str.byte_at(found, 0)] != null and
    len(found) == 1 and here.stray != null and here.stray.pos == pos and
    here.stray.open == null){
    d.message = concat("this `", found, "` has no `", char(opener_of[str.byte_at(found, 0)]), "` to close")
    local suspect = misindented(s, here.pairs, -1)
    if(suspect != null){
      append(d.notes, {
        pos: suspect.close,
        message: concat(
          "this `", char(closer_of[suspect.ch]), "` closes the `",
          char(suspect.ch), "` on line ", line_of(s, suspect.open),
          " but is indented differently"
        ),
      })
    }
    return d
  }

  local what = join_labels(ls)
  // the next line starts where something was still missing on this one:
  // report it at the end of this line
  local missing_on_line = has_label(ls, ")") or has_label(ls, "}") or
    has_label(ls, "]") or has_label(ls, ",") or has_label(ls, "expression")
  if(found == "else"){
    d.message = "this `else` does not follow an `if` block"
    return d
  }
  if((missing_on_line or found == null) and stop < pos and line_of(s, stop) < line_of(s, pos) and
    before != null){
    d.pos = stop
    d.message = concat("expected ", what, " after ", show(before))
  } else {
    d.message = concat("expected ", what, ", found ", show(found))
  }
  if(innermost != null and line_of(s, innermost.pos) != line_of(s, d.pos)){
    local close = char(closer_of[innermost.ch])
    if(has_label(ls, close)){
      append(d.notes, {
        pos: innermost.pos,
        message: concat("this `", char(innermost.ch), "` is not closed yet"),
      })
    }
  }
  return d
}

// offset(source: string, line: int, column: int) -> int
// The byte offset of a 1-based line and column.
func parse_error.offset(source, line, column){
  local pos = 0
  for(local l = 1; l < line; l = l + 1){
    local next = str.index_of(source, "\n", pos)
    if(next < 0){
      return len(source)
    }
    pos = next + 1
  }
  return pos + column - 1
}

// excerpt(source: string, pos: int) -> string
// The line pos is on, numbered, with a caret under pos.
//   12 | local y = x +* 2
//      |              ^
func parse_error.excerpt(source, pos){
  if(pos > len(source)){
    pos = len(source)
  }
  local start = line_start(source, pos)
  local text = str.substring(source, start, line_end(source, pos))
  local number = string(line_of(source, pos))
  local pad = " " * len(number)
  // the caret keeps the line's tabs so that it lines up
  local lead = ""
  for(local i = start; i < pos; i = i + 1){
    if(byte(source, i) == '\t'){
      lead = concat(lead, "\t")
    } else {
      lead = concat(lead, " ")
    }
  }
  return concat(
    "  ", number, " | ", text, "\n",
    "  ", pad, " | ", lead, "^"
  )
}

// report(source: string, origin: string, d: Diagnosis) -> table
// The error to raise for d: {kind: "syntax", message, location, stack},
// where stack (what a command line prints after the location) is the
// excerpt, the hints and the notes.
func parse_error.report(source, origin, d){
  local lc = str.line_col(source, d.pos)
  local parts = {parse_error.excerpt(source, d.pos)}
  for(let local h in values(d.hints)){
    append(parts, concat("  hint: ", h))
  }
  for(let local n in values(d.notes)){
    append(parts, concat("  note: ", origin, ":", where(source, n.pos), ": ", n.message))
    append(parts, parse_error.excerpt(source, n.pos))
  }
  return {
    kind: "syntax",
    message: d.message,
    location: {origin: origin, line: lc[0], column: lc[1]},
    stack: str.join(parts, "\n"),
  }
}

return parse_error
