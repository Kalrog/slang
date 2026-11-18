// gpu/wgsl: WGSL (the WebGPU Shading Language, https://www.w3.org/TR/WGSL/)
// as slang/peg parsers: the language as it is, not a dialect of it. Its
// tokens carry highlighting categories and its parsers the formatter's
// marks, so WGSL is highlighted and formatted wherever this grammar parses
// it: a `wgsl name { ... }` block in a slang file (gpu/syntax).
//
//   local wgsl = require("gpu/wgsl")
//   local items = wgsl.parse("@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0); }")
//   items[0].name          // "fs"
//
// The grammar follows the specification's (section "Grammar for recursive
// descent parsing"), with these differences:
// - Operators have C's usual precedence. WGSL asks for parentheses where
//   that could mislead (`a & b | c`, `a < b < c`); the grammar takes those
//   too, and the WGSL compiler turns them down. A valid program parses the
//   same either way.
// - Numbers also take the suffixes li, lu and lf (64-bit numbers, which
//   wgpu's compiler has as an extension).
// - Template lists (`vec2<f32>`, `var<uniform>`) are found as the
//   specification's "template list discovery" finds them, statement by
//   statement while parsing instead of in a pass before it.
//
// The parsers produce a tree of what a program declares, for the package to
// read: items {k: "struct" | "fn" | "var" | "override" | "const" | "alias" |
// "directive" | "const_assert", name, attributes, ...}, types and
// expressions {k: "name" | "num" | "bool" | "call" | "bin" | "un" | "index" |
// "member", ...}. Function bodies are parsed (they are formatted and
// highlighted) and kept as their statements.
local peg = require("slang/peg")
local fmt = require("slang/format")
local str = require("slang/string")
local regex = require("slang/regex")

local wgsl = {}

// ------------------------------------------------------------ trivia

// blankspace and line comments in one go; block comments nest, so they are
// counted by hand
local plain_trivia = regex.compile(
  "(?:[ \\t\\n\\x0B\\f\\r\\x{85}\\x{200E}\\x{200F}\\x{2028}\\x{2029}]+|//[^\\n\\x0B\\f\\r\\x{85}\\x{2028}\\x{2029}]*)*",
)
local line_comment = regex.compile(
  "//[^\\n\\x0B\\f\\r\\x{85}\\x{2028}\\x{2029}]*",
)

// the position after the /* ... */ at pos, comments of its kind inside
// counted; -1 when it is not closed
local func block_end(buffer, pos){
  local depth = 1
  local i = pos + 2
  for(depth > 0){
    local b = str.byte_at(buffer, i)
    if(b == null){
      return -1
    }
    if(b == '/' and str.byte_at(buffer, i + 1) == '*'){
      depth = depth + 1
      i = i + 2
    } else if(b == '*' and str.byte_at(buffer, i + 1) == '/'){
      depth = depth - 1
      i = i + 2
    } else {
      i = i + 1
    }
  }
  return i
}

// skip(buffer, pos) -> the position after blankspace and comments at pos
local func skip(buffer, pos){
  for(true){
    pos = plain_trivia:match_at(buffer, pos)
    if(str.byte_at(buffer, pos) != '/' or str.byte_at(buffer, pos + 1) != '*'){
      return pos
    }
    local q = block_end(buffer, pos)
    if(q < 0){
      // (not closed: not a comment; the parser fails here)
      return pos
    }
    pos = q
  }
}

// the comments in buffer[start, stop), a stretch skip went over: // to the
// end of its line, and /* ... */, which ends by itself
local func comments(buffer, start, stop){
  local out = {}
  local i = start
  for(i < stop - 1){
    if(str.byte_at(buffer, i) != '/'){
      i = i + 1
    } else if(str.byte_at(buffer, i + 1) == '/'){
      local q = line_comment:match_at(buffer, i)
      append(out, {start: i, stop: q})
      i = q
    } else if(str.byte_at(buffer, i + 1) == '*'){
      local q = block_end(buffer, i)
      append(out, {start: i, stop: q, block: true})
      i = q
    } else {
      i = i + 1
    }
  }
  return out
}

// what WGSL skips between tokens
local trivia = peg.trivia({skip: skip, comments: comments})
wgsl.trivia = trivia

// ------------------------------------------------------------ words

local keywords = {}
for(let local w in values({
  "alias",
  "break",
  "case",
  "const",
  "const_assert",
  "continue",
  "continuing",
  "default",
  "diagnostic",
  "discard",
  "else",
  "enable",
  "false",
  "fn",
  "for",
  "if",
  "let",
  "loop",
  "override",
  "requires",
  "return",
  "struct",
  "switch",
  "true",
  "var",
  "while",
})){
  keywords[w] = true
}
wgsl.keywords = keywords

// the words WGSL keeps for later: not names either
local reserved = {}
for(let local w in values({
  "NULL",
  "Self",
  "abstract",
  "active",
  "alignas",
  "alignof",
  "as",
  "asm",
  "asm_fragment",
  "async",
  "attribute",
  "auto",
  "await",
  "become",
  "cast",
  "catch",
  "class",
  "co_await",
  "co_return",
  "co_yield",
  "coherent",
  "column_major",
  "common",
  "compile",
  "compile_fragment",
  "concept",
  "const_cast",
  "consteval",
  "constexpr",
  "constinit",
  "crate",
  "debugger",
  "decltype",
  "delete",
  "demote",
  "demote_to_helper",
  "do",
  "dynamic_cast",
  "enum",
  "explicit",
  "export",
  "extends",
  "extern",
  "external",
  "fallthrough",
  "filter",
  "final",
  "finally",
  "friend",
  "from",
  "fxgroup",
  "get",
  "goto",
  "groupshared",
  "highp",
  "impl",
  "implements",
  "import",
  "inline",
  "instanceof",
  "interface",
  "layout",
  "lowp",
  "macro",
  "macro_rules",
  "match",
  "mediump",
  "meta",
  "mod",
  "module",
  "move",
  "mut",
  "mutable",
  "namespace",
  "new",
  "nil",
  "noexcept",
  "noinline",
  "nointerpolation",
  "non_coherent",
  "noncoherent",
  "noperspective",
  "null",
  "nullptr",
  "of",
  "operator",
  "package",
  "packoffset",
  "partition",
  "pass",
  "patch",
  "pixelfragment",
  "precise",
  "precision",
  "premerge",
  "priv",
  "protected",
  "pub",
  "public",
  "readonly",
  "ref",
  "regardless",
  "register",
  "reinterpret_cast",
  "require",
  "resource",
  "restrict",
  "self",
  "set",
  "shared",
  "sizeof",
  "smooth",
  "snorm",
  "static",
  "static_assert",
  "static_cast",
  "std",
  "subroutine",
  "super",
  "target",
  "template",
  "this",
  "thread_local",
  "throw",
  "trait",
  "try",
  "type",
  "typedef",
  "typeid",
  "typename",
  "typeof",
  "union",
  "unless",
  "unorm",
  "unsafe",
  "unsized",
  "use",
  "using",
  "varying",
  "virtual",
  "volatile",
  "wgsl",
  "where",
  "with",
  "writeonly",
  "yield",
})){
  reserved[w] = true
}

// the predeclared types and type generators
local types = {}
for(let local w in values({
  "bool",
  "i32",
  "u32",
  "f32",
  "f16",
  "array",
  "atomic",
  "ptr",
  "vec2",
  "vec3",
  "vec4",
  "vec2i",
  "vec3i",
  "vec4i",
  "vec2u",
  "vec3u",
  "vec4u",
  "vec2f",
  "vec3f",
  "vec4f",
  "vec2h",
  "vec3h",
  "vec4h",
  "mat2x2",
  "mat2x3",
  "mat2x4",
  "mat3x2",
  "mat3x3",
  "mat3x4",
  "mat4x2",
  "mat4x3",
  "mat4x4",
  "mat2x2f",
  "mat2x3f",
  "mat2x4f",
  "mat3x2f",
  "mat3x3f",
  "mat3x4f",
  "mat4x2f",
  "mat4x3f",
  "mat4x4f",
  "mat2x2h",
  "mat2x3h",
  "mat2x4h",
  "mat3x2h",
  "mat3x3h",
  "mat3x4h",
  "mat4x2h",
  "mat4x3h",
  "mat4x4h",
  "sampler",
  "sampler_comparison",
  "texture_1d",
  "texture_2d",
  "texture_2d_array",
  "texture_3d",
  "texture_cube",
  "texture_cube_array",
  "texture_multisampled_2d",
  "texture_depth_multisampled_2d",
  "texture_external",
  "texture_storage_1d",
  "texture_storage_2d",
  "texture_storage_2d_array",
  "texture_storage_3d",
  "texture_depth_2d",
  "texture_depth_2d_array",
  "texture_depth_cube",
  "texture_depth_cube_array",
})){
  types[w] = true
}
wgsl.types = types

// the predeclared enumerants: address spaces, access modes, texel formats
local enumerants = {}
for(let local w in values({
  "function",
  "private",
  "workgroup",
  "uniform",
  "storage",
  "handle",
  "read",
  "write",
  "read_write",
  "rgba8unorm",
  "rgba8snorm",
  "rgba8uint",
  "rgba8sint",
  "rgba16unorm",
  "rgba16snorm",
  "rgba16uint",
  "rgba16sint",
  "rgba16float",
  "rg8unorm",
  "rg8snorm",
  "rg8uint",
  "rg8sint",
  "rg16unorm",
  "rg16snorm",
  "rg16uint",
  "rg16sint",
  "rg16float",
  "r32uint",
  "r32sint",
  "r32float",
  "rg32uint",
  "rg32sint",
  "rg32float",
  "rgba32uint",
  "rgba32sint",
  "rgba32float",
  "bgra8unorm",
  "r8unorm",
  "r8snorm",
  "r8uint",
  "r8sint",
  "r16unorm",
  "r16snorm",
  "r16uint",
  "r16sint",
  "r16float",
  "rgb10a2unorm",
  "rgb10a2uint",
  "rg11b10ufloat",
})){
  enumerants[w] = true
}

// the built-in functions
local builtins = {}
for(let local w in values({
  "bitcast",
  "all",
  "any",
  "select",
  "arrayLength",
  "abs",
  "acos",
  "acosh",
  "asin",
  "asinh",
  "atan",
  "atanh",
  "atan2",
  "ceil",
  "clamp",
  "cos",
  "cosh",
  "countLeadingZeros",
  "countOneBits",
  "countTrailingZeros",
  "cross",
  "degrees",
  "determinant",
  "distance",
  "dot",
  "dot4U8Packed",
  "dot4I8Packed",
  "exp",
  "exp2",
  "extractBits",
  "faceForward",
  "firstLeadingBit",
  "firstTrailingBit",
  "floor",
  "fma",
  "fract",
  "frexp",
  "insertBits",
  "inverseSqrt",
  "ldexp",
  "length",
  "log",
  "log2",
  "max",
  "min",
  "mix",
  "modf",
  "normalize",
  "pow",
  "quantizeToF16",
  "radians",
  "reflect",
  "refract",
  "reverseBits",
  "round",
  "saturate",
  "sign",
  "sin",
  "sinh",
  "smoothstep",
  "sqrt",
  "step",
  "tan",
  "tanh",
  "transpose",
  "trunc",
  "dpdx",
  "dpdxCoarse",
  "dpdxFine",
  "dpdy",
  "dpdyCoarse",
  "dpdyFine",
  "fwidth",
  "fwidthCoarse",
  "fwidthFine",
  "textureDimensions",
  "textureGather",
  "textureGatherCompare",
  "textureLoad",
  "textureNumLayers",
  "textureNumLevels",
  "textureNumSamples",
  "textureSample",
  "textureSampleBias",
  "textureSampleCompare",
  "textureSampleCompareLevel",
  "textureSampleGrad",
  "textureSampleLevel",
  "textureSampleBaseClampToEdge",
  "textureStore",
  "atomicLoad",
  "atomicStore",
  "atomicAdd",
  "atomicSub",
  "atomicMax",
  "atomicMin",
  "atomicAnd",
  "atomicOr",
  "atomicXor",
  "atomicExchange",
  "atomicCompareExchangeWeak",
  "pack4x8snorm",
  "pack4x8unorm",
  "pack4xI8",
  "pack4xU8",
  "pack4xI8Clamp",
  "pack4xU8Clamp",
  "pack2x16snorm",
  "pack2x16unorm",
  "pack2x16float",
  "unpack4x8snorm",
  "unpack4x8unorm",
  "unpack4xI8",
  "unpack4xU8",
  "unpack2x16snorm",
  "unpack2x16unorm",
  "unpack2x16float",
  "storageBarrier",
  "workgroupBarrier",
  "textureBarrier",
  "workgroupUniformLoad",
  "subgroupAdd",
  "subgroupAll",
  "subgroupAnd",
  "subgroupAny",
  "subgroupBallot",
  "subgroupBroadcast",
  "subgroupBroadcastFirst",
  "subgroupElect",
  "subgroupMax",
  "subgroupMin",
  "subgroupMul",
  "subgroupOr",
  "subgroupShuffle",
  "subgroupXor",
  "quadBroadcast",
  "quadSwapDiagonal",
  "quadSwapX",
  "quadSwapY",
})){
  builtins[w] = true
}

// ------------------------------------------------------------ tokens

// a character a name goes on with
local word_char = peg.regex("\\p{XID_Continue}")

// a literal token: a keyword (a word not followed by a word character) or
// punctuation
local func tok(s, category){
  local p = peg.string(s, concat("expected ", s))
  if(keywords[s] == true or category == "keyword"){
    p = peg.seq(p, word_char:forbid()):pick(0)
    category = category or "keyword"
  }
  return p:token(category or "punctuation"):trim(trivia)
}

// tok with the formatter's gaps around it
local func ftok(s, before, after, category){
  return fmt.gaps(tok(s, category), before, after)
}

// an identifier, as the specification spells it: not `_` alone, not two `_`
// in front, not a keyword
local name_re = regex.compile(
  "(?:[_\\p{XID_Start}][\\p{XID_Continue}]+|[\\p{XID_Start}])",
)
local name_chars = peg.regex(name_re, "expected a name"):where(func(w){
  return keywords[w] != true and not str.starts_with(w, "__")
}, "expected a name"):where(func(w){
  return reserved[w] != true
}, "a reserved word of WGSL cannot be a name")

// a name highlighted as category: a string, or a function of the name
local func name(category){
  return name_chars:token(category):trim(trivia)
}

// what a name is where a type stands, where a value does, and where it is
// called
local func type_category(w){
  if(types[w]){
    return "type.defaultLibrary"
  }
  if(enumerants[w]){
    return "enumMember"
  }
  return "type"
}
local func value_category(w){
  if(types[w]){
    return "type.defaultLibrary"
  }
  if(enumerants[w]){
    return "enumMember"
  }
  return "variable"
}
local func call_category(w){
  if(types[w]){
    return "type.defaultLibrary"
  }
  if(builtins[w]){
    return "function.defaultLibrary"
  }
  return "function"
}

// numbers, as the specification spells them: hex and decimal floats, then
// hex and decimal ints, with their suffixes (and li, lu, lf: the 64-bit
// numbers of wgpu's compiler, an extension of it)
local number_re = regex.compile(str.join({
  "0[xX][0-9a-fA-F]*\\.[0-9a-fA-F]+(?:[pP][+-]?[0-9]+(?:lf|[fh])?)?",
  "0[xX][0-9a-fA-F]+\\.[0-9a-fA-F]*(?:[pP][+-]?[0-9]+(?:lf|[fh])?)?",
  "0[xX][0-9a-fA-F]+[pP][+-]?[0-9]+(?:lf|[fh])?",
  "0[xX][0-9a-fA-F]+(?:l[iu]|[iu])?",
  "[0-9]*\\.[0-9]+(?:[eE][+-]?[0-9]+)?(?:lf|[fh])?",
  "[0-9]+\\.[0-9]*(?:[eE][+-]?[0-9]+)?(?:lf|[fh])?",
  "[0-9]+[eE][+-]?[0-9]+(?:lf|[fh])?",
  "0(?:lf|[fh])",
  "[1-9][0-9]*(?:lf|[fh])",
  "0(?:l[iu]|[iu])?",
  "[1-9][0-9]*(?:l[iu]|[iu])?",
}, "|"))
local number_chars = peg.seq(
  peg.regex(number_re, "expected an expression"),
  word_char:forbid("a number runs into a name"),
):pick(0)
local number = number_chars:token("number"):trim(trivia):map(func(t){
  return {k: "num", text: t.value, line: t.line}
})

// ------------------------------------------------------------ template lists
//
// `<` and `>` are template brackets or operators, and only the text around
// them says which. The specification settles it before parsing, with its
// template list discovery: a `<` after a name may start a list, and a `>`
// at the same depth of ( and [ ends the most recent one; `;`, `{`, `:` and
// an assignment's `=` give up every open candidate, `&&` and `||` those of
// their depth. The same scan runs here from where a statement starts (the
// candidates are all given up there) and only as far as a question about a
// `<` or a `>` needs it: starts and ends are the positions it found.

// the scan's state for the text a context parses (kept with the
// context's memos, under the id of [statement_start])
local templates_id = null
local func templates_of(ctx){
  local st = ctx.memo[templates_id]
  if(st == null){
    st = {origin: -1, pos: -1, depth: 0, pending: {}, starts: {}, ends: {}}
    ctx.memo[templates_id] = st
  }
  return st
}

// the scan starts over at pos, a place where no candidate is open, unless
// it has been there already
local func restart(st, pos){
  if(st.origin < 0 or pos < st.origin or pos >= st.pos){
    if(st.origin < 0 or pos < st.origin){
      st.origin = pos
    }
    st.pos = pos
    st.depth = 0
    st.pending = {}
  }
}

local func give_up_from(st, depth){
  local pending = st.pending
  for(len(pending) > 0 and pending[len(pending) - 1].depth >= depth){
    remove(pending, len(pending) - 1)
  }
}

// a `<` at pos after a name: a candidate, unless it is `<<` or `<=`
local func candidate(st, buffer, pos){
  local next = str.byte_at(buffer, pos + 1)
  if(next == '<' or next == '='){
    st.pos = pos + 2
    return
  }
  append(st.pending, {position: pos, depth: st.depth})
  st.pos = pos + 1
}

// one step of the discovery; false at the end of the text
local func scan_step(st, buffer){
  local pos = skip(buffer, st.pos)
  local b = str.byte_at(buffer, pos)
  if(b == null){
    st.pos = pos
    return false
  }
  if(b >= '0' and b <= '9' or
    (b == '.' and number_re:match_at(buffer, pos) > pos)){
    local q = number_re:match_at(buffer, pos)
    if(q <= pos){
      q = pos + 1
    }
    st.pos = q
    return true
  }
  local q = name_re:match_at(buffer, pos)
  if(q > pos){
    q = skip(buffer, q)
    if(str.byte_at(buffer, q) == '<'){
      candidate(st, buffer, q)
    } else {
      st.pos = q
    }
    return true
  }
  local next = str.byte_at(buffer, pos + 1)
  if(b == '>'){
    local pending = st.pending
    local top = pending[len(pending) - 1]
    if(top != null and top.depth == st.depth){
      st.starts[top.position] = true
      st.ends[pos] = true
      remove(pending, len(pending) - 1)
      st.pos = pos + 1
    } else if(next == '='){
      st.pos = pos + 2
    } else {
      st.pos = pos + 1
    }
  } else if(b == '(' or b == '['){
    st.depth = st.depth + 1
    st.pos = pos + 1
  } else if(b == ')' or b == ']'){
    give_up_from(st, st.depth)
    if(st.depth > 0){
      st.depth = st.depth - 1
    }
    st.pos = pos + 1
  } else if(b == '!'){
    st.pos = pos + 1
    if(next == '='){
      st.pos = pos + 2
    }
  } else if(b == '='){
    if(next == '='){
      st.pos = pos + 2
    } else {
      // an assignment: no expression goes on across it
      st.depth = 0
      st.pending = {}
      st.pos = pos + 1
    }
  } else if(b == ';' or b == '{' or b == ':'){
    st.depth = 0
    st.pending = {}
    st.pos = pos + 1
  } else if((b == '&' and next == '&') or (b == '|' and next == '|')){
    give_up_from(st, st.depth)
    st.pos = pos + 2
  } else {
    st.pos = pos + 1
  }
  return true
}

local func is_pending(st, pos){
  for(let local c in values(st.pending)){
    if(c.position == pos){
      return true
    }
  }
  return false
}

// whether the `<` at pos starts a template list
local func starts_template(ctx, pos){
  local st = templates_of(ctx)
  if(st.origin < 0 or pos < st.origin){
    // asked without a statement's start before it: the scan starts here
    restart(st, pos)
    candidate(st, ctx.buffer, pos)
  }
  for(st.pos <= pos or is_pending(st, pos)){
    if(not scan_step(st, ctx.buffer)){
      break
    }
  }
  return st.starts[pos] == true
}

// whether the `>` at pos ends one
local func ends_template(ctx, pos){
  local st = templates_of(ctx)
  if(st.origin < 0 or pos < st.origin){
    return false
  }
  for(st.pos <= pos){
    if(not scan_step(st, ctx.buffer)){
      break
    }
  }
  return st.ends[pos] == true
}

// where a declaration or a statement starts: matches nothing, and tells
// the scan that no candidate is open here
local statement_start = peg.custom(func(self, ctx, pos){
  restart(templates_of(ctx), skip(ctx.buffer, pos))
  ctx.value = null
  return pos
})
templates_id = statement_start.id

// < and > as template brackets
local template_open = fmt.gaps(peg.custom(func(self, ctx, pos){
  if(str.byte_at(ctx.buffer, pos) != '<' or not starts_template(ctx, pos)){
    return peg.fail(ctx, pos, "expected <")
  }
  ctx.value = "<"
  return pos + 1
}):token("punctuation"):trim(trivia), "none", "none")
local template_close = fmt.gaps(peg.custom(func(self, ctx, pos){
  if(str.byte_at(ctx.buffer, pos) != '>' or not ends_template(ctx, pos)){
    return peg.fail(ctx, pos, "expected >")
  }
  ctx.value = ">"
  return pos + 1
}):token("punctuation"):trim(trivia), "none")

// an operator: s not followed by any character of not_next (< is not the
// start of <=), and not a template bracket where it starts with one
local func op(s, not_next){
  local first = str.byte_at(s, 0)
  local n = len(s)
  local p = peg.custom(func(self, ctx, pos){
    local buffer = ctx.buffer
    if(not str.starts_with(buffer, s, pos)){
      return peg.fail(ctx, pos, concat("expected ", s))
    }
    if(not_next != null and pos + n < len(buffer)){
      local after = str.substring(buffer, pos + n, pos + n + 1)
      if(str.contains(not_next, after)){
        return peg.fail(ctx, pos, concat("expected ", s))
      }
    }
    if(first == '<' and starts_template(ctx, pos)){
      return peg.fail(ctx, pos, concat("expected ", s))
    }
    if(first == '>' and ends_template(ctx, pos)){
      return peg.fail(ctx, pos, concat("expected ", s))
    }
    ctx.value = s
    return pos + n
  })
  return p:token("operator"):trim(trivia)
}

// ------------------------------------------------------------ expressions

local expr = peg.settable(null)
local type_spec = peg.settable(null)

// the elements of a separated list (its value has the separators too)
local func elements(sep_list){
  return sep_list.elements
}

// a comma-separated list between two brackets, laid out as a call's
// arguments are: on one line when it fits, else one element a line
// [inside]: the gap inside the brackets when it is one line: "softline"
//   (nothing: a call's) by default, "line" for a space (a struct's braces)
local func list_of(open, element, close, marks, inside){
  inside = inside or "softline"
  return fmt.mark(
    peg.seq(
      open,
      fmt.indent(fmt.mark(element:star_separated(ftok(",", "none", "line")), {
        fill: true,
      }):map(elements), inside),
      fmt.trailing_comma(tok(","):optional()),
      fmt.gaps(close, inside),
    ),
    marks,
  ):pick(1)
}

// a template argument: a type where only a type or a name stands (the
// usual case: vec2<f32>, var<storage, read_write>), else an expression
local template_arg = peg.choice(
  peg.seq(type_spec, peg.choice(tok(","), template_close):and()):pick(0),
  expr,
)
local template_list = list_of(template_open, template_arg, template_close, {
  group: true,
  before: "none",
})

// name<args>: a type, or what an expression names
local func elaborated(category){
  return peg.seq(name(category), template_list:optional()):map(func(v){
    return {
      k: "name", name: v[0].value, args: v[1], line: v[0].line, token: v[0]
    }
  })
}
type_spec:set(elaborated(type_category))
wgsl.type = type_spec

local args = list_of(tok("("), expr, tok(")"), {
  group: true,
  hug: true,
  huggable: "call",
  before: "none",
})

local func bin(l, o, r){
  return {k: "bin", op: o.value, l: l, r: r, line: o.line}
}
local func un(o, e){
  return {k: "un", op: o.value, e: e, line: o.line}
}

local w = peg.walker(trivia.skip_at)
w:primary(number, "number")
w:primary(peg.choice(tok("true"), tok("false")):map(func(t){
  return {k: "bool", value: t.value == "true", line: t.line}
}), "bool")
// a call (of a function, or of a type to make a value of it), else a name
w:primary(peg.seq(elaborated(call_category), args):map(func(v){
  return {k: "call", callee: v[0], args: v[1], line: v[0].line}
}), "call")
w:primary(elaborated(value_category), "name")

w:level("bracket")
w:wrapper(tok("("), tok(")"), "bracket", func(left, value, right){
  return {k: "paren", e: value, line: left.line}
})

w:level("postfix")
w:postfix(
  peg.seq(ftok("[", "none", "none"), expr, ftok("]", "none")),
  "postfix",
  func(left, v){
    return {k: "index", e: left, index: v[1], line: v[0].line}
  },
)
w:postfix(
  peg.seq(ftok(".", "none", "none"), name("property")),
  "postfix",
  func(left, v){
    return {k: "member", e: left, name: v[1].value, line: v[0].line}
  },
)

w:level("unary")
w:prefix(fmt.gaps(peg.choice(
  op("!", "="),
  op("&", "&="),
  op("*", "="),
  op("-", "-="),
  op("~"),
), null, "none"), "unary", un)
w:level("multiply")
w:left(peg.choice(op("*", "="), op("/", "="), op("%", "=")), "multiply", bin)
w:level("add")
w:left(peg.choice(op("+", "+="), op("-", "-=>")), "add", bin)
w:level("shift")
w:left(peg.choice(op("<<", "="), op(">>", "=")), "shift", bin)
w:level("compare")
w:left(peg.choice(
  op("<="),
  op(">="),
  op("!="),
  op("=="),
  op("<", "<="),
  op(">", ">="),
), "compare", bin)
w:level("bitAnd")
w:left(op("&", "&="), "bitAnd", bin)
w:level("bitXor")
w:left(op("^", "="), "bitXor", bin)
w:level("bitOr")
w:left(op("|", "|="), "bitOr", bin)
w:level("and")
w:left(op("&&"), "and", bin)
w:level("or")
w:left(op("||"), "or", bin)

expr:set(w:build())
wgsl.expr = expr

// ------------------------------------------------------------ attributes

// @name or @name(arguments). The arguments of builtin, interpolate and
// diagnostic are names of their own kind (position, flat, off); the others
// take expressions.
local attribute = peg.seq(ftok("@", null, "none", "decorator"),
// (any word: @diagnostic and @const are keywords elsewhere)
peg.regex(name_re, "expected an attribute's name"):token("decorator"):trim(trivia), list_of(tok("("), peg.choice(peg.seq(peg.seq(name("enumMember"), peg.seq(ftok(".", "none", "none"), name("enumMember")):optional()):map(func(v){
  local text = v[0].value
  if(v[1] != null){
    text = concat(text, ".", v[1][1].value)
  }
  return {k: "name", name: text, line: v[0].line}
}), peg.choice(tok(","), tok(")")):and()):pick(0), expr), tok(")"), {group: true, before: "none"}):optional()):map(func(v){
  return {name: v[1].value, args: v[2] or {}, line: v[0].line}
})

// attributes in front of what they belong to, each followed by a space
local attributes = fmt.gaps(attribute, null, "space"):star()

// ------------------------------------------------------------ statements

local statement = peg.settable(null)

local semicolon = ftok(";", "none")

// name: type, the type left out where WGSL infers it
local typed_name = func(category){
  return peg.seq(
    name(category),
    peg.seq(ftok(":", "none", "space"), type_spec):pick(1):optional(),
  ):map(func(v){
    return {name: v[0].value, type: v[1], line: v[0].line, token: v[0]}
  })
}

local initializer = peg.seq(ftok("=", "space", "space"), expr):pick(1)

// { statements }, one a line; {} when there is nothing between the braces
local func block_of(inner){
  return peg.choice(
    peg.seq(ftok("{", "space"), ftok("}", "none")):map(func(v){
      return {}
    }),
    peg.seq(
      ftok("{", "space"),
      fmt.indent(inner, "hardline", "hardline"),
      fmt.gaps(tok("}"), "hardline"),
    ):pick(1),
  )
}
local statements = fmt.mark(statement, {before: "hardline", blank: true}):star()
local compound = peg.seq(attributes, block_of(statements)):map(func(v){
  return {k: "block", attributes: v[0], body: v[1]}
})

// var<space, access> name: type = value;  let, const likewise
local func variable(category){
  return peg.seq(
    tok("var"),
    template_list:optional(),
    fmt.gaps(typed_name(category), "space"),
    initializer:optional(),
  ):map(func(v){
    return {
      k: "var", template: v[1] or {}, name: v[2].name, type: v[2].type,
      init: v[3], line: v[0].line, token: v[2].token
    }
  })
}
local func value_decl(word, category){
  return peg.seq(
    ftok(word, null, "space"),
    typed_name(category),
    initializer:optional(),
  ):map(func(v){
    return {
      k: word, name: v[1].name, type: v[1].type, init: v[2], line: v[0].line,
      token: v[1].token
    }
  })
}

// target = value, target += value, target++, or a call
local assign_op = peg.choice(
  op("<<="),
  op(">>="),
  op("%="),
  op("&="),
  op("*="),
  op("+="),
  op("-="),
  op("/="),
  op("^="),
  op("|="),
  op("=", "="),
)
local updating = peg.choice(
  peg.seq(tok("_"), fmt.gaps(op("=", "="), "space", "space"), expr):map(func(v){
    return {k: "assign", op: "=", target: null, value: v[2], line: v[0].line}
  }),
  peg.seq(
    expr,
    peg.choice(
      peg.seq(fmt.gaps(assign_op, "space", "space"), expr),
      fmt.gaps(peg.choice(op("++"), op("--")), "none"):map(func(o){
        return {o}
      }),
    ):optional(),
  )
    :map(func(v){
      if(v[1] == null){
        return {k: "expr", e: v[0], line: v[0].line}
      }
      return {
        k: "assign", op: v[1][0].value, target: v[0], value: v[1][1],
        line: v[0].line
      }
    }),
)

local simple = peg.choice(
  variable("variable.declaration"),
  value_decl("let", "variable.declaration"),
  value_decl("const", "variable.declaration"),
  updating,
)

local if_stat = peg.seq(
  attributes,
  ftok("if", null, "space"),
  expr,
  fmt.gaps(compound, "space"),
  peg.seq(
    ftok("else", "space", "space"),
    ftok("if", null, "space"),
    expr,
    fmt.gaps(compound, "space"),
  ):star(),
  peg.seq(ftok("else", "space", "space"), compound):pick(1):optional(),
)
  :map(func(v){
    return {
      k: "if", cond: v[2], body: v[3], others: v[4], other: v[5],
      line: v[1].line
    }
  })

local case_clause = peg.seq(peg.choice(peg.seq(
  ftok("case", null, "space"),
  peg.choice(tok("default"), expr):plus_separated(ftok(",", "none", "space")),
  tok(","):optional(),
), tok("default")), ftok(":", "none"):optional(), fmt.gaps(compound, "space"))
local switch_stat = peg.seq(
  attributes,
  ftok("switch", null, "space"),
  expr,
  fmt.gaps(attributes, "space"),
  block_of(fmt.mark(case_clause, {before: "hardline", blank: true}):star()),
):map(func(v){
  return {k: "switch", value: v[2], line: v[1].line}
})

local continuing = peg.seq(
  ftok("continuing", null, "space"),
  attributes,
  block_of(peg.seq(statements, fmt.mark(peg.seq(
    ftok("break", null, "space"),
    ftok("if", null, "space"),
    expr,
    semicolon,
  ), {before: "hardline", blank: true}):optional())),
)
local loop_stat = peg.seq(
  attributes,
  ftok("loop", null, "space"),
  attributes,
  block_of(peg.seq(
    statements,
    fmt.mark(continuing, {before: "hardline", blank: true}):optional(),
  )),
)
  :map(func(v){
    return {k: "loop", line: v[1].line}
  })

local for_stat = peg.seq(
  attributes,
  ftok("for", null, "space"),
  ftok("(", null, "none"),
  simple:optional(),
  ftok(";", "none", "space"),
  expr:optional(),
  ftok(";", "none", "space"),
  updating:optional(),
  ftok(")", "none", "space"),
  compound,
):map(func(v){
  return {k: "for", line: v[1].line}
})

local while_stat = peg.seq(
  attributes,
  ftok("while", null, "space"),
  expr,
  fmt.gaps(compound, "space"),
):map(func(v){
  return {k: "while", line: v[1].line}
})

local func word_stat(word){
  return peg.seq(tok(word), semicolon):map(func(v){
    return {k: word, line: v[0].line}
  })
}

statement:set(peg.seq(statement_start, peg.choice(
  if_stat,
  switch_stat,
  loop_stat,
  for_stat,
  while_stat,
  peg.seq(
    ftok("break", null, "space"),
    ftok("if", null, "space"),
    expr,
    semicolon,
  ):map(func(v){
    return {k: "break_if", line: v[0].line}
  }),
  word_stat("break"),
  word_stat("continue"),
  word_stat("discard"),
  peg.seq(tok("return"), fmt.gaps(expr, "space"):optional(), semicolon)
    :map(func(v){
      return {k: "return", value: v[1], line: v[0].line}
    }),
  peg.seq(ftok("const_assert", null, "space"), expr, semicolon):map(func(v){
    return {k: "const_assert", e: v[1], line: v[0].line}
  }),
  peg.seq(simple, semicolon):pick(0),
  compound,
  tok(";"):map(func(t){
    return {k: "empty", line: t.line}
  }),
)):pick(1))

// ------------------------------------------------------------ declarations

// struct Name { @attr member: type, ... }
local member = peg.seq(
  attributes,
  name("property.declaration"),
  ftok(":", "none", "space"),
  type_spec,
):map(func(v){
  return {attributes: v[0], name: v[1].value, type: v[3], line: v[1].line}
})
local struct_decl = peg.seq(
  ftok("struct", null, "space"),
  name("type.declaration"),
  fmt.gaps(list_of(tok("{"), member, tok("}"), {group: true}, "line"), "space"),
  fmt.drop(tok(";"):optional()),
):map(func(v){
  return {
    k: "struct", name: v[1].value, members: v[2], line: v[0].line, token: v[1]
  }
})

// fn name(@attr param: type, ...) -> @attr type { body }
local param = peg.seq(
  attributes,
  name("parameter"),
  ftok(":", "none", "space"),
  type_spec,
):map(func(v){
  return {attributes: v[0], name: v[1].value, type: v[3], line: v[1].line}
})
local fn_decl = peg.seq(
// the attributes of a function stand on the line before it
peg.choice(peg.seq(
  fmt.gaps(attribute, null, "space"):plus(),
  ftok("fn", "hardline", "space"),
), peg.seq(peg.epsilon({}), ftok("fn", null, "space"))), name("function.declaration"), list_of(tok("("), param, tok(")"), {group: true, before: "none"}), peg.seq(ftok("->", "space", "space"), attributes, type_spec):optional(), fmt.gaps(compound, "space")):map(func(v){
  local ret = null
  local ret_attributes = {}
  if(v[3] != null){
    ret_attributes = v[3][1]
    ret = v[3][2]
  }
  return {
    k: "fn", attributes: v[0][0], name: v[1].value, params: v[2], ret: ret,
    ret_attributes: ret_attributes, body: v[4], line: v[0][1].line, token: v[1]
  }
})

local global_var = peg.seq(
  attributes, variable("variable.declaration"), semicolon
)
  :map(func(v){
    v[1].attributes = v[0]
    return v[1]
  })
local override_decl = peg.seq(
  attributes,
  ftok("override", null, "space", "keyword"),
  typed_name("variable.declaration"),
  initializer:optional(),
  semicolon,
):map(func(v){
  return {
    k: "override", attributes: v[0], name: v[2].name, type: v[2].type,
    init: v[3], line: v[1].line, token: v[2].token
  }
})
local const_decl = peg.seq(
  value_decl("const", "variable.declaration"),
  semicolon,
):pick(0)
local alias_decl = peg.seq(
  ftok("alias", null, "space"),
  name("type.declaration"),
  ftok("=", "space", "space"),
  type_spec,
  semicolon,
):map(func(v){
  return {
    k: "alias", name: v[1].value, type: v[3], line: v[0].line, token: v[1]
  }
})

// enable f16;  requires readonly_and_readwrite_storage_textures;
// diagnostic(off, derivative_uniformity);
local name_list = name("enumMember"):plus_separated(ftok(",", "none", "space"))
local func names_of(v){
  local list = {}
  for(let local t in values(v.elements)){
    append(list, t.value)
  }
  return list
}
local directive = peg.choice(
  peg.seq(
    peg.choice(ftok("enable", null, "space"), ftok("requires", null, "space")),
    name_list,
    tok(","):optional(),
    semicolon,
  ):map(func(v){
    return {
      k: "directive", name: v[0].value, names: names_of(v[1]), line: v[0].line
    }
  }),
  peg.seq(
    tok("diagnostic"),
    ftok("(", "none", "none"),
    name("enumMember"),
    ftok(",", "none", "space"),
    name("enumMember"),
    peg.seq(ftok(".", "none", "none"), name("enumMember")):optional(),
    tok(","):optional(),
    ftok(")", "none"),
    semicolon,
  ):map(func(v){
    return {
      k: "directive", name: "diagnostic", names: {v[2].value, v[4].value},
      line: v[0].line
    }
  }),
)

// one declaration or directive at the top level
wgsl.item = peg.seq(statement_start, peg.choice(
  directive,
  struct_decl,
  fn_decl,
  global_var,
  override_decl,
  const_decl,
  alias_decl,
  peg.seq(ftok("const_assert", null, "space"), expr, semicolon):map(func(v){
    return {k: "const_assert", e: v[1], line: v[0].line}
  }),
  fmt.drop(tok(";")):map(func(t){
    return {k: "empty", line: t.line}
  }),
)):pick(1)

// items, one a line (a blank line between them kept)
wgsl.items = fmt.mark(wgsl.item, {before: "hardline", blank: true}):star()

// ------------------------------------------------------------ tokens of a text

// tokens(buffer: string, start: int, stop: int) -> {{text, line, column}}
// The tokens of the WGSL in buffer[start, stop) without its comments, each
// with the line and column it starts at in buffer: names and numbers
// whole, everything else a character at a time (what stood together stands
// together again when the tokens go back to their columns). Left out are
// the tokens that are only layout, which a formatter adds and drops: a
// comma before a closing bracket, a `;` after a `}`. For gpu/syntax, which
// keeps a program as its tokens and their places.
func wgsl.tokens(buffer, start, stop){
  local out = {}
  local line = 1
  local line_start = 0
  // (the lines before start)
  local nl = str.index_of(buffer, "\n")
  for(nl >= 0 and nl < start){
    line = line + 1
    line_start = nl + 1
    nl = str.index_of(buffer, "\n", nl + 1)
  }
  local pos = start
  for(true){
    local q = skip(buffer, pos)
    for(nl >= 0 and nl < q){
      line = line + 1
      line_start = nl + 1
      nl = str.index_of(buffer, "\n", nl + 1)
    }
    pos = q
    if(pos >= stop){
      break
    }
    local b = str.byte_at(buffer, pos)
    local e = -1
    if((b >= '0' and b <= '9') or b == '.'){
      e = number_re:match_at(buffer, pos)
    }
    if(e <= pos){
      e = name_re:match_at(buffer, pos)
    }
    if(e <= pos){
      e = pos + 1
    }
    local text = str.substring(buffer, pos, e)
    local last = out[len(out) - 1]
    if(last != null and last.text == "," and
      (text == ")" or text == "}" or text == ">" or text == "]")){
      remove(out, len(out) - 1)
    }
    if(not(text == ";" and last != null and last.text == "}")){
      append(out, {text: text, line: line, column: pos - line_start + 1})
    }
    pos = e
  }
  return out
}

// ------------------------------------------------------------ parsing

// parse(source: string, origin?: string) -> {table}
// The declarations of WGSL source text. Raises "origin:line: message"
// (kind compile) when it does not parse.
func wgsl.parse(source, origin){
  origin = origin or "wgsl"
  local r = peg.run(
    peg.seq(trivia:optional(), wgsl.items):pick(1):end(),
    source,
  )
  if(not r.ok){
    local line = r.far_line or r.line
    local msg = r.far_message or r.message or "syntax error"
    raise(error.new(
      error.kinds.compile,
      concat(origin, ":", string(line), ": ", msg),
      {origin: origin, line: line},
    ))
  }
  return r.value
}

return wgsl
