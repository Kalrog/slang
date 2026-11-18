# Extending the language

Slang's parser is written in slang, and its grammar is a value a program
can change. This page covers the three layers: code as data (quotes and
`compile`), extension statements that change the grammar of a file, and
projects that give all their files, or files of another suffix, a grammar
of their own.

The modules behind it are `slang/compiler`, `slang/grammar`, `slang/peg`
and `slang/ast`. The extensions that come with slang are documented with
live examples in the [library docs](../../doc/), and their sources in
`extensions/` are the best place to learn from.

## Code as data

```slang
local tree = +{expr: 1 + 2}                 // quote: the syntax tree, a table
local stat = +{stat: local x = -{tree}}     // unquote inside a quote splices a value
-{block: return +{stat: print("made while parsing\n")}}   // at the top level: runs while parsing
print(compile("return 1 + 1")(), "\n")      // compile: source or a tree to a function
```

An unquote at the top level runs once, when the parser reaches it, and the
code it returns is spliced in its place. It may compute anything, but it
may not change the grammar.

`compile(code, origin, env)` gives the compiled code its own globals: it
sees only what the table `env` holds, and its global assignments land in
`env`. An env with `@meta: {__index: shared}` reads through to other
values.

```slang
print(compile("return x * 2", "calc", {x: 21})(), "\n")     // 42
print(compile("return require", "calc", {})(), "\n")        // null: not in the env
```

This is a sandbox for names, not for resources: there are no CPU or memory
limits. Since unquotes and extension statements would run with the
compiler's globals, a source compiled with an env may not contain them.

## Extension statements

Grammar changes are made by extension statements, at the top level of a
file (or of a compiled string):

```slang
extension "extensions/switch"     // runs the file at compile time
extension {                       // runs the block at compile time
  local g = require("slang/compiler").grammar()
  g:expression():primary("one", g:keyword("one"):map(func(t){
    return {token: t, ast: +{expr: 1}}
  }))
}
local x = one                     // the change applies from the next statement on
print(x, "\n")
```

- A file is parsed one top-level statement at a time. An extension
  statement takes effect for the statements after it.
- Grammar changes are scoped to the unit, a file or a compiled string.
  They end with it, and a file is always compiled with the root grammar,
  so a module means the same wherever it is required from.
- Keywords an extension introduces are reserved as variable names but
  stay usable as field names (`t.switch`, `t:switch()`, `{switch: 1}`).
- An extension file runs once per unit that loads it: it is a script, not
  a module. One that depends on another loads it with
  `require("slang/compiler").load_extension(name)`. Compile-time state
  that later units must see belongs in a module the extension requires,
  since modules are loaded once.

The extensions of libraries the binary carries are in the binary too:
`extensions/async`, `extensions/html`, `extensions/inline_test`,
`extensions/json` and `extensions/sqlite` load wherever slang runs, in a
package as well. The others in `extensions/` are files of the repository,
found through a project's search paths.

`slang expand file` prints what a file looks like once its extensions are
applied: core slang, with the unquotes executed and the extension
statements gone. Parsing that output gives the same bytecode as the
original. `slang run --explain file` lists, for every unit compiled under
extensions, the extensions in effect and the rules they changed.

## Extensions for a whole project

Global changes are explicit. The usual place for them is the project
file, [`slang.project`](projects.md):

```slang
{
  extensions: {"extensions/custom_operators"},        // ambient: loaded into every unit
  dialects: {
    [".json"]: {compile: "extensions/json"},          // require("config") loads config.json
    [".hx"]: {extensions: {"ext/html_templates"}},    // .hx files are slang plus these extensions
    [".kernel"]: {grammar: "kernel/file"},            // .kernel files are a language of their own
  },
  warnings: {["extensions/custom_operators"]: false},  // or false: grammar warnings off
}
```

A dialect is one of three kinds:

- **A list of extensions**: the file is slang compiled with them.
- **A grammar**: a module returning the language of the files as
  `slang/peg` parsers (`{item, unit}`: one top-level item, and the code
  made of the items). The files are parsed, highlighted, formatted and
  cached as slang files are. See `FileGrammar` in `slang/grammar`, and
  `packages/kernel/file.slang`.
- **A compile function**: a module exporting `compile(source, origin)`
  that returns a function, as `extensions/json.slang` does. Editors and
  `slang fmt` see nothing of such a file.

`extension global "file"` in a program's main file, before its other
extension statements, changes the root grammar for every unit compiled
afterwards. `examples/project` is a small project that uses ambient
extensions and a dialect.

## The grammar API

An extension gets the grammar it extends with
`require("slang/compiler").grammar()`, and builds parsers with the
combinators of `slang/peg` (`seq`, `choice`, `star`, `plus`, `optional`,
`map`, `token`, `ref`, ...). `peg.regex(pattern)` is a parser of what a
regular expression matches (a number, a name), and `peg.trivia({skip,
comments})` what a language of its own skips between tokens, for syntax
whose blanks and comments are not slang's: the highlighter and the
formatter take its comments from it. The grammar object offers:

- `g:token(text)` and `g:keyword(word)` (a keyword is reserved).
  `g:rule(name)` refers to any rule of the grammar: `"expr"`,
  `"statement"`, `"block"`, `"chunk"`, `"identifier"`, `"slang_pattern"`,
  `"table_literal"`, ...
- `g:statement(name, parser)` adds a statement; the parser yields a node
  or `{token, ast}`.
- `g:extension_statement(name, parser, apply)` adds a statement that is
  only recognised at the top level. After it parsed, `apply(result, g)`
  runs with grammar changes allowed and returns the statement to emit, or
  `null`. `extensions/custom_operators.slang` shows it.
- `g:expression()` is the expression registry. `:primary(name, parser,
  {after, before})` adds a primary expression. `:level(name, {after,
  before})` adds a precedence level; core has `indexAndCall`, `power`,
  `unary`, `multiply`, `add`, `compare`, `and`, `or`, tightest first. A
  level takes `:prefix(op, f)`, `:postfix(op, f)`, `:left(op, f)`,
  `:right(op, f)` and `:wrapper(open, close, f)`. `:levels()` and
  `:primaries()` list the names.
- `g:define(name, parser)` adds a rule, and `g:modify(name, func(old){
  ... })` replaces one by a parser built from the current one. The rules
  that make metaprogramming work (quote, unquote and the extension
  statement) are protected. `g:rules()` lists every rule with the
  extensions that changed it.
- `g:walker()` gives an extension an expression walker of its own, for
  DSLs with their own operators.
- `g:derive()` is a copy that changes independently, `g:root()` the root
  grammar, `g:unit()` the grammar of the unit being parsed, and
  `g:extensions()` the extensions loaded into the grammar.
- `g:error_at(token, message...)` raises a compile error at a token,
  `g:origin()` is the name of the source being compiled, `g:unit_id()`
  identifies the parse of the current unit (for per-unit state in an
  extension a project loads once), and `g:uniq_id()` is an identifier no
  program can write.

A pipe operator, whole:

```slang
extension {
  local g = require("slang/compiler").grammar()
  local pipe = g:expression():level("pipe", {after: "or"})
  pipe:left(g:token("|>"), func(left, op, right){
    return +{expr: -{right}(-{left})}
  })
}

local double = func(x) => x * 2
print(5 |> double |> double, "\n")   // 20
```

## Highlighting and formatting

Editors colour a file from the parser's own tokens, so new syntax is
highlighted as soon as it parses. `g:token(source, name, category)` and
`peg.token(child, category)` tag tokens: core uses `keyword`,
`identifier`, `number`, `string`, `comment`, `operator` and
`punctuation`, and an extension may use any standard LSP token type
(`type`, `function`, `enumMember`, `macro`, ...) with modifiers after
dots (`enumMember.declaration`). `g:tag(g:rule("identifier"),
"function.declaration")` recolours what a rule produced without changing
its value. `extensions/enum.slang` shows it, and the files in
`examples/highlighting` are made to be opened in an editor.

## When extensions meet

Changes are sealed lazily: the first parse after a change rebuilds the
expression walker and the dispatch tables once. `SLANG_GRAMMAR_WARNINGS=1`
(or `slang run --explain`) reports rules modified by more than one
extension, modifications that can never match their second alternative,
and rules that stop parsing their probe snippet.

Sealing also places memoization: a rule that leads several alternatives
of one choice is memoized per position for the duration of a top-level
statement, so `choice(seq(old, tail), old)` parses `old` once.
`--explain` lists the placements, and `SLANG_NO_MEMO=1` turns them off.

A wrapper of a rule built at seal time (`expr`, `statement`) runs at seal
time, so create the tokens it uses before calling `modify`.

## How fast it parses

The combinators interpret the grammar. `slang/pegc` compiles a grammar to
slang, one function per rule, which makes parsing 2 to 2.5 times faster.
It happens by itself for the root grammar and for a project's grammars,
at the first parse that asks for the syntax tree (the language server,
the formatter) or once a process has parsed more than 128 KB; a grammar
with extensions is compiled once and cached as bytecode in
`~/.cache/slang`. A unit's own extension statements keep the combinators
for that unit. `SLANG_PEGC=0` turns it off, and `SLANG_PEGC_DEBUG=1`
reports what is generated and why a grammar was not.

## Larger examples

- `extensions/`: a switch statement, a lambda shorthand, custom
  operators, enums, async/await, HTML templates, SQL literals, the JSON
  dialect.
- `examples/functional`: a pipe operator and holes, ambient in a folder.
- `examples/deckhand/dsl`: the map language of a game.
- `packages/kernel` and `packages/dsp`: whole languages inside slang
  files, compiled to machine code.
