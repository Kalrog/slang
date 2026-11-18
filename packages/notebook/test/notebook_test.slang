// the notebook package: the file format, what values show as, Markdown,
// the kernel and its client, a whole run and the export
local t = require("slang/test")
local str = require("slang/string")
local os = require("slang/os")
local time = require("slang/time")
local tbl = require("slang/table")
local async = require("slang/async")
local encoding = require("slang/encoding")
local html = require("slang/html")
local nb = require("notebook")
local document = require("notebook/document")
local inspect = require("notebook/inspect")
local markdown = require("notebook/markdown")
local highlight = require("notebook/highlight")
local protocol = require("notebook/protocol")
local client = require("notebook/client")
local run = require("notebook/run")
local export = require("notebook/export")

local scratch = concat(
  os.getenv("TMPDIR") or "/tmp/", "/slang-notebook-test-",
  string(to_int(time.now()))
)

local func write(path, text){
  os.write_file(concat(scratch, "/", path), text)
}

local TEXT = """# Title

Some text.

```slang
local x = 1
x
```

```sh
echo "```slang is text here"
```

more

<!-- cell -->

second

~~~slang extra
print("a")
~~~
"""

t.group("document"){
  t.test("Markdown to cells and back"){
    local cells = document.parse(TEXT)
    assert(len(cells) == 5)
    assert(cells[0].type == "markdown" and cells[0].source == "# Title\n\nSome text.")
    assert(cells[1].type == "code" and cells[1].source == "local x = 1\nx")
    assert(cells[1].line == 5, "the code starts after five lines")
    assert(str.index_of(cells[2].source, "echo") > 0, "other languages are text")
    assert(cells[3].source == "second")
    assert(cells[4].info == "slang extra" and cells[4].source == "print(\"a\")")
    local text = document.format(cells)
    local again = document.parse(text)
    assert(len(again) == 5 and document.format(again) == text)
    assert(document.title(cells) == "Title")
    // the layout says where the cells are in that text
    local layout = document.layout(cells)
    local lines = str.split(text, "\n")
    assert(lines[layout[1]] == "local x = 1" and lines[layout[4]] == "print(\"a\")")
    assert(lines[layout[3]] == "second")
  }
  t.test("code that holds a fence gets a longer one; empty text is left out"){
    local cells = {
      {type: "markdown", source: "  \n"},
      {type: "code", source: "local s = \"\"\"\n```\n\"\"\""},
      {type: "code", source: ""},
    }
    local text = document.format(cells)
    assert(str.starts_with(text, "````slang\n"), text)
    local again = document.parse(text)
    assert(len(again) == 2 and again[0].source == cells[1].source)
    assert(again[1].source == "")
    assert(document.layout(cells)[0] == -1)
  }
  t.test("events become outputs"){
    local cell = {type: "code", source: "x"}
    document.apply(cell, {event: "start"})
    document.apply(cell, {event: "stream", name: "stdout", text: "a"})
    document.apply(cell, {event: "stream", name: "stdout", text: "b\n"})
    document.apply(cell, {event: "stream", name: "stderr", text: "e"})
    document.apply(cell, {event: "result", data: {["text/plain"]: "1"}})
    document.apply(cell, {event: "done", ms: 3})
    assert(len(cell.outputs) == 3 and cell.outputs[0].text == "ab\n")
    assert(cell.outputs[1].name == "stderr" and cell.outputs[2].type == "result")
    assert(cell.ms == 3)
    document.apply(cell, {event: "clear"})
    assert(len(cell.outputs) == 0)
  }
  t.test("the sidecar keeps outputs by the cell's source"){
    os.mkdir_all(scratch)
    local path = concat(scratch, "/notes.md")
    local cells = document.parse("```slang\n1\n```\n\n```slang\n2\n```\n")
    cells[0].outputs = {{type: "result", data: {["text/plain"]: "1"}}}
    cells[0].count = 1
    cells[1].outputs = {{type: "stream", name: "stdout", text: "two\n"}}
    document.write(path, cells)
    assert(document.sidecar_path(path) == concat(scratch, "/notes.out.json"))
    assert(os.exists(document.sidecar_path(path)))
    // moved and edited by hand: the outputs follow the code that is the same
    os.write_file(path, "```slang\n2\n```\n\ntext\n\n```slang\n1 + 0\n```\n")
    local back = document.read(path).cells
    assert(back[0].outputs[0].text == "two\n")
    assert(back[2].outputs == null, "an edited cell has none")
    // nothing to keep: no sidecar
    document.write(path, document.parse("```slang\n2\n```\n"))
    assert(not os.exists(document.sidecar_path(path)))
    os.remove_all(scratch)
  }
}

t.group("values"){
  t.test("text: lists, records, strings, types, itself"){
    assert(inspect.text({1, 2.5, "a\"b\n"}) == "{1, 2.5, \"a\\\"b\\n\"}")
    assert(inspect.text({x: 1, ["a b"]: true}) == "{x: 1, [\"a b\"]: true}")
    assert(inspect.text({1, name: "n"}) == "{1, name: \"n\"}")
    assert(inspect.text("s") == "\"s\"" and inspect.text(null) == "null")
    local typed = {v: 1}
    typed.@meta = {__type: "Point"}
    assert(inspect.text(typed) == "Point {v: 1}")
    local shown = {}
    shown.@meta = {__tostring: func(self){ return "as it says" }}
    assert(inspect.text(shown) == "as it says")
    local loop = {}
    loop.me = loop
    assert(inspect.text(loop) == "{me: {<itself>}}")
    local long = {}
    for(local i = 0; i < 30; i = i + 1){
      append(long, "a fairly long string")
    }
    local text = inspect.text(long)
    assert(str.starts_with(text, "{\n  \"a fairly long string\",\n"), text)
    assert(inspect.text({{{{{1}}}}}, {depth: 2}) == "{{{...}}}")
    assert(str.ends_with(inspect.text(long, {items: 2, width: 200}), "... 28 more}"))
  }
  t.test("tree: plain data, cut where it grows"){
    local tree = inspect.tree({1, {a: "x"}, name: "n"})
    assert(tree.t == "table" and tree.n == 3 and len(tree.items) == 3)
    assert(tree.items[0].k == null and tree.items[0].v.v == "1")
    assert(tree.items[1].v.items[0].k == "a" and tree.items[1].v.items[0].v.t == "string")
    assert(tree.items[2].k == "name")
    local many = {}
    for(local i = 0; i < 300; i = i + 1){
      append(many, i)
    }
    local cut = inspect.tree(many)
    assert(len(cut.items) == 200 and cut.more == 100)
  }
  t.test("what a value shows as"){
    assert(nb.bundle(3)["text/plain"] == "3")
    local data = nb.bundle({1, 2})
    assert(data["text/plain"] == "{1, 2}")
    assert(data["application/vnd.slang.value+json"].n == 2)
    assert(nb.bundle(nb.html("<b>x</b>"))["text/html"] == "<b>x</b>")
    assert(nb.bundle(html.element("i", null, {"y"}))["text/html"] == "<i>y</i>")
    local own = {rows: {{1, 2}}}
    own.@meta = {__display: func(self){ return nb.table(self.rows) }}
    assert(str.index_of(nb.bundle(own)["text/html"], "<td class=\"num\">1</td>") > 0)
  }
  t.test("tables, plots, sound, images"){
    local table = nb.table({{name: "a<", n: 1}, {name: "b", n: 2}}, {limit: 1})
    local markup = table.data["text/html"]
    assert(str.index_of(markup, "<th>name</th><th>n</th>") > 0, markup)
    assert(str.index_of(markup, "<td>a&lt;</td>") > 0 and str.index_of(markup, "1 more rows") > 0)
    assert(table.data["text/plain"] == "name\tn\na<\t1\n... 1 more rows")
    local plot = nb.plot({{y: {1, 4, 9}, label: "sq"}, {y: {2, 1, 3}, kind: "bar"}}, {
      title: "t & u"
    })
    local svg = plot.data["image/svg+xml"]
    assert(str.starts_with(svg, "<svg ") and str.index_of(svg, "<polyline") > 0)
    assert(str.count(svg, "<rect") == 4, "three bars and the legend's mark")
    assert(str.index_of(svg, "t &amp; u") > 0 and plot.data["text/plain"] == "<plot: t & u>")
    local big = {}
    for(local i = 0; i < 4000; i = i + 1){
      append(big, i % 50)
    }
    assert(str.index_of(nb.plot(big).data["image/svg+xml"], "<path") > 0)
    local wav = encoding.base64.decode(nb.audio({0, 1, -1, 0.5}, {rate: 8000}).data["audio/wav"])
    assert(str.starts_with(wav, "RIFF") and len(wav) == 44 + 8)
    assert(str.byte_at(wav, 46) == 255 and str.byte_at(wav, 47) == 127, "1.0 is 32767")
    assert(nb.image("\x89PNG....").data["image/png"] != null)
    t.raises(func(){ nb.image("no picture") })
  }
  t.test("outside a notebook, display prints; a sink takes it"){
    local got = {}
    nb.attach(func(kind, data){ append(got, {kind, data}) })
    nb.display(1, nb.markdown("*m*"))
    nb.clear()
    nb.attach(null)
    assert(len(got) == 3 and got[0][1]["text/plain"] == "1")
    assert(got[1][1]["text/markdown"] == "*m*" and got[2][0] == "clear")
    assert(not nb.in_notebook())
  }
}

t.group("markdown"){
  t.test("blocks and inline marks"){
    local out = markdown.render("# A *b*\n\ntext `c<d` and [l](http://x \"t\") ~~no~~ a_b_c\n")
    assert(str.index_of(out, "<h1 id=\"a-b\">A <em>b</em></h1>") == 0, out)
    assert(str.index_of(out, "<code>c&lt;d</code>") > 0)
    assert(str.index_of(out, "<a href=\"http://x\" title=\"t\">l</a>") > 0)
    assert(str.index_of(out, "<del>no</del> a_b_c") > 0)
    local list = markdown.render("- one\n- two\n  - [x] in\n\n1. a\n2. b\n")
    assert(str.index_of(list, "<ul>\n<li>one</li>\n<li>two\n<ul>") == 0, list)
    assert(str.index_of(list, "class=\"task\"") > 0 and str.index_of(list, "<ol>") > 0)
    local table = markdown.render("| a | b |\n|---|--:|\n| 1 | 2 |\n")
    assert(str.index_of(table, "<td style=\"text-align:right\">2</td>") > 0, table)
    assert(markdown.render("> q\n\n---\n") == "<blockquote>\n<p>q</p>\n</blockquote>\n<hr>\n")
    assert(markdown.render("<div>\n*raw*\n</div>\n") == "<div>\n*raw*\n</div>\n")
  }
  t.test("code blocks, highlighted when asked"){
    local out = markdown.render("```slang\nlocal x\n```\n", {
      highlight: func(code, language){ return highlight.html(code) }
    })
    assert(str.index_of(out, "<span class=\"t-keyword\">local</span>") > 0, out)
    assert(markdown.render("```\na < b\n```\n") == "<pre><code>a &lt; b\n</code></pre>\n")
  }
  t.test("highlighting takes a cell's trailing expression, and counts as a page does"){
    local spans = highlight.spans("local s = \"\u{e9}\"\ns", "n.md")
    assert(spans[0][2] == "keyword" and spans[0][1] == 5)
    // the string is 3 characters for a page, 4 bytes for us
    local found = false
    for(let local span in values(spans)){
      if(span[2] == "string"){
        found = span[1] - span[0] == 3
      }
    }
    assert(found)
  }
}

t.group("protocol"){
  t.test("frames come out of the stream whole, however it is cut"){
    local wire = concat(
      "printed ", protocol.frame("tok", {event: "start", id: "a"}), "more\n",
      protocol.frame("other", {event: "fake"}),
      protocol.frame("tok", {event: "done", id: "a"}), "end"
    )
    for(let local size in values({1, 3, 7, 1000})){
      local texts = {}
      local events = {}
      local p = protocol.parser(
        "tok", func(s){ append(texts, s) }, func(e){ append(events, e.event) },
      )
      for(local i = 0; i < len(wire); i = i + size){
        local stop = i + size
        if(stop > len(wire)){
          stop = len(wire)
        }
        p.feed(str.substring(wire, i, stop))
      }
      p.finish()
      assert(str.join(events, ",") == "start,done", str.join(events, ","))
      local text = str.join(texts, "")
      assert(str.starts_with(text, "printed more\n") and str.ends_with(text, "end"))
      assert(str.index_of(text, "fake") > 0, "another kernel's frame is text")
    }
  }
}

// a kernel, with what it said: {k, events, by(kind)}
local func start(path){
  local events = {}
  local k = client.start({
    path: path, on_event: func(e){ append(events, e) }
  })
  local func by(kind, id){
    local out = {}
    for(let local e in values(events)){
      if(e.event == kind and (id == null or e.id == id)){
        append(out, e)
      }
    }
    return out
  }
  return {k: k, events: events, by: by}
}

t.group("kernel"){
  t.test("cells share a session; values, printing and errors are events"){
    os.mkdir_all(scratch)
    async.main(func(){
      local s = start(scratch)
      local k = s.k
      local ready = async.await(k.ready)
      assert(ready.project == null and k.status == "idle")
      local r = async.await(k:execute("local n = 20\nprint(\"hi\\n\")\nn + 1", {id: "a"}))
      assert(r.status == "ok")
      assert(s.by("result", "a")[0].data["text/plain"] == "21")
      assert(s.by("stream", "a")[0].text == "hi\n")
      r = async.await(k:execute("n = n * 2\nrequire(\"notebook\").display(n, {1})", {
        id: "b"
      }))
      local shown = s.by("display", "b")
      assert(len(shown) == 2 and shown[0].data["text/plain"] == "40")
      assert(shown[1].data["application/vnd.slang.value+json"].n == 1)
      // an error has its place in the notebook's file
      r = async.await(k:execute("local t = null\nt.x = 1", {
        id: "c", origin: "notes.md", line: 30
      }))
      assert(r.status == "error")
      local e = s.by("error", "c")[0].error
      assert(e.kind == "type" and e.location.origin == "notes.md" and e.location.line == 32)
      assert(str.index_of(e.stack, "notebook/kernel") < 0, "the kernel's frames are cut")
      r = async.await(k:execute("local = 1", {id: "d"}))
      assert(r.status == "error" and s.by("error", "d")[0].error.kind == "syntax")
      // the session's locals
      local names = {}
      for(let local v in values(async.await(k:variables()))){
        append(names, concat(v.name, "=", v.text))
      }
      assert(str.join(names, " ") == "n=40 t=null", str.join(names, " "))
      async.await(k:shutdown())
      assert(k.status == "dead" and len(s.by("exit")) == 1)
    })
    os.remove_all(scratch)
  }
  t.test("an interrupt stops a busy cell and leaves a waiting one behind"){
    os.mkdir_all(scratch)
    async.main(func(){
      local s = start(scratch)
      local k = s.k
      async.await(k.ready)
      local busy = k:execute("local spins = 0\nfor(true){ spins = spins + 1 }", {id: "a"})
      async.await(async.sleep(250))
      assert(k.status == "busy")
      k:interrupt()
      assert(async.await(busy).status == "interrupted")
      assert(s.by("error", "a")[0].error.kind == "interrupted")
      local waiting = k:execute(
        "local async = require(\"slang/async\")\nasync.await(async.sleep(60000))",
        {id: "b"},
      )
      async.await(async.sleep(250))
      k:interrupt()
      assert(async.await(waiting).status == "interrupted")
      // the kernel and its state are still there
      local after = async.await(k:execute("spins > 100", {id: "c"}))
      assert(after.status == "ok" and s.by("result", "c")[0].data["text/plain"] == "true")
      k:kill()
      async.await(k.exit)
      assert(async.await(k:execute("1", {id: "d"})).status == "dead")
    })
    os.remove_all(scratch)
  }
}

t.group("a notebook in a project"){
  t.test("run: the project's packages, files and extensions; then the export"){
    os.mkdir_all(concat(scratch, "/proj/dep"))
    write("proj/dep/slang.project", "{name: \"dep\"}\n")
    write("proj/dep/init.slang", "return {answer: 42}\n")
    write("proj/helper.slang", "return {double: |x| x * 2}\n")
    write(
      "proj/lambda.slang", os.read_file("../../extensions/lambda_shorthand.slang"),
    )
    write(
      "proj/slang.project",
      "{name: \"proj\", extensions: {\"lambda\"}, dependencies: {dep: {path: \"dep\"}}}\n",
    )
    write("proj/slang.lock", "{[\"dep\"]: {path: \"dep\"}}\n")
    write("proj/notes.md", concat(
      "# Notes\n\n```slang\nlocal dep = require(\"dep\")\n",
      "local add = |x| x + 1\nadd(dep.answer) + require(\"helper\").double(1)\n```\n\n",
      "Then *text*.\n\n```slang\nprint(\"printed\\n\")\n",
      "require(\"notebook\").table({{a: 1}})\n```\n\n",
      "```slang\nlocal t = null\nt.x = 1\n```\n\n```slang\n\"not reached\"\n```\n",
    ))
    local path = concat(scratch, "/proj/notes.md")
    local seen = {}
    local r = async.main(func(){
      return async.await(run.file(path, {
        save: true, on_event: func(e, cell, index){
          if(e.event == "start"){
            append(seen, index)
          }
        }
      }))
    })
    assert(r.ran == 3 and r.failed == 1, "the run stops at the failing cell")
    assert(str.join(tbl.map(seen, string), ",") == "1,3,4")
    assert(str.ends_with(r.project, "/proj/slang.project"))
    assert(r.cells[1].outputs[0].data["text/plain"] == "45")
    assert(r.cells[3].outputs[0].text == "printed\n")
    local e = r.cells[4].outputs[0].error
    // (the file's own line: the cell starts on line 17)
    assert(e.location.line == 18, string(e.location.line))
    assert(r.cells[5].outputs == null)
    // saved: reading the notebook gives the outputs back
    local back = document.read(path)
    assert(back.cells[1].outputs[0].data["text/plain"] == "45" and back.cells[1].count == 1)
    local page = export.html(back)
    assert(str.starts_with(page, "<!DOCTYPE html>") and str.index_of(page, "<title>Notes</title>") > 0)
    assert(str.index_of(page, "<h1 id=\"notes\">Notes</h1>") > 0)
    assert(str.index_of(page, "<span class=\"t-keyword\">local</span>") > 0)
    assert(str.index_of(page, "<pre class=\"nb-stdout\">printed\n</pre>") > 0)
    assert(str.index_of(page, "<table class=\"nb-table\">") > 0)
    assert(str.index_of(page, "class=\"nb-error\"") > 0)
    assert(str.index_of(export.html(back, {code: false}), "<span class=\"t-keyword\"") < 0)
    os.remove_all(scratch)
  }
}
