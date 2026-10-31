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
local input = "(1, 2)"
local r = peg.run(pair, input, {tree: true})
r.value                              // the default layer, computed while parsing
peg.text(r.tree, input) == input     // always true
peg.evaluate(r.tree, sizes, input)   // a custom layer
peg.evaluate(r.tree, "raw", input)   // a built-in layer
peg.marks(node, fmt)                 // the annotations on a node
```

Every node keeps the value its parser produced, so the default layer needs
no work, and a layer on `default` recomputes only the subtrees where it has
operations. `peg.evaluate(tree, "default", input, {replay: true})` computes
the default layer from the tree instead. That is for tests: it runs the
functions of `map` and of the walker again, and some can only run during the
parse (`g:unit_local` in an extension).

`on` doesn't change the parser it is given, so marking a shared parser (a
rule reference, say) marks only that use. Parsers whose state is all in
their closures are copied, so marking them costs nothing when parsing.
Rules, `ref`, `choice`, `dispatch`, settables and custom parsers get a thin
wrapper instead.

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

Whatever an extension registers (statements, extension statements,
primaries, operators, rules it defines or modifies) is formatted when the
extension marks its parsers, and verbatim when it doesn't
(`format.extension`). Marks anywhere inside the registered parser count;
the search stops at rule references, which have their own layout.

- **Not annotated:** the syntax keeps its own line structure, re-indented to
  where it now sits. Text the extension's syntax treats as content (the
  whitespace between html tags, say) stays exactly as written. Core syntax
  inside it (an `expr`, a `chunk`) is still formatted, because those are
  nodes of core rules. The tree has them whatever the extension did with
  them in its `map`. Core code inside verbatim code breaks only where it
  must.
- **Annotated:** the extension marks its parsers like the core does. This is
  `extensions/switch.slang`:

```
local fmt = require("slang/format")

case_block = peg.seq(
  fmt.gaps(g:keyword("case"), "hardline", "space"),
  g:rule("slang_pattern"),
  fmt.gaps(g:token(":"), "none"),
  fmt.indent(g:rule("chunk"), "hardline")
)

switch = peg.seq(
  fmt.gaps(g:keyword("switch"), null, "none"),
  fmt.gaps(g:token("("), "none", "none"),
  g:rule("expr"),
  fmt.gaps(g:token(")"), "none", "none"),
  g:token("{"),
  fmt.indent(case_block:star(), "hardline"),
  fmt.gaps(g:token("}"), "hardline")
)
```

```
switch(color){
  case "red":
    stop()
  case "green":
    go()
}
```

Operators registered through `g:expression()` are placed like the core's
(a space before an infix operator, a possible break after it); marks on the
operator's parser format the operator itself.

### Layout decisions

- Two-space indent, 80 columns, one statement per line.
- The house style stays: `if(x){`, `func(a, b){`, `{a: 1}`, no `;`.
- **The source decides where there are two valid layouts.** A list
  (arguments, parameters, fields, an operator chain) written with every
  element on its own line keeps that layout, unless it all fits on one line,
  which joins it. Any other layout lets the formatter decide.
- A block of one statement written on one line stays on one line when it
  fits (`for(...){ f(i) }`, `func get(){ return x }`); one written over
  several lines keeps them. Blocks next to an `else` or a `catch` always
  break.
- Lists that don't fit are packed as many to a line as fit when their
  typical (median) element is at most 20 columns, with a long element on a
  line of its own; otherwise one per line.
- **A trailing comma stands for one element per line** (2026-10-31, the
  "magic trailing comma" of Black). Tables, call arguments and function
  parameters may end with a comma. Written, it keeps the list one element
  per line, even where it would fit on one line or be packed, and even when
  the list was written on one line (`{a, b,}` breaks). It sticks: remove it
  to join the list. The formatter writes one only when it lays a list out
  one per line, so a packed list gets none. A list kept broken this way
  breaks the groups around it, like a function written over several lines.
- A last argument that is a function or a table stays on the call's line
  and breaks inside itself (`describe("x", func(){` ... `})`); a call as the
  last argument does so only when it is 60 columns or wider. With more than
  one argument that must break, every argument gets a line.
- Method chains of two method calls or more break before each `:method`
  (one call that takes a function counts twice). Binary operators break
  after the operator, packing the operands.
- Operators can carry a style in their marks: `break_before` breaks before
  the operator, `style: "lines"` lays the chain out on one line or one
  operand per line. `|>` (examples/functional/pipe.slang) uses both.
- Because some layouts depend on the source's (a block written on one line
  that doesn't fit becomes a block written over several), `format.source`
  formats again until nothing changes (at most five passes).
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

Highlighting reads the lossless tree (`peg.highlights(tree, buffer,
{trivia})`), so lost alternatives leave nothing behind and there is no
recording to clean up:

- `peg.token(child, category)` gives its span the category. The category
  may be a function of the child's value returning a category or null:
  `html` colours a tag name as a function or a keyword, `sql` only its
  keywords. That replaces the custom parsers that pushed into `ctx.tokens`.
- `peg.tag(child, category)` colours the span of the child's value (a
  token, or a node's token) and wins over the tokens inside it.
- Trivia leaves go to `options.trivia` (`grammar.comments` finds the `//`
  comments); a leaf whose parser has `highlight(buffer, start, stop)` gives
  its own spans.
- A custom parser that parses other parsers itself calls `peg.sub(parser,
  ctx, pos)`: when a tree is built, their trees become part of the custom
  parser's node, so highlighting and formatting see inside it (quote and
  unquote bodies). An engine operator's callback gets a walker whose
  `parse_at` does the same. Normal parses don't pay for this.

`compiler.highlight` parses with `{recover: true}`: a statement that fails
to parse is reported, its lines are coloured by their words (keywords,
identifiers, numbers, strings, comments), and the parse goes on at the next
line where a statement parses. Before, nothing after an error was coloured.

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
- [x] Tags on tree nodes; `text`, `raw`, `default`.
- [x] `peg.layer(name, base)`, `on(layer, f)`, `mark`, `peg.marks`,
      `peg.evaluate`.
- [x] Tests: the default layer evaluated from the tree equals the value
      the parse produced (`test/tree_test.slang`). Checked once over the
      repository: 143 files replay to the same AST. The 11 others use
      extensions that call `g:unit_local`, which only works during the
      parse.

### Phase 3: the formatter
- [x] The document printer (`slang/format`, in `slang/compiler`).
- [x] `slang/format`: the layer, the annotation helpers, comments and
      blank lines.
- [x] Annotations on the core grammar; the walker's operators are laid out
      by the formatter (operator chains, method chains, parentheses).
- [x] The three checks; idempotence over the repository. Every file that
      parses on its own formats with the checks passing, and formatting the
      result again changes nothing (174 files, 40 of them the dungeon's).
      The checks ignore source locations an extension writes into its code
      (`sql` puts `file:line` into queries).
- [x] `slang fmt [--check] [--stdout]` in the CLI.

### Phase 4: extensions
- [x] Re-indenting unannotated extension syntax, with core syntax inside it
      formatted.
- [x] Extensions that mark their parsers are formatted, without opting in.
- [x] `switch` annotated as the example.
- [x] html templates formatted (2026-10-30), with extension layouts:
      `format.layout(parser, fn)` lets an extension lay out its own nodes
      (fn(api, node) -> a document from `format.doc`; `format.role` names
      the parts it finds). Needed where marks cannot say it: whitespace in
      template text means something, so each gap is decided by the
      whitespace the source has there. Words flow at 80 columns; a line
      break next to a child or a tag stays; a space next to a tag, between
      two elements, or anything but single spaces in a run without a line
      break is kept exactly; long tags put one attribute per line. Text is
      parsed as word and whitespace leaves (the value unchanged), tag
      whitespace with `peg.whitespace`, so the token check sees words only;
      the AST check confirms the meaning. The examples' templates are
      formatted with it.
- [ ] Known rough spots: a fixed space between two elements keeps the next
      tag on its line even when its attributes break (`<a/> <button` then
      the attributes); short arguments after a template are packed onto its
      last line (`/>, 401`) by the argument fill.
- [ ] `enum` annotated; a section for extension authors in the docs.

### Phase 5: highlighting
- [x] Highlighting from the tree; `token` categories (also as functions)
      and `g:tag`; `peg.sub` for custom parsers that parse others.
- [x] `slang highlight` output unchanged for every repository file (JSON
      compared before and after), but for `examples/highlighting/broken.slang`,
      which now gets colour after its error; token recording removed.
- [x] Quote and unquote bodies are trees now, so they are formatted; the
      quote syntax has layout marks (`+{stat: x}` on one line when it fits).
- [ ] Highlighting takes about 1.5x as long as with recording (0.64s
      against 0.41s for the largest file, grammar.slang): the tree parse
      is the cost. Worth a look if the language server feels slow. Since
      2026-10-30 the server also analyses names in the same parse (about
      20% more).

### Phase 6: editors
- [x] Formatting requests in the language server; format on save in VS Code
      (2026-10-30): `textDocument/formatting` answers with one edit
      replacing the document with `format.source`'s result (none when it
      is formatted already); a file that does not parse is left alone (its
      diagnostics say why), a failed formatter check on one that parses is
      logged and shown. The VS Code extension makes itself the default
      formatter for slang with `editor.formatOnSave` on (both can be
      overridden in the settings). Range formatting is not offered: a
      range of slang is not a unit the formatter can lay out alone.

## Open questions

- Long argument lists that are mostly short strings (`error("...", x, "...")`)
  break one argument per line, as decided. Packing them ("fill", as Prettier
  does for text) may read better for message-building calls.

- The exact annotation vocabulary, settled while annotating the core
  grammar.
- Whether `slang fmt` may change tokens beyond trailing commas and `;`,
  such as normalising `["name"]: v` to `name: v`.
- Reformatting the repository itself: a separate step once the formatter is
  trusted, in its own commit.
