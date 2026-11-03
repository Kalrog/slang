// HTML templates that read like HTML, as JSX does: an expression that
// starts with `<` builds slang/html nodes, and components compose them.
//
// Syntax:
//   expr ::= element
//   element ::= "<>" child* "</>"
//             | "<" tag attribute* "/>"
//             | "<" tag attribute* ">" child* "</" tag ">"
//   attribute ::= name ("=" (string_literal | "{" expr "}"))?
//               | "{" "..." expr "}"
//   child ::= element | "{" expr "}" | ⟨text: anything but < and {⟩
//   tag ::= [a-zA-Z_] [a-zA-Z0-9_:-]* ("." [a-zA-Z_] [a-zA-Z0-9_:-]*)*
//   name ::= [a-zA-Z_:@] [a-zA-Z0-9_:.-]*
//
// `<tag attrs>children</tag>` is an element, `<tag attrs/>` one without
// children, `<>...</>` a fragment (children without a tag). The closing
// tag must name the opening one. A tag name that starts with a capital
// letter or contains a dot names a component: a function that is called
// with one table, the attributes plus the children under `children`;
// `<Nav links={x}>a</Nav>` is `Nav({links: x, children: {"a"}})`. A
// component is a local like any other, so define it before the templates
// that use it.
//
//   local tbl = require("slang/table")
//   local func Nav(props){
//     return <ul class="nav">
//       {tbl.map(props.links, func(l){
//         return <li><a href={l.href}>{l.text}</a></li>
//       })}
//     </ul>
//   }
//   local func Page(props){
//     return <html>
//       <head><title>{props.title}</title></head>
//       <body class="page" data-user={props.user}>
//         <Nav links={props.links}/>
//         {props.children}
//       </body>
//     </html>
//   }
//   local links = {{href: "/", text: "Home"}, {href: "/faq", text: "Q & A"}}
//   print(string(<Page title="Hi" user="ada" links={links}>
//     <p>welcome</p>
//   </Page>), "\n")
//
// Children are text, elements and `{expr}`: a string is escaped, a number
// printed, a node or a list inserted (lists element by element), null and
// booleans dropped, which makes `{cond and <b>x</b>}` a conditional;
// `html.raw(s)` inserts trusted markup. Literal text is escaped when it is
// compiled, except for entities (`&amp;`, `&#169;`), which are kept; its
// whitespace follows JSX, with a twist: lines are trimmed, blank lines
// dropped, a line break inside text becomes one space, and a space between
// text and a `{value}` is kept (`Hello {name}` stays two words).
//
// Attribute values are text or `{expr}`; null and false omit the
// attribute, true writes it bare, anything else is escaped. An attribute
// without a value is true; `{...table}` adds a table's entries as
// attributes.
//
//   local name = "<Ada>"
//   local ok = false
//   local extra = {id: "who", hidden: true}
//   print(string(<>
//     <input type="text" required disabled={not ok} {...extra}/>
//     <p>Hello {name}, &copy; 2026 {ok and <b>(ok)</b>}</p>
//   </>), "\n")
//
// Everything lowers to calls on slang/html (`html.element`, `html.value`),
// required once per unit; string() of a node renders it. The highlighter
// sees tags as keywords, components as functions, attributes as
// properties.
local peg = require("slang/peg")
local ast = require("slang/ast")
local str = require("slang/string")
local regex = require("slang/regex")
local fmt = require("slang/format")
local g = require("slang/compiler").grammar()

// ------------------------------------------------------------ lexical pieces
//
// Inside a template the slang trivia rules do not apply: whitespace is
// significant in text, so the pieces below are raw parsers; only the
// slang expressions inside `{...}` and the attribute strings use tokens.
// Whitespace is parsed as such (peg.whitespace), so that the formatter may
// change it: it is not a token of the code.

local ws = peg.whitespace():star()

local func punct(s){
  return peg.token(peg.string(s), "punctuation")
}

local name_chars = peg.seq(
  peg.pattern("a-zA-Z_"),
  peg.pattern("a-zA-Z0-9_:-"):star(),
)
local tag_name = peg.seq(
  name_chars,
  peg.seq(peg.char("."), name_chars):star(),
):flatten("tag name expected")
local attr_name = peg.seq(
  peg.pattern("a-zA-Z_:@"),
  peg.pattern("a-zA-Z0-9_:.-"):star(),
):flatten("attribute name expected")

local func is_component(name){
  local b = str.byte_at(name, 0)
  return (b >= 65 and b <= 90) or str.index_of(name, ".") >= 0
}

// the tag name as a token, highlighted by what it names
local tag_token = peg.token(tag_name, func(name){
  return is_component(name) and "function" or "keyword"
})

// text: everything up to the next tag or `{`. In a tree its words and the
// whitespace between them are leaves of their own: the words are the
// tokens, the whitespace is the formatter's to lay out (by the rules of
// clean_text below, see layout_element)
local text_run = regex.compile("[^<{]*")
local word_run = regex.compile("[^ \t\r\n<{]*")
local blank_run = regex.compile("[ \t\r\n]*")
local text_word = peg.custom(func(self, ctx, pos){ return -1 })
local text_space = peg.whitespace()
local text = peg.custom(
  func(self, ctx, pos){
    local q = text_run:match_at(ctx.buffer, pos)
    if(q == pos){
      return peg.fail(ctx, pos, "text expected")
    }
    ctx.value = str.substring(ctx.buffer, pos, q)
    return q
  },
  func(self, ctx, pos){
    local q = self:parse_on(ctx, pos)
    if(q < 0){
      return q
    }
    local kids = {}
    local i = pos
    for(i < q){
      local j = blank_run:match_at(ctx.buffer, i)
      if(j > i){
        append(kids, peg.leaf(text_space, i, j))
      } else {
        j = word_run:match_at(ctx.buffer, i)
        append(kids, peg.leaf(text_word, i, j))
      }
      i = j
    }
    ctx.tree = peg.node(self, pos, q, kids)
    return q
  },
)

// ------------------------------------------------------------ literal text

// & < > escaped, entities (&name; &#123;) left alone
local entity_run = regex.compile("[a-zA-Z0-9#]*")
local func escape_text(s){
  if(str.index_of(s, "&") < 0 and str.index_of(s, ">") < 0){
    return s
  }
  local parts = {}
  local n = len(s)
  local start = 0
  for(local i = 0; i < n; i = i + 1){
    local c = str.substring(s, i, i + 1)
    local repl = null
    if(c == ">"){
      repl = "&gt;"
    } else if(c == "<"){
      repl = "&lt;"
    } else if(c == "&"){
      local q = entity_run:match_at(s, i + 1)
      if(q == i + 1 or str.substring(s, q, q + 1) != ";"){
        repl = "&amp;"
      }
    }
    if(repl != null){
      append(parts, str.substring(s, start, i))
      append(parts, repl)
      start = i + 1
    }
  }
  append(parts, str.substring(s, start, n))
  return str.join(parts, "")
}

local space_char = regex.compile("[ \t\r\n]")
local func is_space(s, i){
  return space_char:match_at(s, i) > 0
}

// the text of a child as written, with JSX whitespace rules: no line break,
// no change; otherwise the lines are trimmed and joined by one space, and
// the space next to a neighbouring child survives (not next to the tags)
local func clean_text(s, first, last){
  if(str.index_of(s, "\n") < 0){
    return s
  }
  local lines = str.split(s, "\n")
  local kept = {}
  for(local i = 0; i < len(lines); i = i + 1){
    local t = str.trim(lines[i])
    if(t != ""){
      append(kept, t)
    }
  }
  if(len(kept) == 0){
    return ""
  }
  local out = str.join(kept, " ")
  if(not first and is_space(s, 0)){
    out = concat(" ", out)
  }
  if(not last and is_space(s, len(s) - 1)){
    out = concat(out, " ")
  }
  return out
}

// ------------------------------------------------------------ building nodes

local func string_node(value, token){
  return ast.node("String", {value: value}, token)
}

// html.NAME, html being the unit's local for require("slang/html")
local func runtime(name, token){
  local module = g:unit_local("slang/html", +{require("slang/html")})
  return ast.node(
    "Index",
    {receiver: module, index: string_node(name, token), dotStyle: true}, token
  )
}
local func runtime_call(name, args, token){
  return ast.node("Call", {function: runtime(name, token), args: args}, token)
}

// the token of the part of a tag name at offset, as long as part: each
// name gets its own place in the source (hover, go to definition)
local func part_token(token, part, offset){
  if(token.start == null){
    return token
  }
  local start = token.start + offset
  return {
    value: part, start: start, stop: start + len(part), buffer: token.buffer,
    @meta: peg.token_meta
  }
}

// Nav, ui.Button -> the expression naming the component
local func component_ref(name, token){
  local parts = str.split(name, ".")
  local node = ast.node(
    "Identifier",
    {value: parts[0]},
    part_token(token, parts[0], 0),
  )
  local offset = len(parts[0]) + 1
  for(local i = 1; i < len(parts); i = i + 1){
    local at = part_token(token, parts[i], offset)
    node = ast.node(
      "Index",
      {receiver: node, index: string_node(parts[i], at), dotStyle: true}, at
    )
    offset = offset + len(parts[i]) + 1
  }
  return node
}

// the attributes as table fields
local func attr_fields(attrs, token){
  local fields = {}
  for(local i = 0; i < len(attrs); i = i + 1){
    local a = attrs[i]
    if(a.spread != null){
      append(fields, ast.node("Spread", {value: a.spread}, token))
    } else {
      local value = a.value
      if(value == null){
        value = ast.node("True", {}, a.name)
      }
      append(fields, ast.node(
        "Field", {key: string_node(a.name.value, a.name), value: value}, a.name
      ))
    }
  }
  return fields
}

// the children as the fields of a list: text, nested nodes, {expr} values
local func child_fields(children, token){
  local fields = {}
  local n = len(children)
  for(local i = 0; i < n; i = i + 1){
    local c = children[i]
    local value = null
    if(c.text != null){
      local s = clean_text(c.text, i == 0, i == n - 1)
      if(s != ""){
        value = string_node(escape_text(s), token)
      }
    } else if(c.expr != null){
      value = runtime_call("value", {c.expr}, token)
    } else {
      value = c.ast
    }
    if(value != null){
      append(fields, ast.node("Field", {value: value}, token))
    }
  }
  return fields
}

local func table_or_null(fields, token){
  if(len(fields) == 0){
    return ast.node("Null", {}, token)
  }
  return ast.node("Table", {fields: fields}, token)
}

local func build(name, attrs, children, token){
  local kids = child_fields(children, token)
  if(name == null){
    return runtime_call("fragment", {table_or_null(kids, token)}, token)
  }
  if(is_component(name.value)){
    local fields = attr_fields(attrs, token)
    if(len(kids) > 0){
      // a trusted list (see slang/html): its text is not escaped again
      local marked = {
        ast.node("MetaField", {value: runtime("list", token)}, token),
      }
      for(local i = 0; i < len(kids); i = i + 1){
        append(marked, kids[i])
      }
      append(fields, ast.node("Field", {
        key: string_node("children", token),
        value: ast.node("Table", {fields: marked}, token),
      }, token))
    }
    local props = ast.node("Table", {fields: fields}, token)
    return ast.node(
      "Call", {function: component_ref(name.value, name), args: {props}}, token
    )
  }
  local tag = string_node(name.value, name)
  local attributes = table_or_null(attr_fields(attrs, token), token)
  return runtime_call(
    "element", {tag, attributes, table_or_null(kids, token)}, token
  )
}

// ------------------------------------------------------------ formatting
//
// How slang fmt lays templates out (format.layout). Whitespace in text
// means something (see clean_text), so each gap between the parts of an
// element is decided by the whitespace the source has there:
//   - words flow: as many on a line as fit;
//   - a line break the source has next to a child or a tag stays (the
//     structure as written); one between words is a space like any other;
//   - a text run without a line break that has a space next to a tag, or
//     any whitespace but single spaces, is kept exactly and never broken
//     (a break would change its meaning);
//   - no whitespace between text and a child stays none; between two
//     children, or at a tag, it may become a break (that means nothing).
// Tags: the attributes go one per line when the tag does not fit, with
// the > on a line of its own. Slang code in `{...}` is formatted as usual.

local D = fmt.doc

// a text run: its leading whitespace, its words with the whitespace before
// each (but the first), and its trailing whitespace
local func words_of(s){
  local out = {lead: "", words: {}, gaps: {}, trail: ""}
  local n = len(s)
  local i = blank_run:match_at(s, 0)
  out.lead = str.substring(s, 0, i)
  for(i < n){
    local k = word_run:match_at(s, i)
    append(out.words, str.substring(s, i, k))
    local e = blank_run:match_at(s, k)
    if(e >= n){
      out.trail = str.substring(s, k, e)
    } else if(len(out.words) > 0){
      append(out.gaps, str.substring(s, k, e))
    }
    i = e
  }
  return out
}

// (method calls are kept out of the table literals below: `{api:f()}`
// would be the field api)
local func braced_doc(api, b){
  local parts = api:parts(b)
  local expr = api:format(parts[0])
  return {"{", expr, "}"}
}

local func attribute_doc(api, a){
  local parts = api:parts(a)
  if(api:role(parts[0]) == "spread"){
    local expr = api:format(api:parts(parts[0])[0])
    return {"{...", expr, "}"}
  }
  local name = api:text(parts[0])
  if(len(parts) == 1){
    return name
  }
  local value = parts[1]
  if(api:role(value) == "braced"){
    return {name, "=", braced_doc(api, value)}
  }
  local text = api:text(value)
  return {name, "=", text}
}

// the doc of the gap between two parts of the children (left and right:
// "word", "node" or "tag"): {doc, breaks} where breaks says the source has
// a line break there that stays (not a fill separator)
local func gap_doc(space, run, left, right){
  local at_tag = left == "tag" or right == "tag"
  if(space == ""){
    if((left == "word" and right == "node") or
      (left == "node" and right == "word")){
      return {doc: ""}
    }
    if(run != null and run.fixed){
      return {doc: ""}
    }
    return {doc: D.softline, breaks: at_tag}
  }
  if(run.fixed){
    return {doc: space}
  }
  // a line break the source has next to a child or a tag stays (the
  // structure as written); between words it is a space like any other
  if(str.index_of(space, "\n") >= 0 and not(left == "word" and right == "word")){
    return {doc: D.hardline, breaks: true}
  }
  if(at_tag or run.blank_only){
    // a line break here means nothing
    return {doc: D.softline}
  }
  return {doc: D.line}
}

// whether a text run must be kept as written: no line break in it, and a
// space next to a tag or whitespace that is not single spaces
local func fixed_run(w, first, last, has_newline){
  if(has_newline){
    return false
  }
  if((first and w.lead != "") or (last and w.trail != "")){
    return true
  }
  if(len(w.words) == 0){
    return true
  }
  for(let local s in values({w.lead, w.trail})){
    if(s != "" and s != " "){
      return true
    }
  }
  for(let local s in values(w.gaps)){
    if(s != " "){
      return true
    }
  }
  return false
}

// the children of an element: {lead, body, trail} docs, or null when there
// are none
local func children_doc(api, children){
  local kids = api:parts(children)
  local count = len(kids)
  // items (words and nodes) with the gap before each; the last gap is the
  // one before the closing tag
  local items = {}
  local gaps = {}
  local pending = {space: "", run: null}
  for(local i = 0; i < count; i = i + 1){
    local k = kids[i]
    if(api:role(k) == "text"){
      local s = api:text(k)
      local w = words_of(s)
      local has_newline = str.index_of(s, "\n") >= 0
      local run = {
        fixed: fixed_run(w, i == 0, i == count - 1, has_newline),
        blank_only: len(w.words) == 0,
      }
      if(len(w.words) == 0){
        pending = {space: s, run: run}
      } else {
        for(local j = 0; j < len(w.words); j = j + 1){
          if(j == 0){
            append(gaps, {space: w.lead, run: run})
          } else {
            append(gaps, {space: w.gaps[j - 1], run: run})
          }
          append(items, {kind: "word", doc: w.words[j]})
        }
        pending = {space: w.trail, run: run}
      }
    } else {
      append(gaps, pending)
      local doc = null
      if(api:role(k) == "braced"){
        doc = braced_doc(api, k)
      } else {
        doc = api:format(k)
      }
      append(items, {kind: "node", doc: doc})
      pending = {space: "", run: null}
    }
  }
  append(gaps, pending)
  local n = len(items)
  if(n == 0){
    // only whitespace: kept when it means a space
    if(pending.run != null and pending.run.fixed){
      return {lead: pending.space, body: "", trail: ""}
    }
    return null
  }
  local func kind_at(i){
    if(i < 0 or i >= n){
      return "tag"
    }
    return items[i].kind
  }
  local lead = gap_doc(gaps[0].space, gaps[0].run, "tag", kind_at(0))
  local trail = gap_doc(gaps[n].space, gaps[n].run, kind_at(n - 1), "tag")
  // segments: the stretches between the gaps where the element breaks;
  // inside one, fill
  local segments = {}
  local breaks = {}
  local parts = {}
  local content = {items[0].doc}
  for(local i = 1; i < n; i = i + 1){
    local g = gap_doc(gaps[i].space, gaps[i].run, kind_at(i - 1), kind_at(i))
    if(g.breaks){
      append(parts, content)
      append(segments, D.fill(parts))
      append(breaks, g.doc)
      parts = {}
      content = {items[i].doc}
    } else if(type(g.doc) == "string"){
      append(content, g.doc)
      append(content, items[i].doc)
    } else {
      append(parts, content)
      append(parts, g.doc)
      content = {items[i].doc}
    }
  }
  append(parts, content)
  append(segments, D.fill(parts))
  local body = {segments[0]}
  for(local i = 1; i < len(segments); i = i + 1){
    append(body, breaks[i - 1])
    append(body, segments[i])
  }
  return {lead: lead.doc, body: body, trail: trail.doc}
}

local func layout_element(api, n){
  local parts = api:parts(n)
  local open = null
  local close = null
  local children = null
  if(api:role(parts[0]) == "fragment"){
    open = "<>"
    close = "</>"
    children = parts[1]
  } else {
    local tag = api:text(parts[0])
    local attrs = {}
    local self_close = false
    for(local i = 1; i < len(parts); i = i + 1){
      local role = api:role(parts[i])
      if(role == "attr"){
        append(attrs, D.line)
        append(attrs, attribute_doc(api, parts[i]))
      } else if(role == "self_close"){
        self_close = true
      } else if(role == "children"){
        children = parts[i]
      }
    }
    local end_mark = ">"
    if(self_close){
      end_mark = "/>"
    }
    if(len(attrs) > 0){
      open = D.group({"<", tag, D.indent(attrs), D.softline, end_mark})
    } else {
      open = {"<", tag, end_mark}
    }
    if(self_close){
      return open
    }
    close = {"</", tag, ">"}
  }
  local c = null
  if(children != null){
    c = children_doc(api, children)
  }
  if(c == null){
    return {open, close}
  }
  return D.group({open, D.indent({c.lead, c.body}), c.trail, close})
}

// ------------------------------------------------------------ syntax

local element = peg.settable()

local braced_expr = fmt.role(
  peg.seq(
    punct("{"), ws, fmt.role(g:rule("expr"), "expr"), ws, punct("}")
  ):pick(2),
  "braced",
)

local attribute = fmt.role(peg.choice(
  fmt.role(
    peg.seq(
      punct("{"), ws, peg.token(peg.string("..."), "operator"),
      fmt.role(g:rule("expr"), "expr"), ws, punct("}")
    ),
    "spread",
  ):map(func(v){
    return {spread: v[3]}
  }),
  peg.seq(
    fmt.role(peg.token(attr_name, "property"), "name"),
    peg.seq(ws, punct("="), ws, peg.choice(
      fmt.role(g:rule("string_literal"), "string"),
      braced_expr,
    )):pick(3):optional(),
  )
    :map(func(v){
      return {name: v[0], value: v[1]}
    }),
), "attr")

local child = peg.choice(
  element,
  braced_expr:map(func(e){ return {expr: e} }),
  fmt.role(text, "text"):map(func(s){ return {text: s} }),
)

local tag_part = fmt.role(tag_token, "tag")

// <>children</> | <name attrs/> | <name attrs>children</name>
element:set(fmt.layout(peg.choice(
  peg.seq(
    fmt.role(punct("<>"), "fragment"),
    fmt.role(child:star(), "children"),
    punct("</>"),
  ):map(func(v){
    return {token: v[0], ast: build(null, {}, v[1], v[0])}
  }),
  peg.seq(
    punct("<"), tag_part, peg.seq(ws, attribute):pick(1):star(), ws,
    peg.choice(
      fmt.role(punct("/>"), "self_close"):map(func(t){ return {children: {}} }),
      peg.seq(
        punct(">"), fmt.role(child:star(), "children"), punct("</"), ws,
        tag_part, ws, punct(">")
      )
        :map(func(v){
          return {children: v[1], close: v[4]}
        }),
    )
  )
    :map(func(v){
      local open = v[1]
      local tail = v[4]
      if(tail.close != null and tail.close.value != open.value){
        g:error_at(
          tail.close, "</", open.value, "> expected to close the <", open.value,
          "> opened at ", v[0].line, ":", v[0].column, ", found </",
          tail.close.value, ">"
        )
      }
      return {token: v[0], ast: build(open, v[2], tail.children, v[0])}
    }),
), func(api, n){ return layout_element(api, n) }))

g:expression():primary("html", element)
