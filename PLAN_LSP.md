# Language server and editor support

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done. Planned 2026-10-27.

Goal: syntax highlighting in VS Code that is right for the code as it is
actually parsed, including every extension and dialect the project loads,
by running slang's own parser inside a language server written in slang
(`slang/http` showed that the `uv` binding and `slang/async` carry a
network service; the LSP is the same shape over stdio). A static TextMate
grammar for the core language gives basic colours before the server is up.

This continues Phase 6 of `PLAN_GRAMMAR.md`: token categories exist on every
token the grammar produces (`keyword`, `punctuation`, `operator`,
`identifier`, `number`, `string`, set by `g:token(source, name, category)`
and `peg.token(child, category)`); what is missing is collecting them.

## How highlighting works

1. The editor sends the document. The server finds the `slang.project` for
   the file (the same lookup as `compiler.load_main`), picks the grammar the
   compiler would use (root plus ambient extensions, or the dialect of the
   file suffix) and parses the text with **token recording** on.
2. Recording: `peg.context` gets a `tokens` list; `peg.token` appends
   `{category, start, stop}` on success; the trivia rule records comments.
   Backtracking leaves records of attempts that lost, so the result is
   normalised at the end: sort by start, drop overlaps, later record wins
   (the winning alternative records last; a memo hit reuses the first
   attempt's records, which are the same tokens).
3. Extension code runs for real: `extension` statements and unquotes execute
   while parsing, exactly as in the compiler, so an extension's keywords and
   operators are highlighted because `g:keyword`/`g:token` tag them. This is
   the deliberate trade-off: the server executes project code, so the editor
   extension only starts it in trusted workspaces, and the server is a
   separate process the client restarts if it dies.
4. Parse errors become diagnostics (the farthest failure with its message);
   tokens up to the failure are still returned. Recovery that continues after
   a failed top-level statement comes later.
5. The result is sent as LSP semantic tokens (`textDocument/semanticTokens/full`)
   with a legend mapping categories to standard token types, so any theme
   colours them. Positions are UTF-8 offsets converted to the encoding the
   client negotiated (`positionEncoding`, UTF-16 by default).

Semantic classes beyond the lexer (local, parameter, upvalue, global,
function, property) come from codegen's name resolution and are a second
step: the compiler already resolves every identifier; recording the class
per token position gives them without extension work, since extensions
lower to the core AST. Needs a compile, so it runs under the same trust rule.

## Phases

### Phase 1: token recording in the parser `[ ]`
- [ ] `peg.context(buffer, {record: true})`; `peg.token` records when the
      context records; the trivia rule (comments) records with category
      `comment` (the native `skip_space` fast path is bypassed while
      recording); `peg.tokens(ctx)` returns the normalised list.
- [ ] `compiler.highlight(source, path) -> {tokens, diagnostics, grammar}`:
      project and dialect selection as `load_main`/`load_file` do, scoped
      unit, no bytecode generation, errors caught into diagnostics.
- [ ] `slang highlight file` prints the tokens as JSON (the tool the
      plan in PLAN_GRAMMAR.md names; useful for tests and other editors).
- [ ] Tests: core categories on a sample, an extension's keyword and
      operator, a dialect file, comments, a parse error with partial tokens.

### Phase 2: pieces the server needs `[ ]`
- [ ] `uv.pipe()` with `open(fd)` for stdin/stdout (stream methods shared
      with tcp), so the server speaks LSP over stdio; `uv.tty` is not needed.
- [ ] `slang/json`: decode (moved from `extensions/json`, which keeps the
      dialect wrapper) and encode; `slang/async` gains nothing new.
- [ ] UTF-8 to UTF-16 column conversion in `slang/string` (`utf16_len`) for
      LSP positions, and negotiation of `positionEncoding: "utf-8"` where
      the client offers it (VS Code does).

### Phase 3: the language server `[ ]`
- [ ] `lsp/` (a slang program, started as `bin/slang run lsp/main.slang`):
      Content-Length framing over a uv stream, a request
      dispatcher, a document store with full-text sync, `initialize`
      (semantic tokens full, diagnostics, position encoding), `didOpen`/
      `didChange`/`didClose`, `semanticTokens/full`, `publishDiagnostics`,
      `shutdown`/`exit`.
- [ ] Project handling: one grammar set per `slang.project`, cached, rebuilt
      when the project file or an ambient extension changes
      (`workspace/didChangeWatchedFiles`); a custom notification
      `slang/project` tells the client the dialect suffixes of each project
      so it can associate them with the slang language.
- [ ] The server logic is a pure `handle(message) -> replies` over an
      injectable transport, so tests drive it from slang without a process:
      initialize, open a file with an extension, check the tokens, change the
      file, check diagnostics, change the project, check the grammar reset.
- [ ] Robustness: a parse that raises (an extension bug) yields a diagnostic
      and keeps the server alive; an error outside parsing is logged to
      stderr; a hung parse (an infinite loop in compile-time code) is the
      client's restart to handle until a restricted/limited VM mode exists.

### Phase 4: the VS Code extension `[ ]`
- [ ] `editors/vscode`: language `slang` (`.slang`, the file name
      `slang.project`), language configuration (comments, brackets,
      auto-closing), a TextMate grammar `syntaxes/slang.tmLanguage.json`
      for the core language (keywords, operators, strings, numbers,
      comments, `func`, `extension`, quotes `+{`/`-{`), generated from the
      core grammar's token registry by `slang syntax-export --textmate` so
      the keyword list cannot drift; checked in.
- [ ] The client (`vscode-languageclient`): starts the bundled `lsp/`
      program with the configured `slang.path` (default: `slang` on PATH)
      only when the workspace is trusted; semantic tokens map to standard scopes; the
      `slang/project` notification updates `files.associations` for the
      project's dialect suffixes when `slang.associateDialects` is on (the
      user can also set associations by hand).
- [ ] Build with `npm`/`esbuild`, `vsce package` into a `.vsix`; a manual
      test checklist (core file, a file using `extensions/custom_operators`,
      a `.json` module under `examples/project`, a parse error, server
      restart after a crash).

### Phase 5: later `[ ]`
- [ ] Semantic classes from codegen (locals, parameters, upvalues, globals,
      functions, fields), hover with the resolved kind, go to definition.
- [ ] Error recovery in the phrase loop (skip to the next top-level
      statement after a failure) so one typo does not uncolour the rest of
      the file.
- [ ] Incremental sync and a per-document parse debounce.
- [ ] A restricted VM mode (no `slang/os`, no native extensions, an
      instruction budget) for untrusted workspaces.
- [ ] Other editors: the same server works for Neovim's built-in client; the
      tree-sitter grammar in `tree-sitter-slang` stays the static fallback
      there.

## Decisions
- Highlighting comes from the real parser, not an approximation: the
  server loads the project's extensions and dialects and executes their
  code. Trust is the editor's decision (workspace trust), not the server's.
- The TextMate grammar covers the core language only and is generated from
  the grammar's token registry. Extensions are never approximated
  statically; they colour through the server.
- Dialect suffixes reach the editor from the server (which can read
  `slang.project`, a slang file), not by the editor parsing the project
  file itself.
- One language id (`slang`) for every suffix; the server picks the grammar
  per file from the project, the editor only needs to know which files are
  slang.

## Decided 2026-10-27
- The server is a separate program (`lsp/main.slang`, run as
  `slang run lsp/main.slang`), not a CLI subcommand: libuv stays outside the
  core of slang. The VS Code extension bundles the `lsp/` files and starts
  them with the configured `slang` binary, so nothing else needs configuring;
  the binary finds `lib/uv.dylib` next to itself. Should the separate
  program ever become a real obstacle, moving it into the binary is an
  option left open, not a plan.
- The first milestone is highlighting and diagnostics only (Phases 1 to 4);
  everything under Phase 5 waits.
