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
  "/* callbacks */",
  "typedef int (*IntFn)(int);",
  "int ft_apply(IntFn f, int x);",
  "uint8_t ft_apply_u8(uint8_t (*f)(uint8_t), uint8_t x);",
  "int8_t ft_apply_i8(int8_t (*f)(int8_t), int8_t x);",
  "double ft_apply_f64(double (*f)(double, float), double x);",
  "Vec2 ft_map_vec(Vec2 (*f)(Vec2, const char *), Vec2 v);",
  "const char *ft_name_of(const char *(*f)(int), int i);",
  "typedef struct { IntFn on_value; int base; } Handler;",
  "void ft_set_handler(Handler h);",
  "int ft_fire(int x);",
  "int ft_threads(IntFn f, int n);",
  "int *ft_alloc(int tag); void ft_free(void *p); int ft_freed(void);",
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
  t.test("doc comments in Doxygen style; initializers with braces"){
    local D = ffi.cdef(str.join({
      "typedef struct { float x, y; } V;",
      "static const V v_zero = { 0.0f, 0.0f };",
      "/// makes a vector",
      "V v_make(float x, float y);",
      "/**",
      " * adds two vectors",
      " */",
      "V v_add(V a, V b);",
      "int v_count(void); ///< how many",
    }, "\n"))
    assert(D.functions.v_make.doc == "makes a vector")
    assert(D.functions.v_add.doc == "adds two vectors")
    assert(D.functions.v_count.doc == "how many")
  }
  t.test("header: quoted includes spliced in, each once"){
    local os = require("slang/os")
    local dir = concat(os.getenv("TMPDIR") or "/tmp/", "/slang-ffi-test")
    os.mkdir_all(dir)
    os.write_file(concat(dir, "/ffi_a.h"), "#include \"ffi_b.h\"\n#include <stdint.h>\nB f(void);\n")
    os.write_file(concat(dir, "/ffi_b.h"), "#pragma once\n#include \"ffi_b.h\"\ntypedef int B;\n")
    local text = ffi.header(concat(dir, "/ffi_a.h"))
    assert(str.index_of(text, "typedef int B;") >= 0)
    assert(str.index_of(text, "#include <stdint.h>") >= 0)
    local D = ffi.cdef(text)
    assert(D.types.B != null and D.functions.f != null)
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
    r = pcall(lib.ft_i32, 1, 2)
    assert(r[1].message == "ft_i32 takes 1 arguments, got 2", r[1].message)
    // a missing argument is null: an int still has to be given
    r = pcall(lib.ft_i32)
    assert(r[0] == "err" and str.index_of(r[1].message, "null") >= 0, r[1].message)
    r = pcall(func(){ return lib.ft_missing })
    assert(r[0] == "err")
    assert(str.index_of(r[1].message, "not in the library") >= 0)
    assert(lib.no_such_function == null)
  }
}

t.group("ffi: struct fields by key"){
  // tables convert to structs by field name and back, with the names
  // interned once per type
  t.test("two fields of one name are refused"){
    // (a struct is defined when it is first used)
    local D = ffi.cdef("typedef struct { int a; int a; } Twice;")
    local r = pcall(ffi.sizeof, "Twice", D)
    assert(r[0] == "err" and str.contains(r[1].message, "two fields named a"), r[0] == "err" and r[1].message or "no error")
  }
  t.test("fields given positionally and by name"){
    assert(lib.ft_vec_add({x: 1, y: 2}, {3, 4}).x == 4)
    assert(lib.ft_vec_add({x: 1, y: 2}, {3, 4}).y == 6)
  }
  t.test("a missing field is zero, a wrong value names the argument"){
    assert(lib.ft_vec_add({x: 1}, {}).x == 1)
    assert(lib.ft_vec_add({x: 1}, {}).y == 0)
    local r = pcall(lib.ft_vec_add, {x: "a"}, {})
    assert(r[0] == "err" and r[1].message == "bad argument #1 to 'ft_vec_add' (float expected, got string)", r[1].message)
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

t.group("ffi: callbacks"){
  t.test("a slang function is a C function pointer"){
    assert(lib.ft_apply(func(x){ return x * 2 }, 21) == 42)
    // small integers widen and narrow as C's do
    assert(lib.ft_apply_u8(func(x){ return x + 1 }, 255) == 0)
    assert(lib.ft_apply_i8(func(x){ return -x }, 5) == -5)
    assert(lib.ft_apply_f64(func(x, half){ return x * half }, 3.0) == 1.5)
  }
  t.test("structs and strings in, a struct out"){
    local seen = null
    local v = lib.ft_map_vec(func(v, why){
      seen = why
      return {v.x * 2, v.y * 2}
    }, {1, 2})
    assert(v.x == 2 and v.y == 4 and seen == "scaled")
    // a string cannot be returned: C would keep a pointer into slang
    local r = pcall(lib.ft_name_of, func(i){ return "x" }, 1)
    assert(r[0] == "err")
    assert(str.index_of(r[1].message, "bad result of a callback") >= 0, r[1].message)
  }
  t.test("a callback kept by C, in a struct, is called later"){
    local total = 0
    lib.ft_set_handler({on_value: func(x){
      total = total + x
      return x * 10
    }, base: 100})
    assert(lib.ft_fire(1) == 1010 and lib.ft_fire(2) == 1020)
    assert(total == 203)
    lib.ft_set_handler({on_value: null, base: 0})
    assert(lib.ft_fire(1) == -1)
  }
  t.test("ffi.callback: an explicit one, by type name or C spelling"){
    local double = ffi.callback("IntFn", func(x){ return x * 2 }, C)
    assert(lib.ft_apply(double, 4) == 8)
    local triple = ffi.callback("int (*)(int)", func(x){ return x * 3 })
    assert(lib.ft_apply(triple, 4) == 12)
    assert(lib.ft_fire != null)
  }
  t.test("a callback can call C again"){
    local inner = func(x){ return x + 1 }
    assert(lib.ft_apply(func(x){ return lib.ft_apply(inner, x) * 2 }, 4) == 10)
  }
  t.test("an error in a callback is raised when the C call returns"){
    local r = pcall(lib.ft_apply, func(x){ error("bad ", x) }, 7)
    assert(r[0] == "err" and r[1].message == "bad 7", r[1].message)
    // an error in a nested callback goes up through the outer one
    r = pcall(lib.ft_apply, func(x){
      return lib.ft_apply(func(y){ error("inner") }, x)
    }, 1)
    assert(r[0] == "err" and r[1].message == "inner")
    // a callback can catch it
    assert(lib.ft_apply(func(x){
      try {
        lib.ft_apply(func(y){ error("caught") }, x)
      } catch(local e){
        return 99
      }
    }, 1) == 99)
    // a later call works
    assert(lib.ft_apply(func(x){ return x }, 3) == 3)
  }
  t.test("callbacks from other threads run one at a time"){
    local calls = 0
    local busy = false
    local overlapped = false
    local sum = lib.ft_threads(func(i){
      if(busy){
        overlapped = true
      }
      busy = true
      calls = calls + 1
      local s = 0
      for(local k = 0; k < 50; k = k + 1){
        s = s + k
      }
      busy = false
      return i * 2
    }, 8)
    assert(sum == 56, sum)
    assert(calls == 800, calls)
    assert(not overlapped)
  }
  t.test("callbacks on other threads that call C themselves"){
    // a C call inside lets the other threads' callbacks in: each thread's
    // calls stay on a stack of their own
    local inner = func(x){ return x + 1 }
    local sum = lib.ft_threads(func(i){
      local r = lib.ft_apply(inner, i * 2)
      local t = {i, r, lib.ft_apply(inner, r)}
      return t[2] - 2
    }, 8)
    assert(sum == 56, sum)
  }
  t.test("ffi.gc: what a pointer points to is freed once it is collected"){
    local before = lib.ft_freed()
    local func use(){
      local p = ffi.gc(lib.ft_alloc(7), lib.ft_free)
      assert(p[0] == 7)
      assert(lib.ft_freed() == before)
    }
    use()
    // garbage until a collection ran
    for(local i = 0; i < 400 and lib.ft_freed() == before; i = i + 1){
      local junk = {}
      for(local k = 0; k < 2000; k = k + 1){
        append(junk, concat("x", string(i), ":", string(k)))
      }
    }
    assert(lib.ft_freed() == before + 1, lib.ft_freed())
    // null takes the finalizer away: freed by hand instead
    local q = ffi.gc(lib.ft_alloc(1), lib.ft_free)
    assert(ffi.gc(q, null) == q)
    lib.ft_free(q)
    assert(lib.ft_freed() == before + 2)
    // slang's own memory, and functions of the wrong shape
    local r = pcall(ffi.gc, ffi.new("int", 1, C), lib.ft_free)
    assert(r[0] == "err" and str.index_of(r[1].message, "ffi.new") >= 0, r[1].message)
    r = pcall(ffi.gc, lib.ft_alloc(1), lib.ft_next)
    assert(r[0] == "err" and str.index_of(r[1].message, "one pointer") >= 0, r[1].message)
    r = pcall(ffi.gc, lib.ft_alloc(1), func(p){})
    assert(r[0] == "err" and str.index_of(r[1].message, "C function") >= 0, r[1].message)
  }
  t.test("ffi.gc: a buffer over the memory keeps it until the buffer goes"){
    local buffer = require("slang/buffer")
    local vm = require("slang/vm")
    local before = lib.ft_freed()
    // only the buffer's slice refers to the pointer
    local b = buffer.wrap(ffi.gc(lib.ft_alloc(9), lib.ft_free), 1, "int")
    b = b:slice(0, 1)
    vm.collect()
    assert(lib.ft_freed() == before, "freed while the buffer is alive")
    assert(b[0] == 9, b[0])
    b = null
    vm.collect()
    assert(lib.ft_freed() == before + 1, lib.ft_freed())
  }

  // last: it uses up the program's callbacks
  t.test("a function made anew on each pass is caught, not leaked"){
    local r = null
    for(local i = 0; i < 1100; i = i + 1){
      r = pcall(lib.ft_apply, func(x){ return x }, i)
      if(r[0] == "err"){
        break
      }
    }
    assert(r[0] == "err")
    assert(str.index_of(r[1].message, "ffi.callback") >= 0, r[1].message)
  }
}
