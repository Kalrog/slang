// Generates syntaxes/slang.tmLanguage.json: a TextMate grammar for the core
// language, with the keyword list taken from the real grammar so it cannot
// drift. try, catch and defer are not reserved words (the grammar matches
// them only where those statements start), so they are named here. Run from
// the repository root:
//     bin/slang run editors/vscode/gen_grammar.slang > editors/vscode/syntaxes/slang.tmLanguage.json
local compiler = require("slang/compiler")
local json = require("slang/json")
local str = require("slang/string")

local g = compiler.grammar()
local control = {
  ["if"]: true,
  ["else"]: true,
  ["for"]: true,
  ["return"]: true,
  ["break"]: true,
  ["continue"]: true,
  ["let"]: true,
  ["in"]: true,
  ["try"]: true,
  ["catch"]: true,
  ["defer"]: true,
}
local storage = {
  ["local"]: true,
  ["func"]: true,
  ["extension"]: true,
  ["global"]: true,
}
local constants = {["true"]: true, ["false"]: true, ["null"]: true}

local func words(set){
  local out = {}
  for(let local e in entries(set)){
    append(out, e[0])
  }
  return str.join(out, "|")
}

local other = {}
for(let local e in entries(g.keywords)){
  local w = e[0]
  if(control[w] == null and storage[w] == null and constants[w] == null){
    other[w] = true
  }
}
other["in"] = null

// keywords the grammar reserves beyond the classes above (none today)
local other_pattern = null
if(len(words(other)) > 0){
  other_pattern = {
    name: "keyword.other.slang",
    match: concat("\\b(", words(other), ")\\b"),
  }
}

local grammar = {
  ["$schema"]: "https://raw.githubusercontent.com/martinring/tmlanguage/master/tmlanguage.json",
  name: "slang",
  scopeName: "source.slang",
  patterns: json.array({
    {include: "#comments"},
    {include: "#strings"},
    {include: "#numbers"},
    {include: "#quotes"},
    {include: "#keywords"},
    {include: "#functions"},
    {include: "#operators"},
    {include: "#punctuation"},
    {include: "#identifiers"},
  }),
  repository: {
    comments: {
      patterns: json.array({
        {name: "comment.line.double-slash.slang", match: "//.*$"},
      }),
    },
    strings: {
      patterns: json.array({
        {
          name: "string.quoted.triple.slang",
          begin: "\"\"\"",
          ["end"]: "\"\"\"",
        },
        {
          name: "string.quoted.double.slang",
          begin: "\"",
          ["end"]: "\"",
          patterns: json.array({
            // \n, \xHH, \u{H...}
            {
              name: "constant.character.escape.slang",
              match: "\\\\(x[0-9a-fA-F]{2}|u\\{[0-9a-fA-F]+\\}|.)",
            },
          }),
        },
      }),
    },
    numbers: {
      patterns: json.array({
        // 0x1F, 0o17, 0b101, 1_000, 2.5e-3
        {
          name: "constant.numeric.slang",
          match: concat(
            "\\b(0[xX][0-9a-fA-F](_?[0-9a-fA-F])*|0[oO][0-7](_?[0-7])*",
            "|0[bB][01](_?[01])*",
            "|[0-9](_?[0-9])*(\\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?)\\b",
          ),
        },
      }),
    },
    quotes: {
      patterns: json.array({
        {name: "keyword.operator.quote.slang", match: "[+-]\\{"},
      }),
    },
    keywords: {
      patterns: json.array({
        {
          name: "keyword.control.slang",
          match: concat("\\b(", words(control), ")\\b"),
        },
        {
          name: "storage.type.slang",
          match: concat("\\b(", words(storage), ")\\b"),
        },
        {
          name: "constant.language.slang",
          match: concat("\\b(", words(constants), ")\\b"),
        },
        {name: "keyword.operator.logical.slang", match: "\\b(and|or|not)\\b"},
        // x.@meta and {@meta: m}: the metatable
        {name: "keyword.other.meta.slang", match: "@meta\\b"},
      }),
    },
    functions: {
      patterns: json.array({
        {
          match: "\\b(func)\\s+([A-Za-z_][A-Za-z0-9_.:]*)",
          captures: {
            ["1"]: {name: "storage.type.slang"},
            ["2"]: {name: "entity.name.function.slang"},
          },
        },
        {
          name: "entity.name.function.call.slang",
          match: "\\b[A-Za-z_][A-Za-z0-9_]*(?=\\s*\\()",
        },
      }),
    },
    operators: {
      patterns: json.array({
        {
          name: "keyword.operator.slang",
          match: "<<|>>|<=|>=|==|!=|[-+*/%^<>&|~]",
        },
      }),
    },
    punctuation: {
      patterns: json.array({
        {name: "punctuation.slang", match: "[{}()\\[\\],;:.=]"},
      }),
    },
    identifiers: {
      patterns: json.array({
        {name: "variable.other.slang", match: "\\b[A-Za-z_][A-Za-z0-9_]*\\b"},
      }),
    },
  },
}

if(other_pattern != null){
  append(grammar.repository.keywords.patterns, other_pattern)
}
print(json.encode(grammar, {indent: "  "}), "\n")
