# Highlighting examples

Files to open in VS Code with the slang extension installed (`make vscode`,
`code --install-extension editors/vscode/slang-lang-0.1.0.vsix`): each one
loads an extension and shows the categories it tags its syntax with.

- `core.slang`: every core category (keyword, identifier, number, string,
  comment, operator, punctuation).
- `enum.slang`: `enum` names as `enum.declaration`, members as
  `enumMember.declaration`.
- `macros.slang`: `$` as `macro`, macro names as `function.declaration`.
- `operators.slang`: user-defined operators as `operator`.
- `async.slang`: `async` and `await` as keywords.
- `broken.slang`: a parse error with a diagnostic.

`bin/slang highlight examples/highlighting/enum.slang` prints the same
tokens as JSON; all files except `broken.slang` run with `bin/slang run`.
