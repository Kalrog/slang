/*
 * uv: a native extension exposing libuv (https://libuv.org) to slang in the
 * callback style of luv: handles are userdata with methods, every operation
 * takes its callback last, and callbacks have the shape cb(err, value) with
 * err a string like "ECONNRESET: connection reset by peer" or null.
 *
 *   local uv = require("uv")
 *   local t = uv.timer()
 *   t:start(100, 0, func(){ print("tick") t:close() })
 *   uv.run()
 *
 * Every VM has a loop of its own, so isolates (slang/isolate) run event
 * loops side by side; handles cannot cross between them, and when an
 * isolate ends, what it left open is closed with its loop. Killing an
 * isolate wakes its loop, and uv.run raises "isolate killed".
 *
 * Callbacks run only from inside uv.run(); an error raised in one stops the
 * loop and comes out of uv.run(). An active handle (a running timer, a
 * listening or reading socket, a pending connect) keeps its userdata alive;
 * a handle that is collected before it was closed is closed by its finalizer.
 * slang/async builds Futures and Streams on top of this module.
 *
 * Handles: timer, tcp, pipe, signal (start(name, cb)), process (from
 * spawn(file, args, options, on_exit); pid, kill), poll (on a descriptor
 * another library owns) and async (async(cb): cb runs on the loop after a
 * wake from another thread, see slang_uv.h); every handle has close, is_active, is_closing,
 * ref, unref and has_ref. getaddrinfo resolves names. The fs_* functions
 * (read_file, write_file, stat, scandir, unlink, mkdir, rmdir, rename,
 * open, read, write, close) run libuv's file calls on its thread pool, the
 * same pool other extensions reach through uv.c_api (slang_uv.h).
 */
#include <uv.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "slang.h"
#include "slang_uv.h"

typedef struct handle {
    union {
        uv_handle_t handle;
        uv_stream_t stream;
        uv_timer_t timer;
        uv_tcp_t tcp;
        uv_pipe_t pipe;
        uv_signal_t signal;
        uv_process_t process;
        uv_poll_t poll;
        uv_async_t async;
    } u;
    int self_ref;    /* the userdata, while the handle is active or closing */
    int cb_ref;      /* timer, listen or read callback */
    int close_ref;   /* close callback */
    int closed;      /* uv_close was issued */
    int close_done;  /* and completed */
    int collected;   /* the userdata was finalized */
    int reading;
} handle;

/* Every VM (every isolate, see slang/isolate) has a loop of its own, made
 * when it opens the extension and kept in its extension data; libuv
 * objects reach it through their loop's data. run_S is the state running
 * the loop (callbacks enter the VM through it), run_failed whether a
 * callback failed (the loop is stopping, further callbacks are skipped). */
typedef struct uv_ctx {
    uv_loop_t loop;
    slang_State *run_S;
    int run_failed;
    uv_async_t hold;     /* keeps the loop alive for a GUI (api hold) */
    uv_async_t wake;     /* sent when the isolate is killed */
    int killed;          /* set by the wake (on the loop thread) */
} uv_ctx;

static const char ctx_key = 0;

static uv_ctx *get_ctx(slang_State *S) {
    return slang_getextdata(S, &ctx_key);
}

static uv_loop_t *loop_of(slang_State *S) {
    return &get_ctx(S)->loop;
}

#define CTX(loop_ptr) ((uv_ctx *)(loop_ptr)->data)

static void push_uv_error(slang_State *S, int status) {
    slang_pushfstring(S, "%s: %s", uv_err_name(status), uv_strerror(status));
}

/* ---- handle lifetime ---- */

static handle *check_handle(slang_State *S, int idx, const char *tname) {
    handle **box = slang_checkudata(S, idx, tname);
    if (box == NULL) return NULL;
    return *box;
}

/* a tcp or pipe handle (the stream methods are shared) */
static handle *check_stream(slang_State *S, int idx) {
    handle **box = slang_testudata(S, idx, "uv.tcp");
    if (box == NULL) box = slang_testudata(S, idx, "uv.pipe");
    if (box == NULL) {
        slang_argerror(S, idx, "uv.tcp or uv.pipe expected");
        return NULL;
    }
    return *box;
}


/* keeps the userdata at idx alive until release() */
static void retain(slang_State *S, handle *h, int idx) {
    if (h->self_ref != SLANG_REFNULL) return;
    slang_pushvalue(S, idx);
    h->self_ref = slang_ref(S);
}

static void release(slang_State *S, handle *h) {
    if (h->self_ref == SLANG_REFNULL) return;
    slang_unref(S, h->self_ref);
    h->self_ref = SLANG_REFNULL;
}

static void drop_ref(slang_State *S, int *ref) {
    if (*ref != SLANG_REFNULL) {
        slang_unref(S, *ref);
        *ref = SLANG_REFNULL;
    }
}

/* pushes the function of ref; false when there is none or the loop failed */
static int begin_callback(uv_ctx *cx, int ref) {
    if (cx->run_S == NULL || cx->run_failed || ref == SLANG_REFNULL) return 0;
    slang_getref(cx->run_S, ref);
    return 1;
}

/* calls the function pushed by begin_callback with nargs arguments */
static void finish_callback(uv_ctx *cx, int nargs) {
    if (slang_call(cx->run_S, nargs) != SLANG_OK) {
        cx->run_failed = 1;
        uv_stop(&cx->loop);
        return;
    }
    slang_pop(cx->run_S, 1);
}

static void on_close(uv_handle_t *uvh) {
    uv_ctx *cx = CTX(uvh->loop);
    handle *h = (handle *)uvh;
    h->close_done = 1;
    if (h->collected) {
        free(h);
        return;
    }
    if (cx->run_S != NULL) {
        if (begin_callback(cx, h->close_ref)) finish_callback(cx, 0);
        drop_ref(cx->run_S, &h->close_ref);
        drop_ref(cx->run_S, &h->cb_ref);
        release(cx->run_S, h);
    }
}

/* the userdata is gone: close the handle if needed, free the struct once closed */
static void handle_finalize(void *data) {
    handle *h = *(handle **)data;
    h->collected = 1;
    if (h->close_done) {
        free(h);
    } else if (!h->closed) {
        h->closed = 1;
        uv_close(&h->u.handle, on_close);
    }
}

static handle *new_handle(slang_State *S, const char *tname) {
    handle *h = calloc(1, sizeof(handle));
    h->self_ref = SLANG_REFNULL;
    h->cb_ref = SLANG_REFNULL;
    h->close_ref = SLANG_REFNULL;
    handle **box = slang_newuserdata(S, sizeof(handle *), tname, handle_finalize);
    *box = h;
    return h;
}

static int l_close(slang_State *S, const char *tname) {
    handle *h = check_handle(S, 1, tname);
    if (h == NULL) return SLANG_ERROR;
    if (h->closed) return 0;
    h->closed = 1;
    if (slang_isfunction(S, 2)) {
        slang_pushvalue(S, 2);
        h->close_ref = slang_ref(S);
    }
    retain(S, h, 1);
    uv_close(&h->u.handle, on_close);
    return 0;
}

static int l_is_closing(slang_State *S, const char *tname) {
    handle *h = check_handle(S, 1, tname);
    if (h == NULL) return SLANG_ERROR;
    slang_pushbool(S, h->closed);
    return 1;
}

static int l_is_active(slang_State *S, const char *tname) {
    handle *h = check_handle(S, 1, tname);
    if (h == NULL) return SLANG_ERROR;
    slang_pushbool(S, !h->closed && uv_is_active(&h->u.handle));
    return 1;
}

/* ---- methods every handle has ---- */

static const char *handle_tnames[] = {"uv.timer", "uv.tcp", "uv.pipe", "uv.signal", "uv.process", "uv.poll", "uv.async", NULL};

static handle *check_any(slang_State *S, int idx) {
    for (int i = 0; handle_tnames[i] != NULL; i++) {
        handle **box = slang_testudata(S, idx, handle_tnames[i]);
        if (box != NULL) return *box;
    }
    slang_argerror(S, idx, "uv handle expected");
    return NULL;
}

/* handle:unref(): the handle no longer keeps uv.run() going (a signal
 * watcher that should not stop the program from ending); ref() undoes it */
static int h_unref(slang_State *S) {
    handle *h = check_any(S, 1);
    if (h == NULL) return SLANG_ERROR;
    if (!h->closed) uv_unref(&h->u.handle);
    return 0;
}

static int h_ref(slang_State *S) {
    handle *h = check_any(S, 1);
    if (h == NULL) return SLANG_ERROR;
    if (!h->closed) uv_ref(&h->u.handle);
    return 0;
}

static int h_has_ref(slang_State *S) {
    handle *h = check_any(S, 1);
    if (h == NULL) return SLANG_ERROR;
    slang_pushbool(S, !h->closed && uv_has_ref(&h->u.handle));
    return 1;
}

#define HANDLE_METHODS {"ref", h_ref}, {"unref", h_unref}, {"has_ref", h_has_ref}

/* ---- loop ---- */

/* runs cx's loop through S: 1 when it has more to do, 0 when not,
 * SLANG_ERROR when a callback raised or the isolate is being killed */
static int run_loop(slang_State *S, uv_ctx *cx, uv_run_mode mode) {
    cx->run_S = S;
    cx->run_failed = 0;
    int more = uv_run(&cx->loop, mode);
    cx->run_S = NULL;
    if (cx->run_failed) {
        cx->run_failed = 0;
        return SLANG_ERROR;
    }
    if (cx->killed || slang_interrupted(S)) return slang_error(S, "isolate killed");
    return more != 0;
}

static int l_run(slang_State *S) {
    const char *mode_name = slang_optstring(S, 1, "default");
    uv_run_mode mode = UV_RUN_DEFAULT;
    if (strcmp(mode_name, "once") == 0) mode = UV_RUN_ONCE;
    else if (strcmp(mode_name, "nowait") == 0) mode = UV_RUN_NOWAIT;
    else if (strcmp(mode_name, "default") != 0) return slang_argerror(S, 1, "\"default\", \"once\" or \"nowait\" expected");
    uv_ctx *cx = get_ctx(S);
    if (cx->run_S != NULL) return slang_error(S, "uv.run is already running");
    int more = run_loop(S, cx, mode);
    if (more == SLANG_ERROR) return SLANG_ERROR; /* the callback's error is still pending */
    slang_pushbool(S, more != 0);
    return 1;
}

static int l_stop(slang_State *S) {
    uv_stop(loop_of(S));
    return 0;
}

static int l_now(slang_State *S) {
    slang_pushint(S, (int64_t)uv_now(loop_of(S)));
    return 1;
}

static int l_hrtime(slang_State *S) {
    slang_pushint(S, (int64_t)uv_hrtime());
    return 1;
}

static int l_loop_alive(slang_State *S) {
    slang_pushbool(S, uv_loop_alive(loop_of(S)) != 0);
    return 1;
}

static int l_version(slang_State *S) {
    slang_pushstring(S, uv_version_string());
    return 1;
}

/* ---- timers ---- */

static int l_timer(slang_State *S) {
    handle *h = new_handle(S, "uv.timer");
    uv_timer_init(loop_of(S), &h->u.timer);
    return 1;
}

static void on_timer(uv_timer_t *t) {
    uv_ctx *cx = CTX(t->loop);
    handle *h = (handle *)t;
    if (begin_callback(cx, h->cb_ref)) finish_callback(cx, 0);
    if (cx->run_S != NULL && !uv_is_active(&h->u.handle)) {
        /* a one-shot timer fired: nothing keeps it alive any more */
        drop_ref(cx->run_S, &h->cb_ref);
        release(cx->run_S, h);
    }
}

/* timer:start(timeout_ms, repeat_ms, cb) */
static int timer_start(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.timer");
    int64_t timeout = slang_checkint(S, 2);
    int64_t repeat = slang_optint(S, 3, 0);
    slang_checkfunction(S, 4);
    if (slang_failed(S)) return SLANG_ERROR;
    if (h->closed) return slang_error(S, "timer is closed");
    drop_ref(S, &h->cb_ref);
    slang_pushvalue(S, 4);
    h->cb_ref = slang_ref(S);
    retain(S, h, 1);
    int r = uv_timer_start(&h->u.timer, on_timer, (uint64_t)timeout, (uint64_t)repeat);
    if (r < 0) {
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

static int timer_stop(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.timer");
    if (h == NULL) return SLANG_ERROR;
    uv_timer_stop(&h->u.timer);
    drop_ref(S, &h->cb_ref);
    release(S, h);
    return 0;
}

static int timer_again(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.timer");
    if (h == NULL) return SLANG_ERROR;
    int r = uv_timer_again(&h->u.timer);
    if (r < 0) {
        push_uv_error(S, r);
        return slang_raise(S);
    }
    retain(S, h, 1);
    return 0;
}

static int timer_close(slang_State *S) { return l_close(S, "uv.timer"); }
static int timer_is_active(slang_State *S) { return l_is_active(S, "uv.timer"); }
static int timer_is_closing(slang_State *S) { return l_is_closing(S, "uv.timer"); }

static const slang_Reg timer_methods[] = {
    {"start", timer_start},
    {"stop", timer_stop},
    {"again", timer_again},
    {"close", timer_close},
    {"is_active", timer_is_active},
    {"is_closing", timer_is_closing},
    HANDLE_METHODS,
    {NULL, NULL},
};

/* ---- tcp ---- */

static int l_tcp(slang_State *S) {
    handle *h = new_handle(S, "uv.tcp");
    uv_tcp_init(loop_of(S), &h->u.tcp);
    return 1;
}

/* fills addr from host (IPv4 or IPv6 literal) and port */
static int parse_addr(slang_State *S, int host_idx, int port_idx, struct sockaddr_storage *addr) {
    const char *host = slang_checkstring(S, host_idx);
    int64_t port = slang_checkint(S, port_idx);
    if (slang_failed(S)) return -1;
    if (strchr(host, ':') != NULL) {
        if (uv_ip6_addr(host, (int)port, (struct sockaddr_in6 *)addr) == 0) return 0;
    } else if (uv_ip4_addr(host, (int)port, (struct sockaddr_in *)addr) == 0) {
        return 0;
    }
    slang_argerror(S, host_idx, "an IP address (not a host name) expected");
    return -1;
}

static int tcp_bind(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.tcp");
    struct sockaddr_storage addr;
    if (h == NULL || parse_addr(S, 2, 3, &addr) < 0) return SLANG_ERROR;
    int r = uv_tcp_bind(&h->u.tcp, (const struct sockaddr *)&addr, 0);
    if (r < 0) {
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

static void on_connection(uv_stream_t *server, int status) {
    uv_ctx *cx = CTX(server->loop);
    handle *h = (handle *)server;
    if (!begin_callback(cx, h->cb_ref)) return;
    if (status < 0) push_uv_error(cx->run_S, status); else slang_pushnull(cx->run_S);
    finish_callback(cx, 1);
}

/* server:listen(backlog, cb(err)) */
static int tcp_listen(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.tcp");
    int64_t backlog = slang_optint(S, 2, 128);
    slang_checkfunction(S, 3);
    if (slang_failed(S)) return SLANG_ERROR;
    drop_ref(S, &h->cb_ref);
    slang_pushvalue(S, 3);
    h->cb_ref = slang_ref(S);
    retain(S, h, 1);
    int r = uv_listen(&h->u.stream, (int)backlog, on_connection);
    if (r < 0) {
        drop_ref(S, &h->cb_ref);
        release(S, h);
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

/* server:accept(client) */
static int tcp_accept(slang_State *S) {
    handle *server = check_handle(S, 1, "uv.tcp");
    handle *client = check_stream(S, 2);
    if (server == NULL || client == NULL) return SLANG_ERROR;
    int r = uv_accept(&server->u.stream, &client->u.stream);
    if (r < 0) {
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

typedef struct {
    uv_connect_t req;
    int cb_ref;
    handle *h;
} connect_req;

static void on_connect(uv_connect_t *req, int status) {
    uv_ctx *cx = CTX(req->handle->loop);
    connect_req *c = (connect_req *)req;
    if (begin_callback(cx, c->cb_ref)) {
        if (status < 0) push_uv_error(cx->run_S, status); else slang_pushnull(cx->run_S);
        finish_callback(cx, 1);
    }
    if (cx->run_S != NULL) {
        drop_ref(cx->run_S, &c->cb_ref);
        release(cx->run_S, c->h);
    }
    free(c);
}

/* client:connect(host, port, cb(err)) */
static int tcp_connect(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.tcp");
    struct sockaddr_storage addr;
    if (h == NULL || parse_addr(S, 2, 3, &addr) < 0) return SLANG_ERROR;
    slang_checkfunction(S, 4);
    if (slang_failed(S)) return SLANG_ERROR;
    connect_req *c = calloc(1, sizeof(connect_req));
    c->h = h;
    slang_pushvalue(S, 4);
    c->cb_ref = slang_ref(S);
    retain(S, h, 1);
    int r = uv_tcp_connect(&c->req, &h->u.tcp, (const struct sockaddr *)&addr, on_connect);
    if (r < 0) {
        drop_ref(S, &c->cb_ref);
        release(S, h);
        free(c);
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

static void on_alloc(uv_handle_t *uvh, size_t suggested, uv_buf_t *buf) {
    (void)uvh;
    buf->base = malloc(suggested);
    buf->len = buf->base ? suggested : 0;
}

/* read callback: cb(err, chunk); chunk is null at end of stream */
static void on_read(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf) {
    uv_ctx *cx = CTX(stream->loop);
    handle *h = (handle *)stream;
    if (nread == 0) {
        free(buf->base);
        return;
    }
    if (begin_callback(cx, h->cb_ref)) {
        if (nread > 0) {
            slang_pushnull(cx->run_S);
            slang_pushlstring(cx->run_S, buf->base, (size_t)nread);
        } else if (nread == UV_EOF) {
            slang_pushnull(cx->run_S);
            slang_pushnull(cx->run_S);
        } else {
            push_uv_error(cx->run_S, (int)nread);
            slang_pushnull(cx->run_S);
        }
        finish_callback(cx, 2);
    }
    free(buf->base);
    if (nread < 0 && cx->run_S != NULL) {
        /* the stream ended: reading stops, nothing keeps the handle alive */
        uv_read_stop(stream);
        h->reading = 0;
        drop_ref(cx->run_S, &h->cb_ref);
        release(cx->run_S, h);
    }
}

/* stream:read_start(cb(err, chunk)) */
static int tcp_read_start(slang_State *S) {
    handle *h = check_stream(S, 1);
    slang_checkfunction(S, 2);
    if (h == NULL || slang_failed(S)) return SLANG_ERROR;
    if (h->closed) return slang_error(S, "stream is closed");
    drop_ref(S, &h->cb_ref);
    slang_pushvalue(S, 2);
    h->cb_ref = slang_ref(S);
    retain(S, h, 1);
    int r = uv_read_start(&h->u.stream, on_alloc, on_read);
    if (r < 0) {
        drop_ref(S, &h->cb_ref);
        release(S, h);
        push_uv_error(S, r);
        return slang_raise(S);
    }
    h->reading = 1;
    return 0;
}

static int tcp_read_stop(slang_State *S) {
    handle *h = check_stream(S, 1);
    if (h == NULL) return SLANG_ERROR;
    if (h->reading) {
        uv_read_stop(&h->u.stream);
        h->reading = 0;
        drop_ref(S, &h->cb_ref);
        release(S, h);
    }
    return 0;
}

typedef struct {
    uv_write_t req;
    int cb_ref;
    int self_ref;
    uv_buf_t buf;
} write_req;

static void on_write(uv_write_t *req, int status) {
    uv_ctx *cx = CTX(req->handle->loop);
    write_req *w = (write_req *)req;
    if (begin_callback(cx, w->cb_ref)) {
        if (status < 0) push_uv_error(cx->run_S, status); else slang_pushnull(cx->run_S);
        finish_callback(cx, 1);
    }
    if (cx->run_S != NULL) {
        drop_ref(cx->run_S, &w->cb_ref);
        drop_ref(cx->run_S, &w->self_ref);
    }
    free(w->buf.base);
    free(w);
}

/* stream:write(data, cb(err)); the data is copied */
static int tcp_write(slang_State *S) {
    handle *h = check_stream(S, 1);
    size_t len = 0;
    const char *data = slang_checkbytes(S, 2, &len);
    if (h == NULL || slang_failed(S)) return SLANG_ERROR;
    if (h->closed) return slang_error(S, "stream is closed");
    write_req *w = calloc(1, sizeof(write_req));
    w->cb_ref = SLANG_REFNULL;
    w->buf.base = malloc(len > 0 ? len : 1);
    memcpy(w->buf.base, data, len);
    w->buf.len = len;
    if (slang_isfunction(S, 3)) {
        slang_pushvalue(S, 3);
        w->cb_ref = slang_ref(S);
    }
    /* the handle must survive until the write completes */
    slang_pushvalue(S, 1);
    w->self_ref = slang_ref(S);
    int r = uv_write(&w->req, &h->u.stream, &w->buf, 1, on_write);
    if (r < 0) {
        drop_ref(S, &w->cb_ref);
        drop_ref(S, &w->self_ref);
        free(w->buf.base);
        free(w);
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

typedef struct {
    uv_shutdown_t req;
    int cb_ref;
    int self_ref;
} shutdown_req;

static void on_shutdown(uv_shutdown_t *req, int status) {
    uv_ctx *cx = CTX(req->handle->loop);
    shutdown_req *s = (shutdown_req *)req;
    if (begin_callback(cx, s->cb_ref)) {
        if (status < 0) push_uv_error(cx->run_S, status); else slang_pushnull(cx->run_S);
        finish_callback(cx, 1);
    }
    if (cx->run_S != NULL) {
        drop_ref(cx->run_S, &s->cb_ref);
        drop_ref(cx->run_S, &s->self_ref);
    }
    free(s);
}

/* stream:shutdown(cb(err)): closes the write side after pending writes */
static int tcp_shutdown(slang_State *S) {
    handle *h = check_stream(S, 1);
    if (h == NULL) return SLANG_ERROR;
    shutdown_req *s = calloc(1, sizeof(shutdown_req));
    s->cb_ref = SLANG_REFNULL;
    if (slang_isfunction(S, 2)) {
        slang_pushvalue(S, 2);
        s->cb_ref = slang_ref(S);
    }
    slang_pushvalue(S, 1);
    s->self_ref = slang_ref(S);
    int r = uv_shutdown(&s->req, &h->u.stream, on_shutdown);
    if (r < 0) {
        drop_ref(S, &s->cb_ref);
        drop_ref(S, &s->self_ref);
        free(s);
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

static void push_sockaddr(slang_State *S, const struct sockaddr_storage *addr) {
    char ip[64] = "";
    int port = 0;
    const char *family = "unknown";
    if (addr->ss_family == AF_INET) {
        const struct sockaddr_in *a = (const struct sockaddr_in *)addr;
        uv_ip4_name(a, ip, sizeof ip);
        port = ntohs(a->sin_port);
        family = "ipv4";
    } else if (addr->ss_family == AF_INET6) {
        const struct sockaddr_in6 *a = (const struct sockaddr_in6 *)addr;
        uv_ip6_name(a, ip, sizeof ip);
        port = ntohs(a->sin6_port);
        family = "ipv6";
    }
    slang_newtable(S);
    slang_pushstring(S, ip);
    slang_setfield(S, -2, "ip");
    slang_pushint(S, port);
    slang_setfield(S, -2, "port");
    slang_pushstring(S, family);
    slang_setfield(S, -2, "family");
}

static int tcp_getsockname(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.tcp");
    if (h == NULL) return SLANG_ERROR;
    struct sockaddr_storage addr;
    int len = sizeof addr;
    int r = uv_tcp_getsockname(&h->u.tcp, (struct sockaddr *)&addr, &len);
    if (r < 0) {
        push_uv_error(S, r);
        return slang_raise(S);
    }
    push_sockaddr(S, &addr);
    return 1;
}

static int tcp_getpeername(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.tcp");
    if (h == NULL) return SLANG_ERROR;
    struct sockaddr_storage addr;
    int len = sizeof addr;
    int r = uv_tcp_getpeername(&h->u.tcp, (struct sockaddr *)&addr, &len);
    if (r < 0) {
        push_uv_error(S, r);
        return slang_raise(S);
    }
    push_sockaddr(S, &addr);
    return 1;
}

static int tcp_nodelay(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.tcp");
    if (h == NULL) return SLANG_ERROR;
    uv_tcp_nodelay(&h->u.tcp, slang_tobool(S, 2));
    return 0;
}

static int tcp_keepalive(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.tcp");
    if (h == NULL) return SLANG_ERROR;
    uv_tcp_keepalive(&h->u.tcp, slang_tobool(S, 2), (unsigned)slang_optint(S, 3, 60));
    return 0;
}

/* stream:fileno(): the OS file descriptor (for poll, or a library that
 * wants it) */
static int stream_fileno(slang_State *S) {
    handle *h = check_stream(S, 1);
    if (h == NULL) return SLANG_ERROR;
    uv_os_fd_t fd;
    int r = uv_fileno(&h->u.handle, &fd);
    if (r < 0) {
        push_uv_error(S, r);
        return slang_raise(S);
    }
    slang_pushint(S, (int64_t)fd);
    return 1;
}

static int tcp_close(slang_State *S) { return l_close(S, "uv.tcp"); }
static int tcp_is_active(slang_State *S) { return l_is_active(S, "uv.tcp"); }
static int tcp_is_closing(slang_State *S) { return l_is_closing(S, "uv.tcp"); }

/* ---- pipes (stdin/stdout and named pipes; the stream methods are shared) ---- */

static int l_pipe(slang_State *S) {
    handle *h = new_handle(S, "uv.pipe");
    uv_pipe_init(loop_of(S), &h->u.pipe, 0);
    return 1;
}

/* pipe:open(fd): takes over an existing file descriptor (0 for stdin, 1 for stdout) */
static int pipe_open(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.pipe");
    int64_t fd = slang_checkint(S, 2);
    if (h == NULL || slang_failed(S)) return SLANG_ERROR;
    int r = uv_pipe_open(&h->u.pipe, (uv_file)fd);
    if (r < 0) {
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

static int pipe_close(slang_State *S) { return l_close(S, "uv.pipe"); }
static int pipe_is_active(slang_State *S) { return l_is_active(S, "uv.pipe"); }
static int pipe_is_closing(slang_State *S) { return l_is_closing(S, "uv.pipe"); }

static const slang_Reg pipe_methods[] = {
    {"open", pipe_open},
    {"read_start", tcp_read_start},
    {"read_stop", tcp_read_stop},
    {"write", tcp_write},
    {"shutdown", tcp_shutdown},
    {"close", pipe_close},
    {"is_active", pipe_is_active},
    {"is_closing", pipe_is_closing},
    {"fileno", stream_fileno},
    HANDLE_METHODS,
    {NULL, NULL},
};

static const slang_Reg tcp_methods[] = {
    {"bind", tcp_bind},
    {"listen", tcp_listen},
    {"accept", tcp_accept},
    {"connect", tcp_connect},
    {"read_start", tcp_read_start},
    {"read_stop", tcp_read_stop},
    {"write", tcp_write},
    {"shutdown", tcp_shutdown},
    {"getsockname", tcp_getsockname},
    {"getpeername", tcp_getpeername},
    {"nodelay", tcp_nodelay},
    {"keepalive", tcp_keepalive},
    {"close", tcp_close},
    {"is_active", tcp_is_active},
    {"is_closing", tcp_is_closing},
    {"fileno", stream_fileno},
    HANDLE_METHODS,
    {NULL, NULL},
};

/* ---- the thread pool (C work only; see slang_uv.h) ---- */

typedef struct work_req {
    uv_work_t req;
    int cb_ref;
    int keep_ref;
    void (*work)(void *);
    int (*push)(slang_State *, void *);
    void (*done)(void *);
    void *data;
} work_req;

static void work_run(uv_work_t *req) {
    work_req *w = (work_req *)req;
    w->work(w->data);
}

static void work_after(uv_work_t *req, int status) {
    uv_ctx *cx = CTX(req->loop);
    work_req *w = (work_req *)req;
    if (begin_callback(cx, w->cb_ref)) {
        int n = 2;
        if (status < 0) {
            push_uv_error(cx->run_S, status);
            slang_pushnull(cx->run_S);
        } else {
            n = w->push(cx->run_S, w->data);
        }
        finish_callback(cx, n);
    }
    w->done(w->data);
    if (cx->run_S != NULL) {
        drop_ref(cx->run_S, &w->cb_ref);
        drop_ref(cx->run_S, &w->keep_ref);
    }
    free(w);
}

static int api_queue(slang_State *S, int cb_idx, int keep_idx,
                     void (*work)(void *), int (*push)(slang_State *, void *),
                     void (*done)(void *), void *data) {
    if (!slang_isfunction(S, cb_idx)) {
        done(data);
        return slang_argerror(S, cb_idx, "callback expected");
    }
    work_req *w = calloc(1, sizeof(work_req));
    w->work = work;
    w->push = push;
    w->done = done;
    w->data = data;
    slang_pushvalue(S, cb_idx);
    w->cb_ref = slang_ref(S);
    w->keep_ref = SLANG_REFNULL;
    if (keep_idx != 0) {
        slang_pushvalue(S, keep_idx);
        w->keep_ref = slang_ref(S);
    }
    int r = uv_queue_work(loop_of(S), &w->req, work_run, work_after);
    if (r < 0) {
        drop_ref(S, &w->cb_ref);
        drop_ref(S, &w->keep_ref);
        done(data);
        free(w);
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

static int api_run(slang_State *S, int mode) {
    uv_ctx *cx = get_ctx(S);
    if (cx->run_S != NULL) return 0;
    return run_loop(S, cx, mode == 2 ? UV_RUN_NOWAIT : mode == 1 ? UV_RUN_ONCE : UV_RUN_DEFAULT);
}

static int api_backend_fd_of(slang_State *S) { return uv_backend_fd(loop_of(S)); }
static int api_backend_timeout_of(slang_State *S) { return uv_backend_timeout(loop_of(S)); }

static void api_hold_of(slang_State *S, int on) {
    uv_ctx *cx = get_ctx(S);
    if (on) uv_ref((uv_handle_t *)&cx->hold);
    else uv_unref((uv_handle_t *)&cx->hold);
}

/* the version 2 and 3 functions, which name no state: the loop of the
 * first VM that opened the extension (the main program's, normally) */
static uv_ctx *first_ctx = NULL;

static int api_backend_fd(void) { return first_ctx ? uv_backend_fd(&first_ctx->loop) : -1; }
static int api_backend_timeout(void) { return first_ctx ? uv_backend_timeout(&first_ctx->loop) : -1; }

static void api_hold(int on) {
    if (first_ctx == NULL) return;
    if (on) uv_ref((uv_handle_t *)&first_ctx->hold);
    else uv_unref((uv_handle_t *)&first_ctx->hold);
}

/* ---- async handles: woken from other threads ---- */

static void on_async(uv_async_t *a) {
    uv_ctx *cx = CTX(a->loop);
    handle *h = (handle *)a;
    if (begin_callback(cx, h->cb_ref)) finish_callback(cx, 0);
}

/* async(cb): a handle whose cb runs on the loop after a wake (through the C
 * API's async_send, from any thread). It keeps the loop running until it
 * is closed. */
static int l_async(slang_State *S) {
    slang_checkfunction(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    handle *h = new_handle(S, "uv.async");
    int r = uv_async_init(loop_of(S), &h->u.async, on_async);
    if (r < 0) {
        h->closed = h->close_done = 1;
        push_uv_error(S, r);
        return slang_raise(S);
    }
    slang_pushvalue(S, 1);
    h->cb_ref = slang_ref(S);
    retain(S, h, -1);
    return 1;
}

static int async_close(slang_State *S) { return l_close(S, "uv.async"); }
static int async_is_active(slang_State *S) { return l_is_active(S, "uv.async"); }
static int async_is_closing(slang_State *S) { return l_is_closing(S, "uv.async"); }

static const slang_Reg async_methods[] = {
    {"close", async_close},
    {"is_active", async_is_active},
    {"is_closing", async_is_closing},
    HANDLE_METHODS,
    {NULL, NULL},
};

static void *api_async_handle(slang_State *S, int idx) {
    handle **box = slang_testudata(S, idx, "uv.async");
    if (box == NULL || (*box)->closed) return NULL;
    return &(*box)->u.async;
}

static int api_async_send(void *h) { return uv_async_send((uv_async_t *)h); }

static const slang_uv_api the_api = {
    SLANG_UV_API_VERSION, api_queue, api_run, api_backend_fd, api_backend_timeout, api_hold,
    api_async_handle, api_async_send, api_backend_fd_of, api_backend_timeout_of, api_hold_of,
};

/* ---- file system: libuv's synchronous calls, run on the pool ---- */

enum {
    FS_READ_FILE, FS_WRITE_FILE, FS_STAT, FS_UNLINK, FS_MKDIR, FS_RMDIR,
    FS_RENAME, FS_SCANDIR, FS_OPEN, FS_READ, FS_WRITE, FS_CLOSE
};

typedef struct fs_job {
    int op;
    uv_loop_t *loop;
    char *path, *path2;
    char *data;       /* bytes to write, or the bytes read */
    size_t len;
    int flags, mode;
    int64_t fd, offset;
    /* results */
    int failed;
    char err[600];
    int64_t result;
    uv_stat_t st;
    char **names;
    int *types;
    int count;
} fs_job;

static const char *fs_op_name(int op) {
    static const char *names[] = {"read_file", "write_file", "stat", "unlink", "mkdir", "rmdir",
                                  "rename", "scandir", "open", "read", "write", "close"};
    return names[op];
}

/* records a libuv error; false when r is not one */
static int fs_failed(fs_job *j, int64_t r) {
    if (r >= 0) return 0;
    j->failed = 1;
    if (j->path != NULL)
        snprintf(j->err, sizeof j->err, "%s: %s, %s '%s'", uv_err_name((int)r), uv_strerror((int)r), fs_op_name(j->op), j->path);
    else
        snprintf(j->err, sizeof j->err, "%s: %s, %s", uv_err_name((int)r), uv_strerror((int)r), fs_op_name(j->op));
    return 1;
}

static int64_t fs_open_sync(fs_job *j, const char *path, int flags, int mode) {
    uv_fs_t r;
    int64_t fd = uv_fs_open(j->loop, &r, path, flags, mode, NULL);
    uv_fs_req_cleanup(&r);
    return fd;
}

static void fs_close_sync(fs_job *j, uv_file fd) {
    uv_fs_t r;
    uv_fs_close(j->loop, &r, fd, NULL);
    uv_fs_req_cleanup(&r);
}

/* reads len bytes (or to the end when len < 0) from fd at offset (-1: the
 * current position) into j->data */
static void fs_read_into(fs_job *j, uv_file fd, int64_t len, int64_t offset) {
    size_t cap = len >= 0 ? (size_t)len : 64 * 1024;
    size_t got = 0;
    j->data = malloc(cap > 0 ? cap : 1);
    for (;;) {
        if (len >= 0 && got >= (size_t)len) break;
        if (got == cap) {
            cap *= 2;
            j->data = realloc(j->data, cap);
        }
        uv_buf_t b = uv_buf_init(j->data + got, (unsigned)(cap - got));
        uv_fs_t r;
        int64_t n = uv_fs_read(j->loop, &r, fd, &b, 1, offset < 0 ? -1 : offset + (int64_t)got, NULL);
        uv_fs_req_cleanup(&r);
        if (fs_failed(j, n)) return;
        if (n == 0) break;
        got += (size_t)n;
    }
    j->len = got;
}

static void fs_write_all(fs_job *j, uv_file fd, int64_t offset) {
    size_t done = 0;
    while (done < j->len) {
        uv_buf_t b = uv_buf_init(j->data + done, (unsigned)(j->len - done));
        uv_fs_t r;
        int64_t n = uv_fs_write(j->loop, &r, fd, &b, 1, offset < 0 ? -1 : offset + (int64_t)done, NULL);
        uv_fs_req_cleanup(&r);
        if (fs_failed(j, n)) return;
        done += (size_t)n;
    }
    j->result = (int64_t)done;
}

static void fs_work(void *data) {
    fs_job *j = data;
    uv_fs_t r;
    int64_t n;
    switch (j->op) {
    case FS_READ_FILE: {
        int64_t fd = fs_open_sync(j, j->path, UV_FS_O_RDONLY, 0);
        if (fs_failed(j, fd)) return;
        /* to the end, not to the size stat reports (0 for /proc files) */
        fs_read_into(j, (uv_file)fd, -1, -1);
        fs_close_sync(j, (uv_file)fd);
        return;
    }
    case FS_WRITE_FILE: {
        int64_t fd = fs_open_sync(j, j->path, j->flags, 0644);
        if (fs_failed(j, fd)) return;
        fs_write_all(j, (uv_file)fd, -1);
        fs_close_sync(j, (uv_file)fd);
        return;
    }
    case FS_STAT:
        n = uv_fs_stat(j->loop, &r, j->path, NULL);
        if (!fs_failed(j, n)) j->st = r.statbuf;
        break;
    case FS_UNLINK:
        n = uv_fs_unlink(j->loop, &r, j->path, NULL);
        fs_failed(j, n);
        break;
    case FS_MKDIR:
        n = uv_fs_mkdir(j->loop, &r, j->path, 0755, NULL);
        fs_failed(j, n);
        break;
    case FS_RMDIR:
        n = uv_fs_rmdir(j->loop, &r, j->path, NULL);
        fs_failed(j, n);
        break;
    case FS_RENAME:
        n = uv_fs_rename(j->loop, &r, j->path, j->path2, NULL);
        fs_failed(j, n);
        break;
    case FS_SCANDIR: {
        n = uv_fs_scandir(j->loop, &r, j->path, 0, NULL);
        if (fs_failed(j, n)) break;
        j->names = calloc((size_t)n + 1, sizeof(char *));
        j->types = calloc((size_t)n + 1, sizeof(int));
        uv_dirent_t ent;
        while (uv_fs_scandir_next(&r, &ent) != UV_EOF && j->count < n) {
            j->names[j->count] = strdup(ent.name);
            j->types[j->count] = ent.type;
            j->count++;
        }
        break;
    }
    case FS_OPEN:
        j->result = fs_open_sync(j, j->path, j->flags, j->mode);
        fs_failed(j, j->result);
        return;
    case FS_READ:
        fs_read_into(j, (uv_file)j->fd, (int64_t)j->len, j->offset);
        return;
    case FS_WRITE:
        fs_write_all(j, (uv_file)j->fd, j->offset);
        return;
    case FS_CLOSE:
        n = uv_fs_close(j->loop, &r, (uv_file)j->fd, NULL);
        fs_failed(j, n);
        break;
    }
    uv_fs_req_cleanup(&r);
}

static double timespec_seconds(uv_timespec_t t) {
    return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

static const char *dirent_type(int t) {
    switch (t) {
    case UV_DIRENT_FILE: return "file";
    case UV_DIRENT_DIR: return "dir";
    case UV_DIRENT_LINK: return "link";
    case UV_DIRENT_UNKNOWN: return "unknown";
    default: return "other";
    }
}

static int fs_push(slang_State *S, void *data) {
    fs_job *j = data;
    if (j->failed) {
        slang_pushstring(S, j->err);
        slang_pushnull(S);
        return 2;
    }
    slang_pushnull(S);
    switch (j->op) {
    case FS_READ_FILE:
    case FS_READ:
        slang_pushlstring(S, j->data ? j->data : "", j->len);
        break;
    case FS_STAT:
        slang_newtable(S);
        slang_pushint(S, (int64_t)j->st.st_size);
        slang_setfield(S, -2, "size");
        slang_pushint(S, (int64_t)j->st.st_mode);
        slang_setfield(S, -2, "mode");
        slang_pushdouble(S, timespec_seconds(j->st.st_mtim));
        slang_setfield(S, -2, "mtime");
        slang_pushdouble(S, timespec_seconds(j->st.st_atim));
        slang_setfield(S, -2, "atime");
        slang_pushdouble(S, timespec_seconds(j->st.st_ctim));
        slang_setfield(S, -2, "ctime");
        slang_pushbool(S, (j->st.st_mode & S_IFMT) == S_IFREG);
        slang_setfield(S, -2, "is_file");
        slang_pushbool(S, (j->st.st_mode & S_IFMT) == S_IFDIR);
        slang_setfield(S, -2, "is_dir");
        break;
    case FS_SCANDIR:
        slang_newtable(S);
        for (int i = 0; i < j->count; i++) {
            slang_newtable(S);
            slang_pushstring(S, j->names[i]);
            slang_setfield(S, -2, "name");
            slang_pushstring(S, dirent_type(j->types[i]));
            slang_setfield(S, -2, "type");
            slang_append(S, -2);
        }
        break;
    case FS_OPEN:
    case FS_WRITE:
        slang_pushint(S, j->result);
        break;
    default:
        slang_pushnull(S);
        break;
    }
    return 2;
}

static void fs_done(void *data) {
    fs_job *j = data;
    free(j->path);
    free(j->path2);
    free(j->data);
    for (int i = 0; i < j->count; i++) free(j->names[i]);
    free(j->names);
    free(j->types);
    free(j);
}

static fs_job *new_job(int op) {
    fs_job *j = calloc(1, sizeof(fs_job));
    j->op = op;
    j->offset = -1;
    return j;
}

static char *dup_arg(slang_State *S, int idx, size_t *len) {
    size_t n = 0;
    const char *s = slang_checkbytes(S, idx, &n);
    if (s == NULL) return NULL;
    char *d = malloc(n + 1);
    memcpy(d, s, n);
    d[n] = 0;
    if (len) *len = n;
    return d;
}

/* queues j with the callback in the last argument */
static int fs_queue(slang_State *S, fs_job *j) {
    if (slang_failed(S)) {
        fs_done(j);
        return SLANG_ERROR;
    }
    j->loop = loop_of(S);
    return api_queue(S, slang_gettop(S), 0, fs_work, fs_push, fs_done, j);
}

/* fs_read_file(path, cb(err, data)) */
static int l_fs_read_file(slang_State *S) {
    fs_job *j = new_job(FS_READ_FILE);
    j->path = dup_arg(S, 1, NULL);
    return fs_queue(S, j);
}

/* fs_write_file(path, data, [append], cb(err)): creates or replaces the
 * file, or appends to it */
static int l_fs_write_file(slang_State *S) {
    fs_job *j = new_job(FS_WRITE_FILE);
    j->path = dup_arg(S, 1, NULL);
    j->data = dup_arg(S, 2, &j->len);
    int append = slang_gettop(S) > 3 && slang_tobool(S, 3);
    j->flags = UV_FS_O_WRONLY | UV_FS_O_CREAT | (append ? UV_FS_O_APPEND : UV_FS_O_TRUNC);
    return fs_queue(S, j);
}

/* fs_stat(path, cb(err, {size, mode, mtime, atime, ctime, is_file, is_dir})) */
static int l_fs_stat(slang_State *S) {
    fs_job *j = new_job(FS_STAT);
    j->path = dup_arg(S, 1, NULL);
    return fs_queue(S, j);
}

static int path_op(slang_State *S, int op) {
    fs_job *j = new_job(op);
    j->path = dup_arg(S, 1, NULL);
    return fs_queue(S, j);
}

static int l_fs_unlink(slang_State *S) { return path_op(S, FS_UNLINK); }
static int l_fs_mkdir(slang_State *S) { return path_op(S, FS_MKDIR); }
static int l_fs_rmdir(slang_State *S) { return path_op(S, FS_RMDIR); }
/* fs_scandir(path, cb(err, list of {name, type})) */
static int l_fs_scandir(slang_State *S) { return path_op(S, FS_SCANDIR); }

static int l_fs_rename(slang_State *S) {
    fs_job *j = new_job(FS_RENAME);
    j->path = dup_arg(S, 1, NULL);
    j->path2 = dup_arg(S, 2, NULL);
    return fs_queue(S, j);
}

/* fs_open(path, flags, cb(err, fd)): flags as in fopen: "r", "r+", "w",
 * "w+", "a", "a+", and "wx"/"w+x" to fail when the file exists */
static int l_fs_open(slang_State *S) {
    const char *f = slang_checklstring(S, 2, NULL);
    int flags = -1;
    if (f != NULL) {
        if (strcmp(f, "r") == 0) flags = UV_FS_O_RDONLY;
        else if (strcmp(f, "r+") == 0) flags = UV_FS_O_RDWR;
        else if (strcmp(f, "w") == 0) flags = UV_FS_O_WRONLY | UV_FS_O_CREAT | UV_FS_O_TRUNC;
        else if (strcmp(f, "w+") == 0) flags = UV_FS_O_RDWR | UV_FS_O_CREAT | UV_FS_O_TRUNC;
        else if (strcmp(f, "wx") == 0) flags = UV_FS_O_WRONLY | UV_FS_O_CREAT | UV_FS_O_EXCL;
        else if (strcmp(f, "w+x") == 0) flags = UV_FS_O_RDWR | UV_FS_O_CREAT | UV_FS_O_EXCL;
        else if (strcmp(f, "a") == 0) flags = UV_FS_O_WRONLY | UV_FS_O_CREAT | UV_FS_O_APPEND;
        else if (strcmp(f, "a+") == 0) flags = UV_FS_O_RDWR | UV_FS_O_CREAT | UV_FS_O_APPEND;
        else return slang_argerror(S, 2, "\"r\", \"r+\", \"w\", \"w+\", \"wx\", \"w+x\", \"a\" or \"a+\" expected");
    }
    fs_job *j = new_job(FS_OPEN);
    j->path = dup_arg(S, 1, NULL);
    j->flags = flags;
    j->mode = 0644;
    return fs_queue(S, j);
}

/* fs_read(fd, length, offset, cb(err, data)): offset -1 or null reads at
 * the current position; data is shorter at the end of the file, "" past it */
static int l_fs_read(slang_State *S) {
    fs_job *j = new_job(FS_READ);
    j->fd = slang_checkint(S, 1);
    int64_t len = slang_checkint(S, 2);
    j->len = len > 0 ? (size_t)len : 0;
    j->offset = slang_isint(S, 3) ? slang_toint(S, 3) : -1;
    return fs_queue(S, j);
}

/* fs_write(fd, data, offset, cb(err, written)) */
static int l_fs_write(slang_State *S) {
    fs_job *j = new_job(FS_WRITE);
    j->fd = slang_checkint(S, 1);
    j->data = dup_arg(S, 2, &j->len);
    j->offset = slang_isint(S, 3) ? slang_toint(S, 3) : -1;
    return fs_queue(S, j);
}

static int l_fs_close(slang_State *S) {
    fs_job *j = new_job(FS_CLOSE);
    j->fd = slang_checkint(S, 1);
    return fs_queue(S, j);
}

/* ---- name resolution ---- */

typedef struct {
    uv_getaddrinfo_t req;
    int cb_ref;
} gai_req;

static void push_sockaddr(slang_State *S, const struct sockaddr_storage *addr);

static void on_getaddrinfo(uv_getaddrinfo_t *req, int status, struct addrinfo *res) {
    uv_ctx *cx = CTX(req->loop);
    gai_req *g = (gai_req *)req;
    if (begin_callback(cx, g->cb_ref)) {
        if (status < 0) {
            push_uv_error(cx->run_S, status);
            slang_pushnull(cx->run_S);
        } else {
            slang_pushnull(cx->run_S);
            slang_newtable(cx->run_S);
            for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
                push_sockaddr(cx->run_S, (const struct sockaddr_storage *)ai->ai_addr);
                slang_append(cx->run_S, -2);
            }
        }
        finish_callback(cx, 2);
    }
    uv_freeaddrinfo(res);
    if (cx->run_S != NULL) drop_ref(cx->run_S, &g->cb_ref);
    free(g);
}

/* getaddrinfo(host, port, [family], cb(err, list of {ip, port, family})):
 * port is a number, a service name or null; family "ipv4" or "ipv6" limits
 * the answers */
static int l_getaddrinfo(slang_State *S) {
    const char *host = slang_checklstring(S, 1, NULL);
    int top = slang_gettop(S);
    slang_checkfunction(S, top);
    if (slang_failed(S)) return SLANG_ERROR;
    char service[32];
    const char *svc = NULL;
    if (slang_isint(S, 2)) {
        snprintf(service, sizeof service, "%lld", (long long)slang_toint(S, 2));
        svc = service;
    } else if (slang_isstring(S, 2) && top > 2) {
        svc = slang_tolstring(S, 2, NULL);
    }
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (top > 3 && slang_isstring(S, 3)) {
        const char *fam = slang_tolstring(S, 3, NULL);
        if (strcmp(fam, "ipv4") == 0) hints.ai_family = AF_INET;
        else if (strcmp(fam, "ipv6") == 0) hints.ai_family = AF_INET6;
        else return slang_argerror(S, 3, "\"ipv4\" or \"ipv6\" expected");
    }
    gai_req *g = calloc(1, sizeof(gai_req));
    slang_pushvalue(S, top);
    g->cb_ref = slang_ref(S);
    int r = uv_getaddrinfo(loop_of(S), &g->req, on_getaddrinfo, host, svc, &hints);
    if (r < 0) {
        drop_ref(S, &g->cb_ref);
        free(g);
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

/* ---- signals ---- */

static const struct { const char *name; int num; } signal_names[] = {
    {"SIGINT", SIGINT}, {"SIGTERM", SIGTERM}, {"SIGHUP", SIGHUP}, {"SIGQUIT", SIGQUIT},
    {"SIGKILL", SIGKILL}, {"SIGUSR1", SIGUSR1}, {"SIGUSR2", SIGUSR2}, {"SIGPIPE", SIGPIPE},
    {"SIGCHLD", SIGCHLD}, {"SIGWINCH", SIGWINCH}, {"SIGALRM", SIGALRM}, {"SIGCONT", SIGCONT},
    {"SIGSTOP", SIGSTOP}, {"SIGTSTP", SIGTSTP}, {NULL, 0},
};

static const char *signal_name(int num) {
    for (int i = 0; signal_names[i].name != NULL; i++)
        if (signal_names[i].num == num) return signal_names[i].name;
    return NULL;
}

/* a signal given by number or name at idx, or -1 after an argument error */
static int check_signal(slang_State *S, int idx, int def) {
    if (slang_isnone(S, idx) || slang_isnull(S, idx)) {
        if (def >= 0) return def;
    } else if (slang_isint(S, idx)) {
        return (int)slang_toint(S, idx);
    } else if (slang_isstring(S, idx)) {
        const char *s = slang_tolstring(S, idx, NULL);
        for (int i = 0; signal_names[i].name != NULL; i++)
            if (strcmp(signal_names[i].name, s) == 0) return signal_names[i].num;
    }
    slang_argerror(S, idx, "a signal number or name like \"SIGTERM\" expected");
    return -1;
}

static int l_signal(slang_State *S) {
    handle *h = new_handle(S, "uv.signal");
    uv_signal_init(loop_of(S), &h->u.signal);
    return 1;
}

static void on_signal(uv_signal_t *sig, int signum) {
    uv_ctx *cx = CTX(sig->loop);
    handle *h = (handle *)sig;
    if (!begin_callback(cx, h->cb_ref)) return;
    slang_pushnull(cx->run_S);
    const char *name = signal_name(signum);
    if (name != NULL) slang_pushstring(cx->run_S, name); else slang_pushint(cx->run_S, signum);
    finish_callback(cx, 2);
}

/* signal:start(sig, cb(err, name)): sig is a number or a name like "SIGINT" */
static int signal_start(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.signal");
    if (h == NULL) return SLANG_ERROR;
    int sig = check_signal(S, 2, -1);
    slang_checkfunction(S, 3);
    if (sig < 0 || slang_failed(S)) return SLANG_ERROR;
    if (h->closed) return slang_error(S, "signal handle is closed");
    drop_ref(S, &h->cb_ref);
    slang_pushvalue(S, 3);
    h->cb_ref = slang_ref(S);
    retain(S, h, 1);
    int r = uv_signal_start(&h->u.signal, on_signal, sig);
    if (r < 0) {
        drop_ref(S, &h->cb_ref);
        release(S, h);
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

static int signal_stop(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.signal");
    if (h == NULL) return SLANG_ERROR;
    uv_signal_stop(&h->u.signal);
    drop_ref(S, &h->cb_ref);
    release(S, h);
    return 0;
}

static int signal_close(slang_State *S) { return l_close(S, "uv.signal"); }
static int signal_is_active(slang_State *S) { return l_is_active(S, "uv.signal"); }
static int signal_is_closing(slang_State *S) { return l_is_closing(S, "uv.signal"); }

static const slang_Reg signal_methods[] = {
    {"start", signal_start},
    {"stop", signal_stop},
    {"close", signal_close},
    {"is_active", signal_is_active},
    {"is_closing", signal_is_closing},
    HANDLE_METHODS,
    {NULL, NULL},
};

/* ---- processes ---- */

static void on_exit_cb(uv_process_t *p, int64_t status, int term_signal) {
    uv_ctx *cx = CTX(p->loop);
    handle *h = (handle *)p;
    if (begin_callback(cx, h->cb_ref)) {
        slang_pushnull(cx->run_S);
        slang_newtable(cx->run_S);
        slang_pushint(cx->run_S, status);
        slang_setfield(cx->run_S, -2, "status");
        if (term_signal != 0) {
            const char *name = signal_name(term_signal);
            if (name != NULL) slang_pushstring(cx->run_S, name); else slang_pushint(cx->run_S, term_signal);
            slang_setfield(cx->run_S, -2, "signal");
        }
        finish_callback(cx, 2);
    }
    if (cx->run_S != NULL) {
        /* the process is gone: the handle is only waiting to be closed */
        drop_ref(cx->run_S, &h->cb_ref);
        release(cx->run_S, h);
    }
}

static void free_strings(char **v) {
    if (v == NULL) return;
    for (int i = 0; v[i] != NULL; i++) free(v[i]);
    free(v);
}

/* spawn(file, args, options, on_exit(err, {status, signal})) -> process:
 * args is the list of arguments after the program name; options (may be
 * null) has cwd, env (a table of names to values, replacing the
 * environment), detached, and stdio: a list for fds 0, 1, 2, ... whose
 * entries are a uv.pipe (connected to the child), "inherit" (the same fd of
 * this process), an int (that fd of this process) or "ignore". Without
 * stdio the child inherits 0, 1 and 2. Raises when the program cannot be
 * started. */
static int l_spawn(slang_State *S) {
    const char *file = slang_checklstring(S, 1, NULL);
    slang_checkfunction(S, 4);
    if (slang_failed(S)) return SLANG_ERROR;
    if (!slang_isnull(S, 2) && !slang_istable(S, 2)) return slang_argerror(S, 2, "list of arguments expected");
    if (!slang_isnull(S, 3) && !slang_istable(S, 3)) return slang_argerror(S, 3, "options table expected");

    uv_process_options_t opts;
    memset(&opts, 0, sizeof opts);
    int nargs = slang_istable(S, 2) ? (int)slang_rawlen(S, 2) : 0;
    char **argv = calloc((size_t)nargs + 2, sizeof(char *));
    argv[0] = strdup(file);
    for (int i = 0; i < nargs; i++) {
        slang_rawgeti(S, 2, i);
        const char *a = slang_isstring(S, -1) ? slang_tolstring(S, -1, NULL) : NULL;
        argv[i + 1] = strdup(a ? a : "");
        slang_pop(S, 1);
        if (a == NULL) {
            free_strings(argv);
            return slang_argerror(S, 2, "arguments must be strings");
        }
    }
    char **env = NULL;
    char *cwd = NULL;
    uv_stdio_container_t stdio[16];
    int nstdio = 3;
    for (int i = 0; i < 3; i++) {
        stdio[i].flags = UV_INHERIT_FD;
        stdio[i].data.fd = i;
    }
    if (slang_istable(S, 3)) {
        slang_getfield(S, 3, "cwd");
        if (slang_isstring(S, -1)) cwd = strdup(slang_tolstring(S, -1, NULL));
        slang_pop(S, 1);
        slang_getfield(S, 3, "detached");
        if (slang_tobool(S, -1)) opts.flags |= UV_PROCESS_DETACHED;
        slang_pop(S, 1);
        slang_getfield(S, 3, "env");
        if (slang_istable(S, -1)) {
            int env_idx = slang_gettop(S);
            size_t n = 0, cap = 16;
            env = calloc(cap, sizeof(char *));
            slang_pushnull(S);
            while (slang_next(S, env_idx)) {
                if (slang_isstring(S, -2) && slang_isstring(S, -1)) {
                    size_t kl = 0, vl = 0;
                    const char *k = slang_tolstring(S, -2, &kl);
                    const char *v = slang_tolstring(S, -1, &vl);
                    if (n + 2 > cap) {
                        cap *= 2;
                        env = realloc(env, cap * sizeof(char *));
                    }
                    env[n] = malloc(kl + vl + 2);
                    memcpy(env[n], k, kl);
                    env[n][kl] = '=';
                    memcpy(env[n] + kl + 1, v, vl);
                    env[n][kl + vl + 1] = 0;
                    n++;
                }
                slang_pop(S, 1);
            }
            env[n] = NULL;
        }
        slang_pop(S, 1);
        slang_getfield(S, 3, "stdio");
        if (slang_istable(S, -1)) {
            int list = slang_gettop(S);
            nstdio = (int)slang_rawlen(S, list);
            if (nstdio > 16) nstdio = 16;
            for (int i = 0; i < nstdio; i++) {
                slang_rawgeti(S, list, i);
                handle **box = slang_testudata(S, -1, "uv.pipe");
                if (box != NULL) {
                    stdio[i].flags = UV_CREATE_PIPE | UV_READABLE_PIPE | UV_WRITABLE_PIPE;
                    stdio[i].data.stream = &(*box)->u.stream;
                } else if (slang_isint(S, -1)) {
                    stdio[i].flags = UV_INHERIT_FD;
                    stdio[i].data.fd = (int)slang_toint(S, -1);
                } else if (slang_isstring(S, -1) && strcmp(slang_tolstring(S, -1, NULL), "inherit") == 0) {
                    stdio[i].flags = UV_INHERIT_FD;
                    stdio[i].data.fd = i;
                } else {
                    stdio[i].flags = UV_IGNORE;
                }
                slang_pop(S, 1);
            }
        }
        slang_pop(S, 1);
    }
    opts.file = file;
    opts.args = argv;
    opts.env = env;
    opts.cwd = cwd;
    opts.stdio = stdio;
    opts.stdio_count = nstdio;
    opts.exit_cb = on_exit_cb;

    handle *h = new_handle(S, "uv.process");
    int proc_idx = slang_gettop(S);
    int r = uv_spawn(loop_of(S), &h->u.process, &opts);
    free_strings(argv);
    free_strings(env);
    free(cwd);
    if (r < 0) {
        /* the handle is initialized even so; its finalizer closes it */
        slang_pushfstring(S, "%s: %s, spawn '%s'", uv_err_name(r), uv_strerror(r), file);
        return slang_raise(S);
    }
    slang_pushvalue(S, 4);
    h->cb_ref = slang_ref(S);
    retain(S, h, proc_idx);
    return 1;
}

static int process_pid(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.process");
    if (h == NULL) return SLANG_ERROR;
    slang_pushint(S, h->u.process.pid);
    return 1;
}

/* process:kill([sig]): SIGTERM by default */
static int process_kill(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.process");
    if (h == NULL) return SLANG_ERROR;
    int sig = check_signal(S, 2, SIGTERM);
    if (sig < 0) return SLANG_ERROR;
    int r = uv_process_kill(&h->u.process, sig);
    if (r < 0) {
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

static int l_getpid(slang_State *S) {
    slang_pushint(S, (int64_t)uv_os_getpid());
    return 1;
}

/* kill(pid, [sig]) */
static int l_kill(slang_State *S) {
    int64_t pid = slang_checkint(S, 1);
    int sig = check_signal(S, 2, SIGTERM);
    if (slang_failed(S) || sig < 0) return SLANG_ERROR;
    int r = uv_kill((int)pid, sig);
    if (r < 0) {
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

static int process_close(slang_State *S) { return l_close(S, "uv.process"); }
static int process_is_active(slang_State *S) { return l_is_active(S, "uv.process"); }
static int process_is_closing(slang_State *S) { return l_is_closing(S, "uv.process"); }

static const slang_Reg process_methods[] = {
    {"pid", process_pid},
    {"kill", process_kill},
    {"close", process_close},
    {"is_active", process_is_active},
    {"is_closing", process_is_closing},
    HANDLE_METHODS,
    {NULL, NULL},
};

/* ---- polling a foreign file descriptor ---- */

/* poll(fd): watches a socket or pipe some other library owns (libpq) */
static int l_poll(slang_State *S) {
    int64_t fd = slang_checkint(S, 1);
    if (slang_failed(S)) return SLANG_ERROR;
    handle *h = new_handle(S, "uv.poll");
    int r = uv_poll_init(loop_of(S), &h->u.poll, (int)fd);
    if (r < 0) {
        /* not initialized: nothing to close */
        h->closed = 1;
        h->close_done = 1;
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 1;
}

static void on_poll(uv_poll_t *p, int status, int events) {
    uv_ctx *cx = CTX(p->loop);
    handle *h = (handle *)p;
    if (!begin_callback(cx, h->cb_ref)) return;
    if (status < 0) {
        push_uv_error(cx->run_S, status);
        slang_pushnull(cx->run_S);
    } else {
        slang_pushnull(cx->run_S);
        int rd = (events & UV_READABLE) != 0, wr = (events & UV_WRITABLE) != 0;
        slang_pushstring(cx->run_S, rd && wr ? "rw" : rd ? "r" : wr ? "w" : "");
    }
    finish_callback(cx, 2);
}

/* poll:start(events, cb(err, events)): events "r", "w" or "rw" */
static int poll_start(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.poll");
    const char *ev = slang_checklstring(S, 2, NULL);
    slang_checkfunction(S, 3);
    if (h == NULL || slang_failed(S)) return SLANG_ERROR;
    int events = 0;
    if (strchr(ev, 'r')) events |= UV_READABLE;
    if (strchr(ev, 'w')) events |= UV_WRITABLE;
    if (events == 0) return slang_argerror(S, 2, "\"r\", \"w\" or \"rw\" expected");
    if (h->closed) return slang_error(S, "poll handle is closed");
    drop_ref(S, &h->cb_ref);
    slang_pushvalue(S, 3);
    h->cb_ref = slang_ref(S);
    retain(S, h, 1);
    int r = uv_poll_start(&h->u.poll, events, on_poll);
    if (r < 0) {
        drop_ref(S, &h->cb_ref);
        release(S, h);
        push_uv_error(S, r);
        return slang_raise(S);
    }
    return 0;
}

static int poll_stop(slang_State *S) {
    handle *h = check_handle(S, 1, "uv.poll");
    if (h == NULL) return SLANG_ERROR;
    uv_poll_stop(&h->u.poll);
    drop_ref(S, &h->cb_ref);
    release(S, h);
    return 0;
}

static int poll_close(slang_State *S) { return l_close(S, "uv.poll"); }
static int poll_is_active(slang_State *S) { return l_is_active(S, "uv.poll"); }
static int poll_is_closing(slang_State *S) { return l_is_closing(S, "uv.poll"); }

static const slang_Reg poll_methods[] = {
    {"start", poll_start},
    {"stop", poll_stop},
    {"close", poll_close},
    {"is_active", poll_is_active},
    {"is_closing", poll_is_closing},
    HANDLE_METHODS,
    {NULL, NULL},
};

/* ---- module ---- */

static const slang_Reg funcs[] = {
    {"run", l_run},
    {"stop", l_stop},
    {"now", l_now},
    {"hrtime", l_hrtime},
    {"loop_alive", l_loop_alive},
    {"version", l_version},
    {"timer", l_timer},
    {"tcp", l_tcp},
    {"pipe", l_pipe},
    {"signal", l_signal},
    {"async", l_async},
    {"spawn", l_spawn},
    {"kill", l_kill},
    {"getpid", l_getpid},
    {"poll", l_poll},
    {"getaddrinfo", l_getaddrinfo},
    {"fs_read_file", l_fs_read_file},
    {"fs_write_file", l_fs_write_file},
    {"fs_stat", l_fs_stat},
    {"fs_unlink", l_fs_unlink},
    {"fs_mkdir", l_fs_mkdir},
    {"fs_rmdir", l_fs_rmdir},
    {"fs_rename", l_fs_rename},
    {"fs_scandir", l_fs_scandir},
    {"fs_open", l_fs_open},
    {"fs_read", l_fs_read},
    {"fs_write", l_fs_write},
    {"fs_close", l_fs_close},
    {NULL, NULL},
};

static void make_meta(slang_State *S, const char *type_name, const slang_Reg *methods) {
    slang_newtable(S);
    slang_newmodule(S, methods);
    slang_setfield(S, -2, "__index");
    slang_pushstring(S, type_name);
    slang_setfield(S, -2, "__type");
    slang_settypemeta(S, type_name);
}

/* ---- the loop of a VM ---- */

static void on_wake(uv_async_t *a) {
    uv_ctx *cx = CTX(a->loop);
    cx->killed = 1;
    uv_stop(&cx->loop);
}

/* the isolate is being killed (on the killing thread): the loop wakes */
static void ctx_interrupt(void *data) {
    uv_async_send(&((uv_ctx *)data)->wake);
}

static void close_walk(uv_handle_t *uvh, void *arg) {
    uv_ctx *cx = arg;
    if (uv_is_closing(uvh)) return;
    /* (the userdata, not yet collected, frees the struct later) */
    if (uvh == (uv_handle_t *)&cx->hold || uvh == (uv_handle_t *)&cx->wake) {
        uv_close(uvh, NULL);
        return;
    }
    handle *h = (handle *)uvh;
    h->closed = 1;
    uv_close(uvh, on_close);
}

/* the VM is closing, its values are still there: every handle is closed and
 * the loop runs until the close callbacks and the work in flight are done
 * (no slang runs: run_S is NULL), so that no pool thread still works on a
 * value when it is freed; then the loop is closed. The handles' finalizers
 * only free them afterwards. */
static void ctx_close(void *data) {
    uv_ctx *cx = data;
    uv_ctx *self = cx;
    __atomic_compare_exchange_n(&first_ctx, &self, NULL, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    uv_walk(&cx->loop, close_walk, cx);
    uv_run(&cx->loop, UV_RUN_DEFAULT);
    uv_loop_close(&cx->loop);
}

static int open_ctx(slang_State *S) {
    if (get_ctx(S) != NULL) return 0;
    uv_ctx *cx = calloc(1, sizeof(uv_ctx));
    int r = uv_loop_init(&cx->loop);
    if (r < 0) {
        free(cx);
        push_uv_error(S, r);
        return slang_raise(S);
    }
    cx->loop.data = cx;
    uv_async_init(&cx->loop, &cx->hold, NULL);
    uv_unref((uv_handle_t *)&cx->hold);
    uv_async_init(&cx->loop, &cx->wake, on_wake);
    uv_unref((uv_handle_t *)&cx->wake);
    slang_setextdata(S, &ctx_key, cx, free);
    slang_onclose(S, ctx_close, cx);
    slang_oninterrupt(S, ctx_interrupt, cx);
    uv_ctx *none = NULL;
    __atomic_compare_exchange_n(&first_ctx, &none, cx, 0, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    return 0;
}

SLANG_EXTENSION(uv) {
    if (open_ctx(S) != 0) return SLANG_ERROR;
    make_meta(S, "uv.timer", timer_methods);
    make_meta(S, "uv.tcp", tcp_methods);
    make_meta(S, "uv.pipe", pipe_methods);
    make_meta(S, "uv.signal", signal_methods);
    make_meta(S, "uv.process", process_methods);
    make_meta(S, "uv.poll", poll_methods);
    make_meta(S, "uv.async", async_methods);
    slang_newmodule(S, funcs);
    const slang_uv_api **api = slang_newuserdata(S, sizeof(slang_uv_api *), SLANG_UV_API_TNAME, NULL);
    *api = &the_api;
    slang_setfield(S, -2, "c_api");
    return 1;
}
