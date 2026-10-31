//! slang/ffi_core: calling C through libffi, without writing C: shared
//! libraries, their symbols, and functions made from a symbol and a
//! signature. The types, pointers and conversions are slang/ctypes'
//! (ctypes.zig), which every build has; this module needs libffi.
//!
//! Arguments convert as ctypes describes; a table given for a pointer
//! parameter marked for writeback gets the memory back after the call
//! (out parameters), and a buffer is passed as its memory.
//!
//! Callbacks: a slang function given for a function pointer becomes a
//! libffi closure that calls it. C may call it from any thread: once a
//! callback exists, the OS thread running slang holds the VM's lock
//! (vm.ffi), every C call releases it for its duration, and a callback
//! takes it, so slang still runs on one thread at a time. A callback runs on
//! the slang thread that made the C call; its error cannot unwind through
//! C, so C gets a zero result and the error is raised when the C call
//! returns.

const std = @import("std");
const builtin = @import("builtin");
const vm_mod = @import("../vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Table = vm_mod.Table;
const Thread = vm_mod.Thread;
const Error = vm_mod.Error;
const api = vm_mod.api;
const stdlib = @import("stdlib.zig");
const ctypes = @import("ctypes.zig");
const Type = ctypes.Type;
const FfiType = ctypes.FfiType;
const Ptr = ctypes.Ptr;

// ------------------------------------------------------------ libffi

extern fn ffi_prep_cif(cif: *Cif, abi: c_uint, nargs: c_uint, rtype: *FfiType, atypes: ?[*]*FfiType) c_int;
extern fn ffi_prep_cif_var(cif: *Cif, abi: c_uint, nfixed: c_uint, ntotal: c_uint, rtype: *FfiType, atypes: ?[*]*FfiType) c_int;
extern fn ffi_call(cif: *Cif, f: *const anyopaque, rvalue: ?*anyopaque, avalue: ?[*]?*anyopaque) void;
extern fn ffi_closure_alloc(size: usize, code: *?*anyopaque) ?*anyopaque;
extern fn ffi_closure_free(closure: *anyopaque) void;
const ClosureFn = *const fn (cif: *Cif, ret: ?*anyopaque, args: [*]?*anyopaque, user: ?*anyopaque) callconv(.c) void;
extern fn ffi_prep_closure_loc(closure: *anyopaque, cif: *Cif, fun: ClosureFn, user: ?*anyopaque, code: ?*anyopaque) c_int;

const FFI_OK: c_int = 0;
const default_abi: c_uint = switch (builtin.cpu.arch) {
    .aarch64 => if (builtin.os.tag == .windows) 2 else 1, // FFI_WIN64 / FFI_SYSV
    .x86_64 => if (builtin.os.tag == .windows) 1 else 2, // FFI_WIN64 / FFI_UNIX64
    .wasm32 => 2, // FFI_WASM32_EMSCRIPTEN
    else => @compileError("ffi: unsupported architecture"),
};

/// Under Emscripten nothing is loaded at run time: the C libraries are linked
/// into the program, and a generated table (see website/web/) gives their
/// symbols by name. Every library "opens" as that table.
const static_symbols = builtin.os.tag == .emscripten;
extern "c" fn slang_ffi_static_symbol(name: [*:0]const u8) ?*anyopaque;
var static_handle: u8 = 0;

/// ffi_cif, kept opaque: libffi's layout differs between targets, so it is
/// given more room than any of them needs.
const Cif = extern struct { space: [16]usize align(16) };

extern "c" fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn dlerror() ?[*:0]const u8;
const RTLD_NOW: c_int = 2;

const library_tname = "ffi.library";
const func_tname = "ffi.func";
const callback_tname = "ffi.callback";

const Func = struct {
    f: *const anyopaque,
    cif: Cif,
    ret: *Type,
    args: []*Type,
    ffi_args: []*FfiType,
    /// pointer parameters whose memory is copied back to the table given
    writeback: []bool,
    variadic: bool,
    name: []const u8,
};

pub fn module(vm: *VM) *Table {
    ctypes.make_callback = lastingCallback;
    return stdlib.makeModule(vm, &.{
        .{ .name = "open", .f = ffiOpen },
        .{ .name = "symbol", .f = ffiSymbol },
        .{ .name = "func", .f = ffiFunc },
        .{ .name = "callback", .f = ffiCallback },
        .{ .name = "gc", .f = ffiGc },
    });
}

// ------------------------------------------------------------ libraries

/// open(path) -> a library (dlopen), or {null, message}; path null is the
/// program itself
fn ffiOpen(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    var h: ?*anyopaque = null;
    if (static_symbols) {
        h = &static_handle;
    } else if (api.arg(args, 0) == .null) {
        h = dlopen(null, RTLD_NOW);
    } else {
        const path = try api.argString(th, args, 0, "path");
        const z = vm.gpa.dupeSentinel(u8, path, 0) catch oom();
        defer vm.gpa.free(z);
        h = dlopen(z.ptr, RTLD_NOW);
    }
    if (h == null) {
        const msg = if (dlerror()) |e| std.mem.span(e) else "cannot open";
        const t = vm.newTable(2, 0);
        t.append(vm.gpa, .null);
        t.append(vm.gpa, vm.str(msg));
        return .{ .table = t };
    }
    const u = vm.newUserdataOf(?*anyopaque, h, library_tname, null);
    return .{ .userdata = u };
}

/// symbol(library, name) -> a pointer to the symbol, or null
fn ffiSymbol(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const h = (try api.argUserdata(th, args, 0, "library", ?*anyopaque, library_tname)).*;
    const name = try api.argString(th, args, 1, "name");
    const z = vm.gpa.dupeSentinel(u8, name, 0) catch oom();
    defer vm.gpa.free(z);
    const p = (if (static_symbols) slang_ffi_static_symbol(z.ptr) else dlsym(h, z.ptr)) orelse return .null;
    return ctypes.newPointer(vm, @intFromPtr(p), null, .null);
}

// ------------------------------------------------------------ functions

/// func(symbol, ret, {args...}, name, [{writeback...}], [variadic]) -> a
/// function calling the C function at symbol with that signature
fn ffiFunc(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const sym = ctypes.asPointer(api.arg(args, 0)) orelse return api.argError(th, "symbol", 0, ctypes.pointer_tname, api.arg(args, 0));
    const ret = try ctypes.argType(th, args, 1, "ret");
    const list = try api.argTable(th, args, 2, "args");
    const name = try api.argString(th, args, 3, "name");
    const wb = api.arg(args, 4).asTable();
    const variadic = api.argBool(args, 5, false);
    const n = list.arrayLen();
    const types = vm.gpa.alloc(*Type, n) catch oom();
    const ffi_types = vm.gpa.alloc(*FfiType, n + 1) catch oom();
    const writeback = vm.gpa.alloc(bool, n) catch oom();
    for (0..n) |i| {
        const t = ctypes.asType(list.getInt(@intCast(i))) orelse return vm.raise("ffi.func: argument {d} of {s} has no type", .{ i, name });
        if (!t.complete or t.kind == .void or t.kind == .array) return vm.raise("ffi.func: argument {d} of {s} cannot be a {s}", .{ i, name, t.name });
        types[i] = t;
        ffi_types[i] = t.ffi;
        writeback[i] = if (wb) |w| w.getInt(@intCast(i)).truthy() else false;
    }
    if (!ret.complete or ret.kind == .array) return vm.raise("ffi.func: {s} cannot return a {s}", .{ name, ret.name });
    const f = vm.gpa.create(Func) catch oom();
    f.* = .{
        .f = @ptrFromInt(sym.as(Ptr).addr),
        .cif = undefined,
        .ret = ret,
        .args = types,
        .ffi_args = ffi_types,
        .writeback = writeback,
        .variadic = variadic,
        .name = vm.gpa.dupe(u8, name) catch oom(),
    };
    if (!variadic and ffi_prep_cif(&f.cif, default_abi, @intCast(n), ret.ffi, ffi_types.ptr) != FFI_OK) {
        return vm.raise("ffi.func: libffi cannot call {s}", .{name});
    }
    const holder = vm.newUserdataOf(*Func, f, func_tname, null);
    holder.owner = .{ .userdata = sym };
    const cl = vm.newNative(name, callFunc, &.{.{ .userdata = holder }});
    return .{ .function = cl };
}

/// gc(pointer, func) -> pointer: the C function func (one pointer
/// parameter, no result, as made by [func]) frees what the pointer points
/// to once the pointer object is collected; null takes the finalizer away.
/// The pointer object itself is changed and returned.
fn ffiGc(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const u = ctypes.asPointer(api.arg(args, 0)) orelse return api.argError(th, "pointer", 0, ctypes.pointer_tname, api.arg(args, 0));
    const p = u.as(Ptr);
    if (u.data.len > @sizeOf(Ptr)) return vm.raise("ffi.gc: the pointer's memory is slang's own (ffi.new), nothing of C's to free", .{});
    if (api.arg(args, 1) == .null) {
        p.free = null;
        u.finalizer = null;
        return args[0];
    }
    const cl = try api.argFunction(th, args, 1, "free");
    const holder = if (cl.native == callFunc and cl.nvals.len == 1) cl.nvals[0].asUserdata() else null;
    const f = if (holder) |h| h.as(*Func).* else return vm.raise("ffi.gc: free must be a C function (ffi.bind, or one of a loaded library)", .{});
    if (f.args.len != 1 or f.args[0].kind != .pointer or f.ret.kind != .void or f.variadic) {
        return vm.raise("ffi.gc: {s} must take one pointer and return nothing", .{f.name});
    }
    p.free = @ptrCast(@alignCast(f.f));
    u.finalizer = ctypes.freePointer;
    return args[0];
}

/// The C type a variadic argument is passed as (C's default promotions).
fn variadicType(vm: *VM, v: Value) Error!*Type {
    return switch (v) {
        .int => |i| ctypes.primitive(if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32)) "int32" else "int64").?,
        .bool => ctypes.primitive("int32").?,
        .float => ctypes.primitive("double").?,
        .string => ctypes.primitive("string").?,
        .null, .userdata => ctypes.primitive("pointer").?,
        else => vm.raise("ffi: a {s} cannot be a variadic argument", .{v.typeName()}),
    };
}

fn callFunc(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const f = th.currentClosure().nvals[0].userdata.as(*Func).*;
    const fixed = f.args.len;
    if (args.len < fixed or (args.len > fixed and !f.variadic)) {
        return vm.raise("{s} takes {d} arguments, got {d}", .{ f.name, fixed, args.len });
    }
    var arena_state = std.heap.ArenaAllocator.init(vm.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var conv = ctypes.Conv{ .th = th, .arena = arena };
    const total = args.len;
    const values = arena.alloc(?*anyopaque, total + 1) catch oom();
    var types = f.args;
    var cif_ptr = &f.cif;
    if (f.variadic) {
        types = arena.alloc(*Type, total) catch oom();
        const ffi_types = arena.alloc(*FfiType, total + 1) catch oom();
        for (0..total) |i| {
            types[i] = if (i < fixed) f.args[i] else try variadicType(vm, args[i]);
            ffi_types[i] = types[i].ffi;
        }
        const cif = arena.create(Cif) catch oom();
        if (ffi_prep_cif_var(cif, default_abi, @intCast(fixed), @intCast(total), f.ret.ffi, ffi_types.ptr) != FFI_OK) {
            return vm.raise("{s}: libffi cannot make this call", .{f.name});
        }
        cif_ptr = cif;
    }
    var what_buf: [128]u8 = undefined;
    for (0..total) |i| {
        const t = types[i];
        const mem = arena.alignedAlloc(u8, .@"16", @max(t.size, 8)) catch oom();
        @memset(mem, 0);
        conv.what = std.fmt.bufPrint(&what_buf, "bad argument #{d} to '{s}'", .{ i + 1, f.name }) catch "bad argument";
        try conv.toC(args[i], t, mem.ptr, i < fixed and f.writeback[i]);
        values[i] = mem.ptr;
    }
    // integer results narrower than a register come back widened
    const rmem = arena.alignedAlloc(u8, .@"16", @max(f.ret.size, 16)) catch oom();
    const released = release(vm, th);
    ffi_call(cif_ptr, f.f, rmem.ptr, values.ptr);
    if (released) reacquire(vm);
    if (vm.ffi.pending) |e| {
        vm.ffi.pending = null;
        if (vm.err) |*old| old.deinit(vm.gpa);
        vm.err = e;
        return error.Slang;
    }
    try conv.writeBack();
    return ctypes.fromC(vm, f.ret, rmem.ptr, .null);
}

// ------------------------------------------------------------ the lock

const threaded = !builtin.single_threaded;

/// Before a C call: lets callbacks from other threads in (when there are
/// callbacks), with th as the thread they run on. Returns whether it did.
fn release(vm: *VM, th: *Thread) bool {
    if (!threaded or !vm.ffi.on) return false;
    vm.ffi.calls.append(vm.gpa, .{ .th = th, .os = std.Thread.getCurrentId() }) catch oom();
    vm.ffi.owner.store(0, .release);
    vm.ffi.lock.unlock(vm.io);
    return true;
}

/// After a C call: slang is this thread's again.
fn reacquire(vm: *VM) void {
    vm.ffi.lock.lockUncancelable(vm.io);
    vm.ffi.owner.store(std.Thread.getCurrentId(), .release);
    _ = vm.ffi.calls.pop();
}

/// A callback starts: takes the lock unless this thread holds it (a C
/// function called from slang without a C call around it, as a native
/// module does). Returns whether it took it.
fn enter(vm: *VM) bool {
    if (!threaded) return false;
    const self = std.Thread.getCurrentId();
    if (vm.ffi.owner.load(.acquire) == self) return false;
    vm.ffi.lock.lockUncancelable(vm.io);
    vm.ffi.owner.store(self, .release);
    return true;
}

fn leave(vm: *VM, took: bool) void {
    if (!took) return;
    vm.ffi.owner.store(0, .release);
    vm.ffi.lock.unlock(vm.io);
}

/// The first callback: from now on the thread running slang holds the lock.
fn turnOn(vm: *VM) void {
    if (!threaded or vm.ffi.on) return;
    vm.ffi.lock.lockUncancelable(vm.io);
    vm.ffi.owner.store(std.Thread.getCurrentId(), .release);
    vm.ffi.on = true;
}

// ------------------------------------------------------------ callbacks

const Callback = struct {
    vm: *VM,
    func: Value,
    sig: *ctypes.Signature,
    cif: Cif,
    ffi_args: []*FfiType,
    closure: *anyopaque,
    code: usize,
};

/// room for libffi's ffi_closure on every target (it is smaller)
const closure_size = 256;

fn newCallback(th: *Thread, f: Value, t: *Type) Error!*Callback {
    const vm = th.vm;
    const sig = t.sig orelse return vm.raise("ffi: {s} is not a function pointer type", .{t.name});
    const ffi_args = vm.gpa.alloc(*FfiType, sig.args.len + 1) catch oom();
    for (sig.args, 0..) |a, i| ffi_args[i] = a.ffi;
    const cb = vm.gpa.create(Callback) catch oom();
    cb.* = .{ .vm = vm, .func = f, .sig = sig, .cif = undefined, .ffi_args = ffi_args, .closure = undefined, .code = 0 };
    if (ffi_prep_cif(&cb.cif, default_abi, @intCast(sig.args.len), sig.ret.ffi, ffi_args.ptr) != FFI_OK) {
        return vm.raise("ffi: libffi cannot make a callback of type {s}", .{t.name});
    }
    var code: ?*anyopaque = null;
    const closure = ffi_closure_alloc(closure_size, &code) orelse return vm.raise("ffi: libffi cannot allocate a callback", .{});
    if (ffi_prep_closure_loc(closure, &cb.cif, handler, cb, code) != FFI_OK) {
        ffi_closure_free(closure);
        return vm.raise("ffi: libffi cannot make a callback of type {s}", .{t.name});
    }
    cb.closure = closure;
    cb.code = @intFromPtr(code);
    turnOn(vm);
    return cb;
}

/// The callbacks made for functions given directly to C, which live as long
/// as the program: the same function and type give the same one.
const LastingKey = struct { vm: usize, func: usize, ty: usize };
var lasting: std.AutoHashMapUnmanaged(LastingKey, *Callback) = .empty;
var lasting_lock: std.Io.Mutex = .init;
const lasting_limit = 1000;

fn lastingCallback(th: *Thread, f: Value, t: *Type) Error!usize {
    const vm = th.vm;
    const key = LastingKey{ .vm = @intFromPtr(vm), .func = @intFromPtr(f.function), .ty = @intFromPtr(t) };
    lasting_lock.lockUncancelable(vm.io);
    defer lasting_lock.unlock(vm.io);
    if (lasting.get(key)) |cb| return cb.code;
    // each one lives for good: a function made anew on every pass of a
    // loop would make a new one each time
    if (lasting.count() >= lasting_limit) {
        return vm.raise("ffi: more than {d} C callbacks made from slang functions (a function written inside a loop is a new function, and a new callback, each time): define it once, or use ffi.callback, which is freed with its pointer", .{lasting_limit});
    }
    const cb = try newCallback(th, f, t);
    _ = vm.makeRef(f); // kept alive for good
    // (malloc: under Emscripten the page allocator would grow the memory
    // behind its back)
    lasting.put(std.heap.c_allocator, key, cb) catch oom();
    return cb.code;
}

/// callback(type, func) -> a pointer to a C function calling func, alive
/// while the pointer is (the closure is freed when it is collected)
fn ffiCallback(th: *Thread, args: []Value) Error!Value {
    const vm = th.vm;
    const t = try ctypes.argType(th, args, 0, "type");
    const f = try api.argFunction(th, args, 1, "func");
    const cb = try newCallback(th, .{ .function = f }, t);
    const holder = vm.newUserdataOf(*Callback, cb, callback_tname, null);
    holder.finalizer = freeCallback;
    holder.owner = .{ .function = f };
    return ctypes.newPointer(vm, cb.code, null, .{ .userdata = holder });
}

fn freeCallback(data: ?*anyopaque) callconv(.c) void {
    const cb = @as(*align(1) *Callback, @ptrCast(data.?)).*;
    ffi_closure_free(cb.closure);
    cb.vm.gpa.free(cb.ffi_args);
    cb.vm.gpa.destroy(cb);
}

/// What C calls: the slang function with the arguments converted, its
/// result converted back.
fn handler(cif: *Cif, ret: ?*anyopaque, args: [*]?*anyopaque, user: ?*anyopaque) callconv(.c) void {
    _ = cif;
    const cb: *Callback = @ptrCast(@alignCast(user.?));
    const vm = cb.vm;
    const sig = cb.sig;
    // zero unless the function says otherwise (libffi widens small
    // integer results to a register)
    if (ret) |r| @memset(@as([*]u8, @ptrCast(r))[0..@max(sig.ret.size, @sizeOf(usize))], 0);
    const took = enter(vm);
    defer leave(vm, took);
    // after an error C finishes without slang; the error is raised then
    if (vm.ffi.pending != null) return;
    const th = callbackThread(vm);
    var arena_state = std.heap.ArenaAllocator.init(vm.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const values = arena.alloc(Value, sig.args.len) catch oom();
    for (sig.args, 0..) |t, i| values[i] = ctypes.fromC(vm, t, @ptrCast(args[i].?), .null);
    const result = th.call(cb.func, values) catch return fail(th);
    if (sig.ret.kind == .void) return;
    const r: [*]u8 = @ptrCast(ret.?);
    // the result is stored in C's memory: nothing temporary may go there
    var conv = ctypes.Conv{ .th = th, .arena = null, .what = "bad result of a callback" };
    switch (sig.ret.kind) {
        .bool, .i8, .i16, .i32 => if (sig.ret.size < @sizeOf(usize)) {
            var tmp: [8]u8 align(8) = undefined;
            conv.toC(result, sig.ret, &tmp, false) catch return fail(th);
            const v: isize = switch (sig.ret.kind) {
                .bool => tmp[0],
                .i8 => @as(i8, @bitCast(tmp[0])),
                .i16 => @as(*align(1) i16, @ptrCast(&tmp)).*,
                else => @as(*align(1) i32, @ptrCast(&tmp)).*,
            };
            @as(*align(1) isize, @ptrCast(r)).* = v;
            return;
        },
        .u8, .u16, .u32 => if (sig.ret.size < @sizeOf(usize)) {
            var tmp: [8]u8 align(8) = @splat(0);
            conv.toC(result, sig.ret, &tmp, false) catch return fail(th);
            const v: usize = switch (sig.ret.kind) {
                .u8 => tmp[0],
                .u16 => @as(*align(1) u16, @ptrCast(&tmp)).*,
                else => @as(*align(1) u32, @ptrCast(&tmp)).*,
            };
            @as(*align(1) usize, @ptrCast(r)).* = v;
            return;
        },
        else => {},
    }
    conv.toC(result, sig.ret, r, false) catch return fail(th);
}

/// The slang thread a callback runs on: the one whose C call it is inside,
/// when it comes from that call's OS thread (calls nest there); else the
/// OS thread's own.
fn callbackThread(vm: *VM) *Thread {
    if (!threaded) {
        const items = vm.ffi.calls.items;
        return if (items.len > 0) items[items.len - 1].th else vm.main;
    }
    const self = std.Thread.getCurrentId();
    var i = vm.ffi.calls.items.len;
    while (i > 0) {
        i -= 1;
        const c = vm.ffi.calls.items[i];
        if (c.os == self) return c.th;
    }
    if (vm.ffi.foreign.get(self)) |t| return t;
    const t = vm.newThread(null);
    t.status = .running;
    vm.ffi.foreign.put(vm.gpa, self, t) catch oom();
    return t;
}

/// A callback failed: its error waits for the C call to return.
fn fail(th: *Thread) void {
    const vm = th.vm;
    th.fillError();
    vm.ffi.pending = vm.err;
    vm.err = null;
}
