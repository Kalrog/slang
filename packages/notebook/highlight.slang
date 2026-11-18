extension "extensions/html"
// notebook/highlight: a cell's code coloured by slang's own parser, under
// the project of the notebook, so that the syntax of the project's
// extensions is coloured as it is parsed.
//
//   local highlight = require("notebook/highlight")
//   highlight.html("local x = 1", "notes.md")
//   // <span class="t-keyword">local</span> x ...
local html = require("slang/html")
local str = require("slang/string")
local compiler = require("slang/compiler")
local regex = require("slang/regex")

local highlight = {}

local non_ascii = regex.compile("[\\x80-\\xff]")

// tokens(source: string, path?: string) -> {{start: int, stop: int, kind: string}}
// The tokens of a cell's code in order, not overlapping: kind is
// "keyword", "string", "number", "comment", "function", ... Code that
// does not parse is coloured as far as it does. Offsets are in bytes.
// [path]: the notebook's file: its project's grammar is used
func highlight.tokens(source, path){
  compiler.workspace()
  local file = concat(path or "notebook.md", ".slang")
  local h = try {
    compiler.for_file(file, func(){
      return compiler.highlight(source, file, {result: true})
    })
  } catch { null }
  local out = {}
  if(h == null){
    return out
  }
  local pos = 0
  for(let local tk in values(h.tokens)){
    if(tk.start >= pos and tk.stop > tk.start){
      append(out, {
        start: tk.start, stop: tk.stop, kind: str.split(tk.category, ".")[0]
      })
      pos = tk.stop
    }
  }
  return out
}

// spans(source: string, path?: string) -> {{int | string}}
// [tokens] for a page's script: {start, stop, kind} lists whose offsets
// count UTF-16 units, as JavaScript's strings do.
func highlight.spans(source, path){
  local list = highlight.tokens(source, path)
  local out = {}
  if(non_ascii:find(source) == null){
    for(let local t in values(list)){
      append(out, {t.start, t.stop, t.kind})
    }
    return out
  }
  // bytes to UTF-16 units, in one pass
  local at = 0
  local units = 0
  local func advance(to){
    for(at < to){
      local b = str.byte_at(source, at)
      if(b < 128 or b >= 192){
        units = units + 1
        if(b >= 240){
          units = units + 1
        }
      }
      at = at + 1
    }
    return units
  }
  for(let local t in values(list)){
    local a = advance(t.start)
    append(out, {a, advance(t.stop), t.kind})
  }
  return out
}

// html(source: string, path?: string) -> string
// The code as HTML: escaped, each token in a span of class t-<kind>.
func highlight.html(source, path){
  local parts = {}
  local pos = 0
  for(let local t in values(highlight.tokens(source, path))){
    append(parts, html.value(str.substring(source, pos, t.start)))
    append(parts, <span class={concat("t-", t.kind)}>
      {str.substring(source, t.start, t.stop)}
    </span>)
    pos = t.stop
  }
  append(parts, html.value(str.substring(source, pos)))
  return html.render(html.fragment(parts))
}

return highlight
