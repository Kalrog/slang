/*
 * webview: native windows with a WKWebView (macOS), for desktop programs
 * whose user interface is a web page and whose logic is slang, in the
 * style of Wails. slang/webview is the API to use; this is the binding.
 *
 *   local wv = require("webview")
 *   local w = wv.window({title, width, height, url | html, resizable,
 *                        debug, scheme})
 *   w:navigate(url)   w:set_html(html)   w:eval(js)   w:set_title(t)
 *   w:close()   w:is_open()
 *   w:on_close(cb())   w:on_message(cb(text))   w:on_request(cb(req, task))
 *   task:respond(status, headers, body)
 *   wv.run_once() -> bool       wv.window_count()
 *
 * The event loops. Cocoa's run loop has to own the main thread, and libuv
 * has to keep running for slang/async. run_once waits for the next Cocoa
 * event while a watcher thread polls libuv's backend descriptor; when libuv
 * has something to do, the watcher has the main thread run it (through the
 * main dispatch queue, which also runs during window resizing and menu
 * tracking). slang/webview installs run_once as slang/async's driver, so
 * async.main keeps working with windows open. libuv is reached through the
 * uv extension's C API (slang_uv.h), not linked here.
 *
 * Cocoa callbacks never enter slang directly: they queue events (a window
 * closed, a message from the page, a request to the custom scheme), and
 * the queue is flushed into slang from run_once on the main thread.
 *
 * The page gets window.slang: slang.send(value) posts a message (JSON) to
 * on_message; slang/webview builds slang.call(name, ...args) -> Promise and
 * slang.on(f) for pushes on top. With options.scheme ("app"), URLs like
 * app://localhost/x are answered by on_request without any socket: a
 * request table {method, url, headers, body} and a task to respond to.
 */
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include <sys/select.h>
#include <pthread.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include "slang.h"
#include "slang_uv.h"

/* ---- state ---- */

typedef struct window window;

static slang_State *run_S = NULL;       /* the state inside run_once */
static const slang_uv_api *uv_api = NULL;
static int app_ready = 0;
static int open_windows = 0;
static int callback_failed = 0;         /* a slang callback raised; its error is pending */
static NSEvent *wake_event = nil;

static const char *window_tname = "webview.window";
static const char *task_tname = "webview.task";

struct window {
    NSWindow *win;
    WKWebView *view;
    id delegate;
    id handler;
    id scheme_handler;
    int closed;
    int self_ref;
    int on_close_ref;
    int on_message_ref;
    int on_request_ref;
};

/* ---- the event queue (Cocoa -> slang) ---- */

enum { EV_CLOSE, EV_MESSAGE, EV_REQUEST };

typedef struct event {
    int kind;
    window *w;
    char *text;            /* message */
    id task;               /* request: the WKURLSchemeTask, retained */
    struct event *next;
} event;

static event *queue_head = NULL, *queue_tail = NULL;

static void enqueue(int kind, window *w, char *text, id task) {
    event *e = calloc(1, sizeof(event));
    e->kind = kind;
    e->w = w;
    e->text = text;
    e->task = task;
    if (queue_tail) queue_tail->next = e; else queue_head = e;
    queue_tail = e;
    /* script messages and scheme requests come from run loop callbacks,
     * not as NSEvents: wake run_once, which waits for the next NSEvent */
    if (wake_event != nil) [NSApp postEvent:wake_event atStart:NO];
}

/* ---- scheme tasks (responders) ---- */

typedef struct task_box {
    id task;          /* retained until responded or collected */
    int stopped;
    int done;
} task_box;

static NSMutableDictionary *live_tasks = nil;   /* task pointer -> NSValue of task_box* */

static void task_finalize(void *data) {
    task_box *t = data;
    if (t->task != nil) {
        if (!t->done && !t->stopped) {
            /* never answered: fail it rather than leave the page waiting */
            @try {
                [t->task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
            } @catch (NSException *e) {}
        }
        [live_tasks removeObjectForKey:[NSValue valueWithPointer:(const void *)t->task]];
        [t->task release];
        t->task = nil;
    }
}

/* task:respond(status, headers, body) */
static int task_respond(slang_State *S) {
    task_box *t = slang_checkudata(S, 1, task_tname);
    int64_t status = slang_checkint(S, 2);
    size_t blen = 0;
    const char *body = slang_isstring(S, 4) ? slang_tolstring(S, 4, &blen) : "";
    if (t == NULL || slang_failed(S)) return SLANG_ERROR;
    if (t->done) return slang_error(S, "webview: the request was answered already");
    t->done = 1;
    if (t->stopped || t->task == nil) return 0;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    if (slang_istable(S, 3)) {
        slang_pushnull(S);
        while (slang_next(S, 3)) {
            if (slang_isstring(S, -2)) {
                NSString *k = [NSString stringWithUTF8String:slang_tolstring(S, -2, NULL)];
                NSString *v = nil;
                if (slang_isstring(S, -1)) v = [NSString stringWithUTF8String:slang_tolstring(S, -1, NULL)];
                else if (slang_istable(S, -1)) {
                    /* a list (Set-Cookie): joined; WebKit keeps no cookies for custom schemes anyway */
                    NSMutableArray *parts = [NSMutableArray array];
                    int64_t n = slang_rawlen(S, -1);
                    for (int64_t i = 0; i < n; i++) {
                        slang_rawgeti(S, -1, i);
                        if (slang_isstring(S, -1)) [parts addObject:[NSString stringWithUTF8String:slang_tolstring(S, -1, NULL)]];
                        slang_pop(S, 1);
                    }
                    v = [parts componentsJoinedByString:@", "];
                } else if (slang_isint(S, -1)) v = [NSString stringWithFormat:@"%lld", (long long)slang_toint(S, -1)];
                if (k && v) headers[k] = v;
            }
            slang_pop(S, 1);
        }
    }
    @try {
        NSHTTPURLResponse *res = [[[NSHTTPURLResponse alloc] initWithURL:[t->task request].URL
                                                              statusCode:(NSInteger)status
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:headers] autorelease];
        [t->task didReceiveResponse:res];
        if (blen > 0) [t->task didReceiveData:[NSData dataWithBytes:body length:blen]];
        [t->task didFinish];
    } @catch (NSException *e) {
        /* the page went away meanwhile */
    }
    return 0;
}

/* ---- calling slang ---- */

static int begin_callback(int ref) {
    if (run_S == NULL || callback_failed || ref == SLANG_REFNULL) return 0;
    slang_getref(run_S, ref);
    return 1;
}

static void finish_callback(int nargs) {
    if (slang_call(run_S, nargs) != SLANG_OK) {
        callback_failed = 1;
        return;
    }
    slang_pop(run_S, 1);
}

static void release_window(window *w);

static void push_request(slang_State *S, NSURLRequest *r) {
    slang_newtable(S);
    slang_pushstring(S, r.HTTPMethod ? r.HTTPMethod.UTF8String : "GET");
    slang_setfield(S, -2, "method");
    slang_pushstring(S, r.URL.absoluteString.UTF8String);
    slang_setfield(S, -2, "url");
    slang_newtable(S);
    for (NSString *k in r.allHTTPHeaderFields) {
        slang_pushstring(S, [r.allHTTPHeaderFields[k] UTF8String]);
        slang_setfield(S, -2, k.lowercaseString.UTF8String);
    }
    slang_setfield(S, -2, "headers");
    NSData *body = r.HTTPBody;
    slang_pushlstring(S, body ? body.bytes : "", body ? body.length : 0);
    slang_setfield(S, -2, "body");
}

/* hands queued events to slang (only with run_S set) */
static void flush_events(void) {
    while (queue_head != NULL && run_S != NULL && !callback_failed) {
        event *e = queue_head;
        queue_head = e->next;
        if (queue_head == NULL) queue_tail = NULL;
        window *w = e->w;
        if (w == NULL) {
            /* its window was collected */
        } else if (e->kind == EV_CLOSE) {
            if (begin_callback(w->on_close_ref)) finish_callback(0);
            release_window(w);
        } else if (e->kind == EV_MESSAGE) {
            if (begin_callback(w->on_message_ref)) {
                slang_pushstring(run_S, e->text);
                finish_callback(1);
            }
        } else if (e->kind == EV_REQUEST) {
            task_box *t = slang_newuserdata(run_S, sizeof(task_box), task_tname, task_finalize);
            t->task = e->task;   /* the queue's retain moves to the box */
            e->task = nil;
            NSValue *key = [NSValue valueWithPointer:(const void *)t->task];
            if ([live_tasks[key] isEqual:@"stopped"]) t->stopped = 1;
            live_tasks[key] = [NSValue valueWithPointer:t];
            int task_idx = slang_gettop(run_S);
            if (begin_callback(w->on_request_ref)) {
                push_request(run_S, [t->task request]);
                slang_pushvalue(run_S, task_idx);
                finish_callback(2);
            } else if (!t->stopped) {
                /* nobody answers this scheme */
                t->done = 1;
                @try {
                    NSHTTPURLResponse *res = [[[NSHTTPURLResponse alloc] initWithURL:[t->task request].URL statusCode:404
                                                                         HTTPVersion:@"HTTP/1.1" headerFields:@{}] autorelease];
                    [t->task didReceiveResponse:res];
                    [t->task didFinish];
                } @catch (NSException *ex) {}
            }
            slang_settop(run_S, task_idx - 1);
        }
        free(e->text);
        if (e->task) [e->task release];
        free(e);
    }
}

/* ---- Cocoa delegates ---- */

@interface SlangWindowDelegate : NSObject <NSWindowDelegate> {
@public
    window *w;
}
@end

@implementation SlangWindowDelegate
- (void)windowWillClose:(NSNotification *)n {
    if (w == NULL || w->closed) return;
    w->closed = 1;
    open_windows--;
    [w->view.configuration.userContentController removeScriptMessageHandlerForName:@"slang"];
    enqueue(EV_CLOSE, w, NULL, nil);
}
@end

@interface SlangMessageHandler : NSObject <WKScriptMessageHandler> {
@public
    window *w;
}
@end

@implementation SlangMessageHandler
- (void)userContentController:(WKUserContentController *)c didReceiveScriptMessage:(WKScriptMessage *)m {
    if (w == NULL || w->closed) return;
    NSString *text = [m.body isKindOfClass:[NSString class]] ? m.body : [m.body description];
    enqueue(EV_MESSAGE, w, strdup(text.UTF8String), nil);
}
@end

@interface SlangSchemeHandler : NSObject <WKURLSchemeHandler> {
@public
    window *w;
}
@end

@implementation SlangSchemeHandler
- (void)webView:(WKWebView *)v startURLSchemeTask:(id<WKURLSchemeTask>)task {
    enqueue(EV_REQUEST, w, NULL, [(id)task retain]);
}
- (void)webView:(WKWebView *)v stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSValue *key = [NSValue valueWithPointer:(const void *)task];
    id entry = live_tasks[key];
    if ([entry isKindOfClass:[NSValue class]]) {
        task_box *t = [entry pointerValue];
        t->stopped = 1;
    } else {
        /* still queued: remember, so the box starts stopped */
        live_tasks[key] = @"stopped";
    }
}
@end

@interface SlangAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation SlangAppDelegate
/* Quit closes the windows; the program decides what then */
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    for (NSWindow *win in [NSApp windows]) [win performClose:nil];
    return NSTerminateCancel;
}
@end

/* ---- the application ---- */

static NSMenuItem *menu_item(NSString *title, SEL action, NSString *key) {
    return [[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key] autorelease];
}

static void build_menu(void) {
    NSMenu *bar = [[[NSMenu alloc] init] autorelease];
    NSString *name = [[NSProcessInfo processInfo] processName];

    NSMenuItem *app_item = [[[NSMenuItem alloc] init] autorelease];
    NSMenu *app_menu = [[[NSMenu alloc] init] autorelease];
    [app_menu addItem:menu_item([@"Hide " stringByAppendingString:name], @selector(hide:), @"h")];
    [app_menu addItem:[NSMenuItem separatorItem]];
    [app_menu addItem:menu_item([@"Quit " stringByAppendingString:name], @selector(terminate:), @"q")];
    app_item.submenu = app_menu;
    [bar addItem:app_item];

    /* without an Edit menu, copy and paste do not reach the page */
    NSMenuItem *edit_item = [[[NSMenuItem alloc] init] autorelease];
    NSMenu *edit = [[[NSMenu alloc] initWithTitle:@"Edit"] autorelease];
    [edit addItem:menu_item(@"Undo", @selector(undo:), @"z")];
    NSMenuItem *redo = menu_item(@"Redo", @selector(redo:), @"z");
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [edit addItem:redo];
    [edit addItem:[NSMenuItem separatorItem]];
    [edit addItem:menu_item(@"Cut", @selector(cut:), @"x")];
    [edit addItem:menu_item(@"Copy", @selector(copy:), @"c")];
    [edit addItem:menu_item(@"Paste", @selector(paste:), @"v")];
    [edit addItem:menu_item(@"Select All", @selector(selectAll:), @"a")];
    edit_item.submenu = edit;
    [bar addItem:edit_item];

    NSMenuItem *win_item = [[[NSMenuItem alloc] init] autorelease];
    NSMenu *win = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
    [win addItem:menu_item(@"Minimize", @selector(performMiniaturize:), @"m")];
    [win addItem:menu_item(@"Close", @selector(performClose:), @"w")];
    win_item.submenu = win;
    [bar addItem:win_item];
    NSApp.windowsMenu = win;

    NSApp.mainMenu = bar;
}

static void ensure_app(void) {
    if (app_ready) return;
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    NSApp.delegate = [[SlangAppDelegate alloc] init];
    build_menu();
    [NSApp finishLaunching];
    live_tasks = [[NSMutableDictionary alloc] init];
    wake_event = [[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0
                                    timestamp:0 windowNumber:0 context:nil subtype:0x51A6 data1:0 data2:0] retain];
    app_ready = 1;
}

/* ---- the watcher thread ---- */

static pthread_mutex_t watch_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t watch_cv = PTHREAD_COND_INITIALIZER;
static int watch_armed = 0;
static int watch_timeout = -1;
static int wake_pipe[2] = {-1, -1};
static int watcher_started = 0;
static int watch_backend = -1;   /* the main program's loop descriptor */

static void uv_ready_on_main(void);

static void *watch(void *unused) {
    (void)unused;
    for (;;) {
        pthread_mutex_lock(&watch_mu);
        while (!watch_armed) pthread_cond_wait(&watch_cv, &watch_mu);
        int timeout = watch_timeout;
        int backend = watch_backend;
        pthread_mutex_unlock(&watch_mu);
        /* select, not poll: macOS's poll does not report a kqueue
         * descriptor as readable (Electron waits on it the same way) */
        fd_set readable;
        FD_ZERO(&readable);
        FD_SET(backend, &readable);
        FD_SET(wake_pipe[0], &readable);
        struct timeval tv = {timeout / 1000, (timeout % 1000) * 1000};
        int top = backend > wake_pipe[0] ? backend : wake_pipe[0];
        select(top + 1, &readable, NULL, NULL, timeout < 0 ? NULL : &tv);
        if (FD_ISSET(wake_pipe[0], &readable)) {
            /* re-armed with a new timeout: poll again */
            char buf[64];
            while (read(wake_pipe[0], buf, sizeof buf) > 0) {}
            continue;
        }
        pthread_mutex_lock(&watch_mu);
        watch_armed = 0;
        pthread_mutex_unlock(&watch_mu);
        dispatch_async(dispatch_get_main_queue(), ^{ uv_ready_on_main(); });
    }
    return NULL;
}

static void arm_watcher(int backend, int timeout) {
    if (!watcher_started) {
        pipe(wake_pipe);
        fcntl(wake_pipe[0], F_SETFL, O_NONBLOCK);
        fcntl(wake_pipe[1], F_SETFL, O_NONBLOCK);
        pthread_t t;
        pthread_create(&t, NULL, watch, NULL);
        pthread_detach(t);
        watcher_started = 1;
    }
    pthread_mutex_lock(&watch_mu);
    watch_backend = backend;
    watch_timeout = timeout;
    int was_armed = watch_armed;
    watch_armed = 1;
    pthread_cond_signal(&watch_cv);
    pthread_mutex_unlock(&watch_mu);
    if (was_armed) write(wake_pipe[1], "x", 1);
}

static int uv_failed = 0;

/* on the main thread: libuv has work; run it, hand over queued events and
 * wake run_once */
static void uv_ready_on_main(void) {
    if (run_S != NULL && !callback_failed && !uv_failed) {
        if (uv_api->run(run_S, 2) == SLANG_ERROR) uv_failed = 1;
        flush_events();
    }
    [NSApp postEvent:wake_event atStart:NO];
}

static const slang_uv_api *get_uv_api(slang_State *S) {
    if (uv_api != NULL) return uv_api;
    int top = slang_gettop(S);
    slang_getglobal(S, "require");
    slang_pushstring(S, "uv");
    if (slang_call(S, 1) != SLANG_OK) return NULL;
    slang_getfield(S, -1, "c_api");
    uv_api = slang_uv_get(S, -1);
    slang_settop(S, top);
    if (uv_api == NULL) slang_error(S, "webview: the uv extension does not offer a compatible C API (version %d)", SLANG_UV_API_VERSION);
    return uv_api;
}

/* run_once() -> bool: waits for and handles one batch of events, Cocoa's
 * and libuv's; true while windows are open or libuv has work */
static int l_run_once(slang_State *S) {
    /* Cocoa runs on the main thread only: an isolate can use the module's
     * types but not run windows */
    if (![NSThread isMainThread]) return slang_error(S, "webview: run_once only works on the main thread");
    if (get_uv_api(S) == NULL) return SLANG_ERROR;
    if (run_S != NULL) return slang_error(S, "webview: run_once does not nest");
    ensure_app();
    /* open windows keep libuv's loop alive, so that it polls I/O (signals
     * included) even when nothing else holds it */
    uv_api->hold_of(S, open_windows > 0);
    run_S = S;
    callback_failed = 0;
    uv_failed = 0;
    int more = 1;
    @autoreleasepool {
        flush_events();
        if (!callback_failed && uv_api->run(S, 2) == SLANG_ERROR) uv_failed = 1;
        if (!callback_failed && !uv_failed) {
            if (open_windows == 0 && queue_head == NULL) {
                /* no window: wait on libuv alone */
                int r = uv_api->run(S, 1);
                if (r == SLANG_ERROR) uv_failed = 1;
                more = r == 1;
                /* let Cocoa catch up (closing windows, activation) */
                NSEvent *e;
                while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
                                                  inMode:NSDefaultRunLoopMode dequeue:YES]) != nil) {
                    if (e.type != NSEventTypeApplicationDefined || e.subtype != 0x51A6) [NSApp sendEvent:e];
                }
            } else {
                arm_watcher(uv_api->backend_fd_of(S), uv_api->backend_timeout_of(S));
                NSEvent *e = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantFuture]
                                                   inMode:NSDefaultRunLoopMode dequeue:YES];
                if (e != nil && !(e.type == NSEventTypeApplicationDefined && e.subtype == 0x51A6)) [NSApp sendEvent:e];
                flush_events();
                if (!callback_failed && !uv_failed && uv_api->run(S, 2) == SLANG_ERROR) uv_failed = 1;
                flush_events();
            }
        }
    }
    run_S = NULL;
    if (callback_failed || uv_failed) {
        callback_failed = 0;
        uv_failed = 0;
        return SLANG_ERROR;   /* the callback's error is pending */
    }
    slang_pushbool(S, more || open_windows > 0 || queue_head != NULL);
    return 1;
}

static int l_window_count(slang_State *S) {
    slang_pushint(S, open_windows);
    return 1;
}

/* ---- windows ---- */

/* window.slang in every page: send(value), call(name, ...args) -> Promise,
 * on(f) for values pushed by slang; _resolve and _deliver are slang's side */
static const char *bridge_js =
    "(function () {"
    "  if (window.slang) return;"
    "  let next = 1; const pending = new Map(); const listeners = [];"
    "  const post = (m) => window.webkit.messageHandlers.slang.postMessage(JSON.stringify(m));"
    "  window.slang = {"
    "    send(data) { post({type: 'message', data: data}); },"
    "    call(name, ...args) {"
    "      return new Promise((resolve, reject) => {"
    "        const id = next++; pending.set(id, {resolve, reject});"
    "        post({type: 'call', id: id, name: name, args: args});"
    "      });"
    "    },"
    "    on(f) { listeners.push(f); },"
    "    _resolve(id, ok, value) {"
    "      const p = pending.get(id); if (!p) return; pending.delete(id);"
    "      if (ok) p.resolve(value); else p.reject(new Error(value));"
    "    },"
    "    _deliver(data) { for (const f of listeners) { try { f(data); } catch (e) { console.error(e); } } },"
    "  };"
    "})();";

/* a closed window: its callbacks and its userdata are no longer held */
static void release_window(window *w) {
    if (run_S == NULL) return;
    int *refs[] = {&w->self_ref, &w->on_close_ref, &w->on_message_ref, &w->on_request_ref};
    for (int i = 0; i < 4; i++) {
        if (*refs[i] != SLANG_REFNULL) {
            slang_unref(run_S, *refs[i]);
            *refs[i] = SLANG_REFNULL;
        }
    }
}

static void window_finalize(void *data) {
    window *w = *(window **)data;
    if (!w->closed && w->win != nil) {
        w->closed = 1;
        open_windows--;
        [w->view.configuration.userContentController removeScriptMessageHandlerForName:@"slang"];
        w->win.delegate = nil;
        [w->win close];
    }
    /* events still queued for it are dropped */
    for (event *e = queue_head; e != NULL; e = e->next) {
        if (e->w == w) e->w = NULL;
    }
    ((SlangWindowDelegate *)w->delegate)->w = NULL;
    ((SlangMessageHandler *)w->handler)->w = NULL;
    if (w->scheme_handler) ((SlangSchemeHandler *)w->scheme_handler)->w = NULL;
    w->win.delegate = nil;
    [w->delegate release];
    [w->handler release];
    [w->scheme_handler release];
    [w->view release];
    [w->win release];
    free(w);
}

static NSString *opt_string(slang_State *S, int idx, const char *name) {
    slang_getfield(S, idx, name);
    NSString *s = slang_isstring(S, -1) ? [NSString stringWithUTF8String:slang_tolstring(S, -1, NULL)] : nil;
    slang_pop(S, 1);
    return s;
}

static double opt_number(slang_State *S, int idx, const char *name, double def) {
    slang_getfield(S, idx, name);
    double v = slang_isnumber(S, -1) ? slang_todouble(S, -1) : def;
    slang_pop(S, 1);
    return v;
}

static int opt_bool(slang_State *S, int idx, const char *name, int def) {
    slang_getfield(S, idx, name);
    int v = slang_isnull(S, -1) ? def : slang_tobool(S, -1);
    slang_pop(S, 1);
    return v;
}

static int l_window(slang_State *S) {
    if (!slang_istable(S, 1)) return slang_argerror(S, 1, "options table expected");
    if (![NSThread isMainThread]) return slang_error(S, "webview: windows can only be made on the main thread");
    if (get_uv_api(S) == NULL) return SLANG_ERROR;
    ensure_app();
    NSString *title = opt_string(S, 1, "title") ?: @"slang";
    NSString *url = opt_string(S, 1, "url");
    NSString *html = opt_string(S, 1, "html");
    NSString *scheme = opt_string(S, 1, "scheme");
    double width = opt_number(S, 1, "width", 900), height = opt_number(S, 1, "height", 640);
    int resizable = opt_bool(S, 1, "resizable", 1);
    int debug = opt_bool(S, 1, "debug", 0);

    window **box = slang_newuserdata(S, sizeof(window *), window_tname, window_finalize);
    window *w = calloc(1, sizeof(window));
    *box = w;
    w->self_ref = w->on_close_ref = w->on_message_ref = w->on_request_ref = SLANG_REFNULL;
    int idx = slang_gettop(S);

    @autoreleasepool {
        WKWebViewConfiguration *config = [[[WKWebViewConfiguration alloc] init] autorelease];
        SlangMessageHandler *handler = [[SlangMessageHandler alloc] init];
        handler->w = w;
        w->handler = handler;
        [config.userContentController addScriptMessageHandler:handler name:@"slang"];
        WKUserScript *bridge = [[[WKUserScript alloc] initWithSource:[NSString stringWithUTF8String:bridge_js]
                                                       injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                    forMainFrameOnly:YES] autorelease];
        [config.userContentController addUserScript:bridge];
        if (scheme != nil) {
            SlangSchemeHandler *sh = [[SlangSchemeHandler alloc] init];
            sh->w = w;
            w->scheme_handler = sh;
            [config setURLSchemeHandler:sh forURLScheme:scheme];
        }
        if (debug) [config.preferences setValue:@YES forKey:@"developerExtrasEnabled"];

        NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
        if (resizable) style |= NSWindowStyleMaskResizable;
        w->win = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height) styleMask:style
                                               backing:NSBackingStoreBuffered defer:NO];
        w->win.releasedWhenClosed = NO;
        w->win.title = title;
        SlangWindowDelegate *delegate = [[SlangWindowDelegate alloc] init];
        delegate->w = w;
        w->delegate = delegate;
        w->win.delegate = delegate;

        w->view = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, width, height) configuration:config];
        w->view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        if (debug && [w->view respondsToSelector:@selector(setInspectable:)]) [w->view setValue:@YES forKey:@"inspectable"];
        w->win.contentView = w->view;
        [w->win center];
        if (url != nil) [w->view loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:url]]];
        else if (html != nil) [w->view loadHTMLString:html baseURL:nil];
        [w->win makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }
    open_windows++;
    /* an open window keeps its userdata alive */
    slang_pushvalue(S, idx);
    w->self_ref = slang_ref(S);
    slang_settop(S, idx);
    return 1;
}

static window *check_window(slang_State *S) {
    window **box = slang_checkudata(S, 1, window_tname);
    return box ? *box : NULL;
}

static window *check_open(slang_State *S) {
    window *w = check_window(S);
    if (w != NULL && w->closed) {
        slang_error(S, "webview: the window is closed");
        return NULL;
    }
    return w;
}

static int window_navigate(slang_State *S) {
    window *w = check_open(S);
    const char *url = slang_checklstring(S, 2, NULL);
    if (w == NULL || url == NULL) return SLANG_ERROR;
    NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (u == nil) return slang_argerror(S, 2, "a URL expected");
    [w->view loadRequest:[NSURLRequest requestWithURL:u]];
    return 0;
}

static int window_set_html(slang_State *S) {
    window *w = check_open(S);
    const char *html = slang_checklstring(S, 2, NULL);
    if (w == NULL || html == NULL) return SLANG_ERROR;
    [w->view loadHTMLString:[NSString stringWithUTF8String:html] baseURL:nil];
    return 0;
}

/* eval(js): runs JavaScript in the page; the result is not returned (use
 * slang.send from the script for answers) */
static int window_eval(slang_State *S) {
    window *w = check_open(S);
    const char *js = slang_checklstring(S, 2, NULL);
    if (w == NULL || js == NULL) return SLANG_ERROR;
    [w->view evaluateJavaScript:[NSString stringWithUTF8String:js] completionHandler:nil];
    return 0;
}

static int window_set_title(slang_State *S) {
    window *w = check_open(S);
    const char *t = slang_checklstring(S, 2, NULL);
    if (w == NULL || t == NULL) return SLANG_ERROR;
    w->win.title = [NSString stringWithUTF8String:t];
    return 0;
}

static int window_close(slang_State *S) {
    window *w = check_window(S);
    if (w == NULL) return SLANG_ERROR;
    if (!w->closed) [w->win close];
    return 0;
}

static int window_is_open(slang_State *S) {
    window *w = check_window(S);
    if (w == NULL) return SLANG_ERROR;
    slang_pushbool(S, !w->closed);
    return 1;
}

static int set_callback(slang_State *S, int *ref) {
    slang_checkfunction(S, 2);
    if (slang_failed(S)) return SLANG_ERROR;
    if (*ref != SLANG_REFNULL) slang_unref(S, *ref);
    slang_pushvalue(S, 2);
    *ref = slang_ref(S);
    return 0;
}

static int window_on_close(slang_State *S) {
    window *w = check_window(S);
    return w ? set_callback(S, &w->on_close_ref) : SLANG_ERROR;
}

static int window_on_message(slang_State *S) {
    window *w = check_window(S);
    return w ? set_callback(S, &w->on_message_ref) : SLANG_ERROR;
}

static int window_on_request(slang_State *S) {
    window *w = check_window(S);
    return w ? set_callback(S, &w->on_request_ref) : SLANG_ERROR;
}

/* ---- module ---- */

static const slang_Reg window_methods[] = {
    {"navigate", window_navigate},
    {"set_html", window_set_html},
    {"eval", window_eval},
    {"set_title", window_set_title},
    {"close", window_close},
    {"is_open", window_is_open},
    {"on_close", window_on_close},
    {"on_message", window_on_message},
    {"on_request", window_on_request},
    {NULL, NULL},
};

static const slang_Reg task_methods[] = {
    {"respond", task_respond},
    {NULL, NULL},
};

static const slang_Reg funcs[] = {
    {"window", l_window},
    {"run_once", l_run_once},
    {"window_count", l_window_count},
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

SLANG_EXTENSION(webview) {
    make_meta(S, window_tname, window_methods);
    make_meta(S, task_tname, task_methods);
    slang_newmodule(S, funcs);
    return 1;
}
