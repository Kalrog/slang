// slang/ffi: calling C libraries without writing C. C declarations are read
// from text (a header, or a few lines) and a library is loaded with them;
// its functions are then called like slang functions:
//
//   local ffi = require("slang/ffi")
//   local C = ffi.cdef("typedef struct { int quot; int rem; } div_t; div_t div(int, int); int abs(int);")
//   local libc = ffi.load(null, C)       // null: the program itself (libc)
//   libc.abs(-3)                         // 3
//   libc.div(17, 5)                      // {quot: 3, rem: 2}
//
// A header is read as C reads it: the preprocessor runs (#define, #if,
// function-like macros; #include is skipped), then the declarations are
// parsed: typedefs, structs, enums, function prototypes (function bodies,
// as in inline functions, are skipped). Enum values and #define constants
// become C.constants.
//
// How values cross (slang/ctypes does the conversions): numbers and bools
// for the arithmetic types; a string for `const char *`; a table for a
// struct (fields by name or by position), returned as a table with the
// fields by name; for a pointer null, a pointer, a string (its bytes), or a
// table: a list of elements, or one struct, which is copied back after the
// call when the pointer is not to const (an out parameter). Pointers index
// like C (p[i], p.field) and assign; ffi.new allocates memory the collector
// frees.
//
// A wrong declaration crashes the program as it would in C: the FFI calls
// what it is told is there. Callbacks (C calling slang), unions, bit fields
// and long double are not supported yet. Builds made without libffi
// (-Dffi=false) have types and memory but no calls: [load] raises there,
// and [available] says which it is.

// A C type: made by [type] from a name ("int", "Vector2 *", "float[4]"),
// and given to [new], [sizeof], [cast] and slang/buffer. Types live as long
// as the program.
// type Type

// An address and the type it points to (none for void *). p[i] reads or
// writes the i-th element, p.field a field of a struct; an element or field
// that is a struct is a pointer again, so p.pos.x = 3 writes in place.
// Pointers are == when their addresses are.
// type Pointer

// What [cdef] read: the declarations a library is loaded with.
// type Decls = {types: {[string]: table}, functions: {[string]: FunctionDecl},
//   constants: {[string]: any}, structs: table, order: {string}}
// [types]: the typedefs and structs by name ("Vector2", "struct foo")
// [functions]: the function prototypes by C name
// [constants]: enum values and #define constants (numbers, strings, structs)
// [order]: the function names in the order they were declared

// A function prototype [cdef] read.
// type FunctionDecl = {name: string, ret: table, params: {table},
//   variadic: bool, doc: string, line: int}
// [ret]: the parsed return type
// [params]: the parsed parameters, each {name, type}
// [doc]: its comment, trailing or the lines right above ("" for none)
// [line]: where it starts in the text

// What [cdef] accepts besides the text.
// type CdefOptions = {defines?: {[string]: any},
//   field_name?: func(name: string): string,
//   defaults?: {[string]: {[string]: any}}, into?: Decls}
// [defines]: macros for the preprocessor, like -D
// [field_name]: renames struct fields for slang (C's names by default)
// [defaults]: values for fields a table leaves out: {Color: {a: 255}}
// [into]: earlier declarations to add to, so headers can build on each other

// A loaded C library: its functions by their C names (lib.abs(-3)), bound
// on first use; a name the declarations do not have is null.
// type Library

// Where [load] looks for a library given by name.
// type LoadOptions = {paths?: {string}}
// [paths]: directories searched first

local str = require("slang/string")
local os = require("slang/os")

local ffi = {}

// C types and memory (every build), and calls (builds with libffi)
local ct = __PACKAGES.preloaded["slang/ctypes"][1]
local core_entry = __PACKAGES.preloaded["slang/ffi_core"]
local core = null
if(core_entry != null){
  core = core_entry[1]
}

local func need_core(){
  if(core == null){
    error("slang was built without calls to C (zig build -Dffi=false)")
  }
}

// ------------------------------------------------------------ text

// a comment's text without the marks of doc comments: the third / of ///,
// //! and ///<, and the * that starts each line of a /** ... */ block
local func comment_text(body){
  local lines = {}
  for(let local l in values(str.split(body, "\n"))){
    local t = str.trim(l)
    local k = 0
    for(k < len(t) and (str.byte_at(t, k) == 47 or str.byte_at(t, k) == 42 or
      str.byte_at(t, k) == 33 or str.byte_at(t, k) == 60)){
      k = k + 1
    }
    t = str.trim(str.substring(t, k))
    if(t != ""){
      append(lines, t)
    }
  }
  return str.join(lines, " ")
}

// the code without comments (replaced by spaces, newlines kept), and the
// comments: {line, text, own_line} with own_line when nothing precedes it;
// a block comment on lines of its own counts as on its last line
local func strip_comments(text){
  local out = {}
  local comments = {}
  local n = len(text)
  local i = 0
  local start = 0
  local line = 1
  local line_has_code = false
  for(i < n){
    local c = str.byte_at(text, i)
    if(c == 10){
      line = line + 1
      line_has_code = false
      i = i + 1
    } else if(c == 34 or c == 39){
      // a string or char literal: up to the unescaped closing quote
      local j = i + 1
      for(j < n and str.byte_at(text, j) != c and str.byte_at(text, j) != 10){
        if(str.byte_at(text, j) == 92){
          j = j + 1
        }
        j = j + 1
      }
      i = j + 1
      line_has_code = true
    } else if(c == 47 and str.byte_at(text, i + 1) == 47){
      local j = str.index_of(text, "\n", i)
      if(j < 0){
        j = n
      }
      append(out, str.substring(text, start, i))
      append(comments, {
        line: line,
        text: comment_text(str.substring(text, i + 2, j)),
        own_line: not line_has_code,
      })
      start = j
      i = j
    } else if(c == 47 and str.byte_at(text, i + 1) == 42){
      local j = str.index_of(text, "*/", i + 2)
      if(j < 0){
        j = n - 2
      }
      local body = str.substring(text, i + 2, j)
      append(out, str.substring(text, start, i))
      // keep the newlines so lines still count
      local lines = str.split(body, "\n")
      append(out, " ")
      for(local k = 1; k < len(lines); k = k + 1){
        append(out, "\n")
      }
      local own = not line_has_code
      line = line + len(lines) - 1
      local at = line
      if(not own){
        at = line - len(lines) + 1
      }
      append(comments, {line: at, text: comment_text(body), own_line: own})
      start = j + 2
      i = j + 2
    } else {
      if(c != 32 and c != 9 and c != 13){
        line_has_code = true
      }
      i = i + 1
    }
  }
  append(out, str.substring(text, start))
  return {text: str.join(out, ""), comments: comments}
}

local ident_start = str.char_class("a-zA-Z_")
local ident_rest = str.char_class("a-zA-Z0-9_")
local digits = str.char_class("0-9a-zA-Z_.")
local spaces = str.char_class(" \t\r")

local func math_min(a, b){
  if(a < b){
    return a
  }
  return b
}

local puncts3 = {["..."]: true, ["<<="]: true, [">>="]: true}
local puncts2 = {
  ["<<"]: true, [">>"]: true, ["=="]: true, ["!="]: true, ["<="]: true,
  [">="]: true, ["&&"]: true, ["||"]: true, ["##"]: true, ["->"]: true,
  ["++"]: true, ["--"]: true
}

// the tokens of a line: {kind: "id" | "num" | "str" | "char" | "punct",
// text, line}
local func lex(text, line){
  local out = {}
  local n = len(text)
  local i = 0
  for(i < n){
    local c = str.byte_at(text, i)
    if(str.class_match(spaces, text, i) > 0){
      i = str.class_run(spaces, text, i)
    } else if(str.class_match(ident_start, text, i) > 0){
      local j = str.class_run(ident_rest, text, i)
      append(out, {kind: "id", text: str.substring(text, i, j), line: line})
      i = j
    } else if(c >= 48 and c <= 57 or
      c == 46 and str.byte_at(text, i + 1) != null and
        str.byte_at(text, i + 1) >= 48 and str.byte_at(text, i + 1) <= 57){
      local j = str.class_run(digits, text, i)
      // exponents: 1e-5
      for(j < n and
        (str.byte_at(text, j) == 45 or str.byte_at(text, j) == 43) and
        (str.byte_at(text, j - 1) == 101 or str.byte_at(text, j - 1) == 69) and
        not str.starts_with(text, "0x", i)){
        j = str.class_run(digits, text, j + 1)
      }
      append(out, {kind: "num", text: str.substring(text, i, j), line: line})
      i = j
    } else if(c == 34 or c == 39){
      local j = i + 1
      for(j < n and str.byte_at(text, j) != c){
        if(str.byte_at(text, j) == 92){
          j = j + 1
        }
        j = j + 1
      }
      local kind = "str"
      if(c == 39){
        kind = "char"
      }
      append(out, {kind: kind, text: str.substring(text, i + 1, j), line: line})
      i = j + 1
    } else {
      local p = str.substring(text, i, math_min(i + 3, n))
      if(puncts3[p]){
        i = i + 3
      } else {
        p = str.substring(text, i, math_min(i + 2, n))
        if(puncts2[p]){
          i = i + 2
        } else {
          p = str.substring(text, i, i + 1)
          i = i + 1
        }
      }
      append(out, {kind: "punct", text: p, line: line})
    }
  }
  return out
}

// ------------------------------------------------------------ numbers

local func hex_value(s){
  local x = 0
  for(local k = 0; k < len(s); k = k + 1){
    local c = str.byte_at(s, k)
    local d = c - 48
    if(c >= 97){
      d = c - 87
    } else if(c >= 65){
      d = c - 55
    }
    x = x * 16 + d
  }
  return x
}

// a C number literal as a slang number, or null
local func number_value(text){
  local t = str.lower(text)
  if(str.starts_with(t, "0x")){
    for(str.ends_with(t, "u") or str.ends_with(t, "l")){
      t = str.substring(t, 0, len(t) - 1)
    }
    return hex_value(str.substring(t, 2))
  }
  for(str.ends_with(t, "u") or str.ends_with(t, "l") or str.ends_with(t, "f") ){
    t = str.substring(t, 0, len(t) - 1)
  }
  local floating = str.index_of(t, ".") >= 0 or str.index_of(t, "e") >= 0
  if(len(t) > 1 and str.starts_with(t, "0") and not floating){
    // octal
    local x = 0
    for(local k = 1; k < len(t); k = k + 1){
      x = x * 8 + str.byte_at(t, k) - 48
    }
    return x
  }
  local v = str.to_number(t)
  if(floating and v != null){
    return v * 1.0
  }
  return v
}

// ------------------------------------------------------------ constant expressions

// evaluates a C constant expression over tokens; lookup(name) gives the
// value of an identifier (null: unknown, which makes the whole expression
// unknown). Returns the value or null.
local func evaluate(tokens, lookup){
  local pos = 0
  local unknown = false
  local expr = null
  local func peek(){
    return tokens[pos]
  }
  local func is(text){
    local t = tokens[pos]
    return t != null and t.kind == "punct" and t.text == text
  }
  local func num(v){
    if(v == null){
      unknown = true
      return 0
    }
    if(type(v) == "bool"){
      if(v){
        return 1
      }
      return 0
    }
    if(type(v) != "int" and type(v) != "double"){
      unknown = true
      return 0
    }
    return v
  }
  local func primary(){
    local t = peek()
    if(t == null){
      unknown = true
      return 0
    }
    pos = pos + 1
    if(t.kind == "num"){
      return num(number_value(t.text))
    }
    if(t.kind == "char"){
      return str.byte_at(t.text, 0) or 0
    }
    if(t.kind == "str"){
      return t.text
    }
    if(t.kind == "id"){
      return lookup(t.text)
    }
    if(t.text == "("){
      // a cast: (int)x, (float)x
      local next = peek()
      local after = tokens[pos + 1]
      if(next != null and next.kind == "id" and after != null and
        after.text == ")" and lookup(next.text) == null){
        pos = pos + 2
        local v = num(primary())
        if(next.text == "int" or next.text == "long" or next.text == "unsigned"){
          return to_int(v)
        }
        return v
      }
      local v = expr(0)
      if(is(")")){
        pos = pos + 1
      }
      return v
    }
    if(t.text == "!"){
      if(num(primary()) == 0){
        return 1
      }
      return 0
    }
    if(t.text == "-"){
      return -num(primary())
    }
    if(t.text == "+"){
      return num(primary())
    }
    if(t.text == "~"){
      return -to_int(num(primary())) - 1
    }
    unknown = true
    return 0
  }
  local levels = {
    ["||"]: 1, ["&&"]: 2, ["|"]: 3, ["^"]: 4, ["&"]: 5, ["=="]: 6, ["!="]: 6,
    ["<"]: 7, [">"]: 7, ["<="]: 7, [">="]: 7, ["<<"]: 8, [">>"]: 8, ["+"]: 9,
    ["-"]: 9, ["*"]: 10, ["/"]: 10, ["%"]: 10
  }
  local func apply(op, a, b){
    if(op == "+" and type(a) == "string"){
      unknown = true
      return 0
    }
    a = num(a)
    b = num(b)
    if(op == "||"){
      return (a != 0 or b != 0) and 1 or 0
    }
    if(op == "&&"){
      return (a != 0 and b != 0) and 1 or 0
    }
    if(op == "|"){
      return to_int(a) | to_int(b)
    }
    if(op == "^"){
      return to_int(a) ^ to_int(b)
    }
    if(op == "&"){
      return to_int(a) & to_int(b)
    }
    if(op == "=="){
      return a == b and 1 or 0
    }
    if(op == "!="){
      return a != b and 1 or 0
    }
    if(op == "<"){
      return a < b and 1 or 0
    }
    if(op == ">"){
      return a > b and 1 or 0
    }
    if(op == "<="){
      return a <= b and 1 or 0
    }
    if(op == ">="){
      return a >= b and 1 or 0
    }
    if(op == "<<"){
      return to_int(a) << to_int(b)
    }
    if(op == ">>"){
      return to_int(a) >> to_int(b)
    }
    if(op == "+"){
      return a + b
    }
    if(op == "-"){
      return a - b
    }
    if(op == "*"){
      return a * b
    }
    if(op == "/"){
      if(b == 0){
        unknown = true
        return 0
      }
      if(type(a) == "int" and type(b) == "int"){
        return to_int(a / b)
      }
      return a / b
    }
    if(op == "%"){
      if(b == 0){
        unknown = true
        return 0
      }
      return a % b
    }
    unknown = true
    return 0
  }
  expr = func(min){
    local a = primary()
    for(true){
      local t = peek()
      if(t == null or t.kind != "punct"){
        break
      }
      if(t.text == "?" and min == 0){
        pos = pos + 1
        local yes = expr(0)
        if(is(":")){
          pos = pos + 1
        }
        local no = expr(0)
        if(num(a) != 0){
          a = yes
        } else {
          a = no
        }
        continue
      }
      local level = levels[t.text]
      if(level == null or level <= min){
        break
      }
      pos = pos + 1
      a = apply(t.text, a, expr(level))
    }
    return a
  }
  local v = expr(0)
  if(unknown or pos < len(tokens)){
    return null
  }
  return v
}

// ------------------------------------------------------------ the preprocessor

local func platform_defines(){
  local p = os.platform()
  local d = {
    __STDC__: 1, __STDC_VERSION__: 201112, __STDC_HOSTED__: 1, __LP64__: 1
  }
  if(str.starts_with(p, "macos")){
    d.__APPLE__ = 1
    d.__MACH__ = 1
  } else if(str.starts_with(p, "linux")){
    d.__linux__ = 1
    d.__unix__ = 1
  } else if(str.starts_with(p, "windows")){
    d._WIN32 = 1
    d._WIN64 = 1
  }
  if(str.ends_with(p, "aarch64")){
    d.__aarch64__ = 1
    d.__arm64__ = 1
  } else if(str.ends_with(p, "x86_64")){
    d.__x86_64__ = 1
  }
  return d
}

// a macro: {params: list or null, body: tokens}
local func macro_of(tokens){
  return {params: null, body: tokens}
}

local expand = null

// the arguments of a function-like macro call starting at tokens[i] ("("):
// {args, next}, or null when the call is not complete
local func macro_args(tokens, i){
  local args = {}
  local current = {}
  local depth = 0
  for(local j = i + 1; j < len(tokens); j = j + 1){
    local t = tokens[j]
    if(t.kind == "punct" and t.text == "("){
      depth = depth + 1
    } else if(t.kind == "punct" and t.text == ")"){
      if(depth == 0){
        if(len(current) > 0 or len(args) > 0){
          append(args, current)
        }
        return {args: args, next: j + 1}
      }
      depth = depth - 1
    } else if(t.kind == "punct" and t.text == "," and depth == 0){
      append(args, current)
      current = {}
      continue
    }
    append(current, t)
  }
  return null
}

// the tokens with the macros replaced; active names are not expanded
// again (a macro does not expand inside itself)
expand = func(tokens, macros, active){
  local out = {}
  local i = 0
  local n = len(tokens)
  for(i < n){
    local t = tokens[i]
    local m = null
    if(t.kind == "id" and not active[t.text]){
      m = macros[t.text]
    }
    if(m == null){
      append(out, t)
      i = i + 1
    } else if(m.params == null){
      active[t.text] = true
      for(let local e in values(expand(m.body, macros, active))){
        append(out, {kind: e.kind, text: e.text, line: t.line})
      }
      active[t.text] = null
      i = i + 1
    } else {
      local call = null
      if(tokens[i + 1] != null and tokens[i + 1].text == "("){
        call = macro_args(tokens, i + 1)
      }
      if(call == null){
        append(out, t)
        i = i + 1
      } else {
        local by_name = {}
        for(local k = 0; k < len(m.params); k = k + 1){
          by_name[m.params[k]] = expand(call.args[k] or {}, macros, active)
        }
        local body = {}
        for(let local b in values(m.body)){
          local arg = null
          if(b.kind == "id"){
            arg = by_name[b.text]
          }
          if(arg != null){
            for(let local a in values(arg)){
              append(body, a)
            }
          } else if(not(b.kind == "punct" and (b.text == "#" or b.text == "##"))){
            append(body, b)
          }
        }
        active[t.text] = true
        for(let local e in values(expand(body, macros, active))){
          append(out, {kind: e.kind, text: e.text, line: t.line})
        }
        active[t.text] = null
        i = call.next
      }
    }
  }
  return out
}

// preprocess(text, defines) -> {tokens, macros, comments, defines}: the
// tokens of the code the conditionals leave, macros expanded
local func preprocess(text, defines){
  local stripped = strip_comments(text)
  local lines = str.split(stripped.text, "\n")
  local macros = {}
  for(let local e in entries(platform_defines())){
    macros[e[0]] = macro_of({{kind: "num", text: string(e[1]), line: 0}})
  }
  for(let local e in entries(defines or {})){
    macros[e[0]] = macro_of(lex(string(e[1]), 0))
  }
  // the object-like macros in the order they were defined: constants
  local defined_order = {}
  // the conditionals: {active, taken, parent_active}
  local stack = {}
  local active = true
  local out = {}
  local func condition(tokens){
    // defined(X) and defined X first, then the macros
    local resolved = {}
    local i = 0
    for(i < len(tokens)){
      local t = tokens[i]
      if(t.kind == "id" and t.text == "defined"){
        local name = tokens[i + 1]
        local skip = 2
        if(name != null and name.text == "("){
          name = tokens[i + 2]
          skip = 4
        }
        local v = "0"
        if(name != null and macros[name.text] != null){
          v = "1"
        }
        append(resolved, {kind: "num", text: v, line: t.line})
        i = i + skip
      } else {
        append(resolved, t)
        i = i + 1
      }
    }
    local v = evaluate(expand(resolved, macros, {}), func(name){
      // an unknown identifier is 0 in #if
      return 0
    })
    return v != null and v != 0
  }
  for(local ln = 0; ln < len(lines); ln = ln + 1){
    local line = lines[ln]
    // continuation lines
    for(str.ends_with(line, "\\") and ln + 1 < len(lines)){
      line = concat(str.substring(line, 0, len(line) - 1), " ", lines[ln + 1])
      lines[ln + 1] = ""
      ln = ln + 1
    }
    local t = str.trim(line)
    if(str.starts_with(t, "#")){
      local d = lex(str.substring(t, 1), ln + 1)
      local word = ""
      if(len(d) > 0){
        word = d[0].text
      }
      if(word == "if" or word == "ifdef" or word == "ifndef"){
        local parent = active
        local yes = false
        if(parent){
          if(word == "ifdef"){
            yes = macros[d[1].text] != null
          } else if(word == "ifndef"){
            yes = macros[d[1].text] == null
          } else {
            local rest = {}
            for(local k = 1; k < len(d); k = k + 1){
              append(rest, d[k])
            }
            yes = condition(rest)
          }
        }
        append(stack, {parent: parent, taken: yes})
        active = parent and yes
      } else if(word == "elif" and len(stack) > 0){
        local top = stack[len(stack) - 1]
        if(top.parent and not top.taken){
          local rest = {}
          for(local k = 1; k < len(d); k = k + 1){
            append(rest, d[k])
          }
          local yes = condition(rest)
          top.taken = yes
          active = yes
        } else {
          active = false
        }
      } else if(word == "else" and len(stack) > 0){
        local top = stack[len(stack) - 1]
        active = top.parent and not top.taken
        top.taken = true
      } else if(word == "endif" and len(stack) > 0){
        local top = remove(stack, len(stack) - 1)
        active = top.parent
      } else if(active and word == "define" and len(d) > 1){
        local name = d[1].text
        // NAME( with no space is a function-like macro
        local after = str.index_of(t, name, str.index_of(t, "define") + 6) +
          len(name)
        if(str.byte_at(t, after) == 40){
          local params = {}
          local k = 3
          for(k < len(d) and d[k].text != ")"){
            if(d[k].text != ","){
              append(params, d[k].text)
            }
            k = k + 1
          }
          local body = {}
          for(local b = k + 1; b < len(d); b = b + 1){
            append(body, d[b])
          }
          macros[name] = {params: params, body: body}
        } else {
          local body = {}
          for(local b = 2; b < len(d); b = b + 1){
            append(body, d[b])
          }
          macros[name] = macro_of(body)
          append(defined_order, {name: name, line: ln + 1})
        }
      } else if(active and word == "undef" and len(d) > 1){
        macros[d[1].text] = null
      }
      // #include, #pragma, #error, #line: nothing to do
    } else if(active and t != ""){
      for(let local tok in values(expand(lex(line, ln + 1), macros, {}))){
        append(out, tok)
      }
    }
  }
  return {
    tokens: out,
    macros: macros,
    comments: stripped.comments,
    defined_order: defined_order,
  }
}

// ------------------------------------------------------------ declarations

// C types while parsing: {kind: "prim", name} (an ffi_core primitive),
// {kind: "void"}, {kind: "ptr", to, const_to}, {kind: "array", of, n},
// {kind: "struct", name, info}, {kind: "func", ret, params, variadic},
// {kind: "opaque", name, why}; a type also has c, its C spelling.

local builtin_typedefs = {
  size_t: "uint64", ssize_t: "int64", ptrdiff_t: "int64", intptr_t: "int64",
  uintptr_t: "uint64", int8_t: "int8", uint8_t: "uint8", int16_t: "int16",
  uint16_t: "uint16", int32_t: "int32", uint32_t: "uint32", int64_t: "int64",
  uint64_t: "uint64", wchar_t: "int32", off_t: "int64"
}

local qualifiers = {
  const: true, volatile: true, restrict: true, __restrict: true,
  __restrict__: true, extern: true, static: true, inline: true, __inline: true,
  __inline__: true, register: true, auto: true, _Noreturn: true,
  __extension__: true, __cdecl: true, __stdcall: true
}

// cdef(text: string, options?: CdefOptions) -> Decls
// Reads C declarations: the preprocessor runs, then typedefs, structs,
// enums and function prototypes are parsed. Raises "ffi.cdef: ..." naming
// the line for what it cannot parse.
//
//   local C = ffi.cdef(os.read_file("mylib.h"), {defines: {MYLIB_API: ""}})
func ffi.cdef(text, options){
  options = options or {}
  local decls = options.into or {
    types: {}, functions: {}, constants: {}, structs: {}, order: {}
  }
  local field_name = options.field_name or func(name){ return name }
  local pre = preprocess(text, options.defines)
  local tokens = pre.tokens
  local pos = 0
  local n = len(tokens)

  // docs: the comment on the line a declaration ends, else the comment
  // lines right above where it starts
  local trailing = {}
  local above = {}
  for(let local c in values(pre.comments)){
    if(c.own_line){
      above[c.line] = c.text
    } else {
      trailing[c.line] = c.text
    }
  }
  local func doc_of(first_line, last_line){
    if(trailing[last_line] != null){
      return trailing[last_line]
    }
    local lines = {}
    local l = first_line - 1
    for(above[l] != null){
      append(lines, above[l])
      l = l - 1
    }
    local out = {}
    for(local k = len(lines) - 1; k >= 0; k = k - 1){
      append(out, lines[k])
    }
    return str.join(out, " ")
  }

  local func peek(k){
    return tokens[pos + (k or 0)]
  }
  local func is(text){
    local t = tokens[pos]
    return t != null and t.text == text and t.kind != "str"
  }
  local func fail(message){
    local t = tokens[pos]
    local where = "the end"
    if(t != null){
      where = concat("line ", string(t.line), " at ", t.text)
    }
    error("ffi.cdef: ", message, " (", where, ")")
  }
  local func expect(text){
    if(not is(text)){
      fail(concat(text, " expected"))
    }
    pos = pos + 1
  }
  // skips balanced brackets from an opening one at pos
  local func skip_group(){
    local open = tokens[pos].text
    local close = {["("]: ")", ["{"]: "}", ["["]: "]"}[open]
    local depth = 0
    for(pos < n){
      local t = tokens[pos]
      pos = pos + 1
      if(t.kind == "punct" and t.text == open){
        depth = depth + 1
      } else if(t.kind == "punct" and t.text == close){
        depth = depth - 1
        if(depth == 0){
          return
        }
      }
    }
  }
  local func constant_lookup(name){
    return decls.constants[name]
  }
  // a constant expression up to one of the stop tokens (at depth 0)
  local func constant_until(stops){
    local expr = {}
    local depth = 0
    for(pos < n){
      local t = tokens[pos]
      if(depth == 0 and t.kind == "punct" and stops[t.text]){
        break
      }
      if(t.text == "(" or t.text == "[" or t.text == "{"){
        depth = depth + 1
      } else if(t.text == ")" or t.text == "]" or t.text == "}"){
        depth = depth - 1
      }
      append(expr, t)
      pos = pos + 1
    }
    return evaluate(expr, constant_lookup)
  }

  local func struct_type(name){
    local key = concat("struct ", name)
    local t = decls.types[key]
    if(t == null){
      t = {kind: "struct", name: name, c: key, info: null}
      decls.types[key] = t
    }
    return t
  }

  local parse_specifiers = null
  local parse_declarator = null

  // the members of a struct body at pos ("{")
  local func parse_struct_body(t){
    expect("{")
    local fields = {}
    local why = null
    for(not is("}")){
      if(pos >= n){
        fail("} expected")
      }
      local spec = parse_specifiers()
      if(is(";")){
        // an anonymous struct or union member
        why = "an anonymous member"
      }
      for(not is(";")){
        local d = parse_declarator(spec.type, false)
        if(is(":")){
          why = "a bit field"
          pos = pos + 1
          constant_until({[","]: true, [";"]: true})
        }
        append(fields, {name: d.name, type: d.type})
        if(is(",")){
          pos = pos + 1
        } else if(not is(";")){
          fail("; expected after a struct member")
        }
      }
      expect(";")
    }
    expect("}")
    if(why != null){
      t.unsupported = why
    }
    t.fields = fields
  }

  local func parse_enum_body(){
    expect("{")
    local value = -1
    for(not is("}")){
      local name = tokens[pos].text
      pos = pos + 1
      if(is("=")){
        pos = pos + 1
        local v = constant_until({[","]: true, ["}"]: true})
        if(v == null){
          v = value + 1
        }
        value = v
      } else {
        value = value + 1
      }
      decls.constants[name] = value
      if(is(",")){
        pos = pos + 1
      }
    }
    expect("}")
  }

  // the specifiers of a declaration: {type, typedef}
  parse_specifiers = func(){
    local counts = {}
    local base = null
    local is_typedef = false
    local is_const = false
    for(pos < n){
      local t = tokens[pos]
      local w = t.text
      if(t.kind != "id"){
        break
      }
      if(w == "typedef"){
        is_typedef = true
        pos = pos + 1
      } else if(w == "const"){
        is_const = true
        pos = pos + 1
      } else if(qualifiers[w]){
        pos = pos + 1
      } else if(w == "__attribute__" or w == "__declspec" or w == "__asm__" or
        w == "__asm" or w == "_Alignas"){
        pos = pos + 1
        if(is("(")){
          skip_group()
        }
      } else if(w == "signed" or w == "unsigned" or w == "short" or
        w == "long" or w == "int" or w == "char" or w == "float" or
        w == "double" or w == "void" or w == "_Bool" or w == "bool"){
        counts[w] = (counts[w] or 0) + 1
        pos = pos + 1
      } else if(w == "struct" or w == "union"){
        pos = pos + 1
        local name = null
        if(peek() != null and peek().kind == "id"){
          name = peek().text
          pos = pos + 1
        }
        local st = null
        if(name != null){
          st = struct_type(name)
        } else {
          st = {kind: "struct", name: "(anonymous)", c: "struct", info: null}
        }
        if(w == "union"){
          st.unsupported = "a union"
        }
        if(is("{")){
          parse_struct_body(st)
        }
        base = st
      } else if(w == "enum"){
        pos = pos + 1
        local name = null
        if(peek() != null and peek().kind == "id"){
          name = peek().text
          pos = pos + 1
        }
        if(is("{")){
          parse_enum_body()
        }
        base = {kind: "prim", name: "int32", c: concat("enum ", name or "")}
      } else if(base == null and counts.int == null and counts.char == null and
        counts.long == null and counts.short == null and
        counts.signed == null and counts.unsigned == null and
        counts.float == null and counts.double == null and
        counts.void == null and counts._Bool == null and counts.bool == null){
        // a typedef name
        if(decls.types[w] != null){
          base = decls.types[w]
        } else if(builtin_typedefs[w] != null){
          base = {kind: "prim", name: builtin_typedefs[w], c: w}
        } else if(w == "va_list" or w == "__builtin_va_list" or w == "FILE"){
          base = {
            kind: "opaque", name: w, c: w, why: concat(w, " cannot be passed")
          }
        } else {
          break
        }
        pos = pos + 1
      } else {
        break
      }
    }
    if(base == null){
      local c = counts
      local u = c.unsigned != null
      if(c.void != null){
        base = {kind: "void", c: "void"}
      } else if(c._Bool != null or c.bool != null){
        base = {kind: "prim", name: "bool", c: "bool"}
      } else if(c.char != null){
        if(u){
          base = {kind: "prim", name: "uint8", c: "unsigned char", char: true}
        } else if(c.signed != null){
          base = {kind: "prim", name: "int8", c: "signed char", char: true}
        } else {
          // plain char: its arrays are strings
          base = {kind: "prim", name: "char", c: "char", char: true}
        }
      } else if(c.float != null){
        base = {kind: "prim", name: "float", c: "float"}
      } else if(c.double != null){
        if(c.long != null){
          base = {
            kind: "opaque", name: "long double", c: "long double",
            why: "long double is not supported"
          }
        } else {
          base = {kind: "prim", name: "double", c: "double"}
        }
      } else if(c.short != null){
        base = {
          kind: "prim",
          name: u and "uint16" or "int16",
          c: u and "unsigned short" or "short",
        }
      } else if(c.long != null){
        base = {
          kind: "prim",
          name: u and "uint64" or "int64",
          c: u and "unsigned long" or "long",
        }
      } else if(c.int != null or c.signed != null or u){
        base = {
          kind: "prim",
          name: u and "uint32" or "int32",
          c: u and "unsigned int" or "int",
        }
      } else {
        fail("a type expected")
      }
    }
    if(is_const){
      // a copy that knows it is const (const char *)
      local copy = {}
      for(let local e in entries(base)){
        copy[e[0]] = e[1]
      }
      copy.const = true
      copy.original = base.original or base
      base = copy
    }
    return {type: base, typedef: is_typedef}
  }

  local func params_of(){
    expect("(")
    local params = {}
    local variadic = false
    if(is("void") and peek(1) != null and peek(1).text == ")"){
      pos = pos + 1
    }
    for(not is(")")){
      if(is("...")){
        variadic = true
        pos = pos + 1
      } else {
        local spec = parse_specifiers()
        local d = parse_declarator(spec.type, true)
        local t = d.type
        // arrays and functions are passed as pointers
        if(t.kind == "array"){
          t = {
            kind: "ptr",
            to: t.of,
            const_to: t.of.const == true,
            c: concat(t.of.c, " *"),
          }
        } else if(t.kind == "func"){
          t = {kind: "ptr", to: t, c: "function pointer"}
        }
        append(params, {name: d.name, type: t})
      }
      if(is(",")){
        pos = pos + 1
      } else if(not is(")")){
        fail(", or ) expected in parameters")
      }
    }
    expect(")")
    return {params: params, variadic: variadic}
  }

  // a declarator over base: {name, type}; abstract ones (parameters, the
  // names of types) may leave the name out
  parse_declarator = func(base, abstract){
    local t = base
    for(is("*")){
      pos = pos + 1
      t = {kind: "ptr", to: t, const_to: t.const == true, c: concat(t.c, " *")}
      for(peek() != null and peek().kind == "id" and qualifiers[peek().text]){
        pos = pos + 1
      }
      for(is("__attribute__")){
        pos = pos + 1
        skip_group()
      }
    }
    local name = null
    local inner_start = null
    if(is("(") and peek(1) != null and
      (peek(1).text == "*" or peek(1).text == "^" or peek(1).text == "(")){
      // ( declarator ): parsed after the suffixes, which apply first
      inner_start = pos
      skip_group()
    } else if(peek() != null and peek().kind == "id" and
      not qualifiers[peek().text]){
      name = peek().text
      pos = pos + 1
    }
    // suffixes: arrays and parameter lists, the innermost first
    local suffixes = {}
    for(is("[") or is("(")){
      if(is("[")){
        pos = pos + 1
        local count = 0
        if(not is("]")){
          count = constant_until({["]"]: true})
          if(count == null){
            fail("an array size that is not a constant")
          }
        }
        expect("]")
        append(suffixes, {kind: "array", n: count})
      } else {
        local p = params_of()
        append(suffixes, {kind: "func", params: p.params, variadic: p.variadic})
      }
    }
    for(local k = len(suffixes) - 1; k >= 0; k = k - 1){
      local s = suffixes[k]
      if(s.kind == "array"){
        t = {
          kind: "array", of: t, n: s.n, c: concat(t.c, "[", string(s.n), "]")
        }
      } else {
        t = {
          kind: "func", ret: t, params: s.params, variadic: s.variadic,
          c: "function"
        }
      }
    }
    for(is("__attribute__") or is("__asm__") or is("__asm")){
      pos = pos + 1
      skip_group()
    }
    if(inner_start != null){
      local after = pos
      pos = inner_start + 1
      local d = parse_declarator(t, abstract)
      expect(")")
      pos = after
      return d
    }
    return {name: name, type: t}
  }

  for(pos < n){
    if(is(";")){
      pos = pos + 1
      continue
    }
    local first_line = tokens[pos].line
    local spec = parse_specifiers()
    for(not is(";")){
      local d = parse_declarator(spec.type, false)
      if(spec.typedef){
        if(d.name != null){
          local t = d.type
          if(t.kind == "struct" and t.name == "(anonymous)"){
            t.name = d.name
            t.c = d.name
          }
          decls.types[d.name] = t
        }
      } else if(d.type.kind == "func" and d.name != null){
        local last_line = tokens[pos - 1].line
        if(not is("{")){
          last_line = tokens[pos].line
        }
        decls.functions[d.name] = {
          name: d.name,
          ret: d.type.ret,
          params: d.type.params,
          variadic: d.type.variadic,
          doc: doc_of(first_line, last_line),
          line: first_line,
        }
        append(decls.order, d.name)
      }
      if(is("{")){
        // a function definition (an inline function): its body is skipped
        skip_group()
        break
      }
      if(is("=")){
        // an initializer: skipped
        pos = pos + 1
        constant_until({[","]: true, [";"]: true})
      }
      if(is(",")){
        pos = pos + 1
      } else if(not is(";")){
        fail("; expected")
      }
    }
    if(is(";")){
      pos = pos + 1
    }
  }

  // #define constants: numbers, strings and compound literals of structs
  for(let local d in values(pre.defined_order)){
    local m = pre.macros[d.name]
    if(m != null and m.params == null and decls.constants[d.name] == null){
      local body = expand(m.body, pre.macros, {[d.name]: true})
      local v = evaluate(body, constant_lookup)
      if(v == null and len(body) > 3){
        // (Type){ a, b, c } or Type{ a, b, c }
        local k = 0
        if(body[0].text == "("){
          k = 1
        }
        local tname = body[k].text
        local st = decls.types[tname]
        local open = k + 1
        if(k == 1){
          open = 3
        }
        if(st != null and st.kind == "struct" and body[open] != null and
          body[open].text == "{"){
          local parts = {}
          local current = {}
          for(local j = open + 1; j < len(body); j = j + 1){
            local b = body[j]
            if(b.text == "," or b.text == "}"){
              append(parts, evaluate(current, constant_lookup))
              current = {}
            } else {
              append(current, b)
            }
          }
          local fields = st.fields or {}
          if(len(parts) == len(fields)){
            v = {}
            for(local j = 0; j < len(parts); j = j + 1){
              v[field_name(fields[j].name)] = parts[j]
            }
          }
        }
      }
      if(v != null){
        decls.constants[d.name] = v
      }
    }
  }
  decls.field_name = field_name
  decls.defaults = options.defaults or decls.defaults
  return decls
}

// header(path: string) -> string
// The text of a header file with the headers it includes by quoted name
// (`#include "types.h"`, found next to the file that includes it) put in
// their place, each file once, for [cdef], which skips `#include`. The
// includes are spliced whether or not an `#if` around them holds; system
// headers (`<stdint.h>`) stay out.
//
//   local C = ffi.cdef(ffi.header("/usr/include/box2d/box2d.h"))
func ffi.header(path){
  local seen = {}
  local splice = null
  splice = func(file){
    if(seen[file]){
      return ""
    }
    seen[file] = true
    local slash = len(file)
    for(slash > 0 and str.byte_at(file, slash - 1) != 47){
      slash = slash - 1
    }
    local dir = str.substring(file, 0, slash)
    local out = {}
    for(let local line in values(str.split(os.read_file(file), "\n"))){
      local t = str.trim(line)
      local q = str.index_of(t, "\"")
      if(str.starts_with(t, "#") and q > 0 and
        str.trim(str.substring(t, 1, q)) == "include"){
        local name = str.substring(t, q + 1, str.index_of(t, "\"", q + 1))
        local inner = concat(dir, name)
        if(os.exists(inner)){
          append(out, splice(inner))
        } else {
          append(out, line)
        }
      } else {
        append(out, line)
      }
    }
    return str.join(out, "\n")
  }
  return splice(path)
}

// ------------------------------------------------------------ to ffi_core

local prims = {}
local func prim(name){
  if(prims[name] == null){
    prims[name] = ct.primitive(name)
  }
  return prims[name]
}

// the ffi_core type of a parsed C type, or an error naming why it cannot
// cross
local core_of = null
core_of = func(t, decls){
  if(t.core != null){
    return t.core
  }
  local k = t.kind
  local c = null
  if(k == "prim"){
    c = prim(t.name)
  } else if(k == "void"){
    c = prim("void")
  } else if(k == "ptr"){
    local to = t.to
    if(to.kind == "prim" and to.char and t.const_to){
      c = prim("string")
    } else if(to.kind == "void" or to.kind == "func" or to.kind == "opaque"){
      c = ct.pointer(null)
    } else if(to.kind == "struct" and to.unsupported != null){
      c = ct.pointer(null)
    } else {
      c = ct.pointer(core_of(to, decls))
    }
  } else if(k == "array"){
    c = ct.array(core_of(t.of, decls), t.n)
  } else if(k == "struct"){
    local original = t.original or t
    if(original.core == null){
      original.core = ct.struct(original.name)
      if(original.fields != null and original.unsupported == null){
        local fields = {}
        local defaults = (decls.defaults or {})[original.name] or {}
        for(let local f in values(original.fields)){
          local name = decls.field_name(f.name)
          append(fields, {name, core_of(f.type, decls), defaults[name]})
        }
        ct.define(original.core, fields)
      }
    }
    c = original.core
  } else if(k == "opaque"){
    error(t.why)
  } else if(k == "func"){
    c = ct.pointer(null)
  }
  t.core = c
  return c
}

// ------------------------------------------------------------ types by name

// type(name: string, decls?: Decls) -> Type
// The type a C type name stands for: "int", "uint8_t", "Vector2",
// "struct foo", "Vector2 *", "float[4]".
// [decls]: the declarations that define the struct and typedef names
func ffi.type(name, decls){
  decls = decls or {
    types: {}, functions: {}, constants: {}, structs: {}, order: {}
  }
  decls.field_name = decls.field_name or func(n){ return n }
  // parsed as the declaration of a typedef: int[4] is int __probe[4]
  local head = name
  local tail = ""
  local bracket = str.index_of(name, "[")
  if(bracket >= 0){
    head = str.substring(name, 0, bracket)
    tail = str.substring(name, bracket)
  }
  local probe = ffi.cdef(
    concat("typedef ", head, " __ffi_type_probe", tail, ";"),
    {into: decls, field_name: decls.field_name},
  )
  local t = probe.types.__ffi_type_probe
  probe.types.__ffi_type_probe = null
  return core_of(t, decls)
}

local func as_type(t, decls){
  if(type(t) == "string"){
    return ffi.type(t, decls)
  }
  return t
}

// new(t: string | Type, n?: int, decls?: Decls) -> Pointer
// A pointer to n (1 by default) zeroed values of t, memory the collector
// frees once nothing points into it.
func ffi.new(t, count, decls){
  return ct.new(as_type(t, decls), count or 1)
}

// sizeof(t: string | Type, decls?: Decls) -> int
// The size of a C type in bytes.
func ffi.sizeof(t, decls){
  return ct.sizeof(as_type(t, decls))
}

// cast(p: Pointer | int, t?: string | Type, decls?: Decls) -> Pointer
// The same address as a pointer to t (null: void *). An int is taken as an
// address.
func ffi.cast(p, t, decls){
  if(t == null){
    return ct.cast(p, null)
  }
  return ct.cast(p, as_type(t, decls))
}

// string(p: Pointer?, n?: int) -> string?
// The zero-terminated C string at p, or the n bytes there; null for a
// null pointer.
func ffi.string(p, n){
  return ct.string(p, n)
}

// offset(p: Pointer, n: int) -> Pointer
// The pointer n elements further (bytes for a void pointer); n may be
// negative.
func ffi.offset(p, n){
  return ct.offset(p, n)
}

// address(p: Pointer?) -> int
// The address as an int (0 for null).
func ffi.address(p){
  return ct.address(p)
}

// value(p: Pointer) -> any
// What p points to, copied: a number, or a table for a struct. Raises for
// a void pointer.
func ffi.value(p){
  return ct.value(p)
}

// ------------------------------------------------------------ libraries

local func library_suffixes(){
  local p = os.platform()
  if(str.starts_with(p, "macos")){
    return {".dylib", ".so"}
  }
  if(str.starts_with(p, "windows")){
    return {".dll"}
  }
  return {".so"}
}

// where a library name is looked for: options.paths, slang's native
// search paths, then the usual prefixes
local func library_dirs(options){
  local dirs = {}
  for(let local d in values(options.paths or {})){
    append(dirs, d)
  }
  for(let local d in values(__PACKAGES.nativeSearchPaths or {})){
    append(dirs, d)
  }
  for(let local d in values({
    "/opt/homebrew/lib", "/usr/local/lib", "/usr/lib",
    "/usr/lib/x86_64-linux-gnu", "/usr/lib/aarch64-linux-gnu"
  })){
    append(dirs, d)
  }
  return dirs
}

// the library: name is a path (with a / or a suffix) or a name ("raylib"
// is libraylib.dylib in the search directories, then wherever the system
// finds it); null is the program itself
local func open_library(name, options){
  if(name == null){
    return core.open(null)
  }
  local tried = {}
  local func try_open(path){
    local h = core.open(path)
    if(type(h) == "table"){
      append(tried, h[1])
      return null
    }
    return h
  }
  if(str.index_of(name, "/") >= 0 or str.index_of(name, ".") >= 0){
    local h = try_open(name)
    if(h != null){
      return h
    }
  } else {
    for(let local dir in values(library_dirs(options))){
      for(let local suffix in values(library_suffixes())){
        local path = concat(dir, "/lib", name, suffix)
        if(os.exists(path)){
          local h = try_open(path)
          if(h != null){
            return h
          }
        }
      }
    }
    for(let local suffix in values(library_suffixes())){
      local h = try_open(concat("lib", name, suffix))
      if(h != null){
        return h
      }
    }
  }
  error(
    "ffi.load: cannot load the C library ",
    name,
    ": ",
    str.join(tried, "; "),
  )
}

// the slang function calling the C function f declares (name: what errors
// call it, its C name by default)
local func bind(lib, f, decls, name){
  local sym = core.symbol(lib.handle, f.name)
  if(sym == null){
    error("ffi: ", f.name, " is declared but not in the library")
  }
  local args = {}
  local writeback = {}
  for(let local p in values(f.params)){
    local r = pcall(core_of, p.type, decls)
    if(r[0] == "err"){
      error("ffi: cannot call ", f.name, ": ", r[1].message)
    }
    append(args, r[1])
    // a pointer to something not const is copied back (out parameters)
    local t = p.type
    append(
      writeback,
      t.kind == "ptr" and not t.const_to and t.to.kind != "void",
    )
  }
  local r = pcall(core_of, f.ret, decls)
  if(r[0] == "err"){
    error("ffi: cannot call ", f.name, ": ", r[1].message)
  }
  return core.func(sym, r[1], args, name or f.name, writeback, f.variadic)
}

local library_meta = {
  __index: func(lib, name){
    local f = lib.decls.functions[name]
    if(f == null){
      return null
    }
    local fn = bind(lib, f, lib.decls)
    set_raw(lib, name, fn)
    return fn
  },
  __type: "ffi.library",
}

// load(name: string?, decls: Decls, options?: LoadOptions) -> Library
// Loads a C library with the declarations of its functions. A library
// name ("raylib") is libraylib.dylib or .so in options.paths, slang's
// native search paths, /opt/homebrew/lib, /usr/local/lib, /usr/lib, then
// wherever the system finds it. Raises "ffi.load: ..." with what each
// attempt said when it cannot load it.
// [name]: a path (with a / or a .), a library name, or null for the program
func ffi.load(name, decls, options){
  need_core()
  options = options or {}
  local handle = open_library(name, options)
  return {meta: library_meta, handle: handle, decls: decls}
}

// bind(lib: Library, f: FunctionDecl, name?: string) -> function
// The slang function calling the C function f declares (from
// decls.functions), bound to lib; lib.Name does the same for a declared
// name. Raises when the library lacks the symbol or a parameter's type
// cannot cross.
// [name]: what errors call it (its C name by default)
func ffi.bind(lib, f, name){
  need_core()
  return bind(lib, f, lib.decls, name)
}

// available() -> bool
// Whether this slang can call C (it was built with libffi).
func ffi.available(){
  return core != null
}

return ffi
