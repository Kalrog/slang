# Names and documentation: slang doc, hover, definitions, references

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done. Planned and built
2026-10-30. Part of Phase 6 (tools) of PLAN_1.0.md.

Goal: documentation of modules from the comments the code already has
(`slang doc`), and a language server that understands names: hover with a
definition's signature and doc comment, go to definition, find references,
also across modules loaded with `require`.

## Decisions

- **Doc comments are plain `//` comments**, no new syntax: the comment
  block directly above a definition (no blank line between) documents it;
  the block that starts a file documents the module; `// ---- title` lines
  are sections; in a comment, lines indented by two or more spaces are code
  samples, the rest prose (`` `code` `` spans render as code). The libraries
  already follow this.
- **One analysis for everything** (`slang/symbols`): the names of a parsed
  file are resolved by codegen itself (an optional recorder in
  `codegen.generate`), so scoping is exactly the compiler's: locals,
  upvalues, shadowing, patterns, and code expanded from extensions. Names an
  extension made up have no place in the source and are left out. A file
  that stops compiling half way keeps the names recorded up to the failure.
  Normal compiles pay one null check per name.
- **Modules are understood through `require`**: a local bound to
  `require("name")` carries the module name; its fields resolve into that
  module's file, found as `require` finds it (`compiler.module_path`: the
  search paths, the project's first, then slang's own library sources).
- **slang's library sources ship with slang**: `make install` copies
  `slang/lib` and `slang/compiler` sources to `<prefix>/lib/slang/src`; the
  VM lists the source directories in `__PACKAGES.librarySources` (a
  checkout's `slang/lib` and `slang/compiler`, an installed slang's `src`).
- **References search the whole project** for globals and module fields:
  every `.slang` file under the project directory (or the workspace) that
  mentions the name is analysed on first need and again when its text
  changes; locals stay within their file.
- An extension's names are found when the AST it builds carries the
  source token of each name: `extensions/html` gives `ui` and `Card` of
  `<ui.Card>` their own tokens (a token covering the whole `ui.Card` would
  make both parts claim it). A name built with no token, or another
  buffer's, is left out.
- A module's API is the table it returns (`return m` of a local, or a table
  literal): its fields, defined by `func m.f`, `m.f = ...` or in the
  literal. A `local func` stays internal. `m.f = f` takes the parameters
  and doc of `f`.

## Pieces

- [x] Recording in codegen: `generate(node, origin, {record})` reports
      `define` (a local or parameter, with its token, value and statement),
      `use` (a name read or assigned, with the definition it resolved to,
      null for a global) and `field` (`o.name`, `o["name"]`, `o:name()`
      read or written). Upvalues remember the local they reach.
- [x] `slang/symbols`: `analyse(block, source, origin)` -> defs (local,
      parameter, global, field; ranges, doc, params, owner, module), refs,
      globals, exports, module doc, sections; `at(index, pos)`,
      `signature(def)`, `doc_above`, `doc_blocks`.
- [x] `compiler.highlight(source, path, {symbols: true})`: the same parse
      gives tokens, diagnostics and symbols (about 20% more time on a
      large file). `compiler.module_path(name)`, `compiler.absolute_path`.
- [x] `slang doc [-o dir] [file|dir...]` (`slang/doc`): a page per module
      (module doc, contents, exports by section with signature and doc) and
      an index; without paths the project in the working directory, else
      slang's library. Files that return no table are left out.
- [x] Language server: `hover` (signature, kind, module, doc as markdown,
      the file when it is another), `definition`, `references` (with or
      without the declaration); `lsp/navigate.slang` keeps the open
      documents' symbols (the last ones that compiled while an edit does
      not) and analyses other files on demand, filtered by the name first
      (references to a library function across this repository: 0.9 s the
      first time, a few ms after). What project code prints while it is
      analysed goes to the log.
- [x] Tests: `test/symbols_test.slang` (scoping, fields and exports,
      require, globals, a file that fails to compile, doc blocks, doc
      pages), `test/lsp_test.slang` (definition, references, hover across
      `test/navigate/main.slang` and `util.slang`).

- [x] Methods (2026-10-30): a value lookup in `lsp/navigate.slang`
      follows what a name holds far enough to find the methods called on
      it: a name is what it was assigned, a call what the function returns
      (into other files, `require` included), `await(f(...))` what the
      Future completes with (an `async.run` body's or a `:then` callback's
      return), a table's methods the fields of its meta's `__index`
      (`{meta: m}` or `x.meta = m`); `__type` names the type in hover
      (`func sqlite.db:run(q, values)`, without self when called with `:`).
      Anything it cannot follow (parameters, values that cannot be told)
      gives nothing rather than a guess. References to a method check each
      use the same way. `slang doc` gives every type a module defines a
      section of its methods.
- [x] Stubs for native code (2026-10-30): `slang/stubs/` holds plain slang
      files that declare and document what has no slang source: the
      globals (`globals.slang`), the VM's modules (`slang/string`,
      `slang/os`, `slang/math`, `slang/encoding`, `slang/time`,
      `slang/thread`) and the C extensions (`sqlite`, `crypto`, `tls`,
      `zlib`, `llhttp`, `uv`), native objects as meta tables with
      `__index` and `__type` and constructors returning `{meta: ...}`, so
      the method lookup works on them too. Never run; found through
      `__PACKAGES.stubSources` (a checkout's `slang/stubs`, an installed
      slang's `<prefix>/lib/slang/stubs`); `compiler.module_path` falls
      back to a stub, built-in globals resolve to the globals stub (unless
      the file itself defines the name). `slang doc` documents them; a
      package's native extension can ship its own stub.
- [x] The project walk skips what `.gitignore` files name (plain names and
      paths).

## Later

- [ ] Fields of fields (`async.fs.read_file`) and modules re-exported as
      fields.
- [ ] A `-> type` doc convention (`// open(path) -> sqlite.db`) where the
      value lookup cannot follow, resolved against known `__type` names.
- [ ] Parameters: a value for them from their callers, or from the doc.
- [ ] A stub for `slang/vm`; `compile` (assigned in slang/compiler) found
      as a global definition.
- [ ] References to a common name analyse many files the first time (5 s
      for `str.index_of` across this repository); an index of the
      project's names kept between requests, or built in the background.
- [ ] Rename (on the same references), document symbols (outline),
      workspace symbols, completion of module fields.
- [ ] Semantic token classes from the same analysis (parameter, function,
      property, global with `defaultLibrary`).
- [ ] Doc pages for a project published with the package registry
      (PLAN_1.0.md phase 4).
