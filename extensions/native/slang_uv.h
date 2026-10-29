/*
 * slang_uv.h: the C API the uv extension offers other native extensions, so
 * that they can run blocking C code on libuv's thread pool and deliver the
 * result to a slang callback on the loop thread.
 *
 * The VM is single-threaded: work functions run on a pool thread and must
 * not touch slang at all; only push runs on the loop thread, with the state
 * that runs uv.run(). An extension gets the API from require("uv").c_api:
 *
 *   slang_getglobal(S, "require");
 *   slang_pushstring(S, "uv");
 *   slang_call(S, 1);                       // the uv module
 *   slang_getfield(S, -1, "c_api");
 *   const slang_uv_api *api = slang_uv_get(S, -1);
 *
 * and does not link libuv itself.
 */
#ifndef SLANG_UV_H
#define SLANG_UV_H

#include "slang.h"

#define SLANG_UV_API_VERSION 1
#define SLANG_UV_API_TNAME "uv.c_api"

typedef struct slang_uv_api {
    int version; /* SLANG_UV_API_VERSION */
    /*
     * Queues work(data) on the thread pool. Afterwards, on the loop thread,
     * push(S, data) pushes the arguments for the callback at stack index
     * cb_idx of the caller (by convention err and value, so two) and returns
     * how many it pushed; the callback is then called with them. done(data)
     * runs last in every case, also when the loop stopped on an error or the
     * work was cancelled, and frees what data holds. The value at keep_idx
     * (0 for none) stays alive until then, so a userdata that work uses
     * cannot be collected under it. Returns 0, or raises (returns
     * SLANG_ERROR) when the work cannot be queued, after calling done.
     */
    int (*queue)(slang_State *S, int cb_idx, int keep_idx,
                 void (*work)(void *data),
                 int (*push)(slang_State *S, void *data),
                 void (*done)(void *data),
                 void *data);
} slang_uv_api;

/* The API in the uv.c_api userdata at idx, or NULL. */
static inline const slang_uv_api *slang_uv_get(slang_State *S, int idx) {
    const slang_uv_api **box = (const slang_uv_api **)slang_testudata(S, idx, SLANG_UV_API_TNAME);
    if (box == NULL || *box == NULL || (*box)->version != SLANG_UV_API_VERSION) return NULL;
    return *box;
}

#endif
