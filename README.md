<img src="website/public/logo.svg" alt="" width="56" align="right">

# Slang

A small scripting language you can extend.

Slang is in the family of Lua: tables, closures and coroutines, with
pattern matching and errors that are matched, not parsed. It is one
binary that carries its compiler, its standard library and its tools. Its
parser is written in slang, and a program can change it: new statements,
new operators and whole dialects are ordinary libraries.

```slang
local people = {
  {name: "Ada", born: 1815},
  {name: "Grace", born: 1906},
  {name: "Alan", born: 1912},
}

for(let {name: local n, born: local b} in values(people)){
  print(n, " was born ", 2026 - b, " years ago\n")
}
```

A pipe operator, added by the program that uses it:

```slang
extension {
  local g = require("slang/compiler").grammar()
  local pipe = g:expression():level("pipe", {after: "or"})
  pipe:left(g:token("|>"), func(left, op, right){
    return +{expr: -{right}(-{left})}
  })
}

local double = func(x) => x * 2
print(5 |> double |> double, "\n") // 20
```

## What you get

- **A familiar language.** One data structure, the table, for lists,
  records and objects. Functions are closures. On top: patterns that take
  values apart, `try`/`catch` that matches what was raised, `defer`,
  labeled loops, spread arguments, properties and operator overloading.
- **A grammar that is a library.** Extensions add syntax for a file or a
  project, and are highlighted, formatted and documented like the core
  language.
- **Batteries.** An async runtime on libuv with HTTP, WebSockets and TLS,
  a web framework, SQLite, JSON, regular expressions, HTML templates and
  cryptography. Isolates run code in parallel.
- **C without writing C.** `slang/ffi` calls C libraries from their
  headers, and buffers share memory with them. raylib, Box2D, Jolt, SDL3
  and WebGPU are bound this way in `packages/`.
- **Tools in the binary.** `slang test`, `slang fmt`, `slang doc`, a
  package manager, a debugger, and `slang build`, which makes one
  executable of a program. A language server with plugins for VS Code and
  Neovim.

## Install

Slang builds from source on macOS and Linux. It needs
[Zig](https://ziglang.org) 0.17 (`brew install anyzig`) and, for the
native modules, libuv, OpenSSL 3 and zlib (`brew install libuv openssl@3
zlib`); SQLite is built from its source.

```sh
git clone https://github.com/Kalrog/slang
cd slang
make build        # bin/slang, and the native modules in lib/
make install      # /usr/local, or PREFIX=~/.local
```

[Install slang](website/guide/install.md) has the details: other
platforms, leaving modules out, and setting up an editor.

## First steps

```sh
slang run hello.slang     # run a program
slang repl                # try things out
slang test                # run the *test.slang files in ./test
slang fmt .               # format
slang build main.slang    # one executable, no slang needed to run it
```

## Documentation

| | |
|---|---|
| [Install slang](website/guide/install.md) | build it, a first program, a module and a test, editors |
| [The language](website/guide/language.md) | the reference: scope, values, tables, metatables, patterns, errors, coroutines, isolates |
| [Projects and packages](website/guide/projects.md) | `slang.project`, how `require` finds modules, dependencies |
| [Tools](website/guide/tools.md) | the `slang` command, tests, formatting, docs, editors, the debugger |
| [Single executables](website/guide/build.md) | `slang build` |
| [Async and the web](website/guide/async.md) | futures and `await`, HTTP, the web framework, SQLite |
| [Notebooks](website/guide/notebooks.md) | notebooks as Markdown files, in the browser and the terminal |
| [Extending the language](website/guide/extensions.md) | quotes, extension statements, dialects, the grammar API |
| [Working with C](website/guide/c.md) | the FFI, buffers, native modules, embedding |

The same guides are part of slang's website, with a tour of the language
in thirteen runnable steps, a playground that runs slang in the browser,
and the reference of every library module. The site is in this repository
and slang builds it:

```sh
make wasm serve     # http://127.0.0.1:8080
```

## Examples

`examples/` holds whole programs, most with a README of their own:

- **Games**: `switchback` (an off-road expedition through a world made
  from a seed), `courier` (deliveries by flying car through a night
  city), `siege` (a 3D catapult game), `deckhand` (a heist game whose
  hacking deck runs slang), `delve` (a roguelike), `inkblast` (a party
  game over the network), `breakout`.
- **Sound**: `modular` (a modular synthesizer), `live` (live coding of
  music and visuals), `fm` and `synth` (two keyboards), `granular`, `dsp`.
- **Programs**: `webserver` (a web application), `desktop` (the same
  kind of app in a native window), `isolates` (a Mandelbrot set on every
  CPU), `swarm` (a million particles on the GPU).
- **Languages**: `prolog` (a Prolog interpreter written to be read),
  `futamura` (a partial evaluator), `functional` (pipes and holes as
  extensions), `project` (a `slang.project` with dialects).

## Status

Slang is young. Until 1.0 the language and its library still change, and
there are no releases yet: you build it from source. It is developed on
macOS; Linux builds and runs; Windows is not supported yet.

## Working on slang

The VM is written in Zig (`zig/`). The compiler and most of the library
are written in slang (`slang/`) and shipped as bytecode inside the binary.
[CONTRIBUTING.md](CONTRIBUTING.md) explains how to build, test and change
them, and where everything is.
