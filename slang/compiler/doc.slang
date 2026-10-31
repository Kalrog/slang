// slang/doc: API documentation from the comments the code already has, as
// HTML: `slang doc [-o dir] [file|dir...]`.
//
// A module is a file that returns a table; its documentation is the comment
// block that starts the file and, for every field of the returned table, the
// comment just above its definition (no blank line between). Section
// dividers (`// ---- title`) group the fields. In a comment, lines indented
// by two or more spaces are code samples; the rest is prose. A file that
// returns no table is documented by its globals that have a comment (the
// stub of the globals); others (programs, tests) are left out.
//
// Native modules and the globals are documented from their stubs (see
// compiler.stub_path), and every type a module defines (a meta table with
// __index and __type) gets a section of its methods. Without paths: the
// project in the working directory (a slang.project there), else slang's
// own library with the stubs. Output goes to dir (./doc by default):
// index.html and a page per module.
local str = require("slang/string")
local os = require("slang/os")
local symbols = require("slang/symbols")

local doc = {}

// ------------------------------------------------------------ html

local func escape(s){
  s = str.replace(s, "&", "&amp;")
  s = str.replace(s, "<", "&lt;")
  s = str.replace(s, ">", "&gt;")
  return str.replace(s, "\"", "&quot;")
}

local func is_ref_byte(b){
  return (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or
    (b >= 97 and b <= 122) or b == 95 or b == 46 or b == 58
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

// a module's documentation: {name, path, doc, sections: {title, defs}}
// or null when the file returns no table
// an entry of a page: {name (the anchor), signature, doc, start}
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

// the types a file defines: those its doc comments declare (`type Name =
// {...}` with its fields, `type Name` above the table of its methods), and
// a table with __index and __type, the meta of a type whose methods are the
// fields of the __index table; one section per type
local func type_sections(index){
  local out = {}
  local declared_tables = {}
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
      sec.defs = methods_of(index, t.table, name)
    }
    append(out, sec)
  }
  for(let local d in values(index.defs)){
    local fields = d.fields or {}
    local t = fields.__type
    local methods = fields.__index
    if(d.kind != "field" and t != null and methods != null and
      t.value != null and t.value.type == "String" and methods.value != null and
      methods.value.type == "Identifier" and methods.value.token != null){
      local r = index.by_start[methods.value.token.start]
      local table = r
      if(r != null and r.kind == null){
        table = r.def
      }
      if(table != null and table.fields != null and
        declared_tables[table] == null){
        local type_name = t.value.value
        local list = methods_of(index, table, type_name)
        if(len(list) > 0){
          append(out, {
            title: concat("type ", type_name), type_name: type_name, defs: list
          })
        }
      }
    }
  }
  return out
}

// a module's documentation: {name, path, doc, sections: {title, defs}}:
// the fields of the table the file returns (or, in a file that returns
// none, its documented globals), by section, then its types; null when
// there is nothing to document
func doc.module(name, path, source, index){
  if(index == null){
    return null
  }
  local listed = {}
  for(let local d in values(index.defs)){
    if(index.returned != null){
      if(index.exports[d.name] == d){
        append(listed, entry(d))
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
  local links = {types: {}, exports: {}, aliases: {}}
  for(let local sec in values(types)){
    links.types[sec.type_name] = true
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
      // Type.method of this module
      if(links.types[head]){
        return concat("#", head, ":", rest)
      }
      local module = links.aliases[head]
      if(module != null){
        local b = str.byte_at(rest, 0)
        local anchor = (b >= 65 and b <= 90) and concat("type-", rest) or rest
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

func doc.module_html(m){
  local body = {
    "<nav><a href=\"index.html\">index</a></nav>",
    concat("<h1>", escape(m.name), "</h1>"),
  }
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
  return page(m.name, str.join(body, "\n"))
}

func doc.index_html(modules, title){
  local body = {concat("<h1>", escape(title), "</h1>"), "<dl>"}
  for(let local m in values(modules)){
    append(body, concat(
      "<dt><a href=\"", page_name(m.name), "\"><code>", escape(m.name),
      "</code></a></dt><dd>", prose_html(summary(m.doc)), "</dd>"
    ))
  }
  append(body, "</dl>")
  return page(title, str.join(body, "\n"))
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
  for(let local dir in values(__PACKAGES.librarySources or {})){
    local d = concat(compiler.absolute_path(dir), "/")
    if(str.starts_with(abs, d)){
      return concat("slang/", str.substring(abs, len(d), len(abs) - 6))
    }
  }
  // a stub: the native module it declares
  for(let local dir in values(__PACKAGES.stubSources or {})){
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

// main(args) -> exit code: `slang doc [-o dir] [file|dir...]`
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
      for(let local dir in values(__PACKAGES.librarySources or {})){
        if(os.is_dir(dir)){
          append(paths, dir)
        }
      }
      // the native modules and the globals, from their stubs
      for(let local dir in values(__PACKAGES.stubSources or {})){
        if(os.is_dir(dir)){
          append(paths, dir)
          break
        }
      }
      title = "slang's library"
    }
  }
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
      local m = doc.module(
        module_name(compiler, path),
        shown_path(compiler, path),
        text,
        r[1].symbols,
      )
      if(m != null){
        append(modules, m)
      }
    }
  }
  modules = by_name(modules)
  os.mkdir_all(out_dir)
  for(let local m in values(modules)){
    os.write_file(concat(out_dir, "/", page_name(m.name)), doc.module_html(m))
  }
  os.write_file(concat(out_dir, "/index.html"), doc.index_html(modules, title))
  print(len(modules), " modules documented in ", out_dir, "/index.html\n")
  return status
}

return doc
