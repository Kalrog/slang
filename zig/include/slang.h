/*
 * slang.h: the C API of the slang virtual machine.
 *
 * Used by native extensions (shared libraries loaded by require) and by
 * host programs that embed the VM. The design follows Lua's: a slang_State
 * is a thread with a value stack, values are addressed by stack index and
 * never exposed directly, so native code cannot create dangling references
 * and the VM's internals may change freely.
 *
 * Stack indices: 1..n are the values of the current function's frame (its
 * arguments come first), negative indices count from the top (-1 is the top).
 * slang_upvalueindex(i) addresses the i-th upvalue of a C closure.
 *
 * Errors never longjmp. A function that can fail returns SLANG_ERROR and
 * leaves the error pending in the state; a native function propagates it by
 * returning SLANG_ERROR itself, or handles it with slang_pusherror. The
 * slang_check* helpers record an error and return a dummy value; test
 * slang_failed(S) after the checks.
 *
 * A native function receives its arguments at indices 1..slang_gettop(S) and
 * returns 1 when its result is on top of the stack, 0 to return null, or
 * SLANG_ERROR.
 *
 * Memory: the collector runs only while slang code runs (inside slang_call
 * and friends). Values on the stack, in a table reachable from the globals
 * or held through slang_ref stay alive; pointers returned by slang_tostring
 * and slang_touserdata are valid as long as the value they belong to is.
 */
#ifndef SLANG_H
#define SLANG_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SLANG_API_VERSION 1

#if defined(_WIN32)
#define SLANG_EXPORT __declspec(dllexport)
#else
#define SLANG_EXPORT __attribute__((visibility("default")))
#endif

#define SLANG_OK 0
#define SLANG_ERROR (-1)

typedef struct slang_State slang_State;
typedef int (*slang_CFunction)(slang_State *S);
typedef void (*slang_Finalizer)(void *data);

typedef struct slang_Reg {
    const char *name;
    slang_CFunction func;
} slang_Reg;

enum {
    SLANG_TNONE = -1, /* an index that is not on the stack */
    SLANG_TNULL = 0,
    SLANG_TBOOL,
    SLANG_TINT,
    SLANG_TDOUBLE,
    SLANG_TSTRING,
    SLANG_TTABLE,
    SLANG_TFUNCTION,
    SLANG_TUSERDATA,
    SLANG_TTHREAD
};

#define SLANG_UPVALUE_BASE (-1000000)
#define slang_upvalueindex(i) (SLANG_UPVALUE_BASE - (i))

/* Reference returned by slang_ref for null. */
#define SLANG_REFNULL 0

/* ---- stack ---- */
SLANG_EXPORT int slang_gettop(slang_State *S);
SLANG_EXPORT void slang_settop(slang_State *S, int idx);
SLANG_EXPORT void slang_pushvalue(slang_State *S, int idx);
SLANG_EXPORT void slang_remove(slang_State *S, int idx);
SLANG_EXPORT void slang_insert(slang_State *S, int idx);
SLANG_EXPORT void slang_copy(slang_State *S, int from, int to);
#define slang_pop(S, n) slang_settop(S, -(n) - 1)

SLANG_EXPORT int slang_type(slang_State *S, int idx);
SLANG_EXPORT const char *slang_typename(int type);
#define slang_isnull(S, i) (slang_type(S, i) == SLANG_TNULL)
#define slang_isnone(S, i) (slang_type(S, i) == SLANG_TNONE)
#define slang_isbool(S, i) (slang_type(S, i) == SLANG_TBOOL)
#define slang_isint(S, i) (slang_type(S, i) == SLANG_TINT)
#define slang_isdouble(S, i) (slang_type(S, i) == SLANG_TDOUBLE)
#define slang_isnumber(S, i) (slang_isint(S, i) || slang_isdouble(S, i))
#define slang_isstring(S, i) (slang_type(S, i) == SLANG_TSTRING)
#define slang_istable(S, i) (slang_type(S, i) == SLANG_TTABLE)
#define slang_isfunction(S, i) (slang_type(S, i) == SLANG_TFUNCTION)
#define slang_isuserdata(S, i) (slang_type(S, i) == SLANG_TUSERDATA)

/* ---- push ---- */
SLANG_EXPORT void slang_pushnull(slang_State *S);
SLANG_EXPORT void slang_pushbool(slang_State *S, bool b);
SLANG_EXPORT void slang_pushint(slang_State *S, int64_t i);
SLANG_EXPORT void slang_pushdouble(slang_State *S, double d);
SLANG_EXPORT void slang_pushstring(slang_State *S, const char *s);
SLANG_EXPORT void slang_pushlstring(slang_State *S, const char *s, size_t len);
SLANG_EXPORT void slang_pushfstring(slang_State *S, const char *fmt, ...);
/* A native function; name appears in stack traces. */
SLANG_EXPORT void slang_pushcfunction(slang_State *S, slang_CFunction f, const char *name);
/* A native function with nup upvalues, popped from the stack. */
SLANG_EXPORT void slang_pushcclosure(slang_State *S, slang_CFunction f, const char *name, int nup);

/* ---- read ---- */
SLANG_EXPORT bool slang_tobool(slang_State *S, int idx); /* truthiness */
SLANG_EXPORT int64_t slang_toint(slang_State *S, int idx); /* 0 unless int; doubles truncate */
SLANG_EXPORT double slang_todouble(slang_State *S, int idx); /* 0 unless a number */
/* NULL unless a string. The bytes are NUL terminated; len receives the
 * length, which may be larger when the string contains NUL bytes. */
SLANG_EXPORT const char *slang_tolstring(slang_State *S, int idx, size_t *len);
#define slang_tostring(S, i) slang_tolstring(S, i, NULL)
SLANG_EXPORT void *slang_touserdata(slang_State *S, int idx);
SLANG_EXPORT slang_State *slang_tothread(slang_State *S, int idx);

/* ---- argument checks: record an error and return a dummy on failure ---- */
SLANG_EXPORT int64_t slang_checkint(slang_State *S, int idx);
SLANG_EXPORT double slang_checknumber(slang_State *S, int idx);
SLANG_EXPORT const char *slang_checklstring(slang_State *S, int idx, size_t *len);
#define slang_checkstring(S, i) slang_checklstring(S, i, NULL)
SLANG_EXPORT void slang_checktable(slang_State *S, int idx);
SLANG_EXPORT void slang_checkfunction(slang_State *S, int idx);
SLANG_EXPORT void *slang_checkudata(slang_State *S, int idx, const char *tname);
SLANG_EXPORT int64_t slang_optint(slang_State *S, int idx, int64_t def);
SLANG_EXPORT double slang_optnumber(slang_State *S, int idx, double def);
SLANG_EXPORT const char *slang_optstring(slang_State *S, int idx, const char *def);
/* Whether an error is pending (set by a failed check, slang_error or a
 * failed call). */
SLANG_EXPORT bool slang_failed(slang_State *S);

/* ---- errors ---- */
/* Records an error with a printf-style message; returns SLANG_ERROR. */
SLANG_EXPORT int slang_error(slang_State *S, const char *fmt, ...);
/* "bad argument #arg to 'fn' (msg)"; returns SLANG_ERROR. */
SLANG_EXPORT int slang_argerror(slang_State *S, int arg, const char *msg);
/* Pops an error value (an error table or a string) and makes it the
 * pending error; returns SLANG_ERROR. */
SLANG_EXPORT int slang_raise(slang_State *S);
/* Pushes the pending error as a table {message, location, stack} and clears
 * it (pushes null when there is none). */
SLANG_EXPORT void slang_pusherror(slang_State *S);
/* Discards the pending error. */
SLANG_EXPORT void slang_clearerror(slang_State *S);
/* The message of the pending error, or NULL. Valid until the error is
 * cleared or replaced. */
SLANG_EXPORT const char *slang_errormessage(slang_State *S);

/* ---- tables ---- */
SLANG_EXPORT void slang_newtable(slang_State *S);
/* t[k]: pops the key, pushes the value (metamethods apply, so these can
 * fail). On failure nothing is pushed. */
SLANG_EXPORT int slang_gettable(slang_State *S, int idx);
SLANG_EXPORT int slang_getfield(slang_State *S, int idx, const char *name);
SLANG_EXPORT int slang_geti(slang_State *S, int idx, int64_t i);
/* t[k] = v: pops the value (and the key for slang_settable). */
SLANG_EXPORT int slang_settable(slang_State *S, int idx);
SLANG_EXPORT int slang_setfield(slang_State *S, int idx, const char *name);
SLANG_EXPORT int slang_seti(slang_State *S, int idx, int64_t i);
/* Raw access (no metamethods); the table must be a table. */
SLANG_EXPORT void slang_rawget(slang_State *S, int idx);
SLANG_EXPORT void slang_rawgeti(slang_State *S, int idx, int64_t i);
SLANG_EXPORT void slang_rawset(slang_State *S, int idx);
SLANG_EXPORT void slang_rawseti(slang_State *S, int idx, int64_t i);
/* The number of entries of a table or bytes of a string, no metamethods. */
SLANG_EXPORT int64_t slang_rawlen(slang_State *S, int idx);
/* len(v) with __len; pushes the result. */
SLANG_EXPORT int slang_len(slang_State *S, int idx);
/* Pops a value and appends it to the array part of the table. */
SLANG_EXPORT void slang_append(slang_State *S, int idx);
/* Iteration: pops a key (null to start) and pushes the next key and value
 * in iteration order, or returns 0 when there are no more entries. */
SLANG_EXPORT int slang_next(slang_State *S, int idx);
/* Pushes the metatable of a table or userdata, or returns 0 and pushes
 * nothing. */
SLANG_EXPORT int slang_getmetatable(slang_State *S, int idx);
/* Pops a table (or null) and makes it the metatable of the table or
 * userdata at idx. */
SLANG_EXPORT void slang_setmetatable(slang_State *S, int idx);

/* ---- globals and calls ---- */
SLANG_EXPORT void slang_getglobal(slang_State *S, const char *name);
SLANG_EXPORT void slang_setglobal(slang_State *S, const char *name); /* pops */
/* Calls the function below the nargs arguments on top of the stack. Pops
 * them all and pushes the result; on failure pushes nothing and returns
 * SLANG_ERROR with the error pending. */
SLANG_EXPORT int slang_call(slang_State *S, int nargs);
/* type(v) with __type; pushes the result. */
SLANG_EXPORT int slang_typeof(slang_State *S, int idx);
/* string(v) with __tostring; pushes the result. */
SLANG_EXPORT int slang_tostr(slang_State *S, int idx);

/* ---- userdata ---- */
/* Pushes a new userdata with a zeroed block of size bytes; tname is the
 * type checked by slang_checkudata (compared by content), fin runs when the
 * collector frees the object. It gets the metatable slang_settypemeta set
 * for tname in this VM, if any. */
SLANG_EXPORT void *slang_newuserdata(slang_State *S, size_t size, const char *tname, slang_Finalizer fin);
/* The block of the userdata at idx if it has the given type, else NULL. */
SLANG_EXPORT void *slang_testudata(slang_State *S, int idx, const char *tname);

/* ---- buffers (slang/buffer): typed memory C reads and writes in place ----
 *
 * The memory of a buffer stays where it is (the collector does not move
 * objects) and is valid while the buffer is reachable: on the stack during
 * a call, or held with slang_ref. Element types are named as slang/ctypes
 * names them: bool, char, int8, uint8, int16, uint16, int32, uint32, int64,
 * uint64, float, double. */
/* The memory of the buffer at idx and its number of elements and element
 * size (either may be NULL), or NULL when the value is not a buffer. */
SLANG_EXPORT void *slang_tobuffer(slang_State *S, int idx, size_t *count, size_t *elem_size);
/* Like slang_tobuffer, recording an argument error when it is not one. */
SLANG_EXPORT void *slang_checkbuffer(slang_State *S, int idx, size_t *count, size_t *elem_size);
/* The element type of the buffer at idx ("float", ...; "struct" for a
 * buffer of structs), or NULL when the value is not a buffer. */
SLANG_EXPORT const char *slang_buffertype(slang_State *S, int idx);
/* Pushes a new buffer of count zeroed elements of a scalar type and returns
 * its memory for C to fill; NULL (an error recorded, nothing pushed) for an
 * unknown type. */
SLANG_EXPORT void *slang_newbuffer(slang_State *S, const char *type, size_t count);

/* Binary data: the bytes of a string or of a buffer and their length, or
 * NULL for other values. A string's bytes are NUL terminated, a buffer's
 * are not. For functions that take bytes (compression, hashing, writing to
 * a socket), so slang code can pass either. */
SLANG_EXPORT const char *slang_tobytes(slang_State *S, int idx, size_t *len);
/* Like slang_tobytes, recording an argument error for other values. */
SLANG_EXPORT const char *slang_checkbytes(slang_State *S, int idx, size_t *len);

/* ---- references: keep values alive across calls ---- */
SLANG_EXPORT int slang_ref(slang_State *S); /* pops */
SLANG_EXPORT void slang_getref(slang_State *S, int ref); /* pushes */
SLANG_EXPORT void slang_unref(slang_State *S, int ref);

/* ---- per-VM state for extensions ----
 *
 * require opens an extension once in every VM that loads it, and an
 * isolate (slang/isolate) is a VM of its own on another OS thread, while
 * the extension's C statics are shared by all of them. So whatever belongs
 * to one VM (a reference, a metatable, an event loop) must not live in a
 * static: types register their metatable with slang_settypemeta, the rest
 * goes in extension data.
 *
 * slang_settypemeta pops a table and makes it the metatable of the userdata
 * of type tname that slang_newuserdata makes in this VM from then on;
 * slang_gettypemeta pushes it and returns 1, or pushes null and returns 0.
 *
 * slang_setextdata keeps data for key in this VM (key: the address of a
 * static of the extension's, so that keys never clash); fin(data) runs when
 * the VM is closed, after every value of it is gone (userdata finalizers
 * have run), in the reverse order of the first slang_setextdata of each
 * key. Setting a key again replaces data and fin without running the old
 * fin; NULL data removes the key. slang_getextdata returns the data or
 * NULL.
 *
 * slang_onclose(S, f, data) registers f(data), run when the VM is closed
 * but before its values are freed, the last registered first: where an
 * extension stops what still works on its values (threads, I/O in flight)
 * so that their finalizers do not pull memory from under it. No slang code
 * runs at that point.
 *
 * slang_oninterrupt(S, f, data) registers f(data), called when the VM's
 * isolate is killed, on the killing OS thread with a lock held: it must
 * only wake what the VM waits on outside the interpreter (an event loop
 * blocked in the kernel), which then returns; the next safe point raises
 * "isolate killed". slang_oninterrupt(S, NULL, data) removes the hooks of
 * data. Hooks are dropped when the VM closes, before extension data is
 * finalized. slang_interrupted tells whether the VM is being killed. */
SLANG_EXPORT void slang_settypemeta(slang_State *S, const char *tname);
SLANG_EXPORT int slang_gettypemeta(slang_State *S, const char *tname);
SLANG_EXPORT void *slang_getextdata(slang_State *S, const void *key);
SLANG_EXPORT void slang_setextdata(slang_State *S, const void *key, void *data, slang_Finalizer fin);
SLANG_EXPORT void slang_onclose(slang_State *S, slang_Finalizer f, void *data);
SLANG_EXPORT void slang_oninterrupt(slang_State *S, slang_Finalizer f, void *data);
SLANG_EXPORT bool slang_interrupted(slang_State *S);

/* ---- modules ---- */
/* Pushes a table holding the functions of the NULL-terminated list. */
SLANG_EXPORT void slang_newmodule(slang_State *S, const slang_Reg *l);
/* Stores the functions in the table on top of the stack. */
SLANG_EXPORT void slang_setfuncs(slang_State *S, const slang_Reg *l);

/* ---- embedding ---- */
SLANG_EXPORT int slang_version(void);
SLANG_EXPORT slang_State *slang_new(void);
SLANG_EXPORT void slang_close(slang_State *S);
/* Compiles source text to a function and pushes it. */
SLANG_EXPORT int slang_loadstring(slang_State *S, const char *src, const char *origin);
/* Compiles and runs source text; pushes the result. */
SLANG_EXPORT int slang_dostring(slang_State *S, const char *src, const char *origin);
/* Compiles (or loads, for .slb) and runs a file; pushes the result. */
SLANG_EXPORT int slang_dofile(slang_State *S, const char *path);
/* Makes the module on top of the stack available to require(name). Pops. */
SLANG_EXPORT void slang_preload(slang_State *S, const char *name);

/* ---- isolates (slang/isolate) ----
 *
 * slang_isolate_new makes a VM that shares nothing with S, for an OS thread
 * the caller owns (an audio callback, a thread pool): it has S's search
 * paths and arguments, and the value at idx copied onto its stack the way
 * a channel copies (a function crosses as bytecode and may use globals,
 * not locals of the code around it). Returns the new state, or NULL with
 * the error pending on S. Only one OS thread at a time may use the new
 * state (checked builds catch two in slang_call at once); slang_close ends
 * it. Run the function with slang_pushvalue(I, 1), its arguments and
 * slang_call(I, n).
 *
 * The channel functions work on any state, a driven one included; ch_idx
 * is a channel's stack index. slang_send pops the value on top and sends
 * it, blocking while a channel with a capacity is full; slang_trysend
 * returns 1 when it sent, 0 when the channel was full (the value is popped
 * either way). slang_receive pushes the next value, waiting for one, or
 * null once the channel is closed and empty; slang_tryreceive pushes the
 * next value and returns 1, or pushes null and returns 0 when there is
 * none. All return SLANG_ERROR with an error pending (a closed channel for
 * a send, a value that cannot cross). */
SLANG_EXPORT slang_State *slang_isolate_new(slang_State *S, int idx);
SLANG_EXPORT int slang_send(slang_State *S, int ch_idx);
SLANG_EXPORT int slang_trysend(slang_State *S, int ch_idx);
SLANG_EXPORT int slang_receive(slang_State *S, int ch_idx);
SLANG_EXPORT int slang_tryreceive(slang_State *S, int ch_idx);

/* ---- extension entry point ----
 *
 * SLANG_EXTENSION(name) { ... } defines slang_open_<name>, the function
 * require calls after loading <name>.so/.dylib/.dll; it returns the module
 * like any native function (push it and return 1). The macro also records
 * the API version the extension was built against, which the loader checks.
 * The name is the module name with '/', '-' and '.' replaced by '_'. */
#define SLANG_EXTENSION(name) \
    SLANG_EXPORT int slang_ext_version_##name(void); \
    int slang_ext_version_##name(void) { return SLANG_API_VERSION; } \
    SLANG_EXPORT int slang_open_##name(slang_State *S); \
    int slang_open_##name(slang_State *S)

#ifdef __cplusplus
}
#endif

#endif
