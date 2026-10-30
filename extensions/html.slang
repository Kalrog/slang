// HTML templates that read like HTML, as JSX does: an expression starting
// with `<` builds slang/html nodes, and components compose them.
//
//   local func Page(props){
//     return <html>
//       <head><title>{props.title}</title></head>
//       <body class="page" data-user={props.user.id}>
//         <Nav links={props.links}/>
//         {props.children}
//       </body>
//     </html>
//   }
//   local func Nav(props){
//     return <ul class="nav">
//       {map(props.links, func(l){ return <li><a href={l.href}>{l.text}</a></li> })}
//     </ul>
//   }
//   string(<Page title="Hello" user={user} links={links}><p>welcome</p></Page>)
//
// Elements: `<tag attr="text" attr={expr} flag {...table}>children</tag>`
// or `<tag .../>`; `<>...</>` is a fragment. A tag name that starts with a
// capital letter or contains a dot names a component: a function that is
// called with one table, the attributes plus the children under
// `children`; `<Nav links={x}>a</Nav>` is `Nav({links: x, children: {"a"}})`.
//
// Children are text, elements and `{expr}`: a string is escaped, a number
// printed, a node or a list inserted (lists element by element), null and
// booleans dropped, which makes `{cond and <b>x</b>}` a conditional;
// html.raw(s) inserts trusted markup. Literal text is escaped when it is
// compiled, except for entities (`&amp;`, `&#169;`), which are kept; its
// whitespace follows JSX, with a twist: lines are trimmed, blank lines
// dropped, a line break inside text becomes one space, and a space between
// text and a `{value}` is kept (`Hello {name}` stays two words).
//
// Attribute values are text or `{expr}`; null and false omit the attribute,
// true writes it bare (`<input disabled={not ok}/>`), anything else is
// escaped. Everything lowers to calls on slang/html, required once per
// unit (g:unit_local); the highlighter sees tags as keywords, components
// as functions, attributes as properties.
local peg = require("slang/peg")
local ast = require("slang/ast")
local str = require("slang/string")
local g = require("slang/compiler").grammar()

// ------------------------------------------------------------ lexical pieces
//
// Inside a template the slang trivia rules do not apply: whitespace is
// significant in text, so the pieces below are raw parsers; only the
// slang expressions inside `{...}` and the attribute strings use tokens.

local ws = peg.pattern(" \t\r\n"):star()

local func punct(s){
  return peg.token(peg.string(s), "punctuation")
}

local name_chars = peg.seq(
  peg.pattern("a-zA-Z_"),
  peg.pattern("a-zA-Z0-9_:-"):star()
)
local tag_name = peg.seq(
  name_chars,
  peg.seq(peg.char("."), name_chars):star()
):flatten("tag name expected")
local attr_name = peg.seq(
  peg.pattern("a-zA-Z_:@"),
  peg.pattern("a-zA-Z0-9_:.-"):star()
):flatten("attribute name expected")

local func is_component(name){
  local b = str.byte_at(name, 0)
  return (b >= 65 and b <= 90) or str.index_of(name, ".") >= 0
}

// the tag name as a token, highlighted by what it names
local tag_token = peg.custom(func(self, ctx, pos){
  local q = tag_name:parse_on(ctx, pos)
  if(q < 0){
    return - 1
  }
  local name = ctx.value
  if(ctx.tokens != null){
    list_push(ctx.tokens, {
      category: is_component(name) and "function" or "keyword", start: pos,
      stop: q,
    })
  }
  ctx.value = peg.make_token(ctx, name, pos, q)
  return q
})

// text: everything up to the next tag or `{`
local text_class = str.char_class("^<{")
local text = peg.custom(func(self, ctx, pos){
  local q = str.class_run(text_class, ctx.buffer, pos)
  if(q == pos){
    return peg.fail(ctx, pos, "text expected")
  }
  ctx.value = str.substring(ctx.buffer, pos, q)
  return q
})

// ------------------------------------------------------------ literal text

// & < > escaped, entities (&name; &#123;) left alone
local entity_class = str.char_class("a-zA-Z0-9#")
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
      local q = str.class_run(entity_class, s, i + 1)
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

local space_class = str.char_class(" \t\r\n")
local func is_space(s, i){
  return str.class_match(space_class, s, i) > 0
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

// Nav, ui.Button -> the expression naming the component
local func component_ref(name, token){
  local parts = str.split(name, ".")
  local node = ast.node("Identifier", {value: parts[0]}, token)
  for(local i = 1; i < len(parts); i = i + 1){
    node = ast.node(
      "Index",
      {receiver: node, index: string_node(parts[i], token), dotStyle: true},
      token
    )
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
        ast.node(
          "Field",
          {key: string_node("meta", token), value: runtime("list", token)},
          token
        ),
      }
      for(local i = 0; i < len(kids); i = i + 1){
        append(marked, kids[i])
      }
      append(fields, ast.node(
        "Field",
        {
          key: string_node("children", token),
          value: ast.node("Table", {fields: marked}, token),
        }, token
      ))
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

// ------------------------------------------------------------ syntax

local element = peg.settable()

local braced_expr = peg.seq(
  punct("{"), ws, g:rule("expr"), ws, punct("}")
):pick(2)

local attribute = peg.choice(
  peg.seq(
    punct("{"), ws, peg.token(peg.string("..."), "operator"), g:rule("expr"),
    ws, punct("}")
  )
    :map(func(v){
      return {spread: v[3]}
    }),
  peg.seq(
    peg.token(attr_name, "property"),
    peg.seq(
      ws, punct("="), ws, peg.choice(g:rule("string_literal"), braced_expr)
    )
      :pick(3)
      :optional()
  )
    :map(func(v){
      return {name: v[0], value: v[1]}
    })
)

local child = peg.choice(
  element,
  braced_expr:map(func(e){ return {expr: e} }),
  text:map(func(s){ return {text: s} })
)

// <>children</> | <name attrs/> | <name attrs>children</name>
element:set(peg.choice(
  peg.seq(punct("<>"), child:star(), punct("</>")):map(func(v){
    return {token: v[0], ast: build(null, {}, v[1], v[0])}
  }),
  peg.seq(
    punct("<"), tag_token, peg.seq(ws, attribute):pick(1):star(), ws,
    peg.choice(
      punct("/>"):map(func(t){ return {children: {}} }),
      peg.seq(
        punct(">"), child:star(), punct("</"), ws, tag_token, ws, punct(">")
      )
        :map(func(v){
          return {children: v[1], close: v[4]}
        })
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
    })
))

g:expression():primary("html", element)
