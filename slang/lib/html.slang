// slang/html: HTML nodes that render to a string. It is the runtime
// behind the JSX-like templates of extensions/html and works on its own.
//
//   local html = require("slang/html")
//   local page = html.element("ul", {class: "names"}, {
//     html.element("li", null, {html.value("Tom & Jerry")}),
//   })
//   html.render(page)   // <ul class="names"><li>Tom &amp; Jerry</li></ul>
//
// Trust: the children of [element] and [fragment], and any list whose
// metatable is [list], are trusted, so their strings are markup and are
// written as they are. Pass untrusted text through [value] (or [escape])
// first; the extension does that for every {expr} in a template and
// escapes literal text when it compiles it. [value] passes trusted lists
// through, so children handed on to a component are not escaped twice.
//
// Attributes: values are escaped when rendered; null and false leave the
// attribute out, true writes it bare (<input disabled>). Void elements
// (br, img, input, meta, ...) get no end tag.

// A node; type() of it is "Html", and string(node) renders it.
// type Node = {tag?: string, attrs?: {[string]: any}, children?: {Content},
//   raw?: string}
// [tag]: the element's name; null for a fragment or raw markup
// [attrs]: the attributes by name
// [children]: trusted content, marked with [list]
// [raw]: markup written as it is

// What can be rendered: markup strings, numbers, nodes and lists of
// these. null and booleans write nothing.
// type Content = string | int | float | Node | {Content}
local str = require("slang/string")
local regex = require("slang/regex")
local html = {}

local safe_run = regex.compile("[^&<>\"']*")
local replacements = {
  ["&"]: "&amp;", ["<"]: "&lt;", [">"]: "&gt;", ["\""]: "&quot;", ["'"]: "&#39;"
}

// escape(s: string) -> string
// s with & < > " and ' replaced by their character references; s itself
// when there is nothing to replace.
func html.escape(s){
  local n = len(s)
  local q = safe_run:match_at(s, 0)
  if(q >= n){
    return s
  }
  local parts = {}
  local start = 0
  for(q < n){
    if(q > start){
      append(parts, str.substring(s, start, q))
    }
    append(parts, replacements[str.substring(s, q, q + 1)])
    start = q + 1
    q = safe_run:match_at(s, start)
  }
  if(start < n){
    append(parts, str.substring(s, start, n))
  }
  return str.join(parts, "")
}

local node_meta = {__type: "Html"}
func node_meta.__tostring(self){
  return html.render(self)
}
// The metatable that marks a list of children as trusted markup; type()
// of such a list is "HtmlList".
html.list = {__type: "HtmlList"}

// the void elements; `meta` is checked apart because t.meta is a table's
// metatable, not a field
local void = {
  area: true, base: true, br: true, col: true, embed: true, hr: true, img: true,
  input: true, link: true, param: true, source: true, track: true, wbr: true
}
local func is_void(tag){
  return tag == "meta" or void[tag] == true
}

// element(tag: string, attrs?: {[string]: any},
//         children?: {Content}) -> Node
// The element <tag attrs>children</tag>. children becomes trusted: its
// metatable is set to [list].
func html.element(tag, attrs, children){
  if(children != null){
    children.meta = html.list
  }
  return {meta: node_meta, tag: tag, attrs: attrs, children: children}
}

// fragment(children?: {Content}) -> Node
// The children without an enclosing tag. children becomes trusted, as for
// [element].
func html.fragment(children){
  if(children != null){
    children.meta = html.list
  }
  return {meta: node_meta, children: children}
}

// raw(s: string) -> Node
// A node that writes s as it is, unescaped.
func html.raw(s){
  return {meta: node_meta, raw: s}
}

// The <!DOCTYPE html> node, to put before <html>.
html.doctype = html.raw("<!DOCTYPE html>")

// is_node(v) -> bool
// Whether v is a [Node].
func html.is_node(v){
  return type(v) == "Html"
}

// value(v) -> Content
// What {v} in a template inserts: a string escaped, a number printed, a
// [Node] or trusted list kept, a plain list converted element by element
// into a trusted list, null and booleans "" (not null, which would end the
// list of children it sits in). Anything else is rendered with string()
// and escaped.
func html.value(v){
  local t = type(v)
  if(t == "string"){
    return html.escape(v)
  }
  if(t == "Html" or t == "HtmlList"){
    return v
  }
  if(t == "null" or t == "bool"){
    return ""
  }
  if(t == "int" or t == "double"){
    return string(v)
  }
  if(t == "table"){
    local out = {}
    for(local i = 0; i < len(v); i = i + 1){
      append(out, html.value(v[i]))
    }
    out.meta = html.list
    return out
  }
  return html.escape(string(v))
}

local func write_attrs(out, attrs){
  for(let local e in entries(attrs)){
    local v = e[1]
    if(v == true){
      append(out, concat(" ", e[0]))
    } else if(v != null and v != false){
      append(out, concat(" ", e[0], "=\"", html.escape(string(v)), "\""))
    }
  }
}

// write(out: {string}, v: Content)
// Appends the pieces of the markup of v to the list out; [render] joins
// them. Writing into one list avoids building strings for every node.
func html.write(out, v){
  local t = type(v)
  if(t == "string"){
    append(out, v)
  } else if(t == "Html"){
    if(v.raw != null){
      append(out, v.raw)
      return null
    }
    if(v.tag != null){
      append(out, concat("<", v.tag))
      if(v.attrs != null){
        write_attrs(out, v.attrs)
      }
      append(out, ">")
    }
    if(v.children != null){
      for(local i = 0; i < len(v.children); i = i + 1){
        html.write(out, v.children[i])
      }
    }
    if(v.tag != null and not is_void(v.tag)){
      append(out, concat("</", v.tag, ">"))
    }
  } else if(t == "table" or t == "HtmlList"){
    for(local i = 0; i < len(v); i = i + 1){
      html.write(out, v[i])
    }
  } else if(t == "int" or t == "double"){
    append(out, string(v))
  }
  return null
}

// render(v: Content) -> string
// The markup of v.
func html.render(v){
  local out = {}
  html.write(out, v)
  return str.join(out, "")
}

return html
