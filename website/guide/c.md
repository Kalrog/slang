# Working with C

There are four ways between slang and C, from least to most work:

- **`slang/ffi`** calls a C library from slang, from its header. No C is
  written.
- **`slang/buffer`** is typed memory that slang and C share without
  copying.
- **Native modules** are written in C (or Zig, or anything with a C ABI)
  against `slang.h`.
- **Embedding** runs slang inside a C program, through the same header.

## Calling C libraries: slang/ffi

`slang/ffi` calls C libraries directly, through libffi. Declarations are
C, read from text or from the library's own header:

```slang
local ffi = require("slang/ffi")
local C = ffi.cdef("typedef struct { int quot; int rem; } div_t; div_t div(int, int);")
local libc = ffi.load(null, C)           // null: the program itself
local r = libc.div(17, 5)
print(r.quot, " ", r.rem, "\n")          // 3 2
```

The preprocessor runs on headers (`#define`, `#if`, function-like
macros), and function bodies are skipped. How values cross:

| slang | C |
|---|---|
| numbers, bools | the arithmetic types |
| strings | `const char *` |
| tables | structs: fields by name or by position; results are tables by name |
| `null`, a pointer, a string, a table, a buffer | a pointer parameter |
| a slang function | a function pointer: a C callback |

- A table passed for a pointer is a list of elements or one struct. It is
  copied back after the call when the pointer is not to const, so out
  parameters are plain tables.
- Pointers index C memory like C: `p[i]`, `p.field`, and assignment.
  `ffi.new` allocates memory the collector frees once nothing points into
  it.
- Variadic functions get C's promotions. Enum values and `#define`
  constants (numbers, strings, compound literals) are in `C.constants`.
- C may call a callback from any thread. Slang still runs on one thread
  at a time: every C call lets callbacks in while it runs (a lock, like
  Python's). An error in a callback is raised when the C call returns.
- A wrong declaration crashes as it would in C.
- Unions, bit fields and `long double` are not supported yet.

`packages/raylib` binds all of raylib this way, `packages/box2d` Box2D
and `packages/jolt` Jolt Physics. A build without libffi (`-Dffi=false`)
has no `ffi.load`; `ffi.cdef` and buffers are in every build.

## Sharing memory: slang/buffer

A buffer is n values of one C type, a scalar or a struct. Slang indexes a
buffer about as fast as a list, and C reads it without a copy: passed to
an FFI function, a buffer is its memory.

```slang
local buffer = require("slang/buffer")
local math = require("slang/math")
local samples = buffer.new("float", 44100)
for(local i = 0; i < len(samples); i = i + 1){
  samples[i] = math.sin(i * 0.05)
}
print(len(samples), " ", samples[100], "\n")
```

A buffer of structs takes the declarations the struct comes from
(`buffer.new("Vector2", 100, decls)`), and its elements are views:
`points[3].x = 10` writes into the buffer.

- Indexes count from 0 and are checked. `len`, `values`, `entries` and
  `==` (contents) work as on lists.
- Slices share memory and keep it alive. `fill`, `set`, `copy`, `cast`,
  `to_list`, `to_string` and `from_string` run natively.
- `buffer.wrap(pointer, n)` makes a buffer over memory C owns.
- `buffer.shared(type, n)` is memory several isolates read and write.

## Native modules: slang.h

`zig/include/slang.h` is a stack API in the style of Lua's, for modules
written in C. `require("name")` loads `name.dylib` (or `.so`) from `lib/`
next to the binary, from the working directory, or from the directories
in `SLANG_NATIVE_PATH`, and calls its `slang_open_name`.

The repository's `extensions/native` has modules to read:

| file | shows |
|---|---|
| `hello.c` | every part of the API |
| `vec.zig` | a userdata type with operator metamethods, in Zig |
| `uv.c` | a large binding: libuv, with handles and callbacks |
| `sqlite.c`, `zlib.c`, `crypto.c` | bindings that take strings and buffers alike (`slang_checkbytes`) |

- Natives signal errors by returning `SLANG_ERROR`, never by longjmp.
- A module keeps its state per VM, not in C statics: a program may run
  several VMs (isolates).
- `slang_tobuffer` borrows a buffer's memory.

A package ships its native modules prebuilt, see
[Projects and packages](projects.md).

## Embedding slang

`slang.h` also embeds: `slang_new`, `slang_dostring`, `slang_dofile`,
registering natives and calling slang functions go through the same stack
API the modules use. `slang_isolate_new` makes a VM for a thread the host
owns, and `slang_send` and `slang_receive` (with `try` forms) use channels
from C.
