// slang/format: the formatter (`slang fmt`).
//
// Formatting works on the lossless tree of a file (see slang/peg), not on
// its AST: extension syntax is expanded while parsing, so only the tree still
// shows what was written. The layout comes from marks in the format layer,
// set on the parsers of the grammar (format.gaps, format.indent, ...): they
// say what goes between two tokens, what is a group that is laid out on one
// line or broken, what is indented. A document printer in the style of
// Wadler's "prettier printer" then fits the result into 80 columns.
//
// Syntax that extensions add is formatted when the extension marks its
// parsers like the core does (format.gaps, format.indent, ...). Unmarked,
// it keeps its own line structure (verbatim mode): its gaps are what the
// source has, re-indented to where the syntax now sits. Core syntax inside
// it (an expression, a block) is formatted either way.
//
// format.source checks its own result before returning it: the output has
// the same tokens as the input (but for dropped `;` and trailing commas),
// the same AST, and the same comments in the same order.
local peg = require("slang/peg")
local str = require("slang/string")

local format = {}

local WIDTH = 80
local INDENT = 2

// ------------------------------------------------------------ the layer
//
// Marks are tables merged per node:
//   before, after    the gap before the node's first token / after its last:
//                    "none", "space", "line" (a space or a break), "softline"
//                    (nothing or a break), "hardline", "brace" (nothing
//                    before a `{`, a space before anything else); without a
//                    mark a gap is a space if the source had whitespace
//   blank            a hardline before the node may keep one blank line
//   group            the node is laid out on one line if it fits, else broken
//   indent           breaks in the node, and the gap before it, are indented
//   hug              a group that, when something inside it must break,
//                    keeps its own breaks flat if the first line fits
//   drop             the node's tokens are left out (a `;`)
//   trailing_comma   the node is a `,` when its group breaks, else nothing
//   verbatim         gaps in the node are the source's (extension syntax)
//   formatted        gaps in the node are formatted again

format.layer = peg.layer("format", "text")

// mark(parser, data) -> parser with the format marks data
func format.mark(parser, data){
  return peg.mark(parser, format.layer, data)
}

// gaps(parser, before, after) -> parser with the gaps around it (null: unmarked)
func format.gaps(parser, before, after){
  local data = {}
  if(before != null){
    data.before = before
  }
  if(after != null){
    data.after = after
  }
  return format.mark(parser, data)
}

func format.group(parser){
  return format.mark(parser, {group: true})
}

// indent(parser, before, after): indented, with the gaps around it
func format.indent(parser, before, after){
  local data = {indent: true}
  if(before != null){
    data.before = before
  }
  if(after != null){
    data.after = after
  }
  return format.mark(parser, data)
}

func format.drop(parser){
  return format.mark(parser, {drop: true})
}

func format.trailing_comma(parser){
  return format.mark(parser, {trailing_comma: true})
}

func format.verbatim(parser){
  return format.mark(parser, {verbatim: true})
}

func format.formatted(parser){
  return format.mark(parser, {formatted: true})
}

// whether parser (or a parser inside it) carries layout marks; rule
// references and parts already marked formatted or verbatim are not looked
// into (they have a layout of their own)
func format.uses_marks(parser){
  peg.resolve(parser)
  local seen = {}
  local stack = {parser}
  for(len(stack) > 0){
    local p = remove(stack, len(stack) - 1)
    if(p != null and seen[p] == null and p.kind != "rule"){
      seen[p] = true
      local ops = p.layer_ops
      local switches = false
      if(ops != null and ops[format.layer] != null){
        for(let local op in values(ops[format.layer])){
          if(op.op == "mark"){
            if(op.data.formatted or op.data.verbatim){
              switches = true
            } else {
              return true
            }
          }
        }
      }
      if(not switches){
        if(p.target != null){
          list_push(stack, p.target)
        }
        for(let local c in values(p.children or {})){
          list_push(stack, c)
        }
      }
    }
  }
  return false
}

// extension(parser) -> the parser an extension registered, formatted when
// it uses marks, else verbatim (what the grammar applies to the syntax an
// extension adds)
func format.extension(parser){
  if(format.uses_marks(parser)){
    return format.formatted(parser)
  }
  return format.verbatim(parser)
}

// ------------------------------------------------------------ documents
//
// A document is a string, a list of documents (concatenated) or a table
// with t: line (soft: nothing when flat, hard: always a break), group,
// indent, nest (n more columns), from_line (indented from the indentation of
// the line it starts on, not from the enclosing indent: verbatim code
// inside a group that stayed on one line), flat (groups inside stay on one
// line unless they must break), box (a part of the layout that hugging
// leaves alone), if_break (broken or flat), break_parent
// (breaks the groups around it), choice (the first option whose first line
// fits, the last one otherwise).

local LINE = {t: "line"}
local SOFTLINE = {t: "line", soft: true}
local HARDLINE = {t: "line", hard: true}
local BREAK_PARENT = {t: "break_parent"}

local func group(doc){
  return {t: "group", doc: doc}
}

local func indent(doc){
  return {t: "indent", doc: doc}
}

local func nest(n, doc){
  return {t: "nest", n: n, doc: doc}
}

local func if_break(broken, flat){
  return {t: "if_break", broken: broken, flat: flat}
}

// whether d must break: a hard line or break_parent in it (outside of an
// if_break's flat side); sets group.hard on the way
local func propagate(d){
  if(type(d) == "string"){
    return false
  }
  local t = d.t
  if(t == null){
    local hard = false
    for(local i = 0; i < len(d); i = i + 1){
      if(propagate(d[i])){
        hard = true
      }
    }
    return hard
  }
  if(t == "line"){
    return d.hard == true
  }
  if(t == "break_parent"){
    return true
  }
  if(t == "group"){
    if(d.hard == null){
      d.hard = propagate(d.doc)
    }
    return d.hard
  }
  if(t == "indent" or t == "nest" or t == "from_line" or t == "flat" or
    t == "box"){
    return propagate(d.doc)
  }
  if(t == "if_break"){
    propagate(d.flat)
    return propagate(d.broken)
  }
  if(t == "fill"){
    local hard = false
    for(local i = 0; i < len(d.parts); i = i + 1){
      if(propagate(d.parts[i])){
        hard = true
      }
    }
    return hard
  }
  if(t == "choice"){
    // the options are alternatives: the choice must break when its last
    // (the plain layout) must
    local hard = false
    for(local i = 0; i < len(d.options); i = i + 1){
      hard = propagate(d.options[i])
    }
    return hard
  }
  return false
}

// the width of s in columns (UTF-8 continuation bytes take none)
local func width_of(s){
  local n = len(s)
  local w = n
  for(local i = 0; i < n; i = i + 1){
    local b = str.byte_at(s, i)
    if(b >= 128 and b < 192){
      w = w - 1
    }
  }
  return w
}

// the number of spaces and tabs s starts with
local func leading_space(s){
  local i = 0
  for(i < len(s) and (str.byte_at(s, i) == 32 or str.byte_at(s, i) == 9)){
    i = i + 1
  }
  return i
}

local BREAK = 1
local FLAT = 2

// whether the rest of the line fits in width: next in mode, then the
// commands below on the stack (rest_m, rest_d up to rest_n) in theirs, up to
// the first line break
local func fits(next_mode, next_doc, rest_m, rest_d, rest_n, width){
  local ms = {next_mode}
  local ds = {next_doc}
  local n = 1
  local r = rest_n
  for(true){
    if(width < 0){
      return false
    }
    if(n == 0){
      if(r == 0){
        return true
      }
      r = r - 1
      ms[0] = rest_m[r]
      ds[0] = rest_d[r]
      n = 1
    }
    n = n - 1
    local m = ms[n]
    local d = ds[n]
    if(type(d) == "string"){
      local nl = str.index_of(d, "\n")
      if(nl >= 0){
        return width - width_of(str.substring(d, 0, nl)) >= 0
      }
      width = width - width_of(d)
    } else {
      local t = d.t
      if(t == null){
        for(local i = len(d) - 1; i >= 0; i = i - 1){
          ms[n] = m
          ds[n] = d[i]
          n = n + 1
        }
      } else if(t == "line"){
        if(m == BREAK or d.hard){
          return true
        }
        if(not d.soft){
          width = width - 1
        }
      } else if(t == "group"){
        ms[n] = (d.hard and BREAK) or m
        ds[n] = d.doc
        n = n + 1
      } else if(t == "indent" or t == "nest" or t == "from_line" or t == "box"){
        ms[n] = m
        ds[n] = d.doc
        n = n + 1
      } else if(t == "flat"){
        ms[n] = FLAT
        ds[n] = d.doc
        n = n + 1
      } else if(t == "if_break"){
        ms[n] = m
        ds[n] = (m == BREAK and d.broken) or d.flat
        n = n + 1
      } else if(t == "choice"){
        ms[n] = m
        ds[n] = d.options[0]
        n = n + 1
      } else if(t == "fill"){
        local parts = d.parts
        for(local i = len(parts) - 1; i >= (d.k or 0); i = i - 1){
          ms[n] = m
          ds[n] = parts[i]
          n = n + 1
        }
      } else if(t == "fill_sep"){
        local parts = d.parts
        for(local i = len(parts) - 1; i > d.k; i = i - 1){
          ms[n] = m
          ds[n] = parts[i]
          n = n + 1
        }
      }
    }
  }
}

// hugged_part(doc) -> doc with its first group that may hug made to break,
// or null (set below, with the hugging helpers)
local hugged_part = null

local space_cache = {""}

local func spaces(n){
  local s = space_cache[n]
  if(s == null){
    s = concat(spaces(n - 1), " ")
    space_cache[n] = s
  }
  return s
}

// print(doc, width) -> text
func format.print(doc, width){
  width = width or WIDTH
  propagate(doc)
  local out = {}
  local col = 0
  // the indentation of the current line
  local line_ind = 0
  // indentation waits for the next text, so that empty lines get none
  local pending = - 1
  local si = {0}
  local sm = {BREAK}
  local sd = {doc}
  local n = 1
  local func emit(s){
    if(pending >= 0){
      if(pending > 0){
        list_push(out, spaces(pending))
      }
      col = pending
      pending = - 1
    }
    list_push(out, s)
    local nl = str.index_of(s, "\n")
    if(nl >= 0){
      // text spanning lines (a """ string, verbatim text): the column after
      // its last line, which also sets the line's indentation
      local last = nl
      for(true){
        local next = str.index_of(s, "\n", last + 1)
        if(next < 0){
          break
        }
        last = next
      }
      local tail = str.substring(s, last + 1)
      col = width_of(tail)
      line_ind = leading_space(tail)
    } else {
      col = col + width_of(s)
    }
  }
  // no trailing whitespace: the pieces of nothing but spaces before a break
  // go (a token never is one)
  local func trim_end(){
    for(len(out) > 0 and len(str.trim(out[len(out) - 1])) == 0 and
      str.index_of(out[len(out) - 1], "\n") < 0){
      remove(out, len(out) - 1)
    }
  }
  local func newline(ind){
    trim_end()
    list_push(out, "\n")
    pending = ind
    col = ind
    line_ind = ind
  }
  for(n > 0){
    n = n - 1
    local ind = si[n]
    local m = sm[n]
    local d = sd[n]
    if(type(d) == "string"){
      if(len(d) > 0){
        emit(d)
      }
    } else {
      local t = d.t
      if(t == null){
        for(local i = len(d) - 1; i >= 0; i = i - 1){
          si[n] = ind
          sm[n] = m
          sd[n] = d[i]
          n = n + 1
        }
      } else if(t == "line"){
        if(m == FLAT and not d.hard){
          if(not d.soft){
            emit(" ")
          }
        } else {
          newline(ind)
        }
      } else if(t == "group"){
        // a group that must break breaks also inside one laid out flat
        local mode = BREAK
        if(m == FLAT){
          if(not d.hard){
            mode = FLAT
          }
        } else if(not d.hard and fits(FLAT, d.doc, sm, sd, n, width - col)){
          mode = FLAT
        }
        si[n] = ind
        sm[n] = mode
        sd[n] = d.doc
        n = n + 1
      } else if(t == "indent"){
        si[n] = ind + INDENT
        sm[n] = m
        sd[n] = d.doc
        n = n + 1
      } else if(t == "nest"){
        si[n] = ind + d.n
        sm[n] = m
        sd[n] = d.doc
        n = n + 1
      } else if(t == "from_line"){
        si[n] = line_ind
        sm[n] = m
        sd[n] = d.doc
        n = n + 1
      } else if(t == "flat"){
        si[n] = ind
        sm[n] = FLAT
        sd[n] = d.doc
        n = n + 1
      } else if(t == "box"){
        si[n] = ind
        sm[n] = m
        sd[n] = d.doc
        n = n + 1
      } else if(t == "if_break"){
        si[n] = ind
        sm[n] = m
        sd[n] = (m == BREAK and d.broken) or d.flat
        n = n + 1
      } else if(t == "fill"){
        // as many parts on a line as fit: the separator before a part breaks
        // when the part doesn't fit after what is already on the line; a part
        // that doesn't fit on a line of its own breaks inside, hugging when it
        // can (a table, a function, a call with wide arguments)
        local parts = d.parts
        local k = d.k or 0
        if(m == FLAT){
          for(local i = len(parts) - 1; i >= k; i = i - 1){
            si[n] = ind
            sm[n] = FLAT
            sd[n] = parts[i]
            n = n + 1
          }
        } else {
          local content = parts[k]
          local content_mode = FLAT
          if(not fits(FLAT, content, sm, sd, 0, width - col)){
            // (only the last part hugs: a table mid-list breaks the list)
            local hugged = k + 2 >= len(parts) and content.hug and
              hugged_part(content)
            if(hugged and fits(FLAT, hugged, sm, sd, 0, width - col)){
              // indented from its line, not from the list's indent
              content = {t: "from_line", doc: hugged}
            } else {
              content_mode = BREAK
            }
          }
          if(k + 2 < len(parts)){
            si[n] = ind
            sm[n] = m
            sd[n] = {t: "fill_sep", parts: parts, k: k}
            n = n + 1
          }
          si[n] = ind
          sm[n] = content_mode
          sd[n] = content
          n = n + 1
        }
      } else if(t == "fill_sep"){
        // decided once the part before it is printed
        local parts = d.parts
        local k = d.k
        local separator = parts[k + 1]
        local next = parts[k + 2]
        local separator_mode = BREAK
        if(fits(FLAT, {separator, next}, sm, sd, 0, width - col)){
          separator_mode = FLAT
        } else {
          local hugged = k + 4 >= len(parts) and next.hug and hugged_part(next)
          if(hugged and fits(FLAT, {separator, hugged}, sm, sd, 0, width - col)){
            separator_mode = FLAT
          }
        }
        si[n] = ind
        sm[n] = m
        sd[n] = {t: "fill", parts: parts, k: k + 2}
        n = n + 1
        si[n] = ind
        sm[n] = separator_mode
        sd[n] = separator
        n = n + 1
      } else if(t == "choice"){
        local options = d.options
        // an option is laid out flat but for the groups in it that must
        // break; it is chosen when it fits up to its first break. The last
        // option (the plain layout) is the fallback.
        local chosen = options[len(options) - 1]
        local chosen_mode = m
        if(m == FLAT){
          chosen = options[0]
        } else {
          for(local i = 0; i < len(options) - 1; i = i + 1){
            if(fits(FLAT, options[i], sm, sd, n, width - col)){
              chosen = options[i]
              chosen_mode = FLAT
              break
            }
          }
        }
        si[n] = ind
        sm[n] = chosen_mode
        sd[n] = chosen
        n = n + 1
      }
    }
  }
  trim_end()
  return str.join(out, "")
}

// the group a hugging layout breaks: the last element of doc, when it is a
// group marked huggable (a table); boxes are looked into, other groups not
// the width of doc on one line, -1 when it must break
local func flat_width(d){
  if(type(d) == "string"){
    if(str.index_of(d, "\n") >= 0){
      return - 1
    }
    return width_of(d)
  }
  local t = d.t
  local list = null
  if(t == null){
    list = d
  } else if(t == "fill"){
    list = d.parts
  }
  if(list != null){
    local w = 0
    for(local i = 0; i < len(list); i = i + 1){
      local x = flat_width(list[i])
      if(x < 0){
        return - 1
      }
      w = w + x
    }
    return w
  }
  if(t == "line"){
    if(d.hard){
      return - 1
    }
    if(d.soft){
      return 0
    }
    return 1
  }
  if(t == "break_parent"){
    return - 1
  }
  if(t == "if_break"){
    return flat_width(d.flat)
  }
  if(t == "choice"){
    return flat_width(d.options[0])
  }
  if(t == "group" and d.hard){
    return - 1
  }
  return flat_width(d.doc)
}

// the outermost group that may hug (a call's arguments, a table, a
// function's body) nearest the end of d
local func first_huggable(d){
  if(type(d) == "string"){
    return null
  }
  local t = d.t
  local list = null
  if(t == null){
    list = d
  } else if(t == "fill"){
    list = d.parts
  }
  // from the end: in a.b(x):c(y) the arguments of the last call
  if(list != null){
    for(local i = len(list) - 1; i >= 0; i = i - 1){
      local h = first_huggable(list[i])
      if(h != null){
        return h
      }
    }
    return null
  }
  if(t == "indent" or t == "nest" or t == "box" or t == "from_line" or
    t == "flat"){
    return first_huggable(d.doc)
  }
  // (an empty argument list has nothing to break)
  if((t == "group" or t == "choice") and d.huggable and
    (flat_width(d) < 0 or flat_width(d) > 2)){
    return d
  }
  return null
}

// the last element of a list (an argument: what a rule produced), looking
// past closing brackets and breaks
local func last_element(d){
  if(type(d) == "string"){
    return null
  }
  local t = d.t
  local list = null
  if(t == null){
    list = d
  } else if(t == "fill"){
    list = d.parts
  }
  if(list != null){
    for(local i = len(list) - 1; i >= 0; i = i - 1){
      local e = list[i]
      if(type(e) == "string"){
        if(len(str.trim(e)) > 0 and e != ")" and e != "]" and e != "}" and
          e != ","){
          return null
        }
      } else if(e.t != "line" and e.t != "if_break" and e.t != "break_parent"){
        return last_element(e)
      }
    }
    return null
  }
  if(t == "indent" or t == "nest"){
    return last_element(d.doc)
  }
  return d
}

// the group a hugging layout breaks: the first one that may hug (a call's
// arguments, a table, a function's body) in the last element of doc
// a call hugs only when it is worth breaking: f(x, g(a, b, c)) with g(...)
// too wide for a line of its own; f(x, tok("<")) does not break tok's
local HUG_CALL_WIDTH = 60

// the group a part (an argument, an operand) hugs with, or null: a call
// only when the part is too wide to sit on a line of its own anyway
local huggable_in = null

// the group a hugging layout breaks: in the last element of doc
local func last_huggable(d){
  local e = last_element(d)
  if(e == null){
    return null
  }
  return huggable_in(e)
}

// a call whose own last argument hugs (a function, a table) passes the hug
// on: f(x, g(y, func(){ ... })) breaks the function's body, not g's arguments
huggable_in = func(e){
  local h = first_huggable(e)
  if(h != null and h.huggable == "call"){
    local plain = h
    if(h.t == "choice"){
      plain = h.options[len(h.options) - 1]
    }
    local inner = last_huggable(plain.doc)
    if(inner != null){
      return inner
    }
    if(flat_width(e) < HUG_CALL_WIDTH){
      return null
    }
  }
  return h
}

// the group target made to break (for a choice: its plain layout)
local func broken_copy(target){
  local g = target
  if(target.t == "choice"){
    g = target.options[len(target.options) - 1]
  }
  return {t: "group", doc: g.doc, hard: true}
}

// doc with the group broken made to break, and nothing else changed (the
// path to it: lists, indents, boxes)
// whether target is inside d
local func contains(d, target){
  if(type(d) == "string"){
    return false
  }
  if(d == target){
    return true
  }
  local t = d.t
  local list = null
  if(t == null){
    list = d
  } else if(t == "fill"){
    list = d.parts
  } else if(t == "choice"){
    list = d.options
  }
  if(list != null){
    for(local i = 0; i < len(list); i = i + 1){
      if(contains(list[i], target)){
        return true
      }
    }
    return false
  }
  if(d.doc != null){
    return contains(d.doc, target)
  }
  return false
}

// set below
local flat_shallow = null

local func flat_shallow_box(d, broken){
  if(type(d) == "string"){
    return d
  }
  local t = d.t
  if(t == null){
    local out = {}
    for(local i = 0; i < len(d); i = i + 1){
      list_push(out, flat_shallow_box(d[i], broken))
    }
    return out
  }
  if(d == broken){
    return broken_copy(d)
  }
  if(t == "indent" or t == "box" or t == "flat" or t == "from_line"){
    return {t: t, doc: flat_shallow_box(d.doc, broken)}
  }
  if(t == "fill"){
    local parts = {}
    for(local i = 0; i < len(d.parts); i = i + 1){
      list_push(parts, flat_shallow_box(d.parts[i], broken))
    }
    return {t: "fill", parts: parts}
  }
  if(t == "nest"){
    return nest(d.n, flat_shallow_box(d.doc, broken))
  }
  // a call (or another group) holding the group broken hugs too: its own
  // breaks flat, so that only the group broken breaks
  if((t == "group" or t == "choice") and contains(d, broken)){
    local plain = d
    if(t == "choice"){
      plain = d.options[len(d.options) - 1]
    }
    return flat_shallow(plain.doc, broken)
  }
  return d
}

// flat_shallow(doc, broken) -> a hugging group's layout: its own soft
// breaks flat and its own indentation gone, the parts in boxes and nested
// groups as they are, but for the group broken (see last_huggable), which
// is made to break
flat_shallow = func(d, broken){
  if(type(d) == "string"){
    return d
  }
  local t = d.t
  if(t == null){
    local out = {}
    for(local i = 0; i < len(d); i = i + 1){
      list_push(out, flat_shallow(d[i], broken))
    }
    return out
  }
  if(t == "line"){
    if(d.hard){
      return d
    }
    if(d.soft){
      return ""
    }
    return " "
  }
  if(t == "indent" or t == "nest"){
    return flat_shallow(d.doc, broken)
  }
  if(t == "if_break"){
    return d.flat
  }
  if(broken != null){
    if(d == broken){
      return broken_copy(d)
    }
    if(t == "box" or t == "fill"){
      return flat_shallow_box(d, broken)
    }
  }
  return d
}

hugged_part = func(d){
  local h = huggable_in(d)
  if(h == null){
    return null
  }
  return flat_shallow_box(d, h)
}

// ------------------------------------------------------------ building
//
// build(node) turns a tree node into a piece {doc, first, last, before,
// after, blank, indent}: first and last are the node's first and last token
// leaves, the rest what its marks (or its first and last child's) say about
// the gaps around it. A node without tokens has no piece. The gap between
// two pieces is decided by the node they are children of (so by the
// innermost node holding both tokens), in its mode.

local strength = {
  none: 1,
  brace: 2,
  space: 2,
  softline: 3,
  line: 4,
  hardline: 5,
}

local func stronger(a, b){
  if(a == null){
    return b
  }
  if(b == null){
    return a
  }
  if(strength[b] >= strength[a]){
    return b
  }
  return a
}

local func is_space(b){
  return b == 32 or b == 9 or b == 10 or b == 13
}

local func is_word_byte(b){
  return (b >= 97 and b <= 122) or (b >= 65 and b <= 90) or
    (b >= 48 and b <= 57) or b == 95
}

local func is_digit_byte(b){
  return b != null and b >= 48 and b <= 57
}

local func count_newlines(s){
  local n = 0
  local i = str.index_of(s, "\n")
  for(i >= 0){
    n = n + 1
    i = str.index_of(s, "\n", i + 1)
  }
  return n
}

local func has_space(s){
  return len(s) > 0
}

// the comments in a gap (the text between two tokens): {start, stop}
local func gap_comments(text){
  local out = {}
  local i = str.index_of(text, "//")
  for(i >= 0){
    local j = str.index_of(text, "\n", i)
    if(j < 0){
      j = len(text)
    }
    list_push(out, {start: i, stop: j})
    i = str.index_of(text, "//", j)
  }
  return out
}

local func rstrip(s){
  local e = len(s)
  for(e > 0 and
    (str.byte_at(s, e - 1) == 32 or str.byte_at(s, e - 1) == 9 or
      str.byte_at(s, e - 1) == 13)){
    e = e - 1
  }
  return str.substring(s, 0, e)
}

// the indentation of the source line holding pos
local func line_indent(source, pos){
  local i = pos
  for(i > 0 and str.byte_at(source, i - 1) != 10){
    i = i - 1
  }
  local j = i
  for(j < len(source) and
    (str.byte_at(source, j) == 32 or str.byte_at(source, j) == 9)){
    j = j + 1
  }
  return j - i
}

local formatter_methods = {}
local formatter_meta = {__index: formatter_methods}

local func new_formatter(source){
  local f = {source: source, mark_cache: {}, soft_pending: false}
  f.meta = formatter_meta
  return f
}

func formatter_methods.text(self, n){
  return str.substring(self.source, n.start, n.stop)
}

// the merged format marks of a node's parser
func formatter_methods.marks(self, n){
  local p = n.p
  local m = self.mark_cache[p]
  if(m == null){
    m = {}
    for(let local data in values(peg.marks(n, format.layer))){
      for(let local e in entries(data)){
        m[e[0]] = e[1]
      }
    }
    self.mark_cache[p] = m
  }
  return m
}

// nothing between two tokens that would run into one: a space after all
func formatter_methods.safe_none(self, a, b){
  local x = str.byte_at(self.source, a.last.stop - 1)
  local y = str.byte_at(self.source, b.first.start)
  if(is_word_byte(x) and is_word_byte(y)){
    return " "
  }
  // - 1 is not -1, - -x is not --x, a / /b/ is not a //
  if((x == 45 or x == 43) and (is_digit_byte(y) or y == x)){
    return " "
  }
  if(x == 47 and y == 47){
    return " "
  }
  if(is_digit_byte(x) and y == 46){
    return " "
  }
  return ""
}

// the gap between pieces a and b in formatted code; kind overrides the marks
func formatter_methods.gap(self, a, b, kind, blank){
  local text = str.substring(self.source, a.last.stop, b.first.start)
  kind = kind or stronger(a.after, b.before)
  if(blank == null){
    blank = b.blank == true
  }
  local comments = gap_comments(text)
  if(len(comments) == 0){
    if(kind == null){
      if(has_space(text)){
        return " "
      }
      return self:safe_none(a, b)
    }
    if(kind == "none"){
      return self:safe_none(a, b)
    }
    if(kind == "space"){
      return " "
    }
    if(kind == "brace"){
      if(str.byte_at(self.source, b.first.start) == 123){
        return ""
      }
      return " "
    }
    if(kind == "line"){
      return LINE
    }
    if(kind == "softline"){
      return SOFTLINE
    }
    if(blank and count_newlines(text) >= 2){
      return {HARDLINE, HARDLINE}
    }
    return HARDLINE
  }
  // comments: one on the line of a stays there; the others get lines of
  // their own; a line break always follows the last one
  local keep_blank = kind == "hardline"
  local parts = {}
  local i = 0
  local first = comments[0]
  if(str.index_of(str.substring(text, 0, first.start), "\n") < 0){
    list_push(parts, " ")
    list_push(parts, rstrip(str.substring(text, first.start, first.stop)))
    i = 1
  }
  local lines = {}
  for(i < len(comments)){
    local c = comments[i]
    local from = 0
    if(i > 0){
      from = comments[i - 1].stop
    }
    if(keep_blank and i > 0 and
      count_newlines(str.substring(text, from, c.start)) >= 2){
      list_push(lines, HARDLINE)
    } else if(keep_blank and i == 0 and blank and
      count_newlines(str.substring(text, 0, c.start)) >= 2){
      list_push(lines, HARDLINE)
    }
    list_push(lines, HARDLINE)
    list_push(lines, rstrip(str.substring(text, c.start, c.stop)))
    i = i + 1
  }
  if(a.indent and not b.indent){
    // comments after the last line of an indented part (before a `}`)
    list_push(parts, indent(lines))
  } else {
    list_push(parts, lines)
  }
  list_push(parts, HARDLINE)
  local rest = str.substring(text, comments[len(comments) - 1].stop)
  if(keep_blank and blank and count_newlines(rest) >= 2){
    list_push(parts, HARDLINE)
  }
  list_push(parts, BREAK_PARENT)
  return parts
}

// joins pieces in formatted code
func formatter_methods.join(self, pieces){
  local parts = {}
  local prev = null
  for(local i = 0; i < len(pieces); i = i + 1){
    local p = pieces[i]
    if(p.virtual){
      list_push(parts, p.doc)
    } else {
      local gap = ""
      if(prev != null){
        gap = self:gap(prev, p)
      }
      if(p.indent){
        list_push(parts, indent({gap, p.doc}))
      } else {
        list_push(parts, gap)
        list_push(parts, p.doc)
      }
      prev = p
    }
  }
  return parts
}

// joins pieces of verbatim code: the source's gaps, each line re-indented
// relative to the line the node starts on
func formatter_methods.join_verbatim(self, pieces){
  local source = self.source
  local base = line_indent(source, pieces[0].first.start)
  local func rel(line){
    local r = leading_space(line) - base
    if(r < 0){
      return 0
    }
    return r
  }
  local segments = {}
  local current = {}
  local current_nest = - 1
  local func close(){
    if(current_nest < 0){
      list_push(segments, current)
    } else {
      list_push(segments, nest(current_nest, {HARDLINE, current}))
    }
  }
  local prev = null
  for(local i = 0; i < len(pieces); i = i + 1){
    local p = pieces[i]
    if(prev != null and not p.virtual){
      local text = str.substring(source, prev.last.stop, p.first.start)
      if(str.index_of(text, "\n") < 0){
        list_push(current, text)
      } else {
        local lines = str.split(text, "\n")
        list_push(current, rstrip(lines[0]))
        close()
        for(local j = 1; j < len(lines) - 1; j = j + 1){
          local l = rstrip(lines[j])
          if(len(str.trim(l)) == 0){
            list_push(segments, HARDLINE)
          } else {
            list_push(segments, nest(rel(l), {
              HARDLINE,
              str.substring(l, leading_space(l)),
            }))
          }
        }
        current = {}
        current_nest = rel(lines[len(lines) - 1])
      }
    }
    // core code inside verbatim code breaks only where it must
    list_push(current, {t: "flat", doc: p.doc})
    if(not p.virtual){
      prev = p
    }
  }
  close()
  return {t: "from_line", doc: segments}
}

// the piece of a node, in mode ("formatted" or "verbatim")
func formatter_methods.build(self, n, mode){
  local kids = n.kids
  if(kids == null){
    local p = n.p
    if(n.start == n.stop or p.trivia or p.kind == "whitespace"){
      return null
    }
    return {doc: self:text(n), first: n, last: n}
  }
  local m = self:marks(n)
  local p = n.p
  if(m.verbatim){
    mode = "verbatim"
  } else if(m.formatted){
    mode = "formatted"
  } else if(p.kind == "rule"){
    if(n.owner == "core"){
      mode = "formatted"
    }
  }
  if(m.drop){
    return null
  }
  if(m.trailing_comma){
    return {doc: if_break(",", ""), virtual: true}
  }
  // a block marked hard_body (a catch's) breaks even with one statement
  if(m.hard_body){
    self.hard_pending = true
  }
  local piece = self:build_node(n, m, mode)
  if(m.hard_body){
    self.hard_pending = false
  }
  return piece
}

func formatter_methods.build_node(self, n, m, mode){
  local kids = n.kids
  local p = n.p
  local piece = null
  // a lexical token (one with a category) is one piece of text, whatever
  // its parts; token() without a category only records a span
  if(p.kind == "token" and p.category != null){
    return {doc: self:text(n), first: n, last: n}
  }
  if(p.kind == "trim"){
    piece = self:build(kids[n.at], mode)
  } else if(mode == "formatted" and p.form != null){
    piece = self:build_operator(n)
  } else if(p.kind == "rule" and p.rule_name == "block"){
    local hard = self.hard_pending
    self.hard_pending = false
    if(not hard){
      piece = self:build_soft_block(n)
    }
  } else if(p.kind == "unit"){
    piece = self:build_unit(n)
  }
  if(piece == null){
    local pieces = {}
    for(local i = 0; i < len(kids); i = i + 1){
      local k = self:build(kids[i], mode)
      if(k != null){
        list_push(pieces, k)
      }
    }
    local real = 0
    for(let local k in values(pieces)){
      if(not k.virtual){
        real = real + 1
      }
    }
    if(real == 0){
      return null
    }
    // the elements of a list that must break (a function written over
    // several lines), for hugging
    local hard_elements = null
    if(m.fill){
      hard_elements = 0
      for(local j = 0; j < len(pieces); j = j + 2){
        if(not pieces[j].virtual and propagate(pieces[j].doc)){
          hard_elements = hard_elements + 1
        }
      }
    } else {
      for(let local k in values(pieces)){
        if(k.hard_elements != null){
          hard_elements = k.hard_elements
        }
      }
    }
    if(len(pieces) == 1){
      piece = {
        doc: pieces[0].doc,
        first: pieces[0].first,
        last: pieces[0].last,
        before: pieces[0].before,
        after: pieces[0].after,
        blank: pieces[0].blank,
        indent: pieces[0].indent,
        node: pieces[0].node,
        hard_elements: hard_elements,
      }
    } else {
      local doc = null
      if(mode == "verbatim"){
        doc = self:join_verbatim(pieces)
      } else {
        if(m.fill){
          doc = self:fill(pieces, m.fill)
        }
        if(doc == null){
          doc = self:join(pieces)
        }
      }
      local first = null
      local last = null
      for(let local k in values(pieces)){
        if(not k.virtual){
          if(first == null){
            first = k
          }
          last = k
        }
      }
      piece = {
        doc: doc,
        first: first.first,
        last: last.last,
        before: first.before,
        blank: first.blank,
        after: last.after,
        hard_elements: hard_elements,
      }
    }
  }
  if(piece == null){
    return null
  }
  if(m.group){
    // the arguments of a call that hug: one function or table among them
    // breaks, the rest stays on the call's line when it fits. A function
    // written over several lines must break; one written on one line
    // breaks when it doesn't fit, and is then laid out the same. With more
    // than one argument that must break, every argument gets a line.
    local target = null
    if(m.hug and (piece.hard_elements or 0) <= 1){
      target = last_huggable(piece.doc)
      if(target == null){
        local h = first_huggable(piece.doc)
        if(h != null and h.huggable == "body"){
          target = h
        }
      }
    }
    if(m.hug and (piece.hard_elements or 0) == 1 and propagate(piece.doc)){
      piece.doc = {
        t: "choice",
        options: {flat_shallow(piece.doc, null), group(piece.doc)},
      }
    } else if(target != null and not propagate(piece.doc)){
      // all on one line, or the target broken, or one argument per line
      local plain = group(piece.doc)
      local hugged = flat_shallow(piece.doc, target)
      piece.doc = {
        t: "choice",
        options: {{t: "flat", doc: piece.doc}, hugged, plain},
      }
    } else {
      piece.doc = group(piece.doc)
    }
    if(m.huggable){
      piece.doc.huggable = m.huggable
    }
  }
  local out = {
    doc: piece.doc,
    first: piece.first,
    last: piece.last,
    before: piece.before,
    after: piece.after,
    blank: piece.blank,
    indent: piece.indent,
    hard_elements: piece.hard_elements,
    node: n,
  }
  // a blank line may stay before a node when the mark that set the gap
  // before it says so
  if(m.before != null){
    out.before = m.before
    out.blank = m.blank
  }
  if(m.after != null){
    out.after = m.after
  }
  if(m.indent){
    out.indent = true
  }
  // a block (a function's body) may hug the call it is the last argument of
  if(p.kind == "rule" and p.rule_name == "block" and out.doc.huggable == null){
    out.doc = {t: "group", doc: out.doc, huggable: "body"}
  }
  // what a rule produced is one part of the layout around it
  if(p.kind == "rule"){
    out.doc = {t: "box", doc: out.doc}
  }
  return out
}

// ------------------------------------------------------------ core layouts

// the operands and operators of a chain of one infix level, in order
local func infix_chain(n, out){
  local left = n.kids[0]
  if(n.p.form == "left" and left.p.form == "left" and left.p.level == n.p.level){
    infix_chain(left, out)
  } else {
    list_push(out, left)
  }
  list_push(out, n.kids[1])
  list_push(out, n.kids[2])
  return out
}

// the receiver and the postfix operators of a chain, in order
local func postfix_chain(n, out){
  local left = n.kids[0]
  if(left.p.form == "postfix"){
    postfix_chain(left, out)
  } else {
    list_push(out, left)
  }
  list_push(out, n.kids[1])
  return out
}

// expressions of the walker: operators break after themselves, a chain of
// three method calls or more breaks before each `:`
func formatter_methods.build_operator(self, n){
  local form = n.p.form
  local kids = n.kids
  if(form == "left" or form == "right"){
    // operands packed as many to a line as fit, a break after an operator
    // only where the next operand no longer fits
    // The operator's marks choose: break_before puts a break before the
    // operator (|>), after it otherwise; style "lines" lays the chain out
    // on one line or one operand per line. Without a style the operands
    // are packed, unless the source has every one on a line of its own.
    local nodes = infix_chain(n, {})
    local m = self:marks(nodes[1])
    local first = self:build(nodes[0], "formatted")
    local operands = {first}
    local head = {first.doc}
    local parts = {""}
    local content = head
    local prev = first
    for(local i = 1; i < len(nodes); i = i + 2){
      local op = self:build(nodes[i], "formatted")
      local operand = self:build(nodes[i + 1], "formatted")
      list_push(operands, operand)
      local next = {}
      if(m.break_before){
        list_push(parts, self:gap(prev, op, "line"))
        list_push(next, op.doc)
        list_push(next, self:gap(op, operand, "space"))
      } else {
        list_push(content, self:gap(prev, op, "space"))
        list_push(content, op.doc)
        list_push(parts, self:gap(op, operand, "line"))
      }
      list_push(next, operand.doc)
      content = next
      // (len counts a list's named fields: the flag goes on a box)
      list_push(parts, {t: "box", doc: content, hug: self:may_hug(operand)})
      prev = operand
    }
    local rest = {t: "fill", parts: parts}
    if(m.style == "lines" or self:one_per_line(operands, 1)){
      rest = parts
    }
    local doc = {head, indent(rest)}
    if(rest == parts){
      doc = group(doc)
    }
    return {doc: doc, first: first.first, last: prev.last}
  }
  if(form == "postfix"){
    local nodes = postfix_chain(n, {})
    local receiver = self:build(nodes[0], "formatted")
    local ops = {}
    local calls = 0
    local lead_call = false
    for(local i = 1; i < len(nodes); i = i + 1){
      local op = self:build(nodes[i], "formatted")
      list_push(ops, op)
      // a method call: :name(...); one that takes a function counts twice
      // after a call, so that a.b(x):map(func(){ ... }) may break before
      // :map (w:map(func(){ ... }) does not)
      local b = str.byte_at(self.source, op.first.start)
      if(b == 58){
        calls = calls + 1
        local h = last_huggable(op.doc)
        if(h != null and h.huggable == "body" and lead_call){
          calls = calls + 1
        }
      } else if(calls == 0 and b == 40){
        lead_call = true
      }
    }
    // a chain of two method calls or more may break before each `:`; one that
    // holds a function body (a break it must make) stays on its line when
    // its first line fits
    // (what comes before the first place it can break, a.b(x) in
    // a.b(x):c(), is not indented)
    local lead = {receiver.doc}
    local rest = {}
    local prev = receiver
    for(let local op in values(ops)){
      if(calls >= 2 and str.byte_at(self.source, op.first.start) == 58){
        list_push(rest, self:gap(prev, op, "softline"))
      } else if(len(rest) == 0){
        list_push(lead, self:gap(prev, op, "none"))
        list_push(lead, op.doc)
        prev = op
        continue
      } else {
        list_push(rest, self:gap(prev, op, "none"))
      }
      list_push(rest, op.doc)
      prev = op
    }
    local doc = {lead, rest}
    if(calls >= 2){
      // on one line; or on one line but for the last call's arguments; or
      // a line per call
      local content = {lead, indent(rest)}
      doc = group(content)
      if(propagate(content)){
        doc = {t: "choice", options: {flat_shallow(content, null), doc}}
      } else if(last_huggable(content) != null){
        local hugged = flat_shallow(content, last_huggable(content))
        doc = {t: "choice", options: {{t: "flat", doc: content}, hugged, doc}}
      }
    }
    return {doc: doc, first: receiver.first, last: prev.last}
  }
  if(form == "prefix"){
    local op = self:build(kids[0], "formatted")
    local operand = self:build(kids[1], "formatted")
    // (a method call can't start an element of a table literal: {self:gap()}
    // is the field self)
    local gap = self:gap(op, operand, "none")
    return {
      doc: {op.doc, gap, operand.doc},
      first: op.first,
      last: operand.last,
    }
  }
  if(form == "wrapper"){
    local l = self:build(kids[0], "formatted")
    local inner = self:build(kids[1], "formatted")
    local r = self:build(kids[2], "formatted")
    // the expression inside breaks for itself
    local open = self:gap(l, inner, "none")
    local close = self:gap(inner, r, "none")
    return {
      doc: {l.doc, open, inner.doc, close, r.doc},
      first: l.first,
      last: r.last,
    }
  }
  return null
}

// whether a part of a packed list may hug (break inside when it doesn't fit
// on a line of its own): a table, a function or a call, not an expression
// made of several
func formatter_methods.may_hug(self, piece){
  local n = piece.node
  for(n != null and n.p.kind == "rule" and n.kids != null and
    len(n.kids) == 1 and n.p.rule_name == "expr"){
    n = n.kids[0]
  }
  if(n == null){
    return false
  }
  if(n.p.form == "postfix"){
    return true
  }
  local name = n.p.rule_name
  return name == "table_literal" or name == "function_expression"
}

// the width of a list's typical (median) element up to which the list is
// packed as many to a line as fit; a list of wider elements gets a line per
// element. One long element (a message string) doesn't decide it: it gets
// a line of its own among the packed ones.
local FILL_WIDTH = 20

// the median of a list of numbers
local func median(numbers){
  local sorted = {}
  for(let local x in values(numbers)){
    local i = len(sorted)
    list_push(sorted, x)
    for(i > 0 and sorted[i - 1] > x){
      sorted[i] = sorted[i - 1]
      i = i - 1
    }
    sorted[i] = x
  }
  return sorted[to_int(len(sorted) / 2)]
}

// whether the source has a line break between every two of the elements,
// which are every step-th of pieces
func formatter_methods.one_per_line(self, pieces, step){
  local n = len(pieces)
  if(n <= step){
    return false
  }
  for(local i = 0; i + step < n; i = i + step){
    local a = pieces[i]
    local b = pieces[i + step]
    if(a.virtual or b.virtual){
      return false
    }
    local between = str.substring(self.source, a.last.stop, b.first.start)
    if(str.index_of(between, "\n") < 0){
      return false
    }
  }
  return true
}

// the elements and separators of a list (a separated node: element,
// separator, element, ...) packed as many to a line as fit, when all the
// elements are short and no comment is between them; null otherwise
func formatter_methods.fill(self, pieces, kind){
  local n = len(pieces)
  if(n < 3){
    return null
  }
  // written one per line: kept that way (unless it all fits on one line)
  if(self:one_per_line(pieces, 2)){
    return null
  }
  // (the last element may be one that must break: a function)
  local widths = {}
  for(local j = 0; j < n; j = j + 2){
    local w = flat_width(pieces[j].doc)
    if(pieces[j].virtual or (w < 0 and j + 1 < n)){
      return null
    }
    if(w >= 0){
      list_push(widths, w)
    }
  }
  if(median(widths) > FILL_WIDTH){
    return null
  }
  local parts = {}
  local i = 0
  for(i < n){
    local e = pieces[i]
    local content = {e.doc}
    if(i + 1 < n){
      local separator = pieces[i + 1]
      local before = self:gap(e, separator)
      if(type(before) != "string"){
        return null
      }
      list_push(content, before)
      list_push(content, separator.doc)
      list_push(parts, {t: "box", doc: content, hug: self:may_hug(e)})
      if(i + 2 < n){
        if(self:gap(separator, pieces[i + 2]) != LINE){
          return null
        }
        list_push(parts, LINE)
      }
    } else {
      list_push(parts, {t: "box", doc: content, hug: self:may_hug(e)})
    }
    i = i + 2
  }
  return {t: "fill", parts: parts}
}

// the number of statements of a chunk: the nodes marked as statements (a
// hardline before them that may keep a blank line) outside of other rules
func formatter_methods.count_statements(self, n, top){
  if(n.kids == null){
    return 0
  }
  if(not top and n.p.kind == "rule"){
    return 0
  }
  local m = self:marks(n)
  if(m.blank and m.before == "hardline"){
    return 1
  }
  local count = 0
  for(let local k in values(n.kids)){
    count = count + self:count_statements(k, false)
  }
  return count
}

// the word before pos in the source (skipping whitespace), or ""
func formatter_methods.word_before(self, pos){
  local source = self.source
  local i = pos
  for(i > 0 and is_space(str.byte_at(source, i - 1))){
    i = i - 1
  }
  local j = i
  for(j > 0 and is_word_byte(str.byte_at(source, j - 1))){
    j = j - 1
  }
  return str.substring(source, j, i)
}

// the word after pos in the source (skipping whitespace), or ""
func formatter_methods.word_after(self, pos){
  local source = self.source
  local i = pos
  for(i < len(source) and is_space(str.byte_at(source, i))){
    i = i + 1
  }
  local j = i
  for(j < len(source) and is_word_byte(str.byte_at(source, j))){
    j = j + 1
  }
  return str.substring(source, i, j)
}

// a block of one statement written on one line stays on one line when it
// fits (the source decides: a block written over several lines keeps its
// lines); next to an else or a catch a block always breaks
func formatter_methods.build_soft_block(self, n){
  local seq = n
  for(seq != null and seq.p.kind != "seq"){
    if(seq.kids == null or len(seq.kids) != 1){
      return null
    }
    seq = seq.kids[0]
  }
  if(seq == null or len(seq.kids) != 3){
    return null
  }
  local chunk = seq.kids[1]
  local rule = chunk
  for(rule != null and rule.p.kind != "rule"){
    rule = rule.kids and rule.kids[0]
  }
  if(rule == null or self:count_statements(rule, true) != 1){
    return null
  }
  local l = self:build(seq.kids[0], "formatted")
  local body = self:build(chunk, "formatted")
  local r = self:build(seq.kids[2], "formatted")
  if(body == null){
    return null
  }
  if(str.index_of(
    str.substring(self.source, l.first.start, r.last.stop),
    "\n"
  ) >= 0){
    return null
  }
  if(self:word_before(l.first.start) == "else"){
    return null
  }
  local next = self:word_after(r.last.stop)
  if(next == "else" or next == "catch"){
    return null
  }
  local open = self:gap(l, body, "line")
  local close = self:gap(body, r, "line")
  local doc = group({l.doc, indent({open, body.doc}), close, r.doc})
  // the last argument of a call that doesn't fit breaks its body, not the call
  doc.huggable = "body"
  return {doc: doc, first: l.first, last: r.last}
}

// a whole file: top-level statements on lines of their own, comments before
// the first and after the last kept
func formatter_methods.build_unit(self, n){
  local pieces = {}
  for(let local k in values(n.kids)){
    local piece = self:build(k, "formatted")
    if(piece != null){
      list_push(pieces, piece)
    }
  }
  local source = self.source
  local parts = {}
  if(len(pieces) == 0){
    return null
  }
  // comments before the first statement
  local head = str.substring(source, 0, pieces[0].first.start)
  local head_comments = gap_comments(head)
  for(local i = 0; i < len(head_comments); i = i + 1){
    local c = head_comments[i]
    local from = 0
    if(i > 0){
      from = head_comments[i - 1].stop
      list_push(parts, HARDLINE)
      if(count_newlines(str.substring(head, from, c.start)) >= 2){
        list_push(parts, HARDLINE)
      }
    }
    list_push(parts, rstrip(str.substring(head, c.start, c.stop)))
  }
  if(len(head_comments) > 0){
    list_push(parts, HARDLINE)
    if(count_newlines(str.substring(
      head,
      head_comments[len(head_comments) - 1].stop
    )) >= 2){
      list_push(parts, HARDLINE)
    }
  }
  local prev = null
  for(let local p in values(pieces)){
    if(prev != null){
      list_push(parts, self:gap(prev, p, "hardline", true))
    }
    list_push(parts, p.doc)
    prev = p
  }
  // comments after the last statement
  local tail = str.substring(source, prev.last.stop)
  local tail_comments = gap_comments(tail)
  for(local i = 0; i < len(tail_comments); i = i + 1){
    local c = tail_comments[i]
    local from = 0
    if(i > 0){
      from = tail_comments[i - 1].stop
    }
    local before = str.substring(tail, from, c.start)
    local nl = count_newlines(before)
    if(nl == 0 and i == 0){
      list_push(parts, " ")
    } else {
      list_push(parts, HARDLINE)
      if(nl >= 2){
        list_push(parts, HARDLINE)
      }
    }
    list_push(parts, rstrip(str.substring(tail, c.start, c.stop)))
  }
  return {doc: parts, first: pieces[0].first, last: prev.last}
}

// ------------------------------------------------------------ checks

// the token leaves of a tree, without dropped tokens and trailing commas
local func tokens(f, n, out){
  if(n.kids == null){
    if(n.start != n.stop and not n.p.trivia and n.p.kind != "whitespace"){
      list_push(out, f:text(n))
    }
    return out
  }
  local m = f:marks(n)
  if(m.drop or m.trailing_comma){
    return out
  }
  if(n.p.kind == "token" and n.p.category != null){
    list_push(out, f:text(n))
    return out
  }
  if(n.p.kind == "trim"){
    return tokens(f, n.kids[n.at], out)
  }
  for(let local k in values(n.kids)){
    tokens(f, k, out)
  }
  return out
}

// the comments of a source, in order (between the tokens of its tree)
local func comments_of(f, toks_tree){
  local leaves = {}
  local func collect(n){
    if(n.kids == null){
      if(n.start != n.stop and not n.p.trivia and n.p.kind != "whitespace"){
        list_push(leaves, n)
      }
      return null
    }
    if(n.p.kind == "token" and n.p.category != null){
      list_push(leaves, n)
      return null
    }
    if(n.p.kind == "trim"){
      collect(n.kids[n.at])
      return null
    }
    for(let local k in values(n.kids)){
      collect(k)
    }
  }
  collect(toks_tree)
  local out = {}
  local at = 0
  for(let local l in values(leaves)){
    for(let local c in values(
      gap_comments(str.substring(f.source, at, l.start))
    )){
      list_push(out, rstrip(str.substring(f.source, at + c.start, at + c.stop)))
    }
    at = l.stop
  }
  for(let local c in values(gap_comments(str.substring(f.source, at)))){
    list_push(out, rstrip(str.substring(f.source, at + c.start, at + c.stop)))
  }
  return out
}

// uuid-N names depend on how many were made before: numbered by first use
local func canonical(s){
  local parts = str.split(s, "uuid-")
  local out = {parts[0]}
  local seen = {}
  local count = 0
  for(local i = 1; i < len(parts); i = i + 1){
    local p = parts[i]
    local j = 0
    for(j < len(p) and is_digit_byte(str.byte_at(p, j))){
      j = j + 1
    }
    local id = str.substring(p, 0, j)
    if(seen[id] == null){
      seen[id] = string(count)
      count = count + 1
    }
    append(out, concat("uuid-", seen[id], str.substring(p, j)))
  }
  return str.join(out, "")
}

// source locations an extension put into its code ("path:12", "path:12:5")
// change with the layout: they are left out of the comparison
local func without_locations(s, path){
  local marker = concat(path, ":")
  local parts = str.split(s, marker)
  local out = {parts[0]}
  for(local i = 1; i < len(parts); i = i + 1){
    local p = parts[i]
    local j = 0
    for(j < len(p) and
      (is_digit_byte(str.byte_at(p, j)) or
        (str.byte_at(p, j) == 58 and is_digit_byte(str.byte_at(p, j + 1))))){
      j = j + 1
    }
    append(out, concat(marker, "L", str.substring(p, j)))
  }
  return str.join(out, "")
}

local func same_list(a, b){
  if(len(a) != len(b)){
    return false
  }
  for(local i = 0; i < len(a); i = i + 1){
    if(a[i] != b[i]){
      return false
    }
  }
  return true
}

// the first position where two lists differ, for messages
local func first_difference(a, b){
  local i = 0
  for(i < len(a) and i < len(b) and a[i] == b[i]){
    i = i + 1
  }
  return i
}

// ------------------------------------------------------------ formatting

// the text of a tree laid out
local func layout(f, tree, width){
  local piece = f:build(tree, "formatted")
  if(piece == null){
    return ""
  }
  return concat(format.print(piece.doc, width or WIDTH), "\n")
}

// source(text, path, {find_project, width, check}) -> the formatted text, or
// null for a file of a compile dialect. Raises when the file does not parse,
// or when the result fails its checks (check: false skips them).
func format.source(text, path, options){
  options = options or {}
  local compiler = require("slang/compiler")
  local ast = require("slang/ast")
  local tree = compiler.tree(text, path, {find_project: options.find_project})
  if(tree == null){
    return null
  }
  local f = new_formatter(text)
  local out = layout(f, tree, options.width)
  // Some layouts depend on the source's: a block written on one line that
  // doesn't fit is broken, and is then a block written over several lines.
  // Formatting again until nothing changes makes the result stable.
  local out_tree = compiler.tree(out, path)
  local passes = 1
  for(true){
    local again = layout(new_formatter(out), out_tree, options.width)
    if(again == out){
      break
    }
    passes = passes + 1
    if(passes > 5){
      raise({
        message: concat(
          "formatting ", path, " does not settle; the file was left as it is"
        ),
      })
    }
    out = again
    out_tree = compiler.tree(out, path)
  }
  if(options.check == false){
    return out
  }
  local g = new_formatter(out)
  local before = tokens(f, tree, {})
  local after = tokens(g, out_tree, {})
  if(not same_list(before, after)){
    local i = first_difference(before, after)
    raise({
      message: concat(
        "formatting ", path, " changed its tokens (", string(before[i]),
        " became ", string(after[i]), " at token ", i,
        "); the file was left as it is"
      ),
    })
  }
  local meaning = without_locations(canonical(ast.to_source(tree.ast)), path)
  if(meaning != without_locations(canonical(ast.to_source(out_tree.ast)), path)){
    raise({
      message: concat(
        "formatting ", path,
        " changed what the code means; the file was left as it is"
      ),
    })
  }
  local c1 = comments_of(f, tree)
  local c2 = comments_of(g, out_tree)
  if(not same_list(c1, c2)){
    raise({
      message: concat(
        "formatting ", path,
        " lost or reordered comments; the file was left as it is"
      ),
    })
  }
  return out
}

// ------------------------------------------------------------ slang fmt

local func slang_files(os, path, out){
  if(os.is_dir(path)){
    local names = os.list_dir(path)
    for(let local name in values(names)){
      if(not str.starts_with(name, ".")){
        slang_files(os, concat(path, "/", name), out)
      }
    }
  } else if(str.ends_with(path, ".slang")){
    list_push(out, path)
  }
  return out
}

// main(args) -> exit code: `slang fmt [--check] [--stdout] paths...`
func format.main(arguments){
  local os = require("slang/os")
  local check = false
  local stdout = false
  local paths = {}
  for(let local a in values(arguments)){
    if(a == "--check"){
      check = true
    } else if(a == "--stdout"){
      stdout = true
    } else {
      list_push(paths, a)
    }
  }
  if(len(paths) == 0){
    os.write_stderr(
      "usage: slang fmt [--check] [--stdout] <file.slang|dir>...\n"
    )
    return 2
  }
  local files = {}
  for(let local p in values(paths)){
    slang_files(os, p, files)
  }
  local compiler = require("slang/compiler")
  local status = 0
  for(let local path in values(files)){
    // every file starts from slang's own grammar and finds its own project:
    // what one file's extensions and project changed must not reach the next
    compiler.reset()
    local text = os.read_file(path)
    local r = pcall(format.source, text, path, {find_project: true})
    if(r[0] == "err"){
      local e = r[1]
      local message = e
      if(type(e) == "table"){
        message = e.message
      }
      os.write_stderr(concat(path, ": ", message, "\n"))
      status = 1
    } else if(r[1] != null){
      local out = r[1]
      if(stdout){
        print(out)
      } else if(out != text){
        if(check){
          print(path, "\n")
          status = 1
        } else {
          os.write_file(path, out)
        }
      }
    }
  }
  return status
}

return format
