# slang language server

A language server written in slang: highlighting and diagnostics from the
real parser (extensions and dialects are loaded and executed as the
compiler does it), over stdio on the `uv` extension.

```
bin/slang run lsp/main.slang      # speaks LSP on stdin/stdout, logs to stderr
```

`lsp/server.slang` is the logic (`new`, `handle(message)`), tested in
process by `test/lsp_test.slang`; `lsp/main.slang` is the stdio transport.
Supported: `initialize` (semantic tokens, full sync, `positionEncoding`
utf-8 when offered), `didOpen`/`didChange`/`didClose`,
`semanticTokens/full`, `publishDiagnostics`, `hover`, `definition`,
`references`, `documentSymbol` (the outline, grouped by `// ----`
sections), `documentHighlight`, `prepareRename`/`rename` (across the
project; refused for names defined outside it, and for a field when some
of its uses cannot be resolved), `workspace/symbol`, `inlayHint`
(parameter names before literal arguments, or all, per
`initializationOptions.parameterHints`), `completion` (the members of
what `a.b.` holds and the methods after `a:`, the names in scope, the
grammar's keywords, module names in `require("...")`), `signatureHelp`,
properties (the keys of a metatable's `__get` and `__set`, also along its
`__index` chain: hover shows the getter's doc and its declared result as
the property's type, definition goes to the getter, completion lists them
and follows what the getter returns; a bare `// type Name` above a
metatable is the type of the objects it is the meta of; what a name holds
is followed through later assignments too, and the first parameter of a
function in a meta's `__index`, `__get` or `__set` table is an object of
that meta, with the fields the file makes its objects with; doc types
carry on through lists and maps (`x[i]`, `for(let local v in values(x))`,
the entry pattern of `entries(x)`), function types (a call of a
`func(): T` gives a T) and callbacks (a function literal passed where the
callee's doc says `func(req: Request)` gets a Request); a local's or
field's first doc line `name: Type` declares its type, and `type Name =
other.Type` above a table of methods is that type's fields with these
methods),
lint warnings with the parse errors (unused locals, globals no project
file defines, requires of missing modules, computed requires;
`initializationOptions.lint: false` turns them off), `formatting` and
`rangeFormatting` (`slang fmt`'s formatter; a range formats the lines it
touches), hover and definition on a `require` (the module's file, as
`require` finds it, and its doc comment), hover and definition on
extension syntax (the extension that made it: `format.owner_at` on the
lossless tree), `slang.project` support
(keys completed, explained and checked), and two requests of its own:
`slang/expand {uri}` (the file after its extensions ran) and `slang/tests
{uri}` (the `t.group`/`t.test` calls of a test file, nested, with ranges),
`didChangeWatchedFiles` (the grammars are reset),
`shutdown`/`exit`, and a `slang/project` notification with the project's
dialect suffixes. `editors/vscode` is the VS Code client.

Names (`lsp/navigate.slang`) come from `slang/symbols`: codegen resolves
the names of the parsed file as it would compile it and records what each
one is. A field of a local bound to `require("name")` resolves into that
module's file, found as `require` finds it (slang's own library from its
sources). Globals and module fields are looked up across the project: the
`.slang` files under the project directory that mention the name, analysed
on first need and again when their text changes. While a project file is
analysed, what its code prints goes to the log, not to the protocol.
