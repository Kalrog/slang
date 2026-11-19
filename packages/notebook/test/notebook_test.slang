// the notebook package: the file format, what values show as, Markdown,
// the kernel and its client, a whole run and the export, and a notebook's
// session with a kernel that is somewhere else (the browser's part itself
// is test/web_test.mjs)
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
local json = require("slang/json")
local session = require("notebook/session")
local remote = require("notebook/remote")
local browser = require("notebook/browser")

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

t.group("settings"){
  t.test("a notebook says what runs it on its first line"){
    local text = "<!-- slang-notebook kernel: wasm -->\n\n# T\n\n```slang\n1\n```\n"
    assert(document.settings(text).kernel == "wasm")
    assert(document.settings("# T\n").kernel == null)
    assert(document.settings("<!-- slang-notebook kernel: nope -->\n").kernel == null)
    // the line is no cell, and the cells' lines are the file's
    local cells = document.parse(text)
    assert(len(cells) == 2 and cells[0].source == "# T")
    assert(cells[1].line == 5, string(cells[1].line))
    assert(document.format(cells, {kernel: "wasm"}) == text)
    assert(document.layout(cells, {kernel: "wasm"})[1] == 5)
    assert(document.format(cells) == "# T\n\n```slang\n1\n```\n")
    assert(document.layout(cells)[1] == 3)
    // a comment that is not the first thing is text
    assert(document.settings("# T\n\n<!-- slang-notebook kernel: wasm -->\n").kernel == null)
  }
  t.test("a notebook from text, and its sidecar as text"){
    local doc = document.from_text("<!-- slang-notebook kernel: process -->\n\n```slang\n1\n```\n")
    assert(doc.settings.kernel == "process" and len(doc.cells) == 1)
    assert(document.outputs_text(doc.cells) == null)
    doc.cells[0].outputs = {{type: "result", data: {["text/plain"]: "1"}}}
    doc.cells[0].count = 1
    local side = document.outputs_text(doc.cells)
    local back = document.from_text("```slang\n1\n```\n", side)
    assert(back.cells[0].outputs[0].data["text/plain"] == "1" and back.settings.kernel == null)
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
    local code = nb.code("local s = \"```\"\n")
    assert(code.data["text/plain"] == "local s = \"```\"")
    assert(str.starts_with(code.data["text/markdown"], "````slang\nlocal s"))
    assert(nb.image("\x89PNG....").data["image/png"] != null)
    t.raises(func(){ nb.image("no picture") })
  }
  t.test("an image from its pixels is a PNG, with zlib or without"){
    local zlib = require("slang/zlib")
    local hash = require("slang/hash")
    local func color(x, y){
      if(y == 0){
        return x / 2          // greys: 0, 0.5, 1
      }
      return {x - 1, 2, "no"}   // clamped; what is no number is 0
    }
    // the parts of a PNG: {name, data}, their checksums checked
    local func chunks(png){
      assert(str.substring(png, 0, 8) == "\x89PNG\r\n\x1a\n")
      local out = {}
      local at = 8
      for(at < len(png)){
        local size = (str.byte_at(png, at) << 24) | (str.byte_at(png, at + 1) << 16) |
          (str.byte_at(png, at + 2) << 8) | str.byte_at(png, at + 3)
        local body = str.substring(png, at + 4, at + 8 + size)
        local sum = str.substring(png, at + 8 + size, at + 12 + size)
        local crc = hash.crc32(body)
        assert(sum == str.from_bytes({(crc >> 24) & 255, (crc >> 16) & 255, (crc >> 8) & 255, crc & 255}))
        append(out, {name: str.substring(body, 0, 4), data: str.substring(body, 4)})
        at = at + 12 + size
      }
      return out
    }
    local want = concat(
      "\x00", "\x00\x00\x00", "\x80\x80\x80", "\xff\xff\xff",
      "\x00", "\x00\xff\x00", "\x00\xff\x00", "\xff\xff\x00",
    )
    for(let local options in values({{}, {compress: false}})){
      local shown = nb.pixels(3, 2, color, options)
      assert(shown.data["text/plain"] == "<image, 3 x 2>")
      local parts = chunks(encoding.base64.decode(shown.data["image/png"]))
      assert(len(parts) == 3 and parts[0].name == "IHDR" and parts[2].name == "IEND")
      assert(parts[0].data == "\x00\x00\x00\x03\x00\x00\x00\x02\x08\x02\x00\x00\x00")
      // (inflate checks the stream's own checksum too)
      assert(zlib.inflate(parts[1].data, {format: "zlib"}) == want)
      if(options.compress == false){
        assert(len(parts[1].data) == len(want) + 2 + 5 + 4, "stored as it is")
      }
    }
    // more than one stored block
    local big = nb.pixels(200, 150, func(x, y){ return (x ~ y) % 7 / 6 }, {compress: false})
    local raw = zlib.inflate(chunks(encoding.base64.decode(big.data["image/png"]))[1].data, {format: "zlib"})
    assert(len(raw) == 150 * (1 + 200 * 3))
    local kind = null
    try {
      nb.pixels(0, 4, color)
    } catch(local e) {
      kind = e.kind
    }
    assert(kind == error.kinds.argument)
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

// a host as a test has it: what the session sends is kept, timers fire
// when asked, and the kernel is a notebook/remote whose page is the test
local func fake_host(text){
  local h = {
    name: "notes.md", kernels: {"process", "wasm"}, sent: {}, ops: {},
    timers: {}, saved: null, started: {}
  }
  func h.read(){
    return document.from_text(text)
  }
  func h.write(cells, settings){
    h.saved = document.format(cells, settings)
  }
  func h.send(page, message){
    append(h.sent, message)
  }
  func h.broadcast(message, except){
    append(h.sent, message)
  }
  func h.start_kernel(kind, on_event, page){
    append(h.started, kind)
    h.kernel = remote.new(func(op){ append(h.ops, op) }, on_event)
    h.kernel.start({target: "/work/notes.md"})
    return h.kernel
  }
  func h.later(ms, f){
    local timer = {f: f}
    append(h.timers, timer)
    return {cancel: func(){ timer.f = null }}
  }
  func h.fire(){
    local timers = h.timers
    h.timers = {}
    for(let local timer in values(timers)){
      if(timer.f != null){
        timer.f()
      }
    }
  }
  // the events of a kind sent since the last call
  func h.take(kind){
    local out = {}
    for(let local m in values(h.sent)){
      if(m.event == kind){
        append(out, m)
      }
    }
    h.sent = {}
    return out
  }
  return h
}

t.group("a session and a kernel somewhere else"){
  t.test("cells wait their turn, events become outputs, the notebook is saved"){
    local h = fake_host("# T\n\n```slang\n1\n```\n\n```slang\n2\n```\n")
    local nb = session.new(h)
    local snap = session.snapshot(nb)
    assert(snap.kind == "process" and len(snap.kinds) == 2 and snap.kernel == "none")
    assert(len(snap.cells) == 3 and snap.cells[1].spans[0][2] == "number")
    local a = snap.cells[1].id
    local b = snap.cells[2].id
    session.on_message(nb, "page", {op: "run", ids: {a, b}})
    assert(h.started[0] == "process" and h.ops[0].op == "start")
    // one cell at a time: the second waits for the first to be done
    assert(len(h.ops) == 2 and h.ops[1].op == "execute" and h.ops[1].id == a)
    assert(h.ops[1].origin == "notes.md" and h.ops[1].line == 3)
    assert(session.kernel_status(nb) == "starting")
    h.kernel.receive({event: "ready", project: "/work/slang.project"})
    assert(session.kernel_status(nb) == "busy" and nb.project == "/work/slang.project")
    h.kernel.receive({event: "start", id: a})
    h.kernel.receive({event: "stream", name: "stdout", text: "hi\n"})
    h.kernel.receive({event: "result", id: a, data: {["text/markdown"]: "**b**", ["text/plain"]: "b"}})
    h.kernel.receive({event: "done", id: a, status: "ok", ms: 2})
    assert(nb.cells[1].outputs[0].text == "hi\n" and nb.cells[1].count == 1)
    assert(len(h.ops) == 3 and h.ops[2].id == b and h.ops[2].line == 7)
    // what a page gets of Markdown is rendered
    local shown = null
    for(let local m in values(h.take("cell"))){
      if(m.e.event == "result"){
        shown = m.e.data
      }
    }
    assert(str.index_of(shown["text/html"], "<strong>b</strong>") > 0)
    // an error ends the run; its line is the cell's
    h.kernel.receive({event: "start", id: b})
    h.kernel.receive({event: "error", id: b, error: {
      kind: "type", message: "no", location: {origin: "notes.md", line: 8}
    }})
    h.kernel.receive({event: "done", id: b, status: "error", ms: 1})
    assert(nb.cells[2].outputs[0].error.cell_line == 1)
    assert(session.kernel_status(nb) == "idle" and session.busy(nb))
    h.fire()
    assert(h.saved == nb.text and not session.busy(nb))
    // the variables are asked of the kernel, and answered to the page
    session.on_message(nb, "page", {op: "variables"})
    local asked = h.ops[len(h.ops) - 1]
    assert(asked.op == "variables")
    h.kernel.receive({event: "variables", id: asked.id, variables: {{name: "x", type: "int", text: "1"}}})
    assert(h.take("variables")[0].variables[0].name == "x")
  }
  t.test("the notebook chooses its kernel where there is a choice; a lost kernel ends its cell"){
    local h = fake_host("<!-- slang-notebook kernel: wasm -->\n\n```slang\nfor(true){}\n```\n")
    local nb = session.new(h)
    assert(session.snapshot(nb).kind == "wasm")
    local a = nb.cells[0].id
    session.on_message(nb, "page", {op: "run", ids: {a}})
    assert(h.started[0] == "wasm" and h.ops[1].line == 3)
    h.kernel.receive({event: "ready"})
    h.kernel.receive({event: "start", id: a})
    session.on_message(nb, "page", {op: "interrupt"})
    assert(h.ops[len(h.ops) - 1].op == "interrupt")
    // the page could not: it ended the worker, and says why
    h.take("problem")
    h.kernel.receive({event: "exit", status: 130, reason: "ended by the page"})
    assert(session.kernel_status(nb) == "dead" and nb.cells[0].state == "idle")
    assert(h.take("problem")[0].message == "ended by the page")
    // another kind: the old kernel is ended, the notebook says the new one
    session.on_message(nb, "page", {op: "run", ids: {a}})
    h.kernel.receive({event: "ready"})
    session.on_message(nb, "page", {op: "kernel", kind: "process"})
    assert(h.ops[len(h.ops) - 1].op == "kill" and session.kernel_status(nb) == "none")
    assert(nb.settings.kernel == "process" and nb.cells[0].state == "idle")
    h.fire()
    assert(str.starts_with(h.saved, "<!-- slang-notebook kernel: process -->\n\n```slang"))
    // a kind the host does not have is not taken
    h.kernels = {"process"}
    session.on_message(nb, "page", {op: "kernel", kind: "wasm"})
    assert(nb.settings.kernel == "process")
    // and a notebook that asks for one runs on what there is
    local only = fake_host("<!-- slang-notebook kernel: wasm -->\n\n```slang\n1\n```\n")
    only.kernels = {"process"}
    assert(session.snapshot(session.new(only)).kind == "process")
  }
}

t.group("a notebook's language"){
  t.test("the code cells are one notebook to the language server"){
    local language = require("notebook/language")
    assert(language.available())
    os.mkdir_all(concat(scratch, "/lang"))
    write("lang/slang.project", "{name: \"lang\"}")
    write("lang/util.slang", """// helpers
local util = {}

// greet(name: string) -> string
// A greeting for name.
func util.greet(name){
  return concat("hello ", name)
}

return util
""")
    local l = language.new({path: concat(scratch, "/lang/notes.md")})
    l:sync({
      {id: "a", type: "code", source: "local util = require(\"util\")\nlocal who = \"you\"\nwho"},
      {id: "m", type: "markdown", source: "# text"},
      {id: "b", type: "code", source: "util.greet(who)\nnope(1)"},
    })
    // a cell may end in an expression; a name of a cell is known below it
    local found = l:diagnostics()
    assert(len(found.a) == 0 and len(found.b) == 1)
    assert(found.b[0].severity == "warning" and found.b[0].range[0] == 1)
    assert(str.starts_with(found.b[0].message, "nope is not defined"))
    local h = l:hover("b", {line: 0, character: 6})
    assert(str.index_of(h.markdown, "A greeting for name.") > 0 and h.range[1] == 5)
    // a definition is in a file, or in a cell
    local d = l:definition("b", {line: 0, character: 6})
    assert(str.ends_with(d[0].path, "/lang/util.slang") and d[0].range[0] == 5)
    d = l:definition("b", {line: 0, character: 12})
    assert(d[0].id == "a" and d[0].range[0] == 1 and d[0].range[1] == 6)
    local uses = l:references("a", {line: 1, character: 7})
    assert(len(uses) == 3 and uses[2].id == "b" and uses[2].range[1] == 11)
    local marks = l:occurrences("b", {line: 0, character: 12})
    assert(len(marks) == 3 and marks[0].id == "a" and marks[0].write and
      marks[2].id == "b" and not marks[2].write)
    assert(l:signature("b", {line: 0, character: 11}).label ==
      "greet(name: string) -> string")
    // the cell being typed in is taken as it is
    assert(l:edit("b", "util.\nnope(1)") and not l:edit("zz", ""))
    local items = l:complete("b", {line: 0, character: 5}, ".")
    assert(len(items) == 1 and items[0].label == "greet" and items[0].kind == "function")
    l:edit("b", "print(who)\nlocal = 1")
    found = l:diagnostics()
    assert(found.b[0].severity == "error" and found.b[0].range[0] == 1)
    l:edit("b", "print(who)")
    local renamed = l:rename("a", {line: 1, character: 7}, "whom")
    assert(len(renamed.changes.a) == 2 and renamed.changes.b[0].text == "whom")
    assert(len(renamed.files) == 0)
    assert(l:symbols("a")[1].name == "who")
    assert(l:find("gre")[0].name == "greet")
    // cells come, go and change places
    l:sync({
      {id: "b", type: "code", source: "local   q = {1,2}\nq[0]"},
      {id: "n", type: "code", source: "q"},
    })
    found = l:diagnostics()
    assert(found.a == null and len(found.b) == 0 and len(found.n) == 0)
    assert(l:format("b")[0].text == "local q = {1, 2}\nq[0]")
    assert(l:definition("n", {line: 0, character: 0})[0].id == "b")
    l:close()
  }
  t.test("a session answers a page's questions about its code"){
    local h = fake_host("# T\n\n## Part\n\n```slang\n// doubles a number\nlocal func twice(n){ return n * 2 }\n```\n\n```slang\ntwice(2)\nmissing\n```\n")
    local nb = session.new(h)
    assert(session.snapshot(nb).language == true)
    local a = nb.cells[1].id
    local b = nb.cells[2].id
    session.on_message(nb, "page", {op: "check", seq: 1})
    local found = h.take("diagnostics")[0]
    assert(found.seq == 1 and len(found.cells[a]) == 0)
    assert(str.starts_with(found.cells[b][0].message, "missing is not defined"))
    // a question carries the cell as the page has it
    session.on_message(nb, "page", {
      op: "language", seq: 2, method: "hover", id: b, line: 0, character: 2,
      source: "twice(2)"
    })
    local answer = h.take("language")[0]
    assert(answer.seq == 2 and answer.id == b)
    assert(str.index_of(answer.result.html, "doubles a number") > 0)
    session.on_message(nb, "page", {op: "check", seq: 3})
    assert(len(h.take("diagnostics")[0].cells[b]) == 0)
    session.on_message(nb, "page", {
      op: "language", seq: 4, method: "definition", id: b, line: 0, character: 2
    })
    answer = h.take("language")[0]
    assert(answer.result[0].id == a and answer.result[0].range[0] == 1)
    // the outline: the text's headings and what the code defines
    session.on_message(nb, "page", {op: "language", seq: 5, method: "outline"})
    local outline = h.take("language")[0].result
    assert(outline[0].kind == "heading" and outline[0].name == "T")
    assert(outline[1].level == 2 and outline[2].name == "twice" and outline[2].id == a)
    // what cannot be done is said, not raised
    session.on_message(nb, "page", {
      op: "language", seq: 6, method: "rename", id: b, line: 0, character: 6,
      name: "x"
    })
    assert(h.take("language")[0].error != null)
    // an update is followed by what the code says now
    session.on_message(nb, "page", {op: "update", cells: {
      {id: a, type: "code", source: "local n = 1"},
      {id: b, type: "code", source: "n +"},
    }})
    found = h.take("diagnostics")[0]
    assert(found.cells[b][0].severity == "error")
    session.close(nb)
  }
}

t.group("a notebook in a browser"){
  t.test("the worker's script and the package's files"){
    local source = browser.worker_source()
    assert(str.index_of(source, "async function run(") > 0)
    assert(str.index_of(source, "export ") < 0 and str.index_of(source, "import ") < 0)
    assert(str.index_of(source, "onmessage = ") > 0)
    local files = browser.package_files()
    for(let local name in values({
      "slang.project", "bin/kernel_web.slang", "bin/service_web.slang",
      "runner.slang", "session.slang", "init.slang"
    })){
      assert(files[concat("/pkg/notebook/", name)] != null, name)
    }
    // (a browser has no event loop: nothing in there may need slang/async)
    for(let local e in entries(files)){
      assert(str.index_of(e[1], "require(\"slang/async\")") < 0, e[0])
      assert(str.index_of(e[1], "require(\"uv\")") < 0, e[0])
    }
    local args = browser.kernel_args("/work/a.md")
    assert(args[2] == "/pkg/notebook/bin/kernel_web.slang" and args[3] == "/work/a.md")
    // the session's language is among them; what it asks comes apart
    assert(files["/pkg/notebook/language.slang"] != null)
    local more = browser.language_files()
    assert(more["/lsp/server.slang"] != null and more["/lsp/navigate.slang"] != null)
    assert(str.index_of(more["/pkg/notebook/slang.lock"], "../../lsp") > 0)
    // slang's library to read about, without the compiler's own modules
    assert(more["/slang/lib/json.slang"] != null and more["/slang/lib/grammar.slang"] == null)
    assert(more["/slang/stubs/slang/string.slang"] != null and more["/slang/stubs/globals.slang"] != null)
    // (the library is only read; what runs needs no event loop)
    assert(str.index_of(more["/lsp/server.slang"], "require(\"uv\")") < 0)
    assert(str.index_of(more["/lsp/navigate.slang"], "require(\"uv\")") < 0)
  }
  t.test("a project's files for the worker: the project's folder, without what is hidden or huge"){
    os.mkdir_all(concat(scratch, "/proj/notes/.cache"))
    os.mkdir_all(concat(scratch, "/proj/lib"))
    write("proj/slang.project", "{name: \"proj\"}\n")
    write("proj/lib/util.slang", "return {}\n")
    write("proj/notes/a.md", "# A\n")
    write("proj/notes/a.out.json", "{}")
    write("proj/notes/.cache/x", "hidden")
    write("proj/notes/.env", "SECRET=1")
    write("proj/notes/bytes.bin", "\x00\xff\x01")
    write("proj/big.txt", "x" * (2 * 1024 * 1024 + 1))
    local p = browser.project_files(concat(scratch, "/proj/notes/a.md"))
    assert(p.cwd == "/work/notes" and p.target == "/work/notes/a.md")
    assert(str.ends_with(p.root, "/proj"))
    assert(p.files["/work/slang.project"] != null and p.files["/work/lib/util.slang"] == "return {}\n")
    assert(p.files["/work/notes/a.md"] == "# A\n")
    assert(encoding.base64.decode(p.files["/work/notes/bytes.bin"].b64) == "\x00\xff\x01")
    assert(p.files["/work/notes/.env"] == null and p.files["/work/notes/.cache/x"] == null)
    assert(p.files["/work/notes/a.out.json"] == null)
    assert(p.files["/work/big.txt"] == null and p.left_out == 1)
    // without a project file, the notebook's own folder
    os.remove(concat(scratch, "/proj/slang.project"))
    p = browser.project_files(concat(scratch, "/proj/notes/a.md"))
    assert(p.target == "/work/a.md" and p.files["/work/lib/util.slang"] == null)
    os.remove_all(scratch)
  }
  t.test("the page that needs no server"){
    local nb = document.from_text("# Mine\n\n```slang\nlocal a = \"</script>\"\n```\n")
    nb.path = "mine.md"
    nb.cells[1].outputs = {{type: "result", data: {["text/plain"]: "1"}}}
    local page = export.app(nb, {vm: "../slang.wasm", home: "../"})
    assert(str.starts_with(page, "<!DOCTYPE html>") and str.index_of(page, "<title>Mine</title>") > 0)
    assert(str.index_of(page, "<a class=\"brand\" href=\"../\"") > 0)
    assert(str.index_of(page, "id=\"nb-worker\"") > 0 and str.index_of(page, "id=\"nb-vm\"") < 0)
    // the configuration: the notebook, its outputs, the package's files
    local from = str.index_of(page, "id=\"nb-config\">") + len("id=\"nb-config\">")
    local config_text = str.substring(page, from, str.index_of(page, "</script>", from))
    assert(str.index_of(config_text, "<") < 0, "nothing in it ends the script")
    local config = json.decode(config_text)
    assert(config.vm == "../slang.wasm" and config.notebook.name == "mine.md")
    assert(str.index_of(config.notebook.text, "local a = \"</script>\"") > 0)
    assert(str.index_of(config.notebook.outputs, "\"text/plain\"") > 0)
    assert(config.files["/pkg/notebook/service_web.slang"] != null)
    assert(config.files["/lsp/server.slang"] != null, "the language server is in the page")
    assert(str.starts_with(config.key, "mine.md:"))
    // an empty one
    assert(json.decode(str.substring(
      export.app(null, {vm: "x.wasm"}),
      str.index_of(export.app(null, {vm: "x.wasm"}), "id=\"nb-config\">") + len("id=\"nb-config\">"),
      str.index_of(export.app(null, {vm: "x.wasm"}), "</script>", str.index_of(export.app(null, {vm: "x.wasm"}), "id=\"nb-config\">")),
    )).notebook == null)
  }
}
