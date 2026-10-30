/*
 * sqlite: a native extension exposing SQLite (https://sqlite.org) to slang,
 * as thin as it is useful; slang/sqlite builds the friendly API on it.
 *
 *   local sqlite = require("sqlite")
 *   local db = sqlite.open("todos.db")        // or ":memory:"
 *   db:exec("create table t(id integer primary key, name text)")
 *   local st = db:prepare("insert into t(name) values (?)")
 *   st:bind_all({"ada"}) st:step() st:reset()
 *   local q = db:prepare("select * from t where id > ?")
 *   q:bind(1, 0)
 *   for(q:step()){ print(q:row().name, "\n") }
 *
 * Databases and statements are userdata; a statement is linked to its
 * database, so closing or collecting either first is safe: closing the
 * database finalizes its statements, and a finalized statement raises on
 * use. Values: null, bool (bound as 0/1), int, double, string (text; a blob
 * column also comes back as a string). A column declared boolean (or bool)
 * is read as true/false.
 *
 * stmt:run_async(cb) runs a bound statement to the end on libuv's thread
 * pool (through the C API of the uv extension, see slang_uv.h) and calls
 * cb(err, {rows, changes, last_insert_rowid}) from the loop. Until then the
 * statement is busy: using it raises, and the database cannot be closed
 * (collecting it waits). The connection is opened in serialized mode, so
 * the loop thread can use it while a query runs.
 */
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include "slang.h"
#include "slang_uv.h"

typedef struct stmt stmt;

typedef struct db {
    sqlite3 *handle;
    stmt *stmts;    /* the live statements of this database */
    int users;      /* the userdata plus one per live statement */
    int busy;       /* async queries that have not finished */
    int close_pending; /* the userdata was collected while busy */
} db;

struct stmt {
    sqlite3_stmt *handle;
    db *owner;
    stmt *prev, *next;
    int ncols;
    char *is_bool;  /* per column: declared boolean */
    int busy;       /* an async query is running it */
};

static const char *db_tname = "sqlite.db";
static const char *stmt_tname = "sqlite.stmt";
static int db_meta_ref = SLANG_REFNULL;
static int stmt_meta_ref = SLANG_REFNULL;

/* ---- lifetime ---- */

static void db_release(db *d) {
    if (--d->users == 0) free(d);
}

/* finalizes the sqlite statement; the struct stays until its userdata goes */
static void stmt_drop(stmt *s) {
    if (s->handle != NULL) {
        sqlite3_finalize(s->handle);
        s->handle = NULL;
    }
    free(s->is_bool);
    s->is_bool = NULL;
    s->ncols = 0;
    if (s->owner != NULL) {
        if (s->prev != NULL) s->prev->next = s->next;
        else s->owner->stmts = s->next;
        if (s->next != NULL) s->next->prev = s->prev;
        s->prev = s->next = NULL;
        db_release(s->owner);
        s->owner = NULL;
    }
}

static void db_shutdown(db *d) {
    while (d->stmts != NULL) stmt_drop(d->stmts);
    if (d->handle != NULL) {
        sqlite3_close(d->handle);
        d->handle = NULL;
    }
}

static void db_finalize(void *data) {
    db *d = *(db **)data;
    if (d->busy > 0) {
        /* the last async query to finish shuts it down */
        d->close_pending = 1;
        return;
    }
    db_shutdown(d);
    db_release(d);
}

static void stmt_finalize(void *data) {
    stmt *s = *(stmt **)data;
    stmt_drop(s);
    free(s);
}

static db *check_db(slang_State *S, int idx) {
    db **box = slang_checkudata(S, idx, db_tname);
    if (box == NULL) return NULL;
    if ((*box)->handle == NULL) {
        slang_error(S, "sqlite: the database is closed");
        return NULL;
    }
    return *box;
}

static stmt *check_stmt(slang_State *S, int idx) {
    stmt **box = slang_checkudata(S, idx, stmt_tname);
    if (box == NULL) return NULL;
    if ((*box)->handle == NULL) {
        slang_error(S, "sqlite: the statement is finalized");
        return NULL;
    }
    if ((*box)->busy) {
        slang_error(S, "sqlite: the statement is in use by a query that has not finished");
        return NULL;
    }
    return *box;
}

static int db_error(slang_State *S, sqlite3 *h) {
    return slang_error(S, "sqlite: %s", sqlite3_errmsg(h));
}

/* ---- database ---- */

static int l_open(slang_State *S) {
    const char *path = slang_checklstring(S, 1, NULL);
    if (path == NULL) return SLANG_ERROR;
    sqlite3 *h = NULL;
    int rc = sqlite3_open_v2(path, &h, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL);
    if (rc != SQLITE_OK) {
        slang_error(S, "sqlite: cannot open %s: %s", path, h ? sqlite3_errmsg(h) : "out of memory");
        if (h) sqlite3_close(h);
        return SLANG_ERROR;
    }
    db *d = calloc(1, sizeof(db));
    d->handle = h;
    d->users = 1;
    db **box = slang_newuserdata(S, sizeof(db *), db_tname, db_finalize);
    *box = d;
    slang_getref(S, db_meta_ref);
    slang_setmetatable(S, -2);
    return 1;
}

static int db_exec(slang_State *S) {
    db *d = check_db(S, 1);
    if (d == NULL) return SLANG_ERROR;
    const char *sql = slang_checklstring(S, 2, NULL);
    if (sql == NULL) return SLANG_ERROR;
    char *err = NULL;
    if (sqlite3_exec(d->handle, sql, NULL, NULL, &err) != SQLITE_OK) {
        slang_error(S, "sqlite: %s", err ? err : "error");
        sqlite3_free(err);
        return SLANG_ERROR;
    }
    return 0;
}

static int db_prepare(slang_State *S) {
    db *d = check_db(S, 1);
    if (d == NULL) return SLANG_ERROR;
    size_t len = 0;
    const char *sql = slang_checklstring(S, 2, &len);
    if (sql == NULL) return SLANG_ERROR;
    sqlite3_stmt *h = NULL;
    if (sqlite3_prepare_v2(d->handle, sql, (int)len, &h, NULL) != SQLITE_OK) return db_error(S, d->handle);
    if (h == NULL) return slang_error(S, "sqlite: no statement in the text");
    stmt *s = calloc(1, sizeof(stmt));
    s->handle = h;
    s->owner = d;
    s->next = d->stmts;
    if (d->stmts != NULL) d->stmts->prev = s;
    d->stmts = s;
    d->users++;
    s->ncols = sqlite3_column_count(h);
    s->is_bool = calloc((size_t)s->ncols + 1, 1);
    for (int i = 0; i < s->ncols; i++) {
        const char *decl = sqlite3_column_decltype(h, i);
        if (decl != NULL && (strcasecmp(decl, "boolean") == 0 || strcasecmp(decl, "bool") == 0)) s->is_bool[i] = 1;
    }
    stmt **box = slang_newuserdata(S, sizeof(stmt *), stmt_tname, stmt_finalize);
    *box = s;
    slang_getref(S, stmt_meta_ref);
    slang_setmetatable(S, -2);
    return 1;
}

static int db_close(slang_State *S) {
    db **box = slang_checkudata(S, 1, db_tname);
    if (box == NULL) return SLANG_ERROR;
    if ((*box)->busy > 0) return slang_error(S, "sqlite: cannot close the database while queries are running");
    db_shutdown(*box);
    return 0;
}

static int db_is_open(slang_State *S) {
    db **box = slang_checkudata(S, 1, db_tname);
    if (box == NULL) return SLANG_ERROR;
    slang_pushbool(S, (*box)->handle != NULL);
    return 1;
}

static int db_changes(slang_State *S) {
    db *d = check_db(S, 1);
    if (d == NULL) return SLANG_ERROR;
    slang_pushint(S, sqlite3_changes64(d->handle));
    return 1;
}

static int db_last_insert_rowid(slang_State *S) {
    db *d = check_db(S, 1);
    if (d == NULL) return SLANG_ERROR;
    slang_pushint(S, sqlite3_last_insert_rowid(d->handle));
    return 1;
}

/* ---- statements ---- */

/* binds the value at idx to parameter i (1-based) */
static int bind_value(slang_State *S, stmt *s, int i, int idx) {
    int rc;
    switch (slang_type(S, idx)) {
    case SLANG_TNULL: rc = sqlite3_bind_null(s->handle, i); break;
    case SLANG_TBOOL: rc = sqlite3_bind_int(s->handle, i, slang_tobool(S, idx) ? 1 : 0); break;
    case SLANG_TINT: rc = sqlite3_bind_int64(s->handle, i, slang_toint(S, idx)); break;
    case SLANG_TDOUBLE: rc = sqlite3_bind_double(s->handle, i, slang_todouble(S, idx)); break;
    case SLANG_TSTRING: {
        size_t len = 0;
        const char *text = slang_tolstring(S, idx, &len);
        rc = sqlite3_bind_text64(s->handle, i, text, (sqlite3_uint64)len, SQLITE_TRANSIENT, SQLITE_UTF8);
        break;
    }
    case SLANG_TUSERDATA: {
        /* a slang buffer is a blob */
        size_t len = 0;
        const char *bytes = slang_tobytes(S, idx, &len);
        if (bytes != NULL && !slang_isstring(S, idx)) {
            rc = sqlite3_bind_blob64(s->handle, i, bytes, (sqlite3_uint64)len, SQLITE_TRANSIENT);
            break;
        }
        return slang_error(S, "sqlite: cannot bind a %s (parameter %d)", slang_typename(slang_type(S, idx)), i);
    }
    default:
        return slang_error(S, "sqlite: cannot bind a %s (parameter %d)", slang_typename(slang_type(S, idx)), i);
    }
    if (rc != SQLITE_OK) return slang_error(S, "sqlite: parameter %d: %s", i, sqlite3_errmsg(s->owner->handle));
    return SLANG_OK;
}

static int stmt_bind(slang_State *S) {
    stmt *s = check_stmt(S, 1);
    if (s == NULL) return SLANG_ERROR;
    int64_t i = slang_checkint(S, 2);
    if (slang_failed(S)) return SLANG_ERROR;
    if (bind_value(S, s, (int)i, 3) != SLANG_OK) return SLANG_ERROR;
    slang_pushvalue(S, 1);
    return 1;
}

/* bind_all(values, [count]) -> self */
static int stmt_bind_all(slang_State *S) {
    stmt *s = check_stmt(S, 1);
    if (s == NULL) return SLANG_ERROR;
    slang_checktable(S, 2);
    if (slang_failed(S)) return SLANG_ERROR;
    /* the count, when given, covers values after a null (which ends a
     * list's length) */
    int64_t n = slang_isint(S, 3) ? slang_toint(S, 3) : slang_rawlen(S, 2);
    int expected = sqlite3_bind_parameter_count(s->handle);
    if (n != expected) return slang_error(S, "sqlite: %d parameter(s) expected, %d given", expected, (int)n);
    for (int64_t i = 0; i < n; i++) {
        slang_rawgeti(S, 2, i);
        int rc = bind_value(S, s, (int)i + 1, -1);
        slang_settop(S, 2);
        if (rc != SLANG_OK) return SLANG_ERROR;
    }
    slang_pushvalue(S, 1);
    return 1;
}

static int stmt_step(slang_State *S) {
    stmt *s = check_stmt(S, 1);
    if (s == NULL) return SLANG_ERROR;
    int rc = sqlite3_step(s->handle);
    if (rc == SQLITE_ROW) {
        slang_pushbool(S, true);
        return 1;
    }
    if (rc == SQLITE_DONE) {
        slang_pushbool(S, false);
        return 1;
    }
    slang_error(S, "sqlite: %s", sqlite3_errmsg(s->owner->handle));
    sqlite3_reset(s->handle);
    return SLANG_ERROR;
}

static void push_column(slang_State *S, stmt *s, int i) {
    switch (sqlite3_column_type(s->handle, i)) {
    case SQLITE_INTEGER:
        if (s->is_bool[i]) slang_pushbool(S, sqlite3_column_int64(s->handle, i) != 0);
        else slang_pushint(S, sqlite3_column_int64(s->handle, i));
        break;
    case SQLITE_FLOAT: slang_pushdouble(S, sqlite3_column_double(s->handle, i)); break;
    case SQLITE_TEXT:
        slang_pushlstring(S, (const char *)sqlite3_column_text(s->handle, i), (size_t)sqlite3_column_bytes(s->handle, i));
        break;
    case SQLITE_BLOB: {
        const void *blob = sqlite3_column_blob(s->handle, i);
        slang_pushlstring(S, blob ? blob : "", (size_t)sqlite3_column_bytes(s->handle, i));
        break;
    }
    default: slang_pushnull(S); break;
    }
}

/* row() -> {name: value, ...} of the current row */
static int stmt_row(slang_State *S) {
    stmt *s = check_stmt(S, 1);
    if (s == NULL) return SLANG_ERROR;
    slang_newtable(S);
    for (int i = 0; i < s->ncols; i++) {
        push_column(S, s, i);
        slang_setfield(S, -2, sqlite3_column_name(s->handle, i));
    }
    return 1;
}

/* values() -> {value, ...} of the current row */
static int stmt_values(slang_State *S) {
    stmt *s = check_stmt(S, 1);
    if (s == NULL) return SLANG_ERROR;
    slang_newtable(S);
    for (int i = 0; i < s->ncols; i++) {
        push_column(S, s, i);
        slang_append(S, -2);
    }
    return 1;
}

static int stmt_columns(slang_State *S) {
    stmt *s = check_stmt(S, 1);
    if (s == NULL) return SLANG_ERROR;
    slang_newtable(S);
    for (int i = 0; i < s->ncols; i++) {
        slang_pushstring(S, sqlite3_column_name(s->handle, i));
        slang_append(S, -2);
    }
    return 1;
}

static int stmt_parameter_count(slang_State *S) {
    stmt *s = check_stmt(S, 1);
    if (s == NULL) return SLANG_ERROR;
    slang_pushint(S, sqlite3_bind_parameter_count(s->handle));
    return 1;
}

/* reset() -> self: ready to run again, bindings cleared */
static int stmt_reset(slang_State *S) {
    stmt *s = check_stmt(S, 1);
    if (s == NULL) return SLANG_ERROR;
    sqlite3_reset(s->handle);
    sqlite3_clear_bindings(s->handle);
    slang_pushvalue(S, 1);
    return 1;
}

static int stmt_finalize_m(slang_State *S) {
    stmt **box = slang_checkudata(S, 1, stmt_tname);
    if (box == NULL) return SLANG_ERROR;
    if ((*box)->busy) return slang_error(S, "sqlite: the statement is in use by a query that has not finished");
    stmt_drop(*box);
    return 0;
}

/* ---- queries on the thread pool ---- */

typedef struct cell {
    int type;
    int64_t i;
    double d;
    char *s;
    size_t n;
} cell;

typedef struct query_job {
    stmt *s;
    db *d;
    int ncols;
    cell *cells;          /* row after row, ncols each */
    size_t nrows, cap;
    char *err;
    int64_t changes, last_id;
} query_job;

/* on a pool thread: steps the statement to the end, copying the rows; each
 * step holds the connection's mutex, so the error message is its own */
static void query_work(void *data) {
    query_job *j = data;
    sqlite3 *dbh = j->d->handle;
    sqlite3_stmt *h = j->s->handle;
    sqlite3_mutex *m = sqlite3_db_mutex(dbh);
    for (;;) {
        sqlite3_mutex_enter(m);
        int rc = sqlite3_step(h);
        if (rc == SQLITE_ROW) {
            if (j->nrows == j->cap) {
                j->cap = j->cap ? j->cap * 2 : 16;
                j->cells = realloc(j->cells, j->cap * (size_t)(j->ncols > 0 ? j->ncols : 1) * sizeof(cell));
            }
            cell *row = j->cells + j->nrows * (size_t)j->ncols;
            for (int i = 0; i < j->ncols; i++) {
                cell *c = &row[i];
                memset(c, 0, sizeof *c);
                c->type = sqlite3_column_type(h, i);
                switch (c->type) {
                case SQLITE_INTEGER: c->i = sqlite3_column_int64(h, i); break;
                case SQLITE_FLOAT: c->d = sqlite3_column_double(h, i); break;
                case SQLITE_TEXT:
                case SQLITE_BLOB: {
                    const void *p = c->type == SQLITE_TEXT ? (const void *)sqlite3_column_text(h, i) : sqlite3_column_blob(h, i);
                    c->n = (size_t)sqlite3_column_bytes(h, i);
                    c->s = malloc(c->n + 1);
                    if (p != NULL) memcpy(c->s, p, c->n);
                    c->s[c->n] = 0;
                    break;
                }
                default: break;
                }
            }
            j->nrows++;
            sqlite3_mutex_leave(m);
            continue;
        }
        if (rc != SQLITE_DONE) j->err = strdup(sqlite3_errmsg(dbh));
        j->changes = sqlite3_changes64(dbh);
        j->last_id = sqlite3_last_insert_rowid(dbh);
        sqlite3_reset(h);
        sqlite3_mutex_leave(m);
        break;
    }
}

static int query_push(slang_State *S, void *data) {
    query_job *j = data;
    if (j->err != NULL) {
        slang_pushfstring(S, "sqlite: %s", j->err);
        slang_pushnull(S);
        return 2;
    }
    slang_pushnull(S);
    slang_newtable(S);
    slang_newtable(S);
    for (size_t r = 0; r < j->nrows; r++) {
        cell *row = j->cells + r * (size_t)j->ncols;
        slang_newtable(S);
        for (int i = 0; i < j->ncols; i++) {
            cell *c = &row[i];
            switch (c->type) {
            case SQLITE_INTEGER:
                if (j->s->is_bool[i]) slang_pushbool(S, c->i != 0);
                else slang_pushint(S, c->i);
                break;
            case SQLITE_FLOAT: slang_pushdouble(S, c->d); break;
            case SQLITE_TEXT:
            case SQLITE_BLOB: slang_pushlstring(S, c->s, c->n); break;
            default: slang_pushnull(S); break;
            }
            slang_setfield(S, -2, sqlite3_column_name(j->s->handle, i));
        }
        slang_append(S, -2);
    }
    slang_setfield(S, -2, "rows");
    slang_pushint(S, j->changes);
    slang_setfield(S, -2, "changes");
    slang_pushint(S, j->last_id);
    slang_setfield(S, -2, "last_insert_rowid");
    return 2;
}

static void query_done(void *data) {
    query_job *j = data;
    for (size_t k = 0; k < j->nrows * (size_t)j->ncols; k++) free(j->cells[k].s);
    free(j->cells);
    free(j->err);
    j->s->busy = 0;
    db *d = j->d;
    if (--d->busy == 0 && d->close_pending) {
        db_shutdown(d);
        db_release(d);
    }
    free(j);
}

/* the C API of the uv extension, from require("uv").c_api */
static const slang_uv_api *uv_api = NULL;

static const slang_uv_api *get_uv_api(slang_State *S) {
    if (uv_api != NULL) return uv_api;
    int top = slang_gettop(S);
    slang_getglobal(S, "require");
    slang_pushstring(S, "uv");
    if (slang_call(S, 1) != SLANG_OK) return NULL;
    slang_getfield(S, -1, "c_api");
    uv_api = slang_uv_get(S, -1);
    slang_settop(S, top);
    if (uv_api == NULL) slang_error(S, "sqlite: the uv extension does not offer a compatible C API");
    return uv_api;
}

/* run_async(cb(err, {rows, changes, last_insert_rowid})) */
static int stmt_run_async(slang_State *S) {
    stmt *s = check_stmt(S, 1);
    slang_checkfunction(S, 2);
    if (s == NULL || slang_failed(S)) return SLANG_ERROR;
    const slang_uv_api *api = get_uv_api(S);
    if (api == NULL) return SLANG_ERROR;
    query_job *j = calloc(1, sizeof(query_job));
    j->s = s;
    j->d = s->owner;
    j->ncols = s->ncols;
    s->busy = 1;
    s->owner->busy++;
    return api->queue(S, 2, 1, query_work, query_push, query_done, j);
}

static int stmt_is_busy(slang_State *S) {
    stmt **box = slang_checkudata(S, 1, stmt_tname);
    if (box == NULL) return SLANG_ERROR;
    slang_pushbool(S, (*box)->busy != 0);
    return 1;
}

static int l_version(slang_State *S) {
    slang_pushstring(S, sqlite3_libversion());
    return 1;
}

/* ---- module ---- */

static const slang_Reg db_methods[] = {
    {"exec", db_exec},
    {"prepare", db_prepare},
    {"close", db_close},
    {"is_open", db_is_open},
    {"changes", db_changes},
    {"last_insert_rowid", db_last_insert_rowid},
    {NULL, NULL},
};

static const slang_Reg stmt_methods[] = {
    {"bind", stmt_bind},
    {"bind_all", stmt_bind_all},
    {"step", stmt_step},
    {"row", stmt_row},
    {"values", stmt_values},
    {"columns", stmt_columns},
    {"parameter_count", stmt_parameter_count},
    {"reset", stmt_reset},
    {"finalize", stmt_finalize_m},
    {"run_async", stmt_run_async},
    {"is_busy", stmt_is_busy},
    {NULL, NULL},
};

static const slang_Reg funcs[] = {
    {"open", l_open},
    {"version", l_version},
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

SLANG_EXTENSION(sqlite) {
    db_meta_ref = make_meta(S, db_tname, db_methods);
    stmt_meta_ref = make_meta(S, stmt_tname, stmt_methods);
    slang_newmodule(S, funcs);
    return 1;
}
