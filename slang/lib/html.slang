// slang/html: HTML nodes that render to a string; the runtime behind the
// JSX-like templates of extensions/html, and usable on its own.
//
//   html.element(tag, attrs, children) -> node    <tag attrs>children</tag>
//   html.fragment(children) -> node               children without a tag
//   html.raw(s) -> node                           s inserted as it is
//   html.value(v) -> what {v} in a template inserts: a string escaped, a
//                    number printed, a node or a list kept (lists element
//                    by element), null and booleans nothing ("": a null
//                    would end the list of children it sits in)
//   html.escape(s) -> s with & < > " ' escaped
//   html.render(v) -> the string of v; string(node) renders too
//   html.write(out, v)   appends the pieces of v to the list out
//   html.doctype         the <!DOCTYPE html> node
//
// The children of element and fragment, and any list with html.list as its
// meta, are trusted: their strings are markup (the extension escapes
// literal text when it compiles it, and wraps every {expr} in value), and
// value passes such a list through, so children handed to a component
// are not escaped twice. Attribute values are escaped when rendered, null
// and false omit the attribute, true writes it bare. Void elements (br,
// img, ...) have no end tag.
local str = require("slang/string")
local html = {}

local safe = str.char_class("^&<>\"'")
local replacements = {
  ["&"]: "&amp;", ["<"]: "&lt;", [">"]: "&gt;", ["\""]: "&quot;", ["'"]: "&#39;"
}

func html.escape(s){
  local n = len(s)
  local q = str.class_run(safe, s, 0)
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
    q = str.class_run(safe, s, start)
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
// the meta of a trusted list of children
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

func html.element(tag, attrs, children){
  if(children != null){
    children.meta = html.list
  }
  return {meta: node_meta, tag: tag, attrs: attrs, children: children}
}

func html.fragment(children){
  if(children != null){
    children.meta = html.list
  }
  return {meta: node_meta, children: children}
}

func html.raw(s){
  return {meta: node_meta, raw: s}
}

html.doctype = html.raw("<!DOCTYPE html>")

func html.is_node(v){
  return type(v) == "Html"
}

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

func html.render(v){
  local out = {}
  html.write(out, v)
  return str.join(out, "")
}

return html
