# Buffers

Status legend: `[ ]` todo, `[~]` in progress, `[x]` done. Decided 2026-10-30.

Goal: typed memory that slang code indexes about as fast as a table and
that C reads without copying. A buffer holds n values of one C type: a
scalar (`float`, `int32`, `uint8`, ...) or a struct. It replaces lists of
numbers where speed or interop matters (vertices, pixels, audio samples,
binary data), and strings where binary data has to change.

```slang
local buffer = require("slang/buffer")
local samples = buffer.new("float", 44100)
for(local i = 0; i < len(samples); i = i + 1){
  samples[i] = math.sin(i * 0.05)
}
local points = buffer.new("Vector2", 100, rl.decls)
points[3].x = 10
rl.draw_triangle_strip(points, rl.RED)   // the memory, no conversion
```

## Why this design

A buffer is the FFI's owned memory with a length. `ffi.new(type, n)`
already gives memory the collector owns, typed by a C type, indexed with
`p[i]` (scalars as numbers, structs as views into the memory). What it
lacks is a length, bounds checks, bulk operations, speed, and a way for
native extensions to use it. Buffers add those, so there is one kind of
typed memory in slang, not one for the FFI and another for everything
else.

Considered and not taken:

- JS-style `ArrayBuffer` plus typed views: two concepts where one does.
  Slices and casts already give several typed views of the same memory.
- Tables that store numbers natively (LuaJIT, V8): no new API, but C
  still can't borrow the memory without a copy, and every table
  operation gets a second representation. It would solve speed and leave
  interop unsolved.
- Fixed classes per type (`FloatArray`, `IntArray`): simple, but no
  structs, and a second copy of what the C types already describe.

## The design

### C types in the core

The C types (scalars, pointers, arrays, structs laid out by C's rules)
move out of `ffilib.zig` into a core module that needs no libffi:
`zig/src/stdlib/ctypes.zig`. `slang/ffi_core` keeps only libraries,
symbols and calls, built on it. With that:

- buffers exist in every build, `-Dffi=false` included;
- `ffi.cdef` (declarations, constants, struct layouts) works without
  libffi too; only `ffi.load` and calls need it;
- one type value describes an element everywhere: a buffer's, a
  pointer's, a function parameter's.

### Buffers and pointers

One userdata layout, `{addr, type, count}`, two kinds:

- a **pointer** (`ffi.pointer`): an address without a known length, as C
  hands it out. It indexes without checks, as today.
- a **buffer** (`buffer`): an address with a count. It owns its memory
  (`buffer.new`), or is a slice of a buffer (and keeps that alive), or
  wraps C memory whose length the code knows
  (`buffer.wrap(ptr, n, [type])`, for `mesh.vertices` with
  `vertex_count * 3` floats, or a byte area C filled).

Indexing is 0-based, like lists. `b[i]` reads element i: a number for
scalars, a view (a pointer) for structs, so `b[i].x = 3` writes in place.
`b[i] = v` converts v as the FFI does: a number, or a table or view for a
struct. An index outside `0 .. len(b) - 1` is an error that names it.
String keys are methods (a buffer of structs has no fields of its own;
`b[i].field` reaches them).

### The API (`slang/buffer`)

- `buffer.new(type, n, [decls])`: n zeroed elements. type is a scalar
  name, a C type value, or a struct name from `decls` (from `ffi.cdef`).
- `buffer.from(list, type, [decls])`, `buffer.from_string(s)` (uint8),
  `b:to_list()`, `b:to_string()` (the bytes, for any element type).
- `len(b)` (elements), `b:size()` (bytes), `b:type()` (the element type),
  `b:slice(from, [to])` (shares the memory), `b:copy()` (owns a copy),
  `b:fill(v)`, `b:set(list or buffer, [at])` (bulk writes),
  `b:cast(type)` (the same bytes as another type, the count recomputed).
- `values(b)`, `entries(b)` and `keys(b)` iterate a buffer like a list.
- `string(b)`: `buffer<float>[44100]`, not the contents.
- `==` compares contents (type and bytes), like tables and strings.
  `b:same(other)` asks whether two buffers are the same memory.

Bulk operations run natively, with no slang value made per element.

### The VM fast path

`b[i]` through `__index` is a native call per access, which is no faster
than a table. getTable and setTable in `interp.zig` check a buffer before
the metatable: an int key on a buffer of scalars loads or stores the
element directly (bounds check, a switch on the element kind, no call).
Struct elements and string keys take the metatable path, since they
make a view or a method anyway.

The userdata gets a `buffer: ?*Ptr` field (null for every other userdata)
so the check is one load and compare. Target: indexing a float buffer
within 1.5x of indexing a list in a numeric loop, measured in
`bench/buffers.slang` against the same loop on a list.

### Interop with C

- **FFI**: a buffer passed to a pointer parameter is its address, with no
  copy and no writeback (C writes the memory itself). The element types
  must agree, or the parameter is `void *`, `char *` or `uint8_t *`;
  otherwise it is an argument error (use `b:cast`). The raylib binding's
  list-plus-count arguments take buffers too, since `len(b)` is the count.
- **slang.h** for native extensions:
  - `void *slang_tobuffer(S, idx, size_t *count, size_t *elem_size)`:
    the memory of a buffer argument, or NULL. It stays valid while the
    buffer is reachable (on the stack, or held with `slang_ref`). Buffers
    never move, since the collector does not move objects.
  - `void *slang_newbuffer(S, const char *type, size_t count)`: pushes a
    new buffer of a scalar type and returns its memory for C to fill.
  - `slang_checkbuffer`, the checking variant.
- Extensions that take bytes as a string also take a buffer: zlib, crypto,
  sqlite blobs, and uv and tls writes. Returning buffers instead of
  strings (uv reads into a buffer) comes later, where it pays.

### What stays out

- Growable buffers. A buffer is fixed-size like a typed array; growth is a
  new buffer and `set`. A builder can come later if a use needs it.
- Element-wise math (`b:add(other)`, SIMD). Worth it once buffers carry
  real workloads, and natural on this design (the elements are C
  types).
- Multidimensional views (strides). A buffer is one run of elements.

## Phases

### Phase 1: C types in the core

- [x] `ctypes.zig`: types, layout, conversions (`toC`, `fromC`) and
      pointers move out of `ffilib.zig`; `ffilib.zig` keeps libraries and
      calls. No behaviour changes: the FFI tests pass as they are.
      (2026-10-31) The types carry their own libffi descriptors (libffi
      reads only size, alignment, type code and elements), so ctypes links
      nothing; primitives are made once.
- [x] `ffi.cdef` and the type functions work in a `-Dffi=false` build;
      `ffi.load` there says the build has no FFI. (Checked: that binary
      links only libSystem, and the buffer tests pass on it.)

### Phase 2: buffers

- [x] The buffer kind of the pointer userdata: count, bounds checks,
      owned memory, slices keeping their source alive, `wrap`. Userdata
      has a `kind` (plain, pointer, buffer) for the VM to tell them apart.
- [x] `slang/buffer` with the API above; `values`, `entries`, `keys` and
      `len` on buffers; `==` on contents. (`b:pointer()` added: a pointer
      to the first element.)
- [x] Docs (slang/buffer is slang source with its comments; the native
      part is stubbed as `slang/ctypes`); tests in `test/buffer_test.slang`.

### Phase 3: speed

- [x] `bench/buffers.slang`: a numeric loop over a list and a buffer,
      fill and copy, and passing 10000 `Vector2` to C as a list and as a
      buffer.
- [x] The fast path in getTable and setTable; measured before and after,
      numbers recorded here. (2026-10-31, 1M doubles, ReleaseFast, M-series
      Mac; the "pointer" row is the same memory through `__index`, i.e.
      without the fast path; the loop alone takes 34 ms.)

      | 1M elements       | list  | buffer | pointer (__index) |
      |-------------------|-------|--------|-------------------|
      | write             | 30 ms | 30 ms  | 57 ms             |
      | read and sum      | 25 ms | 29-34 ms | 57 ms           |
      | copy              | 52 ms | 0 ms   |                   |
      | fill              |       | 2 ms   |                   |

      100 calls of a C function taking 10000 `Vec2`: 22 ms as a list, 0 ms
      as a buffer. Target met: reads within 1.4x of a list, writes equal.

### Phase 4: interop

- [x] Buffers as FFI pointer arguments, with the element type check.
- [x] `slang_tobuffer`, `slang_checkbuffer`, `slang_newbuffer` in slang.h,
      exercised by `extensions/native/hello.c` and its test. Also
      `slang_buffertype` (the element type's name) and `slang_tobytes` /
      `slang_checkbytes`: a string's or a buffer's bytes, for functions
      that take binary data.
- [x] zlib, crypto, sqlite and uv/tls accept buffers where they take
      bytes (`slang_checkbytes`; sqlite binds a buffer as a blob);
      `zig/test/bytes_test.slang`.
- [x] raylib: `packages/raylib/examples/terrain.slang` builds a terrain
      mesh in buffers over `mem_alloc`ed memory (`unload_model` frees it
      with raylib's allocator) and uploads it; buffers for list arguments
      in the README.

### Phase 5: docs

- [x] README: a section on buffers next to the FFI's; `slang doc`
      regenerated; PLAN_1.0's "byte buffer or typed-array type" item
      points here.
