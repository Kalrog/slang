// gpu/syntax: WGSL written in the slang file that uses it.
//
//   extension "gpu/syntax"     // or extensions: {"gpu/syntax"} in slang.project
//
//   wgsl doubler {
//     @group(0) @binding(0) var<storage, read_write> v: array<f32>;
//
//     @compute @workgroup_size(64)
//     fn main(@builtin(global_invocation_id) id: vec3u) {
//       v[id.x] = v[id.x] * 2.0;
//     }
//   }
//
//   local pipeline = device:compute_pipeline({shader: device:shader(doubler)})
//
// A `wgsl name { ... }` statement holds a WGSL program as it is written
// for WebGPU: nothing of the language is changed. It is parsed when the
// slang file is, by gpu/wgsl, so a mistake in its syntax is a compile error
// at its line, and it is highlighted and formatted like the slang code
// around it. After it, name is a local: the program (gpu/program), for
// [Device.shader], with what it declares as its fields: its structs as
// values to make memory of, its entry points, variables and constants.
// What the WGSL compiler has to say about it later (a type that does not
// fit, a name it does not know) it says with the lines and columns of the
// slang file.
//
// The word `wgsl` stays usable as a name: `wgsl name {` starts the
// statement only where a statement starts.
//
// Includes. A block can start with #include lines that put the
// declarations of other wgsl blocks before its own:
//
//   wgsl terrain {
//     #include scene from "engine/shaders"   // a block of another module
//     #include noise                         // a block before, in this file
//     ...
//   }
//
// The module is found as require finds it (the project's files, then the
// packages). Each block is included once, however many includes reach it,
// and included blocks may include others (an include without `from`
// there means a block of that block's file). What is included is part of
// the program: its structs and variables are fields like the block's own
// (terrain.Frame), and the WGSL compiler's messages about it point into
// the file it is written in. A file with includes is not cached as
// bytecode, so a change to an included block is always seen.
local peg = require("slang/peg")
local ast = require("slang/ast")
local fmt = require("slang/format")
local str = require("slang/string")
local os = require("slang/os")
local wgsl = require("gpu/wgsl")
local layout = require("gpu/layout")
local g = require("slang/compiler").grammar()

// the AST of a value: a literal, or a table literal of its elements and
// fields
local func value_ast(v, token){
  if(type(v) != "table"){
    return ast.literal(token, v)
  }
  local fields = {}
  local n = len(v)
  for(local i = 0; i < n; i = i + 1){
    append(fields, ast.node(
      "Field", {key: null, value: value_ast(v[i], token)}, token
    ))
  }
  for(let local e in entries(v)){
    local key = e[0]
    if(not(type(key) == "int" and key >= 0 and key < n) and e[1] != null){
      append(fields, ast.node("Field", {
        key: ast.literal(token, key),
        value: value_ast(e[1], token),
      }, token))
    }
  }
  return ast.node("Table", {fields: fields}, token)
}

// ------------------------------------------------------------ includes

local func ident_byte(b){
  return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
    (b >= '0' and b <= '9') or b == '_'
}

local func space_byte(b){
  return b == ' ' or b == '\t' or b == '\n' or b == '\r'
}

// the source file of a module, found as require finds it: in a package
// when the name starts with one, else on the search paths: {path, origin}
// (origin as messages name it: project files by their module path), or
// null if there is none
local func module_source(name){
  local slash = str.index_of(name, "/")
  local head = name
  local rest = "init"
  if(slash >= 0){
    head = str.substring(name, 0, slash)
    rest = str.substring(name, slash + 1)
  }
  local packages = __PACKAGES.packages
  if(packages != null and packages[head] != null){
    for(let local dir in values(packages[head].paths or {})){
      local src = concat(dir, "/", rest, ".slang")
      if(os.exists(src)){
        return {path: src, origin: src}
      }
    }
    return null
  }
  for(let local path in values(__PACKAGES.search_paths or {})){
    local src = concat(path, "/", name, ".slang")
    if(os.exists(src)){
      return {path: src, origin: concat(name, ".slang")}
    }
  }
  return null
}

// where `wgsl name {` is in buffer (before `limit` when given): the
// position of its `{`, or null
local func find_block(buffer, name, limit){
  local pos = 0
  local n = len(buffer)
  for(true){
    local i = str.index_of(buffer, "wgsl", pos)
    if(i < 0 or (limit != null and i >= limit)){
      return null
    }
    pos = i + 4
    if(i == 0 or not ident_byte(str.byte_at(buffer, i - 1))){
      local j = i + 4
      for(j < n and space_byte(str.byte_at(buffer, j))){
        j = j + 1
      }
      local k = j
      for(k < n and ident_byte(str.byte_at(buffer, k))){
        k = k + 1
      }
      if(k > j and str.substring(buffer, j, k) == name){
        for(k < n and space_byte(str.byte_at(buffer, k))){
          k = k + 1
        }
        if(k < n and str.byte_at(buffer, k) == '{'){
          return k
        }
      }
    }
  }
}

// the position of the `}` that closes the `{` at open (WGSL comments, which
// may hold braces, skipped), or null
local func closing_brace(buffer, open){
  local depth = 0
  local n = len(buffer)
  local i = open
  for(i < n){
    local b = str.byte_at(buffer, i)
    local next = 0
    if(i + 1 < n){
      next = str.byte_at(buffer, i + 1)
    }
    if(b == '/' and next == '/'){
      for(i < n and str.byte_at(buffer, i) != '\n'){
        i = i + 1
      }
    } else if(b == '/' and next == '*'){
      // block comments nest in WGSL
      local nest = 1
      i = i + 2
      for(i < n and nest > 0){
        local c = str.byte_at(buffer, i)
        local d = 0
        if(i + 1 < n){
          d = str.byte_at(buffer, i + 1)
        }
        if(c == '/' and d == '*'){
          nest = nest + 1
          i = i + 2
        } else if(c == '*' and d == '/'){
          nest = nest - 1
          i = i + 2
        } else {
          i = i + 1
        }
      }
    } else {
      if(b == '{'){
        depth = depth + 1
      } else if(b == '}'){
        depth = depth - 1
        if(depth == 0){
          return i
        }
      }
      i = i + 1
    }
  }
  return null
}

local func line_of(buffer, pos){
  local line = 1
  local nl = str.index_of(buffer, "\n")
  for(nl >= 0 and nl < pos){
    line = line + 1
    nl = str.index_of(buffer, "\n", nl + 1)
  }
  return line
}

// #include name [from "module"]: {name, module, token, stop}
local include_directive = peg.seq(
  fmt.gaps(
    peg.string("#include"):token("keyword"):trim(wgsl.trivia), null, "space"
  ),
  peg.regex("[A-Za-z_][A-Za-z0-9_]*", "expected the name of a wgsl block")
    :token("variable")
    :trim(wgsl.trivia),
  peg.seq(fmt.gaps(
    peg.seq(peg.string("from"), peg.regex("[A-Za-z0-9_]"):forbid())
      :pick(0)
      :token("keyword")
      :trim(wgsl.trivia),
    "space",
    "space",
  ), peg.regex("\"[^\"\\n]*\"", "expected the module, as a \"string\""):token("string"):trim(wgsl.trivia)):optional(,
  ),
)
  :map(func(v){
    local module = null
    local last = v[1]
    if(v[2] != null){
      local quoted = v[2][1]
      module = str.substring(quoted.value, 1, len(quoted.value) - 1)
      last = quoted
    }
    return {name: v[1].value, module: module, token: v[1], stop: last.stop}
  })

local includes_rule = fmt.mark(include_directive, {before: "hardline"}):star()

// a block's insides: its includes, then its declarations
local body_rule = peg.seq(
  wgsl.trivia:optional(),
  includes_rule,
  wgsl.items,
):map(func(v){
  return {includes: v[1], items: v[2]}
}):end()

// resolve(includes, buffer, origin, seen, out) -> void
// Appends to out, dependencies first, {origin, tokens, items} for each block
// the includes reach that seen has not. buffer and origin are the file the
// includes are written in.
local func resolve(includes, buffer, origin, seen, out){
  for(let local inc in values(includes)){
    local src = buffer
    local src_origin = origin
    if(inc.module != null){
      local found = module_source(inc.module)
      if(found == null){
        g:error_at(inc.token, "#include: no module ", inc.module)
      }
      src = os.read_file(found.path)
      src_origin = found.origin
    }
    local key = concat(src_origin, "#", inc.name)
    if(not seen[key]){
      seen[key] = true
      local open = null
      if(inc.module == null and inc.limit != null){
        open = find_block(src, inc.name, inc.limit)
      } else {
        open = find_block(src, inc.name)
      }
      if(open == null){
        local where = "before it in this file"
        if(inc.module != null){
          where = concat("in ", inc.module)
        }
        g:error_at(inc.token, "#include: no wgsl block ", inc.name, " ", where)
      }
      local close = closing_brace(src, open)
      if(close == null){
        g:error_at(
          inc.token, "#include: the block ", inc.name, " is not closed"
        )
      }
      local body = str.substring(src, open + 1, close)
      local r = peg.run(body_rule, body)
      if(not r.ok){
        g:error_at(
          inc.token, "#include: ", inc.name, " does not parse at ", src_origin,
          ":", string(line_of(src, open) + (r.far_line or r.line) - 1), ": ",
          r.far_message or r.message or "syntax error"
        )
      }
      // its own includes, relative to its file
      local nested = {}
      for(let local n in values(r.value.includes)){
        append(nested, {
          name: n.name,
          module: n.module,
          token: inc.token,
          limit: open,
        })
      }
      resolve(nested, src, src_origin, seen, out)
      local start = open + 1
      local last = r.value.includes[len(r.value.includes) - 1]
      if(last != null){
        start = open + 1 + last.stop
      }
      append(out, {
        origin: src_origin,
        tokens: wgsl.tokens(src, start, close),
        items: r.value.items,
      })
    }
  }
}

// wgsl name { program }: local name = {__info: ..., Uniforms: ..., vs: ...}
// The program is a table written out, a field for each declaration under
// its name, the name being the one in the WGSL: so what reads the code
// (the language server, slang doc) finds pond.Uniforms where the struct is
// declared, and knows it for a struct.
//
// What the fields hold is made once, by gpu/program's block, from data
// worked out here, when the file is compiled: the program's tokens and,
// apart from them, the places they stand at ("origin:line:column", which
// slang/format knows as locations, so formatting the file moves the
// program without changing what the code means), and what it declares
// (gpu/layout: its structs laid out, its constants, variables and entry
// points). The other fields find it by the block's own place.
local func expand(word, name, open, close, body){
  local origin = g:origin() or "wgsl"
  local texts = {}
  local places = {}
  local tokens = {}
  local items = {}
  // the token a declaration's field points at: its own, or for an
  // included one (whose token is in another file) the #include's
  local at_of = {}
  local func take(block_origin, block_tokens, block_items, at){
    for(let local t in values(block_tokens)){
      append(tokens, t)
      append(texts, t.text)
      append(places, concat(
        block_origin, ":", string(t.line), ":", string(t.column)
      ))
    }
    for(let local it in values(block_items)){
      append(items, it)
      if(at != null){
        at_of[it] = at
      }
    }
  }
  local start = open.stop
  local last = body.includes[len(body.includes) - 1]
  if(last != null){
    // what an included block holds may change without this file changing
    g:no_cache()
    local seen = {}
    seen[concat(origin, "#", name.value)] = true
    for(let local inc in values(body.includes)){
      local out = {}
      resolve({
        {
          name: inc.name,
          module: inc.module,
          token: inc.token,
          limit: open.start,
        },
      }, open.buffer, origin, seen, out)
      for(let local blk in values(out)){
        take(blk.origin, blk.tokens, blk.items, inc.token)
      }
    }
    start = last.stop
  }
  take(origin, wgsl.tokens(open.buffer, start, close.start), body.items, null)
  local data = layout.describe(items, tokens)
  data.label = name.value
  data.wgsl = str.join(texts, " ")
  data.at = str.join(places, " ")
  // gpu/program, named by its require in every field: what reads the code
  // follows a require into the module, and so finds what a field is
  local runtime = +{require("gpu/program")}
  local place = ast.literal(word, concat(
    origin,
    ":",
    string(name.line),
    ":",
    string(name.column),
  ))
  local fields = {}
  // a field named as the source names it (at): the name is found there
  local func field(key, at, value){
    append(fields, ast.node("Field", {
      key: ast.node("String", {value: key}, at),
      value: value,
    }, at or word))
  }
  local taken = {}
  field("__info", null, +{-{runtime}.block(-{place}, -{value_ast(data, word)})})
  for(let local it in values(items)){
    if(it.token != null and not taken[it.name]){
      local at = at_of[it] or it.token
      local key = ast.literal(word, it.name)
      local value = null
      if(it.k == "struct"){
        value = +{-{runtime}.struct(-{place}, -{key})}
      } else if(it.k == "fn"){
        for(let local e in values(data.entries)){
          if(e.name == it.name){
            value = +{-{runtime}.entry(-{place}, -{key})}
          }
        }
      } else if(it.k == "var"){
        for(let local v in values(data.vars)){
          if(v.name == it.name){
            value = +{-{runtime}.variable(-{place}, -{key})}
          }
        }
      } else if(it.k == "const"){
        for(let local c in values(data.consts)){
          if(c[0] == it.name){
            value = ast.literal(at, c[1])
          }
        }
      }
      if(value != null){
        taken[it.name] = true
        field(it.name, at, value)
      }
    }
  }
  // (the program's own fields, where no declaration has the name)
  if(not taken.label){
    field("label", null, ast.literal(word, name.value))
  }
  if(not taken.structs){
    field("structs", null, +{-{runtime}.structs(-{place})})
  }
  if(not taken.entries){
    field("entries", null, +{-{runtime}.entries(-{place})})
  }
  if(not taken.variables){
    field("variables", null, +{-{runtime}.variables(-{place})})
  }
  append(fields, ast.node("MetaField", {value: +{-{runtime}.meta}}, word))
  local id = ast.node("Identifier", {value: name.value}, name)
  return {
    token: word,
    ast: ast.node("Declaration", {
      is_local: true,
      left: id,
      right: ast.node("Table", {fields: fields}, word),
    }, word),
  }
}

local tok = func(s){
  return peg.string(s):token("punctuation"):trim(wgsl.trivia)
}

g:statement("wgsl_block", peg.seq(
  fmt.gaps(
    peg.seq(peg.string("wgsl"), peg.regex("[A-Za-z0-9_]"):forbid())
      :pick(0)
      :token("keyword")
      :trim(wgsl.trivia),
    null,
    "space",
  ),
  fmt.gaps(
    peg.regex("[A-Za-z_][A-Za-z0-9_]*", "expected the program's name")
      :token("variable.declaration")
      :trim(wgsl.trivia),
    null,
    "space",
  ),
  tok("{"),
  fmt.indent(peg.seq(includes_rule, wgsl.items):map(func(v){
    return {includes: v[0], items: v[1]}
  }), "hardline", "hardline"),
  fmt.gaps(tok("}"), "hardline"),
):map(func(v){
  return expand(v[0], v[1], v[2], v[4], v[3])
}))
