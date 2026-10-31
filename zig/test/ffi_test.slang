// slang/ffi against zig/test/ffitest.c (lib/libffitest, built by zig
// build): declarations read from text, values crossing both ways, pointers
// into C memory, and the preprocessor
local t = require("slang/test")
local ffi = require("slang/ffi")
local str = require("slang/string")

local header = str.join({
  "#include <stdint.h>",
  "#define FT_VERSION \"1.2\"",
  "#define FT_LIMIT (4 * 16)",
  "#define FT_HALF 0.5f",
  "#define FT_API",
  "#if defined(FT_API) && FT_LIMIT > 10",
  "#define FT_BIG 1",
  "#else",
  "#define FT_BIG 0",
  "#endif",
  "#ifdef NOT_DEFINED",
  "this is not C and is skipped",
  "#endif",
  "#define FT_VEC(x, y) (Vec2){ x, y }",
  "typedef struct { float x, y; } Vec2;",
  "#define FT_ORIGIN FT_VEC(0, 0)",
  "typedef struct { double a; int8_t b; int64_t c; } Mixed;",
  "typedef struct { Vec2 pos; uint8_t tag[4]; char name[8]; } Item;",
  "typedef struct { int32_t v[10]; } Big;",
  "typedef struct Node { int value; struct Node *next; } Node;",
  "typedef enum { RED, GREEN = 5, BLUE, MASK = 1 << 4 } Color;",
  "/* scalars */",
  "FT_API int8_t ft_i8(int8_t x);",
  "uint8_t ft_u8(uint8_t x); int16_t ft_i16(int16_t x); uint16_t ft_u16(uint16_t x);",
  "int32_t ft_i32(int32_t x); uint32_t ft_u32(uint32_t x);",
  "int64_t ft_i64(int64_t x); uint64_t ft_u64(uint64_t x);",
  "float ft_f32(float x); double ft_f64(double x); _Bool ft_not(_Bool b);",
  "double ft_mix_args(int8_t a, double b, uint16_t c, float d, int64_t e);",
  "const char *ft_greet(const char *name);  // says hello",
  "// adds two vectors",
  "Vec2 ft_vec_add(Vec2 a, Vec2 b);",
  "Mixed ft_mixed(double a, int8_t b, int64_t c); double ft_mixed_sum(Mixed m);",
  "Item ft_item(Vec2 pos, const char *name); int ft_item_tags(Item it);",
  "Big ft_big(int start); int64_t ft_big_sum(Big b);",
  "float ft_sum_vecs(const Vec2 *vs, int count);",
  "void ft_scale(Vec2 *v, float k);",
  "void ft_fill(int *out, int count);",
  "int ft_count_nodes(const Node *n);",
  "int ft_sum_ints(int count, ...);",
  "int ft_next(void);",
  "const void *ft_null(void);",
  "int ft_missing(void);",
  "static inline int ft_inline(int x) { return x * (2 + 1); }",
}, "\n")

local C = ffi.cdef(header)
local lib = ffi.load("ffitest", C)

t.group("ffi: declarations"){
  t.test("constants from #define and enums, #if decides"){
    assert(C.constants.FT_VERSION == "1.2")
    assert(C.constants.FT_LIMIT == 64)
    assert(C.constants.FT_HALF == 0.5)
    assert(C.constants.FT_BIG == 1)
    assert(C.constants.RED == 0 and C.constants.GREEN == 5)
    assert(C.constants.BLUE == 6 and C.constants.MASK == 16)
    // a function-like macro expanding to a compound literal
    assert(C.constants.FT_ORIGIN.x == 0 and C.constants.FT_ORIGIN.y == 0)
  }
  t.test("functions with their docs; inline bodies are skipped"){
    assert(C.functions.ft_greet.doc == "says hello")
    assert(C.functions.ft_vec_add.doc == "adds two vectors")
    assert(C.functions.ft_sum_ints.variadic)
    assert(C.functions.ft_inline != null)
    assert(ffi.sizeof("Mixed", C) == 24)
    assert(ffi.sizeof("Item", C) == 20)
    assert(ffi.sizeof("int64_t[3]", C) == 24)
  }
  t.test("bad declarations are located errors"){
    local r = pcall(ffi.cdef, "int f(int x;")
    assert(r[0] == "err")
    assert(str.index_of(r[1].message, "ffi.cdef:") == 0, r[1].message)
    assert(str.index_of(r[1].message, "line 1") >= 0, r[1].message)
  }
}

t.group("ffi: calls"){
  t.test("integers wrap to their C width, floats round to float"){
    assert(lib.ft_i8(200) == -56)
    assert(lib.ft_u8(-1) == 255)
    assert(lib.ft_i16(40000) == -25536 and lib.ft_u16(70000) == 4464)
    assert(lib.ft_i32(-7) == -7 and lib.ft_u32(-1) == 4294967295)
    assert(lib.ft_i64(9007199254740993) == 9007199254740993)
    assert(lib.ft_u64(-1) == -1, "uint64 comes back as its bits")
    assert(lib.ft_f32(0.1) != 0.1 and lib.ft_f64(0.1) == 0.1)
    assert(lib.ft_not(false) == true and lib.ft_not(1) == false)
    assert(lib.ft_mix_args(1, 2.5, 3, 0.5, 4) == 11)
    assert(lib.ft_next() == 1 and lib.ft_next() == 2)
  }
  t.test("strings in and out"){
    assert(lib.ft_greet("slang") == "hi slang")
    assert(lib.ft_greet(null) == "hi nobody")
    assert(lib.ft_null() == null)
  }
  t.test("structs by value: by name or position, padded, nested, large"){
    local v = lib.ft_vec_add({1, 2}, {x: 3, y: 4})
    assert(v.x == 4 and v.y == 6)
    local m = lib.ft_mixed(1.5, -2, 1 << 40)
    assert(m.a == 1.5 and m.b == -2 and m.c == 1 << 40)
    assert(lib.ft_mixed_sum(m) == 1.5 - 2 + (1 << 40))
    local it = lib.ft_item({1, 2}, "abc")
    assert(it.pos.x == 1 and it.tag == {1, 2, 3, 4} and it.name == "abc")
    assert(lib.ft_item_tags(it) == 13)
    assert(lib.ft_item_tags({pos: {0, 0}, tag: {5}, name: "toolongname"}) == 12)
    local b = lib.ft_big(10)
    assert(len(b.v) == 10 and b.v[9] == 19)
    assert(lib.ft_big_sum(b) == 145)
  }
  t.test("pointers: lists, out parameters, a struct updated in place"){
    assert(lib.ft_sum_vecs({{1, 2}, {x: 3, y: 4}}, 2) == 10)
    local v = {x: 2, y: 3}
    lib.ft_scale(v, 2)
    assert(v.x == 4 and v.y == 6)
    local squares = {0, 0, 0, 0}
    lib.ft_fill(squares, 4)
    assert(squares == {0, 1, 4, 9})
  }
  t.test("variadic functions take C's promotions"){
    assert(lib.ft_sum_ints(3, 1, 2, 3) == 6)
  }
  t.test("argument errors"){
    local r = pcall(lib.ft_vec_add, "x", {})
    assert(r[0] == "err")
    assert(
      r[1].message ==
        "bad argument #1 to 'ft_vec_add' (Vec2 expected, got string)",
      r[1].message,
    )
    r = pcall(lib.ft_i32)
    assert(r[1].message == "ft_i32 takes 1 arguments, got 0")
    r = pcall(func(){ return lib.ft_missing })
    assert(r[0] == "err")
    assert(str.index_of(r[1].message, "not in the library") >= 0)
    assert(lib.no_such_function == null)
  }
}

t.group("ffi: buffers"){
  t.test("a buffer is its memory: no copy, C writes it in place"){
    local buffer = require("slang/buffer")
    local vs = buffer.from({{1, 2}, {3, 4}}, "Vec2", C)
    assert(lib.ft_sum_vecs(vs, len(vs)) == 10)
    local squares = buffer.new("int", 5)
    lib.ft_fill(squares, len(squares))
    assert(squares:to_list() == {0, 1, 4, 9, 16})
    // a slice is memory too
    lib.ft_fill(squares:slice(3), 2)
    assert(squares:to_list() == {0, 1, 4, 0, 1})
  }
  t.test("the element type must match, unless C takes bytes"){
    local buffer = require("slang/buffer")
    local r = pcall(lib.ft_sum_vecs, buffer.new("float", 4), 2)
    assert(r[0] == "err")
    assert(
      r[1].message ==
        "bad argument #1 to 'ft_sum_vecs' (Vec2 * expected, got a buffer of float: use b:cast)",
      r[1].message,
    )
    local floats = buffer.from({1, 2, 3, 4}, "float")
    assert(lib.ft_sum_vecs(floats:cast(ffi.type("Vec2", C)), 2) == 10)
  }
}

t.group("ffi: memory"){
  t.test("new, indexing, fields and assignment"){
    local vs = ffi.new("Vec2", 3, C)
    vs[0] = {1, 2}
    vs[1].x = 3
    vs[1].y = 4
    vs[2] = vs[1]
    assert(vs[2].y == 4)
    assert(lib.ft_sum_vecs(vs, 3) == 17)
    // a pointer to a struct is an argument where the struct is
    assert(lib.ft_vec_add(vs[0], vs[1]).x == 4)
    assert(ffi.value(vs[1]) == {x: 3.0, y: 4.0})
    local ints = ffi.new("int", 4, C)
    lib.ft_fill(ints, 4)
    assert(ints[3] == 9)
    assert(ffi.offset(ints, 2)[0] == 4)
    assert(ffi.address(ffi.offset(ints, 1)) - ffi.address(ints) == 4)
  }
  t.test("linked structs through pointers"){
    local nodes = ffi.new("Node", 3, C)
    for(local i = 0; i < 3; i = i + 1){
      nodes[i].value = i + 1
    }
    nodes[0].next = nodes[1]
    nodes[1].next = nodes[2]
    assert(lib.ft_count_nodes(nodes) == 6)
    assert(nodes[0].next.next.value == 3)
    assert(nodes[2].next == null)
  }
  t.test("casts, strings, and memory kept alive by pointers into it"){
    local buf = ffi.new("char", 8, C)
    local bytes = ffi.cast(buf, "uint8_t", C)
    bytes[0] = 104
    bytes[1] = 105
    assert(ffi.string(buf) == "hi" and len(ffi.string(buf, 3)) == 3)
    // only a pointer into the second element is kept
    local tail = ffi.offset(ffi.new("int", 1000, C), 999)
    tail[0] = 7
    local garbage = {}
    for(local i = 0; i < 2000; i = i + 1){
      append(garbage, {i})
    }
    assert(tail[0] == 7)
  }
  t.test("what cannot be stored in C memory is an error"){
    local nodes = ffi.new("Node", 1, C)
    local r = pcall(func(){ nodes[0].next = {value: 1} })
    assert(r[0] == "err")
    assert(str.index_of(r[1].message, "use ffi.new") >= 0, r[1].message)
  }
}
