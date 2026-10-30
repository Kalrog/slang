// Generates syntaxes/slang.tmLanguage.json: a TextMate grammar for the core
// language, with the keyword list taken from the real grammar so it cannot
// drift. Run from the repository root:
//     bin/slang run editors/vscode/gen_grammar.slang > editors/vscode/syntaxes/slang.tmLanguage.json
local compiler = require("slang/compiler")
local json = require("slang/json")
local str = require("slang/string")

local g = compiler.grammar()
local control = {
  ["if"]: true, ["else"]: true, ["for"]: true, ["return"]: true,
  ["break"]: true, ["let"]: true, ["in"]: true,
}
local storage = {
  ["local"]: true, ["func"]: true, ["extension"]: true, ["global"]: true,
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
          name: "string.quoted.triple.slang", begin: "\"\"\"", ["end"]: "\"\"\"",
        },
        {
          name: "string.quoted.double.slang",
          begin: "\"",
          ["end"]: "\"",
          patterns: json.array({
            {name: "constant.character.escape.slang", match: "\\\\."},
          }),
        },
      }),
    },
    numbers: {
      patterns: json.array({
        {name: "constant.numeric.slang", match: "\\b[0-9]+(\\.[0-9]+)?\\b"},
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
        {
          name: "keyword.other.slang",
          match: concat("\\b(", words(other), ")\\b"),
        },
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

print(json.encode(grammar, {indent: "  "}), "\n")
