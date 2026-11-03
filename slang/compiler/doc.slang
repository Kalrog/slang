// slang/doc: API documentation from the comments the code already has, as
// HTML: `slang doc [-o dir] [file|dir...]`.
//
//   slang doc -o site/api slang/lib/http.slang
//
// A module is a file that returns a table; its documentation is the comment
// block that starts the file and, for every field of the returned table, the
// comment just above its definition (no blank line between). Section
// dividers (`// ---- title`) group the fields. In a comment, lines indented
// by two or more spaces are code samples; the rest is prose. A file that
// returns no table is documented by its globals that have a comment (the
// stub of the globals); others (programs, tests) are left out.
//
// A doc may start with a typed signature, describe parameters and fields in
// `[name]: text` lines and refer to names as `[name]`; files declare types
// in `// type Name = ...` lines (the notation is slang/symbols'). Signatures
// and types are shown with their names linked, and every type gets a
// section: a declared one with its fields or methods, and a meta table
// with __index and __type with its methods.
//
// Native modules and the globals are documented from their stubs (see
// compiler.stub_path). Without paths: the project in the working directory
// (a slang.project there), else slang's own library with the stubs. Output
// goes to dir (./doc by default): index.html and a page per module
// (slang/http is slang-http.html).
local str = require("slang/string")
local os = require("slang/os")
local symbols = require("slang/symbols")
local peg = require("slang/peg")
local tbl = require("slang/table")

local doc = {}

// ------------------------------------------------------------ html

local func escape(s){
  s = str.replace(s, "&", "&amp;")
  s = str.replace(s, "<", "&lt;")
  s = str.replace(s, ">", "&gt;")
  return str.replace(s, "\"", "&quot;")
}

local func is_ref_byte(b){
  return (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or
    (b >= 'a' and b <= 'z') or b == '_' or b == '.' or b == ':'
}

// [name] references in escaped prose: a link where resolve(name) gives one,
// code for a name known otherwise (a parameter), the text as it is else
local func refs_html(text, resolve){
  if(resolve == null){
    return text
  }
  local out = {}
  local i = 0
  for(i < len(text)){
    local open = str.index_of(text, "[", i)
    if(open < 0){
      break
    }
    local close = str.index_of(text, "]", open)
    if(close < 0){
      break
    }
    local inner = str.substring(text, open + 1, close)
    local ok = len(inner) > 0
    for(local k = 0; k < len(inner); k = k + 1){
      ok = ok and is_ref_byte(str.byte_at(inner, k))
    }
    local r = ok and resolve(inner) or null
    append(out, str.substring(text, i, open))
    if(r == null){
      append(out, str.substring(text, open, close + 1))
    } else if(r == true){
      append(out, concat("<code>", inner, "</code>"))
    } else {
      append(out, concat("<a href=\"", r, "\"><code>", inner, "</code></a>"))
    }
    i = close + 1
  }
  append(out, str.substring(text, i))
  return str.join(out, "")
}

// prose with `code` spans (and [name] references, with resolve)
local func prose_html(text, resolve){
  local parts = str.split(escape(text), "`")
  if(len(parts) % 2 == 0){
    // an unpaired backquote: the text as it is
    return refs_html(escape(text), resolve)
  }
  local out = {}
  for(local i = 0; i < len(parts); i = i + 1){
    if(i % 2 == 1){
      append(out, concat("<code>", parts[i], "</code>"))
    } else {
      append(out, refs_html(parts[i], resolve))
    }
  }
  return str.join(out, "")
}

local func blocks_html(text, resolve){
  local out = {}
  for(let local b in values(symbols.doc_blocks(text))){
    if(b.kind == "code"){
      append(out, concat("<pre><code>", escape(b.text), "</code></pre>"))
    } else {
      append(out, concat("<p>", prose_html(b.text, resolve), "</p>"))
    }
  }
  return str.join(out, "\n")
}

// ------------------------------------------------------------ types

local params_html = null

local builtin_types = {
  string: true,
  int: true,
  float: true,
  bool: true,
  null: true,
  any: true,
  ["function"]: true,
  table: true,
  number: true,
}

// a type as html, its names linked
local func type_html(t, resolve){
  if(t == null){
    return "any"
  }
  local k = t.kind
  if(k == "name"){
    local href = null
    if(not builtin_types[t.name] and resolve != null){
      href = resolve(t.name)
    }
    if(type(href) == "string"){
      return concat("<a href=\"", href, "\">", escape(t.name), "</a>")
    }
    return escape(t.name)
  }
  if(k == "optional"){
    local inner = type_html(t.of, resolve)
    if(t.of.kind == "union" or t.of.kind == "func"){
      inner = concat("(", inner, ")")
    }
    return concat(inner, "?")
  }
  if(k == "union"){
    local parts = {}
    for(let local p in values(t.of)){
      append(parts, type_html(p, resolve))
    }
    return str.join(parts, " | ")
  }
  if(k == "list"){
    return concat("{", type_html(t.of, resolve), "}")
  }
  if(k == "map"){
    return concat(
      "{[", type_html(t.key, resolve), "]: ", type_html(t.value, resolve), "}"
    )
  }
  if(k == "shape"){
    local parts = {}
    for(let local f in values(t.fields)){
      append(parts, concat(
        escape(f.name),
        f.optional and "?" or "",
        ": ",
        type_html(f.type, resolve),
      ))
    }
    return concat("{", str.join(parts, ", "), "}")
  }
  if(k == "func"){
    local out = concat("func", params_html(t.params, resolve))
    if(t.returns != null){
      out = concat(out, ": ", type_html(t.returns, resolve))
    }
    return out
  }
  return "any"
}

// (a: T, b?: U) as html
params_html = func(params, resolve){
  local parts = {}
  for(let local p in values(params)){
    local text = concat(
      p.rest and "..." or "",
      escape(p.name),
      p.optional and "?" or "",
    )
    if(p.type != null){
      text = concat(text, ": ", type_html(p.type, resolve))
    }
    append(parts, text)
  }
  return concat("(", str.join(parts, ", "), ")")
}

// the first sentence of a doc, for the index
local func summary(text){
  local blocks = symbols.doc_blocks(text)
  if(len(blocks) == 0 or blocks[0].kind != "text"){
    return ""
  }
  local t = blocks[0].text
  local stop = str.index_of(t, ". ")
  if(stop >= 0){
    t = str.substring(t, 0, stop + 1)
  }
  return t
}

local STYLE = """
:root { --fg: #1f2328; --muted: #59636e; --bg: #ffffff; --code: #f6f8fa;
  --line: #d1d9e0; --link: #0969da; }
@media (prefers-color-scheme: dark) {
  :root { --fg: #e6edf3; --muted: #9198a1; --bg: #0d1117; --code: #161b22;
    --line: #3d444d; --link: #4493f8; }
}
body { font: 16px/1.5 -apple-system, system-ui, sans-serif; color: var(--fg);
  background: var(--bg); max-width: 52rem; margin: 0 auto; padding: 1rem; }
a { color: var(--link); text-decoration: none; }
a:hover { text-decoration: underline; }
nav { font-size: 0.9rem; margin-bottom: 1rem; }
h1 { font-size: 1.8rem; margin: 0.5rem 0; }
h2 { font-size: 1.3rem; border-bottom: 1px solid var(--line);
  padding-bottom: 0.3rem; margin-top: 2rem; }
h3 { font-size: 1rem; margin: 1.5rem 0 0.25rem; }
code, pre { font: 0.9rem/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
pre { background: var(--code); padding: 0.75rem 1rem; border-radius: 6px;
  overflow-x: auto; }
.def p { margin: 0.25rem 0 0.5rem; }
.muted { color: var(--muted); }
ul.toc { columns: 2; padding-left: 1.2rem; }
@media (max-width: 40rem) { ul.toc { columns: 1; } }
dt { margin-top: 0.75rem; }
dd { margin-left: 1rem; color: var(--muted); }
dl.params dt { margin-top: 0.4rem; }
dl.params dd { margin: 0 0 0 1.5rem; }
pre.ebnf { white-space: pre-wrap; border-left: 3px solid var(--link); }
dl.syntax dd { margin: 0.2rem 0 0.8rem 0.2rem; }
figure.example { margin: 1rem 0; }
details.expanded summary { cursor: pointer; color: var(--muted); }
"""

local func page(title, body){
  return concat(
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n",
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n",
    "<title>", escape(title), "</title>\n<style>", STYLE, "</style>\n",
    "</head>\n<body>\n", body, "\n</body>\n</html>\n"
  )
}

// the page file of a module: slang/http -> slang-http.html
local func page_name(module){
  return concat(str.replace(module, "/", "-"), ".html")
}

// ------------------------------------------------------------ modules

// The documentation of a module, as [module] gathers it.
// type ModulePage = {name: string, path: string, doc?: string,
//   sections: {PageSection}, links: Links, kind: string}
// [name]: the module's name, as require takes it
// [path]: the file, as shown
// [kind]: "module" ([ExtensionPage] has "extension")
// [doc]: the module's doc, the comment block that starts the file

// A part of a page: the entries under a section divider (title null for
// those before the first), or a type with its methods.
// type PageSection = {title?: string, defs: {Entry}, type_name?: string,
//   decl?: symbols.TypeDecl}
// [type_name]: set for a type's section
// [decl]: the declaration, for a type the doc comments declare

// A documented definition.
// type Entry = {name: string, signature: string, doc?: string, start?: int,
//   info: symbols.DocInfo, params?: {string}, method?: bool}
// [name]: its anchor on the page ("Type:name" for a method)
// [signature]: from its parameter names, for a doc without a typed one

// What names in a page's docs can link to.
// type Links = {types: {[string]: bool}, exports: {[string]: bool},
//   aliases: {[string]: string}, methods: {[string]: bool}}
// [types]: the module's types
// [exports]: the module's documented fields
// [aliases]: the locals that hold a module, and its name
// [methods]: the anchors of the types' methods ("Type:name")

// an entry of a page (see Entry)
local func entry(d, signature){
  return {
    name: d.name, signature: signature or symbols.signature(d), doc: d.doc,
    start: d.start, info: d.info, params: d.params
  }
}

// the methods of a table: entries "Type:name(params)" (without self)
local func methods_of(index, table, type_name){
  local list = {}
  for(let local m in values(index.defs)){
    if(m.kind == "field" and m.owner == table){
      local params = {}
      for(local i = 1; i < len(m.params or {}); i = i + 1){
        append(params, m.params[i])
      }
      local signature = concat(type_name, ".", m.name)
      if(m.params != null){
        signature = concat(
          type_name, ":", m.name, "(", str.join(params, ", "), ")"
        )
      }
      local e = entry(m, signature)
      e.name = concat(type_name, ":", m.name)
      e.method = true
      append(list, e)
    }
  }
  return list
}

// the table a field of a meta holds (__index: methods, __get: {...}): the
// local it names, or the field itself for a table literal
local func table_of(index, f){
  if(f == null or f.value == null){
    return null
  }
  if(f.value.type == "Table"){
    return f
  }
  if(f.value.type != "Identifier" or f.value.token == null){
    return null
  }
  local r = index.by_start[f.value.token.start]
  if(r != null and r.kind == null){
    r = r.def
  }
  if(r == null or r.fields == null){
    return null
  }
  return r
}

// whether a table definition is a meta: it has __index, __get or __set
local func is_meta(d){
  local f = d.fields or {}
  return f.__index != null or f.__get != null or f.__set != null
}

// the properties of a meta: entries "Type.name: T" for the keys of its
// __get and __set, documented by the getter (else the setter): its prose,
// and its declared result (a setter's second parameter) as the type
local func properties_of(index, meta, type_name){
  local getters = table_of(index, meta.fields.__get)
  local setters = table_of(index, meta.fields.__set)
  local list = {}
  local by = {}
  for(let local d in values(index.defs)){
    if(d.kind == "field" and d.owner != null and
      (d.owner == getters or d.owner == setters)){
      local p = by[d.name]
      if(p == null){
        p = {
          name: concat(type_name, ".", d.name), start: d.start, method: false,
          property: true, readable: false, writable: false, info: {items: {}}
        }
        by[d.name] = p
        append(list, p)
      }
      local getter = d.owner == getters
      if(getter){
        p.readable = true
      } else {
        p.writable = true
      }
      // the getter's doc comes first
      if(d.doc != null and (p.doc == null or getter)){
        local sig = d.info.signature
        p.doc = d.doc
        p.info = {items: d.info.items, prose: d.info.prose}
        p.type = null
        if(sig != null){
          p.info.prose = d.info.prose or (sig.result and sig.result.text)
          if(getter and sig.result != null){
            p.type = sig.result.type
          } else if(not getter and len(sig.params) > 1){
            p.type = sig.params[1].type
          }
        }
      }
    }
  }
  for(let local e in entries(by)){
    local p = e[1]
    local sig = concat(type_name, ".", e[0])
    if(p.type != null){
      sig = concat(sig, ": ", symbols.type_text(p.type))
    }
    if(not p.writable){
      sig = concat(sig, " (read-only)")
    } else if(not p.readable){
      sig = concat(sig, " (write-only)")
    }
    p.signature = sig
  }
  return list
}

// the entries of a meta's type: its properties, then the methods of its
// __index table
local func meta_entries(index, meta, type_name){
  local list = properties_of(index, meta, type_name)
  local methods = table_of(index, meta.fields.__index)
  if(methods != null){
    for(let local e in values(methods_of(index, methods, type_name))){
      append(list, e)
    }
  }
  return list
}

// the types a file defines: those its doc comments declare (`type Name =
// {...}` with its fields, `type Name` above the table of its methods or
// above its meta), and a table with __index, __get or __set and __type,
// the meta of a type whose methods are the fields of the __index table
// and whose properties the keys of __get and __set; one section per type
local func type_sections(index){
  local out = {}
  local declared_tables = {}
  // the section of each type name: two metas with the same __type share one
  local by_name = {}
  local names = {}
  for(let local t in values(index.types or {})){
    append(names, t.name)
  }
  for(let local name in values(names)){
    local t = index.types[name]
    local sec = {
      title: concat("type ", name), type_name: name, decl: t, defs: {}
    }
    if(t.table != null){
      declared_tables[t.table] = name
      if(is_meta(t.table)){
        local methods = table_of(index, t.table.fields.__index)
        if(methods != null){
          declared_tables[methods] = name
        }
        sec.defs = meta_entries(index, t.table, name)
      } else {
        sec.defs = methods_of(index, t.table, name)
      }
    }
    by_name[name] = sec
    append(out, sec)
  }
  for(let local d in values(index.defs)){
    local fields = d.fields or {}
    local t = fields.__type
    if(d.kind != "field" and t != null and is_meta(d) and
      t.value != null and t.value.type == "String" and
      declared_tables[d] == null){
      local methods = table_of(index, fields.__index)
      if(methods == null or declared_tables[methods] == null){
        local type_name = t.value.value
        local list = meta_entries(index, d, type_name)
        if(len(list) > 0 and by_name[type_name] != null){
          for(let local e in values(list)){
            append(by_name[type_name].defs, e)
          }
        } else if(len(list) > 0){
          by_name[type_name] = {
            title: concat("type ", type_name), type_name: type_name, defs: list
          }
          append(out, by_name[type_name])
        }
      }
    }
  }
  return out
}

// module(name: string, path: string, source: string,
//   index?: symbols.Index) -> ModulePage?
// A module's documentation: the fields of the table the file returns (or,
// in a file that returns none, its documented globals), by section, then
// its types; null when there is nothing to document.
// [source]: the file's text (not read: index has what is needed)
// [index]: the file's names (compiler.highlight with symbols)
func doc.module(name, path, source, index){
  if(index == null){
    return null
  }
  local listed = {}
  // exports are shown as their users call them: http.serve(...), whatever
  // the file calls its table
  local parts = str.split(name, "/")
  local short = parts[len(parts) - 1]
  for(let local d in values(index.defs)){
    if(d.name == "@meta"){
      // a module's own metatable, not an export
      continue
    }
    if(index.returned != null){
      if(index.exports[d.name] == d){
        local signature = concat(short, ".", d.name)
        if(d.params != null){
          signature = concat(signature, "(", str.join(d.params, ", "), ")")
        }
        append(listed, entry(d, signature))
      }
    } else if(d.kind == "global" and d.doc != null){
      append(listed, entry(d))
    }
  }
  local types = type_sections(index)
  if(len(listed) == 0 and len(types) == 0){
    return null
  }
  local sections = {{title: null, defs: {}}}
  local at = 0
  for(let local d in values(listed)){
    // the last section divider before the definition
    for(at < len(index.sections) and index.sections[at].start < d.start){
      append(sections, {title: index.sections[at].title, defs: {}})
      at = at + 1
    }
    append(sections[len(sections) - 1].defs, d)
  }
  local kept = {}
  for(let local s in values(sections)){
    if(len(s.defs) > 0){
      append(kept, s)
    }
  }
  for(let local s in values(types)){
    append(kept, s)
  }
  // what [name] and type names can link to: this module's types and
  // exports, and other modules through the names the file gives them
  local links = {types: {}, exports: {}, aliases: {}, methods: {}}
  for(let local sec in values(types)){
    links.types[sec.type_name] = true
    for(let local e in values(sec.defs)){
      links.methods[e.name] = true
    }
  }
  for(let local d in values(listed)){
    links.exports[d.name] = true
  }
  for(let local d in values(index.defs)){
    if(d.module != null){
      links.aliases[d.name] = d.module
    }
  }
  return {
    kind: "module",
    name: name,
    path: path,
    doc: index.module_doc,
    sections: kept,
    links: links,
  }
}

// what a name in a module's docs links to: a href, true for a name known
// but not linked (a parameter), or null. params: the names of the entry at
// hand.
local func resolver(m, params){
  return func(name){
    if(params != null and params[name]){
      return true
    }
    local links = m.links or {types: {}, exports: {}, aliases: {}}
    if(links.types[name]){
      return concat("#type-", name)
    }
    if(links.exports[name]){
      return concat("#", name)
    }
    local dot = str.index_of(name, ".")
    if(dot > 0){
      local head = str.substring(name, 0, dot)
      local rest = str.substring(name, dot + 1)
      // Type.method of this module, or the type for one of its fields
      if(links.types[head]){
        if((links.methods or {})[concat(head, ":", rest)]){
          return concat("#", head, ":", rest)
        }
        return concat("#type-", head)
      }
      local module = links.aliases[head]
      if(module != null){
        local b = str.byte_at(rest, 0)
        local anchor = (b >= 'A' and b <= 'Z') and concat("type-", rest) or rest
        return concat(page_name(module), "#", anchor)
      }
    }
    return null
  }
}

// an entry's heading: its typed signature when its doc has one
local func signature_html(d, resolve){
  local sig = d.info and d.info.signature
  if(sig == null){
    return escape(d.signature)
  }
  local cut = str.index_of(d.signature, "(")
  local head = cut >= 0 and str.substring(d.signature, 0, cut) or d.signature
  local params = sig.params
  // a method's first parameter is the value it is called on: left out when
  // the doc lists it (as many parameters as the function has)
  if(d.method and d.params != null and len(params) == len(d.params) and
    len(params) > 0){
    local rest = {}
    for(local i = 1; i < len(params); i = i + 1){
      append(rest, params[i])
    }
    params = rest
  }
  local out = concat(escape(head), params_html(params, resolve))
  local r = sig.result
  if(r != null and r.type != null){
    out = concat(out, " -> ")
    if(r.name != null){
      out = concat(out, escape(r.name), ": ")
    }
    out = concat(out, type_html(r.type, resolve))
  }
  return out
}

// the parameters and the result described: name, type, text
local func items_html(d, resolve){
  local info = d.info
  if(info == null or info.signature == null){
    return ""
  }
  local rows = {}
  for(let local p in values(info.signature.params)){
    local text = info.items[p.name]
    if(text != null){
      append(rows, concat(
        "<dt><code>", escape(p.name), "</code></dt><dd>",
        prose_html(text, resolve), "</dd>"
      ))
    }
  }
  local r = info.signature.result
  if(r != null){
    local text = r.name != null and info.items[r.name] or r.text
    if(text != null){
      append(rows, concat(
        "<dt>returns",
        r.name != null and concat(" <code>", escape(r.name), "</code>") or "",
        "</dt><dd>", prose_html(text, resolve), "</dd>"
      ))
    }
  }
  if(len(rows) == 0){
    return ""
  }
  return concat("<dl class=\"params\">", str.join(rows, ""), "</dl>")
}

local func entry_html(m, d){
  local names = {}
  if(d.info != null and d.info.signature != null){
    for(let local p in values(d.info.signature.params)){
      names[p.name] = true
    }
    if(d.info.signature.result != null and d.info.signature.result.name != null){
      names[d.info.signature.result.name] = true
    }
  }
  local resolve = resolver(m, names)
  local out = {
    concat(
      "<div class=\"def\" id=\"", escape(d.name), "\"><h3><code>",
      signature_html(d, resolve), "</code></h3>"
    ),
  }
  local prose = d.doc
  if(d.info != null){
    prose = d.info.prose
  }
  if(prose != null){
    append(out, blocks_html(prose, resolve))
  } else if(d.doc == null){
    append(out, "<p class=\"muted\">No description.</p>")
  }
  append(out, items_html(d, resolve))
  append(out, "</div>")
  return str.join(out, "\n")
}

// a declared type: its definition and what its fields are
local func type_html_section(m, sec){
  local out = {}
  local t = sec.decl
  local resolve = resolver(m, null)
  if(t != null and t.type != null){
    append(out, concat(
      "<pre><code>type ", escape(sec.type_name), " = ",
      type_html(t.type, resolve), "</code></pre>"
    ))
  }
  if(t != null and t.info != null){
    if(t.info.prose != null){
      append(out, blocks_html(t.info.prose, resolve))
    }
    local rows = {}
    if(t.type != null and t.type.kind == "shape"){
      for(let local f in values(t.type.fields)){
        local text = t.info.items[f.name]
        append(rows, concat(
          "<dt><code>", escape(f.name), f.optional and "?" or "", ": ",
          type_html(f.type, resolve), "</code></dt><dd>",
          text != null and prose_html(text, resolve) or "", "</dd>"
        ))
      }
    }
    if(len(rows) > 0){
      append(out, concat("<dl class=\"params\">", str.join(rows, ""), "</dl>"))
    }
  }
  return str.join(out, "\n")
}

// module_body(m: ModulePage) -> string
// The module's documentation as HTML, without the page around it (for a
// site with a layout of its own): its title, doc, table of contents and
// entries.
func doc.module_body(m){
  local body = {concat("<h1>", escape(m.name), "</h1>")}
  if(m.doc != null){
    append(body, blocks_html(m.doc, resolver(m, null)))
  }
  append(body, "<ul class=\"toc\">")
  for(let local s in values(m.sections)){
    if(s.type_name != null){
      append(body, concat(
        "<li><a href=\"#type-", escape(s.type_name), "\"><code>type ",
        escape(s.type_name), "</code></a></li>"
      ))
    }
    for(let local d in values(s.defs)){
      append(body, concat(
        "<li><a href=\"#", escape(d.name), "\"><code>", escape(d.name),
        "</code></a></li>"
      ))
    }
  }
  append(body, "</ul>")
  for(let local s in values(m.sections)){
    if(s.type_name != null){
      append(body, concat(
        "<h2 id=\"type-", escape(s.type_name), "\">", escape(s.title), "</h2>"
      ))
      append(body, type_html_section(m, s))
    } else if(s.title != null){
      append(body, concat("<h2>", escape(s.title), "</h2>"))
    }
    for(let local d in values(s.defs)){
      append(body, entry_html(m, d))
    }
  }
  append(body, concat("<p class=\"muted\">", escape(m.path), "</p>"))
  return str.join(body, "\n")
}

// module_html(m: ModulePage) -> string: the module's page, as HTML
func doc.module_html(m){
  return page(m.name, concat(
    "<nav><a href=\"index.html\">index</a></nav>\n",
    doc.module_body(m),
  ))
}

// index_body(modules: {ModulePage}, title: string) -> string
// The index as HTML without the page around it: each module, linked to
// its page, with the first sentence of its doc.
func doc.index_body(modules, title){
  local body = {concat("<h1>", escape(title), "</h1>")}
  local func list(kind){
    local rows = {}
    for(let local m in values(modules)){
      if((m.kind == "extension") == (kind == "extension")){
        append(rows, concat(
          "<dt><a href=\"", page_name(m.name), "\"><code>", escape(m.name),
          "</code></a></dt><dd>", prose_html(summary(m.doc)), "</dd>"
        ))
      }
    }
    return rows
  }
  local mods = list("module")
  local exts = list("extension")
  if(len(mods) > 0){
    append(body, concat("<dl>", str.join(mods, "\n"), "</dl>"))
  }
  if(len(exts) > 0){
    append(body, "<h2>Extensions</h2>")
    append(body, concat("<dl>", str.join(exts, "\n"), "</dl>"))
  }
  return str.join(body, "\n")
}

// index_html(modules: {ModulePage}, title: string) -> string
// The index page: each module with the first sentence of its doc.
func doc.index_html(modules, title){
  return page(title, doc.index_body(modules, title))
}

// page_name(module: string) -> string
// The file of a module's page: slang/http is slang-http.html.
doc.page_name = page_name

// blocks_html(text: string) -> string
// Doc text as HTML: paragraphs with `code` spans, and lines indented by two
// spaces or more as code samples.
func doc.blocks_html(text){
  return blocks_html(text, null)
}

// ------------------------------------------------------------ extensions
//
// An extension (a file that changes the grammar it is loaded into) gets a
// page of its own: what its doc says (what it is for and means), the
// syntax it adds as EBNF, worked out from the grammar it leaves behind (or
// written by hand after a `Syntax:` line), the words it reserves, the
// extensions it loads, and its examples (the doc's code samples) next to
// what they expand to.

// The documentation of an extension, as [extension] gathers it.
// type ExtensionPage = {name: string, path: string, doc?: string,
//   blocks: {ExtensionBlock}, syntax: {SyntaxRule}, hand_syntax?: string,
//   keywords: {string}, uses: {string}, examples: {Example}, error?: string,
//   kind: string}
// [name]: what `extension "name"` takes
// [doc]: the doc's first paragraph, its summary
// [blocks]: the rest of the doc in order, its code samples as examples
// [hand_syntax]: the EBNF written after `Syntax:`, shown instead of syntax
// [keywords]: the words it reserves: no longer usable as variable names
// [uses]: the other extensions it loads
// [error]: why the extension could not be loaded to find its syntax
// [kind]: "extension"

// A production of the syntax an extension adds.
// type SyntaxRule = {rule: string, ebnf: string, note?: string}
// [rule]: what it extends: statement, expr, or a rule's name
// [note]: how it fits: a new rule, a changed one, an operator's precedence

// A piece of an extension's doc after its summary.
// type ExtensionBlock = {kind: string, text?: string, example?: Example}
// [kind]: "prose" (text) or "example"

// An example of an extension and what it expands to.
// type Example = {code: string, expanded?: string}
// [expanded]: the example in core slang (slang expand), null when it fails

// the EBNF of a parser: {text, prec}, prec 0 for a choice, 1 for a
// sequence, 2 for what needs no parentheses
local ebnf_of = null

local func ebnf_at(p, ctx, level){
  local r = ebnf_of(p, ctx)
  if(r.text != "" and r.prec < level){
    return concat("(", r.text, ")")
  }
  return r.text
}

// control characters written as escapes
local func visible(s){
  return str.replace(
    str.replace(str.replace(s, "\n", "\\n"), "\t", "\\t"), "\r", "\\r"
  )
}

local func quote(s){
  s = visible(s)
  if(str.index_of(s, "\"") >= 0){
    return concat("'", s, "'")
  }
  return concat("\"", s, "\"")
}

local TRANSPARENT = {
  map: true,
  pick: true,
  tag: true,
  where: true,
  token: true,
  memo: true,
  layer: true,
  trim: true,
}

ebnf_of = func(p, ctx){
  if(p == null){
    return {text: "", prec: 2}
  }
  local named = ctx.names[p]
  if(named != null){
    return {text: named, prec: 2}
  }
  if(ctx.visiting[p]){
    // a parser that contains itself: what it is written for, by name, or a
    // production of its own below
    if(ctx.visiting[p] == "top"){
      return {text: ctx.top, prec: 2}
    }
    if(ctx.cycles[p] == null){
      ctx.count = ctx.count + 1
      ctx.cycles[p] = ctx.count == 1 and "nested" or concat("nested", ctx.count)
      append(ctx.cycle_order, p)
    }
    return {text: ctx.cycles[p], prec: 2}
  }
  if(ctx.cycles[p] != null){
    return {text: ctx.cycles[p], prec: 2}
  }
  local k = p.kind
  local kids = p.children or {}
  if(k == "string"){
    return {text: quote(p.literal), prec: 2}
  }
  if(k == "pattern"){
    return {text: concat("[", visible(p.spec), "]"), prec: 2}
  }
  if(k == "rule"){
    return {text: p.rule_name, prec: 2}
  }
  if(k == "any"){
    return {text: "⟨any character⟩", prec: 2}
  }
  // lookaheads and whitespace leave nothing to write
  if(k == "forbid" or k == "and" or k == "whitespace"){
    return {text: "", prec: 2}
  }
  ctx.visiting[p] = ctx.tops[p] and "top" or true
  local out = null
  if(k == "seq"){
    local parts = {}
    local only = null
    local i = 0
    for(i < len(kids)){
      local c = kids[i]
      local t = ebnf_at(c, ctx, 1)
      // forbid(x) any: one character that does not start x
      if(c.kind == "forbid" and i + 1 < len(kids) and kids[i + 1].kind == "any"){
        t = concat("⟨any character but ", ebnf_at(c.children[0], ctx, 2), "⟩")
        i = i + 1
      }
      if(t != ""){
        append(parts, t)
        only = c
      }
      i = i + 1
    }
    if(len(parts) == 1 and only.kind != "forbid"){
      out = ebnf_of(only, ctx)
    } else if(len(parts) == 1){
      out = {text: parts[0], prec: 2}
    } else {
      out = {text: str.join(parts, " "), prec: 1}
    }
  } else if(k == "choice"){
    local parts = {}
    for(let local c in values(kids)){
      local t = ebnf_at(c, ctx, 0)
      append(parts, t == "" and "ε" or t)
    }
    out = {text: str.join(parts, " | "), prec: len(parts) > 1 and 0 or 2}
  } else if(k == "star_lazy" and kids[0] != null and kids[0].kind == "any" and
    kids[1] != null){
    // any character up to the terminator
    out = {
      text: concat("⟨any character but ", ebnf_at(kids[1], ctx, 2), "⟩*"),
      prec: 2,
    }
  } else if(k == "star" or k == "star_lazy" or k == "plus" or k == "optional"){
    local inner = ebnf_at(kids[0], ctx, 2)
    local mark = k == "plus" and "+" or (k == "optional" and "?" or "*")
    out = {text: inner == "" and "" or concat(inner, mark), prec: 2}
  } else if(k == "separated"){
    local item = ebnf_at(kids[0], ctx, 2)
    local sep = ebnf_at(kids[1], ctx, 1)
    local list = concat(item, " (", sep, " ", item, ")*")
    out = p.at_least_one and {text: list, prec: 1} or
      {text: concat("(", list, ")?"), prec: 2}
  } else if(k == "ref"){
    local a = (p.ref_args or {})[0]
    if(type(a) == "string"){
      out = {text: quote(a), prec: 2}
    } else if(peg.is_parser(a)){
      out = ebnf_of(a, ctx)
    } else {
      out = {text: "⟨token⟩", prec: 2}
    }
  } else if(k == "flatten"){
    // a token's name is its failure message less "expected"
    local label = p.message
    if(label != null){
      label = str.replace(str.replace(label, "Expected: ", ""), " expected", "")
    }
    out = label != null and {text: concat("⟨", label, "⟩"), prec: 2} or
      ebnf_of(kids[0], ctx)
  } else if(k == "settable"){
    out = ebnf_of(p.target, ctx)
  } else if(k == "neg"){
    out = {
      text: concat("⟨any character but ", ebnf_at(kids[0], ctx, 2), "⟩"),
      prec: 2,
    }
  } else if(TRANSPARENT[k] or len(kids) == 1){
    out = ebnf_of(kids[0], ctx)
  } else {
    out = {text: concat("⟨", k, "⟩"), prec: 2}
  }
  ctx.visiting[p] = null
  return out
}

// ebnf(parser: peg.Parser, names?: {[any]: string}, top?: string) -> string
// A parser written as EBNF (W3C style: "text", [a-z], rule names, a b,
// a | b, x*, x+, x?, ⟨named token⟩). Values, marks and lookaheads leave
// no trace; rules are referred to by name.
// [names]: parsers to write as the given text (a rule's previous parser)
// [top]: what parser is written for (a rule's name): parser inside itself
func doc.ebnf(parser, names, top){
  local ctx = {
    names: names or {},
    visiting: {},
    top: top or "…",
    cycles: {},
    cycle_order: {},
    count: 0,
  }
  // the parser and the wrappers under it that only change values are what
  // top names
  local inner = parser
  ctx.tops = {}
  for(inner != null){
    ctx.tops[inner] = true
    if(inner.kind == "settable"){
      inner = inner.target
    } else if(TRANSPARENT[inner.kind]){
      inner = inner.children[0]
    } else {
      break
    }
  }
  local lines = {ebnf_of(parser, ctx).text}
  // the parsers met inside themselves, each a production of its own
  local done = 0
  for(done < len(ctx.cycle_order)){
    local q = ctx.cycle_order[done]
    local name = ctx.cycles[q]
    ctx.cycles[q] = null
    ctx.tops = {}
    ctx.tops[q] = true
    ctx.top = name
    ctx.visiting = {}
    append(lines, concat(name, " ::= ", ebnf_of(q, ctx).text))
    ctx.cycles[q] = name
    done = done + 1
  }
  return str.join(lines, "\n")
}

local func sorted_keys(t){
  return tbl.sort(tbl.keys(t))
}

local func contains(list, v){
  for(let local x in values(list)){
    if(x == v){
      return true
    }
  }
  return false
}

// the operators of a level the base does not have, as syntax rules
local func level_syntax(level, base_level, where, out){
  local func new_entries(field){
    local old = base_level and base_level[field] or {}
    local fresh = {}
    for(let local e in values(level[field] or {})){
      if(not contains(old, e)){
        append(fresh, e)
      }
    }
    return fresh
  }
  local name = level.name or "an unnamed level"
  for(let local e in values(new_entries("prefixes"))){
    append(out, {
      rule: "expr",
      ebnf: concat(doc.ebnf(e.parser), " expr"),
      note: concat("a prefix operator on level ", name, where),
    })
  }
  for(let local e in values(new_entries("postfixes"))){
    append(out, {
      rule: "expr",
      ebnf: concat("expr ", doc.ebnf(e.parser)),
      note: concat("a postfix operator on level ", name, where),
    })
  }
  for(let local e in values(new_entries("lefts"))){
    append(out, {
      rule: "expr",
      ebnf: concat("expr ", doc.ebnf(e.parser), " expr"),
      note: concat("a left-associative infix operator on level ", name, where),
    })
  }
  for(let local e in values(new_entries("rights"))){
    append(out, {
      rule: "expr",
      ebnf: concat("expr ", doc.ebnf(e.parser), " expr"),
      note: concat("a right-associative infix operator on level ", name, where),
    })
  }
  for(let local e in values(new_entries("wrappers"))){
    append(out, {
      rule: "expr",
      ebnf: concat(doc.ebnf(e.left), " expr ", doc.ebnf(e.right)),
      note: concat("a bracketing operator on level ", name, where),
    })
  }
}

// where a level sits among the others: "tighter than x, looser than y"
local func placement_of(names, i){
  local parts = {}
  if(i > 0 and names[i - 1] != null){
    append(parts, concat("binds looser than ", names[i - 1]))
  }
  if(i + 1 < len(names) and names[i + 1] != null){
    append(parts, concat("tighter than ", names[i + 1]))
  }
  if(len(parts) == 0){
    return ", a new level"
  }
  return concat(", a new level that ", str.join(parts, " and "))
}

// the syntax a grammar has that its base does not: statements, rules,
// expression operators and primaries, keywords
local func grammar_changes(g, base, name){
  local syntax = {}
  for(let local s in values(g.statement_order)){
    if(g.statements[s] != base.statements[s]){
      append(syntax, {
        rule: "statement",
        ebnf: doc.ebnf(g.statements[s], null, "statement"),
        note: base.statements[s] == null and concat("a new statement (", s, ")") or
          concat("replaces the statement ", s),
      })
    }
  }
  for(let local s in values(g.extension_statement_order)){
    if(g.extension_statements[s] != base.extension_statements[s]){
      append(syntax, {
        rule: "extension_statement",
        ebnf: doc.ebnf(g.extension_statements[s], null, "extension_statement"),
        note: concat(
          "a statement only at the top level of a file, which changes the ",
          "grammar for the statements after it (",
          s,
          ")",
        ),
      })
    }
  }
  for(let local r in values(g:rules())){
    local before = base.rule_table[r.name]
    local entry = g.rule_table[r.name]
    if(before == null or entry.parser != before.parser or
      len(entry.wrappers) != len(before.wrappers)){
      if(before == null){
        append(syntax, {
          rule: r.name,
          ebnf: entry.parser != null and doc.ebnf(entry.parser, null, r.name) or
            "⟨built when the grammar is sealed⟩",
          note: "a new rule, for other rules and extensions to use",
        })
      } else if(entry.parser != before.parser and entry.parser != null){
        local names = {}
        names[before.parser] = concat("⟨", r.name, " as before⟩")
        append(syntax, {
          rule: r.name,
          ebnf: doc.ebnf(entry.parser, names, r.name),
          note: concat("changes the rule ", r.name),
        })
      } else {
        append(syntax, {
          rule: r.name,
          ebnf: concat("⟨", r.name, " as before, wrapped when sealed⟩"),
          note: concat(
            "changes the rule ", r.name, " (its parser is built late)"
          ),
        })
      }
    }
  }
  local w = g.expression_walker
  local bw = base.expression_walker
  local base_levels = {}
  for(let local l in values(bw.levels)){
    if(l.name != null){
      base_levels[l.name] = l
    }
  }
  local names = w:level_names()
  for(local i = 0; i < len(w.levels); i = i + 1){
    local l = w.levels[i]
    local old = l.name != null and base_levels[l.name] or null
    level_syntax(l, old, old == null and placement_of(names, i) or "", syntax)
  }
  local base_primaries = {}
  for(let local p in values(bw.primaries)){
    base_primaries[p.parser] = true
  }
  for(let local p in values(w.primaries)){
    if(not base_primaries[p.parser]){
      append(syntax, {
        rule: "expr",
        ebnf: doc.ebnf(p.parser, null, "expr"),
        note: concat(
          "a new kind of expression",
          p.name and concat(" (", p.name, ")") or "",
        ),
      })
    }
  }
  local keywords = {}
  for(let local k in values(sorted_keys(g.keywords))){
    if(not base.keywords[k]){
      append(keywords, k)
    }
  }
  local uses = {}
  for(let local e in values(g.loaded_extensions)){
    if(e != name and not contains(base.loaded_extensions, e)){
      append(uses, e)
    }
  }
  return {syntax: syntax, keywords: keywords, uses: uses}
}

// extension(name: string, path: string, index: symbols.Index) -> ExtensionPage
// An extension's documentation: its doc (from index), and what loading it
// into a fresh grammar shows (see compiler.extension_grammar). Its code
// samples are its examples, expanded with the extension.
func doc.extension(name, path, index){
  local compiler = require("slang/compiler")
  local ext = {
    kind: "extension",
    name: name,
    path: path,
    doc: null,
    blocks: {},
    syntax: {},
    keywords: {},
    uses: {},
    examples: {},
  }
  // the doc: its first paragraph is the summary; then prose and examples
  // (its code samples) in order; a code sample after a paragraph that is
  // just `Syntax:` is the hand-written syntax
  local blocks = symbols.doc_blocks(index.module_doc)
  for(local i = 0; i < len(blocks); i = i + 1){
    local b = blocks[i]
    local next = blocks[i + 1]
    if(b.kind == "code"){
      local ex = {code: b.text}
      append(ext.examples, ex)
      append(ext.blocks, {kind: "example", example: ex})
    } else if(str.trim(b.text) == "Syntax:" and next != null and
      next.kind == "code"){
      ext.hand_syntax = next.text
      i = i + 1
    } else if(ext.doc == null){
      ext.doc = b.text
    } else {
      append(ext.blocks, {kind: "prose", text: b.text})
    }
  }
  local r = pcall(compiler.extension_grammar, name)
  if(r[0] == "err"){
    local e = r[1]
    ext.error = type(e) == "table" and e.message or string(e)
  } else {
    local changes = grammar_changes(r[1].grammar, r[1].base, name)
    ext.syntax = changes.syntax
    ext.keywords = changes.keywords
    ext.uses = changes.uses
  }
  for(let local ex in values(ext.examples)){
    compiler.reset()
    local x = pcall(
      compiler.expand,
      concat("extension \"", name, "\"\n", ex.code),
      "example.slang",
    )
    if(x[0] == "ok"){
      ex.expanded = str.trim(x[1])
    }
  }
  return ext
}

// whether a file is an extension: it changes the grammar it gets from
// slang/compiler and returns no module
local func is_extension(source, index){
  return index != null and index.returned == null and
    str.index_of(source, "grammar()") >= 0 and
    str.index_of(source, "slang/compiler") >= 0
}
doc.is_extension = is_extension

// example_html(ex: Example) -> string
// An example as HTML: a <figure class="example"> with the code and, in a
// <details>, what it expands to.
func doc.example_html(ex){
  local parts = {
    "<figure class=\"example\">",
    concat("<pre><code>", escape(ex.code), "</code></pre>"),
  }
  if(ex.expanded != null){
    append(parts, concat(
      "<details class=\"expanded\"><summary>Expanded</summary><pre><code>",
      escape(ex.expanded),
      "</code></pre></details>",
    ))
  }
  append(parts, "</figure>")
  return str.join(parts, "")
}

// extension_body(ext: ExtensionPage, example?: func(ex: Example): string)
//   -> string
// The extension's documentation as HTML without the page around it: its
// summary, how to load it, its syntax, the words it reserves and the
// extensions it loads, then the rest of its doc with the examples where
// the doc has them.
// [example]: writes an example ([example_html] by default)
func doc.extension_body(ext, example){
  example = example or doc.example_html
  local resolve = func(name){ return null }
  local out = {concat("<h1>", escape(ext.name), "</h1>")}
  if(ext.doc != null){
    append(out, concat(
      "<p class=\"summary\">",
      prose_html(ext.doc, resolve),
      "</p>",
    ))
  }
  append(out, concat(
    "<p class=\"use\">Load it at the top of a file with <code>extension \"",
    escape(ext.name),
    "\"</code>, or for every file of a project in ",
    "<code>slang.project</code>: <code>extensions: {\"",
    escape(ext.name),
    "\"}</code>. It changes the grammar of the files that load it only.</p>",
  ))
  append(out, "<h2 id=\"syntax\">Syntax</h2>")
  if(ext.hand_syntax != null){
    append(out, concat(
      "<pre class=\"ebnf\"><code>",
      escape(ext.hand_syntax),
      "</code></pre>",
    ))
  } else if(ext.error != null){
    append(out, concat(
      "<p class=\"muted\">Not worked out: the extension did not load here (",
      escape(ext.error),
      ").</p>",
    ))
  } else if(len(ext.syntax) == 0){
    append(out, "<p class=\"muted\">It adds no syntax.</p>")
  } else {
    local rows = {}
    for(let local r in values(ext.syntax)){
      append(rows, concat(
        "<dt><pre class=\"ebnf\"><code>",
        escape(r.rule),
        " ::= ",
        escape(r.ebnf),
        "</code></pre></dt><dd>",
        escape(r.note or ""),
        "</dd>",
      ))
    }
    append(out, concat("<dl class=\"syntax\">", str.join(rows, ""), "</dl>"))
  }
  if(len(ext.keywords) > 0){
    local words = {}
    for(let local k in values(ext.keywords)){
      append(words, concat("<code>", escape(k), "</code>"))
    }
    append(out, concat(
      "<p><strong>Reserved words:</strong> ",
      str.join(words, ", "),
      ". In a file that loads it they can no longer name variables; fields ",
      "may still use them (<code>t.",
      escape(ext.keywords[0]),
      "</code>).</p>",
    ))
  }
  if(len(ext.uses) > 0){
    local names = {}
    for(let local u in values(ext.uses)){
      append(names, concat(
        "<a href=\"",
        page_name(u),
        "\"><code>",
        escape(u),
        "</code></a>",
      ))
    }
    append(out, concat(
      "<p><strong>Loads:</strong> ",
      str.join(names, ", "),
      "</p>",
    ))
  }
  if(len(ext.blocks) > 0){
    append(out, "<h2 id=\"use\">How it works</h2>")
    for(let local b in values(ext.blocks)){
      if(b.kind == "example"){
        append(out, example(b.example))
      } else {
        append(out, blocks_html(b.text, resolve))
      }
    }
  }
  append(out, concat("<p class=\"muted\">", escape(ext.path), "</p>"))
  return str.join(out, "\n")
}

// extension_html(ext: ExtensionPage) -> string: the extension's page
func doc.extension_html(ext){
  return page(ext.name, concat(
    "<nav><a href=\"index.html\">index</a></nav>\n",
    doc.extension_body(ext),
  ))
}

// ------------------------------------------------------------ the command

local func slang_files(path, out){
  if(os.is_dir(path)){
    local names = os.list_dir(path)
    for(let local name in values(names)){
      if(not str.starts_with(name, ".")){
        slang_files(concat(path, "/", name), out)
      }
    }
  } else if(str.ends_with(path, ".slang")){
    append(out, path)
  }
}

// the module name of a file: slang/x for slang's own library, else the
// path relative to the working directory without .slang
local func module_name(compiler, path){
  local abs = compiler.absolute_path(path)
  for(let local dir in values(__PACKAGES.library_sources or {})){
    local d = concat(compiler.absolute_path(dir), "/")
    if(str.starts_with(abs, d)){
      return concat("slang/", str.substring(abs, len(d), len(abs) - 6))
    }
  }
  // a stub: the native module it declares
  for(let local dir in values(__PACKAGES.stub_sources or {})){
    local d = concat(compiler.absolute_path(dir), "/")
    if(str.starts_with(abs, d)){
      return str.substring(abs, len(d), len(abs) - 6)
    }
  }
  // in a package (the project's own name included): name/x, name for its
  // init, and the stubs of its native modules (stubs/x is name/x)
  for(let local pkg in values(compiler.packages())){
    local d = concat(pkg.dir or "", "/")
    if(pkg.dir != null and str.starts_with(abs, d)){
      local rel = str.substring(abs, len(d), len(abs) - 6)
      if(str.starts_with(rel, "stubs/")){
        rel = str.substring(rel, 6)
      }
      if(rel == "init"){
        return pkg.name
      }
      return concat(pkg.name, "/", rel)
    }
  }
  local cwd = concat(compiler.absolute_path("."), "/")
  if(str.starts_with(abs, cwd)){
    abs = str.substring(abs, len(cwd))
  }
  return str.substring(abs, 0, len(abs) - 6)
}

// a path as it is shown: relative to the working directory when inside it
local func shown_path(compiler, path){
  local abs = compiler.absolute_path(path)
  local cwd = concat(compiler.absolute_path("."), "/")
  if(str.starts_with(abs, cwd)){
    return str.substring(abs, len(cwd))
  }
  return abs
}

local func by_name(list){
  // insertion sort: a few dozen modules
  local out = {}
  for(let local m in values(list)){
    local i = len(out)
    append(out, m)
    for(i > 0 and str.compare(out[i - 1].name, m.name) > 0){
      out[i] = out[i - 1]
      i = i - 1
    }
    out[i] = m
  }
  return out
}

// main(arguments: {string}) -> int: the exit code
// `slang doc [-o dir] [file|dir...]`: documents the .slang files found.
// A file that does not parse is reported and the exit code is 1.
func doc.main(arguments){
  local compiler = require("slang/compiler")
  local out_dir = "doc"
  local paths = {}
  local i = 0
  for(i < len(arguments)){
    local a = arguments[i]
    if(a == "-o" and i + 1 < len(arguments)){
      out_dir = arguments[i + 1]
      i = i + 2
    } else if(str.starts_with(a, "-")){
      os.write_stderr("usage: slang doc [-o dir] [file|dir...]\n")
      return 2
    } else {
      append(paths, a)
      i = i + 1
    }
  }
  local title = "slang"
  if(len(paths) == 0){
    if(os.exists("slang.project")){
      append(paths, ".")
      title = compiler.absolute_path(".")
    } else {
      for(let local dir in values(__PACKAGES.library_sources or {})){
        if(os.is_dir(dir)){
          append(paths, dir)
        }
      }
      // the native modules and the globals, from their stubs
      for(let local dir in values(__PACKAGES.stub_sources or {})){
        if(os.is_dir(dir)){
          append(paths, dir)
          break
        }
      }
      title = "slang's library"
    }
  }
  local r = doc.collect(paths)
  local modules = r.modules
  os.mkdir_all(out_dir)
  for(let local m in values(modules)){
    os.write_file(
      concat(out_dir, "/", page_name(m.name)),
      m.kind == "extension" and doc.extension_html(m) or doc.module_html(m),
    )
  }
  os.write_file(concat(out_dir, "/index.html"), doc.index_html(modules, title))
  print(len(modules), " modules documented in ", out_dir, "/index.html\n")
  return r.status
}

// collect(paths: {string}) -> {modules: {ModulePage}, status: int}
// The modules of the .slang files in paths (files, or directories searched
// all the way down), sorted by name. A file that does not parse is
// reported on stderr and makes status 1.
func doc.collect(paths){
  local compiler = require("slang/compiler")
  local files = {}
  for(let local p in values(paths)){
    slang_files(p, files)
  }
  local modules = {}
  local status = 0
  for(let local path in values(files)){
    compiler.reset()
    local text = os.read_file(path)
    local r = pcall(compiler.highlight, text, path, {
      find_project: true, symbols: true
    })
    if(r[0] == "err"){
      local e = r[1]
      os.write_stderr(concat(
        path, ": ", type(e) == "table" and e.message or e, "\n"
      ))
      status = 1
    } else {
      local name = module_name(compiler, path)
      local m = null
      if(is_extension(text, r[1].symbols)){
        m = doc.extension(name, shown_path(compiler, path), r[1].symbols)
      } else {
        m = doc.module(name, shown_path(compiler, path), text, r[1].symbols)
      }
      if(m != null){
        append(modules, m)
      }
    }
  }
  return {modules: by_name(modules), status: status}
}

return doc
