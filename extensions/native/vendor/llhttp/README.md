# llhttp 9.3.1 (vendored)

The HTTP parser behind the llhttp extension (`extensions/native/llhttp.c`),
compiled into it so that it needs no llhttp installed and links into single
executables (`slang build`).

- Source: https://github.com/nodejs/llhttp, tag `release/v9.3.1` (the
  generated C; the TypeScript it is generated from is on `main`)
- Archive: `llhttp-release-v9.3.1.tar.gz`, SHA-256
  `c14a93f287d3dbd6580d08af968294f8bcc61e1e1e3c34301549d00f3cf09365`
- License: MIT (LICENSE)
- Files: `include/llhttp.h`, `src/api.c`, `src/http.c`, `src/llhttp.c`,
  unchanged

To update, replace these files with those of a newer `release/vX.Y.Z` tag.
