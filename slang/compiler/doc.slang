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

// prose with `code` spans
local func prose_html(text){
  local parts = str.split(escape(text), "`")
  if(len(parts) % 2 == 0){
    // an unpaired backquote: the text as it is
    return escape(text)
  }
  local out = {}
  for(local i = 0; i < len(parts); i = i + 1){
    if(i % 2 == 1){
      append(out, concat("<code>", parts[i], "</code>"))
    } else {
      append(out, parts[i])
    }
  }
  return str.join(out, "")
}

local func blocks_html(text){
  local out = {}
  for(let local b in values(symbols.doc_blocks(text))){
    if(b.kind == "code"){
      append(out, concat("<pre><code>", escape(b.text), "</code></pre>"))
    } else {
      append(out, concat("<p>", prose_html(b.text), "</p>"))
    }
  }
  return str.join(out, "\n")
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
    start: d.start,
  }
}

// the types a file defines: a table with __index and __type is the meta of
// a type whose methods are the fields of the __index table; one section
// per type, its methods as "type:name(params)" (without self)
local func type_sections(index){
  local out = {}
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
      if(table != null and table.fields != null){
        local type_name = t.value.value
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
            append(list, e)
          }
        }
        if(len(list) > 0){
          append(out, {title: concat("type ", type_name), defs: list})
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
  return {name: name, path: path, doc: index.module_doc, sections: kept}
}

func doc.module_html(m){
  local body = {
    "<nav><a href=\"index.html\">index</a></nav>",
    concat("<h1>", escape(m.name), "</h1>"),
  }
  if(m.doc != null){
    append(body, blocks_html(m.doc))
  }
  append(body, "<ul class=\"toc\">")
  for(let local s in values(m.sections)){
    for(let local d in values(s.defs)){
      append(body, concat(
        "<li><a href=\"#", escape(d.name), "\"><code>", escape(d.name),
        "</code></a></li>"
      ))
    }
  }
  append(body, "</ul>")
  for(let local s in values(m.sections)){
    if(s.title != null){
      append(body, concat("<h2>", escape(s.title), "</h2>"))
    }
    for(let local d in values(s.defs)){
      append(body, concat(
        "<div class=\"def\" id=\"", escape(d.name), "\">", "<h3><code>",
        escape(d.signature), "</code></h3>"
      ))
      if(d.doc != null){
        append(body, blocks_html(d.doc))
      } else {
        append(body, "<p class=\"muted\">No description.</p>")
      }
      append(body, "</div>")
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
      find_project: true, symbols: true,
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
        r[1].symbols
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
