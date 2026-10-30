# Formatter and parser layers

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done. Decided 2026-10-30.

Goal: `slang fmt`, an opinionated formatter that enforces 80 columns and
breaks lines on its own, for core slang and for syntax that extensions add.
To get there, `slang/peg` learns to produce more than one output from one
parse: a lossless tree of the source, and layers computed from it. The
formatter is one layer; highlighting moves onto another.

## Why not format the AST

The AST is what the code means, not what was written. It has no comments,
blank lines or parentheses, and it can't tell a block argument from
`func(){}` as the last argument. Worst of all, extension syntax is expanded
while parsing: `switch`, `html`, `async` and lambda shorthand turn into
core nodes on the spot. A formatter printing the AST would print the
expansion, and checks like "the AST didn't change" would pass for that
expansion too. The formatter has to work on what was written.

## Layers in slang/peg

### The lossless tree

When asked for (`{tree: true}`), a parse builds a tree of the source
alongside its value. Joining the tree's leaves gives back the source exactly,
every space and comment included.

Building the tree is a separate path through the parsers:
`peg.parse_tree(p, ctx, pos)` next to `p:parse_on(ctx, pos)`. The tree
paths live in one section of `slang/peg`, keyed by parser kind, and read
what they need from the parser objects. A parse without a tree runs exactly
the code it ran before. Checking a flag in every combinator instead cost
about 10% of parse time.

- Every combinator that consumes input contributes to the tree. Its
  lossy behaviour is recorded on the tree node instead of being applied.
- Trivia (whitespace and comments) that `trim` skips becomes trivia leaves.
- `peg.custom` parsers, and anything else without a tree path, become a text
  leaf of the span they consumed. Losslessness doesn't depend on parsers
  cooperating. `peg.custom(parse_on, parse_tree)` takes a tree path of its
  own; rule references use it to get a node named by the rule.
- Rule references and parsers with layer operations create named nodes;
  anonymous `seq`s and `choice`s fold into their parent. The tree is shaped
  like the grammar's rules, like tree-sitter's named nodes.
- The tree is built the way `ctx.value` is: failed alternatives leave
  nothing behind, and memoized rules cache their tree with their value.
- The expression walker has a tree path too (`parse_at_tree`). Each
  operator gets a node whose `p` is the walker entry, with `form` (`prefix`,
  `wrapper`, `postfix`, `left`, `right`) and `level`, and whose kids are the
  operator's and operands' nodes. An engine entry (`nud`, `led`) parses its
  operands itself, so its node is the operator and a leaf for the rest.

### Tags

Each lossy behaviour that peg already has is a tagged transform:

| tag      | does                                 | from                                        |
|----------|--------------------------------------|---------------------------------------------|
| `trivia` | drops whitespace and comments        | `trim`                                      |
| `absent` | `null` for an unmatched optional     | `optional`                                  |
| `select` | keeps only some children             | `pick`, `permute`, `star_separated` elements |
| `wrap`   | the value as a token or its text     | `token`, `flatten`                          |
| `map`    | the default layer's own functions    | `map`, `where` values                       |

### Built-in layers

A layer is the set of tags it applies.

- **`text`**: no tags. The source as a tree, every character kept.
- **`raw`**: `trivia` and `absent`. The parse without whitespace, before any
  transform.
- **`default`**: every tag. What `map`, `pick` and friends produce today.
  For the slang grammar that is the AST.

Nothing changes for code that only uses the default layer: a quick parser
written with peg never sees layers.

### Custom layers

A custom layer starts from one built-in layer and adds its own operations
with `on`. Custom layers can't build on other custom layers: a parent's
`map` would receive values its child had already changed.

Inside `on`, the callback gets the layer's value pipeline, not the parser:
it offers the value combinators (`map`, `pick`, `permute`, `flatten`) and
`mark`, but nothing that consumes input. A layer can't change what the
parser accepts.

- **Transforms** (`map`, `pick`, ...) change the layer's value.
- **Annotations** (`mark`) attach data to the tree node and leave the value
  alone. Formatting and highlighting are almost entirely annotations.

```
local sizes = peg.layer("sizes", "raw")

local pair = peg.seq(peg.string("("), number, peg.string(","), number, peg.string(")"))
  :pick(1)                                   // default layer: as today
  :on(sizes, func(v){                        // only in the sizes layer
    return v:map(func(parts){ return len(parts) })
  })
```

### Evaluation

Layers are computed after the parse, from the tree. Each layer is one pass
over the tree that applies the transforms whose tags it includes, plus its
own. Any number of layers come out of one tree, and none of them can
influence parsing.

```
local r = peg.run(pair, "(1, 2)", {tree: true})
r.value                          // the default layer, computed while parsing
peg.text(r.tree) == "(1, 2)"     // always true
peg.evaluate(r.tree, sizes)      // a custom layer
peg.evaluate(r.tree, "raw")      // a built-in layer
```

The parse itself still produces the default value. The slang grammar needs
it while parsing: `extension` blocks change the grammar for the rest of the
file, `-{...}` runs code, and `:where` checks parsed values. That is slang's
requirement, not peg's.

## The format layer

`slang/format` defines a layer on `text`, the annotations that drive it, and
a Wadler-style document printer: text, `line` (a space or a break), `softline`
(nothing or a break), `hardline`, `group` (fits on the line or breaks), and
`indent`. A group that doesn't fit in 80 columns breaks its lines; inner
groups are tried again on their own.

Annotations sit on the parsers, so syntax and its layout are defined in one
place, in the grammar and in extensions alike. The vocabulary below is a
sketch, settled while annotating the core grammar.

```
local fmt = require("slang/format")

define("table_literal", fmt.group(peg.seq(
  tok("{"),
  fmt.indent(fmt.before("softline",
    rule("field"):star_separated(fmt.after("line", tok(","))))),
  fmt.only_broken(tok(","):optional()),      // trailing comma when broken
  fmt.before("softline", tok("}"))
)):pick(1):map(elements):token():map(build_table))
```

Each `fmt.*` helper is a `mark` in the format layer, as in:

```
func fmt.group(parser){
  return parser:on(fmt.layer, func(v){ return v:mark({group: true}) })
}
```

### Whitespace and comments

- Inside annotated syntax the formatter owns all whitespace: the gaps
  between tokens are what the annotations say, nothing otherwise.
- Comments are trivia leaves. A comment on the line of the token before it
  stays there as a trailing comment. Any other comment leads the next token
  on its own line. A `//` comment always ends its line, so it breaks every
  group it is in.
- Blank lines between statements and fields are kept, at most one in a
  row. Blank lines are dropped right after `{` and before `}`.

### Extensions

- **Not annotated:** the syntax keeps its own line structure, re-indented to
  where it now sits. Core syntax inside it (an `expr`, a `chunk`) is still
  formatted, because those are nodes of core rules. The tree has them
  whatever the extension did with them in its `map`.
- **Annotated:** the extension marks its parsers like the core does, for
  example `switch`:

```
local case_block = peg.seq(
  fmt.before("hardline", g:keyword("case")), g:rule("slang_pattern"), g:token(":"),
  fmt.indent(fmt.before("hardline", g:rule("chunk")))
)

g:statement("switch", peg.seq(
  g:keyword("switch"), g:token("("), g:rule("expr"), g:token(")"), g:token("{"),
  fmt.indent(case_block:star()),
  fmt.before("hardline", g:token("}"))
):map(build_switch))
```

```
switch(color){
  case "red":
    stop()
  case "green":
    go()
}
```

Operators registered through `g:expression()` take the same annotations as
an option: `left(op, level, callback, {fmt: ...})`.

### Layout decisions

- Two-space indent, 80 columns, one statement per line.
- The house style stays: `if(x){`, `func(a, b){`, `{a: 1}`, no `;`.
- Bodies of `if`, `for`, `try` and `func` statements always go on their own
  lines. A function expression whose body is one statement may stay on one
  line when it fits (`list:map(func(x){ return x * 2 })`).
- When arguments, parameters or fields don't fit, they break all at once,
  one per line; tables get a trailing comma when broken.
- A last argument that is a function or a table stays on the call's line
  and breaks inside itself (`describe("x", func(){` ... `})`).
- Method chains of three calls or more break before each `:method`. Binary
  operators break after the operator.
- No break before a call's `(` or a block argument's `{`: the same-line rule
  would change the meaning.
- Long strings are never split; literals keep their spelling (`0xff`,
  `1_000`, escapes, `"""` strings).

### Checks

Every run checks its own output, and refuses to write a file that fails:

1. **Same tokens:** the non-trivia leaves of the output are the input's,
   in order. This is a check on the source, so it covers extension syntax.
   The named exceptions are trailing commas and `;`.
2. **Same AST:** the default layer of the output equals the input's. This
   catches places where whitespace matters, like the same-line rule.
3. **No comment lost:** the comments come out in the same order.

Over the repository, the tests also check that formatting is idempotent
(formatting formatted code changes nothing).

### `slang fmt`

```
slang fmt file.slang dir/...    rewrites files in place
slang fmt --check ...           lists files that would change, exits 1 if any
slang fmt --stdout file.slang   prints the result
```

Files of a compile dialect (a `.json` dialect, say) are skipped. The language
server answers formatting requests with the same function.

## Highlighting on layers

Highlighting becomes a layer on `text`: token categories are annotations,
and `slang highlight` and the language server read them off the tree.
`peg.token(child, category)` and `g:tag` become helpers that `mark`. The
current recording (`ctx.tokens`, with failed alternatives leaving records
that are sorted out afterwards) goes away.

## Phases

### Phase 1: the lossless tree
- [x] Tree nodes in `slang/peg`: every combinator, trivia leaves, text
      leaves for custom parsers, rule names.
- [ ] Folding of anonymous nodes: left for phase 2, where layers need the
      full structure; the format layer can fold when it reads the tree.
- [x] Memoization caches the tree; failed alternatives leave nothing.
- [x] The walker builds its nodes.
- [x] `parse_source(..., {tree: true})` in the grammar, `compiler.tree`.
- [x] Tests: `peg.text(tree) == source` for peg's own tests and for the
      compiler, libraries and extensions (`test/tree_test.slang`). Checked
      once over every `.slang` file in the repository: all 194 that parse
      on their own round-trip, and a tree parse gives the same AST as a
      normal one.
- [x] No slowdown for normal parses (measured against HEAD).

### Phase 2: layers
- [ ] Tags on tree nodes; `text`, `raw`, `default`.
- [ ] `peg.layer(name, base)`, `on(layer, f)`, `mark`, `peg.evaluate`.
- [ ] Tests: the default layer evaluated from the tree equals the value
      the parse produced (peg's tests, and slang files without
      compile-time code).

### Phase 3: the formatter
- [ ] The document printer.
- [ ] `slang/format`: the layer, the annotation helpers, comments and
      blank lines.
- [ ] Annotations on the core grammar and the walker.
- [ ] The three checks; idempotence over the repository.
- [ ] `slang fmt` in the CLI.

### Phase 4: extensions
- [ ] Re-indenting unannotated extension syntax, with core syntax inside it
      formatted.
- [ ] Annotation options on `g:expression()` registrations.
- [ ] `switch` and `enum` annotated as examples; a section for extension
      authors in the docs.

### Phase 5: highlighting
- [ ] The highlight layer; `token` categories and `g:tag` as annotations.
- [ ] `slang highlight` output unchanged for every repository file (JSON
      compared before and after); token recording removed.

### Phase 6: editors
- [ ] Formatting requests in the language server; format on save in VS Code.

## Open questions

- The exact annotation vocabulary, settled while annotating the core
  grammar.
- Whether `slang fmt` may change tokens beyond trailing commas and `;`,
  such as normalising `["name"]: v` to `name: v`.
- Reformatting the repository itself: a separate step once the formatter is
  trusted, in its own commit.
