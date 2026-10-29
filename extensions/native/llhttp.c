/*
 * llhttp: a native extension around llhttp (https://llhttp.org), the HTTP/1
 * parser of Node.js. slang/http parses requests and responses with it.
 *
 *   local llhttp = require("llhttp")
 *   local p = llhttp.parser("request", {max_head: 65536})
 *   for(let local e in values(p:execute(bytes))){ ... }
 *
 * execute(data) feeds bytes and returns the list of events they completed,
 * in order; the callback traffic of llhttp stays in C:
 *
 *   {type: "head", method, url, version, headers, keep_alive, upgrade,
 *    chunked, content_length}            (requests)
 *   {type: "head", status, reason, version, headers, ...}   (responses)
 *   {type: "body", data}                  a piece of the body, de-chunked
 *   {type: "done", keep_alive}            the message is complete
 *   {type: "upgrade", rest}               the connection switches protocol
 *                                         (rest: the bytes after the head)
 *   {type: "error", code, reason, status} the input is not HTTP; status is
 *                                         431 for a head over max_head, else
 *                                         400; the parser stays failed
 *
 * Header names are lowercased. A repeated header is joined with ", "
 * (cookie with "; "), except set-cookie, which is always a list.
 * finish() ends the input (a response that runs to the end of the
 * connection completes) and returns the events that gives. skip_body()
 * makes the next head have no body (the answer to a HEAD request).
 * reset() readies the parser for a new connection.
 */
#include <llhttp.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include "slang.h"

typedef struct buf {
    char *data;
    size_t len, cap;
} buf;

static void buf_add(buf *b, const char *at, size_t n) {
    if (b->len + n + 1 > b->cap) {
        b->cap = (b->len + n + 1) * 2;
        b->data = realloc(b->data, b->cap);
    }
    memcpy(b->data + b->len, at, n);
    b->len += n;
    b->data[b->len] = 0;
}

static void buf_free(buf *b) {
    free(b->data);
    b->data = NULL;
    b->len = b->cap = 0;
}

typedef struct parser {
    llhttp_t p;
    llhttp_settings_t settings;
    slang_State *S;      /* set during execute and finish */
    int events;          /* stack index of the events list */
    buf url, reason, field, value, body;
    char **names, **values;
    int nheaders, capheaders;
    size_t head_bytes, max_head;
    int skip_next;
    int failed;
    int head_too_large;
} parser;

static const char *parser_tname = "llhttp.parser";
static int parser_meta_ref = SLANG_REFNULL;

static void clear_headers(parser *ps) {
    for (int i = 0; i < ps->nheaders; i++) {
        free(ps->names[i]);
        free(ps->values[i]);
    }
    ps->nheaders = 0;
}

static void parser_finalize(void *data) {
    parser *ps = data;
    clear_headers(ps);
    free(ps->names);
    free(ps->values);
    buf_free(&ps->url);
    buf_free(&ps->reason);
    buf_free(&ps->field);
    buf_free(&ps->value);
    buf_free(&ps->body);
}

static parser *of(llhttp_t *p) {
    return (parser *)p;
}

/* counts head bytes; fails the parse past max_head */
static int count_head(parser *ps, size_t n) {
    ps->head_bytes += n;
    if (ps->max_head > 0 && ps->head_bytes > ps->max_head) {
        ps->head_too_large = 1;
        llhttp_set_error_reason(&ps->p, "the request head is too large");
        return HPE_USER;
    }
    return 0;
}

static void push_body(parser *ps) {
    if (ps->body.len == 0) return;
    slang_State *S = ps->S;
    slang_newtable(S);
    slang_pushstring(S, "body");
    slang_setfield(S, -2, "type");
    slang_pushlstring(S, ps->body.data, ps->body.len);
    slang_setfield(S, -2, "data");
    slang_append(S, ps->events);
    ps->body.len = 0;
}

static int on_message_begin(llhttp_t *p) {
    parser *ps = of(p);
    ps->url.len = ps->reason.len = ps->field.len = ps->value.len = 0;
    ps->head_bytes = 0;
    clear_headers(ps);
    return 0;
}

static int on_url(llhttp_t *p, const char *at, size_t n) {
    parser *ps = of(p);
    buf_add(&ps->url, at, n);
    return count_head(ps, n);
}

static int on_status(llhttp_t *p, const char *at, size_t n) {
    parser *ps = of(p);
    buf_add(&ps->reason, at, n);
    return count_head(ps, n);
}

static int on_header_field(llhttp_t *p, const char *at, size_t n) {
    parser *ps = of(p);
    buf_add(&ps->field, at, n);
    return count_head(ps, n);
}

static int on_header_value(llhttp_t *p, const char *at, size_t n) {
    parser *ps = of(p);
    buf_add(&ps->value, at, n);
    return count_head(ps, n);
}

static char *dup_buf(buf *b) {
    char *s = malloc(b->len + 1);
    if (b->len) memcpy(s, b->data, b->len);
    s[b->len] = 0;
    return s;
}

static int on_header_value_complete(llhttp_t *p) {
    parser *ps = of(p);
    if (ps->nheaders == ps->capheaders) {
        ps->capheaders = ps->capheaders ? ps->capheaders * 2 : 16;
        ps->names = realloc(ps->names, sizeof(char *) * (size_t)ps->capheaders);
        ps->values = realloc(ps->values, sizeof(char *) * (size_t)ps->capheaders);
    }
    char *name = dup_buf(&ps->field);
    for (char *c = name; *c; c++) *c = (char)tolower((unsigned char)*c);
    ps->names[ps->nheaders] = name;
    /* trailing whitespace is not part of the value (RFC 9110, 5.5) */
    while (ps->value.len > 0 && (ps->value.data[ps->value.len - 1] == ' ' || ps->value.data[ps->value.len - 1] == '\t'))
        ps->value.len--;
    ps->values[ps->nheaders] = dup_buf(&ps->value);
    ps->nheaders++;
    ps->field.len = ps->value.len = 0;
    return 0;
}

/* the headers table: lowercased names, repeats joined, set-cookie a list */
static void push_headers(parser *ps) {
    slang_State *S = ps->S;
    slang_newtable(S);
    int t = slang_gettop(S);
    for (int i = 0; i < ps->nheaders; i++) {
        const char *name = ps->names[i];
        if (strcmp(name, "set-cookie") == 0) {
            slang_getfield(S, t, name);
            if (slang_isnull(S, -1)) {
                slang_pop(S, 1);
                slang_newtable(S);
                slang_pushvalue(S, -1);
                slang_setfield(S, t, name);
            }
            slang_pushstring(S, ps->values[i]);
            slang_append(S, -2);
            slang_pop(S, 1);
            continue;
        }
        slang_getfield(S, t, name);
        if (slang_isstring(S, -1)) {
            const char *sep = strcmp(name, "cookie") == 0 ? "; " : ", ";
            slang_pushfstring(S, "%s%s%s", slang_tolstring(S, -1, NULL), sep, ps->values[i]);
            slang_setfield(S, t, name);
            slang_pop(S, 1);
        } else {
            slang_pop(S, 1);
            slang_pushstring(S, ps->values[i]);
            slang_setfield(S, t, name);
        }
    }
}

static int on_headers_complete(llhttp_t *p) {
    parser *ps = of(p);
    slang_State *S = ps->S;
    slang_newtable(S);
    slang_pushstring(S, "head");
    slang_setfield(S, -2, "type");
    if (llhttp_get_type(p) == HTTP_REQUEST) {
        slang_pushstring(S, llhttp_method_name((llhttp_method_t)llhttp_get_method(p)));
        slang_setfield(S, -2, "method");
        slang_pushlstring(S, ps->url.data ? ps->url.data : "", ps->url.len);
        slang_setfield(S, -2, "url");
    } else {
        slang_pushint(S, llhttp_get_status_code(p));
        slang_setfield(S, -2, "status");
        slang_pushlstring(S, ps->reason.data ? ps->reason.data : "", ps->reason.len);
        slang_setfield(S, -2, "reason");
    }
    slang_pushfstring(S, "%d.%d", llhttp_get_http_major(p), llhttp_get_http_minor(p));
    slang_setfield(S, -2, "version");
    push_headers(ps);
    slang_setfield(S, -2, "headers");
    slang_pushbool(S, llhttp_should_keep_alive(p));
    slang_setfield(S, -2, "keep_alive");
    slang_pushbool(S, llhttp_get_upgrade(p));
    slang_setfield(S, -2, "upgrade");
    slang_pushbool(S, (p->flags & F_CHUNKED) != 0);
    slang_setfield(S, -2, "chunked");
    if (p->flags & F_CONTENT_LENGTH) {
        slang_pushint(S, (int64_t)p->content_length);
        slang_setfield(S, -2, "content_length");
    }
    slang_append(S, ps->events);
    clear_headers(ps);
    if (ps->skip_next) {
        ps->skip_next = 0;
        return 1;
    }
    return 0;
}

static int on_body(llhttp_t *p, const char *at, size_t n) {
    buf_add(&of(p)->body, at, n);
    return 0;
}

static int on_message_complete(llhttp_t *p) {
    parser *ps = of(p);
    slang_State *S = ps->S;
    push_body(ps);
    slang_newtable(S);
    slang_pushstring(S, "done");
    slang_setfield(S, -2, "type");
    slang_pushbool(S, llhttp_should_keep_alive(p));
    slang_setfield(S, -2, "keep_alive");
    slang_append(S, ps->events);
    return 0;
}

/* parser(kind, [options]): kind "request" or "response"; options.max_head
 * limits the bytes of a head (0: no limit) */
static int l_parser(slang_State *S) {
    const char *kind = slang_checklstring(S, 1, NULL);
    if (kind == NULL) return SLANG_ERROR;
    llhttp_type_t type;
    if (strcmp(kind, "request") == 0) type = HTTP_REQUEST;
    else if (strcmp(kind, "response") == 0) type = HTTP_RESPONSE;
    else return slang_argerror(S, 1, "\"request\" or \"response\" expected");
    int64_t max_head = 0;
    if (slang_istable(S, 2)) {
        slang_getfield(S, 2, "max_head");
        if (slang_isint(S, -1)) max_head = slang_toint(S, -1);
        slang_pop(S, 1);
    }
    parser *ps = slang_newuserdata(S, sizeof(parser), parser_tname, parser_finalize);
    llhttp_settings_init(&ps->settings);
    ps->settings.on_message_begin = on_message_begin;
    ps->settings.on_url = on_url;
    ps->settings.on_status = on_status;
    ps->settings.on_header_field = on_header_field;
    ps->settings.on_header_value = on_header_value;
    ps->settings.on_header_value_complete = on_header_value_complete;
    ps->settings.on_headers_complete = on_headers_complete;
    ps->settings.on_body = on_body;
    ps->settings.on_message_complete = on_message_complete;
    llhttp_init(&ps->p, type, &ps->settings);
    ps->max_head = max_head > 0 ? (size_t)max_head : 0;
    slang_getref(S, parser_meta_ref);
    slang_setmetatable(S, -2);
    return 1;
}

static parser *check_parser(slang_State *S) {
    return slang_checkudata(S, 1, parser_tname);
}

/* turns the result of llhttp_execute/finish into trailing events */
static void after_run(parser *ps, llhttp_errno_t err, const char *data, size_t len) {
    slang_State *S = ps->S;
    push_body(ps);
    if (err == HPE_OK) return;
    if (err == HPE_PAUSED_UPGRADE) {
        const char *pos = llhttp_get_error_pos(&ps->p);
        size_t used = (pos != NULL && data != NULL && pos >= data && pos <= data + len) ? (size_t)(pos - data) : len;
        slang_newtable(S);
        slang_pushstring(S, "upgrade");
        slang_setfield(S, -2, "type");
        slang_pushlstring(S, data ? data + used : "", len - used);
        slang_setfield(S, -2, "rest");
        slang_append(S, ps->events);
        ps->failed = 1;
        return;
    }
    ps->failed = 1;
    slang_newtable(S);
    slang_pushstring(S, "error");
    slang_setfield(S, -2, "type");
    slang_pushstring(S, ps->head_too_large ? "HPE_HEAD_TOO_LARGE" : llhttp_errno_name(err));
    slang_setfield(S, -2, "code");
    const char *reason = llhttp_get_error_reason(&ps->p);
    slang_pushstring(S, reason ? reason : "parse error");
    slang_setfield(S, -2, "reason");
    slang_pushint(S, ps->head_too_large ? 431 : 400);
    slang_setfield(S, -2, "status");
    slang_append(S, ps->events);
}

static int parser_execute(slang_State *S) {
    parser *ps = check_parser(S);
    size_t len = 0;
    const char *data = slang_checklstring(S, 2, &len);
    if (ps == NULL || data == NULL) return SLANG_ERROR;
    slang_newtable(S);
    if (ps->failed) return 1;
    ps->S = S;
    ps->events = slang_gettop(S);
    llhttp_errno_t err = llhttp_execute(&ps->p, data, len);
    after_run(ps, err, data, len);
    ps->S = NULL;
    slang_settop(S, ps->events);
    return 1;
}

static int parser_finish(slang_State *S) {
    parser *ps = check_parser(S);
    if (ps == NULL) return SLANG_ERROR;
    slang_newtable(S);
    if (ps->failed) return 1;
    ps->S = S;
    ps->events = slang_gettop(S);
    llhttp_errno_t err = llhttp_finish(&ps->p);
    after_run(ps, err, NULL, 0);
    ps->S = NULL;
    slang_settop(S, ps->events);
    return 1;
}

static int parser_skip_body(slang_State *S) {
    parser *ps = check_parser(S);
    if (ps == NULL) return SLANG_ERROR;
    ps->skip_next = 1;
    return 0;
}

static int parser_reset(slang_State *S) {
    parser *ps = check_parser(S);
    if (ps == NULL) return SLANG_ERROR;
    llhttp_reset(&ps->p);
    ps->failed = 0;
    ps->head_too_large = 0;
    ps->skip_next = 0;
    ps->body.len = 0;
    clear_headers(ps);
    return 0;
}

static int l_version(slang_State *S) {
    slang_pushfstring(S, "%d.%d.%d", LLHTTP_VERSION_MAJOR, LLHTTP_VERSION_MINOR, LLHTTP_VERSION_PATCH);
    return 1;
}

static const slang_Reg parser_methods[] = {
    {"execute", parser_execute},
    {"finish", parser_finish},
    {"skip_body", parser_skip_body},
    {"reset", parser_reset},
    {NULL, NULL},
};

static const slang_Reg funcs[] = {
    {"parser", l_parser},
    {"version", l_version},
    {NULL, NULL},
};

SLANG_EXTENSION(llhttp) {
    slang_newtable(S);
    slang_newmodule(S, parser_methods);
    slang_setfield(S, -2, "__index");
    slang_pushstring(S, parser_tname);
    slang_setfield(S, -2, "__type");
    parser_meta_ref = slang_ref(S);
    slang_newmodule(S, funcs);
    return 1;
}
