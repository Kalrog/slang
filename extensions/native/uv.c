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
 * Callbacks run only from inside uv.run(); an error raised in one stops the
 * loop and comes out of uv.run(). An active handle (a running timer, a
 * listening or reading socket, a pending connect) keeps its userdata alive;
 * a handle that is collected before it was closed is closed by its finalizer.
 * slang/async builds Futures and Streams on top of this module.
 */
#include <uv.h>
#include <stdlib.h>
#include <string.h>
#include "slang.h"

typedef struct handle {
    union {
        uv_handle_t handle;
        uv_stream_t stream;
        uv_timer_t timer;
        uv_tcp_t tcp;
    } u;
    int self_ref;    /* the userdata, while the handle is active or closing */
    int cb_ref;      /* timer, listen or read callback */
    int close_ref;   /* close callback */
    int closed;      /* uv_close was issued */
    int close_done;  /* and completed */
    int collected;   /* the userdata was finalized */
    int reading;
} handle;

/* the state running the loop (callbacks enter the VM through it) and whether
 * a callback failed (the loop is stopping, further callbacks are skipped) */
static slang_State *run_S = NULL;
static int run_failed = 0;

static uv_loop_t *loop(void) {
    return uv_default_loop();
}

static void push_uv_error(slang_State *S, int status) {
    slang_pushfstring(S, "%s: %s", uv_err_name(status), uv_strerror(status));
}

/* ---- handle lifetime ---- */

static handle *check_handle(slang_State *S, int idx, const char *tname) {
    handle **box = slang_checkudata(S, idx, tname);
    if (box == NULL) return NULL;
    return *box;
}

static handle *check_stream(slang_State *S, int idx) {
    handle **box = slang_testudata(S, idx, "uv.tcp");
    if (box == NULL) {
        slang_argerror(S, idx, "uv.tcp expected");
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
static int begin_callback(int ref) {
    if (run_S == NULL || run_failed || ref == SLANG_REFNULL) return 0;
    slang_getref(run_S, ref);
    return 1;
}

/* calls the function pushed by begin_callback with nargs arguments */
static void finish_callback(int nargs) {
    if (slang_call(run_S, nargs) != SLANG_OK) {
        run_failed = 1;
        uv_stop(loop());
        return;
    }
    slang_pop(run_S, 1);
}

static void on_close(uv_handle_t *uvh) {
    handle *h = (handle *)uvh;
    h->close_done = 1;
    if (h->collected) {
        free(h);
        return;
    }
    if (run_S != NULL) {
        if (begin_callback(h->close_ref)) finish_callback(0);
        drop_ref(run_S, &h->close_ref);
        drop_ref(run_S, &h->cb_ref);
        release(run_S, h);
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

static handle *new_handle(slang_State *S, const char *tname, int meta_ref) {
    handle *h = calloc(1, sizeof(handle));
    h->self_ref = SLANG_REFNULL;
    h->cb_ref = SLANG_REFNULL;
    h->close_ref = SLANG_REFNULL;
    handle **box = slang_newuserdata(S, sizeof(handle *), tname, handle_finalize);
    *box = h;
    slang_getref(S, meta_ref);
    slang_setmetatable(S, -2);
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

/* ---- loop ---- */

static int l_run(slang_State *S) {
    const char *mode_name = slang_optstring(S, 1, "default");
    uv_run_mode mode = UV_RUN_DEFAULT;
    if (strcmp(mode_name, "once") == 0) mode = UV_RUN_ONCE;
    else if (strcmp(mode_name, "nowait") == 0) mode = UV_RUN_NOWAIT;
    else if (strcmp(mode_name, "default") != 0) return slang_argerror(S, 1, "\"default\", \"once\" or \"nowait\" expected");
    if (run_S != NULL) return slang_error(S, "uv.run is already running");
    run_S = S;
    run_failed = 0;
    int more = uv_run(loop(), mode);
    run_S = NULL;
    if (run_failed) {
        run_failed = 0;
        return SLANG_ERROR; /* the callback's error is still pending */
    }
    slang_pushbool(S, more != 0);
    return 1;
}

static int l_stop(slang_State *S) {
    (void)S;
    uv_stop(loop());
    return 0;
}

static int l_now(slang_State *S) {
    slang_pushint(S, (int64_t)uv_now(loop()));
    return 1;
}

static int l_hrtime(slang_State *S) {
    slang_pushint(S, (int64_t)uv_hrtime());
    return 1;
}

static int l_loop_alive(slang_State *S) {
    slang_pushbool(S, uv_loop_alive(loop()) != 0);
    return 1;
}

static int l_version(slang_State *S) {
    slang_pushstring(S, uv_version_string());
    return 1;
}

/* ---- timers ---- */

static int timer_meta_ref = SLANG_REFNULL;

static int l_timer(slang_State *S) {
    handle *h = new_handle(S, "uv.timer", timer_meta_ref);
    uv_timer_init(loop(), &h->u.timer);
    return 1;
}

static void on_timer(uv_timer_t *t) {
    handle *h = (handle *)t;
    if (begin_callback(h->cb_ref)) finish_callback(0);
    if (run_S != NULL && !uv_is_active(&h->u.handle)) {
        /* a one-shot timer fired: nothing keeps it alive any more */
        drop_ref(run_S, &h->cb_ref);
        release(run_S, h);
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
    {NULL, NULL},
};

/* ---- tcp ---- */

static int tcp_meta_ref = SLANG_REFNULL;

static int l_tcp(slang_State *S) {
    handle *h = new_handle(S, "uv.tcp", tcp_meta_ref);
    uv_tcp_init(loop(), &h->u.tcp);
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
    handle *h = (handle *)server;
    if (!begin_callback(h->cb_ref)) return;
    if (status < 0) push_uv_error(run_S, status); else slang_pushnull(run_S);
    finish_callback(1);
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
    connect_req *c = (connect_req *)req;
    if (begin_callback(c->cb_ref)) {
        if (status < 0) push_uv_error(run_S, status); else slang_pushnull(run_S);
        finish_callback(1);
    }
    if (run_S != NULL) {
        drop_ref(run_S, &c->cb_ref);
        release(run_S, c->h);
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
    handle *h = (handle *)stream;
    if (nread == 0) {
        free(buf->base);
        return;
    }
    if (begin_callback(h->cb_ref)) {
        if (nread > 0) {
            slang_pushnull(run_S);
            slang_pushlstring(run_S, buf->base, (size_t)nread);
        } else if (nread == UV_EOF) {
            slang_pushnull(run_S);
            slang_pushnull(run_S);
        } else {
            push_uv_error(run_S, (int)nread);
            slang_pushnull(run_S);
        }
        finish_callback(2);
    }
    free(buf->base);
    if (nread < 0 && run_S != NULL) {
        /* the stream ended: reading stops, nothing keeps the handle alive */
        uv_read_stop(stream);
        h->reading = 0;
        drop_ref(run_S, &h->cb_ref);
        release(run_S, h);
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
    write_req *w = (write_req *)req;
    if (begin_callback(w->cb_ref)) {
        if (status < 0) push_uv_error(run_S, status); else slang_pushnull(run_S);
        finish_callback(1);
    }
    if (run_S != NULL) {
        drop_ref(run_S, &w->cb_ref);
        drop_ref(run_S, &w->self_ref);
    }
    free(w->buf.base);
    free(w);
}

/* stream:write(data, cb(err)); the data is copied */
static int tcp_write(slang_State *S) {
    handle *h = check_stream(S, 1);
    size_t len = 0;
    const char *data = slang_checklstring(S, 2, &len);
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
    shutdown_req *s = (shutdown_req *)req;
    if (begin_callback(s->cb_ref)) {
        if (status < 0) push_uv_error(run_S, status); else slang_pushnull(run_S);
        finish_callback(1);
    }
    if (run_S != NULL) {
        drop_ref(run_S, &s->cb_ref);
        drop_ref(run_S, &s->self_ref);
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

static int tcp_close(slang_State *S) { return l_close(S, "uv.tcp"); }
static int tcp_is_active(slang_State *S) { return l_is_active(S, "uv.tcp"); }
static int tcp_is_closing(slang_State *S) { return l_is_closing(S, "uv.tcp"); }

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
    {NULL, NULL},
};

static int make_meta(slang_State *S, const char *type_name, const slang_Reg *methods) {
    slang_newtable(S);
    slang_newmodule(S, methods);
    slang_setfield(S, -2, "__index");
    slang_pushstring(S, type_name);
    slang_setfield(S, -2, "__type");
    return slang_ref(S);
}

SLANG_EXTENSION(uv) {
    timer_meta_ref = make_meta(S, "uv.timer", timer_methods);
    tcp_meta_ref = make_meta(S, "uv.tcp", tcp_methods);
    slang_newmodule(S, funcs);
    return 1;
}
