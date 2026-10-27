// lsp/server: the language server's logic, independent of the transport.
//
//   local server = require("lsp/server").new({log: func(text){ ... }})
//   local replies = server:handle(message)   // decoded JSON-RPC message
//
// handle returns the messages to send (responses and notifications). What
// the server speaks: initialize (semantic tokens, full document sync, a
// position encoding), didOpen/didChange/didClose, semanticTokens/full,
// publishDiagnostics, didChangeWatchedFiles (the project file changed: the
// grammars are reset), shutdown, exit. Highlighting comes from
// compiler.highlight, so extensions and dialects are the real ones.
local compiler = require("slang/compiler")
local str = require("slang/string")
local json = require("slang/json")

local lsp = {}

// The semantic token legend: slang's core categories first, then every
// standard LSP token type, so an extension can tag its tokens with any of
// them (`g:token(parser, "name", "enumMember")`); `punctuation` is slang's
// own type (the VS Code extension maps it to a scope). A category may carry
// standard modifiers after dots: "enumMember.declaration.readonly".
// Categories the legend does not know are not sent.
lsp.token_types = {"keyword", "variable", "number", "string", "comment", "operator", "punctuation",
  "namespace", "type", "class", "enum", "interface", "struct", "typeParameter", "parameter", "property",
  "enumMember", "event", "function", "method", "macro", "modifier", "regexp", "decorator"}
lsp.token_modifiers = {"declaration", "definition", "readonly", "static", "deprecated", "abstract", "async",
  "modification", "documentation", "defaultLibrary"}
local type_index = {identifier: 1}
for(let local e in entries(lsp.token_types)){
  type_index[e[1]] = e[0]
}
local modifier_bit = {}
for(let local e in entries(lsp.token_modifiers)){
  modifier_bit[e[1]] = 1 << e[0]
}

// category("enumMember.declaration") -> {type index, modifier bits} or null
local category_cache = {}
local func category_of(name){
  local c = category_cache[name]
  if(c != null){
    return c
  }
  local parts = str.split(name, ".")
  local kind = type_index[parts[0]]
  if(kind == null){
    return null
  }
  local bits = 0
  for(local i = 1; i < len(parts); i = i + 1){
    local b = modifier_bit[parts[i]]
    if(b != null){
      bits = bits | b
    }
  }
  c = {kind: kind, bits: bits}
  category_cache[name] = c
  return c
}

// ------------------------------------------------------------ framing

// frame(buffer) -> {messages, rest}: the complete Content-Length framed
// messages at the start of buffer (decoded) and the unconsumed rest
func lsp.frame(buffer){
  local messages = {}
  for(true){
    local head_end = str.index_of(buffer, "\r\n\r\n")
    if(head_end < 0){
      break
    }
    local head = str.substring(buffer, 0, head_end)
    local length = -1
    for(let local line in values(str.split(head, "\r\n"))){
      local i = str.index_of(line, ":")
      if(i >= 0 and str.lower(str.trim(str.substring(line, 0, i))) == "content-length"){
        length = to_int(str.trim(str.substring(line, i + 1)))
      }
    }
    if(length < 0){
      error("message without Content-Length")
    }
    local body_start = head_end + 4
    if(len(buffer) < body_start + length){
      break
    }
    append(messages, json.decode(str.substring(buffer, body_start, body_start + length), "message"))
    buffer = str.substring(buffer, body_start + length)
  }
  return {messages: messages, rest: buffer}
}

// encode(message) -> the framed bytes
func lsp.encode(message){
  local body = json.encode(message)
  return concat("Content-Length: ", len(body), "\r\n\r\n", body)
}

// ------------------------------------------------------------ uris and positions

local func hex_value(c){
  local b = str.byte_at(c, 0)
  if(b >= 48 and b <= 57){ return b - 48 }
  if(b >= 97 and b <= 102){ return b - 87 }
  if(b >= 65 and b <= 70){ return b - 55 }
  return 0
}

// uri_to_path("file:///a/b%20c.slang") -> "/a/b c.slang"
func lsp.uri_to_path(uri){
  local path = uri
  if(str.starts_with(path, "file://")){
    path = str.substring(path, 7)
  }
  local out = {}
  local i = 0
  local n = len(path)
  for(i < n){
    if(str.byte_at(path, i) == 37 and i + 2 < n){
      append(out, str.chr(hex_value(str.char_at(path, i + 1)) * 16 + hex_value(str.char_at(path, i + 2))))
      i = i + 3
    } else {
      append(out, str.char_at(path, i))
      i = i + 1
    }
  }
  return str.join(out, "")
}

// the character offset of a byte position within its line, in the encoding
local func character_at(text, line_start, pos, encoding){
  if(encoding == "utf-8"){
    return pos - line_start
  }
  return str.utf16_len(str.substring(text, line_start, pos))
}

// semantic_tokens(text, tokens, encoding) -> the LSP data array: for every
// token (split at line breaks) deltaLine, deltaStart, length, type, modifiers
func lsp.semantic_tokens(text, tokens, encoding){
  local starts = str.line_starts(text)
  local data = json.array({})
  local prev_line = 0
  local prev_char = 0
  for(let local t in values(tokens)){
    local cat = category_of(t.category)
    if(cat != null){
      local kind = cat.kind
      local line = t.line - 1
      local pos = t.start
      for(pos < t.stop){
        local line_start = starts[line]
        local line_end = t.stop
        local next_start = starts[line + 1]
        if(next_start != null and next_start <= t.stop){
          // the token continues on the next line: this piece ends before the newline
          line_end = next_start - 1
          if(line_end < pos){ line_end = pos }
        }
        local char = character_at(text, line_start, pos, encoding)
        local length = character_at(text, line_start, line_end, encoding) - char
        if(length > 0){
          local delta_line = line - prev_line
          local delta_char = char
          if(delta_line == 0){
            delta_char = char - prev_char
          }
          append(data, delta_line)
          append(data, delta_char)
          append(data, length)
          append(data, kind)
          append(data, cat.bits)
          prev_line = line
          prev_char = char
        }
        if(next_start == null or next_start > t.stop){
          break
        }
        pos = next_start
        line = line + 1
      }
    }
  }
  return data
}

// diagnostics(text, list, encoding) -> LSP diagnostics
local func lsp_diagnostics(text, list, encoding){
  local starts = str.line_starts(text)
  local out = json.array({})
  for(let local d in values(list)){
    local line = d.line - 1
    local line_start = starts[line] or 0
    local pos = line_start + d.column - 1
    local char = character_at(text, line_start, pos, encoding)
    local next_start = starts[line + 1] or len(text)
    local line_end = character_at(text, line_start, next_start, encoding)
    local end_char = char + 1
    if(end_char > line_end){ end_char = line_end }
    if(end_char < char){ end_char = char }
    append(out, {
      range: {start: {line: line, character: char}, ["end"]: {line: line, character: end_char}},
      severity: 1,
      source: "slang",
      message: d.message,
    })
  }
  return out
}

// ------------------------------------------------------------ the server

local methods = {}
local meta = {__index: methods}

// new({log}) -> server
func lsp.new(options){
  options = options or {}
  local s = {documents: {}, encoding: "utf-16", initialized: false, shutdown_requested: false, exited: false,
             log: options.log or func(text){}}
  s.meta = meta
  return s
}

local func response(id, result){
  return {jsonrpc: "2.0", id: id, result: result}
}

local func error_response(id, code, message){
  return {jsonrpc: "2.0", id: id, error: {code: code, message: message}}
}

local func notification(method, params){
  return {jsonrpc: "2.0", method: method, params: params}
}

// the diagnostics notification for a document, after highlighting it
local func analyse(s, uri){
  local doc = s.documents[uri]
  local r = pcall(compiler.highlight, doc.text, doc.path, {find_project: true})
  if(r[0] == "err"){
    local message = r[1]
    if(type(message) == "table"){ message = message.message }
    s.log(concat("highlight failed for ", uri, ": ", message))
    doc.tokens = {}
    doc.diagnostics = {{line: 1, column: 1, message: concat("the language server could not analyse this file: ", message)}}
  } else {
    doc.tokens = r[1].tokens
    doc.diagnostics = r[1].diagnostics
  }
  return notification("textDocument/publishDiagnostics", {uri: uri, version: doc.version, diagnostics: lsp_diagnostics(doc.text, doc.diagnostics, s.encoding)})
}

local func project_notification(s){
  local p = compiler.project()
  if(p == null){
    return null
  }
  local suffixes = json.array({})
  for(let local e in entries(p.dialects)){
    append(suffixes, e[0])
  }
  return notification("slang/project", {path: p.path, dialects: suffixes})
}

local handlers = {}

handlers["initialize"] = func(s, id, params){
  local encodings = ((params.capabilities or {}).general or {}).positionEncodings or {}
  for(let local e in values(encodings)){
    if(e == "utf-8"){
      s.encoding = "utf-8"
    }
  }
  s.initialized = true
  return {response(id, {
    capabilities: {
      positionEncoding: s.encoding,
      textDocumentSync: 1,
      semanticTokensProvider: {legend: {tokenTypes: json.array(lsp.token_types), tokenModifiers: json.array(lsp.token_modifiers)}, full: true},
    },
    serverInfo: {name: "slang", version: "0.1"},
  })}
}

handlers["shutdown"] = func(s, id, params){
  s.shutdown_requested = true
  return {response(id, null)}
}

handlers["exit"] = func(s, id, params){
  s.exited = true
  return {}
}

handlers["initialized"] = func(s, id, params){ return {} }
handlers["$/cancelRequest"] = func(s, id, params){ return {} }
handlers["$/setTrace"] = func(s, id, params){ return {} }

handlers["textDocument/didOpen"] = func(s, id, params){
  local td = params.textDocument
  s.documents[td.uri] = {uri: td.uri, path: lsp.uri_to_path(td.uri), text: td.text, version: td.version, tokens: {}, diagnostics: {}}
  local out = {analyse(s, td.uri)}
  local p = project_notification(s)
  if(p != null){ append(out, p) }
  return out
}

handlers["textDocument/didChange"] = func(s, id, params){
  local td = params.textDocument
  local doc = s.documents[td.uri]
  if(doc == null){
    return {}
  }
  // full sync: the last change carries the whole text
  for(let local change in values(params.contentChanges or {})){
    doc.text = change.text
  }
  doc.version = td.version
  return {analyse(s, td.uri)}
}

handlers["textDocument/didClose"] = func(s, id, params){
  local uri = params.textDocument.uri
  s.documents[uri] = null
  return {notification("textDocument/publishDiagnostics", {uri: uri, diagnostics: json.array({})})}
}

handlers["textDocument/semanticTokens/full"] = func(s, id, params){
  local doc = s.documents[params.textDocument.uri]
  if(doc == null){
    return {response(id, {data: json.array({})})}
  }
  return {response(id, {data: lsp.semantic_tokens(doc.text, doc.tokens, s.encoding)})}
}

// the project file or an extension changed: forget the grammars and look again
handlers["workspace/didChangeWatchedFiles"] = func(s, id, params){
  compiler.reset()
  local out = {}
  for(let local e in entries(s.documents)){
    append(out, analyse(s, e[0]))
  }
  local p = project_notification(s)
  if(p != null){ append(out, p) }
  return out
}

// handle(message) -> the messages to send in reply
func methods.handle(s, message){
  local method = message.method
  local id = message.id
  if(method == null){
    // a response to something the server sent: nothing to do
    return {}
  }
  local h = handlers[method]
  if(h == null){
    if(id != null){
      return {error_response(id, -32601, concat("method not found: ", method))}
    }
    return {}
  }
  local r = pcall(h, s, id, message.params or {})
  if(r[0] == "err"){
    local msg = r[1]
    if(type(msg) == "table"){ msg = msg.message }
    s.log(concat("error handling ", method, ": ", msg))
    if(id != null){
      return {error_response(id, -32603, msg)}
    }
    return {}
  }
  return r[1]
}

return lsp
