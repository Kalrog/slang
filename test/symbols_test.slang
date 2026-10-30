// slang/symbols: names resolved as codegen resolves them, fields, modules,
// doc comments; and slang/doc's pages built from them
local t = require("slang/test")
local str = require("slang/string")
local compiler = require("slang/compiler")
local symbols = require("slang/symbols")
local doc = require("slang/doc")

local func analyse(source){
  return compiler.highlight(source, "snippet.slang", {symbols: true}).symbols
}

local func word_char(source, i){
  if(i < 0 or i >= len(source)){
    return false
  }
  local c = str.char_at(source, i)
  return c == "_" or str.upper(c) != str.lower(c) or
    (str.byte_at(source, i) >= 48 and str.byte_at(source, i) <= 57)
}

// the def or ref at the nth occurrence of word as a whole name (the cursor
// on its first letter)
local func at(source, index, word, nth){
  local i = - 1
  local k = 0
  for(true){
    i = str.index_of(source, word, i + 1)
    if(i < 0){
      return null
    }
    if(not word_char(source, i - 1) and not word_char(source, i + len(word))){
      if(k == (nth or 0)){
        return symbols.at(index, i)
      }
      k = k + 1
    }
  }
}

local func text_of(source, d){
  return str.substring(source, d.start, d.stop)
}

t.group("symbols"){
  t.test("locals, shadowing, upvalues and parameters"){
    local src = "local a = 1\nlocal func f(b, ...rest){\n  local a = b\n  return func(){ return a + b + rest }\n}\nprint(a, f)\n"
    local ix = analyse(src)
    local outer = at(src, ix, "a")
    local inner = at(src, ix, "a", 1)
    assert(outer.kind == "local" and inner.kind == "local" and outer != inner)
    // in the closure: the inner a (an upvalue) and the parameter b
    assert(at(src, ix, "a", 2).def == inner)
    assert(at(src, ix, "b", 2).def.kind == "parameter")
    assert(at(src, ix, "a", 3).def == outer)
    local rest = at(src, ix, "rest")
    assert(rest.kind == "parameter" and text_of(src, rest) == "rest")
    assert(at(src, ix, "rest", 1).def == rest)
    local f = at(src, ix, "f")
    assert(symbols.signature(f) == "f(b, ...rest)", symbols.signature(f))
    assert(at(src, ix, "print").def == null, "print is a global")
  }
  t.test("fields, the module table, require and doc comments"){
    local src = """// a module
// in two lines
local http = require("slang/http")
local m = {k: 1}

// add(x, y) -> the sum
func m.add(x, y){ return x + y }
local func helper(){ return 2 }
m.helper = helper
print(m:add(1, 2), m.k, http.fetch)
return m"""
    local ix = analyse(src)
    assert(ix.module_doc == "a module\nin two lines", ix.module_doc)
    local http = at(src, ix, "http")
    assert(http.module == "slang/http" and http.doc == null)
    local add = ix.exports.add
    assert(add.kind == "field" and add.doc == "add(x, y) -> the sum")
    assert(symbols.signature(add) == "m.add(x, y)")
    assert(at(src, ix, "add", 2).def == add, "m:add resolves")
    assert(at(src, ix, "k", 1).def == ix.exports.k, "a table literal's field")
    assert(ix.exports.helper.params != null, "an alias has its target's params")
    local fetch = at(src, ix, "fetch")
    assert(fetch.def == null and fetch.owner == http, "a field of a module")
  }
  t.test("globals, and a file that stops compiling half way"){
    local src = "count = 1\ncount = count + 1\nlocal x = 1\nlocal x = 2\nlocal y = x"
    local ix = analyse(src)
    local g = ix.globals.count
    assert(g.kind == "global" and g.start == 0)
    assert(
      at(src, ix, "count", 2).def == null and
        at(src, ix, "count", 2).name == "count"
    )
    // `local x` twice is a compile error: the names before it are kept
    assert(at(src, ix, "x").kind == "local")
    assert(at(src, ix, "y") == null)
  }
  t.test("names an extension builds keep their place: html components"){
    local src = "extension \"extensions/html\"\nlocal ui = {}\nfunc ui.Card(props){ return <p>hi</p> }\nprint(<ui.Card />)\n"
    local ix = analyse(src)
    local card = at(src, ix, "Card", 1)
    assert(card != null and card.def == ix.defs[1], "Card resolves")
    assert(str.substring(src, card.start, card.stop) == "Card")
    assert(at(src, ix, "ui", 2).def == ix.defs[0], "ui is the local")
  }
  t.test("doc comments split into prose and code"){
    local blocks = symbols.doc_blocks(
      "Some prose\non two lines.\n\n  local x = 1\n\n  print(x)\nMore."
    )
    assert(len(blocks) == 3)
    assert(
      blocks[0].kind == "text" and blocks[0].text == "Some prose on two lines."
    )
    assert(
      blocks[1].kind == "code" and blocks[1].text == "local x = 1\n\nprint(x)"
    )
    assert(blocks[2].text == "More.")
    assert(symbols.doc_above("x\n// a\n\n// b\n// c\ny", 18) == "b\nc")
  }
}

t.group("slang doc"){
  t.test("a module's page has its exports by section, with their docs"){
    local src = """// tiny: a module
local m = {}

// ------------------------------------------------------------ first

// one() -> `1`
func m.one(){ return 1 }
local func hidden(){ return 0 }

// ------------------------------------------------------------ second

func m.two(a){ return a }
return m"""
    local ix = analyse(src)
    local mod = doc.module("tiny", "tiny.slang", src, ix)
    assert(len(mod.sections) == 2 and mod.sections[0].title == "first")
    assert(mod.sections[1].defs[0].name == "two")
    local html = doc.module_html(mod)
    assert(str.index_of(html, "<h3><code>m.one()</code></h3>") >= 0)
    assert(str.index_of(html, "<p>one() -&gt; <code>1</code></p>") >= 0)
    assert(str.index_of(html, "hidden") < 0, "only exports")
    assert(doc.module("x", "x.slang", "print(1)", analyse("print(1)")) == null)
  }
  t.test("types get a section of their methods; globals document a file"){
    local src = """// shapes: a module with a type
local m = {}
local box_methods = {}
local box_meta = {__index: box_methods, __type: "Box"}

// box(w) -> a Box
func m.box(w){ return {meta: box_meta, w: w} }

// area(b) -> the area
func box_methods.area(b, scale){ return b.w * scale }
return m"""
    local mod = doc.module("shapes", "shapes.slang", src, analyse(src))
    local last = mod.sections[len(mod.sections) - 1]
    assert(
      last.title == "type Box" and last.defs[0].signature == "Box:area(scale)"
    )
    local html = doc.module_html(mod)
    assert(str.index_of(html, "id=\"Box:area\"") >= 0)
    local g = "// globals: here\n\n// shout(s) -> s, loud\nfunc shout(s){}\n"
    local gm = doc.module("globals", "g.slang", g, analyse(g))
    assert(gm.sections[0].defs[0].signature == "shout(s)")
  }
}
