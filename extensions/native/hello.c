/*
 * hello: an example native extension in C, used by zig/test/native_test.slang
 * to exercise the whole of slang.h. Build: `zig build` in zig/ produces
 * zig-out/lib/hello.dylib (or .so); `require("hello")` finds it through
 * __PACKAGES.native_search_paths.
 */
#include <string.h>
#include <stdlib.h>
#include <pthread.h>
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

/* ---- slang buffers (slang/buffer): memory read and written in place ---- */

/* buffer_sum(buffer of float or double) -> the sum of its elements */
static int l_buffer_sum(slang_State *S) {
    size_t n = 0;
    void *mem = slang_checkbuffer(S, 1, &n, NULL);
    if (slang_failed(S)) return SLANG_ERROR;
    const char *type = slang_buffertype(S, 1);
    double sum = 0;
    if (strcmp(type, "float") == 0) {
        for (size_t i = 0; i < n; i++) sum += ((float *)mem)[i];
    } else if (strcmp(type, "double") == 0) {
        for (size_t i = 0; i < n; i++) sum += ((double *)mem)[i];
    } else {
        return slang_argerror(S, 1, "a buffer of float or double expected");
    }
    slang_pushdouble(S, sum);
    return 1;
}

/* ramp(n) -> a buffer of int32: 0, 1, ..., n - 1 */
static int l_ramp(slang_State *S) {
    int64_t n = slang_checkint(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    int32_t *mem = slang_newbuffer(S, "int32", (size_t)n);
    if (!mem) return SLANG_ERROR;
    for (int64_t i = 0; i < n; i++) mem[i] = (int32_t)i;
    return 1;
}

/* ---- isolates driven from a thread of our own ---- */

typedef struct drive_job {
    slang_State *I;
    int n;
    long long sum;
    int failed;
} drive_job;

static void *drive_thread(void *arg) {
    drive_job *job = arg;
    for (int i = 0; i < job->n; i++) {
        slang_pushvalue(job->I, 1);
        slang_pushint(job->I, i);
        if (slang_call(job->I, 1) != SLANG_OK) {
            job->failed = 1;
            break;
        }
        job->sum += slang_toint(job->I, -1);
        slang_pop(job->I, 1);
    }
    return NULL;
}

/* drive(f, n): sum of f(i) for i in 0..n-1, called in an isolate of its own
 * on a thread this extension starts (the way an audio callback runs slang) */
static int l_drive(slang_State *S) {
    slang_checkfunction(S, 1);
    int n = (int)slang_checkint(S, 2);
    if (slang_failed(S)) return SLANG_ERROR;
    drive_job job = {slang_isolate_new(S, 1), n, 0, 0};
    if (job.I == NULL) return SLANG_ERROR;
    pthread_t t;
    pthread_create(&t, NULL, drive_thread, &job);
    pthread_join(t, NULL);
    if (job.failed) {
        slang_error(S, "drive: %s", slang_errormessage(job.I));
        slang_close(job.I);
        return SLANG_ERROR;
    }
    slang_close(job.I);
    slang_pushint(S, job.sum);
    return 1;
}

/* the pump's thread: doubles the ints of channel 1 into channel 2 until
 * channel 1 is closed, then sends -1 */
static void *pump_thread(void *arg) {
    slang_State *I = arg;
    slang_geti(I, 1, 0);
    slang_geti(I, 1, 1);
    for (;;) {
        if (slang_receive(I, 2) != SLANG_OK || slang_isnull(I, -1)) break;
        int64_t v = slang_toint(I, -1);
        slang_pop(I, 1);
        slang_pushint(I, v * 2);
        if (slang_send(I, 3) != SLANG_OK) break;
    }
    slang_pushint(I, -1);
    slang_send(I, 3);
    slang_close(I);
    return NULL;
}

/* pump(in, out): starts a thread that serves the channels through the C API */
static int l_pump(slang_State *S) {
    slang_newtable(S);
    slang_pushvalue(S, 1);
    slang_append(S, -2);
    slang_pushvalue(S, 2);
    slang_append(S, -2);
    slang_State *I = slang_isolate_new(S, -1);
    if (I == NULL) return SLANG_ERROR;
    pthread_t t;
    pthread_create(&t, NULL, pump_thread, I);
    pthread_detach(t);
    return 0;
}

static const slang_Reg funcs[] = {
    {"drive", l_drive},
    {"pump", l_pump},
    {"buffer_sum", l_buffer_sum},
    {"ramp", l_ramp},
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
