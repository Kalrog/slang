# Install slang

Slang is one binary, `slang`, that carries its compiler and its standard
library. There are no downloads yet: you build it from source, which takes
a minute. It runs on macOS and Linux; Windows is not supported yet.

To try the language without installing anything, the
[tour](../tour/) and the playground on slang's website run it in the
browser.

## What you need

- [Zig](https://ziglang.org) 0.17. `brew install anyzig` gives a `zig`
  that fetches the version pinned in `zig/build.zig.zon`.
- The libraries behind the native modules: libuv (the event loop), SQLite,
  OpenSSL 3 and zlib. With Homebrew: `brew install libuv sqlite openssl@3
  zlib`. Any of them can be left out, see below.
- libffi, for calling C libraries from slang. It is part of macOS; on
  Linux it is the package `libffi-dev`.

## Build and install

```sh
git clone https://github.com/Kalrog/slang
cd slang
make build        # bin/slang, and the native modules in lib/
make install      # /usr/local/bin/slang and /usr/local/lib/slang
```

`make install PREFIX=~/.local` installs for one user, and `make uninstall`
removes what was installed. Slang also runs from the checkout as
`bin/slang`, with nothing installed.

The build looks for the libraries where Homebrew puts them. Elsewhere, say
where they are, or leave a module out:

```sh
cd zig
zig build -Doptimize=ReleaseFast -p .. \
  -Dlibuv-prefix=/usr -Dsqlite-prefix=/usr \
  -Dopenssl-prefix=/usr -Dzlib-prefix=/usr
zig build -Doptimize=ReleaseFast -p .. -Dsqlite=false   # without SQLite
```

Without `libuv` there is no `slang/async`, `slang/http` or `slang/web`;
without `crypto`, no `slang/tls`, `slang/crypto` or `slang/jwt`. The
language, the tools and the rest of the library need none of them.

## Your first program

Put this in `hello.slang`:

```slang
local name = args()[0] or "world"
print("Hello, ", name, "!\n")
```

```sh
slang run hello.slang          # Hello, world!
slang run hello.slang Ada      # Hello, Ada!
```

`print` writes its arguments as they are, so a line ends where you write
`"\n"`. `slang repl` reads statements and expressions and prints what they
give, which is a quick way to try a library function.

## A module and its test

A module is a file that returns a value, usually a table of functions.
`greet.slang`:

```slang
local greet = {}

// hello(name: string) -> string
// A greeting for name.
func greet.hello(name){
  return concat("Hello, ", name, "!")
}

return greet
```

`main.slang` loads it with `require`, by its path without the suffix:

```slang
local greet = require("greet")
print(greet.hello(args()[0] or "world"), "\n")
```

Tests are the files named `*test.slang` in the folder `test`.
`test/greet_test.slang`:

```slang
local test = require("slang/test")
local greet = require("greet")

test.group("greet"){
  test.test("says hello"){
    assert(greet.hello("Ada") == "Hello, Ada!")
  }
}
```

```sh
slang run main.slang Ada       # Hello, Ada!
slang test                     # runs every test file in ./test
slang fmt .                    # formats the files in place
slang doc -o doc               # HTML docs from the comments above definitions
```

## Ship it

`slang build` makes one executable of a program and its modules. It runs on
machines that have no slang:

```sh
slang build -o hello main.slang
./hello Grace                  # Hello, Grace!
```

[Single executables](build.md) covers assets and native modules.

## Set up your editor

Slang has a language server, written in slang, that parses files with the
real parser: errors as you type, completion, hover with doc comments, go to
definition, rename, formatting, tests and a debugger.

- **VS Code**: `make vscode` packages the extension, then
  `code --install-extension editors/vscode/slang-lang-0.2.0.vsix`.
- **Neovim** (0.11 or newer): add `editors/nvim` of your checkout as a
  plugin. `editors/nvim/README.md` has the lazy.nvim entry.

[Tools](tools.md) lists what the editors and the `slang` command do.

## Where next

- [The tour](../tour/): the language in thirteen short steps, each one a
  program to edit and run.
- [The language](language.md): everything the tour leaves out.
- [Projects and packages](projects.md): `slang.project`, dependencies and
  search paths.
- [The standard library](../../doc/): every module, with examples.
- The `examples` folder of the repository: games, synthesizers, a web
  application, a Prolog.
