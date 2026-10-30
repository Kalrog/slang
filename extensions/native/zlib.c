/*
 * zlib: a native extension around zlib (https://zlib.net): deflate and
 * inflate in the gzip, zlib and raw formats, at once or as a stream.
 *
 *   local zlib = require("zlib")
 *   zlib.deflate(data, [format], [level])      -> compressed
 *   zlib.inflate(data, [format], [max_size])   -> data
 *   local c = zlib.compressor([format], [level])
 *   c:push(chunk) -> output so far ("" is common)
 *   c:flush()     -> output that lets the reader decode everything pushed
 *   c:finish()    -> the rest; the compressor is done
 *   local d = zlib.decompressor([format], [max_size])
 *   d:push(chunk) -> output   d:finish() -> raises when the input was cut
 *   d:is_done()   -> the end of the compressed stream was reached
 *
 * format: "gzip" (the default for deflate), "zlib", "raw", and for inflate
 * also "auto" (the default: gzip or zlib, by the header). level 0 to 9,
 * 6 by default. max_size bounds the output (a small input can inflate to
 * gigabytes); going over raises. Errors read "zlib: ...".
 */
#include <zlib.h>
#include <stdlib.h>
#include <string.h>
#include "slang.h"

typedef struct stream {
    z_stream z;
    int deflating;
    int inited;
    int ended;      /* Z_STREAM_END seen, or finish() called */
    int64_t max_size;
    int64_t produced;
} stream;

static const char *stream_tname = "zlib.stream";
static int stream_meta_ref = SLANG_REFNULL;

static void stream_finalize(void *data) {
    stream *s = data;
    if (!s->inited) return;
    if (s->deflating) deflateEnd(&s->z);
    else inflateEnd(&s->z);
    s->inited = 0;
}

/* the windowBits for a format, or 0 after an argument error */
static int window_bits(slang_State *S, int idx, int deflating) {
    const char *f = slang_optstring(S, idx, deflating ? "gzip" : "auto");
    if (f == NULL) return 0;
    if (strcmp(f, "gzip") == 0) return 15 + 16;
    if (strcmp(f, "zlib") == 0) return 15;
    if (strcmp(f, "raw") == 0) return -15;
    if (!deflating && strcmp(f, "auto") == 0) return 15 + 32;
    slang_argerror(S, idx, deflating ? "\"gzip\", \"zlib\" or \"raw\" expected" : "\"auto\", \"gzip\", \"zlib\" or \"raw\" expected");
    return 0;
}

static int init_stream(slang_State *S, stream *s, int deflating, int bits, int level) {
    memset(&s->z, 0, sizeof s->z);
    s->deflating = deflating;
    int rc = deflating ? deflateInit2(&s->z, level, Z_DEFLATED, bits, 8, Z_DEFAULT_STRATEGY) : inflateInit2(&s->z, bits);
    if (rc != Z_OK) return slang_error(S, "zlib: cannot start: %s", s->z.msg ? s->z.msg : "out of memory");
    s->inited = 1;
    return SLANG_OK;
}

/* runs the stream over in with flush, pushing the output as one string */
static int run(slang_State *S, stream *s, const char *in, size_t len, int flush) {
    size_t cap = len * 2 + 256, used = 0;
    char *out = malloc(cap);
    s->z.next_in = (Bytef *)in;
    s->z.avail_in = (uInt)len;
    for (;;) {
        if (cap - used < 1024) {
            cap *= 2;
            out = realloc(out, cap);
        }
        s->z.next_out = (Bytef *)(out + used);
        s->z.avail_out = (uInt)(cap - used);
        int rc = s->deflating ? deflate(&s->z, flush) : inflate(&s->z, flush);
        size_t got = (cap - used) - s->z.avail_out;
        used += got;
        s->produced += (int64_t)got;
        if (s->max_size > 0 && s->produced > s->max_size) {
            free(out);
            return slang_error(S, "zlib: output larger than %lld bytes", (long long)s->max_size);
        }
        if (rc == Z_STREAM_END) {
            s->ended = 1;
            break;
        }
        if (rc == Z_BUF_ERROR) {
            /* out of output space: grow and go on; otherwise nothing more
             * can happen until there is more input */
            if (s->z.avail_out == 0) continue;
            break;
        }
        if (rc != Z_OK) {
            const char *msg = s->z.msg ? s->z.msg : "error";
            free(out);
            return slang_error(S, "zlib: %s", rc == Z_DATA_ERROR ? msg : (rc == Z_MEM_ERROR ? "out of memory" : msg));
        }
        /* output space left over: zlib has done all it can with this input
         * (and with the flush asked for); a full buffer means more output */
        if (s->z.avail_out != 0) break;
    }
    slang_pushlstring(S, out, used);
    free(out);
    return 1;
}

static stream *new_stream(slang_State *S) {
    stream *s = slang_newuserdata(S, sizeof(stream), stream_tname, stream_finalize);
    slang_getref(S, stream_meta_ref);
    slang_setmetatable(S, -2);
    return s;
}

/* deflate(data, [format], [level]) */
static int l_deflate(slang_State *S) {
    size_t len = 0;
    const char *data = slang_checkbytes(S, 1, &len);
    int bits = window_bits(S, 2, 1);
    int64_t level = slang_optint(S, 3, 6);
    if (data == NULL || bits == 0 || slang_failed(S)) return SLANG_ERROR;
    if (level < 0 || level > 9) return slang_argerror(S, 3, "a level from 0 to 9 expected");
    stream *s = new_stream(S);
    if (init_stream(S, s, 1, bits, (int)level) != SLANG_OK) return SLANG_ERROR;
    int r = run(S, s, data, len, Z_FINISH);
    stream_finalize(s);
    return r;
}

/* inflate(data, [format], [max_size]) */
static int l_inflate(slang_State *S) {
    size_t len = 0;
    const char *data = slang_checkbytes(S, 1, &len);
    int bits = window_bits(S, 2, 0);
    int64_t max_size = slang_optint(S, 3, 0);
    if (data == NULL || bits == 0 || slang_failed(S)) return SLANG_ERROR;
    stream *s = new_stream(S);
    s->max_size = max_size;
    if (init_stream(S, s, 0, bits, 0) != SLANG_OK) return SLANG_ERROR;
    int r = run(S, s, data, len, Z_FINISH);
    int ended = s->ended;
    stream_finalize(s);
    if (r == SLANG_ERROR) return r;
    if (!ended) return slang_error(S, "zlib: the compressed data is cut short");
    return r;
}

/* compressor([format], [level]) */
static int l_compressor(slang_State *S) {
    int bits = window_bits(S, 1, 1);
    int64_t level = slang_optint(S, 2, 6);
    if (bits == 0 || slang_failed(S)) return SLANG_ERROR;
    if (level < 0 || level > 9) return slang_argerror(S, 2, "a level from 0 to 9 expected");
    stream *s = new_stream(S);
    if (init_stream(S, s, 1, bits, (int)level) != SLANG_OK) return SLANG_ERROR;
    return 1;
}

/* decompressor([format], [max_size]) */
static int l_decompressor(slang_State *S) {
    int bits = window_bits(S, 1, 0);
    int64_t max_size = slang_optint(S, 2, 0);
    if (bits == 0 || slang_failed(S)) return SLANG_ERROR;
    stream *s = new_stream(S);
    s->max_size = max_size;
    if (init_stream(S, s, 0, bits, 0) != SLANG_OK) return SLANG_ERROR;
    return 1;
}

static stream *check_stream(slang_State *S) {
    stream *s = slang_checkudata(S, 1, stream_tname);
    if (s == NULL) return NULL;
    if (!s->inited) {
        slang_error(S, "zlib: the stream is finished");
        return NULL;
    }
    return s;
}

static int stream_push(slang_State *S) {
    stream *s = check_stream(S);
    size_t len = 0;
    const char *data = slang_checkbytes(S, 2, &len);
    if (s == NULL || data == NULL) return SLANG_ERROR;
    if (!s->deflating && s->ended) {
        slang_pushstring(S, ""); /* bytes after the end are ignored */
        return 1;
    }
    return run(S, s, data, len, s->deflating ? Z_NO_FLUSH : Z_SYNC_FLUSH);
}

static int stream_flush(slang_State *S) {
    stream *s = check_stream(S);
    if (s == NULL) return SLANG_ERROR;
    if (!s->deflating) {
        slang_pushstring(S, "");
        return 1;
    }
    return run(S, s, "", 0, Z_SYNC_FLUSH);
}

static int stream_finish(slang_State *S) {
    stream *s = check_stream(S);
    if (s == NULL) return SLANG_ERROR;
    if (s->deflating) {
        int r = run(S, s, "", 0, Z_FINISH);
        stream_finalize(s);
        return r;
    }
    int ended = s->ended;
    stream_finalize(s);
    if (!ended) return slang_error(S, "zlib: the compressed data is cut short");
    slang_pushstring(S, "");
    return 1;
}

static int stream_is_done(slang_State *S) {
    stream *s = slang_checkudata(S, 1, stream_tname);
    if (s == NULL) return SLANG_ERROR;
    slang_pushbool(S, s->ended || !s->inited);
    return 1;
}

static int l_version(slang_State *S) {
    slang_pushstring(S, zlibVersion());
    return 1;
}

static const slang_Reg stream_methods[] = {
    {"push", stream_push},
    {"flush", stream_flush},
    {"finish", stream_finish},
    {"is_done", stream_is_done},
    {NULL, NULL},
};

static const slang_Reg funcs[] = {
    {"deflate", l_deflate},
    {"inflate", l_inflate},
    {"compressor", l_compressor},
    {"decompressor", l_decompressor},
    {"version", l_version},
    {NULL, NULL},
};

SLANG_EXTENSION(zlib) {
    slang_newtable(S);
    slang_newmodule(S, stream_methods);
    slang_setfield(S, -2, "__index");
    slang_pushstring(S, stream_tname);
    slang_setfield(S, -2, "__type");
    stream_meta_ref = slang_ref(S);
    slang_newmodule(S, funcs);
    return 1;
}
