//! The implementation of include/slang.h. A slang_State is a Thread; stack
//! indices are relative to the base of the running native function's frame
//! (or to the bottom of the stack when no function runs, as in embedding
//! code).

const std = @import("std");
const builtin = @import("builtin");
const vm_mod = @import("vm.zig");
const oom = vm_mod.oom;
const VM = vm_mod.VM;
const Value = vm_mod.Value;
const Kind = vm_mod.Kind;
const Table = vm_mod.Table;
const String = vm_mod.String;
const Thread = vm_mod.Thread;
const Closure = vm_mod.Closure;
const Userdata = vm_mod.Userdata;
const Error = vm_mod.Error;
const object = @import("vm/object.zig");
const interp = @import("vm/interp.zig");
const stdlib = @import("stdlib/stdlib.zig");
const boot = @import("boot.zig");
const ctypes = @import("stdlib/ctypes.zig");
const isolates = @import("stdlib/isolatelib.zig");

pub const api_version: c_int = 1;

// Exported functions are only emitted when they are analysed; referencing
// the file from main.zig is not enough for the optimising backend, so every
// declaration is referenced here.
comptime {
    for (std.meta.declarations(@This())) |name| _ = &@field(@This(), name);
}
const ok: c_int = 0;
const err: c_int = -1;
const upvalue_base: c_int = -1000000;

pub const CFunction = object.CFunction;
pub const Finalizer = object.Finalizer;

const Reg = extern struct {
    name: ?[*:0]const u8,
    func: ?CFunction,
};

// ---- helpers ----

inline fn baseOf(th: *Thread) usize {
    if (th.frames.items.len == 0) return 0;
    return th.frames.items[th.frames.items.len - 1].base;
}

/// The slot addressed by a stack index, or null for an invalid index.
fn slot(th: *Thread, idx: c_int) ?*Value {
    if (idx > 0) {
        const i = baseOf(th) + @as(usize, @intCast(idx)) - 1;
        if (i >= th.top) return null;
        return &th.stack[i];
    }
    if (idx <= upvalue_base) {
        const u: usize = @intCast(upvalue_base - idx);
        if (th.frames.items.len == 0) return null;
        const cl = th.currentClosure();
        if (u == 0 or u > cl.nvals.len) return null;
        return &cl.nvals[u - 1];
    }
    if (idx < 0) {
        const back: usize = @intCast(-idx);
        if (back > th.top or th.top - back < baseOf(th)) return null;
        return &th.stack[th.top - back];
    }
    return null;
}

fn get(th: *Thread, idx: c_int) Value {
    return (slot(th, idx) orelse return .null).*;
}

fn absIndex(th: *Thread, idx: c_int) ?usize {
    const p = slot(th, idx) orelse return null;
    if (idx <= upvalue_base) return null;
    return (@intFromPtr(p) - @intFromPtr(th.stack.ptr)) / @sizeOf(Value);
}

fn span(s: ?[*:0]const u8) []const u8 {
    return if (s) |p| std.mem.span(p) else "";
}

fn pop(th: *Thread) Value {
    if (th.top <= baseOf(th)) return .null;
    th.top -= 1;
    return th.stack[th.top];
}

fn fnName(th: *Thread) []const u8 {
    if (th.frames.items.len == 0) return "?";
    return th.currentClosure().nameBytes();
}

/// Records an argument error unless one is already pending.
fn argError(th: *Thread, idx: c_int, want: []const u8, got: Value) void {
    if (th.vm.err != null) return;
    th.vm.setError("bad argument #{d} to '{s}' ({s} expected, got {s})", .{ idx, fnName(th), want, got.typeName() });
}

/// Runs a C function from the VM: the bridge installed as the native of
/// every closure created by slang_pushcfunction.
pub const callCBridge = callC;

fn callC(th: *Thread, args: []Value) Error!Value {
    _ = args;
    const vm = th.vm;
    const cl = th.currentClosure();
    const f = cl.cfunc.?;
    if (vm.err) |*e| {
        e.deinit(vm.gpa);
        vm.err = null;
    }
    const fbase = baseOf(th);
    const r = f(th);
    // an error left pending counts as a failure whatever was returned
    if (vm.err != null) return error.Slang;
    if (r < 0) return vm.raise("error in native function {s}", .{cl.nameBytes()});
    if (r == 0) return .null;
    if (th.top <= fbase) return vm.raise("native function {s} returned without a result on the stack", .{cl.nameBytes()});
    return th.stack[th.top - 1];
}

fn newCClosure(vm: *VM, f: CFunction, name: []const u8, nvals: []const Value) *Closure {
    const cl = vm.newNative(name, callC, nvals);
    cl.cfunc = f;
    return cl;
}

// printf-style formatting through libc; the va_list is passed the way C
// passes it on this target.
const VaList = std.builtin.VaList;
const va_is_array = @typeInfo(VaList) == .array;
const VaArg = if (va_is_array) *anyopaque else VaList;
extern "c" fn vsnprintf(buf: [*]u8, size: usize, fmt: [*:0]const u8, ap: VaArg) c_int;

fn vformat(vm: *VM, fmt: [*:0]const u8, ap: *VaList) [:0]u8 {
    var copy = @cVaCopy(ap);
    defer @cVaEnd(&copy);
    var small: [512]u8 = undefined;
    const n = vsnprintf(&small, small.len, fmt, if (va_is_array) @ptrCast(&copy) else copy);
    if (n < 0) return vm.dupeZ("");
    const len: usize = @intCast(n);
    if (len < small.len) return vm.dupeZ(small[0..len]);
    const buf = vm.gpa.allocSentinel(u8, len, 0) catch oom();
    var copy2 = @cVaCopy(ap);
    defer @cVaEnd(&copy2);
    _ = vsnprintf(buf.ptr, len + 1, fmt, if (va_is_array) @ptrCast(&copy2) else copy2);
    return buf;
}

// ---- stack ----

pub export fn slang_gettop(th: *Thread) c_int {
    return @intCast(th.top - baseOf(th));
}

pub export fn slang_settop(th: *Thread, idx: c_int) void {
    const base = baseOf(th);
    var new_top: usize = undefined;
    if (idx >= 0) {
        new_top = base + @as(usize, @intCast(idx));
    } else {
        const back: usize = @intCast(-idx - 1);
        if (back > th.top - base) return;
        new_top = th.top - back;
    }
    th.ensure(new_top + 8) catch return;
    while (th.top < new_top) th.push(.null);
    th.top = new_top;
}

pub export fn slang_pushvalue(th: *Thread, idx: c_int) void {
    th.push(get(th, idx));
}

pub export fn slang_remove(th: *Thread, idx: c_int) void {
    const i = absIndex(th, idx) orelse return;
    std.mem.copyForwards(Value, th.stack[i .. th.top - 1], th.stack[i + 1 .. th.top]);
    th.top -= 1;
}

pub export fn slang_insert(th: *Thread, idx: c_int) void {
    const i = absIndex(th, idx) orelse return;
    const v = th.stack[th.top - 1];
    std.mem.copyBackwards(Value, th.stack[i + 1 .. th.top], th.stack[i .. th.top - 1]);
    th.stack[i] = v;
}

pub export fn slang_copy(th: *Thread, from: c_int, to: c_int) void {
    const v = get(th, from);
    const dst = slot(th, to) orelse return;
    dst.* = v;
}

pub export fn slang_type(th: *Thread, idx: c_int) c_int {
    const p = slot(th, idx) orelse return -1;
    return @intFromEnum(p.kind());
}

pub export fn slang_typename(t: c_int) [*:0]const u8 {
    return switch (t) {
        0 => "null",
        1 => "bool",
        2 => "int",
        3 => "double",
        4 => "string",
        5 => "table",
        6 => "function",
        7 => "userdata",
        8 => "thread",
        else => "none",
    };
}

// ---- push ----

pub export fn slang_pushnull(th: *Thread) void {
    th.push(.null);
}

pub export fn slang_pushbool(th: *Thread, b: bool) void {
    th.push(.{ .bool = b });
}

pub export fn slang_pushint(th: *Thread, i: i64) void {
    th.push(.{ .int = i });
}

pub export fn slang_pushdouble(th: *Thread, d: f64) void {
    th.push(.{ .float = d });
}

pub export fn slang_pushstring(th: *Thread, s: ?[*:0]const u8) void {
    th.push(th.vm.str(span(s)));
}

pub export fn slang_pushlstring(th: *Thread, s: [*]const u8, len: usize) void {
    th.push(th.vm.str(s[0..len]));
}

pub export fn slang_pushfstring(th: *Thread, fmt: [*:0]const u8, ...) callconv(.c) void {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    const s = vformat(th.vm, fmt, &ap);
    defer th.vm.gpa.free(s);
    th.push(th.vm.str(s));
}

pub export fn slang_pushcfunction(th: *Thread, f: CFunction, name: ?[*:0]const u8) void {
    th.push(.{ .function = newCClosure(th.vm, f, span(name), &.{}) });
}

pub export fn slang_pushcclosure(th: *Thread, f: CFunction, name: ?[*:0]const u8, nup: c_int) void {
    const n: usize = @intCast(@max(0, nup));
    const base = baseOf(th);
    const avail = th.top - base;
    const take = @min(n, avail);
    const vals = th.stack[th.top - take .. th.top];
    const cl = newCClosure(th.vm, f, span(name), vals);
    th.top -= take;
    th.push(.{ .function = cl });
}

// ---- read ----

pub export fn slang_tobool(th: *Thread, idx: c_int) bool {
    return get(th, idx).truthy();
}

pub export fn slang_toint(th: *Thread, idx: c_int) i64 {
    return switch (get(th, idx)) {
        .int => |i| i,
        .float => |f| @import("stdlib/core.zig").floatToInt(f),
        else => 0,
    };
}

pub export fn slang_todouble(th: *Thread, idx: c_int) f64 {
    return get(th, idx).asNumber();
}

pub export fn slang_tolstring(th: *Thread, idx: c_int, len: ?*usize) ?[*:0]const u8 {
    const s = get(th, idx).asString() orelse return null;
    if (len) |l| l.* = s.len;
    return @ptrCast(s.bytes().ptr);
}

pub export fn slang_touserdata(th: *Thread, idx: c_int) ?*anyopaque {
    const u = get(th, idx).asUserdata() orelse return null;
    return u.data.ptr;
}

pub export fn slang_tothread(th: *Thread, idx: c_int) ?*Thread {
    return get(th, idx).asThread();
}

// ---- checks ----

pub export fn slang_checkint(th: *Thread, idx: c_int) i64 {
    const v = get(th, idx);
    if (v == .int) return v.int;
    argError(th, idx, "int", v);
    return 0;
}

pub export fn slang_checknumber(th: *Thread, idx: c_int) f64 {
    const v = get(th, idx);
    if (v.isNumber()) return v.asNumber();
    argError(th, idx, "number", v);
    return 0;
}

pub export fn slang_checklstring(th: *Thread, idx: c_int, len: ?*usize) [*:0]const u8 {
    const v = get(th, idx);
    if (v.asString()) |s| {
        if (len) |l| l.* = s.len;
        return @ptrCast(s.bytes().ptr);
    }
    argError(th, idx, "string", v);
    if (len) |l| l.* = 0;
    return "";
}

pub export fn slang_checktable(th: *Thread, idx: c_int) void {
    const v = get(th, idx);
    if (v != .table) argError(th, idx, "table", v);
}

pub export fn slang_checkfunction(th: *Thread, idx: c_int) void {
    const v = get(th, idx);
    if (v != .function) argError(th, idx, "function", v);
}

pub export fn slang_checkudata(th: *Thread, idx: c_int, tname: [*:0]const u8) ?*anyopaque {
    const v = get(th, idx);
    const want = std.mem.span(tname);
    if (v.asUserdata()) |u| {
        if (std.mem.eql(u8, u.tname, want)) return u.data.ptr;
        if (th.vm.err == null) th.vm.setError("bad argument #{d} to '{s}' ({s} expected, got {s})", .{ idx, fnName(th), want, u.tname });
        return null;
    }
    argError(th, idx, want, v);
    return null;
}

pub export fn slang_optint(th: *Thread, idx: c_int, def: i64) i64 {
    const v = get(th, idx);
    if (v == .null) return def;
    return slang_checkint(th, idx);
}

pub export fn slang_optnumber(th: *Thread, idx: c_int, def: f64) f64 {
    const v = get(th, idx);
    if (v == .null) return def;
    return slang_checknumber(th, idx);
}

pub export fn slang_optstring(th: *Thread, idx: c_int, def: ?[*:0]const u8) ?[*:0]const u8 {
    const v = get(th, idx);
    if (v == .null) return def;
    return slang_checklstring(th, idx, null);
}

pub export fn slang_failed(th: *Thread) bool {
    return th.vm.err != null;
}

// ---- errors ----

pub export fn slang_error(th: *Thread, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    defer @cVaEnd(&ap);
    th.vm.setErrorOwned(vformat(th.vm, fmt, &ap));
    return err;
}

pub export fn slang_argerror(th: *Thread, arg: c_int, msg: ?[*:0]const u8) c_int {
    th.vm.setError("bad argument #{d} to '{s}' ({s})", .{ arg, fnName(th), span(msg) });
    return err;
}

pub export fn slang_raise(th: *Thread) c_int {
    th.vm.setErrorFromValue(pop(th));
    return err;
}

pub export fn slang_pusherror(th: *Thread) void {
    if (th.vm.err == null) {
        th.push(.null);
        return;
    }
    const v = th.vm.errorToValue();
    th.push(v);
}

pub export fn slang_clearerror(th: *Thread) void {
    if (th.vm.err) |*e| {
        e.deinit(th.vm.gpa);
        th.vm.err = null;
    }
}

pub export fn slang_errormessage(th: *Thread) ?[*:0]const u8 {
    const e = th.vm.err orelse return null;
    return e.message.ptr;
}

// ---- tables ----

pub export fn slang_newtable(th: *Thread) void {
    th.push(.{ .table = th.vm.newTable(0, 0) });
}

fn pushResult(th: *Thread, r: Error!Value) c_int {
    const v = r catch return err;
    th.push(v);
    return ok;
}

pub export fn slang_gettable(th: *Thread, idx: c_int) c_int {
    const t = get(th, idx);
    const key = pop(th);
    return pushResult(th, th.getTable(t, key));
}

pub export fn slang_getfield(th: *Thread, idx: c_int, name: [*:0]const u8) c_int {
    const t = get(th, idx);
    return pushResult(th, th.getTable(t, th.vm.str(std.mem.span(name))));
}

pub export fn slang_geti(th: *Thread, idx: c_int, i: i64) c_int {
    const t = get(th, idx);
    return pushResult(th, th.getTable(t, .{ .int = i }));
}

pub export fn slang_settable(th: *Thread, idx: c_int) c_int {
    const t = get(th, idx);
    const val = pop(th);
    const key = pop(th);
    th.setTable(t, key, val) catch return err;
    return ok;
}

pub export fn slang_setfield(th: *Thread, idx: c_int, name: [*:0]const u8) c_int {
    const t = get(th, idx);
    const val = pop(th);
    th.setTable(t, th.vm.str(std.mem.span(name)), val) catch return err;
    return ok;
}

pub export fn slang_seti(th: *Thread, idx: c_int, i: i64) c_int {
    const t = get(th, idx);
    const val = pop(th);
    th.setTable(t, .{ .int = i }, val) catch return err;
    return ok;
}

pub export fn slang_rawget(th: *Thread, idx: c_int) void {
    const t = get(th, idx).asTable();
    const key = pop(th);
    th.push(if (t) |p| p.get(key) else .null);
}

pub export fn slang_rawgeti(th: *Thread, idx: c_int, i: i64) void {
    const t = get(th, idx).asTable();
    th.push(if (t) |p| p.getInt(i) else .null);
}

pub export fn slang_rawset(th: *Thread, idx: c_int) void {
    const t = get(th, idx).asTable();
    const val = pop(th);
    const key = pop(th);
    if (t) |p| th.rawSet(p, key, val) catch {};
}

pub export fn slang_rawseti(th: *Thread, idx: c_int, i: i64) void {
    const t = get(th, idx).asTable();
    const val = pop(th);
    if (t) |p| p.set(th.vm.gpa, .{ .int = i }, val);
}

pub export fn slang_rawlen(th: *Thread, idx: c_int) i64 {
    return switch (get(th, idx)) {
        .table => |t| @intCast(t.len()),
        .string => |s| @intCast(s.len),
        else => 0,
    };
}

pub export fn slang_len(th: *Thread, idx: c_int) c_int {
    return pushResult(th, th.len(get(th, idx)));
}

pub export fn slang_append(th: *Thread, idx: c_int) void {
    const t = get(th, idx).asTable();
    const val = pop(th);
    if (t) |p| p.set(th.vm.gpa, .{ .int = @intCast(p.len()) }, val);
}

pub export fn slang_next(th: *Thread, idx: c_int) c_int {
    const t = get(th, idx).asTable() orelse {
        _ = pop(th);
        return 0;
    };
    const key = pop(th);
    const e = t.nextEntry(key) orelse return 0;
    th.push(e.key);
    th.push(e.val);
    return 1;
}

pub export fn slang_getmetatable(th: *Thread, idx: c_int) c_int {
    const m = interp.metaOf(get(th, idx)) orelse return 0;
    th.push(.{ .table = m });
    return 1;
}

pub export fn slang_setmetatable(th: *Thread, idx: c_int) void {
    // resolve the target before popping: a negative index refers to the
    // stack as it is on entry
    const target = get(th, idx);
    const m = pop(th).asTable();
    switch (target) {
        .table => |t| t.meta = m,
        .userdata => |u| u.meta = m,
        else => return,
    }
    if (m) |mt| {
        if (target.heapObject()) |o| vm_mod.gc.barrier(th.vm, o, .{ .table = mt });
    }
}

// ---- globals and calls ----

pub export fn slang_getglobal(th: *Thread, name: [*:0]const u8) void {
    th.push(th.vm.getGlobal(std.mem.span(name)));
}

pub export fn slang_setglobal(th: *Thread, name: [*:0]const u8) void {
    th.vm.setGlobal(std.mem.span(name), pop(th));
}

pub export fn slang_call(th: *Thread, nargs: c_int) c_int {
    const n: usize = @intCast(@max(0, nargs));
    const base = baseOf(th);
    if (th.top < base + n + 1) {
        th.vm.setError("slang_call: not enough values on the stack", .{});
        return err;
    }
    const fn_idx = th.top - n - 1;
    // a state of slang_isolate_new is one OS thread's at a time
    var entered = false;
    if (std.debug.runtime_safety and th.vm.driven) {
        const self = std.Thread.getCurrentId();
        if (th.vm.driver.cmpxchgStrong(0, self, .acquire, .monotonic)) |other| {
            if (other != self) @panic("slang_call: two OS threads use one isolate's state at once");
        } else entered = true;
    }
    defer if (entered) th.vm.driver.store(0, .release);
    th.callInPlace(fn_idx, n) catch return err;
    return ok;
}

pub export fn slang_typeof(th: *Thread, idx: c_int) c_int {
    return pushResult(th, th.typeOf(get(th, idx)));
}

pub export fn slang_tostr(th: *Thread, idx: c_int) c_int {
    const s = th.toString(get(th, idx)) catch return err;
    th.push(.{ .string = s });
    return ok;
}

// ---- userdata ----

pub export fn slang_newuserdata(th: *Thread, size: usize, tname: [*:0]const u8, fin: ?Finalizer) ?*anyopaque {
    const name = std.mem.span(tname);
    const u = th.vm.newUserdata(size, name, th.vm.type_metas.getName(name).asTable());
    u.finalizer = fin;
    th.push(.{ .userdata = u });
    return u.data.ptr;
}

pub export fn slang_testudata(th: *Thread, idx: c_int, tname: [*:0]const u8) ?*anyopaque {
    const u = get(th, idx).asUserdata() orelse return null;
    if (!std.mem.eql(u8, u.tname, std.mem.span(tname))) return null;
    return u.data.ptr;
}

// ---- buffers ----

pub export fn slang_tobuffer(th: *Thread, idx: c_int, count: ?*usize, elem_size: ?*usize) ?*anyopaque {
    const u = ctypes.asBuffer(get(th, idx)) orelse return null;
    const p = u.as(ctypes.Ptr);
    if (count) |c| c.* = p.count;
    if (elem_size) |e| e.* = p.ty.?.size;
    return @ptrFromInt(p.addr);
}

pub export fn slang_checkbuffer(th: *Thread, idx: c_int, count: ?*usize, elem_size: ?*usize) ?*anyopaque {
    const v = get(th, idx);
    if (ctypes.asBuffer(v) == null) {
        argError(th, idx, "buffer", v);
        return null;
    }
    return slang_tobuffer(th, idx, count, elem_size);
}

pub export fn slang_buffertype(th: *Thread, idx: c_int) ?[*:0]const u8 {
    const u = ctypes.asBuffer(get(th, idx)) orelse return null;
    const t = u.as(ctypes.Ptr).ty.?;
    // the scalar names are literals (NUL terminated); structs give their name
    // through a copy that lives as long as the type
    if (ctypes.primitiveName(t)) |n| return n;
    return "struct";
}

pub export fn slang_newbuffer(th: *Thread, tname: [*:0]const u8, count: usize) ?*anyopaque {
    const name = std.mem.span(tname);
    const t = ctypes.primitive(name) orelse {
        th.vm.setError("slang_newbuffer: unknown element type {s}", .{name});
        return null;
    };
    if (t.kind == .void or t.kind == .pointer or t.kind == .string) {
        th.vm.setError("slang_newbuffer: {s} cannot be a buffer's element", .{name});
        return null;
    }
    const u = ctypes.newBuffer(th, t, count) catch return null;
    th.push(.{ .userdata = u });
    return @ptrFromInt(u.as(ctypes.Ptr).addr);
}

/// The bytes of a string or of a buffer, or null.
pub export fn slang_tobytes(th: *Thread, idx: c_int, len: ?*usize) ?[*]const u8 {
    const v = get(th, idx);
    if (v.asString()) |str| {
        if (len) |l| l.* = str.len;
        return str.bytes().ptr;
    }
    const u = ctypes.asBuffer(v) orelse return null;
    const p = u.as(ctypes.Ptr);
    if (len) |l| l.* = p.count * p.ty.?.size;
    return @ptrFromInt(p.addr);
}

pub export fn slang_checkbytes(th: *Thread, idx: c_int, len: ?*usize) ?[*]const u8 {
    const v = get(th, idx);
    const b = slang_tobytes(th, idx, len) orelse {
        argError(th, idx, "string or buffer", v);
        return null;
    };
    return b;
}

// ---- references ----

pub export fn slang_ref(th: *Thread) c_int {
    return @intCast(th.vm.makeRef(pop(th)));
}

pub export fn slang_getref(th: *Thread, ref: c_int) void {
    th.push(th.vm.getRef(ref));
}

pub export fn slang_unref(th: *Thread, ref: c_int) void {
    th.vm.unref(ref);
}

// ---- per-VM state for extensions ----

pub export fn slang_settypemeta(th: *Thread, tname: [*:0]const u8) void {
    const v = pop(th);
    const key: Value = .{ .string = th.vm.newString(std.mem.span(tname)) };
    th.vm.type_metas.set(th.vm.gpa, key, if (v.asTable() != null) v else .null);
}

pub export fn slang_gettypemeta(th: *Thread, tname: [*:0]const u8) c_int {
    const v = th.vm.type_metas.getName(std.mem.span(tname));
    th.push(v);
    return @intFromBool(v != .null);
}

pub export fn slang_getextdata(th: *Thread, key: *const anyopaque) ?*anyopaque {
    return th.vm.getExt(key);
}

pub export fn slang_setextdata(th: *Thread, key: *const anyopaque, data: ?*anyopaque, fin: ?Finalizer) void {
    th.vm.setExt(key, data, fin);
}

pub export fn slang_oninterrupt(th: *Thread, f: ?Finalizer, data: ?*anyopaque) void {
    const vm = th.vm;
    vm.hooks_lock.lockUncancelable(vm.io);
    defer vm.hooks_lock.unlock(vm.io);
    if (f) |hook| {
        vm.interrupt_hooks.append(vm.gpa, .{ .f = hook, .data = data }) catch oom();
        return;
    }
    var i: usize = 0;
    while (i < vm.interrupt_hooks.items.len) {
        if (vm.interrupt_hooks.items[i].data == data) {
            _ = vm.interrupt_hooks.orderedRemove(i);
        } else i += 1;
    }
}

pub export fn slang_onclose(th: *Thread, f: Finalizer, data: ?*anyopaque) void {
    th.vm.close_hooks.append(th.vm.gpa, .{ .f = f, .data = data }) catch oom();
}

pub export fn slang_interrupted(th: *Thread) bool {
    return th.vm.interrupt.load(.seq_cst);
}

// ---- modules ----

pub export fn slang_newmodule(th: *Thread, l: [*]const Reg) void {
    slang_newtable(th);
    slang_setfuncs(th, l);
}

pub export fn slang_setfuncs(th: *Thread, l: [*]const Reg) void {
    const t = get(th, -1).asTable() orelse return;
    var i: usize = 0;
    while (l[i].name) |name| : (i += 1) {
        const f = l[i].func orelse continue;
        const n = std.mem.span(name);
        t.set(th.vm.gpa, th.vm.str(n), .{ .function = newCClosure(th.vm, f, n, &.{}) });
    }
}

// ---- embedding ----

pub export fn slang_version() c_int {
    return api_version;
}

pub export fn slang_new() ?*Thread {
    const io = std.Io.Threaded.global_single_threaded.io();
    const vm = VM.create(std.heap.c_allocator, io, null);
    vm.embedded = &boot.embedded_files;
    stdlib.open(vm);
    stdlib.boot(vm) catch {
        vm.destroy();
        return null;
    };
    return vm.main;
}

pub export fn slang_isolate_new(th: *Thread, idx: c_int) ?*Thread {
    const v = get(th, idx);
    const vm = isolates.newDriven(th.vm, v) catch return null;
    return vm.main;
}

pub export fn slang_send(th: *Thread, ch_idx: c_int) c_int {
    const ch = get(th, ch_idx);
    const v = pop(th);
    _ = isolates.sendTo(th, ch, v, true) catch return err;
    return ok;
}

pub export fn slang_trysend(th: *Thread, ch_idx: c_int) c_int {
    const ch = get(th, ch_idx);
    const v = pop(th);
    const sent = isolates.sendTo(th, ch, v, false) catch return err;
    return @intFromBool(sent);
}

pub export fn slang_receive(th: *Thread, ch_idx: c_int) c_int {
    const v = isolates.receiveFrom(th, get(th, ch_idx), true) catch return err;
    th.push(v);
    return ok;
}

pub export fn slang_tryreceive(th: *Thread, ch_idx: c_int) c_int {
    const v = isolates.receiveFrom(th, get(th, ch_idx), false) catch return err;
    th.push(v);
    return @intFromBool(v != .null);
}

pub export fn slang_close(th: *Thread) void {
    th.vm.destroy();
}

pub export fn slang_loadstring(th: *Thread, src: [*:0]const u8, origin: ?[*:0]const u8) c_int {
    const vm = th.vm;
    const compile = vm.getGlobal("compile");
    const r = th.call(compile, &.{ vm.str(std.mem.span(src)), vm.str(span(origin)) });
    return pushResult(th, r);
}

pub export fn slang_dostring(th: *Thread, src: [*:0]const u8, origin: ?[*:0]const u8) c_int {
    if (slang_loadstring(th, src, origin) != ok) return err;
    return slang_call(th, 0);
}

pub export fn slang_dofile(th: *Thread, path: [*:0]const u8) c_int {
    const cl = boot.loadFile(th.vm, std.mem.span(path)) catch return err;
    th.push(.{ .function = cl });
    return slang_call(th, 0);
}

pub export fn slang_preload(th: *Thread, name: [*:0]const u8) void {
    stdlib.preload(th.vm, std.mem.span(name), pop(th));
}
