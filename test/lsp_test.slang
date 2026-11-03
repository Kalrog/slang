// the language server's logic, driven in process
local t = require("slang/test")
local str = require("slang/string")
local json = require("slang/json")
local lsp = require("lsp/server")
local os = require("slang/os")
local compiler = require("slang/compiler")

local func request(id, method, params){
  return {jsonrpc: "2.0", id: id, method: method, params: params}
}
local func notify(method, params){
  return {jsonrpc: "2.0", method: method, params: params}
}
local func open_doc(server, uri, text){
  return server:handle(notify("textDocument/didOpen", {
    textDocument: {uri: uri, languageId: "slang", version: 1, text: text},
  }))
}
local func tokens_of(server, uri){
  local r = server:handle(request(2, "textDocument/semanticTokens/full", {
    textDocument: {uri: uri},
  }))
  return r[0].result.data
}

t.group("language server"){
  t.test("framing round trip"){
    local a = lsp.encode({jsonrpc: "2.0", id: 1, method: "x", params: {}})
    local b = lsp.encode({jsonrpc: "2.0", method: "y"})
    local half = str.substring(b, 0, 20)
    local r = lsp.frame(concat(a, half))
    assert(len(r.messages) == 1 and r.messages[0].method == "x")
    assert(r.rest == half)
    r = lsp.frame(concat(r.rest, str.substring(b, 20)))
    assert(len(
      r.messages,
    ) == 1 and r.messages[0].method == "y" and r.rest == "")
  }
  t.test("uris decode"){
    assert(lsp.uri_to_path("file:///a/b%20c/d.slang") == "/a/b c/d.slang")
    // another scheme (the expanded view): the path it names
    assert(lsp.uri_to_path("slang-expanded:/a/d.expanded.slang") ==
      "/a/d.expanded.slang")
  }
  t.test("initialize negotiates the position encoding"){
    local s = lsp.new()
    local r = s:handle(request(1, "initialize", {
      capabilities: {general: {positionEncodings: {"utf-16", "utf-8"}}},
    }))
    local caps = r[0].result.capabilities
    assert(caps.positionEncoding == "utf-8" and caps.textDocumentSync == 1)
    assert(caps.semanticTokensProvider.legend.tokenTypes[0] == "keyword")
    local s2 = lsp.new()
    local r2 = s2:handle(request(1, "initialize", {capabilities: {}}))
    assert(r2[0].result.capabilities.positionEncoding == "utf-16")
  }
  t.test("a document gets tokens and diagnostics"){
    local s = lsp.new()
    s:handle(request(1, "initialize", {capabilities: {}}))
    local replies = open_doc(
      s,
      "file:///tmp/lsp_test/a.slang",
      "local x = 1\n// note\nprint(x)\n",
    )
    assert(replies[0].method == "textDocument/publishDiagnostics" and len(
        replies[0].params.diagnostics,
      ) == 0)
    local data = tokens_of(s, "file:///tmp/lsp_test/a.slang")
    // local(keyword) x(variable) =(punct) 1(number) // note(comment) print(function) ( x )
    assert(
      data[0] == 0 and data[1] == 0 and data[2] == 5 and data[3] == 0,
      "first token: local at 0:0, length 5, keyword",
    )
    assert(
      data[5] == 0 and data[6] == 6 and data[7] == 1 and data[8] == 1,
      "then x at +6, a variable",
    )
    assert(
      data[20] == 1 and data[21] == 0 and data[22] == 7 and data[23] == 4,
      "the comment on the next line",
    )
    assert(
      data[25] == 1 and data[26] == 0 and data[27] == 5 and data[28] == 18,
      "print on line 3, a function",
    )
    // a change that breaks the file
    local changed = s:handle(notify("textDocument/didChange", {
      textDocument: {uri: "file:///tmp/lsp_test/a.slang", version: 2},
      contentChanges: {{text: "local x = 1\nlocal y = = 2\n"}},
    }))
    local diags = changed[0].params.diagnostics
    assert(
      len(diags) >= 1 and diags[0].severity == 1 and diags[0].source == "slang",
      "a diagnostic",
    )
    assert(
      diags[0].range.start.line == 1,
      concat("at line ", diags[0].range.start.line),
    )
    local closed = s:handle(notify("textDocument/didClose", {
      textDocument: {uri: "file:///tmp/lsp_test/a.slang"},
    }))
    assert(len(closed[0].params.diagnostics) == 0)
  }
  t.test("characters count utf-16 units unless utf-8 was negotiated"){
    local text = "local x = \"héllo日本\" // ü\n"
    local s16 = lsp.new()
    s16:handle(request(1, "initialize", {capabilities: {}}))
    open_doc(s16, "file:///tmp/lsp_test/u.slang", text)
    local d16 = tokens_of(s16, "file:///tmp/lsp_test/u.slang")
    local s8 = lsp.new()
    s8:handle(request(1, "initialize", {
      capabilities: {general: {positionEncodings: {"utf-8"}}},
    }))
    open_doc(s8, "file:///tmp/lsp_test/u.slang", text)
    local d8 = tokens_of(s8, "file:///tmp/lsp_test/u.slang")
    // the string: 9 units, 14 bytes; the comment starts 10/15 after it and is 4 units / 5 bytes
    assert(
      d16[17] == 9 and d8[17] == 14,
      concat("string length ", d16[17], " ", d8[17]),
    )
    assert(
      d16[21] == 10 and d8[21] == 15,
      concat("comment start ", d16[21], " ", d8[21]),
    )
    assert(
      d16[22] == 4 and d8[22] == 5,
      concat("comment length ", d16[22], " ", d8[22]),
    )
  }
  t.test("multi-line strings are split per line"){
    local s = lsp.new()
    s:handle(request(1, "initialize", {capabilities: {}}))
    open_doc(
      s,
      "file:///tmp/lsp_test/m.slang",
      "x = \"\"\"ab\ncd\"\"\"\ny = 1\n",
    )
    local data = tokens_of(s, "file:///tmp/lsp_test/m.slang")
    // x = then the string piece on line 0 (5 chars: """ab), the piece on line 1 (5 chars: cd"""), then y
    assert(
      data[10] == 0 and data[11] == 2 and data[12] == 5 and data[13] == 3,
      "first string piece",
    )
    assert(
      data[15] == 1 and data[16] == 0 and data[17] == 5 and data[18] == 3,
      "second string piece on the next line",
    )
    assert(
      data[20] == 1 and data[21] == 0 and data[22] == 1 and data[23] == 1,
      "y after it",
    )
  }
  t.test("tokens say as much as the TextMate grammar under them"){
    local s = lsp.new()
    local init = s:handle(request(1, "initialize", {capabilities: {}}))
    local types = init[0].result.capabilities.semanticTokensProvider.legend.tokenTypes
    local text = "func t.go(a){ return a and true }\nprint(\"a\\nb\")\n"
    open_doc(s, "file:///tmp/lsp_test/r.slang", text)
    local data = tokens_of(s, "file:///tmp/lsp_test/r.slang")
    // "text type modifiers" of every token but punctuation, on one line each
    local seen = {}
    local starts = str.line_starts(text)
    local line = 0
    local char = 0
    for(local i = 0; i < len(data); i = i + 5){
      if(data[i] > 0){ char = 0 }
      line = line + data[i]
      char = char + data[i + 1]
      local at = starts[line] + char
      if(types[data[i + 3]] != "punctuation"){
        append(seen, concat(
          str.substring(text, at, at + data[i + 2]), " ", types[data[i + 3]],
          " ", data[i + 4],
        ))
      }
    }
    assert(str.join(seen, "|") == str.join({
      "func keyword 1", "t function 1", "go function 1", "a parameter 0",
      "return keyword 0", "a variable 0", "and operator 0", "true keyword 4",
      "print function 0", "\"a string 0", "b\" string 0",
    }, "|"), str.join(seen, "|"))
  }
  t.test("an extension in the document is highlighted"){
    local s = lsp.new()
    s:handle(request(1, "initialize", {capabilities: {}}))
    open_doc(
      s,
      "file:///tmp/lsp_test/e.slang",
      "extension \"extensions/lambda_shorthand\"\nlocal f = |x| x + 1\n",
    )
    local data = tokens_of(s, "file:///tmp/lsp_test/e.slang")
    assert(len(data) > 10)
  }
  t.test("extension categories map to standard types with modifiers"){
    local s = lsp.new()
    local init = s:handle(request(1, "initialize", {capabilities: {}}))
    local legend = init[0].result.capabilities.semanticTokensProvider.legend
    assert(len(
      legend.tokenTypes,
    ) == 24 and legend.tokenModifiers[0] == "declaration")
    open_doc(
      s,
      "file:///tmp/lsp_test/n.slang",
      "extension \"extensions/enum\"\nenum Color { Red }\n",
    )
    local data = tokens_of(s, "file:///tmp/lsp_test/n.slang")
    // after the extension statement (2 tokens): enum, Color, {, Red, }
    local color = 3
    assert(data[color * 5 + 3] == 10 and data[color * 5 + 4] == 1, concat(
      "Color: type ", data[color * 5 + 3], " modifiers ", data[color * 5 + 4]
    ))
    local red = 5
    assert(data[red * 5 + 3] == 16 and data[red * 5 + 4] == 1, concat(
      "Red: type ", data[red * 5 + 3], " modifiers ", data[red * 5 + 4]
    ))
  }
  t.test("formatting replaces the document with slang fmt's result"){
    local s = lsp.new()
    local init = s:handle(request(1, "initialize", {capabilities: {}}))
    assert(init[0].result.capabilities.documentFormattingProvider)
    local func format_doc(uri, text){
      open_doc(s, uri, text)
      return s:handle(request(7, "textDocument/formatting", {
        textDocument: {uri: uri},
        options: {tabSize: 2, insertSpaces: true},
      }))
    }
    local r = format_doc(
      "file:///tmp/lsp_test/f.slang",
      "local  x=1\nprint( x )",
    )
    local edits = r[0].result
    assert(len(edits) == 1 and edits[0].newText == "local x = 1\nprint(x)\n")
    assert(edits[0].range.start.line == 0 and edits[0].range["end"].line == 1)
    assert(edits[0].range["end"].character == 10)
    r = format_doc("file:///tmp/lsp_test/g.slang", "local x = 1\n")
    assert(len(r[0].result) == 0, "formatted already: no edits")
    r = format_doc("file:///tmp/lsp_test/h.slang", "local x = = 1\n")
    assert(
      len(r) == 1 and len(r[0].result) == 0,
      "a parse error: no edits, no message",
    )
  }
  t.test("unknown methods, shutdown and exit"){
    local s = lsp.new()
    local r = s:handle(request(5, "textDocument/codeLens", {}))
    assert(r[0].error.code == -32601)
    assert(len(s:handle(notify("textDocument/nothing", {}))) == 0)
    local down = s:handle(request(6, "shutdown", null))[0]
    assert(type(down.result) == "json.null" and s.shutdown_requested)
    s:handle(notify("exit", null))
    assert(s.exited)
  }
}

t.group("language server: names"){
  // the stubs of this checkout, whichever build runs the tests (the checked
  // builds live in zig/zig-out-*, where no slang/stubs is next to them)
  local stubs = compiler.absolute_path("slang/stubs")
  local known = false
  for(let local d in values(__PACKAGES.stub_sources)){
    known = known or compiler.absolute_path(d) == stubs
  }
  if(not known){
    append(__PACKAGES.stub_sources, stubs)
  }
  // test/navigate/main.slang requires test/navigate/util.slang
  local dir = compiler.absolute_path("test/navigate")
  local main_path = concat(dir, "/main.slang")
  local text = os.read_file(main_path)
  local s = lsp.new({root: dir})
  local init = s:handle(request(1, "initialize", {capabilities: {}}))
  local uri = lsp.path_to_uri(main_path)
  open_doc(s, uri, text)
  // the position of the nth occurrence of word in main.slang
  local func pos(word, nth){
    local i = -1
    for(local k = 0; k <= (nth or 0); k = k + 1){
      i = str.index_of(text, word, i + 1)
    }
    local lc = str.line_col(text, i)
    return {line: lc[0] - 1, character: lc[1] - 1}
  }
  local func ask(method, p, context){
    return s:handle(request(9, method, {
      textDocument: {uri: uri}, position: p, context: context
    }))[0].result
  }
  // "file:line:character" of each location
  local func spots(locations){
    local out = {}
    for(let local l in values(locations)){
      local file = str.substring(l.uri, str.index_of(l.uri, "/navigate/") + 10)
      append(out, concat(
        file, ":", string(l.range.start.line), ":",
        string(l.range.start.character)
      ))
    }
    return out
  }
  t.test("go to definition: locals, globals and a required module's field"){
    assert(init[0].result.capabilities.definitionProvider)
    local d = spots(ask("textDocument/definition", pos("greet(\"x")))
    assert(d == {"main.slang:4:11"}, str.join(d, " "))
    d = spots(ask("textDocument/definition", pos("counter", 1)))
    assert(d == {"main.slang:7:0"}, str.join(d, " "))
    d = spots(ask("textDocument/definition", pos("double")))
    assert(d == {"util.slang:4:10"}, str.join(d, " "))
    // a built-in: its stub
    d = ask("textDocument/definition", pos("print"))
    assert(len(d) == 1 and str.ends_with(
        d[0].uri,
        "/slang/stubs/globals.slang",
      ))
  }
  t.test("go to definition and hover on a require: the module's file"){
    local d = ask("textDocument/definition", pos("navigate/util\""))
    assert(len(d) == 1 and str.ends_with(d[0].uri, "/test/navigate/util.slang"))
    d = ask("textDocument/definition", pos("require(\"test"))
    assert(len(d) == 1 and str.ends_with(d[0].uri, "/test/navigate/util.slang"))
    // a native module: its stub
    d = ask("textDocument/definition", pos("slang/string"))
    assert(len(d) == 1 and str.ends_with(
        d[0].uri,
        "/slang/stubs/slang/string.slang",
      ))
    local h = ask("textDocument/hover", pos("navigate/util\""))
    assert(str.index_of(
      h.contents.value,
      "a module the language server tests require",
    ) >= 0, h.contents.value)
  }
  t.test("find references: a parameter, and a module field across files"){
    local r = spots(ask("textDocument/references", pos("name)", 1), {
      includeDeclaration: true,
    }))
    assert(r == {"main.slang:4:17", "main.slang:5:23"}, str.join(r, " "))
    r = spots(ask("textDocument/references", pos("double"), {
      includeDeclaration: true,
    }))
    assert(
      len(r) == 3 and r[0] == "main.slang:5:34" and
        r[1] == "main.slang:8:32" and r[2] == "util.slang:4:10",
      str.join(r, " "),
    )
    r = spots(ask("textDocument/references", pos("double"), {
      includeDeclaration: false,
    }))
    assert(len(r) == 2, str.join(r, " "))
  }
  t.test("methods are found through what a value is"){
    local h = ask("textDocument/hover", pos("bump"))
    assert(
      str.index_of(h.contents.value, "func Counter:bump(by)") >= 0,
      h.contents.value,
    )
    assert(str.index_of(h.contents.value, "the count after adding by") >= 0)
    local d = spots(ask("textDocument/definition", pos("bump")))
    assert(d == {"util.slang:17:21"}, str.join(d, " "))
  }
  t.test("native modules and built-in globals resolve to their stubs"){
    local h = ask("textDocument/hover", pos("trim"))
    assert(
      str.index_of(h.contents.value, "func str.trim(") >= 0,
      h.contents.value,
    )
    assert(str.index_of(h.contents.value, "slang/string (native)") >= 0)
    local d = ask("textDocument/definition", pos("trim"))
    assert(str.ends_with(d[0].uri, "/slang/stubs/slang/string.slang"))
    h = ask("textDocument/hover", pos("print"))
    assert(str.index_of(h.contents.value, "func print(") >= 0, h.contents.value)
    assert(str.index_of(h.contents.value, "globals (native)") >= 0)
  }
  t.test("outline: the top-level names with their kinds"){
    local syms = s:handle(request(9, "textDocument/documentSymbol", {
      textDocument: {uri: uri},
    }))[0].result
    local got = {}
    for(let local sym in values(syms)){
      append(got, concat(sym.name, "/", string(sym.kind)))
    }
    // modules 2, functions 12, variables 13
    assert(
      got == {"util/2", "greet/12", "counter/13", "c/13", "str/2"},
      str.join(got, " "),
    )
  }
  t.test("highlights: the definition is a write, the uses reads"){
    local h = ask("textDocument/documentHighlight", pos("name)", 1))
    assert(len(h) == 2 and h[0].kind == 3 and h[1].kind == 2)
  }
  t.test("rename: across files, refused outside the project"){
    local p = ask("textDocument/prepareRename", pos("double"))
    assert(p.placeholder == "double")
    local r = s:handle(request(9, "textDocument/rename", {
      textDocument: {uri: uri},
      position: pos("double"),
      newName: "twice",
    }))[0].result
    local counts = {}
    for(let local e in entries(r.changes)){
      local file = str.substring(e[0], str.index_of(e[0], "/navigate/") + 10)
      counts[file] = len(e[1])
      assert(e[1][0].newText == "twice")
    }
    assert(counts == {["main.slang"]: 2, ["util.slang"]: 1}, string(counts))
    local refused = s:handle(request(9, "textDocument/prepareRename", {
      textDocument: {uri: uri},
      position: pos("print"),
    }))[0]
    assert(str.index_of(refused.error.message, "outside the project") >= 0)
    local keyword = s:handle(request(9, "textDocument/rename", {
      textDocument: {uri: uri},
      position: pos("double"),
      newName: "local",
    }))[0]
    assert(keyword.error != null)
  }
  t.test("inlay hints: parameter names before literal arguments"){
    local hints = s:handle(request(9, "textDocument/inlayHint", {
      textDocument: {uri: uri},
      range: {
        start: {line: 0, character: 0},
        ["end"]: {line: 20, character: 0},
      },
    }))[0].result
    local got = {}
    for(let local h in values(hints)){
      append(got, concat(h.label, string(h.position.line)))
    }
    // c:bump(2) names `by`: the receiver is the first parameter
    assert(
      got == {"x:5", "name:8", "x:8", "by:10", "s:12"},
      str.join(got, " "),
    )
  }
  t.test("workspace symbols: the project's names by a fuzzy query"){
    local r = s:handle(request(9, "workspace/symbol", {query: "dbl"}))[0].result
    assert(len(r) == 1 and r[0].name == "double", string(len(r)))
    assert(str.ends_with(r[0].location.uri, "/navigate/util.slang"))
  }
  // the document with extra appended (it need not parse), the result of
  // method at its end; the document is put back after
  local func at_end(extra, method){
    local t = concat(text, extra)
    s:handle(notify("textDocument/didChange", {
      textDocument: {uri: uri, version: 2},
      contentChanges: {{text: t}},
    }))
    local lc = str.line_col(t, len(t))
    local result = s:handle(request(9, method, {
      textDocument: {uri: uri},
      position: {line: lc[0] - 1, character: lc[1] - 1},
    }))[0].result
    s:handle(notify("textDocument/didChange", {
      textDocument: {uri: uri, version: 3},
      contentChanges: {{text: text}},
    }))
    return result
  }
  local func labels(items){
    local out = {}
    for(let local i in values(items)){
      append(out, i.label)
    }
    return out
  }
  t.test("completion: members, methods, names in scope, modules"){
    local members = {}
    for(let local name in values(
      labels(at_end("util.", "textDocument/completion")),
    )){
      members[name] = true
    }
    assert(members == {double: true, counter: true}, string(members))
    assert(labels(at_end("c:", "textDocument/completion")) == {"bump"})
    local plain = at_end("gr", "textDocument/completion")
    local has = {}
    for(let local i in values(plain)){
      has[i.label] = i
    }
    assert(has.greet != null and has.greet.detail == "greet(name)")
    assert(has.print != null and has["local"] != null)
    // locals come before globals and keywords
    assert(str.compare(has.greet.sortText, has.print.sortText) < 0)
    local mods = labels(at_end(
      "local x = require(\"test/navigate/",
      "textDocument/completion",
    ))
    assert(
      mods == {
          "test/navigate/main",
          "test/navigate/typed",
          "test/navigate/typed_main",
          "test/navigate/util",
        },
      str.join(
        mods,
        " ",
      ),
    )
    assert(len(at_end("// util.", "textDocument/completion")) == 0)
  }
  t.test("signature help: parameters, the current one, methods"){
    local sig = at_end("util.double(", "textDocument/signatureHelp")
    assert(sig.signatures[0].label == "double(x)" and sig.activeParameter == 0)
    assert(str.index_of(sig.signatures[0].documentation.value, "twice x") >= 0)
    sig = at_end("c:bump(", "textDocument/signatureHelp")
    assert(sig.signatures[0].label == "bump(by)")
    sig = at_end("greet(f(1, 2), ", "textDocument/signatureHelp")
    assert(
      sig.signatures[0].label == "greet(name)" and sig.activeParameter == 1,
    )
  }
  t.test("lint: unused locals, undefined globals, missing modules"){
    local ls = lsp.new({root: dir})
    ls:handle(request(1, "initialize", {capabilities: {}}))
    local r = open_doc(
      ls,
      lsp.path_to_uri(concat(dir, "/lint.slang")),
      "local unused = 1\nlocal _fine = 2\nprint(nowhere, counter)\nlocal m = require(\"no/such\")\nm.f()\n",
    )
    local got = {}
    for(let local d in values(r[0].params.diagnostics)){
      append(got, concat(string(d.severity), ":", d.message))
    }
    assert(got == {
        "4:unused is never used",
        "2:nowhere is not defined (a global no file of the project assigns)",
        "2:module no/such not found",
      }, str.join(got, " | "))
  }
  t.test("range formatting: only the lines of the selection change"){
    local rs = lsp.new({root: dir})
    rs:handle(request(1, "initialize", {capabilities: {}}))
    local ruri = lsp.path_to_uri(concat(dir, "/range.slang"))
    open_doc(rs, ruri, "local   a=1\nif(a){ print( 1 ) }\nlocal   c=3\n")
    local edits = rs:handle(request(9, "textDocument/rangeFormatting", {
      textDocument: {uri: ruri},
      range: {start: {line: 1, character: 0}, ["end"]: {line: 1, character: 2}},
    }))[0].result
    assert(len(edits) == 1 and edits[0].range.start.line == 1)
    assert(edits[0].newText == "if(a){ print(1) }", edits[0].newText)
  }
  t.test("extension syntax: hover and definition name the extension"){
    local es = lsp.new({root: dir})
    es:handle(request(1, "initialize", {capabilities: {}}))
    local euri = lsp.path_to_uri(concat(dir, "/ext.slang"))
    open_doc(
      es, euri,
      "extension \"extensions/switch\"\nswitch(1){\n  case 1:\n    print(1)\n}\n"
    )
    local at = {textDocument: {uri: euri}, position: {line: 1, character: 2}}
    local h = es:handle(request(9, "textDocument/hover", at))[0].result
    assert(
      str.index_of(h.contents.value, "extension \"extensions/switch\"") >= 0,
      h.contents.value,
    )
    local d = es:handle(request(9, "textDocument/definition", at))[0].result
    assert(len(d) == 1 and str.ends_with(d[0].uri, "/extensions/switch.slang"))
    local e = es:handle(request(9, "slang/expand", {uri: euri}))[0].result
    assert(
      str.index_of(e.text, "switch") < 0 and
        str.index_of(e.text, "print(1)") >= 0,
      e.text,
    )
    // core code an extension embeds (an async function's body) is not
    // the extension's syntax
    local auri = lsp.path_to_uri(concat(dir, "/ext_async.slang"))
    open_doc(
      es, auri,
      "extension \"extensions/async\"\nasync func f(){\n  return nothing_known\n}\n"
    )
    local func hover_at(line, character){
      local r = es:handle(request(9, "textDocument/hover", {
        textDocument: {uri: auri}, position: {line: line, character: character},
      }))[0].result
      return type(r) == "json.null" and "" or r.contents.value
    }
    assert(str.index_of(hover_at(1, 2), "extensions/async") >= 0)
    h = hover_at(2, 12)
    assert(str.index_of(h, "extension") < 0, h)
  }
  t.test("tests: the groups and tests of a test file"){
    local r = s:handle(request(9, "slang/tests", {
      uri: lsp.path_to_uri(compiler.absolute_path("test/build_test.slang")),
    }))[0].result
    assert(r.tests[0].kind == "group" and r.tests[0].name == "build: requires")
    local first = r.tests[0].children[0]
    assert(first.kind == "test" and str.starts_with(
        first.name, "literal requires"
      ))
    assert(first.range.start.line > r.tests[0].range.start.line)
  }
  t.test("tests: those written inline with slang/inline_test"){
    local r = s:handle(request(9, "slang/tests", {
      uri: lsp.path_to_uri(compiler.absolute_path("test/fixtures/inline_tests.slang")),
    }))[0].result
    local g = r.tests[0]
    assert(g.kind == "group" and g.name == "inline tests", "the group")
    // group("inline tests"){ is on line 14 (0-based 13)
    assert(g.range.start.line == 13 and g.range.start.character == 0, "where")
    assert(g.children[0].name == "see the module's locals", "its test")
    assert(g.children[1].children[0].name == "runs too", "the nested group's")
    assert(r.tests[1].kind == "test" and r.tests[1].name == "at the top of the module")
  }
  t.test("slang.project: keys completed, explained and checked"){
    local ps = lsp.new({root: dir})
    ps:handle(request(1, "initialize", {capabilities: {}}))
    local puri = lsp.path_to_uri(concat(dir, "/sub/slang.project"))
    local r = open_doc(
      ps, puri, "{\n  colour: 1,\n  build: {compres: true},\n  \n}\n"
    )
    local got = {}
    for(let local d in values(r[0].params.diagnostics)){
      append(got, d.message)
    }
    assert(
      got == {"slang.project has no key colour", "build has no key compres"},
      str.join(got, " | "),
    )
    local keys_here = ps:handle(request(9, "textDocument/completion", {
      textDocument: {uri: puri},
      position: {line: 3, character: 2},
    }))[0].result
    assert(len(keys_here) == 8)
    local h = ps:handle(request(9, "textDocument/hover", {
      textDocument: {uri: puri},
      position: {line: 2, character: 4},
    }))[0].result
    assert(str.starts_with(h.contents.value, "**build**"))
  }
  t.test("typed docs: completion, hover, signature help, comment links"){
    local ts = lsp.new({root: dir})
    ts:handle(request(1, "initialize", {capabilities: {}}))
    local tpath = concat(dir, "/typed_main.slang")
    local turi = lsp.path_to_uri(tpath)
    local ttext = os.read_file(tpath)
    open_doc(ts, turi, ttext)
    local func spot(t, word, shift){
      local lc = str.line_col(t, str.index_of(t, word) + (shift or 0))
      return {line: lc[0] - 1, character: lc[1] - 1}
    }
    // what is offered after the dot of edited text, the text put back after
    local func complete_in(edited, marker){
      ts:handle(notify("textDocument/didChange", {
        textDocument: {uri: turi, version: 2},
        contentChanges: {{text: edited}},
      }))
      local r = ts:handle(request(9, "textDocument/completion", {
        textDocument: {uri: turi},
        position: spot(edited, marker, len(marker)),
      }))[0].result
      ts:handle(notify("textDocument/didChange", {
        textDocument: {uri: turi, version: 3},
        contentChanges: {{text: ttext}},
      }))
      local names = {}
      for(let local i in values(r)){
        names[i.label] = true
      }
      return names
    }
    // a parameter typed in its function's doc
    local fields = complete_in(str.replace(ttext, "req.path", "req."), "req.")
    assert(fields == {method: true, path: true, body: true}, string(fields))
    // what a function declared to return: its methods
    assert(complete_in(str.replace(ttext, "s:close()", "s:"), "s:") == {
        close: true,
      })
    local h = ts:handle(request(9, "textDocument/hover", {
      textDocument: {uri: turi},
      position: spot(ttext, "serve"),
    }))[0].result.contents.value
    assert(str.index_of(
      h,
      "typed.serve(port: int, handler: func(req: Request): string) -> server: Server",
    ) >= 0, h)
    assert(str.index_of(h, "- `port`: 0 picks a free one") >= 0, h)
    // a type named in a doc comment: its declaration
    local d = ts:handle(request(9, "textDocument/definition", {
      textDocument: {uri: turi},
      position: spot(ttext, "Request"),
    }))[0].result
    assert(len(d) == 1 and str.ends_with(
        d[0].uri,
        "/navigate/typed.slang",
      ) and d[0].range.start.line == 4)
  }
  t.test("hover: the signature and the doc comment"){
    local h = ask("textDocument/hover", pos("greet(\"x"))
    assert(h.contents.kind == "markdown")
    assert(str.index_of(h.contents.value, "local func greet(name)") >= 0)
    assert(
      str.index_of(h.contents.value, "- returns: a greeting") >= 0,
      h.contents.value,
    )
    h = ask("textDocument/hover", pos("double"))
    assert(str.index_of(h.contents.value, "func util.double(x)") >= 0)
    assert(str.index_of(h.contents.value, "- returns: twice x") >= 0)
    assert(h.range.start.line == 5 and h.range.start.character == 34)
    local none = s:handle(request(9, "textDocument/hover", {
      textDocument: {uri: uri},
      position: pos("// navigate"),
    }))[0]
    assert(type(none.result) == "json.null", "no hover is a null result")
    assert(str.index_of(lsp.encode(none), "\"result\":null") >= 0)
  }
  t.test("properties: __get and __set, inherited along __index"){
    local props_uri = lsp.path_to_uri(concat(dir, "/props.slang"))
    local props = str.join({
      "local getters = {}",
      "local setters = {}",
      "local base_meta = {__type: \"Base\", __get: {kind: func(self){ return \"base\" }}}",
      "local base = {@meta: base_meta}",
      "// type Box",
      "local meta = {__type: \"Box\", __index: base, __get: getters, __set: setters}",
      "// size(self) -> int",
      "// How big the box is.",
      "func getters.size(b){ return b.n }",
      "func setters.size(b, v){ b.n = v }",
      "// twin(self) -> a box like this one",
      "func getters.twin(b){ return {@meta: meta, n: b.n} }",
      "// copy(self) -> Box",
      "func getters.copy(b){ return made_elsewhere(b) }",
      "local box = {@meta: meta, n: 1}",
      "box.size = 2",
      "print(box.size, box.kind, box.twin.size)",
      "print(box.copy.size, box.twin.copy.kind)",
      "",
    }, "\n")
    open_doc(s, props_uri, props)
    local func at(word, nth){
      local i = -1
      for(local k = 0; k <= (nth or 0); k = k + 1){
        i = str.index_of(props, word, i + 1)
      }
      local lc = str.line_col(props, i)
      return {line: lc[0] - 1, character: lc[1] - 1}
    }
    local func asked(method, word, nth){
      return s:handle(request(9, method, {
        textDocument: {uri: props_uri}, position: at(word, nth)
      }))[0].result
    }
    // hover: a property of the type, its type and doc
    local h = asked("textDocument/hover", "size, box")
    assert(str.index_of(h.contents.value, "property Box.size: int") >= 0, h.contents.value)
    assert(str.index_of(h.contents.value, "How big the box is.") >= 0, h.contents.value)
    // inherited from base's meta through __index; read-only
    h = asked("textDocument/hover", "kind, box")
    assert(str.index_of(h.contents.value, "property") >= 0 and
      str.index_of(h.contents.value, "(read-only)") >= 0, h.contents.value)
    // definition: the getter; a property's value is what its getter returns
    local d = asked("textDocument/definition", "size", 3)
    assert(len(d) == 1 and d[0].range.start.line == 8, string(d))
    // through chains: what the code returns (twin), else what the doc
    // declares (copy: Box)
    for(let local use in values({"size)", "size, box.twin", "kind)"})){
      d = asked("textDocument/definition", use)
      assert(len(d) == 1, concat(use, " ", string(d)))
      h = asked("textDocument/hover", use)
      assert(str.index_of(h.contents.value, "property") >= 0, h.contents.value)
    }
    assert(asked("textDocument/definition", "size)")[0].range.start.line == 8)
    // references: the uses through the setter and the getter, the getter
    local r = s:handle(request(9, "textDocument/references", {
      textDocument: {uri: props_uri}, position: at("size", 3),
      context: {includeDeclaration: true},
    }))[0].result
    assert(len(r) == 5, string(r))
    // completion lists the properties, the inherited one too; a property
    // is followed into what its getter returns (box.twin.)
    local func completed(extra){
      local t2 = concat(props, extra)
      s:handle(notify("textDocument/didChange", {
        textDocument: {uri: props_uri, version: 2}, contentChanges: {{text: t2}},
      }))
      local lc = str.line_col(t2, len(t2))
      local by = {}
      for(let local i in values(s:handle(request(9, "textDocument/completion", {
        textDocument: {uri: props_uri},
        position: {line: lc[0] - 1, character: lc[1] - 1},
      }))[0].result)){
        by[i.label] = i
      }
      return by
    }
    for(let local extra in values({"box.", "box.twin.", "box.copy."})){
      local by = completed(extra)
      assert(by.size != null and by.size.kind == 10 and by.size.detail == "int",
        concat(extra, " ", string(by)))
      // (a Box known from a doc alone has no fields of its own)
      assert(by.kind != null and by.twin != null and
        (by.n != null or extra == "box.copy."), extra)
    }
    assert(completed("box:").size == null, "a property is not a method")
  }
  t.test("values the code gives later: self, the fields of objects, assignments"){
    local later_uri = lsp.path_to_uri(concat(dir, "/later.slang"))
    local src = str.join({
      "local methods = {}",
      "local getters = {}",
      "// type Thing",
      "local thing_meta = {__index: methods, __get: getters}",
      "// size(self) -> int",
      "func getters.size(t){ return t.n }",
      "func methods.grow(t){ t.n = t.size + 1 }",
      "func methods.make(t){ return {@meta: thing_meta, n: 0, part: {weight: 2}} }",
      "local game = {thing: null}",
      "game.thing = methods.make(null)",
      "local func use(options){",
      "  options = options or {limit: 3}",
      "  return options.limit",
      "}",
      "print(game.thing.size, game.thing.part.weight, use())",
      "",
    }, "\n")
    open_doc(s, later_uri, src)
    local func hover(word, nth){
      local i = -1
      for(local k = 0; k <= (nth or 0); k = k + 1){
        i = str.index_of(src, word, i + 1)
      }
      local lc = str.line_col(src, i)
      local h = s:handle(request(9, "textDocument/hover", {
        textDocument: {uri: later_uri},
        position: {line: lc[0] - 1, character: lc[1] - 1},
      }))[0].result
      return type(h) == "json.null" and "" or h.contents.value
    }
    // self in a method of the meta's tables: an object of it, with the
    // fields the file gives its objects
    local h = hover("size + 1")
    assert(str.index_of(h, "property Thing.size: int") >= 0, h)
    h = hover("n = t.size")
    assert(str.index_of(h, "field Thing.n") >= 0, h)
    // a field assigned after a null first value; through a chain
    h = hover("size, game")
    assert(str.index_of(h, "property Thing.size") >= 0, h)
    h = hover("weight, use")
    assert(str.index_of(h, "field weight") >= 0, concat("weight: ", h))
    // a parameter assigned in its function
    h = hover("limit\n}")
    assert(str.index_of(h, "field limit") >= 0, h)
  }
  t.test("doc types: lists, maps, function types, callbacks, annotations"){
    local typed_uri = lsp.path_to_uri(concat(dir, "/doc_types.slang"))
    local src = str.join({
      "// type Item = {name: string, weight: int}",
      "",
      "// items() -> {Item}",
      "local func items(){ return elsewhere() }",
      "// lookup() -> {[string]: Item}",
      "local func lookup(){ return elsewhere() }",
      "// each(f: func(item: Item, i: int))",
      "local func each(f){}",
      "// maker: func(): Item",
      "local maker = elsewhere()",
      "// current: Item",
      "// The item at hand.",
      "local current = elsewhere()",
      "for(let local it in values(items())){ print(it.weight) }",
      "for(let local e in entries(lookup())){ print(e[1].name) }",
      "for(let {local k, local v} in entries(lookup())){ print(v.name) }",
      "print(items()[0].weight, lookup().any.name)",
      "each(func(item, i){ print(item.weight) })",
      "print(maker().weight, current.name)",
      "// later() -> func(item: Item)",
      "local func later(){ return func(it2){ print(it2.weight) } }",
      "",
    }, "\n")
    open_doc(s, typed_uri, src)
    local func hover(word){
      local i = str.index_of(src, word)
      local lc = str.line_col(src, i)
      local h = s:handle(request(9, "textDocument/hover", {
        textDocument: {uri: typed_uri},
        position: {line: lc[0] - 1, character: lc[1] - 1},
      }))[0].result
      return type(h) == "json.null" and "" or h.contents.value
    }
    local func is_item_field(word, field){
      local h = hover(word)
      assert(str.index_of(h, concat("field Item.", field)) >= 0,
        concat(word, ": ", h))
    }
    // a loop over a list, an entry's value, a table pattern's part
    is_item_field("weight) }\nfor", "weight")
    is_item_field("name) }\nfor", "name")
    is_item_field("name) }\nprint", "name")
    // an element of a list, a value of a map
    is_item_field("weight, lookup", "weight")
    is_item_field("name)\neach", "name")
    // a callback's parameter: its type as the callee's doc gives it
    is_item_field("weight) })", "weight")
    local h = hover("item, i")
    assert(str.index_of(h, "parameter item: Item") >= 0, h)
    // a function type's result; a local's declared type and its doc
    is_item_field("weight, current", "weight")
    is_item_field("name)\n", "name")
    // a function literal returned where the doc declares a function type
    is_item_field("weight) } }", "weight")
    h = hover("current = ")
    assert(str.index_of(h, "local current: Item") >= 0 and
      str.index_of(h, "The item at hand.") >= 0 and
      len(str.split(h, "current: Item")) == 2, h)
  }
  t.test("lint: calls that do not fit the typed docs of what they call"){
    local bad_uri = lsp.path_to_uri(concat(dir, "/bad_calls.slang"))
    local src = str.join({
      "// type Opts = {port: int, name?: string}",
      "",
      "// open(port: int, opts?: Opts, f?: func(x: int)) -> int",
      "local func open(port, opts, f){ return port }",
      "local p = \"80\"",
      "local q = 80",
      "q = \"changed\"",
      "open(p)",
      "open(80, {port: \"x\"})",
      "open(80, null, 3)",
      "open(80, {}, func(x){ return x }, 4)",
      "open(q)",
      "open(1, func(x){ return x })",
      "open(2.0 + 1)",
      "",
    }, "\n")
    local out = open_doc(s, bad_uri, src)
    local messages = {}
    for(let local m in values(out)){
      if(m.method == "textDocument/publishDiagnostics"){
        for(let local d in values(m.params.diagnostics)){
          if(d.severity == 2){
            append(messages, concat(string(d.range.start.line), " ", d.message))
          }
        }
      }
    }
    assert(messages == {
      "7 open's port: expected int, got a string",
      "8 open's opts: field port: expected int, got a string",
      "9 open's f: expected func(x: int), got an int",
      "10 open takes 3 arguments, 4 given",
      // (2.0 + 1 is folded to 3.0 as it is parsed)
      "13 open's port: expected int, got a float",
    }, str.join(messages, "\n"))
  }
  t.test("several projects: each file under its own"){
    // test/lsp_projects holds two projects
    local pdir = compiler.absolute_path("test/lsp_projects")
    local ps = lsp.new({})
    ps:handle(request(1, "initialize", {
      capabilities: {}, rootUri: lsp.path_to_uri(pdir)
    }))
    local func errors_of(sub){
      local path = concat(pdir, "/", sub, "/main.slang")
      local out = open_doc(ps, lsp.path_to_uri(path), os.read_file(path))
      local n = 0
      for(let local m in values(out)){
        if(m.method == "textDocument/publishDiagnostics"){
          for(let local d in values(m.params.diagnostics)){
            if(d.severity == 1){
              n = n + 1
            }
          }
        }
      }
      return n
    }
    // switch is syntax in one and a name in the other, opened either way
    // round and again
    assert(errors_of("proj_switch") == 0, "proj_switch")
    assert(errors_of("proj_plain") == 0, "proj_plain")
    assert(errors_of("proj_switch") == 0, "proj_switch again")
    // a project file changes: every project is made anew
    ps:handle(notify("workspace/didChangeWatchedFiles", {changes: {}}))
    assert(errors_of("proj_plain") == 0 and errors_of("proj_switch") == 0)
  }
  t.test("hover on the last word of a file"){
    local tail_uri = lsp.path_to_uri(concat(dir, "/tail.slang"))
    local tail = "local buffer = {}\nreturn buffer"
    open_doc(s, tail_uri, tail)
    local r = s:handle(request(9, "textDocument/hover", {
      textDocument: {uri: tail_uri}, position: {line: 1, character: 9}
    }))[0]
    assert(r.error == null, r.error and r.error.message)
    assert(str.index_of(r.result.contents.value, "local buffer") >= 0)
  }
}
