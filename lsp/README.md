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
`semanticTokens/full`, `publishDiagnostics`, `didChangeWatchedFiles` (the
grammars are reset), `shutdown`/`exit`, and a `slang/project` notification
with the project's dialect suffixes. `editors/vscode` is the VS Code client.
