# Tools

Everything here is in the one `slang` binary: the runner, the test runner,
the formatter, the doc generator, the package manager, the builder and a
debugger. The language server and the editor plugins are in the
repository.

## The slang command

| command | does |
|---|---|
| `slang run file.slang [args...]` | runs a program; `args()` gives it the arguments |
| `slang repl` | reads statements and expressions and prints what they give |
| `slang test [dir\|file]` | runs every `*test.slang` file in `./test`, a folder, or one file |
| `slang fmt file\|dir...` | formats files in place; `--check` lists the ones that would change |
| `slang doc [-o dir] [file\|dir...]` | writes HTML documentation from doc comments |
| `slang get`, `slang update`, `slang deps` | packages, see [Projects and packages](projects.md) |
| `slang exec name [args...]`, `slang name [args...]` | runs an executable a package offers |
| `slang install [dir\|url]`, `slang uninstall package` | a package's executables, everywhere |
| `slang build [file.slang]` | one executable, see [Single executables](build.md) |
| `slang expand file` | prints a file as core slang, after its extensions were applied |
| `slang highlight [--check] file` | the file's tokens and errors as JSON, for tools |
| `slang compile file.slang [-o out.slb]` | compiles to bytecode; `--strip` leaves out debug information |
| `slang disasm file` | prints the bytecode of a file |

`slang run` takes a few flags before the file: `--explain` also prints the
project file, the units compiled and the extensions in effect; `--profile
out.folded` writes a sampled profile as folded stacks, for a flame graph;
`--debug PORT` waits for a debugger.

The REPL is one session: a line's top-level locals stay for the lines
after it, a line that ends in an expression or a call prints its value,
and ctrl-c stops a line that runs too long. [Notebooks](notebooks.md) are
the same session with a document around it.

## Tests

A test file is a slang file named `*test.slang` that declares groups and
tests with `slang/test`:

```slang
local test = require("slang/test")

test.group("math"){
  test.setup{ }                          // before every test of the group
  test.test("adds"){
    assert(1 + 1 == 2, "one and one")
  }
}
```

`slang test` runs the files in order of their names and reports each test;
a test fails when it raises, with where and the calls in the test that led
there. `test.skip("why")` ends a test as skipped (a platform without what
it needs). Nothing stops the run: a file that does not load, a setup or
teardown that raises, a group whose code raises, each is a failure in the
report, and the other tests still run. `--only "group / test"` runs one
(and fails when no test matches), and `--json` prints the results for
editors and CI. The exit status is 0 when no test failed.

## Formatting

`slang fmt` is opinionated and has no options. It formats extension syntax
too: an extension marks its layout in its grammar, and the formatter uses
the grammar the file is parsed with.

## Documentation

`slang doc` documents a project from the comments it already has: the
comment block that starts a file documents the module, and the block
directly above a definition documents it. Signatures are typed in a small
notation of their own. [Writing docs](../pages/writing-docs.html)
describes it; the [standard library](../../doc/) pages are made this way.

## Editors

`lsp/` is a language server written in slang. It highlights files with the
parser itself, so extensions and dialects are coloured as they are parsed,
and it resolves names the way the compiler does:

- parse errors, compile errors and lint warnings (unused locals, undefined
  globals, missing modules) as you type;
- hover with the signature and doc comment, go to definition and find
  references, for locals, globals, module fields and methods;
- rename across the project, the outline, workspace symbols;
- completion (members, names in scope, keywords, module names, and the
  fields of an option table as its parameter's type documents them) and
  signature help;
- formatting of a file or a selection;
- on extension syntax: hover and go to definition lead to the extension
  that made it.

| editor | where | install |
|---|---|---|
| VS Code | `editors/vscode` | `make vscode`, then `code --install-extension editors/vscode/slang-lang-0.2.0.vsix` |
| Neovim 0.11+ | `editors/nvim` | add the folder as a plugin; its README has the lazy.nvim entry |

Both add the tests of a file (the test explorer in VS Code, `:Slang test`
in Neovim), a view of a file's expanded code, commands to run a file, use
the REPL, fetch packages and build, and the debugger.

The server runs a project's extensions while it parses, as the compiler
does. VS Code starts it in trusted workspaces only; in Neovim, open
projects you do not trust with the plugin off.

## The debugger

`slang run --debug PORT file` (or `SLANG_DEBUG=PORT` with any command)
waits for a debugger on 127.0.0.1:PORT and speaks the Debug Adapter
Protocol itself: breakpoints with conditions, stepping, pause, a stop at
errors no `try` catches (before the stack unwinds), the call stack,
locals, upvalues and globals, and any expression evaluated in the paused
frame. A program without a debugger pays nothing for it. The editor
plugins connect on their own: F5 in VS Code, `:Slang debug` in Neovim.

## The bytecode cache

Files loaded with `require` or `slang run` are cached as bytecode in
`~/.cache/slang`. Only files that compile with the standard grammar and
run no code at compile time are cached, and the key includes a hash of the
compiler, so the cache never changes what a program does.

## Environment variables

| variable | does |
|---|---|
| `SLANG_CACHE_DIR` | where the bytecode cache is (default `~/.cache/slang`) |
| `SLANG_NO_CACHE=1` | turns the bytecode cache off |
| `SLANG_HOME` | where slang keeps packages (`pkg`), installed packages (`tools`) and their launchers (`bin`); default `~/.slang` |
| `SLANG_PKG_DIR` | where packages are fetched to (default `pkg` in slang's home) |
| `SLANG_NATIVE_PATH` | more directories to look for native modules in |
| `SLANG_DEBUG=PORT` | waits for a debugger, with any command |
| `SLANG_GRAMMAR_WARNINGS=1` | reports conflicts between grammar extensions |
| `SLANG_TRACE=1` | prints every instruction to stderr as it runs |
