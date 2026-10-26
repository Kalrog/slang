/*
 * hello: an example native extension in C, used by zig/test/native_test.slang
 * to exercise the whole of slang.h. Build: `zig build` in zig/ produces
 * zig-out/lib/hello.dylib (or .so); `require("hello")` finds it through
 * __PACKAGES.nativeSearchPaths.
 */
#include <string.h>
#include <stdlib.h>
#include "slang.h"

/* add(a, b): numbers, with argument checks */
static int l_add(slang_State *S) {
    double a = slang_checknumber(S, 1);
    double b = slang_checknumber(S, 2);
    if (slang_failed(S)) return SLANG_ERROR;
    if (slang_isint(S, 1) && slang_isint(S, 2)) {
        slang_pushint(S, slang_toint(S, 1) + slang_toint(S, 2));
    } else {
        slang_pushdouble(S, a + b);
    }
    return 1;
}

/* greet(name): string handling and formatting */
static int l_greet(slang_State *S) {
    const char *name = slang_optstring(S, 1, "world");
    slang_pushfstring(S, "hello, %s!", name);
    return 1;
}

/* fail(msg): raises an error with a formatted message */
static int l_fail(slang_State *S) {
    const char *msg = slang_checkstring(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    return slang_error(S, "failed: %s", msg);
}

/* apply(f, x): calls back into slang; errors propagate unchanged */
static int l_apply(slang_State *S) {
    slang_checkfunction(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    slang_pushvalue(S, 1);
    slang_pushvalue(S, 2);
    if (slang_call(S, 1) != SLANG_OK) return SLANG_ERROR;
    return 1;
}

/* try(f): calls f and returns {"ok", result} or {"err", message} */
static int l_try(slang_State *S) {
    slang_pushvalue(S, 1);
    slang_newtable(S); /* the result table, below the call */
    slang_insert(S, -2);
    if (slang_call(S, 0) == SLANG_OK) {
        slang_pushstring(S, "ok");
        slang_append(S, -3);
        slang_append(S, -2);
    } else {
        slang_pushstring(S, "err");
        slang_append(S, -2);
        slang_pushstring(S, slang_errormessage(S));
        slang_clearerror(S);
        slang_append(S, -2);
    }
    return 1;
}

/* sum(t): iterates a table with slang_next */
static int l_sum(slang_State *S) {
    slang_checktable(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    double total = 0;
    slang_pushnull(S);
    while (slang_next(S, 1)) {
        total += slang_todouble(S, -1);
        slang_pop(S, 1); /* keep the key for the next round */
    }
    slang_pushdouble(S, total);
    return 1;
}

/* keys(t): the keys of a table, through the generic access functions */
static int l_keys(slang_State *S) {
    slang_checktable(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    slang_newtable(S);
    slang_pushnull(S);
    while (slang_next(S, 1)) {
        slang_pop(S, 1);
        slang_pushvalue(S, -1);
        slang_append(S, 2);
    }
    return 1;
}

/* make_point(x, y): a table with fields and a __tostring metamethod */
static int point_tostring(slang_State *S) {
    slang_getfield(S, 1, "x");
    slang_getfield(S, 1, "y");
    slang_pushfstring(S, "(%lld, %lld)", (long long)slang_toint(S, -2), (long long)slang_toint(S, -1));
    return 1;
}

static int l_make_point(slang_State *S) {
    int64_t x = slang_checkint(S, 1);
    int64_t y = slang_checkint(S, 2);
    if (slang_failed(S)) return SLANG_ERROR;
    slang_newtable(S);
    slang_pushint(S, x);
    slang_setfield(S, -2, "x");
    slang_pushint(S, y);
    slang_setfield(S, -2, "y");
    slang_newtable(S);
    slang_pushcfunction(S, point_tostring, "point_tostring");
    slang_setfield(S, -2, "__tostring");
    slang_pushstring(S, "point");
    slang_setfield(S, -2, "__type");
    slang_setmetatable(S, -2);
    return 1;
}

/* counter(start): a C closure with an upvalue */
static int counter_next(slang_State *S) {
    int64_t n = slang_toint(S, slang_upvalueindex(1));
    slang_pushint(S, n + 1);
    slang_copy(S, -1, slang_upvalueindex(1));
    return 1;
}

static int l_counter(slang_State *S) {
    slang_pushint(S, slang_optint(S, 1, 0));
    slang_pushcclosure(S, counter_next, "counter_next", 1);
    return 1;
}

/* A userdata type: a growable byte buffer with a finalizer. */
typedef struct {
    char *data;
    size_t len;
} buffer;

static int finalized = 0;

static void buffer_finalize(void *p) {
    buffer *b = p;
    free(b->data);
    finalized++;
}

static int buffer_push(slang_State *S) {
    buffer *b = slang_checkudata(S, 1, "hello.buffer");
    size_t len;
    const char *s = slang_checklstring(S, 2, &len);
    if (slang_failed(S)) return SLANG_ERROR;
    b->data = realloc(b->data, b->len + len);
    memcpy(b->data + b->len, s, len);
    b->len += len;
    return 0;
}

static int buffer_get(slang_State *S) {
    buffer *b = slang_checkudata(S, 1, "hello.buffer");
    if (slang_failed(S)) return SLANG_ERROR;
    slang_pushlstring(S, b->data ? b->data : "", b->len);
    return 1;
}

static int buffer_len(slang_State *S) {
    buffer *b = slang_checkudata(S, 1, "hello.buffer");
    if (slang_failed(S)) return SLANG_ERROR;
    slang_pushint(S, (int64_t)b->len);
    return 1;
}

static const slang_Reg buffer_methods[] = {
    {"push", buffer_push},
    {"get", buffer_get},
    {NULL, NULL},
};

static int buffer_meta_ref = SLANG_REFNULL;

static int l_buffer(slang_State *S) {
    buffer *b = slang_newuserdata(S, sizeof(buffer), "hello.buffer", buffer_finalize);
    b->data = NULL;
    b->len = 0;
    slang_getref(S, buffer_meta_ref);
    slang_setmetatable(S, -2);
    return 1;
}

static int l_finalized(slang_State *S) {
    slang_pushint(S, finalized);
    return 1;
}

/* stored(f): keeps a slang value alive in the registry and calls it later */
static int stored_ref = SLANG_REFNULL;

static int l_store(slang_State *S) {
    if (stored_ref != SLANG_REFNULL) slang_unref(S, stored_ref);
    slang_pushvalue(S, 1);
    stored_ref = slang_ref(S);
    return 0;
}

static int l_call_stored(slang_State *S) {
    slang_getref(S, stored_ref);
    slang_pushvalue(S, 1);
    if (slang_call(S, 1) != SLANG_OK) return SLANG_ERROR;
    return 1;
}

/* global_len(name): reads a global and uses len/type helpers */
static int l_describe_global(slang_State *S) {
    const char *name = slang_checkstring(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    slang_getglobal(S, name);
    if (slang_typeof(S, -1) != SLANG_OK) return SLANG_ERROR;
    if (slang_len(S, -2) != SLANG_OK) {
        slang_clearerror(S);
        slang_pushint(S, -1);
    }
    slang_pushfstring(S, "%s of length %lld", slang_tostring(S, -2), (long long)slang_toint(S, -1));
    return 1;
}

/* reraise(err): raises an error value unchanged (keeps its location) */
static int l_reraise(slang_State *S) {
    slang_pushvalue(S, 1);
    return slang_raise(S);
}

static const slang_Reg funcs[] = {
    {"add", l_add},
    {"greet", l_greet},
    {"fail", l_fail},
    {"apply", l_apply},
    {"try", l_try},
    {"sum", l_sum},
    {"keys", l_keys},
    {"make_point", l_make_point},
    {"counter", l_counter},
    {"buffer", l_buffer},
    {"finalized", l_finalized},
    {"store", l_store},
    {"call_stored", l_call_stored},
    {"describe_global", l_describe_global},
    {"reraise", l_reraise},
    {NULL, NULL},
};

SLANG_EXTENSION(hello) {
    /* the buffer metatable: methods through __index, a type name */
    slang_newtable(S);
    slang_newmodule(S, buffer_methods);
    slang_pushcfunction(S, buffer_len, "buffer_len");
    slang_setfield(S, -2, "len");
    slang_setfield(S, -2, "__index");
    slang_pushstring(S, "buffer");
    slang_setfield(S, -2, "__type");
    buffer_meta_ref = slang_ref(S);

    slang_newmodule(S, funcs);
    slang_pushstring(S, "1.0");
    slang_setfield(S, -2, "version");
    return 1;
}
