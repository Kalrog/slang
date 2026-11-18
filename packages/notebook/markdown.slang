// notebook/markdown: Markdown to HTML, for a notebook's text cells.
//
//   local markdown = require("notebook/markdown")
//   markdown.render("# Hello\n\nSome *text* with `code`.")
//
// It knows what notes are written in: headings, paragraphs, emphasis,
// code, links and images, lists (nested, numbered, with [ ] boxes), quotes,
// rules, tables, and blocks of code in fences. HTML in the text is kept as
// it is, so a notebook is as trusted as the code in it.
local str = require("slang/string")
local regex = require("slang/regex")

local markdown = {}

local func escape(s){
  if(str.index_of(s, "&") < 0 and str.index_of(s, "<") < 0 and
    str.index_of(s, ">") < 0 and str.index_of(s, "\"") < 0){
    return s
  }
  s = str.replace(s, "&", "&amp;")
  s = str.replace(s, "<", "&lt;")
  s = str.replace(s, ">", "&gt;")
  return str.replace(s, "\"", "&quot;")
}

// s from a up to b, cut to where s ends
local func sub(s, a, b){
  if(b > len(s)){
    b = len(s)
  }
  if(a >= b){
    return ""
  }
  return str.substring(s, a, b)
}

// ------------------------------------------------------------ inline

local tag_re = regex.compile("^</?[A-Za-z][A-Za-z0-9-]*(\\s[^<>]*)?/?>")
local comment_re = regex.compile("^<!--[\\s\\S]*?-->")
local autolink_re = regex.compile("^<([A-Za-z][A-Za-z0-9+.-]*:[^ <>]*)>")
local url_re = regex.compile("^https?://[^\\s<>]*[^\\s<>.,;:!?)\\]'\"]")
local entity_re = regex.compile("^&(#[0-9]+|#[xX][0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);")
local punctuation = "\\`*_{}[]()#+-.!|<>~\"'&=:;,/?^$%@"

local func is_word(b){
  return b != null and ((b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
    (b >= '0' and b <= '9') or b >= 128)
}

local func is_space(b){
  return b == null or b == ' ' or b == '\n' or b == '\t'
}

// where the bracket opened at s[i] closes, counting nested ones; -1: never
local func closing(s, i, open, close){
  local depth = 0
  local n = len(s)
  for(i < n){
    local b = str.byte_at(s, i)
    if(b == '\\'){
      i = i + 1
    } else if(b == '`'){
      // a code span hides brackets
      local j = str.index_of(s, "`", i + 1)
      if(j > 0){
        i = j
      }
    } else if(b == open){
      depth = depth + 1
    } else if(b == close){
      depth = depth - 1
      if(depth == 0){
        return i
      }
    }
    i = i + 1
  }
  return -1
}

local inline = null

// the (url "title") after a link's text at s[i]: {url, title, stop}
local func destination(s, i){
  if(str.byte_at(s, i) != '('){
    return null
  }
  local stop = closing(s, i, '(', ')')
  if(stop < 0){
    return null
  }
  local inner = str.trim(str.substring(s, i + 1, stop))
  local title = null
  local q = str.index_of(inner, " \"")
  if(q >= 0 and str.ends_with(inner, "\"")){
    title = str.substring(inner, q + 2, len(inner) - 1)
    inner = str.trim(str.substring(inner, 0, q))
  }
  if(str.starts_with(inner, "<") and str.ends_with(inner, ">")){
    inner = str.substring(inner, 1, len(inner) - 1)
  }
  return {url: inner, title: title, stop: stop + 1}
}

// the end of the emphasis that mark opens at s[i], or -1
local func emphasis_end(s, i, mark){
  local n = len(s)
  local m = len(mark)
  local j = i + m
  for(j < n){
    local b = str.byte_at(s, j)
    if(b == '\\'){
      j = j + 2
    } else if(b == '`'){
      local k = str.index_of(s, "`", j + 1)
      if(k < 0){
        j = j + 1
      } else {
        j = k + 1
      }
    } else if(sub(s, j, j + m) == mark and
      not is_space(str.byte_at(s, j - 1)) and
      (m > 1 or str.byte_at(s, j + 1) != str.byte_at(mark, 0)) and
      (str.byte_at(mark, 0) != '_' or not is_word(str.byte_at(s, j + m)))){
      return j
    } else {
      j = j + 1
    }
  }
  return -1
}

inline = func(s){
  local out = {}
  local n = len(s)
  local from = 0
  local i = 0
  local func text_to(stop){
    if(stop > from){
      append(out, escape(str.substring(s, from, stop)))
    }
  }
  for(i < n){
    local b = str.byte_at(s, i)
    local next = null
    if(b == '\\'){
      local c = str.char_at(s, i + 1)
      if(i + 1 < n and c == "\n"){
        text_to(i)
        append(out, "<br>\n")
        next = i + 2
      } else if(i + 1 < n and str.index_of(punctuation, c) >= 0){
        text_to(i)
        append(out, escape(c))
        next = i + 2
      }
    } else if(b == '`'){
      local k = i
      for(k < n and str.byte_at(s, k) == '`'){
        k = k + 1
      }
      local mark = str.substring(s, i, k)
      local stop = str.index_of(s, mark, k)
      // the closing run must be as long, not longer
      for(stop >= 0 and str.byte_at(s, stop + len(mark)) == '`'){
        local after = stop
        for(after < n and str.byte_at(s, after) == '`'){
          after = after + 1
        }
        stop = str.index_of(s, mark, after)
      }
      if(stop >= 0){
        text_to(i)
        local code = str.replace(str.substring(s, k, stop), "\n", " ")
        if(len(code) > 2 and str.starts_with(code, " ") and
          str.ends_with(code, " ")){
          code = str.substring(code, 1, len(code) - 1)
        }
        append(out, concat("<code>", escape(code), "</code>"))
        next = stop + len(mark)
      } else {
        // no closing run: the backticks are text
        text_to(i)
        append(out, mark)
        next = k
      }
    } else if(b == '!' and str.byte_at(s, i + 1) == '['){
      local stop = closing(s, i + 1, '[', ']')
      local d = null
      if(stop > 0){
        d = destination(s, stop + 1)
      }
      if(d != null){
        text_to(i)
        local title = ""
        if(d.title != null){
          title = concat(" title=\"", escape(d.title), "\"")
        }
        append(out, concat(
          "<img src=\"", escape(d.url), "\" alt=\"",
          escape(str.substring(s, i + 2, stop)), "\"", title, ">"
        ))
        next = d.stop
      }
    } else if(b == '['){
      local stop = closing(s, i, '[', ']')
      local d = null
      if(stop > 0){
        d = destination(s, stop + 1)
      }
      if(d != null){
        text_to(i)
        local title = ""
        if(d.title != null){
          title = concat(" title=\"", escape(d.title), "\"")
        }
        append(out, concat(
          "<a href=\"", escape(d.url), "\"", title, ">",
          inline(str.substring(s, i + 1, stop)), "</a>"
        ))
        next = d.stop
      }
    } else if(b == '<'){
      local rest = sub(s, i, i + 2000)
      local m = autolink_re:find(rest)
      if(m != null){
        text_to(i)
        append(out, concat(
          "<a href=\"", escape(m.groups[1]), "\">", escape(m.groups[1]), "</a>"
        ))
        next = i + len(m.text)
      } else {
        m = comment_re:find(str.substring(s, i)) or tag_re:find(rest)
        if(m != null){
          text_to(i)
          append(out, m.text)
          next = i + len(m.text)
        }
      }
    } else if(b == '&'){
      local m = entity_re:find(sub(s, i, i + 40))
      if(m != null){
        text_to(i)
        append(out, m.text)
        next = i + len(m.text)
      }
    } else if(b == '*' or b == '_' or b == '~'){
      local c = str.char_at(s, i)
      local mark = c
      if(str.byte_at(s, i + 1) == b){
        mark = concat(c, c)
      }
      local opens = not is_space(str.byte_at(s, i + len(mark))) and
        (b != '_' or i == 0 or not is_word(str.byte_at(s, i - 1))) and
        (b != '~' or len(mark) == 2)
      local stop = -1
      if(opens){
        stop = emphasis_end(s, i, mark)
      }
      if(stop > i + len(mark) - 1 and stop > i){
        text_to(i)
        local tag = "em"
        if(b == '~'){
          tag = "del"
        } else if(len(mark) == 2){
          tag = "strong"
        }
        append(out, concat(
          "<", tag, ">", inline(str.substring(s, i + len(mark), stop)), "</",
          tag, ">"
        ))
        next = stop + len(mark)
      } else {
        text_to(i)
        append(out, mark)
        next = i + len(mark)
      }
    } else if(b == 'h' and (i == 0 or not is_word(str.byte_at(s, i - 1))) and
      sub(s, i, i + 4) == "http"){
      local m = url_re:find(sub(s, i, i + 2000))
      if(m != null){
        text_to(i)
        append(out, concat(
          "<a href=\"", escape(m.text), "\">", escape(m.text), "</a>"
        ))
        next = i + len(m.text)
      }
    } else if(b == ' ' and sub(s, i, i + 3) == "  \n"){
      text_to(i)
      append(out, "<br>\n")
      next = i + 3
    }
    if(next != null){
      i = next
      from = next
    } else {
      i = i + 1
    }
  }
  text_to(n)
  return str.join(out, "")
}

// inline(text: string) -> string
// The HTML of a line of Markdown: emphasis, code, links, images.
markdown.inline = inline

// ------------------------------------------------------------ blocks

local heading_re = regex.compile("^ {0,3}(#{1,6})(?:[ \\t]+(.*?))?(?:[ \\t]+#+)?[ \\t]*$")
local rule_re = regex.compile("^ {0,3}(?:(?:\\*[ \\t]*){3,}|(?:-[ \\t]*){3,}|(?:_[ \\t]*){3,})$")
local fence_re = regex.compile("^( {0,3})(`{3,}|~{3,})[ \\t]*([^`]*)$")
local item_re = regex.compile("^( *)([-*+]|[0-9]{1,9}[.)])( +|$)")
local quote_re = regex.compile("^ {0,3}> ?")
local table_rule_re = regex.compile("^ {0,3}\\|?[ \\t]*:?-+:?[ \\t]*(\\|[ \\t]*:?-+:?[ \\t]*)*\\|?[ \\t]*$")
local setext_re = regex.compile("^ {0,3}(=+|-+)[ \\t]*$")
local html_re = regex.compile("^ {0,3}<(/?[A-Za-z][A-Za-z0-9-]*[\\s/>]|!--)")
local box_re = regex.compile("^\\[([ xX])\\][ \\t]+")
local slug_drop = regex.compile("[^a-z0-9\\x80-\\xff]+")

// slug(title: string) -> string
// The id a heading gets: its words in lowercase with dashes.
func markdown.slug(title){
  return str.trim(slug_drop:replace(str.lower(title), "-"), "-")
}

// the cells of a table row
local func row_cells(line){
  local t = str.trim(line)
  if(str.starts_with(t, "|")){
    t = str.substring(t, 1)
  }
  if(str.ends_with(t, "|") and not str.ends_with(t, "\\|")){
    t = str.substring(t, 0, len(t) - 1)
  }
  local out = {}
  local from = 0
  local i = 0
  for(i < len(t)){
    local b = str.byte_at(t, i)
    if(b == '\\'){
      i = i + 1
    } else if(b == '`'){
      local j = str.index_of(t, "`", i + 1)
      if(j > 0){
        i = j
      }
    } else if(b == '|'){
      append(out, str.trim(str.substring(t, from, i)))
      from = i + 1
    }
    i = i + 1
  }
  append(out, str.trim(str.substring(t, from)))
  for(local k = 0; k < len(out); k = k + 1){
    out[k] = str.replace(out[k], "\\|", "|")
  }
  return out
}

local func indent_of(line){
  local i = 0
  for(i < len(line) and str.byte_at(line, i) == ' '){
    i = i + 1
  }
  return i
}

local blocks = null

// whether a line starts a block that ends a paragraph
local func interrupts(line){
  return heading_re:matches(line) or rule_re:matches(line) or
    fence_re:matches(line) or quote_re:match_at(line, 0) > 0 or
    (item_re:match_at(line, 0) > 0 and indent_of(line) < 4) or
    html_re:match_at(line, 0) > 0
}

// a list starting at lines[i]: its HTML and the line after it
local func list_block(lines, i, o){
  local n = len(lines)
  local first = item_re:find(lines[i])
  local base = len(first.groups[1])
  local ordered = len(first.groups[2]) > 1
  local bullet = str.char_at(first.groups[2], len(first.groups[2]) - 1)
  local items = {}
  local loose = false
  // whether a line is an item of this list
  local func item_of(line){
    local m = item_re:find(line)
    if(m == null or len(m.groups[1]) != base or
      (len(m.groups[2]) > 1) != ordered or
      str.char_at(m.groups[2], len(m.groups[2]) - 1) != bullet or
      rule_re:matches(line)){
      return null
    }
    return m
  }
  for(i < n){
    local m = item_of(lines[i])
    if(m == null){
      break
    }
    // the item's lines: what is indented to its content, lazy paragraph
    // lines, and blank lines followed by more of it
    local content = len(m.text)
    if(content - base - len(m.groups[2]) > 4){
      content = base + len(m.groups[2]) + 1
    }
    local body = {str.substring(lines[i], len(m.text))}
    local j = i + 1
    local blank = false
    for(j < n){
      local line = lines[j]
      if(str.trim(line) == ""){
        // blank lines belong to the item when more of it follows
        local k = j
        for(k < n and str.trim(lines[k]) == ""){
          k = k + 1
        }
        if(k < n and indent_of(lines[k]) >= content){
          for(j < k){
            append(body, "")
            j = j + 1
          }
          blank = true
        } else {
          break
        }
      } else if(indent_of(line) >= content){
        append(body, str.substring(line, content))
        j = j + 1
      } else if(not blank and not interrupts(line) and
        item_re:match_at(line, 0) <= 0){
        append(body, str.trim_start(line))
        j = j + 1
      } else {
        break
      }
    }
    if(blank){
      loose = true
    }
    append(items, body)
    i = j
    // a blank line between two items makes the list loose
    local k = i
    for(k < n and str.trim(lines[k]) == ""){
      k = k + 1
    }
    if(k > i and k < n and item_of(lines[k]) != null){
      loose = true
      i = k
    }
  }
  local tag = "ul"
  local start = ""
  if(ordered){
    tag = "ol"
    local number = to_int(str.substring(first.groups[2], 0, len(first.groups[2]) - 1))
    if(number != 1){
      start = concat(" start=\"", string(number), "\"")
    }
  }
  local out = {concat("<", tag, start, ">\n")}
  for(let local body in values(items)){
    local box = box_re:find(body[0])
    local open = "<li>"
    if(box != null){
      body[0] = str.substring(body[0], len(box.text))
      local checked = ""
      if(box.groups[1] != " "){
        checked = " checked"
      }
      open = concat(
        "<li class=\"task\"><input type=\"checkbox\" disabled", checked, "> "
      )
    }
    local inner = blocks(body, o, not loose)
    append(out, concat(open, str.trim_end(inner, "\n"), "</li>\n"))
  }
  append(out, concat("</", tag, ">\n"))
  return {html: str.join(out, ""), next: i}
}

// blocks(lines, o, tight) -> the HTML of lines; tight: paragraphs without <p>
blocks = func(lines, o, tight){
  local out = {}
  local n = len(lines)
  local i = 0
  for(i < n){
    local line = lines[i]
    local fence = null
    if(str.trim(line) == ""){
      i = i + 1
    } else if(heading_re:matches(line)){
      local m = heading_re:find(line)
      local level = string(len(m.groups[1]))
      local title = str.trim(m.groups[2] or "")
      append(out, concat(
        "<h", level, " id=\"", escape(markdown.slug(title)), "\">",
        inline(title), "</h", level, ">\n"
      ))
      i = i + 1
    } else if(fence_re:matches(line)){
      fence = fence_re:find(line)
      local mark = fence.groups[2]
      local info = str.trim(fence.groups[3])
      local indent = len(fence.groups[1])
      local code = {}
      i = i + 1
      for(i < n){
        local t = str.trim(lines[i])
        if(str.starts_with(t, mark) and str.trim(t, str.char_at(mark, 0)) == ""){
          break
        }
        local l = lines[i]
        local k = 0
        for(k < indent and str.byte_at(l, k) == ' '){
          k = k + 1
        }
        append(code, str.substring(l, k))
        i = i + 1
      }
      i = i + 1
      local source = str.join(code, "\n")
      local lang = str.fields(info)[0] or ""
      local inner = null
      if(o.highlight != null and lang != ""){
        inner = o.highlight(source, lang)
      }
      local attr = ""
      if(lang != ""){
        attr = concat(" class=\"language-", escape(lang), "\"")
      }
      append(out, concat(
        "<pre><code", attr, ">", inner or escape(source), "\n</code></pre>\n"
      ))
    } else if(rule_re:matches(line)){
      append(out, "<hr>\n")
      i = i + 1
    } else if(quote_re:match_at(line, 0) > 0){
      local inner = {}
      for(i < n and str.trim(lines[i]) != "" and
        (quote_re:match_at(lines[i], 0) > 0 or not interrupts(lines[i]))){
        local k = quote_re:match_at(lines[i], 0)
        if(k < 0){
          k = 0
        }
        append(inner, str.substring(lines[i], k))
        i = i + 1
      }
      append(out, concat(
        "<blockquote>\n", blocks(inner, o, false), "</blockquote>\n"
      ))
    } else if(item_re:match_at(line, 0) > 0 and indent_of(line) < 4){
      local r = list_block(lines, i, o)
      append(out, r.html)
      i = r.next
    } else if(html_re:match_at(line, 0) > 0){
      // raw HTML up to the next blank line
      local raw = {}
      for(i < n and str.trim(lines[i]) != ""){
        append(raw, lines[i])
        i = i + 1
      }
      append(out, concat(str.join(raw, "\n"), "\n"))
    } else if(i + 1 < n and str.index_of(line, "|") >= 0 and
      table_rule_re:matches(lines[i + 1]) and
      len(row_cells(lines[i + 1])) == len(row_cells(line))){
      local head = row_cells(line)
      local aligns = {}
      for(let local c in values(row_cells(lines[i + 1]))){
        local a = ""
        if(str.starts_with(c, ":") and str.ends_with(c, ":")){
          a = " style=\"text-align:center\""
        } else if(str.ends_with(c, ":")){
          a = " style=\"text-align:right\""
        }
        append(aligns, a)
      }
      append(out, "<table>\n<thead><tr>")
      for(local c = 0; c < len(head); c = c + 1){
        append(out, concat("<th", aligns[c], ">", inline(head[c]), "</th>"))
      }
      append(out, "</tr></thead>\n<tbody>\n")
      i = i + 2
      for(i < n and str.trim(lines[i]) != "" and
        str.index_of(lines[i], "|") >= 0){
        local cells = row_cells(lines[i])
        append(out, "<tr>")
        for(local c = 0; c < len(head); c = c + 1){
          append(out, concat(
            "<td", aligns[c], ">", inline(cells[c] or ""), "</td>"
          ))
        }
        append(out, "</tr>\n")
        i = i + 1
      }
      append(out, "</tbody>\n</table>\n")
    } else {
      // a paragraph, or a heading underlined with === or ---
      local para = {str.trim_start(line)}
      i = i + 1
      local level = null
      for(i < n and str.trim(lines[i]) != ""){
        local m = setext_re:find(lines[i])
        if(m != null){
          level = "2"
          if(str.starts_with(m.groups[1], "=")){
            level = "1"
          }
          i = i + 1
          break
        }
        if(interrupts(lines[i])){
          break
        }
        append(para, str.trim_start(lines[i]))
        i = i + 1
      }
      local text = str.trim_end(str.join(para, "\n"))
      if(level != null){
        append(out, concat(
          "<h", level, " id=\"", escape(markdown.slug(text)), "\">",
          inline(text), "</h", level, ">\n"
        ))
      } else if(tight){
        append(out, concat(inline(text), "\n"))
      } else {
        append(out, concat("<p>", inline(text), "</p>\n"))
      }
    }
  }
  return str.join(out, "")
}

// How [render] renders.
// type Options = {highlight?: func(code: string, language: string): string?}
// [highlight]: the HTML of a code block's text (escaped, with spans), or
//   null to show it plain

// render(text: string, options?: Options) -> string
// The HTML of a Markdown text.
func markdown.render(text, options){
  local lines = str.split(str.replace(text, "\r\n", "\n"), "\n")
  for(local i = 0; i < len(lines); i = i + 1){
    if(str.index_of(lines[i], "\t") >= 0){
      lines[i] = str.replace(lines[i], "\t", "    ")
    }
  }
  return blocks(lines, options or {}, false)
}

return markdown
