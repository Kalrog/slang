# Projects and packages

A single file needs no project. A program of several files gets a
`slang.project` once it needs dependencies, search paths, extensions for
all its files, or settings for `slang build`.

## The project file

`slang.project` is a slang table literal. Slang looks for it next to the
main file and in the directories above it; paths in it are relative to the
file.

```slang
{
  name: "app",
  dependencies: {
    json5: {git: "https://github.com/someone/json5", version: "^1.2"},
    util: {path: "../util"},                 // a directory, while working on both
  },
  search_paths: {"src"},                     // where require looks first
  extensions: {"extensions/async"},          // loaded into every file of the project
  dialects: {
    [".json"]: {compile: "extensions/json"}, // require("config") loads config.json
  },
  build: {assets: {"static"}},               // for slang build
}
```

Every key is optional. `extensions` and `dialects` are explained in
[Extending the language](extensions.md), `build` in
[Single executables](build.md). `slang run --explain file` prints the
project file a program runs under, with its extensions and dialects.

## How require finds a module

`require("name")` loads a module once and returns what its file returns:

- `slang/...` is the standard library, which the binary carries.
- A name whose first part is a dependency is a module of that package:
  `require("json5/parse")` is `parse.slang` of json5, and
  `require("json5")` its `init.slang`.
- Anything else is a file: `name.slang`, then `name` with each dialect's
  suffix, looked up in the project's folder, then in its `search_paths`,
  then in the working directory.
- A native module (`require("uv")`) is a library, `uv.dylib` or `uv.so`,
  in `lib/` next to the binary, in the working directory, or in the
  directories of `SLANG_NATIVE_PATH`.

## Packages

A package is a git repository whose `slang.project` gives its name and
whose tags `vMAJOR.MINOR.PATCH` are its versions.

| command | does |
|---|---|
| `slang get` | fetches the project's dependencies and writes `slang.lock` |
| `slang update [name...]` | moves packages to their newest version within the same major |
| `slang deps` | lists what the project uses and who asks for it |

- Packages are fetched with git into `~/.slang/pkg` (or `$SLANG_PKG_DIR`).
  With the cache complete, nothing needs the network.
- `slang.lock` pins the versions, their commits and hashes of their files.
  Keep it with the project.
- Versions are chosen as Go chooses them: each package gets the highest
  minimum anyone asks for. One program never mixes two majors of a
  package.
- A package compiles under its own `slang.project`, so its grammar
  extensions never reach its users.
- Nothing in a package runs when it is fetched. Compiling it runs its
  grammar extensions, as compiling any slang does.

## Packages with native code

Slang loads native modules but never builds them. A package ships them
prebuilt as `lib/<platform>/<module>.dylib` (or `.so`), built by its
author against `slang.h` for each platform it supports. `os.platform()`
names the platform: `macos-aarch64`, `linux-x86_64`, ...

`require("pkg/mod")` loads `lib/<platform>/mod.dylib` of the package
`pkg`, whose entry point is `slang_open_pkg_mod`. A package with a `lib/`
but no build for the running platform is an error that says so.

Often a package can do without native code: a binding through `slang/ffi`
calls the library installed on the machine. `packages/raylib` does that,
and `examples/breakout` depends on it by path. See
[Working with C](c.md).

## Stubs

A package's `stubs/` declare and document what tools cannot see in its
source: its native modules (`stubs/mod.slang` for `pkg/mod`), and modules
whose fields are made at run time, like an FFI binding (`stubs/init.slang`
for `pkg`). A stub is a slang file that declares the functions with empty
bodies and doc comments; it never runs. The language server and `slang
doc` read a package's stub instead of its source.

## Packages kept with slang

The repository's `packages/` folder holds packages to depend on by path:

| package | what it is |
|---|---|
| `raylib` | windows, drawing, input and sound: all of raylib through `slang/ffi` |
| `box2d` | 2D physics |
| `jolt` | 3D physics (Jolt, through joltc, shipped prebuilt) |
| `window` | windows, input and audio on SDL3 |
| `gpu` | WebGPU through wgpu-native |
| `kernel` | number-crunching loops in a small language of their own, compiled |
| `dsp` | audio processing as block diagrams, after Faust, compiled to kernels |
| `midi` | MIDI input and MIDI files (macOS) |
| `microphone` | audio input (macOS) |
