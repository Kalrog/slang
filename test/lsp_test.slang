// the language server's logic, driven in process
local t = require("slang/test")
local str = require("slang/string")
local json = require("slang/json")
local lsp = require("lsp/server")

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
      r.messages
    ) == 1 and r.messages[0].method == "y" and r.rest == "")
  }
  t.test("uris decode"){
    assert(lsp.uri_to_path("file:///a/b%20c/d.slang") == "/a/b c/d.slang")
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
      "local x = 1\n// note\nprint(x)\n"
    )
    assert(replies[0].method == "textDocument/publishDiagnostics" and len(
        replies[0].params.diagnostics
      ) == 0)
    local data = tokens_of(s, "file:///tmp/lsp_test/a.slang")
    // local(keyword) x(variable) =(punct) 1(number) // note(comment) print(variable) ( x )
    assert(
      data[0] == 0 and data[1] == 0 and data[2] == 5 and data[3] == 0,
      "first token: local at 0:0, length 5, keyword"
    )
    assert(
      data[5] == 0 and data[6] == 6 and data[7] == 1 and data[8] == 1,
      "then x at +6, a variable"
    )
    assert(
      data[20] == 1 and data[21] == 0 and data[22] == 7 and data[23] == 4,
      "the comment on the next line"
    )
    assert(
      data[25] == 1 and data[26] == 0 and data[27] == 5 and data[28] == 1,
      "print on line 3"
    )
    // a change that breaks the file
    local changed = s:handle(notify("textDocument/didChange", {
      textDocument: {uri: "file:///tmp/lsp_test/a.slang", version: 2},
      contentChanges: {{text: "local x = 1\nlocal y = = 2\n"}},
    }))
    local diags = changed[0].params.diagnostics
    assert(
      len(diags) >= 1 and diags[0].severity == 1 and diags[0].source == "slang",
      "a diagnostic"
    )
    assert(
      diags[0].range.start.line == 1,
      concat("at line ", diags[0].range.start.line)
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
      concat("string length ", d16[17], " ", d8[17])
    )
    assert(
      d16[21] == 10 and d8[21] == 15,
      concat("comment start ", d16[21], " ", d8[21])
    )
    assert(
      d16[22] == 4 and d8[22] == 5,
      concat("comment length ", d16[22], " ", d8[22])
    )
  }
  t.test("multi-line strings are split per line"){
    local s = lsp.new()
    s:handle(request(1, "initialize", {capabilities: {}}))
    open_doc(
      s,
      "file:///tmp/lsp_test/m.slang",
      "x = \"\"\"ab\ncd\"\"\"\ny = 1\n"
    )
    local data = tokens_of(s, "file:///tmp/lsp_test/m.slang")
    // x = then the string piece on line 0 (5 chars: """ab), the piece on line 1 (5 chars: cd"""), then y
    assert(
      data[10] == 0 and data[11] == 2 and data[12] == 5 and data[13] == 3,
      "first string piece"
    )
    assert(
      data[15] == 1 and data[16] == 0 and data[17] == 5 and data[18] == 3,
      "second string piece on the next line"
    )
    assert(
      data[20] == 1 and data[21] == 0 and data[22] == 1 and data[23] == 1,
      "y after it"
    )
  }
  t.test("an extension in the document is highlighted"){
    local s = lsp.new()
    s:handle(request(1, "initialize", {capabilities: {}}))
    open_doc(
      s,
      "file:///tmp/lsp_test/e.slang",
      "extension \"extensions/lambda_shorthand\"\nlocal f = |x| x + 1\n"
    )
    local data = tokens_of(s, "file:///tmp/lsp_test/e.slang")
    assert(len(data) > 10)
  }
  t.test("extension categories map to standard types with modifiers"){
    local s = lsp.new()
    local init = s:handle(request(1, "initialize", {capabilities: {}}))
    local legend = init[0].result.capabilities.semanticTokensProvider.legend
    assert(len(
      legend.tokenTypes
    ) == 24 and legend.tokenModifiers[0] == "declaration")
    open_doc(
      s,
      "file:///tmp/lsp_test/n.slang",
      "extension \"extensions/enum\"\nenum Color { Red }\n"
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
  t.test("unknown methods, shutdown and exit"){
    local s = lsp.new()
    local r = s:handle(request(5, "textDocument/hover", {}))
    assert(r[0].error.code == - 32601)
    assert(len(s:handle(notify("textDocument/nothing", {}))) == 0)
    assert(s:handle(
      request(6, "shutdown", null)
    )[0].result == null and s.shutdown_requested)
    s:handle(notify("exit", null))
    assert(s.exited)
  }
}
