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
lint warnings with the parse errors (unused locals, globals no project
file defines, requires of missing modules, computed requires;
`initializationOptions.lint: false` turns them off), `formatting` and
`rangeFormatting` (`slang fmt`'s formatter; a range formats the lines it
touches),
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
