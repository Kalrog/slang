// lsp/server: the language server's logic, independent of the transport.
//
//   local server = require("lsp/server").new({log: func(text){ ... }})
//   local replies = server:handle(message)   // decoded JSON-RPC message
//
// handle returns the messages to send (responses and notifications). What
// the server speaks: initialize (semantic tokens, full document sync, a
// position encoding), didOpen/didChange/didClose, semanticTokens/full,
// publishDiagnostics, didChangeWatchedFiles (the project file changed: the
// grammars are reset), hover, definition, references, documentSymbol (the
// outline, under the `// ----` sections), documentHighlight,
// prepareRename/rename (refused for names outside the project and for
// fields with uses that cannot be told apart), workspace/symbol,
// inlayHint (parameter names; initializationOptions.parameterHints:
// "literals", "all" or "none"), completion (members, names in scope,
// keywords, module names), signatureHelp, lint diagnostics (unused locals,
// undefined globals, missing modules, calls that do not fit the typed docs
// of what they call; initializationOptions.lint),
// formatting and rangeFormatting (slang fmt's formatter), hover and
// definition on extension syntax, slang.project keys (completion, hover,
// checks), slang/expand (the expanded file), slang/tests (a test file's
// groups and tests), slang/highlights (documentHighlight over all the
// cells of a notebook), notebooks (notebookDocument/didOpen, didChange,
// didClose: the slang cells of a notebook are analysed as one document,
// and each cell is asked about by its own uri), shutdown, exit.
// Highlighting and the symbols come from one compiler.highlight, so
// extensions and dialects are the real ones; lsp/navigate answers the
// questions about names.
local compiler = require("slang/compiler")
local str = require("slang/string")
local json = require("slang/json")
local os = require("slang/os")
local navigate = require("lsp/navigate")
local format = require("slang/format")
local symbols = require("slang/symbols")
local ast = require("slang/ast")
local vm = require("slang/vm")
local utf8 = require("slang/utf8")

local lsp = {}

// The semantic token legend: slang's core categories first, then every
// standard LSP token type, so an extension can tag its tokens with any of
// them (`g:token(parser, "name", "enumMember")`); `punctuation` is slang's
// own type (the VS Code extension maps it to a scope). A category may carry
// standard modifiers after dots: "enumMember.declaration.readonly".
// Categories the legend does not know are not sent.
lsp.token_types = {
  "keyword", "variable", "number", "string", "comment", "operator",
  "punctuation", "namespace", "type", "class", "enum", "interface", "struct",
  "typeParameter", "parameter", "property", "enumMember", "event", "function",
  "method", "macro", "modifier", "regexp", "decorator"
}
lsp.token_modifiers = {
  "declaration", "definition", "readonly", "static", "deprecated", "abstract",
  "async", "modification", "documentation", "defaultLibrary"
}
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
      if(i >= 0 and
        str.lower(str.trim(str.substring(line, 0, i))) == "content-length"){
        length = to_int(str.trim(str.substring(line, i + 1)))
      }
    }
    if(length < 0){
      raise(error.new(error.kinds.format, "message without Content-Length"))
    }
    local body_start = head_end + 4
    if(len(buffer) < body_start + length){
      break
    }
    append(messages, json.decode(
      str.substring(buffer, body_start, body_start + length),
      "message",
    ))
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
  if(b >= '0' and b <= '9'){ return b - '0' }
  if(b >= 'a' and b <= 'f'){ return b - 'a' + 10 }
  if(b >= 'A' and b <= 'F'){ return b - 'A' + 10 }
  return 0
}

// uri_to_path("file:///a/b%20c.slang") -> "/a/b c.slang"
func lsp.uri_to_path(uri){
  local path = uri
  if(str.starts_with(path, "file://")){
    path = str.substring(path, 7)
  } else {
    // another scheme (the client's view of a file's expanded code,
    // slang-expanded:/dir/x.expanded.slang): the path it names, next to
    // the file it shows, so that it is under that file's project
    local colon = str.index_of(path, ":/")
    if(colon > 0 and not str.contains(str.substring(path, 0, colon), "/")){
      path = str.substring(path, colon + 1)
    }
  }
  local out = {}
  local i = 0
  local n = len(path)
  for(i < n){
    if(str.byte_at(path, i) == '%' and i + 2 < n){
      append(out, utf8.char(hex_value(str.char_at(path, i + 1)) * 16 + hex_value(
          str.char_at(path, i + 2),
        )))
      i = i + 3
    } else {
      append(out, str.char_at(path, i))
      i = i + 1
    }
  }
  return str.join(out, "")
}

local HEX = "0123456789ABCDEF"

// path_to_uri("/a/b c.slang") -> "file:///a/b%20c.slang"
func lsp.path_to_uri(path){
  local out = {"file://"}
  for(local i = 0; i < len(path); i = i + 1){
    local b = str.byte_at(path, i)
    local safe = (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or
      (b >= 'a' and b <= 'z') or b == '/' or b == '-' or b == '.' or b == '_' or
      b == '~'
    if(safe){
      append(out, str.char_at(path, i))
    } else {
      append(out, concat(
        "%",
        str.char_at(HEX, b >> 4),
        str.char_at(HEX, b & 15),
      ))
    }
  }
  return str.join(out, "")
}

// the character offset of a byte position within its line, in the encoding
local func character_at(text, line_start, pos, encoding){
  if(encoding == "utf-8"){
    return pos - line_start
  }
  return utf8.utf16_len(str.substring(text, line_start, pos))
}

// offset_of(text, {line, character}, encoding) -> the byte offset of an LSP
// position (clamped to its line)
func lsp.offset_of(text, position, encoding){
  local starts = str.line_starts(text)
  local line_start = starts[position.line]
  if(line_start == null){
    return len(text)
  }
  local line_end = starts[position.line + 1]
  if(line_end == null){
    line_end = len(text)
  } else {
    line_end = line_end - 1
  }
  local pos = line_start
  local units = 0
  for(pos < line_end and units < position.character){
    local b = str.byte_at(text, pos)
    local size = 1
    local width = 1
    if(b >= 240){
      size = 4
      width = 2
    } else if(b >= 224){
      size = 3
    } else if(b >= 192){
      size = 2
    }
    if(encoding == "utf-8"){
      width = size
    }
    pos = pos + size
    units = units + width
  }
  if(pos > line_end){
    pos = line_end
  }
  return pos
}

// range_of(text, start, stop, encoding) -> an LSP range of byte offsets
func lsp.range_of(text, start, stop, encoding){
  local a = str.line_col(text, start)
  local b = str.line_col(text, stop)
  local starts = str.line_starts(text)
  return {
    start: {
      line: a[0] - 1,
      character: character_at(text, starts[a[0] - 1], start, encoding),
    },
    ["end"]: {
      line: b[0] - 1,
      character: character_at(text, starts[b[0] - 1], stop, encoding),
    },
  }
}

// The parser's categories, sharpened where the editor's TextMate grammar
// says more (VS Code paints semantic tokens over it, so a plainer token
// would hide what it shows): local, func, extension and global declare, true,
// false and null are constants, and, or and not operators; a name before (
// is a function (after func, the one defined); a string leaves its escapes
// to the grammar.
local declaration_words = {
  ["local"]: true, ["func"]: true, ["extension"]: true, ["global"]: true
}
local constant_words = {["true"]: true, ["false"]: true, ["null"]: true}
local operator_words = {["and"]: true, ["or"]: true, ["not"]: true}

local func is_hex(c){
  return c != "" and str.index_of("0123456789abcdefABCDEF", c) >= 0
}

// whether the next character after pos on its line, past blanks, is (
local func before_call(text, pos){
  for(pos < len(text)){
    local c = str.char_at(text, pos)
    if(c != " " and c != "\t"){
      return c == "("
    }
    pos = pos + 1
  }
  return false
}

// escape_end(text, i, stop) -> where the escape at i (a backslash) ends:
// \x41, \u{1F600} or a backslash and one character, as the grammar has it
local func escape_end(text, i, stop){
  local c = str.char_at(text, i + 1)
  if(c == "x" and i + 3 < stop and is_hex(str.char_at(text, i + 2)) and
    is_hex(str.char_at(text, i + 3))){
    return i + 4
  }
  if(c == "u" and str.char_at(text, i + 2) == "{"){
    local j = i + 3
    for(j < stop and is_hex(str.char_at(text, j))){
      j = j + 1
    }
    if(j > i + 3 and j < stop and str.char_at(text, j) == "}"){
      return j + 1
    }
  }
  return i + 2
}

// a "..." string token, in pieces around its escapes, onto out
local func string_pieces(text, t, out){
  local line = t.line
  local from = t.start
  local from_line = line
  local i = t.start + 1
  for(i < t.stop){
    local c = str.char_at(text, i)
    if(c == "\\" and i + 1 < t.stop and str.char_at(text, i + 1) != "\n"){
      if(i > from){
        append(out, {line: from_line, start: from, stop: i, category: t.category})
      }
      i = escape_end(text, i, t.stop)
      from = i
      from_line = line
    } else {
      if(c == "\n"){ line = line + 1 }
      i = i + 1
    }
  }
  if(t.stop > from){
    append(out, {line: from_line, start: from, stop: t.stop, category: t.category})
  }
}

// refine(text, tokens) -> the tokens with the categories above
local func refine(text, tokens){
  local out = {}
  local defining = false
  for(let local t in values(tokens)){
    local c = t.category
    local word = null
    local name = c == "variable" or c == "identifier"
    if(c == "keyword" or name or c == "punctuation"){
      word = str.substring(text, t.start, t.stop)
    }
    if(c == "keyword"){
      if(declaration_words[word]){
        c = "keyword.declaration"
      } else if(constant_words[word]){
        c = "keyword.readonly"
      } else if(operator_words[word]){
        c = "operator"
      }
    } else if(name){
      if(defining){
        c = "function.declaration"
      } else if(before_call(text, t.stop)){
        c = "function"
      }
    }
    // the name after func, a.b:c included, is the one defined
    if(word == "func"){
      defining = true
    } else if(not (c == "function.declaration" or word == "." or word == ":")){
      defining = false
    }
    if(c == "string" and str.char_at(text, t.start) == "\"" and
      not str.starts_with(str.substring(text, t.start, t.stop), "\"\"\"")){
      string_pieces(text, t, out)
    } else if(c == t.category){
      append(out, t)
    } else {
      append(out, {line: t.line, start: t.start, stop: t.stop, category: c})
    }
  }
  return out
}

// semantic_tokens(text, tokens, encoding) -> the LSP data array: for every
// token (split at line breaks) deltaLine, deltaStart, length, type, modifiers
func lsp.semantic_tokens(text, tokens, encoding){
  local starts = str.line_starts(text)
  local data = json.array({})
  local prev_line = 0
  local prev_char = 0
  for(let local t in values(refine(text, tokens))){
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
// LSP's DiagnosticSeverity for the compiler's names
local severities = {error: 1, warning: 2, information: 3, hint: 4}

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
      range: {
        start: {line: line, character: char},
        ["end"]: {line: line, character: end_char},
      },
      severity: severities[d.severity] or 1,
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
  local s = {
    documents: {}, encoding: "utf-16", initialized: false,
    shutdown_requested: false, exited: false, log: options.log or func(text){},
    root: options.root, nav: null, parameter_hints: "literals", lint: true,
    lint_globals: {}, lint_modules: {}, notebooks: {}, cells: {}
  }
  s.@meta = meta
  // every file under its own project (a folder may hold several)
  compiler.workspace()
  return s
}

// the navigator, made at first need: the workspace folder is its root
// (else the working directory)
local func nav_of(s){
  if(s.nav == null){
    s.nav = navigate.new({root: s.root or os.cwd()})
    for(let local e in entries(s.documents)){
      local doc = e[1]
      s.nav:open(doc.path, doc.symbols_text or doc.text, doc.symbols, doc.ast)
    }
  }
  return s.nav
}

// a response always has its result, null included (the key holds null)
local func response(id, result){
  return {jsonrpc: "2.0", id: id, result: result}
}

local func error_response(id, code, message){
  return {jsonrpc: "2.0", id: id, error: {code: code, message: message}}
}

local func notification(method, params){
  return {jsonrpc: "2.0", method: method, params: params}
}

local lint = null
local cell_diagnostics = null
local in_notebook_folder = null
local project_lint = null
local project_completion = null
local project_hover = null

local func is_project_file(path){
  return str.ends_with(path, "slang.project")
}

// ------------------------------------------------------------ lint
//
// What compiles but is likely a mistake, for a document whose text parses:
// a local never used, a global named in lowercase (the convention: globals
// start with an uppercase letter), a global read but defined nowhere (not
// in the file, not built in, not in the project), a require of a module
// that does not exist, and a require of a computed name. Whether a global or a module
// exists is cached by name; the cache is cleared when a document's globals
// change or the project does.

local SEVERITY = {warning: 2, information: 3, hint: 4}

// the text up to its first space or line break
local func first_word(t){
  for(local i = 0; i < len(t); i = i + 1){
    local b = str.byte_at(t, i)
    if(b == ' ' or b == '\n'){
      return str.substring(t, 0, i)
    }
  }
  return t
}

// where the doc above a statement at pos writes what (its first word, the
// signature's lines having been joined): the last place before pos in
// the comment lines right above it, or null
local func doc_text_at(text, pos, what){
  local word = first_word(what)
  // (from the start of the statement's line: `local func f` starts at func)
  local from = pos
  for(from > 0 and str.byte_at(text, from - 1) != '\n'){
    from = from - 1
  }
  // the comment block: the // lines right above the statement
  for(true){
    local line_start = from
    if(line_start <= 0){
      break
    }
    local k = line_start - 2
    for(k >= 0 and str.byte_at(text, k) != '\n'){
      k = k - 1
    }
    local prev = k + 1
    if(not str.starts_with(str.trim(str.substring(text, prev, line_start)), "//")){
      break
    }
    from = prev
  }
  local found = null
  local i = str.index_of(text, word, from)
  for(i >= 0 and i < pos){
    found = i
    i = str.index_of(text, word, i + 1)
  }
  return found
}

local func is_name_char(b){
  return b != null and (b == '_' or (b >= '0' and b <= '9') or
    (b >= 'A' and b <= 'Z') or (b >= 'a' and b <= 'z'))
}

// the locals of required modules a doc names a type through (`thing.Game`
// in a comment): they are used, though no code reads them
local func doc_type_modules(text){
  local out = {}
  local i = str.index_of(text, "//")
  for(i >= 0){
    local stop = str.index_of(text, "\n", i)
    if(stop < 0){
      stop = len(text)
    }
    local line = str.substring(text, i, stop)
    // name.Capitalized
    for(local k = 1; k + 1 < len(line); k = k + 1){
      local c = str.byte_at(line, k + 1)
      if(str.byte_at(line, k) == '.' and c >= 'A' and c <= 'Z'){
        local a = k
        for(a > 0 and is_name_char(str.byte_at(line, a - 1))){
          a = a - 1
        }
        if(a < k){
          out[str.substring(line, a, k)] = true
        }
      }
    }
    i = str.index_of(text, "//", stop)
  }
  return out
}

local func lint_diagnostic(doc, start, stop, message, severity, tags){
  local d = {
    range: lsp.range_of(doc.text, start, stop, doc.encoding),
    severity: severity,
    source: "slang",
    message: message,
  }
  if(tags != null){
    d.tags = json.array(tags)
  }
  return d
}

// a name an extension made up is not written where it is
local func written_at(text, start, stop, name){
  return start != null and str.substring(text, start, stop) == name
}

// whether a global is defined somewhere: the file, a built-in, the project
local func global_known(s, doc, name){
  // the globals of this VM (require, module, ...) are every slang's
  if(doc.symbols.globals[name] != null or str.starts_with(name, "__") or
    _ENV[name] != null){
    return true
  }
  local hit = s.lint_globals[name]
  if(hit == null){
    hit = nav_of(s):lookup(doc.path, name, 0) != null
    s.lint_globals[name] = hit
  }
  return hit
}

// whether require(name) finds a module
local func module_known(s, name){
  // (per project: what require finds depends on its search paths)
  local p = compiler.project()
  local key = concat(
    p and p.path or "", "\n", string((__PACKAGES.search_paths or {})[0]), "\n",
    name
  )
  local hit = s.lint_modules[key]
  if(hit == null){
    hit = __PACKAGES.preloaded[name] != null or vm.embedded(name) != null or
      compiler.module_path(name) != null or
      (try { __PACKAGES.native_file(name) } catch { null }) != null
    s.lint_modules[key] = hit
  }
  return hit
}

// the byte after pos and the spaces that follow it (-1 at the end)
local func byte_after_space(text, pos){
  for(pos < len(text) and (str.byte_at(text, pos) == ' ' or
    str.byte_at(text, pos) == '\t')){
    pos = pos + 1
  }
  if(pos >= len(text)){
    return -1
  }
  return str.byte_at(text, pos)
}

lint = func(s, doc){
  local out = {}
  local index = doc.symbols
  local text = doc.text
  doc.encoding = s.encoding
  // the globals this document defines: a change clears the caches
  local names = {}
  for(let local k in keys(index.globals)){
    append(names, k)
  }
  local signature = str.join(names, ",")
  if(doc.globals_signature != null and doc.globals_signature != signature){
    s.lint_globals = {}
  }
  doc.globals_signature = signature
  local used = {}
  for(let local r in values(index.refs)){
    if(r.def != null){
      used[r.def] = true
    }
  }
  local in_docs = null
  for(let local d in values(index.defs)){
    if(d.kind == "local" and d.module != null and not used[d]){
      in_docs = in_docs or doc_type_modules(text)
      used[d] = in_docs[d.name]
    }
  }
  for(let local d in values(index.defs)){
    // (a notebook's top-level locals stay for the cells yet to be written)
    if(d.kind == "local" and not used[d] and
      not str.starts_with(d.name, "_") and
      not (doc.notebook != null and d.scope == null) and
      written_at(text, d.start, d.stop, d.name)){
      append(out, lint_diagnostic(
        doc,
        d.start,
        d.stop,
        concat(d.name, " is never used"),
        SEVERITY.hint,
        {1},
      ))
    }
  }
  // globals start with an uppercase letter, so that one made by mistake (a
  // typo, a missing `local`) stands out; a lowercase one declared with
  // `global` is meant, and the globals of this VM (print, require, ...)
  // are lowercase and are not made here
  for(let local d in values(index.globals)){
    local b = str.byte_at(d.name, 0)
    if(b >= 'a' and b <= 'z' and not d.explicit and _ENV[d.name] == null and
      written_at(text, d.start, d.stop, d.name)){
      append(out, lint_diagnostic(doc, d.start, d.stop, concat(
        d.name,
        " is a global (globals start with an uppercase letter; is a local meant, or `global`?)",
      ), SEVERITY.warning))
    }
  }
  // a doc's parameter type that is not in the notation: the parameter is
  // read untyped; marked where the doc writes it
  for(let local d in values(index.defs)){
    local sig = d.info and d.info.signature
    if(sig != null and d.statement != null and written_at(text, d.start, d.stop, d.name)){
      for(let local p in values(sig.params)){
        if(p.malformed != null){
          local at = doc_text_at(text, d.statement, p.malformed)
          local start = at or d.start
          local stop = at and at + len(first_word(p.malformed)) or d.stop
          append(out, lint_diagnostic(doc, start, stop, concat(
            "the doc's type of ", p.name, " is not in the doc notation: ",
            p.malformed, " (the parameter is read untyped)"
          ), SEVERITY.warning))
        }
      }
    }
  }
  for(let local decl in values(index.types or {})){
    if(decl.malformed != null and written_at(text, decl.start, decl.stop, decl.name)){
      append(out, lint_diagnostic(doc, decl.start, decl.stop, concat(
        "type ", decl.name, " is not in the doc notation: ", decl.malformed,
        " (the type is not declared)"
      ), SEVERITY.warning))
    }
  }
  local reported = {}
  for(let local r in values(index.refs)){
    if(r.def == null and r.owner == null and not r.write and
      not reported[r.name] and written_at(text, r.start, r.stop, r.name) and
      not global_known(s, doc, r.name)){
      reported[r.name] = true
      local message = concat(
        r.name, " is not defined (a global no file of the project assigns)"
      )
      if(r.name == "pcall"){
        message = "pcall is not defined (slang catches errors with try/catch)"
      }
      append(out, lint_diagnostic(doc, r.start, r.stop, message, SEVERITY.warning))
    }
  }
  // a call of the global error: it is the error library, not a function
  // (raise raises); error.new and the like are not flagged
  for(let local r in values(index.refs)){
    if(r.name == "error" and r.def == null and r.owner == null and
      not r.write and written_at(text, r.start, r.stop, r.name) and
      byte_after_space(text, r.stop) == '('){
      append(out, lint_diagnostic(
        doc, r.start, r.stop, "error is the error library, not a function: raise(error.new(kind, message))", SEVERITY.warning
      ))
    }
  }
  if(doc.ast != null){
    local found = ast.requires(doc.ast)
    for(let local q in values(found.names)){
      local stop = q.pos + 7
      if(q.pos >= 0 and q.pos < len(text) and not module_known(s, q.name)){
        append(out, lint_diagnostic(
          doc,
          q.pos,
          stop,
          concat("module ", q.name, " not found"),
          SEVERITY.warning,
        ))
      }
    }
    // calls that do not fit the typed docs of what they call
    for(let local c in values(nav_of(s):check_calls(doc.path, doc.ast))){
      append(out, lint_diagnostic(
        doc, c.start, c.stop, c.message, SEVERITY.warning
      ))
    }
    for(let local pos in values(found.computed)){
      if(pos >= 0 and pos < len(text)){
        append(out, lint_diagnostic(
          doc,
          pos,
          pos + 7,
          "require of a computed name: slang build cannot tell which module it loads",
          SEVERITY.hint,
        ))
      }
    }
  }
  return out
}

// the diagnostics notification for a document, after highlighting it
local func analyse(s, uri){
  local doc = s.documents[uri]
  local h = null
  local message = null
  try {
    h = compiler.for_file(doc.path, func(){
      return compiler.highlight(doc.text, doc.path, {
        find_project: true, symbols: true, cells: doc.cell_ends
      })
    })
  } catch(local e) {
    message = e.message
  }
  if(message != null){
    s.log(concat("highlight failed for ", uri, ": ", message))
    doc.tokens = {}
    doc.diagnostics = {
      {
        line: 1, column: 1, message: concat(
          "the language server could not analyse this file: ",
          message,
        )
      },
    }
  } else {
    doc.tokens = h.tokens
    doc.diagnostics = h.diagnostics
    // while an edit does not parse, the symbols of the last text that did
    // stay (a recovered parse leaves out the statement being typed, its
    // locals with it); a file that never parsed takes what there is
    local clean = len(h.diagnostics) == 0
    if(h.symbols != null and (clean or doc.symbols == null)){
      doc.symbols = h.symbols
      doc.symbols_text = doc.text
      doc.ast = h.ast
    }
  }
  if(s.nav != null){
    s.nav:open(doc.path, doc.symbols_text or doc.text, doc.symbols, doc.ast)
  }
  local diagnostics = lsp_diagnostics(doc.text, doc.diagnostics, s.encoding)
  // a project file that failed to load: the file was read as plain slang
  local pe = compiler.project_error(doc.path)
  if(pe != null){
    append(diagnostics, {
      range: lsp.range_of(doc.text, 0, 0, s.encoding),
      severity: 1,
      source: "slang",
      message: concat(
        pe.path, " failed to load, so this file is read as plain slang: ",
        pe.message
      ),
    })
  }
  if(is_project_file(doc.path) and len(doc.diagnostics) == 0){
    for(let local d in values(project_lint(s, doc))){
      append(diagnostics, d)
    }
  }
  // the lint needs the index of this very text
  if(s.lint and len(doc.diagnostics) == 0 and doc.symbols_text == doc.text and
    not is_project_file(doc.path)){
    local found = {}
    try {
      found = lint(s, doc)
    } catch(local e) {
      s.log(concat("lint failed for ", uri, ": ", e.message))
    }
    for(let local d in values(found)){
      append(diagnostics, d)
    }
  }
  return notification("textDocument/publishDiagnostics", {
    uri: uri, version: doc.version, diagnostics: diagnostics
  })
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
  if(s.root == null and type(params.rootUri) == "string"){
    s.root = lsp.uri_to_path(params.rootUri)
  }
  local encodings = ((params.capabilities or {}).general or {}).positionEncodings or
    {}
  for(let local e in values(encodings)){
    if(e == "utf-8"){
      s.encoding = "utf-8"
    }
  }
  s.initialized = true
  // which arguments get their parameter's name: "literals", "all" or "none"
  local init = params.initializationOptions or {}
  local hints = init.parameterHints
  if(hints == "all" or hints == "none" or hints == "literals"){
    s.parameter_hints = hints
  }
  if(init.lint == false){
    s.lint = false
  }
  return {
    response(id, {
      capabilities: {
        positionEncoding: s.encoding,
        textDocumentSync: 1,
        // the slang cells of any notebook (see the notebooks section)
        notebookDocumentSync: {
          notebookSelector: json.array({
            {notebook: "*", cells: json.array({{language: "slang"}})},
          }),
        },
        hoverProvider: true,
        documentFormattingProvider: true,
        documentRangeFormattingProvider: true,
        definitionProvider: true,
        referencesProvider: true,
        documentSymbolProvider: true,
        documentHighlightProvider: true,
        renameProvider: {prepareProvider: true},
        workspaceSymbolProvider: true,
        inlayHintProvider: true,
        // (. and : for members, " and / for modules, { and , for the
        // fields of a table literal)
        completionProvider: {
          triggerCharacters: {".", ":", "\"", "/", "{", ","},
        },
        signatureHelpProvider: {
          triggerCharacters: {"(", ","},
          retriggerCharacters: {")"},
        },
        semanticTokensProvider: {
          legend: {
            tokenTypes: json.array(lsp.token_types),
            tokenModifiers: json.array(lsp.token_modifiers),
          },
          full: true,
        },
      },
      serverInfo: {name: "slang", version: "0.1"},
    }),
  }
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
  s.documents[td.uri] = {
    uri: td.uri, path: lsp.uri_to_path(td.uri), text: td.text,
    version: td.version, tokens: {}, diagnostics: {}
  }
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
  local doc = s.documents[uri]
  if(doc != null and s.nav != null){
    s.nav:close(doc.path)
  }
  delete(s.documents, uri)
  return {
    notification("textDocument/publishDiagnostics", {
      uri: uri,
      diagnostics: json.array({}),
    }),
  }
}

handlers["textDocument/semanticTokens/full"] = func(s, id, params){
  local doc = s.documents[params.textDocument.uri]
  if(doc == null){
    return {response(id, {data: json.array({})})}
  }
  return {
    response(id, {data: lsp.semantic_tokens(doc.text, doc.tokens, s.encoding)}),
  }
}

// the project file or an extension changed: forget the grammars and look again
handlers["workspace/didChangeWatchedFiles"] = func(s, id, params){
  // every project's grammar is made anew (an extension of any may have
  // changed)
  compiler.forget_project()
  s.lint_globals = {}
  s.lint_modules = {}
  if(s.nav != null){
    s.nav:forget_files()
  }
  local out = {}
  for(let local e in entries(s.documents)){
    if(e[1].notebook != null){
      local notes = compiler.for_file(e[1].path, func(){
        return in_notebook_folder(e[1].path, func(){
          return cell_diagnostics(s, e[1], analyse(s, e[0]))
        })
      })
      for(let local n in values(notes)){
        append(out, n)
      }
    } else {
      append(out, analyse(s, e[0]))
    }
  }
  local p = project_notification(s)
  if(p != null){ append(out, p) }
  return out
}

// ------------------------------------------------------------ names

// the document and byte offset of a request's position
local func position_of(s, params){
  local doc = s.documents[params.textDocument.uri]
  if(doc == null){
    return null
  }
  // the symbols are of the text they were made from
  local text = doc.symbols_text or doc.text
  return {
    doc: doc, text: text, pos: lsp.offset_of(text, params.position, s.encoding)
  }
}

// LSP locations of {path, start, stop} results
local func locations(s, list){
  local out = json.array({})
  local nav = nav_of(s)
  for(let local l in values(list)){
    local f = nav:file(l.path)
    if(f != null){
      append(out, {
        uri: lsp.path_to_uri(l.path),
        range: lsp.range_of(f.text, l.start, l.stop, s.encoding),
      })
    }
  }
  return out
}

// the name at pos when pos is in a // comment (a [name] or a type of a
// signature): letters, digits, _ and dots around it; null elsewhere
local func comment_ref_at(text, pos){
  local ls = pos
  for(ls > 0 and str.char_at(text, ls - 1) != "\n"){
    ls = ls - 1
  }
  local slash = str.index_of(text, "//", ls)
  if(slash < 0 or slash > pos){
    return null
  }
  local func name_char(i){
    local b = str.byte_at(text, i)
    return (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or
      (b >= 'a' and b <= 'z') or b == '_' or b == '.'
  }
  local a = pos
  for(a > slash + 2 and name_char(a - 1)){
    a = a - 1
  }
  local b = pos
  for(b < len(text) and name_char(b)){
    b = b + 1
  }
  if(a == b){
    return null
  }
  local name = str.substring(text, a, b)
  // a sentence's final dot is not part of the name
  for(str.ends_with(name, ".")){
    name = str.substring(name, 0, len(name) - 1)
  }
  return len(name) > 0 and name or null
}

// the module a require at pos names (pos on the word require or in the
// string after it): {name, path}, path its file as require finds it (null
// when it cannot), or null when pos is not on a require
local func required_at(text, pos){
  local func name_from(open){
    // open: the offset of the string's opening quote
    if(open < 8 or str.substring(text, open - 8, open) != "require("){
      return null
    }
    local close = str.index_of(text, "\"", open + 1)
    if(close < 0 or str.index_of(str.substring(text, open, close), "\n") >= 0){
      return null
    }
    local name = str.substring(text, open + 1, close)
    return {name: name, path: compiler.module_path(name)}
  }
  // in the string: back to its opening quote
  local i = pos
  for(i > 0 and str.char_at(text, i - 1) != "\"" and
    str.char_at(text, i - 1) != "\n"){
    i = i - 1
  }
  if(i > 0 and str.char_at(text, i - 1) == "\""){
    local found = name_from(i - 1)
    if(found != null){
      return found
    }
  }
  // on the word require: the string after it
  local start = pos
  for(start > 0 and str.char_at(text, start - 1) != " " and
    str.char_at(text, start - 1) != "(" and
    str.char_at(text, start - 1) != "\n" and str.char_at(text, start - 1) != "="){
    start = start - 1
  }
  // (the file may end sooner)
  if(str.starts_with(text, "require(\"", start)){
    return name_from(start + 8)
  }
  return null
}

// the extension whose syntax is at pos (not core syntax): {name, path},
// path its source (null when require cannot find it)
local func extension_at(at){
  // the tree is kept for the text it is of: hovers that find no name ask
  // for it again and again
  local doc = at.doc
  if(doc.tree_text != at.text){
    doc.tree = (try {
      compiler.tree(at.text, doc.path, {find_project: true})
    } catch { null }) or false
    doc.tree_text = at.text
  }
  if(not doc.tree){
    return null
  }
  local owner = format.owner_at(doc.tree, at.pos)
  if(owner == null){
    return null
  }
  return {name: owner, path: compiler.module_path(owner)}
}

handlers["textDocument/definition"] = func(s, id, params){
  local at = position_of(s, params)
  if(at == null){
    return {response(id, json.array({}))}
  }
  // in a doc comment: what a [name] or a type names
  local ref = comment_ref_at(at.text, at.pos)
  if(ref != null){
    local target = nav_of(s):doc_definition(at.doc.path, ref)
    local out = json.array({})
    if(target != null){
      append(out, locations(s, {target})[0])
    }
    return {response(id, out)}
  }
  // a require: the module's file
  local module = required_at(at.text, at.pos)
  if(module != null){
    local out = json.array({})
    if(module.path != null){
      append(out, {
        uri: lsp.path_to_uri(module.path),
        range: {
          start: {line: 0, character: 0},
          ["end"]: {line: 0, character: 0},
        },
      })
    }
    return {response(id, out)}
  }
  local found = locations(s, nav_of(s):definition(at.doc.path, at.pos))
  if(len(found) == 0){
    // extension syntax: the extension's source
    local ext = extension_at(at)
    if(ext != null and ext.path != null){
      append(found, {
        uri: lsp.path_to_uri(ext.path),
        range: {
          start: {line: 0, character: 0},
          ["end"]: {line: 0, character: 0},
        },
      })
    }
  }
  return {response(id, found)}
}

handlers["textDocument/references"] = func(s, id, params){
  local at = position_of(s, params)
  if(at == null){
    return {response(id, json.array({}))}
  }
  local with_declaration = (params.context or {}).includeDeclaration == true
  local found = nav_of(s):references(at.doc.path, at.pos, with_declaration)
  return {response(id, locations(s, found))}
}

// (the hover of a table literal's key, defined with the literals' completion)
local field_hover = null

handlers["textDocument/hover"] = func(s, id, params){
  local at = position_of(s, params)
  if(at == null){
    return {response(id, null)}
  }
  if(is_project_file(at.doc.path)){
    at.pos = lsp.offset_of(at.doc.text, params.position, s.encoding)
    return {response(id, project_hover(s, at))}
  }
  // a require: what the module's file says it is
  local module = required_at(at.text, at.pos)
  if(module != null){
    local lines = {concat("```slang\nmodule \"", module.name, "\"\n```")}
    if(module.path == null){
      append(lines, "not found")
    } else {
      local f = nav_of(s):file(module.path)
      if(f != null and f.index.module_doc != null){
        append(lines, navigate.markdown(f.index.module_doc))
      }
      append(lines, concat("*", nav_of(s):shown(module.path), "*"))
    }
    return {
      response(id, {
        contents: {kind: "markdown", value: str.join(lines, "\n\n")},
      }),
    }
  }
  // a key of a table literal that is to be a documented shape: the field
  local fh = field_hover(
    s, at.doc, lsp.offset_of(at.doc.text, params.position, s.encoding)
  )
  if(fh != null){
    return {
      response(id, {
        contents: {kind: "markdown", value: fh.markdown},
        range: lsp.range_of(at.doc.text, fh.start, fh.stop, s.encoding),
      }),
    }
  }
  local h = nav_of(s):hover(at.doc.path, at.pos)
  if(h == null){
    // extension syntax: which extension, and what its file says it is
    local ext = extension_at(at)
    if(ext == null){
      return {response(id, null)}
    }
    local lines = {concat("```slang\nextension \"", ext.name, "\"\n```")}
    if(ext.path != null){
      local f = nav_of(s):file(ext.path)
      if(f != null and f.index.module_doc != null){
        append(lines, navigate.markdown(f.index.module_doc))
      }
      append(lines, concat("*", nav_of(s):shown(ext.path), "*"))
    }
    return {
      response(id, {
        contents: {kind: "markdown", value: str.join(lines, "\n\n")},
      }),
    }
  }
  return {
    response(id, {
      contents: {kind: "markdown", value: h.markdown},
      range: lsp.range_of(at.text, h.start, h.stop, s.encoding),
    }),
  }
}

// ------------------------------------------------------------ outline

// LSP symbol kinds
local SYMBOL = {
  module: 2, namespace: 3, method: 6, field: 8, fn: 12, variable: 13
}

local func symbol_kind(def){
  if(def.module != null){
    return SYMBOL.module
  }
  if(def.params != null){
    return def.kind == "field" and SYMBOL.method or SYMBOL.fn
  }
  if(def.kind == "field"){
    return SYMBOL.field
  }
  return SYMBOL.variable
}

// where a definition's statement ends: its value's end when the value is
// in this text, else its name's
local func def_end(def, text){
  local v = def.value
  if(v != null and v.token != null and v.token.buffer == text and
    v.token.stop != null and v.token.stop > def.stop){
    return v.token.stop
  }
  return def.stop
}

// whether a definition's name is written where it is (not one an extension
// made up, like sql{}'s statement caches)
local func written(def, text){
  return def.start != null and
    str.substring(text, def.start, def.stop) == def.name
}

// the outline of a document: its top-level definitions with the fields
// they hold, under the `// ---- title` sections they are in
local func outline(doc, encoding){
  local index = doc.symbols
  local text = doc.symbols_text
  local made = {}
  local top = {}
  local func symbol_of(def){
    local start = def.statement or def.start
    if(start > def.start){
      start = def.start
    }
    local detail = null
    if(def.params != null){
      detail = concat("(", str.join(def.params, ", "), ")")
    } else if(def.module != null){
      detail = concat("require(\"", def.module, "\")")
    }
    local sym = {
      name: def.name,
      kind: symbol_kind(def),
      range: lsp.range_of(text, start, def_end(def, text), encoding),
      selectionRange: lsp.range_of(text, def.start, def.stop, encoding),
      children: json.array({}),
      start: start,
    }
    // no detail key at all: the client checks `detail === undefined` to
    // tell a DocumentSymbol from a SymbolInformation, and null would fail it
    if(detail != null){
      sym.detail = detail
    }
    made[def] = sym
    return sym
  }
  for(let local def in values(index.defs)){
    local top_level = written(def, text) and
      ((def.kind == "local" and def.scope == null) or def.kind == "global")
    if(top_level){
      append(top, symbol_of(def))
    } else if(def.kind == "field" and def.owner != null and written(def, text)){
      local owner = made[def.owner]
      if(owner != null){
        append(owner.children, symbol_of(def))
      } else if(def.owner.global != null or def.owner == index.returned){
        // a field of a global or of the returned table no name holds
        local sym = symbol_of(def)
        if(def.owner.global != null){
          sym.name = concat(def.owner.name, ".", def.name)
        }
        append(top, sym)
      }
    }
  }
  local sections = index.sections or {}
  if(len(sections) == 0){
    return top
  }
  // the symbols before the first section stay at the top
  local out = {}
  local i = 0
  for(i < len(top) and top[i].start < sections[0].start){
    append(out, top[i])
    i = i + 1
  }
  for(local k = 0; k < len(sections); k = k + 1){
    local sec = sections[k]
    local stop = len(text)
    if(k + 1 < len(sections)){
      stop = sections[k + 1].start
    }
    local children = json.array({})
    for(i < len(top) and top[i].start < stop){
      append(children, top[i])
      i = i + 1
    }
    local name_stop = sec.start
    for(name_stop < len(text) and str.char_at(text, name_stop) != "\n"){
      name_stop = name_stop + 1
    }
    append(out, {
      name: sec.title,
      kind: SYMBOL.namespace,
      range: lsp.range_of(text, sec.start, stop, encoding),
      selectionRange: lsp.range_of(text, sec.start, name_stop, encoding),
      children: children,
    })
  }
  return out
}

// start is the server's own: LSP has no such member
local func strip_starts(list){
  for(let local sym in values(list)){
    delete(sym, "start")
    if(sym.children != null){
      strip_starts(sym.children)
    }
  }
  return list
}

handlers["textDocument/documentSymbol"] = func(s, id, params){
  local doc = s.documents[params.textDocument.uri]
  if(doc == null or doc.symbols == null){
    return {response(id, json.array({}))}
  }
  return {response(id, json.array(strip_starts(outline(doc, s.encoding))))}
}

// ------------------------------------------------------------ highlights

handlers["textDocument/documentHighlight"] = func(s, id, params){
  local at = position_of(s, params)
  if(at == null or at.doc.symbols == null){
    return {response(id, json.array({}))}
  }
  local index = at.doc.symbols
  local out = json.array({})
  // (the document alone is looked at: this is asked at every move)
  for(let local l in values(nav_of(s):highlights(at.doc.path, at.pos))){
    if(l.path == at.doc.path){
      local found = index.by_start[l.start]
      local write = found != null and (found.kind != null or found.write)
      append(out, {
        range: lsp.range_of(at.text, l.start, l.stop, s.encoding),
        kind: write and 3 or 2,
      })
    }
  }
  return {response(id, out)}
}

// ------------------------------------------------------------ rename

// whether name can be a slang name (and is not a keyword of the grammar)
local func valid_name(name){
  if(type(name) != "string" or len(name) == 0){
    return false
  }
  local parsed = try {
    compiler.parse(concat("local ", name, " = 1"), "rename")
  } catch { null }
  if(parsed == null){
    return false
  }
  local st = parsed.statements
  return len(st) == 1 and st[0].type == "Declaration" and
    st[0].left.type == "Identifier" and st[0].left.value == name
}

// the definition a rename at a position changes, as a location, or an
// error message
local func rename_target(s, at){
  if(at.doc.text != at.doc.symbols_text){
    return {error: "the file does not compile: fix it before renaming"}
  }
  local found = symbols.at(at.doc.symbols, at.pos)
  if(found == null){
    return {error: "there is no name here"}
  }
  local nav = nav_of(s)
  local defs = nav:definition(at.doc.path, at.pos)
  if(len(defs) == 0){
    return {error: concat(found.name, " is not defined in the project")}
  }
  local d = defs[0]
  if(nav.root == null or not str.starts_with(d.path, concat(nav.root, "/"))){
    return {
      error: concat(
        found.name, " is defined outside the project (", nav:shown(d.path), ")"
      ),
    }
  }
  // a field: uses whose owner cannot be told might be it, and would be missed
  if(found.kind == "field" or (found.kind == null and found.owner != null)){
    local known = {}
    for(let local l in values(nav:references(at.doc.path, at.pos, true))){
      known[concat(l.path, ":", string(l.start))] = true
    }
    local unsure = 0
    local example = null
    for(let local l in values(nav:unresolved_fields(found.name))){
      if(not known[concat(l.path, ":", string(l.start))]){
        unsure = unsure + 1
        example = example or l
      }
    }
    if(unsure > 0){
      local f = nav:file(example.path)
      local line = str.line_col(f.text, example.start)[0]
      return {
        error: concat(
          "not renamed: ",
          string(unsure),
          " use(s) of ",
          found.name,
          " cannot be told apart (the first in ",
          nav:shown(example.path),
          ":",
          string(line),
          ")",
        ),
      }
    }
  }
  return {found: found}
}

handlers["textDocument/prepareRename"] = func(s, id, params){
  local at = position_of(s, params)
  if(at == null or at.doc.symbols == null){
    return {response(id, null)}
  }
  local t = rename_target(s, at)
  if(t.error != null){
    return {error_response(id, -32803, t.error)}
  }
  return {
    response(id, {
      range: lsp.range_of(at.text, t.found.start, t.found.stop, s.encoding),
      placeholder: t.found.name,
    }),
  }
}

handlers["textDocument/rename"] = func(s, id, params){
  local at = position_of(s, params)
  if(at == null or at.doc.symbols == null){
    return {response(id, null)}
  }
  if(not valid_name(params.newName)){
    return {
      error_response(
        id, -32803, concat(string(params.newName), " is not a name")
      ),
    }
  }
  local t = rename_target(s, at)
  if(t.error != null){
    return {error_response(id, -32803, t.error)}
  }
  local nav = nav_of(s)
  local changes = {}
  local seen = {}
  for(let local l in values(nav:references(at.doc.path, at.pos, true))){
    local key = concat(l.path, ":", string(l.start))
    if(not seen[key]){
      seen[key] = true
      local f = nav:file(l.path)
      local uri = lsp.path_to_uri(l.path)
      if(changes[uri] == null){
        changes[uri] = json.array({})
      }
      append(changes[uri], {
        range: lsp.range_of(f.text, l.start, l.stop, s.encoding),
        newText: params.newName,
      })
    }
  }
  return {response(id, {changes: changes})}
}

// ------------------------------------------------------------ workspace symbols

// whether the letters of query appear in name in order (any case)
local func fuzzy(query, name){
  local q = str.lower(query)
  local n = str.lower(name)
  local i = 0
  for(local j = 0; j < len(n) and i < len(q); j = j + 1){
    if(str.char_at(n, j) == str.char_at(q, i)){
      i = i + 1
    }
  }
  return i == len(q)
}

local MAX_WORKSPACE_SYMBOLS = 300

handlers["workspace/symbol"] = func(s, id, params){
  local query = params.query or ""
  local nav = nav_of(s)
  local out = json.array({})
  for(let local path in values(nav:project_files())){
    local f = nav:file(path)
    if(f != null){
      local container = nav:shown(path)
      for(let local def in values(f.index.defs)){
        local wanted = def.kind == "global" or
          (def.kind == "field" and def.owner == f.index.returned) or
          (def.kind == "local" and def.scope == null and def.params != null)
        if(wanted and len(out) < MAX_WORKSPACE_SYMBOLS and
          written(def, f.text) and fuzzy(query, def.name)){
          append(out, {
            name: def.name,
            kind: symbol_kind(def),
            containerName: container,
            location: {
              uri: lsp.path_to_uri(path),
              range: lsp.range_of(f.text, def.start, def.stop, s.encoding),
            },
          })
        }
      }
    }
  }
  return {response(id, out)}
}

// ------------------------------------------------------------ inlay hints

local literal_types = {
  Int: true, Double: true, String: true, True: true, False: true, Null: true
}

// the calls in a tree whose start lies in [from, to): {node, name_start,
// invoke}
local func calls_in(node, text, from, to, out){
  if(node == null or ast.specs[node.type] == null or node.type == "Quote"){
    return out
  }
  local token = node.token
  local here = token != null and token.buffer == text and token.start != null
  if(here and (token.stop < from or token.start >= to)){
    return out
  }
  if(here and (node.type == "Call" or node.type == "Invoke")){
    local name = null
    if(node.type == "Invoke"){
      name = node.name.token
    } else if(node.function.type == "Identifier"){
      name = node.function.token
    } else if(node.function.type == "Index" and
      node.function.index.type == "String"){
      name = node.function.index.token
    }
    if(name != null and name.buffer == text){
      append(out, {
        node: node,
        name_start: name.start,
        invoke: node.type == "Invoke",
      })
    }
  }
  for(let local field in values(ast.specs[node.type])){
    local child = node[field[0]]
    if(child != null){
      if(field[1] == "list"){
        for(let local c in values(child)){
          calls_in(c, text, from, to, out)
        }
      } else if(field[1] != "value"){
        calls_in(child, text, from, to, out)
      }
    }
  }
  return out
}

handlers["textDocument/inlayHint"] = func(s, id, params){
  local doc = s.documents[params.textDocument.uri]
  if(doc == null or doc.ast == null or s.parameter_hints == "none"){
    return {response(id, json.array({}))}
  }
  local text = doc.symbols_text
  local from = lsp.offset_of(text, params.range.start, s.encoding)
  local to = lsp.offset_of(text, params.range["end"], s.encoding)
  local nav = nav_of(s)
  local cache = {}
  local out = json.array({})
  for(let local c in values(calls_in(doc.ast, text, from, to, {}))){
    local f = nav:callable(doc.path, c.name_start, cache)
    if(f != null){
      local params_list = f.params
      local first = 0
      if(c.invoke){
        // o:m(...) passes o as the first parameter
        first = 1
      }
      local args = c.node.args
      for(local i = 0; i < len(args) and first + i < len(params_list); i = i + 1){
        local arg = args[i]
        local name = params_list[first + i]
        if(arg.type == "Spread" or str.starts_with(name, "...")){
          break
        }
        local show = s.parameter_hints == "all" or
          literal_types[arg.type] == true
        if(arg.type == "Identifier" and arg.value == name){
          show = false
        }
        if(show and arg.token != null and arg.token.buffer == text){
          append(out, {
            position: lsp.range_of(
              text, arg.token.start, arg.token.start, s.encoding
            ).start,
            label: concat(name, ":"),
            kind: 2,
            paddingRight: true,
          })
        }
      }
    }
  }
  return {response(id, out)}
}

// ------------------------------------------------------------ the text at the cursor
//
// Completion and signature help work on the editor's text, which often does
// not parse while it is typed; names are looked up by name (navigate's
// lookup) at the position the index of the last text that parsed has.

local func is_word_byte(b){
  return (b >= '0' and b <= '9') or (b >= 'A' and b <= 'Z') or
    (b >= 'a' and b <= 'z') or b == '_'
}

// the start of the word that ends at pos
local func word_start(text, pos){
  local i = pos
  for(i > 0 and is_word_byte(str.byte_at(text, i - 1))){
    i = i - 1
  }
  return i
}

// pos in the editor's text, moved to the text the index was made from (the
// same up to where they first differ, shifted by the difference after it)
local func index_pos(doc, pos){
  local a = doc.text
  local b = doc.symbols_text or a
  if(a == b){
    return pos
  }
  local n = len(a)
  if(len(b) < n){
    n = len(b)
  }
  local common = 0
  for(common < n and str.byte_at(a, common) == str.byte_at(b, common)){
    common = common + 1
  }
  if(pos <= common){
    return pos
  }
  local moved = pos - (len(a) - len(b))
  if(moved < common){
    moved = common
  }
  return moved
}

// whether pos is in a comment or a string of its line
local func in_comment_or_string(text, pos){
  local i = pos
  for(i > 0 and str.byte_at(text, i - 1) != '\n'){
    i = i - 1
  }
  local quoted = false
  for(i < pos){
    local b = str.byte_at(text, i)
    if(quoted){
      if(b == '\\'){
        i = i + 1
      } else if(b == '"'){
        quoted = false
      }
    } else if(b == '"'){
      quoted = true
    } else if(b == '/' and str.byte_at(text, i + 1) == '/'){
      return true
    }
    i = i + 1
  }
  return quoted
}

// the names of a chain like a.b:c ending at pos (the part being typed not
// included), with the separator before the part: {names, separator}, or
// null when what is before is not a chain of names
local func chain_before(text, start){
  local sep_pos = start - 1
  if(sep_pos < 0){
    return null
  }
  local sep = str.char_at(text, sep_pos)
  if(sep != "." and sep != ":"){
    return null
  }
  local names = {}
  local p = sep_pos
  for(true){
    local ws = word_start(text, p)
    if(ws == p){
      return null
    }
    local name = str.substring(text, ws, p)
    local b = str.byte_at(name, 0)
    if(b >= '0' and b <= '9'){
      return null
    }
    local rest = names
    names = {name}
    for(let local n in values(rest)){
      append(names, n)
    }
    if(ws == 0){
      break
    }
    local c = str.char_at(text, ws - 1)
    if(c != "."){
      break
    }
    p = ws - 1
  }
  return {names: names, separator: sep, start: word_start(text, sep_pos)}
}

// what a chain of names stands for at pos: {path, def}, or null
local func resolve_chain(nav, path, names, pos){
  local target = nav:lookup(path, names[0], pos)
  for(local i = 1; i < len(names) and target != null; i = i + 1){
    target = nav:member(target, names[i])
  }
  return target
}

// ------------------------------------------------------------ slang.project
//
// A project file is a table literal (read as `return {...}`): its keys are
// completed, explained on hover and checked (unknown keys, extensions that
// do not exist, path dependencies whose directory is missing).

local PROJECT_KEYS = {
  name: "the project's name, as a package: what `require` names it by",
  version: "the project's version, as a package (\"1.2.3\")",
  extensions: "grammar extensions every file of the project uses, in order: `{\"extensions/async\"}`",
  dialects: "file suffixes compiled differently: slang with extensions `{[\".hx\"]: {extensions: {...}}}`, a language of its own `{[\".kernel\"]: {grammar: \"kernel/file\"}}`, or a compile function `{[\".json\"]: {compile: \"extensions/json\"}}`",
  search_paths: "directories (relative to the project) where `require` looks for modules",
  warnings: "`false` silences the extensions' warnings, or `{[\"ext/a\"]: false}` some of them",
  dependencies: "packages: `{json5: {git: \"https://...\", version: \"^1.2\"}, util: {path: \"../util\"}}` (`slang get` fetches them)",
  build: "what `slang build` makes of the project: main, name, output, modules, assets, compress, strip, codesign, linker",
}

local BUILD_KEYS = {
  main: "the file `slang build` alone builds (default: main.slang)",
  name: "the executable's name (default: the project's name, else the main file's)",
  output: "where the executable goes, relative to the project (`-o` wins)",
  modules: "modules to bundle that are required by a computed name",
  assets: "files or directories bundled with the program: `{\"static\", \"data/words.txt\"}`",
  compress: "gzip the assets where it saves 10%: `true` (all but images, video, archives...) or a list of paths",
  strip: "`true` drops the line information from the bytecode",
  codesign: "macOS: sign with codesign and this identity (\"-\" is ad hoc) instead of slang's own ad hoc signature",
  linker: "the command that links native extensions in: \"zig cc\", or a list (default: cc, else zig cc)",
}

local PROJECT_PREFIX = "return "

// the project file's table: {table, shift} (shift: the prefix's length), or
// null when it does not parse
local func project_table(text){
  local parsed = try {
    compiler.parse(concat(PROJECT_PREFIX, text), "slang.project")
  } catch { null }
  if(parsed == null){
    return null
  }
  local st = parsed.statements or {}
  if(len(st) != 1 or st[0].type != "Return" or st[0].value.type != "Table"){
    return null
  }
  return {table: st[0].value, shift: len(PROJECT_PREFIX)}
}

// the fields of a table node with a name key: {name, node, value}
local func named_fields(table){
  local out = {}
  for(let local f in values(table.fields or {})){
    if(f.type == "Field" and f.key != null and f.key.type == "String" and
      f.key.token != null){
      append(out, {name: f.key.value, node: f.key, value: f.value})
    }
  }
  return out
}

project_lint = func(s, doc){
  local out = {}
  local found = project_table(doc.text)
  if(found == null){
    return out
  }
  local shift = found.shift
  local func warn(node, message){
    local t = node.token
    append(out, {
      range: lsp.range_of(
        doc.text, t.start - shift, t.stop - shift, s.encoding
      ),
      severity: 2,
      source: "slang",
      message: message,
    })
  }
  local dir = compiler.dirname(doc.path)
  for(let local f in values(named_fields(found.table))){
    if(PROJECT_KEYS[f.name] == null){
      warn(f.node, concat("slang.project has no key ", f.name))
    } else if(f.name == "build" and f.value.type == "Table"){
      for(let local b in values(named_fields(f.value))){
        if(BUILD_KEYS[b.name] == null){
          warn(b.node, concat("build has no key ", b.name))
        }
      }
    } else if(f.name == "extensions" and f.value.type == "Table"){
      for(let local e in values(f.value.fields)){
        local v = e.value
        if(v != null and v.type == "String" and v.token != null and
          compiler.module_path(v.value) == null){
          warn(v, concat("extension ", v.value, " not found"))
        }
      }
    } else if(f.name == "dependencies" and f.value.type == "Table"){
      for(let local d in values(named_fields(f.value))){
        if(d.value.type == "Table"){
          for(let local p in values(named_fields(d.value))){
            if(p.name == "path" and p.value.type == "String" and
              not os.is_dir(compiler.join_path(dir, p.value.value))){
              warn(p.value, concat("no directory ", p.value.value))
            }
          }
        }
      }
    }
  }
  return out
}

// the keys the table around pos takes: PROJECT_KEYS at the top, BUILD_KEYS
// in build: {...}, else null
local func project_keys_at(text, pos){
  local stack = {}
  local i = 0
  local quoted = false
  for(i < pos){
    local c = str.char_at(text, i)
    if(quoted){
      if(c == "\\"){
        i = i + 1
      } else if(c == "\""){
        quoted = false
      }
    } else if(c == "\""){
      quoted = true
    } else if(c == "/" and str.char_at(text, i + 1) == "/"){
      for(i < pos and str.char_at(text, i) != "\n"){
        i = i + 1
      }
    } else if(c == "{"){
      // the key this table is the value of
      local k = i - 1
      for(k > 0 and (str.char_at(text, k) == " " or str.char_at(text, k) == ":")){
        k = k - 1
      }
      append(stack, str.substring(text, word_start(text, k + 1), k + 1))
    } else if(c == "}" and len(stack) > 0){
      remove(stack, len(stack) - 1)
    }
    i = i + 1
  }
  if(quoted){
    return null
  }
  if(len(stack) == 1){
    return PROJECT_KEYS
  }
  if(len(stack) == 2 and stack[1] == "build"){
    return BUILD_KEYS
  }
  return null
}

project_completion = func(s, doc, pos){
  local keys_here = project_keys_at(doc.text, pos)
  local items = json.array({})
  if(keys_here == null){
    return items
  }
  for(let local e in entries(keys_here)){
    append(items, {
      label: e[0],
      kind: 10,
      detail: "slang.project",
      documentation: {kind: "markdown", value: e[1]},
      insertText: concat(e[0], ": "),
    })
  }
  return items
}

project_hover = func(s, at){
  local text = at.doc.text
  local start = word_start(text, at.pos)
  local stop = at.pos
  for(stop < len(text) and is_word_byte(str.byte_at(text, stop))){
    stop = stop + 1
  }
  local word = str.substring(text, start, stop)
  local keys_here = project_keys_at(text, start)
  if(keys_here == null or keys_here[word] == null){
    return null
  }
  return {
    contents: {
      kind: "markdown",
      value: concat("**", word, "**: ", keys_here[word]),
    },
    range: lsp.range_of(text, start, stop, s.encoding),
  }
}

// ------------------------------------------------------------ completion

// LSP completion item kinds
local ITEM = {
  method: 2, fn: 3, field: 5, variable: 6, module: 9, property: 10, keyword: 14
}

local func item_of(name, def, rank, method){
  local kind = ITEM.variable
  local detail = null
  if(def.params != null){
    kind = method and ITEM.method or ITEM.fn
    local params = def.params
    if(method and len(params) > 0){
      local rest = {}
      for(local i = 1; i < len(params); i = i + 1){
        append(rest, params[i])
      }
      params = rest
    }
    detail = concat(name, "(", str.join(params, ", "), ")")
  } else if(def.module != null){
    kind = ITEM.module
    detail = concat("require(\"", def.module, "\")")
  } else if(def.kind == "field"){
    kind = ITEM.field
  } else if(def.kind == "property"){
    kind = ITEM.property
    if(def.type_shown != null){
      detail = symbols.type_text(def.type_shown)
    }
  }
  local item = {
    label: name, kind: kind, sortText: concat(rank, name), detail: detail
  }
  if(def.doc != null){
    item.documentation = {kind: "markdown", value: navigate.markdown(def.doc)}
  }
  return item
}

// the .slang files under dir as module names (prefix/a/b), at most depth deep
local func modules_in(dir, prefix, depth, out){
  local names = try { os.list_dir(dir) } catch { null }
  if(names == null or depth < 0){
    return out
  }
  for(let local name in values(names)){
    if(not str.starts_with(name, ".") and name != "node_modules" and
      name != "zig-out"){
      local path = concat(dir, "/", name)
      if(str.ends_with(name, ".slang")){
        append(out, concat(prefix, str.substring(name, 0, len(name) - 6)))
      } else if(depth > 0 and os.is_dir(path)){
        modules_in(path, concat(prefix, name, "/"), depth - 1, out)
      }
    }
  }
  return out
}

// the module names require may be given: the project's, its packages',
// slang's library and native modules
local func module_names(s){
  local nav = nav_of(s)
  local names = {}
  // a project file is required by its path from a search path
  local roots = {}
  for(let local dir in values(__PACKAGES.search_paths or {})){
    append(roots, concat(compiler.absolute_path(dir), "/"))
  }
  if(nav.root != null){
    append(roots, concat(nav.root, "/"))
  }
  for(let local p in values(nav:project_files())){
    for(let local root in values(roots)){
      if(str.starts_with(p, root)){
        local rel = str.substring(p, len(root))
        append(names, str.substring(rel, 0, len(rel) - 6))
      }
    }
  }
  for(let local e in entries(__PACKAGES.packages or {})){
    local pkg = e[1]
    if(pkg.dir != null and not pkg.missing){
      append(names, e[0])
      for(let local m in values(modules_in(pkg.dir, concat(e[0], "/"), 2, {}))){
        if(not str.ends_with(m, "/init")){
          append(names, m)
        }
      }
    }
  }
  for(let local dir in values(__PACKAGES.library_sources or {})){
    modules_in(dir, "slang/", 0, names)
  }
  for(let local dir in values(__PACKAGES.stub_sources or {})){
    modules_in(dir, "", 1, names)
  }
  return names
}

local func require_completion(s, text, pos){
  local i = pos
  for(i > 0 and str.char_at(text, i - 1) != "\"" and
    str.char_at(text, i - 1) != "\n"){
    i = i - 1
  }
  if(i < 9 or str.substring(text, i - 9, i) != "require(\""){
    return null
  }
  local typed = str.substring(text, i, pos)
  local range = lsp.range_of(text, i, pos, s.encoding)
  local items = json.array({})
  local seen = {}
  for(let local name in values(module_names(s))){
    if(not seen[name] and str.starts_with(name, typed) and name != "globals"){
      seen[name] = true
      append(items, {
        label: name,
        kind: ITEM.module,
        textEdit: {range: range, newText: name},
      })
    }
  }
  return items
}

// ---- the fields of a table literal
//
// A table literal given where a documented shape is expected (an argument
// of a call whose doc types the parameter, or a table inside such a one)
// is completed with the shape's fields: device:render_pass({ offers
// color_attachments, and the table of an attachment its fields.

local func is_space(b){
  return b == ' ' or b == '\n' or b == '\t' or b == '\r'
}

// The table literal the cursor is in, at a place for a key, when it is an
// argument of a call or inside one that is: {open, arg, steps, keys}, or
// null.
// [open]: the offset of the call's (
// [arg]: which argument the outermost literal is
// [steps]: the way from that literal to the cursor's: for each literal
//   inside the last, the key it is the value of, or false for an element
// [keys]: the keys the cursor's literal has already
local func literal_at(text, pos){
  local from = 0
  if(pos > 8000){
    from = pos - 8000
  }
  local stack = {}
  local i = from
  for(i < pos){
    local b = str.byte_at(text, i)
    local top = stack[len(stack) - 1]
    if(b == '"'){
      i = i + 1
      for(i < pos and str.byte_at(text, i) != '"'){
        if(str.byte_at(text, i) == '\\'){
          i = i + 1
        }
        i = i + 1
      }
    } else if(b == '\'' and str.byte_at(text, i + 1) == '\\'){
      // a character literal with an escape: to its closing quote
      i = i + 2
      for(i < pos and str.byte_at(text, i) != '\'' and
        str.byte_at(text, i) != '\n'){
        i = i + 1
      }
    } else if(b == '\'' and str.byte_at(text, i + 2) == '\''){
      i = i + 2
    } else if(b == '/' and str.byte_at(text, i + 1) == '/'){
      for(i < pos and str.byte_at(text, i) != '\n'){
        i = i + 1
      }
    } else if(b == '(' or b == '['){
      append(stack, {at: i, paren: b == '(', commas: 0})
    } else if(b == '{'){
      // what stands before it says what it is: a call's argument, the
      // value of a key, an element, or something else (a block)
      local p = i
      for(p > from and is_space(str.byte_at(text, p - 1))){
        p = p - 1
      }
      local before = str.byte_at(text, p - 1)
      local frame = {at: i, commas: 0, keys: {}, last: i + 1}
      if(top != null and top.paren and (before == '(' or before == ',')){
        frame.table = true
        frame.arg = top.commas
      } else if(top != null and top.table and before == ':'){
        local stop = p - 1
        for(stop > from and is_space(str.byte_at(text, stop - 1))){
          stop = stop - 1
        }
        local start = word_start(text, stop)
        if(start < stop){
          frame.table = true
          frame.step = str.substring(text, start, stop)
        }
      } else if(top != null and top.table and (before == '{' or before == ',')){
        frame.table = true
        frame.step = false
      }
      append(stack, frame)
    } else if(b == ')' or b == '}' or b == ']'){
      if(top != null){
        remove(stack, len(stack) - 1)
      }
    } else if(b == ',' and top != null){
      top.commas = top.commas + 1
      top.last = i + 1
    } else if(b == ':' and top != null and top.table){
      // name: right after the { or the comma is a key
      local stop = i
      for(stop > from and is_space(str.byte_at(text, stop - 1))){
        stop = stop - 1
      }
      local start = word_start(text, stop)
      local q = top.last
      for(q < start and is_space(str.byte_at(text, q))){
        q = q + 1
      }
      if(start < stop and q == start){
        append(top.keys, str.substring(text, start, stop))
      }
    }
    i = i + 1
  }
  local top = stack[len(stack) - 1]
  if(top == null or not top.table){
    return null
  }
  // a place for a key: only spaces between the { or the last comma and
  // the word being typed
  local q = top.last
  local word = word_start(text, pos)
  for(q < word and is_space(str.byte_at(text, q))){
    q = q + 1
  }
  if(q != word){
    return null
  }
  // out to the literal that is the call's argument
  local k = len(stack) - 1
  for(k > 0 and stack[k].table and stack[k].arg == null){
    k = k - 1
  }
  if(k < 1 or not stack[k].table or stack[k].arg == null){
    return null
  }
  local steps = {}
  for(local j = k + 1; j < len(stack); j = j + 1){
    append(steps, stack[j].step)
  }
  return {
    open: stack[k - 1].at, arg: stack[k].arg, steps: steps, keys: top.keys
  }
}

// what is called by the ( at open: {target, method, name}, or null (a
// definition's func name( is not a call)
local func callee_at(nav, doc, text, open){
  local p = open
  for(p > 0 and str.char_at(text, p - 1) == " "){
    p = p - 1
  }
  local name_start = word_start(text, p)
  if(name_start == p){
    return null
  }
  local last = str.substring(text, name_start, p)
  local before = str.trim(str.substring(
    text, word_start(text, name_start - 1), name_start
  ))
  if(before == "func"){
    return null
  }
  local names = {last}
  local method = false
  local chain = chain_before(text, name_start)
  if(chain != null){
    names = chain.names
    append(names, last)
    method = chain.separator == ":"
  }
  local target = resolve_chain(nav, doc.path, names, index_pos(doc, name_start))
  if(target == null){
    return null
  }
  return {target: target, method: method, name: last}
}

// what a table literal (literal_at's) is expected to be: the value of
// the type the doc of what is called gives it ({path, def}), or null
local func literal_value(nav, doc, text, lit){
  local callee = callee_at(nav, doc, text, lit.open)
  if(callee == null){
    return null
  }
  local value = nav:argument_value(callee.target, lit.arg, callee.method)
  for(let local step in values(lit.steps)){
    value = nav:inside(value, step or null)
  }
  if(value == null or value.def == null){
    return null
  }
  return value
}

// A key of a table literal that is to be a documented shape, at pos: the
// field with its type, its doc, and what its type is declared as;
// {markdown, start, stop}, or null
field_hover = func(s, doc, pos){
  local text = doc.text
  local start = word_start(text, pos)
  local stop = pos
  for(stop < len(text) and is_word_byte(str.byte_at(text, stop))){
    stop = stop + 1
  }
  // name: at a key's place
  local after = stop
  for(after < len(text) and str.byte_at(text, after) == ' '){
    after = after + 1
  }
  if(start == stop or str.byte_at(text, after) != ':' or
    in_comment_or_string(text, start)){
    return null
  }
  local lit = literal_at(text, start)
  if(lit == null){
    return null
  }
  local nav = nav_of(s)
  local value = literal_value(nav, doc, text, lit)
  if(value == null){
    return null
  }
  local name = str.substring(text, start, stop)
  local def = (value.def.fields or {})[name]
  if(def == null or def.kind != "field" or def.type == null){
    return null
  }
  local lines = {
    concat(
      "```slang\n", name, def.optional and "?" or "", ": ",
      symbols.type_text(def.type), "\n```",
    ),
  }
  if(def.doc != null){
    append(lines, navigate.markdown(def.doc))
  }
  local declared = nav:type_declared(def.home or value.path, def.type)
  if(declared != null){
    append(lines, concat("```slang\n", declared, "\n```"))
  }
  if(value.type_name != null){
    append(lines, concat("*a field of ", value.type_name, "*"))
  }
  return {markdown: str.join(lines, "\n\n"), start: start, stop: stop}
}

// the items for the fields of the shape a table literal is expected to
// be, without the keys it has; null when it is not known to be one
local func literal_items(nav, doc, text, lit){
  local value = literal_value(nav, doc, text, lit)
  if(value == null){
    return null
  }
  local have = {}
  for(let local k in values(lit.keys)){
    have[k] = true
  }
  local items = json.array({})
  local n = 0
  for(let local e in entries(value.def.fields or {})){
    local def = e[1]
    // (a shape's fields have types; a table of methods is not a shape)
    if(def.kind == "field" and def.type != null){
      n = n + 1
      if(not have[e[0]]){
        local item = {
          label: e[0],
          kind: ITEM.field,
          // in the order the type declares them
          sortText: str.format("0%03d", n),
          filterText: e[0],
          insertText: concat(e[0], ": "),
          detail: concat(
            e[0], def.optional and "?" or "", ": ", symbols.type_text(def.type),
          ),
        }
        if(def.doc != null){
          item.documentation = {
            kind: "markdown", value: navigate.markdown(def.doc)
          }
        }
        append(items, item)
      }
    }
  }
  if(n == 0){
    return null
  }
  return items
}

handlers["textDocument/completion"] = func(s, id, params){
  local doc = s.documents[params.textDocument.uri]
  if(doc == null){
    return {response(id, json.array({}))}
  }
  local text = doc.text
  local pos = lsp.offset_of(text, params.position, s.encoding)
  if(is_project_file(doc.path)){
    return {response(id, project_completion(s, doc, pos))}
  }
  local modules = require_completion(s, text, pos)
  if(modules != null){
    return {response(id, modules)}
  }
  if(in_comment_or_string(text, pos) or doc.symbols == null){
    return {response(id, json.array({}))}
  }
  local nav = nav_of(s)
  local at = index_pos(doc, pos)
  local start = word_start(text, pos)
  local items = json.array({})
  local chain = chain_before(text, start)
  if(chain != null){
    // a member: what the chain before the dot or colon holds has it
    local target = resolve_chain(
      nav, doc.path, chain.names, index_pos(doc, chain.start)
    )
    local method = chain.separator == ":"
    for(let local e in entries(nav:members(target))){
      local def = e[1].def
      if(not method or def.params != null){
        append(items, item_of(e[0], def, "1", method))
      }
    }
    return {response(id, items)}
  }
  // a key of a table literal that is to be a documented shape
  local lit = literal_at(text, pos)
  if(lit != null){
    local fields = literal_items(nav, doc, text, lit)
    if(fields != null){
      return {response(id, fields)}
    }
  }
  // { and , ask for a literal's fields only
  local trigger = params.context and params.context.triggerCharacter
  if(trigger == "{" or trigger == ","){
    return {response(id, items)}
  }
  local seen = {}
  local func add(name, def, rank){
    if(not seen[name] and def != null){
      seen[name] = true
      append(items, item_of(name, def, rank, false))
    }
  }
  for(let local e in entries(nav:locals_at(doc.path, at))){
    add(e[0], e[1], "0")
  }
  for(let local e in entries(doc.symbols.globals)){
    add(e[0], e[1], "1")
  }
  local stub = compiler.stub_path("globals")
  if(stub != null){
    local f = nav:file(stub)
    if(f != null){
      for(let local e in entries(f.index.globals)){
        add(e[0], e[1], "2")
      }
    }
  }
  for(let local word in values(compiler.keywords(doc.path))){
    if(not seen[word]){
      seen[word] = true
      append(items, {
        label: word, kind: ITEM.keyword, sortText: concat("3", word)
      })
    }
  }
  return {response(id, items)}
}

// ------------------------------------------------------------ signature help

// the call the cursor is in the arguments of: {open, commas} (the offset of
// its "(" and the commas before the cursor), or null. Strings, comments and
// the insides of tables and inner calls are skipped.
local func open_call(text, pos){
  local from = 0
  if(pos > 8000){
    from = pos - 8000
  }
  local stack = {}
  local i = from
  for(i < pos){
    local b = str.byte_at(text, i)
    if(b == '"'){
      i = i + 1
      for(i < pos and str.byte_at(text, i) != '"'){
        if(str.byte_at(text, i) == '\\'){
          i = i + 1
        }
        i = i + 1
      }
    } else if(b == '/' and str.byte_at(text, i + 1) == '/'){
      for(i < pos and str.byte_at(text, i) != '\n'){
        i = i + 1
      }
    } else if(b == '(' or b == '{' or b == '['){
      append(stack, {at: i, paren: b == '(', commas: 0})
    } else if(b == ')' or b == '}' or b == ']'){
      if(len(stack) > 0){
        remove(stack, len(stack) - 1)
      }
    } else if(b == ',' and len(stack) > 0){
      local top = stack[len(stack) - 1]
      top.commas = top.commas + 1
    }
    i = i + 1
  }
  if(len(stack) == 0 or not stack[len(stack) - 1].paren){
    return null
  }
  local top = stack[len(stack) - 1]
  return {open: top.at, commas: top.commas}
}

handlers["textDocument/signatureHelp"] = func(s, id, params){
  local doc = s.documents[params.textDocument.uri]
  if(doc == null or doc.symbols == null){
    return {response(id, null)}
  }
  local text = doc.text
  local pos = lsp.offset_of(text, params.position, s.encoding)
  local call = open_call(text, pos)
  if(call == null){
    return {response(id, null)}
  }
  // the name called: the chain right before the (
  local p = call.open
  for(p > 0 and str.char_at(text, p - 1) == " "){
    p = p - 1
  }
  local name_start = word_start(text, p)
  if(name_start == p){
    return {response(id, null)}
  }
  local last = str.substring(text, name_start, p)
  // func name(...) is a definition, not a call
  local before = str.trim(str.substring(
    text, word_start(text, name_start - 1), name_start
  ))
  if(before == "func"){
    return {response(id, null)}
  }
  local names = {last}
  local method = false
  local chain = chain_before(text, name_start)
  if(chain != null){
    names = chain.names
    append(names, last)
    method = chain.separator == ":"
  }
  local nav = nav_of(s)
  local target = resolve_chain(nav, doc.path, names, index_pos(doc, name_start))
  local plist = nav:params(target)
  if(plist == null){
    return {response(id, null)}
  }
  if(method and len(plist) > 0){
    local rest = {}
    for(local i = 1; i < len(plist); i = i + 1){
      append(rest, plist[i])
    }
    plist = rest
  }
  // the doc's typed parameters when it has them
  local info = target.def.info
  local typed = info and info.signature and info.signature.params
  if(typed != null){
    if(method){
      typed = navigate.method_params(typed, target.def)
    }
    plist = {}
    for(let local p in values(typed)){
      local shown = concat(
        p.rest and "..." or "",
        p.name,
        p.optional and "?" or "",
      )
      if(p.type != null){
        shown = concat(shown, ": ", symbols.type_text(p.type))
      }
      append(plist, shown)
    }
  }
  local label = concat(last, "(")
  local parameters = json.array({})
  for(let local e in entries(plist)){
    if(e[0] > 0){
      label = concat(label, ", ")
    }
    local a = utf8.utf16_len(label)
    label = concat(label, e[1])
    local param = {label: json.array({a, utf8.utf16_len(label)})}
    if(typed != null and info.items[typed[e[0]].name] != null){
      param.documentation = info.items[typed[e[0]].name]
    }
    append(parameters, param)
  }
  label = concat(label, ")")
  if(info != null and info.signature != null and
    info.signature.result != null and info.signature.result.type != null){
    label = concat(label, " -> ", symbols.type_text(info.signature.result.type))
  }
  local active = call.commas
  // a rest parameter takes every argument from its place on
  if(len(plist) > 0 and active >= len(plist) and
    str.starts_with(plist[len(plist) - 1], "...")){
    active = len(plist) - 1
  }
  local sig = {label: label, parameters: parameters}
  local md = navigate.doc_markdown(target.def)
  if(md != null){
    sig.documentation = {kind: "markdown", value: md}
  }
  return {
    response(id, {
      signatures: json.array({sig}),
      activeSignature: 0,
      activeParameter: active,
    }),
  }
}

// ------------------------------------------------------------ tests

// the end of a node: the furthest end of the tokens in it (a node's own
// token may be only its first word)
local func node_stop(node, source, stop){
  if(node == null or ast.specs[node.type] == null){
    return stop
  }
  local t = node.token
  if(t != null and t.buffer == source and t.stop != null and t.stop > stop){
    stop = t.stop
  }
  for(let local field in values(ast.specs[node.type])){
    local child = node[field[0]]
    if(child != null){
      if(field[1] == "list"){
        for(let local c in values(child)){
          stop = node_stop(c, source, stop)
        }
      } else if(field[1] != "value"){
        stop = node_stop(child, source, stop)
      }
    }
  }
  return stop
}

// the t.group("name"){ ... } and t.test("name"){ ... } calls in a tree, nested:
// {kind, name, start, stop, children}
local func tests_in(node, source, out){
  if(node == null or ast.specs[node.type] == null or node.type == "Quote"){
    return out
  }
  if(node.type == "Call" and node.function.type == "Index" and
    node.function.index.type == "String"){
    local kind = node.function.index.value
    local args = node.args
    if((kind == "group" or kind == "test") and len(args) >= 1 and
      args[0].type == "String" and node.function.receiver.token != null and
      node.function.receiver.token.buffer == source){
      local start = node.function.receiver.token.start
      local item = {
        kind: kind,
        name: args[0].value,
        start: start,
        stop: node_stop(node, source, start),
        children: {},
      }
      append(out, item)
      for(let local a in values(args)){
        tests_in(a, source, item.children)
      }
      return out
    }
  }
  for(let local field in values(ast.specs[node.type])){
    local child = node[field[0]]
    if(child != null){
      if(field[1] == "list"){
        for(let local c in values(child)){
          tests_in(c, source, out)
        }
      } else if(field[1] != "value"){
        tests_in(child, source, out)
      }
    }
  }
  return out
}

// slang/tests {uri} -> {tests}: the groups and tests a test file defines,
// {kind: "group"|"test", name, range, children}; the document's text when
// it is open, else the file's
handlers["slang/tests"] = func(s, id, params){
  local doc = s.documents[params.uri]
  local text = null
  local tree = null
  local path = lsp.uri_to_path(params.uri)
  if(doc != null and doc.ast != null){
    text = doc.symbols_text
    tree = doc.ast
  } else {
    text = try { os.read_file(path) } catch { null }
    if(text == null){
      return {response(id, {tests: json.array({})})}
    }
    local h = try {
      compiler.highlight(text, path, {symbols: true})
    } catch { null }
    if(h == null or h.ast == null){
      return {response(id, {tests: json.array({})})}
    }
    tree = h.ast
  }
  local func convert(list){
    local out = json.array({})
    for(let local item in values(list)){
      append(out, {
        kind: item.kind,
        name: item.name,
        range: lsp.range_of(text, item.start, item.stop, s.encoding),
        children: convert(item.children),
      })
    }
    return out
  }
  return {response(id, {tests: convert(tests_in(tree, text, {}))})}
}

// ------------------------------------------------------------ expansion

// slang/expand {uri} -> {text}: the document as core slang, after its
// extensions ran (what `slang expand` prints), or {error}
handlers["slang/expand"] = func(s, id, params){
  local doc = s.documents[params.uri]
  if(doc == null){
    return {response(id, {error: "the document is not open"})}
  }
  local expanded = null
  try {
    expanded = compiler.expand(doc.text, doc.path, {find_project: true})
  } catch(local e) {
    return {response(id, {error: e.message})}
  }
  return {response(id, {text: expanded})}
}

// ------------------------------------------------------------ formatting

// the whole text formatted as `slang fmt` would: one edit replacing it, or
// none when it is formatted already. A text that does not parse is left as
// it is (its diagnostics say why); a formatter whose checks fail on a text
// that parses is a bug in the formatter, and the editor is told.
// [unit]: {text, path, uri, clean, result}: clean when the text has no
//   parse errors, result for a notebook's cell (it may end in an
//   expression, and keeps its own last line break or lack of one)
local func formatted_text(unit){
  local out = format.source(unit.text, unit.path, {
    find_project: true, result: unit.result
  })
  if(out != null and unit.result and not str.ends_with(unit.text, "\n") and
    str.ends_with(out, "\n")){
    out = str.substring(out, 0, len(out) - 1)
  }
  return out
}

local func format_whole(s, id, unit){
  local text = unit.text
  local formatted = null
  local message = null
  try {
    formatted = formatted_text(unit)
  } catch(local e) {
    message = e.message
  }
  if(message != null){
    s.log(concat("formatting failed for ", unit.uri, ": ", message))
    local out = {response(id, json.array({}))}
    if(unit.clean){
      append(out, notification("window/showMessage", {
        type: 2,
        message: concat("slang: the file was not formatted: ", message),
      }))
    }
    return out
  }
  if(formatted == null or formatted == text){
    return {response(id, json.array({}))}
  }
  return {
    response(id, json.array({
      {range: lsp.range_of(text, 0, len(text), s.encoding), newText: formatted},
    })),
  }
}

handlers["textDocument/formatting"] = func(s, id, params){
  local doc = s.documents[params.textDocument.uri]
  if(doc == null){
    return {response(id, json.array({}))}
  }
  return format_whole(s, id, {
    text: doc.text, path: doc.path, uri: doc.uri,
    clean: len(doc.diagnostics) == 0, result: false
  })
}

// The lines a range touches, formatted. The whole document is formatted;
// both texts have the same tokens (but trailing commas and `;`), so the
// tokens on the selected lines are found in the result, the regions grow
// to whole lines on both sides until they hold the same tokens (the
// formatter joins and splits lines), and those lines of the result replace
// the document's.
local func line_tokens(text, path, result){
  local h = try {
    compiler.highlight(text, path, {result: result})
  } catch { null }
  if(h == null or len(h.diagnostics) > 0){
    return null
  }
  local out = {}
  for(let local t in values(h.tokens)){
    local word = str.substring(text, t.start, t.stop)
    if(word != "," and word != ";"){
      append(out, {start: t.start, stop: t.stop, line: t.line - 1, text: word})
    }
  }
  return out
}

local func format_range(s, id, unit, range){
  local text = unit.text
  local formatted = try { formatted_text(unit) } catch { null }
  if(formatted == null or formatted == text){
    return {response(id, json.array({}))}
  }
  local a = line_tokens(text, unit.path, unit.result)
  local b = line_tokens(formatted, unit.path, unit.result)
  if(a == null or b == null or len(a) != len(b) or len(a) == 0){
    return {response(id, json.array({}))}
  }
  local first_line = range.start.line
  local last_line = range["end"].line
  if(range["end"].character == 0 and last_line > first_line){
    last_line = last_line - 1
  }
  local i = -1
  local j = -1
  for(local k = 0; k < len(a); k = k + 1){
    if(a[k].line >= first_line and a[k].line <= last_line){
      if(i < 0){
        i = k
      }
      j = k
    }
  }
  if(i < 0){
    return {response(id, json.array({}))}
  }
  // grow until no token outside [i, j] shares a line with one inside
  local changed = true
  for(changed){
    changed = false
    for(let local list in values({a, b})){
      for(i > 0 and list[i - 1].line == list[i].line){
        i = i - 1
        changed = true
      }
      for(j + 1 < len(list) and list[j + 1].line == list[j].line){
        j = j + 1
        changed = true
      }
    }
  }
  local starts_a = str.line_starts(text)
  local starts_b = str.line_starts(formatted)
  local func line_end(t, starts, line){
    local next = starts[line + 1]
    if(next == null){
      return len(t)
    }
    return next - 1
  }
  local from_a = starts_a[a[i].line]
  local to_a = line_end(text, starts_a, a[j].line)
  local from_b = starts_b[b[i].line]
  local to_b = line_end(formatted, starts_b, b[j].line)
  local old = str.substring(text, from_a, to_a)
  local new = str.substring(formatted, from_b, to_b)
  if(old == new){
    return {response(id, json.array({}))}
  }
  return {
    response(id, json.array({
      {range: lsp.range_of(text, from_a, to_a, s.encoding), newText: new},
    })),
  }
}

handlers["textDocument/rangeFormatting"] = func(s, id, params){
  local doc = s.documents[params.textDocument.uri]
  if(doc == null){
    return {response(id, json.array({}))}
  }
  return format_range(s, id, {
    text: doc.text, path: doc.path, uri: doc.uri, result: false
  }, params.range)
}

// ------------------------------------------------------------ notebooks
//
// A notebook (notebookDocument/didOpen, didChange, didClose) is analysed
// as one document: the text of its slang cells one after another, each on
// lines of its own, under the notebook's path with ".slang" added (a plain
// slang file of the notebook's project). So a name of one cell is known in
// the cells after it, as it is when they run in one session, and a cell
// may end in an expression (compiler.highlight's cells). A request about a
// cell is answered from that document: its position moves down by the
// lines before the cell, and what the answer says of the document moves
// back into the cells (locations, edits, diagnostics). A cell is formatted
// alone.

// What f() gives, with modules looked for as a notebook's cells find them:
// a notebook's kernel runs in the notebook's folder, so without a project
// that folder is where require looks first. (Under the compiler state of
// the notebook's file: compiler.for_file.)
in_notebook_folder = func(path, f){
  if(compiler.project() != null){
    return f()
  }
  local was = __PACKAGES.search_paths
  local paths = {compiler.dirname(path)}
  for(let local dir in values(was or {})){
    append(paths, dir)
  }
  __PACKAGES.search_paths = paths
  local r = try { {ok: true, value: f()} } catch(local e) { {ok: false, error: e} }
  __PACKAGES.search_paths = was
  if(not r.ok){
    raise(r.error)
  }
  return r.value
}

// every slang cell of a notebook gets its place in the notebook's
// document, which gets their text
local func lay_out(s, nb){
  local doc = s.documents[nb.doc_uri]
  if(doc == null){
    doc = {
      uri: nb.doc_uri, path: lsp.uri_to_path(nb.doc_uri), text: "",
      tokens: {}, diagnostics: {}, notebook: nb
    }
    s.documents[nb.doc_uri] = doc
  }
  // (the document starts with an empty line: a comment that starts a file
  // is the file's doc, one that starts a notebook's first cell is the doc
  // of what that cell defines first)
  local parts = {""}
  local places = {}
  local ends = {}
  local line = 1
  local start = 1
  for(let local c in values(nb.cells)){
    local cell = s.cells[c.document]
    if(cell != null and same(cell.notebook, nb)){
      cell.line = line
      cell.start = start
      cell.lines = str.count(cell.text, "\n") + 1
      append(parts, cell.text)
      append(places, cell)
      start = start + len(cell.text)
      append(ends, start)
      start = start + 1
      line = line + cell.lines
    }
  }
  doc.text = str.join(parts, "\n")
  doc.version = nb.version
  doc.cells = places
  doc.cell_ends = ends
  return doc
}

// the cell a line of the notebook's document is in
local func cell_at(doc, line){
  local found = null
  for(let local c in values(doc.cells or {})){
    if(c.line > line){
      break
    }
    found = c
  }
  return found
}

// a range of the notebook's document as one of the cell it starts in
// (cut at the cell's end): {cell, range}, or null
local func to_cell(s, doc, range){
  local cell = cell_at(doc, range.start.line)
  if(cell == null){
    return null
  }
  local stop = {
    line: range["end"].line - cell.line, character: range["end"].character
  }
  if(stop.line >= cell.lines){
    local starts = str.line_starts(cell.text)
    local last = cell.lines - 1
    stop = {
      line: last,
      character: character_at(
        cell.text, starts[last] or len(cell.text), len(cell.text), s.encoding
      ),
    }
  }
  return {
    cell: cell,
    range: {
      start: {
        line: range.start.line - cell.line, character: range.start.character
      },
      ["end"]: stop,
    },
  }
}

// the diagnostics of a notebook's document, as its cells' (every cell gets
// its list, an empty one too)
cell_diagnostics = func(s, doc, note){
  local by_cell = {}
  for(let local c in values(doc.cells)){
    by_cell[c.uri] = json.array({})
  }
  for(let local d in values(note.params.diagnostics)){
    local tc = to_cell(s, doc, d.range)
    if(tc != null){
      local moved = {}
      for(let local e in entries(d)){
        moved[e[0]] = e[1]
      }
      moved.range = tc.range
      append(by_cell[tc.cell.uri], moved)
    }
  }
  local out = {}
  for(let local c in values(doc.cells)){
    append(out, notification("textDocument/publishDiagnostics", {
      uri: c.uri, version: c.version, diagnostics: by_cell[c.uri]
    }))
  }
  return out
}

// the notebook's document made anew and analysed: its cells' diagnostics
local func refresh(s, nb){
  local doc = lay_out(s, nb)
  return cell_diagnostics(s, doc, analyse(s, doc.uri))
}

local func open_cell(s, nb, td){
  if(td.languageId != null and td.languageId != "slang"){
    return
  }
  s.cells[td.uri] = {
    uri: td.uri, notebook: nb, text: td.text or "", version: td.version,
    line: 0, start: 0, lines: 1
  }
}

handlers["notebookDocument/didOpen"] = func(s, id, params){
  local nd = params.notebookDocument
  local nb = {
    uri: nd.uri, version: nd.version, cells: {},
    doc_uri: lsp.path_to_uri(concat(lsp.uri_to_path(nd.uri), ".slang"))
  }
  s.notebooks[nd.uri] = nb
  for(let local c in values(nd.cells or {})){
    append(nb.cells, {kind: c.kind, document: c.document})
  }
  for(let local td in values(params.cellTextDocuments or {})){
    open_cell(s, nb, td)
  }
  local out = refresh(s, nb)
  local p = project_notification(s)
  if(p != null){ append(out, p) }
  return out
}

handlers["notebookDocument/didChange"] = func(s, id, params){
  local nb = s.notebooks[params.notebookDocument.uri]
  if(nb == null){
    return {}
  }
  nb.version = params.notebookDocument.version
  local cells = (params.change or {}).cells or {}
  local out = {}
  local structure = cells.structure
  if(structure != null){
    // cells taken out and put in at one place of the list
    local a = structure.array
    local next = {}
    for(local i = 0; i < a.start and i < len(nb.cells); i = i + 1){
      append(next, nb.cells[i])
    }
    for(let local c in values(a.cells or {})){
      append(next, {kind: c.kind, document: c.document})
    }
    for(local i = a.start + a.deleteCount; i < len(nb.cells); i = i + 1){
      append(next, nb.cells[i])
    }
    nb.cells = next
    for(let local td in values(structure.didOpen or {})){
      open_cell(s, nb, td)
    }
    for(let local td in values(structure.didClose or {})){
      if(s.cells[td.uri] != null){
        delete(s.cells, td.uri)
        append(out, notification("textDocument/publishDiagnostics", {
          uri: td.uri, diagnostics: json.array({})
        }))
      }
    }
  }
  // full sync: a cell's last change carries its whole text
  for(let local tc in values(cells.textContent or {})){
    local cell = s.cells[tc.document.uri]
    if(cell != null){
      for(let local change in values(tc.changes or {})){
        cell.text = change.text
      }
      cell.version = tc.document.version
    }
  }
  for(let local n in values(refresh(s, nb))){
    append(out, n)
  }
  return out
}

handlers["notebookDocument/didClose"] = func(s, id, params){
  local uri = params.notebookDocument.uri
  local nb = s.notebooks[uri]
  if(nb == null){
    return {}
  }
  local out = {}
  for(let local c in values(nb.cells)){
    if(s.cells[c.document] != null){
      delete(s.cells, c.document)
      append(out, notification("textDocument/publishDiagnostics", {
        uri: c.document, diagnostics: json.array({})
      }))
    }
  }
  local doc = s.documents[nb.doc_uri]
  if(doc != null and s.nav != null){
    s.nav:close(doc.path)
  }
  delete(s.documents, nb.doc_uri)
  delete(s.notebooks, uri)
  return out
}

// a request's parameters about a cell, as about the notebook's document
local func into_document(doc, cell, params){
  local out = {}
  for(let local e in entries(params)){
    out[e[0]] = e[1]
  }
  out.textDocument = {uri: doc.uri}
  local func moved(p){
    return {line: p.line + cell.line, character: p.character}
  }
  if(params.position != null){
    out.position = moved(params.position)
  }
  if(params.range != null){
    out.range = {
      start: moved(params.range.start), ["end"]: moved(params.range["end"])
    }
  }
  return out
}

// locations: those in the notebook's document are in its cells
local func cell_locations(s, doc, cell, list){
  local out = json.array({})
  for(let local l in values(list)){
    if(l.uri == doc.uri){
      local tc = to_cell(s, doc, l.range)
      if(tc != null){
        append(out, {uri: tc.cell.uri, range: tc.range})
      }
    } else {
      append(out, l)
    }
  }
  return out
}

// the symbols of an outline that are in a cell (a section of the
// notebook's document that starts in another cell gives its own)
local func cell_symbols(s, doc, cell, list, out){
  for(let local sym in values(list)){
    local name = to_cell(s, doc, sym.selectionRange)
    if(name != null and same(name.cell, cell)){
      local whole = to_cell(s, doc, sym.range)
      local moved = {}
      for(let local e in entries(sym)){
        moved[e[0]] = e[1]
      }
      moved.selectionRange = name.range
      moved.range = whole != null and same(whole.cell, cell) and whole.range or
        name.range
      moved.children = cell_symbols(
        s, doc, cell, sym.children or {}, json.array({})
      )
      append(out, moved)
    } else {
      cell_symbols(s, doc, cell, sym.children or {}, out)
    }
  }
  return out
}

// what an answer about the notebook's document is for the cell asked about
local answers = {}

answers["textDocument/hover"] = func(s, doc, cell, r){
  if(r.range != null){
    local tc = to_cell(s, doc, r.range)
    if(tc != null and same(tc.cell, cell)){
      r.range = tc.range
    } else {
      delete(r, "range")
    }
  }
  return r
}

answers["textDocument/definition"] = cell_locations
answers["textDocument/references"] = cell_locations

answers["textDocument/documentHighlight"] = func(s, doc, cell, r){
  local out = json.array({})
  for(let local h in values(r)){
    local tc = to_cell(s, doc, h.range)
    if(tc != null and same(tc.cell, cell)){
      append(out, {range: tc.range, kind: h.kind})
    }
  }
  return out
}

// slang/highlights {textDocument, position} -> {{uri, range, kind}}:
// documentHighlight for a notebook's cell, over all the notebook's cells
// (for a document, its own highlights with its uri)
handlers["slang/highlights"] = func(s, id, params){
  local uri = params.textDocument.uri
  local replies = handlers["textDocument/documentHighlight"](s, id, params)
  for(let local r in values(replies)){
    if(r.result != null){
      local out = json.array({})
      for(let local h in values(r.result)){
        append(out, {uri: uri, range: h.range, kind: h.kind})
      }
      r.result = out
    }
  }
  return replies
}

answers["slang/highlights"] = func(s, doc, cell, r){
  local out = json.array({})
  for(let local h in values(r)){
    local tc = to_cell(s, doc, h.range)
    if(tc != null){
      append(out, {uri: tc.cell.uri, range: tc.range, kind: h.kind})
    }
  }
  return out
}

answers["textDocument/prepareRename"] = func(s, doc, cell, r){
  local tc = to_cell(s, doc, r.range)
  if(tc != null){
    r.range = tc.range
  }
  return r
}

answers["textDocument/rename"] = func(s, doc, cell, r){
  local changes = {}
  for(let local e in entries(r.changes or {})){
    if(e[0] == doc.uri){
      for(let local edit in values(e[1])){
        local tc = to_cell(s, doc, edit.range)
        if(tc != null){
          if(changes[tc.cell.uri] == null){
            changes[tc.cell.uri] = json.array({})
          }
          append(changes[tc.cell.uri], {
            range: tc.range, newText: edit.newText
          })
        }
      }
    } else {
      changes[e[0]] = e[1]
    }
  }
  return {changes: changes}
}

answers["textDocument/completion"] = func(s, doc, cell, r){
  for(let local item in values(r)){
    if(item.textEdit != null){
      local tc = to_cell(s, doc, item.textEdit.range)
      if(tc != null){
        item.textEdit = {range: tc.range, newText: item.textEdit.newText}
      }
    }
  }
  return r
}

answers["textDocument/signatureHelp"] = func(s, doc, cell, r){
  return r
}

answers["textDocument/inlayHint"] = func(s, doc, cell, r){
  local out = json.array({})
  for(let local hint in values(r)){
    local line = hint.position.line - cell.line
    if(line >= 0 and line < cell.lines){
      hint.position = {line: line, character: hint.position.character}
      append(out, hint)
    }
  }
  return out
}

answers["textDocument/documentSymbol"] = func(s, doc, cell, r){
  return cell_symbols(s, doc, cell, r, json.array({}))
}

// a cell's tokens: those of the notebook's document that are in it
local func cell_tokens(s, doc, cell){
  local stop = cell.start + len(cell.text)
  local out = {}
  for(let local t in values(doc.tokens)){
    if(t.start >= cell.start and t.start < stop){
      local token_stop = t.stop
      if(token_stop > stop){
        token_stop = stop
      }
      append(out, {
        line: t.line - cell.line, start: t.start - cell.start,
        stop: token_stop - cell.start, category: t.category
      })
    }
  }
  return lsp.semantic_tokens(cell.text, out, s.encoding)
}

// a request about a notebook's cell
local func handle_cell(s, cell, message){
  local method = message.method
  local id = message.id
  local params = message.params or {}
  local doc = s.documents[cell.notebook.doc_uri]
  if(method == "textDocument/semanticTokens/full"){
    return {response(id, {data: cell_tokens(s, doc, cell)})}
  }
  if(method == "textDocument/formatting" or
    method == "textDocument/rangeFormatting"){
    local unit = {
      text: cell.text, path: doc.path, uri: cell.uri,
      clean: len(doc.diagnostics) == 0, result: true
    }
    if(method == "textDocument/formatting"){
      return format_whole(s, id, unit)
    }
    return format_range(s, id, unit, params.range)
  }
  local answer = answers[method]
  if(answer == null){
    if(id == null){
      return {}
    }
    return {
      error_response(
        id, -32601, concat(method, " is not answered for a notebook's cell")
      ),
    }
  }
  local replies = handlers[method](s, id, into_document(doc, cell, params))
  for(let local r in values(replies)){
    if(id != null and r.id == id and r.result != null){
      r.result = answer(s, doc, cell, r.result)
    }
  }
  return replies
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
  // under the project of the file the request is about
  local params = message.params or {}
  local td = params.textDocument
  local uri = type(td) == "table" and td.uri or params.uri
  if(uri == null and type(params.notebookDocument) == "table"){
    uri = params.notebookDocument.uri
  }
  local path = type(uri) == "string" and lsp.uri_to_path(uri) or null
  // a notebook's cell: the notebook's document answers
  local cell = type(uri) == "string" and s.cells[uri] or null
  if(cell != null){
    path = s.documents[cell.notebook.doc_uri].path
  }
  local notebook = cell != null or type(params.notebookDocument) == "table"
  try {
    return compiler.for_file(path, func(){
      if(cell != null){
        return in_notebook_folder(path, func(){
          return handle_cell(s, cell, message)
        })
      }
      if(notebook){
        return in_notebook_folder(path, func(){ return h(s, id, params) })
      }
      return h(s, id, params)
    })
  } catch(local e) {
    s.log(concat("error handling ", method, ": ", e.message))
    if(id != null){
      return {error_response(id, -32603, e.message)}
    }
    return {}
  }
}

return lsp
