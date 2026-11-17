# Single executables

`slang build` turns a program into one executable that runs without slang
installed:

```sh
slang build -o hello main.slang      # ./hello, anywhere
slang build --dir main.slang         # dist/<name>, dist/lib/, and the assets next to it
slang build --list main.slang        # what a build would take
```

The executable is a copy of the slang runtime with the program appended:
its modules as bytecode, and its asset files. Nothing is compiled from C.
On macOS slang signs the result ad hoc itself, or runs `codesign` with an
identity from `build.codesign`.

## What goes in

Slang finds a program's modules by following `require` from the main file,
packages included. A `require` of a computed name is reported, and
`build.modules` lists what such a call may load.

Assets are listed in `slang.project`, and keep their project-relative
paths:

```slang
{
  name: "app",
  build: {
    assets: {"static", "data/words.txt"},
    compress: true,          // or a list of paths; images, video and archives are skipped
    modules: {"plugins/a"},  // modules required by a computed name
  },
}
```

## Reading assets

A built program reads its assets with `slang/os` as before: a relative
path finds a bundled file first (`read_file`, `exists`, `is_dir`,
`list_dir`, and `async.fs`), and a `slang/web` app's `app:static` serves
them. `slang/bundle` tells what `os` cannot: whether a file is bundled,
and how it is stored.

Bundled files are read-only. Writes go to the disk, and a bundled path
keeps reading the bundled file, so a program keeps its data apart from its
assets. With `compress`, assets are stored gzipped where that saves at
least 10%, and `app:static` sends them as stored to clients that take
gzip.

## Native modules

A program that needs native modules (`slang/web` needs `uv` and `llhttp`)
gets them linked in. `slang build` links the runtime from slang's static
archives in `lib/static` with `cc`, or with `zig cc` where there is no
`cc`, once per set of modules; the result is cached in
`~/.cache/slang/runtimes`. The archives carry their third-party libraries,
so the executable runs on machines without them.

`--dir` needs no linker. It writes a directory with the executable (the
runtime and the modules), the native modules in `lib/`, and the assets
copied next to it as they were.

A package's prebuilt native modules cannot be linked into one file:
programs that use such a package are built with `--dir`.
